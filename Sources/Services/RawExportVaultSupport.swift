import Foundation

struct NoOpRawExportVault: RawExportVault {
    func ingest(_ urls: [URL]) async throws -> RawExportVaultResult? {
        nil
    }
}
