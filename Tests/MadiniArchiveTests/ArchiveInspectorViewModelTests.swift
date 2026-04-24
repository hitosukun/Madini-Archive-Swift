import XCTest
#if os(macOS)
@testable import MadiniArchive

/// Unit coverage for the consolidated Archive Inspector view model.
///
/// Scope mirrors the now-retired `VaultBrowserViewModelTests`, pared to the
/// surface area that survived consolidation: two page cursors and the
/// unified timeline. The file-content / asset-chip paths moved elsewhere
/// (preview windows, message bubbles) and are not the VM's job.
///
/// The fake vault lets us drive pagination and the pinned-selection
/// stale-write pattern deterministically. For the stale-write case we use a
/// continuation-backed gate so the test can flip `selectedSnapshotID` while
/// `listFiles` is suspended — no timing hacks.
@MainActor
final class ArchiveInspectorViewModelTests: XCTestCase {
    // MARK: - Snapshot pagination

    func testLoadMoreSnapshotsAppendsAndTracksHasMore() async throws {
        let fake = FakeVault()
        fake.snapshotPages = [
            (0..<ArchiveInspectorViewModel.pageSize).map { Self.makeSnapshot(id: Int64($0 + 1)) },
            [Self.makeSnapshot(id: 9_999)] // short page → hasMore flips false
        ]
        let vm = ArchiveInspectorViewModel(vault: fake, intakeLog: nil)

        await vm.loadMoreSnapshots()
        XCTAssertEqual(vm.snapshots.count, ArchiveInspectorViewModel.pageSize)
        XCTAssertEqual(vm.snapshotsState, .loaded)
        XCTAssertTrue(vm.hasMoreSnapshots, "full page means there may be more")

        await vm.loadMoreSnapshots()
        XCTAssertEqual(vm.snapshots.count, ArchiveInspectorViewModel.pageSize + 1)
        XCTAssertFalse(vm.hasMoreSnapshots, "short page means we've hit the end")
    }

    func testReloadSnapshotsResetsCursorAndFetchesFirstPage() async throws {
        let fake = FakeVault()
        fake.snapshotPages = [
            [Self.makeSnapshot(id: 1), Self.makeSnapshot(id: 2)],
            // Simulates vault state after a background ingest — the new
            // snapshot shows up on top; reload must surface it without the
            // old cursor pinning us past it.
            [Self.makeSnapshot(id: 99), Self.makeSnapshot(id: 1), Self.makeSnapshot(id: 2)]
        ]
        let vm = ArchiveInspectorViewModel(vault: fake, intakeLog: nil)

        await vm.loadMoreSnapshots()
        XCTAssertEqual(vm.snapshots.map(\.id), [1, 2])

        await vm.reloadSnapshots()
        XCTAssertEqual(vm.snapshots.map(\.id), [99, 1, 2])
        XCTAssertEqual(vm.snapshotsState, .loaded)
    }

    // MARK: - File pagination

    func testLoadMoreFilesIsNoOpWithoutSelection() async throws {
        let fake = FakeVault()
        let vm = ArchiveInspectorViewModel(vault: fake, intakeLog: nil)

        await vm.loadMoreFiles()

        XCTAssertEqual(fake.listFilesCallCount, 0)
        XCTAssertEqual(vm.filesState, .idle)
    }

    func testLoadMoreFilesPagesInWithOffsetMathAndHonorsShortPage() async throws {
        let fake = FakeVault()
        let firstPage = (0..<ArchiveInspectorViewModel.pageSize).map {
            Self.makeFile(snapshotID: 1, relativePath: "file-\($0).json")
        }
        fake.filePages[1] = [
            firstPage,
            [Self.makeFile(snapshotID: 1, relativePath: "tail.json")] // short page
        ]

        let vm = ArchiveInspectorViewModel(vault: fake, intakeLog: nil)
        vm.selectedSnapshotID = 1
        vm.handleSnapshotSelectionChanged()

        await vm.loadMoreFiles()
        XCTAssertEqual(vm.files.count, ArchiveInspectorViewModel.pageSize)
        XCTAssertTrue(vm.hasMoreFiles)
        XCTAssertEqual(fake.lastFileOffset, 0)

        await vm.loadMoreFiles()
        XCTAssertEqual(vm.files.count, ArchiveInspectorViewModel.pageSize + 1)
        XCTAssertFalse(vm.hasMoreFiles, "short page means we've hit the end")
        XCTAssertEqual(
            fake.lastFileOffset,
            ArchiveInspectorViewModel.pageSize,
            "second fetch should use offset advanced by the first page size"
        )
    }

    // MARK: - Pinned-selection stale-write discard

    func testLoadMoreFilesDiscardsResultWhenSelectionChangesMidFlight() async throws {
        let fake = FakeVault()
        fake.blockFilesFetch = true
        fake.filePages[1] = [[Self.makeFile(snapshotID: 1, relativePath: "slow-from-1.json")]]
        fake.filePages[2] = [[Self.makeFile(snapshotID: 2, relativePath: "fast-from-2.json")]]

        let vm = ArchiveInspectorViewModel(vault: fake, intakeLog: nil)
        vm.selectedSnapshotID = 1
        vm.handleSnapshotSelectionChanged()

        let firstFetch = Task { await vm.loadMoreFiles() }

        // Wait for the in-flight fetch to be suspended on the continuation.
        // No Task.sleep — the gate signals as soon as the fake enters.
        await fake.waitUntilFilesFetchBlocked()

        // Flip selection while the first fetch is still parked.
        vm.selectedSnapshotID = 2
        vm.handleSnapshotSelectionChanged()

        // Release the stale fetch; the VM must drop its result on the floor.
        fake.releaseFilesFetch()
        _ = await firstFetch.value

        XCTAssertTrue(
            vm.files.isEmpty,
            "stale result from the old selection must not land in the VM"
        )
        XCTAssertEqual(
            vm.filesState, .idle,
            "filesState must not be overwritten for the superseded selection"
        )
    }

    // MARK: - Timeline merge ordering

    func testTimelineMergesSnapshotsAndEventsReverseChronologically() async throws {
        let fake = FakeVault()
        // Two snapshots straddling an event recorded "now" (Date()). Using
        // far-past / far-future strings keeps the ordering deterministic
        // regardless of when the test runs.
        let past = Self.makeSnapshot(id: 1, importedAt: "2000-01-01 00:00:00")
        let future = Self.makeSnapshot(id: 2, importedAt: "2999-01-01 00:00:00")
        fake.snapshotPages = [[future, past]]

        let log = IntakeActivityLog()
        log.record(source: "drop", kind: .unrecognized(reason: "test"))

        let vm = ArchiveInspectorViewModel(vault: fake, intakeLog: log)
        await vm.loadMoreSnapshots()

        let timeline = vm.timeline
        XCTAssertEqual(timeline.count, 3)
        XCTAssertEqual(timeline[0].id, "snapshot:\(future.id)", "future snapshot sorts first")
        if case .event = timeline[1] {} else {
            XCTFail("event (Date() ≈ today) should sit between future and past snapshot, got \(timeline[1])")
        }
        XCTAssertEqual(timeline[2].id, "snapshot:\(past.id)", "past snapshot sorts last")
    }

    func testTimelineOmitsEventsWhenIntakeLogIsNil() async throws {
        let fake = FakeVault()
        fake.snapshotPages = [[Self.makeSnapshot(id: 1)]]
        let vm = ArchiveInspectorViewModel(vault: fake, intakeLog: nil)

        await vm.loadMoreSnapshots()

        XCTAssertEqual(vm.timeline.count, 1)
        XCTAssertEqual(vm.timeline[0].id, "snapshot:1")
    }

    // MARK: - Selection reset

    func testHandleSnapshotSelectionChangedResetsFileState() async throws {
        let fake = FakeVault()
        fake.filePages[1] = [[Self.makeFile(snapshotID: 1, relativePath: "a.json")]]
        fake.filePages[2] = [[Self.makeFile(snapshotID: 2, relativePath: "b.json")]]

        let vm = ArchiveInspectorViewModel(vault: fake, intakeLog: nil)
        vm.selectedSnapshotID = 1
        vm.handleSnapshotSelectionChanged()
        await vm.loadMoreFiles()
        XCTAssertEqual(vm.files.map(\.relativePath), ["a.json"])
        XCTAssertEqual(vm.filesState, .loaded)

        vm.selectedSnapshotID = 2
        vm.handleSnapshotSelectionChanged()

        XCTAssertTrue(vm.files.isEmpty, "files should reset on selection change")
        XCTAssertEqual(vm.filesState, .idle)
        XCTAssertTrue(vm.hasMoreFiles)

        // Fresh cursor: the next load must start at offset 0 for the new
        // snapshot, not inherit the previous snapshot's advanced offset.
        await vm.loadMoreFiles()
        XCTAssertEqual(vm.files.map(\.relativePath), ["b.json"])
        XCTAssertEqual(fake.lastFileOffset, 0)
    }

    // MARK: - Fixtures

    private static func makeSnapshot(
        id: Int64,
        importedAt: String = "2026-04-22 00:00:00"
    ) -> RawExportSnapshotSummary {
        RawExportSnapshotSummary(
            id: id,
            provider: .chatGPT,
            sourceRoot: "/tmp/export-\(id)",
            importedAt: importedAt,
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

/// Hand-rolled `RawExportVault` stub. Covers just enough of the protocol to
/// drive the VM — ingest/search/blob paths throw so an accidental call blows
/// up loudly in tests.
///
/// The `blockFilesFetch` gate suspends `listFiles` on a continuation until
/// the test calls `releaseFilesFetch()`. `waitUntilFilesFetchBlocked()` lets
/// the test synchronize on "the fake has entered listFiles and is parked"
/// without timing-based sleeps, which is what makes the stale-write test
/// deterministic.
private final class FakeVault: RawExportVault, @unchecked Sendable {
    var snapshotPages: [[RawExportSnapshotSummary]] = []
    var listSnapshotsCallCount = 0

    var filePages: [Int64: [[RawExportFileEntry]]] = [:]
    var listFilesCallCount = 0
    var lastFileOffset: Int = -1

    // Gate used by the stale-write test.
    var blockFilesFetch = false
    private let lock = NSLock()
    private var fileGateContinuation: CheckedContinuation<Void, Never>?
    private var armedWaiters: [CheckedContinuation<Void, Never>] = []

    func waitUntilFilesFetchBlocked() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lock.lock()
            if fileGateContinuation != nil {
                lock.unlock()
                cont.resume()
            } else {
                armedWaiters.append(cont)
                lock.unlock()
            }
        }
    }

    func releaseFilesFetch() {
        lock.lock()
        let cont = fileGateContinuation
        fileGateContinuation = nil
        lock.unlock()
        cont?.resume()
    }

    // MARK: RawExportVault

    func ingest(_ urls: [URL]) async throws -> RawExportVaultResult? { nil }

    func listSnapshots(offset: Int, limit: Int) async throws -> [RawExportSnapshotSummary] {
        listSnapshotsCallCount += 1
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

    func getSnapshot(id: Int64) async throws -> RawExportSnapshotSummary? { nil }

    func listFiles(
        snapshotID: Int64,
        offset: Int,
        limit: Int
    ) async throws -> [RawExportFileEntry] {
        listFilesCallCount += 1
        lastFileOffset = offset

        if blockFilesFetch {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                lock.lock()
                fileGateContinuation = cont
                let waiters = armedWaiters
                armedWaiters.removeAll()
                lock.unlock()
                for waiter in waiters { waiter.resume() }
            }
        }

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
#endif
