import Foundation
import GRDB

final class GRDBProjectSuggestionRepository: ProjectSuggestionRepository, @unchecked Sendable {
    private let dbQueue: DatabaseQueue

    init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    func topPendingSuggestion(threadId: String) async throws -> ProjectSuggestion? {
        try await GRDBAsync.read(from: dbQueue) { db in
            let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT thread_id, target_project_id, score, reason, state, created_at, updated_at
                    FROM project_suggestions
                    WHERE thread_id = ?
                      AND state = 'pending'
                    ORDER BY score DESC, updated_at DESC, target_project_id ASC
                    LIMIT 1
                """,
                arguments: [threadId]
            )
            return try row.map(Self.makeSuggestion)
        }
    }

    func suggestions(threadId: String) async throws -> [ProjectSuggestion] {
        try await GRDBAsync.read(from: dbQueue) { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT thread_id, target_project_id, score, reason, state, created_at, updated_at
                    FROM project_suggestions
                    WHERE thread_id = ?
                    ORDER BY
                        CASE state
                            WHEN 'pending' THEN 0
                            WHEN 'accepted' THEN 1
                            ELSE 2
                        END,
                        score DESC,
                        updated_at DESC,
                        target_project_id ASC
                """,
                arguments: [threadId]
            )
            return try rows.map(Self.makeSuggestion)
        }
    }

    func upsertSuggestion(_ suggestion: ProjectSuggestion) async throws {
        let reason = try Self.encodeReason(suggestion.reason)
        try await GRDBAsync.write(to: dbQueue) { db in
            try db.execute(
                sql: """
                    INSERT INTO project_suggestions (
                        thread_id,
                        target_project_id,
                        score,
                        reason,
                        state,
                        created_at,
                        updated_at
                    )
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(thread_id, target_project_id) DO UPDATE SET
                        score = excluded.score,
                        reason = excluded.reason,
                        state = excluded.state,
                        updated_at = excluded.updated_at
                """,
                arguments: [
                    suggestion.threadId,
                    suggestion.targetProjectId,
                    suggestion.score,
                    reason,
                    suggestion.state.rawValue,
                    GRDBProjectDateCodec.string(from: suggestion.createdAt),
                    GRDBProjectDateCodec.string(from: suggestion.updatedAt)
                ]
            )
        }
    }

    func markAccepted(threadId: String, targetProjectId: String) async throws {
        let updatedAt = GRDBProjectDateCodec.string(from: Date())
        try await GRDBAsync.write(to: dbQueue) { db in
            try db.execute(
                sql: """
                    UPDATE project_suggestions
                    SET state = 'accepted',
                        updated_at = ?
                    WHERE thread_id = ?
                      AND target_project_id = ?
                """,
                arguments: [updatedAt, threadId, targetProjectId]
            )
            try db.execute(
                sql: """
                    UPDATE project_suggestions
                    SET state = 'dismissed',
                        updated_at = ?
                    WHERE thread_id = ?
                      AND target_project_id != ?
                      AND state = 'pending'
                """,
                arguments: [updatedAt, threadId, targetProjectId]
            )
        }
    }

    func markDismissed(threadId: String, targetProjectId: String) async throws {
        let updatedAt = GRDBProjectDateCodec.string(from: Date())
        try await GRDBAsync.write(to: dbQueue) { db in
            try db.execute(
                sql: """
                    UPDATE project_suggestions
                    SET state = 'dismissed',
                        updated_at = ?
                    WHERE thread_id = ?
                      AND target_project_id = ?
                """,
                arguments: [updatedAt, threadId, targetProjectId]
            )
        }
    }

    func dismissedTokens(projectId: String) async throws -> [String: Int] {
        try await GRDBAsync.read(from: dbQueue) { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT reason
                    FROM project_suggestions
                    WHERE target_project_id = ?
                      AND state = 'dismissed'
                """,
                arguments: [projectId]
            )

            var counts: [String: Int] = [:]
            for row in rows {
                let reason = Self.decodeReason(row["reason"])
                for token in reason.flatMap(Self.tokens) {
                    counts[token, default: 0] += 1
                }
            }
            return counts
        }
    }

    private static func makeSuggestion(_ row: Row) throws -> ProjectSuggestion {
        ProjectSuggestion(
            threadId: row["thread_id"],
            targetProjectId: row["target_project_id"],
            score: row["score"] ?? 0,
            reason: decodeReason(row["reason"]),
            state: SuggestionState(rawValue: row["state"] ?? "") ?? .pending,
            createdAt: GRDBProjectDateCodec.date(from: row["created_at"]),
            updatedAt: GRDBProjectDateCodec.date(from: row["updated_at"])
        )
    }

    private static func encodeReason(_ reason: [String]) throws -> String {
        let data = try JSONEncoder().encode(reason)
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    private static func decodeReason(_ value: String?) -> [String] {
        guard let data = value?.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return decoded
    }

    private static func tokens(from value: String) -> [String] {
        value
            .lowercased()
            .split { character in
                !character.isLetter && !character.isNumber
            }
            .map(String.init)
            .filter { !$0.isEmpty }
    }
}
