import XCTest
@testable import MadiniArchive

/// Exercises the detector's directory-shape checks, JSON-header sniff, and
/// the composite `detect(urls:root:)` entry point that the Vault uses.
final class RawExportProviderDetectorTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("MadiniDetectorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        tempRoot = base
    }

    override func tearDownWithError() throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        tempRoot = nil
    }

    // MARK: - Directory shape

    func testDirectoryDetectionChatGPTByConversationChunks() throws {
        let root = try directory("chatgpt")
        try write("[]", to: root.appendingPathComponent("conversations-0001.json"))
        XCTAssertEqual(
            RawExportProviderDetector.detectFromDirectory(root),
            .chatGPT
        )
    }

    func testDirectoryDetectionChatGPTByManifestAlone() throws {
        let root = try directory("chatgpt-manifest-only")
        try write("{}", to: root.appendingPathComponent("export_manifest.json"))
        XCTAssertEqual(
            RawExportProviderDetector.detectFromDirectory(root),
            .chatGPT
        )
    }

    func testDirectoryDetectionClaudeRequiresBothFiles() throws {
        let root = try directory("claude")
        try write("[]", to: root.appendingPathComponent("conversations.json"))
        try write("[]", to: root.appendingPathComponent("projects.json"))
        XCTAssertEqual(
            RawExportProviderDetector.detectFromDirectory(root),
            .claude
        )
    }

    func testDirectoryDetectionClaudeConversationsAloneIsNotClaimed() throws {
        let root = try directory("claude-partial")
        try write("[]", to: root.appendingPathComponent("conversations.json"))
        // No projects.json — the strict directory signal shouldn't fire.
        XCTAssertNil(RawExportProviderDetector.detectFromDirectory(root))
    }

    func testDirectoryDetectionGeminiByActivityFile() throws {
        let root = try directory("gemini/Takeout/My Activity")
        let json = #"""
        [
          {"header": "Gemini", "title": "hi", "time": "2024-01-01T00:00:00Z"}
        ]
        """#
        try write(json, to: root.appendingPathComponent("MyActivity.json"))
        XCTAssertEqual(
            RawExportProviderDetector.detectFromDirectory(tempRoot.appendingPathComponent("gemini")),
            .gemini
        )
    }

    // MARK: - JSON header

    func testHeaderDetectionChatGPT() throws {
        let url = tempRoot.appendingPathComponent("x.json")
        try write(#"[{"title": "t", "mapping": {}}]"#, to: url)
        XCTAssertEqual(RawExportProviderDetector.detectFromJSONHeader(url), .chatGPT)
    }

    func testHeaderDetectionClaude() throws {
        let url = tempRoot.appendingPathComponent("x.json")
        try write(#"[{"name": "t", "chat_messages": []}]"#, to: url)
        XCTAssertEqual(RawExportProviderDetector.detectFromJSONHeader(url), .claude)
    }

    func testHeaderDetectionGemini() throws {
        let url = tempRoot.appendingPathComponent("x.json")
        try write(#"[{"title": "t", "time": "2024-01-01"}]"#, to: url)
        XCTAssertEqual(RawExportProviderDetector.detectFromJSONHeader(url), .gemini)
    }

    func testHeaderDetectionReturnsNilForUnrecognizedShape() throws {
        let url = tempRoot.appendingPathComponent("x.json")
        try write(#"{"not": "an array"}"#, to: url)
        XCTAssertNil(RawExportProviderDetector.detectFromJSONHeader(url))
    }

    func testHeaderDetectionReturnsNilForInvalidJSON() throws {
        let url = tempRoot.appendingPathComponent("x.json")
        try write("this is not json", to: url)
        XCTAssertNil(RawExportProviderDetector.detectFromJSONHeader(url))
    }

    // MARK: - Composite

    func testCompositeFallsBackToHeaderSniffWhenDirectoryUnknown() throws {
        let url = tempRoot.appendingPathComponent("loose.json")
        try write(#"[{"mapping": {}}]"#, to: url)
        XCTAssertEqual(
            RawExportProviderDetector.detect(urls: [url], root: nil),
            .chatGPT
        )
    }

    func testCompositeReturnsUnknownWhenNothingMatches() throws {
        let url = tempRoot.appendingPathComponent("empty.json")
        try write("not json", to: url)
        XCTAssertEqual(
            RawExportProviderDetector.detect(urls: [url], root: nil),
            .unknown
        )
    }

    func testCompositePrefersDirectoryOverHeaderSniff() throws {
        // Directory is clearly ChatGPT, but we pass a Claude-shaped JSON on
        // the side — the directory hint should win.
        let root = try directory("chatgpt-dir")
        let chunk = root.appendingPathComponent("conversations-0001.json")
        try write("[]", to: chunk)

        let claudeShape = tempRoot.appendingPathComponent("stray-claude.json")
        try write(#"[{"chat_messages": []}]"#, to: claudeShape)

        XCTAssertEqual(
            RawExportProviderDetector.detect(urls: [chunk, claudeShape], root: root),
            .chatGPT
        )
    }

    // MARK: - Helpers

    private func directory(_ relative: String) throws -> URL {
        let url = tempRoot.appendingPathComponent(relative, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ content: String, to url: URL) throws {
        try Data(content.utf8).write(to: url, options: .atomic)
    }
}
