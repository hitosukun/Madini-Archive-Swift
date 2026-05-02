import Foundation

@MainActor
final class MockWikiPageRepository: WikiPageRepository, @unchecked Sendable {
    private var pages: [Int: WikiPage] = [:]
    private var nextID = 1

    func fetchPage(id: Int) async throws -> WikiPage? {
        pages[id]
    }

    func fetchPageByPath(vaultID: String, path: String) async throws -> WikiPage? {
        pages.values.first { $0.vaultID == vaultID && $0.path == path }
    }

    func listPages(vaultID: String, offset: Int, limit: Int) async throws -> [WikiPage] {
        let filtered = pages.values
            .filter { $0.vaultID == vaultID }
            .sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
        let end = min(offset + limit, filtered.count)
        guard offset < filtered.count else { return [] }
        return Array(filtered[offset..<end])
    }

    func searchPages(vaultID: String, query: String, offset: Int, limit: Int) async throws -> [WikiPageSearchResult] {
        let q = query.lowercased()
        let matches = pages.values
            .filter { $0.vaultID == vaultID }
            .filter { ($0.title?.lowercased().contains(q) ?? false) || $0.body.lowercased().contains(q) }
            .sorted { $0.path < $1.path }
        let end = min(offset + limit, matches.count)
        guard offset < matches.count else { return [] }
        return matches[offset..<end].map { page in
            WikiPageSearchResult(
                pageID: page.id, vaultID: page.vaultID, path: page.path,
                title: page.title, snippet: String(page.body.prefix(80)),
                lastModified: page.lastModified
            )
        }
    }

    func count(vaultID: String) async throws -> Int {
        pages.values.filter { $0.vaultID == vaultID }.count
    }

    func upsertPage(_ page: WikiPage) async throws {
        if let existing = pages.values.first(where: { $0.vaultID == page.vaultID && $0.path == page.path }) {
            let updated = WikiPage(
                id: existing.id, vaultID: page.vaultID, path: page.path,
                title: page.title, frontmatterJSON: page.frontmatterJSON,
                body: page.body, lastModified: page.lastModified
            )
            pages[existing.id] = updated
        } else {
            let id = nextID
            nextID += 1
            let newPage = WikiPage(
                id: id, vaultID: page.vaultID, path: page.path,
                title: page.title, frontmatterJSON: page.frontmatterJSON,
                body: page.body, lastModified: page.lastModified
            )
            pages[id] = newPage
        }
    }

    func deletePage(vaultID: String, path: String) async throws {
        if let key = pages.first(where: { $0.value.vaultID == vaultID && $0.value.path == path })?.key {
            pages.removeValue(forKey: key)
        }
    }

    func deleteAllPages(vaultID: String) async throws {
        pages = pages.filter { $0.value.vaultID != vaultID }
    }
}
