import Foundation

enum GRDBProjectDateCodec {
    private static func makeFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    private static func makeFallbackFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }

    static func string(from date: Date) -> String {
        makeFormatter().string(from: date)
    }

    static func date(from value: String?) -> Date {
        guard let value else {
            return Date(timeIntervalSince1970: 0)
        }

        if let date = makeFormatter().date(from: value) {
            return date
        }

        return makeFallbackFormatter().date(from: value) ?? Date(timeIntervalSince1970: 0)
    }
}
