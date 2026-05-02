import XCTest
import GRDB
@testable import MadiniArchive

final class WikiPageRepositoryTests: XCTestCase {
    private var tempRoot: URL!
    private var dbQueue: DatabaseQueue!
    private var repo: GRDBWikiPageRepository!

    private let vaultID = "test-vault-001"

    override func setUpWithError() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("WikiPageTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        tempRoot = base

        let dbURL = base.appendingPathComponent("wiki_index.db")
        dbQueue = try DatabaseQueue(path: dbURL.path)
        try dbQueue.write { db in
            try GRDBWikiPageRepository.installSchema(in: db)
        }
        repo = GRDBWikiPageRepository(dbQueue: dbQueue)
    }

    override func tearDownWithError() throws {
        repo = nil
        dbQueue = nil
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        tempRoot = nil
    }

    // MARK: - Helpers

    private func makePage(path: String, title: String? = nil, body: String = "test body") -> WikiPage {
        WikiPage(
            id: 0,
            vaultID: vaultID,
            path: path,
            title: title,
            frontmatterJSON: nil,
            body: body,
            lastModified: "2026-05-02 10:00:00"
        )
    }

    // MARK: - Schema

    func testInstallSchemaCreatesTablesAndIndex() throws {
        try dbQueue.read { db in
            let tables = try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master
                WHERE type = 'table' AND name IN ('wiki_pages', 'wiki_pages_fts')
                ORDER BY name
                """)
            XCTAssertEqual(tables, ["wiki_pages", "wiki_pages_fts"])
        }
    }

    // MARK: - Upsert & Fetch

    func testUpsertAndFetchPage() async throws {
        let page = makePage(path: "notes/hello.md", title: "Hello", body: "Hello world")
        try await repo.upsertPage(page)

        let fetched = try await repo.fetchPageByPath(vaultID: vaultID, path: "notes/hello.md")
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.title, "Hello")
        XCTAssertEqual(fetched?.body, "Hello world")
        XCTAssertEqual(fetched?.vaultID, vaultID)
    }

    func testUpsertPageUpdatesOnConflict() async throws {
        let original = makePage(path: "doc.md", title: "V1", body: "Original body")
        try await repo.upsertPage(original)

        let updated = makePage(path: "doc.md", title: "V2", body: "Updated body")
        try await repo.upsertPage(updated)

        let count = try await repo.count(vaultID: vaultID)
        XCTAssertEqual(count, 1)

        let fetched = try await repo.fetchPageByPath(vaultID: vaultID, path: "doc.md")
        XCTAssertEqual(fetched?.title, "V2")
        XCTAssertEqual(fetched?.body, "Updated body")
    }

    func testFetchPageByID() async throws {
        try await repo.upsertPage(makePage(path: "a.md", title: "Page A"))
        let page = try await repo.fetchPageByPath(vaultID: vaultID, path: "a.md")
        XCTAssertNotNil(page)

        let byID = try await repo.fetchPage(id: page!.id)
        XCTAssertEqual(byID?.path, "a.md")
    }

    // MARK: - List & Pagination

    func testListPagesPagination() async throws {
        for i in 0..<10 {
            try await repo.upsertPage(makePage(
                path: "page-\(String(format: "%02d", i)).md",
                title: "Page \(i)"
            ))
        }

        let first = try await repo.listPages(vaultID: vaultID, offset: 0, limit: 3)
        XCTAssertEqual(first.count, 3)

        let second = try await repo.listPages(vaultID: vaultID, offset: 3, limit: 3)
        XCTAssertEqual(second.count, 3)

        let all = try await repo.listPages(vaultID: vaultID, offset: 0, limit: 100)
        XCTAssertEqual(all.count, 10)
    }

    func testCount() async throws {
        XCTAssertEqual(try await repo.count(vaultID: vaultID), 0)

        try await repo.upsertPage(makePage(path: "a.md"))
        try await repo.upsertPage(makePage(path: "b.md"))
        XCTAssertEqual(try await repo.count(vaultID: vaultID), 2)
    }

    // MARK: - Search (FTS5)

    func testSearchPagesFTS() async throws {
        try await repo.upsertPage(makePage(path: "cat.md", title: "Cats", body: "Cats are wonderful animals"))
        try await repo.upsertPage(makePage(path: "dog.md", title: "Dogs", body: "Dogs are loyal companions"))
        try await repo.upsertPage(makePage(path: "bird.md", title: "Birds", body: "Birds can fly high"))

        let results = try await repo.searchPages(vaultID: vaultID, query: "loyal", offset: 0, limit: 10)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.path, "dog.md")
    }

    func testSearchPagesNoResults() async throws {
        try await repo.upsertPage(makePage(path: "note.md", body: "Some content"))

        let results = try await repo.searchPages(vaultID: vaultID, query: "nonexistent", offset: 0, limit: 10)
        XCTAssertEqual(results.count, 0)
    }

    // MARK: - Delete

    func testDeletePage() async throws {
        try await repo.upsertPage(makePage(path: "delete-me.md", body: "Temporary"))
        XCTAssertEqual(try await repo.count(vaultID: vaultID), 1)

        try await repo.deletePage(vaultID: vaultID, path: "delete-me.md")
        XCTAssertEqual(try await repo.count(vaultID: vaultID), 0)

        let fetched = try await repo.fetchPageByPath(vaultID: vaultID, path: "delete-me.md")
        XCTAssertNil(fetched)
    }

    func testDeleteAllPages() async throws {
        try await repo.upsertPage(makePage(path: "a.md"))
        try await repo.upsertPage(makePage(path: "b.md"))
        try await repo.upsertPage(makePage(path: "c.md"))
        XCTAssertEqual(try await repo.count(vaultID: vaultID), 3)

        try await repo.deleteAllPages(vaultID: vaultID)
        XCTAssertEqual(try await repo.count(vaultID: vaultID), 0)
    }

    func testFTSSyncOnDelete() async throws {
        try await repo.upsertPage(makePage(path: "ephemeral.md", body: "unique keyword xyzzy"))
        let before = try await repo.searchPages(vaultID: vaultID, query: "xyzzy", offset: 0, limit: 10)
        XCTAssertEqual(before.count, 1)

        try await repo.deletePage(vaultID: vaultID, path: "ephemeral.md")
        let after = try await repo.searchPages(vaultID: vaultID, query: "xyzzy", offset: 0, limit: 10)
        XCTAssertEqual(after.count, 0)
    }

    func testFTSSyncOnUpdate() async throws {
        try await repo.upsertPage(makePage(path: "evolving.md", body: "alpha content"))
        let before = try await repo.searchPages(vaultID: vaultID, query: "alpha", offset: 0, limit: 10)
        XCTAssertEqual(before.count, 1)

        try await repo.upsertPage(makePage(path: "evolving.md", body: "beta content"))
        let alphaAfter = try await repo.searchPages(vaultID: vaultID, query: "alpha", offset: 0, limit: 10)
        XCTAssertEqual(alphaAfter.count, 0)

        let betaAfter = try await repo.searchPages(vaultID: vaultID, query: "beta", offset: 0, limit: 10)
        XCTAssertEqual(betaAfter.count, 1)
    }
}
