import CryptoKit
import Foundation

struct JSONImportProjectReconciler {
    private struct ImportedThreadProjectMetadata {
        let threadID: String
        let projectID: String?
        let projectName: String?
    }

    @MainActor
    static func reconcileImportedFiles(_ urls: [URL], services: AppServices) async throws {
        for url in urls {
            let records = try records(from: url)
            for record in records {
                try await reconcile(record, services: services)
            }
        }
    }

    @MainActor
    private static func reconcile(_ record: ImportedThreadProjectMetadata, services: AppServices) async throws {
        let existingMembership = try await services.projectMemberships.membership(threadId: record.threadID)

        guard let projectID = record.projectID else {
            if existingMembership?.origin == .canonicalImport {
                try await services.projectMemberships.removeMembership(threadId: record.threadID)
                if let oldProjectID = existingMembership?.projectId {
                    try await services.projectSuggester.rebuildCorpus(projectId: oldProjectID)
                }
            }

            let dismissedTargets = Set(
                try await services.projectSuggestions.suggestions(threadId: record.threadID)
                    .filter { $0.state == .dismissed }
                    .map(\.targetProjectId)
            )
            let suggestions = try await services.projectSuggester.suggest(
                threadId: record.threadID,
                topN: TFIDFProjectSuggester.suggestionTopN
            )
            for suggestion in suggestions where !dismissedTargets.contains(suggestion.targetProjectId) {
                try await services.projectSuggestions.upsertSuggestion(suggestion)
            }
            return
        }

        let projectName = record.projectName ?? projectID
        let project = try await services.projects.upsertCanonicalProject(id: projectID, name: projectName)
        try await services.projectMemberships.setMembership(
            ProjectMembership(
                threadId: record.threadID,
                projectId: project.id,
                origin: .canonicalImport,
                assignedAt: Date()
            )
        )
        try await services.projectSuggestions.markAccepted(threadId: record.threadID, targetProjectId: project.id)

        if let oldProjectID = existingMembership?.projectId, oldProjectID != project.id {
            try await services.projectSuggester.rebuildCorpus(projectId: oldProjectID)
        }
        try await services.projectSuggester.rebuildCorpus(projectId: project.id)
    }

    private static func records(from url: URL) throws -> [ImportedThreadProjectMetadata] {
        let data = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: data)
        guard let conversations = object as? [[String: Any]], !conversations.isEmpty else {
            return []
        }
        let projectNamesByID = projectNameLookup(near: url)

        if conversations.first?["mapping"] != nil {
            return conversations
                .compactMap(chatGPTRecord)
                .map { applyingProjectNameLookup(to: $0, projectNamesByID: projectNamesByID) }
        }

        if conversations.first?["chat_messages"] != nil {
            return conversations
                .compactMap(claudeRecord)
                .map { applyingProjectNameLookup(to: $0, projectNamesByID: projectNamesByID) }
        }

        if conversations.first?["time"] != nil, conversations.first?["title"] != nil {
            return geminiRecords(from: conversations)
        }

        return []
    }

    private static func applyingProjectNameLookup(
        to record: ImportedThreadProjectMetadata,
        projectNamesByID: [String: String]
    ) -> ImportedThreadProjectMetadata {
        guard let projectID = record.projectID,
              record.projectName == nil,
              let projectName = projectNamesByID[projectID] else {
            return record
        }
        return ImportedThreadProjectMetadata(
            threadID: record.threadID,
            projectID: projectID,
            projectName: projectName
        )
    }

    private static func chatGPTRecord(_ conversation: [String: Any]) -> ImportedThreadProjectMetadata? {
        let threadID = stringValue(conversation["conversation_id"])
            ?? stringValue(conversation["id"])
        guard let threadID, !threadID.isEmpty else {
            return nil
        }

        let project = chatGPTProjectInfo(in: conversation)
        return ImportedThreadProjectMetadata(
            threadID: threadID,
            projectID: project.id,
            projectName: project.name
        )
    }

    private static func chatGPTProjectInfo(in conversation: [String: Any]) -> (id: String?, name: String?) {
        let explicitID = stringValue(conversation["project_id"])
            ?? stringValue(conversation["projectId"])
            ?? stringValue(conversation["project_uuid"])
            ?? stringValue(conversation["projectUuid"])
            ?? stringValue(conversation["folder_id"])
            ?? stringValue(conversation["folderId"])
        if let explicitID {
            return (explicitID, findProjectName(in: conversation))
        }

        let gizmoID = stringValue(conversation["gizmo_id"])
            ?? stringValue(conversation["gizmoId"])
        if let gizmoID, isChatGPTProjectGizmoID(gizmoID) {
            return (gizmoID, findProjectName(in: conversation))
        }

        // Older ChatGPT exports can omit top-level `gizmo_id` but keep it in
        // message metadata under `mapping`. Treat that as the same canonical
        // project source instead of dropping the whole batch into Orphans.
        guard let mapping = conversation["mapping"] else {
            return (nil, nil)
        }

        return chatGPTMappingProjectInfo(in: mapping)
    }

    private static func claudeRecord(_ conversation: [String: Any]) -> ImportedThreadProjectMetadata? {
        guard let threadID = stringValue(conversation["uuid"]), !threadID.isEmpty else {
            return nil
        }

        let project = projectInfo(in: conversation)
        return ImportedThreadProjectMetadata(
            threadID: threadID,
            projectID: project.id,
            projectName: project.name
        )
    }

    private static func geminiRecords(from conversations: [[String: Any]]) -> [ImportedThreadProjectMetadata] {
        let groupedDates = Set(
            conversations.compactMap { item -> String? in
                guard let time = stringValue(item["time"]), !time.isEmpty else {
                    return nil
                }
                return time.split(separator: "T").first.map(String.init) ?? time
            }
        )

        return groupedDates.map {
            ImportedThreadProjectMetadata(
                threadID: "gemini_\($0)",
                projectID: nil,
                projectName: nil
            )
        }
    }

    private static func projectInfo(in object: Any) -> (id: String?, name: String?) {
        let id = findProjectID(in: object)
        let name = findProjectName(in: object)

        if let id, !id.isEmpty {
            return (id, name)
        }

        guard let name, !name.isEmpty else {
            return (nil, nil)
        }
        return ("name:\(slug(for: name))", name)
    }

    private static func chatGPTMappingProjectInfo(in mapping: Any) -> (id: String?, name: String?) {
        guard let mapping = mapping as? [String: Any] else {
            return (nil, nil)
        }

        for node in mapping.values {
            guard let node = node as? [String: Any],
                  let message = node["message"] as? [String: Any],
                  let metadata = message["metadata"] as? [String: Any] else {
                continue
            }

            let explicitID = stringValue(metadata["project_id"])
                ?? stringValue(metadata["projectId"])
            let gizmoID = stringValue(metadata["gizmo_id"])
                ?? stringValue(metadata["gizmoId"])
            let id = explicitID ?? (gizmoID.flatMap { isChatGPTProjectGizmoID($0) ? $0 : nil })
            if let id {
                let name = stringValue(metadata["gizmo_name"])
                    ?? stringValue(metadata["gizmoName"])
                    ?? stringValue(metadata["project_name"])
                    ?? stringValue(metadata["projectName"])
                return (id, name)
            }
        }

        return (nil, nil)
    }

    private static func isChatGPTProjectGizmoID(_ id: String) -> Bool {
        id.hasPrefix("g-p-")
    }

    private static func projectNameLookup(near url: URL) -> [String: String] {
        let projectsURL = url.deletingLastPathComponent().appendingPathComponent("projects.json")
        guard let data = try? Data(contentsOf: projectsURL),
              let projects = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return [:]
        }

        var lookup: [String: String] = [:]
        for project in projects {
            guard let id = stringValue(project["uuid"])
                    ?? stringValue(project["id"])
                    ?? stringValue(project["project_id"])
                    ?? stringValue(project["projectId"]),
                  let name = stringValue(project["name"])
                    ?? stringValue(project["title"]) else {
                continue
            }
            lookup[id] = name
        }
        return lookup
    }

    private static func findProjectID(in object: Any) -> String? {
        guard let dictionary = object as? [String: Any] else {
            if let array = object as? [Any] {
                return array.lazy.compactMap(findProjectID).first
            }
            return nil
        }

        let preferredKeys = [
            "project_id", "projectId", "project_uuid", "projectUuid",
            "gizmo_id", "gizmoId", "folder_id", "folderId"
        ]
        for key in preferredKeys {
            if let value = stringValue(dictionary[key]), !value.isEmpty {
                return value
            }
        }

        if let project = dictionary["project"] as? [String: Any] {
            for key in ["id", "uuid", "project_id", "project_uuid"] {
                if let value = stringValue(project[key]), !value.isEmpty {
                    return value
                }
            }
        }

        for (key, value) in dictionary where key.lowercased().contains("project")
            || key.lowercased().contains("gizmo")
            || key.lowercased().contains("folder") {
            if let nested = findProjectID(in: value) {
                return nested
            }
        }

        return nil
    }

    private static func findProjectName(in object: Any) -> String? {
        guard let dictionary = object as? [String: Any] else {
            if let array = object as? [Any] {
                return array.lazy.compactMap(findProjectName).first
            }
            return nil
        }

        let preferredKeys = [
            "project_name", "projectName", "folder_name", "folderName",
            "gizmo_name", "gizmoName"
        ]
        for key in preferredKeys {
            if let value = stringValue(dictionary[key]), !value.isEmpty {
                return value
            }
        }

        if let project = dictionary["project"] as? [String: Any] {
            for key in ["name", "title"] {
                if let value = stringValue(project[key]), !value.isEmpty {
                    return value
                }
            }
        }

        for (key, value) in dictionary where key.lowercased().contains("project")
            || key.lowercased().contains("gizmo")
            || key.lowercased().contains("folder") {
            if let nested = findProjectName(in: value) {
                return nested
            }
        }

        return nil
    }

    private static func stringValue(_ value: Any?) -> String? {
        switch value {
        case let value as String:
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case let value as NSNumber:
            return value.stringValue
        default:
            return nil
        }
    }

    private static func slug(for value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
        let slug = value
            .lowercased()
            .unicodeScalars
            .map { scalar -> String in
                if CharacterSet.alphanumerics.contains(scalar) {
                    return String(scalar)
                }
                return "-"
            }
            .reduce(into: "") { partial, character in
                if character != "-" || partial.last != "-" {
                    partial += character
                }
            }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return "\(slug.isEmpty ? "project" : slug)-\(digest)"
    }
}
