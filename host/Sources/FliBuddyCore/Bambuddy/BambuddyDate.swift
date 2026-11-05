import Foundation

/// Bambuddy's timestamps (`updated_at`, `archived_at`, …). Its database keeps
/// naive UTC times and FastAPI sends them without a zone
/// (`2026-10-25T12:00:00`, at times with microseconds); Bambuddy's own web app
/// appends `Z` before parsing (`parseUTCDate`), and so does this.
public enum BambuddyDate {
    /// The date of a Bambuddy timestamp, with or without fractional seconds and
    /// a zone; `nil` for anything else.
    public static func parse(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let time = trimmed.split(separator: "T", maxSplits: 1).dropFirst().first else { return nil }
        let zoned = time.hasSuffix("Z") || time.contains("+") || time.contains("-")
        let full = zoned ? trimmed : trimmed + "Z"
        if let date = try? Date(full, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) {
            return date
        }
        return try? Date(full, strategy: Date.ISO8601FormatStyle())
    }

    /// `date` the way Bambuddy sends it: naive UTC, whole seconds.
    public static func string(from date: Date) -> String {
        let zoned = date.formatted(Date.ISO8601FormatStyle(timeZone: TimeZone(identifier: "UTC")!))
        return zoned.hasSuffix("Z") ? String(zoned.dropLast()) : zoned
    }
}
