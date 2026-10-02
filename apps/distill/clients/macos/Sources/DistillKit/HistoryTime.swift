import Foundation

/// Fixed clock times for History ("today at 3:04 AM", "Sep 30 at 4:10 PM").
/// History never shows a ticking relative time.
public enum HistoryTime {
    /// "today at 3:04 AM", "yesterday at 9:12 PM", "Sep 30 at 4:10 PM",
    /// "Sep 30, 2025 at 4:10 PM" (other years). The time follows the
    /// locale's 12/24-hour setting.
    public static func phrase(_ date: Date, now: Date = Date(),
                              calendar: Calendar = .current, locale: Locale = .current) -> String {
        let time = DateFormatter()
        time.locale = locale
        time.calendar = calendar
        time.timeZone = calendar.timeZone
        time.dateStyle = .none
        time.timeStyle = .short
        let clock = time.string(from: date)
        if calendar.isDate(date, inSameDayAs: now) { return "today at \(clock)" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "yesterday at \(clock)"
        }
        let day = DateFormatter()
        day.locale = locale
        day.calendar = calendar
        day.timeZone = calendar.timeZone
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        day.setLocalizedDateFormatFromTemplate(sameYear ? "MMMd" : "yMMMd")
        return "\(day.string(from: date)) at \(clock)"
    }

    /// "Asked today at 3:04 AM".
    public static func asked(_ date: Date, now: Date = Date()) -> String { "Asked \(phrase(date, now: now))" }
}
