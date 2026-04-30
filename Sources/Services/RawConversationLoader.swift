import Foundation
import GRDB

/// Provider-neutral source JSON for a single conversation. The `data` is a
/// serialized JSON object (the one element inside the vaulted
/// `conversations*.json` array that matches the requested conversation ID),
/// not the full export file. Callers feed this into `RawConversationBlockExtractor`
/// (Phase D1b) to pull out inline images, tool calls, attachments, etc.
struct RawConversationJSON: Sendable {
    let conversationID: String
    let provider: RawExportProvider
    let snapshotID: Int64
    let relativePath: String
    /// Zero-based index of the matching element within the source JSON array.
    /// Stored so cache hits can re-extract the same element without a scan.
    let jsonIndex: Int
    let data: Data
}

/// Looks up the raw-export JSON for a given conversation ID. Read-only; the
/// writer side (cache population) is a private detail of the GRDB-backed
/// implementation. Returning `nil` means "we don't have source JSON for this
/// conversation in any snapshot" — the reader falls back to the canonical
/// messages table in that case.
protocol RawConversationLoader: Sendable {
    func loadRawJSON(conversationID: String) async throws -> RawConversationJSON?
}

/// GRDB + Vault-backed loader.
///
/// Lookup flow:
///   1. Cache hit — `conversation_raw_refs` has a row for this conversation.
///      Load the referenced file, re-extract the element at `json_index`, done.
///   2. Cache miss — walk snapshots newest-first (`imported_at DESC, id DESC`),
///      scan each snapshot's `role = 'conversation'` files, parse JSON arrays
///      and search for a top-level element whose provider-native ID matches.
///      On hit: insert into `conversation_raw_refs` and return. On no-hit
///      across all snapshots: return `nil`.
///
/// Gemini is skipped — its exports don't carry stable provider-native
/// conversation IDs, so the Python importer synthesizes IDs that we can't
/// match back to raw JSON. Callers should not call this for Gemini
/// conversations; the loader will just miss and return nil.
final class GRDBRawConversationLoader: RawConversationLoader, @unchecked Sendable {
    private let dbQueue: DatabaseQueue
    private let vault: RawExportVault

    init(dbQueue: DatabaseQueue, vault: RawExportVault) {
        self.dbQueue = dbQueue
        self.vault = vault
    }

    func loadRawJSON(conversationID: String) async throws -> RawConversationJSON? {
        if let hit = try await fetchFromCache(conversationID: conversationID) {
            return hit
        }
        return try await scanSnapshots(conversationID: conversationID)
    }

    // MARK: - Cache path

    private struct CacheRow: Sendable {
        let snapshotID: Int64
        let relativePath: String
        let jsonIndex: Int
        let provider: RawExportProvider
    }

    private func fetchCacheRow(conversationID: String) async throws -> CacheRow? {
        try await GRDBAsync.read(from: dbQueue) { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT snapshot_id, relative_path, json_index, provider
                    FROM conversation_raw_refs
                    WHERE conversation_id = ?
                    ORDER BY snapshot_id DESC
                    LIMIT 1
                    """,
                arguments: [conversationID]
            ) else {
                return nil
            }
            return CacheRow(
                snapshotID: row["snapshot_id"],
                relativePath: row["relative_path"],
                jsonIndex: row["json_index"],
                provider: RawExportProvider(rawValue: row["provider"] ?? "") ?? .unknown
            )
        }
    }

    private func fetchFromCache(conversationID: String) async throws -> RawConversationJSON? {
        guard let cache = try await fetchCacheRow(conversationID: conversationID) else {
            return nil
        }

        // Cache can go stale if the snapshot was pruned out-of-band. Guard the
        // load so a missing snapshot / file just falls through to a fresh scan
        // instead of bubbling an error up to the reader.
        do {
            let payload = try await vault.loadFile(
                snapshotID: cache.snapshotID,
                relativePath: cache.relativePath
            )
            guard let element = try extractElement(
                from: payload.data,
                at: cache.jsonIndex,
                matchingID: conversationID,
                provider: cache.provider
            ) else {
                // Index no longer matches (e.g. the snapshot file changed).
                // Evict and retry via a full scan.
                try? await evictCache(conversationID: conversationID, snapshotID: cache.snapshotID)
                return nil
            }
            return RawConversationJSON(
                conversationID: conversationID,
                provider: cache.provider,
                snapshotID: cache.snapshotID,
                relativePath: cache.relativePath,
                jsonIndex: cache.jsonIndex,
                data: element
            )
        } catch {
            try? await evictCache(conversationID: conversationID, snapshotID: cache.snapshotID)
            return nil
        }
    }

    private func evictCache(conversationID: String, snapshotID: Int64) async throws {
        try await GRDBAsync.write(to: dbQueue) { db in
            try db.execute(
                sql: "DELETE FROM conversation_raw_refs WHERE conversation_id = ? AND snapshot_id = ?",
                arguments: [conversationID, snapshotID]
            )
        }
    }

    // MARK: - Scan path

    private func scanSnapshots(conversationID: String) async throws -> RawConversationJSON? {
        let pageSize = 50
        var offset = 0
        while true {
            let snapshots = try await vault.listSnapshots(offset: offset, limit: pageSize)
            if snapshots.isEmpty {
                return nil
            }
            for snapshot in snapshots {
                // Gemini can't be matched via provider-native IDs — skip early.
                if snapshot.provider == .gemini {
                    continue
                }
                if let hit = try await scan(
                    snapshot: snapshot,
                    conversationID: conversationID
                ) {
                    try? await recordCacheHit(hit)
                    return hit
                }
            }
            if snapshots.count < pageSize {
                return nil
            }
            offset += snapshots.count
        }
    }

    private func scan(
        snapshot: RawExportSnapshotSummary,
        conversationID: String
    ) async throws -> RawConversationJSON? {
        // listFiles returns every role; filter to conversation-bearing files
        // in-memory since the per-snapshot file count is small (typically 1-10
        // for ChatGPT chunks, 1 for Claude).
        let files = try await collectConversationFiles(snapshotID: snapshot.id)
        for file in files {
            let payload: Data
            do {
                payload = try await vault.loadBlob(hash: file.blobHash)
            } catch {
                continue
            }
            if let (data, index) = try findElement(
                in: payload,
                matching: conversationID,
                provider: snapshot.provider
            ) {
                return RawConversationJSON(
                    conversationID: conversationID,
                    provider: snapshot.provider,
                    snapshotID: snapshot.id,
                    relativePath: file.relativePath,
                    jsonIndex: index,
                    data: data
                )
            }
        }
        return nil
    }

    private func collectConversationFiles(
        snapshotID: Int64
    ) async throws -> [RawExportFileEntry] {
        var collected: [RawExportFileEntry] = []
        let pageSize = 200
        var offset = 0
        while true {
            let page = try await vault.listFiles(
                snapshotID: snapshotID,
                offset: offset,
                limit: pageSize
            )
            if page.isEmpty { break }
            collected.append(contentsOf: page.filter { $0.role == "conversation" })
            if page.count < pageSize { break }
            offset += page.count
        }
        return collected
    }

    private func recordCacheHit(_ hit: RawConversationJSON) async throws {
        let timestamp = Self.nowISO8601()
        try await GRDBAsync.write(to: dbQueue) { db in
            try db.execute(
                sql: """
                    INSERT OR REPLACE INTO conversation_raw_refs (
                        conversation_id, snapshot_id, relative_path, json_index, provider, created_at
                    ) VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    hit.conversationID,
                    hit.snapshotID,
                    hit.relativePath,
                    hit.jsonIndex,
                    hit.provider.rawValue,
                    timestamp
                ]
            )
        }
    }

    // MARK: - JSON matching

    /// Parse `payload` (a provider export file — always a JSON array for the
    /// providers we support) and return the first element whose top-level
    /// conversation-ID field matches `conversationID`, along with its index.
    /// Returns `nil` when no element matches.
    private func findElement(
        in payload: Data,
        matching conversationID: String,
        provider: RawExportProvider
    ) throws -> (data: Data, index: Int)? {
        guard let array = try parseTopLevelArray(payload) else {
            return nil
        }
        let keys = Self.conversationIDKeys(for: provider)
        for (index, element) in array.enumerated() {
            guard let object = element as? [String: Any] else { continue }
            if Self.matches(object: object, keys: keys, target: conversationID) {
                let data = try JSONSerialization.data(withJSONObject: object, options: [])
                return (data, index)
            }
        }
        return nil
    }

    /// Re-extract an element the cache said was at `index`, verifying the ID
    /// still matches. If the file has shifted (re-ingest with a different
    /// ordering), fall back to a linear scan within this file before giving
    /// up — this avoids an unnecessary eviction + full-vault rescan when the
    /// hit is still in the same file.
    private func extractElement(
        from payload: Data,
        at index: Int,
        matchingID conversationID: String,
        provider: RawExportProvider
    ) throws -> Data? {
        guard let array = try parseTopLevelArray(payload) else {
            return nil
        }
        let keys = Self.conversationIDKeys(for: provider)
        if index >= 0, index < array.count,
           let object = array[index] as? [String: Any],
           Self.matches(object: object, keys: keys, target: conversationID) {
            return try JSONSerialization.data(withJSONObject: object, options: [])
        }
        // Index drifted — rescan this file only.
        for element in array {
            guard let object = element as? [String: Any] else { continue }
            if Self.matches(object: object, keys: keys, target: conversationID) {
                return try JSONSerialization.data(withJSONObject: object, options: [])
            }
        }
        return nil
    }

    private func parseTopLevelArray(_ data: Data) throws -> [Any]? {
        let parsed = try JSONSerialization.jsonObject(with: data, options: [])
        return parsed as? [Any]
    }

    private static func conversationIDKeys(for provider: RawExportProvider) -> [String] {
        switch provider {
        case .chatGPT:
            // ChatGPT's top-level conversation field is `conversation_id`; very
            // old exports used a plain `id`. Check both so we match the
            // broadest set of real-world exports.
            return ["conversation_id", "id"]
        case .claude:
            return ["uuid", "id"]
        case .gemini, .unknown:
            return []
        }
    }

    private static func matches(
        object: [String: Any],
        keys: [String],
        target: String
    ) -> Bool {
        for key in keys {
            if let value = object[key] as? String, value == target {
                return true
            }
        }
        return false
    }

    private static func nowISO8601() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}
