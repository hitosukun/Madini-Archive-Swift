import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import NaturalLanguage
import SwiftMath

/// Describes an in-thread search that bubbles should paint keyword-level
/// highlights for. Threaded through the view tree via
/// `EnvironmentValues.searchHighlight` so every `MessageBubbleView` can
/// react independently — no need to plumb a Set of IDs through the
/// `ConversationDetailView` init.
///
/// Semantics:
/// - `query` empty / whitespace → no highlight (cheap no-op path).
/// - `activeAnchorID` matches the current block's anchor +
///   `activeOccurrenceInBlock == N` → the Nth (0-indexed) occurrence
///   inside that specific rendered block is the single "you are here"
///   hit and gets the hot color; every other occurrence (in this
///   block, in other blocks of this message, or across the thread)
///   stays in the dim "also hit" color.
/// - `activeAnchorID` matches the current block with
///   `activeOccurrenceInBlock == nil` → every occurrence in this block
///   gets the hot color (block-level cursor). Retained so non-per-
///   occurrence callers keep working.
///
/// The anchor id is threaded EXPLICITLY down `MessageBubbleView`'s
/// render chain (`renderItem` → `renderBlock` → per-block helpers →
/// `applyingSearchHighlight`) as a `blockAnchorID` parameter. For user
/// messages it's the message id; for rendered assistant replies it's
/// the per-render-item block anchor id produced by
/// `searchBlockAnchorID(messageID:blockIndex:)`. Earlier iterations
/// tried to deliver this via `@Environment`, but `@Environment` on a
/// view reads from the PARENT scope — writing
/// `.environment(\.currentSearchBlockAnchor, …)` inside the view's own
/// body never flowed back to `self`'s env read, so the hot cursor was
/// silently painted with `nil` and never showed up. This granularity
/// is what keeps the "hot" highlight on the *one* match the find bar's
/// N/M cursor points at in a long assistant reply with many matches.
struct SearchHighlightSpec: Equatable {
    var query: String
    /// Anchor id (user message id OR assistant block anchor id) that
    /// contains the active match. `nil` → no block is hot.
    var activeAnchorID: String?
    /// Which occurrence inside the active block is the current jump
    /// target. 0-indexed against a case-insensitive left-to-right scan
    /// of that block's rendered text (the same scan
    /// `applyingSearchHighlight` uses). `nil` falls back to block-level
    /// highlight so older call sites keep working.
    var activeOccurrenceInBlock: Int?

    var normalizedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isEmpty: Bool { normalizedQuery.isEmpty }
}

private struct SearchHighlightKey: EnvironmentKey {
    static let defaultValue: SearchHighlightSpec? = nil
}

extension EnvironmentValues {
    var searchHighlight: SearchHighlightSpec? {
        get { self[SearchHighlightKey.self] }
        set { self[SearchHighlightKey.self] = newValue }
    }
}

/// Phase 4 env-delivered hook so user-authored message bubbles can
/// expose a pin toggle without `MessageBubbleView` needing to know
/// which conversation owns them or which repository/store backs the
/// bookmark state. The host (`ConversationDetailView`'s caller, or
/// the DesignMock shell) captures the conversation id inside the
/// closures and seeds `isPinned` from an observable set so the
/// bubble re-renders the moment the pin flips.
struct PromptBookmarkBridge {
    /// `true` when the given message id is currently pinned. Cheap —
    /// implementations back this with a `Set<String>` lookup.
    var isPinned: (_ promptID: String) -> Bool
    /// Toggle the pin for the given message id. `snippet` is a short
    /// excerpt the sidebar list uses to render the row without
    /// re-fetching the message body.
    var toggle: (_ promptID: String, _ snippet: String) -> Void
}

private struct PromptBookmarkBridgeKey: EnvironmentKey {
    static let defaultValue: PromptBookmarkBridge? = nil
}

extension EnvironmentValues {
    var promptBookmarkBridge: PromptBookmarkBridge? {
        get { self[PromptBookmarkBridgeKey.self] }
        set { self[PromptBookmarkBridgeKey.self] = newValue }
    }
}

struct MessageBubbleView: View, Equatable {
    enum DisplayMode {
        case rendered
        case plain
    }

    /// SwiftUI re-evaluates `body` whenever any ancestor state changes.
    /// In a long conversation that means a `selectedPromptID` write from
    /// the scroll observer (fires on every scroll frame!) used to ripple
    /// through every visible bubble, re-running paragraph parsing and
    /// `Text` concatenation. None of this view's input properties depend
    /// on that selection, so wrap it with `.equatable()` at the call
    /// site and SwiftUI short-circuits the body re-eval when message +
    /// displayMode + identity inputs are unchanged. (Environment-driven
    /// updates — IdentityPreferencesStore mutations — still propagate
    /// because EquatableView only short-circuits structural input
    /// changes, not environment changes.)
    static func == (lhs: MessageBubbleView, rhs: MessageBubbleView) -> Bool {
        lhs.message == rhs.message
            && lhs.displayMode == rhs.displayMode
            && lhs.identityContext == rhs.identityContext
            && lhs.conversationPrimaryLanguage == rhs.conversationPrimaryLanguage
    }

    private enum Layout {
        static let avatarSize: CGFloat = 34
        static let avatarColumnWidth: CGFloat = 42
        /// Max width the user bubble (accent-tinted prompt) is allowed
        /// to reach before its text wraps. Keeps long prompts from
        /// stretching edge-to-edge and makes the bubble read as
        /// anchored to the avatar on the right rather than as a
        /// full-width banner. Tuned by eye against iMessage / Slack:
        /// wide enough for a few-sentence paragraph to sit on one or
        /// two lines, narrow enough that a ~60-char line still wraps.
        static let userBubbleMaxWidth: CGFloat = 520
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

        /// Baseline extra gap between wrapped lines in body text. See
        /// `MessageBubbleView.scaledBodyLineSpacing` for the rationale
        /// and how this scales with the body-text zoom multiplier.
        /// 5pt at the default 15pt body size pushes the effective
        /// line height from ~1.2× to ~1.5× — the comfort zone for
        /// long-form reading per typography research (Bringhurst,
        /// Lupton) and the value most modern reading-mode UIs land
        /// on.
        static let bodyLineSpacing: CGFloat = 5
    }

    let message: Message
    let displayMode: DisplayMode
    let identityContext: MessageIdentityContext?
    /// Conversation-level primary language detected up-front by
    /// `ConversationDetailView` (or `nil` if undetermined). Threaded
    /// through to the foreign-language grouper so its "is this run
    /// foreign?" check compares against the thread's actual native
    /// language, not the system locale — Japanese-primary threads
    /// rendered on an English-locale Mac were getting their
    /// Japanese answers folded into a "translate" disclosure.
    let conversationPrimaryLanguage: NLLanguage?
    @Environment(IdentityPreferencesStore.self) private var identityPreferences
    /// Optional find-in-page spec. SwiftUI tracks this as an environment
    /// dependency of `body`, so even though `.equatable()` short-circuits
    /// on structural input equality (`message`, `displayMode`,
    /// `identityContext`), environment writes still trigger a re-render —
    /// which is exactly what we want when the user types into the find
    /// bar.
    @Environment(\.searchHighlight) private var searchHighlight
    /// Optional Phase 4 pin bridge. When present, user-message bubbles
    /// render a small bookmark toggle next to their byline; when nil
    /// (legacy callers / previews that don't wire a bridge), the
    /// affordance is omitted entirely.
    @Environment(\.promptBookmarkBridge) private var promptBookmarkBridge
    /// Per-conversation asset handles + per-message attachment index
    /// published by `ConversationDetailView` after the raw transcript
    /// load finishes. When present, any images attached to this
    /// message (user-uploaded photos on ChatGPT, Claude image blocks)
    /// render above the text via `RawTranscriptImageView`. When
    /// `nil` — mock data, Gemini conversations, conversations whose
    /// raw JSON isn't vaulted, or the brief window before extraction
    /// resolves — bubbles render text-only, same as before.
    @Environment(\.messageAssetContext) private var messageAssetContext
    /// Browser-style zoom for the body column. Drives paragraph,
    /// list-item, blockquote, code-block, math-block, and table-cell
    /// font sizes. Headings and the smaller meta captions (image alt,
    /// "loading…" bands, unresolved-image error rows) intentionally
    /// stay at their fixed Layout sizes so the chrome doesn't pump
    /// when the user zooms reading text. Default 1.0 keeps the
    /// pre-zoom baseline when the env value isn't injected (Previews,
    /// non-app contexts).
    @Environment(\.bodyTextSizeMultiplier) private var bodyTextSizeMultiplier
    #if os(macOS)
    @Environment(\.openSettings) private var openSettings
    #endif

    /// Body paragraph / list / blockquote / table-cell size, scaled by
    /// the user's reader-zoom preference. Use this in place of
    /// `Layout.bodyFontSize` everywhere the result is body reading
    /// text. Auxiliary captions that derive from `Layout.bodyFontSize`
    /// with a `-1` / `-2` / `-3` offset deliberately keep using the
    /// raw constant — they're metadata, not body.
    private var scaledBodyFontSize: CGFloat {
        Layout.bodyFontSize * bodyTextSizeMultiplier
    }

    /// Code-block font size, scaled. Code is part of the body reading
    /// flow; if the prose bumps up, the code that documents the prose
    /// has to come along or the relative weight inverts.
    private var scaledCodeFontSize: CGFloat {
        Layout.codeFontSize * bodyTextSizeMultiplier
    }

    /// Display-math block size, scaled. Same rationale as code: math
    /// blocks are body content rendered alongside the prose.
    private var scaledMathFontSize: CGFloat {
        Layout.mathFontSize * bodyTextSizeMultiplier
    }

    /// Extra space between wrapped lines in body text. SwiftUI's
    /// default line height is approximately 1.2× the font size; the
    /// 5pt baseline here pushes that to roughly 1.5× at 15pt body
    /// text — the line height most reading-mode designs (Notion,
    /// Medium, browser reader views) settle on for long-form prose.
    /// Mixed Japanese / English content benefits in particular: kanji
    /// without breathing room visually pile up, and the wider
    /// vertical rhythm makes scanning much easier.
    ///
    /// Scales with the body-text zoom so the proportion stays
    /// constant — at 200 % zoom we get 10pt of additional line
    /// spacing on top of the doubled font size, preserving the same
    /// 1.5× line height ratio.
    private var scaledBodyLineSpacing: CGFloat {
        Layout.bodyLineSpacing * bodyTextSizeMultiplier
    }

    var body: some View {
        bodyContent
    }

    @ViewBuilder
    private var bodyContent: some View {
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
            // Two user-side layouts, chosen per-pane-width via
            // `ViewThatFits`:
            //
            // - **Wide** (pane ≥ ~600pt): iMessage-style right-hug.
            //   Leading Spacer, bubble capped at
            //   `Layout.userBubbleMaxWidth`, dedicated avatar column
            //   on the right. Short prompts sit compactly next to
            //   the avatar; long prompts wrap at the cap rather than
            //   stretching edge-to-edge, so the bubble reads as
            //   anchored to the avatar instead of a full-bleed
            //   banner.
            //
            // - **Narrow** (pane < ~600pt): avatar moves INLINE with
            //   the byline above the bubble, and the bubble fills
            //   the pane's full width. At narrow widths the trailing
            //   avatar column costs 52pt of horizontal budget the
            //   prompt text can't spare — the inline byline style
            //   (same pattern the assistant side uses) gives the
            //   bubble ~50pt more breathing room, which is enough to
            //   keep a typical prompt line from wrapping awkwardly.
            //
            // The wide candidate carries an explicit `minWidth` so
            // `ViewThatFits` has an honest rejection criterion —
            // otherwise the HStack's ideal size (tiny Spacer + short
            // bubble + fixed avatar) fits everywhere and the narrow
            // fallback is unreachable.
            ViewThatFits(in: .horizontal) {
                wideUserLayout
                    .frame(minWidth: 600)
                narrowUserLayout
            }
        } else {
            assistantMessageColumn
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Wide layout for user messages — classic trailing-avatar speech
    /// bubble. See `body` for the size-class rationale.
    private var wideUserLayout: some View {
        HStack(alignment: .top, spacing: 10) {
            Spacer(minLength: 0)

            userMessageColumn
                .frame(maxWidth: Layout.userBubbleMaxWidth, alignment: .trailing)

            avatarButton(size: Layout.avatarSize)
                .frame(width: Layout.avatarColumnWidth, alignment: .topTrailing)
        }
    }

    /// Narrow layout for user messages — inline byline + full-width
    /// bubble. Avatar sits in the byline row (same treatment as the
    /// assistant side) rather than stealing a dedicated trailing
    /// column, reclaiming ~50pt of horizontal budget for the prompt
    /// text itself.
    private var narrowUserLayout: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(alignment: .center, spacing: 8) {
                Spacer(minLength: 0)

                if let bridge = promptBookmarkBridge {
                    pinToggle(bridge: bridge)
                }
                Text(identityPresentation.displayName)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(identityPresentation.accentColor)

                avatarButton(size: Layout.avatarSize)
            }

            attachmentImagesView(alignment: .trailing)

            Text(highlightedVerbatim(message.content, blockAnchorID: message.id))
                .font(.system(size: scaledBodyFontSize))
                .lineSpacing(scaledBodyLineSpacing)
                .textSelection(.enabled)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(bubbleBackground)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    /// Pin toggle rendered inside the user-message byline when a
    /// `PromptBookmarkBridge` is available in the environment. Clicking
    /// flips the bookmark for this specific message; the shell observes
    /// the resulting set and updates the sidebar Bookmarks disclosure.
    /// Kept snug (14pt glyph) so it reads as a secondary affordance
    /// rather than a competing primary action to the avatar.
    @ViewBuilder
    private func pinToggle(bridge: PromptBookmarkBridge) -> some View {
        let pinned = bridge.isPinned(message.id)
        Button {
            bridge.toggle(message.id, pinSnippet)
        } label: {
            Image(systemName: pinned ? "bookmark.fill" : "bookmark")
                .font(.caption)
                .foregroundStyle(pinned ? Color.yellow : Color.secondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(pinned ? "Unpin this prompt" : "Pin this prompt")
    }

    /// Short excerpt stored in the bookmark payload so the sidebar row
    /// can render without re-loading the full message. Collapse
    /// whitespace runs first — otherwise `prefix(140)` on a prompt that
    /// starts with "\n\n" would emit a row that looks blank.
    private var pinSnippet: String {
        let collapsed = message.content
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        let trimmed = collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 140 { return trimmed }
        return String(trimmed.prefix(140)) + "…"
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
    /// byline. Column alignment is `.trailing` so the byline and the
    /// bubble hug the right edge (next to the avatar) when the bubble
    /// is narrower than the column's available width — the body lays
    /// out this column with a cap of `Layout.userBubbleMaxWidth`, so
    /// short prompts leave blank space on the LEFT, not distributed on
    /// both sides.
    private var userMessageColumn: some View {
        VStack(alignment: .trailing, spacing: 4) {
            // Byline row: pin toggle (when the env bridge is wired) to
            // the left of the name. The pin sits outside the bubble so
            // it stays visually at the "header" level — the prompt
            // bubble itself is the payload, the header is the metadata.
            HStack(spacing: 6) {
                if let bridge = promptBookmarkBridge {
                    pinToggle(bridge: bridge)
                }
                Text(identityPresentation.displayName)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(identityPresentation.accentColor)
            }

            // User prompts render verbatim regardless of display mode.
            // The raw input often contains markdown-significant prefixes
            // (`# ...`, `- ...`) used as shorthand/outline rather than
            // as actual document structure — rendering them as H1s and
            // bullet lists blows the bubble up to several screens tall
            // and loses the visual parity between "prompt as typed"
            // and "prompt as shown."
            //
            // No `frame(maxWidth: .infinity)` on the Text or its wrapper
            // — we want the bubble to size to the text's natural wrapped
            // width (capped by the parent's max-width frame), not to
            // stretch to fill. That's what lets a short prompt produce
            // a short bubble.
            // Attachments (images the user uploaded alongside this
            // prompt) render above the text bubble, right-aligned so
            // they visually belong to the user's column. Skipped when
            // the environment has no resolved asset context — the
            // normal text-only reader path.
            attachmentImagesView(alignment: .trailing)

            Text(highlightedVerbatim(message.content, blockAnchorID: message.id))
                .font(.system(size: scaledBodyFontSize))
                .lineSpacing(scaledBodyLineSpacing)
                .textSelection(.enabled)
                .multilineTextAlignment(.leading)
                .padding(12)
                .background(bubbleBackground)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
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
            // the assistant persona suddenly feel smaller than the
            // user's, which read as a downgrade.
            HStack(alignment: .center, spacing: 8) {
                avatarButton(size: Layout.avatarSize)

                Text(identityPresentation.displayName)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(identityPresentation.accentColor)

                Spacer()
            }

            VStack(alignment: .leading, spacing: 10) {
                // Attachments — same rationale as the user-side
                // column. Assistants can return image blocks too (for
                // example, Claude's vision responses), so this isn't
                // user-exclusive.
                attachmentImagesView(alignment: .leading)

                // Assistant replies render fully — their markdown is
                // meaningful output (headings, lists, code blocks). The
                // `.plain` display mode switches to verbatim text, same
                // as user prompts, so power-users can inspect raw
                // content without losing formatting chars.
                if displayMode == .plain {
                    Text(highlightedVerbatim(message.content, blockAnchorID: message.id))
                        .font(.system(size: scaledBodyFontSize))
                        .lineSpacing(scaledBodyLineSpacing)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(Array(renderItems.enumerated()), id: \.offset) { offset, item in
                        let anchorID = Self.searchBlockAnchorID(
                            messageID: message.id,
                            blockIndex: offset
                        )
                        // Pass the anchor EXPLICITLY to `renderItem` so
                        // `applyingSearchHighlight` — called deep inside
                        // the render chain — compares against the right
                        // per-block id. An earlier env-based delivery
                        // (`.environment(\.currentSearchBlockAnchor,…)`)
                        // didn't work because @Environment on
                        // MessageBubbleView reads its PARENT scope, not
                        // any `.environment(...)` written inside its
                        // own body — the env write was silently nil at
                        // the call site and the orange cursor never
                        // painted.
                        renderItem(item, blockAnchorID: anchorID)
                            // Register a scroll target per block so the
                            // find-bar's Next/Prev can land on the
                            // specific match inside a long reply,
                            // rather than always snapping back to the
                            // message top.
                            .id(anchorID)
                            // Publish this block's top-Y so the
                            // convergence loop in
                            // `performProgrammaticScroll` can tell when
                            // a block-level jump has actually landed,
                            // instead of always eating its full
                            // 480ms timeout because the target id
                            // never shows up in the offset cache.
                            .background(
                                GeometryReader { proxyGeo in
                                    Color.clear.preference(
                                        key: PromptTopYPreferenceKey.self,
                                        value: [
                                            anchorID: proxyGeo.frame(
                                                in: .named(ReaderScrollCoordinateSpace.name)
                                            ).minY
                                        ]
                                    )
                                }
                            )
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
    private func renderItem(
        _ item: MessageRenderItem,
        blockAnchorID: String
    ) -> some View {
        switch item {
        case .block(let block):
            renderBlock(block, blockAnchorID: blockAnchorID)
        case .foreignLanguageGroup(let language, let blocks):
            ForeignLanguageBlockView(language: language, blocks: blocks) { displayBlocks in
                // All sub-blocks inside a foreign-language group share
                // the outer group's anchor, so matches inside any
                // paragraph of the group hot-color as a single unit
                // when the find bar's cursor points at this group.
                ForEach(Array(displayBlocks.enumerated()), id: \.offset) { _, block in
                    renderBlock(block, blockAnchorID: blockAnchorID)
                }
            }
        case .thinkingGroup(let provider, let blocks):
            // Phase 4 structural-thinking fold. The view owns its
            // expand state internally; we just hand it the provider
            // tag and the blocks. No anchor wiring at the inner-text
            // level because thinking is not a search target — see
            // `searchText(for:)` below, which stringifies thinking
            // as empty so the find bar can't land inside a fold.
            ThinkingGroupView(provider: provider, blocks: blocks)
        }
    }

    @ViewBuilder
    private func renderBlock(
        _ block: ContentBlock,
        blockAnchorID: String
    ) -> some View {
        switch block {
        case .paragraph(let text):
            paragraphView(text, blockAnchorID: blockAnchorID)
        case .heading(let level, let text):
            headingView(level: level, text: text, blockAnchorID: blockAnchorID)
        case .listItem(let ordered, let depth, let text, let marker):
            listItemView(
                ordered: ordered,
                depth: depth,
                text: text,
                marker: marker,
                blockAnchorID: blockAnchorID
            )
        case .blockquote(let text):
            blockquoteView(text, blockAnchorID: blockAnchorID)
        case .code(let language, let code):
            CodeBlockView(language: language, code: code, fontSize: scaledCodeFontSize)
        case .math(let source):
            MathBlockView(source: source, fontSize: scaledMathFontSize)
        case .table(let headers, let rows, let alignments):
            TableBlockView(
                headers: headers,
                rows: rows,
                alignments: alignments,
                fontSize: scaledBodyFontSize,
                renderInline: { text in
                    // Capture this block's anchor so the table's inline
                    // cells flow through the same hot/dim decision as
                    // top-level paragraphs in this block.
                    renderInlineRich(
                        text,
                        fontSize: scaledBodyFontSize,
                        blockAnchorID: blockAnchorID
                    )
                }
            )
        case .horizontalRule:
            Divider()
                .padding(.vertical, 4)
        case .image(let url, let alt):
            imageBlockView(url: url, alt: alt)
        }
    }

    @ViewBuilder
    private func paragraphView(
        _ text: String,
        blockAnchorID: String
    ) -> some View {
        // Inject ZWSPs into long unbreakable runs so URLs / dotted
        // identifier chains in plain English prose break cleanly inside
        // the bubble width. Markdown-link syntax `[text](url)` and
        // inline code spans are skipped — see `LineBreakHints` for
        // the contract.
        let wrapped = LineBreakHints.softWrap(text)
        let rendered: Text = {
            if canRenderMarkdown(wrapped) {
                return renderInlineRich(
                    wrapped,
                    fontSize: scaledBodyFontSize,
                    blockAnchorID: blockAnchorID
                )
            }
            return Text(highlightedVerbatim(wrapped, blockAnchorID: blockAnchorID))
        }()

        rendered
            .font(.system(size: scaledBodyFontSize))
            .lineSpacing(scaledBodyLineSpacing)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func headingView(
        level: Int,
        text: String,
        blockAnchorID: String
    ) -> some View {
        let size: CGFloat = {
            switch level {
            case 1: return Layout.heading1FontSize
            case 2: return Layout.heading2FontSize
            case 3: return Layout.heading3FontSize
            default: return Layout.minorHeadingFontSize
            }
        }()

        // Heading padding is bumped from (top: 6/2, bottom: 2) to
        // (top: 8/4, bottom: 4) to give English ascenders / descenders
        // (the H, l, g, y in "Heading Examples") breathing room. Tight
        // 2-pt bottoms read fine with Japanese glyphs (which sit closer
        // to the baseline), but English heading runs felt cramped
        // against the next paragraph. See AGENTS.md "Reader Typography".
        let wrapped = LineBreakHints.softWrap(text)
        renderInlineRich(wrapped, fontSize: size, blockAnchorID: blockAnchorID)
            .font(.system(size: size, weight: .semibold))
            .textSelection(.enabled)
            .padding(.top, level <= 2 ? 8 : 4)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func listItemView(
        ordered: Bool,
        depth: Int,
        text: String,
        marker: String,
        blockAnchorID: String
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(marker)
                .font(.system(size: scaledBodyFontSize).monospacedDigit())
                .foregroundStyle(.secondary)
                // Ordered-list marker minWidth: 28 fits "100." with the
                // monospacedDigit() variant of SF Pro at the body font
                // size. Original 22 was tuned against single-digit
                // Japanese-prose lists; English numbered lists routinely
                // run into the teens, and double-digit markers ("10.")
                // were starting to nudge the text column. See AGENTS.md
                // "Reader Typography".
                .frame(minWidth: ordered ? 28 : 14, alignment: .trailing)

            renderInlineRich(
                LineBreakHints.softWrap(text),
                fontSize: scaledBodyFontSize,
                blockAnchorID: blockAnchorID
            )
                .font(.system(size: scaledBodyFontSize))
                .lineSpacing(scaledBodyLineSpacing)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, CGFloat(depth) * 16)
    }

    @ViewBuilder
    private func blockquoteView(
        _ text: String,
        blockAnchorID: String
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(Color.accentColor.opacity(0.6))
                .frame(width: 3)

            renderInlineRich(
                LineBreakHints.softWrap(text),
                fontSize: scaledBodyFontSize,
                blockAnchorID: blockAnchorID
            )
                .font(.system(size: scaledBodyFontSize).italic())
                .lineSpacing(scaledBodyLineSpacing)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }

    /// Render a markdown image block. Behaviour depends on the URL
    /// scheme — transcripts end up carrying a mix of:
    ///
    ///   * **`http(s)://…`** — mostly external image hosts pasted by
    ///     the user or retrieved by the assistant. These are the only
    ///     URLs we can actually fetch from the reader, so we hand
    ///     them to `AsyncImage`. While the image is in flight we
    ///     reserve a small placeholder band so the message doesn't
    ///     jump around during load.
    ///   * **`sandbox:/mnt/data/…`** (ChatGPT-generated images) — the
    ///     URL is meaningful only inside the ChatGPT sandbox. The
    ///     primary reader can't resolve it from the DB row alone; the
    ///     canonical rendering path for these lives in the raw
    ///     transcript view, which has access to the export vault and
    ///     asset resolver. We degrade gracefully: show a labelled
    ///     placeholder with the alt text so the reader still sees
    ///     "there was an image here" instead of a raw `![…](…)`
    ///     fragment.
    ///   * **Everything else** (bare filenames, `data:` URIs, etc.) —
    ///     treat as unresolvable for now and render the same labelled
    ///     placeholder.
    ///
    /// The alt caption, when present, renders in secondary foreground
    /// under the image so the description is preserved regardless of
    /// whether the image itself loaded.
    @ViewBuilder
    private func imageBlockView(url: String, alt: String) -> some View {
        let parsed = URL(string: url)
        let scheme = parsed?.scheme?.lowercased()
        let isFetchable = scheme == "http" || scheme == "https"

        VStack(alignment: .leading, spacing: 6) {
            if isFetchable, let parsed {
                AsyncImage(url: parsed) { phase in
                    switch phase {
                    case .empty:
                        imageLoadingBand()
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity, maxHeight: 480, alignment: .leading)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    case .failure:
                        imageUnresolvedView(alt: alt, target: url, reason: .loadFailed)
                    @unknown default:
                        imageUnresolvedView(alt: alt, target: url, reason: .unknown)
                    }
                }
            } else {
                imageUnresolvedView(alt: alt, target: url, reason: .unfetchableScheme(scheme))
            }

            if !alt.isEmpty {
                Text(alt)
                    .font(.system(size: Layout.bodyFontSize - 2))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }

    /// In-flight band shown while `AsyncImage` fetches a remote image.
    /// Fixed height so the surrounding layout doesn't jump once the
    /// real image lands; width is left flexible so the band spans the
    /// reader column.
    @ViewBuilder
    private func imageLoadingBand() -> some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Loading image…")
                .font(.system(size: Layout.bodyFontSize - 2))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 80, alignment: .leading)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
        )
    }

    /// Fallback presentation for image references the primary reader
    /// can't fetch (sandbox paths, bare filenames, load failures).
    /// Keeps the "an image was here" cue visible without spamming the
    /// reader with raw `![…](…)` markdown. The URL text is selectable
    /// so power users can copy it into the raw transcript view, which
    /// DOES know how to resolve sandbox assets via
    /// `RawTranscriptImageView`.
    private enum ImageUnresolvedReason {
        case unfetchableScheme(String?)
        case loadFailed
        case unknown
    }

    @ViewBuilder
    private func imageUnresolvedView(
        alt: String,
        target: String,
        reason: ImageUnresolvedReason
    ) -> some View {
        let caption: String = {
            switch reason {
            case .unfetchableScheme(let scheme):
                if let scheme, scheme == "sandbox" {
                    return String(localized: "Sandboxed image (visible only in the raw export view)")
                }
                if let scheme {
                    return String(localized: "Can’t display images with the \(scheme): scheme")
                }
                return String(localized: "Can’t resolve image location")
            case .loadFailed:
                return String(localized: "Couldn’t load image")
            case .unknown:
                return String(localized: "Can’t display image")
            }
        }()

        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "photo")
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(caption)
                    .font(.system(size: Layout.bodyFontSize - 1))
                    .foregroundStyle(.secondary)
                Text(target)
                    .font(.system(size: Layout.bodyFontSize - 3, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
        )
    }

    /// Render any images the raw transcript extractor attached to
    /// this message. Returns `EmptyView` — not even a `Spacer` — when
    /// the environment has no context or this message has no
    /// attachments, so bubbles without pictures stay visually
    /// identical to the pre-attachment layout.
    ///
    /// `alignment` controls which edge the image stack hugs inside
    /// its parent VStack: `.trailing` on the user side (so photos
    /// mirror the text bubble's right-hugging layout), `.leading` on
    /// the assistant side (so they align with the inline byline and
    /// the message body).
    @ViewBuilder
    private func attachmentImagesView(alignment: HorizontalAlignment) -> some View {
        if let context = messageAssetContext,
           let refs = context.attachmentsByMessageID[message.id],
           !refs.isEmpty {
            let baseOffset = context.startOffsetByMessageID[message.id] ?? 0
            // Horizontal strip: each `RawTranscriptImageView` sizes its
            // width from the decoded bitmap's aspect ratio (height is
            // pinned at `reservedHeight`), so the row naturally matches
            // the pane width when a handful of images fit and overflows
            // into horizontal scroll when they don't. Replaces the
            // prior `VStack`, which stacked portraits into a tall column
            // that forced the reader to scroll past the attachments
            // before the assistant's reply appeared underneath.
            //
            // `GeometryReader` hands the available width into the inner
            // HStack so the row can be right-hugged on the user side
            // when the images fit without scrolling. Without the
            // `minWidth`, an HStack of narrow attachments inside
            // `ScrollView(.horizontal)` collapses to its intrinsic
            // width and always sits at the leading edge — which on the
            // user side breaks the "user messages hug the right" shape
            // of the bubble column.
            GeometryReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 8) {
                        ForEach(Array(refs.enumerated()), id: \.offset) { localIndex, ref in
                            RawTranscriptImageView(
                                reference: ref,
                                snapshotID: context.snapshotID,
                                vault: context.vault,
                                resolver: context.resolver,
                                globalIndex: baseOffset + localIndex,
                                orderedReferences: context.orderedReferences
                            )
                        }
                    }
                    .frame(
                        minWidth: proxy.size.width,
                        alignment: alignment == .trailing ? .trailing : .leading
                    )
                }
            }
            // `GeometryReader` is flex-height, so the outer layout
            // needs a concrete band. `RawTranscriptImageView` reserves
            // `reservedHeight` (320pt) for each cell, and the row
            // itself has no surrounding chrome, so pinning the same
            // height here keeps the bubble layout stable during load.
            .frame(height: RawTranscriptImageView.reservedHeight)
            // Small bottom gap so the image row visually separates
            // from the text bubble / prose body below it.
            .padding(.bottom, 2)
        }
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
        if let cached = Self.blocksCache.object(forKey: message.id) {
            return cached.blocks
        }
        let parsed = ContentBlock.parse(message.content)
        Self.blocksCache.setObject(
            BlocksBox(parsed),
            forKey: message.id,
            cost: CacheCostEstimation.costForBlocks(parsed)
        )
        return parsed
    }

    /// Phase 3a: byte-aware LRU cache. `totalCostLimit = 32 MB` per
    /// the Phase 3 decision (A-3). Registers with
    /// `CachePurgeCoordinator.shared` so memory-pressure warnings drop
    /// the older half instead of triggering a full
    /// `removeAllObjects()` re-parse storm.
    private static let blocksCache: LRUTrackedCache<BlocksBox> = {
        let cache = LRUTrackedCache<BlocksBox>(
            name: "MessageBubbleView.blocks",
            countLimit: 500,
            totalCostLimit: 32 * 1024 * 1024
        )
        CachePurgeCoordinator.shared.register(cache)
        return cache
    }()

    private final class BlocksBox {
        let blocks: [ContentBlock]
        init(_ blocks: [ContentBlock]) { self.blocks = blocks }
    }

    /// Same lifecycle as `contentBlocks`, but folded through
    /// `StructuredBlockGrouper` (Phase 4 structural-thinking path) or
    /// `ForeignLanguageGrouping` (legacy language-detection path).
    /// Cached separately because the grouping pass is itself non-
    /// trivial (NL detection per block, JSON-decoded blocks) and
    /// `body` is re-evaluated on parent updates.
    ///
    /// Dispatch:
    /// - When `message.contentBlocks` is non-nil AND the profile has
    ///   `collapsesThinking` on AND the structured blocks contain at
    ///   least one `.thinking` entry → structural path. The thinking
    ///   blocks lift to a `.thinkingGroup` at the top, the rest of
    ///   the message renders from the flat `content` markdown
    ///   parse as before.
    /// - Otherwise → legacy language-fold path. Preserves today's
    ///   behavior for un-backfilled archive.db rows (content_json
    ///   IS NULL) and for messages that have no thinking content.
    private var renderItems: [MessageRenderItem] {
        // Cache key folds in `collapseFlag`, the conversation's
        // detected primary language, AND a marker for whether the
        // structured-thinking path was taken. The cache lives across
        // message ids, but a single id resolves to the same path
        // every time (contentBlocks is set at fetch time and doesn't
        // mutate), so the marker is conceptually redundant — it's
        // there as defense in depth against future code that might
        // mutate the message.
        let profile = renderProfile
        let collapse = profile.collapsesForeignLanguageRuns
        let nativeLang = conversationPrimaryLanguage?.rawValue ?? ""
        let useStructured = profile.collapsesThinking
            && (message.contentBlocks?.contains(where: {
                if case .thinking = $0 { return true }
                return false
            }) ?? false)
        let key = "\(message.id)#\(collapse ? 1 : 0)#\(nativeLang)#\(useStructured ? 1 : 0)" as NSString
        if let cached = Self.renderItemsCache.object(forKey: key) {
            return cached.items
        }

        let items: [MessageRenderItem]
        if useStructured, let structured = message.contentBlocks {
            // Phase 4 structural path. Uses Python-annotated thinking
            // — no NLLanguageRecognizer involved, no false positives
            // on math notation or short Japanese paragraphs.
            //
            // Important dedup step: Claude's export `message.text`
            // field (the source of `messages.content`) already
            // concatenates the thinking text alongside the response
            // — so without filtering, the same thinking would render
            // twice (once as the lifted `ThinkingGroupView` at the
            // top, once inline as part of the markdown body). Strip
            // each thinking block's text out of the flat content
            // before re-parsing so the body renders the response
            // alone.
            let responseFlatBlocks = contentBlocksExcludingThinking(structured: structured)
            items = StructuredBlockGrouper.group(
                structured: structured,
                flatContent: responseFlatBlocks,
                profile: profile
            )
        } else {
            // Phase 6 retired the language-detection legacy path.
            // Messages without a populated `contentBlocks` (legacy
            // archive rows whose original raw export was never
            // preserved, plus regular text-only assistant turns) now
            // render their flat content as-is. The previous fallback
            // ran each block through `ForeignLanguageGrouping`, but
            // its NLLanguageRecognizer-based heuristic accumulated
            // four hotfix layers (listItem exclusion, formula text
            // exclusion, user-bias primary-language detection, short-
            // run fold gate) before still misfiring on real
            // conversations — the structural path is the supported
            // mechanism now.
            items = contentBlocks.map { .block($0) }
        }
        Self.renderItemsCache.setObject(RenderItemsBox(items), forKey: key)
        return items
    }

    /// Per-bubble rendering policy, resolved from the conversation's
    /// source. See `MessageRenderProfile` for the dispatch table.
    private var renderProfile: MessageRenderProfile {
        MessageRenderProfile.resolve(
            source: identityContext?.source,
            model: identityContext?.model
        )
    }

    /// Build the `[ContentBlock]` for the response body of a message
    /// whose structural-thinking path is active, with each thinking
    /// block's text stripped out of the flat-content source before
    /// markdown parsing. Required because Claude's export
    /// pre-concatenates thinking onto the user-visible response in
    /// `message.text` — `messages.content` therefore carries the
    /// thinking inline, which would otherwise render a second time
    /// underneath the lifted `ThinkingGroupView`.
    ///
    /// Strategy: serially `range(of:)`-search each thinking text in
    /// the flat content and remove the first match. Whitespace at the
    /// extraction boundary is trimmed so the markdown parser doesn't
    /// produce stray empty paragraphs where thinking used to be.
    /// Falls back gracefully when a thinking text is not present in
    /// the flat content (defensive — happens with manually-edited
    /// rows or future format changes): the un-stripped flat content
    /// is parsed instead.
    private func contentBlocksExcludingThinking(structured: [MessageBlock]) -> [ContentBlock] {
        let thinkingTexts: [String] = structured.compactMap { block in
            if case .thinking(_, let text, _) = block {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            return nil
        }
        guard !thinkingTexts.isEmpty else { return contentBlocks }

        var working = message.content
        for text in thinkingTexts {
            if let range = working.range(of: text) {
                working.removeSubrange(range)
            }
        }
        // Collapse the blank paragraphs left behind by the removal
        // (Claude's flat text often has blank-line separators around
        // each thinking segment; after the segment goes, those
        // separators stack up).
        let collapsed = working
            .replacingOccurrences(
                of: #"\n{3,}"#,
                with: "\n\n",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ContentBlock.parse(collapsed)
    }

    private static let renderItemsCache: NSCache<NSString, RenderItemsBox> = {
        let cache = NSCache<NSString, RenderItemsBox>()
        cache.countLimit = 500
        return cache
    }()

    private final class RenderItemsBox {
        let items: [MessageRenderItem]
        init(_ items: [MessageRenderItem]) { self.items = items }
    }

    private var canRenderMessage: Bool {
        message.content.count <= Layout.maxRenderedMessageLength
    }

    // MARK: - In-thread search anchor helpers

    /// Scroll-anchor id for an individual assistant block. Pairs with
    /// the per-renderItem `.id(...)` in `assistantMessageColumn` so the
    /// find-bar's Next/Prev can scroll to the block containing the
    /// active match, not just to the message top.
    ///
    /// Prefix matches `SearchBlockAnchor.idPrefix` so the reader's
    /// outline-cursor logic can cleanly filter these ids back out
    /// (they're NOT prompt boundaries).
    static func searchBlockAnchorID(messageID: String, blockIndex: Int) -> String {
        "\(SearchBlockAnchor.idPrefix)\(messageID)#\(blockIndex)"
    }

    /// Static counterpart to the instance-side
    /// `contentBlocksExcludingThinking(structured:)`. Used by
    /// `searchableBlocks` (a `static` API) so the search-anchor list
    /// stays in lockstep with the instance-side render. Logic is the
    /// same: strip each thinking block's text out of `rawContent`,
    /// collapse the resulting blank-paragraph runs, then markdown-
    /// parse.
    static func parseFlatContentExcludingThinking(
        rawContent: String,
        structured: [MessageBlock]
    ) -> [ContentBlock] {
        let thinkingTexts: [String] = structured.compactMap { block in
            if case .thinking(_, let text, _) = block {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            return nil
        }
        guard !thinkingTexts.isEmpty else {
            return ContentBlock.parse(rawContent)
        }
        var working = rawContent
        for text in thinkingTexts {
            if let range = working.range(of: text) {
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
        return ContentBlock.parse(collapsed)
    }

    /// Build the (text, anchorID) list the in-thread search scanner
    /// needs — one entry per addressable render block inside the
    /// message, in the same order the view lays them out.
    ///
    /// - User messages: a single entry whose anchor id is the outer
    ///   message id, since the whole prompt renders as one Text.
    /// - Assistant messages: one entry per `MessageRenderItem` produced
    ///   by `ForeignLanguageGrouping.group(...)`, so the scanner's
    ///   per-block occurrence counting stays aligned with
    ///   `applyingSearchHighlight`'s per-block scan.
    ///
    /// Caller is `DesignMockReaderPaneContent.recomputeMatches`. Lives
    /// here so the block-enumeration logic is owned by exactly the
    /// view that renders the blocks — the two can't drift out of
    /// sync as the markdown parser / grouper evolves.
    static func searchableBlocks(
        for message: Message,
        profile: MessageRenderProfile = .passthrough,
        nativeLanguage: NLLanguage? = nil
    ) -> [(text: String, anchorID: String)] {
        if message.isUser {
            return [(message.content, message.id)]
        }
        // MUST mirror the grouping decision `renderItems` makes, or
        // the per-block occurrence indices produced here will not line
        // up with `applyingSearchHighlight`'s render-time scan. Take
        // the same dispatch path the instance method takes:
        // structural when the message has thinking blocks and the
        // profile asks for it, language-heuristic otherwise.
        let useStructured = profile.collapsesThinking
            && (message.contentBlocks?.contains(where: {
                if case .thinking = $0 { return true }
                return false
            }) ?? false)
        let items: [MessageRenderItem]
        if useStructured, let structured = message.contentBlocks {
            // Same dedup the instance path uses — strip thinking text
            // out of the flat content before parsing, so the search
            // anchor count matches the (post-dedup) rendered block
            // count exactly.
            let parsed = parseFlatContentExcludingThinking(
                rawContent: message.content,
                structured: structured
            )
            items = StructuredBlockGrouper.group(
                structured: structured,
                flatContent: parsed,
                profile: profile
            )
        } else {
            // Phase 6: legacy language-detection grouper retired.
            // Search-anchor enumeration must mirror whatever
            // `renderItems` actually does, so when the structural
            // path doesn't take over we just wrap each parsed block
            // as `.block(_)` — same shape `renderItems` produces in
            // the corresponding branch.
            let parsed = ContentBlock.parse(message.content)
            items = parsed.map { .block($0) }
        }
        return items.enumerated().map { offset, item in
            let anchorID = searchBlockAnchorID(
                messageID: message.id,
                blockIndex: offset
            )
            return (searchText(for: item), anchorID)
        }
    }

    /// Visible-text payload for a single render item. Matches the text
    /// the layout-side `applyingSearchHighlight` scans, so occurrence
    /// indices produced here line up with the ones the renderer sees
    /// when it picks which range to hot-color.
    private static func searchText(for item: MessageRenderItem) -> String {
        switch item {
        case .block(let block):
            return searchText(for: block)
        case .foreignLanguageGroup(_, let blocks):
            return blocks.map(searchText(for:)).joined(separator: "\n")
        case .thinkingGroup:
            // Thinking is hidden by default and considered model-
            // internal scratch text rather than user-facing prose.
            // Returning empty keeps the find bar from landing
            // matches inside a fold the user would have to expand
            // to see — frustrating UX. If we ever want "search
            // including thinking", make it an opt-in toggle in the
            // search bar rather than the default.
            return ""
        }
    }

    private static func searchText(for block: ContentBlock) -> String {
        switch block {
        case .paragraph(let text):
            return text
        case .heading(_, let text):
            return text
        case .listItem(_, _, let text, _):
            return text
        case .blockquote(let text):
            return text
        case .code(_, let code):
            return code
        case .math(let source):
            return source
        case .table(let headers, let rows, _):
            var parts: [String] = headers
            for row in rows {
                parts.append(contentsOf: row)
            }
            return parts.joined(separator: " ")
        case .horizontalRule:
            return ""
        case .image(_, let alt):
            return alt
        }
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
    private func renderInlineMarkdown(
        _ text: String,
        blockAnchorID: String
    ) -> AttributedString {
        // The cache stores the markdown-parsed `AttributedString` keyed
        // on source text only — deliberately NOT on the search spec, so
        // the cache stays valid across typing. Highlight runs are applied
        // on the way out as a cheap post-pass; they mutate only the
        // `.backgroundColor` attribute of character ranges that match,
        // which is O(n) in the paragraph length.
        applyingSearchHighlight(
            to: InlineMarkdownCache.shared.render(text),
            blockAnchorID: blockAnchorID
        )
    }

    /// Wrap a raw `String` in an `AttributedString`, applying any active
    /// search highlight. Used for the three verbatim-text paths (user
    /// prompt, assistant plain mode, oversized-paragraph fallback) that
    /// bypass the markdown pipeline entirely.
    private func highlightedVerbatim(
        _ text: String,
        blockAnchorID: String
    ) -> AttributedString {
        applyingSearchHighlight(
            to: AttributedString(text),
            blockAnchorID: blockAnchorID
        )
    }

    /// Paint `.backgroundColor` runs onto every case-insensitive substring
    /// match of the active search query. No-ops when the env spec is nil,
    /// empty, or when this bubble's message content doesn't contain the
    /// query (the containment check is a cheap filter to skip the
    /// per-range scan for the majority of bubbles that aren't hits).
    ///
    /// `blockAnchorID` identifies the rendered block this attributed
    /// string belongs to. It's compared against
    /// `SearchHighlightSpec.activeAnchorID` to decide whether THIS block
    /// should draw its Nth match in the hot color (orange) or leave all
    /// matches in the dim color (yellow). Threading this in as an
    /// explicit parameter — rather than via `@Environment` on
    /// MessageBubbleView — is load-bearing: SwiftUI's `@Environment`
    /// properties on a view are read from the view's PARENT scope, so a
    /// `.environment(...)` modifier applied INSIDE MessageBubbleView's
    /// body never flows back up to `self`'s env read. A per-block env
    /// write was silently nil-valued at this call site, which is why
    /// the orange cursor was never visible.
    private func applyingSearchHighlight(
        to attr: AttributedString,
        blockAnchorID: String
    ) -> AttributedString {
        guard let spec = searchHighlight, !spec.isEmpty else { return attr }
        let needle = spec.normalizedQuery
        // Fast path: this bubble isn't a match, don't scan its runs.
        guard message.content.range(of: needle, options: .caseInsensitive) != nil else {
            return attr
        }
        var result = attr
        let isActiveBlock = spec.activeAnchorID != nil
            && spec.activeAnchorID == blockAnchorID
        let activeOccurrence = spec.activeOccurrenceInBlock
        let hot = Color.orange.opacity(0.55)
        let dim = Color.yellow.opacity(0.45)

        var searchStart = result.startIndex
        var occurrenceIndex = 0
        while searchStart < result.endIndex,
              let range = result[searchStart..<result.endIndex]
                .range(of: needle, options: .caseInsensitive) {
            let isHot: Bool
            if isActiveBlock {
                if let target = activeOccurrence {
                    isHot = occurrenceIndex == target
                } else {
                    isHot = true
                }
            } else {
                isHot = false
            }
            result[range].backgroundColor = isHot ? hot : dim
            searchStart = range.upperBound
            occurrenceIndex += 1
        }
        return result
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
    private func renderInlineRich(
        _ text: String,
        fontSize: CGFloat,
        blockAnchorID: String
    ) -> Text {
        // Fast path: nothing that could possibly be inline math. Skip
        // the splitter entirely and go straight to the existing
        // markdown path (which itself has a fast path for pure prose).
        if !text.contains("$") && !text.contains("\\(") {
            return Text(renderInlineMarkdown(text, blockAnchorID: blockAnchorID))
        }

        let runs = InlineMathSplitter.split(text)

        // Splitter found no math spans worth extracting — collapse back
        // to the plain-markdown path so we don't pay for Text
        // concatenation when there's nothing to typeset.
        if runs.count == 1, case .text(let only) = runs[0] {
            return Text(renderInlineMarkdown(only, blockAnchorID: blockAnchorID))
        }

        var result = Text("")
        for run in runs {
            switch run {
            case .text(let segment):
                result = result + Text(renderInlineMarkdown(segment, blockAnchorID: blockAnchorID))
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
    /// Process-level cache for splitter output. Splitting is pure w.r.t.
    /// the input string and produces a small, immutable structure, but
    /// the work itself (full `Array(text)` conversion + per-character
    /// scan + buffer accumulation) repeats on every body re-eval of the
    /// containing message bubble — and on long, math-dense pages
    /// (eigenvalue / linear-algebra threads) we hit the same paragraphs
    /// dozens of times per scroll frame. Memoizing turns those into an
    /// NSCache hit.
    private final class RunsBox {
        let runs: [InlineTextRun]
        init(_ runs: [InlineTextRun]) { self.runs = runs }
    }
    private static let cache: NSCache<NSString, RunsBox> = {
        let c = NSCache<NSString, RunsBox>()
        c.countLimit = 4096
        return c
    }()

    static func split(_ text: String) -> [InlineTextRun] {
        // Skip the cache for tiny inputs — the NSString bridge + NSCache
        // lookup overhead is comparable to the split itself for short
        // strings, and they're cheap to redo.
        if text.count > 24 {
            let key = text as NSString
            if let hit = cache.object(forKey: key) {
                return hit.runs
            }
            let computed = computeSplit(text)
            cache.setObject(RunsBox(computed), forKey: key)
            return computed
        }
        return computeSplit(text)
    }

    private static func computeSplit(_ text: String) -> [InlineTextRun] {
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

    var gridColumnAlignment: HorizontalAlignment {
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
    /// Standalone image reference parsed from markdown image syntax
    /// (`![alt](url)` on its own line). The reader renders this inline
    /// as a picture rather than surfacing the raw `![…](…)` source,
    /// which is how assistants like ChatGPT / Claude deliver generated
    /// or attached images back in their replies. `url` is the source
    /// target as written in the message (may be an `http(s)` URL, a
    /// `sandbox:` path for ChatGPT transcripts, or a bare filename);
    /// the renderer decides per-scheme how (or whether) to resolve it.
    /// `alt` is the bracketed caption — displayed as a subtitle below
    /// the image so the textual description is preserved for
    /// accessibility and for cases where the image can't load.
    case image(url: String, alt: String)

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

                // Standalone image: `![alt](url)` on its own line.
                // Extracted before list / heading detection so that an
                // image isn't swallowed by the paragraph stream (where
                // `canRenderMarkdown` would just surface `![alt](url)`
                // as literal text — SwiftUI's attributed-markdown
                // parser doesn't inflate image references on its own).
                // Inline image syntax inside a prose paragraph is
                // intentionally left untouched: assistants almost
                // always emit image links on their own line, and
                // extracting mid-sentence would fragment the
                // surrounding paragraph into awkward pieces.
                if let image = Self.parseStandaloneImage(trimmed) {
                    flushParagraph()
                    flushBlockquote()
                    flushPendingTable()
                    blocks.append(.image(url: image.url, alt: image.alt))
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

        /// Recognize a standalone markdown image line: `![alt](url)`.
        ///
        /// Returns the bracketed alt text and the parenthesized target
        /// if the entire trimmed line is exactly one image reference
        /// with nothing trailing after the closing `)`. Anything else
        /// (image followed by more prose, optional title strings
        /// inside the parens, bracket-nesting past what a normal alt
        /// string uses, etc.) falls through to paragraph text.
        ///
        /// The matcher is hand-rolled rather than `NSRegularExpression`
        /// because:
        ///   * the parser is on the message-body render hot path, and
        ///     a string scan avoids the per-call regex compile cost;
        ///   * alt strings can legitimately contain unbalanced
        ///     brackets from pasted captions, so we only accept a
        ///     simple (non-nested) `[…]` and let the regex-unfriendly
        ///     edge cases remain paragraph text.
        ///
        /// An optional quoted title after the URL (`![alt](url "t")`)
        /// is stripped — the reader surfaces `alt` as the caption and
        /// doesn't expose link titles separately.
        private static func parseStandaloneImage(_ trimmed: String) -> (url: String, alt: String)? {
            // Fast reject: must start with `![` and end with `)`.
            guard trimmed.hasPrefix("![") else { return nil }
            guard trimmed.hasSuffix(")") else { return nil }

            let chars = Array(trimmed)
            var i = 2 // past `![`
            var altChars: [Character] = []
            while i < chars.count, chars[i] != "]" {
                // No nested brackets inside alt — keep this simple so
                // pathological inputs fall back to paragraph text
                // rather than over-matching.
                if chars[i] == "[" { return nil }
                altChars.append(chars[i])
                i += 1
            }
            guard i < chars.count, chars[i] == "]" else { return nil }
            i += 1
            guard i < chars.count, chars[i] == "(" else { return nil }
            i += 1

            // URL body: everything up to the final `)`. We allow
            // parentheses inside the URL only via balancing, which
            // matches CommonMark's image-URL rule for bare URLs. A
            // trailing `"title"` is tolerated and stripped.
            var urlChars: [Character] = []
            var parenDepth = 1
            while i < chars.count {
                let c = chars[i]
                if c == "(" {
                    parenDepth += 1
                    urlChars.append(c)
                } else if c == ")" {
                    parenDepth -= 1
                    if parenDepth == 0 {
                        i += 1
                        break
                    }
                    urlChars.append(c)
                } else {
                    urlChars.append(c)
                }
                i += 1
            }
            // The whole line must end at the matching `)` — no trailing
            // prose. `i == chars.count` ensures that.
            guard i == chars.count, parenDepth == 0 else { return nil }

            var body = String(urlChars).trimmingCharacters(in: .whitespaces)
            // Strip optional title: `url "title"` or `url 'title'`.
            if let lastSpace = body.lastIndex(of: " ") {
                let tail = body[body.index(after: lastSpace)...]
                    .trimmingCharacters(in: .whitespaces)
                if (tail.hasPrefix("\"") && tail.hasSuffix("\"") && tail.count >= 2)
                    || (tail.hasPrefix("'") && tail.hasSuffix("'") && tail.count >= 2) {
                    body = String(body[..<lastSpace]).trimmingCharacters(in: .whitespaces)
                }
            }
            // Angle-bracket wrapping: `<http://…>` is legal CommonMark.
            if body.hasPrefix("<") && body.hasSuffix(">") && body.count >= 2 {
                body = String(body.dropFirst().dropLast())
            }

            guard !body.isEmpty else { return nil }
            return (url: body, alt: String(altChars))
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

            // Word-wrap (no horizontal ScrollView) so a two-finger
            // horizontal trackpad swipe inside the code can't be
            // mis-recognized as a Viewer Mode swipe — the swipe gesture
            // on the workspace split view (`ViewerModeSwipeGesture`) eats
            // events when the user actually meant to scroll the code
            // sideways. Wrapping also matches the reading flow of the
            // surrounding paragraphs.
            //
            // Long single-token lines (URLs, dotted identifier chains,
            // hashed filenames) need explicit help: SwiftUI's `Text`
            // does not break inside non-CJK tokens regardless of how
            // many slashes / dots / underscores they contain.
            // `LineBreakHints.softWrap(_:inMarkdown: false)` injects
            // zero-width spaces after path-like delimiters so CoreText
            // gets break opportunities. `inMarkdown: false` because the
            // code is rendered verbatim — no markdown link syntax to
            // protect, and inline-code-span backticks inside source
            // shouldn't be treated specially. Colored via
            // `SyntaxHighlighter` so the per-language palette stays in
            // sync with whatever `bodyFontSize` the bubble is using.
            Text(SyntaxHighlighter.highlight(
                LineBreakHints.softWrap(code, inMarkdown: false),
                language: language,
                fontSize: fontSize
            ))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
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
        // No horizontal ScrollView wrapper — two-finger trackpad swipes
        // inside a scrollable table would be mis-recognized by the
        // Viewer-Mode swipe gesture on the workspace split view
        // (`ViewerModeSwipeGesture`) and flip the mode accidentally.
        // Same tradeoff the code-block renderer makes one struct up:
        // wrap cells instead of letting the table scroll sideways.
        //
        // `Grid` sizes every column to its widest cell across ALL
        // rows — header + body — so cell boundaries line up
        // vertically. Cells use `.fixedSize(horizontal: false,
        // vertical: true)` inside `cellText`, so when the Grid's
        // natural width exceeds the bubble's available width, each
        // cell's text wraps rather than the whole grid overflowing.
        //
        // No outer `.frame(maxWidth: .infinity)` — we want the
        // rounded-rectangle chrome to hug the table's natural width.
        // On a wide viewer this stops short tables (3 narrow columns
        // of prices, etc.) from stretching edge-to-edge with blank
        // filler between columns.
        Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                ForEach(Array(headers.enumerated()), id: \.offset) { index, cell in
                    cellText(cell, alignment: alignment(at: index))
                        .font(.system(size: fontSize, weight: .semibold))
                        .padding(.horizontal, 10)
                        // Vertical 8 (was 6) so English descenders
                        // (g, j, p, q, y) clear the row separator. See
                        // AGENTS.md "Reader Typography".
                        .padding(.vertical, 8)
                        .gridColumnAlignment(alignment(at: index).gridColumnAlignment)
                }
            }
            Divider()
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                if index > 0 {
                    Divider().opacity(0.3)
                }
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { idx, cell in
                        cellText(cell, alignment: alignment(at: idx))
                            .font(.system(size: fontSize))
                            .padding(.horizontal, 10)
                            // Match header vertical 8 (see header
                            // padding above).
                            .padding(.vertical, 8)
                    }
                }
            }
        }
        .padding(.vertical, 2)
        .background(PlatformColors.textBackground.opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.gray.opacity(0.2), lineWidth: 1)
        )
    }

    private func cellText(_ text: String, alignment: TableAlignment) -> some View {
        // Soft-break injection: cells often hold URLs / model identifiers
        // / hash-like values that would otherwise overflow the column.
        // Routed through the markdown-aware variant because the cell
        // body still goes through the inline markdown renderer (links
        // and inline code may appear inside cells).
        renderInline(LineBreakHints.softWrap(text))
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
                // No horizontal ScrollView — same rationale as the code
                // block and table renderers: two-finger trackpad swipes
                // inside a scrollable math block would be mis-recognized
                // by `ViewerModeSwipeGesture` and flip Viewer Mode. Wide
                // matrices / long equations that exceed the bubble
                // width will clip at the edge; the raw-source fallback
                // below is the recovery path (users can still read /
                // copy via the CopyButton in the header).
                MathLabelView(
                    latex: source,
                    fontSize: fontSize * 1.15
                )
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
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
