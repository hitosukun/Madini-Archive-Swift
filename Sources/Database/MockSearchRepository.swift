import Foundation

final class MockSearchRepository: SearchRepository, @unchecked Sendable {
    private let items: [ConversationSummary]
    private let details: [String: ConversationDetail]

    init(
        items: [ConversationSummary] = PreviewData.conversations,
        details: [String: ConversationDetail] = PreviewData.details
    ) {
        self.items = items
        self.details = details
    }

    func search(query: SearchQuery) async throws -> [SearchResult] {
        let normalized = query.normalizedText.lowercased()
        guard query.filter.hasMeaningfulFilters else {
            return []
        }

        let filtered = try await allResults(query: query, normalized: normalized)
        let start = min(query.offset, filtered.count)
        let end = min(start + query.limit, filtered.count)
        return Array(filtered[start..<end])
    }

    func count(query: SearchQuery) async throws -> Int {
        guard query.filter.hasMeaningfulFilters else {
            return 0
        }

        return try await allResults(query: query, normalized: query.normalizedText.lowercased()).count
    }

    private func allResults(
        query: SearchQuery,
        normalized: String
    ) async throws -> [SearchResult] {
        items.compactMap { item in
            guard query.filter.sources.isEmpty || query.filter.sources.contains(item.source ?? "") else {
                return nil
            }

            guard query.filter.models.isEmpty || query.filter.models.contains(item.model ?? "") else {
                return nil
            }

            guard !query.filter.bookmarkedOnly || item.isBookmarked else {
                return nil
            }

            if let dateFrom = query.filter.dateFrom, !dateFrom.isEmpty,
               (item.primaryTime ?? "") < dateFrom {
                return nil
            }

            if let dateTo = query.filter.dateTo, !dateTo.isEmpty,
               (item.primaryTime ?? "") > dateTo {
                return nil
            }

            let haystack = [
                item.title ?? "",
                details[item.id]?.messages.map(\.content).joined(separator: "\n") ?? ""
            ].joined(separator: "\n")

            if !query.filter.roles.isEmpty,
               let detail = details[item.id],
               detail.messages.allSatisfy({ !query.filter.roles.contains($0.role) }) {
                return nil
            }

            guard normalized.isEmpty || haystack.lowercased().contains(normalized) else {
                return nil
            }

            return SearchResult(
                conversationID: item.id,
                headline: item.headline,
                title: item.title,
                source: item.source,
                model: item.model,
                messageCount: item.messageCount,
                primaryTime: item.primaryTime,
                snippet: makeSnippet(from: haystack, matching: normalized),
                isBookmarked: item.isBookmarked
            )
        }
        .sorted { lhs, rhs in
            let left = lhs.primaryTime ?? ""
            let right = rhs.primaryTime ?? ""
            return left == right ? lhs.conversationID < rhs.conversationID : left > right
        }
    }

    private func makeSnippet(from content: String, matching normalized: String) -> String {
        let lowered = content.lowercased()
        guard let range = lowered.range(of: normalized) else {
            return String(content.prefix(120))
        }

        let start = content.distance(from: content.startIndex, to: range.lowerBound)
        let prefixStart = max(0, start - 40)
        let prefixIndex = content.index(content.startIndex, offsetBy: prefixStart)
        let suffixIndex = content.index(range.upperBound, offsetBy: min(40, content.distance(from: range.upperBound, to: content.endIndex)), limitedBy: content.endIndex) ?? content.endIndex
        return String(content[prefixIndex..<suffixIndex]).replacingOccurrences(of: "\n", with: " ")
    }
}
