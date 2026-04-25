import Foundation
import GRDB

final class GRDBSearchRepository: SearchRepository, @unchecked Sendable {
    private let dbQueue: DatabaseQueue

    init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    func search(query: SearchQuery) async throws -> [SearchResult] {
        guard Self.shouldExecute(query: query) else {
            return []
        }

        // Short positive tokens (`編集`, `削除`, …) can't be matched by
        // the FTS5 trigram tokenizer — it indexes 3-grams, so any
        // 2-character query produces zero hits. Take the LIKE fallback
        // path instead so 2-char Japanese keywords actually surface
        // results.
        if !query.normalizedText.isEmpty,
           !SearchQueryParser.parse(query.normalizedText).likeFallbackTerms.isEmpty {
            return try await searchViaLike(query: query)
        }

        return try await GRDBAsync.read(from: dbQueue) { db in
            let (filterSQL, arguments) = Self.makeSearchWhereClause(query: query)
            let orderSQL = Self.orderByClause(for: query.sortKey)
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
                    \(orderSQL)
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
        guard Self.shouldExecute(query: query) else {
            return 0
        }

        if !query.normalizedText.isEmpty,
           !SearchQueryParser.parse(query.normalizedText).likeFallbackTerms.isEmpty {
            return try await countViaLike(query: query)
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

    // MARK: - LIKE fallback (sub-trigram queries)

    /// Run the search via plain `LIKE` against `conversations.title` and
    /// `messages.content`. Used only when the parsed query contains a
    /// positive token shorter than the trigram tokenizer's 3-character
    /// floor — which happens routinely for 2-character Japanese words
    /// (`編集`, `削除`, `追加`). Slower than FTS but correct.
    private func searchViaLike(query: SearchQuery) async throws -> [SearchResult] {
        return try await GRDBAsync.read(from: dbQueue) { db in
            let (whereSQL, arguments) = Self.makeLikeWhereClause(query: query)
            let orderSQL = Self.likeOrderByClause(for: query.sortKey)
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
                        \(Self.primaryTimeSQL) AS primary_time
                        \(Self.bookmarkStatusSQL) AS is_bookmarked
                    FROM conversations c
                    \(whereSQL)
                    \(orderSQL)
                    LIMIT ? OFFSET ?
                """,
                arguments: arguments + [query.limit, query.offset]
            )

            return rows.map { row in
                let title: String? = row["title"]
                let firstMessage: String? = row["first_message_snippet"]
                // No FTS5 `snippet()` available on this path — fall
                // back to the headline / title text. The list-row
                // renderer trims to the visible width on its own.
                let snippet = (title?.isEmpty == false ? title : firstMessage) ?? ""
                return SearchResult(
                    conversationID: row["conversation_id"],
                    headline: ConversationHeadlineSummary.build(
                        prompt: row["headline_prompt"],
                        title: title,
                        firstMessage: firstMessage
                    ),
                    title: title,
                    source: row["source"],
                    model: row["model"],
                    messageCount: row["prompt_count"] ?? 0,
                    primaryTime: row["primary_time"],
                    snippet: snippet,
                    isBookmarked: (row["is_bookmarked"] as Int64? ?? 0) != 0
                )
            }
        }
    }

    private func countViaLike(query: SearchQuery) async throws -> Int {
        return try await GRDBAsync.read(from: dbQueue) { db in
            let (whereSQL, arguments) = Self.makeLikeWhereClause(query: query)
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

    /// Build the LIKE-fallback `WHERE` clause + bound arguments. Each
    /// positive term contributes either a `c.title LIKE ?` predicate
    /// (title-scoped) or an `EXISTS(... messages)` predicate (content-
    /// or any-scoped) — joined with AND so multiple keywords narrow
    /// the result set, mirroring FTS5's implicit-AND behaviour.
    /// Non-text filters (sources, dates, bookmarks) reuse the regular
    /// where-clause builder so the two paths stay in lockstep.
    private static func makeLikeWhereClause(
        query: SearchQuery
    ) -> (String, StatementArguments) {
        var filters: [String] = ["COALESCE(c.source, '') != 'markdown'"]
        var arguments = StatementArguments()

        for term in SearchQueryParser.parse(query.normalizedText).likeFallbackTerms {
            let pattern = "%\(escapeLikePattern(term.text))%"
            switch term.scope {
            case .title:
                filters.append("c.title LIKE ? ESCAPE '\\'")
                arguments += [pattern]
            case .content:
                filters.append("""
                    EXISTS(
                        SELECT 1 FROM messages m
                        WHERE m.conv_id = c.id
                          AND m.content LIKE ? ESCAPE '\\'
                    )
                    """)
                arguments += [pattern]
            case .any:
                filters.append("""
                    (
                        c.title LIKE ? ESCAPE '\\'
                        OR EXISTS(
                            SELECT 1 FROM messages m
                            WHERE m.conv_id = c.id
                              AND m.content LIKE ? ESCAPE '\\'
                        )
                    )
                    """)
                arguments += [pattern, pattern]
            }
        }

        let (sharedSQL, sharedArgs) = Self.makeNonTextFiltersClause(query: query)
        if !sharedSQL.isEmpty {
            filters.append(sharedSQL)
            arguments += sharedArgs
        }

        let whereSQL = "WHERE " + filters.joined(separator: " AND ")
        return (whereSQL, arguments)
    }

    private static func likeOrderByClause(for sortKey: ConversationSortKey?) -> String {
        switch sortKey {
        case .dateAsc:         return "ORDER BY \(primaryTimeSQL) ASC, c.id ASC"
        case .promptCountDesc: return "ORDER BY c.prompt_count DESC, c.id ASC"
        case .promptCountAsc:  return "ORDER BY c.prompt_count ASC, c.id ASC"
        case .dateDesc, .none: return "ORDER BY \(primaryTimeSQL) DESC, c.id ASC"
        }
    }

    /// Escape `%`, `_`, `\` for `LIKE … ESCAPE '\\'`. Without escaping
    /// a query like `100%` would silently match anything.
    private static func escapeLikePattern(_ raw: String) -> String {
        var out = ""
        for c in raw {
            if c == "\\" || c == "%" || c == "_" {
                out.append("\\")
            }
            out.append(c)
        }
        return out
    }

    /// Build the `ORDER BY` clause for a search fetch. Nil = keep the
    /// legacy relevance-first ordering (bm25 rank, then date). A non-nil
    /// `sortKey` dominates the ordering with relevance kept as the
    /// stable tie-breaker so results with equal sort values still come
    /// back in a deterministic order (and favour the best match within
    /// each bucket). This is how `sort:updated-asc` typed into the
    /// toolbar reaches the SQL layer — without it, the FTS path was
    /// silently ignoring the directive.
    private static func orderByClause(for sortKey: ConversationSortKey?) -> String {
        guard let sortKey else {
            return "ORDER BY rank ASC, primary_time DESC, c.id ASC"
        }
        switch sortKey {
        case .dateDesc:
            return "ORDER BY primary_time DESC, rank ASC, c.id ASC"
        case .dateAsc:
            return "ORDER BY primary_time ASC, rank ASC, c.id ASC"
        case .promptCountDesc:
            return "ORDER BY c.prompt_count DESC, rank ASC, c.id ASC"
        case .promptCountAsc:
            return "ORDER BY c.prompt_count ASC, rank ASC, c.id ASC"
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

    /// Guard used by both `search` and `count` to decide whether the
    /// query should actually hit the database. Three cases reject:
    ///
    /// 1. No meaningful filters at all (the legacy bail).
    /// 2. The user typed search text, but the parser couldn't turn it
    ///    into a positive FTS5 expression — e.g. `-foo` on its own.
    ///    Without this guard the FROM clause would end up as an
    ///    unconstrained FTS5 JOIN and return every row in the index.
    /// 3. Case 2 happened but there are other non-text filters → we
    ///    still bail, because returning "everything matching source=X"
    ///    when the user's text search produced nothing is surprising
    ///    (they expect zero results from "exclude foo").
    ///
    /// The third point is a conscious UX choice: the user can combine
    /// `-foo` with any positive term (`bar -foo`) when they want to
    /// exclude from a real result set. Pure-negation-plus-filter
    /// returning the filter's full set was the old behaviour that
    /// looked like a bug.
    private static func shouldExecute(query: SearchQuery) -> Bool {
        guard query.filter.hasMeaningfulFilters else { return false }

        let hasText = !query.normalizedText.isEmpty
        if hasText {
            // Text typed but unparseable (only negations, only
            // separators, etc.) → reject. The LIKE fallback path is
            // also a valid execution route — only reject when neither
            // FTS nor LIKE has anything actionable.
            let parsed = SearchQueryParser.parse(query.normalizedText)
            guard parsed.ftsMatchExpression != nil || !parsed.likeFallbackTerms.isEmpty else {
                return false
            }
            return true
        }

        // No text search — require at least one other filter to be
        // set, otherwise we'd return every conversation.
        return query.filter.bookmarkedOnly
            || !query.filter.sources.isEmpty
            || !query.filter.models.isEmpty
            || !query.filter.sourceFiles.isEmpty
            || query.filter.dateFrom != nil
            || query.filter.dateTo != nil
            || !query.filter.roles.isEmpty
            || !query.filter.bookmarkTags.isEmpty
    }

    static func makeSearchWhereClause(
        query: SearchQuery,
        includePagination: Bool = true
    ) -> (String, StatementArguments) {
        var filters: [String] = []
        var arguments = StatementArguments()

        // Markdown import 会話は render 未対応として全面除外。
        // `GRDBConversationRepository.makeConversationWhereClause` と揃える。
        filters.append("COALESCE(c.source, '') != 'markdown'")

        if !query.normalizedText.isEmpty,
           let match = SearchQueryParser.parse(query.normalizedText).ftsMatchExpression {
            filters.append("search_idx MATCH ?")
            arguments += [match]
        }

        let (nonTextSQL, nonTextArgs) = makeNonTextFiltersClause(query: query)
        if !nonTextSQL.isEmpty {
            filters.append(nonTextSQL)
            arguments += nonTextArgs
        }

        let whereSQL = filters.isEmpty ? "" : "WHERE " + filters.joined(separator: " AND ")
        return (whereSQL, arguments)
    }

    /// All conversation-level filters (sources, models, dates, bookmarks,
    /// roles, tags) packaged as a single AND-joined SQL fragment without
    /// the leading `WHERE`. Shared between the FTS path and the LIKE
    /// fallback so the two routes stay in lockstep when the filter
    /// surface grows.
    private static func makeNonTextFiltersClause(
        query: SearchQuery
    ) -> (String, StatementArguments) {
        var filters: [String] = []
        var arguments = StatementArguments()

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

        if !query.filter.sourceFiles.isEmpty {
            let sortedFiles = Array(query.filter.sourceFiles).sorted()
            let placeholders = Array(repeating: "?", count: sortedFiles.count).joined(separator: ", ")
            filters.append("c.source_file IN (\(placeholders))")
            for file in sortedFiles {
                arguments += [file]
            }
        }

        if query.filter.bookmarkedOnly {
            // Phase 4: "bookmarked threads" = "threads with at least one
            // pinned prompt". Kept in lockstep with
            // `GRDBConversationRepository.bookmarkStatusSQL`.
            filters.append("""
                EXISTS(
                    SELECT 1
                    FROM bookmarks b
                    WHERE b.target_type = 'prompt'
                      AND b.target_id LIKE c.id || ':%'
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
                      AND b.target_type = 'thread'
                      AND b.target_id = c.id
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

        // Combined as a single AND-joined fragment. Empty when no
        // non-text filters are set, so callers can decide whether to
        // append it or skip the AND glue entirely.
        let combined = filters.isEmpty ? "" : "(" + filters.joined(separator: " AND ") + ")"
        return (combined, arguments)
    }

}
