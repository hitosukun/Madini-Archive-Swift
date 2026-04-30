import SwiftUI
#if os(macOS)
import AppKit

/// Thin SwiftUI wrapper around `NSVisualEffectView` for the specific
/// use-case of a frosted-glass header / footer bar pinned to a scroll
/// view (the middle pane's view-mode picker strip, the reader pane's
/// conversation-title strip, etc.).
///
/// Why a representable instead of `Material.bar` in a `.background(...)`
/// call? SwiftUI's named materials look right ONLY when the rendered
/// view sits in front of actual pixels that can be sampled — scroll
/// content underneath, a colored panel, etc. When the bar is the first
/// thing rendered inside an empty pane, `.bar` falls back to a nearly
/// opaque tint and the "frosted glass" effect never appears. Reaching
/// directly for `NSVisualEffectView` with `.headerView` material and
/// `.withinWindow` blending gives us the same translucent chrome that
/// Finder's path bar and Mail's message header use, and — critically —
/// it keeps rendering as translucent glass even when the pane below
/// is momentarily empty, because the blending is against the whole
/// window's vibrancy stack rather than just the sibling view behind it.
///
/// Callers apply this as a `.background { VisualEffectBar() }` on the
/// view they want frosted (typically the content of a
/// `.safeAreaInset(edge: .top)` so scroll content scrolls UP under it
/// and the material blurs in real time as the user drags).
struct VisualEffectBar: NSViewRepresentable {
    /// `.headerView` matches Finder's path bar / Mail's message-list
    /// header. `.titlebar` is slightly darker and was tried first —
    /// reads as continuous with the window toolbar, but the chrome
    /// mismatch against the content pane ended up looking like a
    /// second toolbar rather than an inset header strip.
    var material: NSVisualEffectView.Material = .headerView

    /// `.withinWindow` blends with sibling views behind this one in
    /// the same window — exactly what we want for a header pinned
    /// over scroll content. `.behindWindow` is for sidebars / popovers
    /// that should show the desktop through the window.
    var blendingMode: NSVisualEffectView.BlendingMode = .withinWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        // `.active` forces the material to render translucent even
        // when the window isn't frontmost. `.followsWindowActiveState`
        // (the default) dims the material when the window loses key
        // focus, which looks like a bug — the strip suddenly goes
        // opaque when you click away.
        view.state = .active
        // No visible border / drawn background beyond the material
        // itself. The caller composes any labels / controls on top
        // via SwiftUI.
        view.isEmphasized = false
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        if nsView.material != material {
            nsView.material = material
        }
        if nsView.blendingMode != blendingMode {
            nsView.blendingMode = blendingMode
        }
    }
}
#endif
