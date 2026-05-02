import Foundation
import GRDB

final class GRDBWikiVaultRepository: WikiVaultRepository, @unchecked Sendable {
    private let dbQueue: DatabaseQueue

    init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    func listVaults(offset: Int, limit: Int) async throws -> [WikiVault] {
        try await GRDBAsync.read(from: dbQueue) { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, name, path, bookmark_data, created_at, last_indexed_at
                FROM wiki_vaults
                ORDER BY name COLLATE NOCASE
                LIMIT ? OFFSET ?
                """, arguments: [limit, offset])
            return rows.map(Self.makeVault)
        }
    }

    func vault(id: String) async throws -> WikiVault? {
        try await GRDBAsync.read(from: dbQueue) { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT id, name, path, bookmark_data, created_at, last_indexed_at
                FROM wiki_vaults
                WHERE id = ?
                """, arguments: [id])
            return row.map(Self.makeVault)
        }
    }

    func registerVault(name: String, path: String, bookmarkData: Data?) async throws -> WikiVault {
        let id = UUID().uuidString
        let now = TimestampFormatter.now()
        try await GRDBAsync.write(to: dbQueue) { db in
            try db.execute(sql: """
                INSERT INTO wiki_vaults (id, name, path, bookmark_data, created_at)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(path) DO UPDATE SET
                    name = excluded.name,
                    bookmark_data = excluded.bookmark_data
                """, arguments: [id, name, path, bookmarkData, now])
        }
        return WikiVault(
            id: id,
            name: name,
            path: path,
            bookmarkData: bookmarkData,
            createdAt: now,
            lastIndexedAt: nil
        )
    }

    func updateBookmarkData(vaultID: String, bookmarkData: Data?) async throws {
        try await GRDBAsync.write(to: dbQueue) { db in
            try db.execute(sql: """
                UPDATE wiki_vaults SET bookmark_data = ? WHERE id = ?
                """, arguments: [bookmarkData, vaultID])
        }
    }

    func updateLastIndexedAt(vaultID: String, timestamp: String) async throws {
        try await GRDBAsync.write(to: dbQueue) { db in
            try db.execute(sql: """
                UPDATE wiki_vaults SET last_indexed_at = ? WHERE id = ?
                """, arguments: [timestamp, vaultID])
        }
    }

    func unregisterVault(id: String) async throws {
        try await GRDBAsync.write(to: dbQueue) { db in
            try db.execute(sql: "DELETE FROM wiki_vaults WHERE id = ?", arguments: [id])
        }
    }

    private static func makeVault(_ row: Row) -> WikiVault {
        WikiVault(
            id: row["id"],
            name: row["name"],
            path: row["path"],
            bookmarkData: row["bookmark_data"],
            createdAt: row["created_at"],
            lastIndexedAt: row["last_indexed_at"]
        )
    }
}
