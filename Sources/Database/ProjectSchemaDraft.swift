import Foundation

/// SQLite schema draft for the **project-based organization** feature
/// (spec 2026-04). Kept as a constants-only holder here — parallel to the
/// inline SQL strings in `AppServices.bootstrapViewLayerSchema` — so the
/// DDL can be reviewed and iterated independently of the eventual
/// `PRAGMA user_version = 3` migration that will wire it in.
///
/// **Why a draft file and not a direct edit to `AppServices`?**
/// The view-layer schema bootstrap currently sits at `user_version = 2`
/// and runs on every launch. Landing the project tables as a
/// `user_version < 3` branch is a one-line paste once we're happy with
/// the DDL; until then, storing the strings here keeps `AppServices`
/// compile-stable while the shape of `ProjectRepository` settles.
///
/// **Design anchors (mirror `Sources/Models/ProjectMembership.swift`):**
///   1. **1-thread-1-project invariant.** Enforced by a `UNIQUE` index
///      on `project_membership.thread_id` — the schema itself refuses
///      to store two rows for the same thread, so an accidental double-
///      insert surfaces as a failed write instead of silent data
///      duplication.
///   2. **Membership type rawValues match the HTML mock 1:1.** Stored
///      as TEXT so a DB browser dump reads "canonical_import" /
///      "manual_add" / "accepted_suggestion" without a lookup table.
///      Swift's `MembershipType.rawValue` is the single source of truth
///      for those strings.
///   3. **External folder binding lives on `project`, not on each
///      membership.** Spec #5: a project imported from ChatGPT's
///      "Projects" feature (or Claude/Gemini's equivalent) carries
///      `(external_source, external_folder_id)`. Re-imports match by
///      that pair — survives rename on either side.
///   4. **Suggestion rows are ephemeral.** Deleted on accept/dismiss
///      and on re-import; we don't keep a "suggestion history". Score
///      and reason are snapshotted onto the accepted membership row so
///      the user can still see *why* a past accept happened even after
///      the TF-IDF pipeline re-ranks.
///   5. **Virtual scopes (`__all` / `__inbox` / `__orphans`) are
///      computed, not stored.** They're views over `project_membership`
///      + `project_suggestion` — see `sidebarCounts(policy:)` on
///      `ProjectRepository`.
enum ProjectSchemaDraft {

    // MARK: - project

    /// Root table: one row per project. Covers both user-created projects
    /// (Madini Archive, 読書メモ) and projects that originate as an
    /// external LLM folder (ChatGPT "Projects" 機能 のフォルダ).
    ///
    /// `external_source` / `external_folder_id` are NULL for purely-local
    /// projects and non-NULL for imported ones. The `UNIQUE` index on
    /// the pair (declared below) enforces that each external folder maps
    /// to at most one project — a second import of the same folder
    /// updates the existing project in place rather than creating a
    /// duplicate ("ファンタジー百合小説 (2)" is never what the user wants).
    static let createProjectTable = """
        CREATE TABLE IF NOT EXISTS project (
            id                 TEXT PRIMARY KEY,
            name               TEXT NOT NULL,
            external_source    TEXT,
            external_folder_id TEXT,
            sort_index         INTEGER NOT NULL DEFAULT 0,
            created_at         TEXT NOT NULL
        )
        """

    /// One external folder → at most one project. Partial index so rows
    /// without an external binding (user-created local projects) don't
    /// collide on the `(NULL, NULL)` pair. The column order is
    /// `(external_source, external_folder_id)` because the `applyCanonicalImport`
    /// lookup always knows the source up-front.
    static let createProjectExternalIndex = """
        CREATE UNIQUE INDEX IF NOT EXISTS idx_project_external
        ON project(external_source, external_folder_id)
        WHERE external_source IS NOT NULL
          AND external_folder_id IS NOT NULL
        """

    /// Stable display order. Keeps the sidebar's PROJECTS section in the
    /// order the user arranged (drag-reorder is a future feature, but
    /// the column is live so migration away from insert-order isn't a
    /// schema change later).
    static let createProjectSortIndex = """
        CREATE INDEX IF NOT EXISTS idx_project_sort
        ON project(sort_index, created_at)
        """

    // MARK: - project_membership

    /// The assignment table. One row per thread that has a home — the
    /// presence or absence of a row *is* the "assigned vs unassigned"
    /// state. Threads in the Inbox (pending suggestion) and Orphan
    /// (no suggestion, no assignment) scopes live by their *absence*
    /// here, not by a sentinel row.
    ///
    /// `type` carries `canonical_import` / `manual_add` / `accepted_suggestion`
    /// exactly as the HTML mock's `data-membership` attribute does.
    /// `accepted_score` + `accepted_reason` are populated only for
    /// `accepted_suggestion` rows and are a frozen snapshot — they do
    /// not update if the TF-IDF pipeline re-ranks later.
    ///
    /// The `UNIQUE(thread_id)` constraint is the teeth behind the
    /// 1-thread-1-project invariant: INSERT-only call sites rely on a
    /// constraint violation to detect races, and UPSERT call sites
    /// (`setManualMembership`, `acceptSuggestion`, `applyCanonicalImport`)
    /// target it with `INSERT … ON CONFLICT(thread_id) DO UPDATE`.
    static let createProjectMembershipTable = """
        CREATE TABLE IF NOT EXISTS project_membership (
            id              TEXT PRIMARY KEY,
            thread_id       TEXT NOT NULL UNIQUE,
            project_id      TEXT NOT NULL,
            type            TEXT NOT NULL
                CHECK (type IN ('canonical_import', 'manual_add', 'accepted_suggestion')),
            assigned_at     TEXT NOT NULL,
            accepted_score  REAL,
            accepted_reason TEXT,
            FOREIGN KEY(project_id) REFERENCES project(id) ON DELETE CASCADE
        )
        """

    /// Covering index for the "all threads in project X" query that
    /// powers the middle pane when the user clicks a sidebar project.
    /// `(project_id, assigned_at DESC)` so the default sort — newest
    /// assignments first — is an index scan, no filesort.
    static let createProjectMembershipByProjectIndex = """
        CREATE INDEX IF NOT EXISTS idx_project_membership_by_project
        ON project_membership(project_id, assigned_at DESC)
        """

    /// Reverse lookup for `statuses(forThreadIDs:)`. The sidebar
    /// fetches the currently-visible page of threads (≤50 rows) and
    /// asks "which of these have memberships?" — a point lookup per
    /// thread_id that benefits from its own index rather than hitting
    /// the UNIQUE constraint's implicit index.
    ///
    /// (UNIQUE already creates an index on `thread_id`; this duplicate
    /// declaration is intentionally omitted — the `UNIQUE(thread_id)`
    /// in the table body is the lookup index.)

    // MARK: - project_suggestion

    /// Ephemeral table: TF-IDF candidate rows awaiting user verdict.
    /// Multiple rows per thread are allowed (top-K candidates), but the
    /// `topSuggestion(for:)` API filters to `score >= SuggestionPolicy.minScore`
    /// and returns only the highest. Rows are purged on accept/dismiss
    /// and when a thread is re-imported as canonical.
    ///
    /// `reason_terms` is a pre-joined, middle-dot-delimited string
    /// ("真夜・錫花・アビエニア") — same shape the mock's
    /// `data-reason` attribute carries, same shape the tooltip renders.
    /// Storing it pre-joined rather than as a separate table is
    /// deliberate: the reason terms are a cosmetic explanation shown in
    /// a tooltip, never queried or aggregated, and splitting them into
    /// a child table would cost a join per suggestion row for no
    /// analytical benefit.
    ///
    /// No FK on `thread_id` — threads live in the conversation-layer
    /// schema (archive.db via the Python importer) and the project
    /// schema stays referentially isolated so a missing thread doesn't
    /// block suggestion GC.
    static let createProjectSuggestionTable = """
        CREATE TABLE IF NOT EXISTS project_suggestion (
            id                   TEXT PRIMARY KEY,
            thread_id            TEXT NOT NULL,
            candidate_project_id TEXT NOT NULL,
            score                REAL NOT NULL,
            reason_terms         TEXT NOT NULL,
            computed_at          TEXT NOT NULL,
            FOREIGN KEY(candidate_project_id) REFERENCES project(id) ON DELETE CASCADE
        )
        """

    /// Fast "top suggestion for this thread" lookup — the indexed
    /// `(thread_id, score DESC)` lets the query pick the winner in one
    /// scan and breaks ties by `computed_at` implicitly (rowid order
    /// within a same-score group).
    static let createProjectSuggestionByThreadIndex = """
        CREATE INDEX IF NOT EXISTS idx_project_suggestion_by_thread
        ON project_suggestion(thread_id, score DESC)
        """

    /// Covering index for "how many Inbox threads are above threshold
    /// right now?" — the sidebar's live count. Scans `score DESC` until
    /// the first row below `SuggestionPolicy.minScore`, no table access.
    static let createProjectSuggestionByScoreIndex = """
        CREATE INDEX IF NOT EXISTS idx_project_suggestion_by_score
        ON project_suggestion(score DESC, thread_id)
        """

    // MARK: - Ordered DDL payload

    /// The full ordered list of statements to execute on migration.
    /// Consumed by a future `bootstrapViewLayerSchema` branch along the
    /// lines of:
    ///
    ///     if userVersion < 3 {
    ///         for sql in ProjectSchemaDraft.allStatements {
    ///             try db.execute(sql: sql)
    ///         }
    ///         try db.execute(sql: "PRAGMA user_version = 3")
    ///     }
    ///
    /// Order matters: tables before their indexes, and the `project`
    /// table before the two child tables whose FKs reference it.
    static let allStatements: [String] = [
        createProjectTable,
        createProjectExternalIndex,
        createProjectSortIndex,
        createProjectMembershipTable,
        createProjectMembershipByProjectIndex,
        createProjectSuggestionTable,
        createProjectSuggestionByThreadIndex,
        createProjectSuggestionByScoreIndex,
    ]
}
