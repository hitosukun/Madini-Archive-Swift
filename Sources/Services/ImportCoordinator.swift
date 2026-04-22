#if os(macOS)
import Foundation

struct ImportCoordinatorResult: Sendable {
    let jsonFileCount: Int
    let rejectedInputCount: Int
    let vaultResult: RawExportVaultResult
    let importerResult: JSONImportResult
    let reconciliationErrorDescription: String?
}

enum ImportCoordinatorError: LocalizedError, Sendable {
    case noImportableJSON(rejectedInputCount: Int)
    case vaultIngestFailed(message: String)
    case importStartFailed(message: String, vaultResult: RawExportVaultResult?)
    case importerFailed(exitCode: Int32, stderrTail: String?, vaultResult: RawExportVaultResult)

    var errorDescription: String? {
        switch self {
        case .noImportableJSON:
            return "Only JSON exports can be imported."
        case .vaultIngestFailed:
            return "Raw export vaulting failed."
        case .importStartFailed:
            return "Import couldn't start."
        case .importerFailed(let exitCode, _, _):
            return "Import failed (exit \(exitCode))."
        }
    }

    var failureDetail: String? {
        switch self {
        case .noImportableJSON(let rejectedInputCount):
            return rejectedInputCount > 0 ? "No supported export JSON files were found." : nil
        case .vaultIngestFailed(let message):
            return message
        case .importStartFailed(let message, let vaultResult):
            if let vaultResult {
                return "Vaulted snapshot \(vaultResult.snapshotID), but importer launch failed: \(message)"
            }
            return message
        case .importerFailed(_, let stderrTail, let vaultResult):
            let vaultMessage = "Vaulted snapshot \(vaultResult.snapshotID)."
            guard let stderrTail, !stderrTail.isEmpty else {
                return vaultMessage
            }
            return "\(vaultMessage) \(stderrTail)"
        }
    }
}

/// Coordinates one user-visible import attempt: resolve dropped URLs, preserve
/// the raw export first, then run normalization through the Python importer.
///
/// The key contract is asymmetric by design:
/// - Vault failure stops the import. We do not normalize data whose original
///   export was not preserved.
/// - Vault success is kept even if normalization fails. The original export is
///   still useful provenance and can be retried later.
enum ImportCoordinator {
    @MainActor
    static func importDroppedURLs(
        _ urls: [URL],
        services: AppServices
    ) async throws -> ImportCoordinatorResult {
        let selection = JSONImportFileResolver.resolve(urls)
        let jsonURLs = selection.jsonURLs

        guard !jsonURLs.isEmpty else {
            throw ImportCoordinatorError.noImportableJSON(
                rejectedInputCount: selection.rejectedInputCount
            )
        }

        let vaultResult = try await vaultOriginalExport(urls, services: services)
        let importerResult: JSONImportResult
        do {
            importerResult = try await Task.detached(priority: .userInitiated) {
                try await JSONImporter.importFiles(jsonURLs)
            }.value
        } catch {
            throw ImportCoordinatorError.importStartFailed(
                message: error.localizedDescription,
                vaultResult: vaultResult
            )
        }

        guard importerResult.exitCode == 0 else {
            throw ImportCoordinatorError.importerFailed(
                exitCode: importerResult.exitCode,
                stderrTail: stderrTail(from: importerResult),
                vaultResult: vaultResult
            )
        }

        let reconciliationErrorDescription: String?
        do {
            try await JSONImportProjectReconciler.reconcileImportedFiles(jsonURLs, services: services)
            reconciliationErrorDescription = nil
        } catch {
            reconciliationErrorDescription = error.localizedDescription
            print("Project reconciliation failed after import: \(error)")
        }

        return ImportCoordinatorResult(
            jsonFileCount: jsonURLs.count,
            rejectedInputCount: selection.rejectedInputCount,
            vaultResult: vaultResult,
            importerResult: importerResult,
            reconciliationErrorDescription: reconciliationErrorDescription
        )
    }

    @MainActor
    private static func vaultOriginalExport(
        _ urls: [URL],
        services: AppServices
    ) async throws -> RawExportVaultResult {
        do {
            let rawExportVault = services.rawExportVault
            let result = try await Task.detached(priority: .utility) {
                try await rawExportVault.ingest(urls)
            }.value
            guard let result else {
                throw ImportCoordinatorError.vaultIngestFailed(
                    message: "No files were stored in Raw Export Vault."
                )
            }
            return result
        } catch let error as ImportCoordinatorError {
            throw error
        } catch {
            throw ImportCoordinatorError.vaultIngestFailed(
                message: error.localizedDescription
            )
        }
    }

    private static func stderrTail(from result: JSONImportResult) -> String? {
        let tail = result.stderr
            .split(separator: "\n")
            .suffix(2)
            .joined(separator: " ")
        return tail.isEmpty ? nil : String(tail)
    }
}
#endif
