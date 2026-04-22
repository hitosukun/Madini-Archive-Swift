import Foundation

protocol ProjectSuggester: Sendable {
    func suggest(threadId: String, topN: Int) async throws -> [ProjectSuggestion]
    func rebuildCorpus(projectId: String) async throws
    func rebuildAllCorpora() async throws
}

struct NoOpProjectSuggester: ProjectSuggester {
    func suggest(threadId: String, topN: Int) async throws -> [ProjectSuggestion] {
        []
    }

    func rebuildCorpus(projectId: String) async throws {}

    func rebuildAllCorpora() async throws {}
}
