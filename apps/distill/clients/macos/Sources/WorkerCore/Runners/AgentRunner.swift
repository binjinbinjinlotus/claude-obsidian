import Foundation

// MARK: Tasks

/// Something the app asks an AI to do. Each task has its own default
/// runner / model / effort in Settings, and declares what it needs from a runner.
public enum AITask: String, Codable, CaseIterable, Sendable {
    /// Turn queued sources into a reviewed vault transaction (agentic, gated).
    case ingest
    /// Answer a question from the vault.
    case ask
    /// Suggest labels for a queued note.
    case labelSuggest
    /// Read text out of an image the user chose "Extract text" for.
    case imageText

    public var displayName: String {
        switch self {
        case .ingest: return "Adding notes"
        case .ask: return "Ask a question"
        case .labelSuggest: return "Label suggestions"
        case .imageText: return "Text from images"
        }
    }

    /// What a runner must support to run this task.
    public var requiredCapabilities: RunnerCapabilities {
        switch self {
        // Writes to the vault go through the approval gate, which needs tool use,
        // enforceable permission rules, and resuming the same session.
        case .ingest: return [.agentTools, .toolPermissions, .sessionResume, .structuredOutput]
        case .ask: return [.agentTools, .toolPermissions, .sessionResume]
        case .labelSuggest: return [.structuredOutput]
        case .imageText: return [.vision]
        }
    }

    /// Used when Settings has no explicit choice for the task.
    public var fallbackModel: String {
        switch self {
        case .labelSuggest: return "haiku"
        default: return "sonnet"
        }
    }
}

// MARK: Capabilities

public struct RunnerCapabilities: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// Can read files and run commands itself (an agent, not just a model API).
    public static let agentTools = RunnerCapabilities(rawValue: 1 << 0)
    /// Enforces allow-lists for tools, so the approval gate holds.
    public static let toolPermissions = RunnerCapabilities(rawValue: 1 << 1)
    /// Can continue the same conversation in a later call.
    public static let sessionResume = RunnerCapabilities(rawValue: 1 << 2)
    /// Can be forced to answer in a JSON schema.
    public static let structuredOutput = RunnerCapabilities(rawValue: 1 << 3)
    /// Accepts an effort / reasoning level.
    public static let effort = RunnerCapabilities(rawValue: 1 << 4)
    /// Accepts images.
    public static let vision = RunnerCapabilities(rawValue: 1 << 5)
}

// MARK: Selection

/// "Which runner, which model of that runner, at what effort" for one task.
public struct ModelSelection: Codable, Hashable, Sendable {
    public var runnerID: String
    public var model: String
    /// nil = the runner's default.
    public var effort: String?

    public init(runnerID: String, model: String, effort: String? = nil) {
        self.runnerID = runnerID
        self.model = model
        self.effort = effort
    }
}

public struct ModelOption: Hashable, Sendable {
    public let id: String
    public let label: String
    public let note: String

    public init(id: String, label: String, note: String = "") {
        self.id = id
        self.label = label
        self.note = note
    }
}

// MARK: Requests and results

/// A runner-neutral description of one turn. Each runner maps it to its own
/// CLI flags or API request.
public struct RunRequest: Sendable {
    public enum Session: Equatable, Sendable {
        case start(String)
        case resume(String)
    }

    public var workingDirectory: String
    public var prompt: String
    public var session: Session
    public var selection: ModelSelection
    /// Permission rules in Claude Code syntax (`Read`, `Bash(cmd:*)`,
    /// `Edit(//path/**)`). Runners translate them or refuse if they cannot enforce them.
    public var allowedTools: [String]
    /// Extra directories the runner may read (the product root, for skills).
    public var readableDirectories: [String]
    /// claude-obsidian plugin/skills location, for runners that load skills.
    public var pluginDirectory: String?
    public var outputSchema: String?
    public var systemPrompt: String?
    public var environment: [String: String]

    public init(workingDirectory: String, prompt: String, session: Session, selection: ModelSelection,
                allowedTools: [String] = [], readableDirectories: [String] = [], pluginDirectory: String? = nil,
                outputSchema: String? = nil, systemPrompt: String? = nil, environment: [String: String] = [:]) {
        self.workingDirectory = workingDirectory
        self.prompt = prompt
        self.session = session
        self.selection = selection
        self.allowedTools = allowedTools
        self.readableDirectories = readableDirectories
        self.pluginDirectory = pluginDirectory
        self.outputSchema = outputSchema
        self.systemPrompt = systemPrompt
        self.environment = environment
    }
}

/// What every runner returns for one turn.
public struct RunResult: Sendable {
    public var sessionID: String?
    public var resultText: String
    public var isError: Bool
    public var costUSD: Double
    public var structured: JSONValue?
    public var denials: [PermissionDenial]
    public var raw: Data

    public init(sessionID: String?, resultText: String, isError: Bool, costUSD: Double,
                structured: JSONValue?, denials: [PermissionDenial], raw: Data) {
        self.sessionID = sessionID
        self.resultText = resultText
        self.isError = isError
        self.costUSD = costUSD
        self.structured = structured
        self.denials = denials
        self.raw = raw
    }
}

// MARK: Runner protocol

/// One AI backend (Claude Code, Codex, OpenRouter, an OpenAI-compatible API,
/// the Vercel AI SDK, ...). Add a backend by conforming to this protocol and
/// registering it in `Runners.all`; the engine, approval gate and UI then work
/// with it for every task its capabilities allow.
public protocol AgentRunner: Sendable {
    var id: String { get }
    var displayName: String { get }
    var capabilities: RunnerCapabilities { get }
    /// Models this runner offers in pickers. Custom IDs are still allowed.
    var models: [ModelOption] { get }
    /// Effort levels it accepts (empty when it has no such setting).
    var effortLevels: [String] { get }
    var defaultModel: String { get }

    /// Setup problems (missing binary, missing API key, ...).
    func problems(_ settings: WorkerSettings) -> [SetupProblem]

    func run(_ request: RunRequest, settings: WorkerSettings, process: ProcessRunner) async throws -> RunResult

    /// Shell command that reopens a session interactively, if the runner has one.
    func resumeCommand(sessionID: String, model: String, settings: WorkerSettings) -> [String]?
}

extension AgentRunner {
    public func supports(_ task: AITask) -> Bool { capabilities.isSuperset(of: task.requiredCapabilities) }
    public func resumeCommand(sessionID: String, model: String, settings: WorkerSettings) -> [String]? { nil }
}

public enum RunnerError: Error, CustomStringConvertible {
    case launchFailed(String)
    case nonZeroExit(Int32, String)
    case malformedOutput(String)
    case cancelled
    case unknownRunner(String)
    case unsupported(runner: String, task: AITask)

    public var description: String {
        switch self {
        case .launchFailed(let m): return "Could not launch: \(m)"
        case .nonZeroExit(let code, let err): return "Exited \(code): \(err)"
        case .malformedOutput(let m): return "Unreadable runner output: \(m)"
        case .cancelled: return "Cancelled"
        case .unknownRunner(let id): return "Unknown AI runner \(id)."
        case .unsupported(let runner, let task):
            return "\(runner) can't do \(task.displayName.lowercased()): it lacks what this task needs."
        }
    }
}

// MARK: Registry

public enum Runners {
    /// Every runner the app knows about. Add new backends here.
    public static let all: [any AgentRunner] = [ClaudeCodeRunner()]

    public static let defaultID = ClaudeCodeRunner.runnerID

    public static func runner(_ id: String) -> (any AgentRunner)? { all.first { $0.id == id } }

    /// Runners enabled in Settings that can do `task`.
    public static func candidates(for task: AITask, settings: WorkerSettings) -> [any AgentRunner] {
        all.filter { settings.isRunnerEnabled($0.id) && $0.supports(task) }
    }
}
