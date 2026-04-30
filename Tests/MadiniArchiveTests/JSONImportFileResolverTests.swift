import XCTest
@testable import MadiniArchive

/// Resolver coverage: a user drops a mix of folders + files, we want to know
/// which JSON files the importer should actually read. The resolver delegates
/// provider shape checks to `RawExportProviderDetector`, so these tests
/// mostly verify the dispatch order + fallbacks.
final class JSONImportFileResolverTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("MadiniResolverTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        tempRoot = base
    }

    override func tearDownWithError() throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        tempRoot = nil
    }

    func testChatGPTDirectoryPicksConversationChunks() throws {
        let root = try directory("chatgpt")
        try write("[]", to: root.appendingPathComponent("conversations-0001.json"))
        try write("[]", to: root.appendingPathComponent("conversations-0002.json"))
        try write("{}", to: root.appendingPathComponent("export_manifest.json"))

        let selection = JSONImportFileResolver.resolve([root])
        XCTAssertEqual(selection.rejectedInputCount, 0)
        let names = selection.jsonURLs.map(\.lastPathComponent).sorted()
        XCTAssertEqual(names, ["conversations-0001.json", "conversations-0002.json"])
    }

    func testDroppedChatGPTManifestRedirectsToChunks() throws {
        let root = try directory("chatgpt")
        try write("[]", to: root.appendingPathComponent("conversations-0001.json"))
        let manifestURL = root.appendingPathComponent("export_manifest.json")
        try write("{}", to: manifestURL)

        // User dropped the manifest file, not the folder.
        let selection = JSONImportFileResolver.resolve([manifestURL])
        XCTAssertEqual(selection.rejectedInputCount, 0)
        XCTAssertEqual(
            selection.jsonURLs.map(\.lastPathComponent),
            ["conversations-0001.json"]
        )
    }

    func testClaudeDirectoryPicksConversationsJSON() throws {
        let root = try directory("claude")
        try write("[]", to: root.appendingPathComponent("conversations.json"))
        // projects.json isn't required by the resolver fallback, since
        // `claudeConversationsFile` matches on the single-file shape.
        let selection = JSONImportFileResolver.resolve([root])
        XCTAssertEqual(selection.rejectedInputCount, 0)
        XCTAssertEqual(
            selection.jsonURLs.map(\.lastPathComponent),
            ["conversations.json"]
        )
    }

    func testFallbackToDirectJSONChildrenWhenNoProviderShapeMatches() throws {
        let root = try directory("misc")
        try write("[]", to: root.appendingPathComponent("b.json"))
        try write("[]", to: root.appendingPathComponent("a.json"))
        try write("not json", to: root.appendingPathComponent("c.txt"))

        let selection = JSONImportFileResolver.resolve([root])
        XCTAssertEqual(selection.rejectedInputCount, 0)
        XCTAssertEqual(
            selection.jsonURLs.map(\.lastPathComponent),
            ["a.json", "b.json"],
            "fallback should keep .json files only, ordered by localized-standard compare"
        )
    }

    func testNonJSONSingleFileIsRejected() throws {
        let url = tempRoot.appendingPathComponent("readme.txt")
        try write("hi", to: url)

        let selection = JSONImportFileResolver.resolve([url])
        XCTAssertTrue(selection.jsonURLs.isEmpty)
        XCTAssertEqual(selection.rejectedInputCount, 1)
    }

    func testDedupesRepeatedInputs() throws {
        let root = try directory("chatgpt")
        try write("[]", to: root.appendingPathComponent("conversations-0001.json"))

        // Same folder dropped twice — should resolve to one URL, not two.
        let selection = JSONImportFileResolver.resolve([root, root])
        XCTAssertEqual(selection.jsonURLs.count, 1)
    }

    // MARK: - Helpers

    private func directory(_ name: String) throws -> URL {
        let url = tempRoot.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ content: String, to url: URL) throws {
        try Data(content.utf8).write(to: url, options: .atomic)
    }
}
