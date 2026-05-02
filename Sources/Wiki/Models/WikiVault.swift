import Foundation

struct WikiVault: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let path: String
    let bookmarkData: Data?
    let createdAt: String
    let lastIndexedAt: String?
}
