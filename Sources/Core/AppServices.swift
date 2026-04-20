import GRDB
import SwiftUI

@MainActor
final class AppServices: ObservableObject {
    let conversations: any ConversationRepository
    let search: any SearchRepository
    let bookmarks: any BookmarkRepository
    let tags: any TagRepository
    let projects: any ProjectRepository
    let views: any ViewService
    let dataSource: DataSource

    enum DataSource {
        case database(path: String)
        case mock
    }

    init(
        conversations: any ConversationRepository,
        search: any SearchRepository,
        bookmarks: any BookmarkRepository,
        tags: any TagRepository,
        projects: any ProjectRepository,
        views: any ViewService,
        dataSource: DataSource
    ) {
        self.conversations = conversations
        self.search = search
        self.bookmarks = bookmarks
        self.tags = tags
        self.projects = projects
        self.views = views
        self.dataSource = dataSource
    }

    convenience init() {
        AppPaths.ensureUserDataDir()

        let dbPath = AppPaths.databaseFile.path
        if FileManager.default.fileExists(atPath: dbPath) {
            do {
                let dbQueue = try DatabaseQueue(path: dbPath)
                try Self.bootstrapViewLayerSchema(dbQueue: dbQueue)
                self.init(
                    conversations: GRDBConversationRepository(dbQueue: dbQueue),
                    search: GRDBSearchRepository(dbQueue: dbQueue),
                    bookmarks: GRDBBookmarkRepository(dbQueue: dbQueue),
                    tags: GRDBTagRepository(dbQueue: dbQueue),
                    projects: GRDBProjectRepository(dbQueue: dbQueue),
                    views: GRDBViewService(dbQueue: dbQueue),
                    dataSource: .database(path: dbPath)
                )
                return
            } catch {
                print("Failed to open database: \(error)")
            }
        }

        let conversationRepository = MockConversationRepository()
        self.init(
            conversations: conversationRepository,
            search: MockSearchRepository(
                items: PreviewData.conversations,
                details: PreviewData.details
            ),
            bookmarks: MockBookmarkRepository(),
            tags: MockTagRepository(),
            projects: MockProjectRepository(),
            views: MockViewService(),
            dataSource: .mock
        )
    }

    private static func bootstrapViewLayerSchema(dbQueue: DatabaseQueue) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS saved_filters (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    kind TEXT NOT NULL,
                    target_type TEXT NOT NULL,
                    filter_hash TEXT NOT NULL,
                    label TEXT NOT NULL,
                    filter_json TEXT NOT NULL,
                    created_at TEXT NOT NULL,
                    last_used_at TEXT NOT NULL
                )
                """)
            try db.execute(sql: """
                CREATE UNIQUE INDEX IF NOT EXISTS idx_saved_filters_lookup
                ON saved_filters(kind, target_type, filter_hash)
                """)
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_saved_filters_recent
                ON saved_filters(kind, target_type, last_used_at DESC, created_at DESC)
                """)
            // Migration: add `pinned` column to saved_filters, and lift legacy
            // `kind = 'saved_view'` rows into pinned=1. After this migration the
            // UI treats the filters list as a single ranked list (pinned first,
            // then most-recently-used), capped to 20 entries.
            let pinnedExists = try Row.fetchAll(db, sql: "PRAGMA table_info(saved_filters)")
                .contains { ($0["name"] as String?) == "pinned" }
            if !pinnedExists {
                try db.execute(sql: """
                    ALTER TABLE saved_filters
                    ADD COLUMN pinned INTEGER NOT NULL DEFAULT 0
                    """)
                try db.execute(sql: """
                    UPDATE saved_filters SET pinned = 1 WHERE kind = 'saved_view'
                    """)
            }
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_saved_filters_unified
                ON saved_filters(target_type, pinned DESC, last_used_at DESC)
                """)
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS bookmarks (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    target_type TEXT NOT NULL,
                    target_id TEXT NOT NULL,
                    payload_json TEXT,
                    tags TEXT,
                    note TEXT,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                )
                """)
            try db.execute(sql: """
                CREATE UNIQUE INDEX IF NOT EXISTS idx_bookmarks_target
                ON bookmarks(target_type, target_id)
                """)
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_bookmarks_recent
                ON bookmarks(target_type, updated_at DESC, created_at DESC)
                """)
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS bookmark_tags (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    name TEXT NOT NULL UNIQUE COLLATE NOCASE,
                    system_key TEXT,
                    is_system INTEGER NOT NULL DEFAULT 0,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                )
                """)
            try db.execute(sql: """
                CREATE UNIQUE INDEX IF NOT EXISTS idx_bookmark_tags_system_key
                ON bookmark_tags(system_key)
                WHERE system_key IS NOT NULL
                """)
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS bookmark_tag_links (
                    bookmark_id INTEGER NOT NULL,
                    tag_id INTEGER NOT NULL,
                    created_at TEXT NOT NULL,
                    PRIMARY KEY (bookmark_id, tag_id),
                    FOREIGN KEY(bookmark_id) REFERENCES bookmarks(id),
                    FOREIGN KEY(tag_id) REFERENCES bookmark_tags(id)
                )
                """)
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_bookmark_tag_links_tag
                ON bookmark_tag_links(tag_id, bookmark_id)
                """)
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_bookmark_tag_links_bookmark
                ON bookmark_tag_links(bookmark_id, tag_id)
                """)

            // Seed the Trash system tag. Trash is a "rescue lane" — when a
            // user-defined tag is deleted, the conversations that had it get
            // Trash attached in its place, so nothing silently disappears.
            // Attaching any non-Trash tag to a conversation auto-detaches
            // Trash (see GRDBTagRepository.attachTag).
            let timestamp = Self.schemaBootstrapTimestamp()
            try db.execute(sql: """
                INSERT OR IGNORE INTO bookmark_tags (
                    name, system_key, is_system, created_at, updated_at
                )
                VALUES ('Trash', 'trash', 1, ?, ?)
                """, arguments: [timestamp, timestamp])

            // Migration 1: promote prompt-level tag links to thread-level.
            //
            // The app used to support attaching tags per prompt; the UI for
            // that was retired and `bindings(forConversationIDs:)` now only
            // reads thread-level links. Legacy databases (typically imported
            // from the Python backend) can still have tag links pointing at
            // `target_type = 'prompt'` bookmarks, which would make those
            // conversations appear untagged in the new UI — a regression from
            // the user's POV.
            //
            // We fix this once, on first launch against an un-migrated DB, by:
            //   (a) creating thread-level bookmark rows for any conversation
            //       that has tagged prompt-level bookmarks but no thread-level
            //       bookmark yet, and
            //   (b) copying the prompt-level tag links onto those thread-level
            //       bookmarks (INSERT OR IGNORE so repeats are harmless).
            //
            // Migration 2 below then physically deletes the now-orphaned
            // prompt-level rows — but migration 1 is careful to land them on
            // the thread side *first*, so the delete in migration 2 never
            // loses data that the new UI still wants to surface.
            let userVersion = try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0
            if userVersion < 1 {
                // (a) Materialize missing thread bookmarks for conversations
                //     whose only bookmark rows are prompt-level + tagged.
                try db.execute(sql: """
                    INSERT OR IGNORE INTO bookmarks (
                        target_type, target_id, created_at, updated_at
                    )
                    SELECT
                        'thread',
                        substr(b.target_id, 1, instr(b.target_id, ':') - 1),
                        ?,
                        ?
                    FROM bookmarks b
                    WHERE b.target_type = 'prompt'
                      AND instr(b.target_id, ':') > 1
                      AND EXISTS (
                          SELECT 1 FROM bookmark_tag_links tl
                          WHERE tl.bookmark_id = b.id
                      )
                    """, arguments: [timestamp, timestamp])

                // (b) Copy the links. We join prompt bookmarks → their tag
                //     links → the corresponding thread bookmark and INSERT OR
                //     IGNORE onto `bookmark_tag_links` so the composite PK
                //     dedupes anything that already exists.
                try db.execute(sql: """
                    INSERT OR IGNORE INTO bookmark_tag_links (
                        bookmark_id, tag_id, created_at
                    )
                    SELECT
                        thread_b.id,
                        tl.tag_id,
                        tl.created_at
                    FROM bookmarks prompt_b
                    JOIN bookmark_tag_links tl ON tl.bookmark_id = prompt_b.id
                    JOIN bookmarks thread_b
                         ON thread_b.target_type = 'thread'
                        AND thread_b.target_id = substr(
                                prompt_b.target_id, 1, instr(prompt_b.target_id, ':') - 1
                            )
                    WHERE prompt_b.target_type = 'prompt'
                      AND instr(prompt_b.target_id, ':') > 1
                    """)

                try db.execute(sql: "PRAGMA user_version = 1")
            }

            // Migration 2: physically retire prompt-level bookmarks.
            //
            // Migration 1 already rolled every useful link up to the
            // thread level, so the remaining `target_type = 'prompt'`
            // rows are now strictly dead weight — plus their mere
            // existence forces every bookmark-tag query in the app to
            // carry an `OR target_type = 'prompt'` branch (see
            // GRDBConversationRepository and GRDBSearchRepository).
            // Deleting them once lets those branches go away and keeps
            // the DB from growing unboundedly as the user's imported
            // archive accumulates prompt-level rows from Python-backend
            // runs that still predate this app.
            //
            // Order matters: delete the link rows first so the FK from
            // `bookmark_tag_links.bookmark_id` → `bookmarks.id` doesn't
            // wedge us in a partially-deleted state if someone adds
            // ON DELETE RESTRICT later.
            if userVersion < 2 {
                try db.execute(sql: """
                    DELETE FROM bookmark_tag_links
                    WHERE bookmark_id IN (
                        SELECT id FROM bookmarks WHERE target_type = 'prompt'
                    )
                    """)
                try db.execute(sql: """
                    DELETE FROM bookmarks WHERE target_type = 'prompt'
                    """)
                try db.execute(sql: "PRAGMA user_version = 2")
            }

            // Migration 3: project-based organization schema.
            //
            // Adds `project` / `project_membership` / `project_suggestion`
            // tables that back the 2026-04 spec's project-based tag
            // replacement. Delegates the DDL itself to
            // `ProjectSchemaDraft.allStatements` so the schema text can
            // be reviewed and evolved independently of this migration
            // list — see that file for the rationale on each index and
            // the 1-thread-1-project invariant.
            //
            // `CREATE TABLE IF NOT EXISTS` means a re-run on an already-
            // migrated DB is a no-op, so bumping user_version is the
            // authoritative signal. Kept on a separate `if` (not an
            // `else if` chain) so a future migration 4 that edits one
            // of these tables doesn't have to reason about whether the
            // base tables exist yet.
            if userVersion < 3 {
                for sql in ProjectSchemaDraft.allStatements {
                    try db.execute(sql: sql)
                }
                try db.execute(sql: "PRAGMA user_version = 3")
            }
        }
    }

    private static func schemaBootstrapTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: Date())
    }
}
