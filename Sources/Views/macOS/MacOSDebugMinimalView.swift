#if os(macOS)
import SwiftUI

/// Bare-bones `NavigationSplitView` with three text-only columns and
/// no toolbar, environment injection, drop handlers, overlays, or
/// tasks of any kind. Used as a diagnostic swap for `MacOSRootView`
/// to verify that the system-provided window chrome (title bar,
/// sidebar toggle, traffic lights) lays out correctly when nothing
/// in the app's view tree is modifying it.
///
/// Swap it in by flipping the `useMinimalDebugRoot` flag in
/// `RootView` (see `MadiniArchiveApp.swift`). If the sidebar toggle
/// is in its normal position and the title bar doesn't clip anything
/// with this view active, the bug is somewhere in `MacOSRootView`'s
/// tree — otherwise it's upstream of us (SDK / window creation).
struct MacOSDebugMinimalView: View {
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            Text("Sidebar")
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        } content: {
            Text("Content")
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        } detail: {
            Text("Detail")
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }
}
#endif
