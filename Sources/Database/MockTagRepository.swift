import Foundation

actor MockTagRepository: TagRepository {
    private var tags: [TagEntry] = []
    private var tagAssignments: [Int: Set<String>] = [:] // tagID -> conversationIDs
    private var nextID = 1

    init(seed: [String] = ["Favorite", "Follow-up"]) {
        for name in seed {
            tags.append(
                TagEntry(
                    id: nextID,
                    name: name,
                    isSystem: false,
                    systemKey: nil,
                    usageCount: 0,
                    createdAt: "",
                    updatedAt: ""
                )
            )
            nextID += 1
        }
    }

    func listTags() -> [TagEntry] {
        tags.sorted { lhs, rhs in
            if lhs.isSystem != rhs.isSystem {
                return lhs.isSystem && !rhs.isSystem
            }
            return lhs.name.lowercased() < rhs.name.lowercased()
        }
        .map { entry in
            TagEntry(
                id: entry.id,
                name: entry.name,
                isSystem: entry.isSystem,
                systemKey: entry.systemKey,
                usageCount: tagAssignments[entry.id]?.count ?? 0,
                createdAt: entry.createdAt,
                updatedAt: entry.updatedAt
            )
        }
    }

    func findTagByName(_ name: String) -> TagEntry? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return tags.first { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }
    }

    func createTag(name: String) throws -> TagEntry {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw TagRepositoryError.emptyName
        }

        let entry = TagEntry(
            id: nextID,
            name: trimmed,
            isSystem: false,
            systemKey: nil,
            usageCount: 0,
            createdAt: "",
            updatedAt: ""
        )
        nextID += 1
        tags.append(entry)
        return entry
    }

    func renameTag(id: Int, name: String) throws -> TagEntry {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw TagRepositoryError.emptyName
        }

        guard let index = tags.firstIndex(where: { $0.id == id && !$0.isSystem }) else {
            throw TagRepositoryError.notFound
        }

        let updated = TagEntry(
            id: id,
            name: trimmed,
            isSystem: tags[index].isSystem,
            systemKey: tags[index].systemKey,
            usageCount: tagAssignments[id]?.count ?? 0,
            createdAt: tags[index].createdAt,
            updatedAt: ""
        )
        tags[index] = updated
        return updated
    }

    func deleteTag(id: Int) {
        tags.removeAll(where: { $0.id == id && !$0.isSystem })
        tagAssignments[id] = nil
    }

    func bindings(forConversationIDs ids: [String]) -> [String: ConversationTagBinding] {
        var result: [String: ConversationTagBinding] = [:]
        for conversationID in ids {
            let attachedTags = tags.filter { tag in
                tagAssignments[tag.id]?.contains(conversationID) == true
            }
            result[conversationID] = ConversationTagBinding(
                conversationID: conversationID,
                tags: attachedTags,
                bookmarkID: attachedTags.isEmpty ? nil : 1
            )
        }
        return result
    }

    @discardableResult
    func attachTag(tagID: Int, toConversationID conversationID: String, payload: [String: String]) -> Int {
        tagAssignments[tagID, default: []].insert(conversationID)
        return 1
    }

    func detachTag(tagID: Int, fromConversationID conversationID: String) {
        tagAssignments[tagID]?.remove(conversationID)
    }
}
