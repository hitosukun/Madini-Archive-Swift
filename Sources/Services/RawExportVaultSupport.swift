import Foundation

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
}
