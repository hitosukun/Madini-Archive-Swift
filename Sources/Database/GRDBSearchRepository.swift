import Foundation
import GRDB

final class GRDBSearchRepository: SearchRepository, @unchecked Sendable {
    private let dbQueue: DatabaseQueue

    init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    func search(query: SearchQuery) async throws -> [SearchResult] {
        let normalized = query.normalizedText
        guard query.filter.hasMeaningfulFilters,
              !normalized.isEmpty
                || query.filter.bookmarkedOnly
                || !query.filter.sources.isEmpty
                || !query.filter.models.isEmpty
                || query.filter.dateFrom != nil
                || query.filter.dateTo != nil
                || !query.filter.roles.isEmpty
                || !query.filter.bookmarkTags.isEmpty else {
            return []
        }

        return try await GRDBAsync.read(from: dbQueue) { db in
            let (filterSQL, arguments) = Self.makeSearchWhereClause(query: query)
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT
                        c.id AS conversation_id,
                        c.title,
                        c.source,
                        c.model,
                        c.prompt_count,
                        \(Self.headlinePromptSQL) AS headline_prompt,
                        \(Self.firstMessageSnippetSQL) AS first_message_snippet,
                        \(Self.primaryTimeSQL) AS primary_time,
                        snippet(search_idx, 2, '[', ']', ' … ', 12) AS snippet,
                        bm25(search_idx) AS rank
                        \(Self.bookmarkStatusSQL) AS is_bookmarked
                    FROM search_idx
                    JOIN conversations c ON c.id = search_idx.conv_id
                    \(filterSQL)
                    ORDER BY rank ASC, primary_time DESC, c.id ASC
                    LIMIT ? OFFSET ?
                """,
                arguments: arguments + [query.limit, query.offset]
            )

            return rows.map { row in
                SearchResult(
                    conversationID: row["conversation_id"],
                    headline: ConversationHeadlineSummary.build(
                        prompt: row["headline_prompt"],
                        title: row["title"],
                        firstMessage: row["first_message_snippet"]
                    ),
                    title: row["title"],
                    source: row["source"],
                    model: row["model"],
                    messageCount: row["prompt_count"] ?? 0,
                    primaryTime: row["primary_time"],
                    snippet: row["snippet"] ?? "",
                    isBookmarked: (row["is_bookmarked"] as Int64? ?? 0) != 0
                )
            }
        }
    }

    func count(query: SearchQuery) async throws -> Int {
        let normalized = query.normalizedText
        guard query.filter.hasMeaningfulFilters,
              !normalized.isEmpty
                || query.filter.bookmarkedOnly
                || !query.filter.sources.isEmpty
                || !query.filter.models.isEmpty
                || query.filter.dateFrom != nil
                || query.filter.dateTo != nil
                || !query.filter.roles.isEmpty
                || !query.filter.bookmarkTags.isEmpty else {
            return 0
        }

        return try await GRDBAsync.read(from: dbQueue) { db in
            let (filterSQL, arguments) = Self.makeSearchWhereClause(query: query, includePagination: false)
            return try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*)
                    FROM search_idx
                    JOIN conversations c ON c.id = search_idx.conv_id
                    \(filterSQL)
                """,
                arguments: arguments
            ) ?? 0
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
    ,
    EXISTS(
        SELECT 1
        FROM bookmarks b
        WHERE b.target_type = 'thread'
          AND b.target_id = c.id
    )
    """

    static func makeSearchWhereClause(
        query: SearchQuery,
        includePagination: Bool = true
    ) -> (String, StatementArguments) {
        var filters: [String] = []
        var arguments = StatementArguments()

        if !query.normalizedText.isEmpty {
            filters.append("search_idx MATCH ?")
            arguments += [makeMatchQuery(from: query.normalizedText)]
        }

        if !query.filter.sources.isEmpty {
            let sortedSources = Array(query.filter.sources).sorted()
            let placeholders = Array(repeating: "?", count: sortedSources.count).joined(separator: ", ")
            filters.append("c.source IN (\(placeholders))")
            for source in sortedSources {
                arguments += [source]
            }
        }

        if !query.filter.models.isEmpty {
            let sortedModels = Array(query.filter.models).sorted()
            let placeholders = Array(repeating: "?", count: sortedModels.count).joined(separator: ", ")
            filters.append("c.model IN (\(placeholders))")
            for model in sortedModels {
                arguments += [model]
            }
        }

        if query.filter.bookmarkedOnly {
            filters.append("""
                EXISTS(
                    SELECT 1
                    FROM bookmarks b
                    WHERE b.target_type = 'thread'
                      AND b.target_id = c.id
                )
                """)
        }

        if let dateFrom = query.filter.dateFrom?.trimmingCharacters(in: .whitespacesAndNewlines),
           !dateFrom.isEmpty {
            filters.append("\(primaryTimeSQL) >= ?")
            arguments += [dateFrom]
        }

        if let dateTo = query.filter.dateTo?.trimmingCharacters(in: .whitespacesAndNewlines),
           !dateTo.isEmpty {
            filters.append("\(primaryTimeSQL) <= ?")
            arguments += [dateTo]
        }

        if !query.filter.bookmarkTags.isEmpty {
            let tagPlaceholders = Array(repeating: "?", count: query.filter.bookmarkTags.count).joined(separator: ", ")
            filters.append("""
                EXISTS(
                    SELECT 1
                    FROM bookmarks b
                    JOIN bookmark_tag_links tl ON tl.bookmark_id = b.id
                    JOIN bookmark_tags t ON t.id = tl.tag_id
                    WHERE t.name COLLATE NOCASE IN (\(tagPlaceholders))
                      AND (
                          (b.target_type = 'thread' AND b.target_id = c.id)
                          OR (b.target_type = 'prompt'
                              AND substr(b.target_id, 1, instr(b.target_id, ':') - 1) = c.id)
                      )
                )
                """)
            for tag in query.filter.bookmarkTags {
                arguments += [tag]
            }
        }

        if !query.filter.roles.isEmpty {
            let placeholders = Array(repeating: "?", count: query.filter.roles.count).joined(separator: ", ")
            filters.append("""
                EXISTS(
                    SELECT 1
                    FROM messages m
                    WHERE m.conv_id = c.id
                      AND lower(COALESCE(m.role, '')) IN (\(placeholders))
                )
                """)
            for role in query.filter.roles {
                arguments += [role.rawValue]
            }
        }

        let whereSQL = filters.isEmpty ? "" : "WHERE " + filters.joined(separator: " AND ")
        return (whereSQL, arguments)
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
}
