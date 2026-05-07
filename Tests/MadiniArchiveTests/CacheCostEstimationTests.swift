import XCTest
#if os(macOS)
import AppKit
#else
import UIKit
#endif
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

    // MARK: - NSImage / UIImage retina-aware cost (Phase 3a-fix retina)

    #if os(macOS)
    func testCostForNSImageWithBitmapRepUsesPixelDimensions() {
        // 100×50 pixel rep — cost should reflect the *pixel* count,
        // NOT the logical size, even on a retina display.
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 100,
            pixelsHigh: 50,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 32
        )
        XCTAssertNotNil(rep)
        guard let rep else { return }
        let image = NSImage(size: NSSize(width: 50, height: 25)) // logical points (half)
        image.addRepresentation(rep)

        // Expectation: rep's pixelsWide×pixelsHigh wins (100*50*4),
        // NOT image.size (50*25*4 = 5000).
        XCTAssertEqual(
            CacheCostEstimation.costForImage(image),
            100 * 50 * 4
        )
    }

    func testCostForNSImagePicksLargestRepWhenMultipleAttached() {
        let small = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 10, pixelsHigh: 10,
            bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 32
        )!
        let large = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 200, pixelsHigh: 100,
            bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 32
        )!
        let image = NSImage(size: NSSize(width: 100, height: 50))
        image.addRepresentation(small)
        image.addRepresentation(large)

        // Heaviest rep should win (200*100*4 = 80,000).
        XCTAssertEqual(
            CacheCostEstimation.costForImage(image),
            200 * 100 * 4
        )
    }

    func testCostForNSImageWithoutRepUsesAssumedRetinaScale() {
        // No representation attached — fallback uses size × 2.0
        // (assumedRetinaBackingScale).
        let image = NSImage(size: NSSize(width: 60, height: 40))
        // Expected: (60*2)*(40*2)*4 = 120*80*4 = 38,400.
        let scale = CacheCostEstimation.assumedRetinaBackingScale
        let expected = Int((60 * scale).rounded()) * Int((40 * scale).rounded()) * 4
        XCTAssertEqual(CacheCostEstimation.costForImage(image), expected)
    }

    func testCostForNSImageZeroSizeAndNoRepClampsToOne() {
        let image = NSImage(size: .zero)
        // Both width and height clamp to 1 after the (0 * scale).rounded() = 0
        // path goes through max(_, 1).
        XCTAssertEqual(CacheCostEstimation.costForImage(image), 1 * 1 * 4)
    }
    #else
    func testCostForUIImageUsesPixelScale() {
        // UIImage already exposes .scale; verify the pixel-aware
        // calculation kept its retina semantics.
        let size = CGSize(width: 50, height: 25)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { _ in }
        let pixelW = Int((size.width * image.scale).rounded())
        let pixelH = Int((size.height * image.scale).rounded())
        XCTAssertEqual(
            CacheCostEstimation.costForImage(image),
            pixelW * pixelH * 4
        )
    }
    #endif
}
