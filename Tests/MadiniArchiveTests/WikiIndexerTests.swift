import XCTest
import GRDB
@testable import MadiniArchive

@MainActor
final class WikiIndexerTests: XCTestCase {
    private var tempRoot: URL!
    private var vaultDir: URL!
    private var indexDB: URL!
    private var dbQueue: DatabaseQueue!
    private var repo: GRDBWikiPageRepository!
    private var indexer: WikiIndexer!
    private var vault: WikiVault!

    override func setUp() async throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("WikiIndexerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        tempRoot = base
        vaultDir = base.appendingPathComponent("vault", isDirectory: true)
        try FileManager.default.createDirectory(at: vaultDir, withIntermediateDirectories: true)

        indexDB = base.appendingPathComponent("index.db")
        dbQueue = try DatabaseQueue(path: indexDB.path)
        try await GRDBAsync.write(to: dbQueue) { db in
            try GRDBWikiPageRepository.installSchema(in: db)
        }
        repo = GRDBWikiPageRepository(dbQueue: dbQueue)
        indexer = WikiIndexer(pageRepository: repo)
        vault = WikiVault(
            id: "test-vault",
            name: "Test Vault",
            path: vaultDir.path,
            bookmarkData: nil,
            createdAt: "2026-05-02 12:00:00",
            lastIndexedAt: nil
        )
    }

    override func tearDown() async throws {
        repo = nil
        indexer = nil
        dbQueue = nil
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        tempRoot = nil
    }

    // MARK: - Fixtures

    private func writeVaultFile(_ relativePath: String, contents: String) throws {
        let url = vaultDir.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Snapshot the contents of the vault directory by relative path +
    /// content hash. Used to assert non-destructive behavior — running the
    /// indexer must not change the vault.
    private func vaultSnapshot() throws -> [String: String] {
        var snapshot: [String: String] = [:]
        let enumerator = FileManager.default.enumerator(
            at: vaultDir,
            includingPropertiesForKeys: [.isRegularFileKey]
        )!
        for case let url as URL in enumerator {
            let isFile = (try? url.resourceValues(forKeys: [.isRegularFileKey]))?
                .isRegularFile == true
            guard isFile else { continue }
            let relative = String(url.path.dropFirst(vaultDir.path.count + 1))
            snapshot[relative] = try String(contentsOf: url, encoding: .utf8)
        }
        return snapshot
    }

    // MARK: - Tests

    func testIndexEmptyVault() async throws {
        let stats = try await indexer.indexVault(vault)
        XCTAssertEqual(stats.upserted, 0)
        XCTAssertEqual(stats.removed, 0)
        XCTAssertEqual(stats.failed, 0)
    }

    func testIndexSingleFile() async throws {
        try writeVaultFile("hello.md", contents: "# Hello\n\nbody")
        let stats = try await indexer.indexVault(vault)
        XCTAssertEqual(stats.upserted, 1)

        let count = try await repo.count(vaultID: vault.id)
        XCTAssertEqual(count, 1)

        let page = try await repo.fetchPageByPath(vaultID: vault.id, path: "hello.md")
        XCTAssertNotNil(page)
        XCTAssertEqual(page?.title, "Hello")
        XCTAssertTrue(page?.body.contains("body") == true)
    }

    func testIndexMultipleFilesInSubdirs() async throws {
        try writeVaultFile("notes/a.md", contents: "# A")
        try writeVaultFile("notes/b.md", contents: "# B")
        try writeVaultFile("characters/chr_0001.md", contents: """
            ---
            type: chr
            name: 錫花
            ---
            See [[chr_0002]].
            """)

        let stats = try await indexer.indexVault(vault)
        XCTAssertEqual(stats.upserted, 3)

        let count = try await repo.count(vaultID: vault.id)
        XCTAssertEqual(count, 3)

        let chr = try await repo.fetchPageByPath(
            vaultID: vault.id, path: "characters/chr_0001.md"
        )
        XCTAssertNotNil(chr?.frontmatterJSON)
        XCTAssertTrue(chr?.frontmatterJSON?.contains("錫花") == true)
    }

    func testIndexUpdatesExistingPage() async throws {
        try writeVaultFile("doc.md", contents: "# Old Title\n\nold body")
        _ = try await indexer.indexVault(vault)

        // Modify the file and re-index
        try writeVaultFile("doc.md", contents: "# New Title\n\nnew body")
        let stats = try await indexer.indexVault(vault)
        XCTAssertEqual(stats.upserted, 1)
        XCTAssertEqual(stats.removed, 0)

        let count = try await repo.count(vaultID: vault.id)
        XCTAssertEqual(count, 1)

        let page = try await repo.fetchPageByPath(vaultID: vault.id, path: "doc.md")
        XCTAssertEqual(page?.title, "New Title")
        XCTAssertTrue(page?.body.contains("new body") == true)
    }

    func testIndexRemovesDeletedFiles() async throws {
        try writeVaultFile("a.md", contents: "# A")
        try writeVaultFile("b.md", contents: "# B")
        _ = try await indexer.indexVault(vault)

        let beforeCount = try await repo.count(vaultID: vault.id)
        XCTAssertEqual(beforeCount, 2)

        // Remove b.md from disk and re-index
        try FileManager.default.removeItem(
            at: vaultDir.appendingPathComponent("b.md")
        )
        let stats = try await indexer.indexVault(vault)
        XCTAssertEqual(stats.removed, 1)

        let afterCount = try await repo.count(vaultID: vault.id)
        XCTAssertEqual(afterCount, 1)

        let bPage = try await repo.fetchPageByPath(vaultID: vault.id, path: "b.md")
        XCTAssertNil(bPage)
    }

    func testIndexSkipsHiddenDirs() async throws {
        try writeVaultFile(".obsidian/workspace.md", contents: "# config")
        try writeVaultFile("real.md", contents: "# Real")
        let stats = try await indexer.indexVault(vault)
        XCTAssertEqual(stats.upserted, 1)

        let count = try await repo.count(vaultID: vault.id)
        XCTAssertEqual(count, 1)
    }

    func testIndexIgnoresNonMarkdownFiles() async throws {
        try writeVaultFile("note.md", contents: "# Note")
        try writeVaultFile("image.png", contents: "fake png")
        try writeVaultFile("data.json", contents: "{}")
        let stats = try await indexer.indexVault(vault)
        XCTAssertEqual(stats.upserted, 1)
    }

    // MARK: - Title resolution

    func testTitleFromFrontmatter() async throws {
        try writeVaultFile("p.md", contents: """
            ---
            title: From Frontmatter
            ---
            # H1 Title
            """)
        _ = try await indexer.indexVault(vault)
        let page = try await repo.fetchPageByPath(vaultID: vault.id, path: "p.md")
        XCTAssertEqual(page?.title, "From Frontmatter")
    }

    func testTitleFromH1WhenFrontmatterMissing() async throws {
        try writeVaultFile("p.md", contents: "# H1 Title\n\nbody")
        _ = try await indexer.indexVault(vault)
        let page = try await repo.fetchPageByPath(vaultID: vault.id, path: "p.md")
        XCTAssertEqual(page?.title, "H1 Title")
    }

    func testTitleFromFilenameWhenNoFrontmatterOrH1() async throws {
        try writeVaultFile("plain.md", contents: "just body, no heading")
        _ = try await indexer.indexVault(vault)
        let page = try await repo.fetchPageByPath(vaultID: vault.id, path: "plain.md")
        XCTAssertEqual(page?.title, "plain")
    }

    // MARK: - Single-file API

    func testIndexFileSingle() async throws {
        try writeVaultFile("a.md", contents: "# A")
        let url = vaultDir.appendingPathComponent("a.md")
        try await indexer.indexFile(at: url, relativePath: "a.md", in: vault)

        let page = try await repo.fetchPageByPath(vaultID: vault.id, path: "a.md")
        XCTAssertNotNil(page)
        XCTAssertEqual(page?.title, "A")
    }

    func testRemoveFile() async throws {
        try writeVaultFile("a.md", contents: "# A")
        _ = try await indexer.indexVault(vault)
        try await indexer.removeFile(at: "a.md", in: vault)

        let count = try await repo.count(vaultID: vault.id)
        XCTAssertEqual(count, 0)
    }

    // MARK: - Non-destructive (critical)

    func testIndexingDoesNotModifyVault() async throws {
        try writeVaultFile("a.md", contents: "# A\n\nalpha")
        try writeVaultFile("nested/b.md", contents: "# B\n\nbeta")
        try writeVaultFile("characters/chr.md", contents: """
            ---
            type: chr
            ---
            See [[a]] and ![[diagram.png]].
            """)

        let before = try vaultSnapshot()
        _ = try await indexer.indexVault(vault)
        // Run twice — re-indexing the same vault must also stay read-only
        _ = try await indexer.indexVault(vault)
        let after = try vaultSnapshot()

        XCTAssertEqual(before, after, "Indexer must not modify any vault file.")
    }

    // MARK: - Manual verification against an external vault

    /// Index any `/tmp/madini-test-vault-*` directory that the developer
    /// has prepared on disk. Skipped if none exists, so CI runs stay
    /// hermetic. Asserts that indexing leaves every file in the vault
    /// byte-for-byte unchanged (the non-destructive guarantee at the
    /// system level).
    func testManualExternalVaultIsReadOnly() async throws {
        let tmp = URL(fileURLWithPath: "/tmp", isDirectory: true)
        let candidates = (try? FileManager.default.contentsOfDirectory(
            at: tmp,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let testVaults = candidates.filter {
            $0.lastPathComponent.hasPrefix("madini-test-vault-")
        }
        guard let externalVault = testVaults.first else {
            throw XCTSkip("Create /tmp/madini-test-vault-XXX with markdown files to run this manual check.")
        }
        let extVault = WikiVault(
            id: "manual-test-\(UUID().uuidString)",
            name: "Manual Test",
            path: externalVault.path,
            bookmarkData: nil,
            createdAt: TimestampFormatter.now(),
            lastIndexedAt: nil
        )

        let before = try Self.snapshot(of: externalVault)
        let stats = try await indexer.indexVault(extVault)
        let after = try Self.snapshot(of: externalVault)

        XCTAssertEqual(before, after, "Indexer modified the external vault.")
        print("[manual] indexed \(stats.upserted) page(s) from \(externalVault.path)")
    }

    private static func snapshot(of dir: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        let enumerator = FileManager.default.enumerator(
            at: dir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )!
        for case let url as URL in enumerator {
            let isFile = (try? url.resourceValues(forKeys: [.isRegularFileKey]))?
                .isRegularFile == true
            guard isFile else { continue }
            let relative = String(url.path.dropFirst(dir.path.count + 1))
            result[relative] = try String(contentsOf: url, encoding: .utf8)
        }
        return result
    }

    // MARK: - Search after indexing

    func testFTSSearchAfterIndexing() async throws {
        try writeVaultFile("cat.md", contents: "# Cats\n\nFelines are wonderful")
        try writeVaultFile("dog.md", contents: "# Dogs\n\nCanines are loyal")
        _ = try await indexer.indexVault(vault)

        let results = try await repo.searchPages(
            vaultID: vault.id, query: "loyal", offset: 0, limit: 10
        )
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.path, "dog.md")
    }
}
