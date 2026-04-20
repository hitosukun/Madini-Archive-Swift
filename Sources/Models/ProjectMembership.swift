import Foundation

// MARK: - Project-system model draft
//
// This file sketches the data layer for the project-based tag
// replacement described in the 2026-04 spec and prototyped visually
// in `tools/toolbar-mock/index.html`. It is deliberately scoped to
// pure model types — no repository wiring, no view code — so the
// SQLite schema, importer, and UI layers can evolve in separate
// commits without churning a monolith.
//
// Spec summary (abridged):
//   1. Every thread belongs to at most one project (1-thread-1-project
//      invariant). The old many-to-many `threads ↔ tags` graph is
//      replaced with a unique row in `ProjectMembership`.
//   2. Projects come from three sources:
//        · canonical_import    — external LLM folder (ChatGPT project)
//        · manual_add          — user picked directly in Madini
//        · accepted_suggestion — user accepted a TF-IDF match
//   3. On folder re-import, canonical_import OVERWRITES any existing
//      membership — external LLM is source of truth. A user who moves
//      a thread between folders on the LLM side and re-imports sees
//      Madini follow along, even if the local membership was
//      `manual_add`. Rationale: the user's mental "where does this
//      live" lives in the LLM UI, so Madini shouldn't hold a
//      competing taxonomy.
//   4. Unassigned threads (no ProjectMembership row) can still carry
//      zero or more `ProjectSuggestion`s — TF-IDF-derived candidate
//      projects with a score. Score ≥ 0.4 (configurable) promotes the
//      thread into the "Inbox" virtual project; everything else is an
//      "Orphan".
//
// Mock cross-reference: see `index.html` lines tagged with data-
// attributes `data-project-id`, `data-membership`, `data-has-suggestion`,
// and `data-suggested-project`. Those attributes are the JS mirror of
// the Swift types below — keeping the names parallel makes the
// mock-to-Swift port a mechanical step.

// MARK: IDs

/// Stable identifier for a Project row. Wraps a string so the
/// compiler catches cases where a raw `String` accidentally flows
/// into a project API (a class of bug we had repeatedly with tag
/// names-vs-IDs). Uses `String` under the hood because the external
/// LLM's folder identifier is string-shaped (e.g. a ChatGPT
/// project's GID) — persisting integers would lose the round-trip
/// back to the source.
struct ProjectID: Hashable, Codable, Sendable, RawRepresentable {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    init(_ rawValue: String) { self.rawValue = rawValue }
}

/// Stable identifier for a ProjectMembership row. A thread has at
/// most one membership at any time, but memberships are
/// independently identifiable so audit views can show a
/// membership's history (accepted at time T, then overwritten by
/// canonical_import at time T+1, etc.) without the row moving.
struct ProjectMembershipID: Hashable, Codable, Sendable, RawRepresentable {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    init(_ rawValue: String) { self.rawValue = rawValue }
}

// MARK: - Project

/// A named bucket that owns zero or more threads. Created either by
/// an external folder import (`externalSource` non-nil) or manually
/// by the user inside Madini (`externalSource` nil).
///
/// The `externalSource` field matters at re-import time: a folder
/// whose external ID disappears from the LLM's payload is treated as
/// "deleted on the source side" and its threads become unassigned
/// again. A purely Madini-local project is not affected by any
/// re-import since it has no corresponding external folder.
struct Project: Hashable, Codable, Sendable, Identifiable {
    let id: ProjectID
    /// Human-visible name — initially seeded from the external folder
    /// (e.g. "アルラウネ執筆") and editable by the user thereafter.
    /// Rename does NOT break the external binding; that's tracked
    /// via `externalSource.externalID`.
    var name: String
    /// Non-nil iff this project originated from (or is bound to) an
    /// external LLM folder. Nil projects are Madini-local only.
    var externalSource: ExternalFolderBinding?
    /// Ordering hint for sidebar display. Stored so the user's drag
    /// reorder is persistent; defaults to creation order.
    var sortIndex: Int
    /// Creation timestamp (`date_added` for folder-seeded projects,
    /// `date_created` for Madini-local ones).
    var createdAt: Date

    /// Binding to an LLM-side folder. Captures which LLM ("chatgpt"
    /// today, "claude" / "gemini" tomorrow) plus the folder's
    /// identifier on that side. Keeping the source explicit avoids
    /// accidentally cross-wiring a ChatGPT project and a Claude
    /// project that happen to share a name.
    struct ExternalFolderBinding: Hashable, Codable, Sendable {
        let source: ExternalLLMSource
        /// Opaque identifier supplied by the LLM (ChatGPT project
        /// GID, Claude project ID, etc.). Not displayed.
        let externalID: String
    }

    enum ExternalLLMSource: String, Codable, Sendable {
        case chatgpt
        case claude
        case gemini
    }
}

// MARK: - Membership

/// How a thread ended up in a particular project. The three cases
/// are ordered from most to least authoritative at the data-source
/// level, but authority at RESOLUTION time is different — see the
/// re-import rule in the spec summary at the top of this file.
///
/// Raw values match the mock's `data-membership` attribute values
/// 1:1 so the HTML and Swift halves of the project can share
/// fixtures / test snapshots.
enum MembershipType: String, Codable, Sendable, CaseIterable {
    /// Came from an external LLM folder at import time. Re-import
    /// overwrites any prior membership (even `manual_add`) — the
    /// LLM is canonical.
    case canonicalImport    = "canonical_import"
    /// The user picked this project directly in Madini (drag-drop,
    /// context menu, toolbar dropdown). No suggestion involved.
    case manualAdd          = "manual_add"
    /// The user accepted a TF-IDF `ProjectSuggestion`. Behaves
    /// identically to `manualAdd` except the suggestion's score +
    /// reason terms are retained for audit.
    case acceptedSuggestion = "accepted_suggestion"
}

/// A single thread's project assignment. Unique per thread — the
/// 1-thread-1-project invariant is enforced by a UNIQUE constraint
/// on `threadID` in the SQLite schema.
///
/// Absence of a row = "unassigned". Downstream code should never
/// represent unassigned as a sentinel membership (e.g. a
/// `MembershipType.none`); the absence of a row is the signal.
/// This keeps the SQL queries for Inbox / Orphans tidy:
///   Inbox    = threads with no ProjectMembership AND ≥1 live
///              ProjectSuggestion above threshold
///   Orphans  = threads with no ProjectMembership AND no live
///              ProjectSuggestion above threshold
struct ProjectMembership: Hashable, Codable, Sendable, Identifiable {
    let id: ProjectMembershipID
    let threadID: String                 // matches the existing thread PK
    let projectID: ProjectID
    let type: MembershipType
    /// When this membership was first created. For `acceptedSuggestion`
    /// this is when the user clicked ✓; for `canonicalImport` it's the
    /// import run that established the binding; for `manualAdd` it's
    /// the drag / pick gesture.
    let assignedAt: Date
    /// Non-nil only for `acceptedSuggestion`. Snapshots the score at
    /// acceptance time so a later re-ranking doesn't change the
    /// historical value shown in the viewer-card "suggested 0.81".
    let acceptedScore: Double?
    /// Non-nil only for `acceptedSuggestion`. Human-readable evidence
    /// summary ("真夜・錫花・アビエニア"). Rendered in the viewer-card's
    /// reason row and as the tooltip on the table's score cell.
    let acceptedReason: String?
}

// MARK: - Suggestions

/// A TF-IDF-derived candidate project for an unassigned thread.
/// Produced by the suggestion pipeline (see planned `SuggestionEngine`)
/// and persisted so the Inbox list survives an app restart without
/// recomputing on launch.
///
/// One thread may carry multiple ProjectSuggestions (one per candidate
/// project); the UI surfaces only the top-scoring one above the
/// threshold.
struct ProjectSuggestion: Hashable, Codable, Sendable, Identifiable {
    let id: String                       // UUID; server of the row
    let threadID: String
    let candidateProjectID: ProjectID
    /// 0.0–1.0 cosine similarity against the project's aggregated
    /// TF-IDF profile. Threshold for "actionable" is in
    /// `SuggestionPolicy.minScore` — starts at 0.4, tunable later.
    let score: Double
    /// Top-k matching terms, pre-joined for display. UI splits on
    /// "・" if it needs tokenized access. Kept as a single string in
    /// storage to dodge schema churn while the term count is in
    /// flux.
    let reasonTerms: String
    let computedAt: Date
}

// MARK: - Policies

/// Runtime-tunable knobs for the suggestion pipeline. Kept as a
/// plain struct so the debug panel / preferences pane can surface
/// them and persist changes via `UserDefaults` or the repository
/// layer without model-layer churn.
struct SuggestionPolicy: Hashable, Codable, Sendable {
    /// Minimum score below which a `ProjectSuggestion` is not
    /// eligible for the Inbox. Starts conservative (0.4) so Inbox
    /// stays manageable; tune down once the user has a feel for
    /// signal quality.
    var minScore: Double = 0.4

    /// Upper bound on how many candidates to persist per thread.
    /// Above this, only the top-k are stored; the tail is
    /// recomputed on demand if the threshold ever drops.
    var topK: Int = 3
}

// MARK: - Sidebar scope

/// The sidebar's selection — drives the middle pane's row filter.
/// Combines concrete projects with the three virtual scopes
/// (All / Inbox / Orphans) so a single `@Published` on the view
/// model covers every filter case.
///
/// Mock parallel: the HTML mock encodes this onto `body[data-project]`.
/// The `__` prefix on virtual raw values lets CSS selectors like
/// `body[data-project^="__"]` pick them out in bulk (e.g. "show the
/// Project column for all virtual scopes but hide it when a concrete
/// project is picked").
enum ProjectScope: Hashable, Codable, Sendable {
    /// Every thread, regardless of project state. Default if the
    /// user hasn't explicitly scoped.
    case all
    /// Unassigned threads with an actionable ProjectSuggestion.
    case inbox
    /// Unassigned threads with no actionable ProjectSuggestion.
    case orphans
    /// A specific user / imported project.
    case project(ProjectID)

    /// String key matching the mock's `data-project` values. Used by
    /// diagnostic logging and (eventually) for restoring the last
    /// selected scope across launches via `@AppStorage`.
    var storageKey: String {
        switch self {
        case .all:               return "__all"
        case .inbox:             return "__inbox"
        case .orphans:           return "__orphans"
        case .project(let id):   return id.rawValue
        }
    }
}

// MARK: - Project-cell rendering state
//
// A projection of (`ProjectMembership?`, `ProjectSuggestion?`) flattened
// into the five display states the viewer-card and table-row renderers
// both consume. Mirrors the HTML mock's five `data-membership` values
// exactly, so the SwiftUI view code can map the enum to icons +
// labels with a single switch.

/// Five-way projection of the (membership?, suggestion?) pair for UI
/// consumption. Computed by `ProjectCellState.from(_:_:)` at read
/// time; not persisted.
enum ProjectCellState: Hashable, Sendable {
    case canonicalImport(project: ProjectID, name: String)
    case manualAdd(project: ProjectID, name: String)
    case acceptedSuggestion(project: ProjectID, name: String, score: Double, reason: String)
    case pendingSuggestion(candidate: ProjectID, name: String, score: Double, reason: String)
    case unassigned

    /// Derive the state from a membership + top suggestion. The four
    /// assigned states come entirely from the membership row; only
    /// the unassigned row ever looks at the suggestion argument.
    ///
    /// `projectName(for:)` is passed as a closure so this function
    /// stays pure — callers provide the name lookup against their
    /// own in-memory project cache.
    static func from(
        membership: ProjectMembership?,
        topSuggestion: ProjectSuggestion?,
        projectName: (ProjectID) -> String
    ) -> ProjectCellState {
        if let m = membership {
            let name = projectName(m.projectID)
            switch m.type {
            case .canonicalImport:
                return .canonicalImport(project: m.projectID, name: name)
            case .manualAdd:
                return .manualAdd(project: m.projectID, name: name)
            case .acceptedSuggestion:
                return .acceptedSuggestion(
                    project: m.projectID,
                    name: name,
                    score: m.acceptedScore ?? 0,
                    reason: m.acceptedReason ?? ""
                )
            }
        }
        if let s = topSuggestion {
            return .pendingSuggestion(
                candidate: s.candidateProjectID,
                name: projectName(s.candidateProjectID),
                score: s.score,
                reason: s.reasonTerms
            )
        }
        return .unassigned
    }
}

// MARK: - TODO: repository protocol
//
// Once the types above settle, add a `ProjectRepository` protocol to
// `Sources/Core/Repositories.swift` modeled on `TagRepository`:
//
//   func projects() async throws -> [Project]
//   func membership(for threadID: String) async throws -> ProjectMembership?
//   func topSuggestion(for threadID: String) async throws -> ProjectSuggestion?
//   func setManualMembership(threadID:projectID:) async throws
//   func acceptSuggestion(_ suggestion: ProjectSuggestion) async throws
//   func dismissSuggestion(_ suggestion: ProjectSuggestion) async throws
//   func applyCanonicalImport(_ folders: [ExternalFolder]) async throws
//
// Pair with `MockProjectRepository` + `GRDBProjectRepository` to match
// the existing repository split. Delete `GRDBTagRepository` /
// `MockTagRepository` / `SidebarTagsSection` / `ConversationTagsEditor`
// once the UI layer has migrated — keep them alive during the
// transition so the app stays runnable on every intermediate commit.
