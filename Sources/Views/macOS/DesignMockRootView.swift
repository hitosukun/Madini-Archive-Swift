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
    @Published private(set) var bookmarks: [DesignMockBookmark] = []
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
            // Only surface thread-level bookmarks in the sidebar — prompt /
            // virtual-fragment / saved-view bookmarks each have their own
            // semantics and can't be clicked through to a conversation as a
            // single row.
            bookmarks = entries.compactMap { entry in
                guard entry.targetType == .thread else { return nil }
                return DesignMockBookmark(
                    bookmarkID: entry.bookmarkID,
                    conversationID: entry.targetID,
                    title: entry.title ?? entry.label,
                    source: (entry.source ?? "unknown").lowercased(),
                    model: entry.model ?? "—",
                    updated: Self.formatUpdated(entry.primaryTime)
                )
            }
        } catch {
            lastError = String(describing: error)
        }
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

/// Thread-level bookmark row shown in the sidebar Bookmarks section.
fileprivate struct DesignMockBookmark: Identifiable, Hashable {
    let bookmarkID: Int
    let conversationID: String
    let title: String
    let source: String
    let model: String
    let updated: String

    var id: Int { bookmarkID }
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
            NavigationSplitView {
                sidebar
            } content: {
                if showingAutoIntake {
                    AutoIntakePane()
                        .navigationSplitViewColumnWidth(min: 360, ideal: 460, max: 760)
                } else {
                    DesignMockDefaultContentPane(
                        displayMode: $selectedCenterDisplayMode,
                        conversations: store.conversations,
                        conversationSelection: $selectedConversationIDs,
                        pendingPromptID: $pendingPromptID,
                        expandedPromptConversationID: $expandedPromptConversationID,
                        tableSortOrder: tableSortOrderBinding,
                        totalCount: store.totalCount,
                        isLoading: store.isLoading,
                        isLoadingMore: store.isLoadingMore,
                        lastError: store.lastError,
                        onReachEnd: {
                            store.loadMoreIfNeeded(services: services)
                        }
                    )
                    .navigationSplitViewColumnWidth(min: 360, ideal: 460, max: 760)
                }
            } detail: {
                if showingAutoIntake {
                    AutoIntakeDetailPlaceholder()
                } else {
                    readerPane(inThreadSearch: nil)
                }
            }
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
        DesignMockSidebar(
            selection: $selectedSidebarItemID,
            sources: store.sources,
            bookmarks: store.bookmarks,
            databaseInfo: store.databaseInfo,
            totalCount: store.totalCount,
            libraryViewModel: libraryViewModel
        )
        .navigationSplitViewColumnWidth(min: 240, ideal: 270, max: 320)
    }

    private var centerTable: some View {
        DesignMockThreadTablePane(
            conversations: store.conversations,
            selection: $selectedConversationIDs,
            sortOrder: tableSortOrderBinding,
            isLoadingMore: store.isLoadingMore,
            onReachEnd: {
                store.loadMoreIfNeeded(services: services)
            },
            // Double-click / Return: promote into default mode so the
            // reader pane appears alongside the now-smaller table. The
            // selection is already set by the table's primaryAction
            // callback, so the reader has the right conversation queued
            // up when default mode mounts.
            onOpen: { _ in
                selectedLayoutMode = .default
            }
        )
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
    let bookmarks: [DesignMockBookmark]
    let databaseInfo: DesignMockDataStore.DatabaseInfo?
    let totalCount: Int
    /// Shared library VM. Kept optional because it's built lazily in
    /// the shell; upcoming HISTORY / prompt-bookmark surfaces read from
    /// it, so we thread it through even though the sidebar doesn't use
    /// it yet in this transition state.
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
            subtitle: bookmarks.isEmpty ? nil : "\(bookmarks.count) saved",
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

            // The Tags section used to live here. It was removed in the
            // "ditch tags, embrace search history" redesign — Phase 3
            // of that work will mount the query-history list (backed by
            // `LibraryViewModel.unifiedFilters`) in its place.
        }
        .listStyle(.sidebar)
        .onChange(of: sources.map(\.name)) { _, _ in
            seedExpansionIfNeeded()
        }
        .onAppear {
            seedExpansionIfNeeded()
        }
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
        // The list is now a lightly-shaded "tray" that hosts discrete
        // white cards — previously the whole pane was `.regularMaterial`
        // gray, and the rows sat directly on it with no chrome, which
        // made the copy hard to read at the default body font. Two
        // changes:
        //   1. Hide List's own row styling (separators / inset padding)
        //      so each row can own its card-like frame end-to-end.
        //   2. Paint the List container with the window's content
        //      background (light gray in Light Mode, dark in Dark)
        //      so the white cards actually contrast against their
        //      tray. Without this, the cards float on the default
        //      list background and read as "unchanged".
        //
        // `List(selection:)` with a `Set` binding is what enables
        // native ⌘/⇧-click multi-select. Rows still need `.tag(id)`
        // for SwiftUI to bind selection to our id type.
        List(selection: $selection) {
            ForEach(conversations) { conversation in
                DesignMockConversationListRow(conversation: conversation)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        // True card: opaque white fill in Light Mode
                        // (`textBackgroundColor` is the same token the
                        // reader pane uses, so a card reads as "a
                        // miniature document"), with a thin
                        // hairline-style stroke and a soft drop
                        // shadow. Selection tint is layered on TOP
                        // via `.overlay` so the white base survives.
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color(nsColor: .textBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(cardSelectionTint(for: conversation))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(
                                selection.contains(conversation.id)
                                    ? Color.accentColor.opacity(0.55)
                                    : Color.primary.opacity(0.08),
                                lineWidth: selection.contains(conversation.id) ? 1.5 : 0.5
                            )
                    )
                    .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
                    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    // Double-click expands the prompt outline so the
                    // native List selection gesture (single / ⌘ / ⇧
                    // clicks) stays intact. Previously expansion was
                    // tied to single-tap, which pre-empted multi-
                    // select entirely.
                    .onTapGesture(count: 2) {
                        withAnimation(.easeOut(duration: 0.16)) {
                            expandedPromptConversationID = conversation.id
                            selection = [conversation.id]
                        }
                    }
                    // Kill the List's default row chrome — insets /
                    // separators / row background. We're painting the
                    // entire card ourselves now, so any residual
                    // affordance from `List` would either double up
                    // (separators cutting through cards) or bleed
                    // (accent-tinted row background leaking around
                    // the corner radius).
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 5, leading: 10, bottom: 5, trailing: 10))
                    .tag(conversation.id)
                    .onAppear {
                        // Trigger pagination when the last row scrolls into view.
                        // `id == last?.id` keeps us from paging on every row and
                        // also means mid-list scrolls don't thrash the fetcher.
                        if conversation.id == conversations.last?.id {
                            onReachEnd()
                        }
                    }
            }
            if isLoadingMore {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// Translucent accent wash layered over a card's white base when
    /// selected. Kept as a separate overlay (rather than replacing the
    /// fill) so the white card background shows through — selection
    /// reads as "tinted paper" instead of "solid accent panel", which
    /// better matches how Finder / Notes flag a selected item.
    private func cardSelectionTint(for conversation: DesignMockConversation) -> Color {
        selection.contains(conversation.id)
            ? Color.accentColor.opacity(0.14)
            : Color.clear
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

private struct DesignMockDefaultContentPane: View {
    @Binding var displayMode: DesignMockCenterDisplayMode
    let conversations: [DesignMockConversation]
    @Binding var conversationSelection: Set<DesignMockConversation.ID>
    @Binding var pendingPromptID: String?
    @Binding var expandedPromptConversationID: DesignMockConversation.ID?
    /// Forwarded from the shell — shared with the search-field DSL so
    /// the table inside this pane round-trips column-header taps into
    /// the toolbar query text just like the standalone table layout.
    @Binding var tableSortOrder: [KeyPathComparator<DesignMockConversation>]
    let totalCount: Int
    let isLoading: Bool
    let isLoadingMore: Bool
    let lastError: String?
    let onReachEnd: () -> Void

    var body: some View {
        VStack(spacing: 0) {
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

                // Count / load status. Keeps "searching 1,429 threads" info
                // visible at the top of the pane so the user knows when a
                // keyword query is narrowing vs. when it's still loading.
                if isLoading && conversations.isEmpty {
                    ProgressView()
                        .controlSize(.small)
                }

                Text(countLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            if let lastError {
                Text(lastError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)
            }

            Divider()

            contentView
        }
    }

    private var countLabel: String {
        let loaded = conversations.count
        if totalCount > loaded {
            return "\(loaded) / \(totalCount)"
        }
        return "\(loaded)"
    }

    @ViewBuilder
    private var contentView: some View {
        switch displayMode {
        case .table:
            DesignMockThreadTablePane(
                conversations: conversations,
                selection: $conversationSelection,
                sortOrder: $tableSortOrder,
                isLoadingMore: isLoadingMore,
                onReachEnd: onReachEnd
            )
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
        return Table(rows, selection: $selection, sortOrder: $sortOrder) {
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
            .width(min: 200, ideal: 320)

            TableColumn("Model", value: \DesignMockConversation.model) { conversation in
                Text(conversation.model)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(min: 80, ideal: 140, max: 240)

            // Date column sorts by `sortRank` rather than the display
            // string — the latter is pre-formatted, so lexicographic
            // order wouldn't be chronological.
            TableColumn("Updated", value: \DesignMockConversation.sortRank) { conversation in
                Text(conversation.updated)
                    .foregroundStyle(.secondary)
            }
            .width(82)

            TableColumn("Prompts", value: \DesignMockConversation.prompts) { conversation in
                Text("\(conversation.prompts)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(70)

            TableColumn("Source", value: \DesignMockConversation.source) { conversation in
                Text(conversation.source)
                    .foregroundStyle(conversation.sourceColor)
            }
            .width(82)
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
        Button {
            // Fire the id — the reader observes this binding and scrolls to
            // the matching message. `ConversationDetailView` clears the
            // binding back to nil after applying, so reassigning the same
            // id later still triggers a fresh scroll.
            pendingPromptID = prompt.id
            selectedPromptID = prompt.id
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "text.bubble")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(width: 18)

                Text(prompt.snippet)
                    .font(.subheadline)
                    .lineLimit(1)
                    .foregroundStyle(.primary)

                Spacer(minLength: 8)

                Text("\(prompt.index + 1)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                rowBackground(for: prompt),
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredPromptID = hovering ? prompt.id : (hoveredPromptID == prompt.id ? nil : hoveredPromptID)
        }
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
    @Binding var pendingPromptID: String?
    /// Two-way binding into the shell's search text — non-nil only in
    /// focus mode. When present the reader renders a find-in-page bar
    /// that both reads and writes this binding (so clearing from either
    /// side stays in sync) and drives scroll-to-match on `pendingPromptID`.
    private let inThreadSearch: Binding<String>?

    /// Message IDs (in transcript order) that contain the current
    /// in-thread query. Refreshed whenever the conversation or the query
    /// changes. Empty when there's no query or no matches.
    @State private var matchIDs: [String] = []
    /// Which match is currently centered in the reader. Clamped to
    /// `matchIDs.indices` — reset to 0 when the list changes.
    @State private var currentMatchIndex: Int = 0
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
                            matchCount: matchIDs.count,
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

    /// The spec handed to `ConversationDetailView` for keyword-level
    /// highlighting. `nil` when there's nothing to paint, so the reader
    /// stays in its no-op path. The active message id comes from the
    /// find bar's "N / M" cursor so the currently-centered match is
    /// drawn in a hotter color than the rest.
    private var currentSearchHighlight: SearchHighlightSpec? {
        let q = effectiveQuery
        guard !q.isEmpty else { return nil }
        let active: String? = matchIDs.indices.contains(currentMatchIndex)
            ? matchIDs[currentMatchIndex]
            : nil
        return SearchHighlightSpec(query: q, activeMessageID: active)
    }

    /// Fetch the conversation detail, scan every message for a
    /// case-insensitive substring match on the query, and publish the
    /// resulting ids. Also fires the first jump so the reader snaps to
    /// match #1 without the user having to tap Next.
    private func recomputeMatches() async {
        let query = effectiveQuery
        guard !query.isEmpty, let convo = conversation else {
            await MainActor.run {
                matchIDs = []
                currentMatchIndex = 0
            }
            return
        }
        do {
            guard let detail = try await services.conversations.fetchDetail(id: convo.id) else {
                await MainActor.run {
                    matchIDs = []
                    currentMatchIndex = 0
                }
                return
            }
            // Case-insensitive, diacritic-insensitive substring scan. We
            // intentionally don't tokenize — the user's mental model for
            // an in-thread finder is "literal substring", matching ⌘F in
            // every text editor.
            let needle = query.lowercased()
            let ids: [String] = detail.messages.compactMap { message in
                message.content.lowercased().contains(needle) ? message.id : nil
            }
            await MainActor.run {
                matchIDs = ids
                currentMatchIndex = 0
                // Auto-jump to the first match so the user sees feedback
                // immediately on typing.
                if let first = ids.first {
                    pendingPromptID = first
                }
            }
        } catch {
            // Silent — this is a mock shell, and a failed fetch just
            // means "no navigator shown" rather than a hard error.
            await MainActor.run {
                matchIDs = []
                currentMatchIndex = 0
            }
        }
    }

    /// Move the active match index by `delta`, wrapping around the ends
    /// of the list, then fire `pendingPromptID` so the underlying
    /// `ConversationDetailView` scrolls to it.
    private func stepMatch(by delta: Int) {
        guard !matchIDs.isEmpty else { return }
        let count = matchIDs.count
        let next = ((currentMatchIndex + delta) % count + count) % count
        currentMatchIndex = next
        pendingPromptID = matchIDs[next]
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
        case .bookmarks:
            AnyShapeStyle(.yellow)
        case .tag:
            AnyShapeStyle(.purple)
        default:
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
