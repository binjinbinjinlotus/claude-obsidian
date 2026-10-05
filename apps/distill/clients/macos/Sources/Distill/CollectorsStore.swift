import AppKit
import Combine
import DistillKit
import Foundation

/// A schedule being edited: a preset plus a time, or a cron for Custom.
struct ScheduleDraft: Equatable {
    var preset: SchedulePreset = .hourly
    var hour = 9
    var minute = 0
    var customCron = ""

    init(preset: SchedulePreset = .hourly, hour: Int = 9, minute: Int = 0, customCron: String = "") {
        self.preset = preset; self.hour = hour; self.minute = minute; self.customCron = customCron
    }

    init(_ schedule: CollectorSchedule) {
        if let s = CollectorText.shape(schedule.cron), s.preset != .custom {
            self.init(preset: s.preset, hour: s.preset == .daily || s.preset == .weekdays ? s.hour : 9, minute: s.minute)
        } else {
            self.init(preset: .custom, customCron: schedule.cron)
        }
    }

    var cron: String {
        preset == .custom ? customCron.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "  ", with: " ")
            : CollectorText.cron(preset: preset, hour: hour, minute: minute)
    }
    var schedule: CollectorSchedule { CollectorSchedule(cron: cron, preset: preset) }
    var hasTime: Bool { preset == .daily || preset == .weekdays }

    /// Editing the cron (Advanced) switches to Custom unless it is a preset's cron.
    mutating func setCron(_ raw: String) {
        if let s = CollectorText.shape(raw), s.preset != .custom, CollectorText.cron(preset: s.preset, hour: s.hour, minute: s.minute) == raw {
            preset = s.preset; hour = s.hour; minute = s.minute
        } else {
            preset = .custom; customCron = raw
        }
    }
}

/// The Add sheet (three steps).
struct AddDraft: Equatable {
    var step = 1
    var kind: CollectorKind = .folder
    var folderPath = "~/Distill Inbox"
    var afterCollect = "copy"
    /// v5: new collectors take each subfolder as one folder item (as designed); always sent.
    var includeSubfolders = true
    var scriptInline = true
    var scriptFile = ""
    var code = ScriptTemplates.code(.zsh)
    var interpreter: CollectorInterpreter = .zsh
    /// v6: the package manifest's text (package.json / requirements.txt), kept by Distill next to the script.
    var manifest = ""
    var schedule = ScheduleDraft()
    var vaultPath = ""
    var name = ""

    /// v6: "Kept by Distill" (a managed file written from `code`) or "Your own file".
    var managed: Bool {
        get { scriptInline }
        set { scriptInline = newValue }
    }

    /// The language picker: an untouched template follows the language.
    mutating func setLanguage(_ i: CollectorInterpreter) {
        if code == ScriptTemplates.code(interpreter) || code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { code = ScriptTemplates.code(i) }
        if interpreter.manifestName != i.manifestName { manifest = "" }
        interpreter = i
    }
}

/// Starting code for a new script Distill keeps, per language (it writes into the queue folder, `$2`).
enum ScriptTemplates {
    static func code(_ i: CollectorInterpreter) -> String {
        switch i.rawValue {
        case "python3":
            return "import sys, pathlib\n# Write files into the queue folder (argv[2], or DISTILL_QUEUE_DIR).\nqueue = pathlib.Path(sys.argv[2])\n"
        case "node":
            return "import { writeFile } from 'node:fs/promises';\n// Write files into the queue folder (argv[3], or DISTILL_QUEUE_DIR).\nconst queue = process.argv[3];\n"
        case "typescript":
            return "import { writeFile } from 'node:fs/promises';\n// Write files into the queue folder (argv[3], or DISTILL_QUEUE_DIR).\nconst queue: string = process.argv[3];\n"
        default:
            return "#!/bin/zsh\n# Write files into the queue folder ($2, or $DISTILL_QUEUE_DIR).\n"
        }
    }
}

/// The settings form (Edit), in place of the read-only block.
struct CollectorDraft: Equatable {
    var folderPath = ""
    var afterCollect = "copy"
    var includeSubfolders = false
    var vaultPath = ""
    var schedule = ScheduleDraft()
    var scriptInline = false
    var scriptFile = ""
    var code = ""
    var interpreter: CollectorInterpreter = .zsh
    var timeoutSeconds = 300
    var advancedOpen = false

    // v6 (a core with script files: `status.script`). The script field is "Kept by Distill" (`managed`,
    // code and manifest edited here and saved with PUT …/script) or "Your own file" (a path).
    var v6 = false
    var managed = false
    /// The files as loaded (GET …/script); nil until they arrive. Their hashes guard the save.
    var loaded: CollectorScriptFiles?
    var manifest = ""
    /// "Schedule and Advanced" opened in a script's form.
    var scheduleOpen = false

    init() {}

    init(_ c: Collector, text: CollectorText) {
        folderPath = text.tilde(c.folder?.source ?? "")
        afterCollect = c.folder?.afterCollect ?? "copy"
        includeSubfolders = c.folder?.subfolders ?? false
        vaultPath = c.vaultPath
        schedule = ScheduleDraft(c.schedule)
        if let s = c.script {
            scriptInline = s.source.inlineCode != nil
            scriptFile = text.tilde(s.source.filePath ?? "")
            code = s.source.inlineCode ?? ""
            interpreter = s.interpreter
            timeoutSeconds = s.timeoutSeconds
            v6 = c.status?.script != nil
            managed = c.isManaged
            if managed { scriptFile = "" }
        }
    }

    /// Take the files as loaded: the editor starts from them (and saves against their hashes).
    mutating func take(_ files: CollectorScriptFiles) {
        loaded = files
        if managed {
            code = files.code ?? ""
            manifest = files.manifest?.text ?? ""
        }
    }

    /// The language picker. The manifest follows the language's kind: the loaded one when it is that
    /// kind, else empty (the new kind's file is read after Save).
    mutating func setLanguage(_ i: CollectorInterpreter) {
        let before = interpreter.manifestName
        interpreter = i
        guard before != i.manifestName else { return }
        manifest = loaded?.manifest?.name == i.manifestName ? (loaded?.manifest?.text ?? "") : ""
    }

    /// The code or manifest differs from what was loaded.
    var codeChanged: Bool { managed && loaded != nil && code != (loaded?.code ?? "") }
    var manifestChanged: Bool { managed && loaded != nil && manifest != (loaded?.manifest?.text ?? "") }

    /// v6: the PUT for a script that stays kept by Distill: only what changed, with the loaded hashes.
    func scriptUpdate(stillManaged: Bool) -> CollectorScriptUpdate? {
        guard v6, managed, stillManaged, let loaded else { return nil }
        var u = CollectorScriptUpdate()
        if code != (loaded.code ?? "") { u.code = code; u.baseSha256 = loaded.sha256 }
        if let m = loaded.manifest, manifest != (m.text ?? "") {
            let empty = manifest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            // An emptied manifest that never existed sends nothing; one that existed is removed.
            if !(empty && m.text == nil) {
                u.manifest = .some(empty ? nil : manifest)
                u.baseManifestSha256 = .some(m.sha256)
            }
        }
        return u.isEmpty ? nil : u
    }

    /// Only what changed.
    func patch(from c: Collector, text: CollectorText) -> CollectorPatch {
        if v6, c.isScript { return patchV6(from: c, text: text) }
        var p = CollectorPatch()
        if vaultPath != c.vaultPath { p.vaultPath = vaultPath }
        if schedule.cron != c.schedule.cron || schedule.preset != (c.schedule.preset ?? ScheduleDraft(c.schedule).preset) { p.schedule = schedule.schedule }
        if c.isFolder, let f = c.folder {
            let src = text.expand(folderPath)
            var fp = FolderPatch()
            if src != f.source { fp.source = src }
            if afterCollect != f.afterCollect { fp.afterCollect = afterCollect }
            if includeSubfolders != f.subfolders { fp.includeSubfolders = includeSubfolders }
            if fp != FolderPatch() { p.folder = fp }
        }
        if c.isScript, let s = c.script {
            var sp = ScriptPatch()
            let source: ScriptSource = scriptInline ? .inline(code) : .file(text.expand(scriptFile))
            if source != s.source { sp.source = source }
            if interpreter != s.interpreter { sp.interpreter = interpreter }
            if timeoutSeconds != s.timeoutSeconds { sp.timeoutSeconds = timeoutSeconds }
            if sp != ScriptPatch() { p.script = sp }
        }
        return p
    }

    /// v6 scripts: language, timeout, schedule, vault, and switching between kept by Distill and your own
    /// file. Code a kept script already has never goes through PATCH (PUT …/script carries it with the
    /// loaded hash, so an edit made in another editor isn't overwritten).
    private func patchV6(from c: Collector, text: CollectorText) -> CollectorPatch {
        var p = CollectorPatch()
        if vaultPath != c.vaultPath { p.vaultPath = vaultPath }
        if schedule.cron != c.schedule.cron || schedule.preset != (c.schedule.preset ?? ScheduleDraft(c.schedule).preset) { p.schedule = schedule.schedule }
        guard let s = c.script else { return p }
        var sp = ScriptPatch()
        if managed != c.isManaged {
            // To your own file: its path. To kept by Distill: the core writes this code to a new managed file.
            sp.source = managed ? .inline(code) : .file(text.expand(scriptFile))
        } else if !managed, text.expand(scriptFile) != (s.source.filePath ?? "") {
            sp.source = .file(text.expand(scriptFile))
        }
        if interpreter != s.interpreter { sp.interpreter = interpreter }
        if timeoutSeconds != s.timeoutSeconds { sp.timeoutSeconds = timeoutSeconds }
        if sp != ScriptPatch() { p.script = sp }
        return p
    }

    /// Saving asks for the OK again (a new script, language or manifest).
    func asksAgain(from c: Collector, text: CollectorText) -> Bool {
        guard c.isScript else { return false }
        if v6 {
            return codeChanged || manifestChanged || managed != c.isManaged || interpreter != c.script?.interpreter
                || (!managed && text.expand(scriptFile) != (c.script?.source.filePath ?? ""))
        }
        return scriptInline != (c.script?.source.inlineCode != nil) || (scriptInline && code != c.script?.source.inlineCode)
            || (!scriptInline && text.expand(scriptFile) != c.script?.source.filePath) || interpreter != c.script?.interpreter
    }
}

/// The Already collected sheet.
struct CollectedSheet: Equatable {
    var collectorID: String
    var query = ""
    var files: [CollectedFile] = []
    var loading = true
    /// Forgotten in this sheet, by sha256 (the row reads "Will be collected again" with Undo).
    var forgotten: [String: [CollectedFile]] = [:]
    var confirmForgetAll = false
    /// Snapshots: the row drawn as hovered.
    var hover: String?
}

/// Collectors for the whole app (canvas row 7). The core owns collectors, runs
/// and the ledger; this mirrors them (GET + `collector.*` events) and sends commands.
@MainActor
final class CollectorsStore: ObservableObject {
    enum Phase: Equatable { case idle, loading, loaded, unavailable, failed(String) }
    enum Page: Equatable { case overview, allRuns }

    @Published var collectors: [Collector] = []
    @Published var phase: Phase = .idle
    @Published var selected: String?
    @Published var page: Page = .overview
    /// Run history per collector (newest first).
    @Published var runs: [String: [CollectorRun]] = [:]
    /// The queued or running run per collector (from `collector.run.started`).
    @Published var live: [String: CollectorRun] = [:]
    /// Live output per run id.
    @Published var output: [String: (stdout: String, stderr: String)] = [:]
    /// Opened (expanded) run lines.
    @Published var openRuns: Set<String> = []
    /// The settings form, for the selected collector.
    @Published var editing: CollectorDraft?
    @Published var advancedOpen = false
    /// Scripts whose consent card was put aside with "Not now" (this app session only).
    @Published var consentDeferred: Set<String> = []
    @Published var adding: AddDraft?
    @Published var collected: CollectedSheet?
    @Published var renaming: String?
    @Published var confirmDelete: String?
    /// Script code read from a file source for the consent card, by path and hash.
    @Published var fileCode: [String: String] = [:]
    @Published var checks: [String: ScheduleCheck] = [:]
    /// Commands in flight by collector id ("run", "stop", "allow", "save", …).
    @Published var busy: [String: String] = [:]
    @Published var clock = Date()

    // v6: packages, Test run, the manual run's result.
    /// The newest install per collector (events, or `GET …/install` for a failed one's output).
    @Published var installs: [String: CollectorInstall] = [:]
    /// Live install output by install id (the last 64 KB).
    @Published var installOutput: [String: String] = [:]
    /// The run the user started here (Run now, Allow and run, Test run) per collector: its result
    /// shows in the status card until Hide or a newer run.
    @Published var shown: [String: String] = [:]
    /// Test runs whose output is open in the status card.
    @Published var testOutputOpen: Set<String> = []
    /// Saving the editor met a file changed on disk (409): the message, per collector.
    @Published var conflict: [String: String] = [:]
    /// The files a consent card shows (code and manifest), per collector and hash.
    @Published var consentFiles: [String: CollectorScriptFiles] = [:]
    /// Snapshots: file sizes for a test run's files (the app stats the scratch folder).
    var fixtureSizes: [String: Int]?
    /// Snapshots: the Add sheet's managed path shows this state dir.
    var stateDir: String?

    /// Snapshots: fixed clock, home and in-place menus.
    var fixtureNow: Date?
    var fixtureMenu = false
    var text = CollectorText()

    private var ticker: Task<Void, Never>?
    weak var engine: AppModel?
    fileprivate static var stores: [ObjectIdentifier: CollectorsStore] = [:]

    static func of(_ engine: AppModel) -> CollectorsStore {
        let key = ObjectIdentifier(engine)
        if let s = stores[key] { return s }
        let s = CollectorsStore()
        s.engine = engine
        stores[key] = s
        return s
    }

    var now: Date { fixtureNow ?? clock }
    var client: CoreClient? { engine?.client }

    // MARK: Derived

    /// Collectors that need the user (sidebar count).
    var alertCount: Int { phase == .unavailable ? 0 : collectors.filter(\.needsAttention).count }
    var current: Collector? { collectors.first { $0.id == selected } ?? collectors.first }
    func collector(_ id: String) -> Collector? { collectors.first { $0.id == id } }

    func vaultName(_ path: String) -> String {
        engine?.settings.vaults.first { $0.path == path }?.name ?? (path as NSString).lastPathComponent
    }
    func queuePath(_ vaultPath: String) -> String? {
        engine?.settings.vaults.first { $0.path == vaultPath }?.queueDirectory
    }

    /// The running (or queued) run of a collector.
    func activeRun(_ c: Collector) -> CollectorRun? {
        if let r = live[c.id], r.result.isActive { return r }
        if let r = runs[c.id]?.first(where: { $0.result.isActive }) { return r }
        if let r = c.lastRun, r.result.isActive { return r }
        return nil
    }

    func recentRuns(_ c: Collector) -> [CollectorRun] {
        let list = runs[c.id] ?? c.lastRun.map { [$0] } ?? []
        return list.filter { !$0.result.isActive }
    }

    /// The newest finished run the app knows, Test runs included (for the list row).
    func latestRun(_ c: Collector) -> CollectorRun? {
        let list = recentRuns(c)
        let test = c.status?.script?.lastTestRun
        guard let first = list.first else { return test }
        if let test, test.startedAt > first.startedAt { return test }
        return first
    }

    /// The finished run whose result the status card shows (started here, not hidden, nothing newer).
    func shownRun(_ c: Collector) -> CollectorRun? {
        guard let id = shown[c.id], let run = runs[c.id]?.first(where: { $0.id == id }), !run.result.isActive else { return nil }
        if let newer = recentRuns(c).first, newer.id != run.id, newer.startedAt > run.startedAt { return nil }
        return run
    }

    // MARK: Loading

    func load() {
        guard let client, phase != .loading else { return }
        if phase != .loaded { phase = .loading }
        Task {
            do {
                let list = try await client.collectors()
                collectors = list
                phase = .loaded
                if let id = selected ?? list.first?.id { loadRuns(id) }
                startTicker()
            } catch let e as CoreClientError where e.isNotAvailable {
                phase = .unavailable
            } catch {
                if phase != .loaded { phase = .failed("\(error)") }
            }
        }
    }

    func refresh(_ id: String) {
        guard let client else { return }
        Task {
            if let c = try? await client.collector(id) { upsert(c) }
        }
    }

    func loadRuns(_ id: String) {
        guard let client else { return }
        Task {
            if let list = try? await client.collectorRuns(id, limit: 50) { runs[id] = list }
        }
    }

    func select(_ id: String) {
        guard selected != id else { return }
        selected = id
        page = .overview
        editing = nil
        advancedOpen = false
        openRuns = []
        loadRuns(id)
        // A file script may have changed on disk without an event: ask again.
        refresh(id)
    }

    func upsert(_ c: Collector) {
        if let i = collectors.firstIndex(where: { $0.id == c.id }) { collectors[i] = c } else { collectors.append(c) }
        // A failed install's card shows its output, which only GET …/install carries.
        if installFailedNeedsOutput(c) { loadInstall(c.id) }
    }

    /// One-second clock while something runs (elapsed time in rows and the status card).
    private func startTicker() {
        guard ticker == nil, fixtureNow == nil else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self else { return }
                if self.collectors.contains(where: { $0.isRunning || $0.isInstalling }) { self.clock = Date() }
            }
        }
    }

    // MARK: Events (wired in AppModel.apply)

    func apply(_ c: Collector, deleted: Bool) {
        if deleted {
            collectors.removeAll { $0.id == c.id }
            runs[c.id] = nil
            if selected == c.id { selected = collectors.first?.id; editing = nil; page = .overview }
            return
        }
        upsert(c)
        if phase == .idle { phase = .loaded }
    }

    func runStarted(_ run: CollectorRun) {
        live[run.collectorId] = run
        var list = runs[run.collectorId] ?? []
        list.removeAll { $0.id == run.id }
        list.insert(run, at: 0)
        runs[run.collectorId] = list
        clock = Date()
    }

    func runOutput(collectorId: String, runId: String, stream: String, text: String) {
        var o = output[runId] ?? ("", "")
        if stream == "stderr" { o.stderr = String((o.stderr + text).suffix(64 * 1024)) } else { o.stdout = String((o.stdout + text).suffix(64 * 1024)) }
        output[runId] = o
    }

    func runFinished(_ run: CollectorRun) {
        live[run.collectorId] = nil
        var list = runs[run.collectorId] ?? []
        list.removeAll { $0.id == run.id }
        list.insert(run, at: 0)
        runs[run.collectorId] = list
        output[run.id] = nil
        busy[run.collectorId] = nil
        // The status (lastRun, lastTestRun, the sidebar count) follows the run.
        refresh(run.collectorId)
    }

    // MARK: Commands

    func perform(_ id: String, _ what: String, _ op: @escaping (CoreClient) async throws -> Void) {
        guard let client else { return }
        busy[id] = what
        Task {
            defer { if busy[id] == what { busy[id] = nil } }
            do { try await op(client) } catch { engine?.report(error) }
        }
    }

    func setEnabled(_ c: Collector, _ on: Bool) {
        if on, c.needsConsent { return }
        if let i = collectors.firstIndex(where: { $0.id == c.id }) { collectors[i].enabled = on }
        perform(c.id, "toggle") { [weak self] client in
            let updated = try await client.updateCollector(c.id, CollectorPatch(enabled: on))
            self?.upsert(updated)
        }
    }

    /// Run now. A script that waits for the user's OK is "Allow and run" instead.
    func runNow(_ c: Collector) {
        if c.needsConsent { allowAndRun(c); return }
        perform(c.id, "run") { [weak self] client in
            let run = try await client.runCollector(c.id)
            self?.started(run)
        }
    }

    /// Stop: the run, and while packages install, the install too (and the run waiting for it).
    func stop(_ c: Collector) {
        let installing = c.isInstalling
        perform(c.id, "stop") { client in
            if installing {
                _ = try await client.stopCollectorInstall(c.id)
                _ = try? await client.stopCollector(c.id) // the run that waited for it, if any
            } else {
                _ = try await client.stopCollector(c.id)
            }
        }
    }

    /// Allow the script's current version (the core's hash; never one computed here).
    func allow(_ c: Collector) {
        guard let sha = c.status?.currentSha256 else { return }
        perform(c.id, "allow") { [weak self] client in
            let updated = try await client.allowCollector(c.id, sha256: sha)
            self?.upsert(updated)
        }
    }

    func revoke(_ c: Collector) {
        perform(c.id, "revoke") { [weak self] client in
            let updated = try await client.revokeCollector(c.id)
            self?.upsert(updated)
        }
    }

    func startEdit(_ c: Collector) {
        selected = c.id
        page = .overview
        editing = CollectorDraft(c, text: text)
        editing?.advancedOpen = c.isScript && advancedOpen
        conflict[c.id] = nil
        if editing?.v6 == true { loadEditorFiles(c) }
    }

    /// The editor's files (code, manifest and their hashes) for a v6 script.
    func loadEditorFiles(_ c: Collector, keepText: Bool = false) {
        guard let client else { return }
        Task { [weak self] in
            guard let files = try? await client.collectorScript(c.id) else { return }
            guard let self, self.editing != nil, self.current?.id == c.id else { return }
            if keepText {
                // Keep editing: the user's text stays; the hashes move to what is on disk now.
                self.editing?.loaded = files
            } else {
                self.editing?.take(files)
            }
        }
    }

    func save(_ c: Collector) {
        guard let draft = editing else { return }
        let patch = draft.patch(from: c, text: text)
        let stillManaged = draft.managed && c.isManaged
        let update = draft.scriptUpdate(stillManaged: stillManaged)
        if patch.isEmpty && update == nil { editing = nil; return }
        conflict[c.id] = nil
        guard let client else { return }
        busy[c.id] = "save"
        Task { [weak self] in
            defer { if self?.busy[c.id] == "save" { self?.busy[c.id] = nil } }
            do {
                if !patch.isEmpty { self?.upsert(try await client.updateCollector(c.id, patch)) }
            } catch {
                self?.engine?.report(error)
                return
            }
            var update = update
            // A language change renames the script (same bytes, same hash). When the manifest kind changes
            // with it (requirements.txt ↔ package.json), the manifest typed here goes to the new kind's
            // file, against that file's hash on disk.
            if stillManaged, let old = c.script?.interpreter, old.manifestName != draft.interpreter.manifestName {
                update?.manifest = nil
                update?.baseManifestSha256 = nil
                let typed = draft.manifest.trimmingCharacters(in: .whitespacesAndNewlines)
                if !typed.isEmpty, draft.interpreter.manifestName != nil, let files = try? await client.collectorScript(c.id) {
                    var u = update ?? CollectorScriptUpdate()
                    u.manifest = .some(draft.manifest)
                    u.baseManifestSha256 = .some(files.manifest?.sha256)
                    update = u
                }
                if update?.isEmpty == true { update = nil }
            }
            if let update {
                do {
                    _ = try await client.saveCollectorScript(c.id, update)
                    if let fresh = try? await client.collector(c.id) { self?.upsert(fresh) }
                } catch let e as CoreClientError where e.status == 409 {
                    // Changed on disk since the editor loaded it: say so and keep the draft (Reload or Keep editing).
                    self?.conflict[c.id] = e.description
                    return
                } catch {
                    self?.engine?.report(error)
                    return
                }
            }
            self?.editing = nil
        }
    }

    func rename(_ c: Collector, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        renaming = nil
        guard !trimmed.isEmpty, trimmed != c.name else { return }
        perform(c.id, "rename") { [weak self] client in
            self?.upsert(try await client.updateCollector(c.id, CollectorPatch(name: trimmed)))
        }
    }

    func duplicate(_ c: Collector) {
        var input = NewCollectorInput(kind: c.kind, name: c.name + " copy", vaultPath: c.vaultPath, enabled: c.isFolder ? false : nil,
                                      schedule: c.schedule)
        if let f = c.folder { input.folder = FolderPatch(source: f.source, afterCollect: f.afterCollect, includeSubfolders: f.subfolders) }
        if let s = c.script { input.script = .init(source: s.source, interpreter: s.interpreter, timeoutSeconds: s.timeoutSeconds) }
        perform(c.id, "duplicate") { [weak self] client in
            let created = try await client.createCollector(input)
            self?.upsert(created)
            self?.select(created.id)
        }
    }

    func delete(_ c: Collector) {
        confirmDelete = nil
        perform(c.id, "delete") { [weak self] client in
            try await client.deleteCollector(c.id)
            self?.apply(c, deleted: true)
        }
    }

    func createFolder(_ c: Collector, which: String) {
        perform(c.id, "create-\(which)") { [weak self] client in
            self?.upsert(try await client.createCollectorFolder(c.id, which: which))
        }
    }

    /// Choose a folder (NSOpenPanel); macOS asks for access when the folder needs it.
    func chooseFolder(start: String?, _ done: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if let start { panel.directoryURL = URL(fileURLWithPath: text.expand(start)) }
        if panel.runModal() == .OK, let url = panel.url { done(text.tilde(url.standardizedFileURL.path)) }
    }

    func chooseFile(_ done: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { done(text.tilde(url.standardizedFileURL.path)) }
    }

    /// Choose another source folder for a Folder collector and save it at once.
    func chooseSource(_ c: Collector) {
        chooseFolder(start: c.folder?.source) { [weak self] path in
            guard let self else { return }
            let src = self.text.expand(path)
            self.perform(c.id, "save") { client in
                self.upsert(try await client.updateCollector(c.id, CollectorPatch(folder: FolderPatch(source: src))))
            }
        }
    }

    /// The code shown in the consent card: inline code, or the file's text (read here only to show it).
    func code(_ c: Collector) -> String? {
        guard let s = c.script else { return nil }
        if let code = s.source.inlineCode { return code }
        guard let path = s.source.filePath else { return nil }
        // Keyed by the core's current hash too: a script edited on disk is read again, so the
        // consent card never shows an older version than the one Allow would allow.
        let key = path + "|" + (c.status?.currentSha256 ?? "")
        if let cached = fileCode[key] { return cached }
        let text = (try? String(contentsOfFile: path, encoding: .utf8)).map { String($0.prefix(64 * 1024)) }
        if let text { DispatchQueue.main.async { self.fileCode[key] = text } }
        return text
    }

    // MARK: Schedules

    /// Whether Save can be on for this cron: presets always; Custom after the core says it parses.
    func scheduleValid(_ draft: ScheduleDraft) -> Bool? {
        if draft.preset != .custom { return true }
        let cron = draft.cron
        if cron.isEmpty { return false }
        if let c = checks[cron] { return c.valid }
        check(cron)
        return nil
    }

    func check(_ cron: String) {
        guard let client, checks[cron] == nil else { return }
        Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            do { checks[cron] = try await client.checkSchedule(cron) } catch {}
        }
    }

    /// "next at 10:00 AM" for a draft (the core's answer for Custom; computed for presets).
    func nextPhrase(_ draft: ScheduleDraft, first: Bool = false) -> String {
        let next: Date?
        if let c = checks[draft.cron], let d = c.nextRuns.first { next = d } else { next = Self.nextRun(draft, after: now) }
        guard let next else { return "" }
        let phrase = text.next(next, now: now)
        return first ? phrase.replacingOccurrences(of: "next", with: "first run", options: .anchored) : phrase
    }

    /// The next run of a preset (local time); nil for Custom (the core answers).
    static func nextRun(_ d: ScheduleDraft, after now: Date, calendar: Calendar = .current) -> Date? {
        let start = calendar.date(bySetting: .second, value: 0, of: now) ?? now
        var t = calendar.date(byAdding: .minute, value: 1, to: start) ?? now
        t = calendar.date(bySetting: .second, value: 0, of: t) ?? t
        for _ in 0..<(8 * 24 * 60) {
            let c = calendar.dateComponents([.minute, .hour, .weekday], from: t)
            let m = c.minute ?? 0, h = c.hour ?? 0, wd = (c.weekday ?? 1) - 1
            switch d.preset {
            case .every15: if m % 15 == 0 { return t }
            case .hourly: if m == 0 { return t }
            case .daily: if m == d.minute && h == d.hour { return t }
            case .weekdays: if m == d.minute && h == d.hour && (1...5).contains(wd) { return t }
            default: return nil
            }
            t = t.addingTimeInterval(60)
        }
        return nil
    }

    // MARK: Add

    func startAdding(kind: CollectorKind? = nil) {
        var d = AddDraft()
        d.vaultPath = engine?.activeVault?.path ?? engine?.settings.vaults.first?.path ?? ""
        if let kind { d.kind = kind; d.step = 2 }
        adding = d
    }

    func finishAdding() {
        guard let d = adding else { return }
        var input = NewCollectorInput(kind: d.kind, vaultPath: d.vaultPath.isEmpty ? nil : d.vaultPath, schedule: d.schedule.schedule)
        if d.kind == .folder {
            let src = text.expand(d.folderPath)
            input.name = d.name.isEmpty ? (src as NSString).lastPathComponent : d.name
            input.enabled = true
            input.folder = FolderPatch(source: src, afterCollect: d.afterCollect, includeSubfolders: d.includeSubfolders)
        } else {
            let source: ScriptSource = d.scriptInline ? .inline(d.code) : .file(text.expand(d.scriptFile))
            input.name = d.name.isEmpty ? (d.scriptInline ? "Script" : ((d.scriptFile as NSString).lastPathComponent as NSString).deletingPathExtension) : d.name
            // A script Distill keeps gets its package manifest at creation; its packages install on Allow.
            let manifest = d.manifest.trimmingCharacters(in: .whitespacesAndNewlines)
            input.script = .init(source: source, interpreter: d.interpreter,
                                 manifest: d.managed && d.interpreter.manifestName != nil && !manifest.isEmpty ? d.manifest : nil)
        }
        guard let client else { return }
        busy["add"] = "add"
        Task {
            defer { busy["add"] = nil }
            do {
                let created = try await client.createCollector(input)
                upsert(created)
                if phase != .loaded { phase = .loaded }
                adding = nil
                select(created.id)
            } catch {
                engine?.report(error)
            }
        }
    }

    // MARK: Already collected

    func openCollected(_ c: Collector) {
        collected = CollectedSheet(collectorID: c.id)
        loadCollected()
    }

    func loadCollected() {
        guard let client, let sheet = collected else { return }
        let id = sheet.collectorID, query = sheet.query
        Task {
            let files = (try? await client.collected(id, query: query)) ?? []
            guard collected?.collectorID == id, collected?.query == query else { return }
            collected?.files = files
            collected?.loading = false
        }
    }

    func forget(_ f: CollectedFile) {
        guard let client, let id = collected?.collectorID else { return }
        Task {
            do {
                let removed = try await client.forgetCollected(id, sha256: f.sha256)
                collected?.forgotten[f.sha256] = removed.isEmpty ? [f] : removed
                refresh(id)
            } catch { engine?.report(error) }
        }
    }

    func undoForget(_ sha: String) {
        guard let client, let id = collected?.collectorID, let files = collected?.forgotten[sha] else { return }
        Task {
            do {
                _ = try await client.restoreCollected(id, files: files)
                collected?.forgotten[sha] = nil
                refresh(id)
            } catch { engine?.report(error) }
        }
    }

    func forgetAll() {
        guard let client, let id = collected?.collectorID else { return }
        collected?.confirmForgetAll = false
        Task {
            do {
                _ = try await client.forgetCollected(id)
                collected?.files = []
                collected?.forgotten = [:]
                refresh(id)
            } catch { engine?.report(error) }
        }
    }
}

extension AppModel {
    var collectors: CollectorsStore { CollectorsStore.of(self) }
}
