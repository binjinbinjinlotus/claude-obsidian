import Foundation

/// One vault the worker knows about, with its own intake queue directory.
public struct VaultProfile: Codable, Hashable, Identifiable, Sendable {
    public var path: String
    public var queueDirectory: String

    public var id: String { path }
    public var name: String { URL(fileURLWithPath: path).lastPathComponent }
    public var url: URL { URL(fileURLWithPath: path) }
    public var queueURL: URL { URL(fileURLWithPath: queueDirectory) }
    public var inboxURL: URL { url.appendingPathComponent("inbox", isDirectory: true) }
    /// Ignored runtime state per AGENTS.md (`.vault-meta/`).
    public var workerStateURL: URL {
        url.appendingPathComponent(".vault-meta/worker", isDirectory: true)
    }

    public init(path: String, queueDirectory: String) {
        self.path = path
        self.queueDirectory = queueDirectory
    }

    public static func defaultQueueDirectory(forVault path: String) -> String {
        let name = URL(fileURLWithPath: path).lastPathComponent
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Distill Queue/\(name)", isDirectory: true)
            .path
    }
}

public struct ModelChoice: Hashable, Sendable {
    public let id: String
    public let label: String

    /// Aliases track the latest model; full IDs pin a specific one.
    public static let presets: [ModelChoice] = [
        .init(id: "opus", label: "Opus (latest)"),
        .init(id: "sonnet", label: "Sonnet (latest)"),
        .init(id: "haiku", label: "Haiku (latest)"),
        .init(id: "claude-opus-5-5", label: "Claude Opus 5.5"),
        .init(id: "claude-sonnet-5-5", label: "Claude Sonnet 5.5"),
        .init(id: "claude-haiku-4-5-20251001", label: "Claude Haiku 4.5"),
        .init(id: "claude-fable-5-1", label: "Claude Fable 5.1"),
    ]
}

public struct WorkerSettings: Codable, Equatable, Sendable {
    public var vaults: [VaultProfile] = []
    public var activeVaultPath: String?
    /// Minutes between batches. Files accumulate in the queue until then.
    public var batchIntervalMinutes: Int = 10
    /// A file must be unmodified this long before it is batched.
    public var settleSeconds: Int = 10
    public var model: String = "sonnet"
    public var claudePath: String = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".local/bin/claude").path
    public var pythonPath: String = "/usr/bin/python3"
    /// claude-obsidian checkout or installed plugin root (contains scripts/claude-obsidian.py).
    public var productRoot: String = WorkerSettings.bundledProductRoot ?? ""
    /// Extra `--allowedTools` rules granted to every run, one per entry.
    public var extraAllowedTools: [String] = []
    public var autoProcessEnabled: Bool = true
    /// Runner ids turned on in Settings. Only these appear in pickers.
    public var enabledRunners: [String] = [Runners.defaultID]
    /// Per-task "runner + model + effort", keyed by `AITask.rawValue`.
    /// Missing tasks fall back to `defaultSelection(for:)`.
    public var taskDefaults: [String: ModelSelection] = [:]

    public init() {}

    public func isRunnerEnabled(_ id: String) -> Bool { enabledRunners.contains(id) }

    /// The runner/model/effort a new job of `task` should use.
    public func selection(for task: AITask) -> ModelSelection {
        if let chosen = taskDefaults[task.rawValue] { return chosen }
        return defaultSelection(for: task)
    }

    public mutating func setSelection(_ selection: ModelSelection, for task: AITask) {
        taskDefaults[task.rawValue] = selection
    }

    /// Before per-task settings existed, `model` was the one Claude model for
    /// everything; keep honoring it for the agentic tasks.
    public func defaultSelection(for task: AITask) -> ModelSelection {
        let legacy = (task == .ingest || task == .ask) ? model : task.fallbackModel
        return ModelSelection(runnerID: Runners.defaultID, model: legacy, effort: nil)
    }

    public var activeVault: VaultProfile? {
        vaults.first { $0.path == activeVaultPath } ?? vaults.first
    }

    public var coreScriptPath: String {
        URL(fileURLWithPath: productRoot).appendingPathComponent("scripts/claude-obsidian.py").path
    }

    /// Written into Info.plist by scripts/build-app.sh so a fresh install
    /// points at the checkout it was built from.
    public static var bundledProductRoot: String? {
        Bundle.main.object(forInfoDictionaryKey: "ClaudeObsidianProductRoot") as? String
    }

    public mutating func upsert(_ profile: VaultProfile) {
        if let index = vaults.firstIndex(where: { $0.path == profile.path }) {
            vaults[index] = profile
        } else {
            vaults.append(profile)
        }
    }

    // Tolerate settings files written by older builds that lack newer keys.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = WorkerSettings()
        vaults = try c.decodeIfPresent([VaultProfile].self, forKey: .vaults) ?? d.vaults
        activeVaultPath = try c.decodeIfPresent(String.self, forKey: .activeVaultPath)
        batchIntervalMinutes = try c.decodeIfPresent(Int.self, forKey: .batchIntervalMinutes) ?? d.batchIntervalMinutes
        settleSeconds = try c.decodeIfPresent(Int.self, forKey: .settleSeconds) ?? d.settleSeconds
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? d.model
        claudePath = try c.decodeIfPresent(String.self, forKey: .claudePath) ?? d.claudePath
        pythonPath = try c.decodeIfPresent(String.self, forKey: .pythonPath) ?? d.pythonPath
        productRoot = try c.decodeIfPresent(String.self, forKey: .productRoot) ?? d.productRoot
        extraAllowedTools = try c.decodeIfPresent([String].self, forKey: .extraAllowedTools) ?? d.extraAllowedTools
        autoProcessEnabled = try c.decodeIfPresent(Bool.self, forKey: .autoProcessEnabled) ?? d.autoProcessEnabled
        enabledRunners = try c.decodeIfPresent([String].self, forKey: .enabledRunners) ?? d.enabledRunners
        taskDefaults = try c.decodeIfPresent([String: ModelSelection].self, forKey: .taskDefaults) ?? d.taskDefaults
    }
}

/// Validation results surfaced in Settings and before each run.
public enum SetupProblem: Equatable, CustomStringConvertible, Sendable {
    case noVault
    case notAVault(String)
    case missingClaude(String)
    case missingCore(String)
    case queueIsVaultInternal(String)
    case unknownRunner(String)

    public var description: String {
        switch self {
        case .noVault: return "No vault selected."
        case .notAVault(let p): return "\(p) has no .claude-obsidian.json (run `claude-obsidian.py init` or `adopt` first)."
        case .missingClaude(let p): return "claude CLI not found at \(p)."
        case .missingCore(let p): return "claude-obsidian core not found at \(p)."
        case .queueIsVaultInternal(let p): return "Queue directory \(p) must not be inside the vault's .raw/ or .vault-meta/."
        case .unknownRunner(let id): return "AI runner \(id) is not available in this build."
        }
    }
}

public enum SetupValidator {
    public static func isVault(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: URL(fileURLWithPath: path)
            .appendingPathComponent(".claude-obsidian.json").path)
    }

    public static func problems(_ s: WorkerSettings) -> [SetupProblem] {
        var out: [SetupProblem] = []
        let fm = FileManager.default
        if let v = s.activeVault {
            if !isVault(v.path) { out.append(.notAVault(v.path)) }
            let q = v.queueURL.standardizedFileURL.path
            for runtimeDir in [".raw", ".vault-meta"] {
                let p = v.url.appendingPathComponent(runtimeDir).standardizedFileURL.path
                if q == p || q.hasPrefix(p + "/") { out.append(.queueIsVaultInternal(q)) }
            }
        } else {
            out.append(.noVault)
        }
        // Every runner that some task is set to use must be ready.
        let used = Set(AITask.allCases.map { s.selection(for: $0).runnerID })
        for id in used.sorted() {
            guard let runner = Runners.runner(id) else { out.append(.unknownRunner(id)); continue }
            out.append(contentsOf: runner.problems(s))
        }
        if !fm.fileExists(atPath: s.coreScriptPath) { out.append(.missingCore(s.coreScriptPath)) }
        return out
    }
}

public enum WorkerPaths {
    public static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Distill", isDirectory: true)
    }
}

/// JSON file under ~/Library/Application Support/Distill/.
public struct JSONFileStore<Value: Codable> {
    public let url: URL

    public init(filename: String, directory: URL = WorkerPaths.supportDirectory) {
        self.url = directory.appendingPathComponent(filename)
    }

    public func load() -> Value? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder.worker.decode(Value.self, from: data)
    }

    public func save(_ value: Value) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder.worker.encode(value)
        try data.write(to: url, options: .atomic)
    }
}

extension JSONEncoder {
    static var worker: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }
}

extension JSONDecoder {
    static var worker: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
