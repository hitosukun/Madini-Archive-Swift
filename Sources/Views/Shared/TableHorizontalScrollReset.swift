import SwiftUI
#if os(macOS)
import AppKit

/// Zero-size helper that snaps the enclosing `NSTableView` of a SwiftUI
/// `Table` back to its leftmost column whenever `trigger` changes.
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
/// their thread title — not what anyone expects from "open a thread
/// and look at it."
///
/// There's no SwiftUI-level knob for horizontal table scroll offset,
/// so we drop a tiny invisible `NSView` into the table's overlay and
/// reach across to the `NSTableView` via the responder chain. Primary
/// method is the native `NSTableView.scrollColumnToVisible(0)` — the
/// same API Finder / Mail use internally for "jump to first column."
/// We also kick the enclosing `NSClipView` origin back to x=0 as a
/// belt-and-braces backup, and RETRY the whole reset at 0 / 50 / 150 /
/// 400ms because SwiftUI commits table geometry across several
/// runloop hops after a layout change — a one-shot reset at t=0
/// frequently lands BEFORE the column autoresize settles, and gets
/// clobbered as the table finishes tiling.
///
/// ## Usage
///
/// Apply as a zero-size `.overlay` on the `Table`, with any value
/// whose change should retrigger the reset. Typical trigger: a
/// token that rotates whenever the outer layout mode flips back to
/// `.default`, OR the currently-selected thread id.
///
/// ```swift
/// Table(rows, …) { … }
///     .overlay(alignment: .topLeading) {
///         TableHorizontalScrollReset(trigger: resetKey)
///             .frame(width: 0, height: 0)
///             .allowsHitTesting(false)
///     }
/// ```
struct TableHorizontalScrollReset: NSViewRepresentable {
    /// Rotate this value to force a horizontal-scroll reset on the
    /// next SwiftUI update. A fresh `UUID` / incrementing counter
    /// works; so does `selection.first`.
    let trigger: AnyHashable

    final class Coordinator {
        var lastTrigger: AnyHashable?
        /// Cached reference to the target `NSTableView`. Resolved on
        /// first hit and reused on subsequent triggers — walking the
        /// view hierarchy every time is safe but wasteful, and the
        /// table view identity is stable for the lifetime of the
        /// SwiftUI `Table`.
        weak var cachedTableView: NSTableView?
        weak var cachedScrollView: NSScrollView?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = ProbeView()
        view.onAttached = { [weak coord = context.coordinator] probe in
            // Run an initial reset the moment the probe lands in a
            // window — covers fresh mounts where the table's scroll
            // view existed all along and we just need to nudge it
            // once before the user has interacted.
            Self.scheduleResetBursts(probe: probe, coordinator: coord)
        }
        context.coordinator.lastTrigger = trigger
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard context.coordinator.lastTrigger != trigger else { return }
        context.coordinator.lastTrigger = trigger
        Self.scheduleResetBursts(probe: nsView, coordinator: context.coordinator)
    }

    // MARK: - Reset pipeline

    /// Fires the reset repeatedly at escalating delays. SwiftUI
    /// commits `Table` geometry across ~3–4 runloop hops after a
    /// layout change (column autoresize, scroll-view tiling, then
    /// header redraw), so a one-shot reset at t=0 lands before the
    /// final horizontal offset is even committed. The burst strategy
    /// is cheap and resilient: each retry re-resolves the table view
    /// (via the cached reference) and re-snaps the scroll origin.
    private static func scheduleResetBursts(probe: NSView, coordinator: Coordinator?) {
        let delaysMs: [Int] = [0, 50, 150, 400]
        for delay in delaysMs {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delay)) { [weak probe] in
                guard let probe, let coordinator else { return }
                performReset(from: probe, coordinator: coordinator)
            }
        }
    }

    private static func performReset(from probe: NSView, coordinator: Coordinator) {
        // Prefer the cached table view if it's still valid — the
        // underlying NSTableView instance survives across SwiftUI
        // updates, so looking it up fresh every burst is wasted
        // work. Fall back to a hierarchy walk when the cache is
        // empty or the cached view has been torn down.
        let tableView: NSTableView?
        if let cached = coordinator.cachedTableView, cached.window != nil {
            tableView = cached
        } else {
            tableView = locateTableView(from: probe)
            coordinator.cachedTableView = tableView
        }

        let scrollView: NSScrollView?
        if let cached = coordinator.cachedScrollView, cached.window != nil {
            scrollView = cached
        } else if let tv = tableView {
            scrollView = tv.enclosingScrollView
            coordinator.cachedScrollView = scrollView
        } else {
            scrollView = locateScrollView(from: probe)
            coordinator.cachedScrollView = scrollView
        }

        // Primary: ask NSTableView to ensure column 0 is visible.
        // This is the official API for "scroll horizontally so the
        // leftmost column is on-screen," and respects NSTableView's
        // internal layout state in a way that raw bounds twiddling
        // doesn't.
        if let tableView, tableView.numberOfColumns > 0 {
            tableView.scrollColumnToVisible(0)
        }

        // Belt-and-braces: directly reset the clip view's origin.
        // `scrollColumnToVisible` sometimes no-ops if the tiler
        // hasn't caught up yet; setting the bounds origin guarantees
        // x=0 even in that window.
        if let scrollView {
            let y = scrollView.contentView.bounds.origin.y
            scrollView.contentView.setBoundsOrigin(NSPoint(x: 0, y: y))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    // MARK: - View-tree lookup

    private static func locateTableView(from probe: NSView) -> NSTableView? {
        // 1. Up the superview chain — the probe is typically a
        //    sibling of the NSTableView under a shared clip view.
        var current: NSView? = probe
        while let v = current {
            if let t = firstTableView(in: v) { return t }
            current = v.superview
        }
        // 2. Window-scoped fallback.
        if let root = probe.window?.contentView {
            return firstTableView(in: root)
        }
        return nil
    }

    private static func locateScrollView(from probe: NSView) -> NSScrollView? {
        if let sv = probe.enclosingScrollView,
           firstTableView(in: sv) != nil {
            return sv
        }
        var current: NSView? = probe.superview
        while let v = current {
            if let sv = v as? NSScrollView, firstTableView(in: sv) != nil {
                return sv
            }
            current = v.superview
        }
        if let root = probe.window?.contentView {
            return firstTableScrollView(in: root)
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

    private static func firstTableScrollView(in view: NSView) -> NSScrollView? {
        if let sv = view as? NSScrollView, firstTableView(in: sv) != nil {
            return sv
        }
        for sub in view.subviews {
            if let found = firstTableScrollView(in: sub) { return found }
        }
        return nil
    }

    /// `NSView` subclass that notifies when it lands in a window.
    /// SwiftUI creates the probe during the view-tree build, which
    /// can precede the enclosing `NSScrollView`'s own attachment;
    /// the callback fires once the probe is actually attached so
    /// the first reset burst has a valid view hierarchy to walk.
    private final class ProbeView: NSView {
        var onAttached: ((NSView) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            onAttached?(self)
        }
    }
}
#endif
