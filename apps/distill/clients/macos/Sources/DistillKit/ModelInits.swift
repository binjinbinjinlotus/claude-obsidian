import Foundation

// Public memberwise initializers for contract types whose `init(from:)` is
// custom (fixtures, previews, tests, and values the app builds itself).

extension SourceGroup {
    public init(id: String, label: String, sources: [SourceDefinition]) {
        self.id = id; self.label = label; self.sources = sources
    }

    /// `DEFAULT_SOURCE_TAXONOMY` in contracts.ts (used when settings have none).
    public static let defaultTaxonomy: [SourceGroup] = [
        SourceGroup(id: "discussion", label: "Discussion", sources: [
            SourceDefinition(id: "slack", label: "Slack"), SourceDefinition(id: "meeting", label: "Meeting"),
            SourceDefinition(id: "github-review", label: "GitHub review"), SourceDefinition(id: "jira-comment", label: "Jira comment"),
            SourceDefinition(id: "email", label: "Email"), SourceDefinition(id: "in-person", label: "In person"),
        ]),
        SourceGroup(id: "reference", label: "Reference", sources: [
            SourceDefinition(id: "web-page", label: "Web page"), SourceDefinition(id: "document", label: "Document"), SourceDefinition(id: "paper", label: "Paper"),
        ]),
        SourceGroup(id: "personal", label: "Personal", sources: [
            SourceDefinition(id: "remember-this", label: "Remember this"), SourceDefinition(id: "idea", label: "Idea"),
        ]),
    ]
}

extension LabelingPreferences {
    public init(autoLabelQueueFolder: Bool? = nil, cliFallbackToAI: Bool? = nil) {
        self.autoLabelQueueFolder = autoLabelQueueFolder; self.cliFallbackToAI = cliFallbackToAI
    }
}

extension LabelCount {
    public init(name: String, count: Int, unconfirmed: Int = 0) {
        self.name = name; self.count = count; self.unconfirmed = unconfirmed
    }
}

extension LabelReviewItem {
    public init(path: String, title: String, labels: [String], origin: String? = nil) {
        self.path = path; self.title = title; self.labels = labels; self.origin = origin
    }
}

extension ModelOption {
    public init(id: String, label: String, note: String? = nil) { self.id = id; self.label = label; self.note = note }
}

extension RunnerSecret {
    public init(name: String, label: String, isSet: Bool) { self.name = name; self.label = label; self.isSet = isSet }
}

extension RunnerInfo {
    public init(id: String, displayName: String, kind: String = "agent", enabled: Bool = true, capabilities: [String] = [],
                tasks: [AITask] = [], models: [ModelOption] = [], effortLevels: [String] = [], defaultModel: String = "",
                problems: [SetupProblem] = [], secrets: [RunnerSecret] = []) {
        self.id = id; self.displayName = displayName; self.kind = kind; self.enabled = enabled
        self.capabilities = capabilities; self.tasks = tasks; self.models = models; self.effortLevels = effortLevels
        self.defaultModel = defaultModel; self.problems = problems; self.secrets = secrets
    }
}

extension AskCitation {
    public init(n: Int, path: String, title: String) { self.n = n; self.path = path; self.title = title }
}

extension AskResponse {
    public init(conversationID: String, answer: String, citations: [AskCitation] = [], gaps: [String] = [],
                selection: ModelSelection? = nil, costUSD: Double = 0, notices: [String] = []) {
        self.conversationID = conversationID; self.answer = answer; self.citations = citations; self.gaps = gaps
        self.selection = selection; self.costUSD = costUSD; self.notices = notices
    }
}

extension AskTurn {
    public init(askedAt: Date, request: AskRequest, response: AskResponse) {
        self.askedAt = askedAt; self.request = request; self.response = response
    }
}

extension AskConversationSummary {
    public init(id: String, title: String, vaultPath: String = "", createdAt: Date = Date(), updatedAt: Date? = nil,
                pinned: Bool = false, turnCount: Int = 0) {
        self.id = id; self.title = title; self.vaultPath = vaultPath; self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt; self.pinned = pinned; self.turnCount = turnCount
    }
}

extension AskConversation {
    public init(summary: AskConversationSummary, turns: [AskTurn]) { self.summary = summary; self.turns = turns }
}
