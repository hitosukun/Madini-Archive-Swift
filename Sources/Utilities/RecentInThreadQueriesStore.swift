import Foundation
import SwiftUI

/// Rolling history of free-text queries the user ran as find-in-page
/// searches inside an open thread (reader / viewer mode). Companion to
/// `LibraryViewModel.unifiedFilters` (library searches) and
/// `RecentThreadsStore` (recently-opened threads) — three disjoint
/// streams that together let the shell offer context-appropriate
/// suggestions in one place.
///
/// Why a separate store (not reuse `saved_filters`): an in-thread
/// query is a plain substring, not a composable `ArchiveSearchFilter`.
/// The two kinds rank differently (library = last-used filter set,
/// thread = last-used substring), and pinning / evicting them
/// together would muddle both lists. Keep them separate until a UX
/// need for interleaving materializes.
///
/// Persistence: UserDefaults-backed JSON, keyed globally. In-thread
/// history is not per-thread because the search field is global in
/// the shell — a user who searched "error" in three threads expects
/// the fourth thread's suggestion list to include it. Per-thread
/// scoping would shrink each list to a single entry in typical use.
///
/// Cap: 20 entries. Matches `RecentThreadsStore` so the two surfaces
/// have predictable footprints regardless of the mix.
@MainActor
final class RecentInThreadQueriesStore: ObservableObject {
    @Published private(set) var queries: [String] = []

    private let defaults: UserDefaults
    private let storageKey: String
    private let cap: Int

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = "madini.recentInThreadQueries.v1",
        cap: Int = 20
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        self.cap = cap
        load()
    }

    /// Record a query the user just ran inside a thread. Move-to-top
    /// semantics: if the string is already in the list, it bubbles up
    /// and the old row is removed so duplicates never accumulate.
    /// Matching is trimmed + case-sensitive — "foo" and "Foo" count
    /// as distinct queries because find-in-page is case-sensitive at
    /// the trigram layer; presenting them as one row would mislead
    /// about what will actually be searched on re-click.
    func record(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        queries.removeAll { $0 == trimmed }
        queries.insert(trimmed, at: 0)
        if queries.count > cap {
            queries = Array(queries.prefix(cap))
        }
        save()
    }

    /// Forget every entry. Kept in the API (unused today) so all
    /// mutations live on the store and a future "Clear history"
    /// context-menu doesn't have to reach into `@Published` state
    /// from the view layer.
    func clearAll() {
        queries = []
        save()
    }

    /// Drop a single entry (for a future right-click "Remove from
    /// history" affordance on the suggestion row).
    func remove(_ query: String) {
        let before = queries.count
        queries.removeAll { $0 == query }
        if queries.count != before {
            save()
        }
    }

    // MARK: - Persistence

    private func load() {
        guard let data = defaults.data(forKey: storageKey) else { return }
        do {
            queries = try JSONDecoder().decode([String].self, from: data)
        } catch {
            // Corrupt / version-skew payload. Drop rather than hold
            // the user hostage to a parse failure — history is
            // disposable by nature.
            queries = []
            defaults.removeObject(forKey: storageKey)
        }
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(queries)
            defaults.set(data, forKey: storageKey)
        } catch {
            // Encoding a `[String]` with the default encoder isn't
            // expected to fail. Swallow silently rather than crashing
            // a background record path; the next `record` attempt
            // will try again.
        }
    }
}
