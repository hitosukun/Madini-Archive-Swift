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

/// **The navigation bar.** Single connected capsule combining the
/// conversation-title pulldown and the prompt-outline pulldown — the
/// two halves are referred to together as "the navigation bar"
/// throughout the app. Previously rendered as two separate pills; the
/// user asked them merged into one window so "what am I reading /
/// where am I in it" reads as a single piece of chrome.
///
/// Layout, left to right:
///
///   [ Title ] > [ Prompt ]   N / M
///
/// Single capsule, single thin-material fill. A `>` chevron sits
/// between the two halves so the chip reads as a "Title › Prompt"
/// breadcrumb rather than two unrelated buttons under one capsule.
///
/// Mounted into the native window toolbar's `.principal` slot by
/// `MacOSRootView.workspaceSplitView` so it's present in every mode
/// (table included) and its x-coordinate doesn't jump as the user
/// cascades through middle-pane modes.
struct ReaderHeaderActivityPill: View {
    private static let titleSegmentMinWidth: CGFloat = 170
    private static let titleSegmentIdealWidth: CGFloat = 220
    private static let titleSegmentMaxWidth: CGFloat = 300
    private static let promptSegmentMinWidth: CGFloat = 170
    private static let promptSegmentIdealWidth: CGFloat = 230
    private static let promptSegmentMaxWidth: CGFloat = 320
    private static let pillMinWidth: CGFloat = 358
    private static let pillIdealWidth: CGFloat = 472
    private static let pillMaxWidth: CGFloat = 626
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
    @State private var measuredThreadSegmentWidth: CGFloat = Self.titleSegmentIdealWidth
    @State private var measuredPromptSegmentWidth: CGFloat = Self.promptSegmentIdealWidth

    var body: some View {
        // Xcode-style cascade breadcrumb: [thread popover] > [prompt popover]
        // in a soft capsule, with the positional counter pulled OUT
        // of the capsule and rendered as a separate trailing sibling.
        //
        // Information hierarchy: the pill carries the navigation path
        // (thread > prompt), nothing else. Meta like "1 / 5" doesn't
        // belong in the path — it's state about the current prompt,
        // not a step of the breadcrumb — so it sits outside the
        // capsule where the eye can separate "where am I" from "how
        // far in am I".
        //
        // Visual weight: thread is the primary axis (heavier font,
        // primary color), prompt is subordinate (regular weight,
        // secondary color). Reads "thread → prompt" rather than two
        // equal-rank hops.
        //
        // Each segment is a full-width button inside the capsule so the
        // hit target is the bar interior, not just the rendered text.
        // The popovers are also pinned to the exact same width as
        // their source segment so opening them does not suddenly widen
        // the navigation chrome.
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                threadMenu
                chevron
                promptMenu
            }
            .padding(.horizontal, 4)
            .frame(height: 24)
            .background(
                Capsule(style: .continuous)
                    .fill(.ultraThinMaterial)
                    .opacity(0.5)
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.03), lineWidth: 0.5)
            )
            .frame(
                minWidth: Self.pillMinWidth,
                idealWidth: Self.pillIdealWidth,
                maxWidth: Self.pillMaxWidth
            )

            if !promptOutline.isEmpty {
                // Positional meta, outside the breadcrumb capsule.
                // Tabular digits keep the column width stable as the
                // numerator grows past single digits.
                Text(promptCounterText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Thread segment (primary axis)

    private var threadMenu: some View {
        Button {
            guard activeDetail != nil || !conversations.isEmpty else { return }
            isPromptPopoverPresented = false
            isThreadPopoverPresented.toggle()
        } label: {
            segmentLabel(
                text: titleText,
                foregroundStyle: activeDetail == nil ? .secondary : .primary,
                weight: .semibold
            )
        }
        .buttonStyle(.plain)
        .frame(
            minWidth: Self.titleSegmentMinWidth,
            idealWidth: Self.titleSegmentIdealWidth,
            maxWidth: Self.titleSegmentMaxWidth,
            minHeight: Self.segmentHeight,
            maxHeight: Self.segmentHeight
        )
        .background(widthReader(ThreadSegmentWidthPreferenceKey.self))
        .onPreferenceChange(ThreadSegmentWidthPreferenceKey.self) { newWidth in
            measuredThreadSegmentWidth = clamped(
                newWidth,
                min: Self.titleSegmentMinWidth,
                max: Self.titleSegmentMaxWidth
            )
        }
        .disabled(activeDetail == nil && conversations.isEmpty)
        .help("会話を切り替え")
        .popover(isPresented: $isThreadPopoverPresented, arrowEdge: .bottom) {
            ConversationListPopover(
                conversations: conversations,
                activeConversationID: activeDetail?.summary.id,
                rowWidth: popoverWidth(
                    for: measuredThreadSegmentWidth,
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

    private var promptMenu: some View {
        Button {
            guard !promptOutline.isEmpty else { return }
            isThreadPopoverPresented = false
            isPromptPopoverPresented.toggle()
        } label: {
            segmentLabel(
                text: currentPromptTitle,
                foregroundStyle: .secondary,
                weight: .regular
            )
        }
        .buttonStyle(.plain)
        .frame(
            minWidth: Self.promptSegmentMinWidth,
            idealWidth: Self.promptSegmentIdealWidth,
            maxWidth: Self.promptSegmentMaxWidth,
            minHeight: Self.segmentHeight,
            maxHeight: Self.segmentHeight
        )
        .background(widthReader(PromptSegmentWidthPreferenceKey.self))
        .onPreferenceChange(PromptSegmentWidthPreferenceKey.self) { newWidth in
            measuredPromptSegmentWidth = clamped(
                newWidth,
                min: Self.promptSegmentMinWidth,
                max: Self.promptSegmentMaxWidth
            )
        }
        .disabled(promptOutline.isEmpty)
        .help("プロンプトを切り替え")
        .popover(isPresented: $isPromptPopoverPresented, arrowEdge: .bottom) {
            PromptOutlinePopover(
                prompts: promptOutline,
                selectedPromptID: selectedPromptID,
                rowWidth: popoverWidth(
                    for: measuredPromptSegmentWidth,
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

    // MARK: - Chevron divider

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)
    }

    private func segmentLabel(
        text: String,
        foregroundStyle: HierarchicalShapeStyle,
        weight: Font.Weight
    ) -> some View {
        HStack(spacing: 0) {
            Text(text)
                .font(.subheadline.weight(weight))
                .foregroundStyle(foregroundStyle)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func widthReader<Key: PreferenceKey>(_ key: Key.Type) -> some View where Key.Value == CGFloat {
        GeometryReader { proxy in
            Color.clear.preference(key: key, value: proxy.size.width)
        }
    }

    private func clamped(_ value: CGFloat, min: CGFloat, max: CGFloat) -> CGFloat {
        Swift.max(min, Swift.min(max, value))
    }

    private func popoverWidth(for segmentWidth: CGFloat, min: CGFloat, max: CGFloat) -> CGFloat {
        clamped(segmentWidth + 56, min: min, max: max)
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

private struct ThreadSegmentWidthPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct PromptSegmentWidthPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
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
