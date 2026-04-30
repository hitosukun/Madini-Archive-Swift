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
    /// Profile-gated entry point. When `collapseForeignRuns` is false,
    /// returns each block wrapped as `.block(_)` without language
    /// detection — the render pipeline stays uniform (still a
    /// `[MessageRenderItem]`) but no grouping is applied. Callers that
    /// know their source always wants grouping (or never wants it) can
    /// skip this and call `group(_:)` / build trivially directly.
    ///
    /// `nativeLanguage` lets the caller override what counts as
    /// "not foreign". Pass the conversation's detected primary
    /// language so a Japanese-primary thread treats Japanese as
    /// native even when the user's macOS locale is English. `nil`
    /// falls back to the system locale.
    static func items(
        from blocks: [ContentBlock],
        collapseForeignRuns: Bool,
        nativeLanguage: NLLanguage? = nil
    ) -> [MessageRenderItem] {
        guard collapseForeignRuns else {
            return blocks.map { .block($0) }
        }
        return group(blocks, nativeLanguage: nativeLanguage)
    }

    static func group(
        _ blocks: [ContentBlock],
        nativeLanguage: NLLanguage? = nil
    ) -> [MessageRenderItem] {
        let system = nativeLanguage ?? systemLanguage
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

    /// Detect the dominant language of a conversation by sampling
    /// text from its messages. Returns `nil` for inputs too short
    /// or too mixed to call confidently — caller falls back to
    /// `systemLanguage` in that case. Used so a Japanese-primary
    /// thread treats Japanese as native (no collapsed-block
    /// affordance over plain Japanese) even when the user's macOS
    /// locale is English. The reverse holds for English-primary
    /// threads on a Japanese system.
    ///
    /// Concatenates message text up to `sampleLimit` characters
    /// then runs one `NLLanguageRecognizer` pass — language
    /// recognition is global over the whole window, not per-block,
    /// so noise from short or mixed paragraphs averages out.
    static func primaryLanguage(
        ofMessageTexts texts: [String],
        sampleLimit: Int = 5_000,
        minCharacters: Int = 200,
        minimumConfidence: Double = 0.6
    ) -> NLLanguage? {
        var combined = ""
        for text in texts {
            if combined.count >= sampleLimit { break }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            // Phase 9 hotfix — compute remaining capacity AFTER
            // accounting for the separator we're about to append, and
            // bail out when capacity has run out. The previous version
            // appended `"\n\n"` first and then computed
            // `remaining = sampleLimit - combined.count`, which could
            // land at -1 / -2 when an earlier iteration had filled
            // `combined` to within 1-2 chars of `sampleLimit` (the
            // outer `>= sampleLimit` break only catches the exact
            // overshoot, not the off-by-2 caused by the separator).
            // Negative `remaining` then crashed `trimmed.prefix(_:)`
            // with "Can't take a prefix of negative length from a
            // collection" (SIGTRAP, observed in the wild on a real
            // conversation whose message lengths happened to land
            // `combined.count` at `sampleLimit - 1` mid-iteration).
            // Reordering the calculation and adding the early-break
            // removes both the negative-length path AND the silent
            // overshoot where `combined` could exceed `sampleLimit`
            // by the separator length.
            let separator = combined.isEmpty ? "" : "\n\n"
            let remaining = sampleLimit - combined.count - separator.count
            if remaining <= 0 { break }
            combined.append(separator)
            if trimmed.count <= remaining {
                combined.append(trimmed)
            } else {
                combined.append(String(trimmed.prefix(remaining)))
            }
        }
        let trimmedAll = combined.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedAll.count >= minCharacters else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmedAll)
        let hyps = recognizer.languageHypotheses(withMaximum: 1)
        guard let (language, confidence) = hyps.first,
              confidence >= minimumConfidence else {
            return nil
        }
        return language
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
        case .listItem:
            // Temporary fix for Bug A (math/list-item misdetection as
            // Spanish/Polish). Numbered list items frequently contain
            // short Latin-glyph payloads such as math notation
            // ("d(x, y) = d(y, x)") that NLLanguageRecognizer assigns to
            // a confident European language and the grouper then folds
            // away. Excluding listItem from language detection avoids
            // the false positive without touching the confidence
            // threshold or other rules. The trade-off — a genuinely
            // foreign-language list item no longer gets folded — is
            // acceptable: prose runs are paragraphs, and structurally
            // foreign list items are rare.
            //
            // TODO: Remove this exclusion when Phase 6 cleanup of
            // ForeignLanguageGrouping completes. See
            // docs/plans/thinking-preservation-2026-04-30.md for the
            // structural solution (thinking blocks preserved by the
            // Python importer + MessageRenderProfile.collapsesThinking
            // dispatch in the Swift reader).
            return nil
        case .table(let headers, let rows, _):
            return (headers + rows.flatMap { $0 }).joined(separator: " ")
        case .code, .math, .horizontalRule:
            return nil
        case .image:
            // Image blocks don't contribute prose to language detection.
            // The alt text is a short caption, often just "image" or
            // a filename, which would skew per-message language stats
            // if we mixed it in with actual body text.
            return nil
        }
    }

    /// Per-text dominant-language cache. NL detection is pure w.r.t.
    /// the input string, so memoizing is safe and cheap. Keeps the
    /// per-message grouping work near-zero on cache hits.
    private enum Detection {
        private static let cache = NSCache<NSString, NSString>()

        static func dominantLanguage(of block: ContentBlock) -> NLLanguage? {
            guard let text = textContent(of: block), text.count >= 20 else {
                return nil
            }
            // Temporary fix for Bug A v2 (math/formula paragraph
            // misdetection as Spanish/Polish/etc.). Display equations
            // such as "eml(x, y) = eˣ – ln(y)" frequently arrive as a
            // standalone paragraph of mostly Latin glyphs, parens,
            // and operators. NLLanguageRecognizer reads the
            // letter-and-punctuation pattern as a confident European
            // language and the grouper folds the formula away. The
            // listItem exclusion (commit faef0a5) caught the numbered-
            // list flavor of this bug; this guard catches the
            // paragraph flavor by requiring the text to be majority-
            // letters before language detection runs.
            //
            // The 0.55 threshold was tuned against observed false
            // positives ("eml(x, y) = eˣ – ln(y)" ≈ 45 % letters,
            // "d(x, y) = d(y, x)（対称性）" ≈ 38 %) without dropping
            // genuine prose ("The user wants me to act as Madini"
            // ≈ 86 %, "あたしはマディニだよ〜！" ≈ 94 %).
            //
            // TODO: Remove this guard when Phase 6 cleanup of
            // ForeignLanguageGrouping completes. See
            // docs/plans/thinking-preservation-2026-04-30.md for the
            // structural solution (thinking blocks preserved by the
            // Python importer + MessageRenderProfile.collapsesThinking
            // dispatch in the Swift reader).
            let letterCount = text.reduce(into: 0) { $0 += $1.isLetter ? 1 : 0 }
            if Double(letterCount) / Double(text.count) < 0.55 {
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
