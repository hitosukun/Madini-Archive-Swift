import XCTest
import GRDB
@testable import MadiniArchive

/// Covers the Vault-backed `RawConversationLoader`:
/// - ChatGPT shape: top-level array, match by `conversation_id`
/// - Claude shape: top-level array, match by `uuid`
/// - Cache behaviour: miss populates `conversation_raw_refs`, hit skips the scan
/// - Eviction: stale cache rows are recovered via a fresh scan
/// - Multi-snapshot: newest snapshot wins when the same conversation ID appears twice
final class RawConversationLoaderTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("MadiniLoaderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        tempRoot = base
    }

    override func tearDownWithError() throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        tempRoot = nil
    }

    // MARK: - Fixtures

    private struct Bench {
        let vault: GRDBRawExportVault
        let dbQueue: DatabaseQueue
        let loader: GRDBRawConversationLoader
    }

    private func makeBench() throws -> Bench {
        let dbURL = tempRoot.appendingPathComponent("vault.sqlite")
        let dbQueue = try DatabaseQueue(path: dbURL.path)
        try dbQueue.write { db in
            try GRDBRawExportVault.installSchema(in: db)
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS conversation_raw_refs (
                    conversation_id TEXT NOT NULL,
                    snapshot_id INTEGER NOT NULL,
                    relative_path TEXT NOT NULL,
                    json_index INTEGER NOT NULL,
                    provider TEXT NOT NULL,
                    created_at TEXT NOT NULL,
                    PRIMARY KEY (conversation_id, snapshot_id),
                    FOREIGN KEY (snapshot_id) REFERENCES raw_export_snapshots(id) ON DELETE CASCADE
                )
                """)
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_conversation_raw_refs_conv
                ON conversation_raw_refs(conversation_id)
                """)
        }
        let storage = GRDBRawExportVault.Storage(
            blobsDir: tempRoot.appendingPathComponent("blobs", isDirectory: true),
            snapshotsDir: tempRoot.appendingPathComponent("snapshots", isDirectory: true)
        )
        let vault = GRDBRawExportVault(dbQueue: dbQueue, storage: storage)
        let loader = GRDBRawConversationLoader(dbQueue: dbQueue, vault: vault)
        return Bench(vault: vault, dbQueue: dbQueue, loader: loader)
    }

    /// ChatGPT-shaped export. The top-level array contains two conversations,
    /// each keyed by `conversation_id`. Also includes a `mapping` field so the
    /// provider detector classifies the snapshot as ChatGPT.
    private func makeChatGPTExport(
        named name: String,
        conversationIDs: [String]
    ) throws -> URL {
        let root = tempRoot.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let objects: [[String: Any]] = conversationIDs.enumerated().map { index, id in
            [
                "conversation_id": id,
                "title": "Conversation \(index) (\(name))",
                "mapping": [
                    "root": [
                        "message": [
                            "content": ["parts": ["hello from \(id)"]]
                        ]
                    ]
                ]
            ]
        }
        let data = try JSONSerialization.data(withJSONObject: objects, options: [.sortedKeys])
        try data.write(to: root.appendingPathComponent("conversations-0001.json"), options: .atomic)

        let manifest = #"{ "version": 1, "chunks": ["conversations-0001.json"] }"#.data(using: .utf8)!
        try manifest.write(to: root.appendingPathComponent("export_manifest.json"), options: .atomic)

        return root
    }

    /// Claude-shaped export — single top-level array with `uuid`-keyed entries
    /// and a `chat_messages` field that the provider detector uses as its
    /// Claude marker.
    private func makeClaudeExport(
        named name: String,
        uuids: [String]
    ) throws -> URL {
        let root = tempRoot.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let objects: [[String: Any]] = uuids.map { uuid in
            [
                "uuid": uuid,
                "name": "Claude chat \(uuid)",
                "chat_messages": [
                    ["sender": "human", "text": "hi"],
                    ["sender": "assistant", "text": "hello"]
                ]
            ]
        }
        let data = try JSONSerialization.data(withJSONObject: objects, options: [.sortedKeys])
        try data.write(to: root.appendingPathComponent("conversations.json"), options: .atomic)

        // Claude directory-shaped detection requires both conversations.json
        // and projects.json to be present. Empty array is fine.
        try "[]".data(using: .utf8)!
            .write(to: root.appendingPathComponent("projects.json"), options: .atomic)

        return root
    }

    private func cacheCount(dbQueue: DatabaseQueue) throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM conversation_raw_refs") ?? 0
        }
    }

    // MARK: - ChatGPT

    func testLoadRawJSONMatchesChatGPTConversationID() async throws {
        let bench = try makeBench()
        let target = "conv-aaa-111"
        let root = try makeChatGPTExport(
            named: "chatgpt-export",
            conversationIDs: ["conv-other-000", target, "conv-tail-222"]
        )
        _ = try await bench.vault.ingest([root])

        let loaded = try await bench.loader.loadRawJSON(conversationID: target)
        let hit = try XCTUnwrap(loaded, "loader should return raw JSON for the ChatGPT conversation")
        XCTAssertEqual(hit.conversationID, target)
        XCTAssertEqual(hit.provider, .chatGPT)
        XCTAssertEqual(hit.relativePath, "conversations-0001.json")
        XCTAssertEqual(hit.jsonIndex, 1)

        let parsed = try JSONSerialization.jsonObject(with: hit.data) as? [String: Any]
        XCTAssertEqual(parsed?["conversation_id"] as? String, target)
    }

    func testLoadRawJSONReturnsNilForUnknownConversationID() async throws {
        let bench = try makeBench()
        let root = try makeChatGPTExport(
            named: "chatgpt-export",
            conversationIDs: ["conv-a", "conv-b"]
        )
        _ = try await bench.vault.ingest([root])

        let loaded = try await bench.loader.loadRawJSON(conversationID: "missing")
        XCTAssertNil(loaded)
        XCTAssertEqual(try cacheCount(dbQueue: bench.dbQueue), 0)
    }

    // MARK: - Claude

    func testLoadRawJSONMatchesClaudeUUID() async throws {
        let bench = try makeBench()
        let target = "11111111-2222-3333-4444-555555555555"
        let root = try makeClaudeExport(
            named: "claude-export",
            uuids: ["ignore-uuid-1", target]
        )
        _ = try await bench.vault.ingest([root])

        let loaded = try await bench.loader.loadRawJSON(conversationID: target)
        let hit = try XCTUnwrap(loaded, "loader should return raw JSON for the Claude conversation")
        XCTAssertEqual(hit.provider, .claude)
        XCTAssertEqual(hit.relativePath, "conversations.json")
        XCTAssertEqual(hit.jsonIndex, 1)

        let parsed = try JSONSerialization.jsonObject(with: hit.data) as? [String: Any]
        XCTAssertEqual(parsed?["uuid"] as? String, target)
    }

    // MARK: - Cache behaviour

    func testFirstLoadPopulatesCacheSecondLoadIsCacheHit() async throws {
        let bench = try makeBench()
        let target = "conv-cache-test"
        let root = try makeChatGPTExport(
            named: "chatgpt-export",
            conversationIDs: [target, "conv-other"]
        )
        _ = try await bench.vault.ingest([root])

        XCTAssertEqual(try cacheCount(dbQueue: bench.dbQueue), 0)
        _ = try await bench.loader.loadRawJSON(conversationID: target)
        XCTAssertEqual(try cacheCount(dbQueue: bench.dbQueue), 1, "first load should populate cache")

        // Snap the cached row so we can verify the second call uses it.
        struct CachedSnap: Sendable { let snapshotID: Int64; let index: Int; let path: String }
        let cachedOpt: CachedSnap? = try await GRDBAsync.read(from: bench.dbQueue) { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT snapshot_id, json_index, relative_path FROM conversation_raw_refs WHERE conversation_id = ?",
                arguments: [target]
            ) else { return nil }
            return CachedSnap(
                snapshotID: row["snapshot_id"],
                index: row["json_index"],
                path: row["relative_path"]
            )
        }
        let cached = try XCTUnwrap(cachedOpt)

        let second = try await bench.loader.loadRawJSON(conversationID: target)
        let hit = try XCTUnwrap(second)
        XCTAssertEqual(hit.snapshotID, cached.snapshotID)
        XCTAssertEqual(hit.jsonIndex, cached.index)
        XCTAssertEqual(hit.relativePath, cached.path)
        XCTAssertEqual(try cacheCount(dbQueue: bench.dbQueue), 1, "cache hit should not duplicate row")
    }

    func testStaleCacheWithWrongIndexRecoversViaFileRescan() async throws {
        let bench = try makeBench()
        let target = "conv-drift"
        let root = try makeChatGPTExport(
            named: "chatgpt-export",
            conversationIDs: ["conv-a", target, "conv-c"]
        )
        let ingest = try await bench.vault.ingest([root])
        let snapshotID = try XCTUnwrap(ingest?.snapshotID)

        // Poison the cache: point to the same file but at the wrong index. The
        // loader should fall back to a linear scan within that file and still
        // return the right element (without evicting, since the hit stayed in
        // the same file).
        try await GRDBAsync.write(to: bench.dbQueue) { db in
            try db.execute(
                sql: """
                    INSERT INTO conversation_raw_refs
                    (conversation_id, snapshot_id, relative_path, json_index, provider, created_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: [target, snapshotID, "conversations-0001.json", 99, "chatgpt", "2026-01-01T00:00:00Z"]
            )
        }

        let loaded = try await bench.loader.loadRawJSON(conversationID: target)
        let hit = try XCTUnwrap(loaded)
        let parsed = try JSONSerialization.jsonObject(with: hit.data) as? [String: Any]
        XCTAssertEqual(parsed?["conversation_id"] as? String, target)
    }

    // MARK: - Multi-snapshot

    func testNewerSnapshotWinsWhenSameConversationAppearsInMultipleSnapshots() async throws {
        let bench = try makeBench()
        let target = "conv-shared"
        let first = try makeChatGPTExport(
            named: "chatgpt-old",
            conversationIDs: [target]
        )
        _ = try await bench.vault.ingest([first])

        // Second snapshot: same conversation ID, different content, different
        // file path ordering (so we can tell which one was selected).
        let secondRoot = tempRoot.appendingPathComponent("chatgpt-new", isDirectory: true)
        try FileManager.default.createDirectory(at: secondRoot, withIntermediateDirectories: true)
        let newer: [[String: Any]] = [
            ["conversation_id": "conv-filler", "mapping": [:]],
            [
                "conversation_id": target,
                "title": "Newer version",
                "mapping": [:]
            ]
        ]
        let newerData = try JSONSerialization.data(withJSONObject: newer, options: [.sortedKeys])
        try newerData.write(to: secondRoot.appendingPathComponent("conversations-0001.json"), options: .atomic)
        try #"{ "version": 2, "chunks": ["conversations-0001.json"] }"#
            .data(using: .utf8)!
            .write(to: secondRoot.appendingPathComponent("export_manifest.json"), options: .atomic)
        let secondIngest = try await bench.vault.ingest([secondRoot])
        let newerSnapshotID = try XCTUnwrap(secondIngest?.snapshotID)

        let loaded = try await bench.loader.loadRawJSON(conversationID: target)
        let hit = try XCTUnwrap(loaded)
        XCTAssertEqual(hit.snapshotID, newerSnapshotID, "newest snapshot should be preferred")
        XCTAssertEqual(hit.jsonIndex, 1)
        let parsed = try JSONSerialization.jsonObject(with: hit.data) as? [String: Any]
        XCTAssertEqual(parsed?["title"] as? String, "Newer version")
    }
}
