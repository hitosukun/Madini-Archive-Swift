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
        let basename = URL(fileURLWithPath: normalized).lastPathComponent

        return try await GRDBAsync.read(from: dbQueue) { db in
            guard try Self.snapshotExists(snapshotID: snapshotID, in: db) else {
                throw RawExportVaultError.snapshotNotFound(snapshotID: snapshotID)
            }

            let row = try Row.fetchOne(
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
                      AND (
                            l.asset_relative_path = ? COLLATE NOCASE
                         OR l.asset_relative_path LIKE ? COLLATE NOCASE
                      )
                    ORDER BY
                        CASE WHEN l.asset_relative_path = ? COLLATE NOCASE THEN 0 ELSE 1 END,
                        l.asset_relative_path ASC
                    LIMIT 1
                    """,
                arguments: [
                    snapshotID,
                    normalized,
                    "%/\(basename)",
                    normalized
                ]
            )
            return row.map(Self.assetHit(from:))
        }
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
