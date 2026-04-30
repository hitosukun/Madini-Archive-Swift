import Foundation
import GRDB

final class GRDBRawAssetResolver: RawAssetResolver, @unchecked Sendable {
    private let dbQueue: DatabaseQueue

    init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    func resolveAsset(
        snapshotID: Int64,
        reference: String
    ) async throws -> RawAssetHit? {
        let normalized = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return nil
        }
        // Strip provider-specific URL schemes so prefix-based matching
        // can compare ID-only references (what shows up in the JSON)
        // against vault-side file paths that carry an extension and
        // a disambiguation suffix. ChatGPT's modern exports use
        // `sediment://file_ABC`; older ones used
        // `file-service://file-ABC`. Neither prefix appears in the
        // `asset_relative_path` column, but the opaque ID after
        // `://` is always the stem that the vaulted file name starts
        // with. Preserving `normalized` separately means the `= ?`
        // equality check still catches exports where the full URL
        // somehow did make it into the path.
        let schemeStripped = Self.stripAssetScheme(normalized)
        let basename = URL(fileURLWithPath: schemeStripped).lastPathComponent
        let idOnly = Self.stripExtension(basename)
        // Only activate the `idOnly-%` / `idOnly.%` patterns when the
        // reference carried a scheme — otherwise a plain user input
        // like "photo" could LIKE-match every `photo-*.jpg` in the
        // vault. With a scheme present (`sediment://…`), the tail is
        // an opaque content ID and prefix-matching is safe.
        let useOpaqueIDMatch = normalized.contains("://") && !idOnly.isEmpty

        return try await GRDBAsync.read(from: dbQueue) { db in
            guard try Self.snapshotExists(snapshotID: snapshotID, in: db) else {
                throw RawExportVaultError.snapshotNotFound(snapshotID: snapshotID)
            }

            if let hit = try Self.fetchLinkedAsset(
                db: db,
                snapshotID: snapshotID,
                normalized: normalized,
                basename: basename,
                idOnly: idOnly,
                useOpaqueIDMatch: useOpaqueIDMatch
            ) {
                return hit
            }

            // Fallback: some references (notably ChatGPT's
            // `sediment://` image pointers) never reach the
            // `raw_export_asset_links` table because the import-time
            // linker's regex requires an extension in the document
            // text, which these pointers lack. When the file itself
            // is still vaulted with role='asset', match it directly
            // via `raw_export_files` on the opaque ID prefix. We
            // synthesize a best-effort `source_relative_path` by
            // picking any link row that points at the same blob, or
            // leaving it empty — downstream callers only need the
            // blob hash + metadata to render the image.
            if useOpaqueIDMatch {
                return try Self.fetchUnlinkedAsset(
                    db: db,
                    snapshotID: snapshotID,
                    idOnly: idOnly
                )
            }
            return nil
        }
    }

    /// Primary lookup against `raw_export_asset_links`, which is what
    /// the Vault browser / raw transcript view prefers because the
    /// `source_relative_path` it returns ties the hit back to the
    /// document that referenced it.
    private static func fetchLinkedAsset(
        db: Database,
        snapshotID: Int64,
        normalized: String,
        basename: String,
        idOnly: String,
        useOpaqueIDMatch: Bool
    ) throws -> RawAssetHit? {
        // Build the WHERE clauses + bound arguments together so the
        // ordering-preference CASE at the bottom can reference the
        // same `normalized` parameter without re-binding it.
        var clauses: [String] = [
            "l.asset_relative_path = ? COLLATE NOCASE",
            "l.asset_relative_path LIKE ? COLLATE NOCASE"
        ]
        var arguments: [any DatabaseValueConvertible] = [
            snapshotID,
            normalized,
            "%/\(basename)"
        ]
        if useOpaqueIDMatch {
            // Opaque-ID match: stored names look like
            // `file_ABC-<uuid>.jpeg` or `dalle-generations/file-ABC-<uuid>.webp`.
            // We match both the bare-root (`idOnly-%` / `idOnly.%`)
            // and subdirectory (`%/idOnly-%` / `%/idOnly.%`) shapes.
            clauses.append(contentsOf: [
                "l.asset_relative_path LIKE ? COLLATE NOCASE",
                "l.asset_relative_path LIKE ? COLLATE NOCASE",
                "l.asset_relative_path LIKE ? COLLATE NOCASE",
                "l.asset_relative_path LIKE ? COLLATE NOCASE"
            ])
            arguments.append(contentsOf: [
                "\(idOnly)-%",
                "\(idOnly).%",
                "%/\(idOnly)-%",
                "%/\(idOnly).%"
            ])
        }

        let sql = """
            SELECT
                l.snapshot_id AS snapshot_id,
                l.source_relative_path AS source_relative_path,
                l.asset_relative_path AS asset_relative_path,
                l.blob_hash AS blob_hash,
                l.kind AS kind,
                f.size_bytes AS size_bytes,
                b.stored_size_bytes AS stored_size_bytes,
                f.mime_type AS mime_type,
                f.compression AS compression
            FROM raw_export_asset_links AS l
            JOIN raw_export_files AS f
              ON f.snapshot_id = l.snapshot_id
             AND f.relative_path = l.asset_relative_path
            LEFT JOIN raw_export_blobs AS b ON b.hash = l.blob_hash
            WHERE l.snapshot_id = ?
              AND (\(clauses.joined(separator: " OR ")))
            ORDER BY
                CASE WHEN l.asset_relative_path = ? COLLATE NOCASE THEN 0 ELSE 1 END,
                l.asset_relative_path ASC
            LIMIT 1
            """
        arguments.append(normalized)

        let row = try Row.fetchOne(
            db,
            sql: sql,
            arguments: StatementArguments(arguments)
        )
        return row.map(Self.assetHit(from:))
    }

    /// Direct `raw_export_files` lookup for `role = 'asset'` rows
    /// whose name starts with the opaque ID. Used as a fallback when
    /// the link table doesn't know about this reference (typically a
    /// `sediment://` image pointer in a conversation JSON — the
    /// import-time linker's regex only fires on references that
    /// carry an explicit extension).
    private static func fetchUnlinkedAsset(
        db: Database,
        snapshotID: Int64,
        idOnly: String
    ) throws -> RawAssetHit? {
        let row = try Row.fetchOne(
            db,
            sql: """
                SELECT
                    f.snapshot_id AS snapshot_id,
                    '' AS source_relative_path,
                    f.relative_path AS asset_relative_path,
                    f.blob_hash AS blob_hash,
                    'reference' AS kind,
                    f.size_bytes AS size_bytes,
                    b.stored_size_bytes AS stored_size_bytes,
                    f.mime_type AS mime_type,
                    f.compression AS compression
                FROM raw_export_files AS f
                LEFT JOIN raw_export_blobs AS b ON b.hash = f.blob_hash
                WHERE f.snapshot_id = ?
                  AND f.role = 'asset'
                  AND (
                    f.relative_path LIKE ? COLLATE NOCASE
                    OR f.relative_path LIKE ? COLLATE NOCASE
                    OR f.relative_path LIKE ? COLLATE NOCASE
                    OR f.relative_path LIKE ? COLLATE NOCASE
                  )
                ORDER BY f.relative_path ASC
                LIMIT 1
                """,
            arguments: [
                snapshotID,
                "\(idOnly)-%",
                "\(idOnly).%",
                "%/\(idOnly)-%",
                "%/\(idOnly).%"
            ]
        )
        return row.map(Self.assetHit(from:))
    }

    private static func stripAssetScheme(_ s: String) -> String {
        if let range = s.range(of: "://") {
            return String(s[range.upperBound...])
        }
        return s
    }

    private static func stripExtension(_ s: String) -> String {
        // Keep the leading character even if the string starts with
        // `.` (unlikely here, but a hidden-file convention elsewhere
        // in the codebase — being defensive keeps this helper safe
        // to reuse).
        guard let dot = s.lastIndex(of: "."), dot != s.startIndex else { return s }
        return String(s[..<dot])
    }

    func assetsReferencedBy(
        snapshotID: Int64,
        sourceRelativePath: String,
        offset: Int,
        limit: Int
    ) async throws -> [RawAssetHit] {
        let boundedLimit = max(0, min(limit, 500))
        let boundedOffset = max(0, offset)

        return try await GRDBAsync.read(from: dbQueue) { db in
            guard try Self.snapshotExists(snapshotID: snapshotID, in: db) else {
                throw RawExportVaultError.snapshotNotFound(snapshotID: snapshotID)
            }
            guard boundedLimit > 0 else {
                return []
            }

            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT
                        l.snapshot_id AS snapshot_id,
                        l.source_relative_path AS source_relative_path,
                        l.asset_relative_path AS asset_relative_path,
                        l.blob_hash AS blob_hash,
                        l.kind AS kind,
                        f.size_bytes AS size_bytes,
                        b.stored_size_bytes AS stored_size_bytes,
                        f.mime_type AS mime_type,
                        f.compression AS compression
                    FROM raw_export_asset_links AS l
                    JOIN raw_export_files AS f
                      ON f.snapshot_id = l.snapshot_id
                     AND f.relative_path = l.asset_relative_path
                    LEFT JOIN raw_export_blobs AS b ON b.hash = l.blob_hash
                    WHERE l.snapshot_id = ?
                      AND l.source_relative_path = ?
                    ORDER BY l.asset_relative_path ASC
                    LIMIT ? OFFSET ?
                    """,
                arguments: [
                    snapshotID,
                    sourceRelativePath,
                    boundedLimit,
                    boundedOffset
                ]
            )
            return rows.map(Self.assetHit(from:))
        }
    }

    private static func snapshotExists(snapshotID: Int64, in db: Database) throws -> Bool {
        try Bool.fetchOne(
            db,
            sql: "SELECT EXISTS(SELECT 1 FROM raw_export_snapshots WHERE id = ?)",
            arguments: [snapshotID]
        ) ?? false
    }

    private static func assetHit(from row: Row) -> RawAssetHit {
        let sizeBytes: Int64 = row["size_bytes"]
        return RawAssetHit(
            snapshotID: row["snapshot_id"],
            sourceRelativePath: row["source_relative_path"],
            assetRelativePath: row["asset_relative_path"],
            blobHash: row["blob_hash"],
            kind: row["kind"],
            sizeBytes: sizeBytes,
            storedSizeBytes: row["stored_size_bytes"] ?? sizeBytes,
            mimeType: row["mime_type"],
            compression: row["compression"]
        )
    }
}
