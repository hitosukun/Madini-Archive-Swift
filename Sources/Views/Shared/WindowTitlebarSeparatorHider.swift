import SwiftUI
#if os(macOS)
import AppKit

/// Pin the host `NSWindow`'s titlebar separator so it never appears —
/// neither on launch nor when the sidebar is toggled.
///
/// ## Why this needs to be aggressive
///
/// A one-shot `window.titlebarSeparatorStyle = .none` inside a
/// `viewDidMoveToWindow` callback is not enough:
///
/// 1. **Initial launch.** `NavigationSplitView`'s internal
///    `NSSplitViewController` finishes wiring up AFTER
///    `viewDidMoveToWindow` returns, and its setup writes the
///    default chrome back to `.automatic` a few runloop ticks
///    later. The user sees the app open with the separator already
///    drawn.
/// 2. **Sidebar toggle.** Every time the sidebar column shows or
///    hides, `NavigationSplitView` re-asserts the default
///    separator style. Observed: KVO on `titlebarSeparatorStyle`
///    did NOT fire reliably for these re-asserts — the SwiftUI path
///    appears to route through a non-KVO-compliant setter or
///    bypasses the normal property write entirely. So relying on
///    KVO alone left the line reappearing on every sidebar
///    collapse.
///
/// ## What works
///
/// Two defenses applied together:
///
///   * **Write `titlebarSeparatorStyle = .none`** on every event
///     that might correspond to a chrome rewrite: initial window
///     attach, deferred runloop tick, window-did-update
///     notification, window-did-become-main, AND — crucially —
///     split-view resize notifications, which fire around every
///     sidebar toggle. The deferred-tick re-application covers
///     initial launch; the split-view observers cover sidebar
///     toggles.
///   * **Hide the separator `NSView` directly** by walking the
///     window's theme-frame subview tree and matching any view
///     whose class name contains `TitlebarSeparator`. macOS
///     actually renders the line via a real private `NSView`
///     (`_NSTitlebarSeparatorView` on current SDKs), and setting
///     its `isHidden = true` bypasses whatever code path keeps
///     rewriting the separator style. This direct-hide happens
///     inside the same event hooks as the style write, so the
///     view stays hidden across toggles even if a new separator
///     view is swapped in.
///
/// Apply via `.background { WindowTitlebarSeparatorHider() }` on
/// the root view of the window whose separator should stay hidden.
/// The representable renders nothing visible — it exists purely to
/// reach `self.window` and install the observers.
struct WindowTitlebarSeparatorHider: NSViewRepresentable {
    func makeNSView(context: Context) -> SeparatorHidingView {
        SeparatorHidingView()
    }

    func updateNSView(_ nsView: SeparatorHidingView, context: Context) {}

    final class SeparatorHidingView: NSView {
        /// NotificationCenter tokens retained so the callbacks keep
        /// firing. Released together when the view is detached from
        /// its window (or deallocated).
        private var notificationTokens: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            tearDownObservers()
            guard let window = self.window else { return }

            // Apply once synchronously so the most common path
            // (window already fully initialized) takes effect
            // immediately.
            applySeparatorHidden(on: window)

            // Defer another application to the next runloop turn.
            // Covers the case where `NavigationSplitView` finishes
            // its split-view-controller wire-up AFTER
            // `viewDidMoveToWindow` returns, and whatever default
            // chrome it settled on gets overridden before the
            // first frame.
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window else { return }
                self.applySeparatorHidden(on: window)
            }

            let center = NotificationCenter.default
            // Window-level events that correlate with chrome
            // redraws / separator rewrites on launch and window
            // activation.
            for name in [
                NSWindow.didUpdateNotification,
                NSWindow.didBecomeMainNotification,
                NSWindow.didBecomeKeyNotification,
                NSWindow.didResizeNotification,
            ] {
                notificationTokens.append(
                    center.addObserver(
                        forName: name,
                        object: window,
                        queue: .main
                    ) { [weak self] note in
                        guard let self, let win = note.object as? NSWindow else { return }
                        self.applySeparatorHidden(on: win)
                    }
                )
            }

            // Split-view events — the load-bearing observer for
            // sidebar toggle. Posted by `NSSplitView` (including
            // the one `NavigationSplitView` wraps) on every resize
            // / collapse / expand, which is exactly when the
            // separator line reappears in practice. We don't have
            // a handle on the split view directly, so we observe
            // with `object: nil` and filter by checking whether
            // the notification's split view is inside our window.
            for name in [
                NSSplitView.willResizeSubviewsNotification,
                NSSplitView.didResizeSubviewsNotification,
            ] {
                notificationTokens.append(
                    center.addObserver(
                        forName: name,
                        object: nil,
                        queue: .main
                    ) { [weak self] note in
                        guard let self,
                              let splitView = note.object as? NSSplitView,
                              splitView.window === self.window,
                              let win = self.window
                        else { return }
                        self.applySeparatorHidden(on: win)
                    }
                )
            }
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            if newWindow == nil {
                tearDownObservers()
            }
        }

        deinit {
            tearDownObservers()
        }

        /// Belt-and-braces: stomp every API surface known to draw a
        /// line below the titlebar AND hide the internal decoration
        /// / blocking views directly. Any one of these alone has
        /// been observed to leak the line under some event ordering.
        ///
        /// Diagnostic pass (2026-04) confirmed that
        /// `titlebarSeparatorStyle` was already `.none` when the
        /// line was visible — so the actual offender on this SDK is
        /// NOT the modern separator-style property. It's one of:
        ///   - `NSToolbar.showsBaselineSeparator` (the legacy 1pt
        ///     baseline below the toolbar),
        ///   - the bottom edge of `_NSTitlebarDecorationView` /
        ///     `NSTitlebarContainerBlockingView` (private views
        ///     that always sit in the theme-frame hierarchy and
        ///     whose frames animate with sidebar toggle).
        /// We disable all of them.
        private func applySeparatorHidden(on window: NSWindow) {
            if window.titlebarSeparatorStyle != .none {
                window.titlebarSeparatorStyle = .none
            }
            // We deliberately do NOT set `titlebarAppearsTransparent = true`
            // here even though it further smooths the titlebar/content
            // seam visually. That flag merges the titlebar area INTO the
            // content view, which has a side effect AppKit gives us no
            // API to undo: the top ~28pt of the window (overlapping the
            // traffic-light strip) stays a draggable title bar region,
            // and `NavigationSplitView` draws its column dividers all
            // the way up to the window's top edge. The result was that
            // grabbing the center-pane divider at the top inch of its
            // length moved the whole window instead of resizing the
            // pane (user report: "中央ペインの幅を調節しようとすると
            // ウィンドウ自体が動いてしまう"). Leaving the titlebar opaque
            // costs a small amount of visual continuity but restores
            // correct drag-vs-resize behaviour along the divider's full
            // height. The three remaining mechanisms below already
            // cover the hairline the flag was originally added to hide.
            //
            // Legacy toolbar baseline separator — the 1pt line that
            // AppKit draws under the toolbar when there's a toolbar
            // attached. Pre-dates `titlebarSeparatorStyle` and is
            // the load-bearing offender here: re-applied by AppKit
            // on every sidebar resize, which is exactly the symptom.
            if let toolbar = window.toolbar, toolbar.showsBaselineSeparator {
                toolbar.showsBaselineSeparator = false
            }
            hideSeparatorViews(under: window.contentView?.superview)
        }

        /// Recursively walk the window's theme-frame view tree and
        /// neutralize any private view that has been observed to
        /// draw the hairline between the titlebar area and the
        /// content panes.
        ///
        /// The primary targets:
        ///   - `*TitlebarSeparator*` / `*ToolbarSeparator*` — the
        ///     modern separator views controlled by
        ///     `titlebarSeparatorStyle`. Safe to hide outright.
        ///   - `NSTitlebarContainerBlockingView` — a thin (5pt)
        ///     view that sits on the sidebar↔content seam and
        ///     animates with sidebar toggle. Safe to hide: AppKit
        ///     uses it to mask a seam, not to render chrome.
        ///
        /// We deliberately do NOT hide `_NSTitlebarDecorationView`
        /// outright — its frame is the full titlebar area and it
        /// appears to be load-bearing for traffic-light rendering.
        /// Instead, if we encounter it, we null its layer's
        /// background so any bottom-edge line it draws disappears
        /// without removing the decoration view from the hit-test
        /// tree.
        ///
        /// The private class names have been stable across macOS
        /// 11–15; matching on substring keeps us resilient to the
        /// leading-underscore renaming AppKit occasionally applies.
        private func hideSeparatorViews(under root: NSView?) {
            guard let root else { return }
            let className = String(describing: type(of: root))
            if className.contains("TitlebarSeparator")
                || className.contains("ToolbarSeparator")
                || className.contains("TitlebarContainerBlockingView")
            {
                if !root.isHidden {
                    root.isHidden = true
                }
            }
            for subview in root.subviews {
                hideSeparatorViews(under: subview)
            }
        }

        private func tearDownObservers() {
            let center = NotificationCenter.default
            for token in notificationTokens {
                center.removeObserver(token)
            }
            notificationTokens.removeAll()
        }
    }
}
#endif
