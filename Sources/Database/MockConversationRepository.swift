import Foundation

final class MockConversationRepository: ConversationRepository, @unchecked Sendable {
    private let items: [ConversationSummary]
    private let details: [String: ConversationDetail]

    init(
        items: [ConversationSummary] = PreviewData.conversations,
        details: [String: ConversationDetail] = PreviewData.details
    ) {
        self.items = items
        self.details = details
    }

    func fetchIndex(query: ConversationListQuery) async throws -> [ConversationSummary] {
        let filtered = filteredItems(filter: query.filter)
        let sorted = sort(items: filtered, by: query.sortBy)
        let start = min(query.offset, sorted.count)
        let end = min(start + query.limit, sorted.count)
        return Array(sorted[start..<end])
    }

    func fetchDetail(id: String) async throws -> ConversationDetail? {
        details[id]
    }

    func fetchHeadline(id: String) async throws -> ConversationHeadlineSummary? {
        items.first(where: { $0.id == id })?.headline
    }

    func count(query: ConversationListQuery) async throws -> Int {
        filteredItems(filter: query.filter).count
    }

    func fetchSources(filter: ArchiveSearchFilter?) async throws -> [FilterOption] {
        let filtered = filteredItems(filter: sourceFacetFilter(from: filter ?? ArchiveSearchFilter()))
        return Dictionary(grouping: filtered, by: { $0.source ?? "Unknown" })
            .map { FilterOption(value: $0.key, count: $0.value.count) }
            .sorted {
                if $0.count == $1.count {
                    return $0.value < $1.value
                }
                return $0.count > $1.count
            }
    }

    func fetchModels(filter: ArchiveSearchFilter?) async throws -> [FilterOption] {
        let filtered = filteredItems(filter: modelFacetFilter(from: filter ?? ArchiveSearchFilter()))
        return Dictionary(grouping: filtered, by: { $0.model ?? "Unknown" })
            .map { FilterOption(value: $0.key, count: $0.value.count) }
            .sorted {
                if $0.count == $1.count {
                    return $0.value < $1.value
                }
                return $0.count > $1.count
            }
    }

    private func filteredItems(filter: ArchiveSearchFilter) -> [ConversationSummary] {
        items.filter { item in
            let sourceMatches = filter.sources.isEmpty || filter.sources.contains(item.source ?? "")
            let modelMatches = filter.models.isEmpty || filter.models.contains(item.model ?? "")
            let bookmarkMatches = !filter.bookmarkedOnly || item.isBookmarked
            let fromMatches = filter.dateFrom?.isEmpty != false || (item.primaryTime ?? "") >= (filter.dateFrom ?? "")
            let toMatches = filter.dateTo?.isEmpty != false || (item.primaryTime ?? "") <= (filter.dateTo ?? "")
            let roleMatches: Bool
            if filter.roles.isEmpty {
                roleMatches = true
            } else if let detail = details[item.id] {
                roleMatches = detail.messages.contains(where: { filter.roles.contains($0.role) })
            } else {
                roleMatches = false
            }

            return sourceMatches && modelMatches && bookmarkMatches && fromMatches && toMatches && roleMatches
        }
    }

    private func sourceFacetFilter(from filter: ArchiveSearchFilter) -> ArchiveSearchFilter {
        var filter = filter
        filter.sources = []
        return filter
    }

    private func modelFacetFilter(from filter: ArchiveSearchFilter) -> ArchiveSearchFilter {
        var filter = filter
        filter.models = []
        return filter
    }

    private func sort(
        items: [ConversationSummary],
        by sortKey: ConversationSortKey
    ) -> [ConversationSummary] {
        items.sorted { lhs, rhs in
            let left = lhs.primaryTime ?? ""
            let right = rhs.primaryTime ?? ""
            switch sortKey {
            case .dateAsc:
                return left == right ? lhs.id < rhs.id : left < right
            case .dateDesc:
                return left == right ? lhs.id < rhs.id : left > right
            }
        }
    }
}
