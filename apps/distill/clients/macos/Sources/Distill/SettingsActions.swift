import AppKit
import SwiftUI
import DistillKit

// Settings → Actions (canvas: SettingsNav 4, 5, 6, 7, 10): where actions come
// from, the finding model, the action types, each type's own page, and To-do
// defaults. Everything edits `settings.actionPreferences`.

/// Tile colors and symbol for an action type.
enum ActionTypeStyle {
    static func of(_ id: String) -> (tint: Color, ink: Color, icon: String) {
        switch id {
        case "todo": return (Theme.primaryTint, Theme.primary, "checklist")
        case "slack": return (Theme.pinkTint, Theme.pinkInk, "number")
        case "jira": return (Theme.skyTint, Theme.skyInk, "ticket")
        case "confluence": return (Theme.limeTint, Theme.limeInk, "doc.richtext")
        case "email": return (Theme.peachTint, Theme.peachInk, "envelope")
        default: return (Theme.panel, Theme.muted, "bolt")
        }
    }
}

struct ActionTypeTile: View {
    let id: String
    var size: CGFloat = 32

    var body: some View {
        let style = ActionTypeStyle.of(id)
        Image(systemName: style.icon).font(.system(size: size * 0.42, weight: .semibold)).foregroundStyle(style.ink)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.29).fill(style.tint))
    }
}

/// "DEFAULT ON" / "Coming later" style small labels.
private struct CapsLabel: View {
    let text: String
    var body: some View {
        Text(text).font(Theme.body(11, .heavy)).foregroundStyle(Theme.faint).kerning(0.4)
    }
}

/// A gray (or outlined) status pill: "Always on", "Coming later", "On your click".
struct StatePill: View {
    let text: String
    var systemImage: String? = nil
    var outlined = false
    var fill: Color = Theme.panel
    var ink: Color = Theme.muted

    var body: some View {
        HStack(spacing: 5) {
            if let systemImage { Image(systemName: systemImage).font(.system(size: 9, weight: .bold)) }
            Text(text).font(Theme.body(11, .bold))
        }
        .padding(.horizontal, 9).frame(height: 22)
        .foregroundStyle(outlined ? Theme.faint : ink)
        .background(Capsule().fill(outlined ? Color.white : fill))
        .overlay(Capsule().strokeBorder(Theme.border, lineWidth: 1.5).opacity(outlined ? 1 : 0))
    }
}

// MARK: Actions section

struct ActionsSettings: View {
    @EnvironmentObject var engine: AppModel
    @ObservedObject var ui: SettingsStore
    @ObservedObject var notes: NotesStore

    private var detectable: [SettingsActionType] { ui.actionTypes.filter { !$0.reserved && $0.id != "todo" } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if ui.typesLoad == .unavailable {
                CoreUpdateNote(text: "Update the Distill core to use Actions. These settings are saved now and apply once it can find actions.")
            }
            VStack(alignment: .leading, spacing: 10) {
                CapsLabel(text: "WHERE ACTIONS COME FROM")
                ActionSourceCard(source: .notes, title: "Notes processed into the wiki", subtitle: "after a batch is applied", icon: "doc.text",
                                 confirmNote: "Found items wait in “To confirm”", types: detectable)
                ActionSourceCard(source: .ask, title: "Ask answers", subtitle: "main window and quick ask", icon: "bubble.left",
                                 confirmNote: "“Found in this answer” with Add and Dismiss", types: detectable)
            }
            SettingsRow(title: "Model for finding actions", note: "Also listed in Models for tasks", bold: true) {
                ModelPickers(task: .actionFind, name: "finding actions", notes: notes, selection: SettingsEdits.findSelection(engine.settings),
                             widths: (128, 100, 96), height: 30) { sel in
                    SettingsEdits.setActions(&engine.settings) { $0.findSelection = sel }
                }
            }
            .padding(.vertical, 4)
            CapsLabel(text: "ACTION TYPES")
            VStack(spacing: 0) {
                ForEach(Array(ui.actionTypes.enumerated()), id: \.element.id) { index, type in
                    if index > 0 { Divider().overlay(Theme.border) }
                    ActionTypeRow(ui: ui, type: type)
                }
            }
        }
    }
}

/// One source (notes or Ask answers) with its three switches.
struct ActionSourceCard: View {
    @EnvironmentObject var engine: AppModel
    let source: ActionPreferences.Source
    let title: String
    let subtitle: String
    let icon: String
    let confirmNote: String
    let types: [SettingsActionType]

    private var prefs: ActionPreferences { SettingsEdits.actions(engine.settings) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.muted)
                Text(title).font(Theme.body(13, .bold))
                Text(subtitle).font(Theme.body(11)).foregroundStyle(Theme.muted)
            }
            .padding(.bottom, 2)
            row("Detect to-dos", nil, on: prefs.detectTodos(source)) { v in SettingsEdits.setActions(&engine.settings) { $0.setDetectTodos(source, v) } }
            row("Detect \(typeNames) items", "Click a type to turn it off for this source", on: prefs.detectTypes(source), chips: true) { v in
                SettingsEdits.setActions(&engine.settings) { $0.setDetectTypes(source, v) }
            }
            row("Ask me to confirm before adding", confirmNote, on: prefs.confirm(source)) { v in
                SettingsEdits.setActions(&engine.settings) { $0.setConfirm(source, v) }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.border))
    }

    private var typeNames: String {
        let names = types.filter { SettingsEdits.typeEnabled($0, engine.settings) }.map(\.appName)
        return names.isEmpty ? "Slack, Jira, Confluence" : ListFormatter.localizedString(byJoining: names).replacingOccurrences(of: " and ", with: ", ")
    }

    private func row(_ title: String, _ note: String?, on: Bool, chips: Bool = false, set: @escaping (Bool) -> Void) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(Theme.body(12, .semibold))
                if let note { Text(note).font(Theme.body(11)).foregroundStyle(Theme.muted) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if chips {
                HStack(spacing: 4) {
                    ForEach(types.filter { SettingsEdits.typeEnabled($0, engine.settings) }) { t in
                        let detected = !prefs.disabledTypes(source).contains(t.id)
                        Button { SettingsEdits.setActions(&engine.settings) { $0.setType(t.id, detected: !detected, from: source) } } label: {
                            ActionTypeTile(id: t.id, size: 22).opacity(detected ? 1 : 0.3)
                        }
                        .buttonStyle(.plain)
                        .help(detected ? "Detecting \(t.pluralLabel.lowercased()) · click to stop" : "Not detecting \(t.pluralLabel.lowercased()) · click to detect")
                        .accessibilityLabel("\(t.label) from \(source == .notes ? "notes" : "Ask answers")")
                        .accessibilityValue(detected ? "on" : "off")
                    }
                }
                .disabled(!on)
                .opacity(on ? 1 : 0.4)
                .padding(.trailing, 4)
            }
            PillSwitch(isOn: Binding(get: { on }, set: set), label: title, width: 36, height: 22)
            Text("DEFAULT ON").font(Theme.body(10, .bold)).foregroundStyle(Theme.faint).lineLimit(1).fixedSize().frame(width: 70, alignment: .leading)
        }
        .padding(.vertical, 7)
    }
}

/// One line in ACTION TYPES; opens the type's page.
struct ActionTypeRow: View {
    @EnvironmentObject var engine: AppModel
    @ObservedObject var ui: SettingsStore
    let type: SettingsActionType

    var body: some View {
        let enabled = SettingsEdits.typeEnabled(type, engine.settings)
        HStack(spacing: 12) {
            ActionTypeTile(id: type.id)
            VStack(alignment: .leading, spacing: 2) {
                Text(type.label).font(Theme.body(14, .semibold))
                Text(subtitle).font(Theme.body(12)).foregroundStyle(Theme.muted).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(models).font(Theme.body(12)).foregroundStyle(Theme.muted).lineLimit(1)
                .frame(minWidth: 90, idealWidth: 190, maxWidth: 190, alignment: .leading)
            control(enabled)
            Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.faint)
                .opacity(type.reserved ? 0 : 1)
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .onTapGesture { open() }
        .opacity(type.reserved ? 0.5 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(type.reserved ? [] : .isButton)
    }

    @ViewBuilder private func control(_ enabled: Bool) -> some View {
        if type.id == "todo" {
            StatePill(text: "Always on")
        } else if type.reserved {
            StatePill(text: "Coming later", outlined: true)
        } else {
            PillSwitch(isOn: Binding(get: { enabled }, set: { v in SettingsEdits.setActions(&engine.settings) { $0.setTypeValue(type.id, "enabled", .bool(v)) } }),
                       label: "Use \(type.pluralLabel)", width: 36, height: 22)
        }
    }

    private func open() {
        if type.reserved { return }
        ui.select(type.id == "todo" ? SettingsTarget(.todo) : SettingsTarget(.actions, actionType: type.id))
    }

    private var subtitle: String {
        if type.id == "todo" { return "Catch-all for anything no other type can do" }
        if type.reserved { return "Coming later" }
        let when = SettingsEdits.draftWhen(type, engine.settings) == "onRequest" ? "only when I ask" : "when a note is processed"
        return "Write drafts: \(when)" + (type.createsOnClick ? " · create: on your click" : "")
    }

    private var models: String {
        if type.id == "todo" { return "Found with the note or answer" }
        if type.reserved { return "—" }
        let draft = ModelChoice.shortName(SettingsEdits.draftSelection(type.id, engine.settings).model)
        let improve = SettingsEdits.improveAfterEdit(type, engine.settings)
            ? ModelChoice.shortName(SettingsEdits.improveSelection(type.id, engine.settings).model) : "off"
        return "\(draft) · improve: \(improve)"
    }
}

// MARK: An action type's page

struct ActionTypeSettingsPage: View {
    @EnvironmentObject var engine: AppModel
    @ObservedObject var ui: SettingsStore
    let typeID: String
    /// Snapshots: open the reset confirmation for this prompt ("draft" / "improve").
    var confirmingReset: String? = nil

    var body: some View {
        let type = ui.type(typeID) ?? SettingsActionType(id: typeID, label: typeID.capitalized, pluralLabel: typeID.capitalized + "s")
        let enabled = SettingsEdits.typeEnabled(type, engine.settings)
        let thing = type.label
        VStack(alignment: .leading, spacing: 8) {
            Button { ui.select(SettingsTarget(.actions)) } label: {
                Text("‹ Actions").font(Theme.body(12, .semibold)).foregroundStyle(Theme.primary)
            }
            .buttonStyle(.plain)
            .padding(.bottom, 8)
            HStack(spacing: 12) {
                ActionTypeTile(id: type.id, size: 40)
                Text(type.label).font(Theme.display(26))
                Spacer()
                PillSwitch(isOn: Binding(get: { enabled }, set: { v in SettingsEdits.setActions(&engine.settings) { $0.setTypeValue(type.id, "enabled", .bool(v)) } }),
                           label: "Use \(type.pluralLabel)", width: 36, height: 22)
            }
            if !enabled {
                Text("Off: \(type.pluralLabel) have no list, and found items become to-dos.").font(Theme.body(12)).foregroundStyle(Theme.muted)
            }
            if ui.typesLoad == .unavailable {
                CoreUpdateNote(text: "Update the Distill core to use \(type.pluralLabel). These settings are saved now.")
            }
            Group {
                row(type.id == "slack" ? "Write the message" : "Write the draft",
                    type.id == "slack" ? "When off, Slack messages show a Create message button" : nil) {
                    SegmentedPills(options: [("onFind", "When a note is processed"), ("onRequest", "Only when I ask")],
                                   selection: Binding(get: { SettingsEdits.draftWhen(type, engine.settings) },
                                                      set: { v in SettingsEdits.setActions(&engine.settings) { $0.setTypeValue(type.id, "draftWhen", .string(v)) } }),
                                   height: 22)
                        .padding(3).overlay(Capsule().strokeBorder(Theme.border)).fixedSize()
                }
                if type.createsOnClick {
                    row("Create in \(type.appName)", "Always by your click on Create in \(type.appName). Never during note processing.") {
                        StatePill(text: "On your click", systemImage: "lock.fill").help("This can’t be changed")
                    }
                }
                ForEach(type.defaultFields, id: \.key) { field in
                    row(field.title, "New \(type.pluralLabel) start with this; a draft can pick another") {
                        FieldDefaultBox(placeholder: placeholder(field.key),
                                        value: SettingsEdits.actions(engine.settings).fieldDefault(type.id, field.key) ?? "") { v in
                            SettingsEdits.setActions(&engine.settings) { $0.setFieldDefault(type.id, field.key, v) }
                        }
                    }
                }
                row("Model for writing", nil) {
                    ModelPickers(task: .actionDraft, name: "writing \(type.pluralLabel)", notes: engine.notes,
                                 selection: SettingsEdits.draftSelection(type.id, engine.settings), widths: (128, 100, 96), height: 30) { sel in
                        SettingsEdits.setActions(&engine.settings) { $0.setTypeValue(type.id, "draftSelection", ActionPreferences.json(sel)) }
                    }
                }
                row("Improve after I edit", "Fixes grammar when you finish editing; you can always Undo") {
                    HStack(spacing: 6) {
                        PillSwitch(isOn: Binding(get: { SettingsEdits.improveAfterEdit(type, engine.settings) },
                                                 set: { v in SettingsEdits.setActions(&engine.settings) { $0.setTypeValue(type.id, "improveAfterEdit", .bool(v)) } }),
                                   label: "Improve after I edit", width: 36, height: 22)
                        ModelPickers(task: .actionImprove, name: "improving \(type.pluralLabel)", notes: engine.notes,
                                     selection: SettingsEdits.improveSelection(type.id, engine.settings), showsRunner: false,
                                     widths: (0, 100, 96), height: 30) { sel in
                            SettingsEdits.setActions(&engine.settings) { $0.setTypeValue(type.id, "improveSelection", ActionPreferences.json(sel)) }
                        }
                        .disabled(!SettingsEdits.improveAfterEdit(type, engine.settings))
                    }
                }
                if let later = type.laterHandler {
                    row(later.label, "Copy only for now") { StatePill(text: "Coming later", outlined: true) }
                }
            }
            .opacity(enabled ? 1 : 0.55)
            VStack(alignment: .leading, spacing: 22) {
                ActionPromptEditor(ui: ui, type: type, improve: false, title: "Create prompt",
                                   note: "Used to write a new \(thing) from a note", confirming: confirmingReset == "draft")
                ActionPromptEditor(ui: ui, type: type, improve: true, title: "Improve prompt",
                                   note: "Used after you edit a \(thing). Different from the create prompt.", confirming: confirmingReset == "improve")
            }
            .padding(.top, 10)
        }
    }

    private func placeholder(_ key: String) -> String {
        switch key {
        case "project": return "Project key, e.g. PX"
        case "issueType": return "Task"
        case "space": return "Space key, e.g. ENG"
        case "parent": return "Parent page title"
        default: return ""
        }
    }

    private func row<C: View>(_ title: String, _ note: String?, @ViewBuilder _ control: () -> C) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.body(13, .semibold))
                if let note { Text(note).font(Theme.body(12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control()
        }
        .padding(.vertical, 11)
    }
}

/// A one-line text box for a field default; saves on each change.
private struct FieldDefaultBox: View {
    let placeholder: String
    let value: String
    let set: (String) -> Void
    @State private var text: String

    init(placeholder: String, value: String, set: @escaping (String) -> Void) {
        self.placeholder = placeholder
        self.value = value
        self.set = set
        _text = State(initialValue: value)
    }

    var body: some View {
        TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(Theme.faint))
            .textFieldStyle(.plain).font(Theme.body(12, .semibold))
            .padding(.horizontal, 10).frame(width: 200, height: 30)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
            .onChange(of: text) { set(text) }
    }
}

/// A type's create or improve prompt in the shared Markdown editor, with
/// Default / Edited, Insert field and Reset to default (confirmed, undoable
/// until Settings closes).
struct ActionPromptEditor: View {
    @EnvironmentObject var engine: AppModel
    @ObservedObject var ui: SettingsStore
    let type: SettingsActionType
    let improve: Bool
    let title: String
    let note: String
    @State private var confirming: Bool

    init(ui: SettingsStore, type: SettingsActionType, improve: Bool, title: String, note: String, confirming: Bool = false) {
        self.ui = ui
        self.type = type
        self.improve = improve
        self.title = title
        self.note = note
        _confirming = State(initialValue: confirming)
    }

    private var undoKey: String { "\(type.id).\(improve ? "improve" : "draft")" }
    private var edited: Bool { SettingsEdits.promptEdited(type, improve: improve, engine.settings) }
    private var text: Binding<String> {
        Binding(get: { SettingsEdits.prompt(type, improve: improve, engine.settings) },
                set: { v in
                    // An editor echoing the same text back is not an edit (and keeps Undo reset).
                    guard v != SettingsEdits.prompt(type, improve: improve, engine.settings) else { return }
                    SettingsEdits.setPrompt(type, improve: improve, text: v, in: &engine.settings)
                    ui.promptUndo[undoKey] = nil
                })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(title).font(Theme.body(13, .semibold))
                if edited {
                    StatePill(text: "Edited", fill: Theme.peachTint, ink: Theme.peachInk).scaleEffect(0.92)
                } else {
                    StatePill(text: "Default").scaleEffect(0.92)
                }
                if let previous = ui.promptUndo[undoKey], !edited {
                    Button("Undo reset") {
                        SettingsEdits.setPrompt(type, improve: improve, text: previous, in: &engine.settings)
                        ui.promptUndo[undoKey] = nil
                    }
                    .buttonStyle(.plain).font(Theme.body(12, .semibold)).foregroundStyle(Theme.primary)
                }
                Spacer()
                insertField
                SoftButton(title: "Reset to default", tint: edited ? Theme.primary : Color(hex: 0xB5B1A9), fill: .clear,
                           size: .mini, systemImage: "arrow.counterclockwise") { confirming = true }
                    .disabled(!edited)
            }
            Text(note).font(Theme.body(12)).foregroundStyle(Theme.muted)
            MarkdownEditor(text: text, placeholder: "Write the prompt…", textSize: 12, minLines: 3)
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 12).fill(Theme.panel))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.peach, lineWidth: 1.5).opacity(edited ? 1 : 0))
        }
        .overlay(alignment: .topTrailing) {
            if confirming { confirmation.offset(y: 32) }
        }
        .zIndex(confirming ? 1 : 0)
    }

    private var insertField: some View {
        Menu {
            ForEach(type.placeholders, id: \.self) { field in
                Button(field) { insert(field) }
            }
        } label: {
            Text("Insert field ▾").font(Theme.body(12, .semibold)).foregroundStyle(Theme.muted)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .disabled(type.placeholders.isEmpty)
    }

    /// At the cursor when this prompt's editor has focus, otherwise at the end.
    private func insert(_ field: String) {
        let current = text.wrappedValue
        if let view = NSApp.keyWindow?.firstResponder as? NSTextView, view.string == current {
            view.insertText(field, replacementRange: view.selectedRange())
            return
        }
        text.wrappedValue = current + (current.hasSuffix(" ") || current.hasSuffix("\n") || current.isEmpty ? "" : " ") + field
    }

    private var confirmation: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Reset the \(improve ? "improve" : "create") prompt?").font(Theme.body(13, .bold))
            Text("Your version is replaced by the default. You can undo this until you close Settings.")
                .font(Theme.body(12)).foregroundStyle(Color(hex: 0x48463F)).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Spacer()
                SoftButton(title: "Cancel", size: .mini) { confirming = false }
                PrimaryButton(title: "Reset", size: .mini) {
                    let previous = text.wrappedValue
                    SettingsEdits.setPrompt(type, improve: improve, text: nil, in: &engine.settings)
                    ui.promptUndo[undoKey] = previous
                    confirming = false
                }
            }
        }
        .padding(14)
        .frame(width: 300)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white)
            .shadow(color: Theme.ink.opacity(0.2), radius: 16, y: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.ink.opacity(0.08)))
    }
}

// MARK: To-do defaults

struct TodoDefaultsSettings: View {
    @EnvironmentObject var engine: AppModel

    private var prefs: ActionPreferences { SettingsEdits.actions(engine.settings) }
    private let groups: [(String, String)] = [("due", "Due date"), ("note", "Note"), ("none", "None")]
    private let sorts: [(String, String)] = [("due", "Due date, soonest first"), ("created", "Date added, newest first"),
                                             ("priority", "Priority, highest first"), ("note", "Note")]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row("Group by", nil) {
                DropdownButton(title: title(groups, prefs.todoGroup), width: 160, height: 30) {
                    ForEach(groups, id: \.0) { g in Button(g.1) { SettingsEdits.setActions(&engine.settings) { $0.todoGroup = g.0 } } }
                }
                .accessibilityLabel("Group to-dos by")
            }
            row("Sort", "Inside each group") {
                DropdownButton(title: title(sorts, prefs.todoSort), width: 210, height: 30) {
                    ForEach(sorts, id: \.0) { s in Button(s.1) { SettingsEdits.setActions(&engine.settings) { $0.todoSort = s.0 } } }
                }
                .accessibilityLabel("Sort to-dos")
            }
            row("Keep action history", "Removed, completed, sent and done items") {
                SegmentedPills(options: retentionOptions,
                               selection: Binding(get: { prefs.historyDays },
                                                  set: { v in SettingsEdits.setActions(&engine.settings) { $0.historyDays = v } }),
                               height: 22)
                    .padding(3).overlay(Capsule().strokeBorder(Theme.border)).fixedSize()
            }
            row("Remind me of overdue to-dos", "One macOS notification each morning") {
                PillSwitch(isOn: Binding(get: { prefs.remindOverdue },
                                         set: { v in SettingsEdits.setActions(&engine.settings) { $0.remindOverdue = v } }),
                           label: "Remind me of overdue to-dos", width: 36, height: 22)
            }
        }
    }

    /// 30 days, 90 days, 1 year, Forever (0), plus the stored value when it is none of these.
    private var retentionOptions: [(Int, String)] {
        var options: [(Int, String)] = [(30, "30 days"), (90, "90 days"), (365, "1 year"), (0, "Forever")]
        let current = prefs.historyDays
        if !options.contains(where: { $0.0 == current }) {
            options.insert((current, "\(current) \(current == 1 ? "day" : "days")"), at: options.firstIndex { $0.0 > current || $0.0 == 0 } ?? 0)
        }
        return options
    }

    private func title(_ options: [(String, String)], _ id: String) -> String { options.first { $0.0 == id }?.1 ?? id }

    private func row<C: View>(_ title: String, _ note: String?, @ViewBuilder _ control: () -> C) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.body(13, .semibold))
                if let note { Text(note).font(Theme.body(12)).foregroundStyle(Theme.muted) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control()
        }
        .padding(.vertical, 11)
    }
}
