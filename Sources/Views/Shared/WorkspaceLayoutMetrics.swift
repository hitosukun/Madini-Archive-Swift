import SwiftUI

/// Centralized layout constants shared across the three-pane workspace.
///
/// All pane widths, header bar dimensions, and chrome paddings should be
/// read from here so the three panes stay visually aligned when tweaked.
enum WorkspaceLayoutMetrics {
    // MARK: - Sidebar (left) pane

    static let sidebarMinWidth: CGFloat = 260
    static let sidebarIdealWidth: CGFloat = 300
    static let sidebarMaxWidth: CGFloat = 360

    // MARK: - Content (middle) pane

    static let contentMinWidth: CGFloat = 320
    static let contentIdealWidth: CGFloat = 440
    static let contentMaxWidth: CGFloat = 560

    // MARK: - Header bar (middle + right panes share these)

    static let headerBarMinHeight: CGFloat = 46
    static let headerBarHorizontalPadding: CGFloat = 14
    static let headerBarVerticalPadding: CGFloat = 6
    static let headerBarInteriorSpacing: CGFloat = 12

    // MARK: - Pane interior chrome

    static let paneHorizontalPadding: CGFloat = 12
    static let paneTopPadding: CGFloat = 10
    static let paneBottomPadding: CGFloat = 8

    // MARK: - Shared corner radius for rounded chrome bits

    static let controlCornerRadius: CGFloat = 10
    static let chipCornerRadius: CGFloat = 8
}

/// A reusable header bar container used by both the middle and right panes.
///
/// Keeps the visual style (height, background, divider, paddings) consistent
/// so the two panes' top bars stay aligned even when ideas shift.
struct WorkspaceHeaderBar<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: WorkspaceLayoutMetrics.headerBarInteriorSpacing) {
            content()
        }
        .padding(.horizontal, WorkspaceLayoutMetrics.headerBarHorizontalPadding)
        .padding(.vertical, WorkspaceLayoutMetrics.headerBarVerticalPadding)
        .frame(minHeight: WorkspaceLayoutMetrics.headerBarMinHeight)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}
