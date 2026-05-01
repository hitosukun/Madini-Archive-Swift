import SwiftUI

/// Browser-style zoom for the conversation reader's body text. The
/// reader pane is where the user spends the longest unbroken reading
/// sessions, and a fixed point size that's comfortable on a 14" laptop
/// is too small on an external display and too large on a hi-dpi touch
/// screen. Adjusting the OS-level "Larger Text" setting would scale
/// the entire chrome too, which is overkill — we only want to retune
/// the body column.
///
/// Scope:
/// - Applies to paragraphs, list items, blockquotes, code blocks,
///   math blocks, and table cells in `MessageBubbleView`.
/// - Headings, sidebar, central card list, metadata captions, and
///   image-related auxiliary text keep their fixed sizes (per the
///   Task 4 spec — "中央リスト、サイドバー、メタ情報、見出しは現状維持").
///
/// Persistence: `UserDefaults` under
/// `BodyTextSizePreference.storageKey`. Global across the app — the
/// same multiplier applies to every conversation, every source. No
/// per-conversation override at this stage.
@MainActor
final class BodyTextSizePreference: ObservableObject {
    /// Discrete zoom stops, ascending. Mirrors what Mail.app and
    /// Safari expose: a small set of meaningful steps rather than a
    /// continuous slider, so ⌘= / ⌘- always lands on a recognizable
    /// size and the user doesn't end up at 103.7 % through repeated
    /// taps.
    static let scaleStops: [CGFloat] = [0.7, 0.8, 0.9, 1.0, 1.2, 1.5, 2.0]

    /// Default for fresh installs and ⌘0 reset.
    static let defaultMultiplier: CGFloat = 1.0

    /// `UserDefaults` key. Namespaced under "Madini." so it's easy
    /// to spot in `defaults read com.madini.archive`.
    static let storageKey = "Madini.BodyTextSizeMultiplier"

    /// Current multiplier. Always one of `scaleStops`.
    @Published private(set) var multiplier: CGFloat

    init(defaults: UserDefaults = .standard) {
        let stored = defaults.object(forKey: Self.storageKey) as? Double
        let raw: CGFloat = stored.map { CGFloat($0) } ?? Self.defaultMultiplier
        // Snap to the nearest valid stop. Guards against a corrupted
        // pref (e.g. a hand-edited plist with 1.05) by always
        // resolving to a known stop instead of rendering at an
        // unsupported scale.
        self.multiplier = Self.snap(raw)
        self.defaults = defaults
    }

    private let defaults: UserDefaults

    /// Whether `stepUp()` would change anything. Used to dim the
    /// "Increase Body Text Size" menu item at the cap so the user
    /// gets a visual cue without an audible beep.
    var canStepUp: Bool {
        guard let i = Self.scaleStops.firstIndex(of: multiplier) else { return true }
        return i < Self.scaleStops.count - 1
    }

    /// Whether `stepDown()` would change anything.
    var canStepDown: Bool {
        guard let i = Self.scaleStops.firstIndex(of: multiplier) else { return true }
        return i > 0
    }

    /// Whether `reset()` would change anything.
    var canReset: Bool {
        multiplier != Self.defaultMultiplier
    }

    /// Move one stop larger. No-op at the cap — explicitly silent
    /// so ⌘= at 200 % doesn't trigger the system beep that an empty
    /// keyboard binding would.
    func stepUp() {
        guard let i = Self.scaleStops.firstIndex(of: multiplier),
              i + 1 < Self.scaleStops.count
        else { return }
        write(Self.scaleStops[i + 1])
    }

    /// Move one stop smaller. No-op at the floor (same beep-avoidance).
    func stepDown() {
        guard let i = Self.scaleStops.firstIndex(of: multiplier),
              i > 0
        else { return }
        write(Self.scaleStops[i - 1])
    }

    /// Snap back to 100 %.
    func reset() {
        write(Self.defaultMultiplier)
    }

    private func write(_ value: CGFloat) {
        guard value != multiplier else { return }
        multiplier = value
        defaults.set(Double(value), forKey: Self.storageKey)
    }

    /// Resolve an arbitrary multiplier to the nearest valid stop.
    /// Preserves the historical default (1.0) on exact matches and
    /// avoids floating-point comparison surprises by picking the
    /// numerically closest value.
    private static func snap(_ raw: CGFloat) -> CGFloat {
        guard let nearest = scaleStops.min(by: { abs($0 - raw) < abs($1 - raw) }) else {
            return defaultMultiplier
        }
        return nearest
    }
}

// MARK: - Environment plumbing

private struct BodyTextSizeMultiplierKey: EnvironmentKey {
    /// Default 1.0 so any view rendered outside an app scene
    /// (Previews, tests, the iOS reader path that doesn't yet wire
    /// the preference) renders at the design-time size.
    static let defaultValue: CGFloat = 1.0
}

extension EnvironmentValues {
    /// Multiplier for body-column text sizes. Read by
    /// `MessageBubbleView` and applied to paragraphs / list items /
    /// code blocks / math blocks / table cells. Headings and meta
    /// text intentionally bypass this and use their fixed Layout
    /// constants — the spec scopes the zoom to body reading text.
    var bodyTextSizeMultiplier: CGFloat {
        get { self[BodyTextSizeMultiplierKey.self] }
        set { self[BodyTextSizeMultiplierKey.self] = newValue }
    }
}
