import Observation

@MainActor
@Observable
final class ArchiveEvents {
    var bookmarkRevision: Int = 0
    var savedViewRevision: Int = 0

    func didChangeBookmarks() {
        bookmarkRevision += 1
    }

    func didChangeSavedViews() {
        savedViewRevision += 1
    }
}
