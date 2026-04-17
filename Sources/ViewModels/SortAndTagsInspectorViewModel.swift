import Observation
import Foundation
import SwiftUI

@MainActor
@Observable
final class SortAndTagsInspectorViewModel {
    var tags: [TagEntry] = []
    var selectedConversationTagIDs: Set<Int> = []
    var errorText: String?
    var isLoading: Bool = false
    var pendingTagName: String = ""

    private let tagRepository: any TagRepository
    private let libraryViewModel: LibraryViewModel
    private let archiveEvents: ArchiveEvents

    init(
        tagRepository: any TagRepository,
        libraryViewModel: LibraryViewModel,
        archiveEvents: ArchiveEvents
    ) {
        self.tagRepository = tagRepository
        self.libraryViewModel = libraryViewModel
        self.archiveEvents = archiveEvents
    }

    var sortKey: ConversationSortKey {
        libraryViewModel.sortKey
    }

    var activeTagFilters: [String] {
        libraryViewModel.filter.bookmarkTags
    }

    var selectedConversationID: String? {
        libraryViewModel.selectedConversationId
    }

    var selectedConversationTitle: String? {
        libraryViewModel.summary(for: libraryViewModel.selectedConversationId)?.displayTitle
    }

    // MARK: - Lifecycle

    func loadInitial() async {
        await refreshTags()
        await refreshCurrentConversationTags()
    }

    func refreshCurrentConversationTags() async {
        guard let conversationID = libraryViewModel.selectedConversationId else {
            selectedConversationTagIDs = []
            return
        }

        do {
            let bindings = try await tagRepository.bindings(forConversationIDs: [conversationID])
            selectedConversationTagIDs = Set(bindings[conversationID]?.tags.map(\.id) ?? [])
        } catch {
            errorText = error.localizedDescription
        }
    }

    func refreshTags() async {
        isLoading = true
        defer { isLoading = false }

        do {
            tags = try await tagRepository.listTags()
        } catch {
            errorText = error.localizedDescription
        }
    }

    // MARK: - Tag CRUD

    func createPendingTag() {
        let trimmed = pendingTagName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }

        Task {
            do {
                _ = try await tagRepository.createTag(name: trimmed)
                pendingTagName = ""
                await refreshTags()
                archiveEvents.didChangeBookmarks()
            } catch {
                errorText = error.localizedDescription
            }
        }
    }

    func renameTag(_ tag: TagEntry, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != tag.name else {
            return
        }

        Task {
            do {
                _ = try await tagRepository.renameTag(id: tag.id, name: trimmed)
                await refreshTags()
            } catch {
                errorText = error.localizedDescription
            }
        }
    }

    func deleteTag(_ tag: TagEntry) {
        guard !tag.isSystem else {
            return
        }

        Task {
            do {
                try await tagRepository.deleteTag(id: tag.id)
                // If this tag is currently filtering the library, drop it.
                libraryViewModel.removeBookmarkTag(tag.name)
                await refreshTags()
                archiveEvents.didChangeBookmarks()
            } catch {
                errorText = error.localizedDescription
            }
        }
    }

    // MARK: - Filtering

    func toggleTagFilter(_ tag: TagEntry) {
        libraryViewModel.toggleBookmarkTag(tag.name)
    }

    func isTagFilterActive(_ tag: TagEntry) -> Bool {
        libraryViewModel.filter.bookmarkTags.contains { $0.caseInsensitiveCompare(tag.name) == .orderedSame }
    }

    func clearAllTagFilters() {
        libraryViewModel.clearBookmarkTagFilters()
    }

    // MARK: - Attach / Detach

    func isTagAttachedToSelection(_ tag: TagEntry) -> Bool {
        selectedConversationTagIDs.contains(tag.id)
    }

    func toggleAttachmentToSelection(_ tag: TagEntry) {
        guard let conversationID = libraryViewModel.selectedConversationId,
              let summary = libraryViewModel.summary(for: conversationID) else {
            errorText = "Select a conversation first."
            return
        }

        let wasAttached = selectedConversationTagIDs.contains(tag.id)
        Task {
            do {
                if wasAttached {
                    try await tagRepository.detachTag(tagID: tag.id, fromConversationID: conversationID)
                    selectedConversationTagIDs.remove(tag.id)
                } else {
                    var payload: [String: String] = ["title": summary.displayTitle]
                    if let source = summary.source { payload["source"] = source }
                    if let model = summary.model { payload["model"] = model }

                    _ = try await tagRepository.attachTag(
                        tagID: tag.id,
                        toConversationID: conversationID,
                        payload: payload
                    )
                    selectedConversationTagIDs.insert(tag.id)
                    // Ensure the row shows its bookmark state too.
                    libraryViewModel.setBookmarkState(for: conversationID, isBookmarked: true)
                }
                archiveEvents.didChangeBookmarks()
                await refreshTags()
            } catch {
                errorText = error.localizedDescription
            }
        }
    }

    func pendingTagNameBinding() -> Binding<String> {
        // Expose as @Bindable isn't enough for a TextField that lives in a
        // deep subview; provide an explicit binding.
        .init(
            get: { self.pendingTagName },
            set: { self.pendingTagName = $0 }
        )
    }
}
