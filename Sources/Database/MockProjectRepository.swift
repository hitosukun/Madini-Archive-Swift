import Foundation

actor MockProjectRepository: ProjectRepository {
    private var projects: [String: Project]

    init(projects: [Project] = MockProjectRepository.defaultProjects) {
        self.projects = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) })
    }

    func listProjects(offset: Int, limit: Int) async throws -> [Project] {
        let sorted = projects.values.sorted {
            if $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedSame {
                return $0.id < $1.id
            }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        let start = min(offset, sorted.count)
        let end = min(start + limit, sorted.count)
        return Array(sorted[start..<end])
    }

    func project(id: String) async throws -> Project? {
        projects[id]
    }

    func upsertCanonicalProject(id: String, name: String) async throws -> Project {
        let id = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else {
            throw ProjectRepositoryError.emptyProjectID
        }
        let name = try normalizedName(name)
        let existing = projects[id]
        let now = Date()
        let project = Project(
            id: id,
            name: name,
            origin: .canonicalImport,
            createdAt: existing?.createdAt ?? now,
            updatedAt: now
        )
        projects[id] = project
        return project
    }

    func createUserProject(name: String) async throws -> Project {
        let name = try normalizedName(name)
        let now = Date()
        let project = Project(
            id: UUID().uuidString,
            name: name,
            origin: .userCreated,
            createdAt: now,
            updatedAt: now
        )
        projects[project.id] = project
        return project
    }

    func renameProject(id: String, to name: String) async throws {
        let name = try normalizedName(name)
        guard let existing = projects[id] else { return }
        projects[id] = Project(
            id: existing.id,
            name: name,
            origin: existing.origin,
            createdAt: existing.createdAt,
            updatedAt: Date()
        )
    }

    func deleteProject(id: String) async throws {
        projects[id] = nil
    }

    func threadCounts() async throws -> ProjectCounts {
        ProjectCounts(
            all: PreviewData.conversations.count,
            byProject: [:],
            inbox: 0,
            orphans: PreviewData.conversations.count
        )
    }

    private func normalizedName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ProjectRepositoryError.emptyProjectName
        }
        return trimmed
    }

    private static let defaultProjects: [Project] = {
        let now = Date()
        return [
            Project(
                id: "mock-project-swiftui",
                name: "SwiftUI",
                origin: .canonicalImport,
                createdAt: now,
                updatedAt: now
            ),
            Project(
                id: "mock-project-archive",
                name: "Archive Design",
                origin: .canonicalImport,
                createdAt: now,
                updatedAt: now
            )
        ]
    }()
}
