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

    func fetchSourceFileFacets(filter: ArchiveSearchFilter?) async throws -> [FilterOption] {
        // Mock fixtures have no source_file provenance — the sidebar entry
        // stays empty under previews, which is fine.
        []
    }

    func fetchSourceModelFacets(filter: ArchiveSearchFilter?) async throws -> [SourceModelFacet] {
        var facetFilter = filter ?? ArchiveSearchFilter()
        facetFilter.sources = []
        facetFilter.models = []
        let filtered = filteredItems(filter: facetFilter)
        let grouped = Dictionary(grouping: filtered) { item in
            SourceModelKey(source: item.source ?? "Unknown", model: item.model)
        }
        return grouped
            .map { key, items in
                SourceModelFacet(source: key.source, model: key.model, count: items.count)
            }
            .sorted { lhs, rhs in
                if lhs.source != rhs.source { return lhs.source < rhs.source }
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                return (lhs.model ?? "") < (rhs.model ?? "")
            }
    }

    private struct SourceModelKey: Hashable {
        let source: String
        let model: String?
    }

    private func filteredItems(filter: ArchiveSearchFilter) -> [ConversationSummary] {
        items.filter { item in
            let sourceMatches = filter.sources.isEmpty || filter.sources.contains(item.source ?? "")
            let modelMatches = filter.models.isEmpty || filter.models.contains(item.model ?? "")
            // Phase 4 changed the canonical definition of "bookmarked" to
            // "at least one user prompt in the thread is pinned". The
            // preview/test-only mock keeps the simpler per-item boolean
            // since `PreviewData` fixtures don't model per-message state.
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
            switch sortKey {
            case .dateAsc:
                let left = lhs.primaryTime ?? ""
                let right = rhs.primaryTime ?? ""
                return left == right ? lhs.id < rhs.id : left < right
            case .dateDesc:
                let left = lhs.primaryTime ?? ""
                let right = rhs.primaryTime ?? ""
                return left == right ? lhs.id < rhs.id : left > right
            case .promptCountDesc:
                if lhs.messageCount != rhs.messageCount {
                    return lhs.messageCount > rhs.messageCount
                }
                return lhs.id < rhs.id
            case .promptCountAsc:
                if lhs.messageCount != rhs.messageCount {
                    return lhs.messageCount < rhs.messageCount
                }
                return lhs.id < rhs.id
            }
        }
    }
}
