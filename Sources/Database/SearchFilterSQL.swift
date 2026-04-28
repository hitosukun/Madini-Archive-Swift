import Foundation
import GRDB

/// Single source of truth for the SQL fragments that the conversation
/// list, search, facet, and Stats query paths all share.
///
/// **Why a single helper.**
/// Three repositories (`GRDBConversationRepository`,
/// `GRDBSearchRepository`, and the upcoming `GRDBStatsRepository`)
/// need to translate the same `ArchiveSearchFilter` into the same
/// WHERE predicates. Before this file existed, the conversation- and
/// search-side WHERE builders were near-identical copies that had
/// already drifted in subtle ways (the markdown-exclusion ban almost
/// ended up only on one side, and the Phase 4 "bookmark = pinned
/// prompt" semantic change had to be touched in both places).
/// Pulling the predicate logic here means one bug fix fixes every
/// path, and the new Stats path can't accidentally diverge from the
/// existing two.
///
/// **Why option (i) — static helper, not protocol extension.**
/// The three call sites are not OO members of a shared base type;
/// they're three different repositories that happen to share a
/// translation routine. A static enum-namespaced helper expresses
/// "use this function, period" without forcing each repository into
/// a protocol just to inherit a default. Protocol extensions also
/// would have made the FTS-only branch awkward (every conformer
/// would either have to opt out or be aware of the FTS knob).
///
/// Lives in `Database/` so the file stays inside the AGENTS.md SQL
/// boundary — UI / view-model code never imports this.
enum SearchFilterSQL {

    /// COALESCE expression for "primary time" — the canonical
    /// sortable timestamp of a conversation.
    ///
    /// Consumed by:
    /// - column projection (`\(primaryTimeSQL) AS primary_time`)
    /// - WHERE date-range predicates (`primaryTimeSQL >= ?`)
    /// - Stats GROUP BY (`date(primaryTimeSQL, 'localtime')`)
    /// - the migration-3 expression index in
    ///   `AppServices.bootstrapViewLayerSchema` — the index key
    ///   string MUST stay byte-for-byte in sync with this expression
    ///   for the SQLite planner to use the index on COALESCE-bound
    ///   predicates. If the precedence order or the
    ///   `NULLIF(TRIM(...), '')` wrappers change here, register a
    ///   new migration that drops / recreates
    ///   `idx_conversations_primary_time_expr` in the same commit.
    static let primaryTimeSQL = """
    COALESCE(
        NULLIF(TRIM(c.source_created_at), ''),
        NULLIF(TRIM(c.imported_at), ''),
        NULLIF(TRIM(c.date_str), '')
    )
    """

    /// Optional knobs that distinguish the three caller shapes:
    ///
    /// - The conversation-list / facet paths sometimes need to drop
    ///   one of the filter dimensions (`excludingSources` etc.) so
    ///   the resulting facet shows "every source, regardless of
    ///   which sources the user has currently checked".
    /// - The search path needs an FTS5 `MATCH` term added; the
    ///   FTS expression itself is built externally via
    ///   `SearchQueryParser.parse(...).ftsMatchExpression` and
    ///   passed in here as a string.
    /// - The Stats path uses none of the knobs — Stats is always a
    ///   straight aggregate over the active filter.
    struct Options {
        var excludingSources: Bool = false
        var excludingModels: Bool = false
        var excludingSourceFiles: Bool = false
        /// When non-nil and non-empty, adds `search_idx MATCH ?` to
        /// the WHERE clause. Caller is responsible for tokenizing /
        /// quoting via FTS5's match grammar (typical source:
        /// `SearchQueryParser.parse(...).ftsMatchExpression`).
        var ftsMatchTerm: String? = nil
    }

    /// Build the WHERE fragment + bound arguments for the given
    /// filter. The returned SQL always begins with `WHERE` because
    /// the markdown-source exclusion is unconditional — there is no
    /// scenario in which the workspace queries a markdown
    /// conversation, and structurally enforcing that here means the
    /// other layers can't forget it.
    static func makeWhereClause(
        filter: ArchiveSearchFilter,
        options: Options = Options()
    ) -> (sql: String, arguments: StatementArguments) {
        var filters: [String] = []
        var arguments = StatementArguments()

        // Markdown source = imported markdown documents, not LLM
        // conversations. The list / search / Stats paths all hide
        // them so the user's "what counts as a thread" mental model
        // is consistent across pages.
        filters.append("COALESCE(c.source, '') != 'markdown'")

        if let term = options.ftsMatchTerm, !term.isEmpty {
            filters.append("search_idx MATCH ?")
            arguments += [term]
        }

        if !options.excludingSources, !filter.sources.isEmpty {
            let sortedSources = Array(filter.sources).sorted()
            let placeholders = Array(repeating: "?", count: sortedSources.count).joined(separator: ", ")
            filters.append("c.source IN (\(placeholders))")
            for source in sortedSources {
                arguments += [source]
            }
        }

        if !options.excludingModels, !filter.models.isEmpty {
            let sortedModels = Array(filter.models).sorted()
            let placeholders = Array(repeating: "?", count: sortedModels.count).joined(separator: ", ")
            filters.append("c.model IN (\(placeholders))")
            for model in sortedModels {
                arguments += [model]
            }
        }

        if !options.excludingSourceFiles, !filter.sourceFiles.isEmpty {
            let sortedFiles = Array(filter.sourceFiles).sorted()
            let placeholders = Array(repeating: "?", count: sortedFiles.count).joined(separator: ", ")
            filters.append("c.source_file IN (\(placeholders))")
            for file in sortedFiles {
                arguments += [file]
            }
        }

        if filter.bookmarkedOnly {
            // Phase 4 semantics: "bookmarked threads" = "threads with
            // at least one pinned prompt". Mirrors the
            // `bookmarkStatusSQL` projection in
            // `GRDBConversationRepository` so the filter and the
            // `is_bookmarked` flag agree on what counts.
            filters.append("""
                EXISTS(
                    SELECT 1
                    FROM bookmarks b
                    WHERE b.target_type = 'prompt'
                      AND b.target_id LIKE c.id || ':%'
                )
                """)
        }

        if let dateFrom = filter.dateFrom?.trimmingCharacters(in: .whitespacesAndNewlines),
           !dateFrom.isEmpty {
            filters.append("\(primaryTimeSQL) >= ?")
            arguments += [dateFrom]
        }

        if let dateTo = filter.dateTo?.trimmingCharacters(in: .whitespacesAndNewlines),
           !dateTo.isEmpty {
            filters.append("\(primaryTimeSQL) <= ?")
            arguments += [dateTo]
        }

        if !filter.bookmarkTags.isEmpty {
            let tagPlaceholders = Array(repeating: "?", count: filter.bookmarkTags.count).joined(separator: ", ")
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
            for tag in filter.bookmarkTags {
                arguments += [tag]
            }
        }

        if !filter.roles.isEmpty {
            let sortedRoles = filter.roles.map(\.rawValue).sorted()
            let placeholders = Array(repeating: "?", count: sortedRoles.count).joined(separator: ", ")
            filters.append("""
                EXISTS(
                    SELECT 1
                    FROM messages m
                    WHERE m.conv_id = c.id
                      AND lower(COALESCE(m.role, '')) IN (\(placeholders))
                )
                """)
            for role in sortedRoles {
                arguments += [role]
            }
        }

        return ("WHERE " + filters.joined(separator: " AND "), arguments)
    }
}
