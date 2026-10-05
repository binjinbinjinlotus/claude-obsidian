import AppKit
import SwiftUI
import DistillKit

/// Fixtures and snapshot states for board CollectorsScriptFiles (canvas v67, frames T–Z2 and the
/// "Adding a script with packages" cards). Shaped like what a v6 core sends (status.script with its
/// manifest, lastTestRun, changes); paths sit under the real home so they show with `~`.
@MainActor
enum ScriptFixtures {
    typealias F = CollectorFixtures
    static let dirRoot = F.home + "/Library/Application Support/Distill/collectors/scripts"
    static let shaSlack = "77d0b2c4e6f8a0c2e4b6d8f0a1c3e5b7d9f1a3c5e7b9d2f4a6c8e0b2d4f6a1c3"
    static let shaSlackWas = "3f9a0d1c5e7b2a4f6c8e0b1d3f5a7c9e2b4d6f8a0c2e4b6d8f0a1c3e5b7dc217"

    static let pocketCode = """
    import sys, pathlib
    import requests
    queue = pathlib.Path(sys.argv[2])
    r = requests.get("https://getpocket.com/v3/get", timeout=30)
    (queue / "pocket.json").write_text(r.text)
    """
    static let slackCode = """
    import { WebClient } from '@slack/web-api';
    const queue: string = process.argv[3];
    const saved = await new WebClient(process.env.SLACK_TOKEN).stars.list();
    await writeFile(`${queue}/slack-saved.json`, JSON.stringify(saved));
    """
    static let slackManifest = "{\n  \"dependencies\": {\n    \"date-fns\": \"^4.1.0\"\n  }\n}\n"
    static let slackManifestNew = "{\n  \"dependencies\": {\n    \"date-fns\": \"^4.1.0\",\n    \"@slack/web-api\": \"^7.8.0\"\n  }\n}\n"

    static func install(_ c: String, _ result: String, at start: Date, ms: Double = 4000, manifest: String = "package.json",
                        trigger: String = "allow", exit: Int? = 0, out: String? = nil) -> CollectorInstall {
        CollectorInstall(id: "ins-\(c)-\(Int(start.timeIntervalSince1970))", collectorId: c, trigger: trigger, startedAt: start,
                         endedAt: result == "running" ? nil : start.addingTimeInterval(ms / 1000), durationMs: result == "running" ? nil : ms,
                         result: result, command: manifest == "requirements.txt" ? ".venv/bin/python3 -m pip install -r requirements.txt" : "npm install --no-audit --no-fund",
                         manifestName: manifest, manifestSha256: "m1", exitCode: result == "running" ? nil : exit, outputTail: out)
    }

    static func manifest(_ id: String, _ name: String, state: String, count: Int, installedAt: Date? = nil, installing: Bool = false) -> CollectorManifestStatus {
        CollectorManifestStatus(name: name, path: "\(dirRoot)/\(id)/\(name)", exists: count > 0 || state != "none", hasDependencies: count > 0,
                                packageCount: count, sha256: "m1", installedSha256: state == "ready" ? "m1" : nil,
                                needsInstall: state == "needsInstall", installing: installing || state == "installing",
                                lastInstall: installedAt.map { install(id, state == "failed" ? "failed" : "success", at: $0, manifest: name, exit: state == "failed" ? 1 : 0) },
                                state: state)
    }

    /// Pocket export as a script Distill keeps: collector.py with requirements.txt (3 installed Oct 3).
    static func pocket() -> Collector {
        var c = F.pocket()
        let path = "\(dirRoot)/col-3f2a/collector.py"
        c.script = ScriptCollectorSettings(source: .file(path), managed: true, interpreter: .python3, allowedSha256: F.shaPocket,
                                           allowedAt: F.at(9, 12, daysAgo: 1), allowedFiles: AllowedFiles(script: "s1", manifest: "m1"))
        c.status?.script = CollectorScriptStatus(path: path, dir: "\(dirRoot)/col-3f2a", managed: true,
                                                 manifest: manifest("col-3f2a", "requirements.txt", state: "ready", count: 3, installedAt: F.at(9, 12, daysAgo: 1)))
        return c
    }

    /// Slack saved items, kept by Distill: TypeScript (U, Z, Z2) or JavaScript (W, X, X2), with package.json.
    static func slack(_ i: CollectorInterpreter = .typescript, state: String = "ready", count: Int = 1) -> Collector {
        let ext = i == .typescript ? "ts" : "js"
        let path = "\(dirRoot)/col-8c41/collector.\(ext)"
        let last = F.run("s9", "slack", kind: .script, F.at(9, 30), ms: 1100, .success, counts: .init(added: 3), exit: 0, out: "Saved 3 starred items\n")
        return Collector(id: "slack", kind: .script, name: "Slack saved items", vaultPath: "", enabled: true,
                         schedule: CollectorSchedule(cron: "30 * * * *", preset: .custom),
                         script: ScriptCollectorSettings(source: .file(path), managed: true, interpreter: i, allowedSha256: shaSlackWas,
                                                         allowedAt: F.at(9, 0, daysAgo: 3), allowedFiles: AllowedFiles(script: "s1", manifest: "m0")),
                         status: CollectorStatus(nextRunAt: F.at(10, 30), lastRun: last, currentSha256: shaSlackWas,
                                                 script: CollectorScriptStatus(path: path, dir: "\(dirRoot)/col-8c41", managed: true,
                                                                               manifest: manifest("col-8c41", "package.json", state: state, count: count,
                                                                                                  installedAt: F.at(9, 12, daysAgo: 1)))))
    }

    /// Meeting notes: the user's own Python file, every 15 minutes.
    static func meeting() -> Collector {
        let path = F.home + "/Scripts/meeting-notes/fetch_meeting_notes.py"
        let last = F.run("m1", "meeting", kind: .script, F.at(10, 30), ms: 6200, .success, counts: .init(added: 1), exit: 0,
                         out: "Downloaded “Weekly sync · Notes by Gemini”\n")
        return Collector(id: "meeting", kind: .script, name: "Meeting notes", vaultPath: "", enabled: true,
                         schedule: CollectorSchedule(cron: "*/15 * * * *", preset: .every15),
                         script: ScriptCollectorSettings(source: .file(path), interpreter: .python3, allowedSha256: "aa", allowedAt: F.at(8, 2)),
                         status: CollectorStatus(nextRunAt: F.at(10, 45), lastRun: last, currentSha256: "aa",
                                                 script: CollectorScriptStatus(path: path, managed: false)))
    }

    static func list(pocket p: Collector? = nil, slack s: Collector? = nil) -> [Collector] {
        [F.inbox(), p ?? pocket(), s ?? slack(), meeting(), F.scans()]
    }

    static func pocketRuns() -> [CollectorRun] {
        [F.run("p1", "pocket", kind: .script, F.at(7), ms: 2400, .success, counts: .init(added: 4), exit: 0,
               out: "Fetched 4 new articles since Oct 3\nWrote 4 files to \(F.home)/Documents/Distill Queue/Research\n"),
         F.run("p0", "pocket", kind: .script, F.at(7, daysAgo: 1), ms: 2100, .success, counts: .init(added: 2), exit: 0,
               out: "Fetched 2 new articles since Oct 2\n")]
    }

    /// Loads the list, the runs of the scripts, and the clock.
    static func load(_ e: AppModel, _ list: [Collector], select: String, now: Date) -> CollectorsStore {
        let s = F.load(e, list, select: select, now: now)
        s.runs["pocket"] = pocketRuns()
        s.runs["slack"] = [list.first { $0.id == "slack" }?.lastRun].compactMap { $0 }
        s.runs["meeting"] = [list.first { $0.id == "meeting" }?.lastRun,
                             F.run("m0", "meeting", kind: .script, F.at(10, 15), ms: 4900, .nothing, exit: 0)].compactMap { $0 }
        s.stateDir = F.home + "/Library/Application Support/Distill"
        return s
    }
}

extension StatesSnapshot {
    static func collectorScriptStates() {
        let f = Flow.collectors
        let size = CGSize(width: 1200, height: 860)
        let n890 = CGSize(width: 890, height: 760)
        func shot(_ file: String, _ state: String, _ desc: String, _ e: AppModel, size: CGSize = size) {
            main(file, f, "Collectors", state, desc, e, section: .collectors, size: size) { CollectorsScreen() }
        }
        typealias F = CollectorFixtures
        typealias S = ScriptFixtures

        // T · a script Distill keeps.
        var e = engine()
        _ = S.load(e, S.list(), select: "pocket", now: F.at(9, 32))
        shot("collectors-script-managed", "T · A script Distill keeps", "collector.py in its own folder, Reveal in Finder and Open in editor; packages on one line.", e)
        shot("collectors-script-managed-890", "T · A script Distill keeps · 890 pt", "The same in an 890 pt window: controls under the name, labels above values.", e, size: n890)

        // U · Edit: language picker, the file, package.json with a new line not installed yet.
        e = engine()
        var s = S.load(e, S.list(), select: "slack", now: F.at(9, 32))
        s.startEdit(s.collector("slack")!)
        s.editing?.take(CollectorScriptFiles(collectorId: "slack", interpreter: .typescript, managed: true, path: "\(S.dirRoot)/col-8c41/collector.ts",
                                             code: S.slackCode + "\n", sha256: "s1",
                                             manifest: .init(name: "package.json", path: "\(S.dirRoot)/col-8c41/package.json", text: S.slackManifest, sha256: "m1")))
        s.editing?.manifest = S.slackManifestNew
        s.checks["30 * * * *"] = ScheduleCheck(cron: "30 * * * *", valid: true, nextRuns: [F.at(10, 30)])
        shot("collectors-script-editor", "U · Edit a kept script", "Language picker, the file it edits, its package.json with a new line (not installed yet).", e)

        // V · Run now finished: the result and the last lines in the status card.
        e = engine()
        var p = S.pocket()
        let manual = F.run("pm", "pocket", kind: .script, F.at(10, 42), ms: 1800, .success, counts: .init(added: 2), exit: 0,
                           out: "Fetched 2 new articles since 7:00 AM\nWrote pocket-2026-10-04-1.md\nWrote pocket-2026-10-04-2.md\n", trigger: "now")
        p.status?.lastRun = manual
        s = S.load(e, S.list(pocket: p), select: "pocket", now: F.at(10, 43))
        s.runs["pocket"] = [manual] + S.pocketRuns()
        s.shown["pocket"] = "pm"
        shot("collectors-script-manual-run", "V · Run now finished", "The result and the last output lines right in the status card; Copy output, Hide.", e)

        // V2 · Test run: the files it made in the test folder; nothing in the queue.
        e = engine()
        p = S.pocket()
        let test = CollectorRun(id: "pt", collectorId: "pocket", kind: .script, trigger: "test", startedAt: F.at(10, 44),
                                endedAt: F.at(10, 44).addingTimeInterval(1.9), durationMs: 1900, result: .success,
                                counts: .init(added: 2), filesAdded: ["pocket-2026-10-04-1.md", "pocket-2026-10-04-2.md"], exitCode: 0,
                                stdoutTail: "Wrote 2 files to the test folder\n",
                                outputDir: F.home + "/Library/Application Support/Distill/collectors/test-runs/col-3f2a")
        p.status?.script?.lastTestRun = test
        s = S.load(e, S.list(pocket: p), select: "pocket", now: F.at(10, 45))
        s.runs["pocket"] = [test] + S.pocketRuns()
        s.shown["pocket"] = "pt"
        s.fixtureSizes = ["pocket-2026-10-04-1.md": 4100, "pocket-2026-10-04-2.md": 3100]
        shot("collectors-script-test-run", "V2 · Test run", "Ran like a real run into Distill’s test folder: its files, Reveal in Finder; nothing in the queue.", e)
        shot("collectors-script-test-run-890", "V2 · Test run · 890 pt", "The Test run result in an 890 pt window.", e, size: n890)

        // W · package.json changed: paused; Allow and run, or Allow this version.
        e = engine()
        var w = S.slack(.node, state: "needsInstall", count: 2)
        w.enabled = true
        w.status?.currentSha256 = S.shaSlack
        w.status?.needsConsent = true
        w.status?.needsAttention = true
        w.status?.script?.changes = ["manifest"]
        s = S.load(e, S.list(slack: w), select: "slack", now: F.at(9, 32))
        s.consentFiles["slack|" + S.shaSlack] = CollectorScriptFiles(collectorId: "slack", interpreter: .node, managed: true, path: "", code: S.slackCode,
                                                                    manifest: .init(name: "package.json", text: S.slackManifestNew, sha256: "m2"))
        shot("collectors-script-manifest-changed", "W · package.json changed", "Paused until you allow it; WHAT CHANGED shows the manifest; Allow and run.", e)
        shot("collectors-script-manifest-changed-890", "W · package.json changed · 890 pt", "The consent in an 890 pt window.", e, size: n890)

        // X · Allow and run while packages install: the install first, the run waits.
        e = engine()
        let x = S.slack(.node, state: "installing", count: 2)
        s = S.load(e, S.list(slack: x), select: "slack", now: F.at(10, 50, s: 14))
        let ins = S.install("slack", "running", at: F.at(10, 50))
        s.installs["slack"] = ins
        s.installOutput[ins.id] = "npm http fetch GET 200 https://registry.npmjs.org/@slack%2fweb-api 212ms\nadded 11 packages, changed 1 package in 3s\n"
        s.live["slack"] = CollectorRun(id: "sw", collectorId: "slack", kind: .script, trigger: "now", startedAt: F.at(10, 50), result: .queued, waiting: "install")
        shot("collectors-script-installing", "X · Installing after Allow and run", "Live npm output and Stop; the run waits for the install.", e)
        shot("collectors-script-installing-890", "X · Installing · 890 pt", "The install in an 890 pt window.", e, size: n890)

        // X2 · Couldn't install packages: the output, Install again; Run now waits.
        e = engine()
        var x2 = S.slack(.node, state: "failed", count: 3)
        x2.status?.needsAttention = true
        let failedRun = CollectorRun(id: "sf", collectorId: "slack", kind: .script, trigger: "schedule", startedAt: F.at(11, 30), endedAt: F.at(11, 30),
                                     durationMs: 10, result: .failed, error: .init(code: .installFailed, message: "The install exited with code 1."))
        x2.status?.lastRun = failedRun
        s = S.load(e, S.list(slack: x2), select: "slack", now: F.at(11, 32))
        s.runs["slack"] = [failedRun, S.slack().lastRun!]
        s.installs["slack"] = S.install("slack", "failed", at: F.at(10, 50), exit: 1,
                                        out: "$ npm install --no-audit --no-fund\nnpm error 404 Not Found - GET https://registry.npmjs.org/p-retri\nnpm error 404 'p-retri@^6.2.0' is not in this registry.\n")
        shot("collectors-script-install-failed", "X2 · Couldn’t install packages", "The install output, Install again and Open package.json; Run now waits.", e)
        shot("collectors-script-install-failed-890", "X2 · Couldn’t install packages · 890 pt", "The failed install in an 890 pt window.", e, size: n890)

        // Y · Your own file.
        e = engine()
        _ = S.load(e, S.list(), select: "meeting", now: F.at(10, 32))
        shot("collectors-script-external", "Y · Your own file", "Its path, Reveal in Finder and Open in editor; language; no packages.", e)
        shot("collectors-script-external-890", "Y · Your own file · 890 pt", "Your own file in an 890 pt window.", e, size: n890)

        // Z · 890 pt: a Run now that failed after an edit.
        e = engine()
        var z = S.slack(.typescript, state: "ready", count: 2)
        let zr = F.run("sz", "slack", kind: .script, F.at(10, 58), ms: 700, .failed, exit: 1, error: .init(code: .scriptFailed, message: "exit 1"),
                       err: "TypeError: Cannot read properties of undefined (reading 'items')\n    at collector.ts:6:44\n", trigger: "now")
        z.status?.lastRun = zr
        z.status?.needsAttention = true
        s = S.load(e, S.list(slack: z), select: "slack", now: F.at(10, 59))
        s.runs["slack"] = [zr, S.slack().lastRun!]
        s.shown["slack"] = "sz"
        shot("collectors-script-narrow-failed", "Z · 890 pt: Run now failed", "Controls under the name; the failed run’s stderr in the card with Hide.", e, size: n890)

        // Z2 · 890 pt: Edit, labels above the fields.
        e = engine()
        s = S.load(e, S.list(slack: S.slack(.typescript, state: "ready", count: 1)), select: "slack", now: F.at(9, 32))
        s.checks["30 * * * *"] = ScheduleCheck(cron: "30 * * * *", valid: true, nextRuns: [F.at(10, 30)])
        s.startEdit(s.collector("slack")!)
        s.editing?.take(CollectorScriptFiles(collectorId: "slack", interpreter: .typescript, managed: true, path: "\(S.dirRoot)/col-8c41/collector.ts",
                                             code: S.slackCode + "\n", sha256: "s1",
                                             manifest: .init(name: "package.json", path: "\(S.dirRoot)/col-8c41/package.json", text: S.slackManifest, sha256: "m1")))
        shot("collectors-script-narrow-edit", "Z2 · 890 pt: Edit", "The script form at 890 pt: labels above the fields; the editor and packages keep full width.", e, size: n890)

        // Edit conflict: the file changed on disk since the editor opened it.
        s.conflict["slack"] = "The script changed on disk since you opened it; reload it first."
        s.editing?.code = S.slackCode + "\nconsole.log('edited here');\n"
        shot("collectors-script-edit-conflict", "Edit · changed on disk", "Save refused: Reload or Keep editing; nothing is overwritten.", e, size: n890)

        // Adding a script with packages: 1 Add, 2 Review and allow, 3 Installing, 4 Ready.
        e = engine()
        s = S.load(e, S.list(), select: "pocket", now: F.at(10, 20))
        s.startAdding(kind: .script)
        s.adding?.setLanguage(.node)
        s.adding?.code = "import { WebClient } from '@slack/web-api';\nimport pRetry from 'p-retry';\nconst queue = process.argv[3];\nconst saved = await pRetry(() => new WebClient(process.env.SLACK_TOKEN).stars.list());\n"
        s.adding?.manifest = "{\n  \"type\": \"module\",\n  \"dependencies\": {\n    \"@slack/web-api\": \"^7.8.0\",\n    \"date-fns\": \"^4.1.0\",\n    \"p-retry\": \"^6.2.0\"\n  }\n}\n"
        shot("collectors-card-add-1", "1 · Add", "Step 2 of Add: the script and its package.json, kept by Distill in the collector’s folder.", e)
        shot("collectors-card-add-1-890", "1 · Add · 890 pt", "Add step 2 with packages in an 890 pt window (the sheet scrolls).", e, size: n890)

        e = engine()
        var fresh = S.slack(.node, state: "needsInstall", count: 3)
        fresh.enabled = false
        fresh.script?.allowedSha256 = nil
        fresh.script?.allowedAt = nil
        fresh.script?.allowedFiles = nil
        fresh.status?.lastRun = nil
        fresh.status?.nextRunAt = nil
        fresh.status?.currentSha256 = "9b2054de9b2054de9b2054de9b2054de9b2054de9b2054de9b2054de9b2054de"
        fresh.status?.needsConsent = true
        fresh.status?.needsAttention = true
        fresh.status?.script?.manifest?.lastInstall = nil
        s = S.load(e, S.list(slack: fresh), select: "slack", now: F.at(10, 20))
        s.runs["slack"] = []
        s.consentFiles["slack|" + (fresh.status?.currentSha256 ?? "")] = CollectorScriptFiles(
            collectorId: "slack", interpreter: .node, managed: true, path: "",
            code: "import { WebClient } from '@slack/web-api';\nimport pRetry from 'p-retry';\nconst queue = process.argv[3];\n",
            manifest: .init(name: "package.json", text: "{\n  \"type\": \"module\",\n  \"dependencies\": {\n    \"@slack/web-api\": \"^7.8.0\",\n    \"date-fns\": \"^4.1.0\",\n    \"p-retry\": \"^6.2.0\"\n  }\n}\n", sha256: "m1"))
        shot("collectors-card-add-2", "2 · Review and allow", "One OK covers the script and package.json; nothing runs or installs before it.", e)

        e = engine()
        var adding = S.slack(.node, state: "installing", count: 3)
        adding.status?.lastRun = nil
        adding.status?.script?.manifest?.lastInstall = nil
        s = S.load(e, S.list(slack: adding), select: "slack", now: F.at(10, 20, s: 6))
        s.runs["slack"] = []
        let first = S.install("slack", "running", at: F.at(10, 20))
        s.installs["slack"] = first
        s.installOutput[first.id] = "npm http fetch GET 200 https://registry.npmjs.org/p-retry 96ms\nadded 14 packages in 4s\n"
        shot("collectors-card-add-3", "3 · Installing", "Right after Allow, with live output and Stop; the first run waits.", e)

        e = engine()
        var ready = S.slack(.node, state: "ready", count: 3)
        ready.status?.lastRun = nil
        ready.status?.script?.manifest?.lastInstall = S.install("slack", "success", at: F.at(10, 20), ms: 4000)
        ready.script?.allowedAt = F.at(10, 20)
        s = S.load(e, S.list(slack: ready), select: "slack", now: F.at(10, 21))
        s.runs["slack"] = []
        shot("collectors-card-add-4", "4 · Ready", "Installed before its first scheduled run; Test run tries it without the queue.", e)

        // Delete a script collector: the record and its folder go to Distill's trash.
        e = engine()
        s = S.load(e, S.list(), select: "pocket", now: F.at(9, 32))
        s.confirmDelete = "pocket"
        shot("collectors-card-delete", "Delete a script collector", "The collector and its script folder go to the trash for 30 days; restore from History → Activity.", e)

        // Single collector, waiting for the OK, then "Not now" (the one-collector case once failed).
        e = engine()
        s = S.load(e, [fresh], select: "slack", now: F.at(10, 20))
        s.runs["slack"] = []
        shot("collectors-script-single-consent", "One collector · needs your OK", "A single new script with packages: Allow and run in the title row.", e, size: n890)
        s.consentDeferred.insert("slack")
        shot("collectors-script-single-not-now", "One collector · Not now", "After Not now: one quiet line, Review and allow; Allow and run stays in the title row.", e, size: n890)
    }
}
