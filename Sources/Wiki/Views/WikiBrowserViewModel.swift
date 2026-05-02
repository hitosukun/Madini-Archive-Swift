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

    // MARK: - Dependencies

    private let services: AppServices

    init(services: AppServices) {
        self.services = services
    }

    // MARK: - Vault list

    func reloadVaults() async {
        do {
            vaults = try await services.wikiVaults.listVaults(offset: 0, limit: 1000)
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
            let indexer = try services.wikiIndexCoordinator.indexer(for: vault)
            let stats = try await indexer.indexVault(vault)
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

    /// Resolve a `[[wikilink]]` target to a page in the current vault by
    /// prefix-matching the path's filename portion (Obsidian semantics).
    /// Returns the matched relative path if any.
    func resolveWikilink(target: String) -> String? {
        let lowered = target.lowercased()
        // Exact path match first (e.g. `notes/sub/page` from a literal link).
        if let direct = pages.first(where: {
            $0.path.lowercased() == "\(lowered).md" ||
            $0.path.lowercased() == lowered
        }) {
            return direct.path
        }
        // Otherwise prefix-match the filename without extension.
        let match = pages.first { page in
            let filename = (page.path as NSString).lastPathComponent
            let stem = filename.hasSuffix(".md")
                ? String(filename.dropLast(3))
                : filename
            return stem.lowercased().hasPrefix(lowered)
        }
        return match?.path
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
}
