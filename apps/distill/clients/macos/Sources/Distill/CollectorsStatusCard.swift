import AppKit
import SwiftUI
import DistillKit

/// The status card at the top of a collector's detail: "is it working, and what did it last do?"
/// v6 adds packages installing (live output, the run waiting), a failed install (Install again),
/// the result of a run started here (Run now · …, its last output lines, Copy output and Hide),
/// a Test run (the files it made in the test folder, Reveal in Finder) and Ready after an install.
struct CollectorStatusCard: View {
    @ObservedObject var store: CollectorsStore
    let collector: Collector

    enum Tone { case calm, running, error, success, test }

    struct Content {
        var tone: Tone = .calm
        var title = ""
        var lines: [String] = []
        var terminal: [String] = []
        var stderr = false
        /// A header over the terminal ("OUTPUT · LAST LINES") with Copy output, and Hide for a manual run.
        var outputTitle: String?
        var hide = false
        /// A Test run's files (name, size) with Reveal in Finder and Show log.
        var testRun: CollectorRun?
        /// v7: Show log opens the whole output.
        var log: CollectorLogTarget?
        var buttons: [(String, String?, () -> Void)] = []
    }

    var body: some View {
        let c = collector
        let content = describe(c)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if content.tone == .running { Spinner(size: 13) }
                if content.tone == .error { Image(systemName: "exclamationmark.triangle").font(.system(size: 13, weight: .bold)) }
                Text(content.title).font(Theme.body(15, .bold)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(content.tone == .error ? Theme.peachInk : Theme.ink)
            ForEach(content.lines, id: \.self) { line in
                Text(line).font(Theme.body(12.5)).foregroundStyle(CollectorsTheme.body).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let run = content.testRun { testFiles(run) }
            if !content.terminal.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    if let title = content.outputTitle ?? (content.log != nil ? (content.stderr ? "STDERR · LAST LINES" : "OUTPUT · LAST LINES") : nil) {
                        HStack(spacing: 12) {
                            Text(title).font(Theme.body(10, .heavy)).kerning(0.6).foregroundStyle(content.stderr ? Theme.peachInk : Theme.faint)
                            Spacer()
                            if content.outputTitle != nil { CopyOutputButton(lines: content.terminal) }
                            if let log = content.log {
                                Button { store.openLog(log) } label: { Text("Show log").font(Theme.body(11.5, .semibold)).foregroundStyle(Theme.primary) }
                                    .buttonStyle(.plain)
                            }
                            if content.hide {
                                Button { store.hideResult(c) } label: { Text("Hide").font(Theme.body(11, .semibold)).foregroundStyle(Theme.primary) }
                                    .buttonStyle(.plain)
                            }
                        }
                    }
                    TerminalLines(lines: content.terminal, stderr: content.stderr)
                }
                .padding(.top, 6)
            }
            if let run = content.testRun { testFooter(run) }
            actions(c, extra: content.buttons)
            if c.isFolder, let n = c.status?.collectedCount, n > 0 {
                HStack(spacing: 0) {
                    Text("Already collected: ").font(Theme.body(12.5)).foregroundStyle(Theme.muted)
                    Button { store.openCollected(c) } label: {
                        Text(CollectorText.files(n)).font(Theme.body(12.5, .semibold)).foregroundStyle(Theme.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(fill(content.tone)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(stroke(content.tone)))
    }

    private func fill(_ t: Tone) -> Color {
        switch t {
        case .error: return CollectorsTheme.errorFill
        case .running: return CollectorsTheme.runningFill
        case .success: return Color(hex: 0xF6FDEB)
        case .test: return Color(hex: 0xF4F7FD)
        case .calm: return Theme.panel
        }
    }

    private func stroke(_ t: Tone) -> Color {
        switch t {
        case .error: return CollectorsTheme.errorStroke
        case .success: return Color(hex: 0xDDF5B8)
        case .test: return Color(hex: 0xDCE6F7)
        default: return .clear
        }
    }

    // MARK: Test run

    private func testFiles(_ run: CollectorRun) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(run.filesAdded.prefix(8).enumerated()), id: \.offset) { i, name in
                HStack(spacing: 8) {
                    Image(systemName: "doc").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.muted)
                    Text(name).font(Theme.body(12.5)).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let size = store.testFileSize(run, name) {
                        Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)).font(Theme.body(11.5)).foregroundStyle(Theme.faint)
                    }
                }
                .padding(.vertical, 5)
                .overlay(alignment: .top) { if i > 0 { Rectangle().fill(Color(hex: 0xE6EBF5)).frame(height: 1) } }
            }
            if run.filesAdded.count > 8 {
                Text("and \(run.filesAdded.count - 8) more").font(Theme.body(11.5)).foregroundStyle(Theme.faint)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 5)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.white))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color(hex: 0xE6EBF5)))
        .opacity(run.filesAdded.isEmpty ? 0 : 1)
        .frame(height: run.filesAdded.isEmpty ? 0 : nil)
    }

    private func testFooter(_ run: CollectorRun) -> some View {
        let open = store.testOutputOpen.contains(run.id)
        let next = collector.status?.nextRunAt.map { " · " + store.text.next($0, now: store.now) } ?? ""
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                testLinks(run, open: open)
                Spacer(minLength: 8)
                Text("Schedule unchanged" + next).font(Theme.body(11.5)).foregroundStyle(Theme.faint).lineLimit(1).fixedSize()
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 12) { testLinks(run, open: open) }
                Text("Schedule unchanged" + next).font(Theme.body(11.5)).foregroundStyle(Theme.faint).lineLimit(1)
            }
        }
        .padding(.top, 2)
    }

    @ViewBuilder private func testLinks(_ run: CollectorRun, open: Bool) -> some View {
        if let dir = run.outputDir {
            Button { store.reveal(run.filesAdded.first.map { (dir as NSString).appendingPathComponent($0) } ?? dir) } label: {
                Text("Reveal in Finder").font(Theme.body(11.5, .semibold)).foregroundStyle(Theme.primary).fixedSize()
            }
            .buttonStyle(.plain)
        }
        // v7: the Test run's whole output opens in the log view.
        Button { store.openLog(.run(collectorId: collector.id, runId: run.id)) } label: {
            Text("Show log").font(Theme.body(11.5, .semibold)).foregroundStyle(Theme.primary).fixedSize()
        }
        .buttonStyle(.plain)
    }

    // MARK: Buttons

    @ViewBuilder private func actions(_ c: Collector, extra: [(String, String?, () -> Void)]) -> some View {
        let code = c.isRunning ? nil : c.lastRun?.error?.code
        let buttons: [(String, String?, () -> Void)] = {
            if !extra.isEmpty { return extra }
            switch code {
            case .sourceMissing?: return [("Choose folder…", nil, { store.chooseSource(c) }), ("Create it", nil, { store.createFolder(c, which: "source") })]
            case .noPermission?: return [("Choose again…", nil, { store.chooseSource(c) })]
            case .queueMissing?: return [("Create folder", nil, { store.createFolder(c, which: "queue") })]
            default: return []
            }
        }()
        if !buttons.isEmpty {
            HStack(spacing: 8) {
                ForEach(buttons, id: \.0) { b in
                    SoftButton(title: b.0, fill: .white, size: .small, stroke: true, systemImage: b.1, action: b.2).fixedSize()
                        .disabled(store.busy[c.id] != nil)
                }
                if code == .noPermission, extra.isEmpty {
                    LinkButton(title: "Open Privacy settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders") { NSWorkspace.shared.open(url) }
                    }
                }
            }
            .padding(.top, 6)
        }
    }

    // MARK: What it says

    func describe(_ c: Collector) -> Content {
        let text = store.text, now = store.now
        if c.isInstalling { return installing(c) }
        if text.installFailed(c), !c.isRunning { return installFailed(c) }
        if c.isRunning { return running(c) }
        if let run = store.shownRun(c) { return run.isTest ? testResult(c, run) : manualResult(c, run) }
        guard let r = c.lastRun else {
            if c.isManaged, c.manifest?.state == "ready", let i = store.currentInstall(c) ?? c.manifest?.lastInstall, i.result == "success" {
                let next = c.status?.nextRunAt.map { text.next($0, now: now).replacingOccurrences(of: "next ", with: "next run ") } ?? "it runs with Run now"
                let took = CollectorText.duration(i.durationMs).map { " in \($0)" } ?? ""
                return Content(tone: .success, title: "Ready · \(next)",
                               lines: ["Packages installed\(took). Test run tries it without touching the queue."])
            }
            let next = c.status?.nextRunAt.map { text.next($0, now: now) }
            return Content(title: "Not run yet", lines: [c.enabled ? (next.map { "First run: " + $0.replacingOccurrences(of: "next ", with: "") + "." } ?? "Run now runs it at once.") : "It's off. Run now still works."])
        }
        return lastRun(c, r)
    }

    private func installing(_ c: Collector) -> Content {
        let text = store.text, now = store.now
        let install = store.currentInstall(c)
        let name = c.manifest?.name ?? "the manifest"
        let elapsed = CollectorText.elapsed(now.timeIntervalSince(install?.startedAt ?? now))
        let waiting = store.activeRun(c).map { $0.result == .queued } ?? false
        var line: String
        switch install?.trigger {
        case "allow":
            line = waiting
                ? "You allowed this version, so Distill installs what \(name) lists now. Runs after packages install: the run you started with Allow and run waits for it. Stop ends both."
                : "You allowed this version, so Distill installs what \(name) lists now, into the collector’s folder. The first run waits for it."
        case "beforeRun":
            line = "Packages went missing, so the run installs them first. Stop ends both."
        default:
            line = "Installing what \(name) lists into the collector’s folder." + (waiting ? " The run you started waits for it; Stop ends both." : " A run started now waits for it.")
        }
        line += " Stops after 10 minutes."
        let lines = store.installLines(c)
        _ = text
        return Content(tone: .running, title: "Installing packages · \(elapsed)", lines: [line], terminal: Array(lines.suffix(8)),
                       log: install.map { .install(collectorId: c.id, installId: $0.id) })
    }

    private func installFailed(_ c: Collector) -> Content {
        let install = store.currentInstall(c)
        let name = c.manifest?.name ?? "the manifest"
        let tool = name == "requirements.txt" ? "pip" : "npm"
        let exit = install?.exitCode.map { " · exit \($0)" } ?? (install?.result == "timedout" ? " · timed out" : "")
        let path = c.manifest?.path ?? ""
        return Content(tone: .error, title: "Couldn’t install packages\(exit)",
                       lines: ["\(tool) couldn’t install them, so nothing runs: not on schedule, not with Run now, until the packages install. Fix \(name), then Install again. It isn’t retried every hour."],
                       terminal: Array(store.installLines(c).suffix(6)), stderr: true, outputTitle: "INSTALL OUTPUT · LAST LINES",
                       log: install.map { .install(collectorId: c.id, installId: $0.id) },
                       buttons: [("Install again", "arrow.clockwise", { store.install(c) }),
                                 ("Open \(name)", nil, { store.openInEditor(path) })])
    }

    private func running(_ c: Collector) -> Content {
        let text = store.text
        let run = store.activeRun(c)
        var lines: [String] = []
        if let run {
            if run.result == .queued {
                switch run.waiting {
                case "batch": lines.append("It starts when the batch applying to this vault finishes.")
                case "install": lines.append("It starts when the packages finish installing.")
                default: lines.append("It starts when a slot is free (two collectors run at once).")
                }
            } else if c.isScript {
                let how = run.isTest ? "Test run into Distill’s test folder" : run.trigger == "now" ? "Started with Run now" : run.trigger == "catchup" ? "Started to catch up" : "Started"
                let stop = run.startedAt.addingTimeInterval(TimeInterval(c.script?.timeoutSeconds ?? 300))
                lines.append("\(how) at \(text.clock(run.startedAt)) · stops at \(text.clock(stop))")
            } else {
                lines.append("Started at \(text.clock(run.startedAt))")
            }
        }
        var terminal: [String] = []
        if c.isScript, let run, let out = store.output[run.id] {
            terminal = (out.stdout + out.stderr).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            while terminal.last == "" { terminal.removeLast() }
            terminal = Array(terminal.suffix(8))
        }
        return Content(tone: .running, title: text.runningLine(c, run: run, now: store.now), lines: lines, terminal: terminal,
                       log: c.isScript ? run.map { .run(collectorId: c.id, runId: $0.id) } : nil)
    }

    /// Run now's result, right away: one sentence, the schedule, and the last output lines.
    private func manualResult(_ c: Collector, _ r: CollectorRun) -> Content {
        let text = store.text, now = store.now
        let when = text.at(r.startedAt, now: now)
        let next = c.status?.nextRunAt.map { text.next($0, now: now).replacingOccurrences(of: "next ", with: "") }
        let command = collectorCommand(c, text: text).map { ["$ " + $0] } ?? []
        switch r.result {
        case .success, .nothing:
            let did: String
            if c.isScript {
                did = r.counts.added == 0 ? "nothing new" : "added \(CollectorText.files(r.counts.added))"
            } else if r.result == .nothing {
                did = "nothing new"
            } else {
                let unit = (r.files ?? []).contains(where: \.isFolder) ? CollectorText.items : CollectorText.files
                did = r.counts.moved > 0 ? "moved \(unit(r.counts.moved))" : "copied \(unit(r.counts.copied))"
            }
            var line = c.isScript ? "Exit 0" + (CollectorText.duration(r.durationMs).map { " after \($0)" } ?? "") + "." : ""
            if let next { line += (line.isEmpty ? "" : " ") + "It also keeps its schedule: next \(next)." }
            let out = tail(r.stdoutTail, 6)
            return Content(tone: .success, title: "Run now · \(did) \(when)", lines: line.isEmpty ? [] : [line],
                           terminal: c.isScript && !out.isEmpty ? command + out : [], outputTitle: "OUTPUT · LAST LINES", hide: true,
                           log: c.isScript ? .run(collectorId: c.id, runId: r.id) : nil)
        case .stopped:
            return Content(title: "Run now · stopped \(when)", lines: [r.counts.added > 0 ? "It added \(CollectorText.files(r.counts.added)) before you stopped it." : "You stopped it. It stays on schedule."],
                           terminal: c.isScript ? command + tail(r.stdoutTail ?? r.stderrTail, 6) : [], outputTitle: "OUTPUT · LAST LINES", hide: true)
        default:
            if r.error?.code == .installFailed || r.result == .notTrusted { return lastRun(c, r) }
            let exit = r.exitCode.map { " · exit \($0)" } ?? (r.result == .timedout ? " · timed out" : "")
            let added = r.counts.added > 0 ? "Added \(CollectorText.files(r.counts.added)) \(when); they stay in the queue." : "Added nothing \(when)."
            var lines = [c.isScript ? added + " It stays on schedule." : (r.error?.message ?? "It stays on schedule.")]
            if let m = r.error?.message, !m.isEmpty, c.isScript, r.error?.code != .scriptFailed { lines.append(m) }
            let err = tail(r.stderrTail, 6)
            return Content(tone: .error, title: "Run now · failed\(exit)", lines: lines,
                           terminal: c.isScript && !err.isEmpty ? command + err : [], stderr: true, outputTitle: "STDERR · LAST LINES", hide: true,
                           log: c.isScript ? .run(collectorId: c.id, runId: r.id) : nil)
        }
    }

    /// A Test run: what it made in the test folder, never the queue.
    private func testResult(_ c: Collector, _ r: CollectorRun) -> Content {
        let command = collectorCommand(c, text: store.text).map { ["$ " + $0] } ?? []
        let open = store.testOutputOpen.contains(r.id)
        let ok = r.result == .success || r.result == .nothing
        let duration = CollectorText.duration(r.durationMs).map { " after \($0)" } ?? ""
        if ok {
            let n = r.filesAdded.count
            let title = n == 0 ? "Test run · nothing in the test folder, nothing in the queue" : "Test run · \(CollectorText.files(n)) in the test folder, nothing in the queue"
            let out = tail(r.stdoutTail, 8)
            return Content(tone: .test, title: title,
                           lines: ["Exit 0\(duration). It ran exactly like a real run, but wrote to Distill’s test folder instead of the queue. Kept until the next test run."],
                           terminal: open ? command + (out.isEmpty ? ["(no output)"] : out) : [], outputTitle: open ? "OUTPUT · LAST LINES" : nil, testRun: r)
        }
        if r.error?.code == .installFailed || r.result == .notTrusted { return lastRun(c, r) }
        let exit = r.exitCode.map { " · exit \($0)" } ?? (r.result == .timedout ? " · timed out" : r.result == .stopped ? " · stopped" : "")
        let err = tail(r.stderrTail ?? r.stdoutTail, 6)
        return Content(tone: r.result == .stopped ? .test : .error, title: "Test run · failed\(exit)",
                       lines: ["Nothing reached the queue: a Test run writes to Distill’s test folder. The schedule is unchanged."],
                       terminal: err.isEmpty ? [] : command + err, stderr: true, outputTitle: "STDERR · LAST LINES", testRun: r.filesAdded.isEmpty ? nil : r)
    }

    private func lastRun(_ c: Collector, _ r: CollectorRun) -> Content {
        let text = store.text, now = store.now
        let when = text.at(r.startedAt, now: now)
        let nextLine = c.status?.nextRunAt.map { "It stays on schedule and tries again " + text.next($0, now: now).replacingOccurrences(of: "next ", with: "") + "." }
        switch r.result {
        case .success, .nothing:
            var lines: [String] = []
            let title: String
            if c.isScript {
                title = r.counts.added == 0 ? "Nothing new \(when)" : "Added \(CollectorText.files(r.counts.added)) \(when)"
                lines.append("Exit 0" + (CollectorText.duration(r.durationMs).map { " after \($0)" } ?? "") + ".")
            } else if r.result == .nothing {
                title = "Nothing new \(when)"
                if r.counts.skipped > 0 { lines.append("Skipped \(r.counts.skipped) that \(r.counts.skipped == 1 ? "was" : "were") already collected.") }
            } else {
                let moved = r.counts.moved > 0
                title = "\(moved ? "Moved" : "Copied") \(((r.files ?? []).contains(where: \.isFolder) ? CollectorText.items : CollectorText.files)(moved ? r.counts.moved : r.counts.copied)) \(when)"
                var bits: [String] = []
                if r.counts.skipped > 0 { bits.append("Skipped \(r.counts.skipped) that \(r.counts.skipped == 1 ? "was" : "were") already collected.") }
                if r.counts.waiting > 0 { bits.append("\(r.counts.waiting) still changing; the next run takes \(r.counts.waiting == 1 ? "it" : "them").") }
                if r.counts.errors > 0 { bits.append("\(r.counts.errors) couldn't be \(moved ? "moved" : "copied"); open the run to see why.") }
                if !bits.isEmpty { lines.append(bits.joined(separator: " ")) }
            }
            if !c.enabled { lines.append("It's off. Run now still works.") }
            return Content(title: title, lines: lines)
        case .stopped:
            return Content(title: "Stopped \(when)", lines: [r.counts.added > 0 ? "It added \(CollectorText.files(r.counts.added)) before you stopped it." : "You stopped it. It runs again on schedule."])
        case .skipped:
            return Content(title: "Skipped \(when)", lines: [r.skipReason.map { "The \($0)." } ?? ""].filter { !$0.isEmpty })
        case .timedout:
            let after = CollectorText.timeout(c.script?.timeoutSeconds ?? 300)
            return Content(tone: .error, title: "Stopped after \(after) \(when)",
                           lines: [(r.counts.added > 0 ? "It added \(CollectorText.files(r.counts.added)); they stay in the queue." : "Added nothing.") + (nextLine.map { " " + $0 } ?? "")],
                           terminal: tail(r.stderrTail ?? r.stdoutTail, 6), stderr: r.stderrTail != nil)
        default:
            switch r.error?.code {
            case .sourceMissing?:
                return Content(tone: .error, title: "\(text.tilde(c.folder?.source ?? "The folder")) is missing",
                               lines: ["It was moved, renamed or deleted, so the \(text.clock(r.startedAt)) run collected nothing."])
            case .noPermission?:
                return Content(tone: .error, title: "Distill can’t open \(text.tilde(c.folder?.source ?? "the folder"))",
                               lines: ["macOS hasn’t given Distill access to this folder. Choose it again so macOS asks you."])
            case .queueMissing?:
                return Content(tone: .error, title: "The queue folder is missing",
                               lines: ["\(store.queuePath(c.vaultPath).map(text.tilde) ?? "It") was moved or deleted, so the \(text.clock(r.startedAt)) run collected nothing."])
            case .interrupted?:
                return Content(tone: .error, title: "Interrupted \(when)", lines: ["Distill quit while it ran. It runs again on schedule."])
            case .installFailed?:
                return Content(tone: .error, title: "Not run \(when) · packages aren’t installed",
                               lines: ["Install the packages again (⋯ → Install packages), then Run now."])
            default:
                let exit = r.exitCode.map { " · exit \($0)" } ?? ""
                var lines: [String] = []
                if c.isScript {
                    lines.append((r.counts.added > 0 ? "Added \(CollectorText.files(r.counts.added)); they stay in the queue." : "Added nothing.") + (nextLine.map { " " + $0 } ?? ""))
                }
                if let m = r.error?.message, !m.isEmpty, r.error?.code != .scriptFailed { lines.append(m) }
                return Content(tone: .error, title: "Failed \(when)\(exit)", lines: lines, terminal: tail(r.stderrTail, 6), stderr: true,
                               log: c.isScript ? .run(collectorId: c.id, runId: r.id) : nil)
            }
        }
    }

    private func tail(_ s: String?, _ n: Int) -> [String] {
        guard let s, !s.isEmpty else { return [] }
        var lines = s.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        while lines.last == "" { lines.removeLast() }
        return Array(lines.suffix(n))
    }
}
