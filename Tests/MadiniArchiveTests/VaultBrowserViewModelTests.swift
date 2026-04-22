import XCTest
@testable import MadiniArchive

/// Unit coverage for the Phase D1 Vault Browser view model.
///
/// The VM is a thin async adapter over `RawExportVault`, so these tests focus
/// on the behaviours callers depend on:
/// - pagination bookkeeping (offset advances, `hasMore` flips to false when
///   the vault returns a short page)
/// - overlapping-call guards (no double fetch when a load is in flight)
/// - mid-flight selection changes don't write stale `files` into the VM
/// - typed `RawExportVaultError` values become friendly messages
///
/// The fake vault lets us drive every edge case deterministically; nothing
/// here touches SQLite or the filesystem.
@MainActor
final class VaultBrowserViewModelTests: XCTestCase {
    // MARK: - Snapshot pagination

    func testLoadMoreSnapshotsAppendsAndTracksHasMore() async throws {
        let fake = FakeVault()
        fake.snapshotPages = [
            Array(repeating: (), count: VaultBrowserViewModel.pageSize).enumerated().map { idx, _ in
                Self.makeSnapshot(id: Int64(idx + 1))
            },
            [Self.makeSnapshot(id: 9_999)] // short page → hasMore flips false
        ]
        let vm = VaultBrowserViewModel(vault: fake)

        await vm.loadMoreSnapshots()
        XCTAssertEqual(vm.snapshots.count, VaultBrowserViewModel.pageSize)
        XCTAssertEqual(vm.snapshotsState, .loaded)
        XCTAssertTrue(vm.hasMoreSnapshots, "full page means there may be more")

        await vm.loadMoreSnapshots()
        XCTAssertEqual(vm.snapshots.count, VaultBrowserViewModel.pageSize + 1)
        XCTAssertFalse(vm.hasMoreSnapshots, "short page means we've hit the end")
    }

    func testLoadMoreSnapshotsIsIdempotentWhileInFlight() async throws {
        let fake = FakeVault()
        fake.snapshotFetchDelay = .milliseconds(30)
        fake.snapshotPages = [[Self.makeSnapshot(id: 1), Self.makeSnapshot(id: 2)]]
        let vm = VaultBrowserViewModel(vault: fake)

        async let a: Void = vm.loadMoreSnapshots()
        async let b: Void = vm.loadMoreSnapshots()
        _ = await (a, b)

        XCTAssertEqual(fake.listSnapshotsCallCount, 1, "overlapping calls should coalesce")
        XCTAssertEqual(vm.snapshots.count, 2)
    }

    func testSnapshotsFailureProducesTypedMessage() async throws {
        let fake = FakeVault()
        fake.snapshotError = RawExportVaultError.snapshotNotFound(snapshotID: 42)
        let vm = VaultBrowserViewModel(vault: fake)

        await vm.loadMoreSnapshots()

        guard case .failed(let message) = vm.snapshotsState else {
            return XCTFail("expected .failed, got \(vm.snapshotsState)")
        }
        XCTAssertTrue(
            message.contains("42"),
            "error message should surface the snapshot ID, got \(message)"
        )
    }

    // MARK: - File pagination

    func testSelectingSnapshotResetsFileStateAndLoads() async throws {
        let fake = FakeVault()
        fake.filePages[1] = [[Self.makeFile(snapshotID: 1, relativePath: "a.json")]]
        fake.filePages[2] = [[Self.makeFile(snapshotID: 2, relativePath: "b.json")]]
        let vm = VaultBrowserViewModel(vault: fake)

        vm.selectedSnapshotID = 1
        await vm.loadMoreFiles()
        XCTAssertEqual(vm.files.map(\.relativePath), ["a.json"])

        vm.selectedSnapshotID = 2
        // Switching snapshot must clear the previous page list immediately —
        // otherwise the view would briefly show stale rows under the new
        // header.
        XCTAssertTrue(vm.files.isEmpty, "files should reset on selection change")
        await vm.loadMoreFiles()
        XCTAssertEqual(vm.files.map(\.relativePath), ["b.json"])
    }

    func testLoadMoreFilesIgnoresStaleResultAfterSelectionChanged() async throws {
        let fake = FakeVault()
        fake.fileFetchDelay = .milliseconds(60)
        fake.filePages[1] = [[Self.makeFile(snapshotID: 1, relativePath: "slow-from-1.json")]]
        fake.filePages[2] = [[Self.makeFile(snapshotID: 2, relativePath: "fast-from-2.json")]]
        let vm = VaultBrowserViewModel(vault: fake)

        vm.selectedSnapshotID = 1
        async let firstFetch: Void = vm.loadMoreFiles()
        // Flip selection while the first fetch is still in flight.
        try await Task.sleep(nanoseconds: 10_000_000)
        vm.selectedSnapshotID = 2
        _ = await firstFetch

        XCTAssertFalse(
            vm.files.contains(where: { $0.relativePath == "slow-from-1.json" }),
            "stale result from the old selection must not land in the VM"
        )
    }

    func testLoadMoreFilesIsNoOpWithoutSelection() async throws {
        let fake = FakeVault()
        let vm = VaultBrowserViewModel(vault: fake)

        await vm.loadMoreFiles()

        XCTAssertEqual(fake.listFilesCallCount, 0)
        XCTAssertEqual(vm.filesState, .idle)
    }

    // MARK: - Fixtures

    private static func makeSnapshot(id: Int64) -> RawExportSnapshotSummary {
        RawExportSnapshotSummary(
            id: id,
            provider: .chatGPT,
            sourceRoot: "/tmp/export-\(id)",
            importedAt: "2026-04-22 00:00:00",
            manifestHash: String(repeating: "0", count: 64),
            fileCount: 1,
            newBlobCount: 1,
            reusedBlobCount: 0,
            originalBytes: 1_024,
            storedBytes: 1_024,
            manifestPath: "/tmp/manifest-\(id).json"
        )
    }

    private static func makeFile(snapshotID: Int64, relativePath: String) -> RawExportFileEntry {
        RawExportFileEntry(
            snapshotID: snapshotID,
            relativePath: relativePath,
            blobHash: String(repeating: "a", count: 64),
            sizeBytes: 128,
            storedSizeBytes: 128,
            mimeType: "application/json",
            role: "conversation",
            compression: "none",
            storedPath: "/tmp/blobs/aa/aaaa.blob"
        )
    }
}

// MARK: - FakeVault

/// Hand-rolled stub with just enough behaviour to drive the VM tests.
/// Actor-free because the VM is `@MainActor`; all calls land on the main
/// actor's async runtime and the fake just awaits an optional delay.
private final class FakeVault: RawExportVault, @unchecked Sendable {
    var snapshotPages: [[RawExportSnapshotSummary]] = []
    var snapshotError: Error?
    var snapshotFetchDelay: Duration = .zero
    var listSnapshotsCallCount = 0

    var filePages: [Int64: [[RawExportFileEntry]]] = [:]
    var fileError: Error?
    var fileFetchDelay: Duration = .zero
    var listFilesCallCount = 0

    func ingest(_ urls: [URL]) async throws -> RawExportVaultResult? { nil }

    func listSnapshots(offset: Int, limit: Int) async throws -> [RawExportSnapshotSummary] {
        listSnapshotsCallCount += 1
        if snapshotFetchDelay != .zero {
            try await Task.sleep(for: snapshotFetchDelay)
        }
        if let snapshotError { throw snapshotError }
        guard !snapshotPages.isEmpty else { return [] }
        return snapshotPages.removeFirst()
    }

    func search(
        query: String,
        provider: RawExportProvider?,
        offset: Int,
        limit: Int
    ) async throws -> [RawExportSearchResult] {
        []
    }

    func getSnapshot(id: Int64) async throws -> RawExportSnapshotSummary? {
        nil
    }

    func listFiles(
        snapshotID: Int64,
        offset: Int,
        limit: Int
    ) async throws -> [RawExportFileEntry] {
        listFilesCallCount += 1
        if fileFetchDelay != .zero {
            try await Task.sleep(for: fileFetchDelay)
        }
        if let fileError { throw fileError }
        guard var pages = filePages[snapshotID], !pages.isEmpty else { return [] }
        let page = pages.removeFirst()
        filePages[snapshotID] = pages
        return page
    }

    func loadBlob(hash: String) async throws -> Data {
        throw RawExportVaultError.blobNotFound(hash: hash)
    }

    func loadFile(
        snapshotID: Int64,
        relativePath: String
    ) async throws -> RawExportFilePayload {
        throw RawExportVaultError.fileNotFound(snapshotID: snapshotID, relativePath: relativePath)
    }
}
