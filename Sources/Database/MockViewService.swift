import Foundation

final class MockViewService: ViewService, @unchecked Sendable {
    private var recentEntries: [SavedFilterEntry] = [
        SavedFilterEntry(
            id: 1,
            kind: "recent",
            targetType: .virtualThread,
            name: "gpt-4o",
            filters: ArchiveSearchFilter(keyword: "SwiftUI", source: "ChatGPT", model: "gpt-4o"),
            createdAt: "2026-04-15 20:00:00",
            updatedAt: "2026-04-15 20:00:00",
            lastUsedAt: "2026-04-15 20:00:00"
        )
    ]
    private var savedViews: [SavedFilterEntry] = [
        SavedFilterEntry(
            id: 100,
            kind: "saved_view",
            targetType: .virtualThread,
            name: "Bookmarked ChatGPT",
            filters: ArchiveSearchFilter(source: "ChatGPT", bookmarkedOnly: true),
            createdAt: "2026-04-14 10:00:00",
            updatedAt: "2026-04-15 09:00:00",
            lastUsedAt: "2026-04-15 09:00:00"
        )
    ]

    func listRecentFilters(targetType: ViewTargetType) async throws -> [SavedFilterEntry] {
        recentEntries.filter { $0.targetType == targetType }
    }

    func saveRecentFilter(filters: ArchiveSearchFilter, targetType: ViewTargetType) async throws -> SavedFilterEntry? {
        guard filters.hasMeaningfulFilters else {
            return nil
        }

        let entry = SavedFilterEntry(
            id: (recentEntries.map(\.id).max() ?? 0) + 1,
            kind: "recent",
            targetType: targetType,
            name: filters.normalizedKeyword.isEmpty ? "Filtered View" : filters.normalizedKeyword,
            filters: filters,
            createdAt: "2026-04-16 00:00:00",
            updatedAt: "2026-04-16 00:00:00",
            lastUsedAt: "2026-04-16 00:00:00"
        )
        recentEntries.insert(entry, at: 0)
        recentEntries = Array(recentEntries.prefix(10))
        return entry
    }

    func listSavedViews(targetType: ViewTargetType) async throws -> [SavedViewEntry] {
        savedViews.filter { $0.targetType == targetType }
    }

    func saveSavedView(
        name: String,
        filters: ArchiveSearchFilter,
        targetType: ViewTargetType,
        id: Int?
    ) async throws -> SavedViewEntry? {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, filters.hasMeaningfulFilters else {
            return nil
        }

        let entry = SavedFilterEntry(
            id: id ?? (savedViews.map(\.id).max() ?? 0) + 1,
            kind: "saved_view",
            targetType: targetType,
            name: name,
            filters: filters,
            createdAt: "2026-04-16 00:00:00",
            updatedAt: "2026-04-16 00:00:00",
            lastUsedAt: "2026-04-16 00:00:00"
        )

        savedViews.removeAll { $0.id == entry.id }
        savedViews.insert(entry, at: 0)
        return entry
    }

    func deleteSavedView(id: Int, targetType: ViewTargetType) async throws -> Bool {
        let before = savedViews.count
        savedViews.removeAll { $0.id == id && $0.targetType == targetType }
        return savedViews.count != before
    }

    func listUnifiedFilters(targetType: ViewTargetType, limit: Int) async throws -> [SavedFilterEntry] {
        let all = (savedViews + recentEntries).filter { $0.targetType == targetType }
        let sorted = all.sorted { lhs, rhs in
            if lhs.pinned != rhs.pinned { return lhs.pinned && !rhs.pinned }
            return lhs.lastUsedAt > rhs.lastUsedAt
        }
        let effectiveLimit = limit > 0 ? limit : 20
        return Array(sorted.prefix(effectiveLimit))
    }

    func togglePinnedFilter(id: Int, targetType: ViewTargetType) async throws -> Bool {
        if let idx = savedViews.firstIndex(where: { $0.id == id }) {
            savedViews[idx].pinned.toggle()
            return savedViews[idx].pinned
        }
        if let idx = recentEntries.firstIndex(where: { $0.id == id }) {
            recentEntries[idx].pinned.toggle()
            return recentEntries[idx].pinned
        }
        return false
    }

    func deleteFilter(id: Int, targetType: ViewTargetType) async throws -> Bool {
        let before = savedViews.count + recentEntries.count
        savedViews.removeAll { $0.id == id && $0.targetType == targetType }
        recentEntries.removeAll { $0.id == id && $0.targetType == targetType }
        return (savedViews.count + recentEntries.count) != before
    }

    func buildVirtualThreadPreview(
        filters: ArchiveSearchFilter,
        targetType: ViewTargetType
    ) async throws -> VirtualThreadPreview {
        VirtualThreadPreview(title: filters.normalizedKeyword.isEmpty ? "Virtual Thread" : filters.normalizedKeyword, count: 0)
    }

    func buildVirtualThread(
        title: String,
        filters: ArchiveSearchFilter,
        targetType: ViewTargetType
    ) async throws -> VirtualThread {
        VirtualThread(title: title, filters: filters, items: [])
    }
}
