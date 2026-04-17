import Observation
import SwiftUI

@MainActor
@Observable
final class BrowseViewModel {
    var conversations: [ConversationSummary] = []
    var sourceOptions: [FilterOption] = []
    var modelOptions: [FilterOption] = []
    var sidebarSources: [BrowseSidebarSource] = []
    var sidebarSelection: BrowseSidebarSelection? = .all
    var selectedConversationId: String?
    var selectedSource: String?
    var selectedModel: String?
    var sortKey: ConversationSortKey = .dateDesc
    var isLoading: Bool = false
    var isLoadingMore: Bool = false
    var totalCount: Int = 0
    var overallCount: Int = 0
    var errorText: String?

    private let repository: any ConversationRepository
    private let pageSize = 100
    private var hasMorePages = true

    init(repository: any ConversationRepository) {
        self.repository = repository
    }

    func loadIfNeeded() async {
        guard conversations.isEmpty && !isLoading else {
            return
        }

        await reload()
    }

    func reload() async {
        isLoading = true
        errorText = nil
        defer { isLoading = false }

        let selectedId = selectedConversationId

        do {
            let pageQuery = makeQuery(offset: 0)
            let filteredCountQuery = ConversationListQuery(
                offset: 0,
                limit: 1,
                sortBy: sortKey,
                source: selectedSource,
                model: selectedModel
            )
            let overallCountQuery = ConversationListQuery(offset: 0, limit: 1)

            async let conversationsTask = repository.fetchIndex(query: pageQuery)
            async let filteredCountTask = repository.count(query: filteredCountQuery)
            async let overallCountTask = repository.count(query: overallCountQuery)
            async let sourceOptionsTask = repository.fetchSources()
            async let modelOptionsTask = repository.fetchModels(source: selectedSource)

            let page = try await conversationsTask
            let filteredCount = try await filteredCountTask
            let overallCount = try await overallCountTask
            let sourceOptions = try await sourceOptionsTask
            let fetchedModels = try await modelOptionsTask
            let sidebarSources = try await makeSidebarSources(from: sourceOptions)

            self.sourceOptions = sourceOptions
            self.modelOptions = fetchedModels
            self.sidebarSources = sidebarSources
            if let selectedModel, !fetchedModels.map(\.value).contains(selectedModel) {
                self.selectedModel = nil
            }
            syncSidebarSelection()

            self.conversations = page
            self.totalCount = filteredCount
            self.overallCount = overallCount
            self.hasMorePages = page.count < filteredCount

            if let selectedId, page.contains(where: { $0.id == selectedId }) {
                self.selectedConversationId = selectedId
            } else {
                self.selectedConversationId = page.first?.id
            }
        } catch {
            self.errorText = error.localizedDescription
            self.conversations = []
            self.totalCount = 0
            self.hasMorePages = false
            print("Failed to reload browse data: \(error)")
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
            let page = try await repository.fetchIndex(
                query: makeQuery(offset: conversations.count)
            )
            conversations.append(contentsOf: page)
            hasMorePages = conversations.count < totalCount
        } catch {
            errorText = error.localizedDescription
            print("Failed to load more browse items: \(error)")
        }
    }

    func toggleSortOrder() {
        sortKey = (sortKey == .dateDesc) ? .dateAsc : .dateDesc
        Task { await reload() }
    }

    func clearFilters() {
        guard selectedSource != nil || selectedModel != nil else {
            sidebarSelection = .all
            return
        }

        selectedSource = nil
        selectedModel = nil
        sidebarSelection = .all
        Task { await reload() }
    }

    func applySourceFilter(_ source: String?) {
        guard selectedSource != source else {
            return
        }

        selectedSource = source
        selectedModel = nil
        syncSidebarSelection()
        Task { await reload() }
    }

    func applyModelFilter(_ model: String?) {
        guard selectedModel != model else {
            return
        }

        selectedModel = model
        syncSidebarSelection()
        Task { await reload() }
    }

    func applySidebarSelection(_ selection: BrowseSidebarSelection?) {
        let selection = selection ?? .all
        guard sidebarSelection != selection else {
            return
        }

        sidebarSelection = selection

        switch selection {
        case .all:
            selectedSource = nil
            selectedModel = nil
        case .source(let source):
            selectedSource = source
            selectedModel = nil
        case .model(let source, let model):
            selectedSource = source
            selectedModel = model
        }

        Task { await reload() }
    }

    func sourceSelectionBinding() -> Binding<String?> {
        Binding(
            get: { self.selectedSource },
            set: { self.applySourceFilter($0) }
        )
    }

    func modelSelectionBinding() -> Binding<String?> {
        Binding(
            get: { self.selectedModel },
            set: { self.applyModelFilter($0) }
        )
    }

    var hasActiveFilters: Bool {
        selectedSource != nil || selectedModel != nil
    }

    var browseTitle: String {
        switch sidebarSelection ?? .all {
        case .all:
            return "All Conversations"
        case .source(let source):
            return source
        case .model(_, let model):
            return model
        }
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
    }

    private func makeQuery(offset: Int) -> ConversationListQuery {
        ConversationListQuery(
            offset: offset,
            limit: pageSize,
            sortBy: sortKey,
            source: selectedSource,
            model: selectedModel
        )
    }

    private func syncSidebarSelection() {
        if let source = selectedSource, let model = selectedModel {
            sidebarSelection = .model(source: source, model: model)
        } else if let source = selectedSource {
            sidebarSelection = .source(source)
        } else {
            sidebarSelection = .all
        }
    }

    private func makeSidebarSources(from sourceOptions: [FilterOption]) async throws -> [BrowseSidebarSource] {
        var results: [BrowseSidebarSource] = []
        results.reserveCapacity(sourceOptions.count)

        for sourceOption in sourceOptions {
            let models = try await repository.fetchModels(source: sourceOption.value)
                .map { BrowseSidebarModel(value: $0.value, count: $0.count) }
            results.append(
                BrowseSidebarSource(
                    value: sourceOption.value,
                    count: sourceOption.count,
                    models: models
                )
            )
        }

        return results
    }
}

enum BrowseSidebarSelection: Hashable {
    case all
    case source(String)
    case model(source: String, model: String)
}

struct BrowseSidebarSource: Identifiable, Hashable {
    let value: String
    let count: Int
    let models: [BrowseSidebarModel]

    var id: String { value }
}

struct BrowseSidebarModel: Identifiable, Hashable {
    let value: String
    let count: Int

    var id: String { value }
}
