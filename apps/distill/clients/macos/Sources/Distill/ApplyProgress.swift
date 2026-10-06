import DistillKit
import SwiftUI

/// Review after Approve (canvas: ApplyProgress, ReviewProgress): the steps until every approved file is
/// in the knowledge base, in the live log's marks. Built from `ApplyTimeline` (the batch's job.step events).
struct ApplyProgress: View {
    /// approved | starting | applying | applied | finding | done
    var stage: ApplyTimeline.Stage
    var failedAt: ApplyTimeline.Stage? = nil
    var core = false
    var folded = false
    var runner = "Claude"
    var vault = ""
    var sources = ""
    var changes = ""
    var added = ""
    var operation = ""
    var actions = ""
    var error = ""
    var help = ""
    var heading = ""
    var part = ""
    var times: [Date?] = []
    var onShowSteps: () -> Void = {}

    init(stage: ApplyTimeline.Stage, failedAt: ApplyTimeline.Stage? = nil, core: Bool = false, folded: Bool = false, runner: String = "Claude",
         vault: String = "", sources: String = "", changes: String = "", added: String = "", operation: String = "", actions: String = "",
         error: String = "", help: String = "", heading: String = "", part: String = "", times: [Date?] = [], onShowSteps: @escaping () -> Void = {}) {
        self.stage = stage; self.failedAt = failedAt; self.core = core; self.folded = folded; self.runner = runner; self.vault = vault
        self.sources = sources; self.changes = changes; self.added = added; self.operation = operation; self.actions = actions
        self.error = error; self.help = help; self.heading = heading; self.part = part; self.times = times; self.onShowSteps = onShowSteps
    }

    init(_ t: ApplyTimeline, folded: Bool = false, part: String = "", onShowSteps: @escaping () -> Void = {}) {
        self.init(stage: t.stage, failedAt: t.failedAt, core: t.core, folded: folded, runner: t.runner, vault: t.vault, sources: t.sources,
                  changes: t.changes, added: t.added, operation: t.operation, actions: t.actions, error: t.error, help: t.help,
                  heading: t.updating ? t.heading : "", part: part, times: t.times, onShowSteps: onShowSteps)
    }

    private var timeline: ApplyTimeline {
        ApplyTimeline(stage: stage, failedAt: failedAt, core: core, runner: runner, vault: vault, sources: sources, changes: changes,
                      added: added, operation: operation, actions: actions, error: error, help: help, times: times)
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        let t = timeline
        let rows = t.rows
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                Text(heading.isEmpty ? t.heading : heading)
                    .font(Theme.body(14, .bold))
                    .foregroundStyle(t.isFailed ? Theme.peachInk : t.isAdded ? Theme.limeInk : Theme.ink)
                    .lineLimit(1)
                let summary = folded ? ([part, "All \(rows.count) steps done", t.stage == .done || t.failedAt == .finding ? t.actions : ""]
                    .filter { !$0.isEmpty }.joined(separator: " · ")) : part
                if !summary.isEmpty {
                    Text(summary).font(Theme.body(12)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: 0)
                LinkButton(title: "Show steps", action: onShowSteps).fixedSize()
            }
            .padding(.horizontal, 8).padding(.bottom, 6)
            if !folded {
                ForEach(Array(rows.enumerated()), id: \.offset) { i, r in
                    let time = r.state == "waiting" ? "" : (i < times.count ? times[i].map { Self.clock.string(from: $0) } ?? "" : "")
                    LogLine(kind: "step", state: r.state, text: r.text, time: time, count: r.count)
                }
                if !t.help.isEmpty, t.isFailed {
                    Text(t.help).font(Theme.body(12)).foregroundStyle(Color(hex: 0x48463F))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 36).padding(.trailing, 8).padding(.vertical, 4)
                }
            }
        }
        .padding(.horizontal, 10).padding(.top, 12).padding(.bottom, folded ? 6 : 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(t.isFailed ? Color(hex: 0xFFF8F4) : Color(hex: 0xFBFAF8)))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(t.isFailed ? Color(hex: 0xFFE4D6) : Theme.border, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(heading.isEmpty ? t.heading : heading)
    }
}

/// The card on Review (and History) for the latest approval: live from the batch's steps. Shown while it is added,
/// once it is (folded), and when adding it failed (the job may be back in Review with Approve).
struct ApplyProgressCard: View {
    @ObservedObject var store: JobStepsStore
    let job: Job
    let onShowSteps: () -> Void

    var body: some View {
        Group {
            if ApplyTimeline.approvalIsLatest(job), !ApplyTimeline.planReplaced(job),
               let t = ApplyTimeline.make(job: job, steps: store.steps[job.id] ?? []),
               job.state != .awaitingApproval || t.isFailed {
                ApplyProgress(t, folded: t.stage == .done && !t.isFailed && job.state == .completed, part: partLabel, onShowSteps: onShowSteps)
            }
        }
        .onAppear { if job.approvedChange != nil { store.load(job.id) } }
        .onChange(of: job.id) { if job.approvedChange != nil { store.load(job.id) } }
    }

    /// "Part 2 · 8 sources" when this approval was part of a batch.
    private var partLabel: String {
        guard let change = job.approvedChange else { return "" }
        let parts = job.parts ?? []
        let mine = parts.firstIndex { $0.operationID == change.operationID }
        let isPart = mine != nil ? (parts.count > 1 || job.state != .completed) : job.approval?.rebuilt != nil
        guard isPart else { return "" }
        let n = (mine ?? parts.count) + 1
        let k = change.sourcesApproved.map { $0 == 1 ? " · 1 source" : " · \($0) sources" } ?? ""
        return "Part \(n)\(k)"
    }
}
