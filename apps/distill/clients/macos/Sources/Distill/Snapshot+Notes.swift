import AppKit
import SwiftUI
import DistillKit

/// `--snapshot` fixtures for Write a note, the quick note, Labels and the full
/// Settings window. Called from `Snapshot.run` after its own renders, so the
/// full-height settings.png here replaces the short one.
@MainActor
enum NotesSnapshot {
    static func run(engine: AppModel, outDir: URL) {
        let notes = engine.notes
        let main = CGSize(width: 1120, height: 720)
        loadFixtures(notes)

        // Write a note
        notes.drafts[.compose] = composeDraft()
        notes.steps[.compose] = nil
        render(MainShell(section: .queue) { ComposeScreen(mode: .constant(.note)) }.environmentObject(engine),
               size: main, to: outDir.appendingPathComponent("compose.png"))
        notes.steps[.compose] = LabelStep(requestID: "fixture-1", title: "Kettle settings for the new tea set",
                                          suggesting: true, startedAt: Date().addingTimeInterval(-4))
        render(MainShell(section: .queue) { ComposeScreen(mode: .constant(.note)) }.environmentObject(engine),
               size: main, to: outDir.appendingPathComponent("compose-loading.png"))

        // Quick note
        notes.drafts[.quick] = quickDraft()
        notes.steps[.quick] = nil
        render(QuickBackdrop { QuickNoteView(close: {}) }.environmentObject(engine),
               size: CGSize(width: 520, height: 420), to: outDir.appendingPathComponent("quicknote.png"))
        var step = LabelStep(requestID: "fixture-2", title: "Gyokuro at 60 °C", suggesting: true)
        step.received(requestID: "fixture-2", labels: [LabelSuggestion(name: "tea", existing: true),
                                                       LabelSuggestion(name: "gyokuro", existing: true),
                                                       LabelSuggestion(name: "tea-shops", existing: false)], error: nil)
        notes.steps[.quick] = step
        render(QuickBackdrop { QuickNoteView(close: {}) }.environmentObject(engine),
               size: CGSize(width: 520, height: 400), to: outDir.appendingPathComponent("quicknote-labels.png"))
        notes.steps[.quick] = LabelStep(requestID: "fixture-3", title: "Gyokuro at 60 °C", suggesting: true,
                                        startedAt: Date().addingTimeInterval(-3))
        render(QuickBackdrop { QuickNoteView(close: {}) }.environmentObject(engine),
               size: CGSize(width: 520, height: 340), to: outDir.appendingPathComponent("quicknote-loading.png"))

        // Labels
        notes.suggestJobID = nil
        notes.confirmJobID = nil
        render(MainShell(section: .labels) { LabelsSection() }.environmentObject(engine),
               size: main, to: outDir.appendingPathComponent("labels.png"))
        notes.suggestJobID = "fixture-labels-job"
        notes.suggestTotal = 23
        notes.fixtureProgress["fixture-labels-job"] = LabelsProgress(
            message: "Suggesting labels", done: 9, total: 23, startedAt: Date().addingTimeInterval(-41),
            model: "haiku", finished: false, error: nil)
        notes.confirmJobID = "pending"
        render(MainShell(section: .labels) { LabelsSection() }.environmentObject(engine),
               size: main, to: outDir.appendingPathComponent("labels-loading.png"))
        notes.suggestJobID = nil
        notes.confirmJobID = nil

        // Settings (every section)
        render(SettingsView().environmentObject(engine), size: CGSize(width: 760, height: 2280),
               to: outDir.appendingPathComponent("settings.png"))
    }

    // MARK: Fixtures

    private static func composeDraft() -> ComposeDraft {
        var d = ComposeDraft()
        d.title = "Kettle settings for the new tea set"
        d.text = "The gooseneck kettle has presets. 80 °C works for sencha; I set 60 °C for the gyokuro the shop recommended.\nThe shop's brewing card:\n![[brewing-card.png]]\nMy tasting setup:\n![[tasting-setup.jpg]]"
        d.group = "discussion"
        d.source = "in-person"
        d.sourceRef = "#tea-club · with Mei"
        d.images = [DraftImage(url: URL(fileURLWithPath: "/nonexistent/brewing-card.png")),
                    DraftImage(url: URL(fileURLWithPath: "/nonexistent/tasting-setup.jpg"))]
        return d
    }

    private static func quickDraft() -> ComposeDraft {
        var d = ComposeDraft()
        d.title = "Gyokuro at 60 °C"
        d.text = "Shop recommended 60 °C, 2 min first steep.\n![[brewing-card.png]]"
        d.group = "discussion"
        d.source = "in-person"
        d.images = [DraftImage(url: URL(fileURLWithPath: "/nonexistent/brewing-card.png"))]
        return d
    }

    private static func loadFixtures(_ notes: NotesStore) {
        let item = { (path: String, title: String, labels: [String], origin: String) -> JSONValue in
            .object(["path": .string(path), "title": .string(title), "labels": .array(labels.map(JSONValue.string)), "origin": .string(origin)])
        }
        let unlabeled = (1...23).map { JSONValue.object(["path": .string("wiki/notes/note-\($0).md"), "title": .string("Note \($0)")]) }
        notes.review = DTO.make(.object([
            "toReview": .array([
                item("wiki/meetings/q3-architecture-sync.md", "Q3 architecture sync", ["architecture", "project-x"], "queue-folder"),
                item("wiki/incidents/auth-retry-bug.md", "Auth service retry bug", ["project-x", "incidents"], "cli"),
                item("wiki/people/hiring-loop.md", "Hiring loop feedback", ["hiring"], "suggest"),
                item("wiki/tea/gongfu-brewing.md", "Gongfu brewing guide", ["tea", "brewing"], "queue-folder"),
                item("wiki/personal/weekend-ideas.md", "Ideas for weekend", ["personal"], "suggest"),
            ]),
            "unlabeled": .array(unlabeled),
        ]))
        notes.deselected = ["wiki/personal/weekend-ideas.md"]
        let counts: [(String, Int, Int)] = [("tea", 14, 1), ("brewing", 6, 1), ("gyokuro", 3, 0), ("project-x", 22, 2),
                                            ("hiring", 9, 1), ("architecture", 17, 1), ("incidents", 1, 1), ("personal", 1, 1)]
        notes.labelCounts = counts.map { LabelCount(name: $0.0, count: $0.1, unconfirmed: $0.2) }
        notes.runners = runnerFixtures()
        notes.runnerBusy = ["codex": "Checking…", "openrouter": "Saving…"]
        notes.fixtureProgress = [:]
    }

    private static func runnerFixtures() -> [RunnerInfo] {
        func runner(_ id: String, _ name: String, _ kind: String, enabled: Bool, tasks: [String], models: [(String, String)],
                    efforts: [String], problems: [String] = [], secrets: [(String, Bool)] = []) -> RunnerInfo? {
            RunnerInfo(id: id, displayName: name, kind: kind, enabled: enabled, tasks: tasks.compactMap(AITask.init(rawValue:)),
                       models: models.map { ModelOption(id: $0.0, label: $0.1) }, effortLevels: efforts,
                       defaultModel: models.first?.0 ?? "",
                       problems: problems.map { SetupProblem(code: "x", message: $0) },
                       secrets: secrets.map { RunnerSecret(name: $0.0, label: "API key", isSet: $0.1) })
        }
        return [
            runner("claude-code", "Claude Code", "agent", enabled: true, tasks: ["ingest", "ask", "labelSuggest", "imageText"],
                   models: [("sonnet", "Sonnet"), ("haiku", "Haiku"), ("opus", "Opus")], efforts: ["low", "medium", "high", "xhigh", "max"]),
            runner("codex", "Codex", "agent", enabled: false, tasks: ["ingest", "labelSuggest"],
                   models: [("gpt-5.5", "GPT-5.5")], efforts: ["low", "medium", "high"]),
            runner("openrouter", "OpenRouter", "modelAPI", enabled: false, tasks: ["labelSuggest", "imageText"],
                   models: [("google/gemini-2.5-flash", "Gemini 2.5 Flash")], efforts: [], secrets: [("apiKey", false)]),
            runner("openai", "OpenAI API", "modelAPI", enabled: false, tasks: ["labelSuggest", "imageText"],
                   models: [("gpt-5-mini", "GPT-5 mini")], efforts: ["minimal", "low", "medium", "high"],
                   problems: ["OpenAI API key is not set"], secrets: [("apiKey", false)]),
            runner("ai-sdk", "Vercel AI SDK", "modelAPI", enabled: false, tasks: ["labelSuggest"],
                   models: [("openai:gpt-5-mini", "openai:gpt-5-mini")], efforts: [], secrets: [("apiKey", false)]),
        ].compactMap { $0 }
    }

    // MARK: Rendering

    private static func render<V: View>(_ view: V, size: CGSize, to url: URL) {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height)
            .environment(\.colorScheme, .light).environment(\.snapshotMode, true))
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
        print(url.path)
    }
}

/// Sidebar plus one screen, like the main window.
private struct MainShell<Content: View>: View {
    let section: Section?
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(section: .constant(section ?? .history), selectedJob: .constant(nil), openSettings: {})
            content.frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.window)
        }
        .foregroundStyle(Theme.ink)
    }
}

/// The desktop-ish backdrop with the flask at the bottom right, as on the canvas.
private struct QuickBackdrop<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Color(hex: 0xDCD9D2)
            Circle().fill(Color.white).frame(width: 44, height: 44).shadow(color: .black.opacity(0.18), radius: 7, y: 6)
                .overlay(FlaskView(level: 0.45, bubbles: true, lineWidth: 1.6).frame(width: 22, height: 24))
                .padding(24)
            content
                .clipShape(RoundedRectangle(cornerRadius: 20)).compositingGroup()
                .shadow(color: .black.opacity(0.22), radius: 20, y: 18)
                .padding(.trailing, 24).padding(.bottom, 80)
        }
    }
}
