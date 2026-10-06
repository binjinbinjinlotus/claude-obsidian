import SwiftUI
import DistillKit

// The action-button editor (action-buttons.md, "Buttons on action types"): one editor, opened from
// Settings → Actions → a type → Buttons and from an item's ＋ Button. It writes
// `actionPreferences.types[typeId].buttons` and previews the exact command through the core.

struct ButtonEditorSheet: View {
    @EnvironmentObject var engine: AppModel
    let target: ButtonEditorTarget
    var close: () -> Void
    @State private var draft: AutomationButton
    @State private var preview: ActionButtonPreview?
    @State private var previewError: String?
    @State private var previewTask: Task<Void, Never>?
    @State private var confirmDelete = false

    init(target: ButtonEditorTarget, close: @escaping () -> Void) {
        self.target = target
        self.close = close
        var b = target.button ?? AutomationButton()
        if target.button == nil, target.typeID == "slack" { b.onSuccess = .markSent }
        _draft = State(initialValue: b)
    }

    private var isNew: Bool { target.button == nil }
    private var scripts: [Collector] { engine.collectors.collectors.filter { $0.isScript && !($0.script?.commands.isEmpty ?? true) } }
    private var script: Collector? { scripts.first { $0.id == draft.scriptId } }
    private var command: ScriptCommand? { script?.script?.commands.first { $0.id == draft.commandId } }
    private var typeInfo: ActionTypeInfo? { engine.actions.type(target.typeID) }
    private var keys: [String] { AutomationText.templateKeys(fieldKeys: (typeInfo?.fields ?? []).map(\.key)) }
    private var canSave: Bool { !draft.label.trimmingCharacters(in: .whitespaces).isEmpty && script != nil && command != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isNew ? "New button" : "Edit button").font(Theme.body(17, .bold))
            if scripts.isEmpty {
                noCommands
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        basics
                        if let command { mapping(command) }
                        options
                        previewBlock
                    }
                    .padding(.trailing, 6)
                }
                .frame(maxHeight: 520)
            }
            footer
        }
        .padding(22)
        .frame(width: 600)
        .onAppear {
            if draft.scriptId.isEmpty, let first = scripts.first { draft.scriptId = first.id }
            if command == nil, let c = script?.script?.commands.first { pick(c) }
            schedulePreview()
        }
        .onChange(of: draft) { _, _ in schedulePreview() }
    }

    private var noCommands: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No automation offers commands yet.").font(Theme.body(13, .semibold))
            Text("Add a script in Automations, then add a command to it (for example `send` with a target and the text). Buttons run those commands.")
                .font(Theme.body(12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            LinkButton(title: "Open Automations") { close(); engine.activity.navigate = .collector(id: engine.collectors.current?.id ?? "", runs: false) }
        }
    }

    private var basics: some View {
        VStack(alignment: .leading, spacing: 10) {
            field("Label") { TextField("Send in Slack", text: $draft.label).textFieldStyle(.roundedBorder) }
            field("Runs") {
                HStack(spacing: 8) {
                    Picker("", selection: Binding(get: { draft.scriptId }, set: { id in
                        draft.scriptId = id
                        if let c = scripts.first(where: { $0.id == id })?.script?.commands.first { pick(c) }
                    })) {
                        ForEach(scripts) { s in Text(s.name).tag(s.id) }
                    }
                    .labelsHidden().frame(width: 200)
                    Text("›").foregroundStyle(Theme.faint)
                    Picker("", selection: Binding(get: { draft.commandId }, set: { id in
                        if let c = script?.script?.commands.first(where: { $0.id == id }) { pick(c) }
                    })) {
                        ForEach(script?.script?.commands ?? []) { c in Text(c.label).tag(c.id) }
                    }
                    .labelsHidden().frame(width: 200)
                }
            }
            if let script, script.needsConsent {
                Text("\(script.name) needs your OK in Automations before a button can run it.").font(Theme.body(11.5)).foregroundStyle(Theme.peachInk)
            }
        }
    }

    private func mapping(_ command: ScriptCommand) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("ARGUMENTS")
            if command.bindable.isEmpty {
                Text("This command takes no arguments.").font(Theme.body(12)).foregroundStyle(Theme.muted)
            }
            ForEach(command.bindable) { arg in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(arg.name).font(.system(size: 12, weight: .semibold, design: .monospaced))
                        Text(kindNote(arg)).font(Theme.body(11)).foregroundStyle(Theme.faint)
                        Spacer()
                        Menu {
                            ForEach(keys, id: \.self) { k in Button("{\(k)}") { insert(k, into: arg.name) } }
                        } label: { Text("Insert field ▾").font(Theme.body(11.5, .semibold)).foregroundStyle(Theme.muted) }
                            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                    }
                    TextField(arg.kind == .switch ? "true / false, or {a field}" : (arg.hint ?? "{a field} or text"),
                              text: Binding(get: { draft.bindings[arg.name] ?? "" }, set: { draft.bindings[arg.name] = $0 }))
                        .textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
                }
            }
        }
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("WHEN IT WORKS")
            Picker("", selection: $draft.onSuccess) {
                Text("Leave the item as it is").tag(AutomationButton.OnSuccess.none)
                Text("Mark it sent").tag(AutomationButton.OnSuccess.markSent)
                Text("Complete it").tag(AutomationButton.OnSuccess.complete)
            }
            .labelsHidden().pickerStyle(.radioGroup)
            Toggle("Save the key or link it prints on the item", isOn: $draft.storeResult).toggleStyle(.checkbox)
            Toggle("Ask before running (show the command first)", isOn: $draft.confirm).toggleStyle(.checkbox)
            field("Show it as") {
                Picker("", selection: $draft.slot) {
                    if target.typeID == "slack" { Text("The Send button").tag(AutomationButton.Slot.send) }
                    Text("A button").tag(AutomationButton.Slot.primary)
                    Text("In the ⋯ menu").tag(AutomationButton.Slot.more)
                }
                .labelsHidden().frame(width: 200)
            }
            Text("The first run, and the first run after any change, always shows the command.").font(Theme.body(11)).foregroundStyle(Theme.faint)
        }
    }

    @ViewBuilder private var previewBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(target.itemID == nil ? "PREVIEW (ON A SAMPLE ITEM)" : "PREVIEW (ON THE SELECTED ITEM)")
            if let p = preview {
                Text(p.display.isEmpty ? "—" : p.display).font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10).background(RoundedRectangle(cornerRadius: 9).fill(Theme.panel))
                ForEach(p.problems, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").font(Theme.body(12)).foregroundStyle(Theme.peachInk) }
            } else if let previewError {
                Text(previewError).font(Theme.body(12)).foregroundStyle(Theme.peachInk)
            } else {
                Text("Pick an automation and a command.").font(Theme.body(12)).foregroundStyle(Theme.faint)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if !isNew {
                if confirmDelete {
                    Text("Delete this button?").font(Theme.body(12))
                    ActionButton(title: "Delete", kind: .soft) { save(delete: true) }
                    ActionButton(title: "Keep", kind: .plain) { confirmDelete = false }
                } else {
                    Button("Delete button") { confirmDelete = true }.buttonStyle(.plain).font(Theme.body(12, .semibold)).foregroundStyle(Theme.peachInk)
                }
            }
            Spacer()
            ActionButton(title: "Cancel", kind: .plain) { close() }.keyboardShortcut(.cancelAction)
            ActionButton(title: isNew ? "Add button" : "Save", kind: .primary) { save(delete: false) }
                .disabled(!canSave).opacity(canSave ? 1 : 0.45)
                .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: Helpers

    private func field<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 12) {
            Text(title).font(Theme.body(12.5)).foregroundStyle(Theme.muted).frame(width: 80, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }

    private func kindNote(_ arg: ScriptCommandArg) -> String {
        switch arg.kind {
        case .flag: return "\(arg.flag ?? "") value" + (arg.isRequired ? "" : " · optional, left out when empty")
        case .switch: return "\(arg.flag ?? "") on or off"
        case .positional: return arg.isRequired ? "required" : "optional"
        case .word: return ""
        }
    }

    /// A new command: label from it when empty, and `{field}` guesses for arguments named like a field.
    private func pick(_ c: ScriptCommand) {
        draft.commandId = c.id
        if draft.label.isEmpty { draft.label = c.label }
        var bindings: [String: String] = [:]
        for arg in c.bindable {
            if let existing = draft.bindings[arg.name] { bindings[arg.name] = existing; continue }
            switch arg.name {
            case "text", "message", "body": bindings[arg.name] = "{body}"
            case "title", "summary": bindings[arg.name] = "{\(arg.name)}"
            case "target", "to", "channel", "recipient": bindings[arg.name] = keys.contains("fields.to") ? "{fields.to}" : ""
            default: bindings[arg.name] = keys.contains("fields.\(arg.name)") ? "{fields.\(arg.name)}" : ""
            }
        }
        draft.bindings = bindings
    }

    private func insert(_ key: String, into name: String) {
        draft.bindings[name] = (draft.bindings[name] ?? "") + "{\(key)}"
    }

    private func schedulePreview() {
        previewTask?.cancel()
        guard command != nil, let client = engine.client else { preview = nil; return }
        let button = draft, typeID = target.typeID, itemID = target.itemID
        previewTask = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            do {
                let p = try await client.previewButtonDraft(typeId: typeID, button: button, itemId: itemID)
                if !Task.isCancelled { preview = p; previewError = nil }
            } catch {
                if !Task.isCancelled { preview = nil; previewError = (error as? CustomStringConvertible)?.description ?? error.localizedDescription }
            }
        }
    }

    private func save(delete: Bool) {
        var b = draft
        b.label = b.label.trimmingCharacters(in: .whitespaces)
        let typeID = target.typeID
        SettingsEdits.setActions(&engine.settings) { prefs in
            var list = prefs.buttons(typeID)
            if delete {
                list.removeAll { $0.id == b.id }
            } else if let i = list.firstIndex(where: { $0.id == b.id }) {
                list[i] = b
            } else {
                if b.slot == .send { for i in list.indices where list[i].slot == .send { list[i].slot = .primary } }
                list.append(b)
            }
            prefs.setButtons(typeID, list)
        }
        // The type list carries the buttons' availability: read it again once the settings are saved.
        Task { try? await Task.sleep(nanoseconds: 900_000_000); engine.actions.load() }
        close()
    }
}

/// Settings → Actions → a type → Buttons: the type's buttons in order, with a switch, Edit and ＋ Add button.
struct ActionTypeButtonsSection: View {
    @EnvironmentObject var engine: AppModel
    let typeID: String
    let label: String
    @State private var editing: ButtonEditorTarget?

    private var buttons: [AutomationButton] { SettingsEdits.actions(engine.settings).buttons(typeID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Buttons").font(Theme.body(13, .semibold))
                    Text("Buttons on each \(label) that run an automation’s command.").font(Theme.body(12)).foregroundStyle(Theme.muted)
                }
                Spacer()
                SoftButton(title: "Add button", size: .small, stroke: true, systemImage: "plus") {
                    editing = ButtonEditorTarget(typeID: typeID, button: nil, itemID: nil)
                }
                .fixedSize()
            }
            ForEach(buttons) { b in
                let info = engine.actions.type(typeID)?.buttons.first { $0.id == b.id }
                HStack(spacing: 10) {
                    Image(systemName: b.icon ?? "play").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.primary).frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(b.label).font(Theme.body(12.5, .semibold))
                        Text([info?.scriptName, info?.commandLabel].compactMap { $0 }.joined(separator: " › ")
                             + (info.map { $0.available ? "" : " · " + ($0.reason ?? "can’t run") } ?? ""))
                            .font(Theme.body(11.5)).foregroundStyle(info?.available == false ? Theme.peachInk : Theme.muted).lineLimit(1)
                    }
                    Spacer()
                    LinkButton(title: "Edit") { editing = ButtonEditorTarget(typeID: typeID, button: b, itemID: nil) }
                    PillSwitch(isOn: Binding(get: { b.enabled }, set: { v in
                        SettingsEdits.setActions(&engine.settings) { p in
                            var list = p.buttons(typeID)
                            if let i = list.firstIndex(where: { $0.id == b.id }) { list[i].enabled = v; p.setButtons(typeID, list) }
                        }
                    }), label: "Show \(b.label)", width: 32, height: 20)
                }
                .padding(.vertical, 6)
                .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
            }
        }
        .padding(.vertical, 11)
        .settingsAnchor("Buttons")
        .sheet(item: $editing) { t in ButtonEditorSheet(target: t) { editing = nil }.environmentObject(engine) }
    }
}
