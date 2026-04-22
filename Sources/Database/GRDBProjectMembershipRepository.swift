import Foundation
import GRDB

final class GRDBProjectMembershipRepository: ProjectMembershipRepository, @unchecked Sendable {
    private let dbQueue: DatabaseQueue

    init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    func membership(threadId: String) async throws -> ProjectMembership? {
        try await GRDBAsync.read(from: dbQueue) { db in
            let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT thread_id, project_id, origin, assigned_at
                    FROM project_memberships
                    WHERE thread_id = ?
                    LIMIT 1
                """,
                arguments: [threadId]
            )
            return row.map(Self.makeMembership)
        }
    }

    func setMembership(_ membership: ProjectMembership) async throws {
        try await GRDBAsync.write(to: dbQueue) { db in
            try db.execute(
                sql: """
                    INSERT INTO project_memberships (
                        thread_id, project_id, origin, assigned_at
                    )
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(thread_id) DO UPDATE SET
                        project_id = excluded.project_id,
                        origin = excluded.origin,
                        assigned_at = excluded.assigned_at
                """,
                arguments: [
                    membership.threadId,
                    membership.projectId,
                    membership.origin.rawValue,
                    GRDBProjectDateCodec.string(from: membership.assignedAt)
                ]
            )
        }
    }

    func removeMembership(threadId: String) async throws {
        try await GRDBAsync.write(to: dbQueue) { db in
            try db.execute(
                sql: "DELETE FROM project_memberships WHERE thread_id = ?",
                arguments: [threadId]
            )
        }
    }

    func threadsInProject(projectId: String, offset: Int, limit: Int) async throws -> [ConversationSummary] {
        try await GRDBAsync.read(from: dbQueue) { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    \(Self.summarySelectSQL)
                    FROM conversations c
                    JOIN project_memberships pm ON pm.thread_id = c.id
                    WHERE pm.project_id = ?
                    ORDER BY primary_time DESC, c.id ASC
                    LIMIT ? OFFSET ?
                """,
                arguments: [projectId, limit, offset]
            )
            return rows.map(Self.makeSummary)
        }
    }

    func unassignedThreads(hasSuggestion: Bool, offset: Int, limit: Int) async throws -> [ConversationSummary] {
        try await GRDBAsync.read(from: dbQueue) { db in
            let suggestionPredicate = hasSuggestion ? "EXISTS" : "NOT EXISTS"
            let rows = try Row.fetchAll(
                db,
                sql: """
                    \(Self.summarySelectSQL)
                    FROM conversations c
                    WHERE NOT EXISTS (
                        SELECT 1
                        FROM project_memberships pm
                        WHERE pm.thread_id = c.id
                    )
                    AND \(suggestionPredicate) (
                        SELECT 1
                        FROM project_suggestions ps
                        WHERE ps.thread_id = c.id
                          AND ps.state = 'pending'
                    )
                    ORDER BY primary_time DESC, c.id ASC
                    LIMIT ? OFFSET ?
                """,
                arguments: [limit, offset]
            )
            return rows.map(Self.makeSummary)
        }
    }

    private static let primaryTimeSQL = """
    COALESCE(
        NULLIF(TRIM(c.source_created_at), ''),
        NULLIF(TRIM(c.imported_at), ''),
        NULLIF(TRIM(c.date_str), '')
    )
    """

    private static let headlinePromptSQL = """
    (
        SELECT substr(m.content, 1, 400)
        FROM messages m
        WHERE m.conv_id = c.id
          AND lower(COALESCE(m.role, '')) = 'user'
        ORDER BY m.msg_index
        LIMIT 1
    )
    """

    private static let firstMessageSnippetSQL = """
    (
        SELECT substr(m.content, 1, 400)
        FROM messages m
        WHERE m.conv_id = c.id
        ORDER BY m.msg_index
        LIMIT 1
    )
    """

    private static let bookmarkStatusSQL = """
    EXISTS(
        SELECT 1
        FROM bookmarks b
        WHERE b.target_type = 'thread'
          AND b.target_id = c.id
    )
    """

    private static let summarySelectSQL = """
    SELECT
        c.id,
        c.title,
        c.source,
        c.model,
        c.prompt_count,
        \(headlinePromptSQL) AS headline_prompt,
        \(firstMessageSnippetSQL) AS first_message_snippet,
        \(primaryTimeSQL) AS primary_time,
        \(bookmarkStatusSQL) AS is_bookmarked
    """

    private static func makeMembership(_ row: Row) -> ProjectMembership {
        ProjectMembership(
            threadId: row["thread_id"],
            projectId: row["project_id"],
            origin: MembershipOrigin(rawValue: row["origin"] ?? "") ?? .manualAdd,
            assignedAt: GRDBProjectDateCodec.date(from: row["assigned_at"])
        )
    }

    private static func makeSummary(_ row: Row) -> ConversationSummary {
        ConversationSummary(
            id: row["id"],
            headline: ConversationHeadlineSummary.build(
                prompt: row["headline_prompt"],
                title: row["title"],
                firstMessage: row["first_message_snippet"]
            ),
            source: row["source"],
            title: row["title"],
            model: row["model"],
            messageCount: row["prompt_count"] ?? 0,
            primaryTime: row["primary_time"],
            isBookmarked: (row["is_bookmarked"] as Int64? ?? 0) != 0
        )
    }
}
