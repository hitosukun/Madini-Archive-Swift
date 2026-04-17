import Foundation
import GRDB

final class GRDBTagRepository: TagRepository, @unchecked Sendable {
    private let dbQueue: DatabaseQueue

    init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    // MARK: - CRUD

    func listTags() async throws -> [TagEntry] {
        try await GRDBAsync.read(from: dbQueue) { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT
                        t.id,
                        t.name,
                        t.system_key,
                        t.is_system,
                        t.created_at,
                        t.updated_at,
                        (
                            SELECT COUNT(*)
                            FROM bookmark_tag_links tl
                            WHERE tl.tag_id = t.id
                        ) AS usage_count
                    FROM bookmark_tags t
                    ORDER BY t.is_system DESC, LOWER(t.name) ASC
                """
            )

            return rows.map(Self.mapTag)
        }
    }

    func createTag(name: String) async throws -> TagEntry {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw TagRepositoryError.emptyName
        }

        return try await GRDBAsync.write(to: dbQueue) { db in
            let timestamp = Self.currentTimestamp()
            try db.execute(
                sql: """
                    INSERT INTO bookmark_tags (
                        name,
                        is_system,
                        created_at,
                        updated_at
                    )
                    VALUES (?, 0, ?, ?)
                """,
                arguments: [trimmed, timestamp, timestamp]
            )
            let id = db.lastInsertedRowID
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT
                        id, name, system_key, is_system, created_at, updated_at,
                        0 AS usage_count
                    FROM bookmark_tags
                    WHERE id = ?
                """,
                arguments: [id]
            ) else {
                throw TagRepositoryError.notFound
            }
            return Self.mapTag(row)
        }
    }

    func renameTag(id: Int, name: String) async throws -> TagEntry {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw TagRepositoryError.emptyName
        }

        return try await GRDBAsync.write(to: dbQueue) { db in
            let timestamp = Self.currentTimestamp()
            try db.execute(
                sql: """
                    UPDATE bookmark_tags
                    SET name = ?, updated_at = ?
                    WHERE id = ? AND is_system = 0
                """,
                arguments: [trimmed, timestamp, id]
            )

            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT
                        t.id, t.name, t.system_key, t.is_system, t.created_at, t.updated_at,
                        (
                            SELECT COUNT(*)
                            FROM bookmark_tag_links tl
                            WHERE tl.tag_id = t.id
                        ) AS usage_count
                    FROM bookmark_tags t
                    WHERE t.id = ?
                """,
                arguments: [id]
            ) else {
                throw TagRepositoryError.notFound
            }
            return Self.mapTag(row)
        }
    }

    func deleteTag(id: Int) async throws {
        try await GRDBAsync.write(to: dbQueue) { db in
            try db.execute(
                sql: "DELETE FROM bookmark_tag_links WHERE tag_id = ?",
                arguments: [id]
            )
            try db.execute(
                sql: "DELETE FROM bookmark_tags WHERE id = ? AND is_system = 0",
                arguments: [id]
            )
        }
    }

    // MARK: - Attachments

    func bindings(forConversationIDs ids: [String]) async throws -> [String: ConversationTagBinding] {
        guard !ids.isEmpty else {
            return [:]
        }

        return try await GRDBAsync.read(from: dbQueue) { db in
            let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ", ")
            let arguments = StatementArguments(ids)

            // Match both thread-level bookmarks (target_id = conversationID) and
            // prompt-level bookmarks (target_id = "<conversationID>:<msgIndex>"),
            // since the Python app stores tags primarily as prompt-level.
            let bookmarkRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT
                        b.id AS bookmark_id,
                        b.target_type,
                        b.target_id,
                        CASE
                            WHEN b.target_type = 'thread' THEN b.target_id
                            WHEN b.target_type = 'prompt' THEN substr(b.target_id, 1, instr(b.target_id, ':') - 1)
                            ELSE NULL
                        END AS conversation_id
                    FROM bookmarks b
                    WHERE (
                        (b.target_type = 'thread' AND b.target_id IN (\(placeholders)))
                        OR (b.target_type = 'prompt'
                            AND substr(b.target_id, 1, instr(b.target_id, ':') - 1) IN (\(placeholders)))
                    )
                """,
                arguments: arguments + arguments
            )

            // Track the thread-level bookmark id per conversation (used as the
            // canonical writable target for attach/detach from SwiftUI).
            var threadBookmarkIDByConversation: [String: Int] = [:]
            var allBookmarkIDsByConversation: [String: [Int]] = [:]
            for row in bookmarkRows {
                guard let convID = row["conversation_id"] as String? else { continue }
                let bookmarkID = Int(row["bookmark_id"] as Int64? ?? 0)
                allBookmarkIDsByConversation[convID, default: []].append(bookmarkID)
                if (row["target_type"] as String?) == "thread" {
                    threadBookmarkIDByConversation[convID] = bookmarkID
                }
            }

            var result: [String: ConversationTagBinding] = [:]
            for id in ids {
                result[id] = ConversationTagBinding(
                    conversationID: id,
                    tags: [],
                    bookmarkID: threadBookmarkIDByConversation[id]
                )
            }

            let bookmarkIDs = Array(Set(allBookmarkIDsByConversation.values.flatMap { $0 }))
            guard !bookmarkIDs.isEmpty else {
                return result
            }

            let tagPlaceholders = Array(repeating: "?", count: bookmarkIDs.count).joined(separator: ", ")
            let tagArguments = StatementArguments(bookmarkIDs.map { Int64($0) })
            let tagRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT
                        tl.bookmark_id,
                        t.id, t.name, t.system_key, t.is_system, t.created_at, t.updated_at,
                        (
                            SELECT COUNT(*)
                            FROM bookmark_tag_links inner_tl
                            WHERE inner_tl.tag_id = t.id
                        ) AS usage_count
                    FROM bookmark_tag_links tl
                    JOIN bookmark_tags t ON t.id = tl.tag_id
                    WHERE tl.bookmark_id IN (\(tagPlaceholders))
                    ORDER BY LOWER(t.name)
                """,
                arguments: tagArguments
            )

            var tagsByBookmarkID: [Int: [TagEntry]] = [:]
            for row in tagRows {
                let bookmarkID = Int(row["bookmark_id"] as Int64? ?? 0)
                tagsByBookmarkID[bookmarkID, default: []].append(Self.mapTag(row))
            }

            for (conversationID, bookmarkIDs) in allBookmarkIDsByConversation {
                // Union all tags across this conversation's bookmarks (thread + prompt-level).
                var seenTagIDs = Set<Int>()
                var merged: [TagEntry] = []
                for bookmarkID in bookmarkIDs {
                    for tag in tagsByBookmarkID[bookmarkID] ?? [] {
                        if seenTagIDs.insert(tag.id).inserted {
                            merged.append(tag)
                        }
                    }
                }
                merged.sort { $0.name.lowercased() < $1.name.lowercased() }

                result[conversationID] = ConversationTagBinding(
                    conversationID: conversationID,
                    tags: merged,
                    bookmarkID: threadBookmarkIDByConversation[conversationID]
                )
            }

            return result
        }
    }

    @discardableResult
    func attachTag(tagID: Int, toConversationID conversationID: String, payload: [String: String]) async throws -> Int {
        try await GRDBAsync.write(to: dbQueue) { db in
            let timestamp = Self.currentTimestamp()
            let payloadJSON = Self.encodePayload(payload)

            try db.execute(
                sql: """
                    INSERT INTO bookmarks (
                        target_type,
                        target_id,
                        payload_json,
                        created_at,
                        updated_at
                    )
                    VALUES ('thread', ?, ?, ?, ?)
                    ON CONFLICT(target_type, target_id)
                    DO UPDATE SET
                        payload_json = COALESCE(bookmarks.payload_json, excluded.payload_json),
                        updated_at = excluded.updated_at
                """,
                arguments: [
                    conversationID,
                    payloadJSON,
                    timestamp,
                    timestamp,
                ]
            )

            guard let bookmarkID = try Int64.fetchOne(
                db,
                sql: """
                    SELECT id FROM bookmarks
                    WHERE target_type = 'thread' AND target_id = ?
                """,
                arguments: [conversationID]
            ) else {
                throw TagRepositoryError.notFound
            }

            try db.execute(
                sql: """
                    INSERT OR IGNORE INTO bookmark_tag_links (
                        bookmark_id,
                        tag_id,
                        created_at
                    )
                    VALUES (?, ?, ?)
                """,
                arguments: [bookmarkID, tagID, timestamp]
            )

            return Int(bookmarkID)
        }
    }

    func detachTag(tagID: Int, fromConversationID conversationID: String) async throws {
        try await GRDBAsync.write(to: dbQueue) { db in
            try db.execute(
                sql: """
                    DELETE FROM bookmark_tag_links
                    WHERE tag_id = ?
                      AND bookmark_id IN (
                          SELECT id FROM bookmarks
                          WHERE target_type = 'thread' AND target_id = ?
                      )
                """,
                arguments: [tagID, conversationID]
            )
        }
    }

    // MARK: - Helpers

    private static func mapTag(_ row: Row) -> TagEntry {
        TagEntry(
            id: Int(row["id"] as Int64? ?? 0),
            name: row["name"] ?? "",
            isSystem: (row["is_system"] as Int64? ?? 0) != 0,
            systemKey: row["system_key"],
            usageCount: Int(row["usage_count"] as Int64? ?? 0),
            createdAt: row["created_at"] ?? "",
            updatedAt: row["updated_at"] ?? ""
        )
    }

    private static func currentTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: Date())
    }

    private static func encodePayload(_ payload: [String: String]) -> String? {
        guard !payload.isEmpty else {
            return nil
        }
        let data = try? JSONEncoder().encode(payload)
        return data.flatMap { String(data: $0, encoding: .utf8) }
    }
}

enum TagRepositoryError: Error, LocalizedError {
    case emptyName
    case notFound

    var errorDescription: String? {
        switch self {
        case .emptyName: return "Tag name cannot be empty."
        case .notFound: return "Tag could not be found."
        }
    }
}
