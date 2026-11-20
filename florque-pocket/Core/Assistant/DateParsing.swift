import Foundation

/// Parses the model's ISO date-times. Values without a zone are local time in `timeZone`.
public enum DateParsing {
    public static func parse(_ text: String, in timeZone: TimeZone = .current) -> Date? {
        if let d = ISO8601DateFormatter().date(from: text) { return d }
        for pattern in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd"] {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = timeZone
            f.dateFormat = pattern
            f.isLenient = false
            if let d = f.date(from: text) { return d }
        }
        return nil
    }

    public static func formatLocal(_ date: Date, in timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f.string(from: date)
    }
}
