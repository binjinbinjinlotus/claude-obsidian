import AppKit
import Combine
import SwiftUI
import DistillKit

/// The quick ask window (canvas: "Quick actions from the floating flask"
/// panels 2 and 4, "Quick windows: size, growth and scrolling"). Opens
/// centered like Spotlight and grows with the answer; past the screen's limit
/// only the answer scrolls. × and Esc close the window but not the run: the
/// flask shows a green ring until the answer is seen, and clicking the flask
/// reopens the window.
@MainActor
final class QuickAskController {
    private let sizer: QuickWindowSizer
    private let engine: AppModel

    var isVisible: Bool { sizer.window.isVisible }

    init(engine: AppModel, onContinue: @escaping () -> Void) {
        self.engine = engine
        let panel = QuickWindow(width: QuickWindowGeometry.defaultWidth)
        sizer = QuickWindowSizer(window: panel, sizeKey: "distill.quickAsk.size")
        let ask = engine.ask
        panel.onCancel = { [weak panel, weak engine] in
            panel?.orderOut(nil)
            engine?.ask.quickVisible = false
        }
        sizer.setContent(QuickAskView(
            close: { [weak panel] in panel?.cancelOperation(nil) },
            continueInDistill: {
                ask.continueInMain()
                onContinue()
            },
            onDesiredHeight: { [weak sizer] h in sizer?.contentHeight(h) })
            .environmentObject(engine)
            .environmentObject(ask))
    }

    /// Opens on the screen of `anchor` (the flask's frame, from the hover menu) or of the pointer.
    func show(near anchor: NSRect?) {
        engine.ask.prepareQuickAsk()
        engine.ask.refresh()
        engine.ask.quickVisible = true
        if !sizer.window.isVisible {
            sizer.window.contentView?.layoutSubtreeIfNeeded()
            sizer.open(on: QuickWindowSizer.screen(near: anchor))
        }
        // A non-activating panel takes typing without bringing Distill's other windows forward.
        sizer.window.makeKeyAndOrderFront(nil)
    }

    func hide() { sizer.window.cancelOperation(nil) }
}

/// Hosting view whose first click acts (non-activating panels).
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct QuickAskView: View {
    @EnvironmentObject var engine: AppModel
    @EnvironmentObject var ask: AskModel
    var close: () -> Void = {}
    var continueInDistill: () -> Void = {}
    var onDesiredHeight: (CGFloat) -> Void = { _ in }

    var body: some View {
        QuickAskCard(thread: ask.quick, close: close, continueInDistill: continueInDistill, onDesiredHeight: onDesiredHeight)
    }
}

struct QuickAskCard: View {
    @EnvironmentObject var engine: AppModel
    @EnvironmentObject var ask: AskModel
    @ObservedObject var thread: AskThread
    var close: () -> Void
    var continueInDistill: () -> Void
    var onDesiredHeight: (CGFloat) -> Void = { _ in }
    /// Snapshots only (see QuickShell).
    var snapshotHeight: CGFloat? = nil
    /// Snapshots only: older fixtures (SnapshotAsk) frame the card at 400 pt.
    var snapshotWidth: CGFloat = 400

    var body: some View {
        QuickShell(title: "Quick ask", close: close, onDesiredHeight: onDesiredHeight, snapshotHeight: snapshotHeight,
                   snapshotWidth: snapshotWidth) {
            VStack(alignment: .leading, spacing: 12) {
                questionRow
                if !thread.isRunning { chips }
                if thread.filter.showsUnconfirmedToggle && !thread.isRunning { scopeBox }
            }
        } top: {
            VStack(alignment: .leading, spacing: 12) { content }
        } bottom: {
            EmptyView()
        } footer: {
            footer
        }
        .onExitCommand(perform: close)
    }

    // The field shows the last question while it runs or once answered.
    private var questionRow: some View {
        HStack(spacing: 10) {
            if thread.isRunning {
                Spinner(size: 14)
                Text(thread.pending?.question ?? "").font(Theme.body(14)).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Image(systemName: "bubble.left").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.primary)
                QuestionField(text: $thread.draft, placeholder: placeholder, size: 14) { ask.send(thread) }
                Text("↩").font(Theme.body(11)).foregroundStyle(Theme.faint)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.panel))
    }

    private var placeholder: String {
        if let last = thread.entries.last, thread.draft.isEmpty { return thread.entries.count == 1 ? last.question : "Ask a follow-up…" }
        return "Ask \(engine.activeVault?.name ?? "your vault")…"
    }

    private var chips: some View {
        FlowLayout(spacing: 6) {
            ModelChip(thread: thread, showRunner: false, showEffort: true, compact: true)
            if thread.filter.isEmpty {
                Text("All notes").font(Theme.body(11, .bold)).padding(.horizontal, 9).frame(height: 24)
                    .background(Capsule().fill(Theme.panel)).fixedSize()
            }
            ForEach(thread.filter.labels, id: \.self) { label in
                FilterChip(text: "#\(label)", height: 24) { thread.filter.removeLabel(label) }
            }
            ForEach(thread.filter.sources, id: \.self) { id in
                FilterChip(text: AskFilter.sourceLabel(id, taxonomy: ask.taxonomy), fill: Theme.limeTint, ink: Theme.limeInk, height: 24) {
                    thread.filter.removeSource(id)
                }
            }
            LimitMenuButton(thread: thread)
        }
    }

    /// Any/All and Include unconfirmed on one row (no wrapping), plus the page count.
    private var scopeBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if thread.filter.showsMatchSwitch {
                    Segmented(options: [(LabelMatch.any, "Any label"), (.all, "All labels")], selection: $thread.filter.labelMatch, height: 22)
                        .fixedSize()
                }
                CapsuleSwitch(title: "Include unconfirmed", isOn: $thread.filter.includeUnconfirmed, font: Theme.body(11, .semibold))
                    .fixedSize()
                Spacer(minLength: 0)
            }
            if let count = AskFilter.pageCount(notices: thread.lastResponse?.notices ?? []) {
                Text("Using \(count)").font(Theme.body(11)).foregroundStyle(Theme.muted)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.panel))
    }

    @ViewBuilder private var content: some View {
        if let pending = thread.pending {
            switch pending.status {
            case .running:
                VStack(alignment: .leading, spacing: 8) {
                    Shimmer(width: 300, height: 10)
                    Shimmer(width: 220, height: 10)
                }
                .padding(.vertical, 2)
            default:
                AskHaltRow(pending: pending) { ask.retry(thread) }
            }
        } else if let entry = thread.entries.last {
            let r = entry.response
            AnswerText(answer: Self.short(r.answer), size: 14) { n in
                if let c = r.citations.first(where: { $0.n == n }) { ask.openCitation(c) }
            }
            if !r.citations.isEmpty {
                FlowLayout(spacing: 8) {
                    ForEach(Array(r.citations.prefix(3).enumerated()), id: \.offset) { i, c in
                        CitationCard(citation: c, index: i, compact: true) { ask.openCitation(c) }
                    }
                }
            }
            if let gap = r.gaps.first { GapCallout(text: gap) }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            QuickMarkdownBarToggle()
            footerNote.font(Theme.body(11)).foregroundStyle(Theme.faint).lineLimit(1)
            Spacer(minLength: 8)
            if thread.isRunning {
                Button { ask.stop(thread) } label: {
                    Text("Stop").font(Theme.body(11, .semibold)).padding(.horizontal, 10).frame(height: 24)
                        .background(Capsule().fill(Theme.panel))
                }
                .buttonStyle(.plain)
            } else if !thread.isEmpty {
                Button("Continue in Distill", action: continueInDistill)
                    .buttonStyle(.plain).font(Theme.body(12, .semibold)).foregroundStyle(Theme.primary).underline()
            }
        }
        .padding(.top, 6)
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    private var footerNote: some View {
        let s = ask.selection(for: thread)
        let model = AskSelection.modelLabel(s, runners: ask.runners)
        if let pending = thread.pending, pending.status == .running {
            let effort = s.effort.map { " · " + AskSelection.effortLabel($0) } ?? ""
            return AnyView(HStack(spacing: 0) {
                Text("\(model)\(effort) · ")
                ElapsedClock(start: pending.startedAt)
                Text(" · Esc keeps it running")
            })
        }
        if !thread.filter.isEmpty { return AnyView(Text("Defaults from Settings · Esc to close")) }
        return AnyView(Text("\(engine.activeVault?.name ?? "Vault") · \(model) · Esc to close"))
    }

    /// The first paragraph, for the small window (the window grows to fit it, then the answer scrolls).
    static func short(_ answer: String) -> String {
        let first = answer.components(separatedBy: "\n\n").first ?? answer
        return first.count > 1600 ? String(first.prefix(1600)) + "…" : first
    }
}

/// "0:06" counting from `start` (shown from zero, unlike ElapsedText).
struct ElapsedClock: View {
    let start: Date
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(ElapsedText.format(max(0, Int(context.date.timeIntervalSince(start))))).monospacedDigit()
        }
    }
}
