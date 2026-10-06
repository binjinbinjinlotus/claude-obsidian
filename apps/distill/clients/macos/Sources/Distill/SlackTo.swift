import SwiftUI
import DistillKit

// Where a Slack message goes (action-buttons.md, "Where to send"): the To row's kind, the
// "Who is … in Slack?" field for a name Distill doesn't know, and Send turned off until it
// resolves. The core makes the same check before any run (slack-target.ts).

extension ActionsStore {
    /// The vault whose remembered names apply: the item's, else the active one.
    func slackVault(_ item: ActionItem) -> String? { item.vaultPath ?? engine?.settings.activeVaultPath }

    func slackTarget(_ item: ActionItem) -> SlackTarget {
        SlackTarget.resolve(to: item.field("to"), thread: item.field("thread"),
                            lookup: SlackToText.lookup(slackPeople, vault: slackVault(item)))
    }

    /// Why this button can't run for this item yet (a Slack message whose To row doesn't resolve).
    func slackBlock(_ item: ActionItem, _ button: AutomationButton) -> String? {
        item.type == "slack" ? slackTarget(item).blocks(button) : nil
    }

    /// Whether any of the type's buttons sends to the To field (only then does a plain name need its handle;
    /// Copy and paste work with any name).
    func slackSendsToField(_ type: ActionTypeInfo) -> Bool {
        type.buttons.contains { b in
            b.button.enabled && b.button.bindings.values.contains { t in
                let p = SlackTarget.placeholders(t)
                return p.contains("fields.to") || p.contains("recipient")
            }
        }
    }

    /// The pattern the type's Send button declares for the argument it fills from the To field.
    func slackTargetPattern(_ type: ActionTypeInfo) -> String? {
        guard let send = type.buttons.first(where: { $0.button.slot == .send }) ?? type.buttons.first,
              let script = engine?.collectors.collectors.first(where: { $0.id == send.button.scriptId })?.script,
              let command = script.commands.first(where: { $0.id == send.button.commandId }) else { return nil }
        let arg = command.args.first { a in
            let t = send.button.bindings[a.name] ?? ""
            return SlackTarget.placeholders(t).contains("fields.to") || SlackTarget.placeholders(t).contains("recipient")
        }
        return arg?.pattern
    }

    func loadSlackPeople() {
        guard let client else { return }
        Task {
            // An older core has no /v1/slack-people: names just stay unknown.
            if let people = try? await client.slackPeople() { slackPeople = people }
        }
    }

    func rememberSlack(_ item: ActionItem, name: String, target: String) {
        guard let client else { return }
        let vault = slackVault(item)
        Task {
            do {
                let saved = try await client.rememberSlackPerson(name: name, target: target, vault: vault)
                slackPeople.removeAll { $0.id == saved.id }
                slackPeople.append(saved)
            } catch {
                engine?.report(error)
            }
        }
    }

    func forgetSlack(_ item: ActionItem, name: String) {
        guard let client else { return }
        let vault = slackVault(item)
        Task {
            do {
                try await client.forgetSlackPerson(name: name, vault: vault)
                slackPeople.removeAll { $0.vaultPath == vault && SlackTarget.normalName($0.name) == SlackTarget.normalName(name) }
            } catch {
                engine?.report(error)
            }
        }
    }
}

/// "To  [Person]  Aditya Pradhan (@aditya) · direct message" (the header's recipient button label).
struct SlackToLabel: View {
    let target: SlackTarget
    /// A button sends to it, so an unknown name is a question (peach).
    var needsTarget = true

    var body: some View {
        HStack(spacing: 6) {
            Text("To")
            Text(SlackToText.kind(target)).font(Theme.body(10.5, .bold)).foregroundStyle(Theme.muted)
                .padding(.horizontal, 6).padding(.vertical, 1.5).background(Capsule().fill(Theme.panel))
            if target.written.isEmpty && target.kind != .thread {
                Text("Choose who gets it").foregroundStyle(Theme.primary)
            } else {
                Image(systemName: icon).font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.muted)
                // The name and handle win the space; "· direct message" gives way first.
                Text(SlackToText.main(target)).fontWeight(.bold).lineLimit(1).layoutPriority(1)
                    .foregroundStyle(target.ask != nil && needsTarget ? Theme.peachInk : Theme.ink)
                Text("· " + SlackToText.detail(target)).fontWeight(.regular).foregroundStyle(Theme.faint).lineLimit(1)
            }
        }
        .font(Theme.body(13, .semibold))
    }

    private var icon: String {
        switch target.kind {
        case .channel: return "number"
        case .thread: return "arrowshape.turn.up.left"
        case .person: return target.ask != nil && needsTarget ? "person.fill.questionmark" : "person"
        }
    }
}

/// "Who is Aditya Pradhan in Slack?" with a field for the @handle or ID. Save remembers it for the
/// vault; the field refuses what the button's script would refuse.
struct SlackWhoIsRow: View {
    let question: String
    let name: String
    var pattern: String?
    var initial = ""
    let onSave: (String) -> Void

    @State private var text: String

    init(question: String, name: String, pattern: String? = nil, initial: String = "", onSave: @escaping (String) -> Void) {
        self.question = question; self.name = name; self.pattern = pattern; self.initial = initial; self.onSave = onSave
        _text = State(initialValue: initial)
    }

    private var value: String? { SlackTarget.typed(text, pattern: pattern) }
    private var typedWrong: Bool { !text.trimmingCharacters(in: .whitespaces).isEmpty && value == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: "person.fill.questionmark").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.peachInk)
                Text(question).font(Theme.body(13, .bold))
            }
            HStack(spacing: 8) {
                TextField("@handle or user ID (U…)", text: $text)
                    .textFieldStyle(.roundedBorder).font(.system(size: 12.5, design: .monospaced))
                    .onSubmit { if let value { onSave(value) } }
                ActionButton(title: "Save", kind: .primary, height: 26) { if let value { onSave(value) } }
                    .disabled(value == nil).opacity(value == nil ? 0.5 : 1)
            }
            Text(typedWrong ? "That isn’t an @handle, a #channel or a Slack ID (U…, C…)."
                            : "Distill remembers it for this vault, so the next message to \(name) finds them. Send stays off until then.")
                .font(Theme.body(11)).foregroundStyle(typedWrong ? Theme.peachInk : Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.gapFill))
    }
}
