import SwiftUI
#if os(macOS)
import AppKit
#endif

struct ReaderWorkspaceView: View {
    @Bindable var tabManager: ReaderTabManager
    let repository: any ConversationRepository
    /// Binding to the parent's Viewer Mode state. The reader-pane toolbar
    /// carries the toggle button; flipping it from here is what drives the
    /// middle-pane swap and the sidebar auto-collapse (wired up in
    /// `MacOSRootView`). Passed as a binding rather than an observed
    /// object so the source of truth stays in the root view — only one
    /// place needs to persist/restore column visibility.
    @Binding var isViewerModeActive: Bool
    /// Invoked when the user taps the header-bar conversation title.
    /// Parent (MacOSRootView) is expected to scroll the middle-pane list
    /// so that the active conversation's card is at the top; this view
    /// separately rotates `tabManager.scrollToTopToken` to snap the
    /// reader body back to its header. Split across two sinks because
    /// the list lives on `LibraryViewModel` and the reader lives on
    /// `ReaderTabManager` — the parent is the only place that holds
    /// references to both.
    var onRevealActiveConversationInList: (() -> Void)? = nil

    // `selectedPromptID` lives on `tabManager` (see its doc comment) so
    // the viewer-mode middle pane can observe the same reading position
    // without forcing the root view to re-render. All reads / writes in
    // this file go through `tabManager.selectedPromptID` — do NOT
    // re-hoist it back to `@State` here, that reintroduces the
    // "PromptTopYPreferenceKey updated multiple times per frame" warning.

    /// `activeDetail` and `promptOutline` now live on `tabManager` (they
    /// have to be readable from the root-level Viewer-Mode toolbar, which
    /// can't reach into this view's `@State`). See their doc comments in
    /// `ReaderTabManager`. This view still writes to them via the
    /// `onDetailChanged` / `onPromptOutlineChanged` callbacks below.
    /// Display mode (rendered vs. plain) for the currently-open conversation.
    /// Keyed by `ReaderTab.id` so swapping to a different conversation
    /// resets to the default — intentional, since the reader is a fresh
    /// view of whatever card was just clicked and re-inheriting a prior
    /// mode across unrelated conversations is surprising.
    @State private var displayModes: [ReaderTab.ID: ConversationDetailView.DetailDisplayMode] = [:]
    /// Measured height of the floating reader-pane header bar (outline
    /// control + export). Threaded into the inner ScrollView via the
    /// `scrollTopContentInset` environment so rows can slide under the
    /// translucent bar and get blurred by its vibrancy material.
    @State private var headerBarHeight: CGFloat = WorkspaceLayoutMetrics.headerBarContentRowHeight
    @FocusState private var workspaceFocused: Bool

    var body: some View {
        Group {
            if let activeTab = tabManager.activeTab {
                ConversationDetailView(
                    conversationId: activeTab.conversationID,
                    repository: repository,
                    displayMode: displayModeBinding(for: activeTab),
                    selectedPromptID: $tabManager.selectedPromptID,
                    requestedPromptID: $tabManager.requestedPromptID,
                    scrollToTopToken: $tabManager.scrollToTopToken,
                    showsSystemChrome: false,
                    onDetailChanged: { detail in
                        tabManager.activeDetail = detail
                    },
                    onPromptOutlineChanged: { outline in
                        tabManager.promptOutline = outline
                        // Drop a stale selection (carried over from a
                        // previously-open conversation) but do NOT seed
                        // the first prompt. Seeding caused the detail view
                        // to open scrolled partway down —
                        // `scrollToSelectedPrompt` on appear anchored the
                        // first user prompt to the top, which hid any
                        // preceding system / preface messages. A nil
                        // selection lets the ScrollView open at its
                        // natural top, and the scroll-position observer
                        // picks up a "current prompt" once the user
                        // starts scrolling.
                        if let current = tabManager.selectedPromptID,
                           !outline.contains(where: { $0.id == current }) {
                            tabManager.selectedPromptID = nil
                        }
                    }
                )
                .id(activeTab.id)
            } else {
                ContentUnavailableView(
                    "Open a conversation",
                    systemImage: "rectangle.on.rectangle",
                    description: Text("Select a conversation from the list.")
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .focusable()
        .focusEffectDisabled()
        .focused($workspaceFocused)
        .onMoveCommand(perform: handleMoveCommand(_:))
        .simultaneousGesture(
            TapGesture().onEnded {
                workspaceFocused = true
            }
        )
        .onAppear {
            workspaceFocused = true
        }
        .onChange(of: tabManager.activeTab?.id) { _, _ in
            // `activeDetail` / `promptOutline` / `selectedPromptID` are
            // all cleared by `ReaderTabManager.openConversation(…)`
            // atomically with the tab change, so we don't reset them
            // here. Refocusing is still this view's responsibility.
            workspaceFocused = true
        }
        // `tabManager.requestedPromptID` is now observed directly by
        // `ConversationDetailView` (threaded in as a Binding above)
        // rather than bridged through `selectedPromptID` here. The old
        // bridge had two bugs: (1) tapping a prompt you were already
        // reading produced `selectedPromptID == newID` → no onChange
        // in the detail → no scroll ("戻れなかった" report), and (2)
        // writing `selectedPromptID` synchronously raced with the
        // scroll-position observer, producing flip-flop chatter.
        // Observing the request token inside the detail view lets it
        // scroll imperatively and hold a programmatic-scroll lock for
        // the animation's duration.
        //
        // We still want the reader workspace to take keyboard focus
        // when the user taps a prompt from another pane (so arrow
        // keys immediately step through prompts afterwards). Lighter
        // onChange just for the focus grab — the scroll work itself
        // happens inside the detail view.
        .onChange(of: tabManager.requestedPromptID) { _, newID in
            if newID != nil {
                workspaceFocused = true
            }
        }
        // Inject the measured header-bar height so descendants (notably
        // `ConversationDetailView`'s inner ScrollView) can reserve
        // top-of-content room without having the bar take that space out
        // of their scrollable region. Same rationale as the middle pane.
        .environment(\.scrollTopContentInset, headerBarHeight)
        // Fade message content as it scrolls up under the floating
        // toolbar strip. Same technique as the middle pane — see
        // MacOSRootView.libraryContentPane. Applied before the header
        // overlay so the toolbar chrome itself stays crisp.
        .topFadeMask(height: WorkspaceLayoutMetrics.topFadeHeight)
        // Overlay (not safeAreaInset) — see MacOSRootView.libraryContentPane
        // for the rationale. The short version: we want rows to scroll
        // UNDER the bar so its material can blur them.
        //
        // Viewer Mode: the header bar is HIDDEN in this pane because
        // the root view paints a single window-spanning toolbar above
        // both middle + right panes instead (see
        // `MacOSRootView.viewerModeTopToolbar`). Keeping our own header
        // here in Viewer Mode would produce two toolbars stacked
        // awkwardly on top of each other.
        .overlay(alignment: .top) {
            if !isViewerModeActive {
                ReaderWorkspaceHeaderBar(
                    activeDetail: tabManager.activeDetail,
                    promptOutline: tabManager.promptOutline,
                    selectedPromptID: tabManager.selectedPromptID,
                    isViewerModeActive: $isViewerModeActive,
                    onSelectPrompt: selectPrompt,
                    onTapTitle: handleTitleTap
                ) {
                    WorkspaceFloatingExportButton(detail: tabManager.activeDetail)
                }
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: HeaderBarHeightPreferenceKey.self,
                            value: proxy.size.height
                        )
                    }
                )
            }
        }
        .onPreferenceChange(HeaderBarHeightPreferenceKey.self) { newHeight in
            headerBarHeight = newHeight
        }
    }

    private func displayModeBinding(for tab: ReaderTab) -> Binding<ConversationDetailView.DetailDisplayMode> {
        Binding(
            get: { displayModes[tab.id] ?? .rendered },
            set: { displayModes[tab.id] = $0 }
        )
    }

    private func selectPrompt(_ promptID: String) {
        tabManager.selectedPromptID = promptID
        workspaceFocused = true
    }

    /// Conversation-title tap in the header bar. Fires the middle-pane
    /// reveal callback (provided by the root view, which has a handle on
    /// the `LibraryViewModel` holding the list's scroll request) and
    /// rotates the reader-body scroll-to-top token so the right pane
    /// snaps back to the conversation's `ConversationHeaderView`. Only
    /// meaningful when there's an active tab.
    private func handleTitleTap() {
        guard tabManager.activeTab != nil else { return }
        onRevealActiveConversationInList?()
        tabManager.scrollToTopToken = UUID()
        workspaceFocused = true
    }

    private func handleMoveCommand(_ direction: MoveCommandDirection) {
        switch direction {
        case .up:
            tabManager.selectAdjacentPrompt(step: -1)
            workspaceFocused = true
        case .down:
            tabManager.selectAdjacentPrompt(step: 1)
            workspaceFocused = true
        default:
            break
        }
    }

}

private struct ReaderWorkspaceHeaderBar<Accessory: View>: View {
    let activeDetail: ConversationDetail?
    let promptOutline: [ConversationPromptOutlineItem]
    let selectedPromptID: String?
    @Binding var isViewerModeActive: Bool
    let onSelectPrompt: (String) -> Void
    let onTapTitle: () -> Void
    @ViewBuilder let accessory: () -> Accessory

    var body: some View {
        WorkspaceHeaderBar {
            // Leading-most: Viewer Mode toggle. Placed first so the bar
            // bookends — mode control on the left, export on the right —
            // in the same pattern as Safari's Reader View button sitting
            // at the start of its URL bar. Disabled until there's
            // actually a conversation open to read.
            ViewerModeToggleButton(
                isActive: $isViewerModeActive,
                isEnabled: activeDetail != nil
            )

            // Conversation-title pill. Previously the title only appeared
            // in Viewer Mode's window-spanning toolbar; users expected it
            // as an always-on anchor they could tap to "take me back to
            // the top" of both this reader pane and the middle-pane list
            // card. Rendered before the outline control so the header
            // reads as "what am I looking at?" → "where am I in it?".
            if let summary = activeDetail?.summary {
                ReaderHeaderTitlePill(
                    summary: summary,
                    action: onTapTitle
                )
            }

            ReaderWorkspaceOutlineControl(
                activeDetail: activeDetail,
                promptOutline: promptOutline,
                selectedPromptID: selectedPromptID,
                onSelectPrompt: onSelectPrompt
            )

            Spacer(minLength: 0)

            accessory()
        }
    }
}

/// Glass-capsule chip showing the active conversation's title + ISO date.
/// Styled to match the outline pill's material recipe so the header bar
/// reads as a single family of translucent chips. Tapping it fires
/// `action` — the parent wires that to a "reveal this conversation in
/// the middle-pane list AND snap the reader body to its top" combo.
///
/// Shape choices: single-line, fixed max width, truncating tail. Long
/// conversation titles would otherwise stretch the bar past the outline
/// pill and force it off-screen on narrow windows.
private struct ReaderHeaderTitlePill: View {
    let summary: ConversationSummary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                // Up-arrow glyph signals "jump to top" — matches Safari's
                // URL-bar reload/back affordance pattern where the icon
                // telegraphs the destination of the tap.
                Image(systemName: "arrow.up.to.line")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Text(summary.displayTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    // Cap width so a long title can't push the outline
                    // pill off the bar. 280pt is enough room for a
                    // typical chat title while keeping the bar balanced.
                    .frame(maxWidth: 280, alignment: .leading)
            }
            .padding(.horizontal, WorkspaceLayoutMetrics.headerChipHorizontalPadding)
            .frame(height: WorkspaceLayoutMetrics.headerChipHeight)
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .background(
            Capsule(style: .continuous)
                .fill(.thinMaterial)
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .help("Jump to top · reveal in list")
    }
}

/// Leading-edge toggle that flips Madini into Viewer Mode (see
/// `MacOSRootView.isViewerModeActive` for the full plumbing). Uses the
/// Safari Reader-View convention of `book` / `book.fill` — hollow when
/// off, filled when on — so the glyph itself advertises its current
/// state independent of the chip's accent tint. The same
/// `headerIconChipStyle` as the trailing export button keeps the bar's
/// icon buttons visually matched.
///
/// Accessible to other files (not `private`) because the root-level
/// Viewer-Mode toolbar reuses it too — the button lives in the reader
/// header outside Viewer Mode and in the window-spanning toolbar
/// inside it.
struct ViewerModeToggleButton: View {
    @Binding var isActive: Bool
    let isEnabled: Bool

    /// While Viewer Mode is ALREADY on, the button's job is "退出する"
    /// — so it must stay enabled regardless of `isEnabled`
    /// (which only gates entry, based on whether there's a detail
    /// loaded). Previously, if `activeDetail` briefly went nil during
    /// a keyboard-driven conversation switch, the exit button
    /// disabled itself and the user was trapped in Viewer Mode with
    /// no way back. Latch "exit is always available" here.
    private var effectiveEnabled: Bool { isActive || isEnabled }

    var body: some View {
        Button {
            isActive.toggle()
        } label: {
            Image(systemName: isActive ? "book.fill" : "book")
                // `.title3` (~20pt) — matches the bumped calendar /
                // export glyphs so all three icon-only toolbar chips
                // share a single optical size. The prior `.body`
                // (~17pt) read as undersized once the chips all
                // shared the capsule shape.
                .font(.title3.weight(.semibold))
                .headerIconChipStyle(isActive: isActive)
        }
        .buttonStyle(.plain)
        .disabled(!effectiveEnabled)
        // Dim the chip rather than letting SwiftUI's default disabled
        // treatment apply — the default washes the glyph but leaves the
        // material chip fully opaque, which reads as "active but
        // broken" instead of "intentionally unavailable".
        .opacity(effectiveEnabled ? 1 : 0.4)
        // Escape hatch: even if focus drifts or the chip stops accepting
        // clicks for any reason, ⎋ always drops Viewer Mode. Registered
        // only while the mode is active so it doesn't steal Escape from
        // the rest of the UI (search field, popovers, etc.).
        .modifier(ViewerModeEscapeShortcut(enabled: isActive))
        .help(isActive ? "Exit Viewer Mode (Esc)" : "Enter Viewer Mode")
    }
}

/// Attaches the Escape-key shortcut to the enclosing button only while
/// `enabled` is true. Split out into a modifier so the `.keyboardShortcut`
/// call site can truly be absent when off — SwiftUI will otherwise latch
/// a shortcut registration even if we pass a no-op key, producing odd
/// stolen-keystroke behavior elsewhere in the UI.
private struct ViewerModeEscapeShortcut: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.keyboardShortcut(.cancelAction)
        } else {
            content
        }
    }
}

private struct ReaderWorkspaceOutlineControl: View {
    let activeDetail: ConversationDetail?
    let promptOutline: [ConversationPromptOutlineItem]
    let selectedPromptID: String?
    let onSelectPrompt: (String) -> Void

    @State private var isOutlinePresented = false

    /// Outline pull-down pill: counter + current prompt title + chevron,
    /// opening a searchable prompt-list popover. The trailing prev/next
    /// step chips used to live inside this capsule; they were removed
    /// per user request — keyboard arrow keys still move selection (see
    /// `ReaderWorkspaceView.handleMoveCommand`), the chips were
    /// redundant chrome.
    var body: some View {
        HStack(spacing: 0) {
            // The outline is a custom popover rather than a Menu because
            // SwiftUI's Menu renders as a native NSMenu on macOS, which
            // only honors Text + Image inside item labels — alternating
            // row backgrounds (and any other custom styling we might add
            // later) are silently discarded during the AppKit bridge.
            // A popover hosting a real SwiftUI list gives us full
            // control over row chrome.
            Button {
                guard !promptOutline.isEmpty else { return }
                isOutlinePresented.toggle()
            } label: {
                HStack(spacing: 8) {
                    // Prompt counter ("3 / 42") replaces a prior bubble icon.
                    // The denominator uses the outline count — assistant /
                    // system messages are excluded, matching the popover.
                    // Tabular digits so the width stays steady as the
                    // numerator grows from 1 → 2 → 3 digits.
                    Text(promptCounterText)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 42, alignment: .leading)

                    // Single-line title so the capsule's height matches
                    // the sibling chip controls in the middle pane. The
                    // two-line form (conversation title + current prompt)
                    // was making this pill ~16pt taller than its siblings
                    // and visually broke the "one toolbar family" read.
                    Text(currentPromptTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        // Fixed width so the trailing chevron stays at the
                        // same x-coordinate regardless of title length.
                        // Otherwise opening and re-opening the popover
                        // becomes a moving target — the arrow drifts as the
                        // selected prompt changes, which makes it
                        // surprisingly hard to click twice in a row.
                        .frame(width: 260, alignment: .leading)

                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.leading, WorkspaceLayoutMetrics.headerChipHorizontalPadding)
            .disabled(promptOutline.isEmpty)
            .popover(isPresented: $isOutlinePresented, arrowEdge: .bottom) {
                PromptOutlinePopover(
                    prompts: promptOutline,
                    selectedPromptID: selectedPromptID,
                    onSelect: { id in
                        onSelectPrompt(id)
                        isOutlinePresented = false
                    }
                )
            }

            // Trailing breathing room so the chevron-down on the main
            // button doesn't sit flush against the capsule's right wall.
            Color.clear.frame(width: WorkspaceLayoutMetrics.headerChipHorizontalPadding, height: 1)
        }
        // Shared glass treatment — matches the middle pane's sort pill
        // so the top strip reads as one family of pill-shaped glass
        // controls. Inlined (rather than via `.headerChipStyle()`)
        // because this pill contains a divider + step buttons alongside
        // its main button and the modifier's single horizontal padding
        // would double-pad the contents. Keep this recipe in sync with
        // `HeaderChipBackground` — thin material + monochrome hairline
        // stroke, no rim gradient, no shadow. Apple's own toolbar chips
        // are this restrained; adding chrome made Madini's bar read as
        // a skin instead of native UI.
        .frame(height: WorkspaceLayoutMetrics.headerChipHeight)
        .background(
            Capsule(style: .continuous)
                .fill(.thinMaterial)
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
    }

    private var currentPromptTitle: String {
        guard let selectedPromptID,
              let selectedPrompt = promptOutline.first(where: { $0.id == selectedPromptID }) else {
            return activeDetail?.summary.displayTitle ?? "Reader"
        }

        return selectedPrompt.label
    }

    private var promptCounterText: String {
        guard !promptOutline.isEmpty else { return "—" }
        let current = promptOutline.firstIndex(where: { $0.id == selectedPromptID }).map { $0 + 1 } ?? 1
        return "\(current) / \(promptOutline.count)"
    }

}

/// Popover-backed replacement for the outline `Menu`. The whole reason
/// this exists as a separate view (instead of being inlined in
/// `ReaderWorkspaceOutlineControl`'s `.popover` closure) is so the row
/// layout is a normal SwiftUI subtree — NSMenu's restriction on label
/// contents doesn't apply here, so we can alternate row backgrounds,
/// highlight the current selection, and show the "Prompt N" subtitle
/// on its own line.
private struct PromptOutlinePopover: View {
    let prompts: [ConversationPromptOutlineItem]
    let selectedPromptID: String?
    let onSelect: (String) -> Void

    /// Rough budget for the popover: wide enough for a reasonable
    /// title excerpt without dominating the window, tall enough to
    /// show ~12 rows before the user has to scroll. We constrain the
    /// height because SwiftUI popovers otherwise grow to fit every
    /// row, which gets awkward for 100-prompt conversations.
    private let popoverWidth: CGFloat = 360
    private let popoverMaxHeight: CGFloat = 440

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                // `enumerated()` for the visual row index — we can't
                // just use `prompt.index` because that's the underlying
                // message index (which skips non-user messages and
                // therefore can't drive a clean zebra pattern).
                ForEach(Array(prompts.enumerated()), id: \.element.id) { offset, prompt in
                    PromptOutlineRow(
                        prompt: prompt,
                        isSelected: selectedPromptID == prompt.id,
                        isAlternate: offset.isMultiple(of: 2),
                        onSelect: { onSelect(prompt.id) }
                    )
                }
            }
        }
        .frame(width: popoverWidth)
        .frame(maxHeight: popoverMaxHeight)
    }
}

private struct PromptOutlineRow: View {
    let prompt: ConversationPromptOutlineItem
    let isSelected: Bool
    /// `true` for every other row — drives the zebra background. Done
    /// by visual position, not by `prompt.index`, so the stripe pattern
    /// stays tight even when the underlying message indices are
    /// non-contiguous (user prompts are interleaved with assistant +
    /// system messages in the source conversation).
    let isAlternate: Bool
    let onSelect: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                // Fixed-width index column so wrapped titles hang off a
                // consistent left margin instead of reflowing under the
                // number (which looked ragged for 2- vs 3-digit indices).
                Text("\(prompt.index).")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 28, alignment: .trailing)

                Text(prompt.label)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(rowBackground)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }

    /// Layering: selection tint > hover tint > zebra stripe > clear.
    /// The selection tint is strong enough to read at a glance even on
    /// top of the stripe it would otherwise inherit.
    private var rowBackground: Color {
        if isSelected {
            return Color.accentColor.opacity(0.18)
        }
        if isHovering {
            return Color.secondary.opacity(0.12)
        }
        if isAlternate {
            return Color.secondary.opacity(0.06)
        }
        return .clear
    }
}

/// Trailing-edge export chip. Internal (not private) because the
/// root-level Viewer-Mode toolbar reuses it — in Viewer Mode the export
/// action moves from the right-pane header bar into the window-
/// spanning top toolbar, but the styling stays identical.
struct WorkspaceFloatingExportButton: View {
    let detail: ConversationDetail?

    var body: some View {
        #if os(macOS)
        // Glass chip — matches the sort / date / outline controls so the
        // three panes' top bars read as one family of translucent
        // buttons. Previously this wore a hand-rolled 30×30 Circle with
        // its own stroke, which clashed with everything else.
        Button {
            guard let detail else { return }
            export(detail)
        } label: {
            Image(systemName: "square.and.arrow.up")
                // Shared with the calendar + viewer-mode glyphs at
                // `.title3` (~20pt) — one typography step above `.body`
                // so the icon-only chips carry visible presence against
                // the 30pt chip height and the text-bearing sort pill.
                .font(.title3.weight(.semibold))
                // Rounded-square icon chip — matches the calendar button
                // and Apple's titlebar sidebar-toggle shape. Capsule was
                // wrong here: the capsule's wide radius on a 38pt-wide
                // single-glyph chip made it read nearly circular, which
                // broke the icon-button convention.
                .headerIconChipStyle()
        }
        .buttonStyle(.plain)
        .help("Export as Markdown")
        .disabled(detail == nil)
        .opacity(detail == nil ? 0.4 : 1)
        #else
        if let detail {
            ShareLink(item: MarkdownExporter.export(detail)) {
                Image(systemName: "square.and.arrow.up")
            }
        } else {
            Image(systemName: "square.and.arrow.up")
                .foregroundStyle(.tertiary)
        }
        #endif
    }

    #if os(macOS)
    private func export(_ detail: ConversationDetail) {
        let markdown = MarkdownExporter.export(detail)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = sanitizeFilename(detail.summary.title ?? "conversation") + ".md"

        panel.begin { response in
            guard response == .OK, let url = panel.url else {
                return
            }

            try? markdown.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func sanitizeFilename(_ name: String) -> String {
        let illegal = CharacterSet(charactersIn: "/:\\")
        return name.components(separatedBy: illegal).joined(separator: "_")
    }
    #endif
}
