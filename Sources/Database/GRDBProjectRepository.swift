import Foundation
import GRDB

final class GRDBProjectRepository: ProjectRepository, @unchecked Sendable {
    private let dbQueue: DatabaseQueue

    init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    func listProjects(offset: Int, limit: Int) async throws -> [Project] {
        try await GRDBAsync.read(from: dbQueue) { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, name, origin, created_at, updated_at
                    FROM projects
                    ORDER BY LOWER(name) ASC, id ASC
                    LIMIT ? OFFSET ?
                """,
                arguments: [limit, offset]
            )
            return rows.map(Self.makeProject)
        }
    }

    func project(id: String) async throws -> Project? {
        try await GRDBAsync.read(from: dbQueue) { db in
            let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT id, name, origin, created_at, updated_at
                    FROM projects
                    WHERE id = ?
                    LIMIT 1
                """,
                arguments: [id]
            )
            return row.map(Self.makeProject)
        }
    }

    func upsertCanonicalProject(id: String, name: String) async throws -> Project {
        let id = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else {
            throw ProjectRepositoryError.emptyProjectID
        }
        let name = try Self.normalizedName(name)
        let now = Date()
        let timestamp = GRDBProjectDateCodec.string(from: now)

        return try await GRDBAsync.write(to: dbQueue) { db in
            try db.execute(
                sql: """
                    INSERT INTO projects (id, name, origin, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        name = excluded.name,
                        origin = excluded.origin,
                        updated_at = excluded.updated_at
                """,
                arguments: [
                    id,
                    name,
                    ProjectOrigin.canonicalImport.rawValue,
                    timestamp,
                    timestamp
                ]
            )
            let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT id, name, origin, created_at, updated_at
                    FROM projects
                    WHERE id = ?
                    LIMIT 1
                """,
                arguments: [id]
            )
            return row.map(Self.makeProject) ?? Project(
                id: id,
                name: name,
                origin: .canonicalImport,
                createdAt: now,
                updatedAt: now
            )
        }
    }

    func createUserProject(name: String) async throws -> Project {
        let name = try Self.normalizedName(name)
        let now = Date()
        let project = Project(
            id: UUID().uuidString,
            name: name,
            origin: .userCreated,
            createdAt: now,
            updatedAt: now
        )

        try await GRDBAsync.write(to: dbQueue) { db in
            try db.execute(
                sql: """
                    INSERT INTO projects (id, name, origin, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?)
                """,
                arguments: [
                    project.id,
                    project.name,
                    project.origin.rawValue,
                    GRDBProjectDateCodec.string(from: project.createdAt),
                    GRDBProjectDateCodec.string(from: project.updatedAt)
                ]
            )
        }

        return project
    }

    func renameProject(id: String, to name: String) async throws {
        let name = try Self.normalizedName(name)
        let updatedAt = GRDBProjectDateCodec.string(from: Date())

        try await GRDBAsync.write(to: dbQueue) { db in
            try db.execute(
                sql: """
                    UPDATE projects
                    SET name = ?, updated_at = ?
                    WHERE id = ?
                """,
                arguments: [name, updatedAt, id]
            )
        }
    }

    func deleteProject(id: String) async throws {
        try await GRDBAsync.write(to: dbQueue) { db in
            try db.execute(
                sql: "DELETE FROM projects WHERE id = ?",
                arguments: [id]
            )
        }
    }

    func threadCounts() async throws -> ProjectCounts {
        try await GRDBAsync.read(from: dbQueue) { db in
            let all = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM conversations") ?? 0
            let projectRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT project_id, COUNT(*) AS count
                    FROM project_memberships
                    GROUP BY project_id
                """
            )
            let byProject = Dictionary(
                uniqueKeysWithValues: projectRows.compactMap { row -> (String, Int)? in
                    guard let projectID: String = row["project_id"] else { return nil }
                    return (projectID, row["count"] ?? 0)
                }
            )
            let inbox = try Self.countUnassigned(db: db, hasSuggestion: true)
            let orphans = try Self.countUnassigned(db: db, hasSuggestion: false)
            return ProjectCounts(all: all, byProject: byProject, inbox: inbox, orphans: orphans)
        }
    }

    private static func countUnassigned(db: Database, hasSuggestion: Bool) throws -> Int {
        let suggestionPredicate = hasSuggestion ? "EXISTS" : "NOT EXISTS"
        return try Int.fetchOne(
            db,
            sql: """
                SELECT COUNT(*)
                FROM conversations c
                WHERE NOT EXISTS (
                    SELECT 1
                    FROM project_memberships pm
                    WHERE pm.thread_id = c.id
                )
                AND \(suggestionPredicate) (
                    SELECT 1
                    FROM project_suggestions ps
                    WHERE ps.thread_id = c.id
                      AND ps.state = 'pending'
                )
            """
        ) ?? 0
    }

    private static func makeProject(_ row: Row) -> Project {
        Project(
            id: row["id"],
            name: row["name"],
            origin: ProjectOrigin(rawValue: row["origin"] ?? "") ?? .userCreated,
            createdAt: GRDBProjectDateCodec.date(from: row["created_at"]),
            updatedAt: GRDBProjectDateCodec.date(from: row["updated_at"])
        )
    }

    private static func normalizedName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ProjectRepositoryError.emptyProjectName
        }
        return trimmed
    }
}
