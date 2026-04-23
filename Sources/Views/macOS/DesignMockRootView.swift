#if os(macOS)
import AppKit
import SwiftUI

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
            let prompts = detail.messages
                .enumerated()
                .filter { $0.element.isUser }
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
            let searchQuery = SearchQuery(filter: filter, offset: offset, limit: pageSize)
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
    @State private var selectedCenterDisplayMode: DesignMockCenterDisplayMode = .cards
    @State private var searchText = ""
    @State private var expandedPromptConversationID: DesignMockConversation.ID?
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
    /// Rolling list of recently-opened thread ids. Paired with the
    /// filter history in the sidebar HISTORY section so "what did I
    /// look at" is one surface, not two. Persisted to UserDefaults —
    /// see `RecentThreadsStore` for cap / eviction rules.
    @StateObject private var recentThreadsStore = RecentThreadsStore()
    /// Pending debounced `recordRecentSearch` call. Cancel-and-reschedule
    /// on every `composedQuery` change so typing "swift" doesn't write +
    /// re-read the saved-filters table five times in a row — the final
    /// settled query is the only one that gets recorded. Pairs with the
    /// store's own "last write wins" fetch: whatever the user actually
    /// landed on is what enters History.
    @State private var recordRecentSearchTask: Task<Void, Never>?
    /// Persisted center-pane width for the `.default` layout, one slot
    /// per center display mode. The user's desired trade-off differs by
    /// mode: table view wants the center wide (thread list + metadata
    /// columns), card view wants it narrow (cards are self-contained
    /// and the reader gets the slack). Two `@AppStorage` slots keep the
    /// preferences independent across launches.
    @AppStorage("designmock.centerPaneIdealWidth.cards") private var centerWidthCards: Double = 460
    @AppStorage("designmock.centerPaneIdealWidth.table") private var centerWidthTable: Double = 560
    /// Debounces the GeometryReader-driven save so a drag-resize doesn't
    /// write to UserDefaults once per frame. Fires ~200ms after the user
    /// stops dragging.
    @State private var persistCenterWidthTask: Task<Void, Never>?

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
        .navigationTitle("")
        .toolbar {
            // Toolbar sort picker removed — sort direction is now chosen
            // per-column via the filter card's segmented picker, and the
            // initial "global" sort lives implicitly in the DB query.

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
            // Populate `unifiedFilters` up-front so the sidebar HISTORY
            // section has something to render on first paint. Without
            // this the section stays hidden until the user happens to
            // trigger a save-recent path somewhere else in the app.
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
            // Debounce the HISTORY recording. Prior version fired on
            // every keystroke, and each call triggered a DB UPSERT +
            // three reads (`listRecentFilters` + `listSavedViews` +
            // `listUnifiedFilters`) + a `@Published` update that re-
            // laid-out the sidebar. Typing a 5-char query stacked up
            // ~5 of those bursts on the MainActor, visibly stalling
            // the card list. Now only the *settled* query (user
            // paused ≥400ms) is recorded. `saveRecentFilter` still
            // dedupes by filter_hash on top of this, so pinning the
            // same query twice never double-writes.
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
        // Record the "currently displayed" thread into the recent-
        // threads store whenever it changes. We key the observer on
        // the single-conversation id (not the whole selection set) so
        // multi-select lassoes don't spam the history list — only
        // "which thread is the reader showing" counts as an open.
        // Debouncing isn't needed here because each id transition
        // corresponds to a deliberate user pick; back-to-back writes
        // only happen when the user is actively clicking, and the
        // store's move-to-top semantics collapse same-id re-records.
        .onChange(of: selectedConversation?.id) { _, _ in
            recordCurrentThreadInHistory()
        }
        .onAppear {
            repairSelectionIfNeeded(currentIDs: store.conversations.map(\.id))
            // Seed with whatever is already displayed on first paint
            // so the very first thread the user lands on shows up in
            // History without needing to pick a second one first.
            recordCurrentThreadInHistory()
        }
    }

    /// Shared entry point for "the reader is now showing this
    /// thread". Reads the currently-displayed `DesignMockConversation`
    /// and forwards its snapshot into `RecentThreadsStore`. No-op when
    /// no thread is displayed (empty archive / stale selection
    /// between fetches) so the history list doesn't develop phantom
    /// rows.
    private func recordCurrentThreadInHistory() {
        guard let conv = selectedConversation else { return }
        recentThreadsStore.record(
            id: conv.id,
            title: conv.title,
            source: conv.source,
            model: conv.model,
            primaryTime: conv.updated
        )
    }

    /// If the selection set is missing or stale (first launch, or the
    /// previous selection was filtered away by a sidebar / query
    /// change), seed it with the first available conversation so all
    /// three modes agree on what "the current thread" is. No-op when
    /// at least one current id is still present — we never overwrite
    /// a live multi-selection, which would fight the user's own tap.
    private func repairSelectionIfNeeded(currentIDs: [DesignMockConversation.ID]) {
        guard !currentIDs.isEmpty else { return }
        let intersected = selectedConversationIDs.intersection(currentIDs)
        if !intersected.isEmpty {
            // Drop stale ids but keep the user's multi-select intent.
            if intersected != selectedConversationIDs {
                selectedConversationIDs = intersected
            }
            return
        }
        if let first = currentIDs.first {
            selectedConversationIDs = [first]
        }
    }

    @ViewBuilder
    private var rootSplitView: some View {
        switch selectedLayoutMode {
        case .table:
            NavigationSplitView {
                sidebar
            } detail: {
                if showingAutoIntake {
                    AutoIntakePane()
                } else {
                    centerTable
                }
            }
        case .default:
            // The `.id(...)` on the NavigationSplitView forces a rebuild
            // when the center display mode flips. `navigationSplitViewColumnWidth`
            // only influences the *initial* layout of a given split-view
            // instance — without the identity change, switching from cards
            // (narrow center) to table (wider center) would leave the pane
            // stuck at whichever width was active first. Rebuilding makes
            // SwiftUI adopt the new ideal. The per-mode ideal comes from
            // `currentCenterIdeal`, which reads whichever `@AppStorage` slot
            // matches the active mode, so user drag-resizes survive across
            // launches.
            NavigationSplitView {
                sidebar
            } content: {
                if showingAutoIntake {
                    AutoIntakePane()
                        .navigationSplitViewColumnWidth(min: 320, ideal: currentCenterIdeal, max: 760)
                } else {
                    DesignMockDefaultContentPane(
                        displayMode: $selectedCenterDisplayMode,
                        conversations: store.conversations,
                        conversationSelection: $selectedConversationIDs,
                        pendingPromptID: $pendingPromptID,
                        expandedPromptConversationID: $expandedPromptConversationID,
                        totalCount: store.totalCount,
                        isLoading: store.isLoading,
                        isLoadingMore: store.isLoadingMore,
                        lastError: store.lastError,
                        onReachEnd: {
                            store.loadMoreIfNeeded(services: services)
                        },
                        // Share the same table declaration used by
                        // `.table` layout. Inside default mode the
                        // reader is already visible, so `onOpen` is a
                        // no-op — the double-click highlights the row
                        // and the reader updates via selection binding.
                        tableContent: { makeCenterTable() }
                    )
                    .background(centerWidthProbe)
                    .navigationSplitViewColumnWidth(min: 320, ideal: currentCenterIdeal, max: 760)
                }
            } detail: {
                if showingAutoIntake {
                    AutoIntakeDetailPlaceholder()
                } else {
                    readerPane(inThreadSearch: nil)
                }
            }
            .id("default-\(selectedCenterDisplayMode.rawValue)")
        case .viewer:
            NavigationSplitView {
                sidebar
            } detail: {
                if showingAutoIntake {
                    AutoIntakePane()
                } else {
                    readerPane(inThreadSearch: $searchText)
                }
            }
        }
    }

    /// Ideal center-pane width for the currently-active display mode in
    /// `.default` layout. Reads the matching `@AppStorage` slot so the
    /// width the user settled on last session is the one the split view
    /// opens with next launch. Table mode gets its own slot from cards
    /// because the columns-vs-cards trade-off genuinely asks for a
    /// different ratio: the table wants room for `Model / Updated /
    /// Prompts / Source` to breathe, cards hand slack to the reader.
    private var currentCenterIdeal: CGFloat {
        let raw = selectedCenterDisplayMode == .table ? centerWidthTable : centerWidthCards
        // Clamp defensively so a stale / hand-edited preferences value
        // can't lock the user out of the split (below-min disappears
        // the pane, above-max is equally unusable).
        return CGFloat(min(max(raw, 320), 760))
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
    /// *within* the allowed range.
    private func persistCenterWidth(_ width: CGFloat) {
        let clamped = min(max(Double(width), 320), 760)
        // GeometryReader transiently reports 0 during teardown / mode
        // switch. Treating that as a real preference would wipe the saved
        // width the moment the user flips mode.
        guard width > 1 else { return }
        let mode = selectedCenterDisplayMode
        persistCenterWidthTask?.cancel()
        persistCenterWidthTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            switch mode {
            case .table:
                if abs(centerWidthTable - clamped) > 0.5 {
                    centerWidthTable = clamped
                }
            case .cards:
                if abs(centerWidthCards - clamped) > 0.5 {
                    centerWidthCards = clamped
                }
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
                inThreadSearch: inThreadSearch
            )
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var sidebar: some View {
        // Custom binding so a USER click on a Library / Sources row
        // clears any DSL-filled search text lingering from a previous
        // HISTORY pick. Without this, clicking a HISTORY filter
        // entry stuffs `source:claude` (or similar) into the toolbar,
        // then clicking "Bookmarks" / "Sources → chatgpt" appears to
        // do nothing — the DSL in `searchText` overrides the sidebar-
        // derived scope in `composedQuery`, so the fetch query never
        // actually matches what the user just clicked. Clearing
        // `searchText` through the setter (NOT in `.onChange`) means
        // it only fires for List-driven writes; the programmatic
        // `selectedSidebarItemID = allThreads.id` inside
        // `onSelectHistoryEntry` bypasses this setter and leaves the
        // just-restored DSL in place.
        let sidebarSelection = Binding<DesignMockSidebarItem.ID?>(
            get: { selectedSidebarItemID },
            set: { newValue in
                if let newValue, newValue != selectedSidebarItemID {
                    searchText = ""
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
            libraryViewModel: libraryViewModel,
            recentThreads: recentThreadsStore.entries,
            onSelectHistoryEntry: { entry in
                // Push the entry's filter back onto the toolbar field.
                // The `.onChange(of: composedQuery)` wiring then re-runs
                // the store fetch through the exact same path as
                // hand-typed DSL, so HISTORY and typing share a single
                // code path downstream. Sidebar selection is cleared
                // so a matching sidebar pick (e.g. Bookmarks) from a
                // previous tap doesn't compound with the restored
                // filter and over-narrow the list.
                searchText = DesignMockQueryLanguage.searchText(from: entry.filters)
                selectedSidebarItemID = DesignMockSidebarItem.allThreads.id
            },
            onSelectRecentThread: { entry in
                // Clicking a recent-thread history row = "open this
                // thread again". We clear every filter surface so the
                // target is guaranteed to be in the fetch page
                // (sidebar narrowing or a stale search could otherwise
                // filter it out and the click would silently land on
                // whichever thread happens to be first in the
                // narrowed list), then select it. Layout is forced to
                // `.default` so the reader pane is visible — picking a
                // thread from history should always show the thread,
                // even when the user is currently in table mode.
                searchText = ""
                selectedSidebarItemID = DesignMockSidebarItem.allThreads.id
                selectedConversationIDs = [entry.id]
                selectedLayoutMode = .default
            },
            onRemoveRecentThread: { entry in
                recentThreadsStore.remove(id: entry.id)
            }
        )
        .navigationSplitViewColumnWidth(min: 240, ideal: 270, max: 320)
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
            onOpen: onOpen
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
        // current list, falling back to the very first row when the
        // selection is stale or empty so the reader has *something* to
        // show rather than a jarring blank.
        let visibleMatch = store.conversations.first { selectedConversationIDs.contains($0.id) }
        return visibleMatch ?? store.conversations.first
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
        if selectedLayoutMode != .viewer {
            query.keyword = parsed.keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        query.sortKey = DesignMockQueryLanguage.dbSortKey(from: parsed.sortToken)
        // Start from sidebar-derived filters so a plain sidebar pick
        // still scopes the library without any typing.
        let kind = DesignMockSidebarItem.kind(for: selectedSidebarItemID, sources: store.sources)
        switch kind {
        case .all, .archiveDB, .autoIntake, .unknown:
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
    /// Inverse (best-effort) of `DesignMockQueryLanguage.searchText(from:)`
    /// + the `composedQuery` builder: keyword, single-source, single-
    /// model, bookmarksOnly are the only dimensions this shell can
    /// produce, so those are the only ones round-tripped.
    ///
    /// `query.tagName` is intentionally dropped. The tag-picker UI was
    /// removed in the "ditch tags" redesign, and although the `tag:`
    /// DSL token still filters live results, we do NOT want it seeding
    /// `bookmarkTags`-bearing rows in `saved_filters` — those are the
    /// rows `isUnproducibleByCurrentShell` treats as legacy and evicts
    /// from HISTORY. Keeping them out at the write side means the
    /// eviction pass has nothing new to clean up.
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
    /// filter vs. in-thread finder.
    private var searchPrompt: String {
        switch selectedLayoutMode {
        case .table, .default:
            return "ライブラリを検索"
        case .viewer:
            return "このスレッド内を検索"
        }
    }

    private var showingAutoIntake: Bool {
        let kind = DesignMockSidebarItem.kind(for: selectedSidebarItemID, sources: store.sources)
        if case .autoIntake = kind { return true }
        return false
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
    /// the shell; the HISTORY section below reads its `unifiedFilters`
    /// array, and Phase-4 prompt-bookmark surfaces will too.
    let libraryViewModel: LibraryViewModel?
    /// Rolling list of recently-opened threads, rendered in the same
    /// HISTORY section as filter history so the user sees "what I
    /// searched" and "what I opened" in one surface.
    let recentThreads: [RecentThreadsStore.Entry]
    /// Callback for when the user picks a history entry. The parent
    /// translates the entry's `ArchiveSearchFilter` back into the
    /// toolbar search field, which then flows through `composedQuery`
    /// → store fetch via the normal typing path.
    let onSelectHistoryEntry: (SavedFilterEntry) -> Void
    /// Called when the user clicks a recent-thread row. Parent is
    /// responsible for clearing filters and selecting the thread so
    /// the reader pane updates.
    let onSelectRecentThread: (RecentThreadsStore.Entry) -> Void
    /// Called from the recent-thread row's context menu ("Remove from
    /// history"). Lets users prune the list without affecting the
    /// underlying thread.
    let onRemoveRecentThread: (RecentThreadsStore.Entry) -> Void
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
        return List(selection: $selection) {
            Section("Library") {
                sidebarRow(allItem)
                sidebarRow(bookmarksRow)
                sidebarRow(archiveRow)
                sidebarRow(DesignMockSidebarItem.autoIntake)
            }

            Section("Sources") {
                if sources.isEmpty {
                    Text("No sources yet")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(sources, id: \.name) { source in
                        sourceRow(source)
                    }
                }
            }

            // HISTORY — a single chronological stream. Filter entries
            // (from `LibraryViewModel.unifiedFilters`) and opened-thread
            // entries (from `RecentThreadsStore`) are interleaved and
            // ordered strictly by their most-recent-use timestamp, so
            // "what I searched" and "what I opened" appear in the same
            // order the user actually performed the actions. The prior
            // split (filters grouped first, threads grouped after) was
            // dropped per user request: "Historyはクエリとスレッドを
            // 分けずに、シンプルに履歴を順番に表示して".
            //
            // Pinned filters keep their star affordance and their
            // pin/unpin action, but no longer jump to the top — the
            // unified order is purely time-based. Users who want a
            // pinned filter near the top can re-run it to bump its
            // timestamp.
            if !historyItems.isEmpty {
                Section("History") {
                    ForEach(historyItems) { item in
                        switch item {
                        case .filter(let entry):
                            SavedFilterRow(
                                entry: entry,
                                onSelect: { onSelectHistoryEntry(entry) },
                                onTogglePin: {
                                    libraryViewModel?.togglePinned(entry)
                                },
                                onDelete: {
                                    libraryViewModel?.deleteFilterEntry(entry)
                                }
                            )
                        case .thread(let entry):
                            RecentThreadRow(entry: entry)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    onSelectRecentThread(entry)
                                }
                                .contextMenu {
                                    Button("Remove from History", role: .destructive) {
                                        onRemoveRecentThread(entry)
                                    }
                                }
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .onChange(of: sources.map(\.name)) { _, _ in
            seedExpansionIfNeeded()
        }
        .onAppear {
            seedExpansionIfNeeded()
        }
    }

    /// Merged, chronologically-sorted history stream. Both filter
    /// entries and recent-thread entries live here under a single
    /// list — the sidebar renders them in this order, newest first,
    /// without grouping by kind. Empty when both sources are empty,
    /// which lets the "History" section header hide entirely so the
    /// sidebar doesn't draw a collapsible above nothing on a fresh
    /// DB.
    private var historyItems: [HistoryItem] {
        var items: [HistoryItem] = []
        if let libraryViewModel {
            items.append(contentsOf: libraryViewModel.unifiedFilters.map(HistoryItem.filter))
        }
        items.append(contentsOf: recentThreads.map(HistoryItem.thread))
        // Most-recent first. `HistoryItem.timestamp` parses
        // `SavedFilterEntry.lastUsedAt` ("YYYY-MM-DD HH:MM:SS") and
        // returns `RecentThreadsStore.Entry.openedAt` as-is, so
        // filter rows and thread rows compare on the same axis.
        return items.sorted { $0.timestamp > $1.timestamp }
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

    /// Renders a source row. Sources with a single (or zero) model stay as
    /// flat rows; sources with multiple models expand into a `DisclosureGroup`
    /// so the user can narrow to a specific model (`chatgpt → gpt-4o`).
    @ViewBuilder
    private func sourceRow(_ source: DesignMockSource) -> some View {
        let item = DesignMockSidebarItem(
            id: "source-\(source.name)",
            title: source.name,
            subtitle: "\(source.count) threads",
            systemImage: "circle.fill",
            kind: .source(source.name)
        )
        if source.models.count > 1 {
            DisclosureGroup(
                isExpanded: Binding(
                    get: { expandedSources.contains(source.name) },
                    set: { isExpanded in
                        if isExpanded {
                            expandedSources.insert(source.name)
                        } else {
                            expandedSources.remove(source.name)
                        }
                    }
                )
            ) {
                ForEach(source.models, id: \.name) { model in
                    sidebarRow(
                        .init(
                            id: "model-\(source.name)-\(model.name)",
                            title: model.name,
                            subtitle: "\(model.count) threads",
                            systemImage: "cpu",
                            kind: .model(source: source.name, model: model.name)
                        )
                    )
                }
            } label: {
                sidebarRow(item)
            }
        } else {
            sidebarRow(item)
        }
    }

    private func sidebarRow(_ item: DesignMockSidebarItem) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .lineLimit(1)
                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        } icon: {
            Image(systemName: item.systemImage)
                .foregroundStyle(item.iconStyle)
                .frame(width: 17)
        }
        .tag(item.id)
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

    var body: some View {
        if let expandedConversation {
            pinnedPromptView(for: expandedConversation)
        } else {
            cardList
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
        // here — opening a thread from ANY surface (sidebar HISTORY,
        // bookmark, etc.) lands the row at the top of the card list.
        ScrollViewReader { proxy in
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(conversations) { conversation in
                    DesignMockConversationListRow(conversation: conversation)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        // Padding is INSIDE the hit shape — tapping in
                        // the edge margin still registers as the row.
                        .contentShape(Rectangle())
                        .background(
                            selection.contains(conversation.id)
                                ? Color.accentColor.opacity(0.14)
                                : Color.clear
                        )
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
        // Selection-driven scroll-to-top. Fires on every transition of
        // the selection set so external triggers (sidebar recent-thread
        // click, bookmark click, filter-repair) consistently pull the
        // opened row into the top of the visible viewport.
        .onChange(of: selection) { _, newSelection in
            guard let id = newSelection.first else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                proxy.scrollTo(id, anchor: .top)
            }
        }
        // First-mount scroll: if the selection was already seeded
        // before this view materialized (e.g. the user just flipped
        // layout mode with a thread already selected), bring that row
        // into view as well. Short poll lets the in-memory list
        // populate from the DB paged query before we try to scroll.
        .task {
            guard let id = selection.first else { return }
            for _ in 0..<20 {
                if conversations.contains(where: { $0.id == id }) { break }
                try? await Task.sleep(nanoseconds: 40_000_000)
            }
            try? await Task.sleep(nanoseconds: 80_000_000)
            proxy.scrollTo(id, anchor: .top)
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
    }

    private func pinnedPromptView(for conversation: DesignMockConversation) -> some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.16)) {
                    expandedPromptConversationID = nil
                }
            } label: {
                DesignMockConversationListRow(conversation: conversation)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.accentColor.opacity(0.14))
            }
            .buttonStyle(.plain)

            Divider()

            ScrollView {
                DesignMockExpandedPromptList(
                    conversation: conversation,
                    pendingPromptID: $pendingPromptID
                )
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollContentBackground(.hidden)
        }
        .background(.regularMaterial)
    }

    private var expandedConversation: DesignMockConversation? {
        guard let expandedPromptConversationID else { return nil }
        return conversations.first { $0.id == expandedPromptConversationID }
    }
}

private struct DesignMockDefaultContentPane<TableContent: View>: View {
    @Binding var displayMode: DesignMockCenterDisplayMode
    let conversations: [DesignMockConversation]
    @Binding var conversationSelection: Set<DesignMockConversation.ID>
    @Binding var pendingPromptID: String?
    @Binding var expandedPromptConversationID: DesignMockConversation.ID?
    let totalCount: Int
    let isLoading: Bool
    let isLoadingMore: Bool
    let lastError: String?
    let onReachEnd: () -> Void
    /// Shared table view. Injected from the shell so the SAME
    /// `DesignMockThreadTablePane` declaration / config is rendered
    /// both when the outer layout is `.table` (table-only, no reader)
    /// and when the outer layout is `.default` with display mode
    /// `.table` (picker + table + reader). Sharing the construction
    /// site eliminates drift between two call-sites that used to
    /// redeclare the same columns with slightly different parameters,
    /// and gives SwiftUI a single `.id("center-table")` to hang
    /// identity off when it evaluates the view tree.
    @ViewBuilder let tableContent: () -> TableContent

    var body: some View {
        // `.safeAreaInset(edge: .top)` instead of a plain VStack so the
        // scroll content (table rows / cards / gallery tiles) flows
        // BEHIND the header strip and the `.bar` material frosts what's
        // underneath — the same "frosted glass" chrome Finder / Mail /
        // Safari use for their pinned header rows. In a plain VStack
        // the header sat ABOVE the content and nothing scrolled behind
        // it, so `.bar` rendered against the window background and the
        // chrome didn't actually participate in any blur. With a safe-
        // area inset, AppKit's NSScrollView extends its clip bounds up
        // under the inset and the material has real content to blur,
        // which is what makes the strip read as translucent glass
        // rather than an opaque-ish solid bar.
        contentView
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    // Top strip: view-mode picker hugs the LEFT edge;
                    // thread-count (plus an optional spinner while the
                    // first page loads) hugs the RIGHT. Vertical padding
                    // matches the reader pane's pinned
                    // `ConversationHeaderView` (`.padding(.vertical, 10)`)
                    // so the two bar heights line up pixel-for-pixel
                    // across the split-view seam.
                    HStack(spacing: 12) {
                        Picker("Center View", selection: $displayMode) {
                            ForEach(DesignMockCenterDisplayMode.allCases) { mode in
                                Image(systemName: mode.symbol)
                                    .accessibilityLabel(Text(mode.title))
                                    .tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .controlSize(.small)
                        .frame(width: 92)

                        Spacer()

                        // Count / load status. Keeps the "N threads"
                        // total visible at the top of the pane so the
                        // user always knows the scope of what the
                        // keyword query is searching, and shows a
                        // spinner while the first page is still loading.
                        if isLoading && conversations.isEmpty {
                            ProgressView()
                                .controlSize(.small)
                        }

                        Text(countLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)

                    if let lastError {
                        Text(lastError)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .padding(.horizontal, 12)
                            .padding(.bottom, 4)
                    }
                }
                // `.bar` material on the inset wrapper (NOT on the
                // individual rows) so the whole strip — picker row +
                // any error banner — sits on one continuous frosted
                // pane, and the scroll content genuinely blurs behind
                // it instead of showing through. No bottom divider: the
                // blur edge against the non-frosted content below is
                // sharp enough on its own.
                .background(.bar)
            }
    }

    private var countLabel: String {
        // Show only the denominator (the DB total). The previously
        // displayed `loaded / total` fraction exposed the pagination
        // cursor, which is internal plumbing the user doesn't need
        // to see — what matters is the scope of the current filter.
        // `totalCount == 0` falls back to the in-memory list so the
        // label still renders meaningfully before the count query
        // resolves.
        let total = totalCount > 0 ? totalCount : conversations.count
        return "\(total) threads"
    }

    @ViewBuilder
    private var contentView: some View {
        switch displayMode {
        case .table:
            // Hand the shell-owned table view straight through. This is
            // the SAME construction site used by the `.table` outer
            // layout, so there's no second declaration of columns /
            // sort / selection to keep in sync.
            tableContent()
        case .cards:
            DesignMockThreadListPane(
                conversations: conversations,
                selection: $conversationSelection,
                pendingPromptID: $pendingPromptID,
                expandedPromptConversationID: $expandedPromptConversationID,
                isLoadingMore: isLoadingMore,
                onReachEnd: onReachEnd
            )
        }
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
    /// reader pane opens the conversation. Optional because the same
    /// table is also embedded inside `.default` mode, where the reader
    /// is already visible and opening is a no-op.
    var onOpen: ((DesignMockConversation.ID) -> Void)? = nil

    var body: some View {
        // Re-sort locally so header clicks reflect immediately on the page
        // already on screen. Global sort (which drives the DB query and
        // pagination order) is unaffected.
        let rows = conversations.sorted(using: sortOrder)
        // `ScrollViewReader` so selection changes driven from OUTSIDE the
        // table (sidebar HISTORY click, bookmark click, filter swap that
        // repairs the selection) can scroll the target row to the top.
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
        // Whenever the selected thread changes (whether by user click in
        // the table, sidebar HISTORY re-open, bookmark click, or filter-
        // repair in the shell), snap the table so the selected row sits
        // at the top. User requested consistency: opening a thread from
        // ANY surface lands it at the top of the center pane, rather
        // than requiring the user to hunt for the highlighted row in
        // the scroll position. `anchor: .top` + easeInOut is less
        // disorienting than a hard jump on internal clicks.
        .onChange(of: selection) { _, newSelection in
            guard let id = newSelection.first else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                proxy.scrollTo(id, anchor: .top)
            }
        }
        // On first mount, if the selection was already set by the
        // sidebar path (recent-thread click flips layout to `.default`
        // *and* writes the id into `selectedConversationIDs` in the
        // same tick), we need to scroll to it too — the `.onChange`
        // above only fires for transitions *after* mount. A brief
        // poll waits for the target row to page into the in-memory
        // list before asking `proxy.scrollTo` to land it.
        .task {
            guard let id = selection.first else { return }
            for _ in 0..<20 {
                if conversations.contains(where: { $0.id == id }) { break }
                try? await Task.sleep(nanoseconds: 40_000_000)
            }
            try? await Task.sleep(nanoseconds: 80_000_000)
            proxy.scrollTo(id, anchor: .top)
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

    var body: some View {
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
                }
            }
        }
        .padding(.leading, 22)
        .padding(.trailing, 2)
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
    }

    @ViewBuilder
    private func promptRow(_ prompt: DesignMockPrompt) -> some View {
        let isPinned = store.isPromptBookmarked(prompt.id)
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "text.bubble")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 18)

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
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(prompt.snippet)
                        .font(.subheadline)
                        .lineLimit(1)
                        .foregroundStyle(.primary)

                    Spacer(minLength: 8)

                    Text("\(prompt.index + 1)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
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
        .padding(.horizontal, 10)
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
                .frame(width: 18)
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
            inThreadSearch: inThreadSearch
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

    /// Every individual keyword occurrence across the thread, in
    /// transcript order. Each entry is "message M, occurrence N" — so a
    /// message with the query appearing 3 times contributes 3 entries.
    /// This drives per-keyword Prev/Next: stepping cycles through
    /// individual hits rather than jumping whole messages at a time.
    @State private var matchLocations: [MatchLocation] = []
    /// Which match is currently centered in the reader. Clamped to
    /// `matchLocations.indices` — reset to 0 when the list changes.
    @State private var currentMatchIndex: Int = 0

    /// A single keyword hit. `occurrenceInMessage` is the 0-indexed
    /// rank of this hit inside its own message under a case-insensitive
    /// left-to-right scan, and matches the indexing
    /// `MessageBubbleView.applyingSearchHighlight` uses when picking
    /// which range to paint hot.
    fileprivate struct MatchLocation: Equatable {
        let messageID: String
        let occurrenceInMessage: Int
    }
    /// Monotonic token used to cancel in-flight search recomputations
    /// when the user keeps typing.
    @State private var searchToken: UUID = UUID()

    init(
        conversation: DesignMockConversation?,
        services: AppServices,
        libraryViewModel: LibraryViewModel,
        pendingPromptID: Binding<String?>,
        inThreadSearch: Binding<String>? = nil
    ) {
        self.conversation = conversation
        self.services = services
        self.libraryViewModel = libraryViewModel
        _pendingPromptID = pendingPromptID
        self.inThreadSearch = inThreadSearch
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
            } else {
                emptyState
            }
        }
        .background(.background)
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
            activeMessageID: location?.messageID,
            activeOccurrenceInMessage: location?.occurrenceInMessage
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
            // editor. Per message we walk left-to-right and record
            // each hit; the resulting flat list is what the find bar's
            // N/M cursor steps through.
            let needle = query
            var locations: [MatchLocation] = []
            for message in detail.messages {
                let content = message.content
                var searchFrom = content.startIndex
                var occurrence = 0
                while searchFrom < content.endIndex,
                      let range = content.range(
                        of: needle,
                        options: .caseInsensitive,
                        range: searchFrom..<content.endIndex
                      ) {
                    locations.append(MatchLocation(
                        messageID: message.id,
                        occurrenceInMessage: occurrence
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
            await MainActor.run {
                matchLocations = locations
                currentMatchIndex = 0
                // Auto-jump to the first match's message so the user
                // sees feedback immediately on typing. Subsequent hits
                // inside the same message don't need a re-scroll.
                if let first = locations.first {
                    pendingPromptID = first.messageID
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
    /// of the list. Only fires `pendingPromptID` when the step crosses a
    /// message boundary — stepping between two occurrences inside the
    /// same bubble just advances the hot-color cursor via the updated
    /// `SearchHighlightSpec`, without re-triggering a scroll that would
    /// jerk the viewport back to the top of the message.
    private func stepMatch(by delta: Int) {
        guard !matchLocations.isEmpty else { return }
        let count = matchLocations.count
        let next = ((currentMatchIndex + delta) % count + count) % count
        let previousMessageID = matchLocations[currentMatchIndex].messageID
        currentMatchIndex = next
        let nextMessageID = matchLocations[next].messageID
        if nextMessageID != previousMessageID {
            pendingPromptID = nextMessageID
        }
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

/// Sidebar row for one `RecentThreadsStore.Entry`. Visually lighter
/// than the main card list row — no snippet, no prompts count,
/// just "title · model" — so the sidebar stays scannable even when
/// the list fills up to its 20-entry cap. The model text takes the
/// service's brand color (same as `ConversationRowView`) so the
/// user can tell chatgpt vs claude vs gemini threads apart without
/// reading the model string.
/// Unified sidebar-history item: wraps either a saved-filter entry
/// (click re-runs the filter) or a recent-thread entry (click re-opens
/// the thread). A single enum lets the sidebar interleave the two
/// kinds in one chronologically-sorted list while keeping each row's
/// per-kind rendering distinct.
private enum HistoryItem: Identifiable {
    case filter(SavedFilterEntry)
    case thread(RecentThreadsStore.Entry)

    /// Stable id that's unique across the two namespaces — the raw
    /// integer id of a `SavedFilterEntry` could collide with a
    /// conversation id (also a string) in edge cases, so we prefix
    /// both with the kind.
    var id: String {
        switch self {
        case .filter(let entry): return "filter-\(entry.id)"
        case .thread(let entry): return "thread-\(entry.id)"
        }
    }

    /// Comparable timestamp for sort. `SavedFilterEntry.lastUsedAt` is
    /// stored as `"YYYY-MM-DD HH:MM:SS"` (see `TimestampFormatter`), so
    /// we parse with the same format. A missing / malformed timestamp
    /// falls back to `.distantPast` so the row sinks to the bottom
    /// rather than silently vanishing.
    var timestamp: Date {
        switch self {
        case .filter(let entry):
            return HistoryItem.timestampFormatter.date(from: entry.lastUsedAt) ?? .distantPast
        case .thread(let entry):
            return entry.openedAt
        }
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()
}

private struct RecentThreadRow: View {
    let entry: RecentThreadsStore.Entry

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 14, alignment: .center)

            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title)
                    .lineLimit(1)
                if let model = entry.model {
                    Text(model)
                        .font(.caption2)
                        .lineLimit(1)
                        .foregroundStyle(SourceAppearance.color(forModel: model))
                } else if let source = entry.source {
                    Text(source)
                        .font(.caption2)
                        .lineLimit(1)
                        .foregroundStyle(SourceAppearance.color(for: source))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
    }
}

private struct DesignMockConversationListRow: View {
    let conversation: DesignMockConversation

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(conversation.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)

                Spacer(minLength: 8)

                Text(conversation.updated)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if let snippet = conversation.snippet {
                // FTS match snippet — shown only when the user has typed a
                // keyword, so cards in browse mode stay compact.
                Text(snippet)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            HStack(spacing: 8) {
                Label(conversation.model, systemImage: "cpu")
                    .lineLimit(1)
                Text("\(conversation.prompts) prompts")
                    .monospacedDigit()
                Text(conversation.source)
                    .foregroundStyle(conversation.sourceColor)
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
    /// Rendered share URL. Nil while the markdown export is being
    /// written, or when no conversation is selected. `ShareLink`
    /// appears only when non-nil; the disabled placeholder keeps the
    /// toolbar row stable on first mount.
    @State private var shareURL: URL?
    /// Guard against a stale fetch overwriting `shareURL` when the user
    /// switches conversations mid-export. Compared at write time —
    /// if the id changed while the async chain was in flight, the
    /// result is discarded.
    @State private var pendingExportID: String?

    var body: some View {
        Group {
            if let shareURL, let conversation {
                ShareLink(
                    item: shareURL,
                    preview: SharePreview(
                        conversation.title,
                        image: Image(systemName: "doc.text")
                    )
                ) {
                    Image(systemName: "square.and.arrow.up")
                        .font(DesignMockToolbarMetrics.iconFont)
                        .foregroundStyle(.primary)
                }
                .help("Share selected conversation")
            } else {
                // Placeholder keeps the toolbar column width stable
                // while the markdown file is being written (first
                // mount, or after switching to a different thread).
                // Disabled so clicks don't accidentally open a stale
                // picker.
                Button {} label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(DesignMockToolbarMetrics.iconFont)
                        .foregroundStyle(.primary)
                }
                .disabled(true)
                .help(conversation == nil ? "No conversation selected" : "Preparing share…")
            }
        }
        // Re-export whenever the selected thread changes. Keying on
        // the conversation id (or nil) means switching between
        // conversations triggers a fresh export; switching layout
        // modes without changing the selection reuses the current
        // file. `nil` identity cleanly resets the URL so the
        // placeholder returns when the user deselects everything.
        .task(id: conversation?.id) {
            await refreshShareURL(for: conversation)
        }
    }

    private func refreshShareURL(for conversation: DesignMockConversation?) async {
        guard let conversation else {
            shareURL = nil
            pendingExportID = nil
            return
        }
        pendingExportID = conversation.id
        shareURL = nil
        do {
            guard let detail = try await services.conversations
                .fetchDetail(id: conversation.id) else {
                return
            }
            // Bail if the user has since moved on to another thread —
            // writing the file would be wasted work, and assigning
            // `shareURL` would briefly flash a stale file's preview.
            guard pendingExportID == conversation.id else { return }
            let url = await MarkdownExporter.writeTempShareFile(for: detail)
            guard pendingExportID == conversation.id else { return }
            shareURL = url
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
        case autoIntake
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

    static let autoIntake = DesignMockSidebarItem(
        id: "auto-intake",
        title: "Auto Intake",
        subtitle: "Drop exports to ingest",
        systemImage: "tray.and.arrow.down.fill",
        kind: .autoIntake
    )

    static let bookmarks = DesignMockSidebarItem(
        id: "bookmarks",
        title: "Bookmarks",
        subtitle: nil,
        systemImage: "bookmark.fill",
        kind: .bookmarks
    )

    static let archiveDB = DesignMockSidebarItem(
        id: "archive-db",
        title: "archive.db",
        subtitle: "Local SQLite archive",
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
        if id == autoIntake.id { return .autoIntake }
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

private enum DesignMockLayoutMode: String, CaseIterable, Identifiable {
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

private enum DesignMockCenterDisplayMode: String, CaseIterable, Identifiable {
    case table
    case cards

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cards: return "Cards"
        case .table: return "Table"
        }
    }

    var symbol: String {
        switch self {
        case .cards: return "rectangle.stack"
        case .table: return "tablecells"
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

    /// Re-serialize an `ArchiveSearchFilter` back into a searchText
    /// string the toolbar field can display. Used by the HISTORY
    /// sidebar section: clicking a saved entry pushes the
    /// corresponding DSL sentence into the field, which in turn
    /// flows through `composedQuery` → store fetch. The round-trip
    /// is lossy by design — only dimensions the DSL natively
    /// supports (keyword, single source, single model,
    /// bookmarks-only) survive. Multi-value or advanced fields
    /// (date ranges, role, source-file paths, #tags) are dropped;
    /// the corresponding rows won't disappear from history but
    /// they also won't fully reproduce their filter when selected.
    /// That tradeoff is acceptable for a Phase-3 slice — the
    /// common case (keyword + source + model) is what users save
    /// and re-invoke; richer selection UX can come later if the
    /// gap proves painful.
    static func searchText(from filter: ArchiveSearchFilter) -> String {
        var parts: [String] = []
        let keyword = filter.normalizedKeyword
        if !keyword.isEmpty {
            parts.append(keyword)
        }
        if let source = filter.sources.sorted().first {
            parts.append("source:\(source)")
        }
        if let model = filter.models.sorted().first {
            parts.append("model:\(model)")
        }
        if filter.bookmarkedOnly {
            parts.append("is:bookmarked")
        }
        return parts.joined(separator: " ")
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
