import Foundation

/// The batch interval split into days / hours / minutes for editing.
/// Settings keep storing total minutes, so the scheduler is unaffected.
public struct BatchInterval: Equatable, Sendable, CustomStringConvertible {
    public enum Part: Sendable {
        case days, hours, minutes

        public var range: ClosedRange<Int> {
            switch self {
            case .days: return 0...30
            case .hours: return 0...23
            case .minutes: return 0...59
            }
        }
    }

    public var days: Int
    public var hours: Int
    public var minutes: Int

    public init(totalMinutes: Int) {
        let total = max(1, totalMinutes)
        days = total / 1440
        hours = (total % 1440) / 60
        minutes = total % 60
    }

    /// Never below one minute: an all-zero interval would batch continuously.
    public var totalMinutes: Int { max(1, days * 1440 + hours * 60 + minutes) }

    public subscript(part: Part) -> Int {
        get {
            switch part {
            case .days: return days
            case .hours: return hours
            case .minutes: return minutes
            }
        }
        set {
            let v = min(max(newValue, part.range.lowerBound), part.range.upperBound)
            switch part {
            case .days: days = v
            case .hours: hours = v
            case .minutes: minutes = v
            }
        }
    }

    /// "1d 2h 30m", "45m", "3h".
    public var description: String {
        let d = totalMinutes / 1440, h = (totalMinutes % 1440) / 60, m = totalMinutes % 60
        let parts = [(d, "d"), (h, "h"), (m, "m")].filter { $0.0 > 0 }.map { "\($0.0)\($0.1)" }
        return parts.joined(separator: " ")
    }
}

/// `settleSeconds` split into minutes and seconds (0–59 each) for editing.
/// Settings keep storing total seconds; the core applies the wait.
public struct SettleWait: Equatable, Sendable {
    /// Settings → Batching → "Wait before picking up a file": hours (0–24) and minutes (0–59), up to 24 hours.
    public static let hoursRange: ClosedRange<Int> = 0...24
    public static let minutesRange: ClosedRange<Int> = 0...59
    public static let maxSeconds = 24 * 3600
    /// No wait / 1 min / 10 min / 1 hour / 4 hours / 24 hours (seconds).
    public static let presets: [(String, Int)] = [("No wait", 0), ("1 min", 60), ("10 min", 600), ("1 hour", 3600),
                                                  ("4 hours", 4 * 3600), ("24 hours", 24 * 3600)]

    public var hours: Int { didSet { hours = min(max(hours, Self.hoursRange.lowerBound), Self.hoursRange.upperBound) } }
    public var minutes: Int { didSet { minutes = min(max(minutes, Self.minutesRange.lowerBound), Self.minutesRange.upperBound) } }

    /// Seconds a wait set elsewhere may carry (90 s) are rounded down to the minute only when the user edits a field.
    public init(totalSeconds: Int) {
        let total = Self.clamp(totalSeconds)
        hours = total / 3600
        minutes = (total % 3600) / 60
    }

    /// 24 hours is the most: at 24 h the minutes are 0.
    public var totalSeconds: Int { Self.clamp(hours * 3600 + (hours >= 24 ? 0 : minutes * 60)) }

    public static func clamp(_ seconds: Int) -> Int { min(max(0, seconds), maxSeconds) }
}
