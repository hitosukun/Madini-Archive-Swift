import Foundation

struct JSONImportSelection: Sendable {
    let jsonURLs: [URL]
    let rejectedInputCount: Int
}

enum JSONImportFileResolver {
    static func resolve(_ urls: [URL]) -> JSONImportSelection {
        var resolved: [URL] = []
        var seen = Set<String>()
        var rejected = 0

        for url in urls {
            let candidates = importableJSONFiles(from: url)
            if candidates.isEmpty {
                rejected += 1
                continue
            }

            for candidate in candidates {
                let key = candidate.standardizedFileURL.path
                if seen.insert(key).inserted {
                    resolved.append(candidate)
                }
            }
        }

        return JSONImportSelection(
            jsonURLs: resolved,
            rejectedInputCount: rejected
        )
    }

    private static func importableJSONFiles(from url: URL) -> [URL] {
        if isDirectory(url) {
            let conversationChunks = chatGPTConversationChunks(in: url)
            if !conversationChunks.isEmpty {
                return conversationChunks
            }
            let claudeConversations = url.appendingPathComponent("conversations.json")
            if FileManager.default.fileExists(atPath: claudeConversations.path) {
                return [claudeConversations]
            }
            let geminiActivities = geminiActivityFiles(in: url)
            if !geminiActivities.isEmpty {
                return geminiActivities
            }
            return directJSONChildren(in: url)
        }

        guard url.pathExtension.lowercased() == "json" else {
            return []
        }

        // A full ChatGPT export includes several helper JSON files. If the
        // user drops the manifest, import the actual conversation chunks.
        if url.lastPathComponent == "export_manifest.json" {
            let conversationChunks = chatGPTConversationChunks(in: url.deletingLastPathComponent())
            if !conversationChunks.isEmpty {
                return conversationChunks
            }
        }

        return [url]
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private static func directJSONChildren(in directory: URL) -> [URL] {
        directoryChildren(in: directory)
            .filter { $0.pathExtension.lowercased() == "json" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private static func chatGPTConversationChunks(in directory: URL) -> [URL] {
        directoryChildren(in: directory)
            .filter { url in
                let name = url.lastPathComponent
                return name.hasPrefix("conversations-") && name.hasSuffix(".json")
            }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private static func geminiActivityFiles(in directory: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return enumerator
            .compactMap { $0 as? URL }
            .filter(isGeminiActivityFile)
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private static func isGeminiActivityFile(_ url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "json",
              let handle = try? FileHandle(forReadingFrom: url) else {
            return false
        }
        defer { try? handle.close() }

        let prefix = handle.readData(ofLength: 65_536)
        guard let text = String(data: prefix, encoding: .utf8) else {
            return false
        }

        return text.contains("\"header\"")
            && text.contains("Gemini")
            && text.contains("\"time\"")
            && text.contains("\"title\"")
    }

    private static func directoryChildren(in directory: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
    }
}
