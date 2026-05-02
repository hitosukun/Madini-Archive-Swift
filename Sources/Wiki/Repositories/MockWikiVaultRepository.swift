import Foundation

@MainActor
final class MockWikiVaultRepository: WikiVaultRepository, @unchecked Sendable {
    private var vaults: [String: WikiVault] = [:]

    func listVaults(offset: Int, limit: Int) async throws -> [WikiVault] {
        let sorted = vaults.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let end = min(offset + limit, sorted.count)
        guard offset < sorted.count else { return [] }
        return Array(sorted[offset..<end])
    }

    func vault(id: String) async throws -> WikiVault? {
        vaults[id]
    }

    func registerVault(name: String, path: String, bookmarkData: Data?) async throws -> WikiVault {
        let id = UUID().uuidString
        let vault = WikiVault(
            id: id, name: name, path: path,
            bookmarkData: bookmarkData,
            createdAt: "2026-01-01 00:00:00",
            lastIndexedAt: nil
        )
        vaults[id] = vault
        return vault
    }

    func updateBookmarkData(vaultID: String, bookmarkData: Data?) async throws {
        guard let existing = vaults[vaultID] else { return }
        vaults[vaultID] = WikiVault(
            id: existing.id, name: existing.name, path: existing.path,
            bookmarkData: bookmarkData,
            createdAt: existing.createdAt,
            lastIndexedAt: existing.lastIndexedAt
        )
    }

    func updateLastIndexedAt(vaultID: String, timestamp: String) async throws {
        guard let existing = vaults[vaultID] else { return }
        vaults[vaultID] = WikiVault(
            id: existing.id, name: existing.name, path: existing.path,
            bookmarkData: existing.bookmarkData,
            createdAt: existing.createdAt,
            lastIndexedAt: timestamp
        )
    }

    func unregisterVault(id: String) async throws {
        vaults.removeValue(forKey: id)
    }
}
