import Foundation

/// Wording for Collectors (canvas row 7): list rows, the title line, the status
/// card, run lines and schedules. Pure: every function takes `now`, so tests
/// and snapshots pin the clock. The core only sends data; the words live here.
public struct CollectorText: Sendable {
    public var calendar: Calendar
    public var locale: Locale
    public var home: String

    public init(calendar: Calendar = .current, locale: Locale = .current, home: String = NSHomeDirectory()) {
        self.calendar = calendar
        self.locale = locale
        self.home = home
    }

    // MARK: Paths

    /// "/Users/mei/Distill Inbox" → "~/Distill Inbox".
    public func tilde(_ path: String) -> String {
        guard !home.isEmpty, home != "/" else { return path }
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    /// "~/Distill Inbox" → "/Users/mei/Distill Inbox"; other paths unchanged (trimmed).
    public func expand(_ path: String) -> String {
        let p = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if p == "~" { return home }
        if p.hasPrefix("~/") { return home + p.dropFirst(1) }
        return p
    }

    // MARK: Clock

    public func clock(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateStyle = .none
        f.timeStyle = .short
        return f.string(from: date).replacingOccurrences(of: "\u{202F}", with: " ")
    }

    private func dayName(_ date: Date, template: String) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.setLocalizedDateFormatFromTemplate(template)
        return f.string(from: date)
    }

    /// "at 9:00 AM" today, "yesterday at 7:00 AM", "Oct 2 at 7:00 AM".
    public func at(_ date: Date, now: Date) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "at \(clock(date))" }
        if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: y) { return "yesterday at \(clock(date))" }
        return "\(dayName(date, template: "MMMd")) at \(clock(date))"
    }

    /// The time column of a run line: "Today 9:00 AM", then "8:00 AM" for more runs that
    /// day; "Yesterday 7:00 AM"; "Oct 2, 7:00 AM". `previous` is the run listed above.
    public func runTime(_ date: Date, previous: Date?, now: Date) -> String {
        if let previous, calendar.isDate(previous, inSameDayAs: date) { return clock(date) }
        if calendar.isDate(date, inSameDayAs: now) { return "Today \(clock(date))" }
        if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: y) { return "Yesterday \(clock(date))" }
        return "\(dayName(date, template: "MMMd")), \(clock(date))"
    }

    /// "next at 10:00 AM", "next tomorrow at 7:00 AM", "next Mon, Oct 5 at 9:00 AM".
    public func next(_ date: Date, now: Date) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "next at \(clock(date))" }
        if let t = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: t) { return "next tomorrow at \(clock(date))" }
        return "next \(dayName(date, template: "EEEMMMd")) at \(clock(date))"
    }

    /// "0.4 s", "2.4 s", "1:05".
    public static func duration(_ ms: Double?) -> String? {
        guard let ms, ms >= 0 else { return nil }
        let s = ms / 1000
        if s < 60 { return String(format: "%.1f s", s) }
        let whole = Int(s.rounded())
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }

    /// "0:12" for a live elapsed time.
    public static func elapsed(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    /// "5 min", "30 s", "1 hour".
    public static func timeout(_ seconds: Int) -> String {
        if seconds % 3600 == 0 { return seconds == 3600 ? "1 hour" : "\(seconds / 3600) hours" }
        if seconds % 60 == 0 { return "\(seconds / 60) min" }
        return "\(seconds) s"
    }

    public static func files(_ n: Int) -> String { n == 1 ? "1 file" : "\(n) files" }
    public static func items(_ n: Int) -> String { n == 1 ? "1 item" : "\(n) items" }

    // MARK: Schedules

    /// The cron of a preset; daily presets take a time.
    public static func cron(preset: SchedulePreset, hour: Int = 9, minute: Int = 0) -> String {
        switch preset {
        case .every15: return "*/15 * * * *"
        case .hourly: return "0 * * * *"
        case .daily: return "\(minute) \(hour) * * *"
        case .weekdays: return "\(minute) \(hour) * * 1-5"
        default: return "\(minute) \(hour) * * *"
        }
    }

    /// The parts of a cron the presets can express, or nil.
    public struct CronShape: Equatable, Sendable {
        public var preset: SchedulePreset
        public var hour: Int
        public var minute: Int
        /// Days of the week (0 = Sunday … 6) for a "M H * * d,d" cron.
        public var weekdays: [Int]
    }

    public static func shape(_ raw: String) -> CronShape? {
        let cron = raw.trimmingCharacters(in: .whitespaces)
        if cron == "@hourly" { return CronShape(preset: .hourly, hour: 0, minute: 0, weekdays: []) }
        if cron == "@daily" || cron == "@midnight" { return CronShape(preset: .daily, hour: 0, minute: 0, weekdays: []) }
        let f = cron.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard f.count == 5 else { return nil }
        if f[0] == "*/15", f[1] == "*", f[2] == "*", f[3] == "*", f[4] == "*" { return CronShape(preset: .every15, hour: 0, minute: 0, weekdays: []) }
        guard let m = Int(f[0]), (0...59).contains(m) else { return nil }
        if f[1] == "*", f[2] == "*", f[3] == "*", f[4] == "*" {
            return CronShape(preset: m == 0 ? .hourly : .custom, hour: 0, minute: m, weekdays: [])
        }
        guard let h = Int(f[1]), (0...23).contains(h), f[2] == "*", f[3] == "*" else { return nil }
        if f[4] == "*" { return CronShape(preset: .daily, hour: h, minute: m, weekdays: []) }
        if f[4] == "1-5" || f[4] == "MON-FRI" || f[4] == "mon-fri" { return CronShape(preset: .weekdays, hour: h, minute: m, weekdays: [1, 2, 3, 4, 5]) }
        let days = f[4].split(separator: ",").compactMap { Int($0) }.map { $0 == 7 ? 0 : $0 }
        guard !days.isEmpty, days.count == f[4].split(separator: ",").count, days.allSatisfy({ (0...6).contains($0) }) else { return nil }
        return CronShape(preset: .custom, hour: h, minute: m, weekdays: Array(Set(days)).sorted { ($0 + 6) % 7 < ($1 + 6) % 7 })
    }

    private func time(_ hour: Int, _ minute: Int) -> String {
        let d = calendar.date(from: DateComponents(year: 2026, month: 1, day: 5, hour: hour, minute: minute)) ?? Date()
        return clock(d)
    }

    private static let shortDays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    private static func list(_ items: [String]) -> String {
        items.count <= 1 ? items.joined() : items.dropLast().joined(separator: ", ") + " and " + items.last!
    }

    /// The Settings line: "Every hour", "Every hour at :30", "Every 15 minutes",
    /// "Every day at 7:00 AM", "Weekdays at 9:00 AM", "Mon, Wed and Fri at 8:30 AM", or "Custom (cron)".
    public func schedule(_ cron: String) -> String {
        guard let s = Self.shape(cron) else { return "Custom: \(cron.trimmingCharacters(in: .whitespaces))" }
        switch s.preset {
        case .every15: return "Every 15 minutes"
        case .hourly: return "Every hour"
        case .daily: return "Every day at \(time(s.hour, s.minute))"
        case .weekdays: return "Weekdays at \(time(s.hour, s.minute))"
        default:
            if s.weekdays.isEmpty { return String(format: "Every hour at :%02d", s.minute) }
            return "\(Self.list(s.weekdays.map { Self.shortDays[$0] })) at \(time(s.hour, s.minute))"
        }
    }

    /// The ScheduleField preview: "Every hour, on the hour", "Monday to Friday at 9:00 AM", …
    public func preview(_ cron: String) -> String? {
        guard let s = Self.shape(cron) else { return nil }
        switch s.preset {
        case .every15: return "Every 15 minutes, starting on the hour"
        case .hourly: return "Every hour, on the hour"
        case .weekdays: return "Monday to Friday at \(time(s.hour, s.minute))"
        default: return schedule(cron)
        }
    }

    /// The list row's short form: "Every hour", "Daily at 7:00 AM", "Weekdays at 9:00 AM".
    public func shortSchedule(_ cron: String) -> String {
        if let s = Self.shape(cron), s.preset == .daily { return "Daily at \(time(s.hour, s.minute))" }
        if let s = Self.shape(cron), s.preset == .every15 { return "Every 15 min" }
        return schedule(cron)
    }

    /// "every hour" for running text.
    public func lowerSchedule(_ cron: String) -> String {
        let s = schedule(cron)
        guard let first = s.first else { return s }
        // Keep weekday names ("Mon, Wed …") capitalised.
        if Self.shortDays.contains(where: { s.hasPrefix($0) }) || s.hasPrefix("Custom") { return s }
        return first.lowercased() + s.dropFirst()
    }

    // MARK: Rows, title, status

    public enum StatusKind: String, Sendable { case on, off, running, error, consent }

    public func statusKind(_ c: Collector) -> StatusKind {
        if c.isRunning || c.isInstalling { return .running }
        if c.needsConsent { return .consent }
        if c.needsAttention { return .error }
        return c.enabled ? .on : .off
    }

    /// The pill text (only Running, Failed and Needs your OK have one).
    public func pill(_ c: Collector) -> String? {
        switch statusKind(c) {
        case .running: return "Running"
        case .error: return "Failed"
        case .consent: return "Needs your OK"
        default: return nil
        }
    }

    /// The script changed since it was allowed (not a first consent).
    public func scriptChanged(_ c: Collector) -> Bool {
        c.needsConsent && (c.script?.allowedSha256 != nil || c.lastRun?.error?.code == .scriptChanged)
    }

    /// "Copying…" / "Running · 0:12".
    public func runningLine(_ c: Collector, run: CollectorRun?, now: Date) -> String {
        if run?.result == .queued { return Self.waitingLine(run?.waiting) }
        if c.isScript { return (run?.isTest == true ? "Test run · " : "Running · ") + Self.elapsed(now.timeIntervalSince(run?.startedAt ?? now)) }
        return (c.folder?.moves ?? false) ? "Moving…" : "Copying…"
    }

    /// A queued run: what it waits for.
    public static func waitingLine(_ waiting: String?) -> String {
        switch waiting {
        case "batch": return "Waiting for a batch to apply"
        case "install": return "Waiting for packages to install"
        default: return "Waiting to start"
        }
    }

    /// v6: the manifest changed since the OK and the script didn't.
    public func manifestOnlyChanged(_ c: Collector) -> Bool {
        let ch = c.status?.script?.changes ?? []
        return c.needsConsent && ch.contains("manifest") && !ch.contains("script")
    }

    /// v6: the last install of this manifest failed (runs wait until Install again).
    public func installFailed(_ c: Collector) -> Bool { c.manifest?.state == "failed" }

    /// The one status line under a row's name. `latest` is the newest run the app knows (a Test run
    /// never becomes `status.lastRun`, so the list says so from the run history).
    public func rowSummary(_ c: Collector, now: Date, run: CollectorRun? = nil, latest: CollectorRun? = nil) -> String {
        switch statusKind(c) {
        case .running:
            // An install and a run never go at once (a run started meanwhile waits), so installing wins.
            if c.isInstalling { return "Installing packages…" }
            return runningLine(c, run: run ?? c.lastRun, now: now)
        case .consent:
            if manifestOnlyChanged(c) { return "\(c.manifest?.name ?? "Packages") changed" }
            if scriptChanged(c) { return "Script changed · paused" }
            return c.lastRun == nil || c.lastRun?.result == .notTrusted ? "Never run" : "Waiting for your OK"
        case .error:
            if installFailed(c) { return "Couldn’t install packages" }
            guard let r = c.lastRun else { return "Failed" }
            switch r.error?.code {
            case .sourceMissing?: return "Folder missing"
            case .noPermission?: return "No permission"
            case .queueMissing?: return "Queue folder missing"
            default: break
            }
            if r.result == .timedout { return "Timed out \(at(r.startedAt, now: now))" }
            if let code = r.exitCode, code != 0 { return "Exit \(code) \(at(r.startedAt, now: now))" }
            return "Failed \(at(r.startedAt, now: now))"
        case .off: return "Off"
        case .on:
            if let t = latest, t.isTest, !t.result.isActive, t.startedAt >= (c.lastRun?.startedAt ?? .distantPast) {
                if t.result == .success || t.result == .nothing {
                    return t.filesAdded.isEmpty ? "Test run · nothing made" : "Test run · \(Self.files(t.filesAdded.count)), not queued"
                }
                return "Test run · failed"
            }
            let sched = shortSchedule(c.schedule.cron)
            guard let r = c.lastRun else { return "\(sched) · never run" }
            if r.trigger == "now", r.result == .success || r.result == .nothing { return "Run now · \(lastRunPhrase(c, r, now: now))" }
            return "\(sched) · \(lastRunPhrase(c, r, now: now))"
        }
    }

    /// "copied 3 at 9:00 AM", "added 4 at 7:00 AM", "nothing new at 10:00 AM".
    public func lastRunPhrase(_ c: Collector, _ r: CollectorRun, now: Date) -> String {
        let when = at(r.startedAt, now: now)
        switch r.result {
        case .success:
            if c.isScript { return "added \(r.counts.added) \(when)" }
            if r.counts.moved > 0 { return "moved \(r.counts.moved) \(when)" }
            return "copied \(r.counts.copied) \(when)"
        case .nothing: return "nothing new \(when)"
        case .stopped: return "stopped \(when)"
        case .skipped: return "skipped \(when)"
        default: return "last run \(when)"
        }
    }

    /// The quiet line under the detail title: "Folder · every hour · next at 10:00 AM".
    public func titleLine(_ c: Collector, now: Date) -> String {
        var parts = [c.isScript ? "Script" : (c.isFolder ? "Folder" : c.kind.rawValue.capitalized)]
        // v6 cores (status.script) name the language: "Script · Python · every day at 7:00 AM".
        if c.isScript, c.status?.script != nil, let lang = c.script?.interpreter.language { parts.append(lang) }
        if scriptChanged(c) { return (parts + [c.status?.script != nil ? "paused until you allow it" : "paused"]).joined(separator: " · ") }
        if installFailed(c), !c.isInstalling { return (parts + ["waits for its packages"]).joined(separator: " · ") }
        parts.append(lowerSchedule(c.schedule.cron))
        if c.isInstalling { return parts.joined(separator: " · ") }
        if c.folder?.moves == true, statusKind(c) == .error { parts.append("moves files") }
        if c.needsConsent { parts.append("waits for your OK") } else if !c.enabled { parts.append("off") } else if !c.isRunning,
                  statusKind(c) != .error, let n = c.status?.nextRunAt {
            let phrase = next(n, now: now)
            parts.append(phrase.hasPrefix("next tomorrow") ? "next tomorrow" : phrase)
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Runs

    public enum RunKind: String, Sendable { case success, nothing, failed, timedout, skipped, running }

    /// RunLogEntry's `result`.
    public static func runKind(_ r: CollectorRunResult) -> RunKind {
        switch r {
        case .success: return .success
        case .nothing: return .nothing
        case .timedout: return .timedout
        case .running, .queued: return .running
        case .skipped, .notTrusted, .stopped: return .skipped
        default: return .failed
        }
    }

    /// "Copied 3 files · skipped 2 already collected", "Added 4 files", "Folder missing", …
    public func runSummary(_ r: CollectorRun, now: Date = Date()) -> String {
        let base = runSummaryBody(r, now: now)
        // v6: Test runs and Run now say so, as on the board ("Run now · added 2 files", "Test run · 2 files in the test folder").
        if r.isTest {
            switch r.result {
            case .success, .nothing: return r.filesAdded.isEmpty ? "Test run · nothing in the test folder" : "Test run · \(Self.files(r.filesAdded.count)) in the test folder"
            case .queued, .running, .notTrusted: return base
            default: return "Test run · " + base.prefix(1).lowercased() + base.dropFirst()
            }
        }
        if r.trigger == "now", r.result == .queued, r.waiting == "install" { return "Run now · waits for packages" }
        if r.trigger == "now", [.success, .nothing, .failed, .timedout, .stopped].contains(r.result), r.error?.code != .installFailed {
            return "Run now · " + base.prefix(1).lowercased() + base.dropFirst()
        }
        return base
    }

    private func runSummaryBody(_ r: CollectorRun, now: Date) -> String {
        let n = r.counts
        func added() -> String { n.added == 0 ? "added nothing" : "added \(Self.files(n.added))" }
        switch r.result {
        case .queued: return Self.waitingLine(r.waiting)
        case .running: return "Running · " + Self.elapsed(now.timeIntervalSince(r.startedAt))
        case .nothing: return "Nothing new"
        case .success:
            if r.kind == .script { return n.added == 0 ? "Nothing new" : "Added \(Self.files(n.added))" }
            // A run that took a subfolder counts items (a folder is one), as on the board: "Copied 3 items".
            let unit: (Int) -> String = (r.files ?? []).contains(where: \.isFolder) ? Self.items : Self.files
            var parts: [String] = []
            if n.moved > 0 { parts.append("Moved \(unit(n.moved))") }
            if n.copied > 0 || parts.isEmpty { parts.append("Copied \(unit(n.copied))") }
            if n.skipped > 0 { parts.append("skipped \(n.skipped) already collected") }
            if n.waiting > 0 { parts.append("\(n.waiting) still changing") }
            if n.errors > 0 { parts.append("\(n.errors) failed") }
            return parts.joined(separator: " · ")
        case .timedout: return "Stopped after \(r.durationMs.map { Self.timeout(Int(($0 / 1000).rounded())) } ?? "the timeout") · \(added())"
        case .stopped: return "Stopped · \(added())"
        case .skipped: return "Skipped" + (r.skipReason.map { " · \($0)" } ?? "")
        case .notTrusted:
            return r.error?.code == .scriptChanged ? "Not run · the script changed" : "Not run · waiting for your OK"
        default:
            switch r.error?.code {
            case .sourceMissing?: return "Folder missing"
            case .noPermission?: return "No permission to read the folder"
            case .queueMissing?: return "Queue folder missing"
            case .vaultMissing?: return "Vault missing"
            case .scriptMissing?: return "Script missing"
            case .interpreterMissing?: return "Interpreter not found"
            case .interrupted?: return "Interrupted · Distill quit during the run"
            case .installFailed?: return "Not run · packages aren’t installed"
            default: break
            }
            if r.kind == .script { return "Failed · \(added())" }
            return r.error?.message.isEmpty == false ? r.error!.message : "Failed"
        }
    }

    /// RunLogEntry's `meta`: "0.4 s", "exit 0 · 2.4 s", "exit 1", "timeout".
    public func runMeta(_ r: CollectorRun) -> String {
        if r.result == .timedout { return "timeout" }
        if r.error?.code == .installFailed { return "Install again first" }
        if r.result.isActive || r.result == .skipped || r.result == .notTrusted { return "" }
        let d = Self.duration(r.durationMs)
        if r.kind == .script, let code = r.exitCode {
            return code == 0 ? (["exit 0"] + [d].compactMap { $0 }).joined(separator: " · ") : "exit \(code)"
        }
        if r.result == .failed, r.kind == .folder { return "" }
        return d ?? ""
    }

    /// Folder runs: "Copied — name" lines; scripts: the command and its output.
    /// Returns (outputKind, lines).
    public func runLines(_ r: CollectorRun, command: String?) -> (String, [String]) {
        if r.kind == .script {
            let err = (r.stderrTail ?? "").trimmingCharacters(in: .newlines)
            let out = (r.stdoutTail ?? "").trimmingCharacters(in: .newlines)
            let useErr = !err.isEmpty && (r.result == .failed || out.isEmpty)
            let body = useErr ? err : out
            var lines = command.map { ["$ " + $0] } ?? []
            lines += body.isEmpty ? [] : body.components(separatedBy: "\n")
            if r.result == .timedout { lines.append("[stopped by Distill after \(Self.duration(r.durationMs) ?? "the timeout")]") }
            if r.result == .stopped { lines.append("[stopped]") }
            if body.isEmpty, let m = r.error?.message, !m.isEmpty, r.result == .failed { lines.append(m) }
            return (useErr ? "stderr" : "stdout", lines.count <= (command == nil ? 0 : 1) ? [] : lines)
        }
        let lines = (r.files ?? []).map { f -> String in
            let name = Self.runFileName(f)
            switch f.outcome {
            case .copied: return "Copied — \(name)"
            case .moved: return "Moved — \(name)"
            case .skipped: return "Skipped · already collected — \(name)"
            case .waiting: return "Waiting · \(f.reason ?? "still changing") — \(name)"
            default: return "Error — \(name)" + (f.reason.map { " (\($0))" } ?? "")
            }
        }
        return ("files", lines)
    }

    /// The name in a Folder run line. A subfolder item: "Tea tasting trip/ (folder · 5 new of 12 files)";
    /// a collected `.gdoc`: "Q3 plan.gdoc (waits in the queue: needs Google Drive access)".
    public static func runFileName(_ f: CollectorRunFile) -> String {
        if f.isFolder {
            let base = f.name.hasSuffix("/") ? f.name : f.name + "/"
            var detail = ["folder"]
            if let total = f.fileCount {
                let unit = total == 1 ? "file" : "files"
                if let new = f.newCount, f.outcome == .copied || f.outcome == .moved {
                    detail.append("\(new) new of \(total) \(unit)")
                } else {
                    detail.append("\(total) \(unit)")
                }
            }
            return "\(base) (\(detail.joined(separator: " · ")))"
        }
        if f.name.lowercased().hasSuffix(".gdoc"), f.outcome == .copied || f.outcome == .moved {
            return "\(f.name) (waits in the queue: needs Google Drive access)"
        }
        return f.name
    }

    // MARK: v6: script files and packages

    /// "Oct 3" (or "today") for a short date in running text.
    public func shortDay(_ date: Date, now: Date) -> String {
        calendar.isDate(date, inSameDayAs: now) ? "today" : dayName(date, template: "MMMd")
    }

    /// The Settings "Packages" line as (value, quiet suffix): "requirements.txt", " · 3 installed Oct 3".
    public func packagesLine(_ m: CollectorManifestStatus, now: Date) -> (String, String) {
        let count = m.packageCount == 1 ? "1 package" : "\(m.packageCount) packages"
        switch m.state {
        case "installing": return (m.name, " · installing…")
        case "failed": return (m.name, " · \(count) · couldn’t install")
        case "needsInstall": return (m.name, " · \(count) · not installed yet")
        case "ready":
            let when = m.lastInstall?.endedAt ?? m.lastInstall?.startedAt
            return (m.name, " · \(m.packageCount) installed" + (when.map { " " + shortDay($0, now: now) } ?? ""))
        default:
            return m.exists ? (m.name, " · no packages") : ("None", " · add \(m.name) in Edit")
        }
    }

    /// The PackagesPanel status line for a state.
    public func packagesStatus(_ m: CollectorManifestStatus?, state: String, now: Date) -> String {
        let n = m?.packageCount ?? 0
        switch state {
        case "none": return "No packages. Add one to install it into this folder."
        case "ready":
            let when = (m?.lastInstall?.endedAt).map { " · " + at($0, now: now).replacingOccurrences(of: "at ", with: "", options: .anchored) } ?? ""
            return "\(n) installed · ready" + when
        case "needsInstall": return "Not installed yet · Install now, or it installs before the next run"
        case "installing": return "Installing…"
        case "failed": return "Couldn’t install" + ((m?.lastInstall?.exitCode).map { " · exit \($0)" } ?? "") + " · runs wait until it installs"
        case "needsOK": return "Changed · installs when you allow it"
        default: return ""
        }
    }

    /// What runs the script, for Advanced: "python3 from your PATH, with the collector’s .venv".
    public func runsWith(_ c: Collector) -> String {
        guard let s = c.script else { return "" }
        switch s.interpreter.rawValue {
        case "python3":
            return c.isManaged && c.manifest?.installedSha256 != nil ? "python3 from your PATH, with the collector’s .venv" : "python3 from your PATH"
        case "node": return "node from your PATH"
        case "typescript": return "node from your PATH, types stripped"
        default: return s.interpreter.rawValue
        }
    }

    /// What the consent covers, for the Allowed line: "script and requirements.txt".
    public func allowedCovers(_ c: Collector) -> String? {
        guard let m = c.manifest, m.exists || c.script?.allowedFiles?.manifest != nil else { return nil }
        return "script and \(m.name)"
    }

    /// The whole run list with long stretches of quiet runs collapsed:
    /// three or more "Nothing new" runs in a row on the same day become one "N runs with nothing new" entry.
    public enum RunRow: Equatable, Sendable {
        case run(CollectorRun)
        case quiet(count: Int, newest: Date)
    }

    public static func collapse(_ runs: [CollectorRun], keepFirst: Int = 3, calendar: Calendar = .current) -> [RunRow] {
        var out: [RunRow] = []
        var i = 0
        while i < runs.count {
            if i >= keepFirst, runs[i].result == .nothing {
                var j = i
                while j < runs.count, runs[j].result == .nothing, calendar.isDate(runs[j].startedAt, inSameDayAs: runs[i].startedAt) { j += 1 }
                if j - i >= 3 {
                    out.append(.quiet(count: j - i, newest: runs[i].startedAt))
                    i = j
                    continue
                }
            }
            out.append(.run(runs[i]))
            i += 1
        }
        return out
    }
}
