import Observation

@MainActor
@Observable
final class BookmarkListViewModel {
    var items: [BookmarkListEntry] = []
    var selectedTargetID: String?
    var isLoading: Bool = false
    var errorText: String?

    private let repository: any BookmarkRepository

    init(repository: any BookmarkRepository) {
        self.repository = repository
    }

    var count: Int {
        items.count
    }

    func load() async {
        isLoading = true
        errorText = nil
        defer { isLoading = false }

        do {
            let items = try await repository.listBookmarks()
            self.items = items.filter { $0.targetType == .thread }
            if let selectedTargetID,
               self.items.contains(where: { $0.targetID == selectedTargetID }) {
                self.selectedTargetID = selectedTargetID
            } else {
                self.selectedTargetID = self.items.first?.targetID
            }
        } catch {
            self.items = []
            self.errorText = error.localizedDescription
        }
    }

    func entry(for targetID: String?) -> BookmarkListEntry? {
        guard let targetID else {
            return nil
        }

        return items.first(where: { $0.targetID == targetID })
    }
}
