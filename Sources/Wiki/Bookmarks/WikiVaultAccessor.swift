import Foundation

/// Resolves a vault's security-scoped bookmark and keeps the access
/// claim alive for the lifetime of the app.
///
/// macOS's TCC (Transparency, Consent, Control) layer prompts the user
/// once when an app reads from `~/Documents`, `~/Desktop`,
/// `~/Downloads`, or iCloud Drive. The prompt only auto-suppresses
/// for subsequent launches if the app reads the path through a
/// security-scoped bookmark obtained from the original NSOpenPanel
/// approval — without the bookmark resolve, every launch reads from a
/// raw path and TCC re-prompts every time.
///
/// This accessor:
///   1. Resolves the bookmark (or falls back to the raw path).
///   2. Starts security-scoped access; the URL stays valid until
///      `closeAll()` runs (app shutdown).
///   3. Refreshes a stale bookmark by writing a new one back to
///      `wiki_vaults.bookmark_data` so the next launch resolves
///      cleanly.
///
/// Usage: call `openVault(_:)` whenever you need a `URL` for the vault
/// (indexing, embed rendering). Repeated calls return the cached URL
/// without restarting access.
@MainActor
final class WikiVaultAccessor {
    private struct OpenAccess {
        let url: URL
        let claimedScope: Bool
    }

    private var openVaults: [String: OpenAccess] = [:]
    private let vaultRepository: any WikiVaultRepository

    init(vaultRepository: any WikiVaultRepository) {
        self.vaultRepository = vaultRepository
    }

    deinit {
        // Best-effort scope teardown; the OS reclaims any leftovers
        // when the app terminates anyway.
        for access in openVaults.values where access.claimedScope {
            access.url.stopAccessingSecurityScopedResource()
        }
    }

    /// Resolve the vault's stored bookmark and return a usable URL.
    /// Falls back to `WikiVault.path` if the bookmark is missing or
    /// fails to resolve. Idempotent — second call for the same vault
    /// returns the cached URL.
    @discardableResult
    func openVault(_ vault: WikiVault) async -> URL? {
        if let cached = openVaults[vault.id]?.url {
            return cached
        }

        // 1. Try the bookmark first.
        if let data = vault.bookmarkData {
            var stale = false
            if let url = try? URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ) {
                let claimed = url.startAccessingSecurityScopedResource()
                openVaults[vault.id] = OpenAccess(url: url, claimedScope: claimed)
                if stale {
                    await refreshBookmark(for: vault, currentURL: url)
                }
                return url
            }
        }

        // 2. Fall back to the raw path (works when sandbox is off and
        //    TCC has already approved the directory). We still record
        //    a "no-scope-claimed" entry so subsequent calls don't keep
        //    retrying bookmark resolve.
        let fallback = URL(fileURLWithPath: vault.path)
        if FileManager.default.fileExists(atPath: fallback.path) {
            openVaults[vault.id] = OpenAccess(url: fallback, claimedScope: false)
            return fallback
        }

        return nil
    }

    /// Drop a vault's access claim. Called when the user unregisters a
    /// vault. The URL becomes unusable after this; callers must
    /// re-open if they need access again.
    func closeVault(id: String) {
        guard let access = openVaults.removeValue(forKey: id) else { return }
        if access.claimedScope {
            access.url.stopAccessingSecurityScopedResource()
        }
    }

    /// Release every active scope claim. Intended for orderly shutdown.
    func closeAll() {
        for (_, access) in openVaults where access.claimedScope {
            access.url.stopAccessingSecurityScopedResource()
        }
        openVaults.removeAll()
    }

    // MARK: - Private

    /// Generate a fresh bookmark from the resolved URL and persist it.
    /// Best-effort — failures are non-fatal because the next launch
    /// will fall back to the raw path until the user re-grants access.
    private func refreshBookmark(for vault: WikiVault, currentURL url: URL) async {
        guard let newData = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else { return }
        try? await vaultRepository.updateBookmarkData(
            vaultID: vault.id, bookmarkData: newData
        )
    }
}
