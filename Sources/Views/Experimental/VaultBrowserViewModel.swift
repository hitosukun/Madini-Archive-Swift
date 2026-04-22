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
            // Switching snapshot also invalidates any file we had open and
            // therefore any asset chips / preview derived from that file.
            selectedFileID = nil
            resetReferencedAssets()
        }
    }

    /// Files loaded for `selectedSnapshotID`. Resets when the selection
    /// changes, so callers don't need to clear it manually.
    private(set) var files: [RawExportFileEntry] = []
    private(set) var filesState: LoadState = .idle
    private(set) var hasMoreFiles = true

    /// Compound key (`RawExportFileEntry.id` = "snapshotID:relativePath") of
    /// the file the user is currently inspecting. Changing this clears the
    /// previously loaded payload and asset chips so the view can't flash
    /// stale bytes or chips from the old selection.
    var selectedFileID: String? {
        didSet {
            guard oldValue != selectedFileID else { return }
            selectedFilePayload = nil
            fileContentState = .idle
            resetReferencedAssets()
            // Any open asset preview belongs to the previous source file.
            previewingAssetID = nil
        }
    }

    /// Decompressed bytes + metadata for `selectedFileID`. `nil` until the
    /// view calls `loadSelectedFileContent()`.
    private(set) var selectedFilePayload: RawExportFilePayload?
    private(set) var fileContentState: LoadState = .idle

    // MARK: - Asset chips (D4)

    /// Assets referenced by the currently selected (textual) file, resolved
    /// via `RawAssetResolver.assetsReferencedBy`. Empty when the selected
    /// file isn't a document that references anything.
    private(set) var referencedAssets: [RawAssetHit] = []
    private(set) var referencedAssetsState: LoadState = .idle

    /// Asset the user is previewing via the chip overlay (D4). When non-nil
    /// the view shows the asset preview sheet; setting it back to nil or to
    /// a different hit re-triggers payload loading.
    var previewingAssetID: String? {
        didSet {
            guard oldValue != previewingAssetID else { return }
            previewedAssetPayload = nil
            previewedAssetState = .idle
        }
    }

    /// Decompressed bytes for `previewingAssetID` once loaded.
    private(set) var previewedAssetPayload: RawExportFilePayload?
    private(set) var previewedAssetState: LoadState = .idle

    /// Backing hit record for `previewingAssetID` so the view can title the
    /// preview sheet without reaching back through the resolver.
    var previewingAsset: RawAssetHit? {
        guard let previewingAssetID else { return nil }
        return referencedAssets.first { $0.id == previewingAssetID }
    }

    private let vault: any RawExportVault
    private let assetResolver: any RawAssetResolver
    private var snapshotsOffset = 0
    private var filesOffset = 0
    private var referencedAssetsOffset = 0

    init(
        vault: any RawExportVault,
        assetResolver: any RawAssetResolver
    ) {
        self.vault = vault
        self.assetResolver = assetResolver
    }

    /// Entry metadata for `selectedFileID`, looked up in the already-loaded
    /// `files` page. Returns `nil` when no file is selected or when the
    /// selected file no longer exists in the list (e.g. after a selection
    /// change that hasn't yet been reflected in the UI).
    var selectedFileEntry: RawExportFileEntry? {
        guard let selectedFileID else { return nil }
        return files.first { $0.id == selectedFileID }
    }

    // MARK: - Snapshots

    /// Wipe the snapshot list and re-fetch the first page. Called after a
    /// successful vault ingest so the new snapshot appears at the top of the
    /// sidebar without the user having to scroll through a stale page cursor.
    /// File / asset state deliberately stays untouched so the current
    /// selection isn't thrown away when the user's intent was just "import
    /// one more export."
    func reloadSnapshots() async {
        snapshots = []
        snapshotsOffset = 0
        hasMoreSnapshots = true
        snapshotsState = .idle
        await loadMoreSnapshots()
    }

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

    // MARK: - File content

    /// Pull the decompressed bytes for `selectedFileID` via
    /// `RawExportVault.loadFile`. Idempotent while a fetch is in flight, and
    /// the result is discarded if the user switched files mid-flight so the
    /// view never renders bytes belonging to a previously selected file.
    func loadSelectedFileContent() async {
        guard let entry = selectedFileEntry else { return }
        guard fileContentState != .loading else { return }
        let pinnedFileID = entry.id
        fileContentState = .loading
        do {
            let payload = try await vault.loadFile(
                snapshotID: entry.snapshotID,
                relativePath: entry.relativePath
            )
            guard selectedFileID == pinnedFileID else { return }
            selectedFilePayload = payload
            fileContentState = .loaded
        } catch {
            guard selectedFileID == pinnedFileID else { return }
            selectedFilePayload = nil
            fileContentState = .failed(message: Self.message(for: error))
        }
    }

    // MARK: - Referenced assets (D4)

    /// Load (or page) the assets referenced by the currently selected file.
    /// The D4 UI calls this after a file is selected; it's cheap to no-op
    /// when the selection isn't a document that references anything because
    /// the resolver simply returns an empty page.
    func loadMoreReferencedAssets() async {
        guard let entry = selectedFileEntry else { return }
        guard referencedAssetsState != .loading else { return }
        let pinnedFileID = entry.id
        referencedAssetsState = .loading
        do {
            let page = try await assetResolver.assetsReferencedBy(
                snapshotID: entry.snapshotID,
                sourceRelativePath: entry.relativePath,
                offset: referencedAssetsOffset,
                limit: Self.pageSize
            )
            guard selectedFileID == pinnedFileID else { return }
            referencedAssets.append(contentsOf: page)
            referencedAssetsOffset += page.count
            referencedAssetsState = .loaded
        } catch {
            guard selectedFileID == pinnedFileID else { return }
            referencedAssetsState = .failed(message: Self.message(for: error))
        }
    }

    /// Load the asset bytes for the current `previewingAssetID` via
    /// `RawExportVault.loadFile`. Called by the chip-preview sheet.
    func loadPreviewedAssetPayload() async {
        guard let hit = previewingAsset else { return }
        guard previewedAssetState != .loading else { return }
        let pinnedAssetID = hit.id
        previewedAssetState = .loading
        do {
            let payload = try await vault.loadFile(
                snapshotID: hit.snapshotID,
                relativePath: hit.assetRelativePath
            )
            guard previewingAssetID == pinnedAssetID else { return }
            previewedAssetPayload = payload
            previewedAssetState = .loaded
        } catch {
            guard previewingAssetID == pinnedAssetID else { return }
            previewedAssetPayload = nil
            previewedAssetState = .failed(message: Self.message(for: error))
        }
    }

    private func resetReferencedAssets() {
        referencedAssets = []
        referencedAssetsState = .idle
        referencedAssetsOffset = 0
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
