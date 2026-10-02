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
    public static let range: ClosedRange<Int> = 0...59

    public var minutes: Int { didSet { minutes = Self.clamp(minutes) } }
    public var seconds: Int { didSet { seconds = Self.clamp(seconds) } }

    public init(totalSeconds: Int) {
        let total = min(max(0, totalSeconds), 59 * 60 + 59)
        minutes = total / 60
        seconds = total % 60
    }

    public var totalSeconds: Int { minutes * 60 + seconds }

    private static func clamp(_ v: Int) -> Int { min(max(v, range.lowerBound), range.upperBound) }
}
