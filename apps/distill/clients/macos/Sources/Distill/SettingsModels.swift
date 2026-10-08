import SwiftUI
import DistillKit

// Settings → AI → Models for tasks, and the runner / model / effort pickers
// shared with the Actions pages.

struct TaskDefaultsSettings: View {
    @EnvironmentObject var engine: AppModel
    @ObservedObject var notes: NotesStore

    /// Tasks with one model each. Action drafts are set per type (a link to Actions).
    private let tasks: [AITask] = [.ingest, .ask, .labelSuggest, .imageText, .actionFind, .recovery]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(tasks.enumerated()), id: \.element) { index, task in
                    if index > 0 { Divider().overlay(Theme.border) }
                    row(task)
                }
                Divider().overlay(Theme.border)
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Action drafts").font(Theme.body(13, .bold))
                        Text("Writing and improving are set per action type in Actions").font(Theme.body(11)).foregroundStyle(Theme.muted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Open Actions ›") { engine.settingsUI.show(SettingsTarget(.actions)) }
                        .buttonStyle(.plain).font(Theme.body(13, .semibold)).foregroundStyle(Theme.primary)
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
            }
            .background(RoundedRectangle(cornerRadius: 16).fill(Theme.panel))
            RecoverySettings()
            Text("Adding notes and Ask need a runner that can read files and respect permissions (Claude Code, Codex). Model APIs like OpenRouter show up only for label suggestions, text from images, actions and recovery.")
                .font(Theme.body(12)).foregroundStyle(Color(hex: 0x48463F))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12).padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color(hex: 0xFFF4EE)))
        }
    }

    /// Title beside the pickers when the page is wide enough; in a narrower
    /// window (under about 1000 pt) the pickers move under the title.
    private func row(_ task: AITask) -> some View {
        let (name, note) = SettingsEdits.taskTitle(task)
        let title = VStack(alignment: .leading, spacing: 2) {
            Text(name).font(Theme.body(13, .bold))
            Text(note).font(Theme.body(11)).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                title.frame(width: 190, alignment: .leading)
                pickers(task, name)
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 8) {
                title
                pickers(task, name)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsAnchor(name)
    }

    @ViewBuilder private func pickers(_ task: AITask, _ name: String) -> some View {
        if task == .actionFind {
            // The same stored value as Actions → Model for finding actions.
            ModelPickers(task: task, name: name, notes: notes, selection: SettingsEdits.findSelection(engine.settings)) { sel in
                SettingsEdits.setActions(&engine.settings) { $0.findSelection = sel }
            }
        } else {
            ModelPickers(task: task, name: name, notes: notes, selection: SettingsEdits.selection(task, settings: engine.settings)) { sel in
                engine.settings.taskDefaults[task.rawValue] = sel
            }
        }
    }
}

/// Runner, model and effort dropdowns for one model choice.
struct ModelPickers: View {
    @EnvironmentObject var engine: AppModel
    let task: AITask
    let name: String
    @ObservedObject var notes: NotesStore
    let selection: ModelSelection
    var showsRunner = true
    var widths: (CGFloat, CGFloat, CGFloat) = (180, 130, 104)
    var height: CGFloat = 32
    let set: (ModelSelection) -> Void

    var body: some View {
        let runner = notes.runners.first { $0.id == selection.runnerID }
        HStack(spacing: 6) {
            if showsRunner {
                DropdownButton(title: runner?.displayName ?? (selection.runnerID == "claude-code" ? "Claude Code" : selection.runnerID),
                               width: widths.0, height: height) {
                    ForEach(SettingsEdits.candidates(for: task, runners: notes.runners, settings: engine.settings, current: selection.runnerID)) { r in
                        Button(r.displayName) { set(SettingsEdits.withRunner(selection, r)) }
                    }
                }
                .accessibilityLabel("Runner for \(name)")
            }
            DropdownButton(title: SettingsEdits.modelTitle(selection.model, runner: runner), width: widths.1, height: height) {
                ForEach(runner?.models ?? [], id: \.id) { m in
                    Button(m.label) { var s = selection; s.model = m.id; set(s) }
                }
            }
            .accessibilityLabel("Model for \(name)")
            DropdownButton(title: SettingsEdits.effortTitle(selection.effort), width: widths.2, height: height) {
                Button("Default") { var s = selection; s.effort = nil; set(s) }
                ForEach(runner?.effortLevels ?? [], id: \.self) { e in
                    Button(SettingsEdits.effortTitle(e)) { var s = selection; s.effort = e; set(s) }
                }
            }
            .disabled(runner.map { $0.effortLevels.isEmpty } ?? false)
            .accessibilityLabel("Effort for \(name)")
        }
    }
}

/// review-queue.md: how far Distill goes on its own when a batch gets stuck (Settings → AI models → Recovery).
struct RecoverySettings: View {
    @EnvironmentObject var engine: AppModel

    private var prefs: RecoveryPreferences { engine.settings.recovery ?? RecoveryPreferences() }
    private func set(_ edit: (inout RecoveryPreferences) -> Void) {
        var p = prefs
        edit(&p)
        engine.settings.recovery = p
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Recover automatically").font(Theme.body(13, .bold))
                    Text("When a batch is stuck, Distill tries a fix with the Recovery model before it asks you").font(Theme.body(11)).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                PillSwitch(isOn: Binding(get: { prefs.resolvedAutomatic }, set: { v in set { $0.automatic = v } }),
                           label: "Recover automatically", width: 36, height: 22)
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            Divider().overlay(Theme.border)
            HStack(spacing: 10) {
                Text("Attempts per problem").font(Theme.body(13, .bold)).frame(maxWidth: .infinity, alignment: .leading)
                Stepper(value: Binding(get: { prefs.resolvedMaxAttempts }, set: { v in set { $0.maxAttempts = v } }), in: 1...5) {
                    Text("\(prefs.resolvedMaxAttempts)").font(Theme.body(13))
                }
                .fixedSize()
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            Divider().overlay(Theme.border)
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Cost limit per batch").font(Theme.body(13, .bold))
                    Text("Recovery stops here and asks you").font(Theme.body(11)).foregroundStyle(Theme.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Stepper(value: Binding(get: { prefs.resolvedMaxCostUSD }, set: { v in set { $0.maxCostUSD = (v * 4).rounded() / 4 } }), in: 0...10, step: 0.25) {
                    Text(String(format: "$%.2f", prefs.resolvedMaxCostUSD)).font(Theme.body(13))
                }
                .fixedSize()
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
        }
        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.panel))
        .settingsAnchor("Recover automatically")
    }
}
