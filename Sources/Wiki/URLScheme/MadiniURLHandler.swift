import Foundation
import SwiftUI

/// Receives `madini-archive://` URLs from `scene.onOpenURL` and routes
/// them to in-app navigation. Holds no state itself — every dispatch
/// publishes through `ArchiveEvents` (or `wiki-browser` window
/// activation) so the receiving view re-runs its data load.
///
/// Phase A focuses on the four URL shapes from the handoff doc. Each
/// dispatch is best-effort: a missing conversation/page is logged and
/// the handler returns; we never crash on URL input from outside the
/// app.
@MainActor
final class MadiniURLHandler {
    private let services: AppServices
    /// SwiftUI's `openWindow` action plumbed in from the scene.
    private let openWindow: (String) -> Void

    init(services: AppServices, openWindow: @escaping (String) -> Void) {
        self.services = services
        self.openWindow = openWindow
    }

    func handle(_ url: URL) {
        guard let parsed = MadiniURL.parse(url) else { return }
        switch parsed {
        case .conversation(let id, let messageIndex):
            handleConversation(id: id, messageIndex: messageIndex)
        case .search(let query):
            handleSearch(query: query)
        case .wikiPage(let vaultID, let relativePath):
            handleWikiPage(vaultID: vaultID, relativePath: relativePath)
        }
    }

    // MARK: - Routes

    private func handleConversation(id: String, messageIndex: Int?) {
        // Conversation deeplinks publish through the existing
        // ArchiveEvents bus so the reader scene picks them up.
        // RootView already observes archiveEvents; adding the deeplink
        // observer there is a follow-up. For Phase A we record the
        // requested target so a future reader can pick it up.
        Task {
            guard let detail = try? await services.conversations.fetchDetail(id: id) else {
                NSLog("MadiniURL: conversation not found: \(id)")
                return
            }
            _ = detail
            _ = messageIndex
            // Mark a deeplink request that the reader scene observes.
            // Implemented as a NotificationCenter post so we don't need
            // to thread a binding through every scene level.
            NotificationCenter.default.post(
                name: MadiniURLHandler.didRequestConversation,
                object: nil,
                userInfo: [
                    "conversationID": id,
                    "messageIndex": messageIndex as Any,
                ]
            )
        }
    }

    private func handleSearch(query: String) {
        NotificationCenter.default.post(
            name: MadiniURLHandler.didRequestSearch,
            object: nil,
            userInfo: ["query": query]
        )
    }

    private func handleWikiPage(vaultID: String, relativePath: String) {
        // Open the dedicated wiki window first (idempotent — SwiftUI
        // `openWindow(id:)` just brings the existing window forward).
        openWindow("wiki-browser")
        NotificationCenter.default.post(
            name: MadiniURLHandler.didRequestWikiPage,
            object: nil,
            userInfo: [
                "vaultID": vaultID,
                "relativePath": relativePath,
            ]
        )
    }

    // MARK: - Notification names

    static let didRequestConversation = Notification.Name(
        "MadiniURLHandler.didRequestConversation"
    )
    static let didRequestSearch = Notification.Name(
        "MadiniURLHandler.didRequestSearch"
    )
    static let didRequestWikiPage = Notification.Name(
        "MadiniURLHandler.didRequestWikiPage"
    )
}
