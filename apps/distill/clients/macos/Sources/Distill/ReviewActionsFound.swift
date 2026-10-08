import SwiftUI
import DistillKit

// Review's "Actions found" group (canvas row 12 ActionContext, frames C and D; spec action-context.md,
// "What the owner sees"). Information only: Approve never waits for it.

extension ActionsStore {
    /// Loads what a batch found (GET /v1/jobs/:id/actions). An older core has no route: nothing shows.
    func loadJobActions(_ jobID: String) {
        guard let client = engine?.client, !jobActionsUnavailable else { return }
        Task {
            do {
                let found = try await client.jobActions(jobID)
                jobActions[jobID] = found
            } catch let e as CoreClientError where e.isNotAvailable {
                jobActionsUnavailable = true
            } catch {
                // Information only: a failed load leaves the group as it was.
            }
        }
    }
}

struct ReviewActionsFound: View {
    @EnvironmentObject var engine: AppModel
    let job: Job
    /// Source pages not picked in Review (they aren't in what applies now).
    var unpicked: Set<String> = []
    @State private var open = true
    @State private var expanded: Set<String> = []

    private var store: ActionsStore { engine.actions }
    private var summary: JobActionsSummary? { store.jobActions[job.id]?.summary ?? job.actionsFound }
    private var found: JobActions? { store.jobActions[job.id] }
    private var confirm: Bool { SettingsEdits.actions(engine.settings).confirm(.notes) }

    /// Only for batches whose actions are found while they are read (v11).
    private var shows: Bool {
        guard let s = job.actionsFound ?? found?.summary else { return false }
        return s.foundInBatch && (job.state == .awaitingApproval || job.state == .completed)
    }

    var body: some View {
        Group {
            if shows { content }
        }
        .task(id: reloadKey) { if shows { store.loadJobActions(job.id) } }
    }

    private var reloadKey: String {
        "\(job.id)|\(job.state.rawValue)|\(job.actionsFound.map { "\($0.status)-\($0.found)-\($0.proposed ?? -1)-\($0.lines ?? -1)" } ?? "")"
    }

    /// Source pages that won't apply with this change: removed in Review, or not picked.
    private var leftOutPages: Set<String> {
        var out = unpicked
        for s in job.approval?.sources ?? [] where s.removed { out.insert(s.page) }
        return out
    }

    private func isLeftOut(_ p: JobActionProposal) -> Bool {
        if p.isLeftOut { return true }
        guard job.state == .awaitingApproval else { return false }
        if let page = p.page, leftOutPages.contains(page) { return true }
        return (job.approval?.sources ?? []).contains { $0.removed && $0.source == p.file }
    }

    @ViewBuilder private var content: some View {
        let shown = found?.shown ?? []
        let waiting = shown.filter { !isLeftOut($0) && $0.state == "waiting" }.count
        let added = shown.filter { $0.state == "added" }.count
        let status = summary?.status ?? "finding"
        ReviewGroup {
            ReviewGroupHeader(title: "Actions found", count: shown.count,
                              summary: status == "finding" ? "looking through the originals"
                                : ReviewActionsWords.headerSummary(waiting: waiting, added: added, confirm: confirm),
                              expanded: open, busy: status == "finding", onToggle: { open.toggle() })
            if open {
                VStack(alignment: .leading, spacing: 3) {
                    if status == "finding" { findingStrip }
                    if status == "failed" { failedCallout }
                    ForEach(shown) { p in
                        ActionConfirmRow(store: store, item: p.item, expanded: Binding(
                            get: { expanded.contains(p.id) },
                            set: { on in if on { expanded.insert(p.id) } else { expanded.remove(p.id) } }),
                            buttons: false, leftOut: isLeftOut(p) ? ReviewActionsWords.leftOut : nil)
                    }
                    if status != "finding" {
                        if shown.isEmpty && status != "failed" {
                            Text(summary?.linesOf.map { "No actions in these sources. Looked through \($0) lines." } ?? "No actions in these sources.")
                                .font(Theme.body(11.5)).foregroundStyle(Theme.muted).padding(.horizontal, 8).padding(.vertical, 6)
                        } else if !shown.isEmpty {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.limeInk)
                                Text(ReviewActionsWords.footer(summary, confirm: confirm, applied: job.state == .completed))
                                    .font(Theme.body(11.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(.horizontal, 8).padding(.top, 6)
                        }
                    }
                }
                .padding(.leading, 4).padding(.bottom, 4)
            }
        }
    }

    private var findingStrip: some View {
        let n = job.approval?.sources.map { ReviewPicking.active($0).count } ?? job.sources.count
        let p = engine.progress["actions:job:\(job.id)"]
        return HStack(spacing: 12) {
            Spinner(size: 15)
            VStack(alignment: .leading, spacing: 2) {
                Text(ReviewActionsWords.finding(summary, sources: n)).font(Theme.body(13, .bold))
                Text("\(ModelChoice.shortName(p?.model ?? summary?.model ?? "sonnet")) · every line of the originals, with each source’s new page as context. Approve doesn’t wait for it.")
                    .font(Theme.body(11.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.primaryTint))
    }

    private var failedCallout: some View {
        ActionCallout(title: "Couldn’t look through every line",
                      text: "\(summary?.error ?? "The action step failed.") Nothing is missed silently: this stays here until it runs.") {
            ActionButton(title: "Try again", icon: "arrow.clockwise", kind: .soft, height: 28) { store.findAgain(jobID: job.id) }
        }
    }
}
