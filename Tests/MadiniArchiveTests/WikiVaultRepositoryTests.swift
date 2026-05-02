import XCTest
import GRDB
@testable import MadiniArchive

final class WikiVaultRepositoryTests: XCTestCase {
    private var tempRoot: URL!
    private var dbQueue: DatabaseQueue!
    private var repo: GRDBWikiVaultRepository!

    override func setUpWithError() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("WikiVaultTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        tempRoot = base

        let dbURL = base.appendingPathComponent("archive.db")
        dbQueue = try DatabaseQueue(path: dbURL.path)
        // Stub the conversations table that the Python importer would
        // normally create. Migration 3 creates indexes against it.
        try dbQueue.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS conversations (
                    id TEXT PRIMARY KEY,
                    source TEXT,
                    model TEXT,
                    source_file TEXT,
                    title TEXT,
                    date_str TEXT,
                    prompt_count INTEGER,
                    hash TEXT UNIQUE,
                    raw_source_id INTEGER,
                    source_created_at TEXT,
                    imported_at TEXT
                )
                """)
        }
        try AppServices.bootstrapViewLayerSchema(dbQueue: dbQueue)
        repo = GRDBWikiVaultRepository(dbQueue: dbQueue)
    }

    override func tearDownWithError() throws {
        repo = nil
        dbQueue = nil
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        tempRoot = nil
    }

    // MARK: - Tests

    func testRegisterAndFetchVault() async throws {
        let vault = try await repo.registerVault(
            name: "Test Vault", path: "/tmp/vault1", bookmarkData: nil
        )
        XCTAssertEqual(vault.name, "Test Vault")
        XCTAssertEqual(vault.path, "/tmp/vault1")
        XCTAssertNil(vault.lastIndexedAt)

        let fetched = try await repo.vault(id: vault.id)
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.name, "Test Vault")
        XCTAssertEqual(fetched?.path, "/tmp/vault1")
    }

    func testRegisterSamePathUpdatesExisting() async throws {
        let v1 = try await repo.registerVault(
            name: "Original", path: "/tmp/shared", bookmarkData: nil
        )
        let v2 = try await repo.registerVault(
            name: "Updated", path: "/tmp/shared", bookmarkData: Data([0x01])
        )

        let all = try await repo.listVaults(offset: 0, limit: 100)
        XCTAssertEqual(all.count, 1)
        // ON CONFLICT updates name and bookmark_data but keeps the original id
        XCTAssertEqual(all.first?.name, "Updated")
        _ = v1
        _ = v2
    }

    func testListVaultsPagination() async throws {
        for i in 0..<5 {
            _ = try await repo.registerVault(
                name: "Vault \(i)", path: "/tmp/vault\(i)", bookmarkData: nil
            )
        }

        let first = try await repo.listVaults(offset: 0, limit: 2)
        XCTAssertEqual(first.count, 2)

        let second = try await repo.listVaults(offset: 2, limit: 2)
        XCTAssertEqual(second.count, 2)

        let last = try await repo.listVaults(offset: 4, limit: 2)
        XCTAssertEqual(last.count, 1)

        let beyond = try await repo.listVaults(offset: 10, limit: 2)
        XCTAssertEqual(beyond.count, 0)
    }

    func testUnregisterVault() async throws {
        let vault = try await repo.registerVault(
            name: "To Delete", path: "/tmp/delete-me", bookmarkData: nil
        )
        try await repo.unregisterVault(id: vault.id)
        let fetched = try await repo.vault(id: vault.id)
        XCTAssertNil(fetched)
    }

    func testUpdateLastIndexedAt() async throws {
        let vault = try await repo.registerVault(
            name: "Indexable", path: "/tmp/indexable", bookmarkData: nil
        )
        XCTAssertNil(vault.lastIndexedAt)

        try await repo.updateLastIndexedAt(vaultID: vault.id, timestamp: "2026-05-02 12:00:00")
        let fetched = try await repo.vault(id: vault.id)
        XCTAssertEqual(fetched?.lastIndexedAt, "2026-05-02 12:00:00")
    }

    func testUpdateBookmarkData() async throws {
        let vault = try await repo.registerVault(
            name: "Bookmarked", path: "/tmp/bm", bookmarkData: nil
        )
        XCTAssertNil(vault.bookmarkData)

        let data = Data([0xDE, 0xAD, 0xBE, 0xEF])
        try await repo.updateBookmarkData(vaultID: vault.id, bookmarkData: data)
        let fetched = try await repo.vault(id: vault.id)
        XCTAssertEqual(fetched?.bookmarkData, data)
    }

    func testMigration4CreatesWikiVaultsTable() throws {
        try dbQueue.read { db in
            let exists = try Row.fetchOne(db, sql: """
                SELECT name FROM sqlite_master
                WHERE type = 'table' AND name = 'wiki_vaults'
                """)
            XCTAssertNotNil(exists)
        }

        try dbQueue.read { db in
            let version = try Int.fetchOne(db, sql: "PRAGMA user_version")
            XCTAssertEqual(version, 4)
        }
    }
}
