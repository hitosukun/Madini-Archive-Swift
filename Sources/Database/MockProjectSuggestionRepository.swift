import Foundation

actor MockProjectSuggestionRepository: ProjectSuggestionRepository {
    private struct Key: Hashable {
        let threadId: String
        let projectId: String
    }

    private var suggestions: [Key: ProjectSuggestion]

    init(suggestions: [ProjectSuggestion] = []) {
        self.suggestions = Dictionary(
            uniqueKeysWithValues: suggestions.map {
                (Key(threadId: $0.threadId, projectId: $0.targetProjectId), $0)
            }
        )
    }

    func topPendingSuggestion(threadId: String) async throws -> ProjectSuggestion? {
        suggestions.values
            .filter { $0.threadId == threadId && $0.state == .pending }
            .sorted {
                if $0.score != $1.score {
                    return $0.score > $1.score
                }
                return $0.targetProjectId < $1.targetProjectId
            }
            .first
    }

    func suggestions(threadId: String) async throws -> [ProjectSuggestion] {
        suggestions.values
            .filter { $0.threadId == threadId }
            .sorted {
                if $0.state != $1.state {
                    return stateRank($0.state) < stateRank($1.state)
                }
                if $0.score != $1.score {
                    return $0.score > $1.score
                }
                return $0.targetProjectId < $1.targetProjectId
            }
    }

    func upsertSuggestion(_ suggestion: ProjectSuggestion) async throws {
        suggestions[Key(threadId: suggestion.threadId, projectId: suggestion.targetProjectId)] = suggestion
    }

    func markAccepted(threadId: String, targetProjectId: String) async throws {
        update(threadId: threadId, targetProjectId: targetProjectId, state: .accepted)
        for suggestion in suggestions.values where suggestion.threadId == threadId
            && suggestion.targetProjectId != targetProjectId
            && suggestion.state == .pending {
            update(threadId: threadId, targetProjectId: suggestion.targetProjectId, state: .dismissed)
        }
    }

    func markDismissed(threadId: String, targetProjectId: String) async throws {
        update(threadId: threadId, targetProjectId: targetProjectId, state: .dismissed)
    }

    func dismissedTokens(projectId: String) async throws -> [String: Int] {
        var counts: [String: Int] = [:]
        for suggestion in suggestions.values where suggestion.targetProjectId == projectId
            && suggestion.state == .dismissed {
            for token in suggestion.reason.flatMap(tokens) {
                counts[token, default: 0] += 1
            }
        }
        return counts
    }

    private func update(threadId: String, targetProjectId: String, state: SuggestionState) {
        let key = Key(threadId: threadId, projectId: targetProjectId)
        guard let existing = suggestions[key] else { return }
        suggestions[key] = ProjectSuggestion(
            threadId: existing.threadId,
            targetProjectId: existing.targetProjectId,
            score: existing.score,
            reason: existing.reason,
            state: state,
            createdAt: existing.createdAt,
            updatedAt: Date()
        )
    }

    private func stateRank(_ state: SuggestionState) -> Int {
        switch state {
        case .pending: return 0
        case .accepted: return 1
        case .dismissed: return 2
        }
    }

    private func tokens(from value: String) -> [String] {
        value
            .lowercased()
            .split { character in
                !character.isLetter && !character.isNumber
            }
            .map(String.init)
            .filter { !$0.isEmpty }
    }
}
