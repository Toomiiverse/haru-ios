import Foundation

/// "HH:MM" <-> Date, for the quiet-hours pickers. The server keeps strings.
enum Clock {
    static func date(from hhmm: String) -> Date {
        let bits = hhmm.split(separator: ":").compactMap { Int($0) }
        var parts = DateComponents()
        parts.hour = bits.count > 0 ? bits[0] : 0
        parts.minute = bits.count > 1 ? bits[1] : 0
        return Calendar.current.date(from: parts) ?? Date()
    }

    static func hhmm(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    /// "3 minutes ago", "2 hours ago", "4 days ago" from a count of minutes.
    static func ago(minutes: Double) -> String {
        let m = Int(minutes.rounded())
        if m < 1 { return "just now" }
        if m < 60 { return "\(m) minute\(m == 1 ? "" : "s") ago" }
        let h = m / 60
        if h < 48 { return "\(h) hour\(h == 1 ? "" : "s") ago" }
        let d = h / 24
        return "\(d) day\(d == 1 ? "" : "s") ago"
    }
}
