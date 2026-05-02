import XCTest
import GRDB
@testable import MadiniArchive

@MainActor
final class WikiIndexCoordinatorTests: XCTestCase {
    private var tempRoot: URL!
    private var indexesDir: URL!
    private var coordinator: WikiIndexCoordinator!

    override func setUp() async throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("WikiCoordinatorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        tempRoot = base
        indexesDir = base.appendingPathComponent("wiki_indexes", isDirectory: true)
        coordinator = WikiIndexCoordinator(indexesDir: indexesDir)
    }

    override func tearDown() async throws {
        coordinator = nil
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        tempRoot = nil
    }

    private func makeVault(id: String, name: String = "V") -> WikiVault {
        WikiVault(
            id: id, name: name, path: "/tmp/dummy-\(id)",
            bookmarkData: nil,
            createdAt: "2026-05-02 12:00:00",
            lastIndexedAt: nil
        )
    }

    func testPageRepositoryCreatesIndexDB() throws {
        let vault = makeVault(id: "vault-1")
        XCTAssertFalse(FileManager.default.fileExists(atPath: indexesDir.path))

        _ = try coordinator.pageRepository(for: vault)

        XCTAssertTrue(FileManager.default.fileExists(atPath: indexesDir.path))
        let dbURL = coordinator.indexDatabaseURL(for: vault)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dbURL.path))
    }

    func testPageRepositoryReturnsSameInstanceForSameVault() throws {
        let vault = makeVault(id: "vault-1")
        let r1 = try coordinator.pageRepository(for: vault)
        let r2 = try coordinator.pageRepository(for: vault)
        XCTAssertTrue(r1 === r2)
    }

    func testDifferentVaultsGetDifferentDatabases() throws {
        let v1 = makeVault(id: "vault-1")
        let v2 = makeVault(id: "vault-2")
        _ = try coordinator.pageRepository(for: v1)
        _ = try coordinator.pageRepository(for: v2)

        let url1 = coordinator.indexDatabaseURL(for: v1)
        let url2 = coordinator.indexDatabaseURL(for: v2)
        XCTAssertNotEqual(url1, url2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url1.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url2.path))
    }

    func testIndexerSharesRepository() throws {
        let vault = makeVault(id: "vault-1")
        let repo = try coordinator.pageRepository(for: vault)
        let indexer = try coordinator.indexer(for: vault)

        // Indexer's repository should be the same shared instance.
        XCTAssertTrue(indexer.pageRepository as AnyObject === repo as AnyObject)
    }

    func testForgetVaultDropsCachedRepository() throws {
        let vault = makeVault(id: "vault-1")
        let r1 = try coordinator.pageRepository(for: vault)
        coordinator.forgetVault(id: vault.id)
        let r2 = try coordinator.pageRepository(for: vault)
        XCTAssertFalse(r1 === r2)
    }

    func testIndexDBSchemaIsBootstrapped() async throws {
        let vault = makeVault(id: "vault-1")
        let repo = try coordinator.pageRepository(for: vault)

        // Inserting a page proves the wiki_pages + wiki_pages_fts tables
        // were created by the coordinator's bootstrap step.
        let page = WikiPage(
            id: 0, vaultID: vault.id, path: "p.md",
            title: "P", frontmatterJSON: nil,
            body: "test", lastModified: "2026-05-02 12:00:00"
        )
        try await repo.upsertPage(page)
        let count = try await repo.count(vaultID: vault.id)
        XCTAssertEqual(count, 1)
    }
}
