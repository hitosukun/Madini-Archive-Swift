import XCTest
import GRDB
@testable import MadiniArchive

/// Integration tests for the Vault's ingest + restore contract.
///
/// These run against a temporary directory so they are hermetic — no
/// `~/Library/Application Support/Madini Archive` pollution. The tests
/// deliberately walk the full filesystem path (blobs on disk, SQLite queue)
/// rather than mocking, because the whole point of the restore API is to
/// prove that `ingest` really did put the bytes somewhere we can read back.
final class RawExportVaultTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("MadiniVaultTests-\(UUID().uuidString)", isDirectory: true)
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

    /// Build a scratch Vault + DatabaseQueue backed entirely by `tempRoot`.
    private func makeVault() throws -> (vault: GRDBRawExportVault, dbQueue: DatabaseQueue) {
        let dbURL = tempRoot.appendingPathComponent("vault.sqlite")
        let dbQueue = try DatabaseQueue(path: dbURL.path)
        try dbQueue.write { db in
            try GRDBRawExportVault.installSchema(in: db)
        }
        let storage = GRDBRawExportVault.Storage(
            blobsDir: tempRoot.appendingPathComponent("blobs", isDirectory: true),
            snapshotsDir: tempRoot.appendingPathComponent("snapshots", isDirectory: true)
        )
        let vault = GRDBRawExportVault(dbQueue: dbQueue, storage: storage)
        return (vault, dbQueue)
    }

    /// A minimal but provider-shaped ChatGPT export: one conversation chunk
    /// whose first JSON element carries a `mapping` field (which is the
    /// provider detector's ChatGPT marker) plus the companion manifest.
    @discardableResult
    private func makeChatGPTExport(named name: String = "chatgpt-export") throws -> URL {
        let root = tempRoot.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let conversation = #"""
        [
          {
            "title": "Vault roundtrip smoke",
            "mapping": {
              "root": {
                "message": {
                  "content": {
                    "parts": ["hello test vault, the quick brown fox jumps over the lazy dog"]
                  }
                }
              }
            }
          }
        ]
        """#.data(using: .utf8)!
        try conversation.write(
            to: root.appendingPathComponent("conversations-0001.json"),
            options: .atomic
        )

        let manifest = #"""
        { "version": 1, "chunks": ["conversations-0001.json"] }
        """#.data(using: .utf8)!
        try manifest.write(
            to: root.appendingPathComponent("export_manifest.json"),
            options: .atomic
        )

        return root
    }

    // MARK: - Round trip

    func testIngestRestoreRoundTripByteForByte() async throws {
        let (vault, _) = try makeVault()
        let exportRoot = try makeChatGPTExport()

        let result = try await vault.ingest([exportRoot])
        let unwrapped = try XCTUnwrap(result, "ingest should return a result for a non-empty export")
        XCTAssertEqual(unwrapped.provider, .chatGPT)
        XCTAssertEqual(unwrapped.totalFiles, 2)
        XCTAssertEqual(unwrapped.newBlobs, 2)
        XCTAssertEqual(unwrapped.reusedBlobs, 0)

        // Snapshot summary round-trips.
        let summary = try await vault.getSnapshot(id: unwrapped.snapshotID)
        let gotSummary = try XCTUnwrap(summary, "getSnapshot should find the ingested snapshot")
        XCTAssertEqual(gotSummary.provider, .chatGPT)
        XCTAssertEqual(gotSummary.fileCount, 2)

        // File list paginates and preserves relative paths.
        let files = try await vault.listFiles(
            snapshotID: unwrapped.snapshotID,
            offset: 0,
            limit: 100
        )
        XCTAssertEqual(files.count, 2)
        let relativePaths = Set(files.map(\.relativePath))
        XCTAssertEqual(
            relativePaths,
            Set(["conversations-0001.json", "export_manifest.json"])
        )

        // Byte-for-byte round-trip via loadBlob.
        for entry in files {
            let originalURL = exportRoot.appendingPathComponent(entry.relativePath)
            let original = try Data(contentsOf: originalURL)
            let restored = try await vault.loadBlob(hash: entry.blobHash)
            XCTAssertEqual(
                restored,
                original,
                "loadBlob should return the original bytes for \(entry.relativePath)"
            )
        }

        // loadFile combines metadata lookup + blob read + hash verification.
        let payload = try await vault.loadFile(
            snapshotID: unwrapped.snapshotID,
            relativePath: "conversations-0001.json"
        )
        XCTAssertEqual(payload.entry.role, "conversation")
        let expected = try Data(
            contentsOf: exportRoot.appendingPathComponent("conversations-0001.json")
        )
        XCTAssertEqual(payload.data, expected)
    }

    // MARK: - Compression

    func testLZFSECompressionRoundTripForLargeTextualFile() async throws {
        let (vault, _) = try makeVault()
        let root = tempRoot.appendingPathComponent("compressible-export", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        // Build a ~36 KiB highly-redundant JSON so the compression heuristic
        // (≥ 4 KiB AND compressed < 92 %) kicks in.
        let filler = String(repeating: "the quick brown fox jumps over the lazy dog ", count: 800)
        let body = #"[{"mapping": {}, "content": ""# + filler + #""}]"#
        let bytes = Data(body.utf8)
        XCTAssertGreaterThan(bytes.count, 30_000)
        try bytes.write(
            to: root.appendingPathComponent("conversations-0001.json"),
            options: .atomic
        )

        let result = try await vault.ingest([root])
        let unwrapped = try XCTUnwrap(result)

        let files = try await vault.listFiles(
            snapshotID: unwrapped.snapshotID,
            offset: 0,
            limit: 100
        )
        let entry = try XCTUnwrap(
            files.first { $0.relativePath == "conversations-0001.json" }
        )
        XCTAssertEqual(entry.compression, "lzfse", "redundant 36 KiB text should trip LZFSE")
        XCTAssertLessThan(
            entry.storedSizeBytes,
            entry.sizeBytes,
            "LZFSE should produce a smaller stored size"
        )

        // Decompress + SHA-256 verify should succeed.
        let restored = try await vault.loadBlob(hash: entry.blobHash)
        XCTAssertEqual(restored, bytes)
    }

    // MARK: - Dedupe

    func testReingestSameExportReusesBlobs() async throws {
        let (vault, _) = try makeVault()
        let root = try makeChatGPTExport()

        let first = try await vault.ingest([root])
        let firstResult = try XCTUnwrap(first)
        XCTAssertEqual(firstResult.newBlobs, 2)
        XCTAssertEqual(firstResult.reusedBlobs, 0)

        let second = try await vault.ingest([root])
        let secondResult = try XCTUnwrap(second)
        XCTAssertEqual(
            secondResult.newBlobs,
            0,
            "second ingest of identical bytes should add zero new blobs"
        )
        XCTAssertEqual(secondResult.reusedBlobs, 2)
    }

    // MARK: - Search

    func testSearchFindsIngestedConversationBody() async throws {
        let (vault, _) = try makeVault()
        _ = try await vault.ingest([try makeChatGPTExport()])

        let hits = try await vault.search(
            query: "quick brown fox",
            provider: nil,
            offset: 0,
            limit: 10
        )
        XCTAssertFalse(hits.isEmpty, "search should match content from the ingested conversation")
        XCTAssertTrue(hits.contains { $0.relativePath == "conversations-0001.json" })
    }

    func testSearchRespectsProviderFilter() async throws {
        let (vault, _) = try makeVault()
        _ = try await vault.ingest([try makeChatGPTExport()])

        let chatgptHits = try await vault.search(
            query: "quick brown fox",
            provider: .chatGPT,
            offset: 0,
            limit: 10
        )
        XCTAssertFalse(chatgptHits.isEmpty)

        let claudeHits = try await vault.search(
            query: "quick brown fox",
            provider: .claude,
            offset: 0,
            limit: 10
        )
        XCTAssertTrue(
            claudeHits.isEmpty,
            "scoping the search to .claude should filter out chatGPT snapshots"
        )
    }

    // MARK: - Restore errors

    func testGetSnapshotReturnsNilForUnknownID() async throws {
        let (vault, _) = try makeVault()
        let got = try await vault.getSnapshot(id: 99_999)
        XCTAssertNil(got)
    }

    func testLoadBlobThrowsBlobNotFoundForUnknownHash() async throws {
        let (vault, _) = try makeVault()
        do {
            _ = try await vault.loadBlob(
                hash: String(repeating: "0", count: 64)
            )
            XCTFail("expected RawExportVaultError.blobNotFound")
        } catch let error as RawExportVaultError {
            guard case .blobNotFound = error else {
                XCTFail("expected .blobNotFound, got \(error)")
                return
            }
        }
    }

    func testLoadFileThrowsFileNotFoundForUnknownPath() async throws {
        let (vault, _) = try makeVault()
        let result = try await vault.ingest([try makeChatGPTExport()])
        let unwrapped = try XCTUnwrap(result)

        do {
            _ = try await vault.loadFile(
                snapshotID: unwrapped.snapshotID,
                relativePath: "does-not-exist.json"
            )
            XCTFail("expected RawExportVaultError.fileNotFound")
        } catch let error as RawExportVaultError {
            guard case .fileNotFound = error else {
                XCTFail("expected .fileNotFound, got \(error)")
                return
            }
        }
    }

    func testLoadBlobDetectsHashMismatchAfterTampering() async throws {
        let (vault, _) = try makeVault()
        let root = try makeChatGPTExport()
        let result = try await vault.ingest([root])
        let unwrapped = try XCTUnwrap(result)

        let files = try await vault.listFiles(
            snapshotID: unwrapped.snapshotID,
            offset: 0,
            limit: 100
        )
        let target = try XCTUnwrap(files.first)

        // Tamper with the on-disk blob so the SHA-256 no longer matches.
        let storedURL = URL(fileURLWithPath: target.storedPath)
        try Data(repeating: 0x41, count: 16).write(to: storedURL, options: .atomic)

        do {
            _ = try await vault.loadBlob(hash: target.blobHash)
            XCTFail("expected RawExportVaultError.hashMismatch or .decompressionFailed")
        } catch let error as RawExportVaultError {
            switch error {
            case .hashMismatch, .decompressionFailed:
                break // either is an acceptable integrity failure
            default:
                XCTFail("expected hash/decompression failure, got \(error)")
            }
        }
    }
}
