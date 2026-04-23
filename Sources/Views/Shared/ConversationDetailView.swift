import SwiftUI
#if os(macOS)
import AppKit
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

private struct LoadedConversationDetailView: View {
    private enum ScrollCoordinateSpace: Hashable {
        case conversation
    }

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

    /// Internal one-shot that fires when the pinned header row is
    /// double-clicked. Unlike `scrollToTopToken` (which is an external
    /// `@Binding` — `.constant(nil)` in call sites that don't care,
    /// silently dropping writes), this is live @State so a double-tap
    /// always round-trips through the `.onChange` handler below.
    @State private var internalScrollToTopToken: UUID?

    var body: some View {
        let detailBody = Group {
            if shouldUseDocumentViewer {
                DocumentConversationView(detail: detail)
            } else {
                ScrollViewReader { proxy in
                    VStack(spacing: 0) {
                        // Pinned thread-title / metadata row is attached
                        // to the ScrollView below via `.safeAreaInset(
                        // edge: .top)` rather than sitting above it in
                        // this VStack. That lets the scroll content
                        // pass UNDER the header row so a `.bar`
                        // material on the inset genuinely blurs what's
                        // scrolling behind it — the frosted-glass
                        // chrome Finder / Mail / Safari use for their
                        // pinned headers. In a plain stacked layout
                        // there's nothing behind the header for the
                        // material to blur, so it reads as a flat
                        // opaque bar with a visible seam against the
                        // window toolbar above, which is exactly what
                        // the user asked to fix ("スクロールに対して
                        // すりガラスのように透過").
                        ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            // Invisible top-anchor. `ConversationHeaderView`
                            // used to carry `Self.topAnchorID`, but the
                            // header was promoted to a pinned strip
                            // above the ScrollView and no longer lives
                            // inside `LazyVStack`. A zero-height
                            // `Color.clear` anchor keeps the existing
                            // `proxy.scrollTo(topAnchorID)` call-sites
                            // working without needing to reach into the
                            // header, and renders nothing visible.
                            Color.clear
                                .frame(height: 0)
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
                                                            in: .named(ScrollCoordinateSpace.conversation)
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
                    .coordinateSpace(name: ScrollCoordinateSpace.conversation)
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
                    // Internal scroll-to-top, driven by a double-click
                    // on the pinned header row. Kept separate from
                    // `scrollToTopToken` (the external binding) so
                    // the header still reaches the top when no
                    // external caller wired the binding — in the
                    // DesignMock shell the binding resolves to
                    // `.constant(nil)`, and writing to a constant
                    // sink is a no-op. A local state token bypasses
                    // that and funnels into the same helper.
                    .onChange(of: internalScrollToTopToken) { _, newValue in
                        guard newValue != nil else { return }
                        performScrollToTop(using: proxy)
                        Task { @MainActor in
                            internalScrollToTopToken = nil
                        }
                    }
                    // Frosted-glass pinned header. Attaching the
                    // `ConversationHeaderView` as a top safe-area
                    // inset (rather than stacking it above the
                    // ScrollView in a VStack) is what makes the
                    // material actually translucent: the scroll
                    // content flows UP under the inset and the
                    // `.bar` material blurs it, same as Finder's
                    // path bar or Mail's message header. Double-
                    // click routes through `internalScrollToTopToken`
                    // so the strip also doubles as a "jump to top"
                    // affordance; `scrollToTopToken` (the external
                    // binding) keeps working unchanged for outline-
                    // popover / keyboard call sites.
                    .safeAreaInset(edge: .top, spacing: 0) {
                        ConversationHeaderView(
                            summary: detail.summary,
                            onDoubleTapToTop: {
                                internalScrollToTopToken = UUID()
                            }
                        )
                        .padding(.horizontal, 24)
                        .padding(.vertical, 10)
                        // `VisualEffectBar` = `NSVisualEffectView` with
                        // `.headerView` material. SwiftUI's `.bar`
                        // material was unreliable here — it read as a
                        // near-opaque tint whenever the message body
                        // didn't happen to be scrolled under the
                        // header, which is most of the time for short
                        // conversations. The AppKit view gives real
                        // translucent Finder-style chrome regardless
                        // of the scroll position.
                        #if os(macOS)
                        .background { VisualEffectBar() }
                        #else
                        .background(.bar)
                        #endif
                    }
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

    /// Animated programmatic scroll that holds `programmaticScrollLock`
    /// for the duration, suppressing the scroll-position observer so
    /// it can't overwrite `selectedPromptID` with transient
    /// mid-animation prompts. Callers just pass the target id — nil
    /// short-circuits cleanly.
    ///
    /// Lock release is done on a dispatched Task sleeping ~0.45s
    /// (animation length + a cushion for the final `PromptTopYPreferenceKey`
    /// emission to arrive). The lock is keyed by a fresh UUID so if
    /// another programmatic scroll starts before the sleep completes,
    /// the older task's release is a no-op — the newer scroll's lock
    /// stays in force for its own window.
    private func performProgrammaticScroll(
        to id: String?,
        using proxy: ScrollViewProxy
    ) {
        guard let id else { return }
        let token = UUID()
        programmaticScrollLock = token
        withAnimation(.easeInOut(duration: 0.2)) {
            proxy.scrollTo(id, anchor: .top)
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 450_000_000)
            if programmaticScrollLock == token {
                programmaticScrollLock = nil
            }
        }
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
        withAnimation(.easeInOut(duration: 0.2)) {
            proxy.scrollTo(Self.topAnchorID, anchor: .top)
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 450_000_000)
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

        let threshold = Self.currentPromptTopThreshold
        let crossed = offsets.filter { $0.value <= threshold }

        let candidate: String?
        if let top = crossed.max(by: { $0.value < $1.value })?.key {
            candidate = top
        } else {
            // Haven't scrolled past the first prompt yet — default to
            // the earliest message (smallest minY).
            candidate = offsets.min(by: { $0.value < $1.value })?.key
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

/// Per-message top-edge y coordinate in the ScrollView's coordinate
/// space. Each user message contributes one entry; merge is a plain
/// dictionary merge because keys (message ids) are unique.
private struct PromptTopYPreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]

    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
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
        HStack(spacing: 8) {
            // Thread title on the left, time + source pill on the
            // right. Title gets `layoutPriority(1)` + `Spacer()` push
            // so it absorbs available width without shoving the
            // metadata off-screen; truncation happens on the title
            // first, which is the right default (the metadata is
            // always short — a pill plus a formatted date — and is
            // what the user scans to identify the thread at a
            // glance). `textSelection(.enabled)` so the title is
            // copy-paste-friendly.
            Text(summary.title ?? "Untitled")
                .font(.callout.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .layoutPriority(1)

            Spacer(minLength: 8)

            // Source-origin pill sits immediately to the LEFT of the
            // date timestamp so the eye doesn't have to traverse the
            // full pane width to find it. The tag editor that used
            // to sit alongside was retired when tags were dropped
            // from the UI.
            SourceOriginPill(
                conversationID: summary.id,
                source: summary.source,
                model: summary.model
            )

            if let time = summary.primaryTime {
                Text(time)
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
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

}

private struct DetailExportToolbar: ToolbarContent {
    let detail: ConversationDetail

    var body: some ToolbarContent {
        ToolbarItem {
            ConversationShareButton(detail: detail)
        }
    }
}

/// Toolbar share button that materializes the conversation as a Markdown
/// file in the temp directory and hands the URL to `ShareLink`. Using a
/// file URL (instead of a raw String) lets AppKit/UIKit present the full
/// `NSSharingServicePicker` menu — AirDrop, Mail, Messages, Notes, Save
/// to Files / Finder, Copy, and any third-party share extensions the
/// user has installed — matching the Finder / Safari share affordance.
///
/// The file is regenerated whenever the bound conversation changes
/// (`.task(id: detail.summary.id)`) so stale content is never shared.
/// We write under a per-conversation subdirectory keyed by ID, keeping
/// the filename readable (title-based) so share-sheet previews and any
/// destination that keeps the filename (Files.app, Finder drop) show a
/// human-meaningful name rather than a UUID.
private struct ConversationShareButton: View {
    let detail: ConversationDetail

    @State private var shareURL: URL?

    var body: some View {
        Group {
            if let shareURL {
                ShareLink(
                    item: shareURL,
                    preview: SharePreview(
                        detail.summary.title ?? "Conversation",
                        image: Image(systemName: "doc.text")
                    )
                ) {
                    Image(systemName: "square.and.arrow.up")
                }
                .help("Share conversation")
            } else {
                // Placeholder keeps toolbar layout stable while the
                // markdown file is being written on first appearance.
                Button {} label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .disabled(true)
                .help("Preparing…")
            }
        }
        .task(id: detail.summary.id) {
            shareURL = await MarkdownExporter.writeTempShareFile(for: detail)
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
}
