import Foundation

@MainActor
final class MockBookmarkRepository: BookmarkRepository, @unchecked Sendable {
    private var states: [String: BookmarkState]
    private let items: [ConversationSummary]

    init(items: [ConversationSummary] = PreviewData.conversations) {
        self.items = items
        self.states = Dictionary(
            uniqueKeysWithValues: items.map {
                (
                    "thread::\($0.id)",
                    BookmarkState(
                        targetType: .thread,
                        targetID: $0.id,
                        payload: ["title": $0.displayTitle],
                        isBookmarked: $0.isBookmarked,
                        updatedAt: $0.primaryTime
                    )
                )
            }
        )
    }

    func setBookmark(target: BookmarkTarget, bookmarked: Bool) async throws -> BookmarkState {
        let key = "\(target.targetType.rawValue)::\(target.targetID)"
        let state = BookmarkState(
            targetType: target.targetType,
            targetID: target.targetID,
            payload: target.payload,
            isBookmarked: bookmarked,
            updatedAt: bookmarked ? "2026-04-16 00:00:00" : nil
        )
        states[key] = state
        return state
    }

    func fetchBookmarkStates(targets: [BookmarkTarget]) async throws -> [BookmarkState] {
        targets.map { target in
            states["\(target.targetType.rawValue)::\(target.targetID)"]
                ?? BookmarkState(
                    targetType: target.targetType,
                    targetID: target.targetID,
                    payload: target.payload,
                    isBookmarked: false,
                    updatedAt: nil
                )
        }
    }

    func listBookmarks() async throws -> [BookmarkListEntry] {
        items.enumerated().compactMap { index, item in
            let key = "thread::\(item.id)"
            guard states[key]?.isBookmarked == true else {
                return nil
            }
            return BookmarkListEntry(
                bookmarkID: index + 1,
                targetType: .thread,
                targetID: item.id,
                payload: ["title": item.displayTitle],
                label: item.displayTitle,
                title: item.title,
                source: item.source,
                model: item.model,
                primaryTime: item.primaryTime,
                updatedAt: item.primaryTime
            )
        }
    }
}
