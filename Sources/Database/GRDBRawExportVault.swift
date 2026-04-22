import Compression
import CryptoKit
import Foundation
import GRDB
import UniformTypeIdentifiers

final class GRDBRawExportVault: RawExportVault, @unchecked Sendable {
    private struct CandidateFile {
        let url: URL
        let relativePath: String
        let role: String
        let mimeType: String?
    }

    private struct StoredFile: Encodable {
        let relativePath: String
        let blobHash: String
        let sizeBytes: Int64
        let mimeType: String?
        let role: String
        let compression: String
        let storedPath: String
    }

    private struct SnapshotManifest: Encodable {
        let provider: String
        let sourceRoot: String?
        let importedAt: String
        let fileCount: Int
        let originalBytes: Int64
        let storedBytes: Int64
        let files: [StoredFile]
    }

    private struct BlobWrite {
        let hash: String
        let originalSize: Int64
        let storedSize: Int64
        let mimeType: String?
        let compression: String
        let storedPath: String
        let wroteNewBlob: Bool
        let data: Data
    }

    private let dbQueue: DatabaseQueue
    private let fileManager: FileManager

    init(dbQueue: DatabaseQueue, fileManager: FileManager = .default) {
        self.dbQueue = dbQueue
        self.fileManager = fileManager
    }

    func ingest(_ urls: [URL]) async throws -> RawExportVaultResult? {
        let roots = urls.filter { isDirectory($0) }
        let root = roots.first ?? commonParent(for: urls)
        let provider = detectProvider(urls: urls, root: root)
        let candidates = collectFiles(from: urls, root: root)
        guard !candidates.isEmpty else {
            return nil
        }

        try fileManager.createDirectory(at: AppPaths.rawExportBlobsDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: AppPaths.rawExportSnapshotsDir, withIntermediateDirectories: true)

        let importedAt = GRDBProjectDateCodec.string(from: Date())
        var storedFiles: [StoredFile] = []
        var blobWrites: [BlobWrite] = []
        var seenHashes = Set<String>()
        var newBlobCount = 0
        var reusedBlobCount = 0
        var originalBytes: Int64 = 0
        var storedBytes: Int64 = 0

        for candidate in candidates {
            let original = try Data(contentsOf: candidate.url)
            let hash = Self.sha256Hex(original)
            let originalSize = Int64(original.count)
            originalBytes += originalSize

            let prepared = prepareBlobData(original, mimeType: candidate.mimeType, relativePath: candidate.relativePath)
            let storedURL = blobURL(hash: hash, compression: prepared.compression)
            let alreadyAvailable = seenHashes.contains(hash) || fileManager.fileExists(atPath: storedURL.path)
            if !alreadyAvailable {
                try fileManager.createDirectory(
                    at: storedURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try prepared.data.write(to: storedURL, options: .atomic)
                newBlobCount += 1
                storedBytes += Int64(prepared.data.count)
            } else {
                reusedBlobCount += 1
            }
            seenHashes.insert(hash)

            let storedPath = storedURL.path
            blobWrites.append(
                BlobWrite(
                    hash: hash,
                    originalSize: originalSize,
                    storedSize: Int64(prepared.data.count),
                    mimeType: candidate.mimeType,
                    compression: prepared.compression,
                    storedPath: storedPath,
                    wroteNewBlob: !alreadyAvailable,
                    data: prepared.data
                )
            )
            storedFiles.append(
                StoredFile(
                    relativePath: candidate.relativePath,
                    blobHash: hash,
                    sizeBytes: originalSize,
                    mimeType: candidate.mimeType,
                    role: candidate.role,
                    compression: prepared.compression,
                    storedPath: storedPath
                )
            )
        }

        let manifest = SnapshotManifest(
            provider: provider.rawValue,
            sourceRoot: root?.path,
            importedAt: importedAt,
            fileCount: storedFiles.count,
            originalBytes: originalBytes,
            storedBytes: storedBytes,
            files: storedFiles
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let manifestData = try encoder.encode(manifest)
        let manifestHash = Self.sha256Hex(manifestData)
        let manifestURL = AppPaths.rawExportSnapshotsDir
            .appendingPathComponent(provider.rawValue, isDirectory: true)
            .appendingPathComponent("\(safeTimestamp(importedAt))-\(String(manifestHash.prefix(12)))", isDirectory: true)
            .appendingPathComponent("manifest.json")
        try fileManager.createDirectory(at: manifestURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try manifestData.write(to: manifestURL, options: .atomic)

        let snapshotID = try await GRDBAsync.write(to: dbQueue) { db in
            try db.execute(
                sql: """
                    INSERT INTO raw_export_snapshots (
                        provider, source_root, imported_at, manifest_hash, file_count,
                        new_blob_count, reused_blob_count, original_bytes, stored_bytes, manifest_path
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    provider.rawValue,
                    root?.path,
                    importedAt,
                    manifestHash,
                    storedFiles.count,
                    newBlobCount,
                    reusedBlobCount,
                    originalBytes,
                    storedBytes,
                    manifestURL.path
                ]
            )
            let snapshotID = db.lastInsertedRowID

            for (storedFile, blobWrite) in zip(storedFiles, blobWrites) {
                try db.execute(
                    sql: """
                        INSERT INTO raw_export_blobs (
                            hash, size_bytes, stored_size_bytes, mime_type, compression, stored_path, created_at
                        )
                        VALUES (?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(hash) DO NOTHING
                        """,
                    arguments: [
                        blobWrite.hash,
                        blobWrite.originalSize,
                        blobWrite.storedSize,
                        blobWrite.mimeType,
                        blobWrite.compression,
                        blobWrite.storedPath,
                        importedAt
                    ]
                )
                try db.execute(
                    sql: """
                        INSERT INTO raw_export_files (
                            snapshot_id, relative_path, blob_hash, size_bytes, mime_type,
                            role, compression, stored_path, created_at
                        )
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        snapshotID,
                        storedFile.relativePath,
                        storedFile.blobHash,
                        storedFile.sizeBytes,
                        storedFile.mimeType,
                        storedFile.role,
                        storedFile.compression,
                        storedFile.storedPath,
                        importedAt
                    ]
                )
            }

            return snapshotID
        }

        return RawExportVaultResult(
            provider: provider,
            snapshotID: snapshotID,
            totalFiles: storedFiles.count,
            newBlobs: newBlobCount,
            reusedBlobs: reusedBlobCount,
            originalBytes: originalBytes,
            storedBytes: storedBytes,
            manifestURL: manifestURL
        )
    }

    private func collectFiles(from urls: [URL], root: URL?) -> [CandidateFile] {
        var result: [CandidateFile] = []
        var seen = Set<String>()
        for url in urls {
            let files: [URL]
            if isDirectory(url) {
                files = recursiveFiles(in: url)
            } else {
                files = [url]
            }

            for file in files where !isHidden(file) {
                let key = file.standardizedFileURL.path
                guard seen.insert(key).inserted else {
                    continue
                }
                let relativePath = relativePath(for: file, root: root)
                result.append(
                    CandidateFile(
                        url: file,
                        relativePath: relativePath,
                        role: role(for: relativePath),
                        mimeType: mimeType(for: file)
                    )
                )
            }
        }
        return result.sorted {
            $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
        }
    }

    private func recursiveFiles(in directory: URL) -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return enumerator.compactMap { item -> URL? in
            guard let url = item as? URL, isRegularFile(url) else {
                return nil
            }
            return url
        }
    }

    private func detectProvider(urls: [URL], root: URL?) -> RawExportProvider {
        if let root {
            if !chatGPTConversationChunks(in: root).isEmpty
                || fileManager.fileExists(atPath: root.appendingPathComponent("export_manifest.json").path) {
                return .chatGPT
            }
            if fileManager.fileExists(atPath: root.appendingPathComponent("conversations.json").path)
                && fileManager.fileExists(atPath: root.appendingPathComponent("projects.json").path) {
                return .claude
            }
            if !geminiActivityFiles(in: root).isEmpty {
                return .gemini
            }
        }

        for url in urls where url.pathExtension.lowercased() == "json" {
            if let provider = providerFromJSONHeader(url) {
                return provider
            }
        }
        return .unknown
    }

    private func providerFromJSONHeader(_ url: URL) -> RawExportProvider? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data),
              let list = object as? [[String: Any]],
              let first = list.first else {
            return nil
        }
        if first["mapping"] != nil {
            return .chatGPT
        }
        if first["chat_messages"] != nil {
            return .claude
        }
        if first["time"] != nil, first["title"] != nil {
            return .gemini
        }
        return nil
    }

    private func prepareBlobData(
        _ original: Data,
        mimeType: String?,
        relativePath: String
    ) -> (data: Data, compression: String) {
        guard shouldCompress(mimeType: mimeType, relativePath: relativePath, byteCount: original.count),
              let compressed = lzfseCompressed(original),
              compressed.count < Int(Double(original.count) * 0.92) else {
            return (original, "none")
        }
        return (compressed, "lzfse")
    }

    private func shouldCompress(mimeType: String?, relativePath: String, byteCount: Int) -> Bool {
        guard byteCount >= 4_096 else {
            return false
        }
        if let mimeType {
            return mimeType.hasPrefix("text/")
                || mimeType == "application/json"
                || mimeType == "application/xml"
                || mimeType == "application/javascript"
        }
        let lower = relativePath.lowercased()
        return lower.hasSuffix(".json")
            || lower.hasSuffix(".html")
            || lower.hasSuffix(".md")
            || lower.hasSuffix(".txt")
            || lower.hasSuffix(".csv")
            || lower.hasSuffix(".xml")
    }

    private func lzfseCompressed(_ data: Data) -> Data? {
        let destinationCapacity = max(1_024, data.count + 1_024)
        return data.withUnsafeBytes { sourceBuffer in
            guard let sourcePointer = sourceBuffer.bindMemory(to: UInt8.self).baseAddress else {
                return nil
            }
            return Data(count: destinationCapacity).withUnsafeBytes { _ in
                var output = Data(count: destinationCapacity)
                let written = output.withUnsafeMutableBytes { destinationBuffer in
                    guard let destinationPointer = destinationBuffer.bindMemory(to: UInt8.self).baseAddress else {
                        return 0
                    }
                    return compression_encode_buffer(
                        destinationPointer,
                        destinationCapacity,
                        sourcePointer,
                        data.count,
                        nil,
                        COMPRESSION_LZFSE
                    )
                }
                guard written > 0 else {
                    return nil
                }
                output.removeSubrange(written..<output.count)
                return output
            }
        }
    }

    private func blobURL(hash: String, compression: String) -> URL {
        AppPaths.rawExportBlobsDir
            .appendingPathComponent(String(hash.prefix(2)), isDirectory: true)
            .appendingPathComponent("\(hash).\(compression == "lzfse" ? "lzfse" : "blob")")
    }

    private func role(for relativePath: String) -> String {
        let name = URL(fileURLWithPath: relativePath).lastPathComponent.lowercased()
        if name == "export_manifest.json" || name == "manifest.json" {
            return "manifest"
        }
        if (name.hasPrefix("conversations-") && name.hasSuffix(".json"))
            || name == "conversations.json"
            || name.contains("マイアクティビティ") {
            return "conversation"
        }
        if ["projects.json", "users.json", "user.json", "user_settings.json", "memories.json"].contains(name) {
            return "metadata"
        }
        if let mimeType = mimeType(forExtension: URL(fileURLWithPath: relativePath).pathExtension),
           mimeType.hasPrefix("image/") || mimeType == "application/pdf" {
            return "asset"
        }
        return "other"
    }

    private func mimeType(for url: URL) -> String? {
        mimeType(forExtension: url.pathExtension)
    }

    private func mimeType(forExtension pathExtension: String) -> String? {
        guard !pathExtension.isEmpty else {
            return nil
        }
        return UTType(filenameExtension: pathExtension)?.preferredMIMEType
    }

    private func relativePath(for file: URL, root: URL?) -> String {
        guard let root else {
            return file.lastPathComponent
        }
        let rootPath = root.standardizedFileURL.path
        let filePath = file.standardizedFileURL.path
        guard filePath.hasPrefix(rootPath) else {
            return file.lastPathComponent
        }
        let offset = filePath.index(filePath.startIndex, offsetBy: rootPath.count)
        return String(filePath[offset...])
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func commonParent(for urls: [URL]) -> URL? {
        guard let first = urls.first else {
            return nil
        }
        if urls.count == 1 {
            return isDirectory(first) ? first : first.deletingLastPathComponent()
        }
        let parents = urls.map { isDirectory($0) ? $0 : $0.deletingLastPathComponent() }
        return parents.dropFirst().allSatisfy { $0.standardizedFileURL.path == parents[0].standardizedFileURL.path }
            ? parents[0]
            : nil
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private func isRegularFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }

    private func isHidden(_ url: URL) -> Bool {
        url.lastPathComponent.hasPrefix(".")
    }

    private func chatGPTConversationChunks(in directory: URL) -> [URL] {
        directoryChildren(in: directory).filter { url in
            let name = url.lastPathComponent
            return name.hasPrefix("conversations-") && name.hasSuffix(".json")
        }
    }

    private func geminiActivityFiles(in directory: URL) -> [URL] {
        recursiveFiles(in: directory).filter { url in
            guard url.pathExtension.lowercased() == "json",
                  let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                  let text = String(data: data.prefix(65_536), encoding: .utf8) else {
                return false
            }
            return text.contains("\"header\"")
                && text.contains("Gemini")
                && text.contains("\"time\"")
                && text.contains("\"title\"")
        }
    }

    private func directoryChildren(in directory: URL) -> [URL] {
        (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
    }

    private func safeTimestamp(_ value: String) -> String {
        value.replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: " ", with: "T")
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
