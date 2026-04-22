import Compression
import CryptoKit
import Foundation
import GRDB
import UniformTypeIdentifiers

final class GRDBRawExportVault: RawExportVault, @unchecked Sendable {
    /// Filesystem layout for blob & manifest storage. Split out so tests can
    /// redirect the vault to a temporary directory without touching
    /// `~/Library/Application Support/Madini Archive`.
    struct Storage: Sendable {
        let blobsDir: URL
        let snapshotsDir: URL

        static var `default`: Storage {
            Storage(
                blobsDir: AppPaths.rawExportBlobsDir,
                snapshotsDir: AppPaths.rawExportSnapshotsDir
            )
        }
    }

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

    private struct IndexedDocument {
        let blobHash: String
        let provider: RawExportProvider
        let relativePath: String
        let content: String
    }

    private struct AssetLink {
        let sourceRelativePath: String
        let assetRelativePath: String
        let blobHash: String
        let kind: String
    }

    private let dbQueue: DatabaseQueue
    private let storage: Storage
    private let fileManager: FileManager

    init(
        dbQueue: DatabaseQueue,
        storage: Storage = .default,
        fileManager: FileManager = .default
    ) {
        self.dbQueue = dbQueue
        self.storage = storage
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

        try fileManager.createDirectory(at: storage.blobsDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: storage.snapshotsDir, withIntermediateDirectories: true)

        let importedAt = GRDBProjectDateCodec.string(from: Date())
        var storedFiles: [StoredFile] = []
        var blobWrites: [BlobWrite] = []
        var indexedDocuments: [IndexedDocument] = []
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
            if let searchable = searchableText(from: original, candidate: candidate) {
                indexedDocuments.append(
                    IndexedDocument(
                        blobHash: hash,
                        provider: provider,
                        relativePath: candidate.relativePath,
                        content: searchable
                    )
                )
            }

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
        let manifestURL = storage.snapshotsDir
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

            for indexedDocument in indexedDocuments {
                try db.execute(
                    sql: """
                        INSERT INTO raw_export_search_idx (
                            snapshot_id, blob_hash, provider, relative_path, content
                        )
                        VALUES (?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        snapshotID,
                        indexedDocument.blobHash,
                        indexedDocument.provider.rawValue,
                        indexedDocument.relativePath,
                        indexedDocument.content
                    ]
                )
            }

            let assetLinks = self.assetLinks(
                snapshotFiles: storedFiles,
                indexedDocuments: indexedDocuments
            )
            for assetLink in assetLinks {
                try db.execute(
                    sql: """
                        INSERT OR IGNORE INTO raw_export_asset_links (
                            snapshot_id, source_relative_path, asset_relative_path,
                            blob_hash, kind, created_at
                        )
                        VALUES (?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        snapshotID,
                        assetLink.sourceRelativePath,
                        assetLink.assetRelativePath,
                        assetLink.blobHash,
                        assetLink.kind,
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

    func listSnapshots(offset: Int, limit: Int) async throws -> [RawExportSnapshotSummary] {
        let boundedLimit = max(0, min(limit, 500))
        let boundedOffset = max(0, offset)
        guard boundedLimit > 0 else {
            return []
        }

        return try await GRDBAsync.read(from: dbQueue) { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT
                        id, provider, source_root, imported_at, manifest_hash, file_count,
                        new_blob_count, reused_blob_count, original_bytes, stored_bytes, manifest_path
                    FROM raw_export_snapshots
                    ORDER BY imported_at DESC, id DESC
                    LIMIT ? OFFSET ?
                    """,
                arguments: [boundedLimit, boundedOffset]
            )

            return rows.map { row in
                RawExportSnapshotSummary(
                    id: row["id"],
                    provider: RawExportProvider(rawValue: row["provider"] ?? "") ?? .unknown,
                    sourceRoot: row["source_root"],
                    importedAt: row["imported_at"],
                    manifestHash: row["manifest_hash"],
                    fileCount: row["file_count"],
                    newBlobCount: row["new_blob_count"],
                    reusedBlobCount: row["reused_blob_count"],
                    originalBytes: row["original_bytes"],
                    storedBytes: row["stored_bytes"],
                    manifestPath: row["manifest_path"]
                )
            }
        }
    }

    func search(
        query: String,
        provider: RawExportProvider?,
        offset: Int,
        limit: Int
    ) async throws -> [RawExportSearchResult] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let boundedLimit = max(0, min(limit, 200))
        let boundedOffset = max(0, offset)
        guard !normalized.isEmpty, boundedLimit > 0 else {
            return []
        }

        return try await GRDBAsync.read(from: dbQueue) { db in
            var filters = ["raw_export_search_idx MATCH ?"]
            var arguments = StatementArguments()
            arguments += [Self.makeMatchQuery(from: normalized)]

            if let provider {
                filters.append("provider = ?")
                arguments += [provider.rawValue]
            }

            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT
                        snapshot_id,
                        blob_hash,
                        provider,
                        relative_path,
                        snippet(raw_export_search_idx, 4, '[', ']', ' … ', 16) AS snippet,
                        bm25(raw_export_search_idx) AS rank
                    FROM raw_export_search_idx
                    WHERE \(filters.joined(separator: " AND "))
                    ORDER BY rank ASC, snapshot_id DESC, relative_path ASC
                    LIMIT ? OFFSET ?
                    """,
                arguments: arguments + [boundedLimit, boundedOffset]
            )

            return rows.map { row in
                RawExportSearchResult(
                    snapshotID: row["snapshot_id"],
                    blobHash: row["blob_hash"],
                    provider: RawExportProvider(rawValue: row["provider"] ?? "") ?? .unknown,
                    relativePath: row["relative_path"],
                    snippet: row["snippet"] ?? ""
                )
            }
        }
    }

    // MARK: - Restore API

    func getSnapshot(id: Int64) async throws -> RawExportSnapshotSummary? {
        try await GRDBAsync.read(from: dbQueue) { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT
                        id, provider, source_root, imported_at, manifest_hash, file_count,
                        new_blob_count, reused_blob_count, original_bytes, stored_bytes, manifest_path
                    FROM raw_export_snapshots
                    WHERE id = ?
                    """,
                arguments: [id]
            ) else {
                return nil
            }
            return RawExportSnapshotSummary(
                id: row["id"],
                provider: RawExportProvider(rawValue: row["provider"] ?? "") ?? .unknown,
                sourceRoot: row["source_root"],
                importedAt: row["imported_at"],
                manifestHash: row["manifest_hash"],
                fileCount: row["file_count"],
                newBlobCount: row["new_blob_count"],
                reusedBlobCount: row["reused_blob_count"],
                originalBytes: row["original_bytes"],
                storedBytes: row["stored_bytes"],
                manifestPath: row["manifest_path"]
            )
        }
    }

    func listFiles(
        snapshotID: Int64,
        offset: Int,
        limit: Int
    ) async throws -> [RawExportFileEntry] {
        let boundedLimit = max(0, min(limit, 5_000))
        let boundedOffset = max(0, offset)
        guard boundedLimit > 0 else {
            return []
        }

        return try await GRDBAsync.read(from: dbQueue) { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT
                        f.snapshot_id    AS snapshot_id,
                        f.relative_path  AS relative_path,
                        f.blob_hash      AS blob_hash,
                        f.size_bytes     AS size_bytes,
                        b.stored_size_bytes AS stored_size_bytes,
                        f.mime_type      AS mime_type,
                        f.role           AS role,
                        f.compression    AS compression,
                        f.stored_path    AS stored_path
                    FROM raw_export_files AS f
                    LEFT JOIN raw_export_blobs AS b ON b.hash = f.blob_hash
                    WHERE f.snapshot_id = ?
                    ORDER BY f.relative_path ASC
                    LIMIT ? OFFSET ?
                    """,
                arguments: [snapshotID, boundedLimit, boundedOffset]
            )
            return rows.map(Self.fileEntry(from:))
        }
    }

    func loadBlob(hash: String) async throws -> Data {
        let record = try await fetchBlobRecord(hash: hash)
        let storedURL = URL(fileURLWithPath: record.storedPath)

        guard fileManager.fileExists(atPath: storedURL.path) else {
            throw RawExportVaultError.blobFileMissing(hash: hash, path: storedURL.path)
        }

        let storedData: Data
        do {
            storedData = try Data(contentsOf: storedURL)
        } catch {
            throw RawExportVaultError.blobFileMissing(hash: hash, path: storedURL.path)
        }

        let bytes: Data
        switch record.compression {
        case "none":
            bytes = storedData
        case "lzfse":
            guard let decompressed = Self.lzfseDecompressed(
                storedData,
                expectedSize: Int(clamping: record.sizeBytes)
            ) else {
                throw RawExportVaultError.decompressionFailed(hash: hash)
            }
            bytes = decompressed
        default:
            throw RawExportVaultError.unsupportedCompression(record.compression)
        }

        let actual = Self.sha256Hex(bytes)
        guard actual == hash else {
            throw RawExportVaultError.hashMismatch(expected: hash, actual: actual)
        }
        return bytes
    }

    func loadFile(
        snapshotID: Int64,
        relativePath: String
    ) async throws -> RawExportFilePayload {
        let entry = try await fetchFileEntry(snapshotID: snapshotID, relativePath: relativePath)
        let data = try await loadBlob(hash: entry.blobHash)
        return RawExportFilePayload(entry: entry, data: data)
    }

    // MARK: - Restore helpers

    private struct BlobRecord {
        let hash: String
        let sizeBytes: Int64
        let storedSizeBytes: Int64
        let compression: String
        let storedPath: String
    }

    private func fetchBlobRecord(hash: String) async throws -> BlobRecord {
        try await GRDBAsync.read(from: dbQueue) { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT hash, size_bytes, stored_size_bytes, compression, stored_path
                    FROM raw_export_blobs
                    WHERE hash = ?
                    """,
                arguments: [hash]
            ) else {
                throw RawExportVaultError.blobNotFound(hash: hash)
            }
            return BlobRecord(
                hash: row["hash"],
                sizeBytes: row["size_bytes"],
                storedSizeBytes: row["stored_size_bytes"],
                compression: row["compression"],
                storedPath: row["stored_path"]
            )
        }
    }

    private func fetchFileEntry(
        snapshotID: Int64,
        relativePath: String
    ) async throws -> RawExportFileEntry {
        try await GRDBAsync.read(from: dbQueue) { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT
                        f.snapshot_id    AS snapshot_id,
                        f.relative_path  AS relative_path,
                        f.blob_hash      AS blob_hash,
                        f.size_bytes     AS size_bytes,
                        b.stored_size_bytes AS stored_size_bytes,
                        f.mime_type      AS mime_type,
                        f.role           AS role,
                        f.compression    AS compression,
                        f.stored_path    AS stored_path
                    FROM raw_export_files AS f
                    LEFT JOIN raw_export_blobs AS b ON b.hash = f.blob_hash
                    WHERE f.snapshot_id = ? AND f.relative_path = ?
                    """,
                arguments: [snapshotID, relativePath]
            ) else {
                throw RawExportVaultError.fileNotFound(
                    snapshotID: snapshotID,
                    relativePath: relativePath
                )
            }
            return Self.fileEntry(from: row)
        }
    }

    private static func fileEntry(from row: Row) -> RawExportFileEntry {
        let sizeBytes: Int64 = row["size_bytes"]
        let storedSizeBytes: Int64 = row["stored_size_bytes"] ?? sizeBytes
        return RawExportFileEntry(
            snapshotID: row["snapshot_id"],
            relativePath: row["relative_path"],
            blobHash: row["blob_hash"],
            sizeBytes: sizeBytes,
            storedSizeBytes: storedSizeBytes,
            mimeType: row["mime_type"],
            role: row["role"],
            compression: row["compression"],
            storedPath: row["stored_path"]
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
        RawExportProviderDetector.detect(urls: urls, root: root, fileManager: fileManager)
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

    private func searchableText(from original: Data, candidate: CandidateFile) -> String? {
        guard shouldIndex(candidate: candidate, byteCount: original.count),
              let text = String(data: original, encoding: .utf8) else {
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func shouldIndex(candidate: CandidateFile, byteCount: Int) -> Bool {
        switch candidate.role {
        case "conversation", "metadata", "manifest":
            return byteCount <= 200_000_000
        default:
            break
        }

        guard byteCount <= 20_000_000 else {
            return false
        }
        if let mimeType = candidate.mimeType, mimeType.hasPrefix("text/") {
            return true
        }
        let lower = candidate.relativePath.lowercased()
        return lower.hasSuffix(".md")
            || lower.hasSuffix(".txt")
            || lower.hasSuffix(".csv")
            || lower.hasSuffix(".xml")
    }

    private func assetLinks(
        snapshotFiles: [StoredFile],
        indexedDocuments: [IndexedDocument]
    ) -> [AssetLink] {
        let assetsByName = Dictionary(
            grouping: snapshotFiles.filter { $0.role == "asset" },
            by: { URL(fileURLWithPath: $0.relativePath).lastPathComponent.lowercased() }
        )
        guard !assetsByName.isEmpty else {
            return []
        }

        var links: [AssetLink] = []
        var seen = Set<String>()
        for document in indexedDocuments where document.content.count <= 20_000_000 {
            for name in referencedAssetNames(in: document.content) {
                guard let assets = assetsByName[name] else {
                    continue
                }
                for asset in assets {
                    let key = "\(document.relativePath)\u{0}\(asset.relativePath)"
                    guard seen.insert(key).inserted else {
                        continue
                    }
                    links.append(
                        AssetLink(
                            sourceRelativePath: document.relativePath,
                            assetRelativePath: asset.relativePath,
                            blobHash: asset.blobHash,
                            kind: "reference"
                        )
                    )
                }
            }
        }
        return links
    }

    private func referencedAssetNames(in text: String) -> Set<String> {
        let pattern = #"[A-Za-z0-9._%+\-]+(?:\.(?:png|jpe?g|gif|webp|heic|pdf|mp4|mov|webm))"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, options: [], range: range)
        return Set(matches.compactMap { match in
            guard let matchRange = Range(match.range, in: text) else {
                return nil
            }
            return URL(fileURLWithPath: String(text[matchRange])).lastPathComponent.lowercased()
        })
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

    private static func lzfseDecompressed(_ data: Data, expectedSize: Int) -> Data? {
        // Start with a buffer sized for the expected payload; retry with a
        // doubled buffer if the runtime can't fit the output (some pathological
        // LZFSE streams expand temporarily during decode). Cap retries so a
        // corrupt blob can't trigger unbounded allocation.
        let minimumCapacity = max(4_096, expectedSize + 1_024)
        var capacity = minimumCapacity
        for _ in 0..<4 {
            if let result = decodeLZFSE(data, capacity: capacity), result.count == expectedSize {
                return result
            }
            capacity *= 2
        }
        return nil
    }

    private static func decodeLZFSE(_ data: Data, capacity: Int) -> Data? {
        data.withUnsafeBytes { sourceBuffer -> Data? in
            guard let sourcePointer = sourceBuffer.bindMemory(to: UInt8.self).baseAddress else {
                return nil
            }
            var output = Data(count: capacity)
            let written = output.withUnsafeMutableBytes { destinationBuffer -> Int in
                guard let destinationPointer = destinationBuffer.bindMemory(to: UInt8.self).baseAddress else {
                    return 0
                }
                return compression_decode_buffer(
                    destinationPointer,
                    capacity,
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
        storage.blobsDir
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

    private func safeTimestamp(_ value: String) -> String {
        value.replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: " ", with: "T")
    }

    private static func makeMatchQuery(from rawValue: String) -> String {
        let tokens = rawValue
            .split(whereSeparator: \.isWhitespace)
            .map { token in
                token.replacingOccurrences(of: "\"", with: "\"\"")
            }
            .filter { !$0.isEmpty }

        if tokens.isEmpty {
            return "\"\(rawValue.replacingOccurrences(of: "\"", with: "\"\""))\""
        }

        return tokens
            .map { "\"\($0)\"" }
            .joined(separator: " AND ")
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    // MARK: - Schema

    /// Install the 5 Vault tables (+ indexes) onto the given database.
    /// Idempotent — all statements use `IF NOT EXISTS` so it can be replayed
    /// after partial setup. `AppServices.bootstrapViewLayerSchema` calls this
    /// during app startup; tests call it directly against a scratch queue.
    static func installSchema(in db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS raw_export_snapshots (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                provider TEXT NOT NULL,
                source_root TEXT,
                imported_at TEXT NOT NULL,
                manifest_hash TEXT NOT NULL,
                file_count INTEGER NOT NULL,
                new_blob_count INTEGER NOT NULL,
                reused_blob_count INTEGER NOT NULL,
                original_bytes INTEGER NOT NULL,
                stored_bytes INTEGER NOT NULL,
                manifest_path TEXT NOT NULL
            )
            """)
        try db.execute(sql: """
            CREATE INDEX IF NOT EXISTS idx_raw_export_snapshots_provider_time
            ON raw_export_snapshots(provider, imported_at DESC, id DESC)
            """)
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS raw_export_blobs (
                hash TEXT PRIMARY KEY,
                size_bytes INTEGER NOT NULL,
                stored_size_bytes INTEGER NOT NULL,
                mime_type TEXT,
                compression TEXT NOT NULL,
                stored_path TEXT NOT NULL,
                created_at TEXT NOT NULL
            )
            """)
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS raw_export_files (
                snapshot_id INTEGER NOT NULL,
                relative_path TEXT NOT NULL,
                blob_hash TEXT NOT NULL,
                size_bytes INTEGER NOT NULL,
                mime_type TEXT,
                role TEXT NOT NULL,
                compression TEXT NOT NULL,
                stored_path TEXT NOT NULL,
                created_at TEXT NOT NULL,
                PRIMARY KEY (snapshot_id, relative_path),
                FOREIGN KEY(snapshot_id) REFERENCES raw_export_snapshots(id) ON DELETE CASCADE,
                FOREIGN KEY(blob_hash) REFERENCES raw_export_blobs(hash)
            )
            """)
        try db.execute(sql: """
            CREATE INDEX IF NOT EXISTS idx_raw_export_files_blob
            ON raw_export_files(blob_hash)
            """)
        try db.execute(sql: """
            CREATE VIRTUAL TABLE IF NOT EXISTS raw_export_search_idx
            USING fts5(
                snapshot_id UNINDEXED,
                blob_hash UNINDEXED,
                provider UNINDEXED,
                relative_path,
                content,
                tokenize="unicode61"
            )
            """)
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS raw_export_asset_links (
                snapshot_id INTEGER NOT NULL,
                source_relative_path TEXT NOT NULL,
                asset_relative_path TEXT NOT NULL,
                blob_hash TEXT,
                kind TEXT NOT NULL,
                created_at TEXT NOT NULL,
                PRIMARY KEY (snapshot_id, source_relative_path, asset_relative_path),
                FOREIGN KEY(snapshot_id) REFERENCES raw_export_snapshots(id) ON DELETE CASCADE
            )
            """)
        try db.execute(sql: """
            CREATE INDEX IF NOT EXISTS idx_raw_export_asset_links_asset
            ON raw_export_asset_links(snapshot_id, asset_relative_path)
            """)
    }
}
