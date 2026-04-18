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
}
