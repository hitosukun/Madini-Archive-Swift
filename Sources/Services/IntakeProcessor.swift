#if os(macOS)
import Foundation

/// Classifies an intake item and hands it to `ImportCoordinator`. Zip
/// archives are extracted to a temp directory first, then cleaned up.
///
/// The processor is stateless — each `process(_:)` call is independent, and
/// bookkeeping (which files are "in flight" vs. already dispatched) lives
/// in `IntakeWatcher`'s delivered-once guarantee. Failures here are surfaced
/// to `IntakeActivityLog` but never rethrown to the watcher, because the
/// watcher has no useful way to retry — "try again after the user changes
/// the file" is encoded by the watcher's observation reset.
@MainActor
struct IntakeProcessor {
    let services: AppServices
    let activityLog: IntakeActivityLog

    func process(_ item: IntakeWatcher.Item) async {
        let source = item.url.lastPathComponent

        switch Self.classify(item) {
        case .jsonFile, .folder:
            await runImport(urls: [item.url], source: source)

        case .zip:
            do {
                let tempDir = try await ZipExtraction.extract(item.url)
                defer { try? FileManager.default.removeItem(at: tempDir) }
                await runImport(urls: [tempDir], source: source)
            } catch {
                activityLog.record(
                    source: source,
                    kind: .failed(detail: "Failed to extract zip: \(error.localizedDescription)")
                )
            }

        case .unrecognized(let reason):
            activityLog.record(
                source: source,
                kind: .unrecognized(reason: reason)
            )
        }
    }

    // MARK: - Classification

    enum Classification: Equatable {
        case jsonFile
        case folder
        case zip
        case unrecognized(reason: String)
    }

    /// Classify an intake item. Zip detection is signature-based rather than
    /// extension-only so that a file renamed away from `.zip` still gets
    /// unzipped, and so that a text file renamed to `.zip` doesn't crash
    /// `/usr/bin/unzip` with a misleading error.
    nonisolated static func classify(_ item: IntakeWatcher.Item) -> Classification {
        if item.isDirectory {
            return .folder
        }
        let ext = item.url.pathExtension.lowercased()
        if ext == "json" {
            return .jsonFile
        }
        if isZipFile(at: item.url) {
            return .zip
        }
        if ext.isEmpty {
            return .unrecognized(reason: "No file extension; cannot classify.")
        }
        return .unrecognized(reason: "Unsupported file type: .\(ext)")
    }

    nonisolated static func isZipFile(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let signature = handle.readData(ofLength: 4)
        // "PK\x03\x04" = standard zip local file header. Empty archives use
        // "PK\x05\x06" (end-of-central-directory); we don't bother with those
        // — an empty zip has nothing to import anyway.
        return signature == Data([0x50, 0x4B, 0x03, 0x04])
    }

    // MARK: - Import dispatch

    private func runImport(urls: [URL], source: String) async {
        do {
            let result = try await ImportCoordinator.importDroppedURLs(urls, services: services)
            if result.wasDuplicateSnapshot {
                activityLog.record(
                    source: source,
                    kind: .alreadyIngested(snapshotID: result.vaultResult.snapshotID)
                )
            } else {
                activityLog.record(
                    source: source,
                    kind: .ingested(
                        snapshotID: result.vaultResult.snapshotID,
                        jsonFileCount: result.jsonFileCount
                    )
                )
            }
        } catch let error as ImportCoordinatorError {
            switch error {
            case .noImportableJSON:
                activityLog.record(
                    source: source,
                    kind: .unrecognized(reason: "No importable JSON files found.")
                )
            case .importerFailed(_, _, let vaultResult):
                activityLog.record(
                    source: source,
                    kind: .importerFailed(
                        snapshotID: vaultResult.snapshotID,
                        detail: error.failureDetail ?? error.errorDescription ?? "Import failed."
                    )
                )
            case .importStartFailed(_, let vaultResult):
                let detail = error.failureDetail ?? error.errorDescription ?? "Importer failed to start."
                if let vaultResult {
                    activityLog.record(
                        source: source,
                        kind: .importerFailed(snapshotID: vaultResult.snapshotID, detail: detail)
                    )
                } else {
                    activityLog.record(source: source, kind: .failed(detail: detail))
                }
            case .vaultIngestFailed:
                activityLog.record(
                    source: source,
                    kind: .failed(detail: error.failureDetail ?? "Vault ingest failed.")
                )
            }
        } catch {
            activityLog.record(
                source: source,
                kind: .failed(detail: error.localizedDescription)
            )
        }
    }
}

// MARK: - Zip extraction

/// Thin wrapper around `/usr/bin/unzip` that writes into a fresh temp
/// directory. `unzip` ships with macOS and handles every zip format the
/// provider exports currently emit (store + deflate); pulling a third-party
/// zip library just to avoid a subprocess isn't worth the dependency weight.
enum ZipExtraction {
    enum Error: LocalizedError {
        case unzipFailed(exitCode: Int32, stderrTail: String?)

        var errorDescription: String? {
            switch self {
            case .unzipFailed(let code, let tail):
                if let tail, !tail.isEmpty {
                    return "unzip exited \(code): \(tail)"
                }
                return "unzip exited \(code)."
            }
        }
    }

    /// Extract `url` into a newly-created temp directory. The caller owns the
    /// returned URL and is responsible for removing it. Runs the subprocess
    /// on a detached task to keep the main actor responsive while large
    /// exports unpack.
    static func extract(_ url: URL) async throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MadiniIntakeUnzip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let sourcePath = url.path
        let destPath = tempDir.path
        do {
            try await Task.detached(priority: .userInitiated) {
                try runUnzip(archive: sourcePath, destination: destPath)
            }.value
            return tempDir
        } catch {
            try? FileManager.default.removeItem(at: tempDir)
            throw error
        }
    }

    private static func runUnzip(archive: String, destination: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        // -q: quiet, -o: overwrite without prompting (we're unpacking into a
        // fresh temp dir anyway, but this prevents a prompt wedging the
        // subprocess if a future refactor reuses dirs).
        process.arguments = ["-q", "-o", archive, "-d", destination]

        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = Pipe()

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let stderrData = try? stderrPipe.fileHandleForReading.readToEnd()
            let tail = stderrData
                .flatMap { String(data: $0, encoding: .utf8) }?
                .split(separator: "\n")
                .suffix(2)
                .joined(separator: " ")
            throw Error.unzipFailed(
                exitCode: process.terminationStatus,
                stderrTail: tail.flatMap { String($0) }
            )
        }
    }
}
#endif
