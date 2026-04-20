import SwiftUI
#if os(macOS)
import AppKit
#endif

struct ReaderWorkspaceView: View {
    @Bindable var tabManager: ReaderTabManager
    let repository: any ConversationRepository

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
        // Bottom fade only — the top used to fade under the overlay
        // bar, but with the standard window toolbar the system handles
        // that edge and a top fade just dims crisp content.
        .edgeFadeMask(
            top: 0,
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

/// **The navigation bar.** Xcode-style cascade breadcrumb rendered
/// inside a soft capsule: `[thread] > [prompt]`, with the "1 / N"
/// prompt counter hanging off outside the capsule as a separate
/// sibling.
///
/// **Design rules (anchored in this order):**
///
///   1. Right-side toolbar buttons never disappear. This pill is the
///      only part of the toolbar that compresses under window-width
///      pressure. The `.primaryAction` cluster (share, mode picker)
///      stays pinned at its natural size.
///   2. The pill shrinks via *truncation*, not via layout break. Text
///      gets `lineLimit(1) + .truncationMode(.tail)`, and the chevron
///      and counter are `fixedSize()` so they never distort.
///   3. Within the pill, the prompt half yields first (lower
///      `layoutPriority`), the thread half yields second, the chevron
///      never yields.
///   4. The "1 / N" counter is external to the breadcrumb capsule so
///      it stays readable even when the thread/prompt labels are
///      ellipsized. It's a higher `layoutPriority` sibling so it
///      survives longer than the capsule body.
///   5. The capsule itself uses `ViewThatFits` with 4 tiers
///      (full → medium → compact → thread-only) to gracefully fall
///      back when even tail-truncation would produce unreadable
///      output. Each tier has bounded segment max widths so
///      `ViewThatFits` can make a clean choice based on the proposed
///      width from the toolbar.
///
/// Mounted into the native window toolbar's `.principal` slot by
/// `MacOSRootView.workspaceSplitView` so it's present in every mode
/// and its x-coordinate doesn't jump as the user cascades through
/// middle-pane modes.
struct ReaderHeaderActivityPill: View {
    private enum HoveredSegment {
        case thread
        case prompt
    }

    /// Tier presets for `ViewThatFits`. `full` is what shows on
    /// comfortably wide windows; `threadOnly` is the last fallback
    /// before everything collapses to just the counter. Each tier
    /// declares the max width each text segment is allowed to take —
    /// below those caps the segments naturally shrink via truncation.
    private struct Tier {
        let threadMaxWidth: CGFloat
        let promptMaxWidth: CGFloat?  // nil = prompt replaced by "…"
        let showsChevron: Bool
    }

    // Tier widths are applied via `.frame(width:)` at the segment
    // level, which pins *both* ideal and max. That's deliberate — if
    // we used `maxWidth` alone, every tier would report the same
    // natural text width as its ideal, and `ViewThatFits` would never
    // be able to tell them apart (it'd always pick tier 0 even when
    // there's no room for it). Fixed widths give `ViewThatFits` a
    // clean ideal-size ladder to descend.
    private static let tiers: [Tier] = [
        // Comfortable width: both segments have room to breathe.
        Tier(threadMaxWidth: 260, promptMaxWidth: 280, showsChevron: true),
        // Medium width: segments cap earlier → tail-truncation kicks in.
        Tier(threadMaxWidth: 180, promptMaxWidth: 160, showsChevron: true),
        // Compact width: prompt half is aggressively squeezed first.
        Tier(threadMaxWidth: 120, promptMaxWidth: 70,  showsChevron: true),
        // Very narrow: prompt is dropped entirely, replaced by "…" —
        // the thread title still reads + chevron signals "there's more
        // under the hood, click to see the full prompt list."
        Tier(threadMaxWidth: 120, promptMaxWidth: nil, showsChevron: true),
        // Thread-only, still with chevron-like "…" affordance dropped.
        Tier(threadMaxWidth: 90, promptMaxWidth: nil, showsChevron: false),
        // Absolute last resort — barely-there sliver that just shows
        // "…" truncation. Counter + right toolbar buttons stay visible.
        Tier(threadMaxWidth: 48, promptMaxWidth: nil, showsChevron: false),
    ]

    private static let segmentHeight: CGFloat = 22
    private static let titlePopoverMinWidth: CGFloat = 300
    private static let titlePopoverMaxWidth: CGFloat = 420
    private static let promptPopoverMinWidth: CGFloat = 280
    private static let promptPopoverMaxWidth: CGFloat = 380

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
    /// When the title pulldown opens, the parent can reveal the active
    /// conversation in the middle pane so the popover and the
    /// underlying list stay aligned.
    let onTitlePulldownOpen: () -> Void

    @State private var isThreadPopoverPresented = false
    @State private var isPromptPopoverPresented = false
    @State private var hoveredSegment: HoveredSegment?

    var body: some View {
        // Two siblings in one horizontal stack:
        //   * `breadcrumbCapsule` — the shrinkable part. `ViewThatFits`
        //     picks a tier based on the width the toolbar proposes.
        //   * `counterView` — a `fixedSize`, high-`layoutPriority`
        //     annotation that rides alongside. It survives every
        //     reasonable shrink, so "how far in am I" stays legible
        //     even when the thread/prompt labels are ellipsized.
        //
        // `layoutPriority` difference (capsule 1 vs counter 2) tells
        // SwiftUI: if there's not enough room for both at their ideal
        // widths, give the counter its natural size first and squeeze
        // the capsule. The capsule's internal `ViewThatFits` then
        // picks the tightest tier that fits the squeezed width.
        HStack(spacing: 8) {
            breadcrumbCapsule
                .layoutPriority(1)

            if !promptOutline.isEmpty {
                counterView
                    .layoutPriority(2)
                    .fixedSize()
            }
        }
        .animation(.easeInOut(duration: 0.12), value: hoveredSegment == .thread)
        .animation(.easeInOut(duration: 0.12), value: hoveredSegment == .prompt)
        .animation(.easeInOut(duration: 0.12), value: isThreadPopoverPresented)
        .animation(.easeInOut(duration: 0.12), value: isPromptPopoverPresented)
    }

    // MARK: - Breadcrumb capsule (tiered)

    /// The whole breadcrumb body, picking the first tier that fits
    /// the proposed width. Capsule shell is shared across tiers so the
    /// background / border geometry stays identical through the stage
    /// transitions.
    private var breadcrumbCapsule: some View {
        ViewThatFits(in: .horizontal) {
            ForEach(Self.tiers.indices, id: \.self) { index in
                tierLayout(Self.tiers[index])
            }
        }
    }

    @ViewBuilder
    private func tierLayout(_ tier: Tier) -> some View {
        HStack(spacing: 2) {
            threadMenu(maxWidth: tier.threadMaxWidth)
                // Thread is the primary axis — shrinks second.
                .layoutPriority(2)

            if tier.showsChevron {
                chevron
                    // Chevron is a glyph: never compress it, it should
                    // read crisp at every tier.
                    .fixedSize()
            }

            if let promptMax = tier.promptMaxWidth {
                promptMenu(maxWidth: promptMax)
                    // Prompt is the subordinate axis — shrinks first.
                    .layoutPriority(1)
            } else if tier.showsChevron {
                // Tier dropped the prompt entirely. Emit a tiny
                // disclosure-style affordance so the user still knows
                // there's a prompt pulldown behind the chevron.
                // Rendered as a popover-opening button so they can
                // still reach the outline from this width.
                collapsedPromptStub
                    .fixedSize()
            }
        }
        .padding(.horizontal, 4)
        .frame(height: 24)
        .background(capsuleBackground)
    }

    private var capsuleBackground: some View {
        ZStack {
            Capsule(style: .continuous)
                .fill(.ultraThinMaterial)
                .opacity(0.5)
            Capsule(style: .continuous)
                .strokeBorder(Color.primary.opacity(0.03), lineWidth: 0.5)
        }
    }

    // MARK: - Thread segment (primary axis)

    private func threadMenu(maxWidth: CGFloat) -> some View {
        Button {
            guard activeDetail != nil || !conversations.isEmpty else { return }
            isPromptPopoverPresented = false
            isThreadPopoverPresented.toggle()
        } label: {
            segmentLabel(
                text: titleText,
                foregroundStyle: activeDetail == nil ? .secondary : .primary,
                weight: .semibold,
                showsDisclosure: isThreadHighlighted
            )
        }
        .buttonStyle(.plain)
        // Pin the segment to the tier's width. See the comment on
        // `Tier` / `tiers` — fixed widths let `ViewThatFits` actually
        // distinguish tiers by reported ideal size. The inner Text
        // uses `lineLimit(1) + truncationMode(.tail)`, so as the
        // pinned frame shrinks, the label tail-truncates instead of
        // blowing past.
        .frame(width: maxWidth)
        .frame(minHeight: Self.segmentHeight, maxHeight: Self.segmentHeight)
        .background(segmentBackground(isHighlighted: isThreadHighlighted))
        .onHover { isHovering in
            hoveredSegment = isHovering ? .thread : (hoveredSegment == .thread ? nil : hoveredSegment)
        }
        .disabled(activeDetail == nil && conversations.isEmpty)
        .help("会話を切り替え")
        .popover(isPresented: $isThreadPopoverPresented, arrowEdge: .bottom) {
            ConversationListPopover(
                conversations: conversations,
                activeConversationID: activeDetail?.summary.id,
                rowWidth: popoverWidth(
                    for: maxWidth,
                    min: Self.titlePopoverMinWidth,
                    max: Self.titlePopoverMaxWidth
                ),
                onSelect: { id in
                    onSelectConversation(id)
                    isThreadPopoverPresented = false
                },
                onOpen: onTitlePulldownOpen
            )
        }
    }

    // MARK: - Prompt segment (subordinate)

    private func promptMenu(maxWidth: CGFloat) -> some View {
        Button {
            guard !promptOutline.isEmpty else { return }
            isThreadPopoverPresented = false
            isPromptPopoverPresented.toggle()
        } label: {
            segmentLabel(
                text: currentPromptTitle,
                foregroundStyle: .secondary,
                weight: .regular,
                showsDisclosure: isPromptHighlighted
            )
        }
        .buttonStyle(.plain)
        // Same fixed-width pattern as `threadMenu` — see the tier
        // comment for why this is `width:` not `maxWidth:`.
        .frame(width: maxWidth)
        .frame(minHeight: Self.segmentHeight, maxHeight: Self.segmentHeight)
        .background(segmentBackground(isHighlighted: isPromptHighlighted))
        .onHover { isHovering in
            hoveredSegment = isHovering ? .prompt : (hoveredSegment == .prompt ? nil : hoveredSegment)
        }
        .disabled(promptOutline.isEmpty)
        .help("プロンプトを切り替え")
        .popover(isPresented: $isPromptPopoverPresented, arrowEdge: .bottom) {
            PromptOutlinePopover(
                prompts: promptOutline,
                selectedPromptID: selectedPromptID,
                rowWidth: popoverWidth(
                    for: maxWidth,
                    min: Self.promptPopoverMinWidth,
                    max: Self.promptPopoverMaxWidth
                ),
                onSelect: { id in
                    onSelectPrompt(id)
                    isPromptPopoverPresented = false
                }
            )
        }
    }

    // MARK: - Collapsed prompt stub

    /// Renders in very narrow tiers where the prompt label is dropped.
    /// Keeps the popover reachable — tapping the "…" still opens the
    /// prompt outline so the user can navigate even when there's no
    /// room for the prompt text.
    private var collapsedPromptStub: some View {
        Button {
            guard !promptOutline.isEmpty else { return }
            isThreadPopoverPresented = false
            isPromptPopoverPresented.toggle()
        } label: {
            Text("…")
                .font(.subheadline.weight(.regular))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .frame(minHeight: Self.segmentHeight, maxHeight: Self.segmentHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(segmentBackground(isHighlighted: isPromptHighlighted))
        .onHover { isHovering in
            hoveredSegment = isHovering ? .prompt : (hoveredSegment == .prompt ? nil : hoveredSegment)
        }
        .disabled(promptOutline.isEmpty)
        .help("プロンプトを切り替え")
        .popover(isPresented: $isPromptPopoverPresented, arrowEdge: .bottom) {
            PromptOutlinePopover(
                prompts: promptOutline,
                selectedPromptID: selectedPromptID,
                rowWidth: Self.promptPopoverMinWidth,
                onSelect: { id in
                    onSelectPrompt(id)
                    isPromptPopoverPresented = false
                }
            )
        }
    }

    // MARK: - Counter (independent sibling)

    /// Positional meta outside the breadcrumb capsule. Tabular digits
    /// keep the column width stable as the numerator grows past single
    /// digits. `fixedSize()` + higher `layoutPriority` at the call
    /// site keeps it visible as the capsule shrinks.
    private var counterView: some View {
        Text(promptCounterText)
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    // MARK: - Chevron divider

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)
            .opacity(isThreadHighlighted ? 0.25 : 1)
    }

    private func segmentLabel(
        text: String,
        foregroundStyle: HierarchicalShapeStyle,
        weight: Font.Weight,
        showsDisclosure: Bool
    ) -> some View {
        HStack(spacing: 6) {
            Text(text)
                .font(.subheadline.weight(weight))
                .foregroundStyle(foregroundStyle)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "chevron.down")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .opacity(showsDisclosure ? 1 : 0)
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func segmentBackground(isHighlighted: Bool) -> some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(Color.primary.opacity(isHighlighted ? 0.08 : 0))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color.primary.opacity(isHighlighted ? 0.06 : 0), lineWidth: 0.5)
            )
    }

    private func clamped(_ value: CGFloat, min: CGFloat, max: CGFloat) -> CGFloat {
        Swift.max(min, Swift.min(max, value))
    }

    private func popoverWidth(for segmentWidth: CGFloat, min: CGFloat, max: CGFloat) -> CGFloat {
        clamped(segmentWidth + 56, min: min, max: max)
    }

    private var isThreadHighlighted: Bool {
        hoveredSegment == .thread || isThreadPopoverPresented
    }

    private var isPromptHighlighted: Bool {
        hoveredSegment == .prompt || isPromptPopoverPresented
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

private struct ConversationListPopover: View {
    let conversations: [ConversationSummary]
    let activeConversationID: String?
    let rowWidth: CGFloat
    let onSelect: (String) -> Void
    let onOpen: () -> Void

    private let popoverMaxHeight: CGFloat = 440

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(conversations.enumerated()), id: \.element.id) { offset, conversation in
                        ConversationListRow(
                            conversation: conversation,
                            rowWidth: rowWidth,
                            isSelected: conversation.id == activeConversationID,
                            isAlternate: offset.isMultiple(of: 2),
                            onSelect: { onSelect(conversation.id) }
                        )
                        .id(conversation.id)
                    }
                }
            }
            .task {
                onOpen()
                await scrollToActive(proxy: proxy)
            }
            .onChange(of: conversations.count) { _, _ in
                Task { await scrollToActive(proxy: proxy) }
            }
        }
        .frame(width: rowWidth)
        .frame(maxHeight: popoverMaxHeight)
    }

    private func scrollToActive(proxy: ScrollViewProxy) async {
        guard let activeConversationID else { return }
        for _ in 0..<10 {
            if conversations.contains(where: { $0.id == activeConversationID }) {
                break
            }
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
        try? await Task.sleep(nanoseconds: 40_000_000)
        proxy.scrollTo(activeConversationID, anchor: .center)
        try? await Task.sleep(nanoseconds: 80_000_000)
        proxy.scrollTo(activeConversationID, anchor: .center)
    }
}

private struct ConversationListRow: View {
    let conversation: ConversationSummary
    let rowWidth: CGFloat
    let isSelected: Bool
    let isAlternate: Bool
    let onSelect: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onSelect) {
            Text(conversation.displayTitle)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(width: rowWidth, alignment: .leading)
                .background(rowBackground)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }

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

private struct PromptOutlinePopover: View {
    let prompts: [ConversationPromptOutlineItem]
    let selectedPromptID: String?
    let rowWidth: CGFloat
    let onSelect: (String) -> Void

    private let popoverMaxHeight: CGFloat = 440

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(prompts.enumerated()), id: \.element.id) { offset, prompt in
                        PromptOutlineRow(
                            prompt: prompt,
                            rowWidth: rowWidth,
                            isSelected: selectedPromptID == prompt.id,
                            isAlternate: offset.isMultiple(of: 2),
                            onSelect: { onSelect(prompt.id) }
                        )
                        .id(prompt.id)
                    }
                }
            }
            .onAppear {
                guard let selectedPromptID else { return }
                DispatchQueue.main.async {
                    proxy.scrollTo(selectedPromptID, anchor: .center)
                }
            }
        }
        .frame(width: rowWidth)
        .frame(maxHeight: popoverMaxHeight)
    }
}

private struct PromptOutlineRow: View {
    let prompt: ConversationPromptOutlineItem
    let rowWidth: CGFloat
    let isSelected: Bool
    let isAlternate: Bool
    let onSelect: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onSelect) {
            Text(prompt.label)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(width: rowWidth, alignment: .leading)
                .background(rowBackground)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }

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
                .help("Share conversation")
            } else {
                // Disabled-looking placeholder while the markdown temp
                // file is being written, or when there's no conversation
                // loaded. Same geometry as the live button so the
                // toolbar doesn't jump on first render.
                Button {} label: {
                    chipLabel
                }
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
        // Deliberately bare: just the SF Symbol at the standard
        // toolbar glyph size. We let SwiftUI's default toolbar
        // button style own the chrome around it — hover tint, press
        // state, keyboard focus ring, and sizing all come from the
        // system, matching every other native toolbar button in
        // Finder / Mail / Notes.
        //
        // **Why no `.buttonStyle(.plain)`, no custom `.frame(...)`,
        // no `.contentShape(...)`.** Each of those overrides a piece
        // of the default toolbar-button chrome. `.plain` kills the
        // hover/press tint; explicit frames shrink the click area
        // below the system default (~28×24); `.contentShape` gates
        // hit-testing in a way that fights the style's own target
        // rect. Removing them all lets the button render at the
        // exact same visual weight as a neighbouring
        // `NSSegmentedControl` segment, which is what L1 / L3 of
        // the low-risk pass asked for.
        //
        // `.font(.body.weight(.regular))` pins the glyph to the
        // toolbar body size (~15pt). Without it the symbol
        // occasionally picked up an inherited smaller font from the
        // ShareLink ancestor and read thin next to the segmented
        // control images.
        Image(systemName: "square.and.arrow.up")
            .font(.body.weight(.regular))
    }
}
