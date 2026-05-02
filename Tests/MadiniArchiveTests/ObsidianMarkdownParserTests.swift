import XCTest
@testable import MadiniArchive

final class ObsidianMarkdownParserTests: XCTestCase {
    // MARK: - Wikilink shapes

    func testSimpleWikilink() {
        let result = ObsidianMarkdownParser.parse("See [[chr_0017]] for details.")
        XCTAssertEqual(result.wikilinks.count, 1)
        let link = result.wikilinks[0]
        XCTAssertEqual(link.target, "chr_0017")
        XCTAssertNil(link.display)
        XCTAssertNil(link.heading)
        XCTAssertNil(link.blockRef)
        XCTAssertFalse(link.isEmbed)
    }

    func testWikilinkWithDisplay() {
        let result = ObsidianMarkdownParser.parse("See [[chr_0017|錫花]].")
        XCTAssertEqual(result.wikilinks.count, 1)
        let link = result.wikilinks[0]
        XCTAssertEqual(link.target, "chr_0017")
        XCTAssertEqual(link.display, "錫花")
        XCTAssertNil(link.heading)
        XCTAssertNil(link.blockRef)
    }

    func testWikilinkWithHeading() {
        let result = ObsidianMarkdownParser.parse("See [[chr_0017#Background]].")
        let link = result.wikilinks[0]
        XCTAssertEqual(link.target, "chr_0017")
        XCTAssertEqual(link.heading, "Background")
        XCTAssertNil(link.display)
    }

    func testWikilinkWithBlockRef() {
        let result = ObsidianMarkdownParser.parse("See [[chr_0017^abc123]].")
        let link = result.wikilinks[0]
        XCTAssertEqual(link.target, "chr_0017")
        XCTAssertEqual(link.blockRef, "abc123")
        XCTAssertNil(link.heading)
    }

    func testWikilinkWithHeadingAndDisplay() {
        let result = ObsidianMarkdownParser.parse("See [[chr_0017#Background|プロフィール]].")
        let link = result.wikilinks[0]
        XCTAssertEqual(link.target, "chr_0017")
        XCTAssertEqual(link.heading, "Background")
        XCTAssertEqual(link.display, "プロフィール")
    }

    func testEmbedWikilink() {
        let result = ObsidianMarkdownParser.parse("![[diagram.png]]")
        XCTAssertEqual(result.wikilinks.count, 1)
        let link = result.wikilinks[0]
        XCTAssertEqual(link.target, "diagram.png")
        XCTAssertTrue(link.isEmbed)
    }

    func testEmbedWithDisplay() {
        let result = ObsidianMarkdownParser.parse("![[chart.png|Stats Chart]]")
        let link = result.wikilinks[0]
        XCTAssertEqual(link.target, "chart.png")
        XCTAssertEqual(link.display, "Stats Chart")
        XCTAssertTrue(link.isEmbed)
    }

    // MARK: - Multiple links + ordering

    func testMultipleWikilinksInOrder() {
        let body = "First [[a]], then [[b|alias]], then ![[c.png]] and [[d#sec]]."
        let result = ObsidianMarkdownParser.parse(body)
        XCTAssertEqual(result.wikilinks.count, 4)
        XCTAssertEqual(result.wikilinks[0].target, "a")
        XCTAssertEqual(result.wikilinks[1].target, "b")
        XCTAssertEqual(result.wikilinks[1].display, "alias")
        XCTAssertEqual(result.wikilinks[2].target, "c.png")
        XCTAssertTrue(result.wikilinks[2].isEmbed)
        XCTAssertEqual(result.wikilinks[3].target, "d")
        XCTAssertEqual(result.wikilinks[3].heading, "sec")
    }

    func testNoWikilinks() {
        let result = ObsidianMarkdownParser.parse("Plain markdown without links.")
        XCTAssertTrue(result.wikilinks.isEmpty)
    }

    // MARK: - Frontmatter integration

    func testFrontmatterAndWikilinkCombined() throws {
        let md = """
        ---
        type: chr
        name: 錫花
        ---
        # 錫花

        See [[chr_0001|姉]] for the elder sister.
        """
        let result = ObsidianMarkdownParser.parse(md)
        XCTAssertNotNil(result.frontmatterJSON)
        XCTAssertTrue(result.body.hasPrefix("# 錫花"))
        XCTAssertEqual(result.wikilinks.count, 1)
        XCTAssertEqual(result.wikilinks[0].target, "chr_0001")
        XCTAssertEqual(result.wikilinks[0].display, "姉")
    }

    func testWikilinkInFrontmatterIsNotExtracted() {
        // Wikilinks inside frontmatter (e.g. `related: [[a]]`) belong to the
        // frontmatter, not the body — they must NOT show up in `wikilinks`.
        let md = """
        ---
        related: "[[a]]"
        ---
        Body has [[b]].
        """
        let result = ObsidianMarkdownParser.parse(md)
        XCTAssertEqual(result.wikilinks.count, 1)
        XCTAssertEqual(result.wikilinks[0].target, "b")
    }

    // MARK: - Edge cases

    func testMalformedWikilinkIgnored() {
        // Single brackets, unclosed double brackets — neither should match.
        let result = ObsidianMarkdownParser.parse("[[unclosed and [single] and [[ok]] end")
        XCTAssertEqual(result.wikilinks.count, 1)
        XCTAssertEqual(result.wikilinks[0].target, "ok")
    }

    func testWikilinkPathWithSlash() {
        let result = ObsidianMarkdownParser.parse("[[notes/sub/page]]")
        XCTAssertEqual(result.wikilinks[0].target, "notes/sub/page")
    }
}
