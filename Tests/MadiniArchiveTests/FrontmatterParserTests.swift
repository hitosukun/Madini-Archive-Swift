import XCTest
@testable import MadiniArchive

final class FrontmatterParserTests: XCTestCase {
    // MARK: - No frontmatter

    func testNoFrontmatterReturnsOriginal() {
        let md = "# Hello\n\nThis is body."
        let result = FrontmatterParser.split(md)
        XCTAssertNil(result.frontmatterJSON)
        XCTAssertEqual(result.body, md)
    }

    func testEmptyDocument() {
        let result = FrontmatterParser.split("")
        XCTAssertNil(result.frontmatterJSON)
        XCTAssertEqual(result.body, "")
    }

    func testUnclosedFrontmatterTreatedAsBody() {
        let md = "---\ntitle: Hello\n\nNo closing fence."
        let result = FrontmatterParser.split(md)
        XCTAssertNil(result.frontmatterJSON)
        XCTAssertEqual(result.body, md)
    }

    func testThreeDashesInBodyAreNotFrontmatter() {
        // Frontmatter must start at byte 0; mid-document `---` is just an HR.
        let md = "Some text\n---\nNot frontmatter\n---\nMore"
        let result = FrontmatterParser.split(md)
        XCTAssertNil(result.frontmatterJSON)
        XCTAssertEqual(result.body, md)
    }

    // MARK: - Scalars

    func testStringScalar() throws {
        let md = "---\ntitle: Hello World\n---\nbody"
        let result = FrontmatterParser.split(md)
        let dict = try jsonDict(result.frontmatterJSON)
        XCTAssertEqual(dict?["title"] as? String, "Hello World")
        XCTAssertEqual(result.body, "body")
    }

    func testQuotedString() throws {
        let md = """
        ---
        title: "Hello: World"
        author: 'Jenna'
        ---
        body
        """
        let result = FrontmatterParser.split(md)
        let dict = try jsonDict(result.frontmatterJSON)
        XCTAssertEqual(dict?["title"] as? String, "Hello: World")
        XCTAssertEqual(dict?["author"] as? String, "Jenna")
    }

    func testIntegerScalar() throws {
        let md = "---\ncount: 42\n---\n"
        let result = FrontmatterParser.split(md)
        let dict = try jsonDict(result.frontmatterJSON)
        XCTAssertEqual(dict?["count"] as? Int, 42)
    }

    func testBoolScalar() throws {
        let md = "---\npublished: true\ndraft: false\n---\n"
        let result = FrontmatterParser.split(md)
        let dict = try jsonDict(result.frontmatterJSON)
        XCTAssertEqual(dict?["published"] as? Bool, true)
        XCTAssertEqual(dict?["draft"] as? Bool, false)
    }

    func testNullScalar() throws {
        let md = "---\nabsent: null\nmissing: ~\n---\n"
        let result = FrontmatterParser.split(md)
        let dict = try jsonDict(result.frontmatterJSON)
        XCTAssertTrue(dict?["absent"] is NSNull)
        XCTAssertTrue(dict?["missing"] is NSNull)
    }

    // MARK: - Lists

    func testInlineList() throws {
        let md = "---\ntags: [novel, draft, chr]\n---\nbody"
        let result = FrontmatterParser.split(md)
        let dict = try jsonDict(result.frontmatterJSON)
        let tags = dict?["tags"] as? [String]
        XCTAssertEqual(tags, ["novel", "draft", "chr"])
    }

    func testBlockList() throws {
        let md = """
        ---
        tags:
          - novel
          - draft
          - chr
        ---
        body
        """
        let result = FrontmatterParser.split(md)
        let dict = try jsonDict(result.frontmatterJSON)
        let tags = dict?["tags"] as? [String]
        XCTAssertEqual(tags, ["novel", "draft", "chr"])
    }

    func testEmptyInlineListBecomesEmptyArray() throws {
        let md = "---\ntags: []\n---\n"
        let result = FrontmatterParser.split(md)
        let dict = try jsonDict(result.frontmatterJSON)
        let tags = dict?["tags"] as? [String]
        XCTAssertEqual(tags, [])
    }

    // MARK: - Mixed

    func testMixedTypicalObsidianFrontmatter() throws {
        let md = """
        ---
        type: chr
        name: 錫花
        tags: [character, novel]
        published: true
        chapter: 5
        ---
        # 錫花

        本文。
        """
        let result = FrontmatterParser.split(md)
        let dict = try jsonDict(result.frontmatterJSON)
        XCTAssertEqual(dict?["type"] as? String, "chr")
        XCTAssertEqual(dict?["name"] as? String, "錫花")
        XCTAssertEqual(dict?["tags"] as? [String], ["character", "novel"])
        XCTAssertEqual(dict?["published"] as? Bool, true)
        XCTAssertEqual(dict?["chapter"] as? Int, 5)
        XCTAssertTrue(result.body.hasPrefix("# 錫花"))
    }

    // MARK: - Edge

    func testEmptyFrontmatterBlock() throws {
        let md = "---\n---\nbody"
        let result = FrontmatterParser.split(md)
        XCTAssertNotNil(result.frontmatterJSON)
        XCTAssertEqual(result.frontmatterJSON, "{}")
        XCTAssertEqual(result.body, "body")
    }

    func testCommentLineIgnored() throws {
        let md = """
        ---
        # this is a comment
        title: Hello
        ---
        body
        """
        let result = FrontmatterParser.split(md)
        let dict = try jsonDict(result.frontmatterJSON)
        XCTAssertEqual(dict?["title"] as? String, "Hello")
        XCTAssertEqual(dict?.count, 1)
    }

    func testBodyWithMultipleLines() throws {
        let md = """
        ---
        title: T
        ---
        line one
        line two
        line three
        """
        let result = FrontmatterParser.split(md)
        XCTAssertEqual(result.body, "line one\nline two\nline three")
    }

    // MARK: - Helpers

    private func jsonDict(_ json: String?) throws -> [String: Any]? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
