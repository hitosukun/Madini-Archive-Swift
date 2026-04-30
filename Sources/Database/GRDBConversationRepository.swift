import Foundation
import GRDB

final class GRDBConversationRepository: ConversationRepository, @unchecked Sendable {
    private let dbQueue: DatabaseQueue

    init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    func fetchIndex(query: ConversationListQuery) async throws -> [ConversationSummary] {
        try await GRDBAsync.read(from: dbQueue) { db in
            let (whereSQL, arguments) = Self.makeConversationWhereClause(filter: query.filter)
            // Secondary sort is always `c.id` so the result ordering is
            // deterministic when the primary sort ties (e.g. two threads
            // with the same prompt count).
            let orderBy: String
            switch query.sortBy {
            case .dateDesc:
                orderBy = "primary_time DESC, c.id"
            case .dateAsc:
                orderBy = "primary_time ASC, c.id"
            case .promptCountDesc:
                orderBy = "c.prompt_count DESC, primary_time DESC, c.id"
            case .promptCountAsc:
                orderBy = "c.prompt_count ASC, primary_time DESC, c.id"
            }

            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT
                        c.id,
                        c.source,
                        c.title,
                        c.model,
                        c.prompt_count,
                        \(Self.headlinePromptSQL) AS headline_prompt,
                        \(Self.firstMessageSnippetSQL) AS first_message_snippet,
                        \(Self.primaryTimeSQL) AS primary_time
                        \(Self.bookmarkStatusSQL) AS is_bookmarked
                    FROM conversations c
                    \(whereSQL)
                    ORDER BY \(orderBy)
                    LIMIT ? OFFSET ?
                """,
                arguments: arguments + [query.limit, query.offset]
            )

            return rows.map(Self.makeSummary)
        }
    }

    func fetchDetail(id: String) async throws -> ConversationDetail? {
        try await GRDBAsync.read(from: dbQueue) { db in
            guard let summaryRow = try Row.fetchOne(
                db,
                sql: """
                    SELECT
                        c.id,
                        c.source,
                        c.title,
                        c.model,
                        c.prompt_count,
                        \(Self.headlinePromptSQL) AS headline_prompt,
                        \(Self.firstMessageSnippetSQL) AS first_message_snippet,
                        \(Self.primaryTimeSQL) AS primary_time
                        \(Self.bookmarkStatusSQL) AS is_bookmarked
                    FROM conversations c
                    WHERE c.id = ?
                """,
                arguments: [id]
            ) else {
                return nil
            }

            let messageRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, role, content
                    FROM messages
                    WHERE conv_id = ?
                    ORDER BY msg_index
                """,
                arguments: [id]
            )

            let messages = messageRows.map { row in
                Message(
                    id: "\(id):\(row["id"] as Int64? ?? 0)",
                    role: MessageRole(databaseValue: row["role"]),
                    content: row["content"] ?? ""
                )
            }

            return ConversationDetail(
                summary: Self.makeSummary(summaryRow),
                messages: messages
            )
        }
    }

    func fetchHeadline(id: String) async throws -> ConversationHeadlineSummary? {
        try await GRDBAsync.read(from: dbQueue) { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT
                        c.title,
                        \(Self.headlinePromptSQL) AS headline_prompt,
                        \(Self.firstMessageSnippetSQL) AS first_message_snippet
                    FROM conversations c
                    WHERE c.id = ?
                """,
                arguments: [id]
            ) else {
                return nil
            }

            return Self.makeHeadline(row)
        }
    }

    func count(query: ConversationListQuery) async throws -> Int {
        try await GRDBAsync.read(from: dbQueue) { db in
            let (whereSQL, arguments) = Self.makeConversationWhereClause(filter: query.filter)

            return try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*)
                    FROM conversations c
                    \(whereSQL)
                """,
                arguments: arguments
            ) ?? 0
        }
    }

    func fetchSources(filter: ArchiveSearchFilter?) async throws -> [FilterOption] {
        try await GRDBAsync.read(from: dbQueue) { db in
            let (whereSQL, arguments) = Self.makeConversationWhereClause(
                filter: filter ?? ArchiveSearchFilter(),
                excludingSources: true
            )
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT source, COUNT(*) AS count
                    FROM conversations c
                    \(whereSQL.isEmpty ? "WHERE c.source IS NOT NULL AND TRIM(c.source) <> ''" : "\(whereSQL) AND c.source IS NOT NULL AND TRIM(c.source) <> ''")
                    GROUP BY source
                    ORDER BY count DESC, source ASC
                """,
                arguments: arguments
            )

            return rows.compactMap { row in
                guard let value: String = row["source"] else {
                    return nil
                }

                return FilterOption(
                    value: value,
                    count: row["count"] ?? 0
                )
            }
        }
    }

    func fetchModels(filter: ArchiveSearchFilter?) async throws -> [FilterOption] {
        try await GRDBAsync.read(from: dbQueue) { db in
            let (whereSQL, arguments) = Self.makeConversationWhereClause(
                filter: filter ?? ArchiveSearchFilter(),
                excludingModels: true
            )

            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT c.model AS model, COUNT(*) AS count
                    FROM conversations c
                    \(whereSQL.isEmpty ? "WHERE c.model IS NOT NULL AND TRIM(c.model) <> ''" : "\(whereSQL) AND c.model IS NOT NULL AND TRIM(c.model) <> ''")
                    GROUP BY model
                    ORDER BY count DESC, model ASC
                """,
                arguments: arguments
            )

            return rows.compactMap { row in
                guard let value: String = row["model"] else {
                    return nil
                }

                return FilterOption(
                    value: value,
                    count: row["count"] ?? 0
                )
            }
        }
    }

    func fetchSourceFileFacets(filter: ArchiveSearchFilter?) async throws -> [FilterOption] {
        try await GRDBAsync.read(from: dbQueue) { db in
            let (whereSQL, arguments) = Self.makeConversationWhereClause(
                filter: filter ?? ArchiveSearchFilter(),
                excludingSourceFiles: true
            )
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT c.source_file AS source_file, COUNT(*) AS count
                    FROM conversations c
                    \(whereSQL.isEmpty ? "WHERE c.source_file IS NOT NULL AND TRIM(c.source_file) <> ''" : "\(whereSQL) AND c.source_file IS NOT NULL AND TRIM(c.source_file) <> ''")
                    GROUP BY c.source_file
                    ORDER BY count DESC, c.source_file ASC
                """,
                arguments: arguments
            )

            return rows.compactMap { row in
                guard let value: String = row["source_file"] else { return nil }
                return FilterOption(value: value, count: row["count"] ?? 0)
            }
        }
    }

    func fetchSourceModelFacets(filter: ArchiveSearchFilter?) async throws -> [SourceModelFacet] {
        try await GRDBAsync.read(from: dbQueue) { db in
            let (whereSQL, arguments) = Self.makeConversationWhereClause(
                filter: filter ?? ArchiveSearchFilter(),
                excludingSources: true,
                excludingModels: true
            )
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT c.source AS source, c.model AS model, COUNT(*) AS count
                    FROM conversations c
                    \(whereSQL.isEmpty ? "WHERE c.source IS NOT NULL AND TRIM(c.source) <> ''" : "\(whereSQL) AND c.source IS NOT NULL AND TRIM(c.source) <> ''")
                    GROUP BY c.source, c.model
                    ORDER BY c.source ASC, count DESC, c.model ASC
                """,
                arguments: arguments
            )

            return rows.compactMap { row in
                guard let source: String = row["source"] else { return nil }
                let rawModel: String? = row["model"]
                let normalizedModel: String? = {
                    guard let value = rawModel?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !value.isEmpty else { return nil }
                    return value
                }()
                return SourceModelFacet(
                    source: source,
                    model: normalizedModel,
                    count: row["count"] ?? 0
                )
            }
        }
    }

    /// Forwarded to the shared expression in `SearchFilterSQL` so the
    /// column projection here, the WHERE-builder, and the migration-3
    /// expression index all read the same `primary_time` definition.
    private static let primaryTimeSQL = SearchFilterSQL.primaryTimeSQL

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

    /// Phase 4: "bookmarked" is now derived from prompt-level pins.
    /// A conversation is considered bookmarked iff at least one of its
    /// user-authored messages has been pinned. Message ids follow
    /// `{conversationID}:{messageRowID}`, so we match by the prefix
    /// `c.id || ':'` to avoid `c.id LIKE c.id || '%'` collisions between
    /// conversation ids that share a prefix.
    private static let bookmarkStatusSQL = """
    ,
    EXISTS(
        SELECT 1
        FROM bookmarks b
        WHERE b.target_type = 'prompt'
          AND b.target_id LIKE c.id || ':%'
    )
    """

    /// Thin façade over `SearchFilterSQL.makeWhereClause` that
    /// preserves the legacy parameter shape used by the rest of this
    /// file. The actual predicate translation lives in
    /// `Database/SearchFilterSQL.swift` so the conversation list,
    /// search, and Stats paths share one implementation.
    private static func makeConversationWhereClause(
        filter: ArchiveSearchFilter,
        excludingSources: Bool = false,
        excludingModels: Bool = false,
        excludingSourceFiles: Bool = false
    ) -> (String, StatementArguments) {
        SearchFilterSQL.makeWhereClause(
            filter: filter,
            options: SearchFilterSQL.Options(
                excludingSources: excludingSources,
                excludingModels: excludingModels,
                excludingSourceFiles: excludingSourceFiles
            )
        )
    }

    private static func makeSummary(_ row: Row) -> ConversationSummary {
        ConversationSummary(
            id: row["id"],
            headline: makeHeadline(row),
            source: row["source"],
            title: row["title"],
            model: row["model"],
            messageCount: row["prompt_count"] ?? 0,
            primaryTime: row["primary_time"],
            isBookmarked: (row["is_bookmarked"] as Int64? ?? 0) != 0
        )
    }

    private static func makeHeadline(_ row: Row) -> ConversationHeadlineSummary {
        ConversationHeadlineSummary.build(
            prompt: row["headline_prompt"],
            title: row["title"],
            firstMessage: row["first_message_snippet"]
        )
    }
}
