import SwiftUI

/// The five mutually-exclusive display states of the workspace's
/// **middle pane**. Per the three-pane architecture, the segment picker
/// in the top bar selects a representation of the SQL database for the
/// middle pane to render — left and right pane behavior is unaffected
/// by this enum (modulo the `.focus` case which collapses the middle
/// column entirely, and `.stats` which replaces the conversation list
/// with the Dashboard).
///
/// Four of the five modes form a single cascade the user moves through
/// left-to-right via the toolbar picker or trackpad swipe:
///
///   `.table` → `.default` → `.viewer` → `.focus`
///
/// `.stats` (Dashboard) sits outside that cascade as a derived view on
/// the archive — it's reachable from the toolbar picker, the keyboard
/// shortcut `⌘4`, and the sidebar `Dashboard` row, but the swipe
/// gesture deliberately does not pull the user into or out of it
/// (entering/leaving Stats is always an explicit, named action).
///
/// Replaces the three independent `is*Active: Bool` flags
/// `MacOSRootView` used to juggle, which permitted contradictory
/// combinations (e.g. table + viewer both "on" at once — a real class
/// of bug) at the type level.
enum MiddlePaneMode: String, CaseIterable, Identifiable, Hashable {
    /// Full-width sortable spreadsheet of every conversation passing
    /// the sidebar filters. The detail (right) pane is collapsed to
    /// zero width so the middle pane absorbs the whole content area.
    /// Sidebar stays user-controllable because the user may still want
    /// to narrow / widen the filter set while scanning the table.
    case table
    /// The three-column default layout the app opens in: sidebar +
    /// card list + reader. Sidebar and detail are both user-
    /// controllable; no column is clamped.
    case `default`
    /// Immersive two-column reading: sidebar is force-hidden, middle
    /// pane shows a flat prompt directory for the active conversation,
    /// right pane is the full-height reader.
    case viewer
    /// Middle pane collapsed to zero width: both sidebar and middle
    /// pane disappear, the prompt outline moves to a pulldown on the
    /// top toolbar, and the reader alone occupies the content area.
    case focus
    /// Dashboard: middle pane renders aggregated charts (heatmaps,
    /// distributions, monthly totals) over the conversations passing
    /// the active filter scope. The right pane behavior follows the
    /// `.default` shape; the sidebar stays user-controllable. This is
    /// a derived / cache view in AGENTS.md terms — counts are not
    /// persisted, every render is a fresh GROUP BY against the SQL
    /// store via `StatsRepository`.
    case stats

    var id: String { rawValue }

    /// Localized label shown as the tooltip on the toolbar picker.
    /// Uses `String(localized:)` so the surrounding AppKit / SwiftUI
    /// API call sites that expect a plain `String` (NSToolTip,
    /// `accessibilityDescription`, etc.) get the right per-locale form.
    var displayName: String {
        switch self {
        case .table: return String(localized: "Table")
        case .default: return String(localized: "Default")
        case .viewer: return String(localized: "Viewer")
        case .focus: return String(localized: "Focus")
        case .stats: return String(localized: "Dashboard")
        }
    }

    /// SF Symbol rendered inside the toolbar picker segment. Chosen to
    /// match Finder's segmented view-picker style (five distinct
    /// glyphs, same optical weight) so the control reads as a familiar
    /// macOS affordance rather than a custom widget.
    var systemImage: String {
        switch self {
        case .table: return "tablecells"
        case .default: return "rectangle.split.3x1"
        case .viewer: return "book.pages"
        case .focus: return "doc.plaintext"
        case .stats: return "chart.bar.xaxis"
        }
    }

    /// Cascade neighbor one step toward the focus / single-pane end
    /// (LEFT swipe on a natural-scrolling trackpad). Returns `self` at
    /// the end of the cascade so an over-swipe is idempotent rather
    /// than dropping the user out of the mode they're in.
    ///
    /// `canEnterViewer` gates the `.default → .viewer` step — no
    /// active conversation means there's nothing to focus on, so the
    /// step short-circuits.
    ///
    /// `.stats` is intentionally outside the cascade: a swipe inside
    /// Stats does nothing, matching the spec that entering / leaving
    /// the Dashboard is always an explicit picker / shortcut action.
    func stepTowardFocus(canEnterViewer: Bool) -> MiddlePaneMode {
        switch self {
        case .table: return .default
        case .default: return canEnterViewer ? .viewer : .default
        case .viewer: return .focus
        case .focus: return .focus
        case .stats: return .stats
        }
    }

    /// Cascade neighbor one step toward overview (RIGHT swipe).
    /// Returns `self` at the `.table` end so over-swiping is
    /// idempotent, mirroring `stepTowardFocus`. `.stats` is again
    /// idempotent for the same reason.
    func stepTowardOverview() -> MiddlePaneMode {
        switch self {
        case .focus: return .viewer
        case .viewer: return .default
        case .default: return .table
        case .table: return .table
        case .stats: return .stats
        }
    }
}
