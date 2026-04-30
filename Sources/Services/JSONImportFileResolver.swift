import Foundation

struct JSONImportSelection: Sendable {
    let jsonURLs: [URL]
    let rejectedInputCount: Int
}

/// Given a list of user-dropped URLs (files or folders), work out which JSON
/// files the importer should actually read. Provider-shape detection lives in
/// `RawExportProviderDetector`; this resolver is the "what to hand off to the
/// importer" layer on top of it.
///
/// Priority when a directory is dropped:
///   1. ChatGPT conversation chunks (`conversations-*.json`)
///   2. Claude `conversations.json` at the root
///   3. Gemini activity files (anywhere beneath the directory)
///   4. Fall back to top-level `.json` children
///
/// A single `.json` file is returned as-is, except that a dropped
/// `export_manifest.json` redirects to the ChatGPT conversation chunks that
/// sit alongside it.
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
            let chatgptChunks = RawExportProviderDetector.chatGPTConversationChunks(in: url)
            if !chatgptChunks.isEmpty {
                return chatgptChunks
            }
            if let claude = RawExportProviderDetector.claudeConversationsFile(in: url) {
                return [claude]
            }
            let geminiActivities = RawExportProviderDetector.geminiActivityFiles(in: url)
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
            let chunks = RawExportProviderDetector.chatGPTConversationChunks(
                in: url.deletingLastPathComponent()
            )
            if !chunks.isEmpty {
                return chunks
            }
        }

        return [url]
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private static func directJSONChildren(in directory: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ))?
            .filter { $0.pathExtension.lowercased() == "json" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        ?? []
    }
}
