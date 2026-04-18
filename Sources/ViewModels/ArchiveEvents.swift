import Observation

@MainActor
@Observable
final class ArchiveEvents {
    var bookmarkRevision: Int = 0
    var savedViewRevision: Int = 0
    /// Bumped whenever a batch of JSON files is successfully imported into
    /// the shared archive.db (via the window-level drag-and-drop import
    /// handler). `MacOSRootView` observes this via `.task(id:)` and fires
    /// `LibraryViewModel.reload()` — that in turn refreshes the main
    /// conversation list AND the sidebar `sourceFileFacets`, so the newly
    /// added files appear under the archive.db row without the user having
    /// to relaunch the app.
    var importRevision: Int = 0

    func didChangeBookmarks() {
        bookmarkRevision += 1
    }

    func didChangeSavedViews() {
        savedViewRevision += 1
    }

    /// Signals a successful import. Call on the main actor after the Python
    /// importer returns exit code 0.
    func didImportConversations() {
        importRevision += 1
    }
}
