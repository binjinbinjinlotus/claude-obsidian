import Foundation

// Codable mirrors of apps/distill/core/src/contracts.ts. The core owns every
// one of these; the app only displays them and sends requests. Decoding is
// tolerant: missing keys fall back to the contract defaults, wrong-typed
// fields are dropped, and malformed array elements are skipped.

// MARK: - Settings

public struct VaultProfile: Codable, Hashable, Identifiable, Sendable {
    public var path: String
    public var queueDirectory: String

    public var id: String { path }
    public var name: String { URL(fileURLWithPath: path).lastPathComponent }
    public var url: URL { URL(fileURLWithPath: path) }
    public var queueURL: URL { URL(fileURLWithPath: queueDirectory) }
    public var inboxURL: URL { url.appendingPathComponent("inbox", isDirectory: true) }
    public var queueIsInbox: Bool { queueURL.standardizedFileURL.path == inboxURL.standardizedFileURL.path }

    public init(path: String, queueDirectory: String) {
        self.path = path
        self.queueDirectory = queueDirectory
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        queueDirectory = c.lossy(String.self, .queueDirectory) ?? Self.defaultQueueDirectory(forVault: path)
    }

    /// Same default as the core's `defaultQueueDirectory` (used when adding a vault).
    public static func defaultQueueDirectory(forVault path: String) -> String {
        let name = URL(fileURLWithPath: path).lastPathComponent
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Distill Queue/\(name)", isDirectory: true).path
    }

    /// A vault is a folder with `.claude-obsidian.json` (checked before adding one).
    public static func isVault(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: URL(fileURLWithPath: path).appendingPathComponent(".claude-obsidian.json").path)
    }
}

public enum AITask: String, Codable, CaseIterable, Sendable {
    case ingest, ask, labelSuggest, imageText
    /// v3: find actions in notes and answers; write and improve action drafts.
    case actionFind, actionDraft, actionImprove
}

public struct ModelSelection: Codable, Hashable, Sendable {
    public var runnerID: String
    public var model: String
    public var effort: String?

    public init(runnerID: String, model: String, effort: String? = nil) {
        self.runnerID = runnerID
        self.model = model
        self.effort = effort
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        runnerID = c.lossy(String.self, .runnerID) ?? "claude-code"
        model = try c.decode(String.self, forKey: .model)
        effort = c.lossy(String.self, .effort)
    }
}

public struct SourceDefinition: Codable, Hashable, Sendable {
    public var id: String
    public var label: String

    public init(id: String, label: String) { self.id = id; self.label = label }
}

public struct SourceGroup: Codable, Hashable, Sendable {
    public var id: String
    public var label: String
    public var sources: [SourceDefinition]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = c.lossy(String.self, .label) ?? id
        sources = c.lossyArray(SourceDefinition.self, .sources)
    }
}

public enum LabelMatch: String, Codable, Sendable { case any, all }

/// `Partial<AskPreferences>` in settings: every field optional.
public struct AskPreferences: Codable, Hashable, Sendable {
    public var labelMatch: LabelMatch?
    public var includeUnconfirmed: Bool?
    public var keepHistory: Bool?
    public var historyDays: Int?

    public init(labelMatch: LabelMatch? = nil, includeUnconfirmed: Bool? = nil, keepHistory: Bool? = nil, historyDays: Int? = nil) {
        self.labelMatch = labelMatch
        self.includeUnconfirmed = includeUnconfirmed
        self.keepHistory = keepHistory
        self.historyDays = historyDays
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        labelMatch = c.lossy(LabelMatch.self, .labelMatch)
        includeUnconfirmed = c.lossy(Bool.self, .includeUnconfirmed)
        keepHistory = c.lossy(Bool.self, .keepHistory)
        historyDays = c.lossyInt(.historyDays)
    }
}

public struct LabelingPreferences: Codable, Hashable, Sendable {
    public var autoLabelQueueFolder: Bool?
    public var cliFallbackToAI: Bool?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        autoLabelQueueFolder = c.lossy(Bool.self, .autoLabelQueueFolder)
        cliFallbackToAI = c.lossy(Bool.self, .cliFallbackToAI)
    }
}

public struct ShortcutSettings: Codable, Hashable, Sendable {
    public var ask: String?
    public var addNote: String?

    public init(ask: String? = nil, addNote: String? = nil) { self.ask = ask; self.addNote = addNote }
}

/// Mirrors `Settings` in contracts.ts. Edit a copy and send the difference with
/// `Settings.patch(from:to:)`; keys this build does not model are never sent,
/// so the core keeps them.
public struct Settings: Codable, Equatable, Sendable {
    public var vaults: [VaultProfile] = []
    public var activeVaultPath: String?
    public var batchIntervalMinutes: Int = 10
    /// Default 600 (10 minutes), as in the core. Process now ignores it.
    public var settleSeconds: Int = 600
    public var model: String = "sonnet"
    public var claudePath: String = ""
    public var pythonPath: String = "/usr/bin/python3"
    public var productRoot: String = ""
    public var extraAllowedTools: [String] = []
    public var autoProcessEnabled: Bool = true
    public var enabledRunners: [String] = ["claude-code"]
    public var taskDefaults: [String: ModelSelection] = [:]
    public var nodePath: String?
    // v2 (optional; absent = the core's defaults)
    public var sourceTaxonomy: [SourceGroup]?
    public var askPreferences: AskPreferences?
    public var labeling: LabelingPreferences?
    public var shortcuts: ShortcutSettings?
    public var runnerOptions: [String: [String: String]]?
    /// v3 (optional; absent = DEFAULT_ACTION_PREFERENCES). Raw object, so unknown nested keys survive.
    public var actionPreferences: ActionPreferences?
    /// v5: the queue check, in minutes (absent = 5, 0 = Off). Never written unless the user picks a value.
    public var queueScanMinutes: Int?

    /// The queue check as the core applies it: absent = 5; clamped to 0…1440.
    public var resolvedQueueScanMinutes: Int { queueScanMinutes.map { min(1440, max(0, $0)) } ?? 5 }

    public init() {}

    public var activeVault: VaultProfile? {
        vaults.first { $0.path == activeVaultPath } ?? vaults.first
    }

    public mutating func upsert(_ profile: VaultProfile) {
        if let i = vaults.firstIndex(where: { $0.path == profile.path }) { vaults[i] = profile } else { vaults.append(profile) }
    }

    public mutating func removeVault(_ path: String) {
        vaults.removeAll { $0.path == path }
        if activeVaultPath == path { activeVaultPath = vaults.first?.path }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        vaults = c.lossyArray(VaultProfile.self, .vaults)
        activeVaultPath = c.lossy(String.self, .activeVaultPath)
        batchIntervalMinutes = c.lossyInt(.batchIntervalMinutes) ?? d.batchIntervalMinutes
        settleSeconds = c.lossyInt(.settleSeconds) ?? d.settleSeconds
        model = c.lossy(String.self, .model) ?? d.model
        claudePath = c.lossy(String.self, .claudePath) ?? d.claudePath
        pythonPath = c.lossy(String.self, .pythonPath) ?? d.pythonPath
        productRoot = c.lossy(String.self, .productRoot) ?? d.productRoot
        extraAllowedTools = c.lossyArray(String.self, .extraAllowedTools)
        autoProcessEnabled = c.lossy(Bool.self, .autoProcessEnabled) ?? d.autoProcessEnabled
        enabledRunners = c.lossy([String].self, .enabledRunners) ?? d.enabledRunners
        if let raw = c.lossy([String: Lossy<ModelSelection>].self, .taskDefaults) {
            taskDefaults = raw.compactMapValues(\.value)
        }
        nodePath = c.lossy(String.self, .nodePath)
        sourceTaxonomy = c.lossy([Lossy<SourceGroup>].self, .sourceTaxonomy)?.compactMap(\.value)
        askPreferences = c.lossy(AskPreferences.self, .askPreferences)
        labeling = c.lossy(LabelingPreferences.self, .labeling)
        shortcuts = c.lossy(ShortcutSettings.self, .shortcuts)
        runnerOptions = c.lossy([String: [String: String]].self, .runnerOptions)
        actionPreferences = c.lossy(ActionPreferences.self, .actionPreferences)
        queueScanMinutes = c.lossyInt(.queueScanMinutes).map { min(1440, max(0, $0)) }
    }

    /// This value as a JSON object (nil optionals omitted).
    public func jsonObject() -> [String: JSONValue] {
        guard let data = try? JSONEncoder.core.encode(self),
              case .object(let o)? = try? JSONDecoder.core.decode(JSONValue.self, from: data) else { return [:] }
        return o
    }

    /// The top-level keys that differ, for `PUT /v1/settings`. A key present in
    /// `old` but cleared in `new` is sent as null (the core clears it).
    public static func patch(from old: Settings, to new: Settings) -> [String: JSONValue] {
        let a = old.jsonObject(), b = new.jsonObject()
        var out: [String: JSONValue] = [:]
        for (k, v) in b where a[k] != v { out[k] = v }
        for k in a.keys where b[k] == nil { out[k] = .null }
        return out
    }
}

// MARK: - Jobs

public enum JobState: String, Codable, Sendable {
    case running, awaitingApproval, completed, failed, rejected, cancelled

    public var holdsVault: Bool { self == .running || self == .awaitingApproval }
    public var isFinished: Bool { !holdsVault }
}

/// `claude-obsidian.transaction-plan.v1`, as produced by `transaction inspect` in the core.
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

    public init(operationID: String, operationType: String, valid: Bool, changedPaths: [String], approvalSHA256: String) {
        self.operationID = operationID
        self.operationType = operationType
        self.valid = valid
        self.changedPaths = changedPaths
        self.approvalSHA256 = approvalSHA256
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        operationID = c.lossy(String.self, .operationID) ?? ""
        operationType = c.lossy(String.self, .operationType) ?? ""
        valid = c.lossy(Bool.self, .valid) ?? false
        changedPaths = c.lossyArray(String.self, .changedPaths)
        approvalSHA256 = c.lossy(String.self, .approvalSHA256) ?? ""
    }
}

public struct ApprovalRequest: Codable, Equatable, Sendable {
    public var summary: String
    public var questions: [String]
    public var bundlePath: String?
    public var plan: TransactionPlan?
    public var planError: String?
    public var denials: [PermissionDenial]
    public var skipped: [String]
    /// v6: each source page the bundle creates, with its labels (nil from an older core).
    public var sources: [ReviewSource]?
    /// v6: where the labels shown in Review stand.
    public var labels: ReviewLabels?
    /// v6: the same change with labels left unconfirmed (Approve, review labels later).
    public var unconfirmed: UnconfirmedPlan?
    /// v6: the plan was rebuilt in the batch's session and checked against what the user approved.
    public var rebuilt: RebuiltPlan?
    /// v6: the batch's AI session could not be resumed; the reason in plain words.
    public var sessionUnavailable: String?
    /// v6: the user discarded the rebuilt change for these sources; nothing was applied. Approve rebuilds it again.
    public var partDiscarded: Bool?

    public var canApplyPlan: Bool { plan?.valid == true && bundlePath != nil }
    /// v6: a rebuilt part of a batch (Reject discards only it) or a discarded one (Approve rebuilds it).
    public var isPart: Bool { rebuilt != nil || partDiscarded == true }

    public init(summary: String, questions: [String] = [], bundlePath: String? = nil, plan: TransactionPlan? = nil,
                planError: String? = nil, denials: [PermissionDenial] = [], skipped: [String] = [],
                sources: [ReviewSource]? = nil, labels: ReviewLabels? = nil, unconfirmed: UnconfirmedPlan? = nil,
                rebuilt: RebuiltPlan? = nil, sessionUnavailable: String? = nil, partDiscarded: Bool? = nil) {
        self.summary = summary
        self.questions = questions
        self.bundlePath = bundlePath
        self.plan = plan
        self.planError = planError
        self.denials = denials
        self.skipped = skipped
        self.sources = sources
        self.labels = labels
        self.unconfirmed = unconfirmed
        self.rebuilt = rebuilt
        self.sessionUnavailable = sessionUnavailable
        self.partDiscarded = partDiscarded
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        summary = c.lossy(String.self, .summary) ?? ""
        questions = c.lossyArray(String.self, .questions)
        bundlePath = c.lossy(String.self, .bundlePath)
        plan = c.lossy(TransactionPlan.self, .plan)
        planError = c.lossy(String.self, .planError)
        denials = c.lossyArray(PermissionDenial.self, .denials)
        skipped = c.lossyArray(String.self, .skipped)
        sources = c.lossy([Lossy<ReviewSource>].self, .sources).map { $0.compactMap(\.value) }
        labels = c.lossy(ReviewLabels.self, .labels)
        unconfirmed = c.lossy(UnconfirmedPlan.self, .unconfirmed).flatMap { $0.bundlePath.isEmpty ? nil : $0 }
        rebuilt = c.lossy(RebuiltPlan.self, .rebuilt)
        sessionUnavailable = c.lossy(String.self, .sessionUnavailable).flatMap { $0.isEmpty ? nil : $0 }
        partDiscarded = c.lossy(Bool.self, .partDiscarded).flatMap { $0 ? true : nil }
    }
}

public struct TurnRecord: Codable, Equatable, Sendable, Identifiable {
    enum CodingKeys: String, CodingKey { case id, date, author, text, costUSD }

    public enum Author: String, Codable, Sendable { case worker, user, app }
    /// A UUID string; the Swift app wrote uppercase, the core writes lowercase.
    public var id: String
    public var date: Date
    public var author: Author
    public var text: String
    public var costUSD: Double

    public init(id: String = UUID().uuidString, date: Date = Date(), author: Author, text: String, costUSD: Double = 0) {
        self.id = id
        self.date = date
        self.author = author
        self.text = text
        self.costUSD = costUSD
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lossy(String.self, .id) ?? UUID().uuidString
        date = c.lossyDate(.date) ?? .distantPast
        author = c.lossy(Author.self, .author) ?? .app
        text = c.lossy(String.self, .text) ?? ""
        costUSD = c.lossyDouble(.costUSD) ?? 0
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(CoreDate.format(date), forKey: .date)
        try c.encode(author, forKey: .author)
        try c.encode(text, forKey: .text)
        try c.encode(costUSD, forKey: .costUSD)
    }
}

public struct Job: Codable, Identifiable, Equatable, Sendable {
    enum CodingKeys: String, CodingKey {
        case id, kind, vaultPath, files, sessionID, runnerID, model, effort, state, createdAt, updatedAt
        case approval, turns, grantedTools, operationID, changedPaths, error, actionsFound, folders, parts, pendingPart
    }

    public var id: String
    public var kind: String
    public var vaultPath: String
    public var files: [String]
    public var sessionID: String
    public var runnerID: String?
    public var model: String
    public var effort: String?
    public var state: JobState
    public var createdAt: Date
    public var updatedAt: Date
    public var approval: ApprovalRequest?
    public var turns: [TurnRecord]
    public var grantedTools: [String]
    public var operationID: String?
    public var changedPaths: [String]
    public var error: String?
    /// v3: what the batch's "Finding actions" step found (nil on older cores and other kinds).
    public var actionsFound: JobActionsSummary?
    /// v5: folder items in this batch (vault-relative, "inbox/2026-10-04/Tea tasting trip"); their files are in `files`. nil on older jobs.
    public var folders: [String]?
    /// v6: parts of this batch already applied (approving only some sources); newest last. nil on older jobs.
    public var parts: [JobPart]?
    /// v6: the part being rebuilt in the batch's session, until its change comes back.
    public var pendingPart: PendingPart?

    public var totalCostUSD: Double { turns.reduce(0) { $0 + $1.costUSD } }
    public var selection: ModelSelection { ModelSelection(runnerID: runnerID ?? "claude-code", model: model, effort: effort) }

    public init(id: String, kind: String = "ingest", vaultPath: String, files: [String], sessionID: String = UUID().uuidString.lowercased(),
                runnerID: String? = "claude-code", model: String = "sonnet", effort: String? = nil, state: JobState = .running,
                createdAt: Date = Date(), updatedAt: Date = Date(), approval: ApprovalRequest? = nil, turns: [TurnRecord] = [],
                grantedTools: [String] = [], operationID: String? = nil, changedPaths: [String] = [], error: String? = nil) {
        self.id = id
        self.kind = kind
        self.vaultPath = vaultPath
        self.files = files
        self.sessionID = sessionID
        self.runnerID = runnerID
        self.model = model
        self.effort = effort
        self.state = state
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.approval = approval
        self.turns = turns
        self.grantedTools = grantedTools
        self.operationID = operationID
        self.changedPaths = changedPaths
        self.error = error
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = c.lossy(String.self, .kind) ?? "ingest"
        vaultPath = c.lossy(String.self, .vaultPath) ?? ""
        files = c.lossyArray(String.self, .files)
        sessionID = c.lossy(String.self, .sessionID) ?? ""
        runnerID = c.lossy(String.self, .runnerID)
        model = c.lossy(String.self, .model) ?? ""
        effort = c.lossy(String.self, .effort)
        // An unknown state from a newer core shows as failed rather than dropping the job.
        state = c.lossy(JobState.self, .state) ?? .failed
        createdAt = c.lossyDate(.createdAt) ?? .distantPast
        updatedAt = c.lossyDate(.updatedAt) ?? createdAt
        approval = c.lossy(ApprovalRequest.self, .approval)
        turns = c.lossyArray(TurnRecord.self, .turns)
        grantedTools = c.lossyArray(String.self, .grantedTools)
        operationID = c.lossy(String.self, .operationID)
        changedPaths = c.lossyArray(String.self, .changedPaths)
        error = c.lossy(String.self, .error)
        actionsFound = c.lossy(JobActionsSummary.self, .actionsFound)
        folders = c.lossy([Lossy<String>].self, .folders).map { $0.compactMap(\.value) }
        parts = c.lossy([Lossy<JobPart>].self, .parts).map { $0.compactMap(\.value) }
        pendingPart = c.lossy(PendingPart.self, .pendingPart)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind, forKey: .kind)
        try c.encode(vaultPath, forKey: .vaultPath)
        try c.encode(files, forKey: .files)
        try c.encode(sessionID, forKey: .sessionID)
        try c.encodeIfPresent(runnerID, forKey: .runnerID)
        try c.encode(model, forKey: .model)
        try c.encodeIfPresent(effort, forKey: .effort)
        try c.encode(state, forKey: .state)
        try c.encode(CoreDate.format(createdAt), forKey: .createdAt)
        try c.encode(CoreDate.format(updatedAt), forKey: .updatedAt)
        try c.encodeIfPresent(approval, forKey: .approval)
        try c.encode(turns, forKey: .turns)
        try c.encode(grantedTools, forKey: .grantedTools)
        try c.encodeIfPresent(operationID, forKey: .operationID)
        try c.encode(changedPaths, forKey: .changedPaths)
        try c.encodeIfPresent(error, forKey: .error)
        try c.encodeIfPresent(actionsFound, forKey: .actionsFound)
        try c.encodeIfPresent(folders, forKey: .folders)
        try c.encodeIfPresent(parts, forKey: .parts)
        try c.encodeIfPresent(pendingPart, forKey: .pendingPart)
    }
}

// MARK: - Queue, status

public struct QueueEntry: Codable, Equatable, Hashable, Sendable, Identifiable {
    enum CodingKeys: String, CodingKey {
        case path, name, modified, size, settled, readyAt, kind, problem, changing, members, note
        case fileCount, folderCount, tree, treeTruncated, gdoc, waiting, labels, heldForLabels
    }

    /// note = written by addNote (complete when queued, skips the settle wait); folder = a folder in the
    /// queue folder, one item (v5); gdoc = a Google Drive `.gdoc` pointer (v5); file = anything else
    /// (an unknown kind from a newer core reads as file).
    public enum Kind: String, Codable, Sendable { case note, file, folder, gdoc }

    /// v5: a `.gdoc` row's title and link (never the account email in the file).
    public struct GoogleDoc: Codable, Equatable, Hashable, Sendable {
        public var title: String
        public var url: String
        public var docId: String?
        public init(title: String, url: String, docId: String? = nil) { self.title = title; self.url = url; self.docId = docId }
        enum CodingKeys: String, CodingKey { case title, url, docId }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            title = c.lossy(String.self, .title) ?? ""
            url = c.lossy(String.self, .url) ?? ""
            docId = c.lossy(String.self, .docId)
        }
    }

    /// A note row's summary from its manifest.
    public struct NoteSummary: Codable, Equatable, Hashable, Sendable {
        enum CodingKeys: String, CodingKey { case source, labelsConfirmed, imageCount }
        /// Display text ("In person"; free text from the CLI as given).
        public var source: String?
        public var labelsConfirmed: Bool
        public var imageCount: Int

        public init(source: String? = nil, labelsConfirmed: Bool = false, imageCount: Int = 0) {
            self.source = source
            self.labelsConfirmed = labelsConfirmed
            self.imageCount = imageCount
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            source = c.lossy(String.self, .source).flatMap { $0.isEmpty ? nil : $0 }
            labelsConfirmed = c.lossy(Bool.self, .labelsConfirmed) ?? false
            imageCount = max(0, c.lossyInt(.imageCount) ?? 0)
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encodeIfPresent(source, forKey: .source)
            try c.encode(labelsConfirmed, forKey: .labelsConfirmed)
            try c.encode(imageCount, forKey: .imageCount)
        }
    }

    public var path: String
    public var name: String
    public var modified: Date
    public var size: Int
    public var settled: Bool
    /// When the settle wait ends (modified + settleSeconds); nil once ready.
    public var readyAt: Date?
    public var kind: Kind
    /// Why the core can't use this file (unreadable, ...).
    public var problem: String?
    /// The file changed after the core first saw it (its ready time moved).
    public var changing: Bool
    /// A note row's companion files (its .distill.json and images). nil from an
    /// older core, which listed them as rows of their own.
    public var members: [String]?
    public var note: NoteSummary?
    /// v5, folder rows: files inside (hidden files and partial downloads not counted), subfolders at any level.
    public var fileCount: Int?
    public var folderCount: Int?
    /// v5, folder rows: the read-only tree, sorted by path (capped by the core; `treeTruncated` then).
    public var tree: [QueueTreeEntry]?
    public var treeTruncated: Bool
    /// v5, gdoc rows.
    public var gdoc: GoogleDoc?
    /// v5: held out of every batch though nothing is wrong ("google-drive": a .gdoc).
    public var waiting: String?
    /// v6, text files that are not notes: their labels, suggested in the background (nil = no label line).
    public var labels: QueueLabels?
    /// v6: the label gate: labels not in yet, so the file stays for the next batch.
    public var heldForLabels: Bool

    public var id: String { path }
    public var url: URL { URL(fileURLWithPath: path) }

    public init(path: String, name: String? = nil, modified: Date, size: Int, settled: Bool,
                readyAt: Date? = nil, kind: Kind = .file, problem: String? = nil,
                changing: Bool = false, members: [String]? = nil, note: NoteSummary? = nil,
                fileCount: Int? = nil, folderCount: Int? = nil, tree: [QueueTreeEntry]? = nil, treeTruncated: Bool = false,
                gdoc: GoogleDoc? = nil, waiting: String? = nil, labels: QueueLabels? = nil, heldForLabels: Bool = false) {
        self.path = path
        self.name = name ?? URL(fileURLWithPath: path).lastPathComponent
        self.modified = modified
        self.size = size
        self.settled = settled
        self.readyAt = readyAt
        self.kind = kind
        self.problem = problem
        self.changing = changing
        self.members = members
        self.note = note
        self.fileCount = fileCount
        self.folderCount = folderCount
        self.tree = tree
        self.treeTruncated = treeTruncated
        self.gdoc = gdoc
        self.waiting = waiting
        self.labels = labels
        self.heldForLabels = heldForLabels
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        name = c.lossy(String.self, .name) ?? URL(fileURLWithPath: path).lastPathComponent
        modified = c.lossyDate(.modified) ?? .distantPast
        size = c.lossyInt(.size) ?? 0
        settled = c.lossy(Bool.self, .settled) ?? true
        readyAt = c.lossyDate(.readyAt)
        kind = c.lossy(String.self, .kind).flatMap(Kind.init(rawValue:)) ?? .file
        problem = c.lossy(String.self, .problem).flatMap { $0.isEmpty ? nil : $0 }
        changing = c.lossy(Bool.self, .changing) ?? false
        members = c.lossy([Lossy<String>].self, .members).map { $0.compactMap(\.value) }
        note = c.lossy(NoteSummary.self, .note)
        fileCount = c.lossyInt(.fileCount).map { max(0, $0) }
        folderCount = c.lossyInt(.folderCount).map { max(0, $0) }
        tree = c.lossy([Lossy<QueueTreeEntry>].self, .tree).map { $0.compactMap(\.value) }
        treeTruncated = c.lossy(Bool.self, .treeTruncated) ?? false
        gdoc = c.lossy(GoogleDoc.self, .gdoc)
        waiting = c.lossy(String.self, .waiting).flatMap { $0.isEmpty ? nil : $0 }
        labels = c.lossy(QueueLabels.self, .labels)
        heldForLabels = c.lossy(Bool.self, .heldForLabels) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(path, forKey: .path)
        try c.encode(name, forKey: .name)
        try c.encode(CoreDate.format(modified), forKey: .modified)
        try c.encode(size, forKey: .size)
        try c.encode(settled, forKey: .settled)
        try c.encodeIfPresent(readyAt.map(CoreDate.format), forKey: .readyAt)
        try c.encode(kind, forKey: .kind)
        try c.encodeIfPresent(problem, forKey: .problem)
        if changing { try c.encode(true, forKey: .changing) }
        try c.encodeIfPresent(members, forKey: .members)
        try c.encodeIfPresent(note, forKey: .note)
        try c.encodeIfPresent(fileCount, forKey: .fileCount)
        try c.encodeIfPresent(folderCount, forKey: .folderCount)
        try c.encodeIfPresent(tree, forKey: .tree)
        if treeTruncated { try c.encode(true, forKey: .treeTruncated) }
        try c.encodeIfPresent(gdoc, forKey: .gdoc)
        try c.encodeIfPresent(waiting, forKey: .waiting)
        try c.encodeIfPresent(labels, forKey: .labels)
        if heldForLabels { try c.encode(true, forKey: .heldForLabels) }
    }
}

/// One entry of a folder item's tree (`QueueTreeEntry`).
public struct QueueTreeEntry: Codable, Equatable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case file, dir, gdoc }
    /// Relative to the folder item, "/"-separated ("notes/day1-uji.md").
    public var path: String
    /// Bytes; a dir: the total of its files.
    public var size: Int
    public var kind: Kind
    /// Collected before (Folder collector): listed for context, not a source.
    public var seenBefore: Bool

    public init(path: String, size: Int = 0, kind: Kind = .file, seenBefore: Bool = false) {
        self.path = path; self.size = size; self.kind = kind; self.seenBefore = seenBefore
    }

    enum CodingKeys: String, CodingKey { case path, size, kind, seenBefore }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        size = max(0, c.lossyInt(.size) ?? 0)
        kind = c.lossy(String.self, .kind).flatMap(Kind.init(rawValue:)) ?? .file
        seenBefore = c.lossy(Bool.self, .seenBefore) ?? false
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(path, forKey: .path)
        try c.encode(size, forKey: .size)
        try c.encode(kind, forKey: .kind)
        if seenBefore { try c.encode(true, forKey: .seenBefore) }
    }
}

/// What a queue scan found (`POST /v1/queue/scan`, the `queue.scanned` event).
public struct QueueScanResult: Codable, Equatable, Sendable {
    public enum Trigger: String, Codable, Sendable { case manual, window, periodic }
    public var added: Int
    public var removed: Int
    public var changed: Int
    public var checkedAt: Date
    /// manual = Refresh; window = the window became active; periodic = the queue check (unknown reads as periodic).
    public var trigger: Trigger
    /// The queue folder exists but can't be read.
    public var problem: String?
    public var addedEntries: [QueueEntry]
    public var removedEntries: [QueueEntry]
    public var changedEntries: [QueueEntry]
    /// The whole list after the scan; nil when the core didn't send it.
    public var entries: [QueueEntry]?

    public init(added: Int = 0, removed: Int = 0, changed: Int = 0, checkedAt: Date = Date(), trigger: Trigger = .manual,
                problem: String? = nil, addedEntries: [QueueEntry] = [], removedEntries: [QueueEntry] = [],
                changedEntries: [QueueEntry] = [], entries: [QueueEntry]? = nil) {
        self.added = added; self.removed = removed; self.changed = changed; self.checkedAt = checkedAt; self.trigger = trigger
        self.problem = problem; self.addedEntries = addedEntries; self.removedEntries = removedEntries
        self.changedEntries = changedEntries; self.entries = entries
    }

    enum CodingKeys: String, CodingKey { case added, removed, changed, checkedAt, trigger, problem, addedEntries, removedEntries, changedEntries, entries }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        added = max(0, c.lossyInt(.added) ?? 0)
        removed = max(0, c.lossyInt(.removed) ?? 0)
        changed = max(0, c.lossyInt(.changed) ?? 0)
        checkedAt = c.lossyDate(.checkedAt) ?? Date()
        trigger = c.lossy(String.self, .trigger).flatMap(Trigger.init(rawValue:)) ?? .periodic
        problem = c.lossy(String.self, .problem).flatMap { $0.isEmpty ? nil : $0 }
        addedEntries = c.lossyArray(QueueEntry.self, .addedEntries)
        removedEntries = c.lossyArray(QueueEntry.self, .removedEntries)
        changedEntries = c.lossyArray(QueueEntry.self, .changedEntries)
        entries = c.lossy([Lossy<QueueEntry>].self, .entries).map { $0.compactMap(\.value) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(added, forKey: .added)
        try c.encode(removed, forKey: .removed)
        try c.encode(changed, forKey: .changed)
        try c.encode(CoreDate.format(checkedAt), forKey: .checkedAt)
        try c.encode(trigger, forKey: .trigger)
        try c.encodeIfPresent(problem, forKey: .problem)
        try c.encode(addedEntries, forKey: .addedEntries)
        try c.encode(removedEntries, forKey: .removedEntries)
        try c.encode(changedEntries, forKey: .changedEntries)
        try c.encodeIfPresent(entries, forKey: .entries)
    }
}

public struct SetupProblem: Codable, Hashable, Sendable, CustomStringConvertible {
    public var code: String
    public var message: String
    public var description: String { message }

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

public struct RunnerStatus: Codable, Equatable, Sendable {
    public var id: String
    public var displayName: String
    public var enabled: Bool
    public var problems: [SetupProblem]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        displayName = c.lossy(String.self, .displayName) ?? id
        enabled = c.lossy(Bool.self, .enabled) ?? false
        problems = c.lossyArray(SetupProblem.self, .problems)
    }
}

public struct StatusResponse: Codable, Equatable, Sendable {
    enum CodingKeys: String, CodingKey {
        case version, activeVault, problems, queueCount, pendingApprovals, runningJobs, nextBatchAt, runners
        case lastQueueScanAt, nextQueueScanAt
    }

    public var version: String
    public var activeVault: VaultProfile?
    public var problems: [SetupProblem]
    public var queueCount: Int
    public var pendingApprovals: Int
    public var runningJobs: Int
    public var nextBatchAt: Date?
    public var runners: [RunnerStatus]
    /// v5: the last full queue scan of any kind ("checked at 3:41 AM"); the next queue check (nil when Off or on an older core).
    public var lastQueueScanAt: Date?
    public var nextQueueScanAt: Date?

    public init(version: String = "", activeVault: VaultProfile? = nil, problems: [SetupProblem] = [], queueCount: Int = 0,
                pendingApprovals: Int = 0, runningJobs: Int = 0, nextBatchAt: Date? = nil, runners: [RunnerStatus] = [],
                lastQueueScanAt: Date? = nil, nextQueueScanAt: Date? = nil) {
        self.version = version
        self.activeVault = activeVault
        self.problems = problems
        self.queueCount = queueCount
        self.pendingApprovals = pendingApprovals
        self.runningJobs = runningJobs
        self.nextBatchAt = nextBatchAt
        self.runners = runners
        self.lastQueueScanAt = lastQueueScanAt
        self.nextQueueScanAt = nextQueueScanAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = c.lossy(String.self, .version) ?? ""
        activeVault = c.lossy(VaultProfile.self, .activeVault)
        problems = c.lossyArray(SetupProblem.self, .problems)
        queueCount = c.lossyInt(.queueCount) ?? 0
        pendingApprovals = c.lossyInt(.pendingApprovals) ?? 0
        runningJobs = c.lossyInt(.runningJobs) ?? 0
        nextBatchAt = c.lossyDate(.nextBatchAt)
        runners = c.lossyArray(RunnerStatus.self, .runners)
        lastQueueScanAt = c.lossyDate(.lastQueueScanAt)
        nextQueueScanAt = c.lossyDate(.nextQueueScanAt)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encodeIfPresent(activeVault, forKey: .activeVault)
        try c.encode(problems, forKey: .problems)
        try c.encode(queueCount, forKey: .queueCount)
        try c.encode(pendingApprovals, forKey: .pendingApprovals)
        try c.encode(runningJobs, forKey: .runningJobs)
        try c.encodeIfPresent(nextBatchAt.map(CoreDate.format), forKey: .nextBatchAt)
        try c.encode(runners, forKey: .runners)
        try c.encodeIfPresent(lastQueueScanAt.map(CoreDate.format), forKey: .lastQueueScanAt)
        try c.encodeIfPresent(nextQueueScanAt.map(CoreDate.format), forKey: .nextQueueScanAt)
    }
}

// MARK: - Notes and labels

public struct NoteImage: Codable, Hashable, Sendable {
    public enum Mode: String, Codable, Sendable { case keep, extract }
    public var path: String
    public var mode: Mode
    public init(path: String, mode: Mode = .keep) { self.path = path; self.mode = mode }
}

/// `POST /v1/images/extract` answer: Markdown read from the image ('' = no text) and the model label ("Haiku").
public struct ExtractImageTextResult: Codable, Hashable, Sendable {
    public var text: String
    public var model: String
    public init(text: String, model: String) { self.text = text; self.model = model }
}

public struct AddNoteRequest: Codable, Hashable, Sendable {
    public enum Suggest: String, Codable, Sendable { case wait, background, none }
    public enum Origin: String, Codable, Sendable { case app, cli }
    public var title: String
    public var text: String
    public var images: [NoteImage]?
    public var source: String?
    public var sourceRef: String?
    public var vaultPath: String?
    public var labels: [String]?
    public var suggest: Suggest?
    public var origin: Origin?

    public init(title: String, text: String, images: [NoteImage]? = nil, source: String? = nil, sourceRef: String? = nil,
                vaultPath: String? = nil, labels: [String]? = nil, suggest: Suggest? = nil, origin: Origin? = .app) {
        self.title = title
        self.text = text
        self.images = images
        self.source = source
        self.sourceRef = sourceRef
        self.vaultPath = vaultPath
        self.labels = labels
        self.suggest = suggest
        self.origin = origin
    }
}

public struct LabelSuggestion: Codable, Hashable, Sendable {
    public var name: String
    public var existing: Bool

    public init(name: String, existing: Bool) { self.name = name; self.existing = existing }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        existing = c.lossy(Bool.self, .existing) ?? false
    }
}

public struct AddNoteResult: Codable, Equatable, Sendable {
    public var queued: [String]
    public var notePath: String
    public var requestID: String
    public var suggestedLabels: [LabelSuggestion]?
    public var suggestError: String?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        queued = c.lossyArray(String.self, .queued)
        notePath = c.lossy(String.self, .notePath) ?? ""
        requestID = c.lossy(String.self, .requestID) ?? ""
        suggestedLabels = c.lossy([Lossy<LabelSuggestion>].self, .suggestedLabels)?.compactMap(\.value)
        suggestError = c.lossy(String.self, .suggestError)
    }
}

public struct LabelCount: Codable, Hashable, Sendable {
    public var name: String
    public var count: Int
    public var unconfirmed: Int

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        count = c.lossyInt(.count) ?? 0
        unconfirmed = c.lossyInt(.unconfirmed) ?? 0
    }
}

public struct LabelReviewItem: Codable, Hashable, Sendable {
    public var path: String
    public var title: String
    public var labels: [String]
    public var origin: String?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        title = c.lossy(String.self, .title) ?? path
        labels = c.lossyArray(String.self, .labels)
        origin = c.lossy(String.self, .origin)
    }
}

public struct UnlabeledPage: Codable, Hashable, Sendable {
    public var path: String
    public var title: String

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        title = c.lossy(String.self, .title) ?? path
    }
}

public struct LabelReview: Codable, Equatable, Sendable {
    public var toReview: [LabelReviewItem]
    public var unlabeled: [UnlabeledPage]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        toReview = c.lossyArray(LabelReviewItem.self, .toReview)
        unlabeled = c.lossyArray(UnlabeledPage.self, .unlabeled)
    }
}

public struct LabeledPage: Codable, Hashable, Sendable {
    public var path: String
    public var labels: [String]
    public init(path: String, labels: [String]) { self.path = path; self.labels = labels }
}

public struct LabelNoteResult: Codable, Equatable, Sendable {
    public var notePath: String
    public var labels: [String]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        notePath = c.lossy(String.self, .notePath) ?? ""
        labels = c.lossyArray(String.self, .labels)
    }
}

// MARK: - Ask

public struct AskRequest: Codable, Hashable, Sendable {
    public var question: String
    public var conversationID: String?
    public var selection: ModelSelection?
    public var labels: [String]?
    public var sources: [String]?
    public var vaultPath: String?
    public var labelMatch: LabelMatch?
    public var includeUnconfirmed: Bool?

    public init(question: String, conversationID: String? = nil, selection: ModelSelection? = nil, labels: [String]? = nil,
                sources: [String]? = nil, vaultPath: String? = nil, labelMatch: LabelMatch? = nil, includeUnconfirmed: Bool? = nil) {
        self.question = question
        self.conversationID = conversationID
        self.selection = selection
        self.labels = labels
        self.sources = sources
        self.vaultPath = vaultPath
        self.labelMatch = labelMatch
        self.includeUnconfirmed = includeUnconfirmed
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        question = c.lossy(String.self, .question) ?? ""
        conversationID = c.lossy(String.self, .conversationID)
        selection = c.lossy(ModelSelection.self, .selection)
        labels = c.lossy([String].self, .labels)
        sources = c.lossy([String].self, .sources)
        vaultPath = c.lossy(String.self, .vaultPath)
        labelMatch = c.lossy(LabelMatch.self, .labelMatch)
        includeUnconfirmed = c.lossy(Bool.self, .includeUnconfirmed)
    }
}

public struct AskCitation: Codable, Hashable, Sendable {
    public var n: Int
    public var path: String
    public var title: String

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        n = c.lossyInt(.n) ?? 0
        path = c.lossy(String.self, .path) ?? ""
        title = c.lossy(String.self, .title) ?? path
    }
}

public struct AskResponse: Codable, Equatable, Sendable {
    public var conversationID: String
    public var answer: String
    public var citations: [AskCitation]
    public var gaps: [String]
    public var selection: ModelSelection?
    public var costUSD: Double
    public var notices: [String]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        conversationID = c.lossy(String.self, .conversationID) ?? ""
        answer = c.lossy(String.self, .answer) ?? ""
        citations = c.lossyArray(AskCitation.self, .citations)
        gaps = c.lossyArray(String.self, .gaps)
        selection = c.lossy(ModelSelection.self, .selection)
        costUSD = c.lossyDouble(.costUSD) ?? 0
        notices = c.lossyArray(String.self, .notices)
    }
}

public struct AskTurn: Codable, Equatable, Sendable {
    enum CodingKeys: String, CodingKey { case askedAt, request, response }

    public var askedAt: Date
    public var request: AskRequest
    public var response: AskResponse

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        askedAt = c.lossyDate(.askedAt) ?? .distantPast
        request = try c.decode(AskRequest.self, forKey: .request)
        response = try c.decode(AskResponse.self, forKey: .response)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(CoreDate.format(askedAt), forKey: .askedAt)
        try c.encode(request, forKey: .request)
        try c.encode(response, forKey: .response)
    }
}

public struct AskConversationSummary: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var vaultPath: String
    public var createdAt: Date
    public var updatedAt: Date
    public var pinned: Bool
    public var turnCount: Int

    enum CodingKeys: String, CodingKey { case id, title, vaultPath, createdAt, updatedAt, pinned, turnCount }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = c.lossy(String.self, .title) ?? ""
        vaultPath = c.lossy(String.self, .vaultPath) ?? ""
        createdAt = c.lossyDate(.createdAt) ?? .distantPast
        updatedAt = c.lossyDate(.updatedAt) ?? createdAt
        pinned = c.lossy(Bool.self, .pinned) ?? false
        turnCount = c.lossyInt(.turnCount) ?? 0
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(vaultPath, forKey: .vaultPath)
        try c.encode(CoreDate.format(createdAt), forKey: .createdAt)
        try c.encode(CoreDate.format(updatedAt), forKey: .updatedAt)
        try c.encode(pinned, forKey: .pinned)
        try c.encode(turnCount, forKey: .turnCount)
    }
}

public struct AskConversation: Codable, Equatable, Identifiable, Sendable {
    public var summary: AskConversationSummary
    public var turns: [AskTurn]
    public var id: String { summary.id }

    enum CodingKeys: String, CodingKey { case turns }

    public init(from decoder: Decoder) throws {
        summary = try AskConversationSummary(from: decoder)
        turns = try decoder.container(keyedBy: CodingKeys.self).lossyArray(AskTurn.self, .turns)
    }

    public func encode(to encoder: Encoder) throws {
        try summary.encode(to: encoder)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(turns, forKey: .turns)
    }
}

// MARK: - Runners

public struct ModelOption: Codable, Hashable, Sendable {
    public var id: String
    public var label: String
    public var note: String?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = c.lossy(String.self, .label) ?? id
        note = c.lossy(String.self, .note)
    }
}

public struct RunnerSecret: Codable, Hashable, Sendable {
    public var name: String
    public var label: String
    public var isSet: Bool

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        label = c.lossy(String.self, .label) ?? name
        isSet = c.lossy(Bool.self, .isSet) ?? false
    }
}

public struct RunnerInfo: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var displayName: String
    public var kind: String
    public var enabled: Bool
    /// Raw capability names; unknown ones from a newer core are kept as strings.
    public var capabilities: [String]
    public var tasks: [AITask]
    public var models: [ModelOption]
    public var effortLevels: [String]
    public var defaultModel: String
    public var problems: [SetupProblem]
    public var secrets: [RunnerSecret]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        displayName = c.lossy(String.self, .displayName) ?? id
        kind = c.lossy(String.self, .kind) ?? "agent"
        enabled = c.lossy(Bool.self, .enabled) ?? false
        capabilities = c.lossyArray(String.self, .capabilities)
        tasks = c.lossyArray(AITask.self, .tasks)
        models = c.lossyArray(ModelOption.self, .models)
        effortLevels = c.lossyArray(String.self, .effortLevels)
        defaultModel = c.lossy(String.self, .defaultModel) ?? ""
        problems = c.lossyArray(SetupProblem.self, .problems)
        secrets = c.lossyArray(RunnerSecret.self, .secrets)
    }
}

// MARK: - Events

/// One server-sent event from `GET /v1/events`. Unknown types are kept as `.unknown`.
public enum CoreEvent: Equatable, Sendable {
    case queue([QueueEntry])
    case job(Job)
    /// A job removed from the list (`DELETE /v1/jobs/:id`; job event with `deleted: true`).
    case jobDeleted(id: String)
    case settings(Settings)
    case log(level: String, message: String)
    case labelSuggestions(requestID: String, notePath: String, labels: [LabelSuggestion], error: String?)
    case conversation(AskConversationSummary, deleted: Bool)
    case progress(CoreProgress)
    /// An action item changed (`deleted`: removed for good, Delete forever or an Undo).
    case action(ActionItem, deleted: Bool)
    /// v3: a connection changed (signed in, expired, disconnected).
    case connection(ConnectionInfo)
    /// v4: a collector changed (`deleted`: removed).
    case collector(Collector, deleted: Bool)
    case collectorRunStarted(CollectorRun)
    /// Live output of a script run: the text added since the last event.
    case collectorRunOutput(collectorId: String, runId: String, stream: String, text: String)
    case collectorRunFinished(CollectorRun)
    /// v6: a package install of a managed script started / printed output / finished.
    case collectorInstallStarted(CollectorInstall)
    case collectorInstallOutput(collectorId: String, installId: String, text: String)
    case collectorInstallFinished(CollectorInstall)
    /// v5: a full queue scan finished (Refresh, the window-active scan or the queue check).
    case queueScanned(QueueScanResult)
    /// v6: a line was added to the activity log.
    case activity(ActivityEntry)
    /// v7: a step of a job's live log, new or changed (same id = the same line).
    case jobStep(jobId: String, step: JobStep)
    case unknown(type: String)

    private enum Keys: String, CodingKey {
        case type, entries, job, settings, level, message, requestID, notePath, labels, error, conversation, deleted, progress, action, connection
        case collector, run, collectorId, runId, stream, text, result, entry
        case install, installId
        case jobId, step
    }

    /// Decodes the JSON of one `data:` line.
    public static func decode(_ data: Data) throws -> CoreEvent {
        try JSONDecoder.core.decode(Wire.self, from: data).event
    }

    private struct Wire: Decodable {
        let event: CoreEvent
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            let type = try c.decode(String.self, forKey: .type)
            switch type {
            case "queue": event = .queue(c.lossyArray(QueueEntry.self, .entries))
            case "job":
                let job = try c.decode(Job.self, forKey: .job)
                event = (c.lossy(Bool.self, .deleted) ?? false) ? .jobDeleted(id: job.id) : .job(job)
            case "settings": event = .settings(try c.decode(Settings.self, forKey: .settings))
            case "log": event = .log(level: c.lossy(String.self, .level) ?? "info", message: c.lossy(String.self, .message) ?? "")
            case "labelSuggestions":
                event = .labelSuggestions(requestID: c.lossy(String.self, .requestID) ?? "", notePath: c.lossy(String.self, .notePath) ?? "",
                                          labels: c.lossyArray(LabelSuggestion.self, .labels), error: c.lossy(String.self, .error))
            case "conversation":
                event = .conversation(try c.decode(AskConversationSummary.self, forKey: .conversation),
                                      deleted: c.lossy(Bool.self, .deleted) ?? false)
            case "progress": event = .progress(try c.decode(CoreProgress.self, forKey: .progress))
            case "action":
                event = .action(try c.decode(ActionItem.self, forKey: .action), deleted: c.lossy(Bool.self, .deleted) ?? false)
            case "connection": event = .connection(try c.decode(ConnectionInfo.self, forKey: .connection))
            case "collector.changed":
                event = .collector(try c.decode(Collector.self, forKey: .collector), deleted: c.lossy(Bool.self, .deleted) ?? false)
            case "collector.run.started": event = .collectorRunStarted(try c.decode(CollectorRun.self, forKey: .run))
            case "collector.run.finished": event = .collectorRunFinished(try c.decode(CollectorRun.self, forKey: .run))
            case "collector.run.output":
                event = .collectorRunOutput(collectorId: c.lossy(String.self, .collectorId) ?? "", runId: c.lossy(String.self, .runId) ?? "",
                                            stream: c.lossy(String.self, .stream) ?? "stdout", text: c.lossy(String.self, .text) ?? "")
            case "collector.install.started": event = .collectorInstallStarted(try c.decode(CollectorInstall.self, forKey: .install))
            case "collector.install.finished": event = .collectorInstallFinished(try c.decode(CollectorInstall.self, forKey: .install))
            case "collector.install.output":
                event = .collectorInstallOutput(collectorId: c.lossy(String.self, .collectorId) ?? "", installId: c.lossy(String.self, .installId) ?? "",
                                                text: c.lossy(String.self, .text) ?? "")
            case "queue.scanned": event = .queueScanned(try c.decode(QueueScanResult.self, forKey: .result))
            // An entry this build can't read is a line it doesn't show, not a broken stream.
            case "activity": event = (try? c.decode(ActivityEntry.self, forKey: .entry)).map(CoreEvent.activity) ?? .unknown(type: type)
            case "job.step":
                if let step = try? c.decode(JobStep.self, forKey: .step), let jobId = c.lossy(String.self, .jobId) {
                    event = .jobStep(jobId: jobId, step: step)
                } else {
                    event = .unknown(type: type)
                }
            default: event = .unknown(type: type)
            }
        }
    }
}

// MARK: - UI helpers that are not state

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

    public static func shortName(_ id: String) -> String {
        for name in ["Opus", "Sonnet", "Haiku", "Fable"] where id.lowercased().contains(name.lowercased()) { return name }
        return id
    }
}

/// A vault page for the note picker (`GET /v1/pages`).
public struct PageRef: Codable, Hashable, Sendable, Identifiable {
    public var path: String
    public var title: String
    public var id: String { path }

    public init(path: String, title: String) {
        self.path = path
        self.title = title
    }

    /// The file name without `.md`: what Obsidian resolves `[[...]]` by.
    public var linkTarget: String {
        let name = (path as NSString).lastPathComponent
        return name.lowercased().hasSuffix(".md") ? String(name.dropLast(3)) : name
    }

    /// `[[Name]]`, or `[[Name|Title]]` when the title differs from the file name.
    public var wikilink: String {
        let target = linkTarget
        return target.caseInsensitiveCompare(title) == .orderedSame || title.isEmpty ? "[[\(target)]]" : "[[\(target)|\(title)]]"
    }
}
