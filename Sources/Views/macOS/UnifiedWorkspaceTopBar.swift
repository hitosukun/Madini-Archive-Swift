#if os(macOS)
import SwiftUI

/// Single window-spanning top bar, always mounted over the
/// NavigationSplitView regardless of mode.
///
/// **Layout, strictly left-to-right:**
///
///   1. Traffic-light / sidebar-toggle clearance (leading spacer)
///   2. Flexible spacer
///   3. **Navigation bar** — `ReaderHeaderActivityPill`, the combined
///      title + prompt-outline capsule. Stays mounted in every mode
///      (including `.table`) so its x-coordinate doesn't jump as the
///      user cascades through modes.
///   4. `WorkspaceFloatingExportButton` (share) — always visible
///   5. `MiddlePaneModePicker` — always trailing, fixed size
///
/// **Pane responsibilities (see `project_three_pane_architecture`).**
/// Sort menu and date range picker control the *middle-pane content*,
/// so they live in the left sidebar (under the search field) — NOT in
/// this bar. Active filter chips also live in the sidebar (inside the
/// expanded search area). The source-origin pill and tag editor are
/// per-conversation reader concerns and live in the right pane's
/// `ConversationHeaderView`. This top bar is reserved for the navigation
/// bar, share, and segment picker — Finder-/Safari-style window chrome
/// that we may extend with further navigation affordances later.
struct UnifiedWorkspaceTopBar: View {
    @Binding var viewMode: MiddlePaneMode
    @Bindable var tabManager: ReaderTabManager
    /// True when the NavigationSplitView sidebar is collapsed — drives
    /// the traffic-light clearance spacer width. When the sidebar is
    /// visible it takes the traffic-light room itself.
    let sidebarIsCollapsed: Bool
    /// Conversations currently rendered by the middle pane (already
    /// filtered/sorted by the sidebar). Forwarded into the title-pill
    /// pulldown so the user can switch to a sibling conversation
    /// without leaving the reader.
    let conversations: [ConversationSummary]
    /// Switch the reader to a different conversation. Plumbed down
    /// to `ReaderHeaderActivityPill` and called from the pulldown's
    /// peer rows.
    let onSelectConversation: (String) -> Void
    /// Double-tap on the bar's blank area → scroll panes back to the
    /// top. Window chrome convention (matches macOS app titlebars and
    /// browser tab bars where double-clicking blank chrome jumps to
    /// the top of content). Parent owns the per-pane scroll plumbing
    /// since the bar itself doesn't hold scroll state.
    let onDoubleTapBlankArea: () -> Void

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

            // Navigation bar — title + prompt combined pill. Mounted in
            // every mode (table included) so its x-coordinate is stable
            // across mode switches and the user always has a way to
            // navigate to a peer conversation / prompt without leaving
            // the current pane layout. When no conversation is open the
            // pill renders a disabled placeholder; when one is open in
            // table mode the right pane is collapsed but the pill still
            // reflects (and lets the user change) the active tab.
            ReaderHeaderActivityPill(
                activeDetail: tabManager.activeDetail,
                promptOutline: tabManager.promptOutline,
                selectedPromptID: tabManager.selectedPromptID,
                onSelectPrompt: { id in
                    tabManager.requestPromptSelection(id)
                },
                conversations: conversations,
                onSelectConversation: onSelectConversation
            )

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
        // Tap-target layer behind the interactive controls. The chip,
        // share button, and mode picker sit visually in front and
        // continue to absorb their own clicks; double-taps on the
        // blank gutters between them (and to either side) fall through
        // to this background and trigger the scroll-to-top action.
        // `.contentShape(Rectangle())` is what makes a transparent
        // background hit-testable in SwiftUI — without it taps pass
        // straight through to whatever is below.
        .background(
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    onDoubleTapBlankArea()
                }
        )
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
