import Foundation
import SwiftUI

/// Owns the user-facing state of the Wiki feature: which vaults exist,
/// which one is currently open, which page is shown, and the loaded
/// page content.
///
/// The view model is `@MainActor` because it drives SwiftUI views; all
/// repository / indexer calls bridge from background queues via async
/// helpers in `GRDBAsync` / `WikiIndexer`. No GRDB types appear in the
/// view-facing API surface.
@MainActor
@Observable
final class WikiBrowserViewModel {
    // MARK: - Published state

    var vaults: [WikiVault] = []
    var selectedVaultID: String?
    var pages: [WikiPage] = []
    var selectedPagePath: String?
    var currentPage: WikiPage?
    var indexingMessage: String?
    var errorMessage: String?

    /// Free-text search query. UI binds to this; setter is sync-only —
    /// `runSearch()` performs the actual lookup.
    var searchQuery: String = ""
    var searchResults: [WikiPageSearchResult] = []
    var searchIsActive: Bool = false

    // MARK: - Dependencies

    private let services: AppServices

    init(services: AppServices) {
        self.services = services
    }

    // MARK: - Vault list

    func reloadVaults() async {
        do {
            vaults = try await services.wikiVaults.listVaults(offset: 0, limit: 1000)
            // Open security-scoped access for every registered vault on
            // load so subsequent file reads (indexing, embed rendering)
            // happen under the bookmark TCC has already approved.
            // Without this the user sees a Documents-folder prompt on
            // every launch.
            for vault in vaults {
                _ = await services.wikiVaultAccessor.openVault(vault)
            }
        } catch {
            errorMessage = "Failed to load vaults: \(error.localizedDescription)"
        }
    }

    /// Register a new vault, persist its security-scoped bookmark, and
    /// kick off the initial index. Returns the registered vault id on
    /// success.
    @discardableResult
    func registerVault(at url: URL) async -> WikiVault? {
        let bookmarkData = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        do {
            let vault = try await services.wikiVaults.registerVault(
                name: url.lastPathComponent,
                path: url.path,
                bookmarkData: bookmarkData
            )
            await reloadVaults()
            await reindex(vault: vault)
            return vault
        } catch {
            errorMessage = "Failed to register vault: \(error.localizedDescription)"
            return nil
        }
    }

    func unregisterVault(_ vault: WikiVault) async {
        do {
            try await services.wikiVaults.unregisterVault(id: vault.id)
            services.wikiIndexCoordinator.forgetVault(id: vault.id)
            services.wikiVaultAccessor.closeVault(id: vault.id)
            if selectedVaultID == vault.id {
                selectedVaultID = nil
                pages = []
                currentPage = nil
            }
            await reloadVaults()
        } catch {
            errorMessage = "Failed to remove vault: \(error.localizedDescription)"
        }
    }

    func reindex(vault: WikiVault) async {
        indexingMessage = "Indexing \(vault.name)…"
        defer { indexingMessage = nil }
        do {
            let vaultURL = await services.wikiVaultAccessor.openVault(vault)
            let indexer = try services.wikiIndexCoordinator.indexer(for: vault)
            let stats = try await indexer.indexVault(vault, vaultURL: vaultURL)
            try await services.wikiVaults.updateLastIndexedAt(
                vaultID: vault.id,
                timestamp: TimestampFormatter.now()
            )
            await reloadVaults()
            indexingMessage = "Indexed \(stats.upserted) page(s)"
            if selectedVaultID == vault.id {
                await reloadPages()
            }
        } catch {
            errorMessage = "Indexing failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Page list

    func selectVault(id: String?) async {
        selectedVaultID = id
        selectedPagePath = nil
        currentPage = nil
        pages = []
        guard let id, let _ = vaults.first(where: { $0.id == id }) else { return }
        await reloadPages()
    }

    func reloadPages() async {
        guard let vaultID = selectedVaultID,
              let vault = vaults.first(where: { $0.id == vaultID }) else {
            pages = []
            return
        }
        do {
            let repo = try services.wikiIndexCoordinator.pageRepository(for: vault)
            pages = try await repo.listPages(vaultID: vault.id, offset: 0, limit: 5000)
        } catch {
            errorMessage = "Failed to load pages: \(error.localizedDescription)"
        }
    }

    // MARK: - Page detail

    func selectPage(path: String?) async {
        selectedPagePath = path
        guard let path, let vaultID = selectedVaultID,
              let vault = vaults.first(where: { $0.id == vaultID }) else {
            currentPage = nil
            return
        }
        do {
            let repo = try services.wikiIndexCoordinator.pageRepository(for: vault)
            currentPage = try await repo.fetchPageByPath(vaultID: vaultID, path: path)
        } catch {
            errorMessage = "Failed to load page: \(error.localizedDescription)"
            currentPage = nil
        }
    }

    /// Resolve a `[[wikilink]]` target to a page in the current vault.
    /// See `WikilinkResolver.resolve` for the match precedence — exact
    /// path → filename → title → suffix `_<target>` → token → prefix.
    func resolveWikilink(target: String) -> String? {
        WikilinkResolver.resolve(target: target, in: pages)
    }

    /// Navigate to a wikilink target within the current vault. No-op if
    /// the target can't be resolved.
    func navigateToWikilink(target: String) async {
        guard let path = resolveWikilink(target: target) else {
            errorMessage = "No page found for [[\(target)]]"
            return
        }
        await selectPage(path: path)
    }

    var currentVault: WikiVault? {
        selectedVaultID.flatMap { id in vaults.first { $0.id == id } }
    }

    // MARK: - Search

    /// Run the search using the current `searchQuery`. Empty query
    /// clears any active result set.
    func runSearch() async {
        let parsed = WikiSearchQueryParser.parse(searchQuery)
        guard !parsed.isEmpty else {
            searchResults = []
            searchIsActive = false
            return
        }
        searchIsActive = true
        guard let vaultID = selectedVaultID,
              let vault = currentVault else {
            searchResults = []
            return
        }
        do {
            let repo = try services.wikiIndexCoordinator.pageRepository(for: vault)
            // Path 1: only frontmatter filters → in-memory filter against
            // the already-loaded page list (no FTS hop).
            // Path 2: FTS query (with or without filters) → run FTS first,
            // then filter the hits.
            let candidates: [WikiPage]
            if parsed.hasFTS {
                let hits = try await repo.searchPages(
                    vaultID: vaultID,
                    query: parsed.ftsQuery,
                    offset: 0,
                    limit: 200
                )
                let hitPaths = Set(hits.map(\.path))
                let pagesByPath = Dictionary(uniqueKeysWithValues: pages.map { ($0.path, $0) })
                candidates = hits.compactMap { pagesByPath[$0.path] }
                searchResults = hits
                    .filter { hit in
                        guard let page = pagesByPath[hit.path] else { return false }
                        return WikiSearchQueryParser.passesFilters(
                            page, filters: parsed.frontmatterFilters
                        )
                    }
                _ = hitPaths
                _ = candidates
            } else {
                // Filter-only query: walk the in-memory page list.
                searchResults = pages
                    .filter {
                        WikiSearchQueryParser.passesFilters(
                            $0, filters: parsed.frontmatterFilters
                        )
                    }
                    .map { page in
                        WikiPageSearchResult(
                            pageID: page.id, vaultID: page.vaultID,
                            path: page.path, title: page.title,
                            snippet: snippetForFilterOnly(page),
                            lastModified: page.lastModified
                        )
                    }
            }
        } catch {
            errorMessage = "Search failed: \(error.localizedDescription)"
        }
    }

    func clearSearch() {
        searchQuery = ""
        searchResults = []
        searchIsActive = false
    }

    private func snippetForFilterOnly(_ page: WikiPage) -> String {
        let body = page.body
        let prefix = body.prefix(120)
        return String(prefix)
    }
}
