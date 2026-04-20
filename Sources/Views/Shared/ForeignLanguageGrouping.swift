import Foundation
import NaturalLanguage

/// One unit produced by `ForeignLanguageGrouping.group(_:)`. Either a
/// regular content block (rendered as before) or a contiguous run of
/// foreign-language blocks bundled into a de-emphasized group with an
/// opt-in translate affordance.
enum MessageRenderItem {
    case block(ContentBlock)
    case foreignLanguageGroup(language: NLLanguage, blocks: [ContentBlock])
}

/// Detects per-block dominant language via `NLLanguageRecognizer` and
/// folds consecutive blocks whose language differs from the system
/// language into a single grouped item. Grouping reduces visual
/// fragmentation when an assistant emits a multi-paragraph foreign
/// preamble (Claude's "thinking out loud" in English before answering
/// in Japanese, etc.) — one bordered, faded box reads as "you can skip
/// this" rather than four jarring paragraphs.
///
/// Detection rules:
///  - Skip blocks that have no natural-language text (`code`, `math`,
///    `horizontalRule`). They neither extend nor break a foreign group.
///    A code block between two foreign paragraphs would render as two
///    separate foreign groups with the code block in normal styling
///    between — accepted simplicity for v1.
///  - Require ≥20 characters of text. `dominantLanguage` is unreliable
///    on very short snippets (a single English word in a Japanese
///    sentence can flip the prediction).
///  - Require ≥0.6 confidence in the dominant-language hypothesis.
///    Below that we treat the text as "not confidently foreign" and
///    leave it as a normal block.
enum ForeignLanguageGrouping {
    static func group(_ blocks: [ContentBlock], mode: GroupingMode = .allRuns) -> [MessageRenderItem] {
        switch mode {
        case .allRuns:
            return groupAllRuns(blocks)
        case .leadingRunOnly:
            return groupLeadingRunOnly(blocks)
        }
    }

    enum GroupingMode {
        case allRuns
        case leadingRunOnly
    }

    private static func groupAllRuns(_ blocks: [ContentBlock]) -> [MessageRenderItem] {
        let system = systemLanguage
        var result: [MessageRenderItem] = []
        var pending: (language: NLLanguage, blocks: [ContentBlock])?

        func flush() {
            guard let p = pending else { return }
            result.append(.foreignLanguageGroup(language: p.language, blocks: p.blocks))
            pending = nil
        }

        for block in blocks {
            let detected = Detection.dominantLanguage(of: block)
            if let lang = detected, lang != system {
                if var p = pending, p.language == lang {
                    p.blocks.append(block)
                    pending = p
                } else {
                    flush()
                    pending = (lang, [block])
                }
            } else {
                flush()
                result.append(.block(block))
            }
        }
        flush()
        return result
    }

    /// Narrower mode used for assistant replies: only fold a foreign-
    /// language run if it appears at the very start of the message.
    /// This matches the original UX goal — collapse Claude/ChatGPT's
    /// initial English "thinking out loud" preamble — without
    /// de-emphasizing later legitimate content such as standalone math
    /// explanations, quoted snippets, or short English sub-sections.
    private static func groupLeadingRunOnly(_ blocks: [ContentBlock]) -> [MessageRenderItem] {
        let system = systemLanguage
        var leadingBlocks: [MessageRenderItem] = []
        var prefixLanguage: NLLanguage?
        var prefixBlocks: [ContentBlock] = []
        var index = 0

        while index < blocks.count {
            let block = blocks[index]
            if prefixBlocks.isEmpty, Detection.isIgnorableLeadingBlock(block) {
                leadingBlocks.append(.block(block))
                index += 1
                continue
            }

            guard let lang = Detection.dominantLanguage(of: block), lang != system else {
                break
            }

            if let prefixLanguage {
                guard prefixLanguage == lang else { break }
            } else {
                prefixLanguage = lang
            }

            prefixBlocks.append(block)
            index += 1
        }

        guard let prefixLanguage, !prefixBlocks.isEmpty else {
            return blocks.map(MessageRenderItem.block)
        }

        var result: [MessageRenderItem] = leadingBlocks
        result.append(.foreignLanguageGroup(language: prefixLanguage, blocks: prefixBlocks))
        result.append(contentsOf: blocks.dropFirst(index).map(MessageRenderItem.block))
        return result
    }

    /// System-preferred language as `NLLanguage`. Falls back to
    /// English when the locale doesn't expose a code (shouldn't
    /// happen on Apple OSes but we keep the default sensible).
    static var systemLanguage: NLLanguage {
        if let code = Locale.current.language.languageCode?.identifier {
            return NLLanguage(rawValue: code)
        }
        if let preferred = Locale.preferredLanguages.first?.split(separator: "-").first {
            return NLLanguage(rawValue: String(preferred))
        }
        return .english
    }

    static func textContent(of block: ContentBlock) -> String? {
        switch block {
        case .paragraph(let s), .blockquote(let s):
            return s
        case .heading(_, let s):
            return s
        case .listItem(_, _, let s, _):
            return s
        case .table(let headers, let rows, _):
            return (headers + rows.flatMap { $0 }).joined(separator: " ")
        case .code, .math, .horizontalRule:
            return nil
        }
    }

    /// Per-text dominant-language cache. NL detection is pure w.r.t.
    /// the input string, so memoizing is safe and cheap. Keeps the
    /// per-message grouping work near-zero on cache hits.
    private enum Detection {
        private static let cache = NSCache<NSString, NSString>()

        static func isIgnorableLeadingBlock(_ block: ContentBlock) -> Bool {
            guard let text = textContent(of: block)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !text.isEmpty else {
                return true
            }

            if text.contains("http://") || text.contains("https://") {
                return true
            }

            return false
        }

        static func dominantLanguage(of block: ContentBlock) -> NLLanguage? {
            guard let text = textContent(of: block), text.count >= 20 else {
                return nil
            }
            let key = text as NSString
            if let cached = cache.object(forKey: key) {
                return cached as String == "" ? nil : NLLanguage(rawValue: cached as String)
            }
            let recognizer = NLLanguageRecognizer()
            recognizer.processString(text)
            // `languageHypotheses` exposes the confidence value
            // `dominantLanguage` hides — we want it so we can reject
            // weak guesses (mixed-script paragraphs, very short ones).
            let hypotheses = recognizer.languageHypotheses(withMaximum: 1)
            let lang: NLLanguage?
            if let (candidate, confidence) = hypotheses.first, confidence >= 0.6 {
                lang = candidate
            } else {
                lang = nil
            }
            // Cache empty string for "no confident detection" so we
            // don't re-run on every body eval.
            cache.setObject((lang?.rawValue ?? "") as NSString, forKey: key)
            return lang
        }
    }
}
