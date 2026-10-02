import Foundation

/// The status pill on a Queue row (canvas: "Queue rows: every state").
public enum QueueRowStatus: Equatable, Sendable {
    /// Waiting for the settle delay; a fixed clock time, never a ticking counter.
    case readyAt(Date)
    case ready
    /// A running batch is reading it (row locked, no ×).
    case inBatch
    /// Added while a batch runs: it waits for the next one.
    case nextBatch
    /// "Couldn't read", with the core's reason in the tooltip.
    case problem(String)

    public enum Tone: Sendable { case gray, green, blue, peach }

    public var tone: Tone {
        switch self {
        case .readyAt, .nextBatch: return .gray
        case .ready: return .green
        case .inBatch: return .blue
        case .problem: return .peach
        }
    }

    /// Rows in a running batch can't be removed.
    public var removable: Bool { self != .inBatch }
}

/// Where a queued file came from, for the row's meta line.
public enum QueueRowOrigin: Equatable, Sendable {
    case pasted, dropped, note

    public var verb: String {
        switch self {
        case .pasted: return "Pasted"
        case .dropped: return "Dropped"
        case .note: return "Added"
        }
    }
}

/// Pure formatting for Queue rows and the Queue header. Times are clock times
/// ("Pasted at 3:04 AM", "Ready at 3:14 AM", "Next batch at 5:30 AM") so the
/// screen never ticks; it changes only when the core's queue changes.
public enum QueueRows {
    public static let manifestSuffix = ".distill.json"

    /// Rows to show: a note's `.distill.json` sidecar is hidden (removing the
    /// note's `.md` takes it along).
    public static func visible(_ entries: [QueueEntry]) -> [QueueEntry] {
        entries.filter { !$0.name.hasSuffix(manifestSuffix) }
    }

    public static func status(_ entry: QueueEntry, batchRunning: Bool) -> QueueRowStatus {
        if let problem = entry.problem { return .problem(problem) }
        if batchRunning { return .nextBatch }
        if entry.kind == .note || entry.settled { return .ready }
        if let at = entry.readyAt { return .readyAt(at) }
        return .ready
    }

    public static func pillText(_ status: QueueRowStatus, now: Date = Date(),
                                locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        switch status {
        case .readyAt(let date): return "Ready " + at(date, now: now, locale: locale, timeZone: timeZone)
        case .ready: return "Ready"
        case .inBatch: return "In batch"
        case .nextBatch: return "Next batch"
        case .problem: return "Couldn’t read"
        }
    }

    /// Hover text for the pill.
    public static func pillHelp(_ status: QueueRowStatus, settleSeconds: Int) -> String? {
        switch status {
        case .readyAt:
            return "Distill waits \(waitPhrase(settleSeconds)) after a file last changes so half-written files aren't picked up. Process now skips the wait."
        case .problem(let reason): return reason
        case .inBatch: return "A batch is reading it now."
        case .nextBatch: return "Added while a batch runs: it waits for the next one."
        case .ready: return nil
        }
    }

    /// Screenshot/Clipping files named by paste intake (intake-paste-drop.md) were pasted; notes were written in Distill.
    public static func origin(_ entry: QueueEntry) -> QueueRowOrigin {
        if entry.kind == .note { return .note }
        let pasted = #"^(Screenshot|Clipping) \d{4}-\d{2}-\d{2} \d{6}( \d+)?\.(png|md)$"#
        return entry.name.range(of: pasted, options: .regularExpression) != nil ? .pasted : .dropped
    }

    /// The row title: a written note shows its title (the file stem), anything else its file name.
    public static func title(_ entry: QueueEntry) -> String {
        if entry.kind == .note, entry.name.hasSuffix(".md") { return String(entry.name.dropLast(3)) }
        return entry.name
    }

    /// "Pasted at 3:04 AM · 36 KB", "Written note · Added at 3:04 AM".
    public static func meta(_ entry: QueueEntry, now: Date = Date(),
                            locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        let origin = origin(entry)
        let when = "\(origin.verb) \(at(entry.modified, now: now, locale: locale, timeZone: timeZone))"
        if origin == .note, entry.name.hasSuffix(".md") { return "Written note · " + when }
        guard entry.size > 0 else { return when }
        let size = ByteCountFormatter.string(fromByteCount: Int64(entry.size), countStyle: .file)
        return "\(when) · \(size)"
    }

    /// "3:04 AM" today; "Sep 3, 3:04 AM" on another day.
    public static func clock(_ date: Date, now: Date = Date(), locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = timeZone
        f.setLocalizedDateFormatFromTemplate(calendar.isDate(date, inSameDayAs: now) ? "jmm" : "MMMdjmm")
        return f.string(from: date)
    }

    /// "at 3:04 AM" today; "Sep 3 at 2:12 AM" on another day.
    public static func at(_ date: Date, now: Date = Date(), locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let text = clock(date, now: now, locale: locale, timeZone: timeZone)
        return calendar.isDate(date, inSameDayAs: now) ? "at " + text : text
    }

    /// Header: "Next batch at 5:30 AM · every 2 hours".
    public static func nextBatchLine(_ next: Date, intervalMinutes: Int, now: Date = Date(),
                                     locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        "Next batch \(at(next, now: now, locale: locale, timeZone: timeZone)) · every \(BatchInterval(totalMinutes: intervalMinutes).phrase)"
    }

    /// "10 min", "30 s", "1 min 30 s".
    static func waitPhrase(_ seconds: Int) -> String {
        let m = max(0, seconds) / 60, s = max(0, seconds) % 60
        switch (m, s) {
        case (0, _): return "\(s) s"
        case (_, 0): return "\(m) min"
        default: return "\(m) min \(s) s"
        }
    }
}

extension BatchInterval {
    /// Long form for sentences: "2 hours", "1 hour 30 minutes", "1 day", "45 minutes".
    public var phrase: String {
        let t = totalMinutes
        let parts = [(t / 1440, "day"), ((t % 1440) / 60, "hour"), (t % 60, "minute")]
            .filter { $0.0 > 0 }
            .map { "\($0.0) \($0.1)\($0.0 == 1 ? "" : "s")" }
        return parts.joined(separator: " ")
    }
}
