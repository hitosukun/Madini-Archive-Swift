import SwiftUI

/// The four mutually-exclusive display states of the workspace's
/// **middle pane**. Per the three-pane architecture, the segment picker
/// in the top bar selects a representation of the SQL database for the
/// middle pane to render — left and right pane behavior is unaffected
/// by this enum (modulo the `.focus` case which collapses the middle
/// column entirely).
///
/// The four modes are ordered as a single cascade the user moves
/// through left-to-right via the toolbar picker or trackpad swipe:
///
///   `.table` → `.default` → `.viewer` → `.focus`
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

    var id: String { rawValue }

    /// Japanese label shown as the tooltip on the toolbar picker.
    var displayName: String {
        switch self {
        case .table: return "テーブル"
        case .default: return "デフォルト"
        case .viewer: return "ビューアー"
        case .focus: return "フォーカス"
        }
    }

    /// SF Symbol rendered inside the toolbar picker segment. Chosen to
    /// match Finder's segmented view-picker style (four distinct
    /// glyphs, same optical weight) so the control reads as a familiar
    /// macOS affordance rather than a custom widget.
    var systemImage: String {
        switch self {
        case .table: return "tablecells"
        case .default: return "rectangle.split.3x1"
        case .viewer: return "book.pages"
        case .focus: return "doc.plaintext"
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
    func stepTowardFocus(canEnterViewer: Bool) -> MiddlePaneMode {
        switch self {
        case .table: return .default
        case .default: return canEnterViewer ? .viewer : .default
        case .viewer: return .focus
        case .focus: return .focus
        }
    }

    /// Cascade neighbor one step toward overview (RIGHT swipe).
    /// Returns `self` at the `.table` end so over-swiping is
    /// idempotent, mirroring `stepTowardFocus`.
    func stepTowardOverview() -> MiddlePaneMode {
        switch self {
        case .focus: return .viewer
        case .viewer: return .default
        case .default: return .table
        case .table: return .table
        }
    }
}
