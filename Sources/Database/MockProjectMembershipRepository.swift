import Foundation

actor MockProjectMembershipRepository: ProjectMembershipRepository {
    private var memberships: [String: ProjectMembership]
    private let conversations: [ConversationSummary]

    init(
        memberships: [ProjectMembership] = [],
        conversations: [ConversationSummary] = PreviewData.conversations
    ) {
        self.memberships = Dictionary(uniqueKeysWithValues: memberships.map { ($0.threadId, $0) })
        self.conversations = conversations
    }

    func membership(threadId: String) async throws -> ProjectMembership? {
        memberships[threadId]
    }

    func setMembership(_ membership: ProjectMembership) async throws {
        memberships[membership.threadId] = membership
    }

    func removeMembership(threadId: String) async throws {
        memberships[threadId] = nil
    }

    func threadsInProject(projectId: String, offset: Int, limit: Int) async throws -> [ConversationSummary] {
        let ids = Set(
            memberships.values
                .filter { $0.projectId == projectId }
                .map(\.threadId)
        )
        return paged(conversations.filter { ids.contains($0.id) }, offset: offset, limit: limit)
    }

    func unassignedThreads(hasSuggestion: Bool, offset: Int, limit: Int) async throws -> [ConversationSummary] {
        guard !hasSuggestion else {
            return []
        }
        let assignedIDs = Set(memberships.keys)
        return paged(conversations.filter { !assignedIDs.contains($0.id) }, offset: offset, limit: limit)
    }

    private func paged(_ items: [ConversationSummary], offset: Int, limit: Int) -> [ConversationSummary] {
        let sorted = items.sorted {
            let left = $0.primaryTime ?? ""
            let right = $1.primaryTime ?? ""
            return left == right ? $0.id < $1.id : left > right
        }
        let start = min(offset, sorted.count)
        let end = min(start + limit, sorted.count)
        return Array(sorted[start..<end])
    }
}
