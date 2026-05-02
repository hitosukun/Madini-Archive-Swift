import Foundation

protocol WikiVaultRepository: Sendable {
    func listVaults(offset: Int, limit: Int) async throws -> [WikiVault]
    func vault(id: String) async throws -> WikiVault?
    func registerVault(name: String, path: String, bookmarkData: Data?) async throws -> WikiVault
    func updateBookmarkData(vaultID: String, bookmarkData: Data?) async throws
    func updateLastIndexedAt(vaultID: String, timestamp: String) async throws
    func unregisterVault(id: String) async throws
}
