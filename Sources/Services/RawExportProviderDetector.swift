import Foundation

/// Single source of truth for detecting which external LLM an export folder /
/// JSON file belongs to. Used by both `GRDBRawExportVault.ingest` (to tag the
/// snapshot) and `JSONImportFileResolver` (to pick which files the importer
/// should read).
///
/// Detection priority:
///   1. Directory-shaped hints (filenames that are unique to each provider).
///   2. JSON header sniffing (structural fields that are unique to each
///      provider: ChatGPT's `mapping`, Claude's `chat_messages`,
///      Gemini's `time`/`title` pair).
///   3. Fall back to `.unknown` when no hint matches.
///
/// This enum only decides "which provider"; per-provider file listing helpers
/// are also exposed here so callers don't duplicate the globbing rules.
enum RawExportProviderDetector {
    // MARK: - Primary detection

    /// Return the provider for a set of URLs. `root`, if provided, is the
    /// common directory context used for directory-shaped detection.
    ///
    /// Returns `.unknown` when no hint fires. Never throws — detection should
    /// degrade gracefully for unfamiliar inputs.
    static func detect(
        urls: [URL],
        root: URL?,
        fileManager: FileManager = .default
    ) -> RawExportProvider {
        if let root, let provider = detectFromDirectory(root, fileManager: fileManager) {
            return provider
        }
        for url in urls where url.pathExtension.lowercased() == "json" {
            if let provider = detectFromJSONHeader(url) {
                return provider
            }
        }
        return .unknown
    }

    /// Directory-shaped detection. Looks for provider-specific filenames or
    /// activity files. Returns `nil` when nothing matches.
    static func detectFromDirectory(
        _ root: URL,
        fileManager: FileManager = .default
    ) -> RawExportProvider? {
        if !chatGPTConversationChunks(in: root, fileManager: fileManager).isEmpty
            || fileManager.fileExists(atPath: root.appendingPathComponent("export_manifest.json").path) {
            return .chatGPT
        }
        if isClaudeExportRoot(root, fileManager: fileManager) {
            return .claude
        }
        if !geminiActivityFiles(in: root, fileManager: fileManager).isEmpty {
            return .gemini
        }
        return nil
    }

    /// True when `root` looks like a Claude export. Accepts both the
    /// pre-2026-05 layout (`conversations.json` + `projects.json` flat
    /// file) and the post-2026-05 layout (`conversations.json` +
    /// `projects/` directory or `memories.json`). The change in
    /// Claude's exporter replaced the flat `projects.json` with a
    /// per-project file under `projects/<uuid>.json` and added a
    /// `memories.json` sibling — either of those, when paired with
    /// the always-present `conversations.json`, is enough to claim
    /// the snapshot. `conversations.json` alone stays ambiguous so
    /// stray Anthropic-shaped JSON outside an export folder doesn't
    /// get mis-tagged.
    private static func isClaudeExportRoot(
        _ root: URL,
        fileManager: FileManager
    ) -> Bool {
        let conversations = root.appendingPathComponent("conversations.json").path
        guard fileManager.fileExists(atPath: conversations) else { return false }

        let projectsFile = root.appendingPathComponent("projects.json").path
        if fileManager.fileExists(atPath: projectsFile) {
            return true
        }

        var isDir: ObjCBool = false
        let projectsDir = root.appendingPathComponent("projects").path
        if fileManager.fileExists(atPath: projectsDir, isDirectory: &isDir), isDir.boolValue {
            return true
        }

        let memories = root.appendingPathComponent("memories.json").path
        if fileManager.fileExists(atPath: memories) {
            return true
        }

        return false
    }

    /// Peek at the first element of a JSON array and decide which provider's
    /// shape it matches. Returns `nil` when the file is unreadable, not an
    /// array, or none of the shape markers match.
    static func detectFromJSONHeader(_ url: URL) -> RawExportProvider? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let object = try? JSONSerialization.jsonObject(with: data),
              let list = object as? [[String: Any]],
              let first = list.first else {
            return nil
        }
        if first["mapping"] != nil {
            return .chatGPT
        }
        if first["chat_messages"] != nil {
            return .claude
        }
        if first["time"] != nil, first["title"] != nil {
            return .gemini
        }
        return nil
    }

    // MARK: - Provider-shape file helpers

    /// ChatGPT splits conversations into `conversations-<n>.json` chunks at
    /// the root of the export folder. Non-recursive by design — chunks only
    /// ever appear at the top level.
    static func chatGPTConversationChunks(
        in directory: URL,
        fileManager: FileManager = .default
    ) -> [URL] {
        directoryChildren(in: directory, fileManager: fileManager)
            .filter { url in
                let name = url.lastPathComponent
                return name.hasPrefix("conversations-") && name.hasSuffix(".json")
            }
            .sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
            }
    }

    /// Claude exports ship `conversations.json` at the root. We do not require
    /// `projects.json` to be present for this helper — callers that need the
    /// strict shape use `detectFromDirectory` instead.
    static func claudeConversationsFile(
        in directory: URL,
        fileManager: FileManager = .default
    ) -> URL? {
        let candidate = directory.appendingPathComponent("conversations.json")
        return fileManager.fileExists(atPath: candidate.path) ? candidate : nil
    }

    /// Gemini activity JSON files are buried inside a Takeout-style hierarchy.
    /// Detection sniffs the first 64 KiB of each `.json` file for the tell-tale
    /// header/Gemini/time/title markers and returns the ones that match.
    static func geminiActivityFiles(
        in directory: URL,
        fileManager: FileManager = .default
    ) -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return enumerator
            .compactMap { $0 as? URL }
            .filter(isGeminiActivityFile)
            .sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
            }
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

    private static func directoryChildren(
        in directory: URL,
        fileManager: FileManager
    ) -> [URL] {
        (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
    }
}
