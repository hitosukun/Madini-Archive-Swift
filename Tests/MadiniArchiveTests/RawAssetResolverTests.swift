import XCTest
import GRDB
@testable import MadiniArchive

final class RawAssetResolverTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("MadiniAssetResolverTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        tempRoot = base
    }

    override func tearDownWithError() throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        tempRoot = nil
    }

    func testResolvesReferencedAssetAndRestoresBytes() async throws {
        let (vault, resolver, _) = try makeVaultAndResolver()
        let exportRoot = try makeExportWithAsset()

        let result = try await vault.ingest([exportRoot])
        let snapshot = try XCTUnwrap(result)

        let hits = try await resolver.assetsReferencedBy(
            snapshotID: snapshot.snapshotID,
            sourceRelativePath: "conversations-0001.json",
            offset: 0,
            limit: 10
        )
        XCTAssertEqual(hits.count, 1)
        let firstHit = try XCTUnwrap(hits.first)
        XCTAssertEqual(firstHit.assetRelativePath, "assets/cat.png")
        XCTAssertEqual(firstHit.mimeType, "image/png")

        let resolved = try await resolver.resolveAsset(
            snapshotID: snapshot.snapshotID,
            reference: "cat.png"
        )
        let hit = try XCTUnwrap(resolved)
        XCTAssertEqual(hit.assetRelativePath, "assets/cat.png")

        let payload = try await vault.loadFile(
            snapshotID: snapshot.snapshotID,
            relativePath: hit.assetRelativePath
        )
        XCTAssertEqual(
            payload.data,
            try Data(contentsOf: exportRoot.appendingPathComponent("assets/cat.png"))
        )
    }

    func testResolveAssetReturnsNilWhenSnapshotExistsButReferenceDoesNot() async throws {
        let (vault, resolver, _) = try makeVaultAndResolver()
        let result = try await vault.ingest([try makeExportWithAsset()])
        let snapshot = try XCTUnwrap(result)

        let missing = try await resolver.resolveAsset(
            snapshotID: snapshot.snapshotID,
            reference: "missing.png"
        )
        XCTAssertNil(missing)
    }

    func testAssetsReferencedByThrowsSnapshotNotFoundForUnknownSnapshot() async throws {
        let (_, resolver, _) = try makeVaultAndResolver()

        do {
            _ = try await resolver.assetsReferencedBy(
                snapshotID: 999_999,
                sourceRelativePath: "conversations-0001.json",
                offset: 0,
                limit: 10
            )
            XCTFail("expected RawExportVaultError.snapshotNotFound")
        } catch let error as RawExportVaultError {
            guard case .snapshotNotFound(let snapshotID) = error else {
                XCTFail("expected .snapshotNotFound, got \(error)")
                return
            }
            XCTAssertEqual(snapshotID, 999_999)
        }
    }

    private func makeVaultAndResolver() throws -> (
        vault: GRDBRawExportVault,
        resolver: GRDBRawAssetResolver,
        dbQueue: DatabaseQueue
    ) {
        let dbURL = tempRoot.appendingPathComponent("vault.sqlite")
        let dbQueue = try DatabaseQueue(path: dbURL.path)
        try dbQueue.write { db in
            try GRDBRawExportVault.installSchema(in: db)
        }
        let storage = GRDBRawExportVault.Storage(
            blobsDir: tempRoot.appendingPathComponent("blobs", isDirectory: true),
            snapshotsDir: tempRoot.appendingPathComponent("snapshots", isDirectory: true)
        )
        return (
            GRDBRawExportVault(dbQueue: dbQueue, storage: storage),
            GRDBRawAssetResolver(dbQueue: dbQueue),
            dbQueue
        )
    }

    @discardableResult
    private func makeExportWithAsset() throws -> URL {
        let root = tempRoot.appendingPathComponent("chatgpt-export", isDirectory: true)
        let assets = root.appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)

        let conversation = #"""
        [
          {
            "title": "Image reference",
            "mapping": {
              "root": {
                "message": {
                  "content": {
                    "parts": ["Please look at cat.png before answering."]
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

        let pngHeader = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        try pngHeader.write(to: assets.appendingPathComponent("cat.png"), options: .atomic)

        return root
    }
}
