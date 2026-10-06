import Foundation

/// Where a Slack message goes (action-buttons.md, "Where to send"). A mirror of the core's
/// `resolveSlackTarget` (core/src/actions/slack-target.ts): both pass slack-target.cases.json.
/// The core decides at run time; the app uses this to draw the To row and turn Send off early.
public struct SlackTarget: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case channel, person, thread }
    public var kind: Kind
    /// The item's `to` field as written.
    public var written: String
    /// #channel, @handle or an ID; nil while a plain name is unknown.
    public var target: String?
    /// The written name, when a remembered name resolved it.
    public var name: String?
    /// Thread: the ts to reply under.
    public var threadTs: String?
    /// "Who is Aditya Pradhan in Slack?"
    public var ask: String?
    /// Why a button can't send it, in plain words.
    public var problem: String?

    public init(kind: Kind, written: String, target: String?, name: String? = nil, threadTs: String? = nil,
                ask: String? = nil, problem: String? = nil) {
        self.kind = kind; self.written = written; self.target = target; self.name = name
        self.threadTs = threadTs; self.ask = ask; self.problem = problem
    }

    /// "  Aditya   Pradhan " → "aditya pradhan". Only an exact match resolves.
    public static func normalName(_ name: String) -> String {
        name.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }

    /// A Slack message link or "channel ts" → the channel and the ts; a link's thread_ts wins.
    public static func parseThread(_ text: String) -> (channel: String?, ts: String)? {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if let m = match(#"^https?://[^\s/]*slack\.com/archives/([CGD][A-Z0-9]{2,})/p(\d{10})(\d{6})(?:[?#](\S*))?$"#, s) {
            if let q = m[4], let parent = match(#"(?:^|&)thread_ts=(\d{10}\.\d{6})(?:&|$)"#, q), let ts = parent[1] {
                return (m[1], ts)
            }
            return (m[1], "\(m[2]!).\(m[3]!)")
        }
        if match(#"^\d{10}\.\d{6}$"#, s) != nil { return (nil, s) }
        if let m = match(#"^(#\S+|[CGD][A-Z0-9]{2,})\s+(\d{10}\.\d{6})$"#, s) { return (m[1], m[2]!) }
        return nil
    }

    /// The To row of a Slack message, against the names remembered for its vault.
    public static func resolve(to: String?, thread: String?, lookup: (String) -> String?) -> SlackTarget {
        let written = (to ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let threadText = (thread ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed = threadText.isEmpty ? nil : parseThread(threadText)
        var base = toTarget(written, lookup: lookup)
        if !threadText.isEmpty && parsed == nil {
            base.kind = .thread; base.target = nil
            base.problem = "“\(threadText)” isn’t a Slack message link, so Distill can’t tell which thread to reply in."
            return base
        }
        guard let parsed else { return base }
        if let channel = parsed.channel {
            return SlackTarget(kind: .thread, written: written, target: channel, name: base.name, threadTs: parsed.ts)
        }
        base.kind = .thread; base.threadTs = parsed.ts
        return base
    }

    private static func toTarget(_ written: String, lookup: (String) -> String?) -> SlackTarget {
        if written.isEmpty { return SlackTarget(kind: .person, written: written, target: nil, problem: "Choose who gets it first.") }
        if written.contains(",") {
            return SlackTarget(kind: .person, written: written, target: nil, problem: "A button sends to one person or one channel. Pick one.")
        }
        if written.hasPrefix("#") || match(#"^[CG][A-Z0-9]{2,}$"#, written) != nil { return SlackTarget(kind: .channel, written: written, target: written) }
        if written.hasPrefix("@") || match(#"^[DUW][A-Z0-9]{2,}$"#, written) != nil { return SlackTarget(kind: .person, written: written, target: written) }
        if let found = lookup(normalName(written)) {
            return SlackTarget(kind: match(#"^(#|[CG][A-Z0-9])"#, found) != nil ? .channel : .person, written: written, target: found, name: written)
        }
        return SlackTarget(kind: .person, written: written, target: nil, ask: "Who is \(written) in Slack?",
                           problem: "Distill doesn’t know who \(written) is in Slack yet. Add their @handle or ID in the To row.")
    }

    /// What slack_cli.py accepts (its resolve_channel), used when the command declares no pattern.
    public static let rule = #"^(#\S+|@\S+|[CGDUW][A-Z0-9]{2,})$"#

    /// What the owner typed for a name: "aditya.p" → "@aditya.p"; nil when it is no handle, channel
    /// or ID. `pattern` is the button's declared target pattern, so the field says no to what the
    /// script would refuse.
    public static func typed(_ text: String, pattern: String? = nil) -> String? {
        var t = text.trimmingCharacters(in: .whitespaces)
        if match(#"^[a-z0-9][a-z0-9._-]*$"#, t) != nil { t = "@" + t }
        guard match(rule, t) != nil else { return nil }
        if let pattern, !pattern.isEmpty, let re = try? NSRegularExpression(pattern: pattern),
           re.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) == nil { return nil }
        return t
    }

    /// Why a button can't send this message: the core's refusal, before the click. Nil when it can
    /// (or when the button doesn't use the To field).
    public func blocks(_ button: AutomationButton) -> String? {
        let used = Set(button.bindings.values.flatMap(Self.placeholders))
        guard used.contains("fields.to") || used.contains("recipient") else { return nil }
        if let problem { return problem }
        if kind == .thread && !used.contains("fields.thread") {
            return "This message replies in a thread, but \(button.label) doesn’t fill in a thread. Edit the button and set thread to {fields.thread}."
        }
        return nil
    }

    /// `{a}{{b}}{ c }` → ["a", "c"].
    public static func placeholders(_ template: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: #"\{\{|\}\}|\{([^{}]*)\}"#) else { return [] }
        return re.matches(in: template, range: NSRange(template.startIndex..., in: template)).compactMap { m in
            guard let r = Range(m.range(at: 1), in: template) else { return nil }
            return template[r].trimmingCharacters(in: .whitespaces)
        }
    }

    private static func match(_ pattern: String, _ s: String) -> [String?]? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        return (0..<m.numberOfRanges).map { i in Range(m.range(at: i), in: s).map { String(s[$0]) } }
    }
}

/// A remembered name → Slack target, per vault (GET /v1/slack-people).
public struct SlackPerson: Codable, Hashable, Sendable, Identifiable {
    public var vaultPath: String
    public var name: String
    public var target: String
    public var savedAt: String
    public var id: String { vaultPath + "\n" + SlackTarget.normalName(name) }
    public init(vaultPath: String, name: String, target: String, savedAt: String = "") {
        self.vaultPath = vaultPath; self.name = name; self.target = target; self.savedAt = savedAt
    }
}

/// The To row's words.
public enum SlackToText {
    public static func kind(_ t: SlackTarget) -> String {
        switch t.kind {
        case .channel: return "Channel"
        case .person: return t.written.contains(",") ? "Group" : "Person"
        case .thread: return "Thread"
        }
    }

    /// "Aditya Pradhan (@aditya)", "#general", "@mei"; the written name while it is unknown.
    public static func main(_ t: SlackTarget) -> String {
        if t.written.isEmpty && t.kind != .thread { return "Choose who gets it" }
        if let name = t.name, let target = t.target, t.kind != .thread { return "\(name) (\(target))" }
        if t.kind == .thread {
            if t.written.hasPrefix("#") || t.target == nil { return t.written.isEmpty ? (t.target ?? "") : t.written }
            if let name = t.name, let target = t.target, !target.hasPrefix("C"), !target.hasPrefix("G") { return "\(name) (\(target))" }
            return t.target ?? t.written
        }
        return t.target ?? t.written
    }

    /// The grey words after it.
    public static func detail(_ t: SlackTarget) -> String {
        switch t.kind {
        case .channel: return "channel"
        case .person: return t.written.contains(",") ? "group message" : "direct message"
        case .thread: return "reply in its thread"
        }
    }

    /// Names remembered for a vault, as a lookup.
    public static func lookup(_ people: [SlackPerson], vault: String?) -> (String) -> String? {
        guard let vault else { return { _ in nil } }
        let mine = people.filter { $0.vaultPath == vault }
        return { key in mine.first { SlackTarget.normalName($0.name) == key }?.target }
    }
}

private struct SlackPersonBody: Encodable { let name: String; let target: String?; let vaultPath: String? }
public struct SlackForgotten: Decodable, Sendable { public var forgotten: Bool }

extension CoreClient {
    public func slackPeople(vault: String? = nil) async throws -> [SlackPerson] {
        try await getPlain("/v1/slack-people" + (vault.map { "?vault=\(Self.segment($0))" } ?? ""))
    }

    /// Remember who a name is in Slack (a bare handle gets its @; anything else is a 400 in plain words).
    public func rememberSlackPerson(name: String, target: String, vault: String?) async throws -> SlackPerson {
        try await sendPlain("PUT", "/v1/slack-people", body: SlackPersonBody(name: name, target: target, vaultPath: vault))
    }

    @discardableResult
    public func forgetSlackPerson(name: String, vault: String?) async throws -> Bool {
        let r: SlackForgotten = try await sendPlain("POST", "/v1/slack-people/forget", body: SlackPersonBody(name: name, target: nil, vaultPath: vault))
        return r.forgotten
    }
}
