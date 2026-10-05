import AppKit
import SwiftUI
import DistillKit

/// What a Review or History job shows under its heading (canvas: Review): groups that fold, New pages
/// (open), Updated (folded; the summary names the pages), and Sources (each source with the page it made
/// and its labels; folded past 6 rows with the most used labels). The picking and label-edit state lives in
/// JobDetailView, per job.
struct ReviewGroupsView: View {
    @EnvironmentObject var engine: AppModel
    let job: Job
    let summary: ReviewSummary
    @Binding var unpicked: Set<String>
    @Binding var editingPage: String?
    @Binding var editDraft: [String]
    @Binding var labelError: String?
    /// Group open/folded overrides by title ("New pages", "Updated", "Sources").
    @Binding var overrides: [String: Bool]
    /// Snapshots: a source row drawn hovered.
    var hoverPage: String? = nil
    /// v8: the change is in the vault (Review after Approve): new pages show Open.
    var openable = false
    let open: (String) -> Void

    private var pending: Bool { job.state == .awaitingApproval }
    private var sources: [ReviewSource]? { job.approval?.sources }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            let newPages = sources == nil ? summary.sourcePages + summary.newPages : summary.newPages
            if !newPages.isEmpty {
                let open = isOpen("New pages", default: true)
                ReviewGroup {
                    ReviewGroupHeader(title: "New pages", count: newPages.count,
                                      summary: sources == nil && !summary.sourcePages.isEmpty
                                        ? [plural(summary.sourcePages.count, "source page"), summary.newPagesSummary].filter { !$0.isEmpty }.joined(separator: " · ")
                                        : summary.newPagesSummary,
                                      expanded: open, onToggle: { toggle("New pages", open) })
                    if open {
                        ForEach(newPages, id: \.self) { path in
                            ReviewChangeRow(title: ReviewSummary.pageName(path), change: .new, kind: ReviewSummary.kind(path),
                                            directory: ReviewSummary.directory(path), openable: openable, onOpen: { self.open(path) })
                        }
                    }
                }
            }
            if summary.updatedCount > 0 {
                let open = isOpen("Updated", default: false)
                ReviewGroup {
                    ReviewGroupHeader(title: "Updated", count: summary.updated.count, summary: summary.updatedSummary,
                                      expanded: open, onToggle: { toggle("Updated", open) })
                    if open {
                        ForEach(summary.updated, id: \.self) { path in
                            ReviewChangeRow(title: ReviewSummary.pageName(path), change: .updated,
                                            directory: ReviewSummary.directory(path), onOpen: { self.open(path) })
                        }
                        if !summary.bookkeeping.isEmpty {
                            Text("Plus \(plural(summary.bookkeeping.count, "bookkeeping file")): \(summary.bookkeeping.joined(separator: ", "))")
                                .font(Theme.body(11.5)).foregroundStyle(Theme.faint).lineLimit(2).truncationMode(.middle)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                        }
                    }
                }
            }
            if let sources, !sources.isEmpty { sourcesGroup(sources) }
        }
    }

    // MARK: Sources

    @ViewBuilder private func sourcesGroup(_ sources: [ReviewSource]) -> some View {
        let active = ReviewPicking.active(sources)
        let selectable = pending && active.count > 1 && job.approval?.rebuilt == nil
        let open = isOpen("Sources", default: active.count <= 6)
        let busy = job.approval?.labels?.state == .suggesting
        let known = knownLabels
        ReviewGroup {
            ReviewGroupHeader(title: "Sources", count: active.count, summary: sourcesSummary(sources, selectable: selectable),
                              expanded: open, busy: busy, action: sourcesAction(active, open: open, selectable: selectable),
                              onToggle: { toggle("Sources", open) },
                              onAction: {
                                  if !open { overrides["Sources"] = true }
                                  else if selectable { unpicked = ReviewPicking.allPicked(sources, unpicked: unpicked) ? Set(active.map(\.page)) : [] }
                                  else { overrides["Sources"] = false }
                              })
            if open {
                ForEach(sources) { source in sourceRow(source, selectable: selectable, known: known) }
            } else {
                let usage = LabelUsage.make(sources, known: known)
                if !usage.isEmpty { usageLine(usage).padding(.leading, 30).padding(.trailing, 10).padding(.bottom, 8) }
            }
        }
    }

    private func sourceRow(_ source: ReviewSource, selectable: Bool, known: Set<String>?) -> some View {
        let editing = editingPage == source.page
        let names = editing ? editDraft : source.labels
        let labels = names.map { name in LabelSuggestion(name: name, existing: known?.contains(name) ?? true) }
        let file = ((source.source ?? source.page) as NSString).lastPathComponent
        return ReviewSourceRow(
            title: source.title, file: file, labels: labels,
            labelState: editing ? .editing : LabelLineState(review: source),
            hover: hoverPage == source.page, selectable: selectable, selected: !unpicked.contains(source.page), removed: source.removed,
            onSelect: { on in if on { unpicked.remove(source.page) } else { unpicked.insert(source.page) } },
            onOpen: { open(source.page) },
            onRemove: pending ? { engine.removeReviewSource(job.id, page: source.page, removed: true) } : nil,
            onUndo: { engine.removeReviewSource(job.id, page: source.page, removed: false) },
            onEdit: pending ? { start in labelError = nil; editDraft = start; editingPage = source.page } : nil,
            onRemoveLabel: { name in editDraft.removeAll { $0 == name } },
            onAddLabel: { name in if !editDraft.contains(name) { editDraft.append(name) } },
            onDone: {
                let page = source.page, labels = editDraft
                editingPage = nil
                guard labels != source.labels else { return }
                engine.editReviewLabels(job.id, page: page, labels: labels) { error in labelError = error }
            },
            onCancel: { editingPage = nil })
    }

    private func sourcesSummary(_ sources: [ReviewSource], selectable: Bool) -> String {
        if let labels = job.approval?.labels, labels.state == .suggesting {
            var text = "Suggesting labels"
            if let done = labels.done, let total = labels.total { text += " · \(done) of \(total)" }
            return text + " · 3 at a time"
        }
        var tail: [String] = []
        if !selectable { tail.append("one page per note") }
        let active = ReviewPicking.active(sources)
        if active.contains(where: { $0.by == .ai && !$0.labels.isEmpty }) {
            tail.append("labels suggested" + (labelModel.map { " by \($0)" } ?? ""))
        } else if !active.isEmpty, active.allSatisfy({ $0.by == .user || $0.labels.isEmpty }), active.contains(where: { !$0.labels.isEmpty }) {
            tail.append("labels confirmed")
        }
        return ReviewPicking.sourcesSummary(sources, unpicked: unpicked, selectable: selectable, tail: tail.joined(separator: " · "))
    }

    private func sourcesAction(_ active: [ReviewSource], open: Bool, selectable: Bool) -> String? {
        if !open { return "Show all \(active.count)" }
        if selectable { return unpicked.isEmpty ? "Pick none" : "Pick all" }
        return active.count > 6 ? "Fold" : nil
    }

    private func usageLine(_ usage: LabelUsage) -> some View {
        var t = Text("Most used labels: ").foregroundColor(Theme.muted)
        for (i, item) in usage.top.enumerated() {
            if i > 0 { t = t + Text(" · ").foregroundColor(Theme.muted) }
            t = t + Text("#\(item.name)").fontWeight(.semibold).foregroundColor(Theme.limeInk) + Text(" \(item.count)").foregroundColor(Theme.muted)
        }
        if !usage.new.isEmpty {
            t = t + Text(usage.top.isEmpty ? "" : " · ").foregroundColor(Theme.muted) + Text("\(usage.new.count) new: ").foregroundColor(Theme.muted)
            for (i, name) in usage.new.enumerated() {
                if i > 0 { t = t + Text(", ").foregroundColor(Theme.muted) }
                t = t + Text("#\(name)").fontWeight(.semibold).foregroundColor(Theme.peachInk)
            }
        }
        return t.font(Theme.body(12)).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
    }

    // MARK: helpers

    /// The vault's labels (nil before they load: every label then counts as known, never guessed "new").
    private var knownLabels: Set<String>? {
        let counts = engine.notes.labelCounts
        return counts.isEmpty ? nil : Set(counts.map(\.name))
    }

    /// The Label suggestions model's short name ("Haiku"), when set.
    private var labelModel: String? {
        engine.settings.taskDefaults[AITask.labelSuggest.rawValue].map { ModelChoice.shortName($0.model) }.flatMap { $0.isEmpty ? nil : $0 }
    }

    private func isOpen(_ group: String, default value: Bool) -> Bool { overrides[group] ?? value }

    private func toggle(_ group: String, _ open: Bool) {
        withAnimation(.easeOut(duration: 0.15)) { overrides[group] = !open }
    }

    private func plural(_ n: Int, _ one: String) -> String { n == 1 ? "1 \(one)" : "\(n) \(one)s" }
}

/// A notice above the groups: an icon, a bold title and a line (rebuilt, rebuilding, label edit refused…).
struct ReviewNotice: View {
    enum Tone { case green, blue, peach, calm }
    let tone: Tone
    let title: String
    var text: String = ""
    var busy = false
    var systemImage = "checkmark.circle"

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Group {
                if busy { Spinner(color: ink, size: 12) } else { Image(systemName: systemImage).font(.system(size: 12, weight: .semibold)) }
            }
            .foregroundStyle(ink).frame(width: 14).padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Theme.body(13, .bold)).foregroundStyle(ink)
                if !text.isEmpty {
                    Text(text).font(Theme.body(12.5)).foregroundStyle(Color(hex: 0x48463F))
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(fill))
    }

    private var fill: Color {
        switch tone {
        case .green: return Color(hex: 0xF3FDE4)
        case .blue: return Color(hex: 0xF2F7FF)
        case .peach: return Color(hex: 0xFFF4EE)
        case .calm: return Theme.panel
        }
    }

    private var ink: Color {
        switch tone {
        case .green: return Theme.limeInk
        case .blue: return Theme.primary
        case .peach: return Theme.peachInk
        case .calm: return Theme.muted
        }
    }
}

/// History: "Applied in parts" with one line per part and the sources removed from the batch.
struct JobPartsList: View {
    let parts: [JobPart]
    var removed: [ReviewSource] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Applied in parts").font(Theme.body(13, .bold))
            ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.limeInk)
                    Text(ReviewBatches.partLine(part)).font(Theme.body(12)).foregroundStyle(Color(hex: 0x48463F))
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
            }
            if !removed.isEmpty {
                Text("\(removed.count) removed: \(removed.map(\.title).joined(separator: ", ")) (still in inbox/)")
                    .font(Theme.body(12)).foregroundStyle(Theme.muted).lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
