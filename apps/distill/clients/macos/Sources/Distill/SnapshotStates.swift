import AppKit
import SwiftUI
import DistillKit

/// `Distill --snapshot OUT --state-dir DIR --states`
/// Renders every screen state of the app (one PNG each) plus OUT/manifest.json
/// for the design canvas. DIR supplies settings.json (vault paths); all other
/// data is fixture data built here. Each state gets a fresh fixture model, so
/// nothing leaks between renders, and nothing talks to a core.
@MainActor
enum StatesSnapshot {
    enum Flow: String {
        case intake = "1 · Add sources → Queue → Review"
        case ask = "2 · Ask your vault"
        case labels = "3 · Labels"
        case flask = "4 · Quick access from the flask"
        case app = "5 · Settings and app"
        case actions = "6 · Actions from your notes"
        case collectors = "7 · Collectors"
        case activity = "8 · Activity"
        case liveLog = "9 · Live log"
    }

    nonisolated static let mainSize = CGSize(width: 1200, height: 760)
    private static var stateDir = URL(fileURLWithPath: "/")
    private static var outDir = URL(fileURLWithPath: "/")
    /// Every fixture model stays alive for the whole run: `NotesStore` is keyed
    /// by the model's identity, and a reused address would hand over a stale store.
    private static var engines: [AppModel] = []
    private static var manifest: [[String: Any]] = []
    private static var counter = 0
    private static let baseDefaults: [String: Any] = ["distill.addMode": "files", "distill.labelsTab": "toReview",
                                                      AppModel.suggestAfterQueueKey: true,
                                                      "distill.todo.group": "", "distill.todo.sort": ""]

    static func run(stateDir: URL, outDir: URL) {
        self.stateDir = stateDir
        self.outDir = outDir
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        queueStates()
        queueItemStates()
        queueLabelStates()
        composeStates()
        reviewStates()
        reviewLabelStates()
        historyStates()
        askStates()
        labelsStates()
        flaskStates()
        quickAskStates()
        quickNoteStates()
        settingsStates()
        actionsStates()
        collectorsStates()
        activityStates()
        liveLogStates()
        applyCleanupStates()
        fullReadStates()
        settingsNavStates()
        writeManifest()
    }

    // MARK: Fixture model

    static func engine(_ edit: (inout DistillKit.Settings) -> Void = { _ in }) -> AppModel {
        var settings = (try? Data(contentsOf: stateDir.appendingPathComponent("settings.json")))
            .flatMap { try? JSONDecoder.core.decode(DistillKit.Settings.self, from: $0) } ?? DistillKit.Settings()
        edit(&settings)
        let status = StatusResponse(activeVault: settings.activeVault, nextBatchAt: Date().addingTimeInterval(9 * 60 + 20))
        let e = AppModel(fixtureSettings: settings, jobs: [], queue: queue(settings), status: status)
        engines.append(e)
        AskFixtures.load(e.ask, vault: vault(e))
        e.ask.runners = AskFixtures.runners
        loadLabels(e.notes)
        e.notes.runners = runners()
        return e
    }

    static func vault(_ e: AppModel) -> String { e.activeVault?.path ?? "/Research" }

    static func queue(_ s: DistillKit.Settings, settling: Bool = true) -> [QueueEntry] {
        guard let dir = s.activeVault?.queueURL else { return [] }
        let now = Date()
        var items: [(String, Double, Int, Bool)] = [("Screenshot 2026-10-02 153212.png", 3600, 412_000, true),
                                                    ("gongfu-brewing-guide.pdf", 2400, 2_300_000, true),
                                                    ("Clipping 15.44.10.md", 1500, 4_100, true)]
        if settling { items.append(("Tea club thread.md", 40, 2_800, false)) }
        return items.map { QueueEntry(path: dir.appendingPathComponent($0.0).path, modified: now.addingTimeInterval(-$0.1),
                                      size: $0.2, settled: $0.3) }
    }

    static func loadLabels(_ notes: NotesStore, toReview: Bool = true, unlabeled: Bool = true) {
        let item = { (path: String, title: String, labels: [String], origin: String) -> JSONValue in
            .object(["path": .string(path), "title": .string(title), "labels": .array(labels.map(JSONValue.string)), "origin": .string(origin)])
        }
        let page = { (path: String, title: String) -> JSONValue in .object(["path": .string(path), "title": .string(title)]) }
        notes.review = DTO.make(.object([
            "toReview": .array(toReview ? [
                item("wiki/meetings/q3-architecture-sync.md", "Q3 architecture sync", ["architecture", "project-x"], "queue-folder"),
                item("wiki/incidents/auth-retry-bug.md", "Auth service retry bug", ["project-x", "incidents"], "cli"),
                item("wiki/people/hiring-loop.md", "Hiring loop feedback", ["hiring"], "suggest"),
                item("wiki/tea/gongfu-brewing.md", "Gongfu brewing guide", ["tea", "brewing"], "queue-folder"),
                item("wiki/personal/weekend-ideas.md", "Ideas for weekend", ["personal"], "suggest"),
            ] : []),
            "unlabeled": .array(unlabeled ? [
                page("wiki/notes/kettle-presets.md", "Kettle presets"),
                page("wiki/notes/oolong-oxidation.md", "Oolong oxidation range"),
                page("wiki/notes/standup-2026-09-28.md", "Standup 2026-09-28"),
                page("wiki/notes/retry-budget.md", "Retry budget for the auth service"),
                page("wiki/notes/book-list.md", "Book list"),
                page("wiki/notes/tea-shop-visit.md", "Tea shop visit, Kyoto"),
                page("wiki/notes/sprint-goals.md", "Sprint goals"),
            ] : []),
        ]))
        notes.deselected = ["wiki/personal/weekend-ideas.md"]
        let counts: [(String, Int, Int)] = [("tea", 14, 1), ("brewing", 6, 1), ("gyokuro", 3, 0), ("project-x", 22, 2),
                                            ("hiring", 9, 1), ("architecture", 17, 1), ("incidents", 1, 1), ("personal", 1, 1)]
        notes.labelCounts = counts.map { LabelCount(name: $0.0, count: $0.1, unconfirmed: $0.2) }
    }

    static func runners() -> [RunnerInfo] {
        func runner(_ id: String, _ name: String, _ kind: String, tasks: [AITask], models: [(String, String)], efforts: [String],
                    problems: [String] = [], secrets: [(String, Bool)] = []) -> RunnerInfo {
            RunnerInfo(id: id, displayName: name, kind: kind, tasks: tasks,
                       models: models.map { ModelOption(id: $0.0, label: $0.1) }, effortLevels: efforts,
                       defaultModel: models.first?.0 ?? "",
                       problems: problems.map { SetupProblem(code: "x", message: $0) },
                       secrets: secrets.map { RunnerSecret(name: $0.0, label: "API key", isSet: $0.1) })
        }
        return [
            runner("claude-code", "Claude Code", "agent", tasks: [.ingest, .ask, .labelSuggest, .imageText],
                   models: [("sonnet", "Sonnet"), ("haiku", "Haiku"), ("opus", "Opus")], efforts: ["low", "medium", "high", "xhigh", "max"]),
            runner("codex", "Codex", "agent", tasks: [.ingest, .labelSuggest], models: [("gpt-5.5", "GPT-5.5")], efforts: ["low", "medium", "high"]),
            runner("openrouter", "OpenRouter", "modelAPI", tasks: [.labelSuggest, .imageText],
                   models: [("google/gemini-2.5-flash", "Gemini 2.5 Flash")], efforts: [], secrets: [("apiKey", false)]),
            runner("openai", "OpenAI API", "modelAPI", tasks: [.labelSuggest, .imageText], models: [("gpt-5-mini", "GPT-5 mini")],
                   efforts: ["minimal", "low", "medium", "high"], secrets: [("apiKey", true)]),
            runner("ai-sdk", "Vercel AI SDK", "modelAPI", tasks: [.labelSuggest], models: [("openai:gpt-5-mini", "openai:gpt-5-mini")],
                   efforts: [], problems: ["The local AI SDK bridge did not answer on port 4319."], secrets: [("apiKey", true)]),
        ]
    }

    // MARK: Jobs

    nonisolated static let changePaths = ["wiki/sources/Brewing Green Tea.md", "wiki/concepts/Green tea.md", "wiki/index.md", "wiki/log.md", "wiki/hot.md"]

    static func turns(_ minutesAgo: Double, worker: String) -> [TurnRecord] {
        [TurnRecord(date: Date().addingTimeInterval(-minutesAgo * 60), author: .app, text: "Moved 2 files from the queue into your inbox."),
         TurnRecord(date: Date().addingTimeInterval(-(minutesAgo - 2) * 60), author: .worker, text: worker, costUSD: 0.12)]
    }

    static func awaiting(_ e: AppModel, id: String = "job-20261002-154200-a1b2",
                         files: [String] = ["inbox/tea-brewing-session.md", "inbox/brewing-card.png"],
                         summary: String = "Claude turned 2 sources into one new page and updated **Green tea** with the brewing temperatures. 3 tasting claims stay provisional, since they come from a single note.",
                         questions: [String] = [], denials: [PermissionDenial] = [], planError: String? = nil,
                         paths: [String] = changePaths, minutesAgo: Double = 20,
                         worker: String = "All set and checked. Approve and I will apply it.") -> Job {
        let valid = planError == nil
        let approval = ApprovalRequest(summary: summary, questions: questions, bundlePath: valid ? "/x/bundle.json" : nil,
                                       plan: TransactionPlan(operationID: "op-7f3a", operationType: "ingest", valid: valid,
                                                             changedPaths: paths, approvalSHA256: "a"),
                                       planError: planError, denials: denials)
        return Job(id: id, vaultPath: vault(e), files: files, state: .awaitingApproval,
                   createdAt: Date().addingTimeInterval(-minutesAgo * 60), updatedAt: Date().addingTimeInterval(-120),
                   approval: approval, turns: turns(minutesAgo, worker: worker))
    }

    static func job(_ e: AppModel, _ id: String, _ state: JobState, files: [String], minutesAgo: Double, kind: String = "ingest",
                    error: String? = nil, changed: [String] = [], op: String? = nil, worker: String? = nil) -> Job {
        Job(id: id, kind: kind, vaultPath: vault(e), files: files, state: state,
            createdAt: Date().addingTimeInterval(-minutesAgo * 60), updatedAt: Date().addingTimeInterval(-minutesAgo * 60 + 90),
            turns: worker.map { turns(minutesAgo, worker: $0) } ?? [], operationID: op, changedPaths: changed, error: error)
    }

    static func historyJobs(_ e: AppModel) -> [Job] {
        [
            job(e, "job-run", .running, files: ["inbox/Gyokuro at 60 °C.md", "inbox/Screenshot 15.32.12.png"], minutesAgo: 2),
            job(e, "job-done", .completed, files: ["inbox/q3-architecture-sync.md"], minutesAgo: 180, changed: changePaths,
                op: "op-20261002-1500-c3d4", worker: "Added **Q3 architecture sync** and linked it from Project X."),
            job(e, "job-failed", .failed, files: ["inbox/gongfu-brewing-guide.pdf"], minutesAgo: 300,
                error: "Claude Code stopped: usage limit reached. The files are back in the queue; reply to try again.",
                worker: "I could read 4 of 11 pages before the run stopped."),
            job(e, "job-rejected", .rejected, files: ["inbox/hiring-loop.md"], minutesAgo: 1440, op: "op-20261001-0910-e5f6",
                worker: "Drafted a new **Hiring loop** page."),
            job(e, "job-cancelled", .cancelled, files: ["inbox/standup-notes.md", "inbox/whiteboard.jpg"], minutesAgo: 2880,
                worker: "Reading the standup notes…"),
        ]
    }

    // MARK: Rendering

    /// Main window: sidebar plus one screen, at 1200×760, like `MainView` (Ask
    /// environment object, error banner overlay).
    static func main<V: View>(_ file: String, _ flow: Flow, _ screen: String, _ state: String, _ description: String,
                              _ e: AppModel, section: Section, job: String? = nil, historyPart: HistoryPart = .jobs,
                              defaults: [String: Any] = [:],
                              size: CGSize = mainSize, live: Bool = true, @ViewBuilder _ content: () -> V) {
        let view = HStack(spacing: 0) {
            Sidebar(section: .constant(section), selectedJob: .constant(job), historyPart: .constant(historyPart), openSettings: {})
            content().frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.window)
        }
        .environmentObject(e.ask)
        .overlay { if section == .collectors { CollectorsOverlay(store: e.collectors) } }
        .overlay(alignment: .bottom) { ErrorBanner() }
        .foregroundStyle(Theme.ink)
        .environmentObject(e)
        .environment(\.fixtureFolders, true)
        .frame(width: size.width, height: size.height)
        shoot(file, flow, screen, state, description, defaults: defaults, live: live, liveSize: size, view)
    }

    /// A floating or quick window (or a sheet / section) at its natural size on a light gray backdrop.
    static func natural<V: View>(_ file: String, _ flow: Flow, _ screen: String, _ state: String, _ description: String,
                                 _ e: AppModel, padding: CGFloat = 24, defaults: [String: Any] = [:], @ViewBuilder _ content: () -> V) {
        let view = content()
            .environmentObject(e.ask)
            .environmentObject(e)
            .foregroundStyle(Theme.ink)
            .fixedSize()
            .padding(padding)
            .background(Color(hex: 0xEAE8E3))
        shoot(file, flow, screen, state, description, defaults: defaults, live: true, view)
    }

    /// A quick window at the height it asks for (`onDesiredHeight`), like the app's
    /// QuickWindowSizer: a natural render alone collapses the scrolling middle.
    static func quickWindow<V: View>(_ file: String, _ flow: Flow, _ screen: String, _ state: String, _ description: String,
                                     _ e: AppModel, width: CGFloat = QuickWindowGeometry.defaultWidth, padding: CGFloat = 24,
                                     @ViewBuilder _ content: (@escaping (CGFloat) -> Void) -> V) {
        let store = UserDefaults(suiteName: "distill.snapshot.states") ?? .standard
        store.register(defaults: baseDefaults)
        var desired: CGFloat = 0
        let probe = NSHostingView(rootView: content { desired = $0 }
            .environmentObject(e.ask).environmentObject(e)
            .environment(\.colorScheme, .light).environment(\.snapshotMode, false).defaultAppStorage(store)
            .frame(width: width, height: 600))
        let window = NSWindow(contentRect: CGRect(x: -30000, y: -30000, width: width, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = probe
        liveWindows.append(window)
        for _ in 0..<6 { RunLoop.main.run(until: Date().addingTimeInterval(0.04)) }
        let height = max(QuickWindowGeometry.defaultSize.height, desired)
        natural(file, flow, screen, state, description, e, padding: padding) {
            content { _ in }.frame(width: width, height: height)
        }
    }

    /// `live`: draw through an offscreen NSHostingView with snapshot mode off,
    /// so AppKit-backed controls (checkboxes, switches, text fields, pickers,
    /// scroll views) render as in the app. ImageRenderer draws those as a
    /// placeholder. `liveSize` nil = the view's fitting size.
    static func shoot<V: View>(_ file: String, _ flow: Flow, _ screen: String, _ state: String, _ description: String,
                               defaults: [String: Any], live: Bool = false, liveSize: CGSize? = nil, _ view: V) {
        // DISTILL_STATES_ONLY=prefix renders only the files starting with it (quicker checks of one area).
        if let only = ProcessInfo.processInfo.environment["DISTILL_STATES_ONLY"], !only.isEmpty, !file.hasPrefix(only) { return }
        counter += 1
        // @AppStorage reads from an in-memory registration domain (never the
        // user's defaults). That domain is shared by the whole process, so every
        // render sets every key the views read.
        let store = UserDefaults(suiteName: "distill.snapshot.states") ?? .standard
        store.register(defaults: baseDefaults.merging(defaults) { $1 })
        let content = view.environment(\.colorScheme, .light).defaultAppStorage(store)
        let result: (Data, CGSize)?
        if live {
            result = liveImage(content.environment(\.snapshotMode, false), size: liveSize,
                               backdrop: liveSize == nil ? NSColor(red: 0xEA / 255, green: 0xE8 / 255, blue: 0xE3 / 255, alpha: 1) : nil)
        } else {
            let renderer = ImageRenderer(content: content.environment(\.snapshotMode, true))
            renderer.scale = 2
            if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                result = (png, image.size)
            } else {
                result = nil
            }
        }
        guard let (png, size) = result else {
            FileHandle.standardError.write(Data("failed: \(file)\n".utf8))
            return
        }
        let name = file + ".png"
        try? png.write(to: outDir.appendingPathComponent(name))
        manifest.append(["file": name, "flow": flow.rawValue, "screen": screen, "state": state, "description": description,
                         "widthPt": Int(size.width.rounded()), "heightPt": Int(size.height.rounded())])
        print(name)
    }

    private static var liveWindows: [NSWindow] = []

    static func liveImage<V: View>(_ view: V, size: CGSize?, backdrop: NSColor? = nil) -> (Data, CGSize)? {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: view)
        // Whole points: a fractional size leaves a transparent row at the edge.
        let raw = size ?? host.fittingSize
        let fitted = CGSize(width: raw.width.rounded(.up), height: raw.height.rounded(.up))
        let window = NSWindow(contentRect: CGRect(x: -30000, y: -30000, width: fitted.width, height: fitted.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = CGRect(origin: .zero, size: fitted)
        liveWindows.append(window)
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        host.layoutSubtreeIfNeeded()
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(fitted.width * 2), pixelsHigh: Int(fitted.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = fitted
        // Natural-size renders sit on the gray desk: fill it first so a rounding
        // row SwiftUI leaves uncovered is gray, not transparent.
        if let backdrop, let context = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            backdrop.setFill()
            CGRect(origin: .zero, size: fitted).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return (png, fitted)
    }

    static func writeManifest() {
        guard let data = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: outDir.appendingPathComponent("manifest.json"))
    }

    /// What “Extract content” returns for the brewing card in the fixtures.
    static let extractedCard = "**Gyokuro brewing card**\n- 60 °C, 2 min first steep\n- Second steep 30 s, third 1 min\n- 6 g leaf for a 180 ml kyusu"

    static func image(_ name: String, bytes: Int = 412_000) -> DraftImage {
        DraftImage(url: URL(fileURLWithPath: "/nonexistent/\(name)"), byteCount: bytes)
    }

    static func problem(_ e: AppModel, _ messages: [String], connection: AppModel.Connection = .offline) {
        let status = StatusResponse(activeVault: e.activeVault, problems: messages.map { SetupProblem(code: "x", message: $0) },
                                    nextBatchAt: Date().addingTimeInterval(560))
        e.setFixtureState(connection: connection, status: status)
    }

    static let nodeMissing = "Node.js 20 or newer was not found. Install it (brew install node) or set its path in Settings → Advanced."
    static let coreDown = "The Distill core stopped. Retry starts it again."
}

// MARK: - Flow 1: Queue, Write a note, Review, History

extension StatesSnapshot {
    static func queueStates() {
        let f = Flow.intake
        var e = engine { $0.activeVaultPath = $0.vaults.first?.path }
        e.queued = []
        e.refreshState = .nothing("Nothing new")
        main("queue-empty", f, "Queue", "Empty · all caught up", "Nothing in the queue; the header shows the next batch time, and Refresh just said “Nothing new”.", e, section: .queue) { QueueView() }

        e = engine()
        main("queue-ready", f, "Queue", "Files waiting (Ready / Ready at)", "Three ready files and one waiting until its ready time; Process now enabled.", e, section: .queue) { QueueView() }

        e = engine()
        main("queue-drop-target", f, "Queue", "Drop target highlighted", "A file is dragged over the drop panel: “Let go to add it”.", e, section: .queue) { QueueView(targeted: true) }

        e = engine()
        e.pendingActions["process"] = Date()
        main("queue-processing", f, "Queue", "Process now pressed", "“Processing…” while the core starts the batch.", e, section: .queue) { QueueView() }

        e = engine()
        let started = Date().addingTimeInterval(-112)
        var batch = job(e, "job-batch", .running, files: ["inbox/Gyokuro at 60 °C.md", "inbox/Screenshot 15.32.12.png", "inbox/gongfu-brewing-guide.pdf"], minutesAgo: 0)
        batch.createdAt = started
        e.jobs = [batch]
        e.queued = Array(e.queued.suffix(2))
        e.progress[batch.id] = CoreProgress(key: batch.id, kind: "batch", message: "Reading 3 sources",
                                            steps: ["Moved to inbox", "Read sources", "Drafting page changes", "Ready for review"],
                                            stepIndex: 2, startedAt: started, runnerID: "claude-code", model: "sonnet")
        main("queue-batch-running", f, "Queue", "Batch running (with steps)", "Batch banner with steps, In batch rows and Next batch rows.", e, section: .queue) { QueueView() }

        e = engine()
        e.jobs = [batch]
        e.queued = Array(e.queued.suffix(2))
        e.progress[batch.id] = CoreProgress(key: batch.id, kind: "batch", message: "Reading 3 sources",
                                            steps: ["Moved to inbox", "Read sources", "Drafting page changes", "Ready for review"],
                                            stepIndex: 2, startedAt: started, runnerID: "claude-code", model: "sonnet")
        main("queue-batch-running-900", f, "Queue", "Batch running · smallest window (900×600)", "The widest Queue header (running batch, Processing…) at the window's minimum size.", e, section: .queue, size: CGSize(width: 900, height: 600)) { QueueView() }

        e = engine()
        e.jobs = [batch]
        e.queued = []
        main("queue-batch-running-basic", f, "Queue", "Batch running (no progress events)", "Older core: banner from the job only, no steps.", e, section: .queue) { QueueView() }

        e = engine()
        var slow = batch
        slow.createdAt = Date().addingTimeInterval(-11 * 60 - 4)
        e.jobs = [slow]
        e.queued = []
        main("queue-batch-slow", f, "Queue", "Batch still working (10+ min)", "“Still working” after 10 minutes; the detail keeps “started at” its clock time.", e, section: .queue) { QueueView() }

        e = engine()
        e.jobs = [awaiting(e)]
        main("queue-waiting-review", f, "Queue", "Next batch waits for review", "A job waits in Review, so the next batch waits; Review badge in the sidebar.", e, section: .queue) { QueueView() }

        e = engine { $0.autoProcessEnabled = false }
        main("queue-auto-off", f, "Queue", "Automatic batching off", "Schedule line says batching is off; Process now still works.", e, section: .queue) { QueueView() }

        e = engine()
        e.setFixtureState(connection: .connecting, status: nil)
        main("queue-starting", f, "Queue", "Starting Distill…", "First launch before the core answers: shimmer header and rows, connecting banner.", e, section: .queue) { QueueView() }

        e = engine()
        e.setFixtureState(connection: .connecting, status: StatusResponse(activeVault: e.activeVault, nextBatchAt: Date().addingTimeInterval(560)))
        main("queue-reconnecting", f, "Queue", "Reconnecting", "Data is shown; the core is being reconnected (“Connecting to Distill's core…”).", e, section: .queue) { QueueView() }

        e = engine()
        problem(e, [], connection: .unreachable(coreDown))
        main("queue-core-unreachable", f, "Queue", "Core unreachable", "Banner “Distill's core isn't running” with Retry; schedule line explains.", e, section: .queue) { QueueView() }

        e = engine()
        problem(e, [nodeMissing], connection: .unreachable("node was not found. Install Node.js 20+ or set its path in Settings → Advanced, then Retry."))
        main("queue-node-missing", f, "Queue", "Node missing", "The core can't start without node: banner with the reason and Retry.", e, section: .queue) { QueueView() }

        e = engine()
        problem(e, ["The claude CLI was not found at /Users/me/.local/bin/claude."])
        main("queue-setup-problem", f, "Queue", "Setup problem", "The core reports a setup problem: schedule line shows it, vault switcher says Needs setup.", e, section: .queue) { QueueView() }

        e = engine { $0.activeVaultPath = nil; $0.vaults = [] }
        e.queued = []
        main("queue-no-vault", f, "Queue", "No vault selected", "No vault yet: “Choose a vault” switcher and blocker line.", e, section: .queue) { QueueView() }

        e = engine()
        e.lastError = "Could not move gongfu-brewing-guide.pdf to the Trash: the file is locked."
        main("queue-error", f, "Queue", "Error message", "A failed command shows a dismissable error at the bottom.", e, section: .queue) { QueueView() }
    }

    static func composeStates() {
        let f = Flow.intake
        let note: [String: Any] = ["distill.addMode": "note"]
        func filled() -> ComposeDraft {
            var d = ComposeDraft()
            d.title = "Kettle settings for the new tea set"
            d.text = "The gooseneck kettle has presets. 80 °C works for sencha; I set 60 °C for the gyokuro the shop recommended.\nTheir card had the steep times:\n![[brewing-card.png]]\nMy tasting setup:\n![[tasting-setup.jpg]]"
            d.group = "discussion"
            d.source = "in-person"
            d.sourceRef = "#tea-club · with Mei"
            d.images = [image("brewing-card.png"), image("tasting-setup.jpg", bytes: 1_240_000)]
            return d
        }
        /// Board "Images stay inside the text": one pasted card between two lines.
        func oneImage() -> ComposeDraft {
            var d = filled()
            d.text = "The gooseneck kettle has presets. 80 °C works for sencha; I set 60 °C for the gyokuro the shop recommended.\nTheir card had the steep times:\n![[brewing-card.png]]\nBuy the 50 g tin next time."
            d.images = [image("brewing-card.png")]
            return d
        }
        func step(_ edit: (inout LabelStep) -> Void = { _ in }) -> LabelStep {
            var s = LabelStep(requestID: "r1", title: "Kettle settings for the new tea set", suggesting: true, startedAt: Date().addingTimeInterval(-4))
            edit(&s)
            return s
        }
        let suggestions = [LabelSuggestion(name: "tea", existing: true), LabelSuggestion(name: "brewing", existing: true),
                           LabelSuggestion(name: "kettle", existing: false)]
        func shot(_ file: String, _ state: String, _ desc: String, _ setup: (NotesStore) -> Void) {
            let e = engine()
            e.notes.drafts[.compose] = filled()
            setup(e.notes)
            main(file, f, "Write a note", state, desc, e, section: .queue, defaults: note) { QueueView() }
        }
        shot("compose-empty", "Empty", "“Write a note” mode with nothing typed; Add to queue disabled.") { $0.drafts[.compose] = ComposeDraft() }
        shot("compose-text-only", "Text, no images", "A typed note with a source chip and no images.") { n in
            var d = filled(); d.images = []; n.drafts[.compose] = d
        }
        shot("compose-filled", "Filled · images inside the text", "Title, text, source, and two images inside the text where they were pasted; the footer counts them.") { _ in }
        shot("compose-image-pasted", "Image pasted at the cursor", "⌘V put the image between the lines at its own shape; typing carries on under it.") {
            $0.drafts[.compose] = oneImage()
        }
        shot("compose-image-hover", "Image · hover", "Hovering the image: Extract content and × in its corner, name and size bottom-left.") {
            $0.drafts[.compose] = oneImage(); $0.imageFixtures[.compose] = InlineImageFixture(hovered: "brewing-card.png")
        }
        shot("compose-image-selected", "Image · selected", "A click selects the image (blue ring); Delete removes it.") {
            $0.drafts[.compose] = oneImage(); $0.imageFixtures[.compose] = InlineImageFixture(selected: "brewing-card.png")
        }
        shot("compose-image-reading", "Image · reading", "Extract content clicked: the image dims with a shimmer and “Reading with Haiku…”; Add to queue waits.") {
            var d = oneImage(); d.imageStates["brewing-card.png"] = .reading(model: "Haiku"); $0.drafts[.compose] = d
        }
        shot("compose-image-extracted", "Image · extracted", "The text read from the image replaced it in place, tinted, with Undo ⌘Z.") {
            var d = oneImage()
            d.text = d.text.replacingOccurrences(of: "![[brewing-card.png]]", with: extractedCard)
            $0.drafts[.compose] = d
            $0.imageFixtures[.compose] = InlineImageFixture(extracted: (extractedCard, "brewing-card.png", "Haiku"))
        }
        shot("compose-image-failed", "Image · couldn’t read it", "The reading failed: the image stays, with the reason, Try again and Settings.") {
            var d = oneImage(); d.imageStates["brewing-card.png"] = .failed("Claude Code isn’t signed in."); $0.drafts[.compose] = d
        }
        shot("compose-image-no-text", "Image · no text found", "The model found no text: the image stays as it was.") {
            var d = oneImage(); d.imageStates["brewing-card.png"] = .noText; $0.drafts[.compose] = d
        }
        do {
            let e = engine()
            e.notes.drafts[.compose] = filled()
            main("compose-filled-900", f, "Write a note", "Filled · smallest window (900×600)", "Write a note at the window's minimum size.", e, section: .queue, defaults: note, size: CGSize(width: 900, height: 600)) { QueueView() }
        }
        shot("compose-adding", "Adding…", "Add to queue pressed; waiting for the core.") { $0.adding = [.compose] }
        shot("compose-add-error", "Add failed", "The core refused or could not be reached; the draft stays.") {
            $0.addErrors[.compose] = "Cannot reach the Distill core: connection refused"
        }
        shot("compose-suggesting", "Label step · suggesting", "Queued; label suggestions are on their way (shimmer chips).") { $0.steps[.compose] = step() }
        shot("compose-suggestions", "Label step · suggestions", "Suggestions arrived (green existing, peach new) plus an own label; Apply N labels.") {
            $0.steps[.compose] = step { s in s.received(requestID: "r1", labels: suggestions, error: nil); s.add("gooseneck") }
        }
        shot("compose-unchosen", "Label step · one suggestion removed", "A removed suggestion stays as a muted chip to bring back.") {
            $0.steps[.compose] = step { s in s.received(requestID: "r1", labels: suggestions, error: nil); s.remove("kettle") }
        }
        shot("compose-applying", "Label step · applying", "Apply pressed; chips lock while labels are written.") {
            $0.steps[.compose] = step { s in s.received(requestID: "r1", labels: suggestions, error: nil); s.applyStarted() }
        }
        shot("compose-applied", "Label step · applied", "Labels applied; Write another.") {
            $0.steps[.compose] = step { s in s.received(requestID: "r1", labels: suggestions, error: nil); s.applyStarted(); s.applySucceeded(labels: ["tea", "brewing", "kettle"]) }
        }
        shot("compose-skipped", "Label step · skipped", "Labels skipped: the note stays unlabeled.") {
            $0.steps[.compose] = step { s in s.received(requestID: "r1", labels: suggestions, error: nil); s.skip() }
        }
        shot("compose-suggest-error", "Label step · suggestions failed", "Suggestions failed; the note is still queued, add your own.") {
            $0.steps[.compose] = step { s in s.received(requestID: "r1", labels: [], error: "OpenRouter answered 401 (check the API key)") }
        }
        shot("compose-too-late", "Label step · too late", "The batch already took the note, so labels can't be applied here.") {
            $0.steps[.compose] = step { s in
                s.received(requestID: "r1", labels: suggestions, error: nil); s.applyStarted()
                s.applyFailed(CoreClientError.api(status: 409, code: "invalid_state", message: "note already taken by a batch"))
            }
        }
    }

    static func reviewStates() {
        let f = Flow.intake
        var e = engine()
        main("review-empty", f, "Review", "Empty", "Nothing waits for approval.", e, section: .review) { ReviewSection(selectedJob: .constant(nil)) }

        e = engine()
        e.jobs = [awaiting(e)]
        main("review-ready", f, "Review", "Awaiting approval · plan ready", "Summary, 1 new page / 4 updated, changes list, conversation, Approve & apply.", e, section: .review, job: e.jobs[0].id) {
            ReviewSection(selectedJob: .constant(e.jobs[0].id))
        }
        main("review-ready-900", f, "Review", "Plan ready · smallest window (900×600)", "The review at the window's minimum size: the conversation starts at the top.", e, section: .review, job: e.jobs[0].id, size: CGSize(width: 900, height: 600)) {
            ReviewSection(selectedJob: .constant(e.jobs[0].id))
        }

        e = engine()
        e.jobs = [awaiting(e), awaiting(e, id: "job-b", files: ["inbox/q3-architecture-sync.md"], summary: "One meeting note becomes a new page under Project X."),
                  awaiting(e, id: "job-c", kind: nil, files: ["wiki/meetings/q3-architecture-sync.md", "wiki/incidents/auth-retry-bug.md"],
                           summary: "Confirm labels on 2 notes.")]
        main("review-multiple", f, "Review", "Several jobs waiting", "Tabs across the top when more than one job waits.", e, section: .review, job: e.jobs[0].id) {
            ReviewSection(selectedJob: .constant(e.jobs[0].id))
        }

        // Session continuity (canvas: SessionContinuity): the batch's AI session is gone.
        e = engine()
        e.jobs = [awaiting(e)]
        e.sessionPrompts[e.jobs[0].id] = SessionPrompt(jobID: e.jobs[0].id, info: SessionUnavailable(
            place: "batch", reason: "missing", detail: "~/.claude/projects/…/3f2a91c0-…-c217.jsonl is missing", action: "approve"))
        main("session-review-approve", f, "Review", "Approve: the AI session is gone", "SessionReplaceConfirm above the dimmed footer; Continue applies in a new session.", e, section: .review, job: e.jobs[0].id) {
            ReviewSection(selectedJob: .constant(e.jobs[0].id))
        }

        e = engine()
        var refused = awaiting(e)
        refused.sessionUnavailable = SessionUnavailable(place: "batch", reason: "notFound",
                                                        detail: "claude exited 1: No conversation found with session ID: 3f2a91c0-…-c217",
                                                        action: "reply", text: "Put the shading notes on the Gyokuro page instead", at: "t")
        e.jobs = [refused]
        main("session-review-reply", f, "Review", "Reply: the runner can't find the session", "From the job's marker after a refused resume; the reply is kept for Continue.", e, section: .review, job: e.jobs[0].id) {
            ReviewSection(selectedJob: .constant(e.jobs[0].id))
        }

        e = engine()
        e.jobs = [awaiting(e, questions: ["Should the tasting notes go on the existing Green tea page or a new Gyokuro page?",
                                          "The brewing card says 50–60 °C; your note says 60 °C. Which one should the page use?"],
                           worker: "I have two questions before this is final; the plan below works either way.")]
        main("review-questions", f, "Review", "Awaiting approval · questions", "Claude asks questions; reply or approve as is.", e, section: .review, job: e.jobs[0].id) {
            ReviewSection(selectedJob: .constant(e.jobs[0].id))
        }

        let denials = [
            PermissionDenial(toolName: "WebFetch", input: ["url": .string("https://www.example-tea.com/gyokuro-guide")]),
            PermissionDenial(toolName: "Bash", input: ["command": .string("python3 scripts/claude-obsidian.py lint --json")]),
            PermissionDenial(toolName: "Bash", input: ["command": .string("cd wiki && grep -rl gyokuro .")]),
        ]
        e = engine()
        e.jobs = [awaiting(e, denials: denials, worker: "I couldn't fetch the shop's guide or run the linter. Allow them and I'll continue.")]
        main("review-denials", f, "Review", "Awaiting approval · blocked tools", "Denied tool calls with suggested rules (one bypasses review) and a combined command.", e, section: .review, job: e.jobs[0].id) {
            JobDetailView(jobID: e.jobs[0].id)
        }

        e = engine()
        e.jobs = [awaiting(e, denials: denials, worker: "I couldn't fetch the shop's guide or run the linter. Allow them and I'll continue.")]
        main("review-denials-allowed", f, "Review", "Blocked tools · rule ticked", "A rule is ticked: “Allow & continue” appears.", e, section: .review, job: e.jobs[0].id) {
            JobDetailView(jobID: e.jobs[0].id, allowed: ["WebFetch(domain:www.example-tea.com)"])
        }
        main("review-denials-allowed-900", f, "Review", "Rule ticked · smallest window (900×600)", "“Allow & continue” is visible without scrolling at the minimum size.", e, section: .review, job: e.jobs[0].id, size: CGSize(width: 900, height: 600)) {
            JobDetailView(jobID: e.jobs[0].id, allowed: ["WebFetch(domain:www.example-tea.com)"])
        }

        e = engine()
        e.jobs = [awaiting(e, planError: "The bundle changed wiki/index.md, but the page changed on disk since Claude read it. Reply to have Claude redo the plan.",
                           worker: "The plan could not be verified.")]
        main("review-needs-input", f, "Review", "Needs input · plan can't apply", "The plan failed verification: no Approve button, reply to continue.", e, section: .review, job: e.jobs[0].id) {
            ReviewSection(selectedJob: .constant(e.jobs[0].id))
        }

        e = engine()
        e.jobs = [awaiting(e)]
        main("review-reply-typed", f, "Review", "Reply typed", "A reply is typed to Claude: Send reply is enabled.", e, section: .review, job: e.jobs[0].id) {
            JobDetailView(jobID: e.jobs[0].id, reply: "Put the tasting notes on the Green tea page instead of a new page.")
        }

        e = engine()
        e.jobs = [awaiting(e)]
        e.pendingActions["approve:\(e.jobs[0].id)"] = Date().addingTimeInterval(-3)
        main("review-applying", f, "Review", "Applying", "Approve pressed: “Writing to Research · 0:03”, Applying N changes…", e, section: .review, job: e.jobs[0].id) {
            ReviewSection(selectedJob: .constant(e.jobs[0].id))
        }

        e = engine()
        e.jobs = [awaiting(e)]
        e.pendingActions["approve:\(e.jobs[0].id)"] = Date().addingTimeInterval(-74)
        main("review-applying-slow", f, "Review", "Applying (slow)", "Still writing after a minute.", e, section: .review, job: e.jobs[0].id) {
            ReviewSection(selectedJob: .constant(e.jobs[0].id))
        }
    }

    static func awaiting(_ e: AppModel, id: String, kind: String?, files: [String], summary: String) -> Job {
        var j = awaiting(e, id: id, files: files, summary: summary, paths: files)
        if kind == nil { j.kind = "labels" }
        return j
    }

    static func historyStates() {
        let f = Flow.intake
        var e = engine()
        e.jobs = historyJobs(e)
        main("history-list", f, "History · Jobs", "List, nothing selected", "Every job state dot (Working, Applied, Didn't finish, Rejected, Cancelled); Clear.", e, section: .history) {
            HistorySection(selectedJob: .constant(nil))
        }
        let details: [(String, String, String, String)] = [
            ("job-run", "history-running", "Job · running", "Working: spinner, “Claude is working on it…”, Cancel."),
            ("job-done", "history-completed", "Job · completed", "Applied changes and the operation ID."),
            ("job-failed", "history-failed", "Job · failed", "Error text; reply to retry."),
            ("job-rejected", "history-rejected", "Job · rejected", "Rejected; nothing was written."),
            ("job-cancelled", "history-cancelled", "Job · cancelled", "Cancelled; reply to continue."),
        ]
        for (id, file, state, desc) in details {
            e = engine()
            e.jobs = historyJobs(e)
            if id == "job-run" {
                e.progress[id] = CoreProgress(key: id, kind: "batch", message: "Drafting page changes",
                                              steps: ["Moved to inbox", "Read sources", "Drafting page changes", "Ready for review"],
                                              stepIndex: 2, startedAt: Date().addingTimeInterval(-120))
            }
            main(file, f, "History · Jobs", state, desc, e, section: .history, job: id) { HistorySection(selectedJob: .constant(id)) }
        }

        e = engine()
        main("history-empty", f, "History · Jobs", "Empty", "No jobs yet.", e, section: .history) { HistorySection(selectedJob: .constant(nil)) }

        e = engine()
        e.setFixtureState(connection: .connecting, status: nil)
        main("history-starting", f, "History · Jobs", "Starting Distill…", "Shimmer rows while the core starts.", e, section: .history) { HistorySection(selectedJob: .constant(nil)) }
    }
}

// MARK: - Flow 2: Ask

extension StatesSnapshot {
    static func askStates() {
        let f = Flow.ask
        var e = engine()
        e.ask.conversations = []
        main("ask-empty", f, "Ask", "Empty · first use", "No chats yet: intro, suggestions, model and effort.", e, section: .ask) { AskScreen() }
        main("ask-empty-900", f, "Ask", "Empty · smallest window (900×600)", "The intro sits at the top of the chat area.", e, section: .ask, size: CGSize(width: 900, height: 600)) { AskScreen() }

        e = engine()
        main("ask-empty-recents", f, "Ask", "Empty · with recent chats", "Recent chats in the screen and Recent questions in the sidebar.", e, section: .ask) { AskScreen() }

        e = engine()
        let t = e.ask.main
        t.reset(filter: AskFilter())
        t.filter.addLabel("tea"); t.filter.addLabel("gyokuro"); t.filter.addSource("slack")
        t.filter.labelMatch = .all
        t.filter.includeUnconfirmed = false
        t.draft = "How hot should the water be for gyokuro?"
        main("ask-filtered", f, "Ask", "Filtered · labels and source", "#tea and #gyokuro (All labels), unconfirmed off, Slack source, a typed question.", e, section: .ask) { AskScreen() }
        main("ask-filtered-900", f, "Ask", "Filtered · smallest window (900×600)", "The filter bar and its count line at the minimum size.", e, section: .ask, size: CGSize(width: 900, height: 600)) { AskScreen() }

        e = engine()
        AskFixtures.loading(e.ask.main, question: "How hot should the water be for green tea, and does it differ for gyokuro?")
        main("ask-answering", f, "Ask", "Answering", "Reading your notes… with elapsed time, Stop, and answer shimmer.", e, section: .ask) { AskScreen() }

        e = engine()
        AskFixtures.loading(e.ask.main, question: "Summarize everything I know about Project X's architecture decisions.", seconds: 75)
        main("ask-answering-slow", f, "Ask", "Answering (slow)", "“Still working · 1:15” after a minute.", e, section: .ask) { AskScreen() }

        e = engine()
        AskFixtures.loading(e.ask.main, question: "How hot should the water be for green tea, and does it differ for gyokuro?")
        e.ask.main.pending?.status = .stopped
        main("ask-stopped", f, "Ask", "Stopped", "Stopped by the user; the question is kept, Ask again.", e, section: .ask) { AskScreen() }

        e = engine()
        AskFixtures.loading(e.ask.main, question: "How hot should the water be for green tea, and does it differ for gyokuro?")
        e.ask.main.pending?.status = .failed("Claude Code exited: usage limit reached.")
        main("ask-error", f, "Ask", "Error", "Couldn't get an answer; the question is kept, Retry.", e, section: .ask) { AskScreen() }

        e = engine()
        AskFixtures.loading(e.ask.main, question: "And does it differ for gyokuro?")
        e.ask.main.pending?.status = .sessionUnavailable(SessionUnavailable(
            place: "conversation", reason: "notFound", detail: "claude exited 1: No conversation found with session ID: 8c1d…04ab", action: "ask"))
        main("session-ask", f, "Ask", "Follow-up: the AI session is gone", "SessionReplaceConfirm in place of the pending question; Cancel puts it back in the box.", e, section: .ask) { AskScreen() }

        e = engine()
        AskFixtures.answered(e.ask.main)
        main("ask-answered", f, "Ask", "Answered · gaps and notices", "Answer with citation markers, cards, a Gap callout and a page-limit notice.", e, section: .ask) { AskScreen() }
        main("ask-answered-900", f, "Ask", "Answered · smallest window (900×600)", "An answer at the minimum size.", e, section: .ask, size: CGSize(width: 900, height: 600)) { AskScreen() }

        e = engine()
        AskFixtures.answered(e.ask.main)
        let second = AskResponse(conversationID: "c1", answer: "Your vault has nothing on oolong water temperature yet.",
                                 gaps: ["no page covers oolong. Drop a source in the queue to fill it."],
                                 selection: e.ask.main.selection)
        e.ask.main.entries.append(AskEntry(question: "And oolong?", askedAt: Date(), request: AskRequest(question: "And oolong?"),
                                           response: second, duration: 75))
        e.ask.savedEntries.insert(e.ask.main.entries[0].id)
        main("ask-followup", f, "Ask", "Follow-up · saved answer", "Two turns; the first answer saved to the queue, the second cites nothing.", e, section: .ask) { AskScreen() }

        e = engine()
        e.ask.main.reset(filter: AskFilter())
        e.ask.main.conversationID = "c3"
        e.ask.main.note = "Couldn't load this chat: Cannot reach the Distill core: connection refused"
        main("ask-chat-load-error", f, "Ask", "Chat couldn't load", "Opening a stored chat failed; a note above the empty state.", e, section: .ask) { AskScreen() }

        e = engine()
        main("history-chats", f, "History · Ask chats", "Chats list · keep history on", "Ask chats with pin and delete; kept N days.", e, section: .history, historyPart: .chats) {
            HistorySection(selectedJob: .constant(nil), part: .chats)
        }
        main("history-chats-900", f, "History · Ask chats", "Chats list · smallest window (900×600)", "Each chat's “N questions · Asked …” stays on one line.", e, section: .history, historyPart: .chats, size: CGSize(width: 900, height: 600)) {
            HistorySection(selectedJob: .constant(nil), part: .chats)
        }

        e = engine { SettingsEdits.setAsk(&$0) { $0.keepHistory = false } }
        e.ask.conversations = []
        main("history-chats-empty", f, "History · Ask chats", "Empty · keep history off", "No chats; explains that chats are deleted when left.", e, section: .history, historyPart: .chats) {
            HistorySection(selectedJob: .constant(nil), part: .chats)
        }
    }
}

// MARK: - Flow 3: Labels

extension StatesSnapshot {
    static func labelsStates() {
        let f = Flow.labels
        let unl: [String: Any] = ["distill.labelsTab": "unlabeled"]
        var e = engine()
        main("labels-to-review", f, "Labels", "To review", "AI labels not confirmed yet; one row unticked; suggest banner for unlabeled notes.", e, section: .labels) { LabelsSection() }

        e = engine()
        e.notes.edits["wiki/incidents/auth-retry-bug.md"] = ["project-x", "incidents", "retries"]
        e.notes.edits["wiki/people/hiring-loop.md"] = []
        main("labels-edited", f, "Labels", "To review · edited", "A label added by hand (solid) and a row with every label removed.", e, section: .labels) { LabelsSection() }

        e = engine()
        e.notes.edits["wiki/notes/kettle-presets.md"] = ["tea", "kettle"]
        main("labels-unlabeled", f, "Labels", "Unlabeled", "Notes with no labels; one given labels by hand and ready to confirm.", e, section: .labels, defaults: unl) { LabelsSection() }

        e = engine()
        e.notes.review = nil
        main("labels-loading", f, "Labels", "Loading", "Shimmer rows before the review list arrives.", e, section: .labels) { LabelsSection() }

        e = engine()
        e.notes.review = nil
        e.notes.reviewError = "This Distill core has no Labels API yet."
        main("labels-error", f, "Labels", "Error", "The review list could not be loaded.", e, section: .labels) { LabelsSection() }

        e = engine()
        loadLabels(e.notes, toReview: false, unlabeled: false)
        main("labels-empty", f, "Labels", "Empty · to review", "Nothing to review and no unlabeled notes.", e, section: .labels) { LabelsSection() }

        e = engine()
        loadLabels(e.notes, toReview: true, unlabeled: false)
        main("labels-empty-unlabeled", f, "Labels", "Empty · unlabeled", "Every note has labels.", e, section: .labels, defaults: unl) { LabelsSection() }

        e = engine()
        e.notes.suggestJobID = "pending"
        e.notes.suggestTotal = 7
        main("labels-suggest-starting", f, "Labels", "Suggesting · starting", "Suggest pressed; waiting for the job to start.", e, section: .labels, defaults: unl) { LabelsSection() }

        e = engine()
        e.jobs = [job(e, "job-labels", .running, files: [], minutesAgo: 1, kind: "labels")]
        e.notes.suggestJobID = "job-labels"
        e.notes.suggestTotal = 7
        e.notes.fixtureProgress["job-labels"] = LabelsProgress(message: "Suggesting labels", done: 3, total: 7,
                                                               startedAt: Date().addingTimeInterval(-41), model: "haiku", finished: false, error: nil)
        main("labels-suggest-progress", f, "Labels", "Suggesting · N of M", "Suggesting labels · 3 of 7 with a progress bar and Stop.", e, section: .labels, defaults: unl) { LabelsSection() }

        e = engine()
        e.jobs = [job(e, "job-labels", .failed, files: [], minutesAgo: 3, kind: "labels", error: "Claude Code exited: usage limit reached.")]
        e.notes.suggestJobID = "job-labels"
        main("labels-suggest-failed", f, "Labels", "Suggesting · failed", "Couldn't suggest labels; notes unchanged.", e, section: .labels, defaults: unl) { LabelsSection() }

        e = engine()
        e.jobs = [awaiting(e, id: "job-labels", kind: nil, files: ["wiki/notes/kettle-presets.md"], summary: "Labels for 7 notes.")]
        e.notes.suggestJobID = "job-labels"
        main("labels-suggest-ready", f, "Labels", "Suggesting · ready in Review", "AI labels are ready; approve them in Review.", e, section: .labels, defaults: unl) { LabelsSection() }

        e = engine()
        e.notes.confirmJobID = "pending"
        main("labels-preparing", f, "Labels", "Confirm · preparing", "Confirm pressed: rows lock, “Preparing the change…”.", e, section: .labels) { LabelsSection() }

        e = engine()
        e.jobs = [awaiting(e, id: "job-confirm", kind: nil, files: ["wiki/meetings/q3-architecture-sync.md"], summary: "Confirm labels on 4 notes.")]
        e.notes.confirmJobID = "job-confirm"
        main("labels-sent-to-review", f, "Labels", "Confirm · sent to Review", "The change waits in Review (footer note, Review badge).", e, section: .labels) { LabelsSection() }
    }
}

// MARK: - Flow 4: Flask, hover menu, quick ask, quick note

extension StatesSnapshot {
    static func flaskStates() {
        let f = Flow.flask
        func flask(_ file: String, _ state: String, _ desc: String, targeted: Bool = false, _ setup: (AppModel) -> Void) {
            let e = engine()
            e.queued = []
            setup(e)
            let drop = DropState()
            drop.targeted = targeted
            natural(file, f, "Floating flask", state, desc, e) { FloatingFace(dropState: drop) }
        }
        flask("flask-idle", "Idle", "Nothing queued or running.") { _ in }
        flask("flask-queue", "Has queue", "Files waiting: blue count badge, liquid rises.") { $0.queued = queue($0.settings) }
        flask("flask-working", "Working", "A batch runs: blue ring, bubbling liquid.") { e in
            e.jobs = [job(e, "job-run", .running, files: ["inbox/a.md"], minutesAgo: 1)]
        }
        flask("flask-needs-review", "Needs review", "A job waits for approval: peach liquid and badge.") { e in e.jobs = [awaiting(e)] }
        flask("flask-green-ring", "Quick answer on its way", "A quick-ask question still answering after its window closed: green ring.") { e in
            e.ask.quickVisible = false
            let id = "quick-bg"
            e.ask.background[id] = BackgroundAsk(
                id: id, token: UUID(),
                pending: PendingQuestion(question: "Best water temp for sencha?", startedAt: Date().addingTimeInterval(-6),
                                         request: AskRequest(question: "Best water temp for sencha?"), status: .running),
                isNew: true, task: nil, origin: .quick)
        }
        flask("flask-drop-target", "Drop target", "A file is dragged over the flask.", targeted: true) { _ in }

        let e = engine()
        for (bottom, trailing, name, desc) in [(true, true, "flask-hover-menu", "Flask in the lower right: pills fan up and left."),
                                               (true, false, "flask-hover-menu-left", "Flask in the lower left: pills fan up and right."),
                                               (false, true, "flask-hover-menu-top", "Flask in the upper right: pills fan down and left."),
                                               (false, false, "flask-hover-menu-top-left", "Flask in the upper left: pills fan down and right.")] {
            natural(name, f, "Hover menu", "Open · \(bottom ? "below" : "above") center, \(trailing ? "right" : "left") side", desc, e) {
                HStack(alignment: bottom ? .bottom : .top, spacing: -12) {
                    if trailing {
                        HoverMenuView(alignTrailing: true, bottomAligned: bottom) { _ in }.frame(width: 236, height: 228)
                        FloatingFace(dropState: DropState())
                    } else {
                        FloatingFace(dropState: DropState())
                        HoverMenuView(alignTrailing: false, bottomAligned: bottom) { _ in }.frame(width: 236, height: 228)
                    }
                }
            }
        }
    }

    static func quickAskStates() {
        let f = Flow.flask
        func quick(_ file: String, _ state: String, _ desc: String, _ setup: (AskThread) -> Void) {
            let e = engine()
            setup(e.ask.quick)
            quickWindow(file, f, "Quick ask", state, desc, e, padding: 8) { QuickAskView(onDesiredHeight: $0) }
        }
        quick("quickask-empty", "Empty", "Just opened: all notes, model chip, + Limit.") { $0.reset(filter: AskFilter()) }
        quick("quickask-limited", "Limited by labels", "Two labels and a source: Any/All, Include unconfirmed, page count.") { t in
            t.reset(filter: AskFilter())
            t.filter.addLabel("project-x"); t.filter.addLabel("incidents"); t.filter.addSource("slack")
            t.selection = ModelSelection(runnerID: "claude-code", model: "haiku", effort: "low")
            let r = AskResponse(conversationID: "q2", answer: "Cap retries at 3 with jittered backoff; stop on 503 [1].",
                                citations: [AskCitation(n: 1, path: "wiki/notes/Retry policy.md", title: "Retry policy")],
                                notices: ["Limited to 6 pages (2 unconfirmed)."])
            t.entries = [AskEntry(question: "What did we decide about retries?", askedAt: Date(),
                                  request: AskRequest(question: "What did we decide about retries?"), response: r)]
        }
        do {
            let e = engine()
            let t = e.ask.quick
            t.reset(filter: AskFilter())
            let r = AskResponse(conversationID: "q3", answer: "70–80 °C for sencha. Boiling water pulls out bitter catechins [1].",
                                citations: [AskCitation(n: 1, path: "wiki/sources/Brewing Green Tea.md", title: "Brewing Green Tea")])
            t.entries = [AskEntry(question: "Best water temp for sencha?", askedAt: Date(), request: AskRequest(question: "Best water temp for sencha?"), response: r)]
            natural("quickask-resized", f, "Quick ask", "Dragged taller", "The answer takes the extra height; the model and filter row stays right above the footer.", e, padding: 8) {
                QuickAskView().frame(width: QuickWindowGeometry.defaultWidth, height: 440)
            }
        }
        quick("quickask-loading", "Answering", "Spinner, the question, shimmer, elapsed time and Stop.") { t in
            AskFixtures.loading(t, question: "Best water temp for sencha?", model: "haiku", effort: "low", seconds: 6)
            t.filter = AskFilter()
        }
        quick("quickask-answered", "Answered", "Short answer, compact citations, a gap, Continue in Distill.") { t in
            t.reset(filter: AskFilter())
            t.selection = ModelSelection(runnerID: "claude-code", model: "sonnet", effort: "medium")
            let r = AskResponse(conversationID: "q1", answer: "70–80 °C for sencha. Boiling water pulls out bitter catechins [1]; gyokuro wants it cooler [2].",
                                citations: [AskCitation(n: 1, path: "wiki/sources/Brewing Green Tea.md", title: "Brewing Green Tea"),
                                            AskCitation(n: 2, path: "wiki/notes/Tea club thread.md", title: "Tea club thread")],
                                gaps: ["no exact temperature for gyokuro."])
            t.entries = [AskEntry(question: "Best water temp for sencha?", askedAt: Date(), request: AskRequest(question: "Best water temp for sencha?"), response: r)]
        }
        quick("quickask-stopped", "Stopped", "Stopped; Ask again.") { t in
            AskFixtures.loading(t, question: "Best water temp for sencha?", model: "haiku", effort: "low", seconds: 6)
            t.filter = AskFilter()
            t.pending?.status = .stopped
        }
        quick("quickask-error", "Error", "Couldn't get an answer; Retry.") { t in
            AskFixtures.loading(t, question: "Best water temp for sencha?", model: "haiku", effort: "low", seconds: 6)
            t.filter = AskFilter()
            t.pending?.status = .failed("Cannot reach the Distill core: connection refused.")
        }
    }

    static func quickNoteStates() {
        let f = Flow.flask
        let suggestions = [LabelSuggestion(name: "tea", existing: true), LabelSuggestion(name: "gyokuro", existing: true),
                           LabelSuggestion(name: "tea-shops", existing: false)]
        func draft(images: Int = 1) -> ComposeDraft {
            var d = ComposeDraft()
            d.title = "Gyokuro at 60 °C"
            d.text = "Shop recommended 60 °C, 2 min first steep."
            d.group = "discussion"
            d.source = "in-person"
            d.images = Array([image("brewing-card.png"), image("teapot.jpg", bytes: 860_000)].prefix(images))
            d.text += d.images.map { "\n" + ComposeDraft.embed($0.name) }.joined()
            return d
        }
        func step(_ edit: (inout LabelStep) -> Void = { _ in }) -> LabelStep {
            var s = LabelStep(requestID: "q1", title: "Gyokuro at 60 °C", suggesting: true, startedAt: Date().addingTimeInterval(-3))
            edit(&s)
            return s
        }
        func shot(_ file: String, _ state: String, _ desc: String, height: CGFloat? = nil, _ setup: (NotesStore) -> Void) {
            let e = engine()
            e.notes.drafts[.quick] = draft()
            setup(e.notes)
            quickWindow(file, f, "Quick note", state, desc, e) { QuickNoteView(close: {}, onDesiredHeight: $0) }
        }
        shot("quicknote-empty", "Empty", "Just opened: title, text, + Source.") { $0.drafts[.quick] = ComposeDraft() }
        shot("quicknote-typing", "Typing", "Text and a source; no images.") { $0.drafts[.quick] = draft(images: 0) }
        shot("quicknote-images", "Images", "Two images inside the text.", height: 560) { $0.drafts[.quick] = draft(images: 2) }
        shot("quicknote-image-hover", "Image · hover", "Same rules as Write a note: hover for Extract content and ×.", height: 360) {
            $0.drafts[.quick] = draft(); $0.imageFixtures[.quick] = InlineImageFixture(hovered: "brewing-card.png")
        }
        shot("quicknote-image-reading", "Image · reading", "Reading with Haiku…; Add to queue waits.", height: 360) {
            var d = draft(); d.imageStates["brewing-card.png"] = .reading(model: "Haiku"); $0.drafts[.quick] = d
        }
        shot("quicknote-image-extracted", "Image · extracted", "The image's text replaced it in place; the window resizes to the new content.", height: 360) {
            var d = draft()
            d.text = d.text.replacingOccurrences(of: "![[brewing-card.png]]", with: extractedCard)
            $0.drafts[.quick] = d
            $0.imageFixtures[.quick] = InlineImageFixture(extracted: (extractedCard, "brewing-card.png", "Haiku"))
        }
        do {
            let e = engine()
            e.notes.drafts[.quick] = draft(images: 0)
            natural("quicknote-resized", f, "Quick note", "Dragged taller", "The text area takes the extra height; the source and footer stay at the bottom.", e) {
                QuickNoteView(close: {}).frame(width: QuickWindowGeometry.defaultWidth, height: 420)
            }
        }
        shot("quicknote-adding", "Adding…", "Add to queue pressed.") { $0.adding = [.quick] }
        shot("quicknote-add-error", "Add failed", "The core refused; the draft stays.") { $0.addErrors[.quick] = "Cannot reach the Distill core: connection refused" }
        shot("quicknote-suggesting", "Label step · suggesting", "Queued ✓; suggestions on the way; type a label while you wait.") { $0.steps[.quick] = step() }
        shot("quicknote-suggestions", "Label step · suggestions", "Suggested labels with Apply.") {
            $0.steps[.quick] = step { s in s.received(requestID: "q1", labels: suggestions, error: nil) }
        }
        shot("quicknote-applying", "Label step · applying", "Applying…") {
            $0.steps[.quick] = step { s in s.received(requestID: "q1", labels: suggestions, error: nil); s.applyStarted() }
        }
        shot("quicknote-applied", "Label step · applied", "Labels applied; the window closes a moment later.") {
            $0.steps[.quick] = step { s in s.received(requestID: "q1", labels: suggestions, error: nil); s.applyStarted(); s.applySucceeded(labels: ["tea", "gyokuro", "tea-shops"]) }
        }
        shot("quicknote-suggest-error", "Label step · suggestions failed", "Couldn't get labels; add your own.") {
            $0.steps[.quick] = step { s in s.received(requestID: "q1", labels: [], error: "OpenRouter answered 401 (check the API key).") }
        }
        shot("quicknote-too-late", "Label step · too late", "The batch already took the note.") {
            $0.steps[.quick] = step { s in
                s.received(requestID: "q1", labels: suggestions, error: nil); s.applyStarted()
                s.applyFailed(CoreClientError.api(status: 409, code: "invalid_state", message: "note already taken by a batch"))
            }
        }
    }
}

// MARK: - Flow 5: Settings and app

extension StatesSnapshot {
    static func settingsStates() {
        let f = Flow.app
        func settings(_ file: String, _ state: String, _ desc: String, target: SettingsTarget = SettingsTarget(.vaults), advanced: Bool = false,
                      width: CGFloat = settingsSize.width, defaults: [String: Any] = [:], _ e: AppModel) {
            // A whole page: measure the stacked (snapshot-mode) layout, then draw
            // the live window that tall so its scroll view shows everything.
            e.settingsUI.target = target
            let measure = ImageRenderer(content: SettingsView(showAdvanced: advanced).environmentObject(e)
                .environment(\.snapshotMode, true).frame(width: width).fixedSize(horizontal: false, vertical: true))
            let height = max(settingsSize.height, ((measure.nsImage?.size.height ?? 2400) + (advanced ? 160 : 40)).rounded(.up))
            settingsWindow(file, state, desc, e, target: target,
                           size: CGSize(width: width, height: height), advanced: advanced, defaults: defaults)
        }
        let busy: (AppModel) -> Void = { $0.notes.runnerBusy = ["openai": "Checking…"] }
        var e: AppModel
        // One page per section and per action type, whole, at the minimum width and
        // the usual ~890 pt: nothing clipped, rows reflow, the nav is never cut off.
        // (`settings-nav-*` shows each page's top at the default 1140 pt.)
        let minWidth = SettingsWindowSize.minimum.width
        for (suffix, width) in [("min", minWidth), ("890", 890)] {
            for section in SettingsSection.allCases {
                e = engine { $0.enabledRunners = ["claude-code", "ai-sdk"] }
                busy(e)
                if section == .connections {
                    e.settingsUI.connections = [ConnectionInfo(id: "atlassian", label: "Atlassian", status: .notConnected, site: nil, account: nil,
                                                               message: nil, usedBy: ["jira", "confluence"])]
                    e.settingsUI.connectionsLoad = .loaded
                }
                settings("settings-page-\(section.rawValue)-\(suffix)", "\(section.title) · \(Int(width)) pt wide",
                         "The \(section.title) page alone: its title and note, then its content. Rows reflow to fit; no label is cut.",
                         target: SettingsTarget(section), width: width, e)
            }
            for type in SettingsActionType.builtIn where !type.reserved && type.id != "todo" {
                e = engine()
                settings("settings-type-\(type.id)-\(suffix)", "Actions › \(type.label) · \(Int(width)) pt wide", "Rows keep their controls; prompts fit.",
                         target: SettingsTarget(.actions, actionType: type.id), width: width, e)
            }
        }

        e = engine { $0.enabledRunners = ["claude-code", "ai-sdk"] }
        settings("settings-advanced", "Advanced expanded", "End of the AI runners page. Advanced: model, paths, extra allowed tools.",
                 target: SettingsTarget(.advancedHome), advanced: true, e)

        e = engine()
        e.notes.runners = []
        e.notes.runnersLoading = true
        problem(e, [nodeMissing, "The claude CLI was not found at /Users/me/.local/bin/claude."])
        settings("settings-problems", "Setup problems · runners loading", "Problems block at the top of the AI runners page; runner cards shimmer while loading.",
                 target: SettingsTarget(.runners), e)

        e = engine()
        e.notes.runners = []
        e.notes.labelCounts = []
        problem(e, [], connection: .unreachable(coreDown))
        settings("settings-disconnected", "Core not running", "Labels page: no labels until the core is connected; Retry at the top. Also shows “Suggest labels after a note is queued” switched off.",
                 target: SettingsTarget(.labels), defaults: [AppModel.suggestAfterQueueKey: false], e)

        // Sections in their other states.
        e = engine { $0.enabledRunners = ["claude-code", "codex"] }
        e.notes.runnerBusy = ["openrouter": "Saving…", "codex": "Checking…"]
        natural("settings-runners-busy", f, "Settings · AI runners", "Saving key / checking", "OpenRouter saving its key to the Keychain; Codex being checked after turning on.", e) {
            RunnersSettings(notes: e.notes).frame(width: 640)
        }
        e = engine()
        e.notes.clearingHistory = true
        natural("settings-history-clearing", f, "Settings · Ask history", "Clearing…", "Clear now pressed.", e) { AskHistorySettings(notes: e.notes).frame(width: 640) }
        e = engine { SettingsEdits.setAsk(&$0) { $0.keepHistory = false; $0.historyDays = 30 } }
        e.notes.historyMessage = "Deleted 3 chats."
        natural("settings-history-cleared", f, "Settings · Ask history", "Cleared · keep off", "Result message; Keep turned off.", e) { AskHistorySettings(notes: e.notes).frame(width: 640) }

        e = engine()
        let set = KeyShortcut("ctrl+opt+space")
        for (file, state, desc, shortcut, recording, hint) in [
            ("shortcut-empty", "Not set", "Dashed “Record shortcut”.", nil, false, nil),
            ("shortcut-recording", "Recording", "“Press keys…” while recording.", nil, true, nil),
            ("shortcut-needs-modifier", "Recording · needs modifier", "A key without ⌃, ⌥ or ⌘ was pressed.", nil, true, "Add ⌃, ⌥ or ⌘"),
            ("shortcut-set", "Set", "⌃⌥Space with × to clear.", set, false, nil),
        ] as [(String, String, String, KeyShortcut?, Bool, String?)] {
            natural(file, f, "Settings · Shortcut recorder", state, desc, e) {
                ShortcutRecorder(shortcut: .constant(shortcut), label: "Ask a question", recording: recording, hint: hint)
            }
        }

        // Sheets.
        func sheet(_ file: String, _ runner: String, _ state: String, _ desc: String, saving: String? = nil, errors: [String: String] = [:],
                   _ edit: (inout [RunnerInfo]) -> Void = { _ in }) {
            let e = engine()
            edit(&e.notes.runners)
            natural(file, f, "Runner set-up sheet", state, desc, e) { RunnerSetupSheet(runnerID: runner, done: {}, saving: saving, errors: errors).background(Color.white) }
        }
        sheet("setup-sheet-key-needed", "openrouter", "Key needed", "OpenRouter: paste an API key.")
        sheet("setup-sheet-saving", "openrouter", "Saving", "Saving the key to the Keychain.", saving: "apiKey")
        sheet("setup-sheet-error", "openrouter", "Error", "The core refused the key.", errors: ["apiKey": "The Keychain refused the item (errSecAuthFailed)."])
        sheet("setup-sheet-saved", "openai", "Key saved", "Key in the Keychain: replace or Remove.")
        sheet("setup-sheet-options", "ai-sdk", "Options and problem", "Vercel AI SDK: key, bridge options and a reported problem.")

        e = engine()
        if let vault = e.settings.vaults.first {
            natural("vault-editor", f, "Vault editor sheet", "Edit vault", "Queue folder, use inbox, remove.", e) { VaultEditor(vault: vault, done: {}).background(Color.white) }
        }

        // Vault switcher (sidebar foot) states.
        func switcher(_ file: String, _ state: String, _ desc: String, _ edit: (inout DistillKit.Settings) -> Void = { _ in }, _ setup: (AppModel) -> Void = { _ in }) {
            let e = engine(edit)
            setup(e)
            natural(file, f, "Vault switcher", state, desc, e) { VaultSwitcher(openSettings: {}).frame(width: 192).padding(14).background(Theme.panel) }
        }
        switcher("vault-switcher-ready", "Ready", "Active vault, model · ready.")
        switcher("vault-switcher-working", "Working", "A batch runs.") { _ in } _: { e in e.jobs = [job(e, "j", .running, files: ["inbox/a.md"], minutesAgo: 1)] }
        switcher("vault-switcher-waiting", "Waiting on you", "A job waits in Review.") { _ in } _: { e in e.jobs = [awaiting(e)] }
        switcher("vault-switcher-setup", "Needs setup", "The core reports a setup problem.") { _ in } _: { e in problem(e, [nodeMissing]) }
        switcher("vault-switcher-none", "No vault", "Choose a vault.") { $0.activeVaultPath = nil; $0.vaults = [] }
    }
}
