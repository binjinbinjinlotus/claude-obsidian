import Foundation

public enum JobState: String, Codable, Sendable {
    case running
    /// Claude stopped and is waiting on the user: a transaction plan to
    /// approve, questions to answer, or denied tool calls to allow.
    case awaitingApproval
    case completed
    case failed
    case rejected
    case cancelled

    /// A job in these states blocks the next batch for the same vault, so a
    /// new bundle is never built against hashes an approval is about to change.
    public var holdsVault: Bool { self == .running || self == .awaitingApproval }
    public var isFinished: Bool { !holdsVault }
}

/// `claude-obsidian.transaction-plan.v1`, as printed by `transaction inspect`.
public struct TransactionPlan: Codable, Equatable, Sendable {
    public var operationID: String
    public var operationType: String
    public var valid: Bool
    public var changedPaths: [String]
    public var approvalSHA256: String

    enum CodingKeys: String, CodingKey {
        case operationID = "operation_id"
        case operationType = "operation_type"
        case valid
        case changedPaths = "changed_paths"
        case approvalSHA256 = "approval_sha256"
    }
}

/// The structured status every worker turn must end with (see `WorkerProtocol.schema`).
public struct WorkerStatus: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        case needsApproval = "needs_approval"
        case needsInput = "needs_input"
        case done
        case nothingToDo = "nothing_to_do"
        case failed
    }

    public var status: Status
    public var summary: String
    public var bundlePath: String?
    public var questions: [String]
    public var operationID: String?
    public var changedPaths: [String]
    public var skipped: [String]

    public init(status: Status, summary: String, bundlePath: String? = nil, questions: [String] = [],
                operationID: String? = nil, changedPaths: [String] = [], skipped: [String] = []) {
        self.status = status
        self.summary = summary
        self.bundlePath = bundlePath
        self.questions = questions
        self.operationID = operationID
        self.changedPaths = changedPaths
        self.skipped = skipped
    }

    public init?(_ value: JSONValue?) {
        guard let value, let raw = value["status"]?.stringValue, let status = Status(rawValue: raw) else {
            return nil
        }
        self.init(
            status: status,
            summary: value["summary"]?.stringValue ?? "",
            bundlePath: value["bundle_path"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 },
            questions: value["questions"]?.stringArray ?? [],
            operationID: value["operation_id"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 },
            changedPaths: value["changed_paths"]?.stringArray ?? [],
            skipped: value["skipped"]?.stringArray ?? []
        )
    }
}

/// What the user is asked to decide. The plan comes from the app running
/// `transaction inspect` itself, not from Claude's summary of it.
public struct ApprovalRequest: Codable, Equatable, Sendable {
    public var summary: String
    public var questions: [String]
    public var bundlePath: String?
    public var plan: TransactionPlan?
    public var planError: String?
    public var denials: [PermissionDenial]
    public var skipped: [String]

    public var canApplyPlan: Bool { plan?.valid == true && bundlePath != nil }
}

public struct TurnRecord: Codable, Equatable, Sendable, Identifiable {
    public enum Author: String, Codable, Sendable { case worker, user, app }
    public var id = UUID()
    public var date = Date()
    public var author: Author
    public var text: String
    public var costUSD: Double = 0

    public init(author: Author, text: String, costUSD: Double = 0) {
        self.author = author
        self.text = text
        self.costUSD = costUSD
    }
}

public struct Job: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var kind: String
    public var vaultPath: String
    /// Vault-relative paths of the inputs this job owns.
    public var files: [String]
    public var sessionID: String
    /// nil in jobs saved before runners existed = Claude Code.
    public var runnerID: String?
    public var model: String
    public var effort: String?
    public var state: JobState
    public var createdAt: Date
    public var updatedAt: Date
    public var approval: ApprovalRequest?
    public var turns: [TurnRecord]
    /// Tool rules the user granted after a denial; kept for later turns.
    public var grantedTools: [String]
    public var operationID: String?
    public var changedPaths: [String]
    public var error: String?

    public init(id: String, kind: String, vaultPath: String, files: [String], model: String) {
        self.id = id
        self.kind = kind
        self.vaultPath = vaultPath
        self.files = files
        self.sessionID = UUID().uuidString.lowercased()
        self.model = model
        self.state = .running
        self.createdAt = Date()
        self.updatedAt = Date()
        self.turns = []
        self.grantedTools = []
        self.changedPaths = []
    }

    public var totalCostUSD: Double { turns.reduce(0) { $0 + $1.costUSD } }

    public var selection: ModelSelection {
        get { ModelSelection(runnerID: runnerID ?? Runners.defaultID, model: model, effort: effort) }
        set { runnerID = newValue.runnerID; model = newValue.model; effort = newValue.effort }
    }

    public var stateDirectory: URL {
        URL(fileURLWithPath: vaultPath).appendingPathComponent(".vault-meta/worker/\(id)", isDirectory: true)
    }

    public static func makeID(date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return "job-\(f.string(from: date))-\(UUID().uuidString.prefix(4).lowercased())"
    }
}
