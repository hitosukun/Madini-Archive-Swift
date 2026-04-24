import Foundation

/// Inert `RawExportVault` used when the on-disk database is absent or when a
/// caller wants a feature-flag "off" switch without branching every call site.
///
/// - `ingest` / `listSnapshots` / `search` return empty results rather than
///   throwing, so the UI can compose these calls without special-casing the
///   mock path.
/// - `getSnapshot` returns `nil` — single-item lookup APIs naturally express
///   absence as `nil`, and callers typically branch on that already.
/// - `listFiles` / `loadBlob` / `loadFile` throw `RawExportVaultError.*NotFound`
///   so that callers hitting the no-op vault by mistake surface a loud, typed
///   failure rather than silently receiving empty data.
struct NoOpRawExportVault: RawExportVault {
    func ingest(_ urls: [URL]) async throws -> RawExportVaultResult? {
        nil
    }

    func listSnapshots(offset: Int, limit: Int) async throws -> [RawExportSnapshotSummary] {
        []
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
        // A no-op vault never ingests, so every snapshotID is unknown —
        // match `GRDBRawExportVault.listFiles` and throw rather than return
        // an empty page that callers could mistake for "snapshot was empty".
        throw RawExportVaultError.snapshotNotFound(snapshotID: snapshotID)
    }

    func loadBlob(hash: String) async throws -> Data {
        throw RawExportVaultError.blobNotFound(hash: hash)
    }

    func loadFile(
        snapshotID: Int64,
        relativePath: String
    ) async throws -> RawExportFilePayload {
        throw RawExportVaultError.fileNotFound(
            snapshotID: snapshotID,
            relativePath: relativePath
        )
    }

    func deleteSnapshot(id: Int64) async throws -> RawExportVaultDeleteResult {
        // The no-op vault holds no snapshots, so a delete request can only
        // reference an unknown id. Match the read APIs' loud-failure stance
        // (rather than silently returning a zero-result struct) so a caller
        // who reaches the no-op path by mistake hears about it.
        throw RawExportVaultError.snapshotNotFound(snapshotID: id)
    }
}

struct NoOpRawAssetResolver: RawAssetResolver {
    func resolveAsset(
        snapshotID: Int64,
        reference: String
    ) async throws -> RawAssetHit? {
        nil
    }

    func assetsReferencedBy(
        snapshotID: Int64,
        sourceRelativePath: String,
        offset: Int,
        limit: Int
    ) async throws -> [RawAssetHit] {
        throw RawExportVaultError.snapshotNotFound(snapshotID: snapshotID)
    }
}
