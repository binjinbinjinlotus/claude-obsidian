import AppKit
import SwiftUI
import DistillKit

/// Fixture collectors for the Collectors snapshots (canvas row 7, boards
/// Collectors and CollectorsScript). Paths sit under the real home folder so
/// they show with `~`; nothing is read from or written to them.
@MainActor
enum CollectorFixtures {
    static let home = NSHomeDirectory()
    static func at(_ h: Int, _ m: Int = 0, daysAgo: Int = 0, s: Int = 0) -> Date {
        ActionFixtures.at(h, m, daysAgo: daysAgo).addingTimeInterval(TimeInterval(s))
    }

    static let kindleCode = """
    #!/bin/zsh
    # Copy the Kindle clippings into the queue
    src="$HOME/Documents/My Clippings.txt"
    [[ -f $src ]] || exit 0
    cp "$src" "$DISTILL_QUEUE_DIR/kindle-$(date +%F).txt"
    """
    static let shaPocket = "3f9a0d1c5e7b2a4f6c8e0b1d3f5a7c9e2b4d6f8a0c2e4b6d8f0a1c3e5b7dc217"
    static let shaPocketNew = "81bc2d4f6a8c0e2b4d6f8a1c3e5b7d9f0a2c4e6b8d0f1a3c5e7b9d2f4a6c0e4f"
    static let shaKindle = "a71e3c5b7d9f1a2c4e6b8d0f2a4c6e8b0d1f3a5c7e9b2d4f6a8c0e1b3d599d0"

    static func run(_ id: String, _ c: String, kind: CollectorKind = .folder, _ start: Date, ms: Double = 400,
                    _ result: CollectorRunResult, counts: CollectorRunCounts = CollectorRunCounts(), files: [CollectorRunFile]? = nil,
                    exit: Int? = nil, error: CollectorRunError? = nil, out: String? = nil, err: String? = nil, trigger: String = "schedule") -> CollectorRun {
        CollectorRun(id: id, collectorId: c, kind: kind, vaultPath: "", trigger: trigger, startedAt: start,
                     endedAt: result.isActive ? nil : start.addingTimeInterval(ms / 1000), durationMs: result.isActive ? nil : ms,
                     result: result, error: error, files: files, counts: counts, filesAdded: [], exitCode: exit,
                     stdoutTail: out, stderrTail: err)
    }

    static let inboxFiles: [CollectorRunFile] = [
        .init(name: "gongfu-brewing-guide.pdf", outcome: .copied),
        .init(name: "Tea tasting trip/", outcome: .copied, queueName: "Tea tasting trip", kind: "folder", fileCount: 12, newCount: 5),
        .init(name: "Q3 tea club plan.gdoc", outcome: .copied), .init(name: "gyokuro.md", outcome: .skipped),
        .init(name: "gyokuro copy.md", outcome: .skipped),
    ]

    static func inboxRuns() -> [CollectorRun] {
        var list = [
            run("in1", "inbox", at(9), .success, counts: .init(copied: 3, skipped: 2, added: 3), files: inboxFiles),
            run("in2", "inbox", at(8), ms: 100, .nothing),
            run("in3", "inbox", at(7), ms: 200, .success, counts: .init(copied: 1, waiting: 1, added: 1),
                files: [.init(name: "receipt.pdf", outcome: .copied), .init(name: "export.zip", outcome: .waiting, reason: "still changing")]),
            run("in4", "inbox", at(6), ms: 100, .nothing),
        ]
        for i in 0..<14 { list.append(run("iny\(i)", "inbox", at(23 - i, daysAgo: 1), ms: 100, .nothing)) }
        return list
    }

    static func pocketRuns() -> [CollectorRun] {
        [
            run("p1", "pocket", kind: .script, at(7), ms: 2400, .success, counts: .init(added: 4), exit: 0,
                out: "Fetched 4 new articles since Oct 3\nWrote 4 files to \(home)/Documents/Distill Queue/Research\n"),
            run("p2", "pocket", kind: .script, at(7, daysAgo: 1), ms: 300_000, .timedout, counts: .init(added: 2),
                out: "Fetched 40 articles; writing… 2 of 40\n"),
            run("p3", "pocket", kind: .script, at(7, daysAgo: 2), ms: 900, .failed, exit: 1,
                error: .init(code: .scriptFailed, message: "exit 1"),
                err: "Traceback (most recent call last):\n  File \"pocket-export.py\", line 31, in fetch\nrequests.exceptions.HTTPError: 401 Unauthorized\n"),
            run("p4", "pocket", kind: .script, at(7, daysAgo: 3), ms: 1900, .success, counts: .init(added: 1), exit: 0),
        ]
    }

    static func inbox() -> Collector {
        Collector(id: "inbox", kind: .folder, name: "Distill Inbox", vaultPath: "", enabled: true, schedule: .hourly,
                  folder: FolderCollectorSettings(source: home + "/Distill Inbox", includeSubfolders: true),
                  status: CollectorStatus(nextRunAt: at(10), lastRun: inboxRuns()[0], collectedCount: 128))
    }

    static func pocket() -> Collector {
        Collector(id: "pocket", kind: .script, name: "Pocket export", vaultPath: "", enabled: true,
                  schedule: CollectorSchedule(cron: "0 7 * * *", preset: .daily),
                  script: ScriptCollectorSettings(source: .file(home + "/Scripts/pocket-export.py"), interpreter: .python3,
                                                  allowedSha256: shaPocket, allowedAt: at(9, 14, daysAgo: 2)),
                  status: CollectorStatus(nextRunAt: at(7, daysAgo: -1), lastRun: pocketRuns()[0], currentSha256: shaPocket))
    }

    static func slack() -> Collector {
        let failed = run("s1", "slack", kind: .script, at(8, 30), ms: 800, .failed, exit: 1, error: .init(code: .scriptFailed, message: "exit 1"),
                         err: "Error: SLACK_TOKEN is not set\n    at main (slack-saved.mjs:12:11)\n")
        return Collector(id: "slack", kind: .script, name: "Slack saved items", vaultPath: "", enabled: true,
                         schedule: CollectorSchedule(cron: "30 * * * *", preset: .custom),
                         script: ScriptCollectorSettings(source: .file(home + "/Scripts/slack-saved.mjs"), interpreter: .node,
                                                         allowedSha256: "5c1d", allowedAt: at(9, 0, daysAgo: 3)),
                         status: CollectorStatus(nextRunAt: at(9, 30), lastRun: failed, currentSha256: "5c1d", needsAttention: true))
    }

    static func kindle() -> Collector {
        Collector(id: "kindle", kind: .script, name: "Kindle highlights", vaultPath: "", enabled: false,
                  schedule: CollectorSchedule(cron: "0 20 * * *", preset: .daily),
                  script: ScriptCollectorSettings(source: .inline(kindleCode + "\n"), interpreter: .zsh),
                  status: CollectorStatus(nextRunAt: nil, currentSha256: shaKindle, needsConsent: true, needsAttention: true))
    }

    static func scans(noPermission: Bool = false) -> Collector {
        var c = Collector(id: "scans", kind: .folder, name: "Scans", vaultPath: "", enabled: noPermission,
                          schedule: CollectorSchedule(cron: "0 9 * * *", preset: .daily),
                          folder: FolderCollectorSettings(source: home + "/Desktop/Scans"),
                          status: CollectorStatus(collectedCount: 0))
        if noPermission {
            c.status?.lastRun = run("sc1", "scans", at(9), .failed, error: .init(code: .noPermission, message: "EPERM"))
            c.status?.needsAttention = true
            c.status?.nextRunAt = at(9, daysAgo: -1)
        }
        return c
    }

    static func phone() -> Collector {
        Collector(id: "phone", kind: .folder, name: "Phone uploads", vaultPath: "", enabled: true, schedule: .hourly,
                  folder: FolderCollectorSettings(source: home + "/Phone uploads", afterCollect: "move"),
                  status: CollectorStatus(nextRunAt: at(10),
                                          lastRun: run("ph1", "phone", at(9), .failed, error: .init(code: .sourceMissing, message: "missing")),
                                          collectedCount: 0, needsAttention: true))
    }

    /// Loads the store: collectors (vault set to the fixture vault), runs, the clock.
    static func load(_ e: AppModel, _ list: [Collector], select: String? = nil, now: Date? = nil) -> CollectorsStore {
        let s = e.collectors
        let vault = e.activeVault?.path ?? "/Research"
        s.collectors = list.map { var c = $0; c.vaultPath = vault; return c }
        s.phase = .loaded
        s.fixtureNow = now ?? at(9, 32)
        s.selected = select ?? list.first?.id
        s.runs = ["inbox": inboxRuns(), "pocket": pocketRuns(),
                  "slack": [slack().lastRun!, run("s2", "slack", kind: .script, at(7, 30), ms: 1100, .success, counts: .init(added: 2), exit: 0)],
                  "phone": [phone().lastRun!, run("ph2", "phone", at(8), ms: 300, .success, counts: .init(moved: 2, added: 2),
                                                  files: [.init(name: "IMG_2041.HEIC", outcome: .moved), .init(name: "IMG_2042.HEIC", outcome: .moved)])],
                  "scans": scans(noPermission: true).lastRun.map { [$0] } ?? []]
        return s
    }

    static var base: [Collector] { [inbox(), pocket(), slack(), kindle(), scans()] }

    static func collected(_ id: String) -> [CollectedFile] {
        let rows: [(String, Date)] = [("gongfu-brewing-guide.pdf", at(9)), ("Screenshot 08.52.10.png", at(9)), ("tasting-notes.md", at(9)),
                                      ("gyokuro.md", at(8, daysAgo: 2)), ("receipt.pdf", at(7)), ("menu-autumn.pdf", at(18, daysAgo: 3))]
        return rows.enumerated().map { i, r in
            CollectedFile(sha256: String(repeating: "\(i)", count: 64), name: r.0, sourcePath: home + "/Distill Inbox/" + r.0, size: 1000,
                          mtime: CoreDate.format(r.1), collectedAt: CoreDate.format(r.1), collectorId: id, queueName: r.0)
        }
    }
}

extension StatesSnapshot {
    static func collectorsStates() {
        let f = Flow.collectors
        let size = CGSize(width: 1200, height: 860)
        let narrow = CGSize(width: 900, height: 700)
        func shot(_ file: String, _ state: String, _ desc: String, _ e: AppModel, size: CGSize = size) {
            main(file, f, "Collectors", state, desc, e, section: .collectors, size: size) { CollectorsScreen() }
        }
        typealias F = CollectorFixtures

        var e = engine()
        _ = F.load(e, [])
        shot("collectors-empty", "A · No collectors yet", "Empty state: Add a folder / Add a script; no Add collector in the header.", e)

        e = engine()
        var s = F.load(e, [])
        s.startAdding()
        shot("collectors-add", "B · Add, step 1", "What it does: Collect on a schedule (selected), Commands for buttons, or Both.", e)

        e = engine()
        s = F.load(e, [])
        s.startAdding()
        s.adding?.stage = "Kind"
        shot("collectors-add-kind", "B2 · Add, Collect: the kind", "Folder (selected) or Custom script, as before.", e)

        // Add automation as Commands for buttons: What it does → Source → Commands (no schedule; it never collects).
        e = engine()
        s = F.load(e, [])
        s.startAdding()
        s.adding?.setRole(.commands)
        s.adding?.stage = "Source"
        s.adding?.code = "#!/usr/bin/env zsh\n# send -- <target> <text>: the button passes them after --\nshift  # the command name\n[[ $1 == -- ]] && shift\nslack chat send --channel \"$1\" --text \"$2\"\n"
        shot("collectors-add-commands-source", "B3 · Add, Commands: the script", "Commands for buttons skips Kind and Schedule: a script Distill keeps, or your own file.", e)

        e = engine()
        s = F.load(e, [])
        s.startAdding()
        s.adding?.setRole(.commands)
        s.adding?.stage = "Commands"
        shot("collectors-add-commands", "B4 · Add, Commands: last step", "Where its commands are declared (the saved script's COMMANDS block); Add saves it off, never collecting.", e)

        e = engine()
        s = F.load(e, [])
        s.startAdding(kind: .folder)
        shot("collectors-add-folder", "C · Add Folder, step 2", "The folder (default ~/Distill Inbox) and Keep or Move.", e)

        e = engine()
        s = F.load(e, [])
        s.startAdding(kind: .folder)
        s.adding?.stage = "Schedule"
        shot("collectors-add-schedule", "D · Add, step 3", "Schedule (every hour) and target vault (the active vault).", e)

        e = engine()
        s = F.load(e, [])
        s.startAdding(kind: .script)
        s.adding?.code = F.kindleCode + "\n"
        shot("collectors-add-script", "L · Add Custom script, step 2", "Inline code or a file, and the interpreter.", e)

        e = engine()
        _ = F.load(e, F.base)
        shot("collectors-folder", "E · Folder at a glance", "Status card, read-only settings, the last three runs.", e)
        shot("collectors-folder-900", "E · Folder at a glance · 900 pt", "The same at the window's minimum width.", e, size: narrow)

        e = engine()
        s = F.load(e, F.base)
        s.startEdit(s.collector("inbox")!)
        shot("collectors-folder-edit", "F · Edit settings in place", "The settings block becomes a form with Cancel and Save.", e)
        shot("collectors-folder-edit-900", "F · Edit · 900 pt", "The form at the minimum width.", e, size: narrow)

        e = engine()
        s = F.load(e, F.base)
        var sheet = CollectedSheet(collectorID: "inbox", files: F.collected("inbox"), loading: false)
        sheet.forgotten[sheet.files[3].sha256] = [sheet.files[3]]
        sheet.hover = sheet.files[1].id
        s.collected = sheet
        shot("collectors-folder-collected", "G · Already collected", "Search, Forget on hover, a forgotten file with Undo, Forget all…", e)

        e = engine()
        var running = F.base
        running[0].status?.running = true
        s = F.load(e, running, now: F.at(10, 0, s: 4))
        s.live["inbox"] = F.run("in0", "inbox", F.at(10), .running)
        shot("collectors-folder-running", "H · Running", "The status card says what it is doing; Stop replaces Run now.", e)

        e = engine()
        s = F.load(e, F.base)
        s.page = .allRuns
        s.openRuns = ["in1"]
        shot("collectors-folder-history", "I · All runs", "Per-file detail in an opened run; quiet runs collapse.", e)

        e = engine()
        _ = F.load(e, [F.phone(), F.inbox(), F.pocket()])
        shot("collectors-folder-missing", "J · Error: folder missing", "Choose folder… or Create it; this one moves files.", e)
        shot("collectors-folder-missing-900", "J · Error: folder missing", "Choose folder… or Create it; this one moves files.", e, size: narrow)

        e = engine()
        _ = F.load(e, [F.inbox(), F.scans(noPermission: true)], select: "scans")
        shot("collectors-folder-no-permission", "K · Error: no permission", "Choose again… so macOS asks, or Open Privacy settings.", e)
        shot("collectors-folder-no-permission-900", "K · Error: no permission", "Choose again… so macOS asks, or Open Privacy settings.", e, size: narrow)

        e = engine()
        _ = F.load(e, F.base, select: "kindle")
        shot("collectors-script-consent", "M · New script asks once", "ScriptConsent with the code; nothing runs before Allow and turn on.", e)
        shot("collectors-script-consent-900", "M · New script asks once", "ScriptConsent with the code; nothing runs before Allow and turn on.", e, size: narrow)

        e = engine()
        _ = F.load(e, F.base, select: "pocket")
        shot("collectors-script", "N · Script at a glance", "Status, settings (script, schedule, allowed), Advanced collapsed, recent runs.", e)
        shot("collectors-script-900", "N · Script · 900 pt", "The script detail at the minimum width.", e, size: narrow)

        e = engine()
        s = F.load(e, F.base, select: "pocket")
        s.startEdit(s.collector("pocket")!)
        s.editing?.advancedOpen = true
        shot("collectors-script-edit", "O · Edit, Advanced open", "Interpreter, timeout, cron and what the script gets.", e)
        shot("collectors-script-edit-900", "O · Edit, Advanced open", "Interpreter, timeout, cron and what the script gets.", e, size: narrow)

        e = engine()
        s = F.load(e, F.base, select: "pocket")
        s.page = .allRuns
        s.openRuns = ["p3"]
        shot("collectors-script-log", "P · All runs, a failed run opened", "stderr in an opened run.", e)

        e = engine()
        var pr = F.base
        pr[1].status?.running = true
        s = F.load(e, pr, select: "pocket", now: F.at(10, 14, s: 12))
        let live = F.run("pl", "pocket", kind: .script, F.at(10, 14), .running, trigger: "now")
        s.live["pocket"] = live
        s.output["pl"] = ("Fetching articles since Oct 4, 7:00 AM…\nWrote 1 file to \(F.home)/Documents/Distill Queue/Research\n", "")
        shot("collectors-script-running", "Q · Script running", "Live output in the status card; Stop.", e)
        shot("collectors-script-running-900", "Q · Script running", "Live output in the status card; Stop.", e, size: narrow)

        e = engine()
        _ = F.load(e, F.base, select: "slack")
        shot("collectors-script-failed", "R · Error: the script failed", "Exit 1 with stderr in the status card.", e)
        shot("collectors-script-failed-900", "R · Error: the script failed", "Exit 1 with stderr in the status card.", e, size: narrow)

        e = engine()
        var changed = F.base
        changed[1].status?.currentSha256 = F.shaPocketNew
        changed[1].status?.needsConsent = true
        changed[1].status?.needsAttention = true
        changed[1].status?.lastRun = F.run("pc", "pocket", kind: .script, F.at(7), .notTrusted,
                                           error: .init(code: .scriptChanged, message: "the script changed since you allowed it"))
        s = F.load(e, changed, select: "pocket")
        s.runs["pocket"] = [changed[1].status!.lastRun!] + Array(F.pocketRuns().prefix(1))
        shot("collectors-script-changed", "S · Script changed since you allowed it", "Paused; Allow this version.", e)
        shot("collectors-script-changed-900", "S · Script changed since you allowed it", "Paused; Allow this version.", e, size: narrow)

        // Long content: a long name, a long source path, and 130 collected files with long names.
        e = engine()
        var long = F.base
        long[0].name = "Phone uploads from the shared family iCloud album (weekly)"
        long[0].folder?.source = F.home + "/Library/Mobile Documents/com~apple~CloudDocs/Family/Phone uploads/Shared album exports"
        s = F.load(e, long)
        var many = CollectedSheet(collectorID: "inbox", loading: false)
        many.files = (0..<130).map { i in
            CollectedFile(sha256: String(format: "%064d", i), name: "2026-10-\(String(format: "%02d", i % 28 + 1)) very long scanned receipt name number \(i) from the shared album.pdf",
                          sourcePath: F.home + "/x\(i).pdf", size: 1000, mtime: CoreDate.format(F.at(9)), collectedAt: CoreDate.format(F.at(9, daysAgo: i / 10)),
                          collectorId: "inbox", queueName: "x.pdf")
        }
        shot("collectors-long-name", "Long name and path", "A long collector name and source path in the list and the detail.", e)
        shot("collectors-long-name-900", "Long name and path · 900 pt", "The same at the minimum width.", e, size: narrow)
        s.collected = many
        shot("collectors-collected-long", "Already collected · 130 files", "The list scrolls inside the sheet; long names truncate in the middle.", e)

        // QueuePath states (the Queue screen draws the folder it finds; these force each state).
        e = engine()
        let q = (e.activeVault?.queueDirectory ?? F.home + "/Documents/Distill Queue/Research")
        natural("collectors-queuepath-states", f, "Queue path", "QueuePath states", "Default, copied, missing (Create folder), compact and a long path.", e) {
            VStack(alignment: .leading, spacing: 12) {
                QueuePath(path: q)
                QueuePath(path: q, state: "copied")
                QueuePath(path: q, state: "missing", onCreate: {})
                QueuePath(path: q, label: "Lands in", size: "compact")
                QueuePath(path: F.home + "/Library/Mobile Documents/com~apple~CloudDocs/Distill Queue/Research", width: 420)
            }
            .padding(16).frame(width: 560, alignment: .leading).background(Color.white)
        }

        e = engine()
        s = F.load(e, [])
        s.phase = .unavailable
        shot("collectors-old-core", "Older core", "The core has no collectors routes: calm “Update the Distill core”.", e)

        // v6: script files, packages, Test run and Run now everywhere (board CollectorsScriptFiles).
        collectorScriptStates()
        // Automations: commands and action buttons (board ScriptActions).
        scriptActionStates()
    }
}
