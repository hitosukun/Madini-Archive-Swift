import GRDB
import SwiftUI

@MainActor
final class AppServices: ObservableObject {
    let conversations: any ConversationRepository
    let search: any SearchRepository
    let projects: any ProjectRepository
    let projectMemberships: any ProjectMembershipRepository
    let projectSuggestions: any ProjectSuggestionRepository
    let projectSuggester: any ProjectSuggester
    let rawExportVault: any RawExportVault
    let rawAssetResolver: any RawAssetResolver
    /// Optional: populated only when the app is running against a real
    /// archive database. Mock mode leaves this `nil` — there's no vault to
    /// load raw JSON from. The rich-content reader gates its "switch to
    /// Source view" UI on this being non-nil.
    let rawConversationLoader: (any RawConversationLoader)?
    let bookmarks: any BookmarkRepository
    let tags: any TagRepository
    let views: any ViewService
    let stats: any StatsRepository
    let wikiVaults: any WikiVaultRepository
    let dataSource: DataSource

    enum DataSource {
        case database(path: String)
        case mock
    }

    #if os(macOS)
    /// Path the watcher polls. Always resolvable, even in mock mode, so the
    /// UI can still render "this is where it would go" when intake is off.
    /// Published so the Drop folder pane re-renders when the user picks a
    /// different directory via `setIntakeDirectory(_:)`.
    ///
    /// Seeded from `IntakeLocationStore.load()` on launch — if the user had
    /// previously overridden the location, we honor that before any lazy
    /// intake wiring runs. Absent override ⇒ `IntakePaths.intakeDir`
    /// (`~/Documents/Madini Archive Intake`).
    @Published private(set) var intakeDirURL: URL = IntakeLocationStore.load() ?? IntakePaths.intakeDir

    /// Lazy because `IntakeService` needs `self` to drive `ImportCoordinator`.
    /// Constructed on first access, started explicitly via `startIntake()` —
    /// we don't auto-start in `init` because the mock `DataSource` would wire
    /// the intake folder to a `NoOpRawExportVault` that rejects every ingest.
    private(set) lazy var intake: IntakeService = IntakeService(
        services: self,
        intakeDir: intakeDirURL
    )

    /// Kick off auto-intake. No-op when the app is running off mock data
    /// (there's no Vault to ingest into, so polling would just spam the
    /// activity log with "Vault ingest failed" for anything the user drops).
    func startIntake() {
        guard case .database = dataSource else { return }
        intake.start()
    }

    func stopIntake() {
        intake.stop()
    }

    /// Activity log surfaced by the auto-intake watcher. `nil` when the app
    /// is running against mock data — the watcher is never started in that
    /// mode, so there's no log to show.
    var intakeActivityLog: IntakeActivityLog? {
        guard case .database = dataSource else { return nil }
        return intake.activityLog
    }

    /// Re-point the auto-intake watcher at a new directory (or, with `nil`,
    /// reset to the default under `~/Documents`). Persists the choice so it
    /// survives relaunches, and — in database mode — restarts the watcher
    /// against the new path if it was already running.
    func setIntakeDirectory(_ url: URL?) {
        let resolved = url ?? IntakePaths.intakeDir
        intakeDirURL = resolved
        IntakeLocationStore.save(url)
        if case .database = dataSource {
            intake.switchDirectory(to: resolved)
        }
    }
    #endif

    init(
        conversations: any ConversationRepository,
        search: any SearchRepository,
        projects: any ProjectRepository,
        projectMemberships: any ProjectMembershipRepository,
        projectSuggestions: any ProjectSuggestionRepository,
        projectSuggester: any ProjectSuggester,
        rawExportVault: any RawExportVault,
        rawAssetResolver: any RawAssetResolver,
        rawConversationLoader: (any RawConversationLoader)? = nil,
        bookmarks: any BookmarkRepository,
        tags: any TagRepository,
        views: any ViewService,
        stats: any StatsRepository,
        wikiVaults: any WikiVaultRepository,
        dataSource: DataSource
    ) {
        self.conversations = conversations
        self.search = search
        self.projects = projects
        self.projectMemberships = projectMemberships
        self.projectSuggestions = projectSuggestions
        self.projectSuggester = projectSuggester
        self.rawExportVault = rawExportVault
        self.rawAssetResolver = rawAssetResolver
        self.rawConversationLoader = rawConversationLoader
        self.bookmarks = bookmarks
        self.tags = tags
        self.views = views
        self.stats = stats
        self.wikiVaults = wikiVaults
        self.dataSource = dataSource
    }

    convenience init() {
        AppPaths.ensureUserDataDir()

        let dbPath = AppPaths.databaseFile.path
        if FileManager.default.fileExists(atPath: dbPath) {
            do {
                let dbQueue = try DatabaseQueue(path: dbPath)
                try Self.bootstrapViewLayerSchema(dbQueue: dbQueue)
                let conversations = GRDBConversationRepository(dbQueue: dbQueue)
                let projects = GRDBProjectRepository(dbQueue: dbQueue)
                let projectMemberships = GRDBProjectMembershipRepository(dbQueue: dbQueue)
                let projectSuggestions = GRDBProjectSuggestionRepository(dbQueue: dbQueue)
                let vault = GRDBRawExportVault(dbQueue: dbQueue)
                self.init(
                    conversations: conversations,
                    search: GRDBSearchRepository(dbQueue: dbQueue),
                    projects: projects,
                    projectMemberships: projectMemberships,
                    projectSuggestions: projectSuggestions,
                    projectSuggester: TFIDFProjectSuggester(
                        conversations: conversations,
                        projects: projects,
                        memberships: projectMemberships,
                        suggestions: projectSuggestions
                    ),
                    rawExportVault: vault,
                    rawAssetResolver: GRDBRawAssetResolver(dbQueue: dbQueue),
                    rawConversationLoader: GRDBRawConversationLoader(dbQueue: dbQueue, vault: vault),
                    bookmarks: GRDBBookmarkRepository(dbQueue: dbQueue),
                    tags: GRDBTagRepository(dbQueue: dbQueue),
                    views: GRDBViewService(dbQueue: dbQueue),
                    stats: GRDBStatsRepository(dbQueue: dbQueue),
                    wikiVaults: GRDBWikiVaultRepository(dbQueue: dbQueue),
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
            projects: MockProjectRepository(),
            projectMemberships: MockProjectMembershipRepository(),
            projectSuggestions: MockProjectSuggestionRepository(),
            projectSuggester: NoOpProjectSuggester(),
            rawExportVault: NoOpRawExportVault(),
            rawAssetResolver: NoOpRawAssetResolver(),
            bookmarks: MockBookmarkRepository(),
            tags: MockTagRepository(),
            views: MockViewService(),
            stats: MockStatsRepository(),
            wikiVaults: MockWikiVaultRepository(),
            dataSource: .mock
        )
    }

    static func bootstrapViewLayerSchema(dbQueue: DatabaseQueue) throws {
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
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS projects (
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    origin TEXT NOT NULL CHECK (origin IN ('canonical_import', 'user_created')),
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                )
                """)
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS project_memberships (
                    thread_id TEXT PRIMARY KEY,
                    project_id TEXT NOT NULL,
                    origin TEXT NOT NULL CHECK (origin IN ('canonical_import', 'manual_add', 'accepted_suggestion')),
                    assigned_at TEXT NOT NULL,
                    FOREIGN KEY (thread_id) REFERENCES conversations(id) ON DELETE CASCADE,
                    FOREIGN KEY (project_id) REFERENCES projects(id) ON DELETE CASCADE
                )
                """)
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_project_memberships_project
                ON project_memberships(project_id)
                """)
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS project_suggestions (
                    thread_id TEXT NOT NULL,
                    target_project_id TEXT NOT NULL,
                    score REAL NOT NULL,
                    reason TEXT NOT NULL,
                    state TEXT NOT NULL CHECK (state IN ('pending', 'accepted', 'dismissed')),
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL,
                    PRIMARY KEY (thread_id, target_project_id),
                    FOREIGN KEY (thread_id) REFERENCES conversations(id) ON DELETE CASCADE,
                    FOREIGN KEY (target_project_id) REFERENCES projects(id) ON DELETE CASCADE
                )
                """)
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_project_suggestions_thread_state
                ON project_suggestions(thread_id, state)
                """)
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_project_suggestions_state_score
                ON project_suggestions(state, score DESC)
                """)
            // Raw Export Vault schema (5 tables + 2 indexes) lives next to the
            // Vault implementation so the on-disk shape stays co-located with
            // the code that reads it. `installSchema` is idempotent, so this
            // plays nicely with the surrounding `CREATE ... IF NOT EXISTS`
            // idioms in this bootstrap.
            try GRDBRawExportVault.installSchema(in: db)

            // conversation_raw_refs links a `conversations.id` (provider-native
            // conversation ID, populated by the Python importer) back to the
            // exact Raw Export Vault location where that conversation's source
            // JSON lives. The reader uses this as an O(1) lookup — on miss,
            // `RawConversationLoader` scans the newest matching snapshot and
            // caches the hit here. Composite PK means one row per
            // (conversation, snapshot) pair: the same conversation can appear
            // in multiple snapshots (e.g. user re-exports later) and we keep
            // the pointer per snapshot so deleting a snapshot CASCADEs the
            // pointer with it.
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS conversation_raw_refs (
                    conversation_id TEXT NOT NULL,
                    snapshot_id INTEGER NOT NULL,
                    relative_path TEXT NOT NULL,
                    json_index INTEGER NOT NULL,
                    provider TEXT NOT NULL,
                    created_at TEXT NOT NULL,
                    PRIMARY KEY (conversation_id, snapshot_id),
                    FOREIGN KEY (snapshot_id) REFERENCES raw_export_snapshots(id) ON DELETE CASCADE
                )
                """)
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_conversation_raw_refs_conv
                ON conversation_raw_refs(conversation_id)
                """)

            // Body-data search index (`search_idx`). The Swift app owns this
            // index and uses FTS5 trigram tokenization so `title:マディニ`
            // matches "マディニちゃん画像" style titles (substring search
            // that the legacy `unicode61` tokenizer couldn't express for
            // CJK text). See `SearchQueryParser` for the query grammar.
            //
            // Migration policy:
            //   - Fresh DB: create empty trigram index. Rebuild is a no-op.
            //   - Legacy index (unicode61, or any non-trigram config):
            //     drop + recreate + repopulate from `conversations` +
            //     `messages`. At ~1,000 conversations this finishes in well
            //     under a second; scaling to ~100,000 (the 100x target) is
            //     tracked as a separate task that hoists this out of the
            //     synchronous bootstrap and wraps it with progress UI.
            //
            // We detect the need for migration by scanning the existing
            // `CREATE VIRTUAL TABLE` statement in `sqlite_master` for the
            // word "trigram". Any other tokenizer (or no table at all)
            // triggers a rebuild.
            let searchSchemaRow = try Row.fetchOne(db, sql: """
                SELECT sql FROM sqlite_master
                WHERE type = 'table' AND name = 'search_idx'
                """)
            let existingSearchSQL = (searchSchemaRow?["sql"] as String?) ?? ""
            let isTrigramIndex = existingSearchSQL.range(
                of: "trigram",
                options: .caseInsensitive
            ) != nil
            if !isTrigramIndex {
                if !existingSearchSQL.isEmpty {
                    try db.execute(sql: "DROP TABLE search_idx")
                }
                try db.execute(sql: """
                    CREATE VIRTUAL TABLE IF NOT EXISTS search_idx USING fts5(
                        conv_id UNINDEXED,
                        title,
                        content,
                        tokenize = "trigram case_sensitive 0"
                    )
                    """)
                // Only repopulate if the canonical tables are present.
                // A fresh DB (no conversations yet) can skip rebuild — the
                // import pipeline inserts into `search_idx` when a
                // conversation is added.
                let convTableExists = try Row.fetchOne(db, sql: """
                    SELECT 1 FROM sqlite_master
                    WHERE type = 'table' AND name = 'conversations'
                    """) != nil
                let messagesTableExists = try Row.fetchOne(db, sql: """
                    SELECT 1 FROM sqlite_master
                    WHERE type = 'table' AND name = 'messages'
                    """) != nil
                if convTableExists && messagesTableExists {
                    // Emit a timing + size diagnostic so scale problems
                    // show up in Console.app rather than as a silent
                    // launch freeze. The threshold for "this will feel
                    // slow" is roughly 10k conversations on M-series
                    // hardware — beyond that we should hoist the
                    // rebuild out of bootstrap (see TODO below).
                    let convCount = try Int.fetchOne(
                        db,
                        sql: "SELECT COUNT(*) FROM conversations"
                    ) ?? 0
                    let startedAt = Date()
                    if convCount > 10_000 {
                        print("[search_idx] Rebuilding FTS5 trigram index over \(convCount) conversations. UI may appear frozen; see TODO in AppServices for progress-UI follow-up.")
                    }
                    try db.execute(sql: """
                        INSERT INTO search_idx (conv_id, title, content)
                        SELECT
                            c.id,
                            COALESCE(c.title, ''),
                            COALESCE((
                                SELECT GROUP_CONCAT(m.content, ' ')
                                FROM messages m
                                WHERE m.conv_id = c.id
                            ), '')
                        FROM conversations c
                        """)
                    let elapsed = Date().timeIntervalSince(startedAt)
                    print(String(format: "[search_idx] Rebuilt trigram index: %d conversations in %.2fs", convCount, elapsed))
                }
            }
            // TODO (100x-scale follow-up): hoist the trigram rebuild
            // out of this synchronous bootstrap transaction once library
            // sizes cross ~10k conversations. Proposed shape:
            //
            //   1. Add a `pending_migrations(name TEXT PRIMARY KEY)` table.
            //   2. In bootstrap, insert `'search_idx_trigram'` into it
            //      instead of running the INSERT inline.
            //   3. On app launch, after AppServices is wired up, check
            //      `pending_migrations` and run the rebuild in an async
            //      task with a launch-screen progress view that reads
            //      `SELECT COUNT(*) FROM search_idx` periodically.
            //   4. Delete the pending-migrations row on success.
            //
            // At today's scale (hundreds-to-low-thousands of threads)
            // the inline path is fast enough that the extra
            // orchestration isn't worth the complexity; revisit when
            // the live DB crosses the threshold or when a user reports
            // a slow first-launch after upgrade.

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

            // Migration 3: index timestamp columns + the primary_time
            // COALESCE expression itself.
            //
            // `primary_time` is not a stored column — it's a SELECT-time
            // COALESCE over (source_created_at → imported_at → date_str)
            // defined verbatim as `primaryTimeSQL` in
            // GRDBConversationRepository / GRDBSearchRepository (and,
            // once the next commit lands, in `SearchFilterSQL`). Date-
            // range predicates in the existing WHERE assembly and the
            // upcoming Stats aggregations both compare against this
            // exact expression.
            //
            // EXPLAIN QUERY PLAN (verified against an in-memory schema
            // clone with 5,000 conversations / 10,000 messages):
            //  - Indexing only the underlying columns leaves the planner
            //    doing SCAN conversations for COALESCE-bound predicates
            //    — the NULLIF/TRIM/COALESCE wrapper hides the column
            //    lookup.
            //  - An *expression* index whose key matches the COALESCE
            //    expression byte-for-byte gets picked up
            //    (SEARCH ... USING INDEX (<expr>>? AND <expr><?)).
            //
            // We register all three:
            //   - idx_conversations_primary_time_expr is the one Stats
            //     and date-range queries actually use; its key string
            //     MUST stay byte-for-byte in sync with
            //     `GRDBConversationRepository.primaryTimeSQL`. If the
            //     COALESCE expression in that constant changes, register
            //     a new migration that drops / recreates this index in
            //     the same commit — do NOT modify Migration 3 in place.
            //   - idx_conversations_source_created_at /
            //     idx_conversations_imported_at cover direct-column
            //     predicates. Current code does not query the columns
            //     directly, but they're the natural sort keys for
            //     future Stats axes and for any planner path that
            //     prefers a covering index over the expression index.
            //   - date_str is left unindexed — last-resort fallback,
            //     write cost outweighs the benefit.
            if userVersion < 3 {
                try db.execute(sql: """
                    CREATE INDEX IF NOT EXISTS idx_conversations_primary_time_expr
                    ON conversations(
                        COALESCE(
                            NULLIF(TRIM(source_created_at), ''),
                            NULLIF(TRIM(imported_at), ''),
                            NULLIF(TRIM(date_str), '')
                        )
                    )
                    """)
                try db.execute(sql: """
                    CREATE INDEX IF NOT EXISTS idx_conversations_source_created_at
                    ON conversations(source_created_at)
                    """)
                try db.execute(sql: """
                    CREATE INDEX IF NOT EXISTS idx_conversations_imported_at
                    ON conversations(imported_at)
                    """)
                try db.execute(sql: "PRAGMA user_version = 3")
            }

            if userVersion < 4 {
                try db.execute(sql: """
                    CREATE TABLE IF NOT EXISTS wiki_vaults (
                        id TEXT PRIMARY KEY,
                        name TEXT NOT NULL,
                        path TEXT NOT NULL UNIQUE,
                        bookmark_data BLOB,
                        created_at TEXT NOT NULL,
                        last_indexed_at TEXT
                    )
                    """)
                try db.execute(sql: "PRAGMA user_version = 4")
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
