import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Two-finger trackpad / mouse horizontal swipe → toggle Viewer Mode.
///
/// **Why a swipe path at all.** The toolbar `ViewerModeToggleButton`
/// (`ReaderWorkspaceView.swift`) is fine for mouse-bound users but
/// trackpad-first users want to enter and exit focus reading without
/// jumping the cursor up to the title bar. Horizontal swipes are the
/// only common trackpad input Madini doesn't already use — vertical
/// scroll feeds the message ScrollView, pinch is unbound, taps go to
/// buttons — so they're a free channel.
///
/// **Direction mapping.** Swipe LEFT (fingers move left under default
/// natural-scrolling) → enter Viewer Mode (sidebar collapses left,
/// content tightens to the right pane). Swipe RIGHT (fingers move
/// right) → exit (sidebar swings back in from the left). The visual
/// motion of the panes mirrors the physical motion of the fingers,
/// which is the discoverability we get for free here.
///
/// **Thresholds — why these numbers.**
///
/// On macOS we listen via an `NSEvent` local monitor on `.scrollWheel`
/// (the event family two-finger trackpad swipes belong to) and require
/// a SINGLE-gesture accumulated `|dx| ≥ 100pt` with `|dx| > |dy| * 3`.
/// The 100pt threshold is large enough that:
///   1. small horizontal drift while reading-scrolling never hits it
///      (vertical-dominant gestures get rejected by the dominance
///      check anyway, but the threshold is the second line of
///      defense),
///   2. short horizontal scrubs inside a code block (`MessageBubbleView`
///      has horizontal `ScrollView`s for long code lines —
///      MessageBubbleView.swift:1263, 1298, 1420) don't accidentally
///      flip the mode mid-read.
/// The 3:1 dominance ratio rejects diagonal scrolls. Together these
/// mean only a deliberate, mostly-horizontal swipe — the kind the user
/// makes intentionally — registers.
///
/// We only react to `event.hasPreciseScrollingDeltas == true` (trackpad
/// or Magic Mouse). Classic mouse wheels report integer dy only, so
/// they could never satisfy the dominance check; gating up front keeps
/// the per-event gesture accounting clean and is documented behavior.
///
/// We fire AT MOST once per gesture (between `.began` and `.ended`),
/// and once we fire we keep returning `nil` from the monitor for the
/// rest of that gesture's events. Returning `nil` swallows the event
/// before it reaches any underlying scroll view — without that the
/// same swipe would also horizontally slide a code block while
/// flipping Viewer Mode, which reads as "the gesture broke the page".
///
/// **iOS portability.** Same shape, different hook: `DragGesture` with
/// the same 100pt + 3:1 thresholds, attached via `simultaneousGesture`
/// so SwiftUI's ScrollView keeps priority on its own (vertical) axis
/// and our recognizer only wins when the translation is genuinely
/// horizontal-dominant. The thresholds are the same numbers because
/// a 100pt swipe feels comparable on either platform's trackpad /
/// touchscreen.
///
/// **Why not `DragGesture` on macOS too.** SwiftUI's `DragGesture` on
/// macOS responds to mouse-button drag — clicking and dragging — not
/// to trackpad two-finger swipes. Trackpad swipes come through as
/// `scrollWheel` events. We want both — so macOS uses the `NSEvent`
/// monitor (which catches trackpad and Magic Mouse), and iOS uses
/// `DragGesture` (which catches touch).
///
/// **Accessibility.** The modifier observes scroll-wheel events
/// passively; no focus is moved, no button is replaced. The toolbar
/// button + ⎋ shortcut both still work as before. Users who don't use
/// the swipe never notice it exists.
struct ViewerModeSwipeGesture: ViewModifier {
    @Binding var isActive: Bool
    /// Whether ENTERING viewer mode is currently allowed. Mirrors the
    /// `ViewerModeToggleButton`'s `isEnabled` gate: no active
    /// conversation → nothing to read in viewer mode → swipe-left is
    /// a no-op. Exits are always allowed regardless of this flag (same
    /// rationale as the button's `effectiveEnabled`: never trap the
    /// user inside the mode).
    let canEnter: Bool

    func body(content: Content) -> some View {
        #if os(macOS)
        content.background(
            SwipeScrollMonitor(isActive: $isActive, canEnter: canEnter)
                // Zero-frame, non-hit-testing host. The NSView exists
                // only as a lifetime anchor for the global event
                // monitor — it never participates in layout or
                // hit-testing.
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
        )
        #else
        content.simultaneousGesture(
            DragGesture(minimumDistance: 20)
                .onEnded { value in
                    let dx = value.translation.width
                    let dy = value.translation.height
                    guard abs(dx) >= Self.triggerThreshold,
                          abs(dx) > abs(dy) * Self.dominanceRatio else {
                        return
                    }
                    if dx < 0 {
                        if canEnter, !isActive { isActive = true }
                    } else if isActive {
                        isActive = false
                    }
                }
        )
        #endif
    }

    fileprivate static let triggerThreshold: CGFloat = 100
    fileprivate static let dominanceRatio: CGFloat = 3
}

#if os(macOS)
/// Hosts an `NSEvent` local monitor whose lifetime matches this view's
/// place in the SwiftUI tree. Installed on `makeNSView`, removed on
/// `dismantleNSView` — so when the root view goes away (e.g. window
/// closes) we don't leak a global monitor that fires forever.
private struct SwipeScrollMonitor: NSViewRepresentable {
    @Binding var isActive: Bool
    let canEnter: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(binding: $isActive, canEnter: canEnter)
    }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.install()
        return NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Bindings/flags re-flow on every parent re-render; refresh
        // the coordinator's snapshots so the next event fires against
        // the latest source-of-truth values.
        context.coordinator.binding = $isActive
        context.coordinator.canEnter = canEnter
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    final class Coordinator {
        var binding: Binding<Bool>
        var canEnter: Bool
        private var monitor: Any?

        // Per-gesture accumulator. Reset on `.began`; fires at most
        // once per gesture; locked-out for the remainder of the
        // gesture once fired (see `handle(_:)`).
        private var accumulatedDX: CGFloat = 0
        private var accumulatedDY: CGFloat = 0
        private var hasFiredThisGesture = false

        init(binding: Binding<Bool>, canEnter: Bool) {
            self.binding = binding
            self.canEnter = canEnter
        }

        deinit { uninstall() }

        func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self else { return event }
                return self.handle(event)
            }
        }

        func uninstall() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            // Trackpad / Magic Mouse only — see the file-level doc.
            guard event.hasPreciseScrollingDeltas else { return event }

            switch event.phase {
            case .began:
                accumulatedDX = event.scrollingDeltaX
                accumulatedDY = event.scrollingDeltaY
                hasFiredThisGesture = false
            case .changed:
                accumulatedDX += event.scrollingDeltaX
                accumulatedDY += event.scrollingDeltaY
            case .ended, .cancelled:
                let wasFired = hasFiredThisGesture
                accumulatedDX = 0
                accumulatedDY = 0
                hasFiredThisGesture = false
                // Eat the terminating event too if we fired earlier
                // in this gesture so a momentum tail can't slide a
                // ScrollView immediately after the toggle.
                return wasFired ? nil : event
            default:
                // Momentum and other phases — ignore for the gesture
                // accumulator. Returning the event lets normal scroll
                // momentum continue to feed underlying ScrollViews.
                return event
            }

            if hasFiredThisGesture {
                // Already toggled mid-gesture: keep eating the rest
                // so the underlying ScrollView doesn't ALSO slide
                // horizontally during the same hand motion.
                return nil
            }

            guard abs(accumulatedDX) >= ViewerModeSwipeGesture.triggerThreshold,
                  abs(accumulatedDX) > abs(accumulatedDY) * ViewerModeSwipeGesture.dominanceRatio
            else {
                return event
            }

            // `scrollingDeltaX` follows the system's natural-scrolling
            // setting: with natural scrolling ON (default), fingers
            // moving LEFT produce NEGATIVE dx (content shifts left
            // with the fingers). We map "fingers left" → enter Viewer
            // Mode (focus, sidebar collapses left), so:
            //   dx < 0  →  enter
            //   dx > 0  →  exit
            // Users who flipped natural scrolling off get the inverted
            // mapping for free, which still matches their finger
            // direction relative to the rest of their UI.
            let shouldEnter = accumulatedDX < 0
            hasFiredThisGesture = true

            // The monitor closure runs on the main thread already, but
            // mutating a SwiftUI Binding from inside an event handler
            // can re-enter the SwiftUI graph mid-flush. Defer the
            // write a tick so it lands on a clean runloop turn — same
            // pattern `MacOSRootView` uses for its column-visibility
            // clamp (`onChange(of: columnVisibility)`).
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if shouldEnter {
                    if self.canEnter, !self.binding.wrappedValue {
                        self.binding.wrappedValue = true
                    }
                } else if self.binding.wrappedValue {
                    self.binding.wrappedValue = false
                }
            }

            // Swallow this event so the same swipe can't also drive a
            // horizontal ScrollView underneath us.
            return nil
        }
    }
}
#endif

extension View {
    /// Convenience wrapper — same name as the modifier, applied as
    /// `.viewerModeSwipeGesture(isActive: ..., canEnter: ...)` so the
    /// call site at `MacOSRootView.workspaceSplitView` reads as one
    /// fluent modifier in the chain.
    func viewerModeSwipeGesture(isActive: Binding<Bool>, canEnter: Bool) -> some View {
        modifier(ViewerModeSwipeGesture(isActive: isActive, canEnter: canEnter))
    }
}
