import AppKit
import SwiftUI
import DistillKit

/// Fixture data and screens for the Ask, quick ask, hover menu and loading
/// snapshots (`--snapshot`). Nothing here talks to a core.
@MainActor
enum AskFixtures {
    static let runners: [RunnerInfo] = [
        RunnerInfo(id: "claude-code", displayName: "Claude Code", tasks: [.ingest, .ask, .labelSuggest],
                   models: [ModelOption(id: "sonnet", label: "Sonnet (latest)"), ModelOption(id: "opus", label: "Opus (latest)"),
                            ModelOption(id: "haiku", label: "Haiku (latest)")],
                   effortLevels: ["low", "medium", "high", "max"], defaultModel: "sonnet"),
    ]

    static let answer = "Your notes say sencha brews best at **70–80 °C**; boiling water pulls out bitter catechins [1]. Gyokuro is shade-grown about three weeks, which raises its umami [1], but your vault has **no temperature for gyokuro** itself."

    static func load(_ ask: AskModel, vault: String) {
        ask.runners = runners
        let now = Date()
        ask.conversations = [
            AskConversationSummary(id: "c1", title: "Green tea water temperature", vaultPath: vault, createdAt: now.addingTimeInterval(-300), turnCount: 1),
            AskConversationSummary(id: "c2", title: "What did I add this week?", vaultPath: vault, createdAt: now.addingTimeInterval(-86_400), pinned: true, turnCount: 2),
            AskConversationSummary(id: "c3", title: "Oolong oxidation range", vaultPath: vault, createdAt: now.addingTimeInterval(-3 * 86_400), turnCount: 1),
        ]
    }

    static func answered(_ thread: AskThread) {
        thread.reset(filter: AskFilter())
        thread.filter.addLabel("tea")
        thread.filter.addLabel("gyokuro")
        thread.conversationID = "c1"
        thread.selection = ModelSelection(runnerID: "claude-code", model: "sonnet", effort: "medium")
        var request = AskRequest(question: "How hot should the water be for green tea, and does it differ for gyokuro?", conversationID: "c1")
        thread.filter.apply(to: &request)
        let response = AskResponse(
            conversationID: "c1", answer: answer,
            citations: [AskCitation(n: 1, path: "wiki/sources/Brewing Green Tea.md", title: "Brewing Green Tea"),
                        AskCitation(n: 2, path: "wiki/notes/Tea club thread.md", title: "Tea club thread")],
            gaps: ["nothing in your vault on gyokuro water temperature. Drop a source in the queue to fill it."],
            selection: thread.selection, costUSD: 0.03, notices: ["Limited to 15 pages (3 unconfirmed)."])
        thread.entries = [AskEntry(question: request.question, askedAt: Date(), request: request, response: response, duration: 4)]
    }

    static func loading(_ thread: AskThread, question: String, model: String = "sonnet", effort: String = "medium", seconds: TimeInterval = 14) {
        thread.reset(filter: AskFilter())
        thread.filter.addLabel("tea")
        thread.filter.addLabel("gyokuro")
        thread.selection = ModelSelection(runnerID: "claude-code", model: model, effort: effort)
        var request = AskRequest(question: question, selection: thread.selection)
        thread.filter.apply(to: &request)
        thread.pending = PendingQuestion(question: question, startedAt: Date().addingTimeInterval(-seconds), request: request, status: .running)
        thread.inFlightID = "fixture"
    }
}

/// Main window on the Ask screen, for snapshots.
struct AskSnapshotScreen: View {
    @EnvironmentObject var engine: AppModel
    var body: some View {
        HStack(spacing: 0) {
            Sidebar(section: .constant(.ask), selectedJob: .constant(nil), openSettings: {})
            AskScreen().frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.window)
        }
        .environmentObject(engine.ask)
        .foregroundStyle(Theme.ink)
    }
}

extension Snapshot {
    /// ask.png, ask-loading.png, ask-stopped.png, quickask.png, menu.png, queue-loading.png, review-loading.png.
    static func renderV3(engine: AppModel, size: CGSize, outDir: URL) {
        let ask = engine.ask
        AskFixtures.load(ask, vault: engine.activeVault?.path ?? "/Research")
        AskFixtures.answered(ask.main)
        render(AskSnapshotScreen().environmentObject(engine), size: size, to: outDir.appendingPathComponent("ask.png"))
        AskFixtures.loading(ask.main, question: "How hot should the water be for green tea, and does it differ for gyokuro?")
        render(AskSnapshotScreen().environmentObject(engine), size: size, to: outDir.appendingPathComponent("ask-loading.png"))
        ask.main.pending?.status = .stopped
        render(AskSnapshotScreen().environmentObject(engine), size: size, to: outDir.appendingPathComponent("ask-stopped.png"))
    }
}

/// A grey desk with the flask near the bottom right, like the canvas panels.
struct DeskSnapshot<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        ZStack { Color(hex: 0xDCD9D2); content }
    }
}
