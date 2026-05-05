// TEMPORARY — Phase 2 benchmark only. Delete after the report is final.
// Verbatim copy of Sources/Views/Shared/LineBreakHints.swift.

import Foundation

enum LineBreakHints {
    private static let runThreshold = 24

    private static let breakAfter: Set<Character> = [
        "/", ".", "-", "_", "?", "&", "=", ":", ";", ",", "#", "@"
    ]

    private static let zwsp: Character = "\u{200B}"

    static func softWrap(_ text: String, inMarkdown: Bool = true) -> String {
        guard text.count > runThreshold else { return text }
        var output = String()
        output.reserveCapacity(text.count + text.count / 16)
        var i = text.startIndex
        var runStart: String.Index? = nil
        func flushRun(_ end: String.Index) {
            guard let start = runStart else { return }
            let run = text[start..<end]
            if run.count > runThreshold {
                for ch in run {
                    output.append(ch)
                    if breakAfter.contains(ch) {
                        output.append(zwsp)
                    }
                }
            } else {
                output.append(contentsOf: run)
            }
            runStart = nil
        }
        while i < text.endIndex {
            let ch = text[i]
            if inMarkdown {
                if ch == "`",
                   let end = text[text.index(after: i)..<text.endIndex].firstIndex(of: "`") {
                    flushRun(i)
                    let closeIndex = text.index(after: end)
                    output.append(contentsOf: text[i..<closeIndex])
                    i = closeIndex
                    continue
                }
                if ch == "[",
                   let bracketCloseRange = text.range(of: "](", range: i..<text.endIndex),
                   let parenCloseIndex = text[bracketCloseRange.upperBound..<text.endIndex].firstIndex(of: ")") {
                    flushRun(i)
                    let endExclusive = text.index(after: parenCloseIndex)
                    output.append(contentsOf: text[i..<endExclusive])
                    i = endExclusive
                    continue
                }
                if ch == "<",
                   let close = text[text.index(after: i)..<text.endIndex].firstIndex(of: ">") {
                    let inner = text[text.index(after: i)..<close]
                    let looksLikeURL = inner.contains("://") || inner.contains("@")
                    if looksLikeURL {
                        flushRun(i)
                        let endExclusive = text.index(after: close)
                        output.append(contentsOf: text[i..<endExclusive])
                        i = endExclusive
                        continue
                    }
                }
            }
            if ch.isWhitespace || ch.isNewline || isCJK(ch) {
                flushRun(i)
                output.append(ch)
                i = text.index(after: i)
            } else {
                if runStart == nil { runStart = i }
                i = text.index(after: i)
            }
        }
        flushRun(text.endIndex)
        return output
    }

    private static func isCJK(_ ch: Character) -> Bool {
        for scalar in ch.unicodeScalars {
            let v = scalar.value
            if (0x3040...0x30FF).contains(v) ||
               (0x4E00...0x9FFF).contains(v) ||
               (0x3400...0x4DBF).contains(v) ||
               (0xF900...0xFAFF).contains(v) ||
               (0xFF00...0xFFEF).contains(v) {
                return true
            }
        }
        return false
    }
}
