import Observation
import Foundation

/// Represents the single conversation currently open in the right-hand
/// reader pane.
///
/// The workspace is permanently single-conversation — clicking another
/// card REPLACES whatever was showing. Earlier drafts of the app had a
/// tabbed reader (multi-tab browser pattern); that model is gone. This
/// lightweight struct survives only because `ReaderWorkspaceView` keys
/// its detail view by `.id(tab.id)` so swapping conversations remounts
/// the scroll-position / display-mode state cleanly.
struct ReaderTab: Identifiable, Hashable, Sendable {
    let id: UUID
    var title: String
    var conversationID: String

    init(
        id: UUID = UUID(),
        title: String,
        conversationID: String
    ) {
        self.id = id
        self.title = title
        self.conversationID = conversationID
    }
}

@MainActor
@Observable
final class ReaderTabManager {
    /// The single conversation currently displayed, or `nil` if the pane
    /// is empty. Assigning a new value (or clearing to nil) is the ONLY
    /// way to change what the reader shows.
    var activeTab: ReaderTab?

    /// One-shot signal from other panes (e.g. the pinned-conversation pane
    /// in the middle column) asking the reader to jump to a specific
    /// prompt. `ReaderWorkspaceView` observes this via `.onChange` and
    /// clears it back to nil after applying, so setting the same prompt
    /// id twice still fires both times.
    var requestedPromptID: String?

    /// One-shot signal asking the reader pane to scroll its body to the
    /// very top (the `ConversationHeaderView`). Fired by the right-pane
    /// header bar's conversation-title button — tapping the title resets
    /// the reader's scroll position and simultaneously asks the middle
    /// pane to reveal the matching card (see
    /// `LibraryViewModel.pendingListScrollConversationID`). A fresh
    /// `UUID` is assigned each time so consecutive taps still fire the
    /// `.onChange` even though the target "position" never changes.
    var scrollToTopToken: UUID?

    /// ID of the prompt the reader is currently scrolled to. Lives here —
    /// on the shared tab manager — rather than as `@State` in the root
    /// view for an important reason: the scroll-position observer in
    /// `ConversationDetailView` writes this value continuously while the
    /// user scrolls, and if it were root state, every write would force
    /// `MacOSRootView` to re-render, which cascades into
    /// `libraryContentPane`'s overlay header → `contentMargins` changes →
    /// the reader's `GeometryReader`s republishing `PromptTopYPreferenceKey`
    /// within the same layout pass → SwiftUI's "preference updated
    /// multiple times per frame" warning. Hosting the value on an
    /// `@Observable` model means only the views that actually READ it
    /// (the reader's detail view, the viewer-mode prompt list, the
    /// header-bar outline control) re-render — the unrelated middle-
    /// pane list doesn't, so the cascade is broken.
    var selectedPromptID: String?

    /// The freshly loaded `ConversationDetail` for whatever tab is active.
    /// Written by `ReaderWorkspaceView`'s `onDetailChanged` callback and
    /// read by the root-level Viewer-Mode toolbar (which needs the title
    /// + summary metadata to render its title chip). Before this lived
    /// here, the right-pane toolbar owned the state and the root couldn't
    /// reach it; hoisting onto the shared tab manager lets both the
    /// right-pane body and the root-level Viewer-Mode toolbar read the
    /// same value without duplicating the load.
    var activeDetail: ConversationDetail?

    /// Prompt outline for the active tab, kept in sync by the reader
    /// pane. The Viewer-Mode root toolbar's prev/next buttons operate on
    /// this array. Same rationale as `activeDetail` for why it lives on
    /// the manager rather than in `ReaderWorkspaceView`.
    var promptOutline: [ConversationPromptOutlineItem] = []

    func requestPromptSelection(_ id: String) {
        requestedPromptID = id
    }

    /// Move the reader's current prompt selection forward or backward by
    /// `step` entries in the outline. Used by both the right-pane
    /// header's prev/next chips (non-Viewer-Mode) and the root-level
    /// Viewer-Mode toolbar's prev/next chips — they share this single
    /// implementation so the keyboard arrow-key handler only has to
    /// speak to one method.
    func selectAdjacentPrompt(step: Int) {
        guard !promptOutline.isEmpty else { return }
        let currentIndex = promptOutline.firstIndex(where: { $0.id == selectedPromptID }) ?? 0
        let nextIndex = min(max(currentIndex + step, 0), promptOutline.count - 1)
        guard nextIndex != currentIndex || selectedPromptID == nil else { return }
        selectedPromptID = promptOutline[nextIndex].id
    }

    /// Opens a conversation in the reader pane, replacing whatever was
    /// previously showing. Re-opening the SAME conversation is a no-op so
    /// repeated clicks on the active card don't reset the reader's
    /// scroll position / display mode.
    func openConversation(id conversationID: String, title: String) {
        if activeTab?.conversationID == conversationID {
            return
        }
        // New conversation → previous highlight belongs to a different
        // prompt list and would render as a stale row highlight. Clear
        // it here so switching tabs always starts "no current prompt"
        // until the scroll observer picks a fresh one.
        selectedPromptID = nil
        // Clear outline + detail too — stale values would let prev/next
        // operate on the previous conversation's prompts for the frame
        // or two it takes the new detail to load.
        activeDetail = nil
        promptOutline = []
        activeTab = ReaderTab(
            title: title,
            conversationID: conversationID
        )
    }
}
