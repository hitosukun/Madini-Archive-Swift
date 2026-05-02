import Foundation

struct WikiPage: Identifiable, Hashable, Sendable {
    let id: Int
    let vaultID: String
    let path: String
    let title: String?
    let frontmatterJSON: String?
    let body: String
    let lastModified: String
}
