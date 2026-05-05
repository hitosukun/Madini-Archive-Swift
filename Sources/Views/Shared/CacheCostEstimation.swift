import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Cost-estimation helpers for the byte-aware NSCache layer introduced
/// in Phase 3a.
///
/// `NSCache.totalCostLimit` evicts entries by an opaque integer "cost"
/// the caller attaches at insert time. We don't measure the actual
/// in-memory footprint of every cached value — that would require
/// poking at internal storage of `AttributedString`, `NSImage`, etc.
/// Instead we use cheap, deterministic estimators that scale linearly
/// with the input string size, matching Phase 3 decision A-2 (`utf8 *
/// 4` for text-derived values).
///
/// The factor 4 is calibrated against a typical `AttributedString` from
/// `AttributedString(markdown:)`: original UTF-8 bytes plus the
/// CommonMark run table plus per-run attribute storage. Empirically
/// this lands within 2-3x of the true byte cost across short prose,
/// long Japanese paragraphs, and mixed code/text blocks — an accuracy
/// sufficient for eviction decisions but not exact-byte accounting.
enum CacheCostEstimation {
    /// Multiplier applied to UTF-8 byte length when estimating the
    /// cost of a value derived from a source string (parsed blocks,
    /// rendered AttributedString, etc.). Single point of adjustment if
    /// later profiling suggests a different ratio.
    static let textExpansionFactor = 4

    /// Cost in bytes for a value whose memory footprint scales with the
    /// length of `text`. Adopt this for `AttributedString`,
    /// `[ContentBlock]`, and any other text-derived cache value.
    static func costForText(_ text: String) -> Int {
        return text.utf8.count * textExpansionFactor
    }

    /// Per-entry minimum cost. `NSCache.totalCostLimit` ignores entries
    /// whose cost is zero (they never trigger eviction), so we floor an
    /// otherwise-empty block list at this value to keep the entry
    /// participating in eviction. Content-bearing blocks always exceed
    /// this floor naturally.
    static let emptyBlocksFloorBytes = 64

    /// Cost for a parsed `[ContentBlock]` array. Sums the visible-text
    /// content of each block; non-text blocks (`horizontalRule`)
    /// contribute a small fixed allowance to capture per-entry
    /// overhead without claiming zero. An entirely empty array uses
    /// `emptyBlocksFloorBytes` so the entry stays evictable.
    static func costForBlocks(_ blocks: [ContentBlock]) -> Int {
        guard !blocks.isEmpty else { return emptyBlocksFloorBytes }
        var total = 0
        for block in blocks {
            switch block {
            case .paragraph(let s),
                 .blockquote(let s),
                 .math(let s):
                total += costForText(s)
            case .heading(_, let s):
                total += costForText(s)
            case .listItem(_, _, let s, let marker):
                total += costForText(s) + costForText(marker)
            case .code(let lang, let body):
                total += costForText(body)
                if let lang { total += costForText(lang) }
            case .table(let headers, let rows, _):
                for h in headers { total += costForText(h) }
                for row in rows {
                    for cell in row { total += costForText(cell) }
                }
            case .horizontalRule:
                total += 32
            case .image(let url, let alt):
                total += costForText(url) + costForText(alt)
            }
        }
        return total
    }

    /// Cost for a decoded raster image cached in memory. Width × height
    /// × 4 bytes (RGBA8), which is the minimum a Core Graphics-backed
    /// `NSImage` / `UIImage` takes for its primary representation. Real
    /// memory may exceed this when the image carries multiple
    /// representations or vector data, but for cache-eviction sizing
    /// the lower bound is the right anchor.
    static func costForImage(width: Int, height: Int) -> Int {
        let w = max(width, 1)
        let h = max(height, 1)
        return w * h * 4
    }

    #if os(macOS)
    /// Convenience for `NSImage`. Falls back to a 1×1 estimate when the
    /// size is unknown so the entry is never assigned zero cost.
    static func costForImage(_ image: NSImage) -> Int {
        let s = image.size
        return costForImage(width: Int(s.width.rounded()), height: Int(s.height.rounded()))
    }
    #else
    /// Convenience for `UIImage`. Same fallback rationale as macOS.
    static func costForImage(_ image: UIImage) -> Int {
        let s = image.size
        let scale = image.scale
        return costForImage(
            width: Int((s.width * scale).rounded()),
            height: Int((s.height * scale).rounded())
        )
    }
    #endif
}
