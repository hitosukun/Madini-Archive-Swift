#if os(macOS)
import SwiftUI

/// Single window-spanning top bar, always mounted over the
/// NavigationSplitView regardless of mode.
///
/// **Layout, strictly left-to-right:**
///
///   1. Traffic-light / sidebar-toggle clearance (leading spacer)
///   2. Flexible spacer
///   3. `ReaderHeaderActivityPill` — the combined title + prompt-outline
///      capsule. Shown in `.default` / `.viewer` / `.hidden`; hidden in
///      `.table` (nothing to read from).
///   4. `WorkspaceFloatingExportButton` (share) — always visible
///   5. `MiddlePaneModePicker` — always trailing, fixed size
///
/// **Pane responsibilities (see `project_three_pane_architecture`).**
/// Sort menu and date range picker control the *middle-pane content*,
/// so they live in the left sidebar (under the search field) — NOT in
/// this bar. Active filter chips also live in the sidebar (inside the
/// expanded search area). The source-origin pill and tag editor are
/// per-conversation reader concerns and live in the right pane's
/// `ConversationHeaderView`. This top bar is reserved for the activity
/// pill, share, and segment picker — Finder-/Safari-style window
/// chrome that we may extend with navigation affordances later.
struct UnifiedWorkspaceTopBar: View {
    @Binding var viewMode: MiddlePaneMode
    @Bindable var tabManager: ReaderTabManager
    /// True when the NavigationSplitView sidebar is collapsed — drives
    /// the traffic-light clearance spacer width. When the sidebar is
    /// visible it takes the traffic-light room itself.
    let sidebarIsCollapsed: Bool
    /// Parent-supplied handler for "tap title pill" — reveal the active
    /// conversation in the middle-pane list AND scroll the reader body
    /// to the top. `MacOSRootView` owns both sides of that combo since
    /// it holds references to both the library VM and the tab manager.
    let onTapTitle: () -> Void
    /// Conversations currently rendered by the middle pane (already
    /// filtered/sorted by the sidebar). Forwarded into the title-pill
    /// pulldown so the user can switch to a sibling conversation
    /// without leaving the reader.
    let conversations: [ConversationSummary]
    /// Switch the reader to a different conversation. Plumbed down
    /// to `ReaderHeaderActivityPill` and called from the pulldown's
    /// peer rows.
    let onSelectConversation: (String) -> Void
    /// Repository forwarded into the title pulldown so non-active
    /// rows can lazy-load their prompt outlines on expand. Optional
    /// — preview-style mounts that don't have a real repo can pass
    /// `nil` and the pulldown drops to a flat list.
    let repository: (any ConversationRepository)?

    var body: some View {
        HStack(spacing: WorkspaceLayoutMetrics.headerBarInteriorSpacing) {
            // Traffic-light / sidebar-toggle clearance. This bar sits
            // at window y=0 via `.ignoresSafeArea(.container, edges:
            // .top)`, which places it INSIDE the NSWindow titlebar
            // region. macOS draws the native traffic-light buttons
            // (and the NavigationSplitView's sidebar-toggle button)
            // ON TOP of SwiftUI content in that region, so anything
            // we put at x < (trafficLightsWidth + toggleWidth) ends
            // up hidden under the native buttons — the "sort / date
            // icons don't show up in default and table modes" bug.
            //
            // We therefore ALWAYS reserve leading room. The exact
            // width depends on sidebar state:
            //   * sidebar visible: ~78pt just for the traffic-light
            //     cluster. The sidebar-toggle button is over the
            //     content column's leading edge — which is past the
            //     sidebar's width — so the sort / date chips can sit
            //     safely in the sidebar column's titlebar region.
            //   * sidebar collapsed: ~140pt for traffic lights +
            //     toggle, since both now sit on the same column's
            //     leading edge.
            Color.clear.frame(
                width: sidebarIsCollapsed ? 140 : 78,
                height: 1
            )

            Spacer(minLength: 8)

            // Title + prompt combined pill. Suppressed in `.table`
            // because the table IS the browse surface — there's no
            // single "active conversation" to title.
            if viewMode != .table {
                ReaderHeaderActivityPill(
                    activeDetail: tabManager.activeDetail,
                    promptOutline: tabManager.promptOutline,
                    selectedPromptID: tabManager.selectedPromptID,
                    onSelectPrompt: { id in
                        tabManager.requestPromptSelection(id)
                    },
                    onTapTitle: onTapTitle,
                    conversations: conversations,
                    onSelectConversation: onSelectConversation,
                    repository: repository
                )
            }

            // Share button — always present. In table mode there's no
            // `activeDetail`, so the button renders in its disabled
            // placeholder state, which keeps its x-coordinate stable
            // across mode switches.
            WorkspaceFloatingExportButton(detail: tabManager.activeDetail)

            // Picker always last — fixed size, fixed position,
            // across all four modes. This is the single affordance
            // users rely on to navigate the cascade; keeping it at
            // a predictable x-coordinate is the whole point of the
            // unified-bar refactor.
            MiddlePaneModePicker(selection: $viewMode)
        }
        .padding(.horizontal, WorkspaceLayoutMetrics.headerBarHorizontalPadding)
        .frame(height: WorkspaceLayoutMetrics.headerBarContentRowHeight)
        .frame(maxWidth: .infinity)
        // Measure bar height so each pane underneath can apply the
        // correct `.safeAreaInset` above its first row of content.
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
#endif
