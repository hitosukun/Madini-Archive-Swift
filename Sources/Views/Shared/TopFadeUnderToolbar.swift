import SwiftUI

/// Fade the top edge of a scroll-hosting view to transparent, so
/// content that's about to slide up under the window's translucent
/// toolbar dissolves into the toolbar material instead of reading
/// as a hard cutoff behind frosted glass.
///
/// ## Why this exists
///
/// The shell sets `titlebarAppearsTransparent = true` on the host
/// `NSWindow` (see `WindowTitlebarSeparatorHider`) so scroll content
/// visually bleeds up into the toolbar area, giving the pane a
/// continuous "content flows to the top edge of the window" look
/// rather than a bolted-on toolbar band. The user liked that
/// transparent feel but asked for a softening: "スクロールで透過
/// するのはいいけど、ツールバーに差し掛かるとフェードアウトする
/// ようにできる？". Without a mask, text and card chrome stay fully
/// opaque right up to where the toolbar material begins, which
/// reads as "toolbar is semi-transparent and I can see text right
/// behind it" rather than "text gracefully dissolves into the
/// toolbar."
///
/// ## How it works
///
/// Apply as `.topFadeUnderToolbar()` on the view whose top edge
/// sits under the toolbar (typically the outermost `ScrollView` or
/// `List` in a pane). The modifier masks the view with:
///
///   * A `LinearGradient` from fully transparent at the top edge
///     down to fully opaque `fadeHeight` points lower, and
///   * A solid rectangle below that, so the rest of the view
///     renders untouched.
///
/// `fadeHeight` defaults to 52pt — the height of a standard macOS
/// unified toolbar — so the fade region lines up exactly with the
/// toolbar's vertical extent. Content below that point renders at
/// full opacity; content above gradually disappears into the
/// toolbar's vibrancy.
///
/// `ignoresSafeArea` on the mask is load-bearing: with
/// `titlebarAppearsTransparent`, the pane's coordinate space can
/// extend under the titlebar, and a mask that respects the top
/// safe-area inset would leave a sharp seam right where the fade
/// should start. Having the mask ignore safe areas pins the
/// gradient to the raw top edge of the masked view.
struct TopFadeUnderToolbarModifier: ViewModifier {
    /// How tall the fade region is. Default matches the standard
    /// macOS unified-toolbar height so the gradient spans exactly
    /// the toolbar's overlap with content below it.
    var fadeHeight: CGFloat = 52

    func body(content: Content) -> some View {
        content
            .mask(
                VStack(spacing: 0) {
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .black, location: 1),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: fadeHeight)
                    Rectangle().fill(Color.black)
                }
                .ignoresSafeArea()
            )
    }
}

extension View {
    /// Apply a top-edge fade so content scrolling up under the
    /// window's translucent toolbar dissolves into the toolbar
    /// material. See `TopFadeUnderToolbarModifier` for rationale.
    func topFadeUnderToolbar(fadeHeight: CGFloat = 52) -> some View {
        modifier(TopFadeUnderToolbarModifier(fadeHeight: fadeHeight))
    }
}
