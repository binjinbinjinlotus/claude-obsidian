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

        // Hover menu beside the flask.
        render(DeskSnapshot {
            HStack(alignment: .bottom, spacing: -12) {
                HoverMenuView(alignTrailing: true, bottomAligned: true) { _ in }.frame(width: 236, height: 228)
                FloatingFace(dropState: DropState()).environmentObject(engine)
            }
            .padding(30).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        }, size: CGSize(width: 480, height: 320), to: outDir.appendingPathComponent("menu.png"))

        // Quick ask: answered (all notes), limited by labels, and answering.
        let quickSize = CGSize(width: 460, height: 420)
        let views: [(String, (AskThread) -> Void)] = [
            ("quickask.png", { t in
                t.reset(filter: AskFilter())
                t.selection = ModelSelection(runnerID: "claude-code", model: "sonnet", effort: "medium")
                let r = AskResponse(conversationID: "q1", answer: "70–80 °C. Boiling water pulls out bitter catechins [1].",
                                    citations: [AskCitation(n: 1, path: "wiki/sources/Brewing Green Tea.md", title: "Brewing Green Tea")])
                t.entries = [AskEntry(question: "Best water temp for sencha?", askedAt: Date(), request: AskRequest(question: "Best water temp for sencha?"), response: r)]
            }),
            ("quickask-limited.png", { t in
                t.reset(filter: AskFilter())
                t.filter.addLabel("project-x"); t.filter.addLabel("incidents"); t.filter.addSource("slack")
                t.selection = ModelSelection(runnerID: "claude-code", model: "haiku", effort: "low")
                let r = AskResponse(conversationID: "q2", answer: "Cap retries at 3 with jittered backoff; stop on 503 [1].",
                                    citations: [AskCitation(n: 1, path: "wiki/notes/Retry policy.md", title: "Retry policy")],
                                    notices: ["Limited to 6 pages (2 unconfirmed)."])
                t.entries = [AskEntry(question: "What did we decide about retries?", askedAt: Date(), request: AskRequest(question: "What did we decide about retries?"), response: r)]
            }),
            ("quickask-loading.png", { t in
                AskFixtures.loading(t, question: "Best water temp for sencha?", model: "haiku", effort: "low", seconds: 6)
                t.filter = AskFilter()
            }),
        ]
        for (name, setup) in views {
            setup(ask.quick)
            render(DeskSnapshot {
                ZStack(alignment: .bottomTrailing) {
                    QuickAskCard(thread: ask.quick, close: {}, continueInDistill: {})
                        .padding(.trailing, 40).padding(.bottom, 66)
                    FloatingFace(dropState: DropState()).environmentObject(engine).scaleEffect(0.7)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
            .environmentObject(engine).environmentObject(ask), size: quickSize, to: outDir.appendingPathComponent(name))
        }
        renderLoadingScreens(engine: engine, size: size, outDir: outDir)
    }
}

extension Snapshot {
    /// queue-loading.png (batch running, from a progress event), review-loading.png (applying), starting.png.
    static func renderLoadingScreens(engine: AppModel, size: CGSize, outDir: URL) {
        guard let vault = engine.activeVault?.path else { return }
        let started = Date().addingTimeInterval(-112)
        let batch = Job(id: "job-snapshot-batch", vaultPath: vault,
                        files: ["inbox/Gyokuro at 60 °C.md", "inbox/Screenshot 15.32.12.png", "inbox/gongfu-brewing-guide.pdf"],
                        model: "sonnet", state: .running, createdAt: started, updatedAt: started)
        let savedJobs = engine.jobs
        engine.jobs = [batch] + savedJobs.filter { $0.state != .running }
        engine.progress[batch.id] = CoreProgress(key: batch.id, kind: "batch", message: "Reading 3 sources",
                                                 steps: ["Moved to inbox", "Read sources", "Drafting page changes", "Ready for review"],
                                                 stepIndex: 2, startedAt: started, runnerID: "claude-code", model: "sonnet")
        render(QueueSnapshotScreen().environmentObject(engine), size: CGSize(width: size.width, height: 800),
               to: outDir.appendingPathComponent("queue-loading.png"))
        engine.jobs = savedJobs
        engine.progress = [:]

        if let job = engine.pendingApprovals.first {
            engine.pendingActions["approve:\(job.id)"] = Date().addingTimeInterval(-3)
            render(HStack(spacing: 0) {
                Sidebar(section: .constant(.review), selectedJob: .constant(job.id), openSettings: {})
                JobDetailView(jobID: job.id).frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.window)
            }.foregroundStyle(Theme.ink).environmentObject(engine), size: size, to: outDir.appendingPathComponent("review-loading.png"))
            engine.pendingActions = [:]
        }
    }
}

/// Main window on the Queue screen, for snapshots.
struct QueueSnapshotScreen: View {
    @EnvironmentObject var engine: AppModel
    var body: some View {
        HStack(spacing: 0) {
            Sidebar(section: .constant(.queue), selectedJob: .constant(nil), openSettings: {})
            QueueView().frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.window)
        }
        .foregroundStyle(Theme.ink)
    }
}

/// A grey desk with the flask near the bottom right, like the canvas panels.
struct DeskSnapshot<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        ZStack { Color(hex: 0xDCD9D2); content }
    }
}
