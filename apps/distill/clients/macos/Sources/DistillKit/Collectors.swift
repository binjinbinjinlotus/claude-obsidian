import Foundation

// Collectors (contracts.ts → "Collectors (collectors.json)"; spec collectors.md).
// Collectors fill a vault's queue folder on a schedule. The core owns them, runs
// them and keeps their history; this file only mirrors the contract. Kinds,
// results, error codes, outcomes, interpreters and presets are raw strings, so a
// newer core's values decode and render generically instead of failing.

/// A raw string value that keeps unknown values (decodes anything; encodes as is).
public protocol RawStringValue: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible where RawValue == String {
    init(rawValue: String)
    static var fallback: String { get }
}

public extension RawStringValue {
    init(_ raw: String) { self.init(rawValue: raw) }
    var description: String { rawValue }
    init(from decoder: Decoder) throws {
        self.init(rawValue: (try? decoder.singleValueContainer().decode(String.self)) ?? Self.fallback)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

public struct CollectorKind: RawStringValue {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let fallback = "folder"
    public static let folder = CollectorKind("folder")
    public static let script = CollectorKind("script")
}

public struct CollectorInterpreter: RawStringValue {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let fallback = "zsh"
    public static let zsh = CollectorInterpreter("zsh")
    public static let python3 = CollectorInterpreter("python3")
    public static let node = CollectorInterpreter("node")
    /// v6: runs on the login shell's node with its built-in type stripping.
    public static let typescript = CollectorInterpreter("typescript")
    public static let all: [CollectorInterpreter] = [.zsh, .python3, .node, .typescript]

    /// The language picker's name: zsh, Python, JavaScript, TypeScript (unknown values as they are).
    public var language: String {
        switch rawValue {
        case "zsh": return "zsh"
        case "python3": return "Python"
        case "node": return "JavaScript"
        case "typescript": return "TypeScript"
        default: return rawValue
        }
    }
    /// The managed file's extension (a migrated node script may keep `.mjs`; the core's path is the truth).
    public var fileExtension: String {
        switch rawValue {
        case "python3": return "py"
        case "node": return "js"
        case "typescript": return "ts"
        default: return "zsh"
        }
    }
    /// The package manifest this language uses in a managed folder; nil for zsh.
    public var manifestName: String? {
        switch rawValue {
        case "python3": return "requirements.txt"
        case "node", "typescript": return "package.json"
        default: return nil
        }
    }
    /// What actually runs the file (TypeScript runs on node).
    public var command: String { rawValue == "typescript" ? "node" : rawValue }
}

/// `SchedulePreset`: every15 / hourly / daily / weekdays / custom.
public struct SchedulePreset: RawStringValue {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let fallback = "custom"
    public static let every15 = SchedulePreset("every15")
    public static let hourly = SchedulePreset("hourly")
    public static let daily = SchedulePreset("daily")
    public static let weekdays = SchedulePreset("weekdays")
    public static let custom = SchedulePreset("custom")
    public static let all: [SchedulePreset] = [.every15, .hourly, .daily, .weekdays, .custom]
}

public struct CollectorRunResult: RawStringValue {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let fallback = "failed"
    public static let queued = CollectorRunResult("queued")
    public static let running = CollectorRunResult("running")
    public static let success = CollectorRunResult("success")
    public static let nothing = CollectorRunResult("nothing")
    public static let failed = CollectorRunResult("failed")
    public static let timedout = CollectorRunResult("timedout")
    public static let skipped = CollectorRunResult("skipped")
    public static let notTrusted = CollectorRunResult("notTrusted")
    public static let stopped = CollectorRunResult("stopped")

    /// Queued or running.
    public var isActive: Bool { self == .queued || self == .running }
}

public struct CollectorErrorCode: RawStringValue {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let fallback = "other"
    public static let sourceMissing = CollectorErrorCode("sourceMissing")
    public static let noPermission = CollectorErrorCode("noPermission")
    public static let queueMissing = CollectorErrorCode("queueMissing")
    public static let vaultMissing = CollectorErrorCode("vaultMissing")
    public static let scriptMissing = CollectorErrorCode("scriptMissing")
    public static let interpreterMissing = CollectorErrorCode("interpreterMissing")
    public static let scriptFailed = CollectorErrorCode("scriptFailed")
    public static let notAllowed = CollectorErrorCode("notAllowed")
    public static let scriptChanged = CollectorErrorCode("scriptChanged")
    public static let interrupted = CollectorErrorCode("interrupted")
    /// v6: the install before the run failed.
    public static let installFailed = CollectorErrorCode("installFailed")
    public static let other = CollectorErrorCode("other")
}

public struct CollectorFileOutcome: RawStringValue {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let fallback = "error"
    public static let copied = CollectorFileOutcome("copied")
    public static let moved = CollectorFileOutcome("moved")
    public static let skipped = CollectorFileOutcome("skipped")
    public static let waiting = CollectorFileOutcome("waiting")
    public static let error = CollectorFileOutcome("error")
}

public struct CollectorSchedule: Codable, Hashable, Sendable {
    public var cron: String
    public var preset: SchedulePreset?

    public init(cron: String, preset: SchedulePreset? = nil) { self.cron = cron; self.preset = preset }

    public static let hourly = CollectorSchedule(cron: "0 * * * *", preset: .hourly)

    enum Keys: String, CodingKey { case cron, preset }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        cron = c.lossy(String.self, .cron) ?? "0 * * * *"
        preset = c.lossy(SchedulePreset.self, .preset)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(cron, forKey: .cron)
        try c.encodeIfPresent(preset, forKey: .preset)
    }
}

public struct FolderCollectorSettings: Codable, Hashable, Sendable {
    public var source: String
    /// "copy" (default) or "move" (raw, unknown kept).
    public var afterCollect: String
    /// v5: each top-level subfolder is collected as one folder item. Absent (a collector saved before v5) = off.
    public var includeSubfolders: Bool?

    public init(source: String, afterCollect: String = "copy", includeSubfolders: Bool? = nil) {
        self.source = source; self.afterCollect = afterCollect; self.includeSubfolders = includeSubfolders
    }
    public var moves: Bool { afterCollect == "move" }
    /// Off when absent, so an older collector keeps doing what the user set up.
    public var subfolders: Bool { includeSubfolders ?? false }

    enum Keys: String, CodingKey { case source, afterCollect, includeSubfolders }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        source = c.lossy(String.self, .source) ?? ""
        afterCollect = c.lossy(String.self, .afterCollect) ?? "copy"
        includeSubfolders = c.lossy(Bool.self, .includeSubfolders)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(source, forKey: .source)
        try c.encode(afterCollect, forKey: .afterCollect)
        try c.encodeIfPresent(includeSubfolders, forKey: .includeSubfolders)
    }
}

/// `{file: path}` or `{inline: code}`.
public enum ScriptSource: Codable, Hashable, Sendable {
    case file(String)
    case inline(String)

    enum Keys: String, CodingKey { case file, inline }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        if let code = c.lossy(String.self, .inline) { self = .inline(code) } else { self = .file(c.lossy(String.self, .file) ?? "") }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .file(let p): try c.encode(p, forKey: .file)
        case .inline(let code): try c.encode(code, forKey: .inline)
        }
    }

    public var filePath: String? { if case .file(let p) = self { return p }; return nil }
    public var inlineCode: String? { if case .inline(let c) = self { return c }; return nil }
}

public struct ScriptCollectorSettings: Codable, Hashable, Sendable {
    public var source: ScriptSource
    /// v6: `source.managed`: a script Distill keeps in its own folder (`{file, managed: true}`).
    public var managed: Bool
    public var interpreter: CollectorInterpreter
    public var timeoutSeconds: Int
    public var allowedSha256: String?
    public var allowedAt: Date?
    /// v6: the hash of each file the consent covered.
    public var allowedFiles: AllowedFiles?
    /// Automations: false for a commands-only script that never collects on a schedule.
    public var collects: Bool
    /// Automations: commands action buttons can run (action-buttons.md).
    public var commands: [ScriptCommand]

    public init(source: ScriptSource, managed: Bool = false, interpreter: CollectorInterpreter, timeoutSeconds: Int = 300,
                allowedSha256: String? = nil, allowedAt: Date? = nil, allowedFiles: AllowedFiles? = nil,
                collects: Bool = true, commands: [ScriptCommand] = []) {
        self.source = source; self.managed = managed; self.interpreter = interpreter; self.timeoutSeconds = timeoutSeconds
        self.allowedSha256 = allowedSha256; self.allowedAt = allowedAt; self.allowedFiles = allowedFiles
        self.collects = collects; self.commands = commands
    }

    enum Keys: String, CodingKey { case source, interpreter, timeoutSeconds, allowedSha256, allowedAt, allowedFiles, collects, commands }
    private enum SourceKeys: String, CodingKey { case managed }
    private struct ManagedSource: Encodable { let file: String; let managed: Bool }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        source = c.lossy(ScriptSource.self, .source) ?? .inline("")
        managed = (try? c.nestedContainer(keyedBy: SourceKeys.self, forKey: .source))?.lossy(Bool.self, .managed) ?? false
        interpreter = c.lossy(CollectorInterpreter.self, .interpreter) ?? .zsh
        timeoutSeconds = c.lossyInt(.timeoutSeconds) ?? 300
        allowedSha256 = c.lossy(String.self, .allowedSha256)
        allowedAt = c.lossyDate(.allowedAt)
        allowedFiles = c.lossy(AllowedFiles.self, .allowedFiles)
        collects = c.lossy(Bool.self, .collects) ?? true
        commands = c.lossyArray(ScriptCommand.self, .commands)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        if managed, let path = source.filePath {
            try c.encode(ManagedSource(file: path, managed: true), forKey: .source)
        } else {
            try c.encode(source, forKey: .source)
        }
        try c.encode(interpreter, forKey: .interpreter)
        try c.encode(timeoutSeconds, forKey: .timeoutSeconds)
        try c.encodeIfPresent(allowedSha256, forKey: .allowedSha256)
        try c.encodeIfPresent(allowedAt.map(CoreDate.format), forKey: .allowedAt)
        try c.encodeIfPresent(allowedFiles, forKey: .allowedFiles)
        if !collects { try c.encode(collects, forKey: .collects) }
        if !commands.isEmpty { try c.encode(commands, forKey: .commands) }
    }
}

/// Computed by the core on every read.
public struct CollectorStatus: Codable, Hashable, Sendable {
    public var running: Bool
    public var nextRunAt: Date?
    public var lastRun: CollectorRun?
    public var currentSha256: String?
    public var scriptProblem: String?
    public var needsConsent: Bool
    public var collectedCount: Int?
    /// v6, scripts: where the script lives and its packages (absent from an older core).
    public var script: CollectorScriptStatus?
    public var needsAttention: Bool

    public init(running: Bool = false, nextRunAt: Date? = nil, lastRun: CollectorRun? = nil, currentSha256: String? = nil,
                scriptProblem: String? = nil, needsConsent: Bool = false, collectedCount: Int? = nil, script: CollectorScriptStatus? = nil,
                needsAttention: Bool = false) {
        self.running = running; self.nextRunAt = nextRunAt; self.lastRun = lastRun; self.currentSha256 = currentSha256
        self.scriptProblem = scriptProblem; self.needsConsent = needsConsent; self.collectedCount = collectedCount
        self.script = script; self.needsAttention = needsAttention
    }

    enum Keys: String, CodingKey { case running, nextRunAt, lastRun, currentSha256, scriptProblem, needsConsent, collectedCount, script, needsAttention }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        running = c.lossy(Bool.self, .running) ?? false
        nextRunAt = c.lossyDate(.nextRunAt)
        lastRun = c.lossy(CollectorRun.self, .lastRun)
        currentSha256 = c.lossy(String.self, .currentSha256)
        scriptProblem = c.lossy(String.self, .scriptProblem)
        needsConsent = c.lossy(Bool.self, .needsConsent) ?? false
        collectedCount = c.lossyInt(.collectedCount)
        script = c.lossy(CollectorScriptStatus.self, .script)
        needsAttention = c.lossy(Bool.self, .needsAttention) ?? false
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(running, forKey: .running)
        try c.encodeIfPresent(nextRunAt.map(CoreDate.format), forKey: .nextRunAt)
        try c.encodeIfPresent(lastRun, forKey: .lastRun)
        try c.encodeIfPresent(currentSha256, forKey: .currentSha256)
        try c.encodeIfPresent(scriptProblem, forKey: .scriptProblem)
        try c.encode(needsConsent, forKey: .needsConsent)
        try c.encodeIfPresent(collectedCount, forKey: .collectedCount)
        try c.encodeIfPresent(script, forKey: .script)
        try c.encode(needsAttention, forKey: .needsAttention)
    }
}

public struct Collector: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var kind: CollectorKind
    public var name: String
    public var vaultPath: String
    public var enabled: Bool
    public var schedule: CollectorSchedule
    public var folder: FolderCollectorSettings?
    public var script: ScriptCollectorSettings?
    public var createdAt: Date
    public var updatedAt: Date
    public var status: CollectorStatus?

    public init(id: String, kind: CollectorKind, name: String, vaultPath: String, enabled: Bool = true,
                schedule: CollectorSchedule = .hourly, folder: FolderCollectorSettings? = nil, script: ScriptCollectorSettings? = nil,
                createdAt: Date = Date(), updatedAt: Date = Date(), status: CollectorStatus? = nil) {
        self.id = id; self.kind = kind; self.name = name; self.vaultPath = vaultPath; self.enabled = enabled
        self.schedule = schedule; self.folder = folder; self.script = script
        self.createdAt = createdAt; self.updatedAt = updatedAt; self.status = status
    }

    enum Keys: String, CodingKey { case id, kind, name, vaultPath, enabled, schedule, folder, script, createdAt, updatedAt, status }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        guard let id = c.lossy(String.self, .id), !id.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "a collector needs an id")
        }
        self.id = id
        kind = c.lossy(CollectorKind.self, .kind) ?? .folder
        name = c.lossy(String.self, .name) ?? "Collector"
        vaultPath = c.lossy(String.self, .vaultPath) ?? ""
        enabled = c.lossy(Bool.self, .enabled) ?? false
        schedule = c.lossy(CollectorSchedule.self, .schedule) ?? .hourly
        folder = c.lossy(FolderCollectorSettings.self, .folder)
        script = c.lossy(ScriptCollectorSettings.self, .script)
        createdAt = c.lossyDate(.createdAt) ?? Date(timeIntervalSince1970: 0)
        updatedAt = c.lossyDate(.updatedAt) ?? createdAt
        status = c.lossy(CollectorStatus.self, .status)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind, forKey: .kind)
        try c.encode(name, forKey: .name)
        try c.encode(vaultPath, forKey: .vaultPath)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(schedule, forKey: .schedule)
        try c.encodeIfPresent(folder, forKey: .folder)
        try c.encodeIfPresent(script, forKey: .script)
        try c.encode(CoreDate.format(createdAt), forKey: .createdAt)
        try c.encode(CoreDate.format(updatedAt), forKey: .updatedAt)
        try c.encodeIfPresent(status, forKey: .status)
    }

    public var isScript: Bool { kind == .script }
    public var isFolder: Bool { kind == .folder }
    public var isRunning: Bool { status?.running ?? false }
    public var needsConsent: Bool { status?.needsConsent ?? false }
    public var needsAttention: Bool { status?.needsAttention ?? false }
    public var lastRun: CollectorRun? { status?.lastRun }
    /// v6: a script Distill keeps in its own folder (the record's `managed`, or the status's).
    public var isManaged: Bool { script?.managed == true || status?.script?.managed == true }
    public var manifest: CollectorManifestStatus? { status?.script?.manifest }
    /// v6: packages are being installed (not counted in `status.running`).
    public var isInstalling: Bool { manifest?.installing == true || manifest?.state == "installing" }
    /// The script file that runs: the status's path, else the record's file.
    public var scriptPath: String? {
        if let p = status?.script?.path, !p.isEmpty { return p }
        return script?.source.filePath
    }
}

public struct CollectorRunError: Codable, Hashable, Sendable {
    public var code: CollectorErrorCode
    public var message: String
    public init(code: CollectorErrorCode, message: String) { self.code = code; self.message = message }
    enum Keys: String, CodingKey { case code, message }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        code = c.lossy(CollectorErrorCode.self, .code) ?? .other
        message = c.lossy(String.self, .message) ?? ""
    }
}

public struct CollectorRunFile: Codable, Hashable, Sendable {
    public var name: String
    public var outcome: CollectorFileOutcome
    public var reason: String?
    public var queueName: String?
    public var size: Int?
    /// v5: "folder" for a subfolder collected as one item (raw; absent = a file).
    public var kind: String?
    /// v5, folder lines: files inside, and how many were new or changed.
    public var fileCount: Int?
    public var newCount: Int?

    public var isFolder: Bool { kind == "folder" }

    public init(name: String, outcome: CollectorFileOutcome, reason: String? = nil, queueName: String? = nil, size: Int? = nil,
                kind: String? = nil, fileCount: Int? = nil, newCount: Int? = nil) {
        self.name = name; self.outcome = outcome; self.reason = reason; self.queueName = queueName; self.size = size
        self.kind = kind; self.fileCount = fileCount; self.newCount = newCount
    }
    enum Keys: String, CodingKey { case name, outcome, reason, queueName, size, kind, fileCount, newCount }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        name = c.lossy(String.self, .name) ?? ""
        outcome = c.lossy(CollectorFileOutcome.self, .outcome) ?? .error
        reason = c.lossy(String.self, .reason)
        queueName = c.lossy(String.self, .queueName)
        size = c.lossyInt(.size)
        kind = c.lossy(String.self, .kind)
        fileCount = c.lossyInt(.fileCount)
        newCount = c.lossyInt(.newCount)
    }
}

public struct CollectorRunCounts: Codable, Hashable, Sendable {
    public var copied = 0, moved = 0, skipped = 0, waiting = 0, errors = 0, added = 0
    public init(copied: Int = 0, moved: Int = 0, skipped: Int = 0, waiting: Int = 0, errors: Int = 0, added: Int = 0) {
        self.copied = copied; self.moved = moved; self.skipped = skipped; self.waiting = waiting; self.errors = errors; self.added = added
    }
    enum Keys: String, CodingKey { case copied, moved, skipped, waiting, errors, added }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        copied = c.lossyInt(.copied) ?? 0; moved = c.lossyInt(.moved) ?? 0; skipped = c.lossyInt(.skipped) ?? 0
        waiting = c.lossyInt(.waiting) ?? 0; errors = c.lossyInt(.errors) ?? 0; added = c.lossyInt(.added) ?? 0
    }
}

public struct CollectorRun: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var collectorId: String
    public var kind: CollectorKind
    public var vaultPath: String
    /// schedule / now / catchup (raw).
    public var trigger: String
    public var startedAt: Date
    public var endedAt: Date?
    public var durationMs: Double?
    public var result: CollectorRunResult
    /// While queued: "slot" or "batch".
    public var waiting: String?
    public var skipReason: String?
    public var error: CollectorRunError?
    public var files: [CollectorRunFile]?
    public var counts: CollectorRunCounts
    public var filesAdded: [String]
    public var exitCode: Int?
    public var signal: String?
    public var sha256: String?
    public var stdoutTail: String?
    public var stderrTail: String?
    /// v6: the install this run did first.
    public var installId: String?
    /// v6, test runs: the scratch folder that stood in for the queue (`filesAdded` are its names).
    public var outputDir: String?
    /// v7: both streams in the order they were printed (the last 64 KB). Empty for runs saved before.
    public var outputLog: [CollectorOutputChunk] = []
    /// v6: what ran the script ("python3 (.venv)" and its path).
    public var runtime: CollectorRuntime?

    /// v6: a Test run (into a scratch folder, never the queue).
    public var isTest: Bool { trigger == "test" }

    public init(id: String, collectorId: String, kind: CollectorKind = .folder, vaultPath: String = "", trigger: String = "schedule",
                startedAt: Date, endedAt: Date? = nil, durationMs: Double? = nil, result: CollectorRunResult,
                waiting: String? = nil, skipReason: String? = nil, error: CollectorRunError? = nil, files: [CollectorRunFile]? = nil,
                counts: CollectorRunCounts = CollectorRunCounts(), filesAdded: [String] = [], exitCode: Int? = nil, signal: String? = nil,
                sha256: String? = nil, stdoutTail: String? = nil, stderrTail: String? = nil, installId: String? = nil, outputDir: String? = nil) {
        self.id = id; self.collectorId = collectorId; self.kind = kind; self.vaultPath = vaultPath; self.trigger = trigger
        self.startedAt = startedAt; self.endedAt = endedAt; self.durationMs = durationMs; self.result = result
        self.waiting = waiting; self.skipReason = skipReason; self.error = error; self.files = files; self.counts = counts
        self.filesAdded = filesAdded; self.exitCode = exitCode; self.signal = signal; self.sha256 = sha256
        self.stdoutTail = stdoutTail; self.stderrTail = stderrTail; self.installId = installId; self.outputDir = outputDir
    }

    enum Keys: String, CodingKey {
        case id, collectorId, kind, vaultPath, trigger, startedAt, endedAt, durationMs, result, waiting, skipReason, error, files, counts,
             filesAdded, exitCode, signal, sha256, stdoutTail, stderrTail, installId, outputDir, outputLog, runtime
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        guard let id = c.lossy(String.self, .id), !id.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "a run needs an id")
        }
        self.id = id
        collectorId = c.lossy(String.self, .collectorId) ?? ""
        kind = c.lossy(CollectorKind.self, .kind) ?? .folder
        vaultPath = c.lossy(String.self, .vaultPath) ?? ""
        trigger = c.lossy(String.self, .trigger) ?? "schedule"
        startedAt = c.lossyDate(.startedAt) ?? Date(timeIntervalSince1970: 0)
        endedAt = c.lossyDate(.endedAt)
        durationMs = c.lossyDouble(.durationMs)
        result = c.lossy(CollectorRunResult.self, .result) ?? .failed
        waiting = c.lossy(String.self, .waiting)
        skipReason = c.lossy(String.self, .skipReason)
        error = c.lossy(CollectorRunError.self, .error)
        files = (try? c.decodeIfPresent([Lossy<CollectorRunFile>].self, forKey: .files))??.compactMap(\.value)
        counts = c.lossy(CollectorRunCounts.self, .counts) ?? CollectorRunCounts()
        filesAdded = c.lossyArray(String.self, .filesAdded)
        exitCode = c.lossyInt(.exitCode)
        signal = c.lossy(String.self, .signal)
        sha256 = c.lossy(String.self, .sha256)
        stdoutTail = c.lossy(String.self, .stdoutTail)
        stderrTail = c.lossy(String.self, .stderrTail)
        installId = c.lossy(String.self, .installId)
        outputDir = c.lossy(String.self, .outputDir)
        outputLog = c.lossyArray(CollectorOutputChunk.self, .outputLog)
        runtime = c.lossy(CollectorRuntime.self, .runtime)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(id, forKey: .id)
        try c.encode(collectorId, forKey: .collectorId)
        try c.encode(kind, forKey: .kind)
        try c.encode(vaultPath, forKey: .vaultPath)
        try c.encode(trigger, forKey: .trigger)
        try c.encode(CoreDate.format(startedAt), forKey: .startedAt)
        try c.encodeIfPresent(endedAt.map(CoreDate.format), forKey: .endedAt)
        try c.encodeIfPresent(durationMs, forKey: .durationMs)
        try c.encode(result, forKey: .result)
        try c.encodeIfPresent(waiting, forKey: .waiting)
        try c.encodeIfPresent(skipReason, forKey: .skipReason)
        try c.encodeIfPresent(error, forKey: .error)
        try c.encodeIfPresent(files, forKey: .files)
        try c.encode(counts, forKey: .counts)
        try c.encode(filesAdded, forKey: .filesAdded)
        try c.encodeIfPresent(exitCode, forKey: .exitCode)
        try c.encodeIfPresent(signal, forKey: .signal)
        try c.encodeIfPresent(sha256, forKey: .sha256)
        try c.encodeIfPresent(stdoutTail, forKey: .stdoutTail)
        try c.encodeIfPresent(stderrTail, forKey: .stderrTail)
        try c.encodeIfPresent(installId, forKey: .installId)
        try c.encodeIfPresent(outputDir, forKey: .outputDir)
        if !outputLog.isEmpty { try c.encode(outputLog, forKey: .outputLog) }
        try c.encodeIfPresent(runtime, forKey: .runtime)
    }
}

/// v7: a piece of script output, its stream and when it came.
public struct CollectorOutputChunk: Codable, Hashable, Sendable {
    public var stream: String
    public var text: String
    public var at: Date

    public init(stream: String, text: String, at: Date) {
        self.stream = stream; self.text = text; self.at = at
    }

    enum Keys: String, CodingKey { case stream, text, at }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        stream = c.lossy(String.self, .stream) == "stderr" ? "stderr" : "stdout"
        text = c.lossy(String.self, .text) ?? ""
        at = c.lossyDate(.at) ?? Date(timeIntervalSince1970: 0)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(stream, forKey: .stream)
        try c.encode(text, forKey: .text)
        try c.encode(CoreDate.format(at), forKey: .at)
    }
}

/// One ledger entry (Already collected). Round-trips exactly for Undo (`collected/restore`).
public struct CollectedFile: Codable, Hashable, Sendable, Identifiable {
    public var sha256: String
    public var name: String
    public var sourcePath: String
    public var size: Int
    public var mtime: String
    public var collectedAt: String
    public var collectorId: String
    public var queueName: String
    public var outcome: String

    public var id: String { sha256 + "|" + sourcePath + "|" + collectedAt }
    public var collectedDate: Date? { CoreDate.parse(collectedAt) }

    public init(sha256: String, name: String, sourcePath: String, size: Int, mtime: String, collectedAt: String,
                collectorId: String, queueName: String, outcome: String = "copied") {
        self.sha256 = sha256; self.name = name; self.sourcePath = sourcePath; self.size = size; self.mtime = mtime
        self.collectedAt = collectedAt; self.collectorId = collectorId; self.queueName = queueName; self.outcome = outcome
    }

    enum Keys: String, CodingKey { case sha256, name, sourcePath, size, mtime, collectedAt, collectorId, queueName, outcome }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        guard let sha = c.lossy(String.self, .sha256), !sha.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .sha256, in: c, debugDescription: "a collected file needs a sha256")
        }
        sha256 = sha
        name = c.lossy(String.self, .name) ?? ""
        sourcePath = c.lossy(String.self, .sourcePath) ?? ""
        size = c.lossyInt(.size) ?? 0
        mtime = c.lossy(String.self, .mtime) ?? ""
        collectedAt = c.lossy(String.self, .collectedAt) ?? ""
        collectorId = c.lossy(String.self, .collectorId) ?? ""
        queueName = c.lossy(String.self, .queueName) ?? ""
        outcome = c.lossy(String.self, .outcome) ?? "copied"
    }
}

public struct ScheduleCheck: Codable, Hashable, Sendable {
    public var cron: String
    public var valid: Bool
    public var error: String?
    public var preset: SchedulePreset?
    public var nextRuns: [Date]

    public init(cron: String, valid: Bool, error: String? = nil, preset: SchedulePreset? = nil, nextRuns: [Date] = []) {
        self.cron = cron; self.valid = valid; self.error = error; self.preset = preset; self.nextRuns = nextRuns
    }
    enum Keys: String, CodingKey { case cron, valid, error, preset, nextRuns }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        cron = c.lossy(String.self, .cron) ?? ""
        valid = c.lossy(Bool.self, .valid) ?? false
        error = c.lossy(String.self, .error)
        preset = c.lossy(SchedulePreset.self, .preset)
        nextRuns = c.lossyArray(String.self, .nextRuns).compactMap(CoreDate.parse)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(cron, forKey: .cron)
        try c.encode(valid, forKey: .valid)
        try c.encodeIfPresent(error, forKey: .error)
        try c.encodeIfPresent(preset, forKey: .preset)
        try c.encode(nextRuns.map(CoreDate.format), forKey: .nextRuns)
    }
}

/// `POST /v1/collectors`.
public struct NewCollectorInput: Encodable, Hashable, Sendable {
    public struct Script: Encodable, Hashable, Sendable {
        public var source: ScriptSource
        public var interpreter: CollectorInterpreter
        public var timeoutSeconds: Int?
        /// v6: the package manifest's text for a managed script (package.json / requirements.txt).
        public var manifest: String?
        /// Automations: false for "Commands for buttons" (absent = collects).
        public var collects: Bool?
        public init(source: ScriptSource, interpreter: CollectorInterpreter, timeoutSeconds: Int? = nil, manifest: String? = nil,
                    collects: Bool? = nil) {
            self.source = source; self.interpreter = interpreter; self.timeoutSeconds = timeoutSeconds; self.manifest = manifest
            self.collects = collects
        }
    }
    public var kind: CollectorKind
    public var name: String?
    public var vaultPath: String?
    public var enabled: Bool?
    public var schedule: CollectorSchedule?
    public var folder: FolderPatch?
    public var script: Script?

    public init(kind: CollectorKind, name: String? = nil, vaultPath: String? = nil, enabled: Bool? = nil,
                schedule: CollectorSchedule? = nil, folder: FolderPatch? = nil, script: Script? = nil) {
        self.kind = kind; self.name = name; self.vaultPath = vaultPath; self.enabled = enabled
        self.schedule = schedule; self.folder = folder; self.script = script
    }
}

public struct FolderPatch: Encodable, Hashable, Sendable {
    public var source: String?
    public var afterCollect: String?
    /// v5; nil = not sent.
    public var includeSubfolders: Bool?
    public init(source: String? = nil, afterCollect: String? = nil, includeSubfolders: Bool? = nil) {
        self.source = source; self.afterCollect = afterCollect; self.includeSubfolders = includeSubfolders
    }
}

public struct ScriptPatch: Encodable, Hashable, Sendable {
    public var source: ScriptSource?
    public var interpreter: CollectorInterpreter?
    public var timeoutSeconds: Int?
    public init(source: ScriptSource? = nil, interpreter: CollectorInterpreter? = nil, timeoutSeconds: Int? = nil) {
        self.source = source; self.interpreter = interpreter; self.timeoutSeconds = timeoutSeconds
    }
}

/// `PATCH /v1/collectors/:id` (only the keys set are sent).
public struct CollectorPatch: Encodable, Hashable, Sendable {
    public var name: String?
    public var vaultPath: String?
    public var enabled: Bool?
    public var schedule: CollectorSchedule?
    public var folder: FolderPatch?
    public var script: ScriptPatch?
    public init(name: String? = nil, vaultPath: String? = nil, enabled: Bool? = nil, schedule: CollectorSchedule? = nil,
                folder: FolderPatch? = nil, script: ScriptPatch? = nil) {
        self.name = name; self.vaultPath = vaultPath; self.enabled = enabled; self.schedule = schedule
        self.folder = folder; self.script = script
    }
    public var isEmpty: Bool { self == CollectorPatch() }
}

// MARK: - CoreClient

extension CoreClient {
    public func collectors() async throws -> [Collector] {
        try await getWrapped("/v1/collectors", LossyList<Collector>.self, key: "collectors").items
    }

    public func collector(_ id: String) async throws -> Collector { try await getPlain("/v1/collectors/\(Self.segment(id))") }

    /// A script collector is saved off; it needs `allowCollector` before it runs.
    public func createCollector(_ input: NewCollectorInput) async throws -> Collector {
        try await sendPlain("POST", "/v1/collectors", body: input)
    }

    public func updateCollector(_ id: String, _ patch: CollectorPatch) async throws -> Collector {
        try await sendPlain("PATCH", "/v1/collectors/\(Self.segment(id))", body: patch)
    }

    /// Refused (409) while a run is queued or running. The ledger is kept.
    public func deleteCollector(_ id: String) async throws {
        let _: JSONValue = try await sendPlain("DELETE", "/v1/collectors/\(Self.segment(id))", body: Optional<JSONValue>.none)
    }

    /// Run now: the queued or running run (409 when one is already queued or running).
    public func runCollector(_ id: String) async throws -> CollectorRun {
        try await sendWrapped("POST", "/v1/collectors/\(Self.segment(id))/run", body: JSONValue.object([:]), CollectorRun.self, key: "run")
    }

    /// Stop: the stopped run, or nil when idle.
    public func stopCollector(_ id: String) async throws -> CollectorRun? {
        try await sendWrapped("POST", "/v1/collectors/\(Self.segment(id))/stop", body: JSONValue.object([:]), CollectorRun?.self, key: "run")
    }

    /// Consent: `sha256` must be the script's current hash (the core's `status.currentSha256`). Also turns it on.
    public func allowCollector(_ id: String, sha256: String) async throws -> Collector {
        try await sendPlain("POST", "/v1/collectors/\(Self.segment(id))/consent", body: ["sha256": sha256])
    }

    /// Clears the consent and turns the collector off.
    public func revokeCollector(_ id: String) async throws -> Collector {
        try await sendPlain("DELETE", "/v1/collectors/\(Self.segment(id))/consent", body: Optional<JSONValue>.none)
    }

    /// Newest first.
    public func collectorRuns(_ id: String, limit: Int? = nil) async throws -> [CollectorRun] {
        let q = limit.map { "?limit=\($0)" } ?? ""
        return try await getWrapped("/v1/collectors/\(Self.segment(id))/runs" + q, LossyList<CollectorRun>.self, key: "runs").items
    }

    /// Already collected, newest first; `query` filters by name.
    public func collected(_ id: String, query: String? = nil) async throws -> [CollectedFile] {
        var path = "/v1/collectors/\(Self.segment(id))/collected"
        if let query, !query.isEmpty {
            var c = URLComponents()
            c.queryItems = [URLQueryItem(name: "query", value: query)]
            path += "?" + (c.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B")
        }
        return try await getWrapped(path, LossyList<CollectedFile>.self, key: "files").items
    }

    /// Forget one (by sha256) or, with nil, all from this folder. Returns what was removed (for Undo).
    public func forgetCollected(_ id: String, sha256: String? = nil) async throws -> [CollectedFile] {
        let path = "/v1/collectors/\(Self.segment(id))/collected" + (sha256.map { "/" + Self.segment($0) } ?? "")
        return try await sendWrapped("DELETE", path, body: Optional<JSONValue>.none, LossyList<CollectedFile>.self, key: "forgotten").items
    }

    /// Undo of Forget: puts the entries back. Returns how many.
    public func restoreCollected(_ id: String, files: [CollectedFile]) async throws -> Int {
        struct Body: Encodable { let files: [CollectedFile] }
        return try await sendWrapped("POST", "/v1/collectors/\(Self.segment(id))/collected/restore", body: Body(files: files),
                                     Int.self, key: "restored")
    }

    /// Create a missing source folder or the target vault's queue folder.
    public func createCollectorFolder(_ id: String, which: String) async throws -> Collector {
        try await sendPlain("POST", "/v1/collectors/\(Self.segment(id))/create-folder", body: ["which": which])
    }

    public func checkSchedule(_ cron: String) async throws -> ScheduleCheck {
        try await sendPlain("POST", "/v1/collectors/check-schedule", body: ["cron": cron])
    }
}
