import Foundation
import Observation

/// Drives the Phase D1 raw-export Vault browser.
///
/// The view model is deliberately small and read-only: it wraps
/// `RawExportVault.listSnapshots` + `listFiles`, keeps a cursor for each, and
/// exposes async entry points the view can call from `.task` / button taps.
/// Callers **must not** touch the underlying SQLite tables directly — this
/// class is the only bridge between the UI and the vault protocol.
///
/// The VM is `@Observable` so SwiftUI redraws on any `@ObservationTracked`
/// property mutation, and `@MainActor` so `snapshots` / `files` / phase
/// mutations stay on the main thread without extra hopping.
@MainActor
@Observable
final class VaultBrowserViewModel {
    /// Page size for both snapshot + file paging. Chosen to be big enough that
    /// the UI rarely needs to paginate in practice but small enough that the
    /// first frame paints quickly.
    static let pageSize = 50

    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(message: String)
    }

    /// Snapshots loaded so far, newest first (matches the SQL order).
    private(set) var snapshots: [RawExportSnapshotSummary] = []
    private(set) var snapshotsState: LoadState = .idle
    private(set) var hasMoreSnapshots = true

    /// Snapshot the user has currently selected in the sidebar (nil = none).
    var selectedSnapshotID: Int64? {
        didSet {
            guard oldValue != selectedSnapshotID else { return }
            files = []
            filesState = .idle
            hasMoreFiles = true
            filesOffset = 0
        }
    }

    /// Files loaded for `selectedSnapshotID`. Resets when the selection
    /// changes, so callers don't need to clear it manually.
    private(set) var files: [RawExportFileEntry] = []
    private(set) var filesState: LoadState = .idle
    private(set) var hasMoreFiles = true

    private let vault: any RawExportVault
    private var snapshotsOffset = 0
    private var filesOffset = 0

    init(vault: any RawExportVault) {
        self.vault = vault
    }

    // MARK: - Snapshots

    /// Fetch the next page of snapshots. Idempotent while a fetch is in
    /// flight, so the view can call this from `.task` + "Load more" without
    /// worrying about overlap.
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

    // MARK: - Files

    /// Fetch the next page of files for the currently selected snapshot.
    /// No-op when `selectedSnapshotID` is nil.
    func loadMoreFiles() async {
        guard let snapshotID = selectedSnapshotID else { return }
        guard filesState != .loading, hasMoreFiles else { return }
        // Capture the selection we started with so we can abort writing the
        // result if the user clicked away mid-flight.
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
