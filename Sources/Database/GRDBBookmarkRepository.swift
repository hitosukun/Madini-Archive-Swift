import Foundation
import GRDB

final class GRDBBookmarkRepository: BookmarkRepository, @unchecked Sendable {
    private let dbQueue: DatabaseQueue

    init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    func setBookmark(target: BookmarkTarget, bookmarked: Bool) async throws -> BookmarkState {
        try await GRDBAsync.write(to: dbQueue) { db in
            let timestamp = Self.currentTimestamp()
            let payloadJSON = Self.encodePayload(target.payload)

            if bookmarked {
                try db.execute(
                    sql: """
                        INSERT INTO bookmarks (
                            target_type,
                            target_id,
                            payload_json,
                            created_at,
                            updated_at
                        )
                        VALUES (?, ?, ?, ?, ?)
                        ON CONFLICT(target_type, target_id)
                        DO UPDATE SET
                            payload_json = excluded.payload_json,
                            updated_at = excluded.updated_at
                    """,
                    arguments: [
                        target.targetType.rawValue,
                        target.targetID,
                        payloadJSON,
                        timestamp,
                        timestamp,
                    ]
                )
            } else {
                try db.execute(
                    sql: """
                        DELETE FROM bookmarks
                        WHERE target_type = ?
                          AND target_id = ?
                    """,
                    arguments: [target.targetType.rawValue, target.targetID]
                )
            }

            let updatedAt: String? = bookmarked ? timestamp : nil
            return BookmarkState(
                targetType: target.targetType,
                targetID: target.targetID,
                payload: target.payload,
                isBookmarked: bookmarked,
                updatedAt: updatedAt
            )
        }
    }

    func fetchBookmarkStates(targets: [BookmarkTarget]) async throws -> [BookmarkState] {
        try await GRDBAsync.read(from: dbQueue) { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT target_type, target_id, payload_json, updated_at
                    FROM bookmarks
                """
            )

            let stateMap = Dictionary(
                uniqueKeysWithValues: rows.map { row in
                    (
                        "\(row["target_type"] as String? ?? "")::\(row["target_id"] as String? ?? "")",
                        row
                    )
                }
            )

            return targets.map { target in
                let key = "\(target.targetType.rawValue)::\(target.targetID)"
                if let row = stateMap[key] {
                    return BookmarkState(
                        targetType: target.targetType,
                        targetID: target.targetID,
                        payload: Self.decodePayload(row["payload_json"]) ?? target.payload,
                        isBookmarked: true,
                        updatedAt: row["updated_at"]
                    )
                }

                return BookmarkState(
                    targetType: target.targetType,
                    targetID: target.targetID,
                    payload: target.payload,
                    isBookmarked: false,
                    updatedAt: nil
                )
            }
        }
    }

    func listBookmarks() async throws -> [BookmarkListEntry] {
        try await GRDBAsync.read(from: dbQueue) { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT
                        b.id,
                        b.target_type,
                        b.target_id,
                        b.payload_json,
                        b.updated_at,
                        c.title,
                        c.source,
                        c.model,
                        COALESCE(
                            NULLIF(TRIM(c.source_created_at), ''),
                            NULLIF(TRIM(c.imported_at), ''),
                            NULLIF(TRIM(c.date_str), '')
                        ) AS primary_time
                    FROM bookmarks b
                    LEFT JOIN conversations c
                        ON b.target_type = 'thread'
                       AND c.id = b.target_id
                    -- markdown import 会話は render 未対応のため一覧から除外。
                    -- thread 以外のブックマーク (c が NULL) は影響させない。
                    WHERE c.source IS NULL OR c.source != 'markdown'
                    ORDER BY b.updated_at DESC, b.created_at DESC, b.id DESC
                """
            )

            return rows.compactMap { row in
                guard let targetType = BookmarkTargetType(rawValue: row["target_type"] ?? "") else {
                    return nil
                }

                let payload = Self.decodePayload(row["payload_json"]) ?? [:]
                let title: String? = row["title"]
                let label = title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                    ? (title ?? row["target_id"] ?? "")
                    : (payload["title"] ?? row["target_id"] ?? "")

                return BookmarkListEntry(
                    bookmarkID: Int(row["id"] as Int64? ?? 0),
                    targetType: targetType,
                    targetID: row["target_id"] ?? "",
                    payload: payload,
                    label: label,
                    title: title,
                    source: row["source"],
                    model: row["model"],
                    primaryTime: row["primary_time"],
                    updatedAt: row["updated_at"]
                )
            }
        }
    }

    private static func currentTimestamp() -> String {
        TimestampFormatter.now()
    }

    private static func encodePayload(_ payload: [String: String]) -> String? {
        guard !payload.isEmpty else {
            return nil
        }

        let data = try? JSONEncoder().encode(payload)
        return data.flatMap { String(data: $0, encoding: .utf8) }
    }

    private static func decodePayload(_ rawValue: String?) -> [String: String]? {
        guard let rawValue,
              let data = rawValue.data(using: .utf8) else {
            return nil
        }

        return try? JSONDecoder().decode([String: String].self, from: data)
    }
}
