import Observation
import SwiftUI

@MainActor
@Observable
final class SearchViewModel {
    var filter: ArchiveSearchFilter = ArchiveSearchFilter()
    var results: [SearchResult] = []
    var sourceOptions: [FilterOption] = []
    var modelOptions: [FilterOption] = []
    var recentFilters: [SavedFilterEntry] = []
    var savedViews: [SavedViewEntry] = []
    var pendingSavedViewName: String = ""
    var selectedConversationId: String?
    var isLoading: Bool = false
    var isLoadingMore: Bool = false
    var hasSearched: Bool = false
    var totalCount: Int = 0
    var errorText: String?

    private let searchRepository: any SearchRepository
    private let conversationRepository: any ConversationRepository
    private let viewService: any ViewService
    private let pageSize = 50
    private var hasMorePages = true
    private var debounceTask: Task<Void, Never>?

    init(
        searchRepository: any SearchRepository,
        conversationRepository: any ConversationRepository,
        viewService: any ViewService
    ) {
        self.searchRepository = searchRepository
        self.conversationRepository = conversationRepository
        self.viewService = viewService
    }

    var searchText: String {
        get { filter.keyword }
        set { updateSearchText(newValue) }
    }

    var selectedSource: String? {
        get { filter.source }
        set { applySourceFilter(newValue) }
    }

    var selectedModel: String? {
        get { filter.model }
        set { applyModelFilter(newValue) }
    }

    var bookmarkedOnly: Bool {
        get { filter.bookmarkedOnly }
        set { applyBookmarkedOnly(newValue) }
    }

    var dateFrom: String {
        get { filter.dateFrom ?? "" }
        set { applyDateFrom(newValue) }
    }

    var dateTo: String {
        get { filter.dateTo ?? "" }
        set { applyDateTo(newValue) }
    }

    func loadFiltersIfNeeded() async {
        guard sourceOptions.isEmpty && !isLoading else {
            return
        }

        await refreshFilterOptions()
        await refreshSavedEntries()
    }

    func reloadSupportingState() async {
        await refreshFilterOptions()
        await refreshSavedEntries()
    }

    func updateSearchText(_ text: String) {
        filter.keyword = text
        scheduleSearch()
    }

    func applySourceFilter(_ source: String?) {
        guard filter.source != source else {
            return
        }

        filter.source = source
        filter.model = nil

        Task {
            await reloadModels()
            scheduleSearch()
        }
    }

    func applyModelFilter(_ model: String?) {
        guard filter.model != model else {
            return
        }

        filter.model = model
        scheduleSearch()
    }

    func applyBookmarkedOnly(_ bookmarkedOnly: Bool) {
        guard filter.bookmarkedOnly != bookmarkedOnly else {
            return
        }

        filter.bookmarkedOnly = bookmarkedOnly
        scheduleSearch()
    }

    func applyDateFrom(_ rawValue: String) {
        let normalized = normalizeOptionalText(rawValue)
        guard filter.dateFrom != normalized else {
            return
        }

        filter.dateFrom = normalized
        scheduleSearch()
    }

    func applyDateTo(_ rawValue: String) {
        let normalized = normalizeOptionalText(rawValue)
        guard filter.dateTo != normalized else {
            return
        }

        filter.dateTo = normalized
        scheduleSearch()
    }

    func toggleRole(_ role: MessageRole) {
        if filter.roles.contains(role) {
            filter.roles.remove(role)
        } else {
            filter.roles.insert(role)
        }
        scheduleSearch()
    }

    func clearFilters() {
        guard filter.hasMeaningfulFilters else {
            return
        }

        filter = ArchiveSearchFilter()
        Task {
            await reloadModels()
            scheduleSearch()
        }
    }

    func applySavedFilter(_ entry: SavedFilterEntry) {
        filter = entry.filters
        pendingSavedViewName = entry.name
        Task {
            await reloadModels()
            performSearchNow()
        }
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

    func searchTextBinding() -> Binding<String> {
        Binding(
            get: { self.filter.keyword },
            set: { self.updateSearchText($0) }
        )
    }

    func sourceSelectionBinding() -> Binding<String?> {
        Binding(
            get: { self.filter.source },
            set: { self.applySourceFilter($0) }
        )
    }

    func modelSelectionBinding() -> Binding<String?> {
        Binding(
            get: { self.filter.model },
            set: { self.applyModelFilter($0) }
        )
    }

    func bookmarkedOnlyBinding() -> Binding<Bool> {
        Binding(
            get: { self.filter.bookmarkedOnly },
            set: { self.applyBookmarkedOnly($0) }
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

    func performSearchNow() {
        debounceTask?.cancel()
        Task { await reloadSearch() }
    }

    func loadMoreIfNeeded(currentItem: SearchResult) async {
        guard hasMorePages, !isLoadingMore else {
            return
        }

        let thresholdIndex = results.index(
            results.endIndex,
            offsetBy: -5,
            limitedBy: results.startIndex
        ) ?? results.startIndex

        guard let currentIndex = results.firstIndex(where: { $0.id == currentItem.id }),
              currentIndex >= thresholdIndex else {
            return
        }

        isLoadingMore = true
        defer { isLoadingMore = false }

        do {
            let page = try await searchRepository.search(query: makeQuery(offset: results.count))
            results.append(contentsOf: page)
            hasMorePages = results.count < totalCount
        } catch {
            errorText = error.localizedDescription
        }
    }

    func result(for conversationID: String?) -> SearchResult? {
        guard let conversationID else {
            return nil
        }

        return results.first(where: { $0.conversationID == conversationID })
    }

    func setBookmarkState(for conversationID: String, isBookmarked: Bool) {
        results = results.map { result in
            guard result.conversationID == conversationID else {
                return result
            }

            return SearchResult(
                conversationID: result.conversationID,
                headline: result.headline,
                title: result.title,
                source: result.source,
                model: result.model,
                messageCount: result.messageCount,
                primaryTime: result.primaryTime,
                snippet: result.snippet,
                isBookmarked: isBookmarked
            )
        }
    }

    var hasActiveFilters: Bool {
        filter.hasMeaningfulFilters
    }

    var canSaveCurrentView: Bool {
        filter.hasMeaningfulFilters
    }

    var selectedRoles: [MessageRole] {
        filter.roles.sorted { $0.rawValue < $1.rawValue }
    }

    var filterSummaryText: String {
        filter.summaryText
    }

    private func scheduleSearch() {
        debounceTask?.cancel()

        guard filter.hasMeaningfulFilters else {
            hasSearched = false
            results = []
            totalCount = 0
            selectedConversationId = nil
            errorText = nil
            hasMorePages = false
            return
        }

        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else {
                return
            }
            await self?.reloadSearch()
        }
    }

    private func refreshFilterOptions() async {
        do {
            sourceOptions = try await conversationRepository.fetchSources()
            modelOptions = try await conversationRepository.fetchModels(source: filter.source)
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func refreshSavedEntries() async {
        do {
            async let recentTask = viewService.listRecentFilters(targetType: .virtualThread)
            async let savedTask = viewService.listSavedViews(targetType: .virtualThread)
            recentFilters = try await recentTask
            savedViews = try await savedTask
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func reloadModels() async {
        do {
            modelOptions = try await conversationRepository.fetchModels(source: filter.source)
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func reloadSearch() async {
        guard filter.hasMeaningfulFilters else {
            return
        }

        isLoading = true
        hasSearched = true
        errorText = nil
        defer { isLoading = false }

        let selectedID = selectedConversationId

        do {
            let query = makeQuery(offset: 0)
            async let resultsTask = searchRepository.search(query: query)
            async let countTask = searchRepository.count(query: query)
            async let recentTask = viewService.saveRecentFilter(filters: filter, targetType: .virtualThread)

            let page = try await resultsTask
            let count = try await countTask
            _ = try await recentTask

            results = page
            totalCount = count
            hasMorePages = page.count < count

            if let selectedID, page.contains(where: { $0.conversationID == selectedID }) {
                selectedConversationId = selectedID
            } else {
                selectedConversationId = nil
            }

            recentFilters = try await viewService.listRecentFilters(targetType: .virtualThread)
        } catch {
            results = []
            totalCount = 0
            hasMorePages = false
            errorText = error.localizedDescription
        }
    }

    private func makeQuery(offset: Int) -> SearchQuery {
        SearchQuery(
            filter: filter,
            offset: offset,
            limit: pageSize
        )
    }

    private func normalizeOptionalText(_ rawValue: String) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
