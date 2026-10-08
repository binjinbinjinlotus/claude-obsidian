import SwiftUI
import DistillKit

// Automations (action-buttons.md, "Commands: how a script offers them"): a script's Collect switch and
// its commands, declared here by the owner; buttons on action types run them.

extension CollectorsStore {
    func saveCommands(_ c: Collector, collects: Bool? = nil, commands: [ScriptCommand]? = nil, then: (() -> Void)? = nil) {
        perform(c.id, "commands") { [weak self] client in
            let updated = try await client.updateScriptCommands(c.id, collects: collects, commands: commands)
            self?.upsert(updated)
            then?()
        }
    }
}

/// On a script's detail: "Collect on a schedule" and the COMMANDS list (argument chips, Used by, Edit, ＋ Add command).
struct ScriptCommandsBlock: View {
    @EnvironmentObject var engine: AppModel
    @ObservedObject var store: CollectorsStore
    let collector: Collector
    @State private var editing: CommandEditTarget?

    private var commands: [ScriptCommand] { collector.script?.commands ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionLabel("COMMANDS")
                Spacer()
                LinkButton(title: "Add command") { editing = CommandEditTarget(command: nil) }
            }
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Collect on a schedule").font(Theme.body(12.5))
                    Text(collector.script?.collects ?? true ? "Runs on its schedule and fills the queue." : "Off: it only runs from buttons.")
                        .font(Theme.body(11.5)).foregroundStyle(Theme.muted)
                }
                Spacer()
                PillSwitch(isOn: Binding(get: { collector.script?.collects ?? true }, set: { store.saveCommands(collector, collects: $0) }),
                           label: "Collect on a schedule", width: 32, height: 20)
            }
            .padding(.vertical, 6)
            if commands.isEmpty {
                Text("No commands. Add one (for example `send` with a target and the text) and action buttons can run it.")
                    .font(Theme.body(12)).foregroundStyle(Theme.faint).fixedSize(horizontal: false, vertical: true).padding(.vertical, 4)
            }
            ForEach(commands) { cmd in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(cmd.label).font(Theme.body(13, .semibold))
                        Text(cmd.id).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.faint)
                        Spacer()
                        LinkButton(title: "Edit") { editing = CommandEditTarget(command: cmd) }
                    }
                    Text(ScriptCommandText.chips(cmd)).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.softInk).lineLimit(2)
                    let used = usedBy(cmd)
                    Text(used.isEmpty ? "Not used by a button yet" : "Used by " + used.joined(separator: ", "))
                        .font(Theme.body(11.5)).foregroundStyle(Theme.muted)
                }
                .padding(.vertical, 7)
                .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
            }
        }
        .sheet(item: $editing) { t in
            CommandEditorSheet(command: t.command, taken: Set(commands.map(\.id)).subtracting([t.command?.id ?? ""])) { result in
                var list = commands
                switch result {
                case .save(let c):
                    if let old = t.command, let i = list.firstIndex(where: { $0.id == old.id }) { list[i] = c } else { list.append(c) }
                case .delete:
                    list.removeAll { $0.id == t.command?.id }
                case .cancel:
                    editing = nil
                    return
                }
                store.saveCommands(collector, commands: list)
                editing = nil
            }
        }
    }

    /// "Slack › Send in Slack" for each button bound to this command.
    private func usedBy(_ cmd: ScriptCommand) -> [String] {
        let prefs = SettingsEdits.actions(engine.settings)
        return engine.actions.types.flatMap { t in
            prefs.buttons(t.id).filter { $0.scriptId == collector.id && $0.commandId == cmd.id }.map { "\(t.label) › \($0.label)" }
        }
    }
}

struct CommandEditTarget: Identifiable {
    var command: ScriptCommand?
    var id: String { command?.id ?? "new" }
}

enum ScriptCommandText {
    /// `send --thread <thread> -- <target> <text>`: the argv shape, words as typed, values in brackets.
    static func chips(_ c: ScriptCommand) -> String {
        var head: [String] = [], tail: [String] = []
        for a in c.args {
            switch a.kind {
            case .word: head.append(a.value ?? a.name)
            case .flag: head.append("\(a.flag ?? "--?") <\(a.name)>" + (a.isRequired ? "" : "?"))
            case .switch: head.append("[\(a.flag ?? "--?")]")
            case .positional: tail.append("<\(a.name)>" + (a.isRequired ? "" : "?"))
            }
        }
        if !tail.isEmpty && c.endOptions != false { head.append("--") }
        return (head + tail).joined(separator: " ")
    }
}

/// The command editor: label and id, the arguments in argv order (kind, name, flag or word, required,
/// pattern and hint), the `--` rule, the timeout and how to read the result.
struct CommandEditorSheet: View {
    enum Result { case save(ScriptCommand), delete, cancel }
    let original: ScriptCommand?
    let taken: Set<String>
    var done: (Result) -> Void
    @State private var c: ScriptCommand
    @State private var confirmDelete = false

    init(command: ScriptCommand?, taken: Set<String>, done: @escaping (Result) -> Void) {
        original = command
        self.taken = taken
        self.done = done
        _c = State(initialValue: command ?? ScriptCommand(id: "", label: "", args: [ScriptCommandArg(name: "text", kind: .positional)]))
    }

    private var problems: [String] {
        var out: [String] = []
        if c.label.trimmingCharacters(in: .whitespaces).isEmpty { out.append("Give it a name.") }
        let names = c.args.map(\.name)
        if Set(names).count != names.count { out.append("Two arguments share a name.") }
        for a in c.args {
            if a.name.trimmingCharacters(in: .whitespaces).isEmpty { out.append("Every argument needs a name.") }
            if a.kind == .word && (a.value ?? "").isEmpty { out.append("“\(a.name)”: a word needs its text.") }
            if (a.kind == .flag || a.kind == .switch), !(a.flag ?? "").hasPrefix("-") { out.append("“\(a.name)”: the flag looks like --thread.") }
            if let p = a.pattern, !p.isEmpty, (try? NSRegularExpression(pattern: p)) == nil { out.append("“\(a.name)”: the pattern isn’t valid.") }
        }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(original == nil ? "New command" : "Edit command").font(Theme.body(17, .bold))
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    row("Name") { TextField("Send a message", text: $c.label).textFieldStyle(.roundedBorder) }
                    row("Shows as") {
                        Text(ScriptCommandText.chips(c)).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.softInk)
                    }
                    SectionLabel("ARGUMENTS, IN ORDER")
                    ForEach(c.args.indices, id: \.self) { i in argRow(i) }
                    HStack(spacing: 8) {
                        ForEach([("Word", ScriptCommandArg.Kind.word), ("Flag", .flag), ("Switch", .switch), ("Value", .positional)], id: \.0) { title, kind in
                            SoftButton(title: title, size: .mini, stroke: true, systemImage: "plus") { add(kind) }.fixedSize()
                        }
                    }
                    Text("Word: fixed text (send). Flag: --thread and a value. Switch: --dry-run when on. Value: a plain argument after “--”.")
                        .font(Theme.body(11)).foregroundStyle(Theme.faint).fixedSize(horizontal: false, vertical: true)
                    Toggle("Put “--” before the values, so a value starting with “-” is never read as a flag", isOn: Binding(
                        get: { c.endOptions != false }, set: { c.endOptions = $0 ? nil : false })).toggleStyle(.checkbox).font(Theme.body(12))
                    row("Timeout") {
                        Stepper(value: Binding(get: { c.timeoutSeconds ?? 60 }, set: { c.timeoutSeconds = $0 }), in: 5...3600, step: 5) {
                            Text("\(c.timeoutSeconds ?? 60) s").font(Theme.body(12.5))
                        }
                    }
                    SectionLabel("READ THE RESULT")
                    Toggle("The last JSON line it prints ({\"key\", \"url\", \"message\"})", isOn: Binding(
                        get: { c.result?.json ?? false }, set: { v in var r = c.result ?? ScriptResultParse(); r.json = v ? true : nil; c.result = r })).toggleStyle(.checkbox).font(Theme.body(12))
                    row("Key pattern") {
                        TextField("ts ([0-9.]+)", text: Binding(get: { c.result?.keyPattern ?? "" }, set: { v in var r = c.result ?? ScriptResultParse(); r.keyPattern = v.isEmpty ? nil : v; c.result = r }))
                            .textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
                    }
                    row("Link pattern") {
                        TextField("(https://\\S+)", text: Binding(get: { c.result?.urlPattern ?? "" }, set: { v in var r = c.result ?? ScriptResultParse(); r.urlPattern = v.isEmpty ? nil : v; c.result = r }))
                            .textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
                    }
                    ForEach(problems, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").font(Theme.body(12)).foregroundStyle(Theme.peachInk) }
                }
                .padding(.trailing, 6)
            }
            .frame(maxHeight: 520)
            HStack(spacing: 10) {
                if original != nil {
                    if confirmDelete {
                        Text("Delete this command? Buttons using it stop working.").font(Theme.body(12))
                        ActionButton(title: "Delete", kind: .soft) { done(.delete) }
                    } else {
                        Button("Delete command") { confirmDelete = true }.buttonStyle(.plain).font(Theme.body(12, .semibold)).foregroundStyle(Theme.peachInk)
                    }
                }
                Spacer()
                ActionButton(title: "Cancel", kind: .plain) { done(.cancel) }.keyboardShortcut(.cancelAction)
                ActionButton(title: "Save", kind: .primary) { save() }
                    .disabled(!problems.isEmpty).opacity(problems.isEmpty ? 1 : 0.45)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 620)
    }

    private func argRow(_ i: Int) -> some View {
        let a = c.args[i]
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(kindTitle(a.kind)).font(Theme.body(11, .heavy)).foregroundStyle(Theme.muted).frame(width: 52, alignment: .leading)
                TextField("name", text: $c.args[i].name).textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced)).frame(width: 110)
                switch a.kind {
                case .word:
                    TextField("send", text: Binding(get: { c.args[i].value ?? "" }, set: { c.args[i].value = $0 }))
                        .textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
                case .flag, .switch:
                    TextField("--thread", text: Binding(get: { c.args[i].flag ?? "" }, set: { c.args[i].flag = $0 }))
                        .textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
                case .positional:
                    Spacer()
                }
                if a.kind == .flag || a.kind == .positional {
                    Toggle("Required", isOn: Binding(get: { c.args[i].isRequired }, set: { c.args[i].required = $0 })).toggleStyle(.checkbox).font(Theme.body(11.5))
                }
                IconButton(systemImage: "arrow.up", size: 22, help: "Move up") { if i > 0 { c.args.swapAt(i, i - 1) } }.disabled(i == 0)
                IconButton(systemImage: "xmark", size: 22, help: "Remove") { c.args.remove(at: i) }
            }
            if a.kind == .flag || a.kind == .positional {
                HStack(spacing: 8) {
                    Spacer().frame(width: 52)
                    TextField("Pattern (optional), e.g. ^(#\\S+|@\\S+)$", text: Binding(get: { c.args[i].pattern ?? "" }, set: { c.args[i].pattern = $0.isEmpty ? nil : $0 }))
                        .textFieldStyle(.roundedBorder).font(.system(size: 11.5, design: .monospaced))
                    TextField("Hint, e.g. #channel or @handle", text: Binding(get: { c.args[i].hint ?? "" }, set: { c.args[i].hint = $0.isEmpty ? nil : $0 }))
                        .textFieldStyle(.roundedBorder).font(Theme.body(11.5))
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func kindTitle(_ k: ScriptCommandArg.Kind) -> String {
        switch k { case .word: "WORD"; case .flag: "FLAG"; case .switch: "SWITCH"; case .positional: "VALUE" }
    }

    private func add(_ kind: ScriptCommandArg.Kind) {
        let base = kind == .word ? "word" : kind == .positional ? "value" : "option"
        var n = c.args.count + 1
        while c.args.contains(where: { $0.name == "\(base)\(n)" }) { n += 1 }
        let arg = ScriptCommandArg(name: "\(base)\(n)", kind: kind, flag: kind == .flag || kind == .switch ? "--" : nil)
        // Words go before the first value so the argv reads naturally.
        if kind == .word, let i = c.args.firstIndex(where: { $0.kind != .word }) { c.args.insert(arg, at: i) } else { c.args.append(arg) }
    }

    private func save() {
        var out = c
        out.label = out.label.trimmingCharacters(in: .whitespaces)
        if out.id.isEmpty { out.id = AutomationText.slug(out.label, taken: taken) }
        if let r = out.result, r.json == nil, r.keyPattern == nil, r.urlPattern == nil { out.result = nil }
        done(.save(out))
    }

    private func row<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 12) {
            Text(title).font(Theme.body(12.5)).foregroundStyle(Theme.muted).frame(width: 90, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }
}
