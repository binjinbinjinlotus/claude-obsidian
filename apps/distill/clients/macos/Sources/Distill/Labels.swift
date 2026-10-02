import AppKit
import SwiftUI
import DistillKit

/// Sidebar → Labels: "Labels to review" (canvas: "Labels to review" and its
/// loading board). Only labels not confirmed yet; browsing notes is Obsidian's
/// job. Confirming and AI-suggesting both become one change in Review.
struct LabelsSection: View {
    @EnvironmentObject var engine: AppModel

    var body: some View {
        LabelsScreen(notes: engine.notes)
    }
}

enum LabelsTab: Hashable { case toReview, unlabeled }

private struct LabelsScreen: View {
    @EnvironmentObject var engine: AppModel
    @ObservedObject var notes: NotesStore
    @AppStorage("distill.labelsTab") private var tabRaw = "toReview"
    @Environment(\.snapshotMode) private var snapshot

    private var tab: LabelsTab { tabRaw == "unlabeled" ? .unlabeled : .toReview }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Labels to review").font(Theme.display(30))
                Text("Only labels you haven't confirmed yet. To browse or edit notes, open them in Obsidian.")
                    .font(Theme.body(14)).foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, 44).padding(.top, 30)
            tabs.padding(.horizontal, 44).padding(.top, 18)
            if unlabeledCount > 0 || suggestJob != nil || notes.suggestJobID != nil {
                banner.padding(.horizontal, 44).padding(.top, 16)
            }
            list
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            engine.refreshLabels()
            if notes.runners.isEmpty { engine.loadRunners() }
        }
    }

    // MARK: Data

    private var review: LabelReview? { notes.review }
    private var unlabeledCount: Int { review?.unlabeled.count ?? 0 }

    private struct Row: Identifiable {
        let path: String
        let title: String
        let labels: [String]
        let origin: String?
        var id: String { path }
    }

    private var rows: [Row] {
        guard let review else { return [] }
        switch tab {
        case .toReview:
            return review.toReview.map { Row(path: $0.path, title: $0.title, labels: $0.labels, origin: $0.origin) }
        case .unlabeled:
            return review.unlabeled.map { Row(path: $0.path, title: $0.title, labels: [], origin: nil) }
        }
    }

    private func labels(_ row: Row) -> [String] { engine.reviewLabels(path: row.path, original: row.labels) }

    /// Rows that Confirm N will send: all checked rows of this tab (unlabeled
    /// rows only once the user gave them labels).
    private var selectedRows: [Row] {
        rows.filter { !notes.deselected.contains($0.path) && (tab == .toReview || !labels($0).isEmpty) }
    }

    /// A label nobody has confirmed yet in the vault.
    private func isNew(_ name: String) -> Bool {
        guard let count = notes.labelCounts.first(where: { $0.name == name }) else { return true }
        return count.count - count.unconfirmed <= 0
    }

    private var suggestJob: Job? {
        guard let id = notes.suggestJobID, id != "pending" else { return nil }
        return engine.job(id)
    }

    private var confirmJob: Job? {
        guard let id = notes.confirmJobID, id != "pending" else { return nil }
        return engine.job(id)
    }

    private var locked: Bool {
        notes.confirmJobID == "pending" || confirmJob?.state == .running
    }

    // MARK: Tabs

    private var tabs: some View {
        HStack(spacing: 8) {
            tabButton(.toReview, "To review", review?.toReview.count ?? 0)
            tabButton(.unlabeled, "Unlabeled", unlabeledCount)
            Spacer()
            if notes.reviewLoading && !snapshot { Spinner(color: Theme.muted, size: 14) }
        }
    }

    private func tabButton(_ t: LabelsTab, _ title: String, _ count: Int) -> some View {
        let on = tab == t
        return Button { tabRaw = t == .unlabeled ? "unlabeled" : "toReview" } label: {
            HStack(spacing: 7) {
                Text(title).font(Theme.body(13, .semibold))
                Text("\(count)").font(Theme.body(12, .bold)).opacity(0.8)
            }
            .padding(.horizontal, 13).frame(height: 32)
            .foregroundStyle(on ? Color.white : Color(hex: 0x48463F))
            .background(Capsule().fill(on ? Theme.primary : Theme.panel))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: Banner (suggest for unlabeled notes)

    @ViewBuilder private var banner: some View {
        HStack(spacing: 14) {
            if let progress = suggestProgress {
                VStack(alignment: .leading, spacing: 2) {
                    Text(progress.title).font(Theme.body(14, .bold))
                    HStack(spacing: 0) {
                        Text(progress.model)
                        ElapsedSuffix(start: progress.start)
                        Text(" · you can leave this screen. When all are done, one change goes to Review.")
                    }
                    .font(Theme.body(12)).foregroundStyle(Theme.muted).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let total = progress.total, total > 0 {
                    ProgressBar(done: progress.done ?? 0, total: total).frame(width: 160)
                } else {
                    Spinner(color: Theme.peachInk, size: 16)
                }
                SmallButton(title: "Stop", fill: .white, height: 34) { engine.stopSuggesting() }
                    .disabled(notes.suggestJobID == "pending")
            } else if let job = suggestJob, job.state == .failed {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Couldn't suggest labels").font(Theme.body(14, .bold))
                    Text("\(job.error ?? "The run stopped.") Your notes were not changed.")
                        .font(Theme.body(12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                SmallButton(title: "OK", fill: .white, height: 34) { notes.suggestJobID = nil }
            } else if let job = suggestJob, job.state == .awaitingApproval {
                VStack(alignment: .leading, spacing: 2) {
                    Text("AI labels are ready in Review").font(Theme.body(14, .bold))
                    Text("Approve the change there; the notes then show up here under To review.")
                        .font(Theme.body(12)).foregroundStyle(Theme.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                SmallButton(title: "OK", fill: .white, height: 34) { notes.suggestJobID = nil }
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(unlabeledCount) \(unlabeledCount == 1 ? "note has" : "notes have") no labels").font(Theme.body(14, .bold))
                    Text("AI labels them the same way as files dropped in the queue folder, reusing your labels first. They then show up here under To review.")
                        .font(Theme.body(12)).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                modelPicker
                Button { suggest() } label: {
                    Text("Suggest labels for \(unlabeledCount) \(unlabeledCount == 1 ? "note" : "notes")")
                        .font(Theme.body(13, .bold)).padding(.horizontal, 16).frame(height: 34)
                        .foregroundStyle(.white).background(Capsule().fill(Theme.peachInk))
                }
                .buttonStyle(.plain)
                .disabled(unlabeledCount == 0)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: 18).fill(Color(hex: 0xFFF4EE)))
    }

    private struct SuggestStatus { let title: String; let model: String; let start: Date; let done: Int?; let total: Int? }

    /// From live progress (key = job id) or, without it, the running job.
    private var suggestProgress: SuggestStatus? {
        let model = SettingsEdits.modelTitle((notes.suggestSelection ?? SettingsEdits.selection(.labelSuggest, settings: engine.settings)).model,
                                             runner: nil)
        if notes.suggestJobID == "pending" {
            return SuggestStatus(title: "Suggesting labels…", model: model, start: Date(), done: nil, total: notes.suggestTotal)
        }
        if let id = notes.suggestJobID, let p = LabelsProgress.progress(engine, key: id), !p.finished {
            return status(p, model: model)
        }
        guard let job = suggestJob ?? engine.runningJobs.first(where: { $0.kind == "labels" && notes.confirmJobID != $0.id }),
              job.state == .running else { return nil }
        if let p = LabelsProgress.progress(engine, key: job.id), !p.finished { return status(p, model: model) }
        let total = notes.suggestTotal > 0 ? notes.suggestTotal : job.files.count
        return SuggestStatus(title: total > 0 ? "Suggesting labels for \(total) notes" : "Suggesting labels…",
                             model: model, start: job.createdAt, done: nil, total: nil)
    }

    private func status(_ p: LabelsProgress, model: String) -> SuggestStatus {
        let title = p.total.map { "Suggesting labels · \(p.done ?? 0) of \($0)" } ?? p.message
        return SuggestStatus(title: title, model: p.model.map { SettingsEdits.modelTitle($0, runner: nil) } ?? model,
                             start: p.startedAt, done: p.done, total: p.total)
    }

    /// Runners that can suggest labels, with their models.
    private var modelPicker: some View {
        let current = notes.suggestSelection ?? SettingsEdits.selection(.labelSuggest, settings: engine.settings)
        let runners = SettingsEdits.candidates(for: .labelSuggest, runners: notes.runners, settings: engine.settings)
        let runner = notes.runners.first { $0.id == current.runnerID }
        return DropdownButton(title: SettingsEdits.modelTitle(current.model, runner: runner), height: 30, radius: 15,
                              font: Theme.body(12, .bold)) {
            ForEach(runners) { r in
                SwiftUI.Section(r.displayName) {
                    ForEach(r.models, id: \.id) { m in
                        Button(m.label) { notes.suggestSelection = ModelSelection(runnerID: r.id, model: m.id, effort: current.effort) }
                    }
                }
            }
        }
        .fixedSize()
        .accessibilityLabel("Model for label suggestions")
    }

    private func suggest() {
        let paths = review?.unlabeled.map(\.path) ?? []
        engine.suggestLabels(paths: paths, selection: notes.suggestSelection)
    }

    // MARK: List

    @ViewBuilder private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                checkbox(allSelected) { selectAll(!allSelected) }
                Text("NOTE").frame(width: 250, alignment: .leading)
                Text("LABELED BY").frame(width: 110, alignment: .leading)
                Text("LABELS").frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(Theme.body(11, .bold)).tracking(0.5).foregroundStyle(Theme.faint)
            .padding(.horizontal, 12).padding(.vertical, 8)
            Scrolling {
                VStack(spacing: 2) {
                    if review == nil {
                        if let error = notes.reviewError {
                            Text(error).font(Theme.body(13)).foregroundStyle(Theme.peachInk).padding(.vertical, 20)
                        } else {
                            ForEach(0..<5, id: \.self) { _ in shimmerRow }
                        }
                    } else if rows.isEmpty {
                        Text(tab == .toReview ? "Nothing to review. AI labels you haven't confirmed show up here."
                                              : "Every note has labels.")
                            .font(Theme.body(13)).foregroundStyle(Theme.faint)
                            .frame(maxWidth: .infinity).padding(.vertical, 24)
                    } else {
                        ForEach(rows) { row($0) }
                    }
                }
            }
        }
        .padding(.horizontal, 44).padding(.top, 10)
        .frame(maxHeight: .infinity, alignment: .top)
        .disabled(locked)
    }

    private var shimmerRow: some View {
        HStack(spacing: 14) {
            Shimmer(width: 14, height: 14, radius: 4)
            Shimmer(width: 220, height: 14)
            Shimmer(width: 80, height: 12).padding(.leading, 80)
            Shimmer(width: 90, height: 24, radius: 12)
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 16)
    }

    private func row(_ row: Row) -> some View {
        let checked = !notes.deselected.contains(row.path)
        let current = labels(row)
        return HStack(spacing: 14) {
            checkbox(checked) {
                if checked { notes.deselected.insert(row.path) } else { notes.deselected.remove(row.path) }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title).font(Theme.body(14, .semibold)).lineLimit(1).truncationMode(.tail)
                Button { engine.openInObsidian(row.path) } label: {
                    Text("Open in Obsidian ↗").font(Theme.body(11)).foregroundStyle(Theme.primary)
                }
                .buttonStyle(.plain)
            }
            .frame(width: 250, alignment: .leading)
            Text(originTitle(row.origin)).font(Theme.body(12)).foregroundStyle(Theme.muted)
                .frame(width: 110, alignment: .leading)
            FlowRow(spacing: 6) {
                ForEach(current, id: \.self) { name in
                    let edited = !row.labels.contains(name)
                    LabelChip(name: name, style: edited ? .plain : isNew(name) ? .suggestedNew : .suggestedExisting,
                              height: 28, onRemove: {
                                  engine.editReviewLabels(path: row.path, original: row.labels) { $0.removeAll { $0 == name } }
                              })
                }
                RowLabelAdder { raw in
                    let names = LabelName.parseList(raw)
                    guard !names.isEmpty else { return false }
                    engine.editReviewLabels(path: row.path, original: row.labels) { $0 += names }
                    return true
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            SmallButton(title: "Confirm", fill: Theme.primaryTint, ink: Theme.primary, weight: .bold) {
                engine.confirmLabels([LabeledPage(path: row.path, labels: current)])
            }
            .disabled(tab == .unlabeled && current.isEmpty)
            .opacity(tab == .unlabeled && current.isEmpty ? 0.4 : 1)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 14).fill(checked && (tab == .toReview || !current.isEmpty) ? Theme.panel : .clear))
    }

    private func originTitle(_ origin: String?) -> String {
        switch origin {
        case "queue-folder": return "Queue folder"
        case "cli": return "CLI · no reply"
        case "suggest": return "Suggest button"
        case nil: return tab == .unlabeled ? "—" : "AI"
        case let other?: return other
        }
    }

    private var allSelected: Bool { !rows.isEmpty && rows.allSatisfy { !notes.deselected.contains($0.path) } }

    private func selectAll(_ on: Bool) {
        for r in rows { if on { notes.deselected.remove(r.path) } else { notes.deselected.insert(r.path) } }
    }

    private func checkbox(_ on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 4)
                .fill(on ? Theme.primary : Color.white)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(on ? Theme.primary : Color(hex: 0xC9C6BF)))
                .overlay { if on { Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy)).foregroundStyle(.white) } }
                .frame(width: 14, height: 14)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Footer

    private var footer: some View {
        let selected = selectedRows
        return HStack(spacing: 10) {
            Text("\(selected.count) selected").font(Theme.body(13, .semibold))
            Text(footerNote).font(Theme.body(12)).foregroundStyle(Theme.muted)
                .frame(maxWidth: .infinity, alignment: .trailing)
            if locked {
                HStack(spacing: 8) {
                    Spinner(color: .white, size: 14)
                    Text("Preparing the change…").font(Theme.body(14, .semibold))
                }
                .padding(.horizontal, 20).frame(height: 40)
                .foregroundStyle(.white)
                .background(Capsule().fill(Theme.primary.opacity(0.85)))
            } else {
                PrimaryButton(title: "Confirm \(selected.count) \(selected.count == 1 ? "note" : "notes")") {
                    engine.confirmLabels(selected.map { LabeledPage(path: $0.path, labels: labels($0)) })
                }
                .disabled(selected.isEmpty)
                .opacity(selected.isEmpty ? 0.5 : 1)
            }
        }
        .padding(.horizontal, 44).padding(.vertical, 16)
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    private var footerNote: String {
        if locked { return "Building the change for Review · rows lock until it is ready" }
        if let job = confirmJob, job.state == .awaitingApproval { return "Sent to Review: approve it there to write the labels" }
        return "Confirming writes the labels through Review, like any other vault change"
    }
}

/// The "+" at the end of a row's chips; turns into a small field.
private struct RowLabelAdder: View {
    let onAdd: (String) -> Bool
    @State private var editing = false

    var body: some View {
        if editing {
            AddLabelField(placeholder: "label", width: 90, height: 28) { raw in
                let ok = onAdd(raw)
                if ok { editing = false }
                return ok
            }
        } else {
            Button { editing = true } label: {
                Text("+").font(Theme.body(16)).foregroundStyle(Theme.primary).frame(width: 28, height: 28).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add label")
        }
    }
}
