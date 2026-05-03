import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// Middle-pane view that replaces the scrolling card list while the user
/// is in Viewer Mode (toggled from the right-pane toolbar — see
/// `ReaderWorkspaceView.ViewerModeToggleButton`). Shows a flat prompt
/// directory index. Clicking a prompt row asks the reader (right pane)
/// to jump to that prompt via `ReaderTabManager.requestPromptSelection`.
///
/// The conversation title used to live here as a compact card at the top
/// of the pane, but the traffic-light clearance + card chrome ate roughly
/// 60% of the horizontal room at the sidebar-collapsed widths the user
/// actually uses Viewer Mode at. The title was also getting faded by the
/// content-under-toolbar mask. Both problems are solved by moving the
/// title into the right pane's header bar (see
/// `ReaderWorkspaceHeaderBar.viewerModeTitleChip`) — the right pane has
/// more horizontal room, no traffic-light to dodge, and its own chip bar
/// already exists.
///
/// Unlike the old per-card pin, this pane is driven by whichever tab is
/// active in the reader pane — switching tabs reloads the outline. The
/// parent view (`MacOSRootView`) passes that active conversation id in via
/// `conversationID`, and `.task(id:)` below handles the reload. The
/// currently-reading prompt (driven by the reader's scroll-position
/// observer) flows in via `selectedPromptID` so the matching row gets
/// highlighted and auto-scrolled into view.
struct ViewerModePane: View {
    @Bindable var viewModel: LibraryViewModel
    @Bindable var tabManager: ReaderTabManager
    /// The conversation currently open in the reader pane. `nil` when no
    /// tab is active — in that case the pane renders an unavailable
    /// placeholder (the entry button in the reader toolbar is already
    /// disabled in this state so this is mostly defensive).
    let conversationID: String?

    var body: some View {
        promptIndex
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Reload the outline whenever the active reader tab changes so
        // the middle pane tracks the reader's current conversation. The
        // VM short-circuits when the ID already matches.
        .task(id: conversationID) {
            if let conversationID {
                await viewModel.loadViewerConversation(id: conversationID)
            } else {
                viewModel.clearViewerData()
            }
        }
    }

    // MARK: - Prompt directory listing

    @ViewBuilder
    private var promptIndex: some View {
        if conversationID == nil {
            EmptyView()
        } else if viewModel.isLoadingViewerDetail, viewModel.viewerDetail == nil {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.viewerPromptOutline.isEmpty {
            ContentUnavailableView(
                "No Prompts",
                systemImage: "text.alignleft",
                description: Text("This conversation has no user prompts to list.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // `ScrollViewReader` so we can programmatically scroll the
            // highlighted row back into view when the reader's scroll
            // position leaves its visible region. Without this the row
            // gets marked selected but stays off-screen — the user sees
            // no visible response as they scroll on the right.
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        // Flat, dense listing — the "directory index" the
                        // user asked for. Zebra stripes by visual position
                        // (not prompt.index, which is the original message
                        // offset and would stripe unevenly).
                        ForEach(Array(viewModel.viewerPromptOutline.enumerated()), id: \.element.id) { offset, prompt in
                            ViewerPromptRow(
                                prompt: prompt,
                                isAlternate: offset.isMultiple(of: 2),
                                isSelected: isRowSelected(prompt),
                                onTap: { modifiers in
                                    handleRowTap(
                                        promptID: prompt.id,
                                        modifiers: modifiers
                                    )
                                }
                            )
                            .contextMenu {
                                contextMenuItems(for: prompt)
                            }
                            // Scroll target id so `proxy.scrollTo(id)`
                            // below can bring this row into view.
                            .id(prompt.id)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onChange(of: tabManager.selectedPromptID) { _, newID in
                    guard let newID else { return }
                    // `.center` keeps the currently-reading prompt around
                    // the middle of the list as the user reads on, which
                    // both reveals upcoming prompts and a bit of history.
                    // `.easeInOut 0.2s` is quick enough to feel linked to
                    // the scroll on the right but not so fast it snaps
                    // jarringly when scrolling rapidly.
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(newID, anchor: .center)
                    }
                }
                // Title-chip tap in the Viewer-Mode toolbar → scroll this
                // prompt directory back to its top. The right-pane
                // `ConversationDetailView` observes the same token and
                // snaps its body to the conversation header, so both
                // panes move together. `anchor: .top` (vs `.center` for
                // the selection-driven scroll above) because "up に戻る"
                // unambiguously means flush to the top, not centered.
                .onChange(of: tabManager.scrollToTopToken) { _, newValue in
                    guard newValue != nil,
                          let firstID = viewModel.viewerPromptOutline.first?.id else {
                        return
                    }
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(firstID, anchor: .top)
                    }
                    // Don't clear the token here — the reader pane
                    // (`LoadedConversationDetailView.onChange(of:
                    // scrollToTopToken)`) owns that, so observers who
                    // missed the current tick still see the non-nil
                    // value on their next layout pass.
                }
            }
        }
    }

    private var viewerSummary: ConversationSummary? {
        // Prefer the detail-backed summary when available (it has freshly
        // loaded metadata), otherwise fall back to whatever is already in
        // the list — which is the summary the user last interacted with.
        if let detail = viewModel.viewerDetail {
            return detail.summary
        }
        return viewModel.summary(for: viewModel.viewerConversationID)
    }

    // MARK: - Selection logic

    /// A row is rendered as "selected" under one of two conditions:
    ///   1. Multi-select is active (any rows in the set) → membership in
    ///      that set drives the highlight, and the reader's current
    ///      scroll position is intentionally ignored. The user has just
    ///      told us which rows they care about.
    ///   2. Multi-select is empty → fall back to the legacy single-row
    ///      "where is the reader parked" highlight.
    private func isRowSelected(_ prompt: ConversationPromptOutlineItem) -> Bool {
        if !tabManager.multiSelectedPromptIDs.isEmpty {
            return tabManager.multiSelectedPromptIDs.contains(prompt.id)
        }
        return prompt.id == tabManager.selectedPromptID
    }

    /// Dispatch a row tap to the appropriate selection mutation based on
    /// the keyboard modifiers held at click time. macOS Finder rules:
    ///
    ///   - **bare**: single-row select; clear any prior multi-select;
    ///     update the anchor; scroll the reader to that prompt.
    ///   - **⌘**: toggle one row in/out of the set; update the anchor.
    ///     The reader scroll *is* fired so prev/next chips and the
    ///     scroll-position observer stay in sync with the active row.
    ///   - **shift**: range from anchor → clicked row, replacing the set.
    ///     Anchor is *not* updated — extending the shift range from a
    ///     stable origin is the canonical Finder feel.
    ///   - **shift + ⌘**: range from anchor → clicked row, *unioned*
    ///     into the existing set. Useful for adding a contiguous block
    ///     to a non-contiguous selection.
    private func handleRowTap(
        promptID: String,
        modifiers: ViewerPromptRow.TapModifiers
    ) {
        let orderedIDs = viewModel.viewerPromptOutline.map(\.id)

        if modifiers.contains(.shift) {
            let anchor = tabManager.multiSelectAnchorID ?? promptID
            let range = idsInRange(
                anchor: anchor,
                target: promptID,
                in: orderedIDs
            )
            if modifiers.contains(.command) {
                tabManager.multiSelectedPromptIDs.formUnion(range)
            } else {
                tabManager.multiSelectedPromptIDs = range
            }
            tabManager.selectedPromptID = promptID
            // Anchor stays put — that's the point of shift-extension.
        } else if modifiers.contains(.command) {
            if tabManager.multiSelectedPromptIDs.contains(promptID) {
                tabManager.multiSelectedPromptIDs.remove(promptID)
            } else {
                tabManager.multiSelectedPromptIDs.insert(promptID)
            }
            tabManager.multiSelectAnchorID = promptID
            tabManager.selectedPromptID = promptID
            tabManager.requestPromptSelection(promptID)
        } else {
            // Bare click — restore the legacy single-row select +
            // reader-jump behaviour, plus clear any leftover multi-select.
            tabManager.multiSelectedPromptIDs = [promptID]
            tabManager.multiSelectAnchorID = promptID
            tabManager.selectedPromptID = promptID
            if let summary = viewerSummary {
                tabManager.openConversation(
                    id: summary.id,
                    title: summary.displayTitle
                )
            }
            tabManager.requestPromptSelection(promptID)
        }
    }

    /// Inclusive id range between two ids, ordered by their position in
    /// `ordered`. Falls back to `[target]` if either id is missing
    /// (defensive — shouldn't normally happen, but a stale anchor from a
    /// previous outline shouldn't crash the click).
    private func idsInRange(
        anchor: String,
        target: String,
        in ordered: [String]
    ) -> Set<String> {
        guard let i = ordered.firstIndex(of: anchor),
              let j = ordered.firstIndex(of: target) else {
            return [target]
        }
        let lo = min(i, j)
        let hi = max(i, j)
        return Set(ordered[lo...hi])
    }

    // MARK: - Context menu

    /// Build the right-click menu for a given row. Finder rule: if the
    /// right-clicked row is part of the active multi-selection, the
    /// action runs over the whole set; otherwise it runs over just that
    /// one row (without disturbing the existing set state).
    @ViewBuilder
    private func contextMenuItems(
        for prompt: ConversationPromptOutlineItem
    ) -> some View {
        Button {
            copySelectedConversation(rightClickedID: prompt.id)
        } label: {
            Text("Copy selected conversation")
        }
        .disabled(viewModel.viewerDetail == nil)
    }

    private func copySelectedConversation(rightClickedID: String) {
        guard let detail = viewModel.viewerDetail else { return }
        let ids: Set<String>
        if tabManager.multiSelectedPromptIDs.contains(rightClickedID) {
            ids = tabManager.multiSelectedPromptIDs
        } else {
            ids = [rightClickedID]
        }
        SelectedConversationClipboard.copy(
            detail: detail,
            selectedPromptIDs: ids
        )
    }
}

/// One entry in the viewer pane's prompt directory listing. The
/// row carries an accent-tinted background plus a trailing checkmark
/// when `isSelected` is true so the user can glance at the pane and
/// see which prompt the reader is currently parked on. Outside
/// selection the row shows only hover feedback + alternating stripes.
private struct ViewerPromptRow: View {
    /// Modifier flags read at click time so the caller can route the tap
    /// to the right selection-mutation branch (bare / ⌘ / shift /
    /// shift+⌘). Captured via `NSApp.currentEvent` inside the Button
    /// action because SwiftUI's `Button(action:)` itself doesn't surface
    /// the event modifiers — the action closure is `() -> Void`. iOS
    /// always sees the empty set; multi-select keyboard shortcuts are a
    /// macOS-only affordance for now (see Sub-B spec §G — keyboard
    /// shortcuts out of scope).
    struct TapModifiers: OptionSet {
        let rawValue: Int
        static let shift = TapModifiers(rawValue: 1 << 0)
        static let command = TapModifiers(rawValue: 1 << 1)
    }

    let prompt: ConversationPromptOutlineItem
    let isAlternate: Bool
    /// `true` when this row should render with the selection tint —
    /// either it's the prompt the reader is currently parked on, or the
    /// user has explicitly multi-selected it. Resolution lives in the
    /// parent (`ViewerModePane.isRowSelected(_:)`) so this struct stays
    /// agnostic of the two highlight sources.
    let isSelected: Bool
    let onTap: (TapModifiers) -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: handleTap) {
            HStack(alignment: .top, spacing: 10) {
                Text("\(prompt.index)")
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
            .contentShape(Rectangle())
            .background(rowBackground)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }

    /// Read modifier flags off the AppKit event currently being
    /// processed and forward them to the parent. `NSApp.currentEvent` is
    /// the SwiftUI-Button-friendly version of "what was the user doing
    /// when they clicked?" — `.gesture(TapGesture().modifiers(...))`
    /// stacks would have to coexist with the Button's own tap recognizer
    /// and the priority ordering between them is fragile across OS
    /// versions. Reading modifierFlags inside the `() -> Void` action
    /// closure avoids that whole problem.
    private func handleTap() {
        var mods: TapModifiers = []
        #if canImport(AppKit)
        if let flags = NSApp.currentEvent?.modifierFlags {
            if flags.contains(.shift) { mods.insert(.shift) }
            if flags.contains(.command) { mods.insert(.command) }
        }
        #endif
        onTap(mods)
    }

    /// Layering: selection tint > hover tint > zebra stripe > clear.
    /// The selection tint is strong enough to read at a glance even on
    /// top of the stripe it would otherwise inherit.
    private var rowBackground: Color {
        if isSelected {
            return Color.accentColor.opacity(0.18)
        }
        if isHovering {
            return Color.secondary.opacity(0.14)
        }
        if isAlternate {
            return Color.secondary.opacity(0.06)
        }
        return .clear
    }
}
