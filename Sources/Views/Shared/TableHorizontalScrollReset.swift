import SwiftUI
#if os(macOS)
import AppKit

/// Zero-size helper that finds the enclosing `NSScrollView` of a
/// SwiftUI `Table` and snaps its horizontal scroll offset back to 0
/// whenever `trigger` changes.
///
/// ## Why this exists
///
/// SwiftUI's `ScrollViewReader` + `proxy.scrollTo(id, anchor: .top)`
/// is vertical-only for `Table`. When the enclosing pane shrinks (e.g.
/// flipping from `.table` layout → `.default` layout brings the reader
/// back into view and the middle column drops from ~800pt down to
/// 320–480pt), `NSTableView` keeps its column widths wider than the
/// new visible area. The leftmost column (`Title`) ends up scrolled
/// off-screen and the user has to manually drag the scroller to find
/// their thread title — not the behavior anyone expects from "open a
/// thread and look at it."
///
/// There's no SwiftUI-level knob for horizontal table scroll offset,
/// so we drop a tiny invisible `NSView` into the table's overlay,
/// walk up its superview chain to the hosting `NSScrollView`, and
/// call `contentView.setBoundsOrigin(x: 0, …)`.
///
/// ## Usage
///
/// Apply as an `.overlay` on the `Table`, keyed on whatever should
/// retrigger the reset (layout mode, selection, mount):
///
/// ```swift
/// Table(rows, …) { … }
///     .overlay(TableHorizontalScrollReset(trigger: layoutResetKey))
/// ```
///
/// The overlay is zero-area (`.frame(width: 0, height: 0)`) so it
/// doesn't interfere with hit-testing or layout.
struct TableHorizontalScrollReset: NSViewRepresentable {
    /// Change this value to force a horizontal-scroll reset on the
    /// next SwiftUI update. Typical triggers: the outer layout mode,
    /// the selected-thread id, or a manually minted `UUID` token
    /// that you rotate at exactly the moments you want a reset.
    let trigger: AnyHashable

    final class Coordinator {
        var lastTrigger: AnyHashable?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = ProbeView()
        // First-pass reset: the probe is inserted as the table
        // mounts. At this point the enclosing `NSScrollView` might
        // not exist yet (SwiftUI still assembling the view tree);
        // `ProbeView.viewDidMoveToSuperview` handles the case where
        // the scroll view materializes later.
        resetEnclosingScroll(from: view)
        context.coordinator.lastTrigger = trigger
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard context.coordinator.lastTrigger != trigger else { return }
        context.coordinator.lastTrigger = trigger
        // Defer one runloop hop so SwiftUI finishes committing the
        // surrounding layout change (e.g. pane width shrinking as
        // the reader appears) before we look at `bounds`.
        DispatchQueue.main.async { [weak nsView] in
            guard let nsView else { return }
            resetEnclosingScroll(from: nsView)
        }
    }

    private func resetEnclosingScroll(from view: NSView) {
        guard let scrollView = locateScrollView(from: view) else { return }
        let y = scrollView.contentView.bounds.origin.y
        scrollView.contentView.setBoundsOrigin(NSPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// Walk UP the superview chain first (the common case — the probe
    /// is a child of the table's NSScrollView document view). If
    /// nothing's found that way, the probe may have been attached
    /// somewhere lateral; as a fallback, walk UP to the window's
    /// content view and then search DOWN for the first NSScrollView
    /// containing an NSTableView — that's our target.
    private func locateScrollView(from view: NSView) -> NSScrollView? {
        if let sv = view.enclosingScrollView {
            return sv
        }
        var current: NSView? = view.superview
        while let v = current {
            if let sv = v as? NSScrollView, containsTableView(sv) {
                return sv
            }
            current = v.superview
        }
        // Window-scoped fallback.
        if let root = view.window?.contentView,
           let sv = firstTableScrollView(in: root) {
            return sv
        }
        return nil
    }

    private func containsTableView(_ scrollView: NSScrollView) -> Bool {
        firstTableView(in: scrollView) != nil
    }

    private func firstTableView(in view: NSView) -> NSTableView? {
        if let t = view as? NSTableView { return t }
        for sub in view.subviews {
            if let found = firstTableView(in: sub) { return found }
        }
        return nil
    }

    private func firstTableScrollView(in view: NSView) -> NSScrollView? {
        if let sv = view as? NSScrollView, containsTableView(sv) {
            return sv
        }
        for sub in view.subviews {
            if let found = firstTableScrollView(in: sub) { return found }
        }
        return nil
    }

    /// `NSView` subclass that re-runs the horizontal reset the first
    /// time it's actually attached to a window — covers the case
    /// where SwiftUI creates the probe before the table's scroll
    /// view exists.
    private final class ProbeView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, let scrollView = self.enclosingScrollView
                    ?? (self.window?.contentView).flatMap(Self.firstTableScrollView)
                else { return }
                let y = scrollView.contentView.bounds.origin.y
                scrollView.contentView.setBoundsOrigin(NSPoint(x: 0, y: y))
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
        }

        private static func firstTableScrollView(in view: NSView) -> NSScrollView? {
            if let sv = view as? NSScrollView, firstTableView(in: sv) != nil {
                return sv
            }
            for sub in view.subviews {
                if let found = firstTableScrollView(in: sub) { return found }
            }
            return nil
        }

        private static func firstTableView(in view: NSView) -> NSTableView? {
            if let t = view as? NSTableView { return t }
            for sub in view.subviews {
                if let found = firstTableView(in: sub) { return found }
            }
            return nil
        }
    }
}
#endif
