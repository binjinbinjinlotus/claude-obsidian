import Foundation

// v7 live log (spec live-log.md): a job's steps (`JobStep` in contracts.ts) and the
// UI-free logic that turns them, or a collector's output, into the lines the log shows.

/// One line of a job's live log, as the core keeps it. A changed step comes again with the same id.
public struct JobStep: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var at: Date
    public var endedAt: Date?
    /// prepare | agent | check | review | apply
    public var phase: String
    /// step | note
    public var kind: String
    /// done | running | waiting | review | failed
    public var state: String
    /// What sort of step (read, readPage, search, command, write, label, …), for folding repeats.
    public var verb: String
    public var text: String
    public var detail: String?
    public var count: String?
    public var file: String?
    public var parent: String?
    /// v8: what to do next, on a failed apply step.
    public var hint: String?

    public init(id: String, at: Date, endedAt: Date? = nil, phase: String = "agent", kind: String = "step", state: String = "done",
                verb: String = "tool", text: String, detail: String? = nil, count: String? = nil, file: String? = nil, parent: String? = nil,
                hint: String? = nil) {
        self.id = id; self.at = at; self.endedAt = endedAt; self.phase = phase; self.kind = kind; self.state = state
        self.verb = verb; self.text = text; self.detail = detail; self.count = count; self.file = file; self.parent = parent; self.hint = hint
    }

    enum Keys: String, CodingKey { case id, at, endedAt, phase, kind, state, verb, text, detail, count, file, parent, hint }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        guard let id = c.lossy(String.self, .id), !id.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "a step needs an id")
        }
        self.id = id
        at = c.lossyDate(.at) ?? Date(timeIntervalSince1970: 0)
        endedAt = c.lossyDate(.endedAt)
        phase = c.lossy(String.self, .phase) ?? "agent"
        kind = c.lossy(String.self, .kind) ?? "step"
        state = c.lossy(String.self, .state) ?? "done"
        verb = c.lossy(String.self, .verb) ?? "tool"
        text = c.lossy(String.self, .text) ?? ""
        detail = c.lossy(String.self, .detail)
        count = c.lossy(String.self, .count)
        file = c.lossy(String.self, .file)
        parent = c.lossy(String.self, .parent)
        hint = c.lossy(String.self, .hint)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(id, forKey: .id)
        try c.encode(CoreDate.format(at), forKey: .at)
        try c.encodeIfPresent(endedAt.map(CoreDate.format), forKey: .endedAt)
        try c.encode(phase, forKey: .phase)
        try c.encode(kind, forKey: .kind)
        try c.encode(state, forKey: .state)
        try c.encode(verb, forKey: .verb)
        try c.encode(text, forKey: .text)
        try c.encodeIfPresent(detail, forKey: .detail)
        try c.encodeIfPresent(count, forKey: .count)
        try c.encodeIfPresent(file, forKey: .file)
        try c.encodeIfPresent(parent, forKey: .parent)
        try c.encodeIfPresent(hint, forKey: .hint)
    }
}

/// `GET /v1/jobs/:id/steps`.
public struct JobStepsPage: Codable, Equatable, Sendable {
    public var jobId: String
    public var steps: [JobStep]
    /// False when the job ran before steps were kept.
    public var kept: Bool
    public var truncated: Bool

    public init(jobId: String, steps: [JobStep], kept: Bool = true, truncated: Bool = false) {
        self.jobId = jobId; self.steps = steps; self.kept = kept; self.truncated = truncated
    }

    enum Keys: String, CodingKey { case jobId, steps, kept, truncated }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        jobId = c.lossy(String.self, .jobId) ?? ""
        steps = c.lossyArray(JobStep.self, .steps)
        kept = c.lossy(Bool.self, .kept) ?? !steps.isEmpty
        truncated = c.lossy(Bool.self, .truncated) ?? false
    }
}

/// One line the log view draws (`LogLine` on the canvas).
public struct LogRow: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable { case phase, step, group, note, output }
    public var id: String
    public var kind: Kind
    /// done | running | waiting | review | failed
    public var state: String
    public var text: String
    public var count: String?
    /// "14/22": the thin bar of a running group.
    public var progress: (done: Int, total: Int)?
    public var detail: String?
    /// Shown only when the minute changes (steps) or the second changes (output).
    public var time: Date?
    public var level: Int
    public var expanded: Bool
    /// output: stdout | stderr | cmd | system
    public var stream: String

    public init(id: String, kind: Kind, state: String = "done", text: String, count: String? = nil, progress: (done: Int, total: Int)? = nil,
                detail: String? = nil, time: Date? = nil, level: Int = 0, expanded: Bool = false, stream: String = "stdout") {
        self.id = id; self.kind = kind; self.state = state; self.text = text; self.count = count; self.progress = progress
        self.detail = detail; self.time = time; self.level = level; self.expanded = expanded; self.stream = stream
    }

    public static func == (a: LogRow, b: LogRow) -> Bool {
        a.id == b.id && a.kind == b.kind && a.state == b.state && a.text == b.text && a.count == b.count
            && a.progress?.done == b.progress?.done && a.progress?.total == b.progress?.total && a.detail == b.detail
            && a.time == b.time && a.level == b.level && a.expanded == b.expanded && a.stream == b.stream
    }
}

public enum LiveLog {
    /// Steps of these sorts fold when three or more come in a row ("Read 22 sources").
    static let foldable: Set<String> = ["read", "readPage", "readRef", "search", "command", "write", "edit"]
    static let foldAt = 3

    /// Phase headings: Getting ready · Claude’s steps · Checking · Your review · Applying.
    public static func phaseTitle(_ phase: String, runner: String) -> String {
        switch phase {
        case "prepare": return "GETTING READY"
        case "agent": return "\(runner.uppercased())’S STEPS"
        case "check": return "CHECKING"
        case "review": return "YOUR REVIEW"
        case "apply": return "APPLYING"
        default: return phase.uppercased()
        }
    }

    /// A job that is no longer running leaves no spinner: a step still marked running
    /// (cut off by the step cap, a core restart or a failure) shows as done, or as
    /// failed when the job failed or was cancelled. Once the job is finished, nothing
    /// is still waiting for you either.
    public static func settled(_ steps: [JobStep], job: JobState) -> [JobStep] {
        guard job != .running else { return steps }
        let failed = job == .failed || job == .cancelled
        return steps.map { s in
            var t = s
            if s.state == "running" { t.state = failed ? "failed" : "done" }
            else if s.state == "review" && job.isFinished { t.state = "done" }
            return t
        }
    }

    /// Keep the newest version of each step, in the order they first came.
    public static func merge(_ steps: [JobStep], _ step: JobStep) -> [JobStep] {
        var out = steps
        if let i = out.firstIndex(where: { $0.id == step.id }) { out[i] = step } else { out.append(step) }
        return out
    }

    /// The rows of a job's log. `expanded`: ids of groups the user opened (or closed, for a running labels group
    /// that starts open); `details`: the raw line under each step.
    public static func rows(_ steps: [JobStep], runner: String = "Claude", expanded: Set<String> = [], details: Bool = false,
                            calendar: Calendar = .current) -> [LogRow] {
        let children = Dictionary(grouping: steps.filter { $0.parent != nil }, by: { $0.parent! })
        let top = steps.filter { $0.parent == nil }
        var rows: [LogRow] = []
        var phase: String?
        var lastMinute: DateComponents?
        func time(_ d: Date) -> Date? {
            let m = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: d)
            if m == lastMinute { return nil }
            lastMinute = m
            return d
        }
        func head(_ s: JobStep) {
            guard s.phase != phase else { return }
            phase = s.phase
            lastMinute = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: s.at)
            rows.append(LogRow(id: "phase-\(s.id)", kind: .phase, text: phaseTitle(s.phase, runner: runner), time: s.at))
        }
        var i = 0
        while i < top.count {
            let s = top[i]
            head(s)
            // A step with children: the labels group.
            if let kids = children[s.id], !kids.isEmpty || s.verb == "labels" {
                let running = s.state == "running"
                // Open while running (the user may close it), closed when done (the user may open it).
                let open = running ? !expanded.contains(s.id) : expanded.contains(s.id)
                rows.append(LogRow(id: s.id, kind: .group, state: s.state, text: s.text, count: s.count, progress: running ? fraction(s.count) : nil,
                                   time: time(s.at), expanded: open))
                if open { rows += childRows(kids, running: running, details: details) }
                i += 1
                continue
            }
            // Fold a run of the same sort of step.
            var j = i + 1
            if foldable.contains(s.verb) && s.kind == "step" {
                while j < top.count && top[j].verb == s.verb && top[j].kind == "step" && top[j].phase == s.phase && children[top[j].id] == nil { j += 1 }
            }
            if j - i >= foldAt {
                let run = Array(top[i..<j])
                let gid = "g-\(s.id)"
                let open = expanded.contains(gid)
                let isRunning = run.contains { $0.state == "running" }
                rows.append(LogRow(id: gid, kind: .group, state: isRunning ? "running" : "done", text: groupText(run, running: isRunning),
                                   count: isRunning ? "\(run.count) so far" : nil, time: time(s.at), expanded: open))
                if open {
                    rows += run.map { LogRow(id: $0.id, kind: .step, state: $0.state, text: $0.text, count: $0.count,
                                             detail: details ? $0.detail : nil, level: 1) }
                }
                i = j
                continue
            }
            rows.append(LogRow(id: s.id, kind: s.kind == "note" ? .note : .step, state: s.state, text: s.kind == "note" ? "“\(s.text)”" : s.text,
                               count: s.count, detail: details ? s.detail : nil, time: time(s.at)))
            i += 1
        }
        return rows
    }

    static func childRows(_ kids: [JobStep], running: Bool, details: Bool) -> [LogRow] {
        // While running, older finished files fold into one line so the newest stay in view.
        let done = kids.filter { $0.state == "done" || $0.state == "failed" }
        let rest = kids.filter { $0.state != "done" && $0.state != "failed" }
        var out: [LogRow] = []
        var shownDone = done
        if running && done.count > 3 {
            let folded = done.prefix(done.count - 2)
            out.append(LogRow(id: "\(kids[0].parent ?? "")-done", kind: .step, state: "done", text: "\(folded.count) files done", level: 1))
            shownDone = Array(done.suffix(2))
        }
        out += (running ? shownDone + rest : kids).map {
            LogRow(id: $0.id, kind: .step, state: $0.state, text: $0.text, count: $0.count, detail: details ? $0.detail : nil, level: 1)
        }
        return out
    }

    static func fraction(_ count: String?) -> (done: Int, total: Int)? {
        guard let count else { return nil }
        let parts = count.components(separatedBy: " of ")
        guard parts.count == 2, let d = Int(parts[0]), let t = Int(parts[1]), t > 0 else { return nil }
        return (d, t)
    }

    static func groupText(_ run: [JobStep], running: Bool) -> String {
        let n = run.count
        let drafts = run.allSatisfy { $0.text.contains("draft") }
        switch run[0].verb {
        case "read": return "Read \(n) sources"
        case "readPage": return "Read \(n) of your pages"
        case "readRef": return "Read \(n) files"
        case "search": return "Searched \(n) times"
        case "command": return "Ran \(n) commands"
        case "write": return running ? (drafts ? "Writing drafts" : "Writing files") : (drafts ? "Wrote \(n) drafts" : "Wrote \(n) files")
        case "edit": return running ? (drafts ? "Editing drafts" : "Editing files") : (drafts ? "Edited drafts \(n) times" : "Made \(n) edits")
        default: return "\(n) steps"
        }
    }

    /// The batch card's "Now" line: the file being labeled, or the newest running step, else the newest step.
    public static func now(_ steps: [JobStep]) -> String? {
        if let label = steps.last(where: { $0.verb == "label" && $0.state == "running" }) { return "Labeling “\(label.text)”" }
        if let running = steps.last(where: { $0.state == "running" && $0.parent == nil && $0.verb != "labels" }) { return running.text }
        return steps.last(where: { $0.kind == "step" && $0.parent == nil })?.text
    }

    /// Copy: the whole log as plain text, every step (folded or not), with the raw line in brackets.
    public static func copyText(_ steps: [JobStep], title: String, calendar: Calendar = .current) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss"
        var lines = [title]
        for s in steps {
            var line = "\(f.string(from: s.at))  \(s.parent != nil ? "  " : "")\(s.kind == "note" ? "Note: “\(s.text)”" : s.text)"
            if let c = s.count { line += " (\(c))" }
            if s.state == "failed" { line += " [failed]" }
            if let d = s.detail { line += "   [\(d)]" }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: collector output

    /// Output chunks as lines: stream kept, stderr marked; the time shows when the second changes.
    /// A line starting with "$ " is the command (grey); "[…]" lines are Distill's own.
    public static func outputRows(_ chunks: [CollectorOutputChunk], calendar: Calendar = .current) -> [LogRow] {
        var rows: [LogRow] = []
        var lastSecond: DateComponents?
        var n = 0
        for chunk in chunks {
            var parts = chunk.text.components(separatedBy: "\n")
            if parts.last == "" { parts.removeLast() }
            for (k, line) in parts.enumerated() {
                let sec = calendar.dateComponents([.hour, .minute, .second], from: chunk.at)
                let showTime = k == 0 && sec != lastSecond
                if showTime { lastSecond = sec }
                let stream = chunk.stream == "stderr" ? "stderr" : line.hasPrefix("$ ") ? "cmd" : (line.hasPrefix("[") && line.hasSuffix("]")) ? "system" : "stdout"
                rows.append(LogRow(id: "o\(n)", kind: .output, text: line, time: showTime ? chunk.at : nil, stream: stream))
                n += 1
            }
        }
        return rows
    }

    /// Copy for output: as printed, stderr lines marked "err".
    public static func copyOutput(_ chunks: [CollectorOutputChunk], title: String) -> String {
        var lines = [title]
        for chunk in chunks {
            var parts = chunk.text.components(separatedBy: "\n")
            if parts.last == "" { parts.removeLast() }
            lines += parts.map { chunk.stream == "stderr" ? "err  \($0)" : $0 }
        }
        return lines.joined(separator: "\n")
    }

    /// Appends live output to a run's ordered chunks, keeping the last `limit` bytes.
    public static func append(_ chunks: [CollectorOutputChunk], stream: String, text: String, at: Date, limit: Int = 64 * 1024) -> [CollectorOutputChunk] {
        var out = chunks
        if let last = out.last, last.stream == stream, Int(at.timeIntervalSince1970) == Int(last.at.timeIntervalSince1970) {
            out[out.count - 1].text += text
        } else {
            out.append(CollectorOutputChunk(stream: stream, text: text, at: at))
        }
        var size = out.reduce(0) { $0 + $1.text.utf8.count }
        while size > limit, let first = out.first {
            let bytes = first.text.utf8.count
            if bytes <= size - limit {
                out.removeFirst(); size -= bytes
            } else {
                let drop = size - limit
                let kept = String(decoding: Array(first.text.utf8).dropFirst(drop), as: UTF8.self)
                size -= bytes - kept.utf8.count
                out[0].text = kept
                break
            }
        }
        return out
    }
}
