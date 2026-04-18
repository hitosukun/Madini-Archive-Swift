import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import SwiftMath

struct MessageBubbleView: View {
    enum DisplayMode {
        case rendered
        case plain
    }

    private enum Layout {
        static let avatarSize: CGFloat = 34
        static let avatarColumnWidth: CGFloat = 42
        // Caps were historically 12_000 / 8_000, which were conservative
        // to the point that long-form assistant replies (especially the
        // multi-section explanations ChatGPT / Claude produce) routinely
        // crossed them and collapsed into a single `.paragraph(entireBody)`
        // — all headings / code blocks / lists silently disappeared. An
        // earlier bump to 40k / 20k swung the other way and made opening
        // heavy conversations noticeably laggy: `AttributedString(markdown:)`
        // cost scales roughly linearly with paragraph size, and a single
        // 20k-char paragraph rendered first-screen pays that cost on the
        // main thread during initial layout. 20k per message / 12k per
        // paragraph is the middle ground — catches typical multi-section
        // explanations intact while keeping the per-frame parse budget
        // manageable.
        static let maxRenderedMessageLength = 20_000
        static let maxRenderedTextBlockLength = 12_000

        // Typography. The previous version inherited system-default sizes
        // everywhere, which rendered at ~13pt on macOS and felt cramped
        // for long reading sessions. These values are the result of
        // eyeballing against Bear / Obsidian / iA Writer — large enough
        // to read comfortably from a laptop screen, small enough that
        // code blocks still fit ~80 chars wide in the reader pane.
        static let bodyFontSize: CGFloat = 15
        static let codeFontSize: CGFloat = 14
        static let mathFontSize: CGFloat = 15
        static let heading1FontSize: CGFloat = 22
        static let heading2FontSize: CGFloat = 19
        static let heading3FontSize: CGFloat = 17
        static let minorHeadingFontSize: CGFloat = 15
    }

    let message: Message
    let displayMode: DisplayMode
    let identityContext: MessageIdentityContext?
    @Environment(IdentityPreferencesStore.self) private var identityPreferences
    #if os(macOS)
    @Environment(\.openSettings) private var openSettings
    #endif

    var body: some View {
        // Two layouts:
        //
        // - **User** → classic speech-bubble form. Avatar lives in its own
        //   trailing column; the message body sits inside an accent-tinted
        //   rounded rectangle. This visually flags "this is what I wrote"
        //   at a glance, which is still valuable because user prompts are
        //   the navigation anchors in the right pane.
        //
        // - **Assistant** → article-style, edge-to-edge. No dedicated
        //   avatar column (would eat ~52pt of reading width) and no
        //   rounded-rectangle frame (the bubble chrome becomes a visual
        //   prison for paragraphs the reader spends most of their time
        //   in). A compact inline byline at the top carries the avatar +
        //   name; content flows out to the full pane width below it.
        if message.isUser {
            HStack(alignment: .top, spacing: 10) {
                userMessageColumn

                avatarButton(size: Layout.avatarSize)
                    .frame(width: Layout.avatarColumnWidth, alignment: .topTrailing)
            }
        } else {
            assistantMessageColumn
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The avatar is a gateway into the Settings window where the user
    /// edits the user / assistant identity (name + avatar). Wrapped in a
    /// plain button so it stays visually identical while gaining a
    /// clickable affordance and an accessibility path.
    @ViewBuilder
    private func avatarButton(size: CGFloat) -> some View {
        #if os(macOS)
        Button {
            openSettings()
        } label: {
            IdentityAvatarView(
                presentation: identityPresentation,
                size: size
            )
        }
        .buttonStyle(.plain)
        .help("Edit identity in Settings")
        #else
        IdentityAvatarView(
            presentation: identityPresentation,
            size: size
        )
        #endif
    }

    /// User-side: bubble-framed message column with the trailing-aligned
    /// byline. This is the historic layout (avatar column lives outside,
    /// managed by `body`).
    private var userMessageColumn: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Spacer()

                Text(identityPresentation.displayName)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(identityPresentation.accentColor)
            }

            VStack(alignment: .leading, spacing: 10) {
                // User prompts render verbatim regardless of display mode.
                // The raw input often contains markdown-significant prefixes
                // (`# ...`, `- ...`) used as shorthand/outline rather than
                // as actual document structure — rendering them as H1s and
                // bullet lists blows the bubble up to several screens tall
                // and loses the visual parity between "prompt as typed"
                // and "prompt as shown."
                Text(verbatim: message.content)
                    .font(.system(size: Layout.bodyFontSize))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(bubbleBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Assistant-side: no bubble chrome, no dedicated avatar column. A
    /// compact inline byline (small avatar + name) sits above the content,
    /// which flows out to the pane's full width.
    private var assistantMessageColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Inline byline uses the full avatar size (same as the user
            // side's trailing-column avatar) so the two speakers feel
            // visually balanced — an earlier draft shrank the assistant
            // avatar to 22pt to match a caption baseline, but that made
            // the persona suddenly feel smaller than Jenna's, which read
            // as a downgrade.
            HStack(alignment: .center, spacing: 8) {
                avatarButton(size: Layout.avatarSize)

                Text(identityPresentation.displayName)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(identityPresentation.accentColor)

                Spacer()
            }

            VStack(alignment: .leading, spacing: 10) {
                // Assistant replies render fully — their markdown is
                // meaningful output (headings, lists, code blocks). The
                // `.plain` display mode switches to verbatim text, same
                // as user prompts, so power-users can inspect raw
                // content without losing formatting chars.
                if displayMode == .plain {
                    Text(verbatim: message.content)
                        .font(.system(size: Layout.bodyFontSize))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(Array(contentBlocks.enumerated()), id: \.offset) { _, block in
                        renderBlock(block)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Intentionally NO padding / background / clipShape here —
            // the assistant column's whole point is edge-to-edge reading
            // width. The inline byline above supplies the "who said this"
            // cue; the message body meets the pane margins directly.
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Block rendering

    @ViewBuilder
    private func renderBlock(_ block: ContentBlock) -> some View {
        switch block {
        case .paragraph(let text):
            paragraphView(text)
        case .heading(let level, let text):
            headingView(level: level, text: text)
        case .listItem(let ordered, let depth, let text, let marker):
            listItemView(ordered: ordered, depth: depth, text: text, marker: marker)
        case .blockquote(let text):
            blockquoteView(text)
        case .code(let language, let code):
            CodeBlockView(language: language, code: code, fontSize: Layout.codeFontSize)
        case .math(let source):
            MathBlockView(source: source, fontSize: Layout.mathFontSize)
        case .table(let headers, let rows, let alignments):
            TableBlockView(
                headers: headers,
                rows: rows,
                alignments: alignments,
                fontSize: Layout.bodyFontSize,
                renderInline: { renderInlineRich($0, fontSize: Layout.bodyFontSize) }
            )
        case .horizontalRule:
            Divider()
                .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func paragraphView(_ text: String) -> some View {
        let rendered: Text = {
            if canRenderMarkdown(text) {
                return renderInlineRich(text, fontSize: Layout.bodyFontSize)
            }
            return Text(verbatim: text)
        }()

        rendered
            .font(.system(size: Layout.bodyFontSize))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func headingView(level: Int, text: String) -> some View {
        let size: CGFloat = {
            switch level {
            case 1: return Layout.heading1FontSize
            case 2: return Layout.heading2FontSize
            case 3: return Layout.heading3FontSize
            default: return Layout.minorHeadingFontSize
            }
        }()

        renderInlineRich(text, fontSize: size)
            .font(.system(size: size, weight: .semibold))
            .textSelection(.enabled)
            .padding(.top, level <= 2 ? 6 : 2)
            .padding(.bottom, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func listItemView(ordered: Bool, depth: Int, text: String, marker: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(marker)
                .font(.system(size: Layout.bodyFontSize).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: ordered ? 22 : 14, alignment: .trailing)

            renderInlineRich(text, fontSize: Layout.bodyFontSize)
                .font(.system(size: Layout.bodyFontSize))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, CGFloat(depth) * 16)
    }

    @ViewBuilder
    private func blockquoteView(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(Color.accentColor.opacity(0.6))
                .frame(width: 3)

            renderInlineRich(text, fontSize: Layout.bodyFontSize)
                .font(.system(size: Layout.bodyFontSize).italic())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Identity / theme

    private var identityPresentation: MessageIdentityPresentation {
        identityPreferences.presentation(for: message.role, context: identityContext)
    }

    private var bubbleBackground: Color {
        message.isUser ? Color.accentColor.opacity(0.08) : PlatformColors.controlBackground
    }

    // MARK: - Content parsing + caching

    private var contentBlocks: [ContentBlock] {
        guard canRenderMessage else {
            return [.paragraph(message.content)]
        }
        // SwiftUI re-evaluates `body` on parent updates (selectedPromptID
        // changes, bookmark toggles, etc). Parsing markdown on every eval for
        // every visible bubble is measurable on long conversations — cache
        // the parsed blocks by message id so repeated renders are free.
        let key = message.id as NSString
        if let cached = Self.blocksCache.object(forKey: key) {
            return cached.blocks
        }
        let parsed = ContentBlock.parse(message.content)
        Self.blocksCache.setObject(BlocksBox(parsed), forKey: key)
        return parsed
    }

    private static let blocksCache: NSCache<NSString, BlocksBox> = {
        let cache = NSCache<NSString, BlocksBox>()
        cache.countLimit = 500
        return cache
    }()

    private final class BlocksBox {
        let blocks: [ContentBlock]
        init(_ blocks: [ContentBlock]) { self.blocks = blocks }
    }

    private var canRenderMessage: Bool {
        message.content.count <= Layout.maxRenderedMessageLength
    }

    /// Inline-only markdown: bold, italic, inline code, links. We handle
    /// block structures (headings, lists, etc.) ourselves above, so we
    /// specifically do NOT want `.full` here — that would double-format
    /// lines like `## heading` into both the structural heading AND the
    /// inline "##" text inside a heading block.
    ///
    /// The underlying `AttributedString(markdown:)` initializer is surprisingly
    /// expensive (it constructs a full CommonMark parse tree even for short
    /// paragraphs), so we memoize by the exact source string. Cache lives at
    /// process scope because the same paragraph often repeats across messages
    /// (greetings, signatures, template replies).
    private func renderInlineMarkdown(_ text: String) -> AttributedString {
        InlineMarkdownCache.shared.render(text)
    }

    /// Like `renderInlineMarkdown`, but first carves out any inline math
    /// spans (`$…$` or `\(…\)`) and renders them as typeset images
    /// inline-concatenated into the resulting `Text`.
    ///
    /// The block-level parser only recognizes `$$…$$` / `\[…\]` as its own
    /// `.math` block — anything inline-within-a-paragraph (e.g. "where
    /// $x_i$ denotes …") used to fall all the way through to
    /// `renderInlineMarkdown`, which not only left the `$` delimiters as
    /// literal characters but also let CommonMark chew on the math: a
    /// `$x_i$` would render as "$x<italic>i</italic>$" because `_` is an
    /// emphasis sigil. By extracting math spans FIRST and only feeding
    /// the surrounding text through markdown, the math content is
    /// immune to that mangling and comes out typeset.
    ///
    /// Math renders via `SwiftMath.MathImage` → `NSImage` / `UIImage`,
    /// marked as a template image so SwiftUI tints it with the current
    /// foreground color (so it follows dark / light mode and blockquote
    /// `.secondary` styling automatically). Images are embedded in the
    /// concatenated `Text` with a `baselineOffset(-descent)` so the
    /// math's internal baseline lines up with the surrounding prose
    /// baseline instead of its bounding box sitting on top.
    private func renderInlineRich(_ text: String, fontSize: CGFloat) -> Text {
        // Fast path: nothing that could possibly be inline math. Skip
        // the splitter entirely and go straight to the existing
        // markdown path (which itself has a fast path for pure prose).
        if !text.contains("$") && !text.contains("\\(") {
            return Text(renderInlineMarkdown(text))
        }

        let runs = InlineMathSplitter.split(text)

        // Splitter found no math spans worth extracting — collapse back
        // to the plain-markdown path so we don't pay for Text
        // concatenation when there's nothing to typeset.
        if runs.count == 1, case .text(let only) = runs[0] {
            return Text(renderInlineMarkdown(only))
        }

        var result = Text("")
        for run in runs {
            switch run {
            case .text(let segment):
                result = result + Text(renderInlineMarkdown(segment))
            case .math(let latex):
                if let rendered = InlineMathImageCache.shared.rendered(for: latex, fontSize: fontSize) {
                    #if os(macOS)
                    let image = Image(nsImage: rendered.image)
                        .renderingMode(.template)
                    #else
                    let image = Image(uiImage: rendered.image)
                        .renderingMode(.template)
                    #endif
                    // baselineOffset is in the "positive raises" sense.
                    // Image bottom lands on the text baseline by default,
                    // so the math's internal baseline sits `descent`
                    // above the text baseline — shift it back down.
                    result = result
                        + Text(image).baselineOffset(-rendered.descent)
                } else {
                    // Parse failure — restore the original delimited
                    // source so the user can still read / copy it.
                    result = result + Text(verbatim: "\\(\(latex)\\)")
                }
            }
        }
        return result
    }

    private func canRenderMarkdown(_ text: String) -> Bool {
        text.count <= Layout.maxRenderedTextBlockLength
    }
}

// MARK: - Inline math splitter

/// A single run produced by `InlineMathSplitter.split` — either literal
/// paragraph text (which will subsequently be markdown-parsed) or a math
/// fragment that should be typeset via SwiftMath.
private enum InlineTextRun {
    case text(String)
    case math(String)
}

/// Tokenizer that carves inline-math spans (`$…$` and `\(…\)`) out of a
/// paragraph's text, leaving the surrounding prose intact for the
/// markdown pass.
///
/// Rules:
/// - `\(…\)` is always treated as math (unambiguous LaTeX inline
///   delimiter; no reason for it to appear in prose).
/// - `$…$` is treated as math only when the body looks like math — i.e.
///   contains a backslash command, `^`/`_`, `{}`, or `=`. This keeps
///   prose that mentions dollar amounts (`"costs $5 and then $10"`)
///   from collapsing into a single eaten span.
/// - Spans never cross newlines — a stray `$` at end of line is safely
///   left as literal text.
/// - `$$` and `\[` are intentionally NOT consumed here; those are
///   block-level and handled by the line-oriented parser earlier.
private enum InlineMathSplitter {
    static func split(_ text: String) -> [InlineTextRun] {
        let chars = Array(text)
        var runs: [InlineTextRun] = []
        var buffer = ""
        var i = 0

        func flushBuffer() {
            guard !buffer.isEmpty else { return }
            runs.append(.text(buffer))
            buffer.removeAll(keepingCapacity: true)
        }

        while i < chars.count {
            let c = chars[i]

            // `\( … \)` — explicit inline-math delimiters.
            if c == "\\", i + 1 < chars.count, chars[i + 1] == "(" {
                if let end = findEscapedCloseParen(chars, from: i + 2), end > i + 2 {
                    flushBuffer()
                    runs.append(.math(String(chars[(i + 2)..<end])))
                    i = end + 2
                    continue
                }
            }

            // `$ … $` — single-dollar inline math. Skip `$$` which belongs
            // to the block parser, and require the interior to look
            // math-y so currency mentions don't get swallowed.
            if c == "$" {
                let isDoubleOpen = (i + 1 < chars.count && chars[i + 1] == "$")
                let prevIsDollar = (i > 0 && chars[i - 1] == "$")
                if !isDoubleOpen && !prevIsDollar {
                    if let end = findCloseDollar(chars, from: i + 1), end > i + 1 {
                        let latex = String(chars[(i + 1)..<end])
                        if looksLikeMath(latex) {
                            flushBuffer()
                            runs.append(.math(latex))
                            i = end + 1
                            continue
                        }
                    }
                }
            }

            buffer.append(c)
            i += 1
        }

        flushBuffer()
        return runs
    }

    private static func findEscapedCloseParen(_ chars: [Character], from start: Int) -> Int? {
        var i = start
        while i < chars.count - 1 {
            if chars[i] == "\n" { return nil }
            if chars[i] == "\\" && chars[i + 1] == ")" { return i }
            i += 1
        }
        return nil
    }

    private static func findCloseDollar(_ chars: [Character], from start: Int) -> Int? {
        var i = start
        while i < chars.count {
            let c = chars[i]
            if c == "\n" { return nil }
            // Skip over `\\`-escaped chars inside math (e.g. `\$` would
            // not close the span, though in practice LaTeX sources use
            // `\$` outside math, not inside).
            if c == "\\" && i + 1 < chars.count {
                i += 2
                continue
            }
            if c == "$" {
                // `$$` is a block marker — don't consume as close of an
                // inline span. Bail out so the outer loop keeps the
                // original `$` as literal text.
                if i + 1 < chars.count && chars[i + 1] == "$" {
                    return nil
                }
                return i
            }
            i += 1
        }
        return nil
    }

    /// Heuristic: only treat `$…$` as math if the interior has at least
    /// one character that's essentially never a literal dollar-to-dollar
    /// construct in prose. Avoids catastrophic false positives like
    /// "She paid $5 for a $10 burger" collapsing into one math span.
    private static func looksLikeMath(_ s: String) -> Bool {
        for c in s {
            switch c {
            case "\\", "^", "_", "{", "}", "=":
                return true
            default:
                continue
            }
        }
        return false
    }
}

// MARK: - Inline math image cache

/// Renders short LaTeX fragments to a template `NSImage` / `UIImage`
/// suitable for embedding in a SwiftUI `Text` run. "Template" means
/// SwiftUI tints it with the current `foregroundStyle`, so the math
/// inherits light/dark-mode color and blockquote `.secondary` styling
/// without us needing a second cache entry per color.
///
/// The cache is keyed on `fontSize|latex`; rerendering is expensive
/// (SwiftMath builds a full display list every time), and the same
/// equation often appears in both a user prompt and the assistant's
/// reply, so a modest per-process cache pays off.
private final class InlineMathImageCache: @unchecked Sendable {
    static let shared = InlineMathImageCache()

    struct Rendered {
        #if os(macOS)
        let image: NSImage
        #else
        let image: UIImage
        #endif
        let ascent: CGFloat
        let descent: CGFloat
    }

    private final class Box {
        let rendered: Rendered
        init(_ rendered: Rendered) { self.rendered = rendered }
    }

    private let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 512
        return cache
    }()

    func rendered(for latex: String, fontSize: CGFloat) -> Rendered? {
        let key = "\(Int(fontSize * 100))|\(latex)" as NSString
        if let hit = cache.object(forKey: key) {
            return hit.rendered
        }

        // Render in the platform's label color. The image is then flagged
        // as a template, so SwiftUI re-tints with the current foreground
        // and this baseline color never actually shows through in-app.
        // (It only matters for antialiasing.)
        #if os(macOS)
        let baselineColor: NSColor = .labelColor
        #else
        let baselineColor: UIColor = .label
        #endif

        var mathImage = MathImage(
            latex: latex,
            fontSize: fontSize,
            textColor: baselineColor,
            labelMode: .text,
            textAlignment: .left
        )
        let (error, image, layoutInfo) = mathImage.asImage()
        guard error == nil, let image, let layoutInfo else {
            return nil
        }

        #if os(macOS)
        image.isTemplate = true
        let rendered = Rendered(
            image: image,
            ascent: layoutInfo.ascent,
            descent: layoutInfo.descent
        )
        #else
        let rendered = Rendered(
            image: image.withRenderingMode(.alwaysTemplate),
            ascent: layoutInfo.ascent,
            descent: layoutInfo.descent
        )
        #endif
        cache.setObject(Box(rendered), forKey: key)
        return rendered
    }
}

// MARK: - Table alignment

/// Per-column alignment for a pipe-table, inferred from the separator
/// row (`| :--- | :---: | ---: |` → leading / center / trailing).
enum TableAlignment {
    case leading
    case center
    case trailing

    var textAlignment: TextAlignment {
        switch self {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }

    var frameAlignment: Alignment {
        switch self {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }
}

// MARK: - ContentBlock model

/// Structured representation of a parsed message body. Rich enough to
/// recover the source's headings, lists, code, math, and blockquotes
/// for faithful rendering — plain markdown-to-Text isn't enough on its
/// own because SwiftUI's built-in markdown parser stops at inline spans.
enum ContentBlock {
    case paragraph(String)
    case heading(level: Int, text: String)
    /// A single list entry. We emit one per line; consecutive items form
    /// a visual list because they're rendered back-to-back. `marker` is
    /// what to draw in the gutter (e.g. "•", "1.", "2."), `depth` is the
    /// indent level (0 = flush, 1 = nested once, …).
    case listItem(ordered: Bool, depth: Int, text: String, marker: String)
    case blockquote(String)
    case code(language: String?, code: String)
    /// Display-math block: source captured verbatim. Rendering is a
    /// monospaced box with a "LaTeX" badge rather than actual
    /// typesetting — proper MathJax/KaTeX would need a WebView per
    /// message, which is too heavy for scrollback.
    case math(String)
    /// Pipe-table (`| a | b |` + `|---|---|` separator + body rows).
    /// Previously tables surfaced as mangled paragraphs full of literal
    /// `|` characters — assistant responses that included comparison
    /// tables became unreadable. Headers + rows are pre-split so the
    /// renderer can lay them out as a grid. `alignments` is per column,
    /// parsed from the separator row's `:` markers (`:---` = leading,
    /// `:---:` = center, `---:` = trailing).
    case table(headers: [String], rows: [[String]], alignments: [TableAlignment])
    case horizontalRule

    // MARK: - Parser

    static func parse(_ content: String) -> [ContentBlock] {
        var parser = Parser()
        for line in content.components(separatedBy: "\n") {
            parser.feed(line)
        }
        parser.finish()
        return parser.blocks
    }

    /// Line-oriented state machine. Each line is either inside a fenced
    /// code block, inside a display-math block, or a standalone markdown
    /// line. We flush pending paragraph buffers whenever we switch modes
    /// so the emitted blocks stay in document order.
    private struct Parser {
        var blocks: [ContentBlock] = []
        private var paragraphLines: [String] = []
        private var codeLines: [String] = []
        private var codeLanguage: String?
        /// Which fence character opened the current code block — `` ` ``
        /// or `~`. Closing must match. Previously the parser only knew
        /// about triple-backticks, so `~~~`-fenced blocks (common from
        /// Claude and pandoc-style imports) passed through as garbled
        /// paragraph text.
        private var codeFenceChar: Character = "`"
        /// Leading-space count stripped off the opening fence. Used to
        /// re-align indented fences inside list items so the body text
        /// doesn't arrive with that same indent baked into every line.
        private var codeFenceIndent: Int = 0
        private var mathLines: [String] = []
        /// Buffer for consecutive blockquote lines so they render as one
        /// visual quote. Previously every `>` line emitted its own block
        /// and the renderer drew one gutter bar per line, chopping a
        /// multi-line quote into a visually fragmented stack.
        private var blockquoteLines: [String] = []
        /// Buffer for pipe-table rows. `pending[0]` is the header, the
        /// next line must be a separator row (`|---|---|`) for the
        /// buffer to commit as a table; otherwise it flushes back into
        /// the paragraph stream.
        private var pendingTableLines: [String] = []
        private enum Mode { case text, code, math, indentedCode }
        private var mode: Mode = .text
        /// Body of an indented-code block (≥4 leading spaces, no fence).
        /// Only enters when a blank line precedes — mid-paragraph indent
        /// is still treated as a soft line break so wrapped paragraphs
        /// don't suddenly become code.
        private var indentedCodeLines: [String] = []

        mutating func feed(_ line: String) {
            switch mode {
            case .code:
                // A fence closes only when the trimmed line is (≥3) of
                // the opening fence character with nothing else — this
                // is what CommonMark requires and avoids a stray `` `` ``
                // or `~~~` inside an English paragraph accidentally
                // closing a code block.
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if Self.isClosingFence(trimmed, fenceChar: codeFenceChar) {
                    blocks.append(.code(
                        language: codeLanguage,
                        code: codeLines.joined(separator: "\n")
                    ))
                    codeLines.removeAll()
                    codeLanguage = nil
                    codeFenceIndent = 0
                    mode = .text
                } else {
                    // Strip the opener's own indent off each body line so
                    // a fence inside a list item renders flush.
                    codeLines.append(Self.stripLeadingSpaces(line, upTo: codeFenceIndent))
                }

            case .indentedCode:
                if line.trimmingCharacters(in: .whitespaces).isEmpty {
                    // Blank line: keep it so the code block preserves
                    // internal paragraph breaks, but don't commit yet —
                    // might be the end of the block.
                    indentedCodeLines.append("")
                } else if line.hasPrefix("    ") || line.hasPrefix("\t") {
                    let stripped = line.hasPrefix("\t")
                        ? String(line.dropFirst())
                        : String(line.dropFirst(4))
                    indentedCodeLines.append(stripped)
                } else {
                    flushIndentedCode()
                    mode = .text
                    // Re-feed the non-indented line through text mode so
                    // it gets its normal treatment (list, heading, etc.).
                    feed(line)
                }

            case .math:
                if line.trimmingCharacters(in: .whitespaces) == "$$"
                    || line.trimmingCharacters(in: .whitespaces) == "\\]" {
                    blocks.append(.math(mathLines.joined(separator: "\n")))
                    mathLines.removeAll()
                    mode = .text
                } else {
                    mathLines.append(line)
                }

            case .text:
                let trimmed = line.trimmingCharacters(in: .whitespaces)

                // Fenced code block open — either `` ``` `` or `~~~` (both
                // CommonMark-valid). Record which opener so the closing
                // fence has to match the same character.
                if let fence = Self.parseFenceOpen(trimmed) {
                    flushParagraph()
                    flushBlockquote()
                    flushPendingTable()
                    codeLanguage = fence.language
                    codeFenceChar = fence.character
                    codeFenceIndent = Self.leadingSpaceCount(line)
                    mode = .code
                    return
                }

                // Display math open (`$$` alone, or `\[` alone on a line)
                if trimmed == "$$" || trimmed == "\\[" {
                    flushParagraph()
                    flushBlockquote()
                    flushPendingTable()
                    mode = .math
                    return
                }

                // Inline display math on a single line: `$$ foo $$` → one-line math block.
                if trimmed.hasPrefix("$$") && trimmed.hasSuffix("$$") && trimmed.count >= 4 {
                    flushParagraph()
                    flushBlockquote()
                    flushPendingTable()
                    let inner = String(trimmed.dropFirst(2).dropLast(2))
                        .trimmingCharacters(in: .whitespaces)
                    blocks.append(.math(inner))
                    return
                }

                // Horizontal rule
                if Self.isHorizontalRule(trimmed) {
                    flushParagraph()
                    flushBlockquote()
                    flushPendingTable()
                    blocks.append(.horizontalRule)
                    return
                }

                // ATX heading (1–6 `#`s then a space)
                if let heading = Self.parseHeading(trimmed) {
                    flushParagraph()
                    flushBlockquote()
                    flushPendingTable()
                    blocks.append(.heading(level: heading.level, text: heading.text))
                    return
                }

                // Blockquote (`>` prefix). Consecutive `>` lines buffer
                // into one `.blockquote` block so the gutter bar spans
                // the full quote instead of re-drawing per line.
                if trimmed.hasPrefix(">") {
                    flushParagraph()
                    flushPendingTable()
                    let body = trimmed.drop(while: { $0 == ">" || $0 == " " })
                    blockquoteLines.append(String(body))
                    return
                } else {
                    flushBlockquote()
                }

                // Pipe table detection. A candidate header row starts &
                // ends with `|`; if the very next line is a separator
                // (`| --- | :---: | ---: |`), we commit the buffered
                // lines as a `.table`. Until the separator arrives, the
                // header line sits in `pendingTableLines`.
                if Self.looksLikeTableRow(trimmed) {
                    if pendingTableLines.count == 1,
                       let alignments = Self.parseTableSeparator(trimmed) {
                        // Header + separator confirmed. Switch over to
                        // consuming body rows.
                        let header = pendingTableLines[0]
                        pendingTableLines.removeAll()
                        commitTableStart(header: header, alignments: alignments)
                        return
                    }
                    if !tableHeader.isEmpty {
                        tableRows.append(Self.splitTableRow(trimmed))
                        return
                    }
                    pendingTableLines.append(trimmed)
                    return
                } else if !tableHeader.isEmpty {
                    // Header was committed but the current line isn't a
                    // body row — emit the (possibly empty-bodied) table
                    // now so we don't leave it dangling. A header-only
                    // table still reads correctly; losing the whole
                    // block would silently drop content.
                    flushTable()
                } else if !pendingTableLines.isEmpty {
                    // Buffered line turned out not to be a table — push
                    // it back into the paragraph stream so nothing is
                    // lost.
                    paragraphLines.append(contentsOf: pendingTableLines)
                    pendingTableLines.removeAll()
                }

                // List item — unordered (-, *, +) or ordered (1. 2. 3.)
                if let listItem = Self.parseListItem(rawLine: line) {
                    flushParagraph()
                    blocks.append(listItem)
                    return
                }

                // Indented-code block (4-space / tab prefix). Only enters
                // when we're between paragraphs — otherwise a wrapped
                // continuation line that happens to be indented would
                // mis-trigger.
                if paragraphLines.isEmpty,
                   blockquoteLines.isEmpty,
                   (line.hasPrefix("    ") || line.hasPrefix("\t")) {
                    let stripped = line.hasPrefix("\t")
                        ? String(line.dropFirst())
                        : String(line.dropFirst(4))
                    indentedCodeLines.append(stripped)
                    mode = .indentedCode
                    return
                }

                // Blank line terminates the current paragraph.
                if trimmed.isEmpty {
                    flushParagraph()
                    return
                }

                paragraphLines.append(line)
            }
        }

        mutating func finish() {
            switch mode {
            case .code:
                // Unterminated fence: emit what we have so nothing gets lost.
                blocks.append(.code(language: codeLanguage, code: codeLines.joined(separator: "\n")))
                codeLines.removeAll()
                codeLanguage = nil
            case .indentedCode:
                flushIndentedCode()
            case .math:
                blocks.append(.math(mathLines.joined(separator: "\n")))
                mathLines.removeAll()
            case .text:
                break
            }
            flushBlockquote()
            if !tableHeader.isEmpty {
                flushTable()
            } else if !pendingTableLines.isEmpty {
                paragraphLines.append(contentsOf: pendingTableLines)
                pendingTableLines.removeAll()
            }
            flushParagraph()
            mode = .text
        }

        // MARK: - Table buffering

        /// Header row of the in-progress table, pre-split into cells.
        private var tableHeader: [String] = []
        /// Column alignments captured from the separator row.
        private var tableAlignments: [TableAlignment] = []
        /// Body rows of the in-progress table, each pre-split into cells.
        private var tableRows: [[String]] = []

        private mutating func commitTableStart(header: String, alignments: [TableAlignment]) {
            tableHeader = Self.splitTableRow(header)
            tableAlignments = alignments
            tableRows = []
        }

        private mutating func flushTable() {
            guard !tableHeader.isEmpty else {
                tableHeader = []
                tableAlignments = []
                tableRows = []
                return
            }
            // Normalize column count: some authors drop trailing cells
            // on short rows. Pad with empty strings so the grid stays
            // rectangular.
            let columnCount = tableHeader.count
            let paddedRows = tableRows.map { row -> [String] in
                if row.count >= columnCount {
                    return Array(row.prefix(columnCount))
                }
                return row + Array(repeating: "", count: columnCount - row.count)
            }
            let paddedAlignments: [TableAlignment] = {
                if tableAlignments.count >= columnCount {
                    return Array(tableAlignments.prefix(columnCount))
                }
                return tableAlignments + Array(
                    repeating: TableAlignment.leading,
                    count: columnCount - tableAlignments.count
                )
            }()
            blocks.append(.table(
                headers: tableHeader,
                rows: paddedRows,
                alignments: paddedAlignments
            ))
            tableHeader = []
            tableAlignments = []
            tableRows = []
        }

        private mutating func flushPendingTable() {
            if !tableRows.isEmpty || !tableHeader.isEmpty {
                flushTable()
            } else if !pendingTableLines.isEmpty {
                paragraphLines.append(contentsOf: pendingTableLines)
                pendingTableLines.removeAll()
            }
        }

        private mutating func flushBlockquote() {
            guard !blockquoteLines.isEmpty else { return }
            blocks.append(.blockquote(blockquoteLines.joined(separator: "\n")))
            blockquoteLines.removeAll()
        }

        private mutating func flushIndentedCode() {
            // Drop trailing blank lines inside the indented-code buffer —
            // they're almost always the separator after the block.
            while indentedCodeLines.last?.isEmpty == true {
                indentedCodeLines.removeLast()
            }
            let body = indentedCodeLines.joined(separator: "\n")
            if !body.isEmpty {
                blocks.append(.code(language: nil, code: body))
            }
            indentedCodeLines.removeAll()
        }

        private mutating func flushParagraph() {
            let joined = paragraphLines
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty {
                blocks.append(.paragraph(joined))
            }
            paragraphLines.removeAll()
        }

        // MARK: - Line classifiers

        private static func isHorizontalRule(_ trimmed: String) -> Bool {
            guard trimmed.count >= 3 else { return false }
            // `---`, `***`, `___` (with optional interleaved spaces).
            let stripped = trimmed.filter { !$0.isWhitespace }
            guard let first = stripped.first, "-*_".contains(first) else { return false }
            return stripped.allSatisfy { $0 == first } && stripped.count >= 3
        }

        private static func parseHeading(_ trimmed: String) -> (level: Int, text: String)? {
            var hashCount = 0
            for ch in trimmed {
                if ch == "#" { hashCount += 1 } else { break }
                if hashCount > 6 { return nil }
            }
            guard (1...6).contains(hashCount) else { return nil }
            let afterHashes = trimmed.index(trimmed.startIndex, offsetBy: hashCount)
            guard afterHashes < trimmed.endIndex,
                  trimmed[afterHashes] == " " else { return nil }
            let body = trimmed[trimmed.index(after: afterHashes)...]
                .trimmingCharacters(in: .whitespaces)
            return (hashCount, body)
        }

        /// Parse a potential list-item line. Returns `nil` if the line
        /// isn't a list item. We read indent width off the raw line
        /// (spaces before the marker) to infer nesting depth — every
        /// two leading spaces is one level, matching CommonMark's usual
        /// rendering.
        private static func parseListItem(rawLine: String) -> ContentBlock? {
            var leadingSpaces = 0
            for ch in rawLine {
                if ch == " " { leadingSpaces += 1 } else { break }
            }
            let stripped = rawLine.dropFirst(leadingSpaces)

            // Unordered: "- x", "* x", "+ x"
            if let first = stripped.first, "-*+".contains(first),
               stripped.dropFirst().first == " " {
                let body = stripped.dropFirst(2).trimmingCharacters(in: .whitespaces)
                return .listItem(
                    ordered: false,
                    depth: leadingSpaces / 2,
                    text: String(body),
                    marker: "•"
                )
            }

            // Ordered: "1. x", "12. x"
            var digitCount = 0
            for ch in stripped {
                if ch.isNumber { digitCount += 1 } else { break }
            }
            guard digitCount > 0 else { return nil }
            let afterDigits = stripped.index(stripped.startIndex, offsetBy: digitCount)
            guard afterDigits < stripped.endIndex,
                  stripped[afterDigits] == ".",
                  stripped.index(after: afterDigits) < stripped.endIndex,
                  stripped[stripped.index(after: afterDigits)] == " " else { return nil }

            let number = String(stripped.prefix(digitCount))
            let body = stripped[stripped.index(afterDigits, offsetBy: 2)...]
                .trimmingCharacters(in: .whitespaces)
            return .listItem(
                ordered: true,
                depth: leadingSpaces / 2,
                text: String(body),
                marker: "\(number)."
            )
        }

        // MARK: - Fence helpers

        /// Recognize a code-fence opener. Accepts `` ``` `` and `~~~` with
        /// optional language tag (`` ```swift ``, `~~~python`). Returns
        /// the fence character + optional language, or `nil` if the line
        /// isn't a fence open.
        private static func parseFenceOpen(_ trimmed: String) -> (character: Character, language: String?)? {
            guard let first = trimmed.first, first == "`" || first == "~" else { return nil }
            // Count the opening run of the fence character.
            var runLength = 0
            for ch in trimmed {
                if ch == first { runLength += 1 } else { break }
            }
            guard runLength >= 3 else { return nil }
            // If the whole line is just the fence character, treat as
            // open (empty language). Closing-fence-as-open is disambiguated
            // by `mode` at the call site.
            let afterFence = trimmed.dropFirst(runLength).trimmingCharacters(in: .whitespaces)
            // Backtick fences can't contain backticks in their info
            // string per CommonMark — if the tail has one, bail.
            if first == "`" && afterFence.contains("`") { return nil }
            return (first, afterFence.isEmpty ? nil : String(afterFence))
        }

        /// True if a trimmed line is a valid closing fence for a block
        /// opened with `fenceChar` — i.e. ≥3 of the same character with
        /// nothing else on the line.
        private static func isClosingFence(_ trimmed: String, fenceChar: Character) -> Bool {
            guard trimmed.count >= 3 else { return false }
            return trimmed.allSatisfy { $0 == fenceChar }
        }

        /// Count leading ASCII spaces on a raw line.
        private static func leadingSpaceCount(_ line: String) -> Int {
            var n = 0
            for ch in line {
                if ch == " " { n += 1 } else { break }
            }
            return n
        }

        /// Drop up to `upTo` leading spaces from a line. Preserves any
        /// indentation beyond that (so nested code inside a list item
        /// keeps its own internal structure).
        private static func stripLeadingSpaces(_ line: String, upTo: Int) -> String {
            guard upTo > 0 else { return line }
            var remaining = upTo
            var index = line.startIndex
            while index < line.endIndex, remaining > 0, line[index] == " " {
                index = line.index(after: index)
                remaining -= 1
            }
            return String(line[index...])
        }

        // MARK: - Table helpers

        /// Heuristic: a table row starts & ends with `|` and has at
        /// least one interior `|` (i.e. two+ cells). Lines like `|` or
        /// `||` that don't actually carry cell content fail this check
        /// and fall back to paragraph.
        private static func looksLikeTableRow(_ trimmed: String) -> Bool {
            guard trimmed.hasPrefix("|"), trimmed.hasSuffix("|"), trimmed.count >= 3 else {
                return false
            }
            // Strip the outer bars, then require at least one internal
            // separator after removing escaped bars.
            let inner = String(trimmed.dropFirst().dropLast())
            return inner.contains("|")
        }

        /// Parse a table separator row (`|---|:---:|---:|`) into per-
        /// column alignments. Returns `nil` if the row isn't a valid
        /// separator — that's the signal to the caller that the
        /// preceding buffered line was NOT a table header.
        private static func parseTableSeparator(_ trimmed: String) -> [TableAlignment]? {
            let cells = splitTableRow(trimmed)
            guard !cells.isEmpty else { return nil }
            var alignments: [TableAlignment] = []
            for cell in cells {
                let c = cell.trimmingCharacters(in: .whitespaces)
                guard c.count >= 3 else { return nil }
                let hasLeadingColon = c.hasPrefix(":")
                let hasTrailingColon = c.hasSuffix(":")
                let dashBody = c.drop(while: { $0 == ":" })
                    .reversed().drop(while: { $0 == ":" }).reversed()
                // The body between the colons must be all dashes, and
                // there must be at least one.
                guard !dashBody.isEmpty, dashBody.allSatisfy({ $0 == "-" }) else {
                    return nil
                }
                switch (hasLeadingColon, hasTrailingColon) {
                case (true, true): alignments.append(.center)
                case (false, true): alignments.append(.trailing)
                case (true, false): alignments.append(.leading)
                case (false, false): alignments.append(.leading)
                }
            }
            return alignments
        }

        /// Split a pipe-table row into cells. Strips the outer bars and
        /// trims each cell's whitespace.
        private static func splitTableRow(_ trimmed: String) -> [String] {
            var line = trimmed
            if line.hasPrefix("|") { line.removeFirst() }
            if line.hasSuffix("|") { line.removeLast() }
            return line.split(separator: "|", omittingEmptySubsequences: false).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
        }
    }
}

// MARK: - Block views

private struct CodeBlockView: View {
    let language: String?
    let code: String
    let fontSize: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row: language label on the left (if any), copy button
            // on the right. Always rendered so the copy affordance stays
            // at a predictable position even for untagged fences.
            HStack(spacing: 8) {
                if let language, !language.isEmpty {
                    Text(language)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                CopyButton(text: code, helpText: "Copy code")
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)
            .padding(.bottom, 4)

            ScrollView(.horizontal, showsIndicators: true) {
                Text(code)
                    .font(.system(size: fontSize, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PlatformColors.textBackground.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.gray.opacity(0.2), lineWidth: 1)
        )
    }
}

/// Pipe-table renderer. Previously tables fell through the parser and
/// surfaced as paragraphs full of literal `|` characters — assistant
/// responses that used tables to compare options were unreadable. This
/// view draws an actual grid with a header row, per-column alignment
/// from the separator row, and subtle hairline dividers.
///
/// Inline markdown inside cells (bold, inline code, links) is routed
/// through the same `renderInline` closure the paragraph path uses, so
/// `**name**` inside a cell stays bold.
private struct TableBlockView: View {
    let headers: [String]
    let rows: [[String]]
    let alignments: [TableAlignment]
    let fontSize: CGFloat
    let renderInline: (String) -> Text

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 0) {
                headerRow
                Divider()
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    if index > 0 {
                        Divider().opacity(0.3)
                    }
                    bodyRow(row)
                }
            }
            .padding(.vertical, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PlatformColors.textBackground.opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.gray.opacity(0.2), lineWidth: 1)
        )
    }

    private var headerRow: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(headers.enumerated()), id: \.offset) { index, cell in
                cellText(cell, alignment: alignment(at: index))
                    .font(.system(size: fontSize, weight: .semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(minWidth: 80, alignment: alignment(at: index).frameAlignment)
                if index < headers.count - 1 {
                    Rectangle()
                        .fill(Color.gray.opacity(0.2))
                        .frame(width: 1)
                }
            }
        }
    }

    private func bodyRow(_ row: [String]) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(row.enumerated()), id: \.offset) { index, cell in
                cellText(cell, alignment: alignment(at: index))
                    .font(.system(size: fontSize))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(minWidth: 80, alignment: alignment(at: index).frameAlignment)
                if index < row.count - 1 {
                    Rectangle()
                        .fill(Color.gray.opacity(0.15))
                        .frame(width: 1)
                }
            }
        }
    }

    private func cellText(_ text: String, alignment: TableAlignment) -> some View {
        renderInline(text)
            .multilineTextAlignment(alignment.textAlignment)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func alignment(at index: Int) -> TableAlignment {
        guard index < alignments.count else { return .leading }
        return alignments[index]
    }
}

/// Display-math block. Previously this showed the LaTeX source as
/// italic serif text inside a styled container — readable but not
/// typeset, so fractions, exponents, and sum/product operators all
/// collapsed to a single line of raw `\frac{...}` / `^{...}` source.
///
/// The renderer is now `SwiftMath` (native Swift port of iosMath) which
/// lays out proper math via CoreText — no WebView, no JavaScript
/// runtime. `MTMathUILabel` ships as an `NSView` (typealiased from
/// `MTView`) so we wrap it in an `NSViewRepresentable` that reports
/// its `intrinsicContentSize` back up to SwiftUI.
///
/// If the source fails to parse (unsupported macros, `\cite{…}` from
/// model tool-use artifacts, etc.) we fall back to the old source
/// view so the original text is still recoverable. Parse is done once
/// in `init` via `MTMathListBuilder` so we can decide between the two
/// subviews without creating a failed label first.
private struct MathBlockView: View {
    let source: String
    let fontSize: CGFloat

    /// Non-nil when `source` parses as LaTeX math. Cached on init so
    /// the body doesn't re-run the parser on every redraw.
    private let canTypeset: Bool

    init(source: String, fontSize: CGFloat) {
        self.source = source
        self.fontSize = fontSize
        var error: NSError?
        _ = MTMathListBuilder.build(fromString: source, error: &error)
        self.canTypeset = (error == nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("LaTeX")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 0)

                CopyButton(text: source, helpText: "Copy LaTeX source")
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)
            .padding(.bottom, 4)

            if canTypeset {
                // Horizontal scroll as a safety net: a wide matrix /
                // long equation that still overflows the column
                // shouldn't clip. The label reports its own intrinsic
                // size, so short equations just sit at their natural
                // width without scrolling.
                ScrollView(.horizontal, showsIndicators: false) {
                    MathLabelView(
                        latex: source,
                        fontSize: fontSize * 1.15
                    )
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
                }
            } else {
                // Parse failed — preserve the source verbatim in a
                // monospaced source-code style so the user can still
                // read / copy it. Wrap instead of horizontal scroll
                // because raw source is paragraph-shaped.
                Text(source)
                    .font(.system(size: fontSize, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.indigo.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.indigo.opacity(0.25), lineWidth: 1)
        )
    }
}

/// NSViewRepresentable / UIViewRepresentable wrapper around SwiftMath's
/// `MTMathUILabel`. Kept intentionally small — SwiftMath already does
/// all the layout, we just ferry the latex / fontSize / current text
/// color through and let the label report its intrinsic size.
///
/// Why a representable instead of painting to an NSImage via
/// `MTMathImage`: the label honors Dynamic Type-style font scaling and
/// participates in the hosting view's layer hierarchy for free, so
/// copy-selection and live redraw on appearance changes (light ↔ dark)
/// work without extra plumbing. The image path would require us to
/// re-render on every color-scheme change by hand.
private struct MathLabelView: PlatformViewRepresentable {
    let latex: String
    let fontSize: CGFloat

    #if os(macOS)
    func makeNSView(context: Context) -> MTMathUILabel {
        makeLabel(context: context)
    }
    func updateNSView(_ nsView: MTMathUILabel, context: Context) {
        applyState(to: nsView, context: context)
    }
    // SwiftUI pulls the proposed size from here. Critical on macOS:
    // SwiftMath's `MTMathUILabel` only overrides
    // `intrinsicContentSize` on iOS (see `MTMathUILabel.swift`, the
    // override lives inside `#else` for UIKit). On macOS that property
    // falls back to NSView's default `noIntrinsicMetric` sentinel
    // (-1, -1), and SwiftUI collapses the label to near-zero height —
    // which is exactly the "数式が見切れる" (equation is clipped)
    // bug. The macOS counterpart SwiftMath DOES override is
    // `fittingSize`, which internally runs `_sizeThatFits(.zero)` and
    // computes (displayList.width, ascent + descent) from a freshly
    // typeset math list. Reading that gives SwiftUI a correct height
    // so the ScrollView lays the label out at its real typeset size
    // and nothing clips.
    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: MTMathUILabel,
        context: Context
    ) -> CGSize? {
        nsView.needsLayout = true
        return nsView.fittingSize
    }
    #else
    func makeUIView(context: Context) -> MTMathUILabel {
        makeLabel(context: context)
    }
    func updateUIView(_ uiView: MTMathUILabel, context: Context) {
        applyState(to: uiView, context: context)
    }
    // iOS path: `intrinsicContentSize` IS overridden by SwiftMath
    // here (the `#else` branch in MTMathUILabel.swift), so this
    // route works as expected.
    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: MTMathUILabel,
        context: Context
    ) -> CGSize? {
        uiView.invalidateIntrinsicContentSize()
        return uiView.intrinsicContentSize
    }
    #endif

    private func makeLabel(context: Context) -> MTMathUILabel {
        let label = MTMathUILabel()
        // Display mode = full-size fractions / limits / etc. (as in
        // `$$...$$`). Inline-math text mode would render \frac as a
        // smaller in-line style, which is wrong for a block equation.
        label.labelMode = .display
        label.textAlignment = .left
        label.displayErrorInline = false
        // Let the label grow to whatever its content needs rather than
        // being squeezed to the SwiftUI container's proposed width.
        // Without this the label's contentMode flattens tall equations
        // (fractions with exponents) into an intrinsic height that
        // doesn't account for the actual typeset box.
        label.contentInsets = .init(top: 0, left: 0, bottom: 0, right: 0)
        applyState(to: label, context: context)
        return label
    }

    private func applyState(to label: MTMathUILabel, context: Context) {
        label.latex = latex
        label.fontSize = fontSize
        // Follow the environment's foreground color so the math adapts
        // to light / dark mode alongside the surrounding prose. SwiftMath
        // uses platform-native color types (NSColor / UIColor) via the
        // `MTColor` typealias.
        #if os(macOS)
        label.textColor = NSColor.labelColor
        #else
        label.textColor = UIColor.label
        #endif
        label.invalidateIntrinsicContentSize()
    }
}

#if os(macOS)
private typealias PlatformViewRepresentable = NSViewRepresentable
#else
private typealias PlatformViewRepresentable = UIViewRepresentable
#endif

/// Small "Copy"-with-feedback button used by both `CodeBlockView` and
/// `MathBlockView`. The view flips to a green checkmark for ~1.5 s after
/// a successful copy so the user gets clear confirmation without a
/// global toast — important in long conversations where several code
/// blocks might be copied in quick succession.
private struct CopyButton: View {
    let text: String
    let helpText: String

    @State private var didJustCopy = false
    @State private var resetTask: Task<Void, Never>?

    var body: some View {
        Button(action: copy) {
            HStack(spacing: 4) {
                Image(systemName: didJustCopy ? "checkmark" : "doc.on.doc")
                Text(didJustCopy ? "Copied" : "Copy")
            }
            .font(.caption2.weight(.medium))
            .foregroundStyle(didJustCopy ? Color.green : Color.secondary)
            // Enlarge the hit target so the 11pt label doesn't turn into
            // a needle-thin click target on macOS.
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(helpText)
        .onDisappear {
            resetTask?.cancel()
        }
    }

    private func copy() {
        Clipboard.set(text)
        didJustCopy = true
        resetTask?.cancel()
        resetTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            didJustCopy = false
        }
    }
}

/// Thin cross-platform wrapper around the system pasteboard. Kept
/// private to this file because the only callers today are the two
/// block-view copy buttons — if we grow more surfaces that need
/// clipboard access, this can graduate to a top-level utility.
private enum Clipboard {
    static func set(_ string: String) {
        #if os(macOS)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
        #else
        UIPasteboard.general.string = string
        #endif
    }
}

/// Process-level memoization of inline-markdown parses.
///
/// `AttributedString(markdown:)` is pure w.r.t. its input, so we can cache on
/// the source string. Capacity is bounded by `NSCache`'s automatic eviction
/// (default: responds to memory pressure). `AttributedString` is a value type
/// but we box it in a `final class` so `NSCache`'s NSObject keying is happy.
private final class InlineMarkdownCache: @unchecked Sendable {
    static let shared = InlineMarkdownCache()

    private final class Box {
        let value: AttributedString
        init(_ value: AttributedString) { self.value = value }
    }

    private let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        // Bound entries so the cache can't grow unboundedly on very long
        // sessions; individual renders are small so this is generous.
        cache.countLimit = 2048
        return cache
    }()

    private static let options = AttributedString.MarkdownParsingOptions(
        interpretedSyntax: .inlineOnlyPreservingWhitespace
    )

    func render(_ text: String) -> AttributedString {
        // Fast path: if the text carries no markdown sigils at all,
        // `AttributedString(markdown:)` would just return the same
        // characters wrapped in an attributed container. The parse is
        // surprisingly expensive (it always builds a CommonMark tree
        // even for pure text), so skipping it is a big win for the
        // common "plain Japanese prose, no emphasis" paragraph — which
        // is most of what users actually read.
        if !Self.containsInlineMarkdownSigils(text) {
            return AttributedString(text)
        }
        // Skip the cache for very short strings — constructing NSString keys
        // and NSCache lookups has its own cost and "ok" / "thanks" paragraphs
        // parse in microseconds anyway.
        guard text.count > 16 else {
            return (try? AttributedString(markdown: text, options: Self.options)) ?? AttributedString(text)
        }
        let key = text as NSString
        if let hit = cache.object(forKey: key) {
            return hit.value
        }
        let parsed = (try? AttributedString(markdown: text, options: Self.options)) ?? AttributedString(text)
        cache.setObject(Box(parsed), forKey: key)
        return parsed
    }

    /// Bytes that could trigger any inline-markdown construct that
    /// `.inlineOnlyPreservingWhitespace` honors: emphasis (`*`, `_`),
    /// code spans (`` ` ``), links (`[`, `]`, `(`, `)`, `<`, `>`),
    /// images (`!`), escapes (`\`), and strikethrough (`~`). All of
    /// these are single-byte ASCII in UTF-8, so we can sweep raw bytes
    /// instead of iterating `Character`s — the latter goes through
    /// grapheme-cluster segmentation, which adds up fast on long
    /// Japanese paragraphs where every "character" is a multi-byte
    /// cluster. Byte scan is pure ASCII switch and a few hundred
    /// kilobytes of prose run through it in microseconds.
    private static func containsInlineMarkdownSigils(_ text: String) -> Bool {
        for byte in text.utf8 {
            switch byte {
            case 0x2A,  // *
                 0x5F,  // _
                 0x60,  // `
                 0x5B,  // [
                 0x5D,  // ]
                 0x28,  // (
                 0x29,  // )
                 0x3C,  // <
                 0x3E,  // >
                 0x21,  // !
                 0x5C,  // \
                 0x7E:  // ~
                return true
            default:
                continue
            }
        }
        return false
    }
}

private enum PlatformColors {
    #if os(macOS)
    static let controlBackground = Color(nsColor: .controlBackgroundColor)
    static let textBackground = Color(nsColor: .textBackgroundColor)
    #else
    static let controlBackground = Color(uiColor: .secondarySystemBackground)
    static let textBackground = Color(uiColor: .systemBackground)
    #endif
}
