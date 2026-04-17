import Observation
import SwiftUI

@MainActor
@Observable
final class LibraryViewModel {
    var filter = ArchiveSearchFilter()
    var conversations: [ConversationSummary] = []
    var sourceFacets: [LibrarySourceFacet] = []
    var recentFilters: [SavedFilterEntry] = []
    var savedViews: [SavedViewEntry] = []
    /// Unified filter history (pinned first, then recent, capped to 20).
    /// This supersedes `recentFilters` + `savedViews` in the new sidebar UI;
    /// the old properties remain populated for legacy call sites.
    var unifiedFilters: [SavedFilterEntry] = []
    var pendingSavedViewName: String = ""
    var selectedConversationId: String?
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
        for source in filter.sources.sorted() {
            chips.append(.init(kind: .source(source), label: source))
        }
        for model in filter.models.sorted() {
            chips.append(.init(kind: .model(model), label: model))
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

    func summary(for conversationID: String?) -> ConversationSummary? {
        guard let conversationID else {
            return nil
        }

        return conversations.first(where: { $0.id == conversationID })
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
            async let savedEntriesTask = loadSavedEntries()
            async let bookmarkCountTask = bookmarkRepository.listBookmarks()

            let page = try await pageTask
            let filteredCount = try await filteredCountTask
            let overallCount = try await overallCountTask
            let facets = try await sidebarTask
            let savedEntries = try await savedEntriesTask
            let bookmarks = try await bookmarkCountTask

            if saveRecent {
                _ = try await viewService.saveRecentFilter(filters: filter, targetType: .virtualThread)
            }

            self.conversations = page
            self.totalCount = filteredCount
            self.overallCount = overallCount
            self.sourceFacets = facets
            self.recentFilters = savedEntries.recent
            self.savedViews = savedEntries.saved
            self.bookmarkCount = bookmarks.count
            self.hasMorePages = page.count < filteredCount

            self.filter.models = self.filter.models.intersection(
                Set(facets.flatMap { $0.models.map(\.value) })
            )

            if let selectedID, page.contains(where: { $0.id == selectedID }) {
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
            if let existing = try await tagRepository.listTags().first(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
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
            let tags = try await tagRepository.listTags()
            guard let tag = tags.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { return }
            try await tagRepository.detachTag(tagID: tag.id, fromConversationID: conversationID)
            await refreshConversationTags(for: [conversationID], replace: false)
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func refreshSidebarState() async {
        do {
            sourceFacets = try await loadSourceFacets()
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
        let sources = try await conversationRepository.fetchSources(filter: filter)
        var facets: [LibrarySourceFacet] = []
        facets.reserveCapacity(sources.count)

        for source in sources {
            var modelFilter = filter
            modelFilter.sources = [source.value]
            let models = try await conversationRepository.fetchModels(filter: modelFilter)
            facets.append(
                LibrarySourceFacet(
                    value: source.value,
                    count: source.count,
                    isSelected: filter.sources.contains(source.value),
                    models: models.map {
                        LibraryModelFacet(
                            value: $0.value,
                            count: $0.count,
                            isSelected: filter.models.contains($0.value)
                        )
                    }
                )
            )
        }

        return facets
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
                limit: pageSize
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
                limit: 1
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
