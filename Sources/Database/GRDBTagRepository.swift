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

    func findTagByName(_ name: String) async throws -> TagEntry? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return try await GRDBAsync.read(from: dbQueue) { db in
            let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT
                        id, name, system_key, is_system, created_at, updated_at,
                        0 AS usage_count
                    FROM bookmark_tags
                    WHERE name = ? COLLATE NOCASE
                    LIMIT 1
                """,
                arguments: [trimmed]
            )
            return row.map(Self.mapTag)
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

    /// Delete a user-created tag. Rather than dropping the links outright,
    /// we **reroute them to the Trash system tag** so the user can recover
    /// the affected conversations (Trash is a rescue lane, not a grave —
    /// attaching any non-Trash tag back auto-detaches it).
    ///
    /// All steps run inside a single transaction so a crash mid-way cannot
    /// leave dangling links pointing at a tag row that's already gone.
    func deleteTag(id: Int) async throws {
        try await GRDBAsync.write(to: dbQueue) { db in
            // System tags (including Trash itself) are immutable — bail
            // early and match the previous contract.
            guard let isSystem = try Int64.fetchOne(
                db,
                sql: "SELECT is_system FROM bookmark_tags WHERE id = ?",
                arguments: [id]
            ), isSystem == 0 else {
                return
            }

            let trashID = try Self.ensureTrashTagID(db: db)
            let timestamp = Self.currentTimestamp()

            // 1. For every bookmark currently carrying the doomed tag,
            //    attach Trash (INSERT OR IGNORE so duplicates are fine).
            try db.execute(
                sql: """
                    INSERT OR IGNORE INTO bookmark_tag_links (
                        bookmark_id, tag_id, created_at
                    )
                    SELECT tl.bookmark_id, ?, ?
                    FROM bookmark_tag_links tl
                    WHERE tl.tag_id = ?
                """,
                arguments: [trashID, timestamp, id]
            )

            // 2. Drop the old links.
            try db.execute(
                sql: "DELETE FROM bookmark_tag_links WHERE tag_id = ?",
                arguments: [id]
            )

            // 3. Delete the tag row itself (is_system = 0 guard retained
            //    for belt-and-braces — the earlier guard already returned
            //    for system rows).
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

            // Thread-level bookmarks only. Prompt-level tagging has been
            // retired; any legacy `target_type = 'prompt'` rows were rolled
            // up to thread-level and then physically deleted by migrations
            // 1 and 2 (see AppServices.bootstrapViewLayerSchema).
            let bookmarkRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT
                        b.id AS bookmark_id,
                        b.target_id AS conversation_id
                    FROM bookmarks b
                    WHERE b.target_type = 'thread'
                      AND b.target_id IN (\(placeholders))
                """,
                arguments: arguments
            )

            var threadBookmarkIDByConversation: [String: Int] = [:]
            for row in bookmarkRows {
                guard let convID = row["conversation_id"] as String? else { continue }
                let bookmarkID = Int(row["bookmark_id"] as Int64? ?? 0)
                threadBookmarkIDByConversation[convID] = bookmarkID
            }

            var result: [String: ConversationTagBinding] = [:]
            for id in ids {
                result[id] = ConversationTagBinding(
                    conversationID: id,
                    tags: [],
                    bookmarkID: threadBookmarkIDByConversation[id]
                )
            }

            let bookmarkIDs = Array(threadBookmarkIDByConversation.values)
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
                        0 AS usage_count
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

            for (conversationID, bookmarkID) in threadBookmarkIDByConversation {
                let tags = tagsByBookmarkID[bookmarkID] ?? []
                result[conversationID] = ConversationTagBinding(
                    conversationID: conversationID,
                    tags: tags,
                    bookmarkID: bookmarkID
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

            // Rescue semantics: attaching any non-Trash tag implicitly
            // pulls the conversation out of Trash. Skip if the caller is
            // itself attaching Trash (that's a manual "soft-delete").
            let trashID = try Self.ensureTrashTagID(db: db)
            if Int64(tagID) != trashID {
                try db.execute(
                    sql: """
                        DELETE FROM bookmark_tag_links
                        WHERE bookmark_id = ? AND tag_id = ?
                    """,
                    arguments: [bookmarkID, trashID]
                )
            }

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

    /// Resolve the Trash system tag's id, creating it on the fly if the
    /// schema-bootstrap seed did not run (e.g. an older DB file). Called
    /// from within a `write` block so we share the transaction.
    private static func ensureTrashTagID(db: Database) throws -> Int64 {
        if let id = try Int64.fetchOne(
            db,
            sql: "SELECT id FROM bookmark_tags WHERE system_key = 'trash'"
        ) {
            return id
        }
        let timestamp = currentTimestamp()
        try db.execute(
            sql: """
                INSERT INTO bookmark_tags (
                    name, system_key, is_system, created_at, updated_at
                )
                VALUES ('Trash', 'trash', 1, ?, ?)
            """,
            arguments: [timestamp, timestamp]
        )
        return db.lastInsertedRowID
    }

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
        TimestampFormatter.now()
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
