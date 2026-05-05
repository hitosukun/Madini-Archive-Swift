import XCTest
@testable import MadiniArchive

final class CacheCostEstimationTests: XCTestCase {
    // MARK: - Text cost

    func testCostForEmptyTextIsZero() {
        XCTAssertEqual(CacheCostEstimation.costForText(""), 0)
    }

    func testCostForAsciiTextScalesWithFactor() {
        // "hello" = 5 utf-8 bytes; factor = 4
        XCTAssertEqual(
            CacheCostEstimation.costForText("hello"),
            5 * CacheCostEstimation.textExpansionFactor
        )
    }

    func testCostForJapaneseTextUsesUTF8ByteCount() {
        // Each kana is 3 utf-8 bytes; "あいう" = 9 bytes
        XCTAssertEqual(
            CacheCostEstimation.costForText("あいう"),
            9 * CacheCostEstimation.textExpansionFactor
        )
    }

    // MARK: - Blocks cost

    func testCostForEmptyBlocksUsesFloor() {
        // An empty block list still occupies bookkeeping; floor keeps the
        // entry evictable instead of cost=0.
        XCTAssertEqual(
            CacheCostEstimation.costForBlocks([]),
            CacheCostEstimation.emptyBlocksFloorBytes
        )
    }

    func testCostForParagraphBlockTracksText() {
        let blocks: [ContentBlock] = [.paragraph("hello world")]
        let expected = "hello world".utf8.count * CacheCostEstimation.textExpansionFactor
        XCTAssertEqual(CacheCostEstimation.costForBlocks(blocks), expected)
    }

    func testCostForMultipleBlocksSums() {
        let blocks: [ContentBlock] = [
            .paragraph("aa"),
            .heading(level: 1, text: "bbb"),
            .blockquote("c"),
        ]
        let expected = (2 + 3 + 1) * CacheCostEstimation.textExpansionFactor
        XCTAssertEqual(CacheCostEstimation.costForBlocks(blocks), expected)
    }

    func testCostForListItemIncludesMarker() {
        let blocks: [ContentBlock] = [
            .listItem(ordered: true, depth: 0, text: "step", marker: "1.")
        ]
        let expected = ("step".utf8.count + "1.".utf8.count)
            * CacheCostEstimation.textExpansionFactor
        XCTAssertEqual(CacheCostEstimation.costForBlocks(blocks), expected)
    }

    func testCostForCodeBlockIncludesLanguage() {
        let blocks: [ContentBlock] = [
            .code(language: "swift", code: "let x = 1")
        ]
        let expected = ("let x = 1".utf8.count + "swift".utf8.count)
            * CacheCostEstimation.textExpansionFactor
        XCTAssertEqual(CacheCostEstimation.costForBlocks(blocks), expected)
    }

    func testCostForTableSumsAllCells() {
        let blocks: [ContentBlock] = [
            .table(
                headers: ["a", "bb"],
                rows: [["c", "dd"], ["e", "ff"]],
                alignments: [.leading, .leading]
            )
        ]
        let totalChars = 1 + 2 + 1 + 2 + 1 + 2
        XCTAssertEqual(
            CacheCostEstimation.costForBlocks(blocks),
            totalChars * CacheCostEstimation.textExpansionFactor
        )
    }

    func testCostForHorizontalRuleHasFixedAllowance() {
        let blocks: [ContentBlock] = [.horizontalRule]
        // Single rule: 32-byte per-entry allowance, no floor (list non-empty).
        XCTAssertEqual(CacheCostEstimation.costForBlocks(blocks), 32)
    }

    func testCostForImageBlockTracksTextFields() {
        let blocks: [ContentBlock] = [
            .image(url: "https://x.example/a.png", alt: "alt")
        ]
        let expected = ("https://x.example/a.png".utf8.count + "alt".utf8.count)
            * CacheCostEstimation.textExpansionFactor
        XCTAssertEqual(CacheCostEstimation.costForBlocks(blocks), expected)
    }

    // MARK: - Image cost

    func testCostForImageDimensionsIsRGBA8() {
        XCTAssertEqual(
            CacheCostEstimation.costForImage(width: 100, height: 50),
            100 * 50 * 4
        )
    }

    func testCostForImageZeroDimensionsClampsToOne() {
        // Defensive: zero would make the entry exempt from cost-based eviction.
        XCTAssertEqual(
            CacheCostEstimation.costForImage(width: 0, height: 0),
            1 * 1 * 4
        )
    }

    func testCostForImageNegativeDimensionsClampsToOne() {
        XCTAssertEqual(
            CacheCostEstimation.costForImage(width: -10, height: 200),
            1 * 200 * 4
        )
    }
}
