import AppKit
import SwiftUI
import DistillKit

/// Sidebar section Ask (canvas: "Ask", "Ask · answering"). Questions are
/// answered only from the active vault, with citations; filters narrow the
/// pages the runner may read.
struct AskScreen: View {
    @EnvironmentObject var engine: AppModel
    @EnvironmentObject var ask: AskModel

    var body: some View {
        AskThreadView(thread: ask.main)
    }
}

struct AskThreadView: View {
    @EnvironmentObject var engine: AppModel
    @EnvironmentObject var ask: AskModel
    @ObservedObject var thread: AskThread

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            AskFilterBar(thread: thread)
                .padding(.horizontal, 44).padding(.top, 16)
            conversation
            footer
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .bottom, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Ask your vault").font(Theme.display(30))
                Text("Answers come only from \(engine.activeVault?.name ?? "your vault"), with the pages they cite. Uses all notes unless you add labels or sources.")
                    .font(Theme.body(14)).foregroundStyle(Theme.muted)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            Button { ask.newChat(thread) } label: {
                Text("New chat").font(Theme.body(13, .semibold))
                    .padding(.horizontal, 14).frame(height: 34)
                    .background(Capsule().fill(Theme.panel))
            }
            .buttonStyle(.plain)
            .keyboardShortcut("n", modifiers: .command)
            .disabled(thread.isEmpty)
        }
        .padding(.horizontal, 44).padding(.top, 30)
    }

    // MARK: Conversation

    private var conversation: some View {
        ChatScrolling(followsEnd: !(thread.isEmpty && thread.pending == nil)) {
            VStack(alignment: .leading, spacing: 16) {
                if let note = thread.note { NoticeLine(text: note) }
                if thread.isEmpty { emptyState }
                ForEach(thread.entries) { entry in
                    QuestionBubble(text: entry.question)
                    AnswerBlock(entry: entry, saved: ask.savedEntries.contains(entry.id),
                                save: { ask.save(entry) }, copy: { ask.copy(entry) },
                                open: { ask.openCitation($0) })
                }
                if let pending = thread.pending {
                    QuestionBubble(text: pending.question)
                    if pending.status == .running {
                        VStack(alignment: .leading, spacing: 18) {
                            AskWorkingRow(title: workingTitle, detail: workingDetail, start: pending.startedAt) { ask.stop(thread) }
                            AnswerShimmer()
                        }
                        .frame(maxWidth: 760, alignment: .leading)
                    } else {
                        AskHaltRow(pending: pending) { ask.retry(thread) }
                            .frame(maxWidth: 760, alignment: .leading)
                    }
                }
                Color.clear.frame(height: 1).id("bottom")
            }
            .padding(.horizontal, 44).padding(.vertical, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ask anything your notes cover.").font(.system(size: 20, weight: .semibold, design: .rounded))
            Text("Claude reads only this vault and cites the pages it used. When the vault does not cover something, it says so.")
                .font(Theme.body(14)).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            let recent = ask.conversations.prefix(4)
            if !recent.isEmpty {
                Text("RECENT CHATS").font(Theme.body(11, .bold)).foregroundStyle(Theme.faint).kerning(0.6).padding(.top, 10)
                ForEach(Array(recent)) { c in
                    Button { ask.open(conversationID: c.id) } label: {
                        HStack(spacing: 8) {
                            Image(systemName: c.pinned ? "pin.fill" : "bubble.left").font(.system(size: 11)).foregroundStyle(Theme.muted)
                            Text(c.title).font(Theme.body(13)).foregroundStyle(Theme.softInk).lineLimit(1)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: 560, alignment: .leading)
        .padding(.top, 20)
    }

    private var workingTitle: String {
        if let id = thread.inFlightID, let p = engine.progress[CoreProgress.askKey(id)], !p.message.isEmpty { return p.message }
        return "Reading your notes…"
    }

    private var workingDetail: String {
        let s = thread.pending?.request.selection ?? ask.selection(for: thread)
        var parts = [ask.runner(for: s)?.displayName ?? "Claude Code", AskSelection.modelLabel(s, runners: ask.runners)]
        if let e = s.effort { parts.append(AskSelection.effortLabel(e)) }
        if let id = thread.inFlightID, let p = engine.progress[CoreProgress.askKey(id)], let total = p.total {
            parts.append("\(total) pages")
        } else if let count = AskFilter.pageCount(notices: thread.lastResponse?.notices ?? []), !thread.filter.isEmpty,
                  let n = count.split(separator: " ").first {
            parts.append("\(n) pages")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ModelChip(thread: thread)
                EffortPicker(thread: thread)
                Text("effort").font(Theme.body(11)).foregroundStyle(Theme.faint).padding(.trailing, 8)
                // Suggestions only take the room that is left: two, one, or none.
                // A fixed-width row wider than the window would stretch the whole
                // screen and clip the sidebar.
                ViewThatFits(in: .horizontal) {
                    suggestionRow(suggestions)
                    suggestionRow(Array(suggestions.prefix(1)))
                    Color.clear.frame(width: 0, height: 30)
                }
                Spacer(minLength: 0)
            }
            // Bottom-aligned so a taller field (more lines, or Aa's bar above it) keeps Aa and Send on its last line.
            HStack(alignment: .bottom, spacing: 10) {
                MarkdownBarAaButton(key: MarkdownBarKeys.ask, height: 26)
                    .padding(.bottom, 6)
                QuestionField(text: $thread.draft, placeholder: placeholder, disabled: thread.isRunning, bar: .ask) { ask.send(thread) }
                    .padding(.bottom, 5)
                Text("⌘↩").font(Theme.body(12)).foregroundStyle(Theme.faint).padding(.bottom, 11)
                SendButton(enabled: !thread.isRunning && !thread.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                    ask.send(thread)
                }
            }
            .padding(.leading, 12).padding(.trailing, 8).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 24).fill(thread.isRunning ? Color(hex: 0xFBFAF8) : Color.white)
                .shadow(color: .black.opacity(0.06), radius: 9, y: 6))
            .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(Theme.border, lineWidth: 1.5))
        }
        .padding(.horizontal, 44).padding(.bottom, 26).padding(.top, 4)
    }

    private func suggestionRow(_ items: [String]) -> some View {
        HStack(spacing: 8) {
            ForEach(items, id: \.self) { s in
                Button { thread.draft = s } label: {
                    Text(s).font(Theme.body(12, .semibold)).foregroundStyle(Theme.softInk).lineLimit(1).fixedSize()
                        .padding(.horizontal, 12).frame(height: 30)
                        .background(Capsule().fill(Theme.panel))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var placeholder: String {
        if thread.isRunning { return "You can ask a follow-up when this answer lands" }
        return thread.isEmpty ? "Ask a question…" : "Ask a follow-up…"
    }

    private var suggestions: [String] {
        thread.isEmpty ? ["What did I add this week?", "Where do my notes disagree?"] : ["What changed this week?", "Where do my notes disagree?"]
    }
}

/// One answer: header, text with markers, citation cards, gaps, notices, actions.
struct AnswerBlock: View {
    let entry: AskEntry
    var saved = false
    let save: () -> Void
    let copy: () -> Void
    let open: (AskCitation) -> Void
    @State private var copied = false

    var body: some View {
        let r = entry.response
        VStack(alignment: .leading, spacing: 14) {
            let info = AskFilter.infoNotices(r.notices)
            if !info.isEmpty {
                VStack(alignment: .leading, spacing: 4) { ForEach(info, id: \.self) { NoticeLine(text: $0) } }
            }
            HStack(spacing: 8) {
                Image(systemName: "sparkle").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.primary)
                    .frame(width: 26, height: 26).background(Circle().fill(Theme.primaryTint))
                Text("Claude").font(Theme.body(13, .bold))
                Text(meta).font(Theme.body(12)).foregroundStyle(Theme.faint)
            }
            AnswerText(answer: r.answer) { n in
                if let c = r.citations.first(where: { $0.n == n }) { open(c) }
            }
            if !r.citations.isEmpty {
                FlowLayout(spacing: 10) {
                    ForEach(Array(r.citations.enumerated()), id: \.offset) { i, c in
                        CitationCard(citation: c, index: i) { open(c) }
                    }
                }
            }
            ForEach(r.gaps, id: \.self) { GapCallout(text: $0) }
            HStack(spacing: 8) {
                Button(action: save) {
                    HStack(spacing: 6) {
                        Image(systemName: saved ? "checkmark" : "plus").font(.system(size: 11, weight: .bold))
                        Text(saved ? "Saved to the queue" : "Save answer to vault").font(Theme.body(13, .semibold))
                    }
                    .foregroundStyle(Theme.primary)
                    .padding(.horizontal, 14).frame(height: 34)
                    .background(Capsule().fill(Theme.primaryTint))
                }
                .buttonStyle(.plain)
                .disabled(saved)
                .help("Adds the answer as a note; it goes through Review like any other source.")
                Button { copy(); copied = true } label: {
                    Text(copied ? "Copied" : "Copy").font(Theme.body(13, .semibold))
                        .padding(.horizontal, 14).frame(height: 34)
                        .background(Capsule().fill(Theme.panel))
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: 760, alignment: .leading)
    }

    private var meta: String {
        let n = entry.response.citations.count
        var parts = [n == 0 ? "no pages cited" : (n == 1 ? "from 1 page" : "from \(n) pages")]
        if let d = entry.duration { parts.append(d < 60 ? "\(max(1, Int(d.rounded())))s" : ElapsedText.format(Int(d))) }
        return parts.joined(separator: " · ")
    }
}

/// Wraps children onto new lines (chips, citation cards).
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat? = nil

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.reduce(0) { $0 + $1.height } + CGFloat(max(0, rows.count - 1)) * (lineSpacing ?? spacing)
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for i in row.indices {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + (lineSpacing ?? spacing)
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for i in subviews.indices {
            let size = subviews[i].sizeThatFits(.unspecified)
            let extra = rows[rows.count - 1].indices.isEmpty ? size.width : size.width + spacing
            if rows[rows.count - 1].width + extra > width, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            let isFirst = rows[rows.count - 1].indices.isEmpty
            rows[rows.count - 1].indices.append(i)
            rows[rows.count - 1].width += isFirst ? size.width : size.width + spacing
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
        }
        return rows.filter { !$0.indices.isEmpty }
    }
}

/// The filter row: chips, + Label, Any | All, Include unconfirmed, + Limit by source, page count.
struct AskFilterBar: View {
    @EnvironmentObject var ask: AskModel
    @ObservedObject var thread: AskThread

    var body: some View {
        // Controls wrap onto a second line in a narrow window; the count stays at the end.
        HStack(alignment: .center, spacing: 8) {
            FlowLayout(spacing: 8) {
                Image(systemName: "line.3.horizontal.decrease").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.muted)
                    .frame(height: 28)
                if thread.filter.isEmpty {
                    Text("All notes").font(Theme.body(12, .semibold)).foregroundStyle(Theme.softInk).padding(.horizontal, 4)
                        .frame(height: 28).fixedSize()
                }
                ForEach(thread.filter.labels, id: \.self) { label in
                    FilterChip(text: "#\(label)") { thread.filter.removeLabel(label) }
                }
                LabelPickerButton(thread: thread)
                if thread.filter.showsMatchSwitch {
                    Segmented(options: [(LabelMatch.any, "Any label"), (.all, "All labels")], selection: $thread.filter.labelMatch,
                              help: [.any: "Notes with any of these labels", .all: "Only notes with all of these labels"])
                }
                if thread.filter.showsUnconfirmedToggle {
                    CapsuleSwitch(title: "Include unconfirmed", isOn: $thread.filter.includeUnconfirmed)
                        .help("Count AI labels you haven't confirmed yet")
                }
                ForEach(thread.filter.sources, id: \.self) { id in
                    FilterChip(text: AskFilter.sourceLabel(id, taxonomy: ask.taxonomy), fill: Theme.limeTint, ink: Theme.limeInk) {
                        thread.filter.removeSource(id)
                    }
                }
                SourcePickerButton(thread: thread)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // One line, as on the canvas: the whole line when it fits, else just the
            // page count, else the line cut short with "…".
            ViewThatFits(in: .horizontal) {
                countLine.fixedSize()
                if let pages = pageCount { Text(pages).fixedSize() }
                countLine.truncationMode(.tail)
            }
            .font(Theme.body(12)).foregroundStyle(Theme.muted)
            .lineLimit(1)
            .frame(maxWidth: 240, alignment: .trailing)
            .help(Text(countHelp))
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(minHeight: 48)
        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.panel))
    }

    /// "15 pages (3 unconfirmed)" once known, for the short form of the count line.
    private var pageCount: String? {
        thread.filter.isEmpty ? nil : AskFilter.pageCount(notices: thread.lastResponse?.notices ?? [])
    }

    /// The count line as plain text (tooltip when it is shortened).
    private var countHelp: String {
        if thread.filter.isEmpty { return thread.entries.isEmpty ? "" : "All notes" }
        let joiner = thread.filter.labelMatch == .all ? " and " : " or "
        var parts: [String] = []
        if !thread.filter.labels.isEmpty { parts.append(thread.filter.labels.map { "#\($0)" }.joined(separator: joiner)) }
        if !thread.filter.sources.isEmpty {
            parts.append(thread.filter.sources.map { AskFilter.sourceLabel($0, taxonomy: ask.taxonomy) }.joined(separator: " or "))
        }
        if let pageCount { parts.append(pageCount) }
        return parts.joined(separator: " · ")
    }

    private var countLine: Text {
        if thread.filter.isEmpty { return Text(thread.entries.isEmpty ? "" : "All notes") }
        let joiner = thread.filter.labelMatch == .all ? " and " : " or "
        var t = Text("")
        for (i, l) in thread.filter.labels.enumerated() {
            if i > 0 { t = t + Text(joiner).bold() }
            t = t + Text("#\(l)")
        }
        if !thread.filter.sources.isEmpty {
            if !thread.filter.labels.isEmpty { t = t + Text(" · ") }
            t = t + Text(thread.filter.sources.map { AskFilter.sourceLabel($0, taxonomy: ask.taxonomy) }.joined(separator: " or "))
        }
        if let count = AskFilter.pageCount(notices: thread.lastResponse?.notices ?? []) {
            t = t + Text(" · \(count)")
        }
        return t
    }
}
