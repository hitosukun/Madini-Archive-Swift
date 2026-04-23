import SwiftUI
#if os(macOS)
import AppKit
import os

/// Runtime toggle for diagnostic logging. Flip to `true` when the
/// reset misbehaves to see exactly which view is being resolved,
/// what the scroll offset looks like before/after, and whether the
/// burst retries are even firing. Output lands in Console.app under
/// subsystem `madini.archive`, category `table-scroll-reset`.
private let kDiagnosticLoggingEnabled = true
private let tableScrollLog = Logger(subsystem: "madini.archive", category: "table-scroll-reset")

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
        /// Whether we've already dumped the ancestor chain for
        /// diagnostic purposes — expensive to log, and after the
        /// first burst the structure doesn't change meaningfully.
        var didDumpAncestry: Bool = false
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
        // Longer tail (800ms) because the .table → .default mode
        // flip triggers a cascade of NSSplitView tiling passes that
        // can take well over 400ms to settle on slower machines.
        // Extra early ticks at 16/32ms catch the case where the
        // table had been laid out earlier and only needs an
        // immediate nudge.
        let delaysMs: [Int] = [0, 16, 32, 80, 200, 500, 900]
        if kDiagnosticLoggingEnabled {
            tableScrollLog.debug("scheduleResetBursts probe=\(String(describing: probe), privacy: .public) delays=\(delaysMs, privacy: .public)")
        }
        for delay in delaysMs {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delay)) { [weak probe] in
                guard let probe, let coordinator else { return }
                performReset(from: probe, coordinator: coordinator, tickMs: delay)
            }
        }
    }

    private static func performReset(from probe: NSView, coordinator: Coordinator, tickMs: Int) {
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
                ?? locateTableViewViaApplicationWindows()
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

        let beforeOriginX = scrollView?.contentView.bounds.origin.x ?? .nan
        let visibleWidth = scrollView?.contentView.bounds.width ?? .nan
        let totalColumnsWidth: CGFloat = {
            guard let tv = tableView else { return .nan }
            var sum: CGFloat = 0
            for col in tv.tableColumns {
                sum += col.width
            }
            return sum
        }()

        if kDiagnosticLoggingEnabled {
            tableScrollLog.debug("performReset tick=\(tickMs, privacy: .public)ms table=\(tableView == nil ? "nil" : "cols=\(tableView!.numberOfColumns) sumW=\(totalColumnsWidth)", privacy: .public) scroll=\(scrollView == nil ? "nil" : "origin.x=\(beforeOriginX) visW=\(visibleWidth)", privacy: .public)")
        }

        // One-time ancestor dump — tells us exactly which view
        // classes sit between the NSTableView and the window.
        // Previous logs showed that setBoundsOrigin on the
        // `enclosingScrollView` didn't move the visible content,
        // which means the *actual* clipping view is somewhere
        // else in the ancestor chain. The dump lets us see every
        // candidate scroll/clip container at once.
        if kDiagnosticLoggingEnabled, !coordinator.didDumpAncestry, let tv = tableView {
            coordinator.didDumpAncestry = true
            dumpAncestry(from: tv)
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
            // Some SwiftUI Table builds wrap the NSTableView inside
            // an inner ScrollView AND re-apply a cached offset after
            // the clip view resets. Kicking `scroll(_:)` on the
            // documentView directly is a second path that tends to
            // stick even when the clip-view approach gets clobbered.
            if let docView = scrollView.documentView {
                docView.scroll(NSPoint(x: 0, y: docView.visibleRect.origin.y))
            }
        }

        // Quaternary: SwiftUI Table on macOS 14+ nests the
        // NSTableView inside its own scroll container that is NOT
        // necessarily `tableView.enclosingScrollView`. Walk the
        // ENTIRE ancestor chain and reset every NSClipView /
        // NSScrollView we find. This is blunt but robust — most
        // of those clip views are no-ops (their content doesn't
        // overflow), and the one that matters does get reset.
        if let tv = tableView {
            resetAllAncestorScrollContainers(from: tv)
        }

        // Tertiary: force column widths to fit the visible viewport.
        // If the column widths sum to MORE than the scroll view's
        // visible width, there is by definition horizontal overflow
        // — and the leftmost column can end up scrolled out of
        // view whenever the tiler decides to leave the previous
        // scroll offset alone. Shrinking the Title column (the
        // slack-absorbing column) by exactly the overflow amount
        // eliminates the overflow entirely, so there's no offset
        // to fight over. This is the only reliable defense against
        // SwiftUI Table internally re-applying its cached scroll
        // offset after our scroll reset.
        if let tableView, let scrollView {
            compressColumnsToFit(tableView: tableView, scrollView: scrollView)
        }

        if kDiagnosticLoggingEnabled, let scrollView {
            let afterOriginX = scrollView.contentView.bounds.origin.x
            tableScrollLog.debug("performReset tick=\(tickMs, privacy: .public)ms AFTER origin.x=\(afterOriginX, privacy: .public)")
        }
    }

    /// Dump every ancestor of the NSTableView, logging class name
    /// + frame + bounds. Run once per coordinator. Lets us identify
    /// SwiftUI's private scroll container (usually something like
    /// `_TtC7SwiftUIP33_...ScrollView`) so we know what to target.
    private static func dumpAncestry(from tableView: NSTableView) {
        var depth = 0
        var current: NSView? = tableView
        while let v = current {
            let frame = v.frame
            let bounds = v.bounds
            let cls = String(describing: type(of: v))
            tableScrollLog.debug("ancestry[\(depth, privacy: .public)] \(cls, privacy: .public) frame=(\(frame.origin.x, privacy: .public),\(frame.origin.y, privacy: .public),\(frame.size.width, privacy: .public)x\(frame.size.height, privacy: .public)) bounds.origin=(\(bounds.origin.x, privacy: .public),\(bounds.origin.y, privacy: .public))")
            current = v.superview
            depth += 1
        }
    }

    /// Walk up from the NSTableView and reset every NSClipView's
    /// bounds origin AND every NSScrollView's content offset. One
    /// of them is the "real" scroll container. The rest should
    /// no-op on this call because their content doesn't overflow
    /// or their clip bounds are already at 0.
    private static func resetAllAncestorScrollContainers(from tableView: NSTableView) {
        var current: NSView? = tableView
        var depth = 0
        while let v = current {
            if let clip = v as? NSClipView {
                let beforeX = clip.bounds.origin.x
                if beforeX != 0 {
                    let y = clip.bounds.origin.y
                    clip.setBoundsOrigin(NSPoint(x: 0, y: y))
                    if let sv = clip.enclosingScrollView ?? (clip.superview as? NSScrollView) {
                        sv.reflectScrolledClipView(clip)
                    }
                    if kDiagnosticLoggingEnabled {
                        tableScrollLog.debug("resetAllAncestors depth=\(depth, privacy: .public) NSClipView origin.x \(beforeX, privacy: .public) -> \(clip.bounds.origin.x, privacy: .public)")
                    }
                }
            }
            if let sv = v as? NSScrollView {
                let beforeX = sv.contentView.bounds.origin.x
                if beforeX != 0, let docView = sv.documentView {
                    docView.scroll(NSPoint(x: 0, y: docView.visibleRect.origin.y))
                    if kDiagnosticLoggingEnabled {
                        tableScrollLog.debug("resetAllAncestors depth=\(depth, privacy: .public) NSScrollView origin.x \(beforeX, privacy: .public) -> \(sv.contentView.bounds.origin.x, privacy: .public)")
                    }
                }
            }
            current = v.superview
            depth += 1
        }
    }

    /// Shrinks the first (slack-absorbing) column by the exact amount
    /// of horizontal overflow, so the column-widths sum equals the
    /// visible viewport width. With zero overflow, there's no
    /// horizontal scroll to get stuck at the wrong offset and the
    /// Title column is guaranteed to be on-screen.
    private static func compressColumnsToFit(tableView: NSTableView, scrollView: NSScrollView) {
        guard tableView.numberOfColumns > 0 else { return }
        let visibleWidth = scrollView.contentView.bounds.width
        guard visibleWidth > 0 else { return }

        var totalWidth: CGFloat = 0
        for col in tableView.tableColumns {
            totalWidth += col.width
        }
        let overflow = totalWidth - visibleWidth
        guard overflow > 0.5 else { return }

        // First column in the SwiftUI Table is Title — declared with
        // `.width(min: 160)` and no ideal/max, which means it's the
        // one that's *meant* to absorb slack. Shrink it down by the
        // overflow amount, floored at its `minWidth` so we don't
        // collapse it below usability.
        let titleCol = tableView.tableColumns[0]
        let targetWidth = max(titleCol.minWidth, titleCol.width - overflow)
        if abs(targetWidth - titleCol.width) > 0.5 {
            titleCol.width = targetWidth
            if kDiagnosticLoggingEnabled {
                tableScrollLog.debug("compressColumnsToFit shrunk col0 from \(titleCol.width + (titleCol.width - targetWidth), privacy: .public) to \(targetWidth, privacy: .public) (overflow=\(overflow, privacy: .public) visW=\(visibleWidth, privacy: .public))")
            }
        }
    }

    /// Last-ditch fallback: walk every NSWindow in the running app
    /// and return the first multi-column NSTableView we find. Used
    /// when the probe's view-tree walk comes up empty — which can
    /// happen when SwiftUI places the overlay's NSHostingView in a
    /// sibling tree that doesn't share any ancestor with the
    /// Table's NSHostingView.
    private static func locateTableViewViaApplicationWindows() -> NSTableView? {
        for window in NSApp.windows {
            guard let contentView = window.contentView else { continue }
            if let found = firstMultiColumnTableView(in: contentView) {
                if kDiagnosticLoggingEnabled {
                    tableScrollLog.debug("locateTableViewViaApplicationWindows found in window=\(window, privacy: .public)")
                }
                return found
            }
        }
        return nil
    }

    // MARK: - View-tree lookup

    /// Minimum column count that qualifies an `NSTableView` as our
    /// multi-column SwiftUI `Table`. SwiftUI `List` on macOS is ALSO
    /// backed by `NSTableView`, but always with a single column. If
    /// we accepted any `NSTableView`, a depth-first search from an
    /// ancestor would land on the sidebar List's NSTableView (since
    /// `NavigationSplitView` lays out sidebar → content → detail in
    /// that subview order) and we'd scroll the wrong view. Requiring
    /// at least two columns rules out every `List`-backed table and
    /// zeroes in on our actual data table.
    private static let minMultiColumnCount = 2

    private static func locateTableView(from probe: NSView) -> NSTableView? {
        // 1. Up the superview chain — the probe is typically a
        //    sibling of the NSTableView under a shared clip view.
        //    At each ancestor, run a multi-column subtree search so
        //    we skip the sidebar List's single-column NSTableView
        //    and land on our actual Table.
        var current: NSView? = probe
        while let v = current {
            if let t = firstMultiColumnTableView(in: v) { return t }
            current = v.superview
        }
        // 2. Window-scoped fallback. Same multi-column filter —
        //    otherwise a depth-first walk from the window's content
        //    view would hit the sidebar's single-column table first.
        if let root = probe.window?.contentView {
            return firstMultiColumnTableView(in: root)
        }
        return nil
    }

    private static func locateScrollView(from probe: NSView) -> NSScrollView? {
        if let sv = probe.enclosingScrollView,
           firstMultiColumnTableView(in: sv) != nil {
            return sv
        }
        var current: NSView? = probe.superview
        while let v = current {
            if let sv = v as? NSScrollView, firstMultiColumnTableView(in: sv) != nil {
                return sv
            }
            current = v.superview
        }
        if let root = probe.window?.contentView {
            return firstMultiColumnTableScrollView(in: root)
        }
        return nil
    }

    /// Recursively finds the first `NSTableView` with at least
    /// `minMultiColumnCount` columns. Depth-first; returns as soon
    /// as a qualifying view is seen.
    private static func firstMultiColumnTableView(in view: NSView) -> NSTableView? {
        if let t = view as? NSTableView, t.numberOfColumns >= minMultiColumnCount {
            return t
        }
        for sub in view.subviews {
            if let found = firstMultiColumnTableView(in: sub) { return found }
        }
        return nil
    }

    private static func firstMultiColumnTableScrollView(in view: NSView) -> NSScrollView? {
        if let sv = view as? NSScrollView, firstMultiColumnTableView(in: sv) != nil {
            return sv
        }
        for sub in view.subviews {
            if let found = firstMultiColumnTableScrollView(in: sub) { return found }
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
