import AppKit
import SwiftUI
import DistillKit

/// `--snapshot` fixtures for the quick windows, Write a note sizing and Queue
/// rows (canvas: "Quick windows: size, growth and scrolling", "Write a note:
/// size and scrolling", "Queue rows: every state"). One call from Snapshot.run.
@MainActor
enum WindowsSnapshot {
    /// The fake screen the quick windows open on (its visible frame, in points).
    static let screen = CGRect(x: 0, y: 0, width: 760, height: 620)

    static func run(engine: AppModel, outDir: URL) {
        currentOut = outDir
        let savedQueue = engine.queued, savedJobs = engine.jobs
        let savedDraft = engine.notes.drafts[.quick], savedStep = engine.notes.steps[.quick]
        let savedCompose = engine.notes.drafts[.compose], savedComposeStep = engine.notes.steps[.compose]
        defer {
            engine.queued = savedQueue; engine.jobs = savedJobs
            engine.notes.drafts[.quick] = savedDraft; engine.notes.steps[.quick] = savedStep
            engine.notes.drafts[.compose] = savedCompose; engine.notes.steps[.compose] = savedComposeStep
        }
        quickWindows(engine: engine, outDir: outDir)
        compose(engine: engine, outDir: outDir)
        queueRows(engine: engine, outDir: outDir)
    }

    // MARK: Quick windows

    private static let lines = [
        "Shop recommended 60 °C, 2 min first steep.", "Second steep 30 s, third 1 min.", "Use soft water; our tap is fine.",
        "Mei prefers 50 °C for a sweeter cup.", "Buy the 50 g tin next time.", "Card attached for the exact grams.",
        "Ask the shop about the spring harvest.", "Kyusu holds 180 ml; use 6 g of leaf.",
    ]

    private static func quickWindows(engine: AppModel, outDir: URL) {
        let notes = engine.notes
        notes.steps[.quick] = nil
        notes.addErrors[.quick] = nil
        let floor = QuickWindowGeometry.defaultSize
        let topLeft = QuickWindowGeometry.openTopLeft(width: floor.width, visible: screen)
        let limit = QuickWindowGeometry.fittedHeight(desired: 10_000, floor: floor.height, top: topLeft.y, visible: screen)

        // Opens centered, top 30 % down: a short note.
        var d = ComposeDraft()
        d.title = "Gyokuro at 60 °C"
        d.text = lines.prefix(2).joined(separator: "\n")
        notes.drafts[.quick] = d
        render(desk(topLeft: topLeft) { QuickNoteView(close: {}) }.environmentObject(engine), "quicknote-centered.png")

        // Typing grows it downward; the top edge stays. Long title wraps to 2 lines.
        d.title = "Notes from the Kyoto tea shop visit with Mei and the owner"
        d.text = lines.prefix(6).joined(separator: "\n")
        d.text += "\n![[brewing-card.png]]"
        d.images = [DraftImage(url: URL(fileURLWithPath: "/nonexistent/brewing-card.png"))]
        notes.drafts[.quick] = d
        render(desk(topLeft: topLeft) { QuickNoteView(close: {}) }.environmentObject(engine), "quicknote-grown.png")

        // A long paste with images and an error: at the limit (8 pt above the bottom), the middle scrolls.
        d.title = "Gyokuro at 60 °C"
        d.text = (lines + lines + lines).joined(separator: "\n")
        d.images = ["card-1.png", "card-2.png", "card-3.png"].map { DraftImage(url: URL(fileURLWithPath: "/nonexistent/\($0)")) }
        d.text += "\n" + d.images.map { ComposeDraft.embed($0.name) }.joined(separator: "\n")
        notes.drafts[.quick] = d
        notes.addErrors[.quick] = "Couldn't queue the note: Distill core is not running."
        render(desk(topLeft: topLeft) {
            QuickNoteView(close: {}, snapshotHeight: limit).environment(\.snapshotOverflow, true)
        }.environmentObject(engine), "quicknote-limit.png")
        notes.addErrors[.quick] = nil

        // Quick ask: a long answer at the limit; only the answer scrolls.
        let ask = engine.ask
        AskFixtures.load(ask, vault: engine.activeVault?.path ?? "/Research")
        let t = ask.quick
        t.reset(filter: AskFilter())
        t.selection = ModelSelection(runnerID: "claude-code", model: "haiku", effort: "low")
        let answer = (lines + lines + lines + lines).joined(separator: " ") + " [1]"
        let r = AskResponse(conversationID: "q1", answer: answer,
                            citations: [AskCitation(n: 1, path: "wiki/sources/Brewing Green Tea.md", title: "Brewing Green Tea")])
        t.entries = [AskEntry(question: "Best water temp for sencha?", askedAt: Date(),
                              request: AskRequest(question: "Best water temp for sencha?"), response: r)]
        render(desk(topLeft: topLeft) {
            QuickAskCard(thread: t, close: {}, continueInDistill: {}, snapshotHeight: limit, snapshotWidth: QuickWindowGeometry.defaultWidth).environment(\.snapshotOverflow, true)
        }.environmentObject(engine).environmentObject(ask), "quickask-limit.png")
    }

    /// The fake screen: the window at its computed top-left, the "top edge" and "8 pt margin" guides.
    private static func desk<Content: View>(topLeft: CGPoint, @ViewBuilder content: () -> Content) -> some View {
        let top = screen.maxY - topLeft.y
        return ZStack(alignment: .topLeading) {
            Color(hex: 0xDCD9D2)
            guide("TOP EDGE STAYS HERE", y: top)
            guide("BOTTOM OF SCREEN · 8 pt margin", y: screen.height - QuickWindowGeometry.bottomMargin)
            content()
                .shadow(color: .black.opacity(0.22), radius: 18, y: 14)
                .offset(x: topLeft.x - screen.minX, y: top)
        }
        .frame(width: screen.width, height: screen.height, alignment: .topLeading)
        .clipped()
    }

    private static func guide(_ text: String, y: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(text).font(Theme.body(9, .bold)).tracking(0.6).foregroundStyle(Color(hex: 0x8C887F))
            Rectangle().fill(Color(hex: 0x8C887F)).frame(height: 1).opacity(0.6)
        }
        .padding(.leading, 10)
        .offset(y: y - 14)
    }

    // MARK: Write a note

    private static func compose(engine: AppModel, outDir: URL) {
        let notes = engine.notes
        notes.steps[.compose] = nil
        var d = ComposeDraft()
        d.title = "Kettle settings for the new tea set"
        d.text = "The gooseneck kettle has presets. 80 °C works for sencha;\nI set 60 °C for the gyokuro the shop recommended.\nSecond steep 30 s, third 1 min. Mei prefers 50 °C.\nBuy the 50 g tin next time, not the 100 g one."
        d.group = "discussion"
        d.source = "in-person"
        notes.drafts[.compose] = d
        // Taller window: the note box takes the extra height; source, images and buttons stay at the bottom.
        render(MainScreen(section: .queue) { ComposeScreen(mode: .constant(.note)) }.environmentObject(engine),
               size: CGSize(width: 1120, height: 900), "compose-tall.png")
        // The minimum window (900 × 600) with images inside the text: the box keeps 4 lines, the card scrolls.
        d.images = [DraftImage(url: URL(fileURLWithPath: "/nonexistent/brewing-card.png")),
                    DraftImage(url: URL(fileURLWithPath: "/nonexistent/tasting-setup.jpg")),
                    DraftImage(url: URL(fileURLWithPath: "/nonexistent/tin.jpg"))]
        d.text += "\n" + d.images.map { ComposeDraft.embed($0.name) }.joined(separator: "\n")
        notes.drafts[.compose] = d
        render(MainScreen(section: .queue) { ComposeScreen(mode: .constant(.note)) }.environmentObject(engine),
               size: CGSize(width: 900, height: 600), "compose-short.png")
    }

    // MARK: Queue rows

    private static func queueRows(engine: AppModel, outDir: URL) {
        let q = engine.activeVault?.queueURL.path ?? "/tmp/queue"
        let now = Date()
        func at(_ minutes: Double) -> Date { now.addingTimeInterval(minutes * 60) }
        engine.queued = [
            QueueEntry(path: "\(q)/Screenshot 2026-10-02 030432.png", modified: at(-2), size: 36_000, settled: false, readyAt: at(8)),
            QueueEntry(path: "\(q)/Clipping 2026-10-02 030900.md", modified: at(-1), size: 4_000, settled: false, readyAt: at(9),
                       changing: true),
            QueueEntry(path: "\(q)/gongfu-brewing-guide.pdf", modified: at(-52), size: 2_300_000, settled: true),
            // A current core lists a note as one row; its sidecar rides along in members.
            QueueEntry(path: "\(q)/Gyokuro at 60 °C.md", modified: at(-3), size: 420, settled: true, kind: .note,
                       members: ["\(q)/Gyokuro at 60 °C.distill.json"],
                       note: .init(source: "In person", labelsConfirmed: true, imageCount: 0)),
            QueueEntry(path: "\(q)/huge-scan.pdf", modified: at(-20), size: 48_000_000, settled: true,
                       problem: "Distill can't read this file. Check its permissions, or remove it."),
        ]
        engine.jobs = engine.jobs.filter { $0.state != .running }
        render(MainScreen(section: .queue) { QueueView() }.environmentObject(engine),
               size: CGSize(width: 1120, height: 760), "queue-rows.png")

        // A batch is running: its files are locked ("In batch"), new drops wait ("Next batch").
        let vault = engine.activeVault?.path ?? "/tmp/vault"
        let batch = Job(id: "job-snapshot-rows", vaultPath: vault,
                        files: ["inbox/tea-club-minutes.pdf", "inbox/Gyokuro at 60 °C.md", "inbox/Gyokuro at 60 °C.distill.json"],
                        model: "sonnet", state: .running, createdAt: at(-1), updatedAt: at(-1))
        engine.jobs = [batch] + engine.jobs
        engine.queued = [QueueEntry(path: "\(q)/Screenshot 2026-10-02 032855.png", modified: at(0), size: 52_000, settled: false, readyAt: at(10)),
                         QueueEntry(path: "\(q)/notes-from-call.md", modified: at(-30), size: 2_000, settled: true)]
        render(MainScreen(section: .queue) { QueueView() }.environmentObject(engine),
               size: CGSize(width: 900, height: 820), "queue-rows-batch.png") // 900 wide (the minimum); taller only because snapshots do not scroll
    }

    // MARK: Rendering

    private static func render<V: View>(_ view: V, size: CGSize? = nil, _ name: String) {
        Snapshot.render(view, size: size ?? screen.size, to: currentOut.appendingPathComponent(name))
    }

    private static var currentOut = URL(fileURLWithPath: ".")
}

/// Sidebar plus one screen, like the main window.
private struct MainScreen<Content: View>: View {
    let section: Section
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(section: .constant(section), selectedJob: .constant(nil), openSettings: {})
            content.frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.window)
        }
        .foregroundStyle(Theme.ink)
    }
}
