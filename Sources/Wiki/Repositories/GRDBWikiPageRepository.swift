import Foundation
import GRDB

final class GRDBWikiPageRepository: WikiPageRepository, @unchecked Sendable {
    private let dbQueue: DatabaseQueue

    init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    static func installSchema(in db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS wiki_pages (
                id INTEGER PRIMARY KEY,
                vault_id TEXT NOT NULL,
                path TEXT NOT NULL,
                title TEXT,
                frontmatter_json TEXT,
                body TEXT NOT NULL,
                last_modified TEXT NOT NULL,
                UNIQUE(vault_id, path)
            )
            """)
        try db.execute(sql: """
            CREATE INDEX IF NOT EXISTS idx_wiki_pages_vault
            ON wiki_pages(vault_id)
            """)
        try db.execute(sql: """
            CREATE VIRTUAL TABLE IF NOT EXISTS wiki_pages_fts USING fts5(
                title, body,
                content='wiki_pages',
                content_rowid='id',
                tokenize='unicode61 remove_diacritics 2'
            )
            """)
    }

    // MARK: - Read

    func fetchPage(id: Int) async throws -> WikiPage? {
        try await GRDBAsync.read(from: dbQueue) { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT id, vault_id, path, title, frontmatter_json, body, last_modified
                FROM wiki_pages WHERE id = ?
                """, arguments: [id])
            return row.map(Self.makePage)
        }
    }

    func fetchPageByPath(vaultID: String, path: String) async throws -> WikiPage? {
        try await GRDBAsync.read(from: dbQueue) { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT id, vault_id, path, title, frontmatter_json, body, last_modified
                FROM wiki_pages WHERE vault_id = ? AND path = ?
                """, arguments: [vaultID, path])
            return row.map(Self.makePage)
        }
    }

    func listPages(vaultID: String, offset: Int, limit: Int) async throws -> [WikiPage] {
        try await GRDBAsync.read(from: dbQueue) { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, vault_id, path, title, frontmatter_json, body, last_modified
                FROM wiki_pages
                WHERE vault_id = ?
                ORDER BY path COLLATE NOCASE
                LIMIT ? OFFSET ?
                """, arguments: [vaultID, limit, offset])
            return rows.map(Self.makePage)
        }
    }

    func searchPages(vaultID: String, query: String, offset: Int, limit: Int) async throws -> [WikiPageSearchResult] {
        try await GRDBAsync.read(from: dbQueue) { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT
                    p.id, p.vault_id, p.path, p.title, p.last_modified,
                    snippet(wiki_pages_fts, 1, '<b>', '</b>', '…', 32) AS snippet
                FROM wiki_pages_fts fts
                JOIN wiki_pages p ON p.id = fts.rowid
                WHERE fts MATCH ?
                  AND p.vault_id = ?
                ORDER BY rank
                LIMIT ? OFFSET ?
                """, arguments: [query, vaultID, limit, offset])
            return rows.map { row in
                WikiPageSearchResult(
                    pageID: row["id"],
                    vaultID: row["vault_id"],
                    path: row["path"],
                    title: row["title"],
                    snippet: row["snippet"] ?? "",
                    lastModified: row["last_modified"]
                )
            }
        }
    }

    func count(vaultID: String) async throws -> Int {
        try await GRDBAsync.read(from: dbQueue) { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM wiki_pages WHERE vault_id = ?
                """, arguments: [vaultID]) ?? 0
        }
    }

    // MARK: - Write (index cache only)

    func upsertPage(_ page: WikiPage) async throws {
        try await GRDBAsync.write(to: dbQueue) { db in
            // Remove old FTS entry if the page already exists
            if let existingRow = try Row.fetchOne(db, sql: """
                SELECT id, title, body FROM wiki_pages
                WHERE vault_id = ? AND path = ?
                """, arguments: [page.vaultID, page.path]) {
                let oldID: Int = existingRow["id"]
                let oldTitle: String? = existingRow["title"]
                let oldBody: String = existingRow["body"]
                try db.execute(sql: """
                    INSERT INTO wiki_pages_fts(wiki_pages_fts, rowid, title, body)
                    VALUES('delete', ?, ?, ?)
                    """, arguments: [oldID, oldTitle, oldBody])
            }

            try db.execute(sql: """
                INSERT INTO wiki_pages (vault_id, path, title, frontmatter_json, body, last_modified)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(vault_id, path) DO UPDATE SET
                    title = excluded.title,
                    frontmatter_json = excluded.frontmatter_json,
                    body = excluded.body,
                    last_modified = excluded.last_modified
                """, arguments: [
                    page.vaultID, page.path, page.title,
                    page.frontmatterJSON, page.body, page.lastModified
                ])

            let rowid = try Int.fetchOne(db, sql: """
                SELECT id FROM wiki_pages WHERE vault_id = ? AND path = ?
                """, arguments: [page.vaultID, page.path])!
            try db.execute(sql: """
                INSERT INTO wiki_pages_fts(rowid, title, body) VALUES(?, ?, ?)
                """, arguments: [rowid, page.title, page.body])
        }
    }

    func deletePage(vaultID: String, path: String) async throws {
        try await GRDBAsync.write(to: dbQueue) { db in
            if let row = try Row.fetchOne(db, sql: """
                SELECT id, title, body FROM wiki_pages
                WHERE vault_id = ? AND path = ?
                """, arguments: [vaultID, path]) {
                let rowid: Int = row["id"]
                let title: String? = row["title"]
                let body: String = row["body"]
                try db.execute(sql: """
                    INSERT INTO wiki_pages_fts(wiki_pages_fts, rowid, title, body)
                    VALUES('delete', ?, ?, ?)
                    """, arguments: [rowid, title, body])
            }
            try db.execute(sql: """
                DELETE FROM wiki_pages WHERE vault_id = ? AND path = ?
                """, arguments: [vaultID, path])
        }
    }

    func deleteAllPages(vaultID: String) async throws {
        try await GRDBAsync.write(to: dbQueue) { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, title, body FROM wiki_pages WHERE vault_id = ?
                """, arguments: [vaultID])
            for row in rows {
                let rowid: Int = row["id"]
                let title: String? = row["title"]
                let body: String = row["body"]
                try db.execute(sql: """
                    INSERT INTO wiki_pages_fts(wiki_pages_fts, rowid, title, body)
                    VALUES('delete', ?, ?, ?)
                    """, arguments: [rowid, title, body])
            }
            try db.execute(sql: """
                DELETE FROM wiki_pages WHERE vault_id = ?
                """, arguments: [vaultID])
        }
    }

    private static func makePage(_ row: Row) -> WikiPage {
        WikiPage(
            id: row["id"],
            vaultID: row["vault_id"],
            path: row["path"],
            title: row["title"],
            frontmatterJSON: row["frontmatter_json"],
            body: row["body"],
            lastModified: row["last_modified"]
        )
    }
}
