import Foundation

/// Soft-wrap helper for the reader's prose / code / table-cell renderers.
///
/// **Why this exists:** SwiftUI `Text` (CoreText under the hood) breaks
/// lines at whitespace and CJK character boundaries, but does *not*
/// break inside long Latin-script tokens with no spaces. A URL like
/// `https://github.com/user/repo/blob/main/path/to/file.swift` or a
/// dotted identifier chain like `Sources.Views.Shared.MessageBubbleView`
/// counts as a single unbreakable run, and on a narrow reader pane it
/// overflows the bubble's available width — visible on English content,
/// invisible on Japanese (which breaks at every character).
///
/// **What this does:** scans `text` for unbreakable runs longer than
/// ~`threshold` characters and inserts a zero-width space (`U+200B`)
/// after path-like delimiters inside those runs (`/`, `.`, `-`, `_`,
/// `?`, `&`, `=`, `:`, `;`, `,`, `#`, `@`). The ZWSP is invisible at
/// render time but creates a break opportunity that CoreText can use
/// when wrapping. Short tokens (the common case) are returned
/// untouched, so the cost on regular prose is just a single linear scan.
///
/// **What this skips, when `inMarkdown` is true:**
///   * Markdown link syntax `[label](url)` — the URL portion stays
///     pristine so the autolink target remains a valid clickable URL
///     after AttributedString(markdown:) parsing.
///   * `<https://…>` autolink shorthand.
///   * Inline-code spans `` `...` `` — code is supposed to be verbatim;
///     inserting ZWSP would pollute clipboard copy.
///
/// **Tradeoffs accepted:**
///   * **Clipboard impurity.** When the user copies plain prose from
///     a Text that has had ZWSPs injected, the ZWSPs come along for
///     the ride. ZWSP is invisible in most paste destinations and
///     ignored by most parsers, but `wc -c` and byte-exact diff tools
///     will see them. Acceptable for an archive viewer; the
///     surrounding text is intelligible either way.
///   * **Find-in-page mismatch.** A user searching for `github.com/repo`
///     would not match the rendered ZWSP-injected text by character-
///     for-character. The reader's find bar (`DesignMockRootView`)
///     searches the *source* text, not the rendered text, so this is
///     a non-issue in practice — but worth noting if anyone wires a
///     downstream component against the visible string.
///
/// **Why ZWSP and not another approach:**
///   * `Text.lineBreakMode(.byCharWrapping)` does not exist on macOS
///     SwiftUI. UIKit has the API; AppKit / SwiftUI's `Text` does not
///     expose an equivalent. CoreText's `lineBreakStrategy` is the
///     closest, but its options (`.standard`, `.pushOut`,
///     `.hangulWordPriority`) don't change the inside-token behavior.
///   * `Text.allowsTightening(true)` shrinks letter spacing instead
///     of breaking lines.
///   * `Text.minimumScaleFactor(...)` font-shrinks the whole run, which
///     looks ugly and isn't what we want.
///   * Markdown rewriting at parse time was considered and rejected:
///     it would require a full custom parser, since `AttributedString
///     (markdown:)` runs after our string has already been built.
enum LineBreakHints {
    /// Threshold for "long unbreakable run". Empirically tuned: at
    /// the reader's `bodyFontSize` (15pt) on a narrow pane (~520pt
    /// content width), runs of 24+ characters start nudging the
    /// bubble. Shorter than this and SwiftUI's natural word-break is
    /// already adequate.
    private static let runThreshold = 24

    /// Path-like delimiters where we insert a soft-break opportunity.
    /// Order doesn't matter — membership test only. Includes URL
    /// delimiters (`/?#&=:`), filesystem / hostname (`./-_`), and
    /// CSV-style separators (`;,`) so dotted identifier chains and
    /// long parameter lists also wrap.
    private static let breakAfter: Set<Character> = [
        "/", ".", "-", "_", "?", "&", "=", ":", ";", ",", "#", "@"
    ]

    private static let zwsp: Character = "\u{200B}"

    /// Apply soft-break injection to `text`. Set `inMarkdown` to false
    /// for inputs that the markdown parser will not see (raw code
    /// blocks, table-cell strings rendered without the markdown
    /// pipeline) — the markdown-aware skips become unnecessary noise
    /// there and a verbatim string ends up cleaner.
    static func softWrap(_ text: String, inMarkdown: Bool = true) -> String {
        // Empty / short inputs can't have a long run; cheap exit.
        guard text.count > runThreshold else { return text }

        var output = String()
        output.reserveCapacity(text.count + text.count / 16)

        var i = text.startIndex
        var runStart: String.Index? = nil

        // Helper: flush the current unbreakable run from `runStart..<i`
        // into `output`, inserting ZWSP after delimiter chars when the
        // run is long enough to need wrapping.
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

            // ---- Markdown skip regions (only if inMarkdown) ----
            if inMarkdown {
                // Inline code span: `...` (a single backtick on each
                // side; doubled backticks for runs containing a single
                // backtick are rare in chat text — not handled
                // separately, the simple form covers ~99% of cases).
                if ch == "`",
                   let end = text[text.index(after: i)..<text.endIndex].firstIndex(of: "`") {
                    flushRun(i)
                    let closeIndex = text.index(after: end)
                    output.append(contentsOf: text[i..<closeIndex])
                    i = closeIndex
                    continue
                }

                // `[label](url)` — copy through verbatim including the
                // URL parens. Tight matching: only treat as a link if
                // we find both `](` and the closing `)` ahead.
                if ch == "[",
                   let bracketCloseRange = text.range(of: "](", range: i..<text.endIndex),
                   let parenCloseIndex = text[bracketCloseRange.upperBound..<text.endIndex].firstIndex(of: ")") {
                    flushRun(i)
                    let endExclusive = text.index(after: parenCloseIndex)
                    output.append(contentsOf: text[i..<endExclusive])
                    i = endExclusive
                    continue
                }

                // `<https://…>` autolink shorthand. Match only when
                // the angle-bracket payload looks like a scheme'd URL
                // or an email — bare `<x>` in prose would be HTML-
                // looking and we don't want to treat it as a link.
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

            // ---- Run accumulation ----
            // A "run" is a maximal sequence of non-whitespace,
            // non-CJK characters. CJK characters break naturally on
            // their own; whitespace ends a run. Newlines also end a
            // run (text passed in here may include them for code
            // blocks).
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

    /// Quick CJK detector — covers Hiragana, Katakana, CJK Unified
    /// Ideographs, and the most common compatibility / extension
    /// blocks. Used to terminate runs at CJK boundaries (CoreText
    /// already breaks lines per CJK character, so injecting ZWSP
    /// inside CJK content is wasted work).
    private static func isCJK(_ ch: Character) -> Bool {
        for scalar in ch.unicodeScalars {
            let v = scalar.value
            if (0x3040...0x30FF).contains(v) ||  // Hiragana / Katakana
               (0x4E00...0x9FFF).contains(v) ||  // CJK Unified
               (0x3400...0x4DBF).contains(v) ||  // CJK Ext A
               (0xF900...0xFAFF).contains(v) ||  // CJK Compatibility
               (0xFF00...0xFFEF).contains(v) {   // Halfwidth / Fullwidth
                return true
            }
        }
        return false
    }
}
