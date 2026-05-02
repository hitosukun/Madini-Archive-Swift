import Foundation

/// Walks a vault directory, parses every `.md` file, and upserts the
/// resulting `WikiPage` rows into a `WikiPageRepository`. Strictly
/// read-only against the vault filesystem — only the index cache DB
/// is written to.
///
/// The indexer holds no per-vault DatabaseQueue itself; that lifecycle
/// belongs to `WikiIndexCoordinator`. Each `WikiIndexer` instance is
/// scoped to one repository (one vault's index DB).
struct WikiIndexer: Sendable {
    let pageRepository: any WikiPageRepository

    struct IndexStats: Hashable, Sendable {
        var upserted: Int = 0
        var removed: Int = 0
        var failed: Int = 0
    }

    // MARK: - Full vault scan

    /// Scan the vault, parse every `.md` file, and reconcile the index.
    /// Pages that exist in the cache but not on disk are removed.
    func indexVault(_ vault: WikiVault) async throws -> IndexStats {
        let vaultURL = URL(fileURLWithPath: vault.path)
        let mdFiles = try Self.listMarkdownFiles(in: vaultURL)

        var stats = IndexStats()
        var seenRelativePaths = Set<String>()

        for fileURL in mdFiles {
            let relativePath = Self.relativePath(of: fileURL, base: vaultURL)
            seenRelativePaths.insert(relativePath)
            do {
                try await indexFile(
                    at: fileURL,
                    relativePath: relativePath,
                    in: vault
                )
                stats.upserted += 1
            } catch {
                stats.failed += 1
            }
        }

        // Reconcile deletions: anything in the index not seen on disk is
        // gone, so drop it. We page through the existing index (offset/
        // limit) so very large vaults don't blow memory.
        let pageSize = 500
        var offset = 0
        var toDelete: [String] = []
        while true {
            let batch = try await pageRepository.listPages(
                vaultID: vault.id, offset: offset, limit: pageSize
            )
            if batch.isEmpty { break }
            for page in batch where !seenRelativePaths.contains(page.path) {
                toDelete.append(page.path)
            }
            if batch.count < pageSize { break }
            offset += pageSize
        }
        for path in toDelete {
            try await pageRepository.deletePage(vaultID: vault.id, path: path)
            stats.removed += 1
        }

        return stats
    }

    // MARK: - Single file

    /// Parse one file and upsert it. Used by FSEvents-driven incremental
    /// updates and by the full-scan path.
    func indexFile(
        at fileURL: URL,
        relativePath: String,
        in vault: WikiVault
    ) async throws {
        let contents = try String(contentsOf: fileURL, encoding: .utf8)
        let parsed = ObsidianMarkdownParser.parse(contents)
        let title = Self.deriveTitle(
            frontmatterJSON: parsed.frontmatterJSON,
            body: parsed.body,
            filePath: relativePath
        )
        let lastModified = Self.lastModifiedString(at: fileURL)

        let page = WikiPage(
            id: 0, // ignored by upsertPage
            vaultID: vault.id,
            path: relativePath,
            title: title,
            frontmatterJSON: parsed.frontmatterJSON,
            body: parsed.body,
            lastModified: lastModified
        )
        try await pageRepository.upsertPage(page)
    }

    /// Remove a page from the index. Triggered by FSEvents when a file is
    /// deleted from the vault — the file itself is already gone.
    func removeFile(
        at relativePath: String,
        in vault: WikiVault
    ) async throws {
        try await pageRepository.deletePage(vaultID: vault.id, path: relativePath)
    }

    // MARK: - Helpers

    /// Recursively enumerate every `.md` file under `directory`.
    /// Skips Obsidian's hidden `.obsidian` config dir and any other
    /// dotfile dirs to avoid indexing internal metadata.
    static func listMarkdownFiles(in directory: URL) throws -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var results: [URL] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            if values.isRegularFile == true,
               url.pathExtension.lowercased() == "md" {
                results.append(url)
            }
        }
        return results
    }

    static func relativePath(of fileURL: URL, base: URL) -> String {
        let basePath = base.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path
        if filePath.hasPrefix(basePath + "/") {
            return String(filePath.dropFirst(basePath.count + 1))
        }
        return filePath
    }

    /// Title resolution order, mirroring Obsidian's behavior:
    ///   1. `title:` field in frontmatter (if present and non-empty).
    ///   2. First `# ` heading in the body.
    ///   3. Filename without `.md` extension.
    static func deriveTitle(
        frontmatterJSON: String?,
        body: String,
        filePath: String
    ) -> String? {
        if let json = frontmatterJSON,
           let data = json.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let title = dict["title"] as? String,
           !title.isEmpty {
            return title
        }
        for line in body.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("# ") {
                return String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            }
        }
        let filename = (filePath as NSString).lastPathComponent
        if filename.hasSuffix(".md") {
            return String(filename.dropLast(3))
        }
        return filename.isEmpty ? nil : filename
    }

    static func lastModifiedString(at url: URL) -> String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let date = (attrs?[.modificationDate] as? Date) ?? Date()
        return TimestampFormatter.string(from: date)
    }
}
