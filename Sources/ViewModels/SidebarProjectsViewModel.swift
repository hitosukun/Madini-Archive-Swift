import Foundation
import Observation

/// View-model backing the sidebar's PROJECTS + TRIAGE sections.
///
/// Loads from `AppServices.projects` in two parallel calls — the
/// project list (`listProjects`) and the count overlay
/// (`sidebarCounts`) — so one network round-trip populates every badge
/// on every row. Shape deliberately mirrors
/// `SortAndTagsInspectorViewModel`: `@MainActor` + `@Observable`,
/// `loadInitial()` on `.task`, cached state mutated in place rather
/// than emitted through a publisher.
///
/// **Scope note.** This VM does NOT yet plug into
/// `LibraryViewModel.filter`; clicking a row updates local selection
/// only. The middle-pane filtering pass lands next and will add a
/// `projects` / `scope` dimension to `ArchiveSearchFilter`.
@MainActor
@Observable
final class SidebarProjectsViewModel {
    /// Persisted projects, in the order `listProjects()` returns them.
    /// Empty until `loadInitial()` resolves — the view shows a
    /// ProgressView in that window.
    var projects: [Project] = []

    /// Aggregate counts driving the row badges (per-project threads,
    /// inbox, orphans, total). Populated by `sidebarCounts(policy:)`.
    /// Defaults to all-zeros so the view can render the row skeleton
    /// during the first fetch instead of conditionally rendering.
    var counts: ProjectSidebarCounts = .empty

    var errorText: String?
    var isLoading: Bool = false

    /// Suggestion-threshold policy. Currently uses the repository's
    /// default; surfacing it here as a stored property keeps the door
    /// open to the debug-panel "lower the minScore to see more Inbox
    /// candidates" knob without having to change the load call site.
    var policy: SuggestionPolicy = SuggestionPolicy()

    private let projectRepository: any ProjectRepository

    init(projectRepository: any ProjectRepository) {
        self.projectRepository = projectRepository
    }

    // MARK: - Lifecycle

    /// First-fetch entry point. Called from `.task` so it runs once
    /// per view appearance — if the view reappears (e.g. after a
    /// window-close + reopen) the cached state is already on hand and
    /// this fires again to refresh.
    func loadInitial() async {
        await refresh()
    }

    /// Re-fetch both projects and counts. Exposed so external events
    /// (future: project CRUD, canonical re-import completion) can
    /// invalidate without the view having to know which call went
    /// stale.
    func refresh() async {
        isLoading = true
        defer { isLoading = false }

        // Parallel fetches — the two calls are independent on the
        // repository side (list reads `project`, counts reads
        // `project_membership` + `project_suggestion` + `conversations`)
        // so a TaskGroup shaves one DB round-trip's worth of latency
        // vs. awaiting them sequentially. Still cheap (~ms) against
        // SQLite, but consistent with how we treat other fan-out
        // loads elsewhere in the VM layer.
        async let projectsResult = loadProjects()
        async let countsResult = loadCounts()

        let fetched = await projectsResult
        let fetchedCounts = await countsResult

        if let fetched {
            projects = fetched
        }
        if let fetchedCounts {
            counts = fetchedCounts
        }
    }

    // MARK: - Row accessors

    /// Thread count for one project. Falls back to 0 when the count
    /// overlay hasn't seen that project yet (shouldn't happen outside
    /// the "empty repo + first load" window, but keeps the renderer
    /// total-safe).
    func count(for projectID: ProjectID) -> Int {
        counts.perProject[projectID] ?? 0
    }

    var inboxCount: Int { counts.inbox }
    var orphansCount: Int { counts.orphans }
    var allCount: Int { counts.all }

    // MARK: - Internal

    private func loadProjects() async -> [Project]? {
        do {
            return try await projectRepository.listProjects()
        } catch {
            errorText = error.localizedDescription
            return nil
        }
    }

    private func loadCounts() async -> ProjectSidebarCounts? {
        do {
            return try await projectRepository.sidebarCounts(policy: policy)
        } catch {
            errorText = error.localizedDescription
            return nil
        }
    }
}

extension ProjectSidebarCounts {
    /// Zero-initialized counts for use as a "not yet loaded" sentinel
    /// in the VM. Kept here (rather than on the model) because the
    /// semantic of "empty" is a view concern — a repository that
    /// legitimately reports zeros should produce the same struct, and
    /// the view has to handle that case anyway.
    static var empty: ProjectSidebarCounts {
        ProjectSidebarCounts(perProject: [:], inbox: 0, orphans: 0, all: 0)
    }
}
