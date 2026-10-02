import AppKit
import SwiftUI
import DistillKit

// Pieces shared by the Ask screen and the quick ask window (canvas: "Ask",
// "Ask · answering", "Quick actions from the floating flask"). Controls are
// plain SwiftUI shapes (no AppKit-backed Toggle/Picker/Menu in the visible
// part) so they match the boards and render in `--snapshot`.

extension Theme {
    static let bodyInk = Color(hex: 0x2A2925)
    static let softInk = Color(hex: 0x48463F)
    static let gapFill = Color(hex: 0xFFF4EE)
    static let stillFill = Color(hex: 0xFFF9E6)

    /// Number tiles on citation cards, by position.
    static let citationTints: [(Color, Color)] = [(limeTint, limeInk), (primaryTint, primary), (peachTint, peachInk), (pinkTint, pinkInk), (skyTint, skyInk)]
}

/// A removable chip (`#tea ×`, `Slack ×`).
struct FilterChip: View {
    let text: String
    var fill: Color = Theme.primaryTint
    var ink: Color = Theme.primary
    var height: CGFloat = 28
    var onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 4) {
            Text(text).font(Theme.body(12, .bold)).lineLimit(1).fixedSize()
            if let onRemove {
                Button(action: onRemove) {
                    Text("×").font(.system(size: 13, weight: .regular)).frame(width: 18, height: 18).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(text)")
            }
        }
        .foregroundStyle(ink)
        .padding(.leading, 11).padding(.trailing, onRemove == nil ? 11 : 5)
        .frame(height: height)
        .background(Capsule().fill(fill))
    }
}

/// Blue text button ("+ Label", "+ Limit by source").
struct LinkButton: View {
    let title: String
    var size: CGFloat = 12
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).font(Theme.body(size, .semibold)).foregroundStyle(Theme.primary)
                .lineLimit(1).fixedSize()
                .padding(.horizontal, 8).frame(height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// White pill group with one blue selected segment (Any/All, effort).
struct Segmented<Value: Hashable>: View {
    let options: [(Value, String)]
    @Binding var selection: Value
    var height: CGFloat = 24
    var help: [Value: String] = [:]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { value, label in
                let on = value == selection
                Button { selection = value } label: {
                    Text(label).font(Theme.body(12, .bold)).lineLimit(1).fixedSize()
                        .foregroundStyle(on ? Color.white : Theme.muted)
                        .padding(.horizontal, 10).frame(height: height)
                        .background(Capsule().fill(on ? Theme.primary : .clear))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(help[value] ?? "")
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.white))
        .overlay(Capsule().strokeBorder(Theme.border))
    }
}

/// The design's capsule switch (34×20, blue when on).
struct CapsuleSwitch: View {
    let title: String
    @Binding var isOn: Bool
    var font: Font = Theme.body(12, .semibold)

    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(spacing: 6) {
                ZStack(alignment: isOn ? .trailing : .leading) {
                    Capsule().fill(isOn ? Theme.primary : Color(hex: 0xD6D3CC)).frame(width: 34, height: 20)
                    Circle().fill(Color.white).frame(width: 16, height: 16).padding(.horizontal, 2)
                }
                Text(title).font(font).foregroundStyle(Theme.softInk).lineLimit(1).fixedSize()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "On" : "Off")
        .animation(.easeOut(duration: 0.12), value: isOn)
    }
}

/// A Menu in the app; just its label in snapshots (ImageRenderer draws menus blank).
struct SafeMenu<Label: View, Content: View>: View {
    @Environment(\.snapshotMode) private var snapshot
    @ViewBuilder var content: () -> Content
    @ViewBuilder var label: () -> Label

    var body: some View {
        if snapshot {
            label()
        } else {
            Menu(content: content, label: label)
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        }
    }
}

// MARK: Pickers

/// "+ Label": a popover with the vault's labels and a field for any other label.
struct LabelPickerButton: View {
    @EnvironmentObject var ask: AskModel
    @ObservedObject var thread: AskThread
    var title = "+ Label"
    @State private var open = false
    @State private var search = ""

    var body: some View {
        LinkButton(title: title) { open = true; Task { await ask.refreshLabels() } }
            .popover(isPresented: $open, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Label", text: $search)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { add(search) }
                    let matches = ask.labels.filter { search.isEmpty || $0.name.contains(AskFilter.normalize(search)) }
                        .filter { !thread.filter.labels.contains($0.name) }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(matches.prefix(60), id: \.name) { label in
                                Button { add(label.name) } label: {
                                    HStack {
                                        Text("#\(label.name)").font(Theme.body(13, .semibold))
                                        Spacer()
                                        Text(label.unconfirmed > 0 ? "\(label.count) · \(label.unconfirmed) unconfirmed" : "\(label.count)")
                                            .font(Theme.body(11)).foregroundStyle(Theme.muted)
                                    }
                                    .padding(.horizontal, 8).padding(.vertical, 5).contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                            if matches.isEmpty {
                                Text(search.isEmpty ? "No labels in this vault yet." : "Press Return to use #\(AskFilter.normalize(search)).")
                                    .font(Theme.body(12)).foregroundStyle(Theme.muted).padding(8)
                            }
                        }
                    }
                    .frame(maxHeight: 260)
                }
                .padding(12)
                .frame(width: 280)
            }
    }

    private func add(_ name: String) {
        thread.filter.addLabel(name)
        search = ""
        open = false
    }
}

/// "+ Limit by source": source groups (pick the whole group or one source).
struct SourcePickerButton: View {
    @EnvironmentObject var ask: AskModel
    @ObservedObject var thread: AskThread
    var title = "+ Limit by source"

    var body: some View {
        SafeMenu {
            ForEach(ask.taxonomy, id: \.id) { group in
                SwiftUI.Section(group.label) {
                    Button("All \(group.label.lowercased())") { thread.filter.addSource(group.id) }
                    ForEach(group.sources, id: \.id) { source in
                        Button(source.label) { thread.filter.addSource(source.id) }
                    }
                }
            }
        } label: {
            Text(title).font(Theme.body(12, .semibold)).foregroundStyle(Theme.primary)
                .lineLimit(1).fixedSize()
                .padding(.horizontal, 8).frame(height: 28).contentShape(Rectangle())
        }
    }
}

/// "+ Limit" in the quick window: one menu for labels and sources.
struct LimitMenuButton: View {
    @EnvironmentObject var ask: AskModel
    @ObservedObject var thread: AskThread

    var body: some View {
        SafeMenu {
            SwiftUI.Section("Labels") {
                ForEach(ask.labels.prefix(30).filter { !thread.filter.labels.contains($0.name) }, id: \.name) { label in
                    Button("#\(label.name)") { thread.filter.addLabel(label.name) }
                }
            }
            ForEach(ask.taxonomy, id: \.id) { group in
                SwiftUI.Section(group.label) {
                    Button("All \(group.label.lowercased())") { thread.filter.addSource(group.id) }
                    ForEach(group.sources, id: \.id) { source in
                        Button(source.label) { thread.filter.addSource(source.id) }
                    }
                }
            }
        } label: {
            Text("+ Limit").font(Theme.body(12, .semibold)).foregroundStyle(Theme.primary)
                .lineLimit(1).fixedSize()
                .padding(.horizontal, 6).frame(height: 26).contentShape(Rectangle())
        }
        .onAppear { Task { await ask.refreshLabels() } }
    }
}

/// Runner · model chip with a menu of the runners that can ask.
struct ModelChip: View {
    @EnvironmentObject var ask: AskModel
    @ObservedObject var thread: AskThread
    var showRunner = true
    var showEffort = false
    var compact = false

    var body: some View {
        let selection = ask.selection(for: thread)
        SafeMenu {
            ForEach(ask.askRunners) { runner in
                runnerSection(runner, selection: selection)
            }
            if ask.askRunners.isEmpty { Text("No runner can answer questions. Check Settings → AI runners.") }
        } label: {
            label(selection)
        }
    }

    @ViewBuilder
    private func runnerSection(_ runner: RunnerInfo, selection: ModelSelection) -> some View {
        let options: [ModelOption] = runner.models.isEmpty ? [ModelOption(id: runner.defaultModel, label: runner.defaultModel)] : runner.models
        SwiftUI.Section(runner.displayName) {
            ForEach(options, id: \.id) { option in
                Button {
                    pick(runner: runner, model: option.id, current: selection)
                } label: {
                    if option.id == selection.model && runner.id == selection.runnerID {
                        Label(option.label, systemImage: "checkmark")
                    } else {
                        Text(option.label)
                    }
                }
            }
            if showEffort, runner.id == selection.runnerID {
                ForEach(runner.effortLevels, id: \.self) { level in
                    Button("Effort: \(AskSelection.effortLabel(level))") {
                        var s = selection
                        s.effort = level
                        thread.selection = s
                    }
                }
            }
        }
    }

    private func pick(runner: RunnerInfo, model: String, current: ModelSelection) {
        let effort = current.effort.flatMap { runner.effortLevels.contains($0) ? $0 : nil }
        thread.selection = ModelSelection(runnerID: runner.id, model: model, effort: effort)
    }

    private func label(_ selection: ModelSelection) -> some View {
        let model = AskSelection.modelLabel(selection, runners: ask.runners)
        let runnerName = ask.runner(for: selection)?.displayName ?? (selection.runnerID == "claude-code" ? "Claude Code" : selection.runnerID)
        var text = showRunner ? "\(runnerName) · \(model)" : model
        if showEffort { text += " · \(AskSelection.effortLabel(selection.effort ?? defaultEffort(selection)))" }
        return HStack(spacing: 6) {
            if !compact {
                Image(systemName: "drop.fill").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.limeInk)
                    .frame(width: 20, height: 20).background(Circle().fill(Theme.limeTint))
            }
            Text(text).font(Theme.body(12, .bold)).foregroundStyle(Theme.ink).lineLimit(1).fixedSize()
            Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.muted)
        }
        .padding(.leading, compact ? 10 : 6).padding(.trailing, 10)
        .frame(height: compact ? 26 : 30)
        .background(Capsule().fill(compact ? Theme.panel : Color.white))
        .overlay(Capsule().strokeBorder(compact ? Color.clear : Theme.border))
        .contentShape(Capsule())
    }

    private func defaultEffort(_ s: ModelSelection) -> String {
        let levels = ask.runner(for: s)?.effortLevels ?? []
        return levels.contains("medium") ? "medium" : (levels.first ?? "medium")
    }
}

/// Effort segments for the selected runner (from its `effortLevels`).
struct EffortPicker: View {
    @EnvironmentObject var ask: AskModel
    @ObservedObject var thread: AskThread

    var body: some View {
        let levels = ask.effortLevels(for: thread)
        let current = ask.selection(for: thread).effort ?? (levels.contains("medium") ? "medium" : levels.first ?? "medium")
        Segmented(options: levels.map { ($0, AskSelection.effortLabel($0)) },
                  selection: Binding(get: { current }, set: { level in
                      var s = ask.selection(for: thread); s.effort = level; thread.selection = s
                  }), height: 26)
    }
}

// MARK: Conversation

/// The user's question, right-aligned in a lime bubble.
struct QuestionBubble: View {
    let text: String
    var size: CGFloat = 15

    var body: some View {
        HStack {
            Spacer(minLength: 80)
            Text(text).font(Theme.body(size)).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16).padding(.vertical, 12)
                .background(UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: 18, bottomTrailingRadius: 4, topTrailingRadius: 18)
                    .fill(Theme.limeTint))
                .frame(maxWidth: 520, alignment: .trailing)
                .textSelection(.enabled)
        }
    }
}

/// Answer text with `[n]` markers as small blue links to the citations.
struct AnswerText: View {
    let answer: String
    var size: CGFloat = 15
    let open: (Int) -> Void

    var body: some View {
        Text(Self.attributed(answer, size: size))
            .lineSpacing(size * 0.45)
            .foregroundStyle(Theme.bodyInk)
            .tint(Theme.primary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .environment(\.openURL, OpenURLAction { url in
                if url.scheme == "distill-cite", let n = Int(url.host ?? "") { open(n); return .handled }
                return .systemAction
            })
    }

    static func attributed(_ answer: String, size: CGFloat) -> AttributedString {
        var out = AttributedString()
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        for piece in AskAnswer.pieces(answer) {
            switch piece {
            case .text(let t):
                var a = (try? AttributedString(markdown: t, options: options)) ?? AttributedString(t)
                a.font = .system(size: size)
                out += a
            case .citation(let n):
                var a = AttributedString("\u{2009}\(n)\u{2009}")
                a.font = .system(size: size * 0.73, weight: .bold)
                a.foregroundColor = Theme.primary
                a.backgroundColor = Theme.primaryTint
                a.link = URL(string: "distill-cite://\(n)")
                out += AttributedString("\u{2009}") + a
            }
        }
        return out
    }
}

/// A citation card: number tile, page title, folder. Click opens it in Obsidian.
struct CitationCard: View {
    let citation: AskCitation
    let index: Int
    var compact = false
    let open: () -> Void

    var body: some View {
        let tint = Theme.citationTints[index % Theme.citationTints.count]
        Button(action: open) {
            HStack(spacing: compact ? 8 : 10) {
                Text("\(citation.n)").font(Theme.body(11, .bold)).foregroundStyle(tint.1)
                    .frame(width: compact ? 20 : 26, height: compact ? 20 : 26)
                    .background(RoundedRectangle(cornerRadius: compact ? 6 : 8).fill(tint.0))
                VStack(alignment: .leading, spacing: 1) {
                    Text(citation.title).font(Theme.body(13, .semibold)).foregroundStyle(Theme.ink).lineLimit(1)
                    if !compact {
                        Text(meta).font(Theme.body(11)).foregroundStyle(Theme.muted).lineLimit(1)
                    }
                }
            }
            .padding(.leading, compact ? 6 : 8).padding(.trailing, 12).padding(.vertical, compact ? 6 : 8)
            .background(RoundedRectangle(cornerRadius: compact ? 12 : 14).fill(compact ? Theme.panel : Color.white))
            .overlay(RoundedRectangle(cornerRadius: compact ? 12 : 14).strokeBorder(compact ? Color.clear : Theme.border))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open \(citation.path) in Obsidian")
    }

    private var meta: String {
        let dir = (citation.path as NSString).deletingLastPathComponent
        return dir.isEmpty ? citation.path : dir
    }
}

/// Peach "Gap:" callout.
struct GapCallout: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.peachInk)
            Text("Gap: \(text)").font(Theme.body(13)).foregroundStyle(Theme.softInk).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.gapFill))
    }
}

/// Small info line for a notice.
struct NoticeLine: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "info.circle").font(.system(size: 11)).foregroundStyle(Theme.faint)
            Text(text).font(Theme.body(12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The status row while an answer is coming: "Reading your notes…", then
/// "Still working · m:ss" after 60 s (the canvas' slow state).
struct AskWorkingRow: View {
    let title: String
    let detail: String
    let start: Date
    var compact = false
    let stop: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let seconds = Int(context.date.timeIntervalSince(start))
            if seconds >= 60 && !compact {
                HStack(spacing: 10) {
                    Text("⏳").font(.system(size: 15))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Still working · \(ElapsedText.format(seconds))").font(Theme.body(13, .bold))
                        Text("\(detail) · big questions can take a few minutes.").font(Theme.body(11)).foregroundStyle(Theme.muted)
                    }
                    Spacer(minLength: 8)
                    stopButton
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 14).fill(Theme.stillFill))
            } else {
                HStack(spacing: 10) {
                    Spinner(size: 16)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Theme.primaryTint))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(Theme.body(13, .bold)).foregroundStyle(Theme.ink)
                        Text(seconds >= 3 ? "\(detail) · \(ElapsedText.format(seconds))" : detail)
                            .font(Theme.body(12)).foregroundStyle(Theme.muted).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    stopButton
                }
            }
        }
    }

    private var stopButton: some View {
        Button(action: stop) {
            Text("Stop").font(Theme.body(12, .semibold)).foregroundStyle(Theme.ink)
                .padding(.horizontal, 12).frame(height: 30)
                .background(Capsule().fill(Theme.panel))
        }
        .buttonStyle(.plain)
        .keyboardShortcut(".", modifiers: .command)
    }
}

/// Shimmer where the answer and its citation cards will land.
struct AnswerShimmer: View {
    var cards = 2

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ShimmerParagraph(widths: [0.94, 0.88, 0.62])
            if cards > 0 {
                HStack(spacing: 10) {
                    Shimmer(width: 220, height: 42, radius: 14)
                    if cards > 1 { Shimmer(width: 180, height: 42, radius: 14) }
                }
            }
        }
    }
}

/// Stopped or failed: the question is kept, one way forward.
struct AskHaltRow: View {
    let pending: PendingQuestion
    let retry: () -> Void

    var body: some View {
        switch pending.status {
        case .running:
            EmptyView()
        case .stopped:
            row(icon: AnyView(Image(systemName: "stop.fill").font(.system(size: 8)).foregroundStyle(.white)
                    .frame(width: 20, height: 20).background(Circle().fill(Theme.muted))),
                title: "Stopped", detail: "Your question is kept.", fill: Theme.panel, button: "Ask again", primary: true)
        case .failed(let message):
            row(icon: AnyView(Image(systemName: "exclamationmark").font(.system(size: 10, weight: .heavy)).foregroundStyle(.white)
                    .frame(width: 20, height: 20).background(Circle().fill(Theme.peachInk))),
                title: "Couldn't get an answer", detail: "\(message) Your question is kept.", fill: Theme.gapFill, button: "Retry", primary: false)
        }
    }

    private func row(icon: AnyView, title: String, detail: String, fill: Color, button: String, primary: Bool) -> some View {
        HStack(spacing: 12) {
            icon
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.body(13, .bold))
                Text(detail).font(Theme.body(12)).foregroundStyle(Theme.muted).lineLimit(3).textSelection(.enabled)
            }
            Spacer(minLength: 8)
            Button(action: retry) {
                Text(button).font(Theme.body(12, .semibold))
                    .foregroundStyle(primary ? Color.white : Theme.ink)
                    .padding(.horizontal, 12).frame(height: 30)
                    .background(Capsule().fill(primary ? Theme.primary : Color.white))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 14).fill(fill))
    }
}

/// The question field: a TextField in the app, its placeholder in snapshots.
struct QuestionField: View {
    @Binding var text: String
    let placeholder: String
    var size: CGFloat = 15
    var disabled = false
    let submit: () -> Void
    @Environment(\.snapshotMode) private var snapshot
    @FocusState private var focused: Bool

    var body: some View {
        if snapshot {
            Text(text.isEmpty ? placeholder : text).font(Theme.body(size))
                .foregroundStyle(text.isEmpty ? Theme.faint : Theme.ink)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            TextField(placeholder, text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Theme.body(size))
                .lineLimit(1...5)
                .focused($focused)
                .disabled(disabled)
                .onSubmit(submit)
                .onAppear { focused = true }
        }
    }
}

/// Round send button.
struct SendButton: View {
    var enabled: Bool
    var size: CGFloat = 38
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.up").font(.system(size: size * 0.4, weight: .bold)).foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(Circle().fill(enabled ? Theme.primary : Color(hex: 0xD6D3CC)))
                .shadow(color: Theme.primary.opacity(enabled ? 0.3 : 0), radius: 6, y: 4)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .keyboardShortcut(.return, modifiers: .command)
        .accessibilityLabel("Send")
    }
}
