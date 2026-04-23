import CryptoKit
import Foundation
import GRDB

final class GRDBViewService: ViewService, @unchecked Sendable {
    private let dbQueue: DatabaseQueue
    private let recentLimit = 10
    /// Cap for the unified (pinned + recent) filter list.
    private let unifiedLimit = 20

    init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    func listRecentFilters(targetType: ViewTargetType) async throws -> [SavedFilterEntry] {
        try await listEntries(kind: "recent", targetType: targetType)
    }

    func saveRecentFilter(filters: ArchiveSearchFilter, targetType: ViewTargetType) async throws -> SavedFilterEntry? {
        guard filters.hasMeaningfulFilters else {
            return nil
        }

        return try await GRDBAsync.write(to: dbQueue) { db in
            let timestamp = Self.currentTimestamp()
            let filterJSON = try Self.encodeFilters(filters)
            let label = Self.recentLabel(for: filters)
            let filterHash = Self.hash(kind: "recent", label: label, filterJSON: filterJSON)

            if let existing = try Row.fetchOne(
                db,
                sql: """
                    SELECT id, created_at
                    FROM saved_filters
                    WHERE kind = 'recent'
                      AND target_type = ?
                      AND filter_hash = ?
                """,
                arguments: [targetType.rawValue, filterHash]
            ) {
                try db.execute(
                    sql: """
                        UPDATE saved_filters
                        SET label = ?, filter_json = ?, last_used_at = ?
                        WHERE id = ?
                    """,
                    arguments: [label, filterJSON, timestamp, existing["id"]]
                )
            } else {
                try db.execute(
                    sql: """
                        INSERT INTO saved_filters (
                            kind, target_type, filter_hash, label, filter_json, created_at, last_used_at
                        )
                        VALUES ('recent', ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [targetType.rawValue, filterHash, label, filterJSON, timestamp, timestamp]
                )
            }

            // Unified cap: delete oldest non-pinned rows first; only touch
            // pinned rows if pinned-only entries still exceed the cap.
            try Self.enforceUnifiedCap(
                db: db,
                targetType: targetType,
                limit: self.unifiedLimit
            )

            guard let saved = try Row.fetchOne(
                db,
                sql: """
                    SELECT id, kind, target_type, label, filter_json, created_at, last_used_at
                    FROM saved_filters
                    WHERE kind = 'recent'
                      AND target_type = ?
                      AND filter_hash = ?
                """,
                arguments: [targetType.rawValue, filterHash]
            ) else {
                return nil
            }

            return try Self.makeEntry(saved)
        }
    }

    func listSavedViews(targetType: ViewTargetType) async throws -> [SavedViewEntry] {
        try await listEntries(kind: "saved_view", targetType: targetType)
    }

    func saveSavedView(
        name: String,
        filters: ArchiveSearchFilter,
        targetType: ViewTargetType,
        id: Int?
    ) async throws -> SavedViewEntry? {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty, filters.hasMeaningfulFilters else {
            return nil
        }

        return try await GRDBAsync.write(to: dbQueue) { db in
            let timestamp = Self.currentTimestamp()
            let filterJSON = try Self.encodeFilters(filters)
            let filterHash = Self.hash(kind: "saved_view", label: normalizedName, filterJSON: filterJSON)

            if let id {
                try db.execute(
                    sql: """
                        UPDATE saved_filters
                        SET filter_hash = ?, label = ?, filter_json = ?, last_used_at = ?
                        WHERE id = ?
                          AND kind = 'saved_view'
                          AND target_type = ?
                    """,
                    arguments: [filterHash, normalizedName, filterJSON, timestamp, id, targetType.rawValue]
                )
            } else if let existing = try Row.fetchOne(
                db,
                sql: """
                    SELECT id
                    FROM saved_filters
                    WHERE kind = 'saved_view'
                      AND target_type = ?
                      AND label = ?
                    ORDER BY id DESC
                    LIMIT 1
                """,
                arguments: [targetType.rawValue, normalizedName]
            ) {
                try db.execute(
                    sql: """
                        UPDATE saved_filters
                        SET filter_hash = ?, filter_json = ?, last_used_at = ?
                        WHERE id = ?
                    """,
                    arguments: [filterHash, filterJSON, timestamp, existing["id"]]
                )
            } else {
                try db.execute(
                    sql: """
                        INSERT INTO saved_filters (
                            kind, target_type, filter_hash, label, filter_json, created_at, last_used_at
                        )
                        VALUES ('saved_view', ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [targetType.rawValue, filterHash, normalizedName, filterJSON, timestamp, timestamp]
                )
            }

            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT id, kind, target_type, label, filter_json, created_at, last_used_at
                    FROM saved_filters
                    WHERE kind = 'saved_view'
                      AND target_type = ?
                      AND label = ?
                    ORDER BY id DESC
                    LIMIT 1
                """,
                arguments: [targetType.rawValue, normalizedName]
            ) else {
                return nil
            }

            return try Self.makeEntry(row)
        }
    }

    func deleteSavedView(id: Int, targetType: ViewTargetType) async throws -> Bool {
        try await GRDBAsync.write(to: dbQueue) { db in
            try db.execute(
                sql: """
                    DELETE FROM saved_filters
                    WHERE id = ?
                      AND kind = 'saved_view'
                      AND target_type = ?
                """,
                arguments: [id, targetType.rawValue]
            )
            return db.changesCount > 0
        }
    }

    // MARK: Unified Recent/Pinned API

    func listUnifiedFilters(targetType: ViewTargetType, limit: Int) async throws -> [SavedFilterEntry] {
        let effectiveLimit = limit > 0 ? limit : unifiedLimit
        return try await GRDBAsync.read(from: dbQueue) { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, kind, target_type, label, filter_json,
                           created_at, last_used_at, pinned
                    FROM saved_filters
                    WHERE target_type = ?
                    ORDER BY pinned DESC, last_used_at DESC, created_at DESC, id DESC
                    LIMIT ?
                """,
                arguments: [targetType.rawValue, effectiveLimit]
            )
            return rows.compactMap { row in
                do { return try Self.makeEntry(row) } catch { return nil }
            }
        }
    }

    func togglePinnedFilter(id: Int, targetType: ViewTargetType) async throws -> Bool {
        try await GRDBAsync.write(to: dbQueue) { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT pinned FROM saved_filters WHERE id = ? AND target_type = ?",
                arguments: [id, targetType.rawValue]
            ) else {
                return false
            }
            let current = (row["pinned"] as Int64?) ?? 0
            let next: Int64 = current == 0 ? 1 : 0
            try db.execute(
                sql: "UPDATE saved_filters SET pinned = ? WHERE id = ?",
                arguments: [next, id]
            )
            return next == 1
        }
    }

    func deleteFilter(id: Int, targetType: ViewTargetType) async throws -> Bool {
        try await GRDBAsync.write(to: dbQueue) { db in
            try db.execute(
                sql: "DELETE FROM saved_filters WHERE id = ? AND target_type = ?",
                arguments: [id, targetType.rawValue]
            )
            return db.changesCount > 0
        }
    }

    func renameFilter(id: Int, targetType: ViewTargetType, newName: String) async throws -> Bool {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return try await GRDBAsync.write(to: dbQueue) { db in
            // Promote the row to `saved_view` kind at the same time. A
            // named entry is inherently user-curated, so keeping it
            // under the `recent` churn (auto-eviction, label
            // regeneration on re-save) would silently undo the user's
            // naming intent the next time they ran a matching query.
            // `filter_hash` is left alone — it's keyed off label to
            // let `saveRecentFilter` dedupe autogenerated labels, and
            // a renamed row intentionally stops participating in that
            // dedup path.
            try db.execute(
                sql: """
                    UPDATE saved_filters
                    SET label = ?, kind = 'saved_view'
                    WHERE id = ? AND target_type = ?
                """,
                arguments: [trimmed, id, targetType.rawValue]
            )
            return db.changesCount > 0
        }
    }

    func buildVirtualThreadPreview(
        filters: ArchiveSearchFilter,
        targetType: ViewTargetType
    ) async throws -> VirtualThreadPreview {
        let items = try await buildVirtualThread(title: Self.recentLabel(for: filters), filters: filters, targetType: targetType)
        return VirtualThreadPreview(title: items.title, count: items.items.count)
    }

    func buildVirtualThread(
        title: String,
        filters: ArchiveSearchFilter,
        targetType: ViewTargetType
    ) async throws -> VirtualThread {
        let query = SearchQuery(filter: filters, offset: 0, limit: 100)
        let items = try await GRDBAsync.read(from: dbQueue) { db in
            let (filterSQL, arguments) = GRDBSearchRepository.makeSearchWhereClause(query: query)
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT
                        c.id AS conversation_id,
                        c.title,
                        c.source,
                        c.model,
                        COALESCE(
                            NULLIF(TRIM(c.source_created_at), ''),
                            NULLIF(TRIM(c.imported_at), ''),
                            NULLIF(TRIM(c.date_str), '')
                        ) AS primary_time,
                        snippet(search_idx, 2, '[', ']', ' … ', 12) AS snippet
                    FROM search_idx
                    JOIN conversations c ON c.id = search_idx.conv_id
                    \(filterSQL)
                    ORDER BY primary_time DESC, c.id ASC
                    LIMIT 100
                """,
                arguments: arguments
            )

            return rows.enumerated().map { index, row in
                VirtualThreadItem(
                    id: "vt:\(row["conversation_id"] as String? ?? ""):\(index)",
                    conversationID: row["conversation_id"] ?? "",
                    messageIndex: 0,
                    title: row["title"] ?? "Untitled",
                    snippet: row["snippet"] ?? "",
                    source: row["source"],
                    model: row["model"],
                    primaryTime: row["primary_time"]
                )
            }
        }

        return VirtualThread(title: title, filters: filters, items: items)
    }

    private func listEntries(kind: String, targetType: ViewTargetType) async throws -> [SavedFilterEntry] {
        try await GRDBAsync.read(from: dbQueue) { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, kind, target_type, label, filter_json, created_at, last_used_at
                    FROM saved_filters
                    WHERE kind = ?
                      AND target_type = ?
                    ORDER BY last_used_at DESC, created_at DESC, id DESC
                """,
                arguments: [kind, targetType.rawValue]
            )

            return rows.compactMap { row in
                do {
                    return try Self.makeEntry(row)
                } catch {
                    print("Skipping invalid saved filter row: \(error)")
                    return nil
                }
            }
        }
    }

    private static func makeEntry(_ row: Row) throws -> SavedFilterEntry {
        let data = Data((row["filter_json"] as String? ?? "{}").utf8)
        let filters = try JSONDecoder().decode(ArchiveSearchFilter.self, from: data)
        let lastUsedAt: String = row["last_used_at"] ?? ""
        let pinnedInt = (row["pinned"] as Int64?) ?? 0
        return SavedFilterEntry(
            id: Int(row["id"] as Int64? ?? 0),
            kind: row["kind"] ?? "",
            targetType: ViewTargetType(rawValue: row["target_type"] ?? "") ?? .virtualThread,
            name: row["label"] ?? "Untitled",
            filters: filters,
            createdAt: row["created_at"] ?? lastUsedAt,
            updatedAt: lastUsedAt,
            lastUsedAt: lastUsedAt,
            pinned: pinnedInt != 0
        )
    }

    private static func encodeFilters(_ filters: ArchiveSearchFilter) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(filters)
        return String(decoding: data, as: UTF8.self)
    }

    /// Evicts oldest entries until `saved_filters` row count for the given
    /// target is at or below `limit`. Non-pinned rows are evicted first; if
    /// pinned rows alone exceed the cap the oldest pinned rows are evicted.
    private static func enforceUnifiedCap(
        db: Database,
        targetType: ViewTargetType,
        limit: Int
    ) throws {
        // Stage 1: drop oldest non-pinned until total <= limit.
        let nonPinnedOverflow = try Row.fetchAll(
            db,
            sql: """
                SELECT id FROM saved_filters
                WHERE target_type = ? AND pinned = 0
                ORDER BY last_used_at ASC, created_at ASC, id ASC
            """,
            arguments: [targetType.rawValue]
        )
        var total = try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM saved_filters WHERE target_type = ?",
            arguments: [targetType.rawValue]
        ) ?? 0
        for row in nonPinnedOverflow where total > limit {
            try db.execute(sql: "DELETE FROM saved_filters WHERE id = ?", arguments: [row["id"]])
            total -= 1
        }
        // Stage 2: if still above the cap, drop oldest pinned rows.
        if total > limit {
            let pinnedOverflow = try Row.fetchAll(
                db,
                sql: """
                    SELECT id FROM saved_filters
                    WHERE target_type = ? AND pinned = 1
                    ORDER BY last_used_at ASC, created_at ASC, id ASC
                """,
                arguments: [targetType.rawValue]
            )
            for row in pinnedOverflow where total > limit {
                try db.execute(sql: "DELETE FROM saved_filters WHERE id = ?", arguments: [row["id"]])
                total -= 1
            }
        }
    }

    private static func hash(kind: String, label: String, filterJSON: String) -> String {
        let digest = SHA256.hash(data: Data("\(kind)|\(label)|\(filterJSON)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func recentLabel(for filters: ArchiveSearchFilter) -> String {
        if !filters.normalizedKeyword.isEmpty {
            return filters.normalizedKeyword
        }
        if let source = filters.source {
            return "source: \(source)"
        }
        if let model = filters.model {
            return "model: \(model)"
        }
        if filters.bookmarkedOnly {
            return "bookmarked"
        }
        return "Filtered View"
    }

    private static func currentTimestamp() -> String {
        TimestampFormatter.now()
    }
}
