import Observation
import SwiftUI

@MainActor
@Observable
final class LibraryViewModel {
    var filter = ArchiveSearchFilter()
    var conversations: [ConversationSummary] = []
    var sourceFacets: [LibrarySourceFacet] = []
    /// Per-imported-JSON-file facets shown under the sidebar's archive.db
    /// entry. Pre-filtered list of `FilterOption` so checkbox selection state
    /// can be rendered without re-evaluating the filter for each row.
    var sourceFileFacets: [LibrarySourceFileFacet] = []
    var recentFilters: [SavedFilterEntry] = []
    var savedViews: [SavedViewEntry] = []
    /// Unified filter history (pinned first, then recent, capped to 20).
    /// This supersedes `recentFilters` + `savedViews` in the new sidebar UI;
    /// the old properties remain populated for legacy call sites.
    var unifiedFilters: [SavedFilterEntry] = []
    var pendingSavedViewName: String = ""
    /// All conversations currently selected in the middle pane. This is the
    /// storage; the single-valued `selectedConversationId` below is a thin
    /// writable bridge for the many existing call-sites (detail pane,
    /// keyboard next/prev, sidebar refresh triggers) that still think in
    /// terms of "the selected conversation".
    ///
    /// We store this as a `Set` instead of an `Array` because the macOS
    /// `List(selection:)` binding for multi-select demands a `Set`, and
    /// because every existing consumer either asks for "is X selected"
    /// (set-friendly) or "give me one" (via `first`).
    var selectedConversationIDs: Set<String> = []

    /// One-shot signal asking the middle-pane list to scroll a specific
    /// conversation row to the top. Set by the right-pane header's
    /// conversation-title button (tap = "take me back to where this
    /// conversation lives in the list"). `UnifiedConversationListView`
    /// observes via `.onChange`, calls `ScrollViewProxy.scrollTo(id,
    /// anchor: .top)`, and clears it. The companion reader-side scroll
    /// lives on `ReaderTabManager.scrollToTopToken` — both are fired
    /// together from the same tap.
    var pendingListScrollConversationID: String?

    /// Single-selection compatibility shim over `selectedConversationIDs`.
    /// Reads return an arbitrary member (stable enough in practice because
    /// SwiftUI's List only populates multi-selection via user action, and
    /// we always collapse programmatic selections back to a single id).
    /// Writes replace the set wholesale — any nil clears it, any value
    /// becomes the sole selection.
    var selectedConversationId: String? {
        get { selectedConversationIDs.first }
        set {
            if let newValue {
                selectedConversationIDs = [newValue]
            } else {
                selectedConversationIDs = []
            }
        }
    }
    var sortKey: ConversationSortKey = .dateDesc
    var isLoading: Bool = false
    var isLoadingMore: Bool = false
    var totalCount: Int = 0
    var overallCount: Int = 0
    var bookmarkCount: Int = 0
    var errorText: String?
    /// Tags attached to each listed conversation (thread + prompt-level unioned).
    /// Keyed by conversation id; used to render chip strips on each card.
    var conversationTags: [String: [TagEntry]] = [:]

    // MARK: - Viewer-mode conversation state
    //
    // Viewer Mode is a focused "reading" layout driven by the **right-pane
    // toolbar** (see `ReaderWorkspaceView.ViewerModeToggleButton`). When it
    // activates, the middle pane swaps from the scrolling card list to a
    // dedicated view that sticks the currently-open conversation's card at
    // the top and lists its prompt outline below as a flat index. Unlike
    // the old per-card pin, this state is not chosen by clicking a card —
    // it follows whichever conversation is active in the reader. Only one
    // conversation is tracked at a time; switching the active reader tab
    // replaces the state. The mode is intentionally volatile (lives only
    // for the app session) — no DB schema change.
    private(set) var viewerConversationID: String?
    private(set) var viewerDetail: ConversationDetail?
    private(set) var viewerPromptOutline: [ConversationPromptOutlineItem] = []
    private(set) var isLoadingViewerDetail = false

    private let conversationRepository: any ConversationRepository
    private let searchRepository: any SearchRepository
    private let bookmarkRepository: any BookmarkRepository
    private let viewService: any ViewService
    private let tagRepository: (any TagRepository)?
    private let pageSize = 100
    private var hasMorePages = true
    private var debounceTask: Task<Void, Never>?

    init(
        conversationRepository: any ConversationRepository,
        searchRepository: any SearchRepository,
        bookmarkRepository: any BookmarkRepository,
        viewService: any ViewService,
        tagRepository: (any TagRepository)? = nil
    ) {
        self.conversationRepository = conversationRepository
        self.searchRepository = searchRepository
        self.bookmarkRepository = bookmarkRepository
        self.viewService = viewService
        self.tagRepository = tagRepository
    }

    var searchText: String {
        get { filter.keyword }
        set { updateSearchText(newValue) }
    }

    var selectedRoles: [MessageRole] {
        filter.roles.sorted { $0.rawValue < $1.rawValue }
    }

    var hasActiveFilters: Bool {
        filter.hasMeaningfulFilters
    }

    var canSaveCurrentView: Bool {
        filter.hasMeaningfulFilters
    }

    func loadIfNeeded() async {
        guard conversations.isEmpty && !isLoading else {
            return
        }

        await reload()
    }

    func reload() async {
        debounceTask?.cancel()
        await reloadNow(saveRecent: filter.hasMeaningfulFilters)
    }

    func reloadSupportingState() async {
        await refreshSidebarState()
        await refreshSavedEntries()
        await refreshBookmarkCount()
    }

    func updateSearchText(_ text: String) {
        filter.keyword = text
        scheduleReload()
    }

    func toggleSource(_ source: String) {
        if filter.sources.contains(source) {
            filter.sources.remove(source)
        } else {
            filter.sources.insert(source)
        }
        scheduleReload()
    }

    func toggleModel(_ model: String) {
        if filter.models.contains(model) {
            filter.models.remove(model)
        } else {
            filter.models.insert(model)
        }
        scheduleReload()
    }

    func toggleSourceFile(_ path: String) {
        if filter.sourceFiles.contains(path) {
            filter.sourceFiles.remove(path)
        } else {
            filter.sourceFiles.insert(path)
        }
        scheduleReload()
    }

    func setBookmarkScope(_ bookmarkedOnly: Bool) {
        guard filter.bookmarkedOnly != bookmarkedOnly else {
            return
        }

        filter.bookmarkedOnly = bookmarkedOnly
        scheduleReload()
    }

    func toggleSortDirection() {
        sortKey = (sortKey == .dateDesc) ? .dateAsc : .dateDesc
        scheduleReload()
    }

    /// Replace the sort key with `newKey` and reload. No-op if already set.
    /// Powers the full sort picker in the middle-pane header bar — users
    /// choose between date (asc/desc) and prompt count (asc/desc).
    func setSortKey(_ newKey: ConversationSortKey) {
        guard sortKey != newKey else { return }
        sortKey = newKey
        scheduleReload()
    }

    func toggleBookmarkTag(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }

        if let existing = filter.bookmarkTags.firstIndex(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            filter.bookmarkTags.remove(at: existing)
        } else {
            filter.bookmarkTags.append(trimmed)
        }
        scheduleReload()
    }

    func removeBookmarkTag(_ name: String) {
        guard let index = filter.bookmarkTags.firstIndex(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else {
            return
        }

        filter.bookmarkTags.remove(at: index)
        scheduleReload()
    }

    func clearBookmarkTagFilters() {
        guard !filter.bookmarkTags.isEmpty else {
            return
        }

        filter.bookmarkTags.removeAll()
        scheduleReload()
    }

    var activeFilterChips: [LibraryActiveFilterChip] {
        var chips: [LibraryActiveFilterChip] = []

        if !filter.normalizedKeyword.isEmpty {
            chips.append(.init(kind: .keyword, label: "“\(filter.normalizedKeyword)”"))
        }
        // When a model is selected its pill already carries the parent
        // service's brand color — a separate `chatgpt` chip alongside a
        // `gpt-4o` chip is visually redundant. Suppress the source chip
        // whenever its service equals the inferred service of any selected
        // model. (Cross-family selections like `claude` + `gpt-4o` are
        // preserved: `claude` doesn't match gpt-4o's inferred `chatgpt`.)
        let suppressedSources: Set<String> = Set(
            filter.models.compactMap { SourceAppearance.inferredSource(forModel: $0) }
        )
        for source in filter.sources.sorted()
        where !suppressedSources.contains(source.lowercased()) {
            chips.append(.init(kind: .source(source), label: source))
        }
        for model in filter.models.sorted() {
            chips.append(.init(kind: .model(model), label: model))
        }
        for file in filter.sourceFiles.sorted() {
            chips.append(.init(
                kind: .sourceFile(file),
                label: (file as NSString).lastPathComponent
            ))
        }
        if let dateFrom = filter.dateFrom, !dateFrom.isEmpty {
            chips.append(.init(kind: .dateFrom, label: "≥ \(dateFrom)"))
        }
        if let dateTo = filter.dateTo, !dateTo.isEmpty {
            chips.append(.init(kind: .dateTo, label: "≤ \(dateTo)"))
        }
        for role in filter.roles.sorted(by: { $0.rawValue < $1.rawValue }) {
            chips.append(.init(kind: .role(role), label: role.displayName))
        }
        if filter.bookmarkedOnly {
            chips.append(.init(kind: .bookmarkedOnly, label: "Bookmarked"))
        }
        for tag in filter.bookmarkTags {
            chips.append(.init(kind: .bookmarkTag(tag), label: "#\(tag)"))
        }

        return chips
    }

    func clearFilterChip(_ chip: LibraryActiveFilterChip) {
        switch chip.kind {
        case .keyword:
            updateSearchText("")
        case .source(let value):
            toggleSource(value)
        case .model(let value):
            toggleModel(value)
        case .sourceFile(let value):
            toggleSourceFile(value)
        case .dateFrom:
            applyDateFrom("")
        case .dateTo:
            applyDateTo("")
        case .role(let role):
            toggleRole(role)
        case .bookmarkedOnly:
            setBookmarkScope(false)
        case .bookmarkTag(let tag):
            removeBookmarkTag(tag)
        }
    }

    func toggleRole(_ role: MessageRole) {
        if filter.roles.contains(role) {
            filter.roles.remove(role)
        } else {
            filter.roles.insert(role)
        }
        scheduleReload()
    }

    func applyDateFrom(_ rawValue: String) {
        let normalized = normalizeOptionalText(rawValue)
        guard filter.dateFrom != normalized else {
            return
        }

        filter.dateFrom = normalized
        scheduleReload()
    }

    func applyDateTo(_ rawValue: String) {
        let normalized = normalizeOptionalText(rawValue)
        guard filter.dateTo != normalized else {
            return
        }

        filter.dateTo = normalized
        scheduleReload()
    }

    func clearFilters() {
        guard filter.hasMeaningfulFilters else {
            return
        }

        filter = ArchiveSearchFilter()
        Task { await reloadNow(saveRecent: false) }
    }

    func applySavedFilter(_ entry: SavedFilterEntry) {
        filter = entry.filters
        pendingSavedViewName = entry.name
        Task { await reloadNow(saveRecent: false) }
    }

    func saveCurrentView() {
        let name = pendingSavedViewName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            return
        }

        Task {
            do {
                _ = try await viewService.saveSavedView(
                    name: name,
                    filters: filter,
                    targetType: .virtualThread,
                    id: nil
                )
                pendingSavedViewName = ""
                await refreshSavedEntries()
            } catch {
                errorText = error.localizedDescription
            }
        }
    }

    func deleteSavedView(_ entry: SavedViewEntry) {
        Task {
            do {
                _ = try await viewService.deleteSavedView(id: entry.id, targetType: entry.targetType)
                await refreshSavedEntries()
            } catch {
                errorText = error.localizedDescription
            }
        }
    }

    func loadMoreIfNeeded(currentItem: ConversationSummary) async {
        guard hasMorePages, !isLoadingMore else {
            return
        }

        let thresholdIndex = conversations.index(
            conversations.endIndex,
            offsetBy: -5,
            limitedBy: conversations.startIndex
        ) ?? conversations.startIndex

        guard let currentIndex = conversations.firstIndex(where: { $0.id == currentItem.id }),
              currentIndex >= thresholdIndex else {
            return
        }

        isLoadingMore = true
        defer { isLoadingMore = false }

        do {
            let nextPage = try await fetchPage(offset: conversations.count)
            conversations.append(contentsOf: nextPage)
            hasMorePages = conversations.count < totalCount
            await refreshConversationTags(for: nextPage.map(\.id), replace: false)
        } catch {
            errorText = error.localizedDescription
        }
    }

    /// Page forward through the current filtered result set until the
    /// requested conversation id is loaded into `conversations`, then
    /// raise the "scroll to this row" one-shot so the middle-pane list's
    /// `ScrollViewReader` can bring it into view. Called from the
    /// right-pane title tap — after a sort / filter change, the card
    /// may have fallen off the currently-loaded window (all paging is
    /// forward-only from offset 0), and `ScrollViewProxy.scrollTo(id)`
    /// is a no-op when the id isn't in the List's dataset. Paging
    /// forward one chunk at a time lets the list grow just enough to
    /// include the target.
    ///
    /// Gives up after a sanity-capped number of attempts so we never
    /// spin if the id genuinely isn't in the filtered set (e.g. the
    /// active filter excluded it). The cap is generous — 50 pages at
    /// the default page size — because the common case is "a handful
    /// of pages past the end of what's loaded".
    func revealConversation(id: String) async {
        // Fast path: already loaded → just raise the scroll request.
        if conversations.contains(where: { $0.id == id }) {
            pendingListScrollConversationID = id
            return
        }

        var attempts = 0
        while hasMorePages,
              attempts < 50,
              !conversations.contains(where: { $0.id == id }) {
            attempts += 1
            isLoadingMore = true
            do {
                let nextPage = try await fetchPage(offset: conversations.count)
                // Empty page with `hasMorePages` still true would be a
                // totalCount/page mismatch — bail rather than loop forever.
                if nextPage.isEmpty {
                    hasMorePages = false
                    isLoadingMore = false
                    break
                }
                conversations.append(contentsOf: nextPage)
                hasMorePages = conversations.count < totalCount
                await refreshConversationTags(for: nextPage.map(\.id), replace: false)
            } catch {
                errorText = error.localizedDescription
                isLoadingMore = false
                return
            }
            isLoadingMore = false
        }

        if conversations.contains(where: { $0.id == id }) {
            pendingListScrollConversationID = id
        }
    }

    /// Page through the entire current filtered set in one go so the
    /// table view can render every row without relying on the infinite-
    /// scroll trigger. The normal list view pulls the next page from a
    /// `.onAppear` on the tail-most cell, which never fires when the
    /// container is a `SwiftUI.Table` (rows aren't mounted the same way
    /// as a `List`). Bulk-loading sidesteps that entirely — the user
    /// asked for "全部表示" in the table, so we pay the up-front fetch.
    ///
    /// Always begins with a fresh `reload()` so the bulk walk starts
    /// from the FIRST page of the CURRENT filter/sort. Without this,
    /// the bulk walk raced the debounced `reloadNow()` that sidebar
    /// checkbox clicks schedule: `reloadNow()` would replace
    /// `conversations` with the new filter's first page while we
    /// were paging against the OLD filter, and the table ended up
    /// showing only the most-recent page (the reported "両方
    /// チェックしてるのに片方しか出てこない" symptom — claude rows
    /// existed but lived past the first page so they never loaded
    /// when the gpt-4o filter was added on top).
    ///
    /// Snapshots `(filter, sortKey)` on entry and bails if either
    /// changes mid-walk; the next caller (driven by the table view's
    /// `.task(id:)` modifier) will restart the walk against the new
    /// filter.
    func loadAllConversations() async {
        // Serialize concurrent callers. SwiftUI may fire the table
        // view's `.task(id:)` again before a previous walk has
        // settled — wait for the in-flight walk to release
        // `isLoadingMore` before claiming it ourselves so we don't
        // double-write the conversations array.
        while isLoadingMore {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        // Cancels any pending debounced reload and runs `reloadNow()`
        // synchronously, so `conversations` / `totalCount` /
        // `hasMorePages` reflect the current filter's first page
        // before we decide how many more to walk.
        await reload()

        let snapshotFilter = filter
        let snapshotSort = sortKey

        guard hasMorePages else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }

        // Unbounded loop with a hard sanity cap (totalCount is known
        // upfront, so ceiling = ceil(total/pageSize) + a small margin).
        // Empty page with `hasMorePages` still true means a totalCount
        // mismatch — bail rather than spin.
        let maxIterations = max(1, (totalCount / pageSize) + 2)
        var iterations = 0
        while hasMorePages, iterations < maxIterations {
            // Filter / sort changed since we started the walk — discard
            // the rest. The new `.task(id:)` invocation will restart.
            guard filter == snapshotFilter, sortKey == snapshotSort else {
                return
            }
            iterations += 1
            do {
                let nextPage = try await fetchPage(offset: conversations.count)
                // Recheck after the suspension: a parallel `reloadNow()`
                // may have replaced `conversations` while we awaited
                // GRDB. If filter/sort still match, the offset is still
                // valid; if not, drop the page and let the new walk
                // take over.
                guard filter == snapshotFilter, sortKey == snapshotSort else {
                    return
                }
                if nextPage.isEmpty {
                    hasMorePages = false
                    break
                }
                conversations.append(contentsOf: nextPage)
                hasMorePages = conversations.count < totalCount
                await refreshConversationTags(for: nextPage.map(\.id), replace: false)
            } catch is CancellationError {
                // `.task(id:)` cancelled us in favor of a fresh walk —
                // exit silently so we don't surface a phantom error.
                return
            } catch {
                errorText = error.localizedDescription
                return
            }
        }
    }

    func summary(for conversationID: String?) -> ConversationSummary? {
        guard let conversationID else {
            return nil
        }

        return conversations.first(where: { $0.id == conversationID })
    }

    // MARK: - Viewer-mode actions

    /// Load a conversation into viewer-mode state. Fetches the full
    /// `ConversationDetail` so we can build the prompt outline locally;
    /// this is the same detail the right pane fetches when opening a
    /// conversation, so it's almost always cache-warm by the time viewer
    /// mode needs it. If the requested ID is already loaded, this is a
    /// no-op so toggling viewer mode back on or firing redundant
    /// `onChange` callbacks doesn't thrash the state.
    func loadViewerConversation(id conversationID: String) async {
        if viewerConversationID == conversationID, viewerDetail != nil {
            return
        }
        viewerConversationID = conversationID
        viewerDetail = nil
        viewerPromptOutline = []
        isLoadingViewerDetail = true
        defer { isLoadingViewerDetail = false }
        do {
            guard let detail = try await conversationRepository.fetchDetail(id: conversationID) else {
                errorText = "Conversation not found"
                viewerConversationID = nil
                return
            }
            // Ignore if viewer target changed mid-fetch (tab swap).
            guard viewerConversationID == conversationID else { return }
            viewerDetail = detail
            viewerPromptOutline = ConversationDetailView.promptOutline(for: detail)
        } catch {
            errorText = error.localizedDescription
            viewerConversationID = nil
        }
    }

    /// Clear viewer-mode state when exiting the mode.
    func clearViewerData() {
        viewerConversationID = nil
        viewerDetail = nil
        viewerPromptOutline = []
    }

    func setBookmarkState(for conversationID: String, isBookmarked: Bool) {
        conversations = conversations.map { conversation in
            guard conversation.id == conversationID else {
                return conversation
            }

            return ConversationSummary(
                id: conversation.id,
                headline: conversation.headline,
                source: conversation.source,
                title: conversation.title,
                model: conversation.model,
                messageCount: conversation.messageCount,
                primaryTime: conversation.primaryTime,
                isBookmarked: isBookmarked
            )
        }

        bookmarkCount += isBookmarked ? 1 : -1
        bookmarkCount = max(0, bookmarkCount)
    }

    func selectNext() {
        guard !conversations.isEmpty else {
            return
        }

        if let selectedConversationId,
           let index = conversations.firstIndex(where: { $0.id == selectedConversationId }),
           index + 1 < conversations.count {
            self.selectedConversationId = conversations[index + 1].id
        } else {
            selectedConversationId = conversations.first?.id
        }
    }

    func selectPrevious() {
        guard !conversations.isEmpty else {
            return
        }

        if let selectedConversationId,
           let index = conversations.firstIndex(where: { $0.id == selectedConversationId }),
           index > 0 {
            self.selectedConversationId = conversations[index - 1].id
        } else {
            selectedConversationId = conversations.last?.id
        }
    }

    func searchTextBinding() -> Binding<String> {
        Binding(
            get: { self.filter.keyword },
            set: { self.updateSearchText($0) }
        )
    }

    func pendingSavedViewNameBinding() -> Binding<String> {
        Binding(
            get: { self.pendingSavedViewName },
            set: { self.pendingSavedViewName = $0 }
        )
    }

    func dateFromBinding() -> Binding<String> {
        Binding(
            get: { self.filter.dateFrom ?? "" },
            set: { self.applyDateFrom($0) }
        )
    }

    func dateToBinding() -> Binding<String> {
        Binding(
            get: { self.filter.dateTo ?? "" },
            set: { self.applyDateTo($0) }
        )
    }

    private func scheduleReload() {
        debounceTask?.cancel()

        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else {
                return
            }

            await self?.reloadNow(saveRecent: self?.filter.hasMeaningfulFilters ?? false)
        }
    }

    private func reloadNow(saveRecent: Bool) async {
        isLoading = true
        errorText = nil
        defer { isLoading = false }

        let selectedID = selectedConversationId

        do {
            async let pageTask = fetchPage(offset: 0)
            async let filteredCountTask = fetchFilteredCount()
            async let overallCountTask = conversationRepository.count(
                query: ConversationListQuery(offset: 0, limit: 1)
            )
            async let sidebarTask = loadSourceFacets()
            async let sourceFileTask = loadSourceFileFacets()
            async let savedEntriesTask = loadSavedEntries()
            async let bookmarkCountTask = bookmarkRepository.listBookmarks()

            let page = try await pageTask
            let filteredCount = try await filteredCountTask
            let overallCount = try await overallCountTask
            let facets = try await sidebarTask
            let sourceFiles = try await sourceFileTask
            let savedEntries = try await savedEntriesTask
            let bookmarks = try await bookmarkCountTask

            if saveRecent {
                _ = try await viewService.saveRecentFilter(filters: filter, targetType: .virtualThread)
            }

            self.conversations = page
            self.totalCount = filteredCount
            self.overallCount = overallCount
            self.sourceFacets = facets
            self.sourceFileFacets = sourceFiles
            self.recentFilters = savedEntries.recent
            self.savedViews = savedEntries.saved
            // Refresh the unified (pinned + recent) list too. This drives
            // the sidebar "Filters" section; without this refresh, rows
            // saved by `saveRecentFilter` above landed in the DB but the
            // in-memory array the sidebar reads stayed stale — users
            // reported that toggling a model (or any filter) wouldn't
            // show up under Filters until the next app launch /
            // `refreshSavedEntries()` trigger.
            if saveRecent {
                self.unifiedFilters = try await viewService.listUnifiedFilters(
                    targetType: .virtualThread,
                    limit: 20
                )
            }
            self.bookmarkCount = bookmarks.count
            self.hasMorePages = page.count < filteredCount

            self.filter.models = self.filter.models.intersection(
                Set(facets.flatMap { $0.models.map(\.value) })
            )
            // Drop stale source-file filters that no longer match any known
            // file — prevents "ghost" checkboxes lingering after imports
            // swap the set of source files out from under us.
            self.filter.sourceFiles = self.filter.sourceFiles.intersection(
                Set(sourceFiles.map(\.path))
            )

            // Selection preservation policy: once the user has picked a
            // conversation, keep that selection across reloads even if
            // the card falls off the current page (e.g. after changing
            // sort order, applying a filter, or paging). Previously the
            // `else` branch yanked selection to `page.first?.id`, which
            // cascaded into `MacOSRootView`'s
            // `onChange(of: selectedConversationId)` and silently swapped
            // the right-pane reader to a conversation the user never
            // asked for — reported as "ソートを変更しても右ペインが
            // 勝手に切り替わる". First-load fallback still stands: when
            // `selectedID` is nil we seed with `page.first?.id` so the
            // reader has something to show the moment the app opens.
            if let selectedID {
                self.selectedConversationId = selectedID
            } else {
                self.selectedConversationId = page.first?.id
            }

            await refreshConversationTags(for: page.map(\.id), replace: true)
        } catch {
            self.errorText = error.localizedDescription
            self.conversations = []
            self.totalCount = 0
            self.hasMorePages = false
            self.conversationTags = [:]
        }
    }

    /// Fetch tag bindings for the given conversation ids and merge them into
    /// `conversationTags`. When `replace` is true, the map is replaced
    /// wholesale (used on full reload); otherwise only the listed ids are
    /// updated (used when paginating).
    func refreshConversationTags(for ids: [String], replace: Bool) async {
        guard let tagRepository else {
            if replace { conversationTags = [:] }
            return
        }

        guard !ids.isEmpty else {
            if replace { conversationTags = [:] }
            return
        }

        do {
            let bindings = try await tagRepository.bindings(forConversationIDs: ids)
            if replace {
                var fresh: [String: [TagEntry]] = [:]
                for id in ids {
                    if let tags = bindings[id]?.tags, !tags.isEmpty {
                        fresh[id] = tags
                    }
                }
                conversationTags = fresh
            } else {
                for id in ids {
                    let tags = bindings[id]?.tags ?? []
                    if tags.isEmpty {
                        conversationTags.removeValue(forKey: id)
                    } else {
                        conversationTags[id] = tags
                    }
                }
            }
        } catch {
            // Non-fatal — cards simply won't display tags.
        }
    }

    /// Re-fetch tag bindings for every currently loaded conversation. Call
    /// after an attach/detach to keep cards in sync.
    func refreshAllConversationTags() async {
        await refreshConversationTags(for: conversations.map(\.id), replace: true)
    }

    /// Attach a tag by name to the given conversation. Creates the tag if it
    /// does not exist yet. Used by drag-and-drop from the sidebar and by the
    /// sidebar tag row's + button.
    func attachTag(named name: String, toConversation conversationID: String) async {
        guard let tagRepository else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let summary = summary(for: conversationID) else { return }

        do {
            let tag: TagEntry
            if let existing = try await tagRepository.findTagByName(trimmed) {
                tag = existing
            } else {
                tag = try await tagRepository.createTag(name: trimmed)
            }
            var payload: [String: String] = ["title": summary.displayTitle]
            if let source = summary.source { payload["source"] = source }
            if let model = summary.model { payload["model"] = model }
            _ = try await tagRepository.attachTag(
                tagID: tag.id,
                toConversationID: conversationID,
                payload: payload
            )
            setBookmarkState(for: conversationID, isBookmarked: true)
            await refreshConversationTags(for: [conversationID], replace: false)
        } catch {
            errorText = error.localizedDescription
        }
    }

    /// Detach a tag by name from the given conversation.
    func detachTag(named name: String, fromConversation conversationID: String) async {
        guard let tagRepository else { return }
        do {
            guard let tag = try await tagRepository.findTagByName(name) else { return }
            try await tagRepository.detachTag(tagID: tag.id, fromConversationID: conversationID)
            await refreshConversationTags(for: [conversationID], replace: false)
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func refreshSidebarState() async {
        do {
            async let facets = loadSourceFacets()
            async let files = loadSourceFileFacets()
            sourceFacets = try await facets
            sourceFileFacets = try await files
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func refreshSavedEntries() async {
        do {
            let entries = try await loadSavedEntries()
            recentFilters = entries.recent
            savedViews = entries.saved
            unifiedFilters = try await viewService.listUnifiedFilters(
                targetType: .virtualThread,
                limit: 20
            )
        } catch {
            errorText = error.localizedDescription
        }
    }

    /// Toggle the pinned flag of a saved_filters row (from the unified list's
    /// hover pin icon).
    func togglePinned(_ entry: SavedFilterEntry) {
        Task {
            do {
                _ = try await viewService.togglePinnedFilter(
                    id: entry.id,
                    targetType: entry.targetType
                )
                await refreshSavedEntries()
            } catch {
                errorText = error.localizedDescription
            }
        }
    }

    /// Record a query the user ran in the DesignMock shell (or any
    /// surface that doesn't funnel its filter through `LibraryViewModel.filter`)
    /// as a recent-filter row in the shared DB, then refresh
    /// `unifiedFilters` so the saved-filter surfaces (sidebar rows +
    /// toolbar search suggestions) pick it up. Silently no-ops when
    /// the filter carries nothing meaningful — mirrors `saveRecentFilter`'s
    /// own guard so an empty toolbar doesn't flood the list with
    /// identical "Filtered View" rows.
    func recordRecentSearch(_ filter: ArchiveSearchFilter) {
        guard filter.hasMeaningfulFilters else { return }
        Task {
            do {
                _ = try await viewService.saveRecentFilter(
                    filters: filter,
                    targetType: .virtualThread
                )
                await refreshSavedEntries()
            } catch {
                errorText = error.localizedDescription
            }
        }
    }

    /// Delete any saved_filters row — replaces the old `deleteSavedView` path
    /// for the unified list so pinned AND recent rows can be removed.
    func deleteFilterEntry(_ entry: SavedFilterEntry) {
        Task {
            do {
                _ = try await viewService.deleteFilter(
                    id: entry.id,
                    targetType: entry.targetType
                )
                await refreshSavedEntries()
            } catch {
                errorText = error.localizedDescription
            }
        }
    }

    private func refreshBookmarkCount() async {
        do {
            bookmarkCount = try await bookmarkRepository.listBookmarks().count
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func loadSavedEntries() async throws -> (recent: [SavedFilterEntry], saved: [SavedViewEntry]) {
        async let recentTask = viewService.listRecentFilters(targetType: .virtualThread)
        async let savedTask = viewService.listSavedViews(targetType: .virtualThread)
        return (try await recentTask, try await savedTask)
    }

    private func loadSourceFacets() async throws -> [LibrarySourceFacet] {
        // Single DB read: (source, model, count) triples with both source and
        // model filters excluded. Pivot in memory into the nested facet tree
        // instead of doing fetchModels per source (N+1 round-trips).
        let rows = try await conversationRepository.fetchSourceModelFacets(filter: filter)

        var modelsBySource: [String: [LibraryModelFacet]] = [:]
        var totalsBySource: [String: Int] = [:]
        var sourceOrder: [String] = []

        for row in rows {
            if totalsBySource[row.source] == nil {
                sourceOrder.append(row.source)
            }
            totalsBySource[row.source, default: 0] += row.count
            if let model = row.model {
                modelsBySource[row.source, default: []].append(
                    LibraryModelFacet(
                        value: model,
                        count: row.count,
                        isSelected: filter.models.contains(model)
                    )
                )
            }
        }

        // Mirror the SQL ordering that the old fetchSources used: by descending
        // count then source name.
        sourceOrder.sort { lhs, rhs in
            let lhsCount = totalsBySource[lhs] ?? 0
            let rhsCount = totalsBySource[rhs] ?? 0
            if lhsCount != rhsCount { return lhsCount > rhsCount }
            return lhs < rhs
        }

        return sourceOrder.map { source in
            let models = (modelsBySource[source] ?? []).sorted { lhs, rhs in
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                return lhs.value < rhs.value
            }
            return LibrarySourceFacet(
                value: source,
                count: totalsBySource[source] ?? 0,
                isSelected: filter.sources.contains(source),
                models: models
            )
        }
    }

    private func loadSourceFileFacets() async throws -> [LibrarySourceFileFacet] {
        let rows = try await conversationRepository.fetchSourceFileFacets(filter: filter)
        return rows.map { option in
            LibrarySourceFileFacet(
                path: option.value,
                count: option.count,
                isSelected: filter.sourceFiles.contains(option.value)
            )
        }
    }

    private func fetchPage(offset: Int) async throws -> [ConversationSummary] {
        if filter.normalizedKeyword.isEmpty {
            return try await conversationRepository.fetchIndex(
                query: ConversationListQuery(
                    offset: offset,
                    limit: pageSize,
                    sortBy: sortKey,
                    filter: filter
                )
            )
        }

        let results = try await searchRepository.search(
            query: SearchQuery(
                filter: filter,
                offset: offset,
                limit: pageSize,
                sortKey: sortKey
            )
        )

        return results.map(Self.makeSummary(from:))
    }

    private func fetchFilteredCount() async throws -> Int {
        if filter.normalizedKeyword.isEmpty {
            return try await conversationRepository.count(
                query: ConversationListQuery(
                    offset: 0,
                    limit: 1,
                    sortBy: sortKey,
                    filter: filter
                )
            )
        }

        return try await searchRepository.count(
            query: SearchQuery(
                filter: filter,
                offset: 0,
                limit: 1,
                sortKey: sortKey
            )
        )
    }

    private func normalizeOptionalText(_ rawValue: String) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func makeSummary(from result: SearchResult) -> ConversationSummary {
        ConversationSummary(
            id: result.conversationID,
            headline: result.headline,
            source: result.source,
            title: result.title,
            model: result.model,
            messageCount: result.messageCount,
            primaryTime: result.primaryTime,
            isBookmarked: result.isBookmarked
        )
    }
}

struct LibrarySourceFacet: Identifiable, Hashable {
    let value: String
    let count: Int
    let isSelected: Bool
    let models: [LibraryModelFacet]

    var id: String { value }
}

struct LibraryActiveFilterChip: Identifiable, Hashable {
    enum Kind: Hashable {
        case keyword
        case source(String)
        case model(String)
        case sourceFile(String)
        case dateFrom
        case dateTo
        case role(MessageRole)
        case bookmarkedOnly
        case bookmarkTag(String)
    }

    let kind: Kind
    let label: String

    var id: Kind { kind }
}

struct LibraryModelFacet: Identifiable, Hashable {
    let value: String
    let count: Int
    let isSelected: Bool

    var id: String { value }
}

struct LibrarySourceFileFacet: Identifiable, Hashable {
    /// Absolute path of the originally imported JSON file.
    let path: String
    let count: Int
    let isSelected: Bool

    var id: String { path }

    /// Display-friendly filename (no directory). Used by the sidebar row.
    var displayName: String {
        let component = (path as NSString).lastPathComponent
        return component.isEmpty ? path : component
    }
}
