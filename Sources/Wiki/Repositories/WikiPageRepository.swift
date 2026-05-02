import Foundation

struct WikiPageSearchResult: Identifiable, Hashable, Sendable {
    let pageID: Int
    let vaultID: String
    let path: String
    let title: String?
    let snippet: String
    let lastModified: String

    var id: Int { pageID }
}

protocol WikiPageRepository: Sendable {
    // MARK: - Read

    func fetchPage(id: Int) async throws -> WikiPage?
    func fetchPageByPath(vaultID: String, path: String) async throws -> WikiPage?
    func listPages(vaultID: String, offset: Int, limit: Int) async throws -> [WikiPage]
    func searchPages(vaultID: String, query: String, offset: Int, limit: Int) async throws -> [WikiPageSearchResult]
    func count(vaultID: String) async throws -> Int

    // MARK: - Write (index cache only)

    func upsertPage(_ page: WikiPage) async throws
    func deletePage(vaultID: String, path: String) async throws
    func deleteAllPages(vaultID: String) async throws
}
