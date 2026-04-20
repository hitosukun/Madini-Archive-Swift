import Foundation

/// Shared timestamp formatter for repository layer.
///
/// Constructing `DateFormatter` is relatively expensive (locale/calendar lookup,
/// ICU state), so repositories reuse a single configured instance instead of
/// allocating one per row insert or touch.
enum TimestampFormatter {
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    static func now() -> String {
        formatter.string(from: Date())
    }

    static func string(from date: Date) -> String {
        formatter.string(from: date)
    }

    /// Parse a stored timestamp back into a `Date`. Returns `nil` on
    /// malformed input so callers can decide whether to substitute the
    /// current date, fall through to a default, or propagate an error
    /// — a silent `Date()` fallback at this layer would hide corrupt
    /// rows. Used by repositories whose model types (e.g.
    /// `ProjectMembership.assignedAt`) are typed as `Date` rather than
    /// the raw DB `String`.
    static func date(from string: String) -> Date? {
        formatter.date(from: string)
    }
}
