import GRDB
import SwiftUI

@MainActor
final class AppServices: ObservableObject {
    let conversations: any ConversationRepository
    let search: any SearchRepository
    let bookmarks: any BookmarkRepository
    let tags: any TagRepository
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
        views: any ViewService,
        dataSource: DataSource
    ) {
        self.conversations = conversations
        self.search = search
        self.bookmarks = bookmarks
        self.tags = tags
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
        }
    }
}
