import XCTest
@testable import MadiniArchive

@MainActor
final class WikiVaultAccessorTests: XCTestCase {
    private var tempRoot: URL!
    private var vaultDir: URL!
    private var repository: MockWikiVaultRepository!
    private var accessor: WikiVaultAccessor!

    override func setUp() async throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("WikiAccessorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        tempRoot = base
        vaultDir = base.appendingPathComponent("vault", isDirectory: true)
        try FileManager.default.createDirectory(at: vaultDir, withIntermediateDirectories: true)

        repository = MockWikiVaultRepository()
        accessor = WikiVaultAccessor(vaultRepository: repository)
    }

    override func tearDown() async throws {
        accessor.closeAll()
        accessor = nil
        repository = nil
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        tempRoot = nil
    }

    // MARK: - Fallback path

    func testOpenVaultFallsBackToRawPath() async {
        let vault = WikiVault(
            id: "v1", name: "V", path: vaultDir.path,
            bookmarkData: nil,
            createdAt: "2026-05-02 12:00:00",
            lastIndexedAt: nil
        )
        let url = await accessor.openVault(vault)
        XCTAssertNotNil(url)
        XCTAssertEqual(url?.standardizedFileURL.path, vaultDir.standardizedFileURL.path)
    }

    func testOpenVaultReturnsNilForMissingPath() async {
        let vault = WikiVault(
            id: "missing", name: "V", path: "/tmp/does-not-exist-\(UUID())",
            bookmarkData: nil,
            createdAt: "2026-05-02 12:00:00",
            lastIndexedAt: nil
        )
        let url = await accessor.openVault(vault)
        XCTAssertNil(url)
    }

    // MARK: - Caching

    func testRepeatedOpenReturnsSameURL() async {
        let vault = WikiVault(
            id: "v1", name: "V", path: vaultDir.path,
            bookmarkData: nil,
            createdAt: "2026-05-02 12:00:00",
            lastIndexedAt: nil
        )
        let url1 = await accessor.openVault(vault)
        let url2 = await accessor.openVault(vault)
        XCTAssertEqual(url1, url2)
    }

    // MARK: - Bookmark resolution

    func testBookmarkResolvesToOriginalURL() async throws {
        // Capture a real bookmark from the temp vault dir, persist it,
        // then verify that the accessor resolves it back to the same URL.
        let bookmarkData = try vaultDir.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        let vault = WikiVault(
            id: "v1", name: "V", path: vaultDir.path,
            bookmarkData: bookmarkData,
            createdAt: "2026-05-02 12:00:00",
            lastIndexedAt: nil
        )
        let url = await accessor.openVault(vault)
        XCTAssertNotNil(url)
        XCTAssertEqual(url?.standardizedFileURL.path, vaultDir.standardizedFileURL.path)
    }

    func testBookmarkResolveFallsBackWhenDataInvalid() async {
        // Garbage in bookmark_data → resolve fails → fall back to path.
        let vault = WikiVault(
            id: "v1", name: "V", path: vaultDir.path,
            bookmarkData: Data([0x00, 0x01, 0x02, 0x03]),
            createdAt: "2026-05-02 12:00:00",
            lastIndexedAt: nil
        )
        let url = await accessor.openVault(vault)
        XCTAssertNotNil(url, "Should fall back to raw path when bookmark cannot be resolved.")
    }

    // MARK: - Lifecycle

    func testCloseVaultDropsCachedAccess() async {
        let vault = WikiVault(
            id: "v1", name: "V", path: vaultDir.path,
            bookmarkData: nil,
            createdAt: "2026-05-02 12:00:00",
            lastIndexedAt: nil
        )
        _ = await accessor.openVault(vault)
        accessor.closeVault(id: vault.id)
        // Re-opening should still work (not crash, returns same URL).
        let urlAgain = await accessor.openVault(vault)
        XCTAssertNotNil(urlAgain)
    }

    func testCloseAllReleasesEveryVault() async {
        for i in 0..<3 {
            let dir = tempRoot.appendingPathComponent("v\(i)")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let vault = WikiVault(
                id: "v\(i)", name: "V\(i)", path: dir.path,
                bookmarkData: nil,
                createdAt: "2026-05-02 12:00:00",
                lastIndexedAt: nil
            )
            _ = await accessor.openVault(vault)
        }
        accessor.closeAll()
        // No assertion needed beyond "doesn't crash" — closeAll is the
        // shutdown path; we just verify it tears down cleanly.
    }
}
