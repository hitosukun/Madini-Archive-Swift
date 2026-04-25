#if os(macOS)
import AppKit
import SwiftUI

/// Step through an ordered id list by `delta`, clamping at the edges
/// (no wrap — wrapping would silently teleport the user across the
/// whole list on a single keypress, more disorienting than useful).
/// When `cursor` is nil, seeds the edge: `delta >= 0` → first id,
/// `delta < 0` → last id (matches the "unfocused list" convention in
/// Mail and Finder). Returns nil when the list is empty or the cursor
/// is already at the target edge.
///
/// Shared by the three keyboard-nav call sites in this file — the
/// card-list thread stepper, the prompt-list stepper inside an
/// expanded card, and the viewer's ⌘↑/⌘↓ prompt walker — all of
/// which used to carry their own copy of the same clamp-and-seed
/// logic.
fileprivate func steppedID<T: Identifiable>(
    in items: [T],
    from cursor: T.ID?,
    by delta: Int
) -> T.ID? {
    guard !items.isEmpty else { return nil }
    let ids = items.map(\.id)
    if let cursor, let current = ids.firstIndex(of: cursor) {
        let next = min(max(current + delta, 0), ids.count - 1)
        return next == current ? nil : ids[next]
    }
    return delta >= 0 ? ids.first : ids.last
}

/// Live data backing the macOS shell. Talks directly to `AppServices`
/// repositories — no mock fallback once a database is attached. The store is
/// the single source of truth for what the center pane lists, what facets the
/// sidebar renders, what bookmarks/tags exist, and how big the archive is.
///
/// Every user intent (sidebar selection, search keystroke, sort change) is
/// funneled through a `FetchQuery`. Setting a new query cancels the in-flight
/// fetch and kicks a new one, so the UI doesn't flicker between stale / fresh
/// results when the user types quickly.
///
/// Paging: the first page (`pageSize` rows) arrives via `refresh`; subsequent
/// pages via `loadMore` when the center pane reports the last row appeared.
/// `totalCount` drives the "N of M" badge and lets the loader stop early.
@MainActor
fileprivate final class DesignMockDataStore: ObservableObject {
    @Published private(set) var conversations: [DesignMockConversation] = []
    @Published private(set) var sources: [DesignMockSource] = []
    /// Prompt-level bookmarks. Phase 4 retargeted bookmarks from threads
    /// ("is this conversation interesting?") to individual user prompts
    /// ("is this specific question worth re-finding?"), so the sidebar
    /// Bookmarks section now surfaces per-prompt rows instead of one row
    /// per thread. Kept in display order (most-recently-updated first)
    /// so the sidebar list matches the iteration order.
    @Published private(set) var promptBookmarks: [DesignMockPromptBookmark] = []
    /// O(1) lookup companion to `promptBookmarks`. Views (the expanded
    /// card's prompt list, `MessageBubbleView`) ask "is THIS prompt
    /// pinned?" once per row — doing a linear scan over `promptBookmarks`
    /// on every bubble would be O(n·m). Recomputed alongside
    /// `promptBookmarks` in `refreshBookmarks`.
    @Published private(set) var pinnedPromptIDs: Set<String> = []
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var isLoadingMore: Bool = false
    @Published private(set) var lastError: String?
    @Published private(set) var totalCount: Int = 0
    @Published private(set) var databaseInfo: DatabaseInfo?
    @Published private(set) var mode: Mode = .mock
    /// Cached prompt outlines keyed by conversation id. Populated by
    /// `promptOutline(for:services:)` — the center-pane card-expand view and
    /// the right-pane prompt menu both read from here so tapping the same
    /// conversation twice doesn't re-hit the DB.
    @Published private(set) var promptOutlines: [String: [DesignMockPrompt]] = [:]

    enum Mode: Equatable {
        case mock
        case database(path: String)
    }

    struct DatabaseInfo: Equatable {
        let path: String
        let sizeBytes: Int64?
    }

    /// User-driven fetch parameters. The view owns these as `@State` and
    /// funnels changes through `setQuery(_:services:)` — the store is just the
    /// executor, so it doesn't need to debounce or diff on its own.
    struct FetchQuery: Equatable {
        var keyword: String = ""
        var source: String? = nil
        var model: String? = nil
        var bookmarksOnly: Bool = false
        var tagName: String? = nil
        var sortKey: ConversationSortKey = .dateDesc
    }

    private let pageSize = 200
    private var currentQuery: FetchQuery = .init()
    /// Identifies the in-flight fetch so results from a stale request (user
    /// kept typing) are dropped instead of overwriting the fresh results.
    private var activeFetchID: UUID?
    private var activeLoadMoreID: UUID?
    /// Offset into the current result set. Advanced by `loadMore`.
    private var loadedOffset: Int = 0

    init(initialConversations: [DesignMockConversation] = DesignMockData.sampleConversations) {
        // Seed with the bundled sample so the window doesn't paint empty on
        // first launch. Overwritten immediately once `load(services:)` runs
        // against a real database (the mock sample is only ever visible in
        // `.mock` mode, or in previews that never call `load`).
        self.conversations = initialConversations
        self.sources = DesignMockDataStore.sourcesFromMock(initialConversations)
        self.totalCount = initialConversations.count
    }

    /// Kick the store into "real data" mode and run the initial fetches.
    /// No-op when services is backed by mocks — the sample seed from `init`
    /// stays visible so the UI has something to render in dev.
    func load(services: AppServices) {
        switch services.dataSource {
        case .mock:
            mode = .mock
        case .database(let path):
            mode = .database(path: path)
            databaseInfo = Self.captureDatabaseInfo(path: path)
            Task { await refreshAll(services: services) }
        }
    }

    /// Run in parallel: conversations + facets + bookmarks. Each of
    /// these is independent, so bundling them into a task group keeps launch
    /// latency to the slowest single query instead of their sum.
    func refreshAll(services: AppServices) async {
        async let convos: Void = refresh(services: services)
        async let facets: Void = refreshSourceFacets(services: services)
        async let bmarks: Void = refreshBookmarks(services: services)
        _ = await (convos, facets, bmarks)
    }

    /// Apply a new user query (sidebar / search / sort). Cancelling any
    /// in-flight fetch and starting a new one — last write wins, which is
    /// exactly what we want for keystroke-driven search.
    func setQuery(_ query: FetchQuery, services: AppServices) {
        guard query != currentQuery else { return }
        currentQuery = query
        Task { await refresh(services: services) }
    }

    var currentFetchQuery: FetchQuery { currentQuery }

    /// Reload the first page for the current query. Called on launch, on
    /// query changes, and after any action that might have mutated the
    /// archive (new import, bookmark toggle, tag change).
    func refresh(services: AppServices) async {
        let fetchID = UUID()
        activeFetchID = fetchID
        isLoading = true
        lastError = nil
        defer {
            if activeFetchID == fetchID {
                isLoading = false
            }
        }

        do {
            let filter = Self.buildFilter(from: currentQuery)
            let page = try await fetchPage(
                services: services,
                filter: filter,
                sortKey: currentQuery.sortKey,
                offset: 0
            )
            guard activeFetchID == fetchID else { return }
            conversations = page.rows
            totalCount = page.total
            loadedOffset = page.rows.count
        } catch {
            lastError = String(describing: error)
        }
    }

    /// Fetch the next page, appending to `conversations`. The center pane
    /// triggers this from an `.onAppear` on the last visible row. Guards
    /// against concurrent calls so scrolling fast doesn't spawn duplicate
    /// requests.
    func loadMoreIfNeeded(services: AppServices) {
        guard !isLoading, !isLoadingMore else { return }
        guard conversations.count < totalCount else { return }

        let loadID = UUID()
        activeLoadMoreID = loadID
        isLoadingMore = true
        let offset = loadedOffset
        let query = currentQuery

        Task {
            defer {
                if self.activeLoadMoreID == loadID {
                    self.isLoadingMore = false
                }
            }
            do {
                let filter = Self.buildFilter(from: query)
                let page = try await self.fetchPage(
                    services: services,
                    filter: filter,
                    sortKey: query.sortKey,
                    offset: offset,
                    knownTotal: self.totalCount
                )
                // Drop if the user changed query mid-flight.
                guard self.activeLoadMoreID == loadID,
                      self.currentQuery == query else { return }
                self.conversations.append(contentsOf: page.rows)
                self.loadedOffset += page.rows.count
            } catch {
                self.lastError = String(describing: error)
            }
        }
    }

    /// Resolve the prompt outline for a conversation — used by the expanded
    /// card view in the middle pane. Async but idempotent; the first call
    /// fetches the detail and caches the user-authored messages, subsequent
    /// calls hit the cache.
    func promptOutline(for conversationID: String, services: AppServices) async -> [DesignMockPrompt] {
        if let cached = promptOutlines[conversationID] {
            return cached
        }
        do {
            guard let detail = try await services.conversations.fetchDetail(id: conversationID) else {
                return []
            }
            // Filter THEN enumerate — the previous order enumerated all
            // messages (user + assistant) and filtered down to user, so
            // `idx` was the position in the full transcript, not the
            // prompt-within-thread count. That produced a jumpy
            // "1, 3, 5, 7…" display in the card outline whenever
            // assistant replies sat between prompts. The canonical
            // `ConversationDetailView.promptOutline` already uses
            // user-only numbering for the same reason; keeping the
            // DesignMock outline aligned avoids a visual mismatch
            // between the expanded card ("1, 3, 5…") and the reader
            // header counter ("1 / 12").
            let prompts = detail.messages
                .filter { $0.isUser }
                .enumerated()
                .map { idx, message in
                    DesignMockPrompt(
                        id: message.id,
                        index: idx,
                        snippet: Self.snippet(from: message.content)
                    )
                }
            promptOutlines[conversationID] = prompts
            return prompts
        } catch {
            lastError = String(describing: error)
            return []
        }
    }

    // MARK: - Facet / bookmark / tag loaders

    /// One DB round-trip that returns `(source, model, count)` triples we then
    /// pivot in memory into the nested facet tree. Mirrors what
    /// `LibraryViewModel.loadSourceFacets` does for the canonical sidebar.
    func refreshSourceFacets(services: AppServices) async {
        do {
            let rows = try await services.conversations.fetchSourceModelFacets(filter: nil)
            var totalsBySource: [String: Int] = [:]
            var modelsBySource: [String: [DesignMockSourceModel]] = [:]
            var order: [String] = []
            for row in rows {
                if totalsBySource[row.source] == nil { order.append(row.source) }
                totalsBySource[row.source, default: 0] += row.count
                if let model = row.model, !model.isEmpty {
                    modelsBySource[row.source, default: []].append(
                        DesignMockSourceModel(name: model, count: row.count)
                    )
                }
            }
            order.sort { lhs, rhs in
                let lhsCount = totalsBySource[lhs] ?? 0
                let rhsCount = totalsBySource[rhs] ?? 0
                if lhsCount != rhsCount { return lhsCount > rhsCount }
                return lhs < rhs
            }
            self.sources = order.map { name in
                let models = (modelsBySource[name] ?? []).sorted { lhs, rhs in
                    if lhs.count != rhs.count { return lhs.count > rhs.count }
                    return lhs.name < rhs.name
                }
                return DesignMockSource(
                    name: name,
                    count: totalsBySource[name] ?? 0,
                    models: models
                )
            }
        } catch {
            lastError = String(describing: error)
        }
    }

    func refreshBookmarks(services: AppServices) async {
        do {
            let entries = try await services.bookmarks.listBookmarks()
            // Phase 4: only prompt-level bookmarks surface in the sidebar.
            // Thread / virtual-fragment / saved-view bookmarks are
            // legacy — a thread bookmark is now implied ("thread has at
            // least one pinned prompt") rather than a standalone row.
            let prompts = entries.compactMap { entry -> DesignMockPromptBookmark? in
                guard entry.targetType == .prompt else { return nil }
                // Message IDs follow `{conversationID}:{messageRowID}`.
                // Prefer the payload hint (set by the toggle path) but
                // fall back to parsing the id so rows written by an
                // older build without the payload still resolve.
                let convID = entry.payload["conversation_id"]
                    ?? Self.conversationID(fromPromptID: entry.targetID)
                guard let convID, !convID.isEmpty else { return nil }
                let snippet = entry.payload["snippet"]?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return DesignMockPromptBookmark(
                    bookmarkID: entry.bookmarkID,
                    promptID: entry.targetID,
                    conversationID: convID,
                    threadTitle: entry.title
                        ?? entry.payload["thread_title"]
                        ?? entry.label,
                    snippet: (snippet?.isEmpty == false ? snippet! : "—"),
                    source: (entry.source ?? "unknown").lowercased(),
                    model: entry.model ?? "—",
                    updated: Self.formatUpdated(entry.primaryTime ?? entry.updatedAt)
                )
            }
            self.promptBookmarks = prompts
            self.pinnedPromptIDs = Set(prompts.map(\.promptID))
        } catch {
            lastError = String(describing: error)
        }
    }

    /// Toggle a prompt bookmark. `conversationID` is threaded in (not
    /// derived) so a caller that already knows the owning thread doesn't
    /// pay the cost of re-parsing the id — and `snippet`/`threadTitle`
    /// get stored in `payload` so the sidebar can render a meaningful
    /// row without a separate lookup.
    func togglePromptBookmark(
        promptID: String,
        conversationID: String,
        snippet: String,
        threadTitle: String?,
        services: AppServices
    ) async {
        let shouldBookmark = !pinnedPromptIDs.contains(promptID)
        var payload: [String: String] = [
            "conversation_id": conversationID
        ]
        let trimmed = snippet.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            // Cap the snippet so `payload_json` stays small — the sidebar
            // only shows a single line anyway.
            payload["snippet"] = String(trimmed.prefix(280))
        }
        if let threadTitle,
           !threadTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            payload["thread_title"] = threadTitle
        }

        // Optimistic update so the pin UI flips immediately — the
        // authoritative refresh below corrects any drift.
        if shouldBookmark {
            pinnedPromptIDs.insert(promptID)
        } else {
            pinnedPromptIDs.remove(promptID)
        }

        do {
            _ = try await services.bookmarks.setBookmark(
                target: BookmarkTarget(
                    targetType: .prompt,
                    targetID: promptID,
                    payload: payload
                ),
                bookmarked: shouldBookmark
            )
            await refreshBookmarks(services: services)
            // If the center pane is scoped to bookmarked threads, the
            // set of matching threads may have just changed (first pin
            // on a thread promotes it in; last unpin kicks it out).
            if currentQuery.bookmarksOnly {
                await refresh(services: services)
            }
        } catch {
            // Revert the optimistic flip so the UI reflects the DB again.
            if shouldBookmark {
                pinnedPromptIDs.remove(promptID)
            } else {
                pinnedPromptIDs.insert(promptID)
            }
            lastError = String(describing: error)
        }
    }

    /// O(1) lookup used by the expanded-card prompt list and the
    /// reader's message bubbles to paint their pin state.
    func isPromptBookmarked(_ promptID: String) -> Bool {
        pinnedPromptIDs.contains(promptID)
    }

    /// Recover the owning conversation id from a message id. Message
    /// ids are `{conversationID}:{messageRowID}` — we lastIndex(of:) so
    /// conversation ids that themselves contain colons (rare but
    /// legal in imports from some sources) still round-trip.
    private static func conversationID(fromPromptID promptID: String) -> String? {
        guard let sep = promptID.lastIndex(of: ":") else { return nil }
        let head = String(promptID[..<sep])
        return head.isEmpty ? nil : head
    }

    // MARK: - Fetch helpers

    private struct Page {
        let rows: [DesignMockConversation]
        let total: Int
    }

    /// Single fetch path — if the query has a keyword we go through FTS
    /// (`SearchRepository`), otherwise through the index. This mirrors the
    /// pattern `LibraryViewModel.fetchPage` uses for the canonical list.
    private func fetchPage(
        services: AppServices,
        filter: ArchiveSearchFilter,
        sortKey: ConversationSortKey,
        offset: Int,
        knownTotal: Int? = nil
    ) async throws -> Page {
        if !filter.normalizedKeyword.isEmpty {
            // Pass the sort key through so toolbar directives like
            // `sort:updated-asc` reach the FTS layer. Without this the
            // search repository silently ordered by relevance and the
            // typed directive had no effect — the column header showed
            // an ascending caret but the rows came back in rank order.
            let searchQuery = SearchQuery(
                filter: filter,
                offset: offset,
                limit: pageSize,
                sortKey: sortKey
            )
            let results = try await services.search.search(query: searchQuery)
            let total: Int
            if let knownTotal {
                total = knownTotal
            } else {
                total = try await services.search.count(query: searchQuery)
            }
            return Page(
                rows: results.enumerated().map { idx, result in
                    DesignMockConversation(
                        id: result.conversationID,
                        title: result.displayTitle,
                        updated: Self.formatUpdated(result.primaryTime),
                        sortRank: offset + idx,
                        prompts: result.messageCount,
                        source: (result.source ?? "unknown").lowercased(),
                        model: result.model ?? "—",
                        snippet: result.snippet.isEmpty ? nil : result.snippet
                    )
                },
                total: total
            )
        } else {
            let listQuery = ConversationListQuery(
                offset: offset,
                limit: pageSize,
                sortBy: sortKey,
                filter: filter
            )
            let rows = try await services.conversations.fetchIndex(query: listQuery)
            let total: Int
            if let knownTotal {
                total = knownTotal
            } else {
                total = try await services.conversations.count(query: listQuery)
            }
            return Page(
                rows: rows.enumerated().map { idx, summary in
                    DesignMockConversation(
                        id: summary.id,
                        title: summary.displayTitle,
                        updated: Self.formatUpdated(summary.primaryTime),
                        sortRank: offset + idx,
                        prompts: summary.messageCount,
                        source: (summary.source ?? "unknown").lowercased(),
                        model: summary.model ?? "—",
                        snippet: nil
                    )
                },
                total: total
            )
        }
    }

    private static func buildFilter(from query: FetchQuery) -> ArchiveSearchFilter {
        var filter = ArchiveSearchFilter(keyword: query.keyword)
        if let source = query.source {
            filter.sources = [source]
        }
        if let model = query.model {
            filter.models = [model]
        }
        if query.bookmarksOnly {
            filter.bookmarkedOnly = true
        }
        if let tagName = query.tagName {
            filter.bookmarkTags = [tagName]
        }
        return filter
    }

    private static func sourcesFromMock(_ convos: [DesignMockConversation]) -> [DesignMockSource] {
        var totals: [String: Int] = [:]
        var modelCounts: [String: [String: Int]] = [:]
        for convo in convos {
            totals[convo.source, default: 0] += 1
            modelCounts[convo.source, default: [:]][convo.model, default: 0] += 1
        }
        return totals
            .sorted { $0.value > $1.value }
            .map { name, count in
                let models = (modelCounts[name] ?? [:])
                    .sorted { $0.key < $1.key }
                    .map { DesignMockSourceModel(name: $0.key, count: $0.value) }
                return DesignMockSource(name: name, count: count, models: models)
            }
    }

    private static func captureDatabaseInfo(path: String) -> DatabaseInfo {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let size = attrs?[.size] as? Int64
        return DatabaseInfo(path: path, sizeBytes: size)
    }

    // MARK: - Formatting

    /// `primaryTime` is stored as an ISO-ish string in the archive; for row
    /// display we only want a compact "Apr 18"-style label. Falling back to a
    /// prefix of the raw string (or em dash) keeps exotic formats from
    /// blanking the column entirely.
    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let fallbackISOFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static let displayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM dd"
        return f
    }()

    static func formatUpdated(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "—" }
        if let date = isoFormatter.date(from: raw) ?? fallbackISOFormatter.date(from: raw) {
            return displayFormatter.string(from: date)
        }
        return String(raw.prefix(10))
    }

    /// Collapse whitespace and trim to keep a prompt snippet to one visible
    /// line in the expanded card list. Full text lives in the right pane.
    private static func snippet(from text: String) -> String {
        let collapsed = text
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        let trimmed = collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 140 { return trimmed }
        return String(trimmed.prefix(140)) + "…"
    }
}

/// Prompt-level bookmark row shown as a child of the sidebar Bookmarks
/// disclosure. Each row represents one pinned user prompt — clicking the
/// row opens its owning conversation and scrolls to the message. Phase 4
/// replaced the previous thread-level `DesignMockBookmark` shape; a thread
/// is now "bookmarked" transitively when any of its prompts are pinned.
fileprivate struct DesignMockPromptBookmark: Identifiable, Hashable {
    let bookmarkID: Int
    /// Stable message id (`{conversationID}:{messageRowID}`). Used both
    /// as the sidebar row id and as the scroll anchor passed through
    /// `pendingPromptID` when the user clicks the row.
    let promptID: String
    let conversationID: String
    /// Title of the owning conversation. Shown as the secondary line
    /// so the user can tell two same-snippet pins apart (e.g. two
    /// different threads both opening with "fix this bug").
    let threadTitle: String
    /// Cached prompt snippet — the primary visual of the row. Stored
    /// in the bookmark's `payload_json` so the sidebar doesn't have to
    /// re-fetch message bodies to render.
    let snippet: String
    let source: String
    let model: String
    let updated: String

    var id: String { promptID }
}

/// User-authored message displayed in the expanded-card prompt list.
fileprivate struct DesignMockPrompt: Identifiable, Hashable {
    let id: String
    /// Position of the prompt within the conversation (0-indexed across only
    /// user messages). Used for the "Prompt N" label.
    let index: Int
    let snippet: String
}

struct DesignMockRootView: View {
    @EnvironmentObject private var services: AppServices
    @StateObject private var store = DesignMockDataStore()
    @State private var selectedSidebarItemID: DesignMockSidebarItem.ID? = DesignMockSidebarItem.allThreads.id
    /// Multi-selection storage. Was previously a single `ID?`, but the
    /// user wanted to lasso-select multiple threads in both the table and
    /// the card list and DnD-toggle tags onto the whole batch at once.
    /// `Table` and `List` both accept a `Set` binding natively, so this
    /// plugs straight in and SwiftUI auto-batches multi-selected drags
    /// into a single drop delivery on tag rows.
    @State private var selectedConversationIDs: Set<DesignMockConversation.ID> = []
    @State private var selectedLayoutMode: DesignMockLayoutMode = .default
    @State private var searchText = ""
    @State private var expandedPromptConversationID: DesignMockConversation.ID?
    /// Rotates on every keyboard-driven selection change (plain ↑/↓
    /// step via `moveSelection`, ⌘↑/⌘↓ jump-to-edge via the menu).
    /// The thread-list / table panes observe this token and scroll
    /// the current selection into view. We don't key off
    /// `selectedConversationIDs` directly because mouse clicks also
    /// mutate it, and the user deliberately rejected click-driven
    /// auto-scroll ("テーブルでも、選択するだけでは自動で上にスクロール
    /// せず") — a dedicated pulse lets keyboard navigation follow
    /// the cursor without regressing that behaviour.
    @State private var keyboardSelectionPulse: UUID?
    /// Prompt outline for `.viewer` mode's ⌘↑ / ⌘↓ navigation.
    /// In viewer mode there's no visible prompt list, so the menu
    /// shortcut steps through user messages directly in the
    /// transcript: each press fires `pendingPromptID` with the
    /// anchor of the prev / next prompt. Cached at the shell so
    /// re-entering viewer on the same thread is instant. Empty
    /// outside viewer mode.
    @State private var viewerPromptOutline: [DesignMockPrompt] = []
    /// Id of the prompt ⌘↑ / ⌘↓ is currently anchored on in viewer
    /// mode. Separate from `pendingPromptID` because that binding
    /// gets cleared by the reader once the scroll lands (it's a
    /// one-shot signal), whereas the step-walk needs a persistent
    /// cursor to decide what "next prompt" means. Reset whenever
    /// the viewer outline reloads for a different conversation.
    @State private var viewerActivePromptID: String?
    /// One-shot signal that bounces through `selectedPromptID` on the
    /// reader side. Rotating a fresh UUID on tap re-fires the reader's
    /// `requestedPromptID` binding even when the user taps the same
    /// prompt twice.
    @State private var pendingPromptID: String?
    /// Shared library view-model. Hoisted to the shell (rather than
    /// scoped to the reader) so the reader pane and the saved-filter
    /// history list observe the same state. Tag UI was removed in the
    /// "ditch tags, embrace search history" redesign — the VM is kept
    /// because it still drives viewer-mode data, saved filters, and
    /// the (upcoming) prompt-level bookmark surface.
    @State private var libraryViewModel: LibraryViewModel?
    /// Rolling list of find-in-page queries the user ran inside an
    /// open thread. Feeds `.searchSuggestions` when the search field
    /// is acting as a thread-scoped finder (`.default` / `.viewer`
    /// modes) so the dropdown shows "what I searched for while
    /// reading" instead of "filters I applied to the library".
    @StateObject private var recentInThreadQueriesStore = RecentInThreadQueriesStore()
    /// Backs the consolidated archive.db surface (middle pane = Drop-
    /// folder header + intake timeline; right pane = file list). Lazily
    /// materialized on first `.task` so mock-mode launches don't build
    /// one before the user picks the archive row — and keeping it on
    /// the shell instead of scoped to the panes means it survives
    /// layout-mode switches without losing the current snapshot / file
    /// selection.
    @State private var archiveInspectorVM: ArchiveInspectorViewModel?
    /// Pending debounced `recordRecentSearch` call. Cancel-and-reschedule
    /// on every `composedQuery` change so typing "swift" doesn't write +
    /// re-read the saved-filters table five times in a row — the final
    /// settled query is the only one that gets recorded. Pairs with the
    /// store's own "last write wins" fetch: whatever the user actually
    /// landed on is what enters the recent-filter history.
    @State private var recordRecentSearchTask: Task<Void, Never>?
    /// Min / max bounds for the `.default` layout's center pane. Used
    /// in three places — the `navigationSplitViewColumnWidth(min:max:)`
    /// modifier, the `currentCenterIdeal` clamp of the persisted value
    /// on read-back, and the `persistCenterWidth` clamp on write. All
    /// three must agree or a hand-edited / stale preference can lock
    /// the user out of the split.
    private static let centerWidthMin: CGFloat = 180
    private static let centerWidthMax: CGFloat = 760
    /// Min / max bounds for the sidebar column. See `centerWidthMin`
    /// / `centerWidthMax` for the three-call-site invariant.
    private static let sidebarWidthMin: CGFloat = 150
    private static let sidebarWidthMax: CGFloat = 320

    /// Persisted center-pane width for the `.default` layout. Single
    /// slot because the default pane now renders only the card list —
    /// the historical split between card and table widths was dropped
    /// when the in-pane Table/Cards picker was removed. Table view
    /// lives only in the separate `.table` outer layout, which sets
    /// its own pane width via a different mechanism.
    @AppStorage("designmock.centerPaneIdealWidth.cards") private var centerWidthCards: Double = 460
    /// Persisted sidebar width. Same GeometryReader-probe pattern as
    /// the center pane — `NavigationSplitView` doesn't publish a
    /// current-width binding so we have to observe it from inside
    /// the column and debounce writes back into UserDefaults.
    /// Default seeded to the pre-persistence `ideal` (270pt) so
    /// first launches look identical to the prior build.
    @AppStorage("designmock.sidebarWidth") private var sidebarWidthPref: Double = 270
    /// Debounces the GeometryReader-driven save so a drag-resize doesn't
    /// write to UserDefaults once per frame. Fires ~200ms after the user
    /// stops dragging.
    @State private var persistCenterWidthTask: Task<Void, Never>?
    /// Mirror of `persistCenterWidthTask` for the sidebar width probe.
    /// Debouncing lives per-column so a drag on one side doesn't
    /// cancel a pending write for the other.
    @State private var persistSidebarWidthTask: Task<Void, Never>?
    /// One-shot signal fired when the user hits Enter in the toolbar
    /// search field. Downstream the reader observes this token and,
    /// if a query is active, advances to the next in-thread search
    /// match — matching the "Enter cycles hits" convention in every
    /// other macOS find-in-page surface (Safari, Preview, TextEdit).
    /// Rotating a fresh UUID on each keystroke means pressing Enter
    /// repeatedly keeps stepping, and the observer dedupe guards
    /// against stale fires from unrelated state changes.
    @State private var findNextToken: UUID?

    var body: some View {
        rootSplitView
        // Toolbar search field stays pinned in the same spot across all
        // layout modes. Earlier iterations swapped `.searchable` out in
        // focus mode for a reader-top find-in-page bar, but that caused
        // the text field's on-screen position to jump when the user
        // flipped into focus with a query already typed — disorienting
        // enough that the user called it out explicitly. Focus mode now
        // reuses this very field as the in-thread finder; only the
        // prev/next + N/M nav strip lives inside the reader.
        .searchable(text: $searchText, prompt: searchPrompt)
        // Query history lives inside the search field's own dropdown —
        // `.searchSuggestions` renders a list beneath the field whenever
        // it has focus. Keeps each surface focused on one job: sidebar =
        // navigate, search box = re-run a recent query.
        .searchSuggestions {
            ForEach(searchQuerySuggestions, id: \.self) { suggestion in
                // `.searchCompletion(_)` makes the row selectable — click
                // (or ↑/↓ + Return) writes the string into the bound
                // `searchText`, which then flows through the normal
                // `composedQuery` → `recordRecentSearch` pipeline and
                // re-ranks the entry to the top of the history on reuse.
                Label(suggestion, systemImage: "clock.arrow.circlepath")
                    .searchCompletion(suggestion)
            }
        }
        // Enter in the search field → step to the next in-thread
        // match. Mirrors the `⌘G` / Enter convention every macOS
        // find-in-page surface uses. We only fire when a query is
        // actually typed — pressing Enter on an empty field would
        // otherwise be a no-op that the observer still has to wake
        // for. The reader side decides whether there's a reader
        // mounted (`stepMatch` bails if `matchLocations` is empty).
        .onSubmit(of: .search) {
            guard !searchText.isEmpty else { return }
            findNextToken = UUID()
        }
        .navigationTitle("")
        .toolbar {
            // Toolbar sort picker removed — sort direction is now chosen
            // per-column via the filter card's segmented picker, and the
            // initial "global" sort lives implicitly in the DB query.

            // Small spinner that appears while the store is refreshing.
            // Keeps ⌘R observably feedback-ful: the sidebar may end up
            // with identical rows after a refresh (no actual data
            // change), which earlier left the user unsure whether the
            // shortcut had fired. A ProgressView here lights up for
            // the ~100-300ms the query takes, giving a clear "we heard
            // you" signal. `.controlSize(.small)` keeps it from
            // dominating the title bar height.
            ToolbarItem(placement: .primaryAction) {
                if store.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .progressViewStyle(.circular)
                        .frame(width: 16, height: 16)
                }
            }

            ToolbarItem(placement: .primaryAction) {
                DesignMockLayoutModePicker(selection: $selectedLayoutMode)
            }

            ToolbarItem(placement: .primaryAction) {
                // Native macOS share menu. Was previously a
                // copy-to-clipboard fallback because the mock shell
                // didn't have a handle on `ConversationDetail`
                // (only the lightweight summary row) — the button
                // now materializes the selected conversation as a
                // temp Markdown file on demand and hands it to
                // `ShareLink`, which opens the full
                // `NSSharingServicePicker` (AirDrop / Mail /
                // Messages / Notes / Save to Files / installed
                // extensions), same as the detail-pane share.
                DesignMockShareButton(
                    conversation: selectedConversation,
                    services: services
                )
            }
        }
        .background(
            WindowConfigurator { window in
                window.titleVisibility = .hidden
                window.subtitle = ""
                window.title = ""
                window.representedURL = nil
                window.minSize = NSSize(width: 980, height: 640)
            }
        )
        // Hide the 1pt horizontal separator AppKit draws underneath
        // the toolbar. A one-shot `window.titlebarSeparatorStyle =
        // .none` inside the `WindowConfigurator` closure above is
        // NOT enough — `NavigationSplitView` re-asserts `.automatic`
        // every time the sidebar column is shown/hidden, so the
        // line flickers back on whenever the user toggles the
        // sidebar (user report: "サイドバーの開閉によって区切り線
        // が出てしまう"). `WindowTitlebarSeparatorHider` installs a
        // KVO observer and clamps the value back to `.none` on
        // every reassertion for as long as this view is mounted.
        .background(WindowTitlebarSeparatorHider())
        .environmentObject(store)
        .task {
            // Build the shared library VM lazily — `@EnvironmentObject`
            // isn't available in `init`, so we can't construct it in a
            // `@StateObject` initializer. Doing it here runs once per
            // view identity, which matches the lifecycle we want.
            if libraryViewModel == nil {
                libraryViewModel = LibraryViewModel(
                    conversationRepository: services.conversations,
                    searchRepository: services.search,
                    bookmarkRepository: services.bookmarks,
                    viewService: services.views,
                    tagRepository: services.tags
                )
            }
            if archiveInspectorVM == nil {
                archiveInspectorVM = ArchiveInspectorViewModel(
                    vault: services.rawExportVault,
                    intakeLog: services.intakeActivityLog
                )
            }
            // Populate `unifiedFilters` up-front so the saved-filter
            // surfaces (sidebar rows + `.searchSuggestions` dropdown)
            // have something to render on first paint. Without this
            // they stay empty until the user triggers a save-recent
            // path somewhere else in the app.
            if let libraryViewModel {
                await libraryViewModel.reloadSupportingState()
            }
            // Initial load. Store no-ops for the `.mock` data source so the
            // bundled sample remains visible in dev runs without a real DB.
            store.load(services: services)
        }
        // Funnel sidebar / search / sort state into a single FetchQuery, then
        // ship it to the store. Any change here triggers a fresh DB fetch
        // (cancelling the previous one) so the center pane is always showing
        // exactly what the current toolbar + sidebar configuration demands.
        .onChange(of: composedQuery) { _, newQuery in
            store.setQuery(newQuery, services: services)
            // Debounce the recent-filter recording. Prior version fired on
            // every keystroke, and each call triggered a DB UPSERT +
            // three reads (`listRecentFilters` + `listSavedViews` +
            // `listUnifiedFilters`) + a `@Published` update that re-
            // laid-out the sidebar. Typing a 5-char query stacked up
            // ~5 of those bursts on the MainActor, visibly stalling
            // the card list. Now only the *settled* query (user
            // paused ≥400ms) is recorded. `saveRecentFilter` still
            // dedupes by filter_hash on top of this, so pinning the
            // same query twice never double-writes.
            // Record into the library-filter history ONLY in `.table`
            // mode. Thread-mode recording rides a separate
            // `.onChange(of: searchText)` below because `composedQuery`
            // doesn't include the keyword in `.default` / `.viewer`
            // (the keyword is a find-in-page substring there, not a
            // library filter), so this observer wouldn't fire on
            // keyword changes in those modes and the in-thread history
            // would stay empty forever.
            guard selectedLayoutMode == .table else { return }
            recordRecentSearchTask?.cancel()
            let capturedQuery = newQuery
            recordRecentSearchTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard !Task.isCancelled else { return }
                libraryViewModel?.recordRecentSearch(
                    archiveFilter(from: capturedQuery)
                )
            }
        }
        // Thread-mode ( `.default` / `.viewer` ) history recording.
        // In those modes the search field is a find-in-page over the
        // open thread, so the user's keystrokes never flow into
        // `composedQuery` (the library filter). Observe `searchText`
        // directly, debounce by 400ms just like the library path, and
        // route the settled substring into `recentInThreadQueriesStore`
        // so the `.searchSuggestions` dropdown has something to offer
        // on subsequent focuses.
        .onChange(of: searchText) { _, newText in
            guard selectedLayoutMode != .table else { return }
            recordRecentSearchTask?.cancel()
            let capturedText = newText
            recordRecentSearchTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard !Task.isCancelled else { return }
                // Strip DSL directives (`sort:`, `source:`, …) the
                // same way the reader's `effectiveQuery` does, so
                // the history stores only the substring that was
                // actually matched.
                let parsed = DesignMockQueryLanguage.parse(capturedText)
                recentInThreadQueriesStore.record(parsed.keyword)
            }
        }
        // Keep one canonical "currently displayed" conversation across
        // every layout mode. Without this, the selection set was free
        // to stay empty on first launch (or after a fetch that
        // invalidated the previous selection), and each mode
        // independently papered over that with its own fallback —
        // the reader showed `conversations.first`, but the table
        // highlighted nothing, and switching modes felt like the app
        // was quietly picking a different thread each time. Seeding /
        // repairing the set here collapses those fallbacks into a
        // single source of truth.
        .onChange(of: store.conversations.map(\.id)) { _, newIDs in
            repairSelectionIfNeeded(currentIDs: newIDs)
        }
        .onAppear {
            repairSelectionIfNeeded(currentIDs: store.conversations.map(\.id))
        }
        // Publish shell-scoped actions for the main menu. The struct
        // is rebuilt on every body recompute so `currentLayout`,
        // `deleteSelectedSnapshot`'s enablement, and the library
        // reload closure all track the shell's live state. SwiftUI
        // diffs at the Commands layer against the new value, so the
        // menu item states (disabled / enabled) stay in lockstep
        // with the window.
        .focusedSceneValue(\.shellCommands, shellCommandActions)
        // Publish the library view model so `AppCommands`' Next /
        // Previous Conversation buttons have something to call.
        // Previously only `MacOSRootView` (the deprecated alternate
        // shell) published this, which meant the menu item rendered
        // but did nothing in the shipping UI. Optional because the
        // shared VM is materialized lazily in the root `.task` —
        // SwiftUI drops the publish when nil so the menu item
        // correctly disables until the VM is ready.
        .focusedSceneValue(\.libraryViewModel, libraryViewModel)
        // Viewer mode publishes ⌘↑ / ⌘↓ as "step prev / next
        // prompt" via scene-scoped focus value. State 3 publishes
        // the same key via `.focusedValue` on the prompt list,
        // which SwiftUI routes as a focused-subtree publication —
        // those take precedence over `.focusedSceneValue`, so the
        // state-3 semantics (jump-to-edge) shadow the scene-wide
        // viewer closures whenever the prompt list is actually in
        // tree. Outside viewer and state 3, both closures are nil
        // and `AppCommands` falls through to the shell's thread-
        // level jump closures.
        .focusedSceneValue(\.promptNavigation, viewerPromptNavigationActions)
        // Load the prompt outline for the currently-selected
        // conversation whenever we're in viewer mode. Re-fires on
        // conversation change via the task id. The store caches
        // outlines so repeat loads are cheap; guarding on layout
        // mode avoids paying the fetch cost when the user never
        // enters viewer.
        .task(id: viewerOutlineLoadToken) {
            await loadViewerPromptOutlineIfNeeded()
        }
    }

    /// Composite key for the viewer-outline loader task. Changes
    /// whenever either the selected conversation id OR the layout
    /// mode transitions flips — both need the outline re-fetched
    /// (mode flip may have landed us in viewer for the first time
    /// with a stale empty outline; conversation change obviously
    /// invalidates the old one). String encoding is fine because
    /// `.task(id:)` only needs Equatable.
    private var viewerOutlineLoadToken: String {
        let convID = selectedConversation?.id ?? ""
        let inViewer = selectedLayoutMode == .viewer
        return "\(inViewer ? "v" : "x"):\(convID)"
    }

    /// Populate `viewerPromptOutline` + reset the step cursor when
    /// the current viewer target changes. No-op outside viewer mode
    /// so non-viewer states don't pay the fetch cost, and clears
    /// the cache when the user leaves viewer so ⌘↑ / ⌘↓ in
    /// unrelated modes don't see stale prompts.
    private func loadViewerPromptOutlineIfNeeded() async {
        guard selectedLayoutMode == .viewer,
              let conv = selectedConversation else {
            viewerPromptOutline = []
            viewerActivePromptID = nil
            return
        }
        let outline = await store.promptOutline(for: conv.id, services: services)
        await MainActor.run {
            viewerPromptOutline = outline
            // Keep the cursor if it still resolves against the
            // freshly-loaded outline (e.g. re-entering viewer on
            // the same thread). Otherwise reset — it belonged to
            // a different conversation.
            if let cursor = viewerActivePromptID,
               outline.contains(where: { $0.id == cursor }) == false {
                viewerActivePromptID = nil
            }
        }
    }

    /// Build the `PromptNavigationActions` the shell publishes
    /// while in `.viewer`. Supplies all four closures:
    ///
    /// - `stepPrev` / `stepNext` (⌘↑ / ⌘↓) — walk the cursor one
    ///   prompt at a time. In viewer mode plain ↑ / ↓ scroll the
    ///   reader and there's no list UI to arrow through, so the
    ///   menu shortcut is the only step affordance.
    /// - `jumpFirst` / `jumpLast` (⌘⇧↑ / ⌘⇧↓) — land the cursor
    ///   at the outline's first / last prompt. Same gesture that
    ///   state 3 binds, so edge-jump is consistent across surfaces.
    ///
    /// Outside viewer mode (or while the outline is still empty)
    /// all four fields are nil, which drops `AppCommands` back to
    /// the shell's thread-level `selectFirst/LastConversation`
    /// for the jump pair and greys out the step pair.
    private var viewerPromptNavigationActions: PromptNavigationActions {
        guard selectedLayoutMode == .viewer, !viewerPromptOutline.isEmpty else {
            return PromptNavigationActions(
                stepPrev: nil,
                stepNext: nil,
                jumpFirst: nil,
                jumpLast: nil
            )
        }
        let outline = viewerPromptOutline
        let cursor = viewerActivePromptID
        let pendingBinding = $pendingPromptID
        let cursorBinding = $viewerActivePromptID
        // Step by ±1 through the outline. `steppedID` returns nil at
        // the edges (clamp, no wrap) and seeds first/last when no
        // cursor exists yet.
        let step: (Int) -> Void = { delta in
            guard let nextID = steppedID(in: outline, from: cursor, by: delta) else {
                return
            }
            cursorBinding.wrappedValue = nextID
            // Rotating the anchor through `pendingPromptID`
            // re-fires the reader's scroll even if the same id
            // gets re-sent (pending is a one-shot that the reader
            // clears after consuming).
            pendingBinding.wrappedValue = nextID
        }
        // Jump-to-edge shares the same cursor + pending wiring as
        // step so the reader reacts identically; only the target
        // index differs (fixed first / last instead of cursor ± 1).
        let jump: (Bool) -> Void = { toFirst in
            guard let targetID = toFirst ? outline.first?.id : outline.last?.id else {
                return
            }
            if cursorBinding.wrappedValue == targetID { return }
            cursorBinding.wrappedValue = targetID
            pendingBinding.wrappedValue = targetID
        }
        return PromptNavigationActions(
            stepPrev: { step(-1) },
            stepNext: { step(1) },
            jumpFirst: { jump(true) },
            jumpLast: { jump(false) }
        )
    }

    /// Build the `ShellCommandActions` bundle that `AppCommands`
    /// pulls from `FocusedValues`. Computed property rather than
    /// `@State` because every value inside is either already-stored
    /// state or a closure — reconstructing it per body pass is free
    /// and avoids the co-ordination overhead of a redundant mirror.
    private var shellCommandActions: ShellCommandActions {
        // Capture the projected bindings / references once so the
        // closures don't have to reach back into `self` (which, as a
        // SwiftUI View value-type snapshot, can be stale by the time
        // a menu click fires).
        let layoutBinding = $selectedLayoutMode
        let selectionBinding = $selectedConversationIDs
        let expandedBinding = $expandedPromptConversationID
        let scrollPulseBinding = $keyboardSelectionPulse
        let capturedServices = services
        let capturedStore = store
        let capturedLibraryVM = libraryViewModel
        let capturedArchiveVM = archiveInspectorVM
        let archiveFocused = showingArchiveInspector
        let currentSelection = selectedConversationIDs
        let currentExpanded = expandedPromptConversationID
        let currentLayout = selectedLayoutMode
        let visibleConversations = store.conversations

        // Jump-to-first / jump-to-last closures bound to ⌘↑ / ⌘↓.
        // Single-step navigation is delegated to the focused List/
        // Table widget (plain ↑/↓ when the middle pane is key) —
        // reserving the menu binding for "jump to edge" matches the
        // macOS-wide gesture and frees plain arrows for cursor
        // movement inside text fields.
        //
        // We snapshot `visibleConversations` and `currentExpanded`
        // now so the closure isn't re-reading a potentially-stale
        // `self` when the menu fires.
        let jumpToEdge: (Bool) -> (() -> Void)? = { toFirst in
            guard !visibleConversations.isEmpty else { return nil }
            return {
                let ids = visibleConversations.map(\.id)
                guard let targetID = toFirst ? ids.first : ids.last else {
                    return
                }
                // No-op when we're already there — avoids poking the
                // selection binding and triggering downstream
                // `.onChange` observers for nothing.
                if currentSelection == [targetID] { return }
                selectionBinding.wrappedValue = [targetID]
                // If a card was expanded before the jump, keep state
                // 3 coherent by sliding the expanded id to the edge
                // we just landed on. Otherwise the center pane would
                // still show prompts from whatever thread happened
                // to be expanded before.
                if currentExpanded != nil {
                    expandedBinding.wrappedValue = targetID
                }
                // Same pulse the step-by-one path uses — jump-to-
                // edge is a keyboard gesture too, so the pane should
                // scroll to show the new selection.
                scrollPulseBinding.wrappedValue = UUID()
            }
        }
        let firstClosure = jumpToEdge(true)
        let lastClosure = jumpToEdge(false)

        // Drill-in (⌘→) / drill-out (⌘←) along the Thread list →
        // Thread → Prompt hierarchy. Three canonical states:
        //
        //   1. `.table`                            (Thread list)
        //   2. `.default` + currentExpanded == nil (Thread)
        //   3. `.default` + currentExpanded != nil (Prompt list)
        //
        // `.viewer` isn't part of the chain — it's an orthogonal
        // "focus mode" the user enters via ⌘3. We treat ⌘← in
        // `.viewer` as "escape back to `.default`" so the shortcut
        // still has some sensible meaning there; ⌘→ in `.viewer` is
        // a no-op (we're already maximally zoomed-in).
        let drillInClosure: (() -> Void)?
        let drillOutClosure: (() -> Void)?
        switch currentLayout {
        case .table:
            // ⌘→ opens the selected thread in `.default`. If nothing
            // is selected yet, auto-pick the top row so the shortcut
            // still has an obvious effect instead of silently doing
            // nothing (same convention as ⌘↓ on an unfocused list).
            drillInClosure = visibleConversations.isEmpty ? nil : {
                if currentSelection.isEmpty,
                   let first = visibleConversations.first {
                    selectionBinding.wrappedValue = [first.id]
                }
                layoutBinding.wrappedValue = .default
            }
            // Already at the leftmost level — nothing to collapse.
            drillOutClosure = nil

        case .default:
            if currentExpanded == nil {
                // State 2 → State 3: expand the currently-selected
                // card. Only enabled when there actually is a
                // selection; otherwise there's no card to expand.
                drillInClosure = currentSelection.isEmpty ? nil : {
                    if let selectedID = currentSelection.first {
                        expandedBinding.wrappedValue = selectedID
                    }
                }
                // State 2 → State 1: back to the table.
                drillOutClosure = {
                    layoutBinding.wrappedValue = .table
                }
            } else {
                // State 3 → Viewer: ⌘→ at the end of the canonical
                // drill chain slides the user into focus/viewer
                // mode. The user asked for this extension on top
                // of the original 3-state model — "さらに cmd+左右
                // で、フォーカスモードに切り替えることはできる？" —
                // so ⌘→ now reads as "keep drilling toward the
                // content: list → card → prompts → reader-only".
                // ⌘← in `.viewer` already symmetrically hops back
                // to `.default` (see the `.viewer` case below), so
                // the gesture round-trips cleanly.
                drillInClosure = {
                    layoutBinding.wrappedValue = .viewer
                }
                // State 3 → State 2: collapse the card.
                drillOutClosure = {
                    expandedBinding.wrappedValue = nil
                }
            }

        case .viewer:
            // Viewer is off-chain. Treat ⌘← as "go back to the
            // default layout" so ⌘3 → ⌘← round-trips cleanly.
            drillInClosure = nil
            drillOutClosure = {
                layoutBinding.wrappedValue = .default
            }
        }

        // Enable "Delete Snapshot…" only when:
        //   1. the sidebar is pointing at archive.db (so the
        //      Archive Inspector actually owns the current view)
        //   2. a snapshot row is selected, and
        //   3. that id still resolves against the loaded list.
        // Otherwise ship nil so SwiftUI disables the menu item.
        let deleteClosure: (() -> Void)?
        if archiveFocused,
           let vm = capturedArchiveVM,
           let selectedID = vm.selectedSnapshotID,
           let snapshot = vm.snapshots.first(where: { $0.id == selectedID }) {
            deleteClosure = {
                vm.requestDelete(snapshot: snapshot)
            }
        } else {
            deleteClosure = nil
        }

        return ShellCommandActions(
            currentLayout: selectedLayoutMode,
            setLayout: { newMode in
                layoutBinding.wrappedValue = newMode
            },
            reloadLibrary: {
                Task { await capturedStore.refreshAll(services: capturedServices) }
                if let libraryVM = capturedLibraryVM {
                    Task { await libraryVM.reloadSupportingState() }
                }
            },
            selectFirstConversation: firstClosure,
            selectLastConversation: lastClosure,
            drillInSelection: drillInClosure,
            drillOutSelection: drillOutClosure,
            openDropFolder: {
                #if os(macOS)
                NSWorkspace.shared.open(capturedServices.intakeDirURL)
                #endif
            },
            deleteSelectedSnapshot: deleteClosure
        )
    }

    /// Step the selection one row up (delta = -1) or down (delta = +1).
    /// Used by the middle pane's `onKeyPress` handlers — single-step
    /// navigation lives here rather than in `ShellCommandActions`
    /// because the key binding is a first-responder affair (plain ↑/↓
    /// without a menu shortcut), not something the menu bar routes.
    ///
    /// Expanded-id sync matches the jump-to-edge behaviour: if a card
    /// is open (state 3), the expanded id slides to the newly-
    /// selected thread so the center pane's prompt list stays in
    /// sync with whichever row we landed on.
    private func moveSelection(by delta: Int) {
        let conversations = store.conversations
        // Pick whichever selected id appears first in the list order
        // as the "cursor" — multi-select is allowed but stepping
        // only tracks the topmost entry, which matches Mail's
        // behaviour under arrow keys while a multi-selection is held.
        let cursor = conversations.map(\.id).first { selectedConversationIDs.contains($0) }
        guard let nextID = steppedID(in: conversations, from: cursor, by: delta) else {
            return
        }
        selectedConversationIDs = [nextID]
        if expandedPromptConversationID != nil {
            expandedPromptConversationID = nextID
        }
        // Pulse the scroll-follow token so the card/table pane
        // scrolls the newly-selected row into view. Keyboard-driven
        // only — clicks don't fire this path, matching the user's
        // "click-select shouldn't auto-scroll" preference.
        keyboardSelectionPulse = UUID()
    }

    /// Prune the selection set to only ids that actually exist in the
    /// current fetch page, leaving the set empty when the user's
    /// previous pick was filtered away entirely.
    ///
    /// Earlier revisions *also* seeded `[currentIDs.first]` when the
    /// intersection came back empty, so every sidebar change and
    /// query edit guaranteed the reader had something to show. The
    /// user found that actively harmful: "サイドバーから選んだ瞬間に
    /// トップのスレッドが勝手に開かれて履歴がごちゃごちゃになって
    /// しまう" — each sidebar click re-seeded a new "current thread"
    /// which pulled something random into the reader. Now we only
    /// prune; when nothing survives, the reader shows empty state
    /// and the user picks explicitly.
    ///
    /// The stale-id tolerance is intentional: if the user navigates
    /// away to a narrower scope and then back, keeping the prior
    /// selection in the Set means the reader pops back to the same
    /// thread automatically when it becomes visible again — no
    /// destructive clear.
    private func repairSelectionIfNeeded(currentIDs: [DesignMockConversation.ID]) {
        guard !currentIDs.isEmpty else { return }
        let intersected = selectedConversationIDs.intersection(currentIDs)
        guard !intersected.isEmpty else { return }
        // Drop stale ids but keep the user's multi-select intent.
        if intersected != selectedConversationIDs {
            selectedConversationIDs = intersected
        }
    }

    @ViewBuilder
    private var rootSplitView: some View {
        // archive.db short-circuits the layout switch. The Drop-folder
        // header + intake timeline + file list trio has no reader pane
        // to flip between, and threading an "archive mode" into each of
        // the three reader layouts would duplicate the same 3-column
        // arrangement three times. The VM nil-guard handles the first
        // frame before `.task` materializes it — fall-through during
        // that single frame is invisible because the user can't have
        // clicked archive.db and landed here before the task fires.
        if showingArchiveInspector, let archiveVM = archiveInspectorVM {
            archiveInspectorSplit(vm: archiveVM)
        } else {
            readerLayoutSplit
        }
    }

    @ViewBuilder
    private var readerLayoutSplit: some View {
        switch selectedLayoutMode {
        case .table:
            NavigationSplitView {
                sidebar
            } detail: {
                centerTable
            }
        case .default:
            // Center pane is just the thread list now — no header strip,
            // no in-pane view-mode switcher. The picker (Table vs Cards)
            // and the "N threads" count were removed per user request;
            // the Table option lived on as a separate outer layout mode
            // (`.table`) reached from the window toolbar, and the count
            // wasn't worth the vertical real estate it consumed above
            // the card list. Loading and error states still surface —
            // in-flight pagination shows the inline spinner at the list
            // footer, and `store.lastError` is surfaced via the shell's
            // toolbar / status chrome rather than a per-pane banner.
            //
            // The `.id(...)` on the NavigationSplitView keeps a stable
            // identity for the default layout so SwiftUI doesn't tear
            // down and rebuild the pane as sidebar selection / filter
            // state churns.
            NavigationSplitView {
                sidebar
            } content: {
                DesignMockThreadListPane(
                    conversations: store.conversations,
                    selection: $selectedConversationIDs,
                    pendingPromptID: $pendingPromptID,
                    expandedPromptConversationID: $expandedPromptConversationID,
                    isLoadingMore: store.isLoadingMore,
                    onReachEnd: {
                        store.loadMoreIfNeeded(services: services)
                    },
                    onMoveSelection: { delta in
                        moveSelection(by: delta)
                    },
                    scrollPulse: $keyboardSelectionPulse
                )
                .background(centerWidthProbe)
                // Min drops from 320 → 240 so the user can squeeze
                // the center pane narrow enough to exercise the
                // vertical fall-through inside
                // `DesignMockConversationListRow` (switch point
                // ~260pt + 24pt of row padding ≈ 284pt of pane
                // width). Keeping the pane any wider than that
                // prevents the narrow layout from ever appearing,
                // which defeats the point of making the row
                // responsive.
                .navigationSplitViewColumnWidth(
                    min: Self.centerWidthMin,
                    ideal: currentCenterIdeal,
                    max: Self.centerWidthMax
                )
            } detail: {
                // Unified with viewer/focus mode: the toolbar search
                // field is an in-thread finder in default mode too.
                // User request: "デフォルトビューのときはフォーカス
                // ビューと同様にスレッド検索で統一して". Previously
                // default routed `searchText` into `composedQuery`
                // as a library-level keyword filter on the card
                // list; now both modes share the same reader-find
                // behavior, and library-scoped filtering happens
                // via the sidebar (Sources / Bookmarks / saved filters)
                // and DSL directives (`source:` etc., which still
                // flow through `parsed.sortToken` + scope logic in
                // `composedQuery`). `.table` mode still uses the
                // field as a library keyword filter since a table
                // without the reader pane has no thread to search.
                readerPane(inThreadSearch: $searchText)
            }
            .id("default")
        case .viewer:
            NavigationSplitView {
                sidebar
            } detail: {
                readerPane(inThreadSearch: $searchText)
            }
        }
    }

    /// Ideal center-pane width for `.default` layout. Reads the
    /// card-mode `@AppStorage` slot so the width the user settled on
    /// last session is the one the split view opens with next launch.
    /// Only one slot now that the default pane has no in-pane Table
    /// alternative.
    private var currentCenterIdeal: CGFloat {
        // Clamp defensively so a stale / hand-edited preferences value
        // can't lock the user out of the split (below-min disappears
        // the pane, above-max is equally unusable). Bounds are shared
        // with `navigationSplitViewColumnWidth(min:max:)` and
        // `persistCenterWidth` via the static constants above so a
        // persisted narrow width is reproduced on next launch instead
        // of being rounded back up.
        return min(max(CGFloat(centerWidthCards), Self.centerWidthMin), Self.centerWidthMax)
    }

    /// Transparent width probe mounted as the content pane's background.
    /// SwiftUI's `NavigationSplitView` has no binding API for the
    /// *current* column width, so the only way to capture what the user
    /// dragged to is to observe it from inside the pane. `GeometryReader`
    /// reports layout changes, we debounce, then write to the matching
    /// `@AppStorage` slot.
    private var centerWidthProbe: some View {
        GeometryReader { proxy in
            Color.clear
                .onChange(of: proxy.size.width) { _, newValue in
                    persistCenterWidth(newValue)
                }
                .onAppear {
                    persistCenterWidth(proxy.size.width)
                }
        }
    }

    /// Debounced write to the per-mode `@AppStorage` slot. `GeometryReader`
    /// fires on every frame of a drag-resize; persisting raw would churn
    /// UserDefaults ~60× per second. A 200ms trailing window collapses the
    /// burst into a single write landing after the user lets go. Values
    /// outside the slider clamp are dropped so the split view's own min/max
    /// stays authoritative — we're just recording what the user chose
    /// *within* the allowed range. Clamp floor mirrors
    /// `navigationSplitViewColumnWidth(min:)` so a narrow drag is
    /// faithfully restored on next launch instead of being rounded
    /// back up.
    private func persistCenterWidth(_ width: CGFloat) {
        let clamped = Double(min(max(width, Self.centerWidthMin), Self.centerWidthMax))
        // GeometryReader transiently reports 0 during teardown / mode
        // switch. Treating that as a real preference would wipe the
        // saved width the moment the user flips mode.
        guard width > 1 else { return }
        persistCenterWidthTask?.cancel()
        persistCenterWidthTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            if abs(centerWidthCards - clamped) > 0.5 {
                centerWidthCards = clamped
            }
        }
    }

    /// Ideal sidebar width, clamped to the same bounds as
    /// `navigationSplitViewColumnWidth(min:max:)` below so a
    /// hand-edited / stale preference can't lock the user out of
    /// the split.
    private var currentSidebarIdeal: CGFloat {
        min(max(CGFloat(sidebarWidthPref), Self.sidebarWidthMin), Self.sidebarWidthMax)
    }

    /// Transparent width probe mounted as the sidebar's background.
    /// Mirrors `centerWidthProbe` — SwiftUI's `NavigationSplitView`
    /// has no binding for the current sidebar width, so we read it
    /// from a `GeometryReader` parked inside the column and write
    /// the result back after a debounce window.
    private var sidebarWidthProbe: some View {
        GeometryReader { proxy in
            Color.clear
                .onChange(of: proxy.size.width) { _, newValue in
                    persistSidebarWidth(newValue)
                }
                .onAppear {
                    persistSidebarWidth(proxy.size.width)
                }
        }
    }

    private func persistSidebarWidth(_ width: CGFloat) {
        let clamped = Double(min(max(width, Self.sidebarWidthMin), Self.sidebarWidthMax))
        guard width > 1 else { return }
        persistSidebarWidthTask?.cancel()
        persistSidebarWidthTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            if abs(sidebarWidthPref - clamped) > 0.5 {
                sidebarWidthPref = clamped
            }
        }
    }

    /// Reader pane wrapper. Gated on the shared `libraryViewModel` being
    /// built — until then we show a placeholder so the reader, which
    /// needs the VM via environment, doesn't crash on first mount.
    @ViewBuilder
    private func readerPane(inThreadSearch: Binding<String>?) -> some View {
        if let libraryViewModel {
            DesignMockReaderPane(
                conversation: selectedConversation,
                pendingPromptID: $pendingPromptID,
                libraryViewModel: libraryViewModel,
                inThreadSearch: inThreadSearch,
                // Gate Enter-to-step-match on whether this call site is
                // actually running an in-thread search. `.default` and
                // `.viewer` both pass a non-nil binding → Enter steps
                // matches. The now-orphan `inThreadSearch == nil` branch
                // is only taken by call sites that don't surface the
                // in-thread finder (e.g. future embeds / previews) so
                // pressing Enter in the toolbar field there is a silent
                // no-op rather than a hijacked reader step.
                findNextToken: inThreadSearch == nil ? nil : $findNextToken
            )
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var sidebar: some View {
        // Custom binding so a USER click on a Library / Sources /
        // Bookmarks row strips just the DSL directives the sidebar is
        // about to override (`source:`, `model:`, `tag:`, `bookmark:`,
        // `is:`). Without this, selecting a saved-filter entry stuffs
        // `source:claude` (or similar) into the toolbar, then clicking
        // "Bookmarks" / "Sources → chatgpt" appears to do nothing —
        // the DSL in `searchText` overrides the sidebar-derived scope
        // in `composedQuery`, so the fetch query never actually
        // matches what the user just clicked. We DELIBERATELY leave
        // free-text keywords and FTS field-scoped tokens (`content:`,
        // `title:`) plus `sort:` intact so the user's typed query
        // survives a sidebar narrow ("`content:編集` then click
        // gpt-5-2 to drill in"). Clearing through the setter (NOT in
        // `.onChange`) means it only fires for List-driven writes;
        // programmatic writes to `selectedSidebarItemID` (e.g. the
        // saved-filter click handler re-routing to "All Threads")
        // bypass this setter and leave the just-restored DSL in place.
        let sidebarSelection = Binding<DesignMockSidebarItem.ID?>(
            get: { selectedSidebarItemID },
            set: { newValue in
                if let newValue, newValue != selectedSidebarItemID {
                    searchText = DesignMockQueryLanguage
                        .stripSidebarConflictingDirectives(from: searchText)
                }
                selectedSidebarItemID = newValue
            }
        )
        return DesignMockSidebar(
            selection: sidebarSelection,
            sources: store.sources,
            promptBookmarks: store.promptBookmarks,
            databaseInfo: store.databaseInfo,
            totalCount: store.totalCount,
            libraryViewModel: libraryViewModel
        )
        // Finder-parity minimum (~150pt). All sidebar row kinds —
        // `sidebarRow` (icon + title + optional subtitle) and the
        // `sourceRow` disclosure groups — cap at `lineLimit(1)` so
        // they truncate cleanly when the column is squeezed below
        // the text's natural width.
        //
        // `ideal` reads from `@AppStorage` via `currentSidebarIdeal`
        // so a user-dragged width is faithfully reproduced on next
        // launch. The `sidebarWidthProbe` background captures the
        // live width (NavigationSplitView has no binding for it) and
        // writes the debounced result back to UserDefaults.
        .background(sidebarWidthProbe)
        .navigationSplitViewColumnWidth(
            min: Self.sidebarWidthMin,
            ideal: currentSidebarIdeal,
            max: Self.sidebarWidthMax
        )
    }

    /// Single source of truth for the center-pane thread table. Both the
    /// `.table` outer layout (table-only, no reader) and the `.default`
    /// outer layout with display mode `.table` (picker + table + reader)
    /// call this helper, so column declarations / sort binding /
    /// selection binding don't drift between two call sites. The
    /// `.id("center-table")` keeps the identity stable — any state
    /// SwiftUI *can* preserve across layout flips (scroll position on
    /// the underlying NSTableView, sort order, selection highlight)
    /// lands on the same view slot in both trees.
    @ViewBuilder
    private func makeCenterTable(
        onOpen: ((DesignMockConversation.ID) -> Void)? = nil
    ) -> some View {
        DesignMockThreadTablePane(
            conversations: store.conversations,
            selection: $selectedConversationIDs,
            sortOrder: tableSortOrderBinding,
            isLoadingMore: store.isLoadingMore,
            onReachEnd: {
                store.loadMoreIfNeeded(services: services)
            },
            onOpen: onOpen,
            onMoveSelection: { delta in
                moveSelection(by: delta)
            },
            scrollPulse: $keyboardSelectionPulse
        )
        .id("center-table")
    }

    private var centerTable: some View {
        // `.table` layout: table fills the detail column, no reader.
        // Double-click / Return: promote into default mode so the
        // reader pane appears alongside the now-smaller table. The
        // selection is already set by the table's primaryAction
        // callback, so the reader has the right conversation queued
        // up when default mode mounts.
        makeCenterTable(onOpen: { _ in
            selectedLayoutMode = .default
        })
    }

    /// Two-way bridge between the toolbar search field and the `Table`'s
    /// native `sortOrder`. Reading the binding re-parses `searchText` to
    /// synthesize comparators; writing (i.e. the user clicked a column
    /// header) flips the direction through the DSL so the typed sentence
    /// reflects the tap in real time. This replaces the Table pane's
    /// private `@State sortOrder` so a single source of truth — the
    /// search field — drives both sides.
    private var tableSortOrderBinding: Binding<[KeyPathComparator<DesignMockConversation>]> {
        Binding(
            get: {
                let parsed = DesignMockQueryLanguage.parse(searchText)
                return DesignMockQueryLanguage.comparators(for: parsed.sortToken)
            },
            set: { newValue in
                let token = DesignMockQueryLanguage.sortToken(from: newValue)
                searchText = DesignMockQueryLanguage.applySortToken(token, to: searchText)
            }
        )
    }

    private var selectedConversation: DesignMockConversation? {
        // Reader + share button still want a single "currently displayed"
        // thread even though the middle pane is multi-selection. Pick
        // the first entry of the selection set that still exists in the
        // current list.
        //
        // Earlier revisions fell back to `store.conversations.first`
        // so the reader always had *something* to render, but that
        // silently opened the top thread every time the sidebar
        // filter changed — the user saw random threads slide into
        // the reader without their consent. Returning nil when no
        // selected id is visible lets the reader render its empty
        // state; the user explicitly picks a thread to open it.
        return store.conversations.first { selectedConversationIDs.contains($0.id) }
    }

    /// Query strings to surface in the search field's suggestion
    /// dropdown. The list swaps based on what the search field is
    /// currently acting on:
    ///
    /// - `.table` mode → library filter. Pull from
    ///   `libraryViewModel.unifiedFilters` keywords so recent archive
    ///   searches bubble back up.
    /// - `.default` / `.viewer` mode → in-thread find-in-page. Pull
    ///   from `recentInThreadQueriesStore.queries` so the user sees
    ///   "substrings I searched for while reading", not filters that
    ///   scoped the whole library.
    ///
    /// The two histories are disjoint because the activities are
    /// disjoint — a filter like `source:claude` is meaningless as an
    /// in-thread substring, and "error message" as a library filter
    /// would scope the card list (not what the user meant when they
    /// typed it into the reader finder). Keeping them separate avoids
    /// interleaving semantically different rows under one label.
    ///
    /// Both lists are deduped, trimmed, and capped at 12 so the
    /// dropdown doesn't become a scrollable wall on a heavy user (12
    /// is the same order of magnitude Safari / Spotlight show and
    /// fits on-screen without resizing).
    private var searchQuerySuggestions: [String] {
        if selectedLayoutMode == .table {
            return librarySearchQuerySuggestions
        } else {
            return inThreadSearchQuerySuggestions
        }
    }

    private var librarySearchQuerySuggestions: [String] {
        guard let libraryViewModel else { return [] }
        var seen = Set<String>()
        var ordered: [String] = []
        for entry in libraryViewModel.unifiedFilters {
            let keyword = entry.filters.keyword.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !keyword.isEmpty else { continue }
            if seen.insert(keyword).inserted {
                ordered.append(keyword)
            }
        }
        return Array(ordered.prefix(12))
    }

    private var inThreadSearchQuerySuggestions: [String] {
        // `recentInThreadQueriesStore` already enforces move-to-top
        // dedup and move-to-top ordering at record time, so the only
        // work here is bounding the list for the dropdown.
        Array(recentInThreadQueriesStore.queries.prefix(12))
    }

    private var composedQuery: DesignMockDataStore.FetchQuery {
        // Fold every user-driven input (sidebar selection, toolbar search,
        // sort picker) into a single value the store can diff against.
        //
        // The search field doubles as a tiny DSL: `sort:` directives and
        // the free-text keyword are pulled out separately so they drive
        // distinct parts of the fetch query. The layout-mode gate below
        // still applies to the keyword (viewer mode hands it off to the
        // in-thread finder instead), but the sort directive always
        // flows through so sorting stays consistent across mode
        // switches.
        var query = DesignMockDataStore.FetchQuery()
        let parsed = DesignMockQueryLanguage.parse(searchText)
        // Only `.table` mode (no reader pane) treats the free-text
        // keyword as a library filter. `.default` and `.viewer` both
        // ship it to the reader as an in-thread query instead — they
        // each have a thread open, and the user's mental model for the
        // search field in those modes is "find inside what I'm reading"
        // (request: "デフォルトビューのときはフォーカスビューと同様に
        // スレッド検索で統一して"). DSL directives like `sort:` and
        // sidebar-driven scoping still apply below so library navigation
        // remains possible without the keyword filter.
        if selectedLayoutMode == .table {
            query.keyword = parsed.keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        query.sortKey = DesignMockQueryLanguage.dbSortKey(from: parsed.sortToken)
        // Start from sidebar-derived filters so a plain sidebar pick
        // still scopes the library without any typing.
        let kind = DesignMockSidebarItem.kind(for: selectedSidebarItemID, sources: store.sources)
        switch kind {
        case .all, .archiveDB, .unknown:
            break
        case .source(let source):
            query.source = source
        case .model(let source, let model):
            query.source = source
            query.model = model
        case .bookmarks:
            query.bookmarksOnly = true
        case .tag(let name):
            query.tagName = name
        }
        // Explicit DSL tokens take precedence over the sidebar — the
        // reasoning is that typing is a deliberate act, sidebar picks
        // get "sticky" during long sessions, and the user would
        // reasonably expect `model:gpt-4o` to narrow the visible list
        // even when the sidebar still points at a different source.
        if let source = parsed.sourceFilter { query.source = source }
        if let model = parsed.modelFilter { query.model = model }
        if let tag = parsed.tagFilter { query.tagName = tag }
        if parsed.bookmarksOnly { query.bookmarksOnly = true }
        return query
    }

    /// Translate a DesignMock `FetchQuery` back into the canonical
    /// `ArchiveSearchFilter` the shared saved-filters store expects.
    /// Inverse (best-effort) of the `composedQuery` builder: keyword,
    /// single-source, single-model, bookmarksOnly are the only
    /// dimensions this shell can produce, so those are the only ones
    /// round-tripped.
    ///
    /// `query.tagName` is intentionally dropped. The tag-picker UI was
    /// removed in the "ditch tags" redesign, and although the `tag:`
    /// DSL token still filters live results, we do NOT want it seeding
    /// `bookmarkTags`-bearing rows in `saved_filters` — those are the
    /// rows `isUnproducibleByCurrentShell` treats as legacy and evicts
    /// from the recent-filter surfaces. Keeping them out at the write
    /// side means the eviction pass has nothing new to clean up.
    private func archiveFilter(from query: DesignMockDataStore.FetchQuery) -> ArchiveSearchFilter {
        var filter = ArchiveSearchFilter(keyword: query.keyword)
        if let source = query.source {
            filter.sources.insert(source)
        }
        if let model = query.model {
            filter.models.insert(model)
        }
        if query.bookmarksOnly {
            filter.bookmarkedOnly = true
        }
        return filter
    }

    /// Toolbar search field placeholder. Flips with the layout mode so the
    /// affordance tells the user what the field currently does — library
    /// filter vs. in-thread finder. `.default` joins `.viewer` on the
    /// in-thread side since both modes have a reader pane visible and
    /// share a single "find in the open thread" semantic; only `.table`
    /// (no reader) still uses the field for library-wide keyword
    /// filtering.
    private var searchPrompt: String {
        switch selectedLayoutMode {
        case .table:
            return "ライブラリを検索"
        case .default, .viewer:
            return "このスレッド内を検索"
        }
    }

    /// True when the sidebar points at archive.db. The consolidated
    /// surface (Drop-folder header + intake timeline + file list)
    /// takes over the whole split — we don't try to preserve the
    /// user's selected outer layout mode because the three pane roles
    /// are archive-specific and wouldn't map onto the `.table` /
    /// `.default` / `.viewer` trio's reader-centric structure.
    private var showingArchiveInspector: Bool {
        let kind = DesignMockSidebarItem.kind(for: selectedSidebarItemID, sources: store.sources)
        if case .archiveDB = kind { return true }
        return false
    }

    /// Three-pane archive.db split. Renders identically regardless of
    /// `selectedLayoutMode` — the outer layout picker stays on the
    /// toolbar so the user can switch back by picking a thread row
    /// elsewhere in the sidebar, but while archive.db is selected we
    /// show the consolidated panes rather than the reader-family ones.
    @ViewBuilder
    private func archiveInspectorSplit(vm: ArchiveInspectorViewModel) -> some View {
        NavigationSplitView {
            sidebar
        } content: {
            ArchiveInspectorPane(viewModel: vm)
                .navigationSplitViewColumnWidth(min: 280, ideal: 360, max: 620)
        } detail: {
            ArchiveInspectorFileListPane(viewModel: vm)
        }
    }

}

private struct DesignMockSidebar: View {
    @Binding var selection: DesignMockSidebarItem.ID?
    /// Live source list — supplied by `DesignMockDataStore` so switching
    /// between mock and real data refreshes the sidebar tree automatically.
    let sources: [DesignMockSource]
    /// Phase 4: per-user-prompt bookmarks. Rendered as children of the
    /// Bookmarks row when the list is non-empty — clicking a child opens
    /// the bookmark's owning thread and scrolls to the pinned prompt.
    let promptBookmarks: [DesignMockPromptBookmark]
    let databaseInfo: DesignMockDataStore.DatabaseInfo?
    let totalCount: Int
    /// Shared library VM. Kept optional because it's built lazily in
    /// the shell; Phase-4 prompt-bookmark surfaces and other sidebar-
    /// adjacent features read from it.
    let libraryViewModel: LibraryViewModel?
    /// Which sources are currently expanded. We seed from `sources` on
    /// first appear *and* whenever the source list changes shape (e.g. a
    /// real-data fetch finally lands), so newly-visible multi-model
    /// sources default to expanded without stomping on the user's manual
    /// collapses of the ones they've already interacted with.
    @State private var expandedSources: Set<String> = []
    @State private var haveSeededExpansion: Bool = false

    var body: some View {
        // "All" subtitle is driven by the live source totals so the sidebar
        // reads the real archive count, not a hardcoded mock one.
        let totalThreads = totalCount > 0
            ? totalCount
            : sources.reduce(0) { $0 + $1.count }
        let allItem = DesignMockSidebarItem(
            id: DesignMockSidebarItem.allThreads.id,
            title: DesignMockSidebarItem.allThreads.title,
            subtitle: totalThreads > 0 ? "\(totalThreads) threads" : nil,
            systemImage: DesignMockSidebarItem.allThreads.systemImage,
            kind: .all
        )
        let archiveRow = DesignMockSidebarItem(
            id: DesignMockSidebarItem.archiveDB.id,
            title: DesignMockSidebarItem.archiveDB.title,
            subtitle: databaseSubtitle,
            systemImage: DesignMockSidebarItem.archiveDB.systemImage,
            kind: .archiveDB
        )
        let bookmarksRow = DesignMockSidebarItem(
            id: DesignMockSidebarItem.bookmarks.id,
            title: DesignMockSidebarItem.bookmarks.title,
            subtitle: promptBookmarks.isEmpty ? nil : "\(promptBookmarks.count) pinned",
            systemImage: DesignMockSidebarItem.bookmarks.systemImage,
            kind: .bookmarks
        )
        // Hand-built ScrollView + VStack replaces the earlier
        // `List(selection:) + .listStyle(.sidebar)` structure. The native
        // sidebar list forced three things we couldn't override:
        //
        //   1. Section headers sit at a smaller leading inset than
        //      content rows, creating a visible step between the
        //      "Library" label and the first row's icon.
        //   2. `DisclosureGroup` reserves a chevron column for its
        //      siblings too, indenting every row in the section even
        //      when the chevron isn't rendered on them.
        //   3. Selection paints a saturated accent-blue pill over the
        //      full row, which washes out the coloured source dots
        //      (green = chatgpt, blue = gemini, orange = claude).
        //
        // With a manual layout we can line icons up with the section
        // header, put the disclosure chevron on the trailing edge
        // (clean alignment for all rows), and draw a low-chrome
        // selection pill that leaves source colours visible — the
        // pattern the user pointed to in their Finder reference shots.
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                sectionGroup("Library") {
                    customRow(allItem)
                    customRow(bookmarksRow)
                    customRow(archiveRow)
                }

                sectionGroup("Sources") {
                    if sources.isEmpty {
                        Text("No sources yet")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                    } else {
                        ForEach(sources, id: \.name) { source in
                            sourceBlock(source)
                        }
                    }
                }

                // Sidebar is strictly a library-scope narrower (Library
                // → Sources → Bookmarks). Thread-reopening and recent-
                // filter recall live elsewhere: toolbar search suggestions
                // for query recall, ⌘⇧↑/⌘⇧↓ for edge-jump navigation.
            }
            .padding(.horizontal, 6)
            .padding(.top, 10)
            .padding(.bottom, 14)
        }
        .scrollContentBackground(.hidden)
        .onChange(of: sources.map(\.name)) { _, _ in
            seedExpansionIfNeeded()
        }
        .onAppear {
            seedExpansionIfNeeded()
        }
    }

    /// Wraps a section under a single header, aligning the header text
    /// with the icons of the rows below. Header uses `.horizontal, 4`
    /// which matches the row's own `.horizontal, 4` so the "Library"
    /// text sits directly above the first row's leading icon column.
    @ViewBuilder
    private func sectionGroup<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .textCase(nil)
                .padding(.horizontal, 4)
                .padding(.bottom, 2)
            content()
        }
    }

    /// Finder-style selection fill. Low-opacity neutral tint instead of
    /// a saturated accent-blue pill so the coloured source dots stay
    /// readable when their row is selected. Falls back to clear for
    /// unselected rows (no resting state decoration).
    private func selectionFill(for id: DesignMockSidebarItem.ID, isHovering: Bool = false) -> Color {
        if selection == id { return Color.primary.opacity(0.10) }
        if isHovering { return Color.primary.opacity(0.05) }
        return .clear
    }

    private var databaseSubtitle: String? {
        guard let info = databaseInfo else { return nil }
        if let bytes = info.sizeBytes {
            return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        }
        return URL(fileURLWithPath: info.path).lastPathComponent
    }

    private func seedExpansionIfNeeded() {
        guard !haveSeededExpansion, !sources.isEmpty else { return }
        // Default every multi-model source to expanded so the user sees
        // the model breakdown without hunting for the disclosure chevron.
        expandedSources = Set(sources.filter { $0.models.count > 1 }.map(\.name))
        haveSeededExpansion = true
    }

    /// A single sidebar row. Leading edge is always the item icon —
    /// no reserved chevron column — so every row in every section
    /// aligns at the same x. Disclosure state is communicated by a
    /// trailing `chevron.right` that rotates when expanded, which
    /// keeps the leading alignment identical whether a row is a
    /// disclosure parent or a plain leaf.
    @ViewBuilder
    private func customRow(
        _ item: DesignMockSidebarItem,
        hasDisclosure: Bool = false,
        isExpanded: Bool = false,
        onToggleDisclosure: (() -> Void)? = nil
    ) -> some View {
        HoverableRow(isSelected: selection == item.id) { isHovering in
            let fill = selectionFill(for: item.id, isHovering: isHovering)
            Button {
                selection = item.id
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: item.systemImage)
                        .foregroundStyle(item.iconStyle)
                        .frame(width: 16, alignment: .center)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.title)
                            .lineLimit(1)
                            .foregroundStyle(.primary)
                        if let subtitle = item.subtitle {
                            Text(subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    if hasDisclosure {
                        // Dedicated tappable region so clicking the
                        // chevron only toggles expansion — the rest of
                        // the row still fires selection. Matches the
                        // macOS convention where the row label and the
                        // disclosure arrow are independent hit targets.
                        //
                        // Chevron hugs the title column instead of
                        // floating out at the row's trailing edge —
                        // with no natural end-of-row content next to
                        // it, a trailing-edge position read as
                        // "disconnected" (user flag: "矢印が離れすぎ
                        // ている"). The `Spacer` below fills the
                        // remainder of the row so the selection pill
                        // still spans full width.
                        Button {
                            onToggleDisclosure?()
                        } label: {
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                                .frame(width: 12, height: 12)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(fill)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
        }
    }

    /// Renders a source with optional model breakdown. Multi-model
    /// sources get a trailing disclosure chevron; the row itself still
    /// selects the source-level filter, while the chevron expands the
    /// per-model rows below. Model rows indent visually so they read
    /// as children of the parent source.
    @ViewBuilder
    private func sourceBlock(_ source: DesignMockSource) -> some View {
        let item = DesignMockSidebarItem(
            id: "source-\(source.name)",
            title: source.name,
            subtitle: "\(source.count) threads",
            systemImage: "circle.fill",
            kind: .source(source.name)
        )
        if source.models.count > 1 {
            let isExpanded = expandedSources.contains(source.name)
            customRow(
                item,
                hasDisclosure: true,
                isExpanded: isExpanded
            ) {
                if expandedSources.contains(source.name) {
                    expandedSources.remove(source.name)
                } else {
                    expandedSources.insert(source.name)
                }
            }
            if isExpanded {
                ForEach(source.models, id: \.name) { model in
                    customRow(
                        .init(
                            id: "model-\(source.name)-\(model.name)",
                            title: model.name,
                            subtitle: "\(model.count) threads",
                            systemImage: "cpu",
                            kind: .model(source: source.name, model: model.name)
                        )
                    )
                    .padding(.leading, 18)
                }
            }
        } else {
            customRow(item)
        }
    }

}

/// Per-row hover state. SwiftUI's `.onHover` on a Button label leaks
/// into the button's own press feedback and flickers during scroll —
/// hoisting the hover state into a dedicated container lets us apply
/// the hover tint to the background fill without fighting the button
/// style. Matches the transaction-based hover pattern used in
/// `SavedFilterRow` so scrolling through the sidebar doesn't cascade
/// animations across every visible row.
private struct HoverableRow<Content: View>: View {
    let isSelected: Bool
    @ViewBuilder let content: (Bool) -> Content
    @State private var isHovering: Bool = false

    var body: some View {
        content(isHovering)
            .animation(nil, value: isHovering)
            .onHover { hovering in
                var tx = Transaction()
                tx.disablesAnimations = true
                withTransaction(tx) {
                    isHovering = hovering
                }
            }
    }
}

private struct DesignMockThreadListPane: View {
    let conversations: [DesignMockConversation]
    /// Multi-selection binding. Was previously `ID?`, but the user
    /// asked for ⌘/⇧-click multi-select so DnD can attach a tag to a
    /// whole batch of cards at once. SwiftUI's `List(selection:)` with
    /// a `Set` binding handles the selection gestures natively and
    /// auto-batches multi-selected drags into a single drop delivery.
    @Binding var selection: Set<DesignMockConversation.ID>
    /// Outgoing one-shot: when the user taps a prompt inside the expanded
    /// card, we fire the prompt's canonical Message id into this binding so
    /// the reader scrolls to it. Rotating a fresh id each time keeps
    /// repeat-taps firing.
    @Binding var pendingPromptID: String?
    @Binding var expandedPromptConversationID: DesignMockConversation.ID?
    let isLoadingMore: Bool
    let onReachEnd: () -> Void
    /// Step the selection up (-1) or down (+1). Published by the shell
    /// because moving the selection also has to sync
    /// `expandedPromptConversationID` to preserve state 3's center-
    /// pane / reader-pane coherence, which the pane itself can't do
    /// without reaching back into shell-owned state.
    ///
    /// We wire this up as an `onKeyPress` handler on `.upArrow` /
    /// `.downArrow` because the pane renders as a `ScrollView` +
    /// `LazyVStack` rather than a `List(selection:)` — SwiftUI's
    /// built-in arrow-key navigation doesn't apply to the raw stack,
    /// so the pane is responsible for publishing its own focus and
    /// translating arrow presses into selection moves.
    let onMoveSelection: (Int) -> Void

    /// One-shot pulse the shell bumps on every keyboard-driven
    /// selection change (plain ↑/↓ and menu-bar ⌘↑/⌘↓). We observe
    /// via `.onChange` and scroll the current selection into view so
    /// arrow navigation never leaves the user stranded with the
    /// highlighted row offscreen. Keeping this as a separate signal
    /// (rather than `onChange(of: selection)`) preserves the
    /// user's "clicks don't auto-scroll" preference.
    @Binding var scrollPulse: UUID?

    /// Local focus flag for the `.focusable()` modifier on the card-
    /// list branch (state 2). The pinned-prompt branch (state 3)
    /// deliberately does NOT carry a focusable wrapper at this level
    /// — focus ownership is handed entirely to the inner
    /// `DesignMockExpandedPromptList` so there's only one focus
    /// target in the chain when a card is open. An earlier version
    /// kept a shared `.focusable()` on the outer Group; nesting it
    /// with the prompt list's own focusable created ambiguous
    /// routing where the outer sometimes retained focus even after
    /// the inner's `.onAppear` set its own FocusState, and ↑/↓
    /// silently switched threads instead of stepping prompts.
    @FocusState private var isFocused: Bool

    var body: some View {
        // Each branch owns its own focus wiring so there's never
        // more than one `.focusable()` view in the subtree at once
        // — avoids the nested-focus routing ambiguity that broke
        // state-3 prompt navigation.
        if let expandedConversation {
            pinnedPromptView(for: expandedConversation)
        } else {
            cardList
                .focusable()
                .focusEffectDisabled()
                .focused($isFocused)
                .onKeyPress(.upArrow) {
                    onMoveSelection(-1)
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    onMoveSelection(1)
                    return .handled
                }
                // Defer focus claim to the next runloop turn so
                // the pane has fully mounted before we request
                // key routing. Synchronous `.onAppear` assignment
                // raced the previous view's focus teardown during
                // drill transitions (⌘← from .default → .table,
                // card collapse from state 3 → state 2) and
                // silently lost the claim.
                .onAppear {
                    Task { @MainActor in
                        isFocused = true
                    }
                }
        }
    }

    private var cardList: some View {
        // `ScrollView` + `LazyVStack` instead of `List`. Rationale:
        //
        // 1. Hit area. SwiftUI's `List` adds non-zero horizontal and
        //    inter-row insets that `.contentShape(Rectangle())` can't
        //    reach — clicks landing in the inset strips were visibly
        //    dead. A `LazyVStack(spacing: 0)` row has zero gap above/
        //    below, so the whole card rectangle is clickable with no
        //    seams. User report: "当たり判定に隙間がある".
        //
        // 2. Scroll cost. `List` on macOS wraps NSTableView and layers
        //    on SwiftUI bridging, per-row `.listRowBackground` +
        //    `.listRowSeparator(.hidden)` + `.scrollContentBackground(
        //    .hidden)`. For plain custom rows (no system-standard cell
        //    chrome) the bridging cost outweighs the recycling win.
        //    LazyVStack renders rows directly, skips the NSTableView
        //    round-trip, and the result is noticeably smoother on
        //    200-row pages. User report: "スクロールがまだ重い".
        //
        // Interaction model is the pre-tag-era `selectOrToggle` pattern
        // (commit 315caf2): first tap selects, second tap on the same
        // card expands the prompt outline.
        //
        // Wrap in `ScrollViewReader` so the same selection-driven
        // scroll-to-top pattern used in the table pane also applies
        // here — opening a thread from ANY surface (bookmark click,
        // filter swap, keyboard jump, etc.) lands the row at the top
        // of the card list.
        ScrollViewReader { proxy in
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(conversations) { conversation in
                    DesignMockConversationListRow(conversation: conversation)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        // Selection highlight is applied INSIDE the
                        // horizontal padding (background layer before
                        // `.padding(.horizontal, 12)`) rather than
                        // around the whole row. Two reasons:
                        //
                        // 1. Bleed-through. The selection tint is
                        //    `Color.accentColor.opacity(0.14)` over
                        //    paper-white. If the highlight ran edge-
                        //    to-edge, the leftmost few points of the
                        //    middle pane would be faintly blue, and
                        //    `NavigationSplitView`'s sidebar — which
                        //    uses a `withinWindow`-blended
                        //    `NSVisualEffectView` — would blur those
                        //    blue pixels and the tint would show
                        //    through behind the sidebar (user report:
                        //    "水色ハイライトがサイドバーの裏側まで
                        //    貫通して透過してる"). Inset the tint by
                        //    the padding and the sidebar sees only
                        //    paper-white at the pane boundary, with
                        //    nothing to blur through.
                        //
                        // 2. Chrome consistency. Mail / Finder / Notes
                        //    all render list selection as an inset
                        //    rounded rectangle rather than a full-
                        //    width strip; the inset highlight reads
                        //    as "a pill around this row" instead of
                        //    "a colored band across the pane".
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(
                                    selection.contains(conversation.id)
                                        ? Color.accentColor.opacity(0.14)
                                        : Color.clear
                                )
                        )
                        .padding(.horizontal, 12)
                        // Padding is INSIDE the hit shape — tapping in
                        // the edge margin still registers as the row.
                        .contentShape(Rectangle())
                        // Subtle inter-card divider. Mail / Finder-style
                        // hairline at ~6% primary; 0.5pt on retina reads
                        // as a barely-there separator without competing
                        // with the selection pill or source color dots.
                        // Suppressed on the last row so the list doesn't
                        // end on a line. Inset by the same 12pt the card
                        // itself uses so the divider aligns with the pill
                        // edges rather than the pane edges.
                        .overlay(alignment: .bottom) {
                            if conversation.id != conversations.last?.id {
                                Rectangle()
                                    .fill(Color.primary.opacity(0.06))
                                    .frame(height: 0.5)
                                    .padding(.horizontal, 12)
                            }
                        }
                        // `.id(conversation.id)` attaches a
                        // `ScrollViewReader`-visible anchor to each row,
                        // so `proxy.scrollTo(id, anchor: .top)` lands
                        // exactly on the matching card.
                        .id(conversation.id)
                        .onTapGesture {
                            withAnimation(.easeOut(duration: 0.16)) {
                                selectOrToggle(conversation)
                            }
                        }
                        .onAppear {
                            // Trigger pagination when the last row scrolls into
                            // view. Guard on id-equality so mid-list appearances
                            // don't thrash the fetcher.
                            if conversation.id == conversations.last?.id {
                                onReachEnd()
                            }
                        }
                }
                if isLoadingMore {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
            }
        }
        // White tray (was gray `.regularMaterial` / `.windowBackgroundColor`).
        .background(Color(nsColor: .textBackgroundColor))
        // Fade the top edge so cards scrolling up dissolve into the
        // translucent toolbar instead of showing through it at full
        // opacity. Pairs with `titlebarAppearsTransparent = true` on
        // the host window — without this mask, text reads right
        // through the toolbar's vibrancy; with it, the top ~52pt
        // acts as a soft handoff from pane content to toolbar
        // material. User request: "スクロールで透過するのはいいけど、
        // ツールバーに差し掛かるとフェードアウトするようにできる？".
        .topFadeUnderToolbar()
        // First-mount scroll only. When the user was in `.table` mode
        // with a row selected and double-clicks it — or otherwise
        // flips the outer layout from `.table` to `.default` — the
        // NavigationSplitView's `.id("default")` tears down and
        // rebuilds the card pane from scratch, so this `.task` fires
        // on that transition and pulls the selected card into the top
        // of the viewport. That's the only case the user asked for:
        // "テーブルから開いてカードに切り替わった時だけ上に行く".
        //
        // Within the card pane itself (bookmark click, tapping a
        // different card, keyboard step) the selection
        // changes but the pane doesn't remount, so this `.task`
        // doesn't refire — and intentionally. A prior
        // `.onChange(of: selection)` handler used to scroll-to-top on
        // every selection transition; the user found the auto-scroll
        // jarring when reading down the list and tapping a card
        // partway through, so the onChange variant was dropped.
        //
        // Short poll lets the in-memory list populate from the DB
        // paged query before we try to scroll — the selection may
        // reference a conversation that isn't in `conversations` yet.
        .task {
            guard let id = selection.first else { return }
            for _ in 0..<20 {
                if conversations.contains(where: { $0.id == id }) { break }
                try? await Task.sleep(nanoseconds: 40_000_000)
            }
            try? await Task.sleep(nanoseconds: 80_000_000)
            proxy.scrollTo(id, anchor: .top)
        }
        // Scroll-follow for keyboard navigation. Each ⌘↑/⌘↓ / plain
        // ↑/↓ press bumps `scrollPulse`; we react by scrolling the
        // newly-selected row into view. `.center` keeps the row
        // vertically inside the visible band without snapping to an
        // edge — mimics how Mail scrolls the message list when you
        // arrow-navigate past the fold.
        .onChange(of: scrollPulse) { _, newValue in
            guard newValue != nil, let id = selection.first else { return }
            withAnimation(.easeOut(duration: 0.18)) {
                proxy.scrollTo(id, anchor: .center)
            }
        }
        } // ScrollViewReader
    }

    /// First tap on a card ⇒ select it (replacing any prior selection).
    /// Second tap on the same, already-selected card ⇒ expand/collapse
    /// the prompt outline. Mirrors the pre-tag `selectOrToggle` in
    /// commit 315caf2. The `Set<ID>` binding is treated as single-slot
    /// (`[id]` or `[]`) because the table view and selection-repair
    /// code still want a Set; card interactions never populate more
    /// than one id.
    private func selectOrToggle(_ conversation: DesignMockConversation) {
        if selection == [conversation.id] {
            expandedPromptConversationID =
                expandedPromptConversationID == conversation.id ? nil : conversation.id
        } else {
            selection = [conversation.id]
            expandedPromptConversationID = nil
        }
        // Clicking a card should leave keyboard focus on the pane
        // so the user can immediately reach for ↑/↓ to keep
        // navigating. Without this the user would have to
        // tab-cycle back into the pane every time they picked
        // something with the mouse.
        isFocused = true
    }

    private func pinnedPromptView(for conversation: DesignMockConversation) -> some View {
        // The expanded state is intentionally low-chrome: the card
        // keeps the same selection pill treatment it had in the
        // regular list (inset rounded rectangle at
        // `Color.accentColor.opacity(0.14)`), and the prompt list
        // just appears underneath it. An earlier draft wrapped the
        // whole assembly in a full-width accent tint plus a leading
        // rail to communicate "grouped unit", but that read as a
        // heavy "this whole region is now blue" moment instead of
        // the "card opened → prompts showed up below" affordance
        // the user actually wanted. The only indicator that
        // distinguishes expanded-and-selected from merely-selected
        // is now the `chevron.up` glyph on the trailing edge of the
        // card — same cue Finder / outline disclosures use.
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                DesignMockConversationListRow(conversation: conversation)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // Chevron sits in the trailing padding so it lines up
                // with the title row baseline. Secondary foreground
                // keeps it quiet — a colored accent here would drag
                // visual weight back toward the heavy treatment we
                // just removed.
                Image(systemName: "chevron.up")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 10)
            }
            .background(
                // Same inset pill the list's selected row renders —
                // `padding(.horizontal, 12)` below keeps the pill
                // clear of the pane's leading edge so it doesn't
                // bleed under the sidebar's vibrancy blur (same
                // rationale documented on the card-list background).
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.accentColor.opacity(0.14))
            )
            .padding(.horizontal, 12)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeOut(duration: 0.16)) {
                    expandedPromptConversationID = nil
                }
            }
            .help("Collapse prompt list")

            // `DesignMockExpandedPromptList` owns its own `ScrollView`
            // + `ScrollViewReader` internally so keyboard navigation
            // can call `proxy.scrollTo` on the newly-selected prompt.
            // Nesting a second ScrollView here would double-scroll
            // (inner scroll working correctly, outer eating the gesture
            // at the edge) and also hide the inner ScrollView's proxy
            // from the keyboard handler. Content padding migrates
            // inside the inner scroll so it still reads as inset from
            // the pane edge.
            DesignMockExpandedPromptList(
                conversation: conversation,
                pendingPromptID: $pendingPromptID
            )
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var expandedConversation: DesignMockConversation? {
        guard let expandedPromptConversationID else { return nil }
        return conversations.first { $0.id == expandedPromptConversationID }
    }
}

private struct DesignMockThreadTablePane: View {
    let conversations: [DesignMockConversation]
    /// Multi-selection binding (mirrors the card list). `Table` accepts
    /// a `Set` directly; column-header ⌘/⇧-click gestures and
    /// drag-select are handled natively once the type is a Set.
    @Binding var selection: Set<DesignMockConversation.ID>
    /// Sort state is owned by the shell (derived from the toolbar search
    /// field's `sort:` directive) rather than local `@State`, so a header
    /// click writes back into the search field and vice-versa — one
    /// canonical representation for the user to read and edit.
    @Binding var sortOrder: [KeyPathComparator<DesignMockConversation>]
    let isLoadingMore: Bool
    let onReachEnd: () -> Void
    /// Invoked when the user double-clicks a row or hits Return on a
    /// selection — the shell wires this to flip the layout mode so the
    /// reader pane opens the conversation. Only the `.table` outer
    /// layout uses this table now that the default mode has no in-
    /// pane Table option, so this is always wired up to "flip to
    /// `.default` so the reader appears."
    var onOpen: ((DesignMockConversation.ID) -> Void)? = nil
    /// Step-by-one selection callback, mirroring the one on the
    /// card-list pane. SwiftUI `Table` DOES support arrow-key
    /// navigation natively, but only once its underlying NSTableView
    /// is first responder — which doesn't happen automatically when
    /// the user drills back to `.table` via ⌘← (the NSTableView was
    /// never clicked, so AppKit never promoted it). We attach our own
    /// focus + onKeyPress handlers at the wrapper level so the
    /// shortcut works the moment the pane appears, without relying
    /// on the user clicking into the table first.
    let onMoveSelection: (Int) -> Void

    /// Shell-bumped pulse for keyboard-driven scroll-follow —
    /// identical semantics to the card-list pane. SwiftUI Table's
    /// own native arrow handling would scroll the selection into
    /// view for free, but that path only fires when the underlying
    /// NSTableView is first responder; keyboard nav via our wrapper
    /// handlers bypasses it, so we re-emit the scroll ourselves.
    @Binding var scrollPulse: UUID?

    @FocusState private var isFocused: Bool

    var body: some View {
        // Re-sort locally so header clicks reflect immediately on the page
        // already on screen. Global sort (which drives the DB query and
        // pagination order) is unaffected.
        let rows = conversations.sorted(using: sortOrder)
        // `ScrollViewReader` so selection changes driven from OUTSIDE the
        // table (bookmark click, filter swap that repairs the selection,
        // keyboard edge-jump) can scroll the target row to the top.
        // SwiftUI `Table` on macOS forwards `proxy.scrollTo(id)` through
        // its underlying `NSScrollView`, so the same row-id we bind the
        // selection on doubles as the scroll anchor.
        return ScrollViewReader { proxy in
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Title", value: \DesignMockConversation.title) { conversation in
                VStack(alignment: .leading, spacing: 2) {
                    Text(conversation.title)
                        .lineLimit(1)
                    if let snippet = conversation.snippet {
                        Text(snippet)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onAppear {
                    if conversation.id == rows.last?.id {
                        onReachEnd()
                    }
                }
            }
            // Title absorbs slack — no `ideal` / `max`, so when the other
            // columns hug their content the remainder lands here. Floor
            // at 160pt so narrow windows still show a usable prefix.
            .width(min: 160)

            TableColumn("Model", value: \DesignMockConversation.model) { conversation in
                Text(conversation.model)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    // Reserve enough horizontal space to render the
                    // full slug without truncating. Table columns don't
                    // intrinsically grow to fit their cells — they
                    // respect the declared `ideal`/`max` — so if the
                    // widest model string ("claude-3-5-sonnet-20241022",
                    // etc.) needs ~180pt and the column's max is 96pt,
                    // it clips. `fixedSize` forces the cell to claim
                    // its natural width so the column's auto-layout
                    // opens up for it instead.
                    .fixedSize(horizontal: true, vertical: false)
            }
            // No `max` — let the column expand to whatever the widest
            // visible model slug needs. `ideal: 120` is the opening
            // width on first paint; the user can drag narrower down to
            // the floor.
            .width(min: 56, ideal: 120)

            // Date column sorts by `sortRank` rather than the display
            // string — the latter is pre-formatted, so lexicographic
            // order wouldn't be chronological.
            TableColumn("Updated", value: \DesignMockConversation.sortRank) { conversation in
                Text(conversation.updated)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            // Date strings can vary in length depending on locale
            // ("Jan 1, 2026" vs "2026-01-01 12:34"). No `max` cap —
            // paired with `.fixedSize` on the cell, the column claims
            // the natural width of its widest visible row, and the
            // user can drag it narrower down to the `min` floor.
            .width(min: 56, ideal: 72)

            TableColumn("Prompts", value: \DesignMockConversation.prompts) { conversation in
                Text("\(conversation.prompts)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            // Header text "Prompts" itself is ~52pt at the default
            // font — we need the column at least that wide or the
            // header truncates to "Prom…". No `max` so the natural
            // width of the widest prompt count (5-digit archives
            // exist) lands without clipping; the `.fixedSize` on the
            // cell content pulls the column to exactly-fit width.
            .width(min: 56, ideal: 64)

            TableColumn("Source", value: \DesignMockConversation.source) { conversation in
                Text(conversation.source)
                    .foregroundStyle(conversation.sourceColor)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            // No `max` — "chatgpt"/"claude"/"gemini" all fit in ~52pt,
            // but imports can surface longer labels (filesystem-path
            // sources, custom importers). Dropping the 100pt cap lets
            // those render in full instead of truncating mid-word.
            .width(min: 56, ideal: 88)
        }
        // `primaryAction` fires on double-click or Return — the native
        // "open this row" affordance that Finder / Mail / every
        // tree-and-table Mac app uses. We don't supply an actual menu
        // (first closure returns EmptyView) because a blank context
        // menu on right-click would feel broken; the system falls back
        // to no menu when the builder is empty. Using the selection-
        // typed variant also fixes the data flow: the primary action
        // receives a Set of ids (exactly what was activated) rather
        // than whatever happened to be in `@Binding var selection`
        // at the time, which can lag behind a fresh double-click on
        // an unselected row.
        .contextMenu(forSelectionType: DesignMockConversation.ID.self) { _ in
            EmptyView()
        } primaryAction: { ids in
            guard let id = ids.first, let onOpen else { return }
            // Pre-seed the selection binding so the reader pane has the
            // right conversation queued up before the mode flip happens.
            // Collapse to the activated row so the reader shows exactly
            // what was double-clicked, even if the user had a wider
            // multi-select active before.
            selection = [id]
            onOpen(id)
        }
        .overlay(alignment: .bottom) {
            if isLoadingMore {
                ProgressView()
                    .controlSize(.small)
                    .padding(.bottom, 6)
            }
        }
        // (Horizontal-scroll reset used to live here. It was needed
        // only for `.default` mode's in-pane table, which ran too
        // narrow for the column declarations to fit — the Title
        // column ended up scrolled off-screen on every mode flip.
        // The in-pane table was removed from `.default` mode
        // entirely; the `.table` outer layout always gives the
        // table plenty of room, so horizontal overflow isn't a
        // problem here anymore.)
        //
        // NOTE: earlier revisions had an `.onChange(of: selection)`
        // handler here that re-ran `proxy.scrollTo(id, anchor: .top)`
        // on every selection transition. The user explicitly
        // rejected that behavior: "テーブルでも、選択するだけでは
        // 自動で上にスクロールせず" — clicking a row to preview it
        // should just highlight it in place, not yank the scroll
        // position. Auto-scroll now only fires via the `.task`
        // below, which runs once on fresh table mount (e.g. flipping
        // into `.table` mode with a pre-existing selection, or a
        // bookmark click that flips layout) so cross-surface
        // navigation still lands the target row at the top without
        // disturbing in-table clicks.
        //
        // On first mount, if the selection was already set by the
        // sidebar path (e.g. a bookmark click flips layout to `.default`
        // *and* writes the id into `selectedConversationIDs` in the
        // same tick), we need to scroll to it too — any on-transition
        // handler wouldn't fire for the initial value. A brief poll
        // waits for the target row to page into the in-memory list
        // before asking `proxy.scrollTo` to land it.
        .task {
            guard let id = selection.first else { return }
            for _ in 0..<20 {
                if conversations.contains(where: { $0.id == id }) { break }
                try? await Task.sleep(nanoseconds: 40_000_000)
            }
            try? await Task.sleep(nanoseconds: 80_000_000)
            proxy.scrollTo(id, anchor: .top)
        }
        // Wrap-level focus + arrow key handlers. `.focusEffectDisabled`
        // on the wrapper keeps the Table's native selection row
        // highlight as the sole focus indicator (otherwise the whole
        // pane would sprout an accent-blue ring). onAppear pulls
        // focus so ⌘← from `.default` lands the user somewhere that
        // can receive ↑/↓ immediately — the underlying NSTableView
        // needs a click to become first responder on its own, which
        // broke keyboard flow across layout drills (user report:
        // "デフォルトからcmd+←でテーブルに戻ると、上下移動が
        // 聞かなくなるね").
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onKeyPress(.upArrow) {
            onMoveSelection(-1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            onMoveSelection(1)
            return .handled
        }
        // Defer the focus claim to the next main-actor turn. A
        // synchronous `isFocused = true` inside `.onAppear` fires
        // while the outgoing view (the card list we drilled back
        // from) is still tearing down its own focus state; SwiftUI
        // was treating our claim as redundant and silently dropping
        // it, so the wrapper never became the key target and ↑/↓
        // bubbled to nothing. Hopping through `Task { @MainActor }`
        // lets the prior view's teardown settle first, then our
        // claim lands on a clean focus slot.
        .onAppear {
            Task { @MainActor in
                isFocused = true
            }
        }
        // Keyboard-driven scroll-follow, twin of the card-list
        // pane's handler. Click-driven selection stays silent
        // because the shell only pulses this token from the
        // arrow-key paths.
        .onChange(of: scrollPulse) { _, newValue in
            guard newValue != nil, let id = selection.first else { return }
            withAnimation(.easeOut(duration: 0.18)) {
                proxy.scrollTo(id, anchor: .center)
            }
        }
        } // ScrollViewReader
    }

}

/// Expanded card → inline prompt list. Each row is a user-authored message
/// from the selected conversation; tapping fires `pendingPromptID` so the
/// right-pane reader scrolls to that prompt's anchor in the transcript.
private struct DesignMockExpandedPromptList: View {
    let conversation: DesignMockConversation
    @Binding var pendingPromptID: String?
    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var store: DesignMockDataStore
    @State private var prompts: [DesignMockPrompt] = []
    @State private var isLoading: Bool = false
    /// Local highlight for the most recently tapped prompt. Kept in view
    /// state (not the data store) because this is pure UI feedback — the
    /// reader uses `pendingPromptID` to scroll, and that binding is cleared
    /// by `ConversationDetailView` once the scroll lands, so we'd lose the
    /// highlight immediately if we reused it.
    @State private var selectedPromptID: String?
    @State private var hoveredPromptID: String?
    /// Focus flag for the prompt list's keyboard handler. Set to true
    /// on appear so ⌘→ (drill-in from state 2 to state 3) lands the
    /// user directly in a prompt-navigable surface — they don't have
    /// to click anywhere to "enter" the list. Yielded to text fields
    /// etc. via the normal first-responder chain.
    @FocusState private var isPromptListFocused: Bool

    var body: some View {
        // ScrollViewReader so keyboard navigation (plain ↑/↓ and
        // menu ⌘↑/⌘↓) can pull the newly-selected prompt into view
        // even when it's offscreen. The parent `pinnedPromptView`
        // in `DesignMockThreadListPane` used to wrap this view in
        // its own `ScrollView`; we now own scroll here so the
        // proxy is reachable from `movePromptSelection` / the
        // jump-to-edge helpers. The parent drops its ScrollView to
        // avoid nested scrolling.
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                if isLoading && prompts.isEmpty {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.vertical, 8)
                } else if prompts.isEmpty {
                    Text("No user prompts in this conversation.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } else {
                    ForEach(prompts) { prompt in
                        promptRow(prompt)
                            // `.id(prompt.id)` wires each row into
                            // `ScrollViewReader` so `proxy.scrollTo`
                            // can land on the exact prompt when
                            // keyboard navigation walks past the
                            // viewport edge.
                            .id(prompt.id)
                    }
                }
            }
            .padding(.leading, 6)
            .padding(.trailing, 2)
        }
        // Focus + keyboard handling. The prompt list is the state-3
        // drill-in target, so plain ↑/↓ here walks the prompt list
        // (and auto-fires `pendingPromptID` so the reader scrolls to
        // each prompt in lockstep). The outer thread-list pane's
        // matching `.onKeyPress` also exists; SwiftUI routes key
        // events to the deepest focused view first, so the prompt
        // list's handler preempts the outer one whenever state 3 is
        // active.
        .focusable()
        .focusEffectDisabled()
        .focused($isPromptListFocused)
        .onKeyPress(.upArrow) {
            movePromptSelection(by: -1, proxy: proxy)
            return .handled
        }
        .onKeyPress(.downArrow) {
            movePromptSelection(by: 1, proxy: proxy)
            return .handled
        }
        // Defer the focus claim to the next main-actor turn. The
        // outer thread-list pane is tearing down its own focus
        // wrapper as this view mounts (the card-list branch is
        // leaving the tree); a synchronous claim here raced that
        // teardown and SwiftUI sometimes dropped our bid, leaving
        // no focused view at all (user report: ↑/↓ don't move
        // prompts even after clicking into the list). Bouncing
        // through `Task { @MainActor }` lets the tree settle on
        // the pinned-prompt branch first, then our claim lands
        // cleanly as the sole focusable in the subtree.
        .onAppear {
            Task { @MainActor in
                isPromptListFocused = true
            }
        }
        // Publish jump-to-edge closures so the main menu's
        // ⌘↑ / ⌘↓ items can retarget prompts when this list is
        // focused. `focusedValue` scopes the publication to
        // whichever view in the subtree currently owns focus, so
        // state 2 (card list focused, prompt list not in tree)
        // reads `nil` and falls back to the shell's thread-level
        // closures; state 3 sees these values and jumps prompts
        // instead. Rebuilt each pass so the closure captures the
        // current `prompts` snapshot rather than a stale one.
        .focusedValue(\.promptNavigation, promptNavigationActions(proxy: proxy))
        .task(id: conversation.id) {
            // Re-fetch whenever the expanded card changes identity. Store
            // caches the outline, so flipping back to a previously-expanded
            // card is instant.
            isLoading = true
            prompts = await store.promptOutline(for: conversation.id, services: services)
            isLoading = false
            // Clear the local highlight when the conversation changes —
            // otherwise a prompt from the previous card would stay tinted.
            selectedPromptID = nil
            hoveredPromptID = nil
        }
        } // ScrollViewReader
    }

    /// Build the `PromptNavigationActions` bundle for
    /// `focusedValue(\.promptNavigation, ...)`. Closures are nil
    /// when the outline is empty so the menu items disable
    /// themselves rather than fire a no-op. `proxy` is captured so
    /// the edge jump can scroll the target row into view — the
    /// shell-level jump-to-edge for threads uses the same pattern.
    private func promptNavigationActions(proxy: ScrollViewProxy) -> PromptNavigationActions {
        let promptsSnapshot = prompts
        let currentSelected = selectedPromptID
        let isEmpty = promptsSnapshot.isEmpty
        let firstClosure: (() -> Void)? = isEmpty ? nil : {
            jumpPromptToEdge(
                prompts: promptsSnapshot,
                currentSelected: currentSelected,
                toFirst: true,
                proxy: proxy
            )
        }
        let lastClosure: (() -> Void)? = isEmpty ? nil : {
            jumpPromptToEdge(
                prompts: promptsSnapshot,
                currentSelected: currentSelected,
                toFirst: false,
                proxy: proxy
            )
        }
        // State 3 maps ⌘⇧↑ / ⌘⇧↓ to "jump to first / last
        // prompt". Step semantics (⌘↑ / ⌘↓) are left nil on
        // purpose — the prompt list has focus in state 3, so
        // plain ↑ / ↓ already walks rows; a menu duplicate
        // would be dead weight. In `.viewer`, where plain ↑ /
        // ↓ scroll the reader instead of stepping prompts, the
        // shell publishes its own step closures.
        return PromptNavigationActions(
            stepPrev: nil,
            stepNext: nil,
            jumpFirst: firstClosure,
            jumpLast: lastClosure
        )
    }

    /// Shared implementation for ⌘↑ / ⌘↓ on the prompt list.
    /// Separated from `movePromptSelection` so the menu closures
    /// can carry a captured `prompts` snapshot instead of reaching
    /// back into the view (which is a value type and can be stale
    /// by the time a menu click fires).
    private func jumpPromptToEdge(
        prompts: [DesignMockPrompt],
        currentSelected: String?,
        toFirst: Bool,
        proxy: ScrollViewProxy
    ) {
        guard let target = toFirst ? prompts.first : prompts.last else {
            return
        }
        if currentSelected == target.id { return }
        selectedPromptID = target.id
        pendingPromptID = target.id
        withAnimation(.easeOut(duration: 0.18)) {
            proxy.scrollTo(target.id, anchor: .center)
        }
    }

    /// Move `selectedPromptID` one row up (-1) or down (+1). Fires
    /// `pendingPromptID` as a side effect so the reader scrolls to
    /// the newly-selected prompt — same behaviour as tapping a row.
    /// No-op when the outline is empty or we're already at the
    /// target edge. `proxy` lets the move scroll the new row into
    /// view when it's past the viewport edge.
    private func movePromptSelection(by delta: Int, proxy: ScrollViewProxy) {
        guard let nextID = steppedID(in: prompts, from: selectedPromptID, by: delta) else {
            return
        }
        selectedPromptID = nextID
        pendingPromptID = nextID
        // Keep the highlighted row visible as we walk off the
        // top/bottom edges of the viewport. `.center` matches the
        // card-list / table behaviour for consistency across
        // levels.
        withAnimation(.easeOut(duration: 0.18)) {
            proxy.scrollTo(nextID, anchor: .center)
        }
    }

    @ViewBuilder
    private func promptRow(_ prompt: DesignMockPrompt) -> some View {
        let isPinned = store.isPromptBookmarked(prompt.id)
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            // Sequence number sits on the LEADING edge instead of
            // the trailing edge, and the previous `text.bubble`
            // glyph is retired — the number alone already
            // identifies "which prompt", and the icon was just
            // decorative chrome that stole horizontal budget at
            // narrow widths. Right-aligned within a fixed-width
            // gutter so single-, double- and triple-digit rows
            // line up vertically (1 / 10 / 100).
            Text("\(prompt.index + 1)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 20, alignment: .trailing)

            // Main click target — scroll-to-prompt. Kept as an explicit
            // Button so the row responds to keyboard focus and taps,
            // while the pin toggle below stays independently hit-testable
            // (a .simultaneousGesture-style approach would swallow the
            // pin tap into the row scroll action).
            Button {
                // Fire the id — the reader observes this binding and scrolls to
                // the matching message. `ConversationDetailView` clears the
                // binding back to nil after applying, so reassigning the same
                // id later still triggers a fresh scroll.
                pendingPromptID = prompt.id
                selectedPromptID = prompt.id
                // Clicking a prompt row should leave keyboard
                // focus on the prompt list so the user can
                // immediately hit ↑/↓ to step through. Without
                // this explicit re-claim, the Button's tap would
                // transfer first-responder to the Button itself
                // and our `@FocusState` wrapper would lose its
                // key routing.
                isPromptListFocused = true
            } label: {
                // `lineLimit(2)` instead of 1: at narrow center-pane
                // widths (the user drags the pane down to ~180pt,
                // per the split-view min), a single-line snippet
                // truncates to one or two characters — effectively
                // hiding the prompt text. Two lines give enough
                // room for a Japanese title to survive truncation
                // while keeping the row compact enough that a long
                // outline still reads as a list.
                Text(prompt.snippet)
                    .font(.subheadline)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Pin toggle. Only visible on hover or when already pinned —
            // unpinned + unhovered rows stay visually quiet so the
            // prompt list doesn't turn into a wall of bookmark icons.
            pinButton(for: prompt, isPinned: isPinned)
                .opacity(isPinned || hoveredPromptID == prompt.id ? 1 : 0)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            rowBackground(for: prompt),
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            hoveredPromptID = hovering ? prompt.id : (hoveredPromptID == prompt.id ? nil : hoveredPromptID)
        }
    }

    @ViewBuilder
    private func pinButton(for prompt: DesignMockPrompt, isPinned: Bool) -> some View {
        Button {
            Task {
                await store.togglePromptBookmark(
                    promptID: prompt.id,
                    conversationID: conversation.id,
                    snippet: prompt.snippet,
                    threadTitle: conversation.title,
                    services: services
                )
            }
        } label: {
            Image(systemName: isPinned ? "bookmark.fill" : "bookmark")
                .font(.subheadline)
                .foregroundStyle(isPinned ? Color.yellow : Color.secondary)
                .frame(width: 14)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isPinned ? "Unpin prompt" : "Pin prompt")
    }

    private func rowBackground(for prompt: DesignMockPrompt) -> Color {
        if selectedPromptID == prompt.id {
            return Color.accentColor.opacity(0.22)
        }
        if hoveredPromptID == prompt.id {
            return Color.primary.opacity(0.06)
        }
        return Color.clear
    }
}

private struct DesignMockReaderPane: View {
    let conversation: DesignMockConversation?
    @Binding var pendingPromptID: String?
    /// Shared library VM — hoisted to `DesignMockRootView` so the
    /// reader and the (future) prompt-bookmark surface share the same
    /// state without re-fetching.
    let libraryViewModel: LibraryViewModel
    /// Two-way binding into the shell's search text — non-nil only in
    /// focus/viewer mode. When present, the reader renders a Safari-
    /// style find-in-page bar that writes back to the same text (so the
    /// user can also edit it directly) and drives scroll-to-match.
    var inThreadSearch: Binding<String>? = nil
    /// One-shot Enter-key signal from the toolbar search field. Muted
    /// (`nil`) in modes where Enter should drive a non-reader action.
    /// Reader observes this and advances to the next in-thread match
    /// when it fires.
    var findNextToken: Binding<UUID?>? = nil
    @EnvironmentObject private var services: AppServices

    var body: some View {
        // Route through `DesignMockReaderPaneContent` so the shared
        // `LibraryViewModel` can be forwarded via the environment to
        // downstream reader surfaces.
        DesignMockReaderPaneContent(
            conversation: conversation,
            services: services,
            libraryViewModel: libraryViewModel,
            pendingPromptID: $pendingPromptID,
            inThreadSearch: inThreadSearch,
            findNextToken: findNextToken
        )
    }
}

/// Concrete body for the reader pane. Consumes the shared
/// `LibraryViewModel` hoisted to `DesignMockRootView` so the
/// reader's downstream surfaces have the
/// `@Environment(LibraryViewModel.self)` they demand.
private struct DesignMockReaderPaneContent: View {
    let conversation: DesignMockConversation?
    let services: AppServices
    let libraryViewModel: LibraryViewModel
    /// Shared data store. Read here for two purposes: (1) the
    /// `PromptBookmarkBridge` the reader injects so user-message
    /// bubbles can toggle their pin, and (2) observing
    /// `pinnedPromptIDs` so the bubble re-renders the moment the pin
    /// flips (the bridge's `isPinned` closure captures the store, but
    /// SwiftUI only re-evaluates the environment-reading bubbles when
    /// the enclosing view re-evaluates — which happens because we
    /// listen via `@EnvironmentObject`).
    @EnvironmentObject private var store: DesignMockDataStore
    @Binding var pendingPromptID: String?
    /// Two-way binding into the shell's search text — non-nil only in
    /// focus mode. When present the reader renders a find-in-page bar
    /// that both reads and writes this binding (so clearing from either
    /// side stays in sync) and drives scroll-to-match on `pendingPromptID`.
    private let inThreadSearch: Binding<String>?
    /// One-shot Enter-key signal from the toolbar search field. When
    /// it rotates to a fresh UUID we step to the next match.
    private let findNextToken: Binding<UUID?>?

    /// Every individual keyword occurrence across the thread, in
    /// transcript order. Each entry is "message M, occurrence N" — so a
    /// message with the query appearing 3 times contributes 3 entries.
    /// This drives per-keyword Prev/Next: stepping cycles through
    /// individual hits rather than jumping whole messages at a time.
    @State private var matchLocations: [MatchLocation] = []
    /// Which match is currently centered in the reader. Clamped to
    /// `matchLocations.indices` — reset to 0 when the list changes.
    @State private var currentMatchIndex: Int = 0

    /// A single keyword hit. `anchorID` is the per-block scroll anchor
    /// (see `MessageBubbleView.searchBlockAnchorID`), used both as the
    /// scroll target and as the identity `applyingSearchHighlight`
    /// compares against to decide which block owns the active hit.
    /// `occurrenceInBlock` is the 0-indexed rank of this hit inside its
    /// own block under a case-insensitive left-to-right scan, matching
    /// the per-block indexing the bubble uses when picking which range
    /// to paint hot. `messageID` is kept so the stepper can detect
    /// cross-message jumps (which need a two-stage scroll to
    /// materialize the destination bubble before the precise block
    /// anchor resolves).
    fileprivate struct MatchLocation: Equatable {
        let messageID: String
        let anchorID: String
        let occurrenceInBlock: Int
    }
    /// Monotonic token used to cancel in-flight search recomputations
    /// when the user keeps typing.
    @State private var searchToken: UUID = UUID()

    init(
        conversation: DesignMockConversation?,
        services: AppServices,
        libraryViewModel: LibraryViewModel,
        pendingPromptID: Binding<String?>,
        inThreadSearch: Binding<String>? = nil,
        findNextToken: Binding<UUID?>? = nil
    ) {
        self.conversation = conversation
        self.services = services
        self.libraryViewModel = libraryViewModel
        _pendingPromptID = pendingPromptID
        self.inThreadSearch = inThreadSearch
        self.findNextToken = findNextToken
    }

    var body: some View {
        Group {
            if let conversation {
                // Defer to the canonical reader — it already handles async
                // loading, rendered vs. plain toggle, prompt outline, and
                // error states. Reusing it here means the DesignMock shell
                // stays a thin layout wrapper rather than re-implementing
                // message rendering.
                //
                // `.id(conversation.id)` is load-bearing: the detail view
                // stashes its view-model in `@State`, seeded from the
                // initializer's `conversationId`. Without rotating the
                // SwiftUI identity, selecting a different row would keep
                // rendering the first conversation we ever picked.
                ConversationDetailView(
                    conversationId: conversation.id,
                    repository: services.conversations,
                    requestedPromptID: $pendingPromptID,
                    showsSystemChrome: false,
                    // Keyword-level highlight: every case-insensitive
                    // substring match inside any bubble gets a yellow
                    // wash, and the single match currently centered by
                    // the Find bar's "N / M" slot gets a saturated
                    // orange wash. Bubbles read the spec off
                    // `EnvironmentValues.searchHighlight` and paint it
                    // onto their own `AttributedString` runs, so the
                    // highlight follows the exact keyword rather than
                    // washing the whole message.
                    searchHighlight: currentSearchHighlight
                )
                .id(conversation.id)
                .environment(libraryViewModel)
                .environment(\.promptBookmarkBridge, promptBookmarkBridge(for: conversation))
                .overlay(alignment: .top) {
                    // Only surface the nav strip when the user has
                    // actually typed something — otherwise it'd float at
                    // the top of the reader doing nothing. The text
                    // field itself lives in the toolbar regardless of
                    // mode, so the search-window position never shifts
                    // between library browsing and focus reading.
                    if let binding = inThreadSearch, !effectiveQuery.isEmpty {
                        FindInPageNavStrip(
                            text: binding,
                            matchCount: matchLocations.count,
                            currentIndex: currentMatchIndex,
                            onPrev: { stepMatch(by: -1) },
                            onNext: { stepMatch(by: 1) }
                        )
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                // Re-run the in-thread search whenever the typed query or
                // the selected conversation changes. Conversation change
                // resets both the match list and the position so we don't
                // carry an index from the previous thread.
                .task(id: searchTaskKey) {
                    await recomputeMatches()
                }
                // Keep the shared VM pointed at the currently-open
                // thread so downstream surfaces (saved filters,
                // upcoming prompt bookmarks) know which conversation
                // is active without threading an extra binding.
                .task(id: conversation.id) {
                    libraryViewModel.selectedConversationId = conversation.id
                }
                // Enter-in-toolbar-search → step to the next in-thread
                // match. `findNextToken` rotates a fresh UUID on every
                // Enter press, so even Enter-Enter-Enter repeats fire
                // a distinct `.onChange` — no dedup collision against
                // the previous press. A nil value means "cleared"
                // (never observed here, but guarded against).
                .onChange(of: findNextToken?.wrappedValue) { _, newToken in
                    guard newToken != nil else { return }
                    stepMatch(by: 1)
                }
            } else {
                emptyState
            }
        }
        // Paper-white backing (same `Color(nsColor: .textBackgroundColor)`
        // the center-pane thread table uses) so the pinned
        // `ConversationHeaderView`'s `NSVisualEffectView` material has
        // the same opaque white surface to blur against as the center
        // pane's picker strip does. The prior `.background(.background)`
        // resolved to `windowBackgroundColor`, which is both grayer AND
        // picks up the titlebar-transparency of the host window, so
        // the right-pane header read as noticeably more see-through
        // than the center-pane one despite both using the exact same
        // `VisualEffectBar` helper — user's "右ペインは透過しすぎてる"
        // report.
        .background(Color(nsColor: .textBackgroundColor))
        // Match the center pane: fade the top edge so message
        // content (and the pinned `ConversationHeaderView` that
        // sits between the scroll view and the window toolbar)
        // dissolve into the toolbar material on their way up. User
        // request after the center-pane fade landed: "右ペインも
        // 同様にして". The pinned header already has its own frosted
        // `VisualEffectBar`; stacking this top-edge mask on top of
        // that means the header's frosted surface itself gradients
        // into the toolbar instead of reading as a hard seam
        // between two separate frosted strips.
        .topFadeUnderToolbar()
    }

    /// Combined task key: any of these three shifting means we need to
    /// rebuild the match list. `searchToken` is here as a manual escape
    /// hatch for forcing a recompute even when the key otherwise matches.
    private var searchTaskKey: String {
        let qid = conversation?.id ?? ""
        let q = effectiveQuery
        return "\(qid)|\(q)|\(searchToken.uuidString)"
    }

    /// The free-text portion of the typed query — directive tokens like
    /// `sort:...` are stripped so they don't leak into the in-thread
    /// substring scan and generate bogus "no match" states.
    private var effectiveQuery: String {
        guard let raw = inThreadSearch?.wrappedValue else { return "" }
        return DesignMockQueryLanguage.parse(raw).keyword
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Construct a `PromptBookmarkBridge` bound to the currently-open
    /// conversation. The closures capture the store + services by
    /// reference; SwiftUI re-reads this every body pass when
    /// `pinnedPromptIDs` changes so `isPinned` reflects the freshest
    /// set, and `toggle` always sees the current services handle.
    private func promptBookmarkBridge(for conversation: DesignMockConversation) -> PromptBookmarkBridge {
        let store = self.store
        let services = self.services
        let convID = conversation.id
        let threadTitle = conversation.title
        return PromptBookmarkBridge(
            isPinned: { [weak store] promptID in
                store?.isPromptBookmarked(promptID) ?? false
            },
            toggle: { [weak store] promptID, snippet in
                guard let store else { return }
                Task {
                    await store.togglePromptBookmark(
                        promptID: promptID,
                        conversationID: convID,
                        snippet: snippet,
                        threadTitle: threadTitle,
                        services: services
                    )
                }
            }
        )
    }

    /// The spec handed to `ConversationDetailView` for keyword-level
    /// highlighting. `nil` when there's nothing to paint, so the reader
    /// stays in its no-op path. The active message id + occurrence
    /// index come from the find bar's "N / M" cursor so the single
    /// currently-centered keyword — not the whole message — is drawn
    /// in the hotter color.
    private var currentSearchHighlight: SearchHighlightSpec? {
        let q = effectiveQuery
        guard !q.isEmpty else { return nil }
        let location: MatchLocation? = matchLocations.indices.contains(currentMatchIndex)
            ? matchLocations[currentMatchIndex]
            : nil
        return SearchHighlightSpec(
            query: q,
            activeAnchorID: location?.anchorID,
            activeOccurrenceInBlock: location?.occurrenceInBlock
        )
    }

    /// Fetch the conversation detail, scan every message for a
    /// case-insensitive substring match on the query, and publish the
    /// resulting per-occurrence locations. Also fires the first jump so
    /// the reader snaps to match #1 without the user having to tap Next.
    private func recomputeMatches() async {
        let query = effectiveQuery
        guard !query.isEmpty, let convo = conversation else {
            await MainActor.run {
                matchLocations = []
                currentMatchIndex = 0
            }
            return
        }
        do {
            guard let detail = try await services.conversations.fetchDetail(id: convo.id) else {
                await MainActor.run {
                    matchLocations = []
                    currentMatchIndex = 0
                }
                return
            }
            // Case-insensitive substring scan. We intentionally don't
            // tokenize — the user's mental model for an in-thread
            // finder is "literal substring", matching ⌘F in every text
            // editor.
            //
            // The scan happens PER BLOCK rather than per message
            // because long assistant replies render as many separate
            // bubble sub-views (paragraph / heading / code / table /
            // …), and each carries its own scroll anchor. Stepping
            // through matches needs block-level granularity or the
            // scroll jump and the highlight cursor desync for long
            // replies — user report: "アシスタントの回答みたいに
            // テキストが長くなると、ハイライトが一つずつ追えなく
            // なり、スクロールのジャンプも機能しなくなる".
            //
            // The block enumeration MUST mirror what
            // `MessageBubbleView` does at render time — we delegate to
            // `MessageBubbleView.searchableBlocks(for:)` which returns
            // `(text, anchorID)` pairs in the exact order the bubble
            // attaches `.id(anchorID)`. That keeps per-block
            // occurrence indices aligned with
            // `applyingSearchHighlight`'s per-block scan.
            let needle = query
            // Resolve the bubble's rendering profile from the same
            // summary.source the view uses, so the per-block anchor
            // enumeration here matches what the renderer emits. If we
            // pass the default `.passthrough` for a Claude thread, the
            // renderer's grouped-foreign blocks get collapsed into
            // fewer anchor ids than this scan produces → find-bar
            // cursor lands on a block that doesn't exist.
            let profile = MessageRenderProfile.resolve(
                source: detail.summary.source,
                model: detail.summary.model
            )
            var locations: [MatchLocation] = []
            for message in detail.messages {
                let blocks = MessageBubbleView.searchableBlocks(for: message, profile: profile)
                for (text, anchorID) in blocks {
                    var searchFrom = text.startIndex
                    var occurrence = 0
                    while searchFrom < text.endIndex,
                          let range = text.range(
                            of: needle,
                            options: .caseInsensitive,
                            range: searchFrom..<text.endIndex
                          ) {
                        locations.append(MatchLocation(
                            messageID: message.id,
                            anchorID: anchorID,
                            occurrenceInBlock: occurrence
                        ))
                        occurrence += 1
                        // Advance past the match. Use `range.upperBound`
                        // directly — overlapping matches aren't meaningful
                        // for user-facing find, and this matches the
                        // non-overlapping scan in `applyingSearchHighlight`
                        // so per-occurrence indices line up exactly.
                        searchFrom = range.upperBound
                    }
                }
            }
            await MainActor.run {
                matchLocations = locations
                currentMatchIndex = 0
                // Auto-jump to the first match so the user sees
                // feedback immediately on typing. Fire the block
                // anchor directly — the reader's
                // `performProgrammaticScroll` handles the on-screen
                // case (skip the scroll), the "bubble not materialized
                // yet" case (first jump to the parent message id, then
                // converge to the block), and the in-between cases
                // uniformly. Previously this path used a two-stage
                // jump that unconditionally scrolled to the message id
                // first, which yanked the viewport even when the hit
                // was already visible.
                if let first = locations.first {
                    pendingPromptID = first.anchorID
                }
            }
        } catch {
            // Silent — this is a mock shell, and a failed fetch just
            // means "no navigator shown" rather than a hard error.
            await MainActor.run {
                matchLocations = []
                currentMatchIndex = 0
            }
        }
    }

    /// Move the active match index by `delta`, wrapping around the ends
    /// of the list.
    ///
    /// Two stepping regimes:
    /// 1. Same anchor (same block). The hit is inside the same rendered
    ///    sub-view we were just painting — no scroll even requested,
    ///    the updated `SearchHighlightSpec.activeOccurrenceInBlock`
    ///    re-paints which range gets the hot color.
    /// 2. Different anchor (different block, same or different
    ///    message). Fire `pendingPromptID = target.anchorID` and let
    ///    the reader's `performProgrammaticScroll` decide what to do:
    ///    - anchor already visible → no scroll, just the orange
    ///      cursor moves
    ///    - anchor off-screen but bubble materialized → single-shot
    ///      scrollTo + convergence
    ///    - anchor off-screen with bubble NOT materialized →
    ///      pre-scroll to the parent message id first so LazyVStack
    ///      builds the bubble, then converge onto the inner block
    ///
    /// Earlier iterations split cross-message stepping into a caller-
    /// side two-stage jump (messageID → 120ms → anchorID), but that
    /// unconditionally scrolled the next message's top to the viewport
    /// top — even when the adjacent message was already fully visible
    /// — which defeated the "画面外にハイライトがあったらジャンプする"
    /// refactor. The materialization check now lives inside the reader
    /// where it can be gated on "anchor not in offset cache yet"
    /// instead of "messages are different".
    private func stepMatch(by delta: Int) {
        guard !matchLocations.isEmpty else { return }
        let count = matchLocations.count
        let next = ((currentMatchIndex + delta) % count + count) % count
        let prev = matchLocations[currentMatchIndex]
        currentMatchIndex = next
        let target = matchLocations[next]

        // Regime 1: same block. Only the hot-color cursor moves.
        if target.anchorID == prev.anchorID && target.messageID == prev.messageID {
            return
        }

        // Regime 2: anywhere else. Let the reader decide whether to
        // scroll, pre-materialize, or skip entirely.
        pendingPromptID = target.anchorID
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "text.bubble")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text("Select a conversation")
                .font(.title3.weight(.medium))
            Text("Pick a thread on the left to load the full transcript here.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}

/// Compact navigation strip anchored at the top of the reader while
/// focus mode has an active in-thread query. Intentionally NOT a
/// full find-in-page bar — the text input lives in the toolbar
/// search field regardless of mode, because flipping that field's
/// position when entering focus was visually disorienting. This
/// strip only carries the auxiliary controls: match count, prev /
/// next chevrons, and a clear-query button. Shows up only while
/// there's something to navigate, so it doesn't hog reader real
/// estate when the user isn't searching.
private struct FindInPageNavStrip: View {
    @Binding var text: String
    let matchCount: Int
    let currentIndex: Int
    let onPrev: () -> Void
    let onNext: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if matchCount == 0 {
                    Text("一致なし")
                } else {
                    Text("\(currentIndex + 1) / \(matchCount)")
                        .monospacedDigit()
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            Button(action: onPrev) {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)
            .disabled(matchCount == 0)
            .keyboardShortcut("g", modifiers: [.command, .shift])
            .help("前の一致（⇧⌘G）")

            Button(action: onNext) {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)
            .disabled(matchCount == 0)
            .keyboardShortcut("g", modifiers: .command)
            .help("次の一致（⌘G）")

            Divider()
                .frame(height: 14)

            Button {
                text = ""
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("検索文字列をクリア")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.15), radius: 6, y: 3)
        .animation(.easeInOut(duration: 0.15), value: matchCount)
        .animation(.easeInOut(duration: 0.15), value: currentIndex)
    }
}

private struct DesignMockConversationListRow: View {
    let conversation: DesignMockConversation

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Title + date layout switches based on available width.
            // `ViewThatFits` picks the first candidate whose ideal
            // size fits; the wide one carries an explicit
            // `minWidth` so SwiftUI rejects it (and falls through to
            // the vertical stack) once the center pane is narrow
            // enough that the title would have to truncate
            // aggressively to share the line with the date.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(conversation.title)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    Text(conversation.updated)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                }
                .frame(minWidth: 260)

                // Narrow fallback: title on top, date wraps underneath.
                // Title gets a second line of headroom so the whole
                // card is readable even when the pane is squeezed.
                VStack(alignment: .leading, spacing: 2) {
                    Text(conversation.title)
                        .font(.callout.weight(.medium))
                        .lineLimit(2)
                    Text(conversation.updated)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            if let snippet = conversation.snippet {
                // FTS match snippet — shown only when the user has typed a
                // keyword, so cards in browse mode stay compact.
                Text(snippet)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            HStack(spacing: 10) {
                // Service chip: `cpu` glyph tinted by source color
                // (chatgpt → green, claude → orange, gemini → blue,
                // etc.) + the parsed model name when it exists.
                // Dropping the separate "chatgpt" / "claude" / …
                // text removes the redundancy — the glyph's color
                // already carries the service identity that the
                // text used to repeat, and the row gets a compact
                // 1-glyph-plus-optional-model chip instead of a
                // 3-item strip (icon + model + source). The model
                // text is skipped outright when the parsed value
                // is empty; no "unknown" placeholder.
                HStack(spacing: 4) {
                    Image(systemName: "cpu")
                        .foregroundStyle(conversation.sourceColor)
                    if !conversation.model.isEmpty {
                        Text(conversation.model)
                            .lineLimit(1)
                    }
                }

                // Prompt count: speech-bubble glyph + number. The
                // "prompts" suffix word was retired — the glyph
                // already communicates "messages from the user"
                // and the repeated word cost more horizontal
                // budget than it earned in clarity.
                HStack(spacing: 4) {
                    Image(systemName: "text.bubble")
                    Text("\(conversation.prompts)")
                        .monospacedDigit()
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }
}

private struct DesignMockSortPicker: View {
    @Binding var selection: ConversationSortKey

    var body: some View {
        Menu {
            Picker("Sort", selection: $selection) {
                Text("Newest first").tag(ConversationSortKey.dateDesc)
                Text("Oldest first").tag(ConversationSortKey.dateAsc)
                Text("Most prompts").tag(ConversationSortKey.promptCountDesc)
                Text("Fewest prompts").tag(ConversationSortKey.promptCountAsc)
            }
        } label: {
            Label(label, systemImage: "arrow.up.arrow.down")
                .labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton)
        .help("Sort order: \(label)")
    }

    private var label: String {
        switch selection {
        case .dateDesc: return "Newest first"
        case .dateAsc: return "Oldest first"
        case .promptCountDesc: return "Most prompts"
        case .promptCountAsc: return "Fewest prompts"
        }
    }
}

private struct DesignMockLayoutModePicker: View {
    @Binding var selection: DesignMockLayoutMode

    var body: some View {
        Picker("Layout", selection: $selection) {
            ForEach(DesignMockLayoutMode.allCases) { mode in
                Image(systemName: mode.symbol)
                    .accessibilityLabel(Text(mode.title))
                    .tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        // Previously scaled down to `.small` while the search field was
        // active (`isSearching || !searchText.isEmpty`) to reclaim toolbar
        // width, but the shrink-on-focus felt jittery — icons visibly
        // resized mid-typing. Lock to `.regular`; if the toolbar ever
        // actually overflows we'll solve it with `.toolbar(.automatic)`
        // priority hints rather than a manual size swap.
        .controlSize(.regular)
        .help("Layout mode")
    }
}

private struct DesignMockToolbarIconButton: View {
    let systemImage: String
    let help: String
    var action: () -> Void = {}

    init(systemImage: String, help: String, action: @escaping () -> Void = {}) {
        self.systemImage = systemImage
        self.help = help
        self.action = action
    }

    var body: some View {
        Button {
            action()
        } label: {
            Image(systemName: systemImage)
                .font(DesignMockToolbarMetrics.iconFont)
                .foregroundStyle(.primary)
        }
        .help(help)
    }
}

private enum DesignMockToolbarMetrics {
    static let iconFont: Font = .system(size: 14, weight: .semibold)
}

/// Toolbar share button. Fetches the selected conversation's full
/// `ConversationDetail` and materializes it as a temp Markdown file,
/// then hands the file URL to `ShareLink` so the native macOS share
/// menu (AirDrop / Mail / Messages / Notes / Save to Files / installed
/// extensions) can present it. Mirrors the reader pane's
/// `ConversationShareButton` behavior — both paths end up routing
/// through `MarkdownExporter.writeTempShareFile(for:)` so the file
/// format is identical regardless of where the share was initiated.
private struct DesignMockShareButton: View {
    let conversation: DesignMockConversation?
    let services: AppServices
    /// Fetched `ConversationDetail` for the current selection. Drives
    /// the share menu — the two temp-file URLs below and the
    /// "Copy as LLM Prompt" item all need the full detail, so we
    /// fetch it once and retain it until the selection changes.
    @State private var detail: ConversationDetail?
    /// Rendered export URLs. Nil while the files are being written,
    /// or when no conversation is selected. Each `ShareLink` inside
    /// the menu gates itself on its own URL being non-nil, so the
    /// menu stays open and partially populated during the gap.
    @State private var markdownURL: URL?
    @State private var plainTextURL: URL?
    /// Guard against stale fetches overwriting the state when the user
    /// switches conversations mid-export. Compared at write time — if
    /// the id changed while the async chain was in flight, the result
    /// is discarded.
    @State private var pendingExportID: String?

    var body: some View {
        Menu {
            conversationShareMenuItems(
                detail: detail,
                markdownURL: markdownURL,
                plainTextURL: plainTextURL
            )
        } label: {
            Image(systemName: "square.and.arrow.up")
                .font(DesignMockToolbarMetrics.iconFont)
                .foregroundStyle(.primary)
        }
        .menuIndicator(.hidden)
        .disabled(conversation == nil)
        .help(conversation == nil ? "No conversation selected" : "Share selected conversation")
        // Re-export whenever the selected thread changes. Keying on
        // the conversation id (or nil) means switching between
        // conversations triggers a fresh export; switching layout
        // modes without changing the selection reuses the current
        // files. `nil` identity cleanly resets all state so the
        // disabled menu returns when the user deselects everything.
        .task(id: conversation?.id) {
            await refreshShareState(for: conversation)
        }
    }

    private func refreshShareState(for conversation: DesignMockConversation?) async {
        guard let conversation else {
            detail = nil
            markdownURL = nil
            plainTextURL = nil
            pendingExportID = nil
            return
        }
        pendingExportID = conversation.id
        detail = nil
        markdownURL = nil
        plainTextURL = nil
        do {
            guard let fetched = try await services.conversations
                .fetchDetail(id: conversation.id) else {
                return
            }
            // Bail if the user has since moved on to another thread.
            // Writing the files would be wasted work, and surfacing
            // them in the menu would briefly show a stale export.
            guard pendingExportID == conversation.id else { return }
            detail = fetched
            let urls = await prepareConversationShareURLs(for: fetched)
            guard pendingExportID == conversation.id else { return }
            markdownURL = urls.markdown
            plainTextURL = urls.plainText
        } catch {
            // Silent — the disabled placeholder is an acceptable
            // fallback, and a real failure is rare enough (temp dir
            // write failure) that a modal alert feels disproportionate.
        }
    }
}

private struct DesignMockSidebarItem: Identifiable {
    enum Kind: Equatable {
        case all
        case archiveDB
        case bookmarks
        case source(String)
        case model(source: String, model: String)
        case tag(String)
        case unknown
    }

    let id: String
    let title: String
    let subtitle: String?
    let systemImage: String
    let kind: Kind

    static let allThreads = DesignMockSidebarItem(
        id: "all",
        title: "All Threads",
        subtitle: nil,
        systemImage: "rectangle.stack",
        kind: .all
    )

    static let bookmarks = DesignMockSidebarItem(
        id: "bookmarks",
        title: "Bookmarks",
        subtitle: nil,
        systemImage: "bookmark.fill",
        kind: .bookmarks
    )

    /// Consolidated archive entry point. Clicking it surfaces the
    /// Drop-folder configuration, the vault snapshot + intake timeline,
    /// and the per-snapshot file list in a single three-pane layout.
    /// The title stays at "archive.db" (not "Archive") because the
    /// user's mental model is still "the database file on disk" — the
    /// consolidation merges surfaces without renaming the concept.
    static let archiveDB = DesignMockSidebarItem(
        id: "archive-db",
        title: "archive.db",
        subtitle: "Vault + auto intake",
        systemImage: "externaldrive",
        kind: .archiveDB
    )

    /// Reverse a sidebar-row id into the logical `Kind`. Takes `sources`
    /// from the caller (rather than pulling from a global) so the lookup
    /// works whether the sidebar is showing the built-in sample or the
    /// live archive database.
    static func kind(for id: String?, sources: [DesignMockSource]) -> Kind {
        guard let id else { return .unknown }
        if id == allThreads.id { return .all }
        if id == bookmarks.id { return .bookmarks }
        if id == archiveDB.id { return .archiveDB }
        if id.hasPrefix("tag-") {
            return .tag(String(id.dropFirst("tag-".count)))
        }
        // Model rows encode both source + model in their id to avoid collision
        // across providers that happen to share a model slug.
        if id.hasPrefix("model-") {
            let remainder = String(id.dropFirst("model-".count))
            for source in sources {
                let prefix = "\(source.name)-"
                if remainder.hasPrefix(prefix) {
                    let model = String(remainder.dropFirst(prefix.count))
                    return .model(source: source.name, model: model)
                }
            }
        }
        if let source = sources.first(where: { "source-\($0.name)" == id }) {
            return .source(source.name)
        }
        return .unknown
    }

    var iconStyle: AnyShapeStyle {
        switch kind {
        case .source(let source):
            AnyShapeStyle(DesignMockSource.color(for: source))
        case .model(let source, _):
            AnyShapeStyle(DesignMockSource.color(for: source))
        case .tag:
            AnyShapeStyle(.purple)
        default:
            // Bookmarks used to render in yellow to match the bookmark
            // pill color the reader uses on individual prompts, but it
            // stuck out as the only bright icon in the Library section
            // (All / Archive DB / Auto-intake all use the default
            // secondary style). Folded into the default branch so the
            // whole Library section reads as one neutral column.
            AnyShapeStyle(.secondary)
        }
    }
}

/// Outer layout mode toggled from the toolbar (Table / Default / Viewer).
/// Promoted from `private` to module-internal so `AppCommands` can reference
/// it when wiring up ⌘1 / ⌘2 / ⌘3 — the menu actions flip this via a
/// shared `ShellCommandActions` bundle published as a `FocusedValue`.
enum DesignMockLayoutMode: String, CaseIterable, Identifiable {
    case table
    case `default`
    case viewer

    var id: String { rawValue }

    var title: String {
        switch self {
        case .table: return "Table"
        case .default: return "Default"
        case .viewer: return "Viewer"
        }
    }

    var symbol: String {
        switch self {
        case .table: return "tablecells"
        case .default: return "rectangle.split.3x1"
        case .viewer: return "doc.plaintext"
        }
    }
}

private struct DesignMockSource {
    let name: String
    let count: Int
    /// Model breakdown inside this source. Empty ⇒ render as a flat row; one
    /// ⇒ still flat (a singleton list adds chevron noise without payoff);
    /// two or more ⇒ the sidebar expands it into a DisclosureGroup.
    let models: [DesignMockSourceModel]

    var color: Color {
        Self.color(for: name)
    }

    static func color(for name: String) -> Color {
        switch name.lowercased() {
        case "chatgpt": return .green
        case "claude": return .orange
        case "gemini": return .blue
        default: return .secondary
        }
    }
}

private struct DesignMockSourceModel {
    let name: String
    let count: Int
}

private struct DesignMockConversation: Identifiable, Hashable {
    let id: String
    let title: String
    let updated: String
    let sortRank: Int
    let prompts: Int
    let source: String
    let model: String
    /// BM25 snippet returned by FTS. `nil` for rows loaded via the plain
    /// index; populated when the user types a keyword so the card row can
    /// show why the result matched.
    let snippet: String?

    init(
        id: String,
        title: String,
        updated: String,
        sortRank: Int,
        prompts: Int,
        source: String,
        model: String,
        snippet: String? = nil
    ) {
        self.id = id
        self.title = title
        self.updated = updated
        self.sortRank = sortRank
        self.prompts = prompts
        self.source = source
        self.model = model
        self.snippet = snippet
    }

    var sourceColor: Color {
        DesignMockSource.color(for: source)
    }
}

/// Tiny DSL the toolbar search field speaks in the mock shell. The field
/// doubles as a FTS entry point AND a surface for operation tokens
/// (currently just `sort:`), so that tapping a column header in the table
/// pane writes a human-readable sentence the user can also type/edit by
/// hand. This is the spiritual cousin of GitHub's search syntax
/// (`is:open sort:updated-desc`) scaled down to what Madini actually needs.
///
/// Two rules keep the parser honest:
///   1. Tokens of the form `key:value` are reserved directives; only the
///      first match per key wins.
///   2. Everything else joins back into the free-text keyword verbatim,
///      preserving the user's spacing so an accidentally-typed directive
///      doesn't erase neighbouring search terms.
private enum DesignMockQueryLanguage {
    struct Parsed: Equatable {
        /// Free-text portion, with directive tokens stripped out.
        var keyword: String
        /// Canonical value of the matched `sort:` token (e.g.
        /// `"updated-desc"`). Nil when no sort directive was typed.
        var sortToken: String?
        /// Value of the matched `source:` token (e.g. `"chatgpt"`) —
        /// case is preserved from the typed value because downstream
        /// `FetchQuery.source` comparisons are case-sensitive against
        /// the stored source name.
        var sourceFilter: String?
        /// Value of the matched `model:` token. Same case-preservation
        /// rationale as `sourceFilter`.
        var modelFilter: String?
        /// Value of the matched `tag:` token.
        var tagFilter: String?
        /// True when `bookmark:true` / `is:bookmarked` was typed.
        var bookmarksOnly: Bool = false
    }

    static func parse(_ text: String) -> Parsed {
        var parsed = Parsed(keyword: "")
        var freeWords: [String] = []

        for raw in text.split(separator: " ", omittingEmptySubsequences: true) {
            let token = String(raw)
            // Split on the first colon only — values like
            // `model:gpt-5-4-thinking` carry their own hyphens but no
            // further colons, and if they ever did we'd want the value
            // kept intact.
            guard let colonIx = token.firstIndex(of: ":") else {
                freeWords.append(token)
                continue
            }

            let key = token[..<colonIx].lowercased()
            let rawValue = String(token[token.index(after: colonIx)...])
            guard !rawValue.isEmpty else {
                // `sort:` with no value is ambiguous — treat as garbage
                // and pass through as free text so the user's typing
                // isn't silently dropped mid-keystroke.
                freeWords.append(token)
                continue
            }

            // First directive of each key wins. Subsequent duplicates
            // become no-ops so stale trailing tokens can't clobber the
            // one the user just typed in front.
            switch key {
            case "sort":
                if parsed.sortToken == nil {
                    parsed.sortToken = rawValue.lowercased()
                }
            case "source":
                if parsed.sourceFilter == nil {
                    parsed.sourceFilter = rawValue
                }
            case "model":
                if parsed.modelFilter == nil {
                    parsed.modelFilter = rawValue
                }
            case "tag":
                if parsed.tagFilter == nil {
                    parsed.tagFilter = rawValue
                }
            case "bookmark", "is":
                // `bookmark:true` / `bookmark:false` and the GitHub-ish
                // shorthand `is:bookmarked`. Anything else under these
                // keys falls through to free text so the user's typing
                // stays visible rather than vanishing.
                let low = rawValue.lowercased()
                if key == "bookmark" && (low == "true" || low == "false") {
                    parsed.bookmarksOnly = (low == "true")
                } else if key == "is" && low == "bookmarked" {
                    parsed.bookmarksOnly = true
                } else {
                    freeWords.append(token)
                }
            default:
                // Unknown directive → preserve as free text. Future-
                // proofs against typos and keeps the user's typing
                // visible in the search field.
                freeWords.append(token)
            }
        }

        parsed.keyword = freeWords.joined(separator: " ")
        return parsed
    }

    /// Strip the DSL directives that the sidebar is about to override —
    /// `source:`, `model:`, `tag:`, `bookmark:`, `is:`. Free text,
    /// FTS field-scoped tokens (`title:`, `content:`), and `sort:`
    /// survive untouched so a query like `content:編集 source:claude`
    /// becomes just `content:編集` after the user clicks "Sources →
    /// chatgpt" — the keyword they typed stays visible, only the
    /// conflicting source filter goes away. Returns the trimmed
    /// string with single-space separators rebuilt.
    static func stripSidebarConflictingDirectives(from text: String) -> String {
        let pieces = text.split(separator: " ", omittingEmptySubsequences: true)
            .map(String.init)
        let out = pieces.filter { piece in
            guard let colonIx = piece.firstIndex(of: ":") else { return true }
            let key = piece[..<colonIx].lowercased()
            switch key {
            case "source", "model", "tag", "bookmark", "is":
                return false
            default:
                return true
            }
        }
        return out.joined(separator: " ")
    }

    /// Rewrite `text` so its sort directive becomes `sort:\(token)`, or
    /// strip it entirely when `token` is nil. Replaces in-place at the
    /// first existing `sort:...` occurrence so the caret position stays
    /// stable; appends to the end only when no directive exists yet.
    static func applySortToken(_ token: String?, to text: String) -> String {
        let pieces = text.split(separator: " ", omittingEmptySubsequences: false)
            .map { String($0) }
        var out: [String] = []
        var replaced = false

        for piece in pieces {
            if piece.lowercased().hasPrefix("sort:") {
                if let token, !replaced {
                    out.append("sort:\(token)")
                    replaced = true
                }
                // else: drop the directive (nil-out path, or we've
                // already done the replacement earlier in the string
                // and any further matches are redundant).
                continue
            }
            out.append(piece)
        }

        if let token, !replaced {
            // No existing directive to overwrite — append one. Trim a
            // dangling trailing space so we don't leave "foo  sort:x".
            if let last = out.last, last.isEmpty {
                out[out.count - 1] = "sort:\(token)"
            } else {
                out.append("sort:\(token)")
            }
        }

        return out.joined(separator: " ")
    }

    /// Comparator stack the `Table` should use for a given token. An
    /// unknown / nil token falls back to "Updated ascending" so the
    /// header indicator has a predictable default — the alternative
    /// (nil comparators) drops the chevron entirely and the user can't
    /// tell the table is sorted at all.
    static func comparators(for token: String?) -> [KeyPathComparator<DesignMockConversation>] {
        switch token {
        case "title-asc":    return [KeyPathComparator(\DesignMockConversation.title,    order: .forward)]
        case "title-desc":   return [KeyPathComparator(\DesignMockConversation.title,    order: .reverse)]
        case "model-asc":    return [KeyPathComparator(\DesignMockConversation.model,    order: .forward)]
        case "model-desc":   return [KeyPathComparator(\DesignMockConversation.model,    order: .reverse)]
        case "updated-asc":  return [KeyPathComparator(\DesignMockConversation.sortRank, order: .forward)]
        case "updated-desc": return [KeyPathComparator(\DesignMockConversation.sortRank, order: .reverse)]
        case "prompts-asc":  return [KeyPathComparator(\DesignMockConversation.prompts,  order: .forward)]
        case "prompts-desc": return [KeyPathComparator(\DesignMockConversation.prompts,  order: .reverse)]
        case "source-asc":   return [KeyPathComparator(\DesignMockConversation.source,   order: .forward)]
        case "source-desc":  return [KeyPathComparator(\DesignMockConversation.source,   order: .reverse)]
        default:
            return [KeyPathComparator(\DesignMockConversation.sortRank, order: .forward)]
        }
    }

    /// Inverse of `comparators(for:)`. Returns the token that represents
    /// the first comparator in the stack; nil when none match (e.g. a
    /// future column we haven't taught the DSL about). Secondary sort
    /// keys are discarded because the token language has no multi-key
    /// syntax.
    static func sortToken(from comparators: [KeyPathComparator<DesignMockConversation>]) -> String? {
        guard let first = comparators.first else { return nil }
        let suffix = first.order == .forward ? "asc" : "desc"
        switch first.keyPath {
        case \DesignMockConversation.title:    return "title-\(suffix)"
        case \DesignMockConversation.model:    return "model-\(suffix)"
        case \DesignMockConversation.sortRank: return "updated-\(suffix)"
        case \DesignMockConversation.prompts:  return "prompts-\(suffix)"
        case \DesignMockConversation.source:   return "source-\(suffix)"
        default:                               return nil
        }
    }

    /// DB-level sort key that should drive the store fetch for a given
    /// DSL token. Columns the DB doesn't know how to sort on (title,
    /// model, source) fall through to the default so pagination stays
    /// well-ordered server-side; the Table still re-sorts in-memory so
    /// the visible page matches what the user asked for.
    static func dbSortKey(from token: String?) -> ConversationSortKey {
        switch token {
        case "updated-asc":  return .dateAsc
        case "prompts-desc": return .promptCountDesc
        case "prompts-asc":  return .promptCountAsc
        default:             return .dateDesc
        }
    }

}

private enum DesignMockData {
    /// Tiny hardcoded fallback — shown only when `AppServices` is backed by
    /// the in-memory mock data source (no archive.db on disk). Real runs
    /// overwrite this via `DesignMockDataStore.load(services:)` immediately
    /// after first paint, so in normal use this list is never visible.
    ///
    /// Kept intentionally short: one row per supported provider so the
    /// sidebar still renders a non-empty Sources section in dev, without
    /// misleading the eye into thinking it's looking at real data.
    static let sampleConversations: [DesignMockConversation] = [
        .init(id: "mock-1", title: "ChatGPT sample thread", updated: "—", sortRank: 0, prompts: 0, source: "chatgpt", model: "gpt-4o"),
        .init(id: "mock-2", title: "Claude sample thread",  updated: "—", sortRank: 1, prompts: 0, source: "claude",  model: "claude-3-5-sonnet"),
        .init(id: "mock-3", title: "Gemini sample thread",  updated: "—", sortRank: 2, prompts: 0, source: "gemini",  model: "gemini-1.5-pro")
    ]
}
#endif
