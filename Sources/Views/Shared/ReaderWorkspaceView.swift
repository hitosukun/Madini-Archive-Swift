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
/// Mounted into the native window toolbar's `.principal` slot by
/// `MacOSRootView.workspaceSplitView` so it's present in every mode
/// (table included) and its x-coordinate doesn't jump as the user
/// cascades through middle-pane modes.
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
    /// Fires when the title pulldown is opened. The parent uses this to
    /// reveal the active conversation in the underlying middle pane —
    /// scroll the card list to it, or select + scroll the table to it.
    /// Driven from the popover's `.task`, not the button's tap action,
    /// so single-shot reveals fire even if the user closes and reopens
    /// the pulldown without ever tapping a row.
    let onTitlePulldownOpen: () -> Void

    var body: some View {
        // Xcode-style cascade breadcrumb: [thread Menu] > [prompt Menu]
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
        // Menus (not popovers): the user explicitly asked for the
        // Xcode jump-bar cascade feel. An earlier iteration used
        // custom popovers to support "scroll to active row + gray
        // highlight on current"; that affordance is lost with NSMenu
        // (single-line items, opens at top with no scroll API). The
        // call site's `onTitlePulldownOpen` hook is still accepted
        // for source compatibility but no longer fires — there is no
        // reliable Menu-open hook without dropping into AppKit.
        //
        // Width behavior: each segment is pinned by an outer
        // `.frame(width:)` on the Menu itself (thread 130pt,
        // prompt 80pt). The fixed width has to go on the Menu,
        // not on the Text label inside the Menu's label closure —
        // `.menuStyle(.borderlessButton)` reads the label's natural
        // content size for its own layout and ignores width frames
        // set deeper in the label's view tree, so a `.frame(width:)`
        // on the Text (or even a prior `.fixedSize()` on the Menu)
        // let long prompts blow the pill out to their full natural
        // width. Pinning the Menu itself is authoritative: the label
        // then fills that fixed width and truncates with `.tail`.
        // Total pill footprint is ~220pt; stays visible at every
        // usable window size. The counter sibling is unconstrained
        // and may be clipped on very narrow windows.
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
        Menu {
            ForEach(conversations) { summary in
                Button {
                    onSelectConversation(summary.id)
                } label: {
                    if activeDetail?.summary.id == summary.id {
                        Label(summary.displayTitle, systemImage: "checkmark")
                    } else {
                        Text(summary.displayTitle)
                    }
                }
            }
        } label: {
            Text(titleText)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(activeDetail == nil ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6)
                .frame(height: 22)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 130)
        .disabled(activeDetail == nil && conversations.isEmpty)
        .help("会話を切り替え")
    }

    // MARK: - Prompt segment (subordinate)

    private var promptMenu: some View {
        Menu {
            ForEach(promptOutline) { prompt in
                Button {
                    onSelectPrompt(prompt.id)
                } label: {
                    if selectedPromptID == prompt.id {
                        Label(prompt.label, systemImage: "checkmark")
                    } else {
                        Text(prompt.label)
                    }
                }
            }
        } label: {
            Text(currentPromptTitle)
                .font(.subheadline.weight(.regular))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6)
                .frame(height: 22)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 80)
        .disabled(promptOutline.isEmpty)
        .help("プロンプトを切り替え")
    }

    // MARK: - Chevron divider

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)
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
    let onAppear: () -> Void

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
            .task {
                // Reveal the active card in the underlying middle pane
                // (so the user can see it both inside the pulldown AND
                // in the list/table behind it). This may kick off async
                // pagination, which grows `conversations` a tick later
                // — the `.onChange` below re-scrolls once that lands.
                onAppear()
                await scrollToActive(proxy: proxy)
            }
            // Re-anchor whenever the backing array changes size. The
            // first pulldown open after selecting a new conversation
            // used to miss the scroll because `onAppear` triggers
            // pagination that extends `conversations` AFTER our initial
            // `scrollTo` fires, invalidating the LazyVStack layout.
            // Firing again on every count change catches the row once
            // pagination settles.
            .onChange(of: conversations.count) { _, _ in
                Task { await scrollToActive(proxy: proxy) }
            }
        }
        .frame(width: popoverWidth)
        .frame(maxHeight: popoverMaxHeight)
    }

    /// Wait until the active row is actually present in the backing
    /// array, then scroll to it. We poll at 40ms intervals for up to
    /// ~400ms because `revealConversation(_:)` paginates asynchronously
    /// — firing `scrollTo` before the row exists is a no-op, and firing
    /// right as pagination lands loses the scroll to the layout
    /// invalidation that follows. Two `scrollTo` calls separated by
    /// another short sleep cover the case where the first pass bounced
    /// because `LazyVStack` hadn't materialized the target yet.
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
