import AppKit
import DistillKit
import Foundation
import UniformTypeIdentifiers

// Collectors v6 in the store (spec collectors.md → "Script files and packages (v6)", board
// CollectorsScriptFiles): Allow and run, Test run, package installs and their live output, the
// manual run's result in the status card, and the script's file (Reveal in Finder, Open in editor).
extension CollectorsStore {
    // MARK: Runs started here

    /// A run the user started: tracked live, and its result shows in the status card.
    func started(_ run: CollectorRun) {
        shown[run.collectorId] = run.id
        if run.result.isActive { runStarted(run) } else { runFinished(run) }
    }

    /// "Allow and run": allow the version shown (the core's hash), then run it once. While its packages
    /// install (allowing starts that), the run waits for them in the core.
    func allowAndRun(_ c: Collector) {
        guard let sha = c.status?.currentSha256, let client else { return }
        busy[c.id] = "allow"
        Task { [weak self] in
            defer { if self?.busy[c.id] == "allow" { self?.busy[c.id] = nil } }
            do {
                let allowed = try await client.allowCollector(c.id, sha256: sha)
                self?.upsert(allowed)
                self?.consentDeferred.remove(c.id)
                let run = try await client.runCollector(c.id)
                self?.started(run)
            } catch {
                self?.engine?.report(error)
            }
        }
    }

    /// Test run: the script runs like a real run, into Distill's scratch folder (never the queue).
    func testRun(_ c: Collector) {
        guard c.isScript else { return }
        perform(c.id, "test") { [weak self] client in
            let run = try await client.testCollector(c.id)
            self?.started(run)
        }
    }

    /// Hide a manual run's result in the status card.
    func hideResult(_ c: Collector) { shown[c.id] = nil }

    // MARK: Packages

    func install(_ c: Collector, clean: Bool = false) {
        perform(c.id, "install") { [weak self] client in
            let i = try await client.installCollectorPackages(c.id, clean: clean)
            self?.installStarted(i)
        }
    }

    /// Clean reinstall asks first: it removes node_modules / .venv.
    func confirmCleanInstall(_ c: Collector) {
        let folder = c.manifest?.name == "requirements.txt" ? ".venv" : "node_modules"
        let alert = NSAlert()
        alert.messageText = "Reinstall packages from scratch?"
        alert.informativeText = "Distill removes \(folder) in the collector’s folder and installs what \(c.manifest?.name ?? "the manifest") lists again."
        alert.addButton(withTitle: "Clean reinstall")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { install(c, clean: true) }
    }

    func loadInstall(_ id: String) {
        guard let client else { return }
        Task { [weak self] in
            if let i = try? await client.collectorInstall(id) { self?.installs[id] = i }
        }
    }

    /// The failed card needs the install's output, which the collector's status leaves out.
    func installFailedNeedsOutput(_ c: Collector) -> Bool {
        guard c.manifest?.state == "failed" else { return false }
        let known = installs[c.id]
        return known == nil || known?.outputTail == nil || (c.manifest?.lastInstall.map { $0.id != known?.id } ?? false)
    }

    func installStarted(_ i: CollectorInstall) {
        installs[i.collectorId] = i
        if installOutput[i.id] == nil { installOutput[i.id] = "" }
        // Flip the collector to installing at once; `collector.changed` confirms it.
        if let idx = collectors.firstIndex(where: { $0.id == i.collectorId }), collectors[idx].status?.script?.manifest != nil {
            collectors[idx].status?.script?.manifest?.installing = true
            collectors[idx].status?.script?.manifest?.state = "installing"
        }
        clock = Date()
    }

    func installOutput(collectorId: String, installId: String, text: String) {
        installOutput[installId] = String(((installOutput[installId] ?? "") + text).suffix(64 * 1024))
    }

    func installFinished(_ i: CollectorInstall) {
        installs[i.collectorId] = i
        installOutput[i.id] = nil
        busy[i.collectorId] = nil
        refresh(i.collectorId)
    }

    /// The install the status card shows: the newest known, or the status's (without output).
    func currentInstall(_ c: Collector) -> CollectorInstall? {
        if let i = installs[c.id], i.id == c.manifest?.lastInstall?.id || c.manifest?.lastInstall == nil || i.startedAt >= (c.manifest?.lastInstall?.startedAt ?? .distantPast) {
            return i
        }
        return c.manifest?.lastInstall
    }

    /// Output lines of an install: live while it runs, else its stored tail.
    func installLines(_ c: Collector) -> [String] {
        guard let i = currentInstall(c) else { return [] }
        let raw = installOutput[i.id] ?? i.outputTail ?? ""
        var lines = raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        while lines.last == "" { lines.removeLast() }
        if !i.command.isEmpty, lines.first?.hasPrefix("$ ") != true { lines.insert("$ " + i.command, at: 0) }
        return lines
    }

    // MARK: Files

    /// The files the consent card shows (code and manifest). Read once per hash.
    func consentScript(_ c: Collector) -> CollectorScriptFiles? {
        guard c.status?.script != nil else { return nil }
        let key = c.id + "|" + (c.status?.currentSha256 ?? "")
        if let f = consentFiles[key] { return f }
        guard let client, fixtureNow == nil else { return nil }
        // Called from view bodies: change published state after this update, never during it.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.consentFiles[key] == nil else { return }
            self.consentFiles[key] = CollectorScriptFiles(collectorId: c.id, interpreter: c.script?.interpreter ?? .zsh, managed: c.isManaged, path: "")
            Task { [weak self] in
                if let f = try? await client.collectorScript(c.id) { self?.consentFiles[key] = f }
            }
        }
        return nil
    }

    /// Sizes of a test run's files (read from its scratch folder; snapshots use fixtures).
    func testFileSize(_ run: CollectorRun, _ name: String) -> Int? {
        if let fixtureSizes { return fixtureSizes[name] }
        guard let dir = run.outputDir else { return nil }
        let attrs = try? FileManager.default.attributesOfItem(atPath: (dir as NSString).appendingPathComponent(name))
        return (attrs?[.size] as? NSNumber)?.intValue
    }

    func reveal(_ path: String) {
        guard !path.isEmpty else { return }
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }

    /// Open a script or manifest in the user's editor. `.ts` often belongs to a video player (MPEG-2
    /// transport stream) and some script types to Terminal, so those open in the default text editor.
    func openInEditor(_ path: String) {
        guard !path.isEmpty else { return }
        let url = URL(fileURLWithPath: path)
        let ws = NSWorkspace.shared
        let handler = ws.urlForApplication(toOpen: url)
        let type = UTType(filenameExtension: url.pathExtension)
        let mediaOrNone = handler == nil || type?.conforms(to: .audiovisualContent) == true
            || ["com.apple.Terminal", "com.apple.QuickTimePlayerX", "org.videolan.vlc", "com.colliderli.iina"]
                .contains(handler.flatMap { Bundle(url: $0)?.bundleIdentifier } ?? "")
        if mediaOrNone, let editor = ws.urlForApplication(toOpen: .plainText) {
            ws.open([url], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration())
        } else {
            ws.open(url)
        }
    }

    /// Where a new kept script will live, for the Add sheet ("…/collectors/scripts/(new)/collector.zsh").
    func newScriptPath(_ i: CollectorInterpreter) -> String {
        let state = stateDir ?? StatePaths.resolve().dir.path
        return text.tilde(state + "/collectors/scripts/(new)/collector.\(i.fileExtension)")
    }
}
