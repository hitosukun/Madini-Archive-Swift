import Observation
import Foundation

enum ReaderTabContent: Hashable, Sendable {
    case conversation(id: String)
    case search
    case bookmarks
}

struct ReaderTab: Identifiable, Hashable, Sendable {
    let id: UUID
    var title: String
    var content: ReaderTabContent

    init(
        id: UUID = UUID(),
        title: String,
        content: ReaderTabContent
    ) {
        self.id = id
        self.title = title
        self.content = content
    }
}

enum ReaderTabOpenMode: Sendable {
    case replaceCurrent
    case newTab
}

@MainActor
@Observable
final class ReaderTabManager {
    var tabs: [ReaderTab] = []
    var activeTabID: ReaderTab.ID?

    var activeTab: ReaderTab? {
        guard let activeTabID else {
            return nil
        }

        return tabs.first(where: { $0.id == activeTabID })
    }

    func openConversation(
        id conversationID: String,
        title: String,
        mode: ReaderTabOpenMode
    ) {
        if let existingIndex = tabs.firstIndex(where: { $0.content == .conversation(id: conversationID) }) {
            activeTabID = tabs[existingIndex].id
            return
        }

        switch mode {
        case .replaceCurrent:
            replaceCurrentOrAppend(
                with: ReaderTab(
                    title: title,
                    content: .conversation(id: conversationID)
                )
            )
        case .newTab:
            insertNewTab(
                ReaderTab(
                    title: title,
                    content: .conversation(id: conversationID)
                )
            )
        }
    }

    func activate(_ tabID: ReaderTab.ID) {
        guard tabs.contains(where: { $0.id == tabID }) else {
            return
        }

        activeTabID = tabID
    }

    func close(_ tabID: ReaderTab.ID) {
        guard let closingIndex = tabs.firstIndex(where: { $0.id == tabID }) else {
            return
        }

        let wasActive = activeTabID == tabID
        tabs.remove(at: closingIndex)

        guard wasActive else {
            return
        }

        if closingIndex < tabs.count {
            activeTabID = tabs[closingIndex].id
        } else {
            activeTabID = tabs.last?.id
        }
    }

    private func replaceCurrentOrAppend(with tab: ReaderTab) {
        if let activeTabID,
           let activeIndex = tabs.firstIndex(where: { $0.id == activeTabID }) {
            tabs[activeIndex] = tab
            self.activeTabID = tab.id
            return
        }

        tabs = [tab]
        activeTabID = tab.id
    }

    private func insertNewTab(_ tab: ReaderTab) {
        if let activeTabID,
           let activeIndex = tabs.firstIndex(where: { $0.id == activeTabID }) {
            tabs.insert(tab, at: activeIndex + 1)
        } else {
            tabs.append(tab)
        }
        activeTabID = tab.id
    }
}
