import Foundation

/// In-memory `ProjectRepository` that replays the fixed dataset the
/// toolbar mock at `tools/toolbar-mock/index.html` ships with. Kept
/// parallel to `MockTagRepository` (same `actor` pattern, same
/// `seed:` convention) so a single switch at the `AppServices`
/// factory level picks database-backed vs. mock.
///
/// The seed matches the mock's demo table row-for-row:
///   · Project "アルラウネ執筆"      — 2 canonical rows + 1 accepted
///   · Project "ファンタジー百合小説" — 1 canonical row
///   · Project "Madini Archive"     — 1 manual_add row
///   · Project "読書メモ"           — (no threads yet)
///   · Inbox:  2 threads with pending suggestions
///   · Orphan: 1 thread (複利の仕組み)
///
/// The sidebar counts returned by `sidebarCounts` are aspirational
/// (629 / 12 / 517 etc., same as the mock) rather than derived from
/// the seed — an eight-row demo can't believably show "629 threads
/// in LIBRARY". See `ProjectSidebarCounts` below for the override
/// hook used to match that visual scale without pretending the
/// dataset is larger than it is.
actor MockProjectRepository: ProjectRepository {
    // MARK: Backing stores

    private var projects: [ProjectID: Project] = [:]
    private var projectOrder: [ProjectID] = []

    /// Keyed by thread ID. Absence = unassigned.
    private var memberships: [String: ProjectMembership] = [:]

    /// Keyed by thread ID; stored as a list so multiple candidates
    /// per thread fit, but `topSuggestion(for:)` only ever returns
    /// the highest-scoring one above the policy threshold.
    private var suggestions: [String: [ProjectSuggestion]] = [:]

    /// Aspirational counts overlay — what the sidebar should report
    /// even though the seed is tiny. See class doc above.
    private var sidebarOverlay: ProjectSidebarCounts

    // MARK: Seed

    init() {
        let alraune  = ProjectID("alraune")
        let yuri     = ProjectID("yuri")
        let madini   = ProjectID("madini")
        let reading  = ProjectID("reading")

        projectOrder = [alraune, yuri, madini, reading]
        let now = Date()
        projects[alraune] = Project(
            id: alraune,
            name: "アルラウネ執筆",
            externalSource: .init(source: .chatgpt, externalID: "chatgpt:alraune"),
            sortIndex: 0,
            createdAt: now
        )
        projects[yuri] = Project(
            id: yuri,
            name: "ファンタジー百合小説",
            externalSource: .init(source: .chatgpt, externalID: "chatgpt:yuri"),
            sortIndex: 1,
            createdAt: now
        )
        projects[madini] = Project(
            id: madini,
            name: "Madini Archive",
            externalSource: nil,
            sortIndex: 2,
            createdAt: now
        )
        projects[reading] = Project(
            id: reading,
            name: "読書メモ",
            externalSource: .init(source: .chatgpt, externalID: "chatgpt:reading"),
            sortIndex: 3,
            createdAt: now
        )

        // 4 assigned memberships, mirroring the mock's sample rows.
        memberships["alraune-1"] = Self.makeMembership(thread: "alraune-1", project: alraune, type: .canonicalImport)
        memberships["alraune-2"] = Self.makeMembership(thread: "alraune-2", project: alraune, type: .canonicalImport)
        memberships["alraune-3"] = Self.makeMembership(
            thread: "alraune-3",
            project: alraune,
            type: .acceptedSuggestion,
            score: 0.73,
            reason: "真夜・錫花・アビエニア"
        )
        memberships["yuri-1"]   = Self.makeMembership(thread: "yuri-1",   project: yuri,   type: .canonicalImport)
        memberships["madini-1"] = Self.makeMembership(thread: "madini-1", project: madini, type: .manualAdd)

        // 2 Inbox rows (pending suggestions, above threshold).
        suggestions["inbox-1"] = [
            ProjectSuggestion(
                id: "s-inbox-1",
                threadID: "inbox-1",
                candidateProjectID: madini,
                score: 0.62,
                reasonTerms: "SwiftUI・モデル名・アプリ命名",
                computedAt: now
            )
        ]
        suggestions["inbox-2"] = [
            ProjectSuggestion(
                id: "s-inbox-2",
                threadID: "inbox-2",
                candidateProjectID: reading,
                score: 0.48,
                reasonTerms: "運動・習慣・記録",
                computedAt: now
            )
        ]
        // Orphan "複利の仕組み" — no membership, no suggestion.

        // Aspirational overlay, matches the mock's sidebar numbers.
        sidebarOverlay = ProjectSidebarCounts(
            perProject: [
                alraune: 42,
                yuri:    31,
                madini:  18,
                reading: 9,
            ],
            inbox: 12,
            orphans: 517,
            all: 629
        )
    }

    private static func makeMembership(
        thread: String,
        project: ProjectID,
        type: MembershipType,
        score: Double? = nil,
        reason: String? = nil
    ) -> ProjectMembership {
        ProjectMembership(
            id: ProjectMembershipID("m-\(thread)"),
            threadID: thread,
            projectID: project,
            type: type,
            assignedAt: Date(),
            acceptedScore: score,
            acceptedReason: reason
        )
    }

    // MARK: ProjectRepository conformance

    func listProjects() -> [Project] {
        projectOrder.compactMap { projects[$0] }
    }

    func createProject(name: String) throws -> Project {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ProjectRepositoryError.emptyName }
        if projects.values.contains(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            throw ProjectRepositoryError.invariantViolated("Project '\(trimmed)' already exists.")
        }
        let id = ProjectID(UUID().uuidString.lowercased())
        let project = Project(
            id: id,
            name: trimmed,
            externalSource: nil,
            sortIndex: projectOrder.count,
            createdAt: Date()
        )
        projects[id] = project
        projectOrder.append(id)
        return project
    }

    func renameProject(id: ProjectID, name: String) throws -> Project {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ProjectRepositoryError.emptyName }
        guard var existing = projects[id] else { throw ProjectRepositoryError.notFound }
        existing.name = trimmed
        projects[id] = existing
        return existing
    }

    func deleteProject(id: ProjectID) throws {
        guard projects.removeValue(forKey: id) != nil else { throw ProjectRepositoryError.notFound }
        projectOrder.removeAll { $0 == id }
        // Any threads in that project become unassigned.
        for (threadID, m) in memberships where m.projectID == id {
            memberships.removeValue(forKey: threadID)
        }
    }

    func membership(for threadID: String) -> ProjectMembership? {
        memberships[threadID]
    }

    func statuses(forThreadIDs ids: [String]) -> [String: ProjectThreadStatus] {
        var result: [String: ProjectThreadStatus] = [:]
        for threadID in ids {
            result[threadID] = ProjectThreadStatus(
                threadID: threadID,
                membership: memberships[threadID],
                topSuggestion: resolveTopSuggestion(for: threadID, policy: .init())
            )
        }
        return result
    }

    @discardableResult
    func setManualMembership(threadID: String, projectID: ProjectID) throws -> ProjectMembership {
        guard projects[projectID] != nil else { throw ProjectRepositoryError.notFound }
        let m = ProjectMembership(
            id: ProjectMembershipID("m-\(threadID)"),
            threadID: threadID,
            projectID: projectID,
            type: .manualAdd,
            assignedAt: Date(),
            acceptedScore: nil,
            acceptedReason: nil
        )
        memberships[threadID] = m
        // Manual assignment implicitly dismisses any pending
        // suggestions — the thread is no longer looking for a home.
        suggestions.removeValue(forKey: threadID)
        return m
    }

    func clearMembership(threadID: String) {
        memberships.removeValue(forKey: threadID)
    }

    func topSuggestion(for threadID: String) -> ProjectSuggestion? {
        resolveTopSuggestion(for: threadID, policy: .init())
    }

    @discardableResult
    func acceptSuggestion(_ suggestion: ProjectSuggestion) throws -> ProjectMembership {
        guard projects[suggestion.candidateProjectID] != nil else {
            throw ProjectRepositoryError.notFound
        }
        let m = ProjectMembership(
            id: ProjectMembershipID("m-\(suggestion.threadID)"),
            threadID: suggestion.threadID,
            projectID: suggestion.candidateProjectID,
            type: .acceptedSuggestion,
            assignedAt: Date(),
            acceptedScore: suggestion.score,
            acceptedReason: suggestion.reasonTerms
        )
        memberships[suggestion.threadID] = m
        // Remove the entire candidate list for the thread — the user
        // has ruled, the other candidates are no longer actionable.
        suggestions.removeValue(forKey: suggestion.threadID)
        return m
    }

    func dismissSuggestion(_ suggestion: ProjectSuggestion) {
        // Drop only the dismissed candidate row; the thread stays
        // unassigned but may still have lower-scoring candidates
        // waiting for a future threshold drop.
        suggestions[suggestion.threadID]?.removeAll { $0.id == suggestion.id }
        if suggestions[suggestion.threadID]?.isEmpty == true {
            suggestions.removeValue(forKey: suggestion.threadID)
        }
    }

    func applyCanonicalImport(_ folders: [ImportedExternalFolder]) {
        for folder in folders {
            // Find-or-create the matching project. We match by
            // (source, externalFolderID) — renaming on the Madini
            // side survives because we key off the ID, not the name.
            let existingID = projects.values.first { proj in
                guard let src = proj.externalSource else { return false }
                return src.source == folder.source && src.externalID == folder.externalFolderID
            }?.id

            let projectID: ProjectID
            if let id = existingID {
                projectID = id
            } else {
                projectID = ProjectID("imp-\(folder.source.rawValue)-\(folder.externalFolderID)")
                projects[projectID] = Project(
                    id: projectID,
                    name: folder.folderName,
                    externalSource: .init(source: folder.source, externalID: folder.externalFolderID),
                    sortIndex: projectOrder.count,
                    createdAt: Date()
                )
                projectOrder.append(projectID)
            }

            // Upsert canonical memberships. Spec #5: canonicalImport
            // overwrites any prior membership — manualAdd included.
            for threadID in folder.threadIDs {
                memberships[threadID] = ProjectMembership(
                    id: ProjectMembershipID("m-\(threadID)"),
                    threadID: threadID,
                    projectID: projectID,
                    type: .canonicalImport,
                    assignedAt: Date(),
                    acceptedScore: nil,
                    acceptedReason: nil
                )
                // Re-imported threads are no longer suggestion
                // candidates; clear any stale rows.
                suggestions.removeValue(forKey: threadID)
            }
        }
    }

    func sidebarCounts(policy: SuggestionPolicy) -> ProjectSidebarCounts {
        // Mock intentionally returns the aspirational overlay rather
        // than counts derived from the tiny seed. See the class doc.
        sidebarOverlay
    }

    // MARK: Helpers

    private func resolveTopSuggestion(
        for threadID: String,
        policy: SuggestionPolicy
    ) -> ProjectSuggestion? {
        // If the thread is assigned, no suggestion should surface.
        if memberships[threadID] != nil { return nil }
        return suggestions[threadID]?
            .filter { $0.score >= policy.minScore }
            .max(by: { $0.score < $1.score })
    }
}
