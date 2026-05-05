// TEMPORARY — Phase 2 benchmark only. Delete after the report is final.

import Foundation

func bench(_ name: String, iterations: Int = 100, _ body: () -> Void) -> (avg_ms: Double, max_ms: Double, min_ms: Double) {
    // Warm-up: 5 iterations not counted, so caches / first-touch cost
    // doesn't dominate the average.
    for _ in 0..<5 { body() }
    var times: [Double] = []
    times.reserveCapacity(iterations)
    for _ in 0..<iterations {
        let start = DispatchTime.now()
        body()
        let end = DispatchTime.now()
        let ns = Double(end.uptimeNanoseconds - start.uptimeNanoseconds)
        times.append(ns / 1_000_000.0)
    }
    let avg = times.reduce(0, +) / Double(times.count)
    let mx = times.max() ?? 0
    let mn = times.min() ?? 0
    return (avg, mx, mn)
}

func report(_ name: String, _ chars: Int, _ r: (avg_ms: Double, max_ms: Double, min_ms: Double)) {
    let padded = name.padding(toLength: 48, withPad: " ", startingAt: 0)
    let nums = String(format: "%6d chars   avg=%7.3f ms   max=%7.3f ms   min=%7.3f ms",
                      chars, r.avg_ms, r.max_ms, r.min_ms)
    print("  " + padded + nums)
}

print("=== ContentBlock.parse ===")
do {
    let small = Fixtures.small()
    let medium = Fixtures.medium()
    let large = Fixtures.largePlain()
    let largeMC = Fixtures.largeMathCode()

    report("ContentBlock.parse / 2k JP + small code", small.count,
           bench("parse-small") { _ = ContentBlock.parse(small) })
    report("ContentBlock.parse / 8k JP + lists/code", medium.count,
           bench("parse-medium") { _ = ContentBlock.parse(medium) })
    report("ContentBlock.parse / 20k JP plain", large.count,
           bench("parse-large-plain") { _ = ContentBlock.parse(large) })
    report("ContentBlock.parse / 20k math+code mix", largeMC.count,
           bench("parse-large-mc") { _ = ContentBlock.parse(largeMC) })
}

print()
print("=== AttributedString(markdown:) ===")
do {
    let small = Fixtures.small()
    let medium = Fixtures.medium()
    let large = Fixtures.largePlain()

    let opts = AttributedString.MarkdownParsingOptions(
        interpretedSyntax: .inlineOnlyPreservingWhitespace
    )

    func parseMd(_ s: String) {
        _ = try? AttributedString(markdown: s, options: opts)
    }
    report("AttributedString(markdown:) / 2k", small.count,
           bench("md-small", iterations: 50) { parseMd(small) })
    report("AttributedString(markdown:) / 8k", medium.count,
           bench("md-medium", iterations: 50) { parseMd(medium) })
    report("AttributedString(markdown:) / 20k", large.count,
           bench("md-large", iterations: 30) { parseMd(large) })

    // Per-paragraph cost: take the parsed blocks of the medium fixture
    // and replay their AttributedString(markdown:) calls one paragraph
    // at a time, since that's the actual workload InlineMarkdownCache
    // sees.
    let blocks = ContentBlock.parse(medium)
    var paraTexts: [String] = []
    for b in blocks {
        if case .paragraph(let s) = b { paraTexts.append(s) }
    }
    let totalParaChars = paraTexts.reduce(0) { $0 + $1.count }
    let paraCount = paraTexts.count
    let r = bench("md-per-para", iterations: 30) {
        for p in paraTexts {
            _ = try? AttributedString(markdown: p, options: opts)
        }
    }
    let perParaAvg = paraCount == 0 ? 0 : r.avg_ms / Double(paraCount)
    print(String(format: "  AttributedString per paragraph (8k fixture, %d paras, %d total chars):",
                 paraCount, totalParaChars))
    print(String(format: "    avg per paragraph: %.3f ms (whole-batch avg=%.3f ms)",
                 perParaAvg, r.avg_ms))
}

print()
print("=== contentBlocksExcludingThinking — substring + regex collapse ===")
do {
    // Simulate the body's chain: a 20k content with 4 thinking-text spans
    // baked in. The benchmark replays the substring removal + regex
    // collapse + re-parse cost from MessageBubbleView.swift:1147-1164.
    var content = ""
    let thinking = "<thinking-block-text-marker-XYZ>これは内省ブロックの本文として、それなりに長めの文章を含めた典型例である。</thinking-block-text-marker-XYZ>"
    var n = 0
    while content.count < 20_000 {
        content += "これは通常の段落であり、検証目的で利用される文章である。\n\n"
        if n % 4 == 0 { content += thinking + "\n\n" }
        n += 1
    }
    let thinkingTexts = [thinking]

    let r = bench("excludeThinking-20k", iterations: 50) {
        var working = content
        for t in thinkingTexts {
            if let range = working.range(of: t) {
                working.removeSubrange(range)
            }
        }
        let collapsed = working
            .replacingOccurrences(
                of: #"\n{3,}"#,
                with: "\n\n",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
        _ = ContentBlock.parse(collapsed)
    }
    report("excludeThinking + regex collapse + re-parse", content.count, r)
}

print()
print("=== LineBreakHints.softWrap ===")
do {
    let p = Fixtures.longParagraph()
    let large = Fixtures.largePlain()
    report("LineBreakHints.softWrap / 1.5k mixed", p.count,
           bench("softwrap-mixed") { _ = LineBreakHints.softWrap(p) })
    report("LineBreakHints.softWrap / 20k JP", large.count,
           bench("softwrap-large", iterations: 30) { _ = LineBreakHints.softWrap(large) })
}

print()
print("=== Per-message full pipeline (parse + per-block markdown) ===")
do {
    // Simulates one MessageBubbleView body evaluation on a cache-miss:
    // ContentBlock.parse() then AttributedString(markdown:) on each
    // paragraph / heading / list-item / blockquote text.
    let opts = AttributedString.MarkdownParsingOptions(
        interpretedSyntax: .inlineOnlyPreservingWhitespace
    )
    func fullPipeline(_ content: String) {
        let blocks = ContentBlock.parse(content)
        for b in blocks {
            switch b {
            case .paragraph(let s),
                 .heading(_, let s),
                 .blockquote(let s),
                 .listItem(_, _, let s, _):
                _ = try? AttributedString(markdown: s, options: opts)
            default:
                break
            }
        }
    }
    let small = Fixtures.small()
    let medium = Fixtures.medium()
    let large = Fixtures.largePlain()
    let largeMC = Fixtures.largeMathCode()
    report("full pipeline / 2k", small.count,
           bench("full-2k", iterations: 50) { fullPipeline(small) })
    report("full pipeline / 8k", medium.count,
           bench("full-8k", iterations: 30) { fullPipeline(medium) })
    report("full pipeline / 20k plain", large.count,
           bench("full-20k", iterations: 20) { fullPipeline(large) })
    report("full pipeline / 20k math+code", largeMC.count,
           bench("full-20k-mc", iterations: 20) { fullPipeline(largeMC) })
}
