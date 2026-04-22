import Foundation

final class TFIDFProjectSuggester: ProjectSuggester, @unchecked Sendable {
    static let suggestionThreshold = 0.4
    static let suggestionTopN = 3

    private let conversations: any ConversationRepository
    private let projects: any ProjectRepository
    private let memberships: any ProjectMembershipRepository
    private let suggestions: any ProjectSuggestionRepository
    private let pageSize: Int

    init(
        conversations: any ConversationRepository,
        projects: any ProjectRepository,
        memberships: any ProjectMembershipRepository,
        suggestions: any ProjectSuggestionRepository,
        pageSize: Int = 200
    ) {
        self.conversations = conversations
        self.projects = projects
        self.memberships = memberships
        self.suggestions = suggestions
        self.pageSize = pageSize
    }

    func suggest(threadId: String, topN: Int = TFIDFProjectSuggester.suggestionTopN) async throws -> [ProjectSuggestion] {
        guard let threadText = try await conversationText(threadId: threadId),
              !threadText.isEmpty else {
            return []
        }

        let projectList = try await allProjects()
        guard !projectList.isEmpty else {
            return []
        }

        var projectDocuments: [(Project, String)] = []
        for project in projectList {
            let text = try await projectCorpusText(projectId: project.id)
            guard !text.isEmpty else { continue }
            projectDocuments.append((project, text))
        }

        guard !projectDocuments.isEmpty else {
            return []
        }

        let threadCounts = Self.tokenCounts(threadText)
        let projectCounts = projectDocuments.map { ($0.0, Self.tokenCounts($0.1)) }
        let documentCounts = [threadCounts] + projectCounts.map(\.1)
        let idf = Self.inverseDocumentFrequency(documentCounts)
        let threadVector = Self.weightedVector(threadCounts, idf: idf)
        let now = Date()

        var ranked: [ProjectSuggestion] = []
        for (project, counts) in projectCounts {
            let projectVector = Self.weightedVector(counts, idf: idf)
            let rawScore = Self.cosine(threadVector, projectVector)
            let penalty = Self.dismissPenalty(
                threadTokens: Set(threadCounts.keys),
                dismissedTokens: try await suggestions.dismissedTokens(projectId: project.id)
            )
            let score = max(0, min(1, rawScore * (1 - penalty)))
            guard score >= Self.suggestionThreshold else {
                continue
            }

            ranked.append(ProjectSuggestion(
                threadId: threadId,
                targetProjectId: project.id,
                score: score,
                reason: Self.reasonTerms(threadVector: threadVector, projectVector: projectVector),
                state: .pending,
                createdAt: now,
                updatedAt: now
            ))
        }

        return Array(
            ranked
                .sorted {
                    if $0.score != $1.score {
                        return $0.score > $1.score
                    }
                    return $0.targetProjectId < $1.targetProjectId
                }
                .prefix(max(topN, 0))
        )
    }

    func rebuildCorpus(projectId: String) async throws {
        // v1 keeps corpus construction on demand so the cache layer stays
        // rebuildable and never becomes canonical state.
    }

    func rebuildAllCorpora() async throws {
        // See rebuildCorpus(projectId:). This hook is intentionally present
        // so a persistent cache can be added without changing import/UI code.
    }

    private func allProjects() async throws -> [Project] {
        var result: [Project] = []
        var offset = 0
        while true {
            let page = try await projects.listProjects(offset: offset, limit: pageSize)
            result.append(contentsOf: page)
            if page.count < pageSize {
                break
            }
            offset += pageSize
        }
        return result
    }

    private func projectCorpusText(projectId: String) async throws -> String {
        var chunks: [String] = []
        var offset = 0
        while true {
            let page = try await memberships.threadsInProject(projectId: projectId, offset: offset, limit: pageSize)
            for item in page {
                if let text = try await conversationText(threadId: item.id), !text.isEmpty {
                    chunks.append(text)
                }
            }
            if page.count < pageSize {
                break
            }
            offset += pageSize
        }
        return chunks.joined(separator: "\n\n")
    }

    private func conversationText(threadId: String) async throws -> String? {
        guard let detail = try await conversations.fetchDetail(id: threadId) else {
            return nil
        }
        return detail.messages
            .map(\.content)
            .joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func tokenCounts(_ text: String) -> [String: Double] {
        var counts: [String: Double] = [:]
        for token in tokenize(text) {
            counts[token, default: 0] += 1
        }
        return counts
    }

    private static func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        var asciiBuffer = ""
        var nonASCIIBuffer = ""

        func flushASCII() {
            if asciiBuffer.count >= 2 {
                tokens.append(asciiBuffer)
            }
            asciiBuffer = ""
        }

        func flushNonASCII() {
            let characters = Array(nonASCIIBuffer)
            if characters.count == 1 {
                tokens.append(String(characters[0]))
            } else if characters.count > 1 {
                for index in 0..<(characters.count - 1) {
                    tokens.append(String(characters[index...index + 1]))
                }
            }
            nonASCIIBuffer = ""
        }

        for character in text.lowercased() {
            guard character.isLetter || character.isNumber else {
                flushASCII()
                flushNonASCII()
                continue
            }

            if character.unicodeScalars.allSatisfy(\.isASCII) {
                flushNonASCII()
                asciiBuffer.append(character)
            } else {
                flushASCII()
                nonASCIIBuffer.append(character)
            }
        }

        flushASCII()
        flushNonASCII()
        return tokens.filter { $0.count <= 50 }
    }

    private static func inverseDocumentFrequency(_ documents: [[String: Double]]) -> [String: Double] {
        var documentFrequency: [String: Int] = [:]
        for document in documents {
            for token in document.keys {
                documentFrequency[token, default: 0] += 1
            }
        }

        let documentCount = Double(max(documents.count, 1))
        return documentFrequency.mapValues { frequency in
            log((documentCount + 1) / (Double(frequency) + 1)) + 1
        }
    }

    private static func weightedVector(_ counts: [String: Double], idf: [String: Double]) -> [String: Double] {
        counts.mapValues { value in value }
            .reduce(into: [String: Double]()) { result, entry in
                result[entry.key] = entry.value * (idf[entry.key] ?? 1)
            }
    }

    private static func cosine(_ lhs: [String: Double], _ rhs: [String: Double]) -> Double {
        guard !lhs.isEmpty, !rhs.isEmpty else {
            return 0
        }

        let dot = lhs.reduce(0) { partial, entry in
            partial + entry.value * (rhs[entry.key] ?? 0)
        }
        let leftNorm = sqrt(lhs.values.reduce(0) { $0 + $1 * $1 })
        let rightNorm = sqrt(rhs.values.reduce(0) { $0 + $1 * $1 })
        guard leftNorm > 0, rightNorm > 0 else {
            return 0
        }
        return dot / (leftNorm * rightNorm)
    }

    private static func dismissPenalty(threadTokens: Set<String>, dismissedTokens: [String: Int]) -> Double {
        guard !threadTokens.isEmpty, !dismissedTokens.isEmpty else {
            return 0
        }

        let overlapWeight = threadTokens.reduce(0) { partial, token in
            partial + Double(dismissedTokens[token] ?? 0)
        }
        return min(0.3, overlapWeight / Double(threadTokens.count * 3))
    }

    private static func reasonTerms(
        threadVector: [String: Double],
        projectVector: [String: Double]
    ) -> [String] {
        threadVector.compactMap { token, threadWeight -> (String, Double)? in
            guard token.count <= 50,
                  let projectWeight = projectVector[token],
                  projectWeight > 0 else {
                return nil
            }
            return (token, threadWeight * projectWeight)
        }
        .sorted {
            if $0.1 != $1.1 {
                return $0.1 > $1.1
            }
            return $0.0 < $1.0
        }
        .prefix(5)
        .map(\.0)
    }
}
