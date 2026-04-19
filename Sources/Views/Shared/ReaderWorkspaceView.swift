import SwiftUI
#if os(macOS)
import AppKit
#endif

struct ReaderWorkspaceView: View {
    @Bindable var tabManager: ReaderTabManager
    let repository: any ConversationRepository
    /// Reserved room above the first line of reader content. The
    /// window-spanning `UnifiedWorkspaceTopBar` floats above this pane
    /// (mounted at the NavigationSplitView level in `MacOSRootView`) and
    /// its measured height is passed in here so rows can slide under
    /// the bar and get blurred by its vibrancy material — the local
    /// reader-pane header bar that used to live here has been removed.
    var topContentInset: CGFloat = WorkspaceLayoutMetrics.headerBarContentRowHeight

    // `selectedPromptID` lives on `tabManager` (see its doc comment) so
    // the viewer-mode middle pane can observe the same reading position
    // without forcing the root view to re-render. All reads / writes in
    // this file go through `tabManager.selectedPromptID` — do NOT
    // re-hoist it back to `@State` here, that reintroduces the
    // "PromptTopYPreferenceKey updated multiple times per frame" warning.

    /// `activeDetail` and `promptOutline` live on `tabManager` (they
    /// have to be readable from the unified top bar, which can't reach
    /// into this view's `@State`). See their doc comments in
    /// `ReaderTabManager`. This view still writes to them via the
    /// `onDetailChanged` / `onPromptOutlineChanged` callbacks below.
    /// Display mode (rendered vs. plain) for the currently-open conversation.
    /// Keyed by `ReaderTab.id` so swapping to a different conversation
    /// resets to the default — intentional, since the reader is a fresh
    /// view of whatever card was just clicked and re-inheriting a prior
    /// mode across unrelated conversations is surprising.
    @State private var displayModes: [ReaderTab.ID: ConversationDetailView.DetailDisplayMode] = [:]
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
        // of their scrollable region. The bar itself is mounted on the
        // root `workspaceSplitView`, so its height arrives here as a
        // parameter from `MacOSRootView` instead of being measured in
        // this view directly.
        .environment(\.scrollTopContentInset, topContentInset)
        // Fade message content as it scrolls up under the floating
        // toolbar strip AND off the bottom edge. Same technique as the
        // middle pane — see MacOSRootView.libraryContentPane.
        .edgeFadeMask(
            top: WorkspaceLayoutMetrics.topFadeHeight,
            bottom: WorkspaceLayoutMetrics.bottomFadeHeight
        )
    }

    private func displayModeBinding(for tab: ReaderTab) -> Binding<ConversationDetailView.DetailDisplayMode> {
        Binding(
            get: { displayModes[tab.id] ?? .rendered },
            set: { displayModes[tab.id] = $0 }
        )
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

/// **The navigation bar.** Single connected capsule combining the
/// conversation-title pulldown and the prompt-outline pulldown — the
/// two halves are referred to together as "the navigation bar"
/// throughout the app. Previously rendered as two separate pills; the
/// user asked them merged into one window so "what am I reading /
/// where am I in it" reads as a single piece of chrome.
///
/// Layout, left to right:
///
///   [ ↑ Title ] │ [ N/M PromptTitle ⌄ ]
///
/// Left half = title pulldown. Custom popover (`ConversationListPopover`)
/// listing the conversations currently rendered by the middle pane,
/// opened anchored on the active row. Top item preserves the legacy
/// `onTapTitle` action so the muscle memory still works.
///
/// Right half = prompt pulldown. Custom popover (`PromptOutlinePopover`)
/// rather than an NSMenu, because NSMenu's single-line text rendering
/// truncated long prompt labels too aggressively — the user reads each
/// row's label to pick a prompt, so legibility matters.
///
/// Single capsule, single thin-material fill. A `>` chevron sits
/// between the two halves so the chip reads as a "Title › Prompt"
/// breadcrumb rather than two unrelated buttons under one capsule.
///
/// Mounted by `UnifiedWorkspaceTopBar` in every mode (table included).
struct ReaderHeaderActivityPill: View {
    let activeDetail: ConversationDetail?
    let promptOutline: [ConversationPromptOutlineItem]
    let selectedPromptID: String?
    let onSelectPrompt: (String) -> Void
    /// Conversations currently rendered by the middle pane (already
    /// filtered/sorted by the sidebar). Powers the title-pulldown's
    /// jump-to-other-conversation list — Xcode-style breadcrumb where
    /// each row is a peer the user can switch to without leaving the
    /// reader.
    let conversations: [ConversationSummary]
    /// Switch the reader to a different conversation. Wired upstream
    /// to `selectedConversationId =` which fans out via
    /// `MacOSRootView.onChange` into the tab-manager open path.
    let onSelectConversation: (String) -> Void

    @State private var isOutlinePresented = false
    @State private var isTitlePresented = false

    var body: some View {
        HStack(spacing: 0) {
            titleHalf
            divider
            promptHalf
        }
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

    // MARK: - Title half (left)
    //
    // Custom popover (`ConversationListPopover`) instead of an
    // NSMenu. Earlier iterations used `Menu` for the Xcode-jump-bar
    // cascade-out submenu effect, but two requirements pushed us back
    // to a popover:
    //
    //   1. Open the pulldown anchored on the active conversation, with
    //      that row highlighted in gray and visible without scrolling.
    //      `Menu`/NSMenu always opens at the top of its item list with
    //      no programmatic scroll API — there's no way to seed a
    //      "current selection" the way a popover + ScrollViewReader can.
    //   2. Match the prompt-side popover's visual language (gray
    //      highlight on the current row, multi-line titles, zebra
    //      stripes). `Menu` items are NSMenu-backed, single-line, with
    //      a fixed checked-state glyph that doesn't read as the same
    //      "current row" affordance.
    //
    // The popover lists every conversation in the current middle-pane
    // filter; the active one carries the gray highlight + checkmark.
    // The top "現在の会話を中央リストで見る" row preserves the legacy
    // `onTapTitle` muscle memory.

    @ViewBuilder
    private var titleHalf: some View {
        Button {
            guard activeDetail != nil || !conversations.isEmpty else { return }
            isTitlePresented.toggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "list.bullet.indent")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Text(titleText)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(activeDetail == nil ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    // Fixed cap so a long title can't push the prompt
                    // half off the trailing edge of the bar.
                    .frame(maxWidth: 180, alignment: .leading)
            }
            .padding(.leading, WorkspaceLayoutMetrics.headerChipHorizontalPadding)
            .padding(.trailing, 10)
            .frame(height: WorkspaceLayoutMetrics.headerChipHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(activeDetail == nil && conversations.isEmpty)
        .popover(isPresented: $isTitlePresented, arrowEdge: .bottom) {
            ConversationListPopover(
                conversations: conversations,
                activeConversationID: activeDetail?.summary.id,
                onSelect: { id in
                    onSelectConversation(id)
                    isTitlePresented = false
                }
            )
        }
        .help("会話・プロンプトに移動")
    }

    // MARK: - Prompt half (right)
    //
    // Layout reads left-to-right as `[prompt label] [N/M] [chev]`.
    // The counter sits AFTER the prompt label so it's visually anchored
    // to the prompt side and not crowding the title divider — an
    // earlier ordering put `[N/M]` first, immediately right of the
    // chip's central `>` separator, which made the count read as
    // metadata about the title (the user reported it as "プロンプト
    // 数の表記がタイトル側に近くてわかりにくい").
    //
    // Stays a `Button` + `.popover` (not a `Menu` like the title
    // half) so the popover's multi-line prompt-label rendering and
    // checkmark-on-current-prompt highlight survive — NSMenu items
    // are single-line only and that lost too much of the prompt text
    // for long prompts.

    @ViewBuilder
    private var promptHalf: some View {
        Button {
            guard !promptOutline.isEmpty else { return }
            isOutlinePresented.toggle()
        } label: {
            HStack(spacing: 8) {
                Text(currentPromptTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(promptOutline.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
                    // Fixed width so the trailing counter + chevron
                    // stay at a consistent x-coordinate regardless of
                    // current prompt title.
                    .frame(width: 180, alignment: .leading)

                // Tabular digits so the counter column doesn't shift
                // width as the numerator grows from 1 → 10 → 100.
                Text(promptCounterText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 42, alignment: .trailing)

                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, 10)
            .padding(.trailing, WorkspaceLayoutMetrics.headerChipHorizontalPadding)
            .frame(height: WorkspaceLayoutMetrics.headerChipHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
    }

    // MARK: - Divider

    /// Breadcrumb chevron between the two halves, so the chip reads
    /// as a "Title › Prompt" path rather than two adjacent buttons.
    /// Same direction and weight as Finder's path bar / Xcode's
    /// jump-bar separators.
    private var divider: some View {
        Image(systemName: "chevron.right")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 2)
    }

    // MARK: - Text helpers

    private var titleText: String {
        activeDetail?.summary.displayTitle ?? "—"
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

/// Custom popover for the title-half pulldown. Replaced an earlier
/// `Menu`-based jump bar so the pulldown can:
///
///   * Open with the active conversation centered and gray-highlighted
///     (NSMenu has no programmatic scroll API). The auto-scroll on
///     appear replaces what used to be an explicit "現在の会話を中央
///     リストで見る" header row — opening the pulldown is now itself
///     the affordance for "show me where I am".
///   * Render multi-line conversation titles (NSMenu items are
///     single-line and truncate aggressively).
///   * Share visual language with the prompt-side `PromptOutlinePopover`
///     — both pulldowns now read as the same kind of "where am I in
///     this list" affordance.
private struct ConversationListPopover: View {
    let conversations: [ConversationSummary]
    let activeConversationID: String?
    let onSelect: (String) -> Void

    private let popoverWidth: CGFloat = 360
    private let popoverMaxHeight: CGFloat = 440

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(conversations.enumerated()), id: \.element.id) { offset, conversation in
                        ConversationListRow(
                            conversation: conversation,
                            isSelected: conversation.id == activeConversationID,
                            isAlternate: offset.isMultiple(of: 2),
                            onSelect: { onSelect(conversation.id) }
                        )
                        .id(conversation.id)
                    }
                }
            }
            .onAppear {
                // Same deferral as `PromptOutlinePopover.onAppear` —
                // `LazyVStack` rows aren't materialized synchronously on
                // first display, so an immediate `scrollTo` can land on
                // the wrong row (it scrolls to where the row WILL be
                // rather than where it lands once measured).
                guard let activeConversationID else { return }
                DispatchQueue.main.async {
                    proxy.scrollTo(activeConversationID, anchor: .center)
                }
            }
        }
        .frame(width: popoverWidth)
        .frame(maxHeight: popoverMaxHeight)
    }
}

private struct ConversationListRow: View {
    let conversation: ConversationSummary
    let isSelected: Bool
    let isAlternate: Bool
    let onSelect: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(conversation.displayTitle)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
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

    /// Same layering as `PromptOutlineRow.rowBackground` — gray
    /// highlight on the active conversation so the two pulldowns
    /// read as the same kind of pulldown.
    private var rowBackground: Color {
        if isSelected {
            return Color.secondary.opacity(0.22)
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

/// Custom popover for the prompt-half pulldown. Used instead of an
/// NSMenu so each row can render its prompt label as a 2-line block
/// (NSMenu items are single-line) and so the currently-active prompt
/// can carry a stronger highlight + checkmark than NSMenu's bare
/// "checked" state.
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
        // `ScrollViewReader` so we can re-anchor to the current
        // prompt every time the popover opens. Without this, opening
        // the pulldown for a 100-prompt conversation parks the user
        // at row 1 with no signal that their current row is way
        // further down — they have to manually scroll to find it.
        ScrollViewReader { proxy in
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
                        .id(prompt.id)
                    }
                }
            }
            .onAppear {
                // Defer one runloop turn so LazyVStack has a chance to
                // measure the rows; calling `scrollTo` synchronously
                // inside `onAppear` sometimes lands on the wrong row
                // because the lazy children haven't been instantiated
                // yet. `.center` anchor matches the viewer-mode pane's
                // selection-tracking scroll.
                guard let selectedPromptID else { return }
                DispatchQueue.main.async {
                    proxy.scrollTo(selectedPromptID, anchor: .center)
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
    /// The selection tint uses gray (not accent) per user request — the
    /// pulldown reads as a "where am I in the list" affordance, not a
    /// state toggle, so the muted gray fits its semantic load better
    /// and matches the title-side `ConversationListPopover`.
    private var rowBackground: Color {
        if isSelected {
            return Color.secondary.opacity(0.22)
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
///
/// Wraps `ShareLink` rather than presenting a save panel, so the user
/// gets the full system share sheet (AirDrop, Mail, Messages, Notes,
/// Save to Files, and any installed extensions) — matching the behavior
/// of the right-pane share button. The chip styling is preserved by
/// handing `ShareLink` a custom label and stripping its default button
/// chrome with `.buttonStyle(.plain)`.
struct WorkspaceFloatingExportButton: View {
    let detail: ConversationDetail?

    @State private var shareURL: URL?

    var body: some View {
        Group {
            if let detail, let shareURL {
                ShareLink(
                    item: shareURL,
                    preview: SharePreview(
                        detail.summary.title ?? "Conversation",
                        image: Image(systemName: "doc.text")
                    )
                ) {
                    chipLabel
                }
                .buttonStyle(.plain)
                .help("Share conversation")
            } else {
                // Disabled-looking placeholder while the markdown temp
                // file is being written, or when there's no conversation
                // loaded. Same geometry as the live button so the
                // toolbar doesn't jump on first render.
                Button {} label: {
                    chipLabel
                }
                .buttonStyle(.plain)
                .disabled(true)
                .opacity(detail == nil ? 0.4 : 0.6)
                .help(detail == nil ? "Export as Markdown" : "Preparing…")
            }
        }
        .task(id: detail?.summary.id) {
            guard let detail else {
                shareURL = nil
                return
            }
            shareURL = await MarkdownExporter.writeTempShareFile(for: detail)
        }
    }

    @ViewBuilder
    private var chipLabel: some View {
        #if os(macOS)
        // Glass chip — matches the sort / date / outline controls so the
        // three panes' top bars read as one family of translucent
        // buttons. `.title3` (~20pt) icon size is shared with the
        // calendar + viewer-mode glyphs so the icon-only chips carry
        // visible presence against the 30pt chip height.
        Image(systemName: "square.and.arrow.up")
            .font(.title3.weight(.semibold))
            .headerIconChipStyle()
        #else
        Image(systemName: "square.and.arrow.up")
        #endif
    }
}
