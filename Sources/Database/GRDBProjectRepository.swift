import Foundation
import GRDB

/// SQLite-backed `ProjectRepository` that persists against the tables
/// declared in `ProjectSchemaDraft` (`project`, `project_membership`,
/// `project_suggestion`). Mirrors the behaviour of `MockProjectRepository`
/// row-for-row — callers shouldn't have to care which implementation
/// they got from `AppServices`.
///
/// Threading model: `@unchecked Sendable` (same pattern as
/// `GRDBTagRepository`) because `DatabaseQueue` is internally
/// thread-safe and we never mutate instance state outside the queue.
/// All public methods hop off the main actor via `GRDBAsync.read/write`.
///
/// Conversion between Swift `Date` and the stored
/// `'yyyy-MM-dd HH:mm:ss'` strings goes through `TimestampFormatter` —
/// matches what `bookmark_tags` / `bookmarks` do, so a future
/// cross-table query reads one date format.
final class GRDBProjectRepository: ProjectRepository, @unchecked Sendable {
    private let dbQueue: DatabaseQueue

    init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    // MARK: - Projects

    func listProjects() async throws -> [Project] {
        try await GRDBAsync.read(from: dbQueue) { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, name, external_source, external_folder_id,
                           sort_index, created_at
                    FROM project
                    ORDER BY sort_index ASC, created_at ASC
                """
            )
            return rows.compactMap(Self.mapProject)
        }
    }

    func createProject(name: String) async throws -> Project {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ProjectRepositoryError.emptyName }

        return try await GRDBAsync.write(to: dbQueue) { db in
            // Case-insensitive uniqueness — matches MockProjectRepository's
            // behaviour. Done in-query rather than via a UNIQUE INDEX so
            // we can surface a structured error instead of a SQLite
            // constraint violation, and so a re-import that happens to
            // reuse a user-typed name doesn't fail silently.
            let existing = try Int.fetchOne(
                db,
                sql: """
                    SELECT 1 FROM project
                    WHERE LOWER(name) = LOWER(?)
                    LIMIT 1
                """,
                arguments: [trimmed]
            )
            if existing != nil {
                throw ProjectRepositoryError.invariantViolated(
                    "Project '\(trimmed)' already exists."
                )
            }

            let id = ProjectID(UUID().uuidString.lowercased())
            let now = Date()
            let nextSortIndex = (try Int.fetchOne(
                db,
                sql: "SELECT COALESCE(MAX(sort_index), -1) + 1 FROM project"
            )) ?? 0

            try db.execute(
                sql: """
                    INSERT INTO project (
                        id, name, external_source, external_folder_id,
                        sort_index, created_at
                    )
                    VALUES (?, ?, NULL, NULL, ?, ?)
                """,
                arguments: [
                    id.rawValue, trimmed,
                    nextSortIndex, TimestampFormatter.string(from: now)
                ]
            )
            return Project(
                id: id,
                name: trimmed,
                externalSource: nil,
                sortIndex: nextSortIndex,
                createdAt: now
            )
        }
    }

    func renameProject(id: ProjectID, name: String) async throws -> Project {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ProjectRepositoryError.emptyName }

        return try await GRDBAsync.write(to: dbQueue) { db in
            try db.execute(
                sql: "UPDATE project SET name = ? WHERE id = ?",
                arguments: [trimmed, id.rawValue]
            )
            // Deliberately no changesCount check here — the followup
            // SELECT below returns `notFound` if the id didn't exist,
            // so an update that matched zero rows surfaces as the same
            // error the caller already handles.
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT id, name, external_source, external_folder_id,
                           sort_index, created_at
                    FROM project WHERE id = ?
                """,
                arguments: [id.rawValue]
            ), let project = Self.mapProject(row) else {
                throw ProjectRepositoryError.notFound
            }
            return project
        }
    }

    func deleteProject(id: ProjectID) async throws {
        try await GRDBAsync.write(to: dbQueue) { db in
            // Look the row up first so we can tell "not found" from
            // "found and deleted" — DELETE returns silently either way.
            // The FK on project_membership.project_id is declared
            // ON DELETE CASCADE, so child memberships + suggestions
            // (also FK'd to project) go with the parent in one stroke.
            // This matches MockProjectRepository's "become unassigned"
            // behaviour because the cascaded-away memberships are the
            // only thing holding threads in the project.
            guard try Int.fetchOne(
                db,
                sql: "SELECT 1 FROM project WHERE id = ?",
                arguments: [id.rawValue]
            ) != nil else {
                throw ProjectRepositoryError.notFound
            }
            try db.execute(
                sql: "DELETE FROM project WHERE id = ?",
                arguments: [id.rawValue]
            )
        }
    }

    // MARK: - Memberships

    func membership(for threadID: String) async throws -> ProjectMembership? {
        try await GRDBAsync.read(from: dbQueue) { db in
            let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT id, thread_id, project_id, type, assigned_at,
                           accepted_score, accepted_reason
                    FROM project_membership
                    WHERE thread_id = ?
                """,
                arguments: [threadID]
            )
            return row.flatMap(Self.mapMembership)
        }
    }

    func statuses(forThreadIDs ids: [String]) async throws -> [String: ProjectThreadStatus] {
        guard !ids.isEmpty else { return [:] }

        return try await GRDBAsync.read(from: dbQueue) { db in
            // Batch the IN clause ourselves rather than relying on a
            // GRDB helper — keeps the SQL pasteable into any SQLite
            // client for debugging.
            let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
            let args = StatementArguments(ids)

            let membershipRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, thread_id, project_id, type, assigned_at,
                           accepted_score, accepted_reason
                    FROM project_membership
                    WHERE thread_id IN (\(placeholders))
                """,
                arguments: args
            )
            let memberships: [String: ProjectMembership] = membershipRows.reduce(into: [:]) { acc, row in
                if let m = Self.mapMembership(row) {
                    acc[m.threadID] = m
                }
            }

            // Top-suggestion-per-thread via a window-ish pattern that
            // SQLite doesn't have natively — we join the suggestion
            // table to itself and keep rows that are the max-scoring
            // candidate for their thread. Cheaper than fetching all
            // rows and topping in Swift when the thread list is small
            // (typical call is ≤50 IDs).
            let policy = SuggestionPolicy()
            let suggestionRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT s.id, s.thread_id, s.candidate_project_id,
                           s.score, s.reason_terms, s.computed_at
                    FROM project_suggestion s
                    WHERE s.thread_id IN (\(placeholders))
                      AND s.score >= ?
                      AND NOT EXISTS (
                          SELECT 1 FROM project_suggestion s2
                          WHERE s2.thread_id = s.thread_id
                            AND s2.score > s.score
                      )
                """,
                arguments: args + [policy.minScore]
            )
            let suggestions: [String: ProjectSuggestion] = suggestionRows.reduce(into: [:]) { acc, row in
                if let s = Self.mapSuggestion(row) {
                    // There can still be ties at the max score; pick
                    // the most recently computed one deterministically.
                    if let prior = acc[s.threadID], prior.computedAt >= s.computedAt {
                        return
                    }
                    acc[s.threadID] = s
                }
            }

            var result: [String: ProjectThreadStatus] = [:]
            for threadID in ids {
                let m = memberships[threadID]
                // Spec: if a thread is assigned, no suggestion surfaces.
                let topSuggestion: ProjectSuggestion? = (m == nil) ? suggestions[threadID] : nil
                result[threadID] = ProjectThreadStatus(
                    threadID: threadID,
                    membership: m,
                    topSuggestion: topSuggestion
                )
            }
            return result
        }
    }

    @discardableResult
    func setManualMembership(threadID: String, projectID: ProjectID) async throws -> ProjectMembership {
        try await GRDBAsync.write(to: dbQueue) { db in
            guard try Int.fetchOne(
                db,
                sql: "SELECT 1 FROM project WHERE id = ?",
                arguments: [projectID.rawValue]
            ) != nil else {
                throw ProjectRepositoryError.notFound
            }

            let membershipID = ProjectMembershipID("m-\(threadID)")
            let now = Date()
            let nowString = TimestampFormatter.string(from: now)

            // UPSERT on thread_id — the UNIQUE constraint on
            // project_membership.thread_id lets us lean on SQLite's
            // `ON CONFLICT` clause instead of a read-modify-write
            // round-trip. Matches MockProjectRepository's "always
            // replace" contract for manual assignments.
            try db.execute(
                sql: """
                    INSERT INTO project_membership (
                        id, thread_id, project_id, type,
                        assigned_at, accepted_score, accepted_reason
                    )
                    VALUES (?, ?, ?, 'manual_add', ?, NULL, NULL)
                    ON CONFLICT(thread_id) DO UPDATE SET
                        id              = excluded.id,
                        project_id      = excluded.project_id,
                        type            = 'manual_add',
                        assigned_at     = excluded.assigned_at,
                        accepted_score  = NULL,
                        accepted_reason = NULL
                """,
                arguments: [
                    membershipID.rawValue, threadID, projectID.rawValue,
                    nowString
                ]
            )

            // Manual assignment implicitly dismisses any pending
            // suggestions — matches the viewer-card's "accept clears
            // siblings" and the mock's `.vc-actions` handler.
            try db.execute(
                sql: "DELETE FROM project_suggestion WHERE thread_id = ?",
                arguments: [threadID]
            )

            return ProjectMembership(
                id: membershipID,
                threadID: threadID,
                projectID: projectID,
                type: .manualAdd,
                assignedAt: now,
                acceptedScore: nil,
                acceptedReason: nil
            )
        }
    }

    func clearMembership(threadID: String) async throws {
        try await GRDBAsync.write(to: dbQueue) { db in
            // Spec: clearing does NOT touch the suggestion table.
            // Dropped threads may resurface in Inbox under a
            // lower-scoring candidate — the pipeline rule is "absence
            // of membership is the unassigned signal", not "absence
            // of membership AND suggestions".
            try db.execute(
                sql: "DELETE FROM project_membership WHERE thread_id = ?",
                arguments: [threadID]
            )
        }
    }

    // MARK: - Suggestions

    func topSuggestion(for threadID: String) async throws -> ProjectSuggestion? {
        try await GRDBAsync.read(from: dbQueue) { db in
            // No membership → look up the top suggestion; if the
            // thread is assigned, short-circuit to nil to match the
            // "assigned threads never surface a suggestion" rule.
            let assigned = try Int.fetchOne(
                db,
                sql: "SELECT 1 FROM project_membership WHERE thread_id = ?",
                arguments: [threadID]
            ) != nil
            if assigned { return nil }

            let policy = SuggestionPolicy()
            let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT id, thread_id, candidate_project_id,
                           score, reason_terms, computed_at
                    FROM project_suggestion
                    WHERE thread_id = ? AND score >= ?
                    ORDER BY score DESC, computed_at DESC
                    LIMIT 1
                """,
                arguments: [threadID, policy.minScore]
            )
            return row.flatMap(Self.mapSuggestion)
        }
    }

    @discardableResult
    func acceptSuggestion(_ suggestion: ProjectSuggestion) async throws -> ProjectMembership {
        try await GRDBAsync.write(to: dbQueue) { db in
            guard try Int.fetchOne(
                db,
                sql: "SELECT 1 FROM project WHERE id = ?",
                arguments: [suggestion.candidateProjectID.rawValue]
            ) != nil else {
                throw ProjectRepositoryError.notFound
            }

            let membershipID = ProjectMembershipID("m-\(suggestion.threadID)")
            let now = Date()
            let nowString = TimestampFormatter.string(from: now)

            // Same UPSERT pattern as setManualMembership — except here
            // the type is acceptedSuggestion and we carry the snapshot
            // score + reason forward (so "why did I accept this" is
            // recoverable even after the TF-IDF pipeline re-ranks).
            try db.execute(
                sql: """
                    INSERT INTO project_membership (
                        id, thread_id, project_id, type,
                        assigned_at, accepted_score, accepted_reason
                    )
                    VALUES (?, ?, ?, 'accepted_suggestion', ?, ?, ?)
                    ON CONFLICT(thread_id) DO UPDATE SET
                        id              = excluded.id,
                        project_id      = excluded.project_id,
                        type            = 'accepted_suggestion',
                        assigned_at     = excluded.assigned_at,
                        accepted_score  = excluded.accepted_score,
                        accepted_reason = excluded.accepted_reason
                """,
                arguments: [
                    membershipID.rawValue,
                    suggestion.threadID,
                    suggestion.candidateProjectID.rawValue,
                    nowString,
                    suggestion.score,
                    suggestion.reasonTerms
                ]
            )

            // Remove the entire candidate list for this thread — the
            // user has ruled; the other candidates are no longer
            // actionable. Matches MockProjectRepository.
            try db.execute(
                sql: "DELETE FROM project_suggestion WHERE thread_id = ?",
                arguments: [suggestion.threadID]
            )

            return ProjectMembership(
                id: membershipID,
                threadID: suggestion.threadID,
                projectID: suggestion.candidateProjectID,
                type: .acceptedSuggestion,
                assignedAt: now,
                acceptedScore: suggestion.score,
                acceptedReason: suggestion.reasonTerms
            )
        }
    }

    func dismissSuggestion(_ suggestion: ProjectSuggestion) async throws {
        try await GRDBAsync.write(to: dbQueue) { db in
            // Drop ONLY the dismissed candidate row. Sibling candidates
            // on the same thread stay in place; a future threshold
            // lowering could re-promote one of them, matching the
            // "dismissed is a per-candidate verdict, not a per-thread
            // verdict" rule.
            try db.execute(
                sql: "DELETE FROM project_suggestion WHERE id = ?",
                arguments: [suggestion.id]
            )
        }
    }

    // MARK: - Import

    func applyCanonicalImport(_ folders: [ImportedExternalFolder]) async throws {
        guard !folders.isEmpty else { return }

        try await GRDBAsync.write(to: dbQueue) { db in
            let now = Date()
            let nowString = TimestampFormatter.string(from: now)

            for folder in folders {
                // Find-or-create the project by (source, externalFolderID).
                // Matching on the ID pair — not the name — preserves
                // a user's Madini-side rename across re-imports.
                let existingID: ProjectID?
                if let row = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT id FROM project
                        WHERE external_source = ? AND external_folder_id = ?
                    """,
                    arguments: [folder.source.rawValue, folder.externalFolderID]
                ) {
                    existingID = ProjectID((row["id"] as String?) ?? "")
                } else {
                    existingID = nil
                }

                let projectID: ProjectID
                if let id = existingID, !id.rawValue.isEmpty {
                    projectID = id
                } else {
                    // Deterministic ID shape matches MockProjectRepository
                    // ("imp-<source>-<externalFolderID>"). Keeps test
                    // fixtures legible and re-run-idempotent.
                    projectID = ProjectID("imp-\(folder.source.rawValue)-\(folder.externalFolderID)")
                    let nextSortIndex = (try Int.fetchOne(
                        db,
                        sql: "SELECT COALESCE(MAX(sort_index), -1) + 1 FROM project"
                    )) ?? 0
                    try db.execute(
                        sql: """
                            INSERT INTO project (
                                id, name, external_source, external_folder_id,
                                sort_index, created_at
                            )
                            VALUES (?, ?, ?, ?, ?, ?)
                        """,
                        arguments: [
                            projectID.rawValue,
                            folder.folderName,
                            folder.source.rawValue,
                            folder.externalFolderID,
                            nextSortIndex,
                            nowString
                        ]
                    )
                }

                // Upsert canonical memberships. Spec #5 — canonical
                // import OVERWRITES any prior membership type
                // (including manual_add). The ON CONFLICT clause does
                // the heavy lifting.
                for threadID in folder.threadIDs {
                    let membershipID = ProjectMembershipID("m-\(threadID)")
                    try db.execute(
                        sql: """
                            INSERT INTO project_membership (
                                id, thread_id, project_id, type,
                                assigned_at, accepted_score, accepted_reason
                            )
                            VALUES (?, ?, ?, 'canonical_import', ?, NULL, NULL)
                            ON CONFLICT(thread_id) DO UPDATE SET
                                id              = excluded.id,
                                project_id      = excluded.project_id,
                                type            = 'canonical_import',
                                assigned_at     = excluded.assigned_at,
                                accepted_score  = NULL,
                                accepted_reason = NULL
                        """,
                        arguments: [
                            membershipID.rawValue, threadID, projectID.rawValue,
                            nowString
                        ]
                    )
                    // Re-imported threads are no longer suggestion
                    // candidates; clear any stale rows.
                    try db.execute(
                        sql: "DELETE FROM project_suggestion WHERE thread_id = ?",
                        arguments: [threadID]
                    )
                }
            }
        }
    }

    // MARK: - Sidebar

    func sidebarCounts(policy: SuggestionPolicy) async throws -> ProjectSidebarCounts {
        try await GRDBAsync.read(from: dbQueue) { db in
            // Per-project assigned-thread counts. LEFT JOIN so a project
            // with zero memberships still appears with a 0 count — the
            // sidebar should render an empty project, not hide it.
            let perProjectRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT p.id AS project_id,
                           COUNT(m.thread_id) AS thread_count
                    FROM project p
                    LEFT JOIN project_membership m ON m.project_id = p.id
                    GROUP BY p.id
                """
            )
            var perProject: [ProjectID: Int] = [:]
            for row in perProjectRows {
                let id = ProjectID((row["project_id"] as String?) ?? "")
                let count = Int(row["thread_count"] as Int64? ?? 0)
                perProject[id] = count
            }

            // Inbox = unassigned threads with ≥1 suggestion ≥ minScore.
            // "Unassigned" = no row in project_membership for that
            // thread_id. Note: if the main archive adds Inbox-eligible
            // threads without corresponding suggestion rows yet, they
            // land in Orphans (no candidate above threshold) until the
            // next pipeline run.
            let inbox = (try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(DISTINCT s.thread_id)
                    FROM project_suggestion s
                    LEFT JOIN project_membership m ON m.thread_id = s.thread_id
                    WHERE m.thread_id IS NULL AND s.score >= ?
                """,
                arguments: [policy.minScore]
            )) ?? 0

            // Total threads is defined against the archive's
            // `conversations` table (what this app calls a "thread"
            // at the UI layer maps to one row in `conversations` at
            // the DB layer — `c.id` is the string identifier used as
            // `threadID` everywhere above). The archive layer owns
            // that count; we read it here because the sidebar needs
            // it in the same round-trip.
            let allThreads = (try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM conversations"
            )) ?? 0

            // Orphans = unassigned AND no actionable suggestion.
            //         = (all - assigned - inbox).
            let assigned = perProject.values.reduce(0, +)
            let orphans = max(0, allThreads - assigned - inbox)

            return ProjectSidebarCounts(
                perProject: perProject,
                inbox: inbox,
                orphans: orphans,
                all: allThreads
            )
        }
    }

    // MARK: - Row mappers

    private static func mapProject(_ row: Row) -> Project? {
        guard let idString: String = row["id"] else { return nil }
        guard let name: String = row["name"] else { return nil }

        let externalSource: Project.ExternalFolderBinding?
        if let sourceRaw: String = row["external_source"],
           let externalID: String = row["external_folder_id"],
           let source = Project.ExternalLLMSource(rawValue: sourceRaw) {
            externalSource = Project.ExternalFolderBinding(
                source: source,
                externalID: externalID
            )
        } else {
            externalSource = nil
        }

        let sortIndex = Int(row["sort_index"] as Int64? ?? 0)
        let createdAt = (row["created_at"] as String?)
            .flatMap(TimestampFormatter.date(from:))
            ?? Date()

        return Project(
            id: ProjectID(idString),
            name: name,
            externalSource: externalSource,
            sortIndex: sortIndex,
            createdAt: createdAt
        )
    }

    private static func mapMembership(_ row: Row) -> ProjectMembership? {
        guard let idString: String = row["id"],
              let threadID: String = row["thread_id"],
              let projectIDString: String = row["project_id"],
              let typeRaw: String = row["type"],
              let type = MembershipType(rawValue: typeRaw) else {
            return nil
        }
        let assignedAt = (row["assigned_at"] as String?)
            .flatMap(TimestampFormatter.date(from:))
            ?? Date()
        return ProjectMembership(
            id: ProjectMembershipID(idString),
            threadID: threadID,
            projectID: ProjectID(projectIDString),
            type: type,
            assignedAt: assignedAt,
            acceptedScore: row["accepted_score"] as Double?,
            acceptedReason: row["accepted_reason"] as String?
        )
    }

    private static func mapSuggestion(_ row: Row) -> ProjectSuggestion? {
        guard let id: String = row["id"],
              let threadID: String = row["thread_id"],
              let candidateIDString: String = row["candidate_project_id"],
              let reasonTerms: String = row["reason_terms"] else {
            return nil
        }
        let score = row["score"] as Double? ?? 0
        let computedAt = (row["computed_at"] as String?)
            .flatMap(TimestampFormatter.date(from:))
            ?? Date()
        return ProjectSuggestion(
            id: id,
            threadID: threadID,
            candidateProjectID: ProjectID(candidateIDString),
            score: score,
            reasonTerms: reasonTerms,
            computedAt: computedAt
        )
    }
}
