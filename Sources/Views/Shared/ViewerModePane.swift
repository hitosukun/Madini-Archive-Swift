import SwiftUI

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
    /// Space reserved at the top so the viewer-mode header card isn't
    /// hidden under a floating overlay. In practice viewer mode hides the
    /// middle-pane toolbar entirely, so callers pass `0` — but the
    /// parameter stays so this pane can be reused in contexts that DO
    /// float a bar above it without re-plumbing.
    var topContentInset: CGFloat = 0

    var body: some View {
        // Just the prompt directory now — the conversation title has
        // moved to the right pane's header bar. If the caller reserved
        // space above us (`topContentInset` > 0, e.g. a hypothetical
        // middle-pane toolbar sits above), honor it with a safeAreaInset
        // so the first row isn't hidden. In the Viewer-Mode path
        // `topContentInset` is 0 so the list sits flush with the top.
        promptIndex
            .safeAreaInset(edge: .top, spacing: 0) {
                if topContentInset > 0 {
                    Color.clear
                        .frame(height: topContentInset)
                        .allowsHitTesting(false)
                }
            }
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
                                isSelected: prompt.id == tabManager.selectedPromptID,
                                onSelect: {
                                    // Fire the one-shot signal the reader
                                    // pane is observing. If the reader is
                                    // currently showing a different
                                    // conversation, also ensure the
                                    // viewer-tracked one is active.
                                    if let summary = viewerSummary {
                                        tabManager.openConversation(
                                            id: summary.id,
                                            title: summary.displayTitle
                                        )
                                    }
                                    tabManager.requestPromptSelection(prompt.id)
                                }
                            )
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
}

/// One entry in the viewer pane's prompt directory listing. Matches the
/// reader-popover's `PromptOutlineRow` styling when `isSelected` is true
/// (accent-tinted background + trailing checkmark) so the two views
/// agree on what "the current prompt" looks like. Outside selection the
/// row shows only hover feedback + alternating stripes.
private struct ViewerPromptRow: View {
    let prompt: ConversationPromptOutlineItem
    let isAlternate: Bool
    /// `true` when this row corresponds to the prompt the reader is
    /// currently scrolled to. Drives the accent highlight + the right-
    /// aligned checkmark so the user can glance at the middle pane and
    /// see "where am I" without tracking the scroll position themselves.
    let isSelected: Bool
    let onSelect: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onSelect) {
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

    /// Layering: selection tint > hover tint > zebra stripe > clear.
    /// The selection tint is strong enough to read at a glance even on
    /// top of the stripe it would otherwise inherit. Matches the reader
    /// popover's `PromptOutlineRow.rowBackground` layering so both views
    /// agree on what "the current prompt" looks like.
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
