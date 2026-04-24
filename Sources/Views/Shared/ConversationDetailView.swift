import SwiftUI
#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

struct ConversationDetailView: View {
    enum DetailDisplayMode: String, CaseIterable, Identifiable {
        case rendered = "Rendered"
        case plain = "Plain"

        var id: String { rawValue }
    }

    @State private var viewModel: ConversationDetailViewModel
    @State private var localDisplayMode: DetailDisplayMode = .rendered
    private let externalDisplayMode: Binding<DetailDisplayMode>?
    private let externalSelectedPromptID: Binding<String?>?
    /// One-shot "please scroll to this prompt" signal from outside the
    /// reader pane (e.g. the middle-pane Viewer-Mode prompt directory,
    /// or the header outline popover). The detail view observes this
    /// binding and performs a programmatic scroll, then clears it back
    /// to nil so the next tap — even on the SAME prompt — re-fires.
    ///
    /// Split from `selectedPromptID` because the selection binding is
    /// also written continuously by the scroll observer, which means
    /// "tap prompt you're already looking at" used to be a silent
    /// no-op (the binding already equaled the tap target, onChange
    /// never fired). Routing through this separate imperative token
    /// fixes the "戻れなかった" report.
    private let externalRequestedPromptID: Binding<String?>?
    /// Observed one-shot signal asking the reader body to snap to its
    /// top (the `ConversationHeaderView`). The caller rotates a fresh
    /// `UUID` per tap so consecutive taps re-fire `.onChange`. `nil`
    /// when no external party is driving scroll-to-top behavior (iOS,
    /// previews, embedded uses).
    private let externalScrollToTopToken: Binding<UUID?>?
    private let showsSystemChrome: Bool
    private let onDetailChanged: ((ConversationDetail?) -> Void)?
    private let onPromptOutlineChanged: (([ConversationPromptOutlineItem]) -> Void)?
    /// Optional find-in-page spec forwarded down to every
    /// `MessageBubbleView` via `EnvironmentValues.searchHighlight`. When
    /// non-nil and non-empty, bubbles paint a keyword-level background
    /// wash on matching substrings (orange on the active match, yellow
    /// on others). Defaults to nil so call sites that don't use the
    /// in-thread finder see no behavioral change.
    private let searchHighlight: SearchHighlightSpec?
    /// Optional. When present, the view pulls the raw transcript for
    /// this conversation after the DB detail lands and publishes an
    /// `MessageAssetContext` down the view tree so bubbles can render
    /// user-uploaded images. `nil` is the honest state when the host
    /// isn't running against a real vault (mock / preview) — bubbles
    /// fall back to text-only rendering. Resolved via
    /// `@EnvironmentObject` rather than a constructor arg so the
    /// four existing call sites stay untouched.
    @EnvironmentObject private var services: AppServices

    init(
        conversationId: String,
        repository: any ConversationRepository,
        displayMode: Binding<DetailDisplayMode>? = nil,
        selectedPromptID: Binding<String?>? = nil,
        requestedPromptID: Binding<String?>? = nil,
        scrollToTopToken: Binding<UUID?>? = nil,
        showsSystemChrome: Bool = true,
        searchHighlight: SearchHighlightSpec? = nil,
        onDetailChanged: ((ConversationDetail?) -> Void)? = nil,
        onPromptOutlineChanged: (([ConversationPromptOutlineItem]) -> Void)? = nil
    ) {
        _viewModel = State(
            initialValue: ConversationDetailViewModel(
                conversationId: conversationId,
                repository: repository
            )
        )
        externalDisplayMode = displayMode
        externalSelectedPromptID = selectedPromptID
        externalRequestedPromptID = requestedPromptID
        externalScrollToTopToken = scrollToTopToken
        self.showsSystemChrome = showsSystemChrome
        self.searchHighlight = searchHighlight
        self.onDetailChanged = onDetailChanged
        self.onPromptOutlineChanged = onPromptOutlineChanged
    }

    var body: some View {
        contentView
            .task(id: viewModel.conversationId) {
                await viewModel.load()
                // Kick off the raw-transcript attachment pull in the
                // SAME task so it cancels cleanly on conversation
                // switch. Runs after `fetchDetail` so the alignment
                // routine has DB messages to pair against. No-op
                // when the services are mock-backed (loader is nil).
                await viewModel.attachRawServices(
                    loader: services.rawConversationLoader,
                    vault: services.rawExportVault,
                    resolver: services.rawAssetResolver
                )
                onDetailChanged?(viewModel.detail)
                if let detail = viewModel.detail {
                    if Self.shouldPreferPlainDisplay(for: detail) {
                        resolvedDisplayMode.wrappedValue = .plain
                    }

                    let outline = Self.promptOutline(for: detail)
                    onPromptOutlineChanged?(outline)
                    // Intentionally do NOT seed `resolvedSelectedPromptID` here:
                    // doing so caused the viewer to open scrolled partway down
                    // (ScrollViewReader.onChange jumped to the first user
                    // prompt, hiding system/preface messages). The selection
                    // is now only set when the user taps an outline entry.
                }
            }
    }

    @ViewBuilder
    private var contentView: some View {
        if viewModel.isLoading {
            ProgressView()
        } else if let detail = viewModel.detail {
            LoadedConversationDetailView(
                displayMode: resolvedDisplayMode,
                selectedPromptID: resolvedSelectedPromptID,
                requestedPromptID: externalRequestedPromptID ?? .constant(nil),
                scrollToTopToken: externalScrollToTopToken ?? .constant(nil),
                detail: detail,
                showsSystemChrome: showsSystemChrome
            )
            .environment(\.searchHighlight, searchHighlight)
            // Publish any resolved per-message attachments so
            // `MessageBubbleView` can paint user-uploaded images above
            // each message's text. `nil` while the second-stage raw
            // transcript load is still running, which keeps the
            // first-paint text-only fast path responsive.
            .environment(\.messageAssetContext, viewModel.assetContext)
        } else if let errorText = viewModel.errorText {
            ContentUnavailableView(
                "Couldn’t Load Conversation",
                systemImage: "exclamationmark.triangle",
                description: Text(errorText)
            )
        } else {
            ContentUnavailableView(
                "Not Found",
                systemImage: "questionmark.circle",
                description: Text("The selected conversation no longer exists.")
            )
        }
    }

    private var resolvedDisplayMode: Binding<DetailDisplayMode> {
        externalDisplayMode ?? $localDisplayMode
    }

    private var resolvedSelectedPromptID: Binding<String?> {
        externalSelectedPromptID ?? .constant(nil)
    }

    static func shouldPreferPlainDisplay(for detail: ConversationDetail) -> Bool {
        // Previously returned true for `source == "markdown"` (so every
        // imported `.md` conversation opened as verbatim text) and for
        // any conversation containing a 20k+ char message. Both defaults
        // were counter-intuitive:
        //   - "markdown" imports are *the* source type that most benefits
        //     from rendering — the user explicitly asked for markdown
        //     yet the pane refused to parse it.
        //   - A single long message flipped the entire transcript to
        //     plain, erasing formatting from every other short response
        //     in the conversation.
        // Per-message degradation (`MessageBubbleView.canRenderMessage`
        // falling back to a single paragraph when a single message
        // exceeds its cap) already handles the "don't parse monsters"
        // concern at the right granularity, so this helper no longer
        // forces plain by default. The user can still switch manually.
        return false
    }


    static func promptOutline(for detail: ConversationDetail) -> [ConversationPromptOutlineItem] {
        // Straight-line pass over user-authored messages. Earlier iterations
        // tried to color-code "topic shifts" here via a Jaccard similarity
        // heuristic over leading keywords; that was scrapped because it
        // was noisy for Japanese prompts (no token boundaries → every
        // prompt scored as a shift) and the color signal couldn't render
        // inside a native `NSMenu` anyway. Visual grouping is now done
        // with zebra-striped row backgrounds in the outline popover, so
        // the item itself doesn't need to carry any group metadata.
        // `index` counts user prompts only (1, 2, 3, ...) — not the
        // position in `detail.messages`, which interleaves assistant /
        // system messages and produced a jumpy "13, 15, 17, 19, …"
        // sequence in the outline popover. The header-bar counter
        // ("15 / 23") already uses user-only numbering, so keeping
        // the two in sync also avoids the mismatch where the popover
        // showed an index that didn't match the header.
        var items: [ConversationPromptOutlineItem] = []
        var userIndex = 0

        for message in detail.messages {
            guard message.isUser else { continue }
            userIndex += 1

            items.append(ConversationPromptOutlineItem(
                id: message.id,
                index: userIndex,
                label: promptLabel(from: message.content)
            ))
        }

        return items
    }

    // Pre-compiled once; `String.replacingOccurrences(options: .regularExpression)`
    // re-parses the pattern on every call, which adds up when building an
    // outline for a 100-prompt conversation.
    private static let whitespaceRegex: NSRegularExpression = {
        // Force-try is safe: the pattern is a compile-time constant.
        try! NSRegularExpression(pattern: "\\s+")
    }()

    private static func promptLabel(from text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        let collapsed = whitespaceRegex
            .stringByReplacingMatches(in: text, range: range, withTemplate: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !collapsed.isEmpty else {
            return "Untitled Prompt"
        }

        if collapsed.count <= 72 {
            return collapsed
        }

        let endIndex = collapsed.index(collapsed.startIndex, offsetBy: 72)
        return String(collapsed[..<endIndex]).trimmingCharacters(in: .whitespaces) + "…"
    }
}

struct ConversationPromptOutlineItem: Identifiable, Hashable {
    let id: String
    let index: Int
    let label: String
}

/// Named coordinate space shared by the reader's ScrollView and every
/// anchor-publisher underneath it (user-message top-Y observers, and —
/// from `MessageBubbleView` — per-block search anchors). The name is
/// module-internal rather than nested-private because the in-thread
/// finder needs `MessageBubbleView` to publish its block offsets into
/// the *same* preference key the reader's scroll logic reads from, so
/// the convergence loop in `performProgrammaticScroll` can tell when a
/// block-level jump has actually landed on target.
enum ReaderScrollCoordinateSpace {
    static let name: String = "conversation.reader"
}

private struct LoadedConversationDetailView: View {

    /// Top inset (points) below which a message is considered "current".
    /// Roughly matches the floating header bar's vertical footprint so
    /// the counter flips to the next prompt right as it appears from
    /// behind the header, not when it crests the raw viewport top.
    private static let currentPromptTopThreshold: CGFloat = 120

    /// Anchor id attached to the `ConversationHeaderView` so the
    /// ScrollViewReader can jump back to the very top of the body on
    /// demand. String literal rather than a derived id so the value is
    /// stable regardless of the underlying conversation.
    private static let topAnchorID: String = "__conversation_top__"

    @Binding var displayMode: ConversationDetailView.DetailDisplayMode
    @Binding var selectedPromptID: String?
    @Binding var requestedPromptID: String?
    @Binding var scrollToTopToken: UUID?
    let detail: ConversationDetail
    let showsSystemChrome: Bool

    /// Written whenever the scroll-position observer updates
    /// `selectedPromptID`. `.onChange(of: selectedPromptID)` consults
    /// this to decide whether the change came from the user tapping
    /// the outline (→ scroll to it) or from the user scrolling the
    /// body (→ do NOT programmatically scroll, which would fight the
    /// live gesture and create an infinite feedback loop).
    @State private var scrollDrivenSelection: String?

    /// Non-nil while a programmatic `proxy.scrollTo` animation is in
    /// flight. The scroll-position observer skips updates while this
    /// is set — without that guard, intermediate frames of the
    /// animation would pick up transient "current prompts" and
    /// flip-flop `selectedPromptID`, which cascades into the middle
    /// pane scroll-chattering as it tries to keep the highlighted row
    /// centered. A fresh UUID is minted per scroll and a dispatched
    /// task clears it after ~0.45s (0.20s animation + slack for the
    /// final preference emission to settle), so the lock is
    /// self-healing even if a scroll is interrupted.
    @State private var programmaticScrollLock: UUID?

    /// Cached copy of the most-recent `PromptTopYPreferenceKey`
    /// dictionary. `handlePromptOffsetChange` ignores it while a
    /// programmatic scroll is in flight, but `performProgrammaticScroll`
    /// needs to *read* it mid-scroll to tell whether the target row has
    /// actually landed at the anchor — that's what lets the convergence
    /// loop exit as soon as the measured top-Y is close to zero, instead
    /// of burning the full fixed timeout every time.
    @State private var latestPromptOffsets: [String: CGFloat] = [:]

    /// Height of the ScrollView's visible viewport, captured via a
    /// background GeometryReader on the scroll container. Paired with
    /// `latestPromptOffsets` it lets `performProgrammaticScroll` decide
    /// "is this block anchor already on-screen?" — the find bar's N/M
    /// stepping uses that check to skip a redundant scroll when the
    /// next match sits inside the currently-visible screenful, so
    /// stepping between nearby matches no longer yanks the viewport
    /// (user report: "毎回スクロールするより、画面外にハイライトが
    /// あったらジャンプするという挙動にできる？").
    @State private var readerViewportHeight: CGFloat = 0

    var body: some View {
        let detailBody = Group {
            if shouldUseDocumentViewer {
                DocumentConversationView(detail: detail)
            } else {
                ScrollViewReader { proxy in
                    VStack(spacing: 0) {
                        // Thread-title / metadata row lives INSIDE the
                        // scroll content (first element in the
                        // LazyVStack) rather than as a pinned
                        // `.safeAreaInset(edge: .top)` strip above the
                        // ScrollView. It used to be pinned so a frosted-
                        // glass chrome could blur scrolling content
                        // behind it, but the user asked to unpin the
                        // header so it scrolls away naturally with the
                        // rest of the conversation — no persistent
                        // strip at the top of the reader. The
                        // `VisualEffectBar` backing and the `.safeArea`
                        // plumbing went with it. Double-tap-to-top is
                        // also dropped: once the header scrolls away,
                        // there's nothing to double-tap, and the
                        // `scrollToTopToken` external binding still
                        // routes through the `Self.topAnchorID` that
                        // the header now carries inline.
                        ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            // Inline conversation header. Carries
                            // `Self.topAnchorID` so `proxy.scrollTo(
                            // topAnchorID)` call-sites (scroll-to-top
                            // token, external "jump to top" requests)
                            // still land at the header row — same
                            // anchor id the old invisible `Color.clear`
                            // placeholder used to carry when the header
                            // was a pinned safe-area inset.
                            ConversationHeaderView(summary: detail.summary)
                                .padding(.bottom, 16)
                                .id(Self.topAnchorID)

                            ForEach(Array(detail.messages.enumerated()), id: \.element.id) { index, message in
                                // Turn boundary: draw a divider BEFORE each
                                // user message (except the very first one
                                // in the conversation). A "turn" is a user
                                // prompt plus any assistant / tool messages
                                // that follow it, so the visual group stays
                                // together and the line only appears where
                                // a new question starts. Previously every
                                // message pair was separated, which made
                                // the reader feel choppy — Q and its A
                                // visually disconnected.
                                if index > 0 && message.isUser {
                                    Divider()
                                        .padding(.vertical, 12)
                                }

                                MessageBubbleView(
                                    message: message,
                                    displayMode: messageDisplayMode,
                                    identityContext: MessageIdentityContext(
                                        source: detail.summary.source,
                                        model: detail.summary.model
                                    )
                                )
                                .equatable()
                                .id(message.id)
                                .background(
                                    // User messages publish their top-edge y
                                    // coordinate into the ScrollView's named
                                    // coordinate space. Non-user messages
                                    // publish nothing, so the preference
                                    // dictionary stays user-only.
                                    Group {
                                        if message.isUser {
                                            GeometryReader { proxyGeo in
                                                Color.clear.preference(
                                                    key: PromptTopYPreferenceKey.self,
                                                    value: [
                                                        message.id: proxyGeo.frame(
                                                            in: .named(ReaderScrollCoordinateSpace.name)
                                                        ).minY
                                                    ]
                                                )
                                            }
                                        }
                                    }
                                )
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    guard message.isUser else {
                                        return
                                    }

                                    selectedPromptID = message.id
                                }

                                // Within-turn spacer between this message
                                // and the next one of the same turn. A
                                // plain vertical gap (no line) keeps Q → A
                                // visually paired. Skipped for the last
                                // message (no following sibling) and when
                                // the next message is a user prompt (the
                                // divider above handles that transition).
                                if index < detail.messages.count - 1,
                                   !detail.messages[index + 1].isUser {
                                    Spacer().frame(height: 8)
                                }
                            }
                        }
                        // Slightly wider horizontal gutters than the
                        // default 16pt so the reader text has a bit
                        // more breathing room against the pane edges;
                        // vertical padding stays at the default so the
                        // top/bottom fade masks still bite into
                        // content rather than blank margin.
                        .padding(.horizontal, 24)
                        .padding(.vertical, 16)
                    }
                    .coordinateSpace(name: ReaderScrollCoordinateSpace.name)
                    // Capture the ScrollView's visible height so the
                    // find-bar step logic can tell whether a block
                    // anchor's top-Y (read from `latestPromptOffsets`)
                    // falls inside the viewport. The GeometryReader
                    // sits in the background so it doesn't interfere
                    // with layout; its size mirrors the ScrollView's
                    // own frame.
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(
                                key: ReaderViewportSizePreferenceKey.self,
                                value: geo.size.height
                            )
                        }
                    )
                    .onPreferenceChange(ReaderViewportSizePreferenceKey.self) { h in
                        readerViewportHeight = h
                    }
                    .scrollContentBackground(.hidden)
                    // Reserve scroll-overshoot room at the bottom equal to
                    // the bottom-fade height. Without this the last line
                    // of the conversation stops at the fade's midpoint
                    // and reads as dimmed / unreadable; with it, the
                    // user can scroll the final line UP past the fade
                    // zone to read it at full opacity.
                    .contentMargins(
                        .bottom,
                        WorkspaceLayoutMetrics.bottomFadeHeight,
                        for: .scrollContent
                    )
                    .onPreferenceChange(PromptTopYPreferenceKey.self) { offsets in
                        // Defer the state write off the current layout pass.
                        // Writing `selectedPromptID` synchronously here would
                        // update the reader-pane outline pulldown in the
                        // same frame, which can shift `contentMargins` via
                        // the header-bar height preference and force the
                        // GeometryReaders below to re-publish — SwiftUI
                        // flags this as "preference updated multiple times
                        // per frame". `Task { @MainActor in … }` hops to
                        // the next runloop iteration, breaking the cycle.
                        Task { @MainActor in
                            // Always keep the cache fresh, even while
                            // programmaticScrollLock is held — the
                            // convergence loop reads it to decide when the
                            // target row has actually landed on the anchor.
                            latestPromptOffsets = offsets
                            handlePromptOffsetChange(offsets)
                        }
                    }
                    .onAppear {
                        // Only scroll on appear if the selection was set
                        // EXTERNALLY before mount (e.g. the pin pane
                        // requested a specific prompt via
                        // `ReaderTabManager.requestedPromptID`). A nil
                        // selection is a fresh open — leave the
                        // ScrollView at its natural top so the
                        // conversation header + any preface messages are
                        // visible. A selection that equals
                        // `scrollDrivenSelection` means the scroll-
                        // position observer already assigned it from the
                        // current viewport; scrolling again would jump
                        // to `.top` and push the header off-screen,
                        // which is exactly the bug this guard is here
                        // to prevent.
                        guard let selectedPromptID,
                              selectedPromptID != scrollDrivenSelection else {
                            return
                        }
                        scrollToSelectedPrompt(using: proxy, animated: false)
                    }
                    .onChange(of: selectedPromptID) { _, newValue in
                        // Skip scrolling if this update came from the
                        // scroll observer — the view is already at the
                        // right position, and re-entering scrollTo mid-
                        // gesture produces jitter.
                        if newValue == scrollDrivenSelection {
                            return
                        }
                        // Non-scroll-driven change (keyboard arrow key,
                        // outline popover selection): animate to the
                        // new target, holding the programmatic lock so
                        // the scroll-position observer doesn't
                        // re-write `selectedPromptID` to transient
                        // mid-animation prompts.
                        performProgrammaticScroll(to: newValue, using: proxy)
                    }
                    // Direct one-shot scroll request from outside the
                    // pane (middle-pane Viewer-Mode row tap, or any
                    // future imperative "jump to prompt X" call site).
                    // Kept as a SEPARATE signal from `selectedPromptID`
                    // because `selectedPromptID` dedupes on equality —
                    // tapping the prompt you're currently reading
                    // would otherwise be silently swallowed (→
                    // "戻れなかった" bug). Routing through a dedicated
                    // nil-after-fire token guarantees re-triggering
                    // even for the same target.
                    .onChange(of: requestedPromptID) { _, newID in
                        guard let newID else { return }
                        // Pre-seed `scrollDrivenSelection` so the
                        // `selectedPromptID` write below is treated
                        // as an "already-at-position" no-op by the
                        // sibling `.onChange` handler. Without this
                        // we'd scroll twice (once here, once from the
                        // re-entrant change notification).
                        scrollDrivenSelection = newID
                        selectedPromptID = newID
                        performProgrammaticScroll(to: newID, using: proxy)
                        // Clear the one-shot on the next runloop tick
                        // so the change notification for "X → nil"
                        // doesn't race with our own scroll work.
                        Task { @MainActor in
                            requestedPromptID = nil
                        }
                    }
                    // Scroll-to-top one-shot: fired by the right-pane
                    // header's conversation-title button. Clears the
                    // prompt selection first so `scrollToSelectedPrompt`
                    // doesn't yank us back to a mid-body position on
                    // the next layout pass, then scrolls the
                    // `ConversationHeaderView` anchor back to the
                    // viewport top. Token is cleared afterwards so the
                    // next tap reassigns and re-triggers this handler.
                    .onChange(of: scrollToTopToken) { _, newValue in
                        guard newValue != nil else { return }
                        performScrollToTop(using: proxy)
                        // Clear so consecutive taps with the same
                        // trivial outcome still fire a change event.
                        Task { @MainActor in
                            scrollToTopToken = nil
                        }
                    }
                    // Header used to live here as a pinned
                    // `.safeAreaInset(edge: .top)` with a
                    // `VisualEffectBar` frosted-glass backing. The
                    // user asked to unpin it, so the header moved
                    // inline into the LazyVStack above — it now
                    // scrolls with the conversation body like any
                    // other row, and there's no fixed strip at the
                    // top of the reader.
                    }
                }
            }
        }
        if showsSystemChrome {
            detailBody
                .navigationTitle(detail.summary.title ?? "Untitled")
                .toolbar {
                    if shouldPreferPlainDisplay {
                        ToolbarItem {
                            Menu(effectiveDisplayMode.rawValue) {
                                Button("Rendered") {
                                    displayMode = .rendered
                                }
                                Button("Plain") {
                                    displayMode = .plain
                                }
                            }
                        }
                    }

                    DetailExportToolbar(detail: detail)
                }
        } else {
            detailBody
        }
    }

    private var shouldPreferPlainDisplay: Bool {
        ConversationDetailView.shouldPreferPlainDisplay(for: detail)
    }

    private var shouldUseDocumentViewer: Bool {
        effectiveDisplayMode == .plain
            && detail.messages.count == 1
            && shouldPreferPlainDisplay
    }

    private var messageDisplayMode: MessageBubbleView.DisplayMode {
        switch effectiveDisplayMode {
        case .rendered:
            return .rendered
        case .plain:
            return .plain
        }
    }

    private var effectiveDisplayMode: ConversationDetailView.DetailDisplayMode {
        displayMode
    }

    private func scrollToSelectedPrompt(
        using proxy: ScrollViewProxy,
        animated: Bool
    ) {
        guard let selectedPromptID else {
            return
        }

        let action = {
            proxy.scrollTo(selectedPromptID, anchor: .top)
        }

        if animated {
            withAnimation(.easeInOut(duration: 0.2), action)
        } else {
            action()
        }
    }

    /// Instant programmatic jump to the requested id, driven by a
    /// measurement-based convergence loop.
    ///
    /// **Why not just call `proxy.scrollTo` once?** The reader body is a
    /// `LazyVStack`, so messages below the viewport haven't been
    /// materialised. `proxy.scrollTo(id, anchor: .top)` estimates the
    /// target's offset from the currently-known row heights — usually
    /// wrong for distant jumps, so the first scroll lands close but not
    /// on target. Worse, on *long* conversations a fixed-iteration
    /// retry (what we used to do: three calls at 0ms / 16ms / 120ms)
    /// still hadn't converged by the time the lock released, so the
    /// user report "離れた場所にジャンプする時かなり遅くなるし反応
    /// しないことが多い" matched the observed behavior — the last
    /// scrollTo fired before the LazyVStack had materialised the
    /// region, and the viewport stayed parked near the initial estimate.
    ///
    /// The fix is to *measure* where the target actually lands after
    /// each scroll (via the `PromptTopYPreferenceKey` cache populated
    /// by the same GeometryReaders that feed the scroll-position
    /// observer) and exit the loop the frame we see the target's
    /// measured top-Y within a couple of points of the anchor (0pt,
    /// because `anchor: .top` means the row's top should sit at the
    /// viewport top). For nearby jumps this converges in 1–2
    /// iterations; for distant jumps it keeps firing `scrollTo` at
    /// ~16ms cadence until the LazyVStack has materialised the target
    /// and the scroll offset settles.
    ///
    /// Total budget is capped at ~480ms (30 frames at 16ms) so a
    /// pathological case — e.g. a target id that never appears in the
    /// offset dictionary because the conversation list changed under us
    /// — can't hang the lock forever. The scroll-position observer is
    /// gated out for the duration so intermediate frames don't
    /// overwrite `selectedPromptID` with a transient "current prompt".
    private func performProgrammaticScroll(
        to id: String?,
        using proxy: ScrollViewProxy
    ) {
        guard let id else { return }
        // Find-bar shortcut: if the caller is targeting a search-block
        // anchor whose top-Y falls inside the currently-visible
        // viewport, the match is already on-screen. Skip the scroll
        // entirely so the find bar's Next/Prev just updates the orange
        // cursor in place — user complained about the "毎回スクロール
        // するより、画面外にハイライトがあったらジャンプする" feel
        // when walking matches inside one screenful of content. Only
        // gated on the block-anchor prefix so prompt-outline taps
        // (which the user explicitly selected and expects to land at
        // the anchor top) keep their old behaviour.
        if shouldSkipScrollForVisibleSearchAnchor(id) {
            return
        }
        let token = UUID()
        programmaticScrollLock = token
        // Pre-materialization for distant block-anchor jumps.
        //
        // A block anchor lives on a nested `ForEach` `.id(...)` inside
        // a bubble. When the owning bubble hasn't been materialized by
        // the outer LazyVStack — common when jumping into a long
        // assistant reply that's currently off-screen —
        // `proxy.scrollTo(anchorID)` can no-op because the nested id
        // isn't reachable from the proxy until the parent row exists.
        // Detect this by the anchor's absence from the offset cache
        // (an on-screen or adjacent block would have published its
        // top-Y via `PromptTopYPreferenceKey` already) and do a
        // one-shot `scrollTo` on the parent message id first so
        // LazyVStack instantiates the bubble and its inner ids. The
        // convergence loop below then refines onto the precise block.
        //
        // This materialization step used to live on the caller side
        // (`DesignMockReaderPaneContent.performTwoStageJump`), but it
        // fired unconditionally for every cross-message step — so
        // stepping between two matches whose messages were both
        // visible still scrolled the next message's top to the
        // viewport top, exactly the "画面外にハイライトがあったら
        // ジャンプする" feel the user wanted to avoid. Gating it on
        // the offset-cache miss means we only pay the materialization
        // scroll when the bubble genuinely isn't rendered yet.
        if id.hasPrefix(SearchBlockAnchor.idPrefix),
           latestPromptOffsets[id] == nil,
           let messageID = Self.parentMessageID(ofBlockAnchor: id) {
            proxy.scrollTo(messageID, anchor: .top)
        }
        // Fire the first scroll synchronously so the viewport starts
        // moving in the same frame as the user gesture — avoids the
        // "click did nothing" feeling if the loop's first await slips
        // past a display refresh.
        proxy.scrollTo(id, anchor: .top)
        Task { @MainActor in
            // Tolerances:
            //   convergedPx — how close the measured top-Y must get to
            //     0 before we consider the row "on the anchor". A
            //     couple of points absorbs sub-pixel rounding without
            //     accepting a visibly-off result.
            //   stableDeltaPx — if the measurement didn't move more
            //     than this between two consecutive frames, layout has
            //     settled and we can exit even if we aren't quite at 0
            //     (e.g. the target is the very last message and the
            //     scrollview's contentMargins prevent it from reaching
            //     the top).
            let convergedPx: CGFloat = 2
            let stableDeltaPx: CGFloat = 0.5
            let frameNanos: UInt64 = 16_000_000
            let maxIterations = 30

            var previousY: CGFloat? = nil
            for iteration in 0..<maxIterations {
                try? await Task.sleep(nanoseconds: frameNanos)
                guard programmaticScrollLock == token else { return }

                if let y = latestPromptOffsets[id] {
                    // Close enough to the anchor → done.
                    if abs(y) <= convergedPx { break }
                    // Layout has stopped moving but we aren't at 0.
                    // This happens when the target can't physically
                    // reach the top (bottom bumper against
                    // contentMargins). Ship the current position
                    // instead of looping until the timeout.
                    if let prev = previousY,
                       abs(y - prev) <= stableDeltaPx,
                       iteration >= 2 {
                        break
                    }
                    previousY = y
                }
                // Either we don't have a measurement yet (target not
                // materialised) or we're still approaching it. Re-fire
                // with the now-fresher height map.
                proxy.scrollTo(id, anchor: .top)
            }

            // Brief settle window before releasing the lock so the
            // trailing batch of preference emissions the convergence
            // kicked off doesn't race the observer into reassigning
            // selection to a neighbouring prompt mid-reflow.
            try? await Task.sleep(nanoseconds: 60_000_000)
            if programmaticScrollLock == token {
                programmaticScrollLock = nil
            }
        }
    }

    /// Extract the owning message id from a block anchor string.
    /// Block anchors have the form `"__mb-search-{messageID}#{index}"`
    /// (see `MessageBubbleView.searchBlockAnchorID`). Returns nil for
    /// strings that don't match the expected shape — the caller treats
    /// that as "no pre-materialization needed" and lets the
    /// convergence loop work with the id as-is.
    private static func parentMessageID(ofBlockAnchor id: String) -> String? {
        guard id.hasPrefix(SearchBlockAnchor.idPrefix) else { return nil }
        let tail = id.dropFirst(SearchBlockAnchor.idPrefix.count)
        guard let hashIdx = tail.firstIndex(of: "#") else { return nil }
        let messageID = tail[..<hashIdx]
        return messageID.isEmpty ? nil : String(messageID)
    }

    /// `true` when `id` refers to a find-bar block anchor AND that
    /// anchor's top is currently inside the reader's visible viewport.
    /// The caller uses this to skip a redundant scroll when stepping
    /// between matches that share a screenful of content.
    ///
    /// Gated on the `SearchBlockAnchor.idPrefix` so only find-bar
    /// targets get the "don't scroll if already visible" treatment —
    /// prompt-outline anchors (user explicitly asked to jump there)
    /// still scroll to `.top` unconditionally.
    ///
    /// Visibility window is `[0, viewportHeight - bottomFadeHeight]`:
    /// - `0` as the top bound means "block top is NOT scrolled above
    ///   the visible top"; if it were, the block's interior (where the
    ///   match likely lives) could easily be off-screen, so we scroll.
    /// - `viewportHeight - bottomFadeHeight` as the bottom bound keeps
    ///   a block that's only peeking in under the bottom fade from
    ///   counting as "visible enough" — the match sitting deeper
    ///   inside the block would still be below the fade.
    ///
    /// Approximate by design: we only have block TOP-Y, not the match
    /// position or the block's height. For most replies the match
    /// falls within a screenful of the block top, so this is a good
    /// trade-off against the cost of threading per-match geometry
    /// through to the find bar.
    private func shouldSkipScrollForVisibleSearchAnchor(_ id: String) -> Bool {
        guard id.hasPrefix(SearchBlockAnchor.idPrefix) else { return false }
        guard readerViewportHeight > 0 else { return false }
        guard let y = latestPromptOffsets[id] else { return false }
        let topBound: CGFloat = 0
        let bottomBound: CGFloat = readerViewportHeight
            - WorkspaceLayoutMetrics.bottomFadeHeight
        return y >= topBound && y <= bottomBound
    }

    /// Scroll the body back to `Self.topAnchorID`. Shared by the
    /// external `scrollToTopToken` binding (outline popover, future
    /// imperative callers) and the internal double-click-on-pinned-
    /// header gesture. Clears the prompt selection first so
    /// `scrollToSelectedPrompt` doesn't yank the viewport back to a
    /// mid-body position on the next layout pass, then holds the
    /// programmatic-scroll lock while the animation runs so the
    /// scroll-position observer can't repopulate `selectedPromptID`
    /// with the first prompt crossing the threshold mid-flight.
    private func performScrollToTop(using proxy: ScrollViewProxy) {
        let token = UUID()
        programmaticScrollLock = token
        scrollDrivenSelection = nil
        selectedPromptID = nil
        // Jump rather than animated scroll — matches the lighter,
        // snappier feel the user asked for on prompt navigation
        // ("スクロールより、ジャンプして欲しい。動作が軽い方がいい"). On
        // long conversations a 0.2s animated scroll back to the top
        // could traverse several screens of content and read as
        // laggy.
        proxy.scrollTo(Self.topAnchorID, anchor: .top)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            if programmaticScrollLock == token {
                programmaticScrollLock = nil
            }
        }
    }

    /// Given each user-message's top-edge y coordinate inside the
    /// ScrollView, pick the one currently occupying the "current prompt"
    /// slot and, if different from the current selection, propagate it
    /// upward as a scroll-driven change.
    ///
    /// The rule is: among messages whose top has already crossed the
    /// header-bar threshold (minY ≤ threshold), take the one with the
    /// LARGEST minY — i.e. the latest prompt that has scrolled into
    /// active reading position. If none have crossed yet (we're above
    /// the first prompt), fall back to the first outline entry so the
    /// counter reads "1 / N" instead of blank.
    private func handlePromptOffsetChange(_ offsets: [String: CGFloat]) {
        guard !offsets.isEmpty else { return }
        // Suppress updates while a programmatic scroll is running —
        // mid-animation frames otherwise pick intermediate prompts as
        // "current" and flip-flop `selectedPromptID`, making the
        // middle-pane highlighted row chatter between values. The
        // lock auto-releases ~0.45s after the scroll kicks off, at
        // which point the final resting position lands a single
        // clean observer fire.
        guard programmaticScrollLock == nil else { return }

        // The preference dictionary is shared with the in-thread search
        // infrastructure: `MessageBubbleView` publishes one entry per
        // rendered block inside an assistant reply so
        // `performProgrammaticScroll` can measure per-block jumps.
        // Those anchors are NOT prompt boundaries — they sit below the
        // owning user message — so let them through to the outline
        // cursor logic would flip the "current prompt" readout to
        // mid-reply block anchors as the user scrolls. Filter by the
        // shared `SearchBlockAnchor.idPrefix` so only bona-fide prompt
        // ids compete for the current-prompt slot.
        let promptOffsets = offsets.filter {
            !$0.key.hasPrefix(SearchBlockAnchor.idPrefix)
        }
        guard !promptOffsets.isEmpty else { return }
        let threshold = Self.currentPromptTopThreshold
        let crossed = promptOffsets.filter { $0.value <= threshold }

        let candidate: String?
        if let top = crossed.max(by: { $0.value < $1.value })?.key {
            candidate = top
        } else {
            // Haven't scrolled past the first prompt yet — default to
            // the earliest message (smallest minY).
            candidate = promptOffsets.min(by: { $0.value < $1.value })?.key
        }

        guard let candidate else { return }
        // Compare against `scrollDrivenSelection` (real @State) rather
        // than `selectedPromptID` (the outgoing `@Binding`). Call sites
        // that don't care about the scroll-driven selection pass
        // `selectedPromptID: nil` into `ConversationDetailView`, which
        // resolves to `.constant(nil)` internally — a sink that swallows
        // writes. Against a .constant sink the old guard became
        // `candidate != nil`, which is ALWAYS true for a non-empty
        // viewport, so every preference emission wrote state and kicked
        // off a re-evaluation pass. During scroll that produced visible
        // chatter (user report: "右ペインを上にスクロールしたときの挙動が変。
        // チャタリングしてるように見える"), worst on upward scroll where
        // `LazyVStack` pays extra instantiating rows returning to the
        // viewport. Keying the dedup off our own @State means the guard
        // stays honest regardless of what the caller supplied.
        guard candidate != scrollDrivenSelection else { return }

        scrollDrivenSelection = candidate
        selectedPromptID = candidate
    }
}

/// Per-anchor top-edge y coordinate in the ScrollView's coordinate
/// space. Two kinds of keys live in this dictionary:
///
/// - **User-message ids** (e.g. `"msg-123"`): published by the
///   observers in `LoadedConversationDetailView` and consumed by the
///   outline cursor in `handlePromptOffsetChange`. The outline logic
///   filters block-level ids out so a per-block offset can't be
///   mistaken for a prompt boundary.
///
/// - **Block-level search anchors** (prefixed with
///   `"__mb-search-"`, see
///   `MessageBubbleView.searchBlockAnchorID(messageID:blockIndex:)`):
///   published by `MessageBubbleView` for every rendered block inside
///   an assistant reply, so `performProgrammaticScroll` can measure
///   whether an in-thread-search block jump has actually landed on
///   target, instead of burning its whole timeout on a distant one-
///   shot `proxy.scrollTo` that an under-materialised LazyVStack
///   answered with a stale estimate.
///
/// Merge is a plain dictionary overwrite because anchor ids are unique
/// across the reader body — the last emission from a GeometryReader is
/// always the authoritative current position.
internal struct PromptTopYPreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]

    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// Shared id prefix for `MessageBubbleView`-published block scroll
/// anchors. Used both at the publishing site (building the id) and at
/// the consuming site (`handlePromptOffsetChange` filters by this
/// prefix so block anchors never compete with user-prompt anchors for
/// the outline cursor slot).
internal enum SearchBlockAnchor {
    static let idPrefix: String = "__mb-search-"
}

/// Published by a background `GeometryReader` on the reader ScrollView
/// so the detail view can cache the current viewport height. Used by
/// `performProgrammaticScroll` to decide whether a find-bar block
/// anchor is already on-screen (and therefore the step can skip its
/// scroll, leaving the viewport alone and letting the orange cursor
/// repaint in place).
private struct ReaderViewportSizePreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        // Last emission wins — the ScrollView only publishes one value
        // at a time, so the "newer" reading is always authoritative.
        value = nextValue()
    }
}

private struct DocumentConversationView: View {
    private enum Layout {
        static let avatarSize: CGFloat = 30
        static let avatarColumnWidth: CGFloat = 38
    }

    let detail: ConversationDetail
    @Environment(IdentityPreferencesStore.self) private var identityPreferences

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ConversationHeaderView(summary: detail.summary)
                .padding(.horizontal)
                .padding(.top)

            if let message = detail.messages.first {
                HStack(alignment: .top, spacing: 10) {
                    if message.isUser {
                        Spacer()

                        Text(identityPresentation(for: message).displayName)
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(identityPresentation(for: message).accentColor)

                        IdentityAvatarView(
                            presentation: identityPresentation(for: message),
                            size: Layout.avatarSize
                        )
                        .frame(width: Layout.avatarColumnWidth, alignment: .topTrailing)
                    } else {
                        IdentityAvatarView(
                            presentation: identityPresentation(for: message),
                            size: Layout.avatarSize
                        )
                        .frame(width: Layout.avatarColumnWidth, alignment: .topLeading)

                        Text(identityPresentation(for: message).displayName)
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(identityPresentation(for: message).accentColor)

                        Spacer()
                    }
                }
                .padding(.horizontal)

                ReadOnlyTextDocumentView(text: message.content)
                    .padding(.leading, message.isUser ? 16 : Layout.avatarColumnWidth + 10)
                    .padding(.trailing, message.isUser ? Layout.avatarColumnWidth + 10 : 16)
                    .padding(.bottom)
            }
        }
    }

    private func identityPresentation(for message: Message) -> MessageIdentityPresentation {
        identityPreferences.presentation(
            for: message.role,
            context: MessageIdentityContext(
                source: detail.summary.source,
                model: detail.summary.model
            )
        )
    }
}

private struct ConversationHeaderView: View {
    let summary: ConversationSummary
    /// Fired on double-click (and tap-twice on iPadOS) when the caller
    /// wants the row to double as a "back to top" affordance. `nil`
    /// means "decorative header only, don't attach the gesture" — used
    /// by layout paths that keep this view inline inside the scroll
    /// content (where a double-tap-to-top gesture would be surprising
    /// because the header is already at the top). The pinned-above-
    /// the-ScrollView rendering passes a live closure that fires the
    /// ScrollViewReader's top-anchor jump.
    var onDoubleTapToTop: (() -> Void)? = nil

    var body: some View {
        // Two layouts. `ViewThatFits` picks horizontal when the pane
        // is wide enough to carry the title + pill + date on one
        // line without compressing any of them, and falls through to
        // a vertical stack otherwise so the pill and date wrap onto
        // a second row instead of getting clipped off-screen.
        //
        // The wide candidate declares an explicit `minWidth` to make
        // `ViewThatFits` reject it once the pane drops below that
        // threshold — without it, the HStack happily shrinks forever
        // (title truncates down to an ellipsis) because SwiftUI
        // considers a truncated text "fitting." The minWidth is
        // tuned against typical title lengths: below ~480pt, the
        // title has to truncate so aggressively that the vertical
        // layout becomes the better read.
        ViewThatFits(in: .horizontal) {
            horizontalLayout
                .frame(minWidth: 480)
            verticalLayout
        }
        .padding(.horizontal, 4)
        // Hit-test the whole row (including the Spacer) so a
        // double-click anywhere in the pinned header — not just on
        // the title text — registers as "jump to top". Without
        // `contentShape` the gap between the title and the pill
        // would be dead space.
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            onDoubleTapToTop?()
        }
    }

    /// Wide layout: title / pill / date on one line. Title gets
    /// `layoutPriority(1)` + `Spacer()` push so it absorbs available
    /// width without shoving the metadata off-screen; truncation
    /// happens on the title first, which is the right default (the
    /// metadata is always short — a pill plus a formatted date —
    /// and is what the user scans to identify the thread at a
    /// glance). `textSelection(.enabled)` so the title is
    /// copy-paste-friendly.
    private var horizontalLayout: some View {
        HStack(spacing: 8) {
            titleText
                .layoutPriority(1)

            Spacer(minLength: 8)

            // Source-origin pill sits immediately to the LEFT of the
            // date timestamp so the eye doesn't have to traverse the
            // full pane width to find it. The tag editor that used
            // to sit alongside was retired when tags were dropped
            // from the UI.
            sourcePill

            if let time = summary.primaryTime {
                Text(time)
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// Narrow layout: title on line 1, pill + date on line 2. Keeps
    /// the same information density but trades horizontal space for
    /// vertical so nothing has to truncate or clip. Pill sits first
    /// on the metadata row so the source-origin affordance (click
    /// to open raw data) stays visible even when the pane is very
    /// narrow.
    private var verticalLayout: some View {
        VStack(alignment: .leading, spacing: 4) {
            titleText

            HStack(spacing: 8) {
                sourcePill

                if let time = summary.primaryTime {
                    Text(time)
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var titleText: some View {
        Text(summary.title ?? "Untitled")
            .font(.callout.weight(.semibold))
            .lineLimit(1)
            .truncationMode(.tail)
            .foregroundStyle(.primary)
            .textSelection(.enabled)
    }

    private var sourcePill: some View {
        SourceOriginPill(
            conversationID: summary.id,
            source: summary.source,
            model: summary.model
        )
    }

}

private struct DetailExportToolbar: ToolbarContent {
    let detail: ConversationDetail

    var body: some ToolbarContent {
        ToolbarItem {
            ConversationShareButton(detail: detail)
        }
    }
}

/// Toolbar share control. Presents a `Menu` with three export paths —
/// Markdown share, LLM-friendly plain-text share, and a clipboard
/// shortcut — all driven by the shared `conversationShareMenuItems`
/// builder so the reader-detail, Viewer-Mode, and Design Mock
/// toolbars offer the same set of options.
///
/// Each `ShareLink` inside the menu hands a file URL (under
/// `<tmp>/madini-share/<conversation-id>/`) to the native share
/// sheet — AirDrop, Mail, Messages, Notes, Save to Files / Finder,
/// Copy, and any third-party share extensions. Using file URLs
/// (instead of raw strings) is what unlocks the full
/// `NSSharingServicePicker` menu on macOS / `UIActivityViewController`
/// on iOS, and also gives each destination a title-based filename.
///
/// Both export files are regenerated whenever the bound conversation
/// changes (`.task(id: detail.summary.id)`) so stale content is
/// never shared.
private struct ConversationShareButton: View {
    let detail: ConversationDetail

    @State private var markdownURL: URL?
    @State private var plainTextURL: URL?

    var body: some View {
        Menu {
            conversationShareMenuItems(
                detail: detail,
                markdownURL: markdownURL,
                plainTextURL: plainTextURL
            )
        } label: {
            Image(systemName: "square.and.arrow.up")
        }
        .menuIndicator(.hidden)
        .help("Share conversation")
        .task(id: detail.summary.id) {
            let urls = await prepareConversationShareURLs(for: detail)
            markdownURL = urls.markdown
            plainTextURL = urls.plainText
        }
    }
}

enum MarkdownExporter {
    static func export(_ detail: ConversationDetail) -> String {
        var lines: [String] = []

        lines.append("# \(detail.summary.title ?? "Untitled")")
        lines.append("")

        var metadata: [String] = []
        if let source = detail.summary.source {
            metadata.append("Source: \(source)")
        }
        if let model = detail.summary.model {
            metadata.append("Model: \(model)")
        }
        if let time = detail.summary.primaryTime {
            metadata.append("Date: \(time)")
        }

        if !metadata.isEmpty {
            lines.append(metadata.joined(separator: " | "))
            lines.append("")
            lines.append("---")
            lines.append("")
        }

        for message in detail.messages {
            lines.append("### \(message.isUser ? "**User**" : "**\(message.role.rawValue.capitalized)**")")
            lines.append("")
            lines.append(message.content)
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    /// Materialize the conversation as a Markdown file in a stable temp
    /// location so it can be handed to `ShareLink(item: url)` — the URL
    /// form is what unlocks the full `NSSharingServicePicker` menu
    /// (AirDrop, Mail, Messages, Notes, Save to Files, extensions…) on
    /// both macOS and iOS. Shared by the detail-pane toolbar button and
    /// the floating Viewer-Mode export chip so the two affordances are
    /// behaviorally identical.
    static func writeTempShareFile(for detail: ConversationDetail) async -> URL? {
        let markdown = export(detail)
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("madini-share", isDirectory: true)
            .appendingPathComponent(detail.summary.id, isDirectory: true)
        let filename = sanitizeShareFilename(detail.summary.title ?? "conversation") + ".md"
        let url = base.appendingPathComponent(filename)
        do {
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            try markdown.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    private static func sanitizeShareFilename(_ name: String) -> String {
        let illegal = CharacterSet(charactersIn: "/:\\")
        let cleaned = name.components(separatedBy: illegal).joined(separator: "_")
        return cleaned.isEmpty ? "conversation" : cleaned
    }

    /// Shared with the LLM-oriented plain-text exporter so the two
    /// share paths produce identically-named sibling files inside the
    /// per-conversation temp directory.
    fileprivate static func shareTempDirectory(for detail: ConversationDetail) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("madini-share", isDirectory: true)
            .appendingPathComponent(detail.summary.id, isDirectory: true)
    }

    fileprivate static func sanitizedBaseName(for detail: ConversationDetail) -> String {
        sanitizeShareFilename(detail.summary.title ?? "conversation")
    }
}

/// LLM-oriented plain-text export.
///
/// The markdown exporter is optimized for humans reading the file in
/// Notes / Mail — it uses `###` headings and `**bold**` for role
/// labels. That decoration gets in the way when the file is pasted
/// into an LLM prompt: some models re-interpret the `**` emphasis or
/// blend the role label into the user's actual message content.
///
/// This exporter strips those conventions and produces a format tuned
/// for pasting into a ChatGPT/Claude/etc. chat box:
///
/// ```
/// Title: ...
/// Source: ChatGPT | Model: gpt-5 | Date: 2026-01-15
///
/// ===== User =====
///
/// <message body, verbatim>
///
/// ===== Assistant =====
///
/// <message body, verbatim>
/// ```
///
/// Rules:
///   * Role delimiter is a distinctive `===== Role =====` line with
///     blank lines on both sides. Easy for a model to recognize as a
///     turn boundary without eating the surrounding content.
///   * Message bodies are left completely untouched — in particular
///     fenced code blocks (``` ... ```) stay intact, so the LLM still
///     sees the original syntactic structure.
///   * No leading/trailing role-label decoration characters (`#`,
///     `**`, etc.) — the model reads the label as plain English.
///
/// This is used both by the `.txt`-file share option and by the
/// "Copy as LLM Prompt" menu item (`LLMPromptClipboard`), which
/// re-uses `export(_:)` to fill the pasteboard.
enum PlainTextExporter {
    static func export(_ detail: ConversationDetail) -> String {
        var lines: [String] = []

        if let title = detail.summary.title {
            lines.append("Title: \(title)")
        }

        var metadata: [String] = []
        if let source = detail.summary.source {
            metadata.append("Source: \(source)")
        }
        if let model = detail.summary.model {
            metadata.append("Model: \(model)")
        }
        if let time = detail.summary.primaryTime {
            metadata.append("Date: \(time)")
        }
        if !metadata.isEmpty {
            lines.append(metadata.joined(separator: " | "))
        }

        // Separator between the header block and the first message.
        // `joined(separator: "\n")` at the end collapses adjacent
        // empty strings into the blank lines we want.
        if !lines.isEmpty {
            lines.append("")
        }

        for message in detail.messages {
            let roleLabel = message.isUser
                ? "User"
                : message.role.rawValue.capitalized
            lines.append("===== \(roleLabel) =====")
            lines.append("")
            lines.append(message.content)
            lines.append("")
        }

        // Trim trailing blank line so there's no dangling newline at
        // end-of-file — cleaner paste target.
        while lines.last == "" {
            lines.removeLast()
        }

        return lines.joined(separator: "\n") + "\n"
    }

    /// Sibling to `MarkdownExporter.writeTempShareFile(for:)`. Writes
    /// the LLM-oriented plain-text form under the same per-
    /// conversation temp directory with a `.txt` extension so the
    /// share sheet's file picker shows a sensible filename.
    static func writeTempShareFile(for detail: ConversationDetail) async -> URL? {
        let text = export(detail)
        let base = MarkdownExporter.shareTempDirectory(for: detail)
        let filename = MarkdownExporter.sanitizedBaseName(for: detail) + ".txt"
        let url = base.appendingPathComponent(filename)
        do {
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }
}

/// Puts the LLM-oriented plain-text form of a conversation on the
/// system clipboard so the user can paste it straight into a chat
/// box without a file-sharing round-trip.
///
/// Kept as its own namespace (rather than a method on
/// `PlainTextExporter`) because the platform pasteboard APIs differ
/// between macOS (`NSPasteboard`) and iOS (`UIPasteboard`) and we
/// don't want the exporter — which is pure, testable string work —
/// to carry a UIKit/AppKit dependency.
enum LLMPromptClipboard {
    @MainActor
    static func copy(_ detail: ConversationDetail) {
        let text = PlainTextExporter.export(detail)
        #if os(macOS)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        #elseif canImport(UIKit)
        UIPasteboard.general.string = text
        #endif
    }
}

/// Menu contents shared by every toolbar "share" button in the app
/// (reader detail, Viewer-Mode floating chip, Design Mock top
/// toolbar). Centralising it here guarantees the three share
/// affordances offer an identical set of export formats and identical
/// labels — the previous per-site implementations had already drifted
/// in subtle ways (different help text, different preview icons).
///
/// Each caller owns its own `@State` for the two temp-file URLs and
/// writes them in a `.task(id:)` via
/// `prepareConversationShareURLs(for:)`, then hands them and the
/// `ConversationDetail` to this builder. The builder renders:
///
///   1. `ShareLink` for the Markdown export (human-friendly, retains
///      `###` role headings and metadata block).
///   2. `ShareLink` for the plain-text export (LLM-friendly; see
///      `PlainTextExporter` docs).
///   3. A `Button` that copies the plain-text form to the clipboard
///      — for the common case of pasting straight into a chat box.
///
/// Each `ShareLink` gracefully degrades to a disabled placeholder
/// while its temp file is being written, keeping the menu present
/// (so the surrounding button layout doesn't jump) but preventing a
/// click on an incomplete export.
@ViewBuilder
func conversationShareMenuItems(
    detail: ConversationDetail?,
    markdownURL: URL?,
    plainTextURL: URL?
) -> some View {
    if let detail {
        let previewTitle = detail.summary.title ?? "Conversation"
        if let markdownURL {
            ShareLink(
                item: markdownURL,
                preview: SharePreview(
                    previewTitle,
                    image: Image(systemName: "doc.text")
                )
            ) {
                Label("Markdown (.md) として共有…", systemImage: "doc.text")
            }
        } else {
            Button {} label: {
                Label("Markdown を書き出し中…", systemImage: "doc.text")
            }
            .disabled(true)
        }
        if let plainTextURL {
            ShareLink(
                item: plainTextURL,
                preview: SharePreview(
                    previewTitle,
                    image: Image(systemName: "text.alignleft")
                )
            ) {
                Label("プレーンテキスト (.txt) として共有… — LLM 向け",
                      systemImage: "text.alignleft")
            }
        } else {
            Button {} label: {
                Label("プレーンテキストを書き出し中…", systemImage: "text.alignleft")
            }
            .disabled(true)
        }
        Divider()
        Button {
            LLMPromptClipboard.copy(detail)
        } label: {
            Label("LLM プロンプトとしてコピー",
                  systemImage: "doc.on.clipboard")
        }
    } else {
        // No conversation selected — show a single disabled row so
        // the menu isn't empty when the user opens it by accident.
        Button {} label: {
            Label("会話が選択されていません", systemImage: "square.and.arrow.up")
        }
        .disabled(true)
    }
}

/// Kick off markdown and plain-text exports in parallel for the given
/// conversation and return both URLs. Used by every site that hosts
/// the share menu — each one calls this inside a `.task(id:)` keyed
/// on the conversation id so the exports re-run whenever the
/// selection changes.
func prepareConversationShareURLs(
    for detail: ConversationDetail
) async -> (markdown: URL?, plainText: URL?) {
    async let markdown = MarkdownExporter.writeTempShareFile(for: detail)
    async let plainText = PlainTextExporter.writeTempShareFile(for: detail)
    return await (markdown, plainText)
}
