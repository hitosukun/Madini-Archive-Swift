import Foundation
import GRDB

/// Aggregations powering the Dashboard (Stats) middle-pane mode.
///
/// Every method is a bounded GROUP BY against the `conversations`
/// table (with a `messages` join for the prompt-counting heatmaps).
/// No intermediate state, no caching layer — per AGENTS.md, Stats is
/// a *derived* view that the user re-evaluates whenever the filter
/// scope changes. This file is the only place SQL for Stats lives.
///
/// **Filter handling.** All queries delegate WHERE assembly to
/// `SearchFilterSQL.makeWhereClause`, the same helper the
/// conversation list and search paths use. The shared helper means
/// Stats can never silently disagree with the rest of the app on
/// what the filter is scoped to (e.g. the markdown-source exclusion,
/// or the date-range predicate's reliance on the migration-3
/// expression index).
///
/// **Time grouping.** All time-axis charts pass `primary_time`
/// through `SQLite`'s `'localtime'` modifier on `date()` /
/// `strftime()`. The "blue tile" timezone bug from the SPEC — UTC
/// midnight rows landing on the wrong calendar day — is structurally
/// prevented because we never carry a UTC timestamp into Swift; the
/// bucket key is materialized inside SQLite under `'localtime'`.
///
/// **Bounding.** The category charts are top-N (10 for models,
/// natural for sources since the canonical universe is small); the
/// time-axis charts are windowed to the trailing 24 months / 365
/// days so they render predictably even at the user's projected
/// 100x scale. The view doesn't virtualize.
final class GRDBStatsRepository: StatsRepository, @unchecked Sendable {
    private let dbQueue: DatabaseQueue

    init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    // MARK: - Source breakdown

    func sourceBreakdown(filter: ArchiveSearchFilter) async throws -> [SourceCount] {
        try await GRDBAsync.read(from: dbQueue) { db in
            let (whereSQL, arguments) = SearchFilterSQL.makeWhereClause(filter: filter)
            // Per the WHERE clause, markdown rows are already gone;
            // we additionally drop NULL / blank source rows here so
            // the chart's "label" axis stays meaningful.
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT
                        c.source AS label,
                        COUNT(*) AS count
                    FROM conversations c
                    \(whereSQL)
                      AND c.source IS NOT NULL
                      AND TRIM(c.source) <> ''
                    GROUP BY c.source
                    ORDER BY count DESC, label ASC
                    """,
                arguments: arguments
            )
            return rows.compactMap { row -> SourceCount? in
                guard let label: String = row["label"] else { return nil }
                return SourceCount(label: label, count: row["count"] ?? 0)
            }
        }
    }

    // MARK: - Model breakdown

    func modelBreakdown(filter: ArchiveSearchFilter) async throws -> [ModelCount] {
        try await GRDBAsync.read(from: dbQueue) { db in
            let (whereSQL, arguments) = SearchFilterSQL.makeWhereClause(filter: filter)
            // NULL / blank model names collapse into a single
            // `'Unknown'` bucket so the chart never grows an
            // unbounded "blank" slice (Phase 0 finding: model is
            // free-form text, no enum constraint, blanks are
            // common). Top 10 cap keeps the chart legible — the
            // long tail of model variants would otherwise produce
            // 60+ slices.
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT
                        CASE
                            WHEN c.model IS NULL OR TRIM(c.model) = '' THEN 'Unknown'
                            ELSE c.model
                        END AS label,
                        COUNT(*) AS count
                    FROM conversations c
                    \(whereSQL)
                    GROUP BY label
                    ORDER BY count DESC, label ASC
                    LIMIT 10
                    """,
                arguments: arguments
            )
            return rows.map { row in
                ModelCount(label: row["label"] ?? "Unknown", count: row["count"] ?? 0)
            }
        }
    }

    // MARK: - Monthly breakdown

    func monthlyBreakdown(filter: ArchiveSearchFilter) async throws -> [MonthlyCount] {
        try await GRDBAsync.read(from: dbQueue) { db in
            let (whereSQL, arguments) = SearchFilterSQL.makeWhereClause(filter: filter)
            // Window: trailing 24 months. We GROUP / ORDER DESC,
            // LIMIT 24, then reverse in Swift so callers receive
            // chronological order — the chart x-axis reads
            // left-to-right.
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT
                        strftime('%Y-%m', \(SearchFilterSQL.primaryTimeSQL), 'localtime') AS year_month,
                        COUNT(DISTINCT c.id) AS conversation_count,
                        SUM(CASE WHEN m.role = 'user' THEN 1 ELSE 0 END) AS prompt_count
                    FROM conversations c
                    LEFT JOIN messages m ON m.conv_id = c.id
                    \(whereSQL)
                      AND \(SearchFilterSQL.primaryTimeSQL) IS NOT NULL
                    GROUP BY year_month
                    ORDER BY year_month DESC
                    LIMIT 24
                    """,
                arguments: arguments
            )
            return rows.compactMap { row -> MonthlyCount? in
                guard let yearMonth: String = row["year_month"] else { return nil }
                return MonthlyCount(
                    yearMonth: yearMonth,
                    conversationCount: row["conversation_count"] ?? 0,
                    promptCount: row["prompt_count"] ?? 0
                )
            }.reversed()
        }
    }

    // MARK: - Daily heatmap

    func dailyHeatmap(filter: ArchiveSearchFilter) async throws -> [DailyCount] {
        try await GRDBAsync.read(from: dbQueue) { db in
            let (whereSQL, arguments) = SearchFilterSQL.makeWhereClause(filter: filter)
            // Window: trailing 365 days. Same reverse-order trick
            // as the monthly query so the GitHub-contributions
            // grid reads left-to-right (oldest to newest).
            //
            // Per Phase 0: `messages` has no per-row timestamp, so
            // every prompt within a conversation is bucketed by
            // its parent conversation's `primary_time`. The user
            // is aware of this approximation (SPEC §5.8 calls it
            // out explicitly).
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT
                        date(\(SearchFilterSQL.primaryTimeSQL), 'localtime') AS day,
                        COUNT(m.id) AS prompt_count
                    FROM messages m
                    JOIN conversations c ON m.conv_id = c.id
                    \(whereSQL)
                      AND m.role = 'user'
                      AND \(SearchFilterSQL.primaryTimeSQL) IS NOT NULL
                    GROUP BY day
                    ORDER BY day DESC
                    LIMIT 365
                    """,
                arguments: arguments
            )
            return rows.compactMap { row -> DailyCount? in
                guard let day: String = row["day"] else { return nil }
                return DailyCount(date: day, promptCount: row["prompt_count"] ?? 0)
            }.reversed()
        }
    }

    // MARK: - Hour × weekday heatmap

    func hourWeekdayHeatmap(filter: ArchiveSearchFilter) async throws -> [HourWeekdayCount] {
        try await GRDBAsync.read(from: dbQueue) { db in
            let (whereSQL, arguments) = SearchFilterSQL.makeWhereClause(filter: filter)
            // 7 × 24 grid. Missing cells are zero by convention —
            // the view fills the gap rather than the SQL
            // CROSS JOIN ing a calendar table. `strftime('%w')`
            // returns Sunday=0..Saturday=6, matching `Calendar`'s
            // default firstWeekday on en_US locales (which is what
            // SwiftUI Charts assumes for axis labels).
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT
                        CAST(strftime('%w', \(SearchFilterSQL.primaryTimeSQL), 'localtime') AS INTEGER) AS weekday,
                        CAST(strftime('%H', \(SearchFilterSQL.primaryTimeSQL), 'localtime') AS INTEGER) AS hour,
                        COUNT(m.id) AS count
                    FROM messages m
                    JOIN conversations c ON m.conv_id = c.id
                    \(whereSQL)
                      AND m.role = 'user'
                      AND \(SearchFilterSQL.primaryTimeSQL) IS NOT NULL
                    GROUP BY weekday, hour
                    ORDER BY weekday ASC, hour ASC
                    """,
                arguments: arguments
            )
            return rows.compactMap { row -> HourWeekdayCount? in
                guard let weekday: Int = row["weekday"],
                      let hour: Int = row["hour"] else {
                    return nil
                }
                return HourWeekdayCount(
                    weekday: weekday,
                    hour: hour,
                    count: row["count"] ?? 0
                )
            }
        }
    }
}
