import XCTest
@testable import MadiniArchive

final class WikiMarkdownPreprocessorTests: XCTestCase {
    private let vaultPath = "/tmp/vault"

    // MARK: - Plain wikilinks

    func testSimpleWikilink() {
        let input = "See [[chr_0017]] for details."
        let output = WikiMarkdownPreprocessor.preprocess(input, vaultPath: vaultPath)
        XCTAssertEqual(output, "See [chr_0017](wiki://chr_0017) for details.")
    }

    func testWikilinkWithDisplay() {
        let input = "See [[chr_0017|錫花]]."
        let output = WikiMarkdownPreprocessor.preprocess(input, vaultPath: vaultPath)
        XCTAssertEqual(output, "See [錫花](wiki://chr_0017).")
    }

    func testWikilinkWithHeading() {
        let input = "See [[chr_0017#Background]]."
        let output = WikiMarkdownPreprocessor.preprocess(input, vaultPath: vaultPath)
        XCTAssertEqual(
            output,
            "See [chr_0017#Background](wiki://chr_0017#Background)."
        )
    }

    func testMultipleWikilinks() {
        let input = "[[a]] and [[b]] and [[c|see-c]]."
        let output = WikiMarkdownPreprocessor.preprocess(input, vaultPath: vaultPath)
        XCTAssertEqual(output, "[a](wiki://a) and [b](wiki://b) and [see-c](wiki://c).")
    }

    func testWikilinkAtStartOfString() {
        let input = "[[start]] then text"
        let output = WikiMarkdownPreprocessor.preprocess(input, vaultPath: vaultPath)
        XCTAssertEqual(output, "[start](wiki://start) then text")
    }

    func testNoWikilinksUnchanged() {
        let input = "Plain markdown without links."
        let output = WikiMarkdownPreprocessor.preprocess(input, vaultPath: vaultPath)
        XCTAssertEqual(output, input)
    }

    // MARK: - Embeds

    func testEmbedRewrittenToFileURL() {
        let input = "![[diagram.png]]"
        let output = WikiMarkdownPreprocessor.preprocess(input, vaultPath: vaultPath)
        XCTAssertEqual(output, "![diagram.png](file:///tmp/vault/diagram.png)")
    }

    func testEmbedWithSubdir() {
        let input = "![[assets/map.png]]"
        let output = WikiMarkdownPreprocessor.preprocess(input, vaultPath: vaultPath)
        XCTAssertEqual(output, "![assets/map.png](file:///tmp/vault/assets/map.png)")
    }

    func testEmbedSizeHintStripped() {
        // Obsidian uses `|` for size hints; we drop it in Phase A.
        let input = "![[chart.png|200]]"
        let output = WikiMarkdownPreprocessor.preprocess(input, vaultPath: vaultPath)
        XCTAssertEqual(output, "![chart.png](file:///tmp/vault/chart.png)")
    }

    // MARK: - Embed vs wikilink disambiguation

    func testEmbedDoesNotBecomeWikilink() {
        // The `!` prefix must protect the link from also matching the
        // bare wikilink pattern.
        let input = "![[image.png]]"
        let output = WikiMarkdownPreprocessor.preprocess(input, vaultPath: vaultPath)
        XCTAssertFalse(output.contains("wiki://"))
        XCTAssertTrue(output.contains("file://"))
    }

    func testMixedEmbedsAndWikilinks() {
        let input = "See [[notes]] and ![[map.png]] for context."
        let output = WikiMarkdownPreprocessor.preprocess(input, vaultPath: vaultPath)
        XCTAssertTrue(output.contains("[notes](wiki://notes)"))
        XCTAssertTrue(output.contains("file:///tmp/vault/map.png"))
    }

    // MARK: - URL encoding

    func testNonASCIITargetsArePercentEncoded() {
        let input = "[[キャラ]]"
        let output = WikiMarkdownPreprocessor.preprocess(input, vaultPath: vaultPath)
        // Display preserves Japanese; URL host is percent-encoded.
        XCTAssertTrue(output.contains("[キャラ]"))
        XCTAssertTrue(output.contains("wiki://%"))
    }

    func testEmbedWithSpaceInPath() {
        let input = "![[my image.png]]"
        let output = WikiMarkdownPreprocessor.preprocess(input, vaultPath: vaultPath)
        XCTAssertTrue(output.contains("file:///tmp/vault/my%20image.png"))
    }
}
