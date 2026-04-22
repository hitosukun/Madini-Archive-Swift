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
        let vm = Self.makeViewModel(vault: fake)

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
        let vm = Self.makeViewModel(vault: fake)

        async let a: Void = vm.loadMoreSnapshots()
        async let b: Void = vm.loadMoreSnapshots()
        _ = await (a, b)

        XCTAssertEqual(fake.listSnapshotsCallCount, 1, "overlapping calls should coalesce")
        XCTAssertEqual(vm.snapshots.count, 2)
    }

    func testSnapshotsFailureProducesTypedMessage() async throws {
        let fake = FakeVault()
        fake.snapshotError = RawExportVaultError.snapshotNotFound(snapshotID: 42)
        let vm = Self.makeViewModel(vault: fake)

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
        let vm = Self.makeViewModel(vault: fake)

        vm.selectedSnapshotID = 1
        vm.handleSnapshotSelectionChanged()
        await vm.loadMoreFiles()
        XCTAssertEqual(vm.files.map(\.relativePath), ["a.json"])

        vm.selectedSnapshotID = 2
        // In production the view drives this via `.onChange(of:)` so the
        // `@Observable` mutations land outside SwiftUI's view-update cycle.
        // Tests call the handler directly to simulate that wiring.
        vm.handleSnapshotSelectionChanged()
        XCTAssertTrue(vm.files.isEmpty, "files should reset on selection change")
        await vm.loadMoreFiles()
        XCTAssertEqual(vm.files.map(\.relativePath), ["b.json"])
    }

    func testLoadMoreFilesIgnoresStaleResultAfterSelectionChanged() async throws {
        let fake = FakeVault()
        fake.fileFetchDelay = .milliseconds(60)
        fake.filePages[1] = [[Self.makeFile(snapshotID: 1, relativePath: "slow-from-1.json")]]
        fake.filePages[2] = [[Self.makeFile(snapshotID: 2, relativePath: "fast-from-2.json")]]
        let vm = Self.makeViewModel(vault: fake)

        vm.selectedSnapshotID = 1
        vm.handleSnapshotSelectionChanged()
        async let firstFetch: Void = vm.loadMoreFiles()
        // Flip selection while the first fetch is still in flight.
        try await Task.sleep(nanoseconds: 10_000_000)
        vm.selectedSnapshotID = 2
        vm.handleSnapshotSelectionChanged()
        _ = await firstFetch

        XCTAssertFalse(
            vm.files.contains(where: { $0.relativePath == "slow-from-1.json" }),
            "stale result from the old selection must not land in the VM"
        )
    }

    func testLoadMoreFilesIsNoOpWithoutSelection() async throws {
        let fake = FakeVault()
        let vm = Self.makeViewModel(vault: fake)

        await vm.loadMoreFiles()

        XCTAssertEqual(fake.listFilesCallCount, 0)
        XCTAssertEqual(vm.filesState, .idle)
    }

    // MARK: - File content (D2)

    func testLoadSelectedFileContentStoresPayloadFromVault() async throws {
        let fake = FakeVault()
        let entry = Self.makeFile(snapshotID: 1, relativePath: "conversations-0001.json")
        fake.filePages[1] = [[entry]]
        fake.payloadsByRelativePath["conversations-0001.json"] = RawExportFilePayload(
            entry: entry,
            data: Data("{\"ok\":true}".utf8)
        )
        let vm = Self.makeViewModel(vault: fake)

        vm.selectedSnapshotID = 1
        vm.handleSnapshotSelectionChanged()
        await vm.loadMoreFiles()
        vm.selectedFileID = entry.id
        vm.handleFileSelectionChanged()
        await vm.loadSelectedFileContent()

        XCTAssertEqual(vm.fileContentState, .loaded)
        XCTAssertEqual(
            vm.selectedFilePayload?.data,
            Data("{\"ok\":true}".utf8)
        )
    }

    func testSelectingDifferentFileClearsPreviousPayloadBeforeLoad() async throws {
        let fake = FakeVault()
        let a = Self.makeFile(snapshotID: 1, relativePath: "a.json")
        let b = Self.makeFile(snapshotID: 1, relativePath: "b.json")
        fake.filePages[1] = [[a, b]]
        fake.payloadsByRelativePath["a.json"] = RawExportFilePayload(entry: a, data: Data("A".utf8))
        fake.payloadsByRelativePath["b.json"] = RawExportFilePayload(entry: b, data: Data("B".utf8))
        let vm = Self.makeViewModel(vault: fake)

        vm.selectedSnapshotID = 1
        vm.handleSnapshotSelectionChanged()
        await vm.loadMoreFiles()
        vm.selectedFileID = a.id
        vm.handleFileSelectionChanged()
        await vm.loadSelectedFileContent()
        XCTAssertEqual(vm.selectedFilePayload?.data, Data("A".utf8))

        vm.selectedFileID = b.id
        vm.handleFileSelectionChanged()
        // Switching files must clear previous bytes synchronously so the view
        // can't flash file A's content under file B's header. In production
        // the view drives this via `.onChange(of:)`; tests invoke the handler
        // directly.
        XCTAssertNil(vm.selectedFilePayload, "payload should clear on selection change")
        XCTAssertEqual(vm.fileContentState, .idle)

        await vm.loadSelectedFileContent()
        XCTAssertEqual(vm.selectedFilePayload?.data, Data("B".utf8))
    }

    func testLoadSelectedFileContentSurfacesTypedError() async throws {
        let fake = FakeVault()
        let entry = Self.makeFile(snapshotID: 7, relativePath: "missing.json")
        fake.filePages[7] = [[entry]]
        fake.loadFileError = RawExportVaultError.fileNotFound(
            snapshotID: 7,
            relativePath: "missing.json"
        )
        let vm = Self.makeViewModel(vault: fake)

        vm.selectedSnapshotID = 7
        vm.handleSnapshotSelectionChanged()
        await vm.loadMoreFiles()
        vm.selectedFileID = entry.id
        vm.handleFileSelectionChanged()
        await vm.loadSelectedFileContent()

        guard case .failed(let message) = vm.fileContentState else {
            return XCTFail("expected .failed, got \(vm.fileContentState)")
        }
        XCTAssertTrue(
            message.contains("missing.json"),
            "error message should surface the relative path, got \(message)"
        )
        XCTAssertNil(vm.selectedFilePayload)
    }

    func testChangingSnapshotInvalidatesSelectedFile() async throws {
        let fake = FakeVault()
        let entry = Self.makeFile(snapshotID: 1, relativePath: "a.json")
        fake.filePages[1] = [[entry]]
        fake.payloadsByRelativePath["a.json"] = RawExportFilePayload(entry: entry, data: Data("A".utf8))
        let vm = Self.makeViewModel(vault: fake)

        vm.selectedSnapshotID = 1
        vm.handleSnapshotSelectionChanged()
        await vm.loadMoreFiles()
        vm.selectedFileID = entry.id
        vm.handleFileSelectionChanged()
        await vm.loadSelectedFileContent()
        XCTAssertNotNil(vm.selectedFilePayload)

        vm.selectedSnapshotID = 2
        vm.handleSnapshotSelectionChanged()
        XCTAssertNil(vm.selectedFileID, "snapshot change should also clear file selection")
        XCTAssertNil(vm.selectedFilePayload)
    }

    // MARK: - Text rendering (D2)

    func testTextRepresentationPrettyPrintsJSONFiles() throws {
        let entry = Self.makeFile(snapshotID: 1, relativePath: "conversations-0001.json")
        let minified = Data(#"{"b":2,"a":1}"#.utf8)
        let payload = RawExportFilePayload(entry: entry, data: minified)

        let text = try XCTUnwrap(
            VaultFileContentView.textRepresentation(for: payload),
            "JSON payloads should render as text"
        )
        XCTAssertTrue(text.contains("\n"), "pretty-print should insert newlines")
        // sortedKeys ⇒ deterministic ordering across runs.
        if let aIndex = text.range(of: "\"a\""),
           let bIndex = text.range(of: "\"b\"") {
            XCTAssertLessThan(aIndex.lowerBound, bIndex.lowerBound, "keys should be sorted")
        } else {
            XCTFail("expected both keys in pretty-printed output")
        }
    }

    func testLooksTextualClassifiesConversationJSONEvenAtHugeSize() throws {
        // A 500 MB ChatGPT `conversations.json` is the motivating case —
        // `textRepresentation` still refuses (size cap), but the classifier
        // must return true so the view can show "too large" rather than
        // falling through to the generic binary placeholder.
        let entry = RawExportFileEntry(
            snapshotID: 1,
            relativePath: "conversations-000.json",
            blobHash: String(repeating: "a", count: 64),
            sizeBytes: 500_000_000,
            storedSizeBytes: 50_000_000,
            mimeType: "application/json",
            role: "conversation",
            compression: "lzfse",
            storedPath: "/tmp/blobs/aa/aaaa.blob"
        )

        XCTAssertTrue(VaultFileContentView.looksTextual(entry))

        let payload = RawExportFilePayload(entry: entry, data: Data())
        XCTAssertNil(
            VaultFileContentView.textRepresentation(for: payload),
            "files past the size cap must still opt out of inline rendering"
        )
    }

    func testLooksTextualRejectsImageAsset() throws {
        let entry = RawExportFileEntry(
            snapshotID: 1,
            relativePath: "assets/screenshot.png",
            blobHash: String(repeating: "b", count: 64),
            sizeBytes: 4,
            storedSizeBytes: 4,
            mimeType: "image/png",
            role: "asset",
            compression: "none",
            storedPath: "/tmp/blobs/bb/bbbb.blob"
        )
        XCTAssertFalse(VaultFileContentView.looksTextual(entry))
    }

    func testTextRepresentationReturnsNilForBinaryPayload() throws {
        let entry = RawExportFileEntry(
            snapshotID: 1,
            relativePath: "screenshot.png",
            blobHash: String(repeating: "b", count: 64),
            sizeBytes: 4,
            storedSizeBytes: 4,
            mimeType: "image/png",
            role: "asset",
            compression: "none",
            storedPath: "/tmp/blobs/bb/bbbb.blob"
        )
        let payload = RawExportFilePayload(
            entry: entry,
            data: Data([0x89, 0x50, 0x4E, 0x47]) // PNG magic
        )

        XCTAssertNil(
            VaultFileContentView.textRepresentation(for: payload),
            "binary asset should not be rendered as text"
        )
    }

    // MARK: - Reload snapshots

    func testReloadSnapshotsStartsFromOffsetZero() async throws {
        let fake = FakeVault()
        fake.snapshotPages = [
            [Self.makeSnapshot(id: 1), Self.makeSnapshot(id: 2)],
            // Simulates the vault state after a user imported a new export:
            // the reload should surface the just-ingested snapshot at the
            // top without needing to page past the pre-reload cursor.
            [Self.makeSnapshot(id: 99), Self.makeSnapshot(id: 1), Self.makeSnapshot(id: 2)]
        ]
        let vm = Self.makeViewModel(vault: fake)

        await vm.loadMoreSnapshots()
        XCTAssertEqual(vm.snapshots.map(\.id), [1, 2])

        await vm.reloadSnapshots()
        XCTAssertEqual(
            vm.snapshots.map(\.id),
            [99, 1, 2],
            "reload should replace the existing list with the fresh first page"
        )
        XCTAssertEqual(vm.snapshotsState, .loaded)
    }

    // MARK: - Referenced assets (D4)

    func testLoadMoreReferencedAssetsPopulatesChips() async throws {
        let fake = FakeVault()
        let source = Self.makeFile(snapshotID: 1, relativePath: "conversations-0001.json")
        fake.filePages[1] = [[source]]

        let resolver = FakeAssetResolver()
        let hit = Self.makeAssetHit(snapshotID: 1, sourceRelativePath: source.relativePath, asset: "assets/a.png")
        resolver.assetsByFile[Self.key(1, source.relativePath)] = [[hit]]

        let vm = Self.makeViewModel(vault: fake, resolver: resolver)
        vm.selectedSnapshotID = 1
        vm.handleSnapshotSelectionChanged()
        await vm.loadMoreFiles()
        vm.selectedFileID = source.id
        vm.handleFileSelectionChanged()

        await vm.loadMoreReferencedAssets()

        XCTAssertEqual(vm.referencedAssets.map(\.assetRelativePath), ["assets/a.png"])
        XCTAssertEqual(vm.referencedAssetsState, .loaded)
    }

    func testReferencedAssetsResetOnFileChange() async throws {
        let fake = FakeVault()
        let a = Self.makeFile(snapshotID: 1, relativePath: "a.json")
        let b = Self.makeFile(snapshotID: 1, relativePath: "b.json")
        fake.filePages[1] = [[a, b]]

        let resolver = FakeAssetResolver()
        resolver.assetsByFile[Self.key(1, "a.json")] = [[
            Self.makeAssetHit(snapshotID: 1, sourceRelativePath: "a.json", asset: "assets/one.png")
        ]]

        let vm = Self.makeViewModel(vault: fake, resolver: resolver)
        vm.selectedSnapshotID = 1
        vm.handleSnapshotSelectionChanged()
        await vm.loadMoreFiles()
        vm.selectedFileID = a.id
        vm.handleFileSelectionChanged()
        await vm.loadMoreReferencedAssets()
        XCTAssertFalse(vm.referencedAssets.isEmpty)

        vm.selectedFileID = b.id
        vm.handleFileSelectionChanged()
        // Switching files MUST clear the chips synchronously so the view never
        // flashes file A's chips under file B's header. In production the
        // view drives this via `.onChange(of:)`.
        XCTAssertTrue(vm.referencedAssets.isEmpty)
        XCTAssertEqual(vm.referencedAssetsState, .idle)
    }

    func testReferencedAssetsDiscardsStaleResultAfterFileChange() async throws {
        let fake = FakeVault()
        let a = Self.makeFile(snapshotID: 1, relativePath: "a.json")
        let b = Self.makeFile(snapshotID: 1, relativePath: "b.json")
        fake.filePages[1] = [[a, b]]

        let resolver = FakeAssetResolver()
        resolver.fetchDelay = .milliseconds(60)
        resolver.assetsByFile[Self.key(1, "a.json")] = [[
            Self.makeAssetHit(snapshotID: 1, sourceRelativePath: "a.json", asset: "assets/slow.png")
        ]]
        resolver.assetsByFile[Self.key(1, "b.json")] = [[
            Self.makeAssetHit(snapshotID: 1, sourceRelativePath: "b.json", asset: "assets/fast.png")
        ]]

        let vm = Self.makeViewModel(vault: fake, resolver: resolver)
        vm.selectedSnapshotID = 1
        vm.handleSnapshotSelectionChanged()
        await vm.loadMoreFiles()

        vm.selectedFileID = a.id
        vm.handleFileSelectionChanged()
        async let firstFetch: Void = vm.loadMoreReferencedAssets()
        try await Task.sleep(nanoseconds: 10_000_000)
        vm.selectedFileID = b.id
        vm.handleFileSelectionChanged()
        _ = await firstFetch

        XCTAssertFalse(
            vm.referencedAssets.contains(where: { $0.assetRelativePath == "assets/slow.png" }),
            "stale chip list from the old file must not land in the VM"
        )
    }

    func testLoadPreviewedAssetPayloadPopulatesBytes() async throws {
        let fake = FakeVault()
        let source = Self.makeFile(snapshotID: 1, relativePath: "conversations-0001.json")
        fake.filePages[1] = [[source]]

        let resolver = FakeAssetResolver()
        let hit = Self.makeAssetHit(snapshotID: 1, sourceRelativePath: source.relativePath, asset: "assets/img.png")
        resolver.assetsByFile[Self.key(1, source.relativePath)] = [[hit]]

        // The preview sheet pulls bytes via vault.loadFile — the fake keys on
        // relative path, so seed the asset's path rather than the source file's.
        fake.payloadsByRelativePath[hit.assetRelativePath] = RawExportFilePayload(
            entry: Self.makeFile(snapshotID: 1, relativePath: hit.assetRelativePath),
            data: Data([0x89, 0x50, 0x4E, 0x47])
        )

        let vm = Self.makeViewModel(vault: fake, resolver: resolver)
        vm.selectedSnapshotID = 1
        vm.handleSnapshotSelectionChanged()
        await vm.loadMoreFiles()
        vm.selectedFileID = source.id
        vm.handleFileSelectionChanged()
        await vm.loadMoreReferencedAssets()

        vm.previewingAssetID = hit.id
        await vm.loadPreviewedAssetPayload()

        XCTAssertEqual(vm.previewedAssetState, .loaded)
        XCTAssertEqual(
            vm.previewedAssetPayload?.data,
            Data([0x89, 0x50, 0x4E, 0x47])
        )
    }

    func testChangingFilePreservesNoPreviewIDFromOldFile() async throws {
        let fake = FakeVault()
        let a = Self.makeFile(snapshotID: 1, relativePath: "a.json")
        let b = Self.makeFile(snapshotID: 1, relativePath: "b.json")
        fake.filePages[1] = [[a, b]]

        let resolver = FakeAssetResolver()
        let hit = Self.makeAssetHit(snapshotID: 1, sourceRelativePath: "a.json", asset: "assets/a.png")
        resolver.assetsByFile[Self.key(1, "a.json")] = [[hit]]

        let vm = Self.makeViewModel(vault: fake, resolver: resolver)
        vm.selectedSnapshotID = 1
        vm.handleSnapshotSelectionChanged()
        await vm.loadMoreFiles()
        vm.selectedFileID = a.id
        vm.handleFileSelectionChanged()
        await vm.loadMoreReferencedAssets()
        vm.previewingAssetID = hit.id
        XCTAssertNotNil(vm.previewingAssetID)

        vm.selectedFileID = b.id
        vm.handleFileSelectionChanged()
        // Preview belongs to file A — switching to file B must retire the
        // open asset sheet so it can't linger with stale chip metadata. In
        // production the view's `.onChange(of:)` handler does this.
        XCTAssertNil(vm.previewingAssetID)
        XCTAssertNil(vm.previewedAssetPayload)
    }

    // MARK: - Fixtures

    private static func makeViewModel(
        vault: any RawExportVault,
        resolver: any RawAssetResolver = FakeAssetResolver()
    ) -> VaultBrowserViewModel {
        VaultBrowserViewModel(vault: vault, assetResolver: resolver)
    }

    private static func key(_ snapshotID: Int64, _ relativePath: String) -> String {
        "\(snapshotID):\(relativePath)"
    }

    private static func makeAssetHit(
        snapshotID: Int64,
        sourceRelativePath: String,
        asset: String
    ) -> RawAssetHit {
        RawAssetHit(
            snapshotID: snapshotID,
            sourceRelativePath: sourceRelativePath,
            assetRelativePath: asset,
            blobHash: String(repeating: "d", count: 64),
            kind: "image",
            sizeBytes: 256,
            storedSizeBytes: 256,
            mimeType: "image/png",
            compression: "none"
        )
    }

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

    var payloadsByRelativePath: [String: RawExportFilePayload] = [:]
    var loadFileError: Error?
    var loadFileCallCount = 0

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
        loadFileCallCount += 1
        if let loadFileError { throw loadFileError }
        if let payload = payloadsByRelativePath[relativePath] {
            return payload
        }
        throw RawExportVaultError.fileNotFound(snapshotID: snapshotID, relativePath: relativePath)
    }
}

// MARK: - FakeAssetResolver

/// Hand-rolled `RawAssetResolver` stub for D4 tests. Keyed by the compound
/// `"snapshotID:sourceRelativePath"` so multiple files inside the same
/// snapshot can each expose a distinct chip list.
private final class FakeAssetResolver: RawAssetResolver, @unchecked Sendable {
    /// Pages of hits, keyed by `"snapshotID:sourceRelativePath"`. Each call
    /// to `assetsReferencedBy` pops the head page, matching the way the VM
    /// calls this method as the user pages through chips.
    var assetsByFile: [String: [[RawAssetHit]]] = [:]
    var resolverError: Error?
    var fetchDelay: Duration = .zero
    var assetsReferencedByCallCount = 0
    var resolveAssetCallCount = 0

    func resolveAsset(
        snapshotID: Int64,
        reference: String
    ) async throws -> RawAssetHit? {
        resolveAssetCallCount += 1
        if let resolverError { throw resolverError }
        return nil
    }

    func assetsReferencedBy(
        snapshotID: Int64,
        sourceRelativePath: String,
        offset: Int,
        limit: Int
    ) async throws -> [RawAssetHit] {
        assetsReferencedByCallCount += 1
        if fetchDelay != .zero {
            try await Task.sleep(for: fetchDelay)
        }
        if let resolverError { throw resolverError }
        let key = "\(snapshotID):\(sourceRelativePath)"
        guard var pages = assetsByFile[key], !pages.isEmpty else { return [] }
        let page = pages.removeFirst()
        assetsByFile[key] = pages
        return page
    }
}
