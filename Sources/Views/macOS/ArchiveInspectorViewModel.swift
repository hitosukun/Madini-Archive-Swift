#if os(macOS)
import Foundation
import Observation

/// Drives the consolidated Library → archive.db pane. Replaces what used to
/// be three separate sidebar entry points: the Auto-Intake drop-folder
/// pane, the rolling activity log, and the standalone Vault Browser
/// window. Everything funnels through this view model now, so the user
/// has one "the archive lives here" surface instead of three.
///
/// ## Responsibilities
///
/// 1. **Snapshot paging**: same pattern as the old `VaultBrowserViewModel` —
///    `listSnapshots(offset:limit:)` with a cursor, `.loaded`/`.loading`
///    state, stale-result discard by pinning the requested cursor.
/// 2. **Per-snapshot file paging**: the right pane asks for files once a
///    snapshot is selected; the VM pages them in, cancelling stale
///    writes if the user clicks away mid-flight.
/// 3. **Unified timeline**: merges the snapshot list with the ephemeral
///    `IntakeActivityLog` events (recent importer successes, failures,
///    already-ingested hits) into one reverse-chronological list. The
///    user asked for the Auto-Intake activity log to show up inside the
///    vault browsing surface, not next to it — this is the merge that
///    makes "I just dropped a file, did it land?" answerable without
///    switching panes.
///
/// ## What lives elsewhere
///
/// - Drop-folder configuration (Copy / Change / Reset buttons and the
///   current path) is driven by `AppServices.intakeDirURL` /
///   `setIntakeDirectory(_:)` directly in the view; this VM doesn't
///   proxy those because they're trivially few-line operations and
///   wrapping them would just add indirection.
/// - Previewing a file's bytes is delegated to `ImagePreviewWindow` /
///   `TextPreviewWindow`, not to a detail pane inside the VM. The user
///   explicitly asked for the image preview window to be "reused" for
///   file contents, which we implement by routing clicks from the file
///   list into those windows — the VM only cares about metadata.
///
/// ## Why not fold this into `VaultBrowserViewModel`
///
/// `VaultBrowserViewModel` also handled asset chips and the asset-
/// preview sheet used inside the standalone Vault Browser window. Those
/// live inside the reader experience now (asset chips are in message
/// bubbles, preview uses `ImagePreviewWindow`), so importing them into
/// the Archive Inspector would just carry dead weight. Starting fresh
/// lets us keep this pared down to the two page cursors we actually use.
@MainActor
@Observable
final class ArchiveInspectorViewModel {
    static let pageSize: Int = 50

    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(message: String)
    }

    /// One row in the unified timeline shown in the middle pane. Either
    /// a vaulted snapshot (selectable — picking it populates the right
    /// pane with that snapshot's files) or an ephemeral intake event
    /// (non-selectable — it's context about what the drop-folder
    /// watcher saw). Kept as an enum rather than a struct so the SwiftUI
    /// row view can branch its styling / selection behavior cleanly.
    /// `Hashable` via the computed `id` (both snapshot and event ids
    /// are already unique) rather than deriving from associated values —
    /// `IntakeActivityLog.Event` isn't Hashable, and wrapping it just
    /// to get synthesized conformance would be noise.
    enum TimelineItem: Identifiable, Hashable {
        case snapshot(RawExportSnapshotSummary)
        case event(IntakeActivityLog.Event)

        static func == (lhs: TimelineItem, rhs: TimelineItem) -> Bool {
            lhs.id == rhs.id
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(id)
        }

        var id: String {
            switch self {
            case .snapshot(let s): return "snapshot:\(s.id)"
            case .event(let e): return "event:\(e.id.uuidString)"
            }
        }

        var sortDate: Date {
            switch self {
            case .snapshot(let s):
                return GRDBProjectDateCodec.date(from: s.importedAt)
            case .event(let e):
                return e.timestamp
            }
        }
    }

    // MARK: Snapshots

    /// Snapshots loaded so far, newest first (matches the SQL order).
    private(set) var snapshots: [RawExportSnapshotSummary] = []
    private(set) var snapshotsState: LoadState = .idle
    private(set) var hasMoreSnapshots: Bool = true

    /// The snapshot row the user currently has selected, if any. The
    /// right pane watches this via `.task(id:)` and (re)loads the file
    /// list when it changes. Explicit reset happens in
    /// `handleSnapshotSelectionChanged()` — we don't use `didSet` here
    /// to avoid the re-entrant @Observable redraw problem the old
    /// Vault Browser hit: triggering cascading mutations from inside a
    /// SwiftUI `Binding.set` can leave columns blank on macOS.
    var selectedSnapshotID: Int64?

    // MARK: Files for the selected snapshot

    private(set) var files: [RawExportFileEntry] = []
    private(set) var filesState: LoadState = .idle
    private(set) var hasMoreFiles: Bool = true

    // MARK: Intake activity

    /// Observable handle to the rolling intake log. `nil` in mock mode —
    /// auto-intake isn't wired so there's nothing to show. The view reads
    /// `intakeLog?.events` via this property; SwiftUI's observation
    /// follows the nested @Observable so log mutations redraw the
    /// timeline without us plumbing an explicit notification.
    let intakeLog: IntakeActivityLog?

    // MARK: Private

    private let vault: any RawExportVault
    private var snapshotsOffset: Int = 0
    private var filesOffset: Int = 0

    init(vault: any RawExportVault, intakeLog: IntakeActivityLog?) {
        self.vault = vault
        self.intakeLog = intakeLog
    }

    // MARK: - Timeline

    /// Merged reverse-chronological list of snapshots and intake events.
    /// Recomputed from source-of-truth arrays on each read — both inputs
    /// are small (≤ page size for snapshots, 100-entry cap on the log),
    /// so an O(n log n) sort per draw is cheaper than maintaining a
    /// synthetic index that could drift out of sync with the backing
    /// stores on async mutations.
    var timeline: [TimelineItem] {
        var items: [TimelineItem] = []
        items.reserveCapacity(snapshots.count + (intakeLog?.events.count ?? 0))
        for snapshot in snapshots {
            items.append(.snapshot(snapshot))
        }
        if let events = intakeLog?.events {
            for event in events {
                items.append(.event(event))
            }
        }
        items.sort { $0.sortDate > $1.sortDate }
        return items
    }

    // MARK: - Snapshot loading

    /// Wipe the snapshot list and re-fetch the first page. Called after a
    /// successful vault ingest so the new snapshot shows up at the top
    /// of the timeline without the user needing to scroll through a
    /// stale cursor. File selection state is intentionally preserved so
    /// the user's current inspection isn't interrupted by an unrelated
    /// background ingest.
    func reloadSnapshots() async {
        snapshots = []
        snapshotsOffset = 0
        hasMoreSnapshots = true
        snapshotsState = .idle
        await loadMoreSnapshots()
    }

    /// Fetch the next page of snapshots. Idempotent while a fetch is in
    /// flight so `.task` + "Load more" can both call this without
    /// racing.
    func loadMoreSnapshots() async {
        guard snapshotsState != .loading, hasMoreSnapshots else { return }
        snapshotsState = .loading
        do {
            let page = try await vault.listSnapshots(
                offset: snapshotsOffset,
                limit: Self.pageSize
            )
            snapshots.append(contentsOf: page)
            snapshotsOffset += page.count
            hasMoreSnapshots = page.count == Self.pageSize
            snapshotsState = .loaded
        } catch {
            snapshotsState = .failed(message: Self.message(for: error))
        }
    }

    // MARK: - File loading

    /// Clear every piece of state that belongs to the previously selected
    /// snapshot. Called from the right pane's `.task(id:)` so the reset
    /// is serialized with the subsequent `loadMoreFiles()` call —
    /// running it from a `didSet` would fire inside a SwiftUI binding
    /// update and can blank the detail column on macOS (same bug the
    /// old Vault Browser hit).
    func handleSnapshotSelectionChanged() {
        files = []
        filesState = .idle
        hasMoreFiles = true
        filesOffset = 0
    }

    /// Fetch the next page of files for the currently selected snapshot.
    /// Pins the requested selection locally and refuses to publish the
    /// result if the user clicked away while the call was in flight —
    /// otherwise a slow load could overwrite the new snapshot's file
    /// list with stale rows from the previous one.
    func loadMoreFiles() async {
        guard let snapshotID = selectedSnapshotID else { return }
        guard filesState != .loading, hasMoreFiles else { return }
        let pinnedSelection = snapshotID
        filesState = .loading
        do {
            let page = try await vault.listFiles(
                snapshotID: snapshotID,
                offset: filesOffset,
                limit: Self.pageSize
            )
            guard selectedSnapshotID == pinnedSelection else { return }
            files.append(contentsOf: page)
            filesOffset += page.count
            hasMoreFiles = page.count == Self.pageSize
            filesState = .loaded
        } catch {
            guard selectedSnapshotID == pinnedSelection else { return }
            filesState = .failed(message: Self.message(for: error))
        }
    }

    // MARK: - Helpers

    private static func message(for error: Error) -> String {
        if let vaultError = error as? RawExportVaultError {
            switch vaultError {
            case .snapshotNotFound(let id):
                return "Snapshot \(id) was not found. It may have been deleted."
            case .fileNotFound(_, let path):
                return "File “\(path)” is missing from this snapshot."
            case .blobNotFound(let hash):
                return "Blob \(hash.prefix(8))… is missing from the vault."
            case .blobFileMissing(let hash, _):
                return "Blob \(hash.prefix(8))… was expected on disk but is missing."
            case .decompressionFailed(let hash):
                return "Failed to decompress blob \(hash.prefix(8))…."
            case .hashMismatch:
                return "A blob failed integrity check (hash mismatch)."
            case .unsupportedCompression(let codec):
                return "Unsupported compression codec: \(codec)."
            }
        }
        return error.localizedDescription
    }
}
#endif
