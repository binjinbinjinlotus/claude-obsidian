import Foundation

/// One `claude -p` invocation. The first turn of a job pins `--session-id`;
/// every later turn uses `--resume` with the same id, from the same cwd
/// (sessions are keyed by working directory).
public struct ClaudeInvocation: Equatable, Sendable {
    public enum Session: Equatable, Sendable {
        case start(String)
        case resume(String)
    }

    public var claudePath: String
    public var workingDirectory: String
    public var prompt: String
    public var session: Session
    public var model: String
    public var effort: String?
    public var allowedTools: [String]
    public var addDirectories: [String]
    public var pluginDirectory: String?
    public var outputSchema: String?
    public var appendSystemPrompt: String?
    public var environment: [String: String]

    public init(
        claudePath: String, workingDirectory: String, prompt: String, session: Session,
        model: String, effort: String? = nil, allowedTools: [String], addDirectories: [String] = [],
        pluginDirectory: String? = nil, outputSchema: String? = nil,
        appendSystemPrompt: String? = nil, environment: [String: String] = [:]
    ) {
        self.claudePath = claudePath
        self.workingDirectory = workingDirectory
        self.prompt = prompt
        self.session = session
        self.model = model
        self.effort = effort
        self.allowedTools = allowedTools
        self.addDirectories = addDirectories
        self.pluginDirectory = pluginDirectory
        self.outputSchema = outputSchema
        self.appendSystemPrompt = appendSystemPrompt
        self.environment = environment
    }

    /// The prompt goes over stdin so it never collides with variadic flags
    /// such as `--allowedTools`.
    public var arguments: [String] {
        var args = ["-p", "--output-format", "json", "--model", model]
        if let effort, !effort.isEmpty { args += ["--effort", effort] }
        switch session {
        case .start(let id): args += ["--session-id", id]
        case .resume(let id): args += ["--resume", id]
        }
        if let plugin = pluginDirectory { args += ["--plugin-dir", plugin] }
        for dir in addDirectories { args += ["--add-dir", dir] }
        if let schema = outputSchema { args += ["--json-schema", schema] }
        if let system = appendSystemPrompt { args += ["--append-system-prompt", system] }
        // One argv entry per rule: a comma inside a rule must not split it.
        if !allowedTools.isEmpty { args += ["--allowedTools"] + allowedTools }
        return args
    }
}

/// Claude Code's `--output-format json` envelope, decoded into a `RunResult`.
extension RunResult {

    public static func parseClaudeJSON(_ data: Data) throws -> RunResult {
        guard case .object(let obj) = try JSONDecoder().decode(JSONValue.self, from: data) else {
            throw RunnerError.malformedOutput(String(decoding: data.prefix(500), as: UTF8.self))
        }
        var denials: [PermissionDenial] = []
        if case .array(let items)? = obj["permission_denials"] {
            for case .object(let d) in items {
                guard case .string(let name)? = d["tool_name"] else { continue }
                var input: [String: JSONValue] = [:]
                if case .object(let i)? = d["tool_input"] { input = i }
                denials.append(PermissionDenial(toolName: name, input: input))
            }
        }
        return RunResult(
            sessionID: obj["session_id"]?.stringValue,
            resultText: obj["result"]?.stringValue ?? "",
            isError: obj["is_error"]?.boolValue ?? false,
            costUSD: obj["total_cost_usd"]?.doubleValue ?? 0,
            structured: obj["structured_output"],
            denials: denials,
            raw: data
        )
    }
}

/// Back-compat name for the Claude Code result type.
public typealias ClaudeResult = RunResult
extension RunResult {
    public static func parse(_ data: Data) throws -> RunResult { try parseClaudeJSON(data) }
}

/// Claude Code (`claude -p`). Full agent: tools, enforceable permission rules,
/// session resume, JSON-schema output, effort, images.
public struct ClaudeCodeRunner: AgentRunner {
    public static let runnerID = "claude-code"
    public init() {}

    public var id: String { Self.runnerID }
    public var displayName: String { "Claude Code" }
    public var capabilities: RunnerCapabilities {
        [.agentTools, .toolPermissions, .sessionResume, .structuredOutput, .effort, .vision]
    }
    public var models: [ModelOption] {
        [
            .init(id: "haiku", label: "Haiku", note: "Fastest and lightest"),
            .init(id: "sonnet", label: "Sonnet", note: "Balanced, recommended"),
            .init(id: "opus", label: "Opus", note: "Deepest synthesis"),
            .init(id: "claude-opus-5-5", label: "Claude Opus 5.5"),
            .init(id: "claude-sonnet-5-5", label: "Claude Sonnet 5.5"),
            .init(id: "claude-haiku-4-5-20251001", label: "Claude Haiku 4.5"),
            .init(id: "claude-fable-5-1", label: "Claude Fable 5.1"),
        ]
    }
    public var effortLevels: [String] { ["low", "medium", "high", "xhigh", "max"] }
    public var defaultModel: String { "sonnet" }

    public func problems(_ settings: WorkerSettings) -> [SetupProblem] {
        FileManager.default.isExecutableFile(atPath: settings.claudePath) ? [] : [.missingClaude(settings.claudePath)]
    }

    public func invocation(_ request: RunRequest, settings: WorkerSettings) -> ClaudeInvocation {
        ClaudeInvocation(
            claudePath: settings.claudePath,
            workingDirectory: request.workingDirectory,
            prompt: request.prompt,
            session: {
                switch request.session {
                case .start(let id): return .start(id)
                case .resume(let id): return .resume(id)
                }
            }(),
            model: request.selection.model,
            effort: request.selection.effort,
            allowedTools: request.allowedTools,
            addDirectories: request.readableDirectories,
            pluginDirectory: request.pluginDirectory,
            outputSchema: request.outputSchema,
            appendSystemPrompt: request.systemPrompt,
            environment: request.environment)
    }

    public func run(_ request: RunRequest, settings: WorkerSettings, process: ProcessRunner) async throws -> RunResult {
        let inv = invocation(request, settings: settings)
        let output = try await process.run(
            executable: inv.claudePath, arguments: inv.arguments, cwd: inv.workingDirectory,
            stdin: Data(inv.prompt.utf8), environment: inv.environment)
        if output.stdout.isEmpty, output.status != 0 {
            throw RunnerError.nonZeroExit(output.status, String(decoding: output.stderr.suffix(2000), as: UTF8.self))
        }
        return try RunResult.parseClaudeJSON(output.stdout)
    }

    public func resumeCommand(sessionID: String, model: String, settings: WorkerSettings) -> [String]? {
        [settings.claudePath, "--resume", sessionID, "--plugin-dir", settings.productRoot, "--model", model]
    }
}
