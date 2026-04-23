import Foundation
import SwiftUI

/// Sidebar "History" companion for the search-filter list: a rolling
/// record of the conversations the user recently opened. Paired with
/// `LibraryViewModel.unifiedFilters`, this gives the sidebar two
/// parallel streams — "recent searches" and "recently opened threads"
/// — so users can jump back to either a query they ran or a thread
/// they read.
///
/// Persistence: UserDefaults-backed JSON, keyed globally (not per-DB).
/// This intentionally sidesteps the `saved_filters` table so the two
/// history kinds can iterate independently; if later we want them
/// cross-correlated (pin a thread, evict oldest regardless of kind,
/// …), it moves to SQLite.
///
/// Cap: 20 entries. Matches the unified-filters cap so the sidebar
/// has a predictable footprint regardless of the mix.
@MainActor
final class RecentThreadsStore: ObservableObject {
    struct Entry: Codable, Identifiable, Hashable, Sendable {
        /// Conversation id — the primary key the shell uses to select
        /// the row in the middle pane. Same space as
        /// `ConversationSummary.id` and `DesignMockConversation.id`.
        let id: String
        /// Snapshot of the title as shown in the card list. We
        /// snapshot (rather than re-fetch on every sidebar render) so
        /// deleting a conversation doesn't turn its history row into
        /// a blank; the stale title stays visible and clicking it
        /// fails gracefully (no-op when the id is no longer in the
        /// fetch page).
        let title: String
        let source: String?
        let model: String?
        /// Primary timestamp shown on the right side of the card. Kept
        /// as a pre-formatted string because the shell stores it that
        /// way on `DesignMockConversation.updated` / `ConversationSummary.primaryTime`.
        let primaryTime: String?
        /// When the user last opened this thread. Drives the sort
        /// (most-recent first) and lets the eviction step pick a
        /// victim without needing a separate counter.
        let openedAt: Date
    }

    @Published private(set) var entries: [Entry] = []

    private let defaults: UserDefaults
    private let storageKey: String
    private let cap: Int

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = "madini.recentThreads.v1",
        cap: Int = 20
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.cap = cap
        load()
    }

    /// Record a conversation the user just opened. Move-to-top
    /// semantics: if the id is already in the list, it bubbles up and
    /// the old row is removed so duplicates never accumulate. Oldest
    /// entries beyond `cap` are evicted.
    func record(
        id: String,
        title: String,
        source: String?,
        model: String?,
        primaryTime: String?
    ) {
        let entry = Entry(
            id: id,
            title: title,
            source: source,
            model: model,
            primaryTime: primaryTime,
            openedAt: Date()
        )
        entries.removeAll { $0.id == id }
        entries.insert(entry, at: 0)
        if entries.count > cap {
            entries = Array(entries.prefix(cap))
        }
        save()
    }

    /// Forget every entry. Exposed for a future "Clear history"
    /// context-menu action; unused today but intentionally kept in
    /// the API so the store owns all mutations.
    func clearAll() {
        entries = []
        save()
    }

    /// Drop a single entry (for right-click "Remove from history").
    func remove(id: String) {
        let before = entries.count
        entries.removeAll { $0.id == id }
        if entries.count != before {
            save()
        }
    }

    // MARK: - Persistence

    private func load() {
        guard let data = defaults.data(forKey: storageKey) else { return }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            entries = try decoder.decode([Entry].self, from: data)
        } catch {
            // Corrupt / version-skew payload. Rather than holding the
            // user hostage to a parse failure, drop the whole store
            // and start fresh — history is disposable by nature.
            entries = []
            defaults.removeObject(forKey: storageKey)
        }
    }

    private func save() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(entries)
            defaults.set(data, forKey: storageKey)
        } catch {
            // Encoding a concrete Codable with ISO-8601 dates isn't
            // expected to fail — but if it does, swallow silently
            // rather than crashing a read-only sidebar surface. The
            // next `record` attempt will try again.
        }
    }
}
