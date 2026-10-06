import Foundation

// Automations (action-buttons.md): a script's commands, and buttons on action types that run them.
// Every type decodes leniently; unknown keys are ignored.

public struct ScriptCommandArg: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable { case word, flag, `switch`, positional }
    public var name: String
    public var kind: Kind
    public var flag: String?
    public var value: String?
    public var required: Bool?
    public var pattern: String?
    public var hint: String?
    public var id: String { name }

    public init(name: String, kind: Kind, flag: String? = nil, value: String? = nil, required: Bool? = nil,
                pattern: String? = nil, hint: String? = nil) {
        self.name = name; self.kind = kind; self.flag = flag; self.value = value; self.required = required
        self.pattern = pattern; self.hint = hint
    }

    enum Keys: String, CodingKey { case name, kind, flag, value, required, pattern, hint }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        name = c.lossy(String.self, .name) ?? ""
        kind = c.lossy(Kind.self, .kind) ?? .positional
        flag = c.lossy(String.self, .flag)
        value = c.lossy(String.self, .value)
        required = c.lossy(Bool.self, .required)
        pattern = c.lossy(String.self, .pattern)
        hint = c.lossy(String.self, .hint)
    }

    /// What the core assumes when `required` is absent.
    public var isRequired: Bool { required ?? (kind == .positional) }

    /// The grey words beside the name in the button editor ("--thread value · optional, left out
    /// when empty", "required").
    public var editorNote: String {
        switch kind {
        case .flag: return "\(flag ?? "") value" + (isRequired ? "" : " · optional, left out when empty")
        case .switch: return "\(flag ?? "") on or off"
        case .positional: return isRequired ? "required" : "optional"
        case .word: return ""
        }
    }

    /// The field's placeholder. A hint that only repeats the name ("text" for `text`, "<text>")
    /// says nothing new, so the generic one shows instead.
    public var editorPlaceholder: String {
        if kind == .switch { return "true / false, or {a field}" }
        guard let hint, !hint.trimmingCharacters(in: .whitespaces).isEmpty, !Self.sameWord(hint, name) else {
            return "{a field} or text"
        }
        return hint
    }

    /// "text", "<text>", "TEXT", "--text" and "text_" all come from the declared word `text`.
    static func sameWord(_ a: String, _ b: String) -> Bool {
        func bare(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
        return !bare(a).isEmpty && bare(a) == bare(b)
    }
}

public struct ScriptResultParse: Codable, Hashable, Sendable {
    public var json: Bool?
    public var keyPattern: String?
    public var urlPattern: String?
    public init(json: Bool? = nil, keyPattern: String? = nil, urlPattern: String? = nil) {
        self.json = json; self.keyPattern = keyPattern; self.urlPattern = urlPattern
    }
}

public struct ScriptCommand: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var label: String
    public var description: String?
    public var args: [ScriptCommandArg]
    public var endOptions: Bool?
    public var timeoutSeconds: Int?
    public var result: ScriptResultParse?

    public init(id: String, label: String, description: String? = nil, args: [ScriptCommandArg] = [],
                endOptions: Bool? = nil, timeoutSeconds: Int? = nil, result: ScriptResultParse? = nil) {
        self.id = id; self.label = label; self.description = description; self.args = args
        self.endOptions = endOptions; self.timeoutSeconds = timeoutSeconds; self.result = result
    }

    enum Keys: String, CodingKey { case id, label, description, args, endOptions, timeoutSeconds, result }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = c.lossy(String.self, .id) ?? ""
        label = c.lossy(String.self, .label) ?? id
        description = c.lossy(String.self, .description)
        args = c.lossyArray(ScriptCommandArg.self, .args)
        endOptions = c.lossy(Bool.self, .endOptions)
        timeoutSeconds = c.lossyInt(.timeoutSeconds)
        result = c.lossy(ScriptResultParse.self, .result)
    }

    /// The arguments a button binds (words are fixed).
    public var bindable: [ScriptCommandArg] { args.filter { $0.kind != .word } }
}

public struct AutomationButton: Codable, Hashable, Sendable, Identifiable {
    public enum OnSuccess: String, Codable, Sendable, CaseIterable { case none, markSent, complete }
    public enum Slot: String, Codable, Sendable, CaseIterable { case send, primary, more }
    public var id: String
    public var label: String
    public var icon: String?
    public var enabled: Bool
    public var scriptId: String
    public var commandId: String
    public var bindings: [String: String]
    public var confirm: Bool
    public var onSuccess: OnSuccess
    public var storeResult: Bool
    public var when: [String]?
    public var slot: Slot

    public init(id: String = "btn-\(UUID().uuidString.lowercased())", label: String = "", icon: String? = nil, enabled: Bool = true,
                scriptId: String = "", commandId: String = "", bindings: [String: String] = [:], confirm: Bool = true,
                onSuccess: OnSuccess = .none, storeResult: Bool = true, when: [String]? = nil, slot: Slot = .primary) {
        self.id = id; self.label = label; self.icon = icon; self.enabled = enabled; self.scriptId = scriptId
        self.commandId = commandId; self.bindings = bindings; self.confirm = confirm; self.onSuccess = onSuccess
        self.storeResult = storeResult; self.when = when; self.slot = slot
    }

    enum Keys: String, CodingKey { case id, label, icon, enabled, scriptId, commandId, bindings, confirm, onSuccess, storeResult, when, slot }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = c.lossy(String.self, .id) ?? ""
        label = c.lossy(String.self, .label) ?? "Run"
        icon = c.lossy(String.self, .icon)
        enabled = c.lossy(Bool.self, .enabled) ?? true
        scriptId = c.lossy(String.self, .scriptId) ?? ""
        commandId = c.lossy(String.self, .commandId) ?? ""
        bindings = c.lossy([String: String].self, .bindings) ?? [:]
        confirm = c.lossy(Bool.self, .confirm) ?? true
        onSuccess = c.lossy(OnSuccess.self, .onSuccess) ?? .none
        storeResult = c.lossy(Bool.self, .storeResult) ?? true
        when = c.lossy([String].self, .when)
        slot = c.lossy(Slot.self, .slot) ?? .primary
    }

    /// Shown for an item in this status (default: open and ready).
    public func shows(for status: ActionStatus) -> Bool {
        (when ?? ["open", "ready"]).contains(status.rawValue)
    }
}

/// A button as the core reports it: whether it can run now, and what it runs.
public struct ActionButtonInfo: Codable, Hashable, Sendable, Identifiable {
    public var button: AutomationButton
    public var available: Bool
    public var reason: String?
    public var scriptName: String?
    public var commandLabel: String?
    public var id: String { button.id }

    public init(button: AutomationButton, available: Bool = true, reason: String? = nil, scriptName: String? = nil, commandLabel: String? = nil) {
        self.button = button; self.available = available; self.reason = reason; self.scriptName = scriptName; self.commandLabel = commandLabel
    }

    enum Keys: String, CodingKey { case available, reason, scriptName, commandLabel }
    public init(from decoder: Decoder) throws {
        button = try AutomationButton(from: decoder)
        let c = try decoder.container(keyedBy: Keys.self)
        available = c.lossy(Bool.self, .available) ?? false
        reason = c.lossy(String.self, .reason)
        scriptName = c.lossy(String.self, .scriptName)
        commandLabel = c.lossy(String.self, .commandLabel)
    }
    public func encode(to encoder: Encoder) throws {
        try button.encode(to: encoder)
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(available, forKey: .available)
        try c.encodeIfPresent(reason, forKey: .reason)
        try c.encodeIfPresent(scriptName, forKey: .scriptName)
        try c.encodeIfPresent(commandLabel, forKey: .commandLabel)
    }
}

public struct ActionButtonPreview: Codable, Hashable, Sendable {
    public var argv: [String]
    public var display: String
    public var problems: [String]
    public var needsApproval: Bool
    public var needsConsent: Bool
    public var approvalHash: String

    public init(argv: [String] = [], display: String = "", problems: [String] = [], needsApproval: Bool = true,
                needsConsent: Bool = false, approvalHash: String = "") {
        self.argv = argv; self.display = display; self.problems = problems; self.needsApproval = needsApproval
        self.needsConsent = needsConsent; self.approvalHash = approvalHash
    }

    enum Keys: String, CodingKey { case argv, display, problems, needsApproval, needsConsent, approvalHash }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        argv = c.lossyArray(String.self, .argv)
        display = c.lossy(String.self, .display) ?? ""
        problems = c.lossyArray(String.self, .problems)
        needsApproval = c.lossy(Bool.self, .needsApproval) ?? true
        needsConsent = c.lossy(Bool.self, .needsConsent) ?? false
        approvalHash = c.lossy(String.self, .approvalHash) ?? ""
    }
}

public struct ActionButtonRun: Codable, Hashable, Sendable, Identifiable {
    public var runId: String
    public var buttonId: String
    public var label: String
    public var startedAt: Date
    public var endedAt: Date?
    public var durationMs: Int?
    /// running | success | failed | timedout | stopped | notTrusted
    public var result: String
    public var exitCode: Int?
    public var stdoutTail: String?
    public var stderrTail: String?
    public var externalKey: String?
    public var externalURL: String?
    public var message: String?
    public var id: String { runId }

    public init(runId: String, buttonId: String, label: String, startedAt: Date = Date(), endedAt: Date? = nil, durationMs: Int? = nil,
                result: String = "running", exitCode: Int? = nil, stdoutTail: String? = nil, stderrTail: String? = nil,
                externalKey: String? = nil, externalURL: String? = nil, message: String? = nil) {
        self.runId = runId; self.buttonId = buttonId; self.label = label; self.startedAt = startedAt; self.endedAt = endedAt
        self.durationMs = durationMs; self.result = result; self.exitCode = exitCode; self.stdoutTail = stdoutTail
        self.stderrTail = stderrTail; self.externalKey = externalKey; self.externalURL = externalURL; self.message = message
    }

    enum Keys: String, CodingKey { case runId, buttonId, label, startedAt, endedAt, durationMs, result, exitCode, stdoutTail, stderrTail, external, message }
    private enum ExternalKeys: String, CodingKey { case key, url }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        runId = c.lossy(String.self, .runId) ?? ""
        buttonId = c.lossy(String.self, .buttonId) ?? ""
        label = c.lossy(String.self, .label) ?? "Run"
        startedAt = c.lossyDate(.startedAt) ?? .distantPast
        endedAt = c.lossyDate(.endedAt)
        durationMs = c.lossyInt(.durationMs)
        result = c.lossy(String.self, .result) ?? "failed"
        exitCode = c.lossyInt(.exitCode)
        stdoutTail = c.lossy(String.self, .stdoutTail)
        stderrTail = c.lossy(String.self, .stderrTail)
        let e = try? c.nestedContainer(keyedBy: ExternalKeys.self, forKey: .external)
        externalKey = e?.lossy(String.self, .key)
        externalURL = e?.lossy(String.self, .url)
        message = c.lossy(String.self, .message)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(runId, forKey: .runId)
        try c.encode(buttonId, forKey: .buttonId)
        try c.encode(label, forKey: .label)
        try c.encode(CoreDate.format(startedAt), forKey: .startedAt)
        try c.encodeIfPresent(endedAt.map(CoreDate.format), forKey: .endedAt)
        try c.encodeIfPresent(durationMs, forKey: .durationMs)
        try c.encode(result, forKey: .result)
        try c.encodeIfPresent(exitCode, forKey: .exitCode)
        try c.encodeIfPresent(stdoutTail, forKey: .stdoutTail)
        try c.encodeIfPresent(stderrTail, forKey: .stderrTail)
        if externalKey != nil || externalURL != nil {
            var e = c.nestedContainer(keyedBy: ExternalKeys.self, forKey: .external)
            try e.encodeIfPresent(externalKey, forKey: .key)
            try e.encodeIfPresent(externalURL, forKey: .url)
        }
        try c.encodeIfPresent(message, forKey: .message)
    }

    public var isRunning: Bool { result == "running" }
    public var succeeded: Bool { result == "success" }
}

public struct ActiveButtonRun: Codable, Hashable, Sendable {
    public var runId: String
    public var buttonId: String
    public init(runId: String, buttonId: String) { self.runId = runId; self.buttonId = buttonId }
}

public struct ActionButtonStarted: Decodable, Sendable {
    public var item: ActionItem
}

/// A 409 from a run: the run sheet must show the command (needsApproval) or the script needs its OK.
public struct ActionButtonRefusal: Error, Sendable {
    public var needsApproval: Bool
    public var needsConsent: Bool
    public var preview: ActionButtonPreview?
    public var message: String
}

private struct ButtonRunBody: Encodable { let approve: Bool }
private struct ButtonDraftBody: Encodable { let typeId: String; let button: AutomationButton; let itemId: String? }
private struct CommandsPatch: Encodable {
    struct Script: Encodable { let collects: Bool?; let commands: [ScriptCommand]? }
    let script: Script
}

extension CoreClient {
    public func previewActionButton(_ id: String, button: String) async throws -> ActionButtonPreview {
        try await sendPlain("POST", "/v1/actions/\(Self.segment(id))/buttons/\(Self.segment(button))/preview", body: Optional<JSONValue>.none)
    }

    public func previewButtonDraft(typeId: String, button: AutomationButton, itemId: String? = nil) async throws -> ActionButtonPreview {
        try await sendPlain("POST", "/v1/action-buttons/preview", body: ButtonDraftBody(typeId: typeId, button: button, itemId: itemId))
    }

    /// Starts a run (202). A refusal that needs the run sheet or the script's OK comes back as ActionButtonRefusal.
    public func runActionButton(_ id: String, button: String, approve: Bool) async throws -> ActionItem {
        let (status, data) = try await sendRaw("POST", "/v1/actions/\(Self.segment(id))/buttons/\(Self.segment(button))/run",
                                               body: ButtonRunBody(approve: approve))
        if (200..<300).contains(status) {
            do { return try JSONDecoder.core.decode(ActionButtonStarted.self, from: data).item }
            catch { throw CoreClientError.badResponse("button run: \(error)") }
        }
        if status == 409, let r = Self.buttonRefusal(data) { throw r }
        throw Self.apiError(status: status, data: data)
    }

    static func buttonRefusal(_ data: Data) -> ActionButtonRefusal? {
        struct Body: Decodable {
            struct E: Decodable { let message: String?; let needsApproval: Bool?; let needsConsent: Bool?; let preview: ActionButtonPreview? }
            let error: E?
        }
        guard let e = (try? JSONDecoder.core.decode(Body.self, from: data))?.error,
              e.needsApproval == true || e.needsConsent == true else { return nil }
        return ActionButtonRefusal(needsApproval: e.needsApproval ?? false, needsConsent: e.needsConsent ?? false,
                                   preview: e.preview, message: e.message ?? "")
    }

    public func stopActionButtonRun(_ id: String) async throws {
        let _: JSONValue = try await sendPlain("POST", "/v1/actions/\(Self.segment(id))/buttons/stop", body: Optional<JSONValue>.none)
    }

    /// Automations: whether a script collects, and its commands (consent is unchanged).
    public func updateScriptCommands(_ collectorID: String, collects: Bool? = nil, commands: [ScriptCommand]? = nil) async throws -> Collector {
        try await sendPlain("PATCH", "/v1/collectors/\(Self.segment(collectorID))",
                            body: CommandsPatch(script: .init(collects: collects, commands: commands)))
    }
}

// MARK: - Logic the app shows (tested in AutomationsTests)

public enum AutomationText {
    /// The buttons an item shows, split by slot. Disabled buttons and statuses outside `when` are left out.
    public static func slots(_ buttons: [ActionButtonInfo], for item: ActionItem) -> (send: ActionButtonInfo?, primary: [ActionButtonInfo], more: [ActionButtonInfo]) {
        let shown = buttons.filter { $0.button.enabled && $0.button.shows(for: item.status) }
        let send = shown.first { $0.button.slot == .send }
        return (send, shown.filter { $0.button.slot == .primary }, shown.filter { $0.button.slot == .more || ($0.button.slot == .send && $0.id != send?.id) })
    }

    /// What `{placeholders}` a button binding can use, in Insert field ▾ order (core: actions/buttons.ts templateValues).
    public static func templateKeys(fieldKeys: [String]) -> [String] {
        ["title", "body", "summary", "why", "labels", "quote", "excerpt", "note_title", "note_path", "source.raw", "source.wiki"]
            + fieldKeys.map { "fields.\($0)" }
            + ["external.key", "external.url", "item.id", "type", "today", "now", "vault"]
    }

    /// "✓ Send in Slack · exit 0 · 1.2 s · 10:42 AM" for the Last run block.
    public static func runLine(_ run: ActionButtonRun, time: String) -> String {
        var parts = [run.label]
        switch run.result {
        case "running": parts.append("running")
        case "success": break
        case "timedout": parts.append("timed out")
        case "stopped": parts.append("stopped")
        case "notTrusted": parts.append("needs your OK")
        default: if let code = run.exitCode { parts.append("exit \(code)") } else { parts.append("failed") }
        }
        if let ms = run.durationMs { parts.append(ms < 1000 ? "\(ms) ms" : String(format: "%.1f s", Double(ms) / 1000)) }
        parts.append(time)
        return parts.joined(separator: " · ")
    }

    /// The last `n` non-empty lines of a stream tail.
    public static func lastLines(_ text: String?, _ n: Int = 3) -> [String] {
        Array((text ?? "").split(separator: "\n", omittingEmptySubsequences: true).map(String.init).suffix(n))
    }

    /// A new command's id from its label ("Send a message" → "send-a-message"), unique in `taken`.
    public static func slug(_ label: String, taken: Set<String>) -> String {
        let base = label.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
            .split(separator: "-").joined(separator: "-").prefix(32)
        var id = base.isEmpty ? "command" : String(base)
        if !(id.first?.isLetter ?? false) && !(id.first?.isNumber ?? false) { id = "c" + id }
        var n = 2, out = id
        while taken.contains(out) { out = "\(id)-\(n)"; n += 1 }
        return out
    }
}

/// Add automation, step 1 "What it does" (action-buttons.md, board ScriptActions frame sa-card-add). Collect keeps
/// today's steps; Commands and Both are scripts. Commands never collects (`script.collects: false`).
public enum AutomationRole: String, CaseIterable, Sendable {
    case collect, commands, both

    public var title: String {
        switch self { case .collect: "Collect on a schedule"; case .commands: "Commands for buttons"; case .both: "Both" }
    }

    public var detail: String {
        switch self {
        case .collect: "Folder or script. Fills the queue, like a collector today."
        case .commands: "A script you call with arguments from action buttons. Never runs on its own."
        case .both: "A script that collects and also offers commands."
        }
    }

    /// What the new script sends as `collects` (nil = absent, which collects).
    public var collects: Bool? { self == .commands ? false : nil }

    /// The Add sheet's steps for this role, in order.
    public var steps: [String] {
        switch self {
        case .collect: ["What it does", "Kind", "Source", "Schedule"]
        case .commands: ["What it does", "Source", "Commands"]
        case .both: ["What it does", "Source", "Schedule", "Commands"]
        }
    }
}
