import AppKit
import SwiftUI
import DistillKit

// v7 live log (canvas row 9: LiveLog, CollectorsLog, LogLine; spec live-log.md).
// One view for a batch's steps and for a collector's output. It opens in place of the
// screen it came from (‹ back), follows the newest line until the user scrolls up
// (then "Jump to latest"), has Copy, and stays readable after the run.

/// One line of the live log (canvas component LogLine).
struct LogLine: View {
    /// step | group | note | phase | output
    var kind: String = "step"
    /// done | running | waiting | review | failed
    var state: String = "done"
    var text: String
    var time: String = ""
    var count: String = ""
    /// "done/total": the thin bar of a running group.
    var progress: String = ""
    var detail: String = ""
    var showDetail = false
    /// stdout | stderr | cmd | system
    var stream: String = "stdout"
    /// "0" or "1" (a file inside a group).
    var level: String = "0"
    var expanded = false
    var width: CGFloat? = nil
    var onToggle: (() -> Void)? = nil

    var body: some View {
        Group {
            switch kind {
            case "phase": phase
            case "output": output
            default: row
            }
        }
        .frame(width: width, alignment: .leading)
        .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
    }

    private var phase: some View {
        HStack(spacing: 8) {
            Text(text).font(Theme.body(10, .heavy)).kerning(0.6).foregroundStyle(Theme.faint).lineLimit(1).fixedSize()
            Rectangle().fill(Theme.border).frame(height: 1)
            Text(time).font(Theme.body(11)).monospacedDigit().foregroundStyle(Theme.faint).fixedSize()
        }
        .padding(.top, 14).padding(.bottom, 6).padding(.horizontal, 8)
    }

    private var output: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            RoundedRectangle(cornerRadius: 2).fill(stream == "stderr" ? Color(hex: 0xFF9A6B) : .clear).frame(width: 3)
                .frame(maxHeight: .infinity)
            Text(text.isEmpty ? " " : text).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(outputInk)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !time.isEmpty {
                Text(time).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Color(hex: 0x7C7870)).fixedSize()
            }
        }
        .padding(.horizontal, 4)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var outputInk: Color {
        switch stream {
        case "stderr": return Theme.peach
        case "cmd", "system": return Theme.faint
        default: return Color(hex: 0xE8E6E1)
        }
    }

    @ViewBuilder private var row: some View {
        if let onToggle {
            Button(action: onToggle) { rowContent }
                .buttonStyle(.plain)
                .accessibilityAddTraits(.isButton)
        } else {
            rowContent
        }
    }

    private var rowContent: some View {
        let isGroup = kind == "group"
        return HStack(alignment: .top, spacing: 10) {
                mark.frame(width: 18, height: 18).padding(.top, 1)
                VStack(alignment: .leading, spacing: 5) {
                    (Text(text).foregroundColor(textInk).italic(kind == "note")
                        + Text(count.isEmpty ? "" : " · \(count)").foregroundColor(Theme.faint))
                        .font(Theme.body(level == "1" ? 12.5 : 13))
                        .lineLimit(kind == "note" ? 4 : 1)
                        .truncationMode(.middle)
                        .fixedSize(horizontal: false, vertical: kind == "note")
                    if let bar = fraction, state == "running" {
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Theme.border)
                                Capsule().fill(Theme.primary).frame(width: g.size.width * bar)
                            }
                        }
                        .frame(width: 180, height: 4)
                    }
                    if showDetail, !detail.isEmpty {
                        Text(detail).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.muted)
                            .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if isGroup {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.faint).padding(.top, 4)
                }
                Text(time).font(Theme.body(11)).monospacedDigit().foregroundStyle(Theme.faint)
                    .frame(minWidth: 52, alignment: .trailing).padding(.top, 1)
            }
            .padding(.vertical, level == "1" ? 4 : 6)
            .padding(.leading, level == "1" ? 36 : 8).padding(.trailing, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(isGroup && expanded ? Theme.panel : .clear))
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
    }

    private var fraction: Double? {
        let p = progress.split(separator: "/").compactMap { Double($0) }
        guard p.count == 2, p[1] > 0 else { return nil }
        return min(1, p[0] / p[1])
    }

    private var textInk: Color {
        if kind == "note" { return Color(hex: 0x48463F) }
        switch state {
        case "failed": return Theme.peachInk
        case "waiting": return Theme.faint
        default: return Theme.ink
        }
    }

    @ViewBuilder private var mark: some View {
        if kind == "note" {
            Image(systemName: "bubble.left").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.faint)
        } else {
            switch state {
            case "running": Spinner(size: 11)
            case "waiting": Circle().strokeBorder(Color(hex: 0xC9C5BD), lineWidth: 1.5).frame(width: 11, height: 11)
            case "review": Image(systemName: "clock").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.peachInk)
            case "failed": Image(systemName: "exclamationmark").font(.system(size: 11, weight: .heavy)).foregroundStyle(Theme.peachInk)
            default: Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.limeInk)
            }
        }
    }
}

extension LogLine {
    /// A row the DistillKit logic built.
    init(_ row: LogRow, details: Bool, timeText: String, onToggle: (() -> Void)? = nil) {
        self.init(kind: row.kind.rawValue, state: row.state, text: row.text, time: timeText, count: row.count ?? "",
                  progress: row.progress.map { "\($0.done)/\($0.total)" } ?? "", detail: row.detail ?? "", showDetail: details,
                  stream: row.stream, level: row.level == 1 ? "1" : "0", expanded: row.expanded,
                  onToggle: row.kind == .group ? onToggle : nil)
    }
}

/// The log view: back link, title and status, optional step strip, the lines (following the newest),
/// Jump to latest, Details and Copy, and a quiet footnote.
struct LiveLogView<Sub: View, Top: View>: View {
    let back: String
    let title: String
    var rows: [LogRow]
    /// Output on the dark terminal surface (collectors).
    var dark = false
    /// nil: no Details switch (output is already raw).
    var details: Binding<Bool>? = nil
    var foot: String? = nil
    var footLink: (String, () -> Void)? = nil
    /// Shown instead of the lines (a batch from before steps were kept).
    var empty: (title: String, message: String)? = nil
    /// Sections instead of one stream (a run saved before output was kept in order).
    var sections: [(title: String, stderr: Bool, rows: [LogRow])] = []
    /// Snapshots: start scrolled up (Jump to latest shows).
    var startFollowing = true
    let copyText: () -> String
    let onBack: () -> Void
    var onToggle: (String) -> Void = { _ in }
    @ViewBuilder var subtitle: Sub
    @ViewBuilder var top: Top

    @State private var following = true
    @State private var settling = false
    @State private var copied = false
    @Environment(\.snapshotMode) private var snapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onBack) {
                Text("‹ \(back)").font(Theme.body(12.5, .semibold)).foregroundStyle(Theme.primary).lineLimit(1)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .padding(.bottom, 10)
            header
            top.padding(.top, 12)
            Rectangle().fill(Theme.border).frame(height: 1).padding(.top, 14)
            if let empty { emptyState(empty) } else { lines }
            if let foot {
                Rectangle().fill(Theme.border).frame(height: 1)
                HStack(spacing: 12) {
                    if let footLink { LinkButton(title: footLink.0, size: 11.5, action: footLink.1) }
                    Spacer(minLength: 0)
                    Text(foot).font(Theme.body(11.5)).foregroundStyle(Theme.faint).lineLimit(2)
                        .multilineTextAlignment(footLink == nil ? .leading : .trailing)
                        .frame(maxWidth: footLink == nil ? .infinity : nil, alignment: footLink == nil ? .leading : .trailing)
                }
                .padding(.top, 10).padding(.bottom, 16)
            } else {
                Spacer().frame(height: 16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { following = startFollowing }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(Theme.display(24)).lineLimit(1).truncationMode(.tail)
                HStack(spacing: 6) { subtitle }.font(Theme.body(12.5)).foregroundStyle(Theme.muted).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 14) {
                if let details { CapsuleSwitch(title: "Details", isOn: details) }
                SoftButton(title: copied ? "Copied" : "Copy", fill: .white, size: .small, stroke: true, systemImage: copied ? "checkmark" : "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(copyText(), forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                }
                .fixedSize()
                .help("Copy the whole log as text")
            }
            .padding(.top, 4)
        }
    }

    private func emptyState(_ e: (title: String, message: String)) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(e.title).font(Theme.body(13, .semibold))
            Text(e.message).font(Theme.body(12.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: 560, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.panel))
        .padding(.top, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var lines: some View {
        GeometryReader { outer in
            ScrollViewReader { proxy in
                ZStack(alignment: .bottom) {
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: 0) {
                            if sections.isEmpty {
                                block(rows)
                            } else {
                                ForEach(Array(sections.enumerated()), id: \.offset) { _, s in
                                    Text(s.title).font(Theme.body(10, .heavy)).kerning(0.6)
                                        .foregroundStyle(s.stderr ? Theme.peachInk : Theme.faint)
                                        .padding(.top, 10).padding(.bottom, 6)
                                    block(s.rows)
                                }
                            }
                            Color.clear.frame(height: 1).id("bottom")
                                .background(GeometryReader { g in
                                    Color.clear.preference(key: LogBottomKey.self, value: g.frame(in: .named("log")).minY)
                                })
                        }
                        .frame(maxWidth: dark ? .infinity : 760, alignment: .leading)
                        .padding(.top, 6).padding(.bottom, 12)
                        .background(OverlayScrollers())
                    }
                    .coordinateSpace(name: "log")
                    .onPreferenceChange(LogBottomKey.self) { y in
                        guard !settling else { return }
                        let atBottom = y <= outer.size.height + 24
                        if atBottom != following { following = atBottom }
                    }
                    .onChange(of: rows) {
                        guard following, !snapshot else { return }
                        settling = true
                        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("bottom", anchor: .bottom) }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { settling = false }
                    }
                    .onAppear {
                        guard startFollowing else { return }
                        DispatchQueue.main.async { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                    if !following {
                        Button {
                            following = true
                            settling = true
                            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { settling = false }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.down").font(.system(size: 11, weight: .bold))
                                Text("Jump to latest").font(Theme.body(12.5, .semibold))
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14).frame(height: 30)
                            .background(Capsule().fill(Theme.ink))
                            .shadow(color: Theme.ink.opacity(0.18), radius: 7, y: 4)
                        }
                        .buttonStyle(.plain)
                        .padding(.bottom, 18)
                    }
                }
            }
        }
    }

    @ViewBuilder private func block(_ rows: [LogRow]) -> some View {
        if dark {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { r in LogLine(r, details: false, timeText: r.time.map(Self.second) ?? "") }
            }
            .padding(.horizontal, 8).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(hex: 0x1F1E1C)))
        } else {
            ForEach(rows) { r in
                LogLine(r, details: details?.wrappedValue ?? false, timeText: r.time.map(Self.minute) ?? "") { onToggle(r.id) }
            }
        }
    }

    static func minute(_ d: Date) -> String { ActionsClock.time(d) }
    static func second(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "H:mm:ss"
        return f.string(from: d)
    }
}

private struct LogBottomKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// The pulsing "Live" mark in a log's subtitle.
struct LiveMark: View {
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(Theme.primary).frame(width: 7, height: 7)
            Text("Live").font(Theme.body(12.5, .semibold)).foregroundStyle(Theme.primary)
        }
    }
}

/// Snapshots: how a steps view starts (Details on, scrolled up, groups open).
struct StepsSnapshot {
    var details = false
    var following = true
    var expanded: Set<String> = []
}

struct LogDot: View {
    var body: some View { Text("·").foregroundStyle(Theme.faint) }
}

// MARK: - Job steps

/// The live log of each job: live from `job.step` events, loaded with `GET /v1/jobs/:id/steps`.
@MainActor
final class JobStepsStore: ObservableObject {
    @Published var steps: [String: [JobStep]] = [:]
    /// False for a job that ran before steps were kept (from the core's answer).
    @Published var kept: [String: Bool] = [:]
    /// Jobs whose core doesn't serve steps (an older core: 501 or no route).
    @Published var unavailable: Set<String> = []
    @Published var loaded: Set<String> = []
    weak var engine: AppModel?
    fileprivate static var stores: [ObjectIdentifier: JobStepsStore] = [:]

    static func of(_ engine: AppModel) -> JobStepsStore {
        let key = ObjectIdentifier(engine)
        if let s = stores[key] { return s }
        let s = JobStepsStore()
        s.engine = engine
        stores[key] = s
        return s
    }

    func received(jobId: String, step: JobStep) {
        steps[jobId] = LiveLog.merge(steps[jobId] ?? [], step)
        kept[jobId] = true
    }

    func load(_ jobId: String, force: Bool = false) {
        guard force || !loaded.contains(jobId), let client = engine?.client else { return }
        loaded.insert(jobId)
        Task { [weak self] in
            let page: JobStepsPage
            do {
                page = try await client.jobSteps(jobId)
            } catch {
                guard let self else { return }
                if let e = error as? CoreClientError, e.isNotAvailable {
                    self.unavailable.insert(jobId)
                } else {
                    self.loaded.remove(jobId)
                }
                return
            }
            guard let self else { return }
            self.unavailable.remove(jobId)
            // Steps that came live while the request was out win (they are newer).
            var merged = page.steps
            for s in self.steps[jobId] ?? [] where !merged.contains(where: { $0.id == s.id && $0 == s }) { merged = LiveLog.merge(merged, s) }
            self.steps[jobId] = merged
            self.kept[jobId] = page.kept || !merged.isEmpty
        }
    }

    /// After a reconnect: logs that were open load again (steps may have been missed).
    func reconnected() {
        let ids = loaded
        loaded = []
        for id in ids { load(id) }
    }
}

extension AppModel {
    var jobSteps: JobStepsStore { JobStepsStore.of(self) }
}

/// A batch's steps (LiveLog board): from Queue while it runs, from Review and History afterwards.
struct JobStepsView: View {
    @EnvironmentObject var engine: AppModel
    @ObservedObject var store: JobStepsStore
    let job: Job
    let back: String
    var title: String? = nil
    var startDetails = false
    var startFollowing = true
    var startExpanded: Set<String> = []
    let onBack: () -> Void
    @State private var details = false
    @State private var expanded: Set<String> = []
    @State private var primed = false

    var body: some View {
        let steps = LiveLog.settled(store.steps[job.id] ?? [], job: job.state)
        let runner = runnerName
        let rows = LiveLog.rows(steps, runner: runner == "Claude Code" ? "Claude" : runner, expanded: expanded, details: details)
        let empty: (title: String, message: String)? = !steps.isEmpty ? nil
            : store.unavailable.contains(job.id)
                ? ("Update the Distill core", "This core doesn’t keep a batch’s steps yet. Update Distill (distill.sh update) and they show up here. Nothing else is affected.")
            : store.kept[job.id] == false && job.state != .running
                ? ("Steps weren’t kept for this batch", "It ran before Distill kept steps. The conversation has what Claude said; Open in Terminal shows the whole session.")
            : nil
        LiveLogView(back: back, title: title ?? job.displayTitle, rows: rows, details: $details, foot: foot, empty: empty, startFollowing: startFollowing,
                    copyText: { LiveLog.copyText(steps, title: copyTitle) }, onBack: onBack,
                    onToggle: { id in if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) } }) {
            subtitle
        } top: {
            if job.state == .running, let p = engine.progress(forJob: job.id), !p.steps.isEmpty {
                StepRow(steps: BatchBanner.steps(p.steps), index: p.stepIndex ?? 0)
            }
        }
        .onAppear {
            store.load(job.id)
            if !primed { details = startDetails; expanded = startExpanded; primed = true }
        }
    }

    private var runnerName: String {
        let id = job.selection.runnerID
        return id == "claude-code" ? "Claude Code" : id == "codex" ? "Codex" : id
    }

    private var vault: String { URL(fileURLWithPath: job.vaultPath).lastPathComponent }
    private var copyTitle: String { "\(job.displayTitle) · \(vault) · \(runnerName) · \(ModelChoice.shortName(job.model))" }

    @ViewBuilder private var subtitle: some View {
        let model = ModelChoice.shortName(job.model)
        switch job.state {
        case .running:
            LiveMark(); LogDot(); Text("\(runnerName) · \(model)"); LogDot(); Text("into \(vault)"); LogDot(); Text("started at \(ActionsClock.time(job.createdAt))")
        case .awaitingApproval:
            Text("Ready for your review").foregroundStyle(Theme.peachInk).fontWeight(.semibold); LogDot(); Text("\(runnerName) · \(model)"); LogDot()
            Text("\(ActionsClock.time(job.createdAt)) to \(ActionsClock.time(job.updatedAt))")
        case .completed:
            Text("Applied at \(ActionsClock.time(job.updatedAt))").foregroundStyle(Theme.limeInk).fontWeight(.semibold); LogDot(); Text("\(runnerName) · \(model)")
        case .failed:
            Text("Failed at \(ActionsClock.time(job.updatedAt))").foregroundStyle(Theme.peachInk).fontWeight(.semibold); LogDot(); Text("\(runnerName) · \(model)")
        default:
            Text(StateStyle.of(job.state).label); LogDot(); Text("\(runnerName) · \(model)")
        }
    }

    private var foot: String {
        switch job.state {
        case .running: return "Nothing is written until you approve. Details show the tool and what it touched, never what it read or wrote."
        default: return "Kept with the batch: the steps and file names, never the text of your notes."
        }
    }
}

// MARK: - Collector log

/// A collector run's or package install's whole output (CollectorsLog board).
struct CollectorLogView: View {
    @ObservedObject var store: CollectorsStore
    let collector: Collector
    let target: CollectorLogTarget
    var startFollowing = true

    var body: some View {
        let back = store.page == .log(target, back: .allRuns) ? "All runs" : collector.name
        switch target {
        case .run(_, let runId):
            if let run = store.run(collector.id, runId) {
                runLog(run, back: back)
            } else {
                missing(back)
            }
        case .install(_, let installId):
            installLog(installId, back: back)
        }
    }

    private func missing(_ back: String) -> some View {
        LiveLogView(back: back, title: "Run", rows: [], empty: ("This run is no longer kept", "Runs are kept for 30 days (the newest 200)."),
                    copyText: { "" }, onBack: { store.closeLog() }) { EmptyView() } top: { EmptyView() }
            .onAppear { store.loadRuns(collector.id) }
    }

    private func runLog(_ run: CollectorRun, back: String) -> some View {
        let text = store.text
        let active = run.result == .running || run.result == .queued
        let command = collectorCommand(collector, text: text).map { "$ " + $0 }
        let chunks = store.orderedOutput(run)
        var rows: [LogRow] = []
        var sections: [(title: String, stderr: Bool, rows: [LogRow])] = []
        if let chunks {
            let lead = command.map { [CollectorOutputChunk(stream: "stdout", text: $0 + "\n", at: run.startedAt)] } ?? []
            rows = LiveLog.outputRows(lead + chunks)
        } else {
            let out = (command.map { $0 + "\n" } ?? "") + (run.stdoutTail ?? "")
            if !out.isEmpty { sections.append(("OUTPUT", false, LiveLog.outputRows([CollectorOutputChunk(stream: "stdout", text: out, at: run.startedAt)]).map { var r = $0; r.time = nil; return r })) }
            if let err = run.stderrTail, !err.isEmpty {
                sections.append(("STDERR", true, LiveLog.outputRows([CollectorOutputChunk(stream: "stderr", text: err, at: run.startedAt)]).map { var r = $0; r.time = nil; return r }))
            }
        }
        let how = run.isTest ? "Test run" : run.trigger == "now" ? "Run now" : "Run"
        let title = "\(how) · \(text.runTime(run.startedAt, previous: nil, now: store.now))"
        let copy = { () -> String in
            if let chunks { return LiveLog.copyOutput(chunks, title: "\(collector.name) · \(title)") }
            return ["\(collector.name) · \(title)", run.stdoutTail ?? "", (run.stderrTail ?? "").split(separator: "\n").map { "err  \($0)" }.joined(separator: "\n")].joined(separator: "\n")
        }
        let foot: String = chunks == nil
            ? "Saved before Distill kept the order of the lines: output first, then stderr. The last 64 KB of each."
            : run.isTest ? "Kept until the next test run." : "Kept with the run: the last 64 KB, in order."
        let reveal: (String, () -> Void)? = run.isTest ? run.outputDir.map { dir in ("Reveal in Finder", { store.reveal(run.filesAdded.first.map { (dir as NSString).appendingPathComponent($0) } ?? dir) }) } : nil
        return LiveLogView(back: back, title: title, rows: rows, dark: chunks != nil, foot: foot, footLink: reveal,
                           empty: rows.isEmpty && sections.isEmpty && !active ? ("No output", "The script printed nothing.") : nil,
                           sections: sections, startFollowing: startFollowing, copyText: copy, onBack: { store.closeLog() }) {
            if active {
                LiveMark(); LogDot(); Text(runSummary(run))
            } else {
                Text(result(run)).foregroundStyle(run.result == .failed || run.result == .timedout ? Theme.peachInk : Theme.limeInk).fontWeight(.semibold)
                LogDot(); Text(runSummary(run))
            }
            if let rt = run.runtime {
                LogDot(); Text(rt.line()).foregroundStyle(Theme.faint).truncationMode(.middle).help(rt.path)
            }
        } top: { EmptyView() }
        .onAppear { if run.stdoutTail == nil && run.outputLog.isEmpty && !active { store.loadRuns(collector.id) } }
    }

    private func result(_ r: CollectorRun) -> String {
        switch r.result {
        case .success, .nothing: return "Finished · exit 0"
        case .failed: return "Failed" + (r.exitCode.map { " · exit \($0)" } ?? "")
        case .timedout: return "Timed out"
        case .stopped: return "Stopped"
        default: return r.result.rawValue.capitalized
        }
    }

    private func runSummary(_ r: CollectorRun) -> String {
        let n = r.isTest ? r.filesAdded.count : max(r.counts.added, r.filesAdded.count)
        if r.isTest { return n == 0 ? "nothing in the test folder, nothing in the queue" : "\(CollectorText.files(n)) in the test folder, nothing in the queue" }
        if r.result == .running { return n == 0 ? "nothing added yet" : "\(CollectorText.files(n)) added so far" }
        return n == 0 ? "added nothing" : "added \(CollectorText.files(n))"
    }

    private func installLog(_ installId: String, back: String) -> some View {
        let install = store.installs[collector.id].flatMap { $0.id == installId ? $0 : nil } ?? collector.manifest?.lastInstall
        let raw = store.installOutput[installId] ?? install?.outputTail ?? ""
        let lead = install.map { $0.command.isEmpty ? "" : "$ \($0.command)\n" } ?? ""
        let at = install?.startedAt ?? Date()
        let body = raw.hasPrefix("$ ") ? raw : lead + raw
        let chunks = body.isEmpty ? [] : [CollectorOutputChunk(stream: "stdout", text: body, at: at)]
        let active = install?.result == "running" || collector.isInstalling
        let tool = collector.manifest?.name == "requirements.txt" ? "pip" : "npm"
        return LiveLogView(back: back, title: "Installing packages · \(tool)", rows: LiveLog.outputRows(chunks), dark: true,
                           foot: active ? "A run started now waits for this. Tokens in the output show as •••." : "The install’s last 64 KB of output.",
                           empty: chunks.isEmpty && !active ? ("No output", "This install printed nothing.") : nil, startFollowing: startFollowing,
                           copyText: { LiveLog.copyOutput(chunks, title: "\(collector.name) · package install") }, onBack: { store.closeLog() }) {
            if active { LiveMark(); LogDot(); Text("from \(collector.manifest?.name ?? "package.json")"); LogDot(); Text("stops after 10 min") }
            else { Text(install?.result == "success" ? "Installed" : "Couldn’t install").foregroundStyle(install?.result == "success" ? Theme.limeInk : Theme.peachInk).fontWeight(.semibold) }
            if let rt = install?.runtime {
                LogDot(); Text(rt.line()).foregroundStyle(Theme.faint).truncationMode(.middle).help(rt.path)
            }
        } top: { EmptyView() }
    }
}
