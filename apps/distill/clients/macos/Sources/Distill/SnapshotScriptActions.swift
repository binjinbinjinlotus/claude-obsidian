import AppKit
import SwiftUI
import DistillKit

/// Fixtures and snapshot states for board ScriptActions (canvas row 15, action-buttons.md): a Slack CLI script
/// that only offers commands, a Send in Slack button bound to its `send`, the run sheet, and the result on the item.
/// File names are the board's frame ids (`sa-…`).
@MainActor
enum ScriptActionFixtures {
    typealias F = CollectorFixtures
    static let scriptPath = F.home + "/Scripts/slack-cli/slack_send.py"

    static let send = ScriptCommand(
        id: "send", label: "Send a message", description: "Posts a message to a person or a channel.",
        args: [ScriptCommandArg(name: "send", kind: .word, value: "send"),
               ScriptCommandArg(name: "thread", kind: .flag, flag: "--thread", required: false, hint: "a message ts, to reply in its thread"),
               ScriptCommandArg(name: "target", kind: .positional, hint: "@person or #channel"),
               ScriptCommandArg(name: "text", kind: .positional)],
        endOptions: true, timeoutSeconds: 30, result: ScriptResultParse(json: true, keyPattern: "ts"))

    /// Slack CLI: the owner's own Python file; it collects nothing, it offers `send` to buttons.
    static func slackCLI() -> Collector {
        Collector(id: "slack-cli", kind: .script, name: "Slack CLI", vaultPath: "", enabled: true,
                  schedule: CollectorSchedule(cron: "0 * * * *", preset: .hourly),
                  script: ScriptCollectorSettings(source: .file(scriptPath), interpreter: .python3, timeoutSeconds: 30, allowedSha256: "cc",
                                                  allowedAt: F.at(9, 5, daysAgo: 1), collects: false, commands: [send]),
                  status: CollectorStatus(currentSha256: "cc", script: CollectorScriptStatus(path: scriptPath, managed: false)))
    }

    static let sendButton = AutomationButton(id: "send-slack", label: "Send in Slack", icon: "paperplane", scriptId: "slack-cli", commandId: "send",
                                             bindings: ["thread": "", "target": "{fields.to}", "text": "{body}"], confirm: false,
                                             onSuccess: .markSent, storeResult: true, slot: .send)
    static let dmButton = AutomationButton(id: "dm-me", label: "Send to me in Slack", icon: "paperplane", scriptId: "slack-cli", commandId: "send",
                                           bindings: ["thread": "", "target": "@me", "text": "{title}"], confirm: false, slot: .primary)

    static func info(_ b: AutomationButton) -> ActionButtonInfo {
        ActionButtonInfo(button: b, scriptName: "Slack CLI", commandLabel: send.label)
    }

    static var types: [ActionTypeInfo] {
        ActionFixtures.types.map { t in
            var t = t
            // As the core sends it: a button in the Send slot hides the reserved Send in Slack handler.
            if t.id == "slack" { t.buttons = [info(sendButton)]; t.handlers.removeAll { $0.id == "send" } }
            if t.id == "todo" { t.buttons = [info(dmButton)] }
            return t
        }
    }

    static let shortMessage = "Hi @Mei, I booked the tasting room for Saturday at 2 PM. Could you bring the new 50 g gyokuro tin?"

    static var preview: ActionButtonPreview {
        let argv = ["python3", scriptPath, "send", "--", "Mei Tanaka", shortMessage]
        return ActionButtonPreview(argv: argv, display: "python3 ~/Scripts/slack-cli/slack_send.py send -- 'Mei Tanaka' '\(shortMessage)'",
                                   needsApproval: true, approvalHash: "a1")
    }

    static func sheet(_ phase: ButtonRunSheetState.Phase, runID: String? = nil) -> ButtonRunSheetState {
        ButtonRunSheetState(itemID: "s1", buttonID: sendButton.id, label: sendButton.label, runs: "Slack CLI › \(send.label)",
                            phase: phase, preview: preview, firstRun: true, runID: runID)
    }

    /// Settings with the buttons saved (Settings → Actions → a type → Buttons).
    static func engine() -> AppModel {
        let e = StatesSnapshot.engine {
            SettingsEdits.setActions(&$0) { p in
                p.setButtons("slack", [sendButton])
                p.setButtons("todo", [dmButton])
            }
        }
        e.actions.loadFixture(types: types, items: ActionFixtures.live() + ActionFixtures.history())
        e.actions.items["s1"]?.body = shortMessage
        e.settingsUI.connections = [ConnectionInfo(id: "atlassian", label: "Atlassian", status: .connected, site: "https://acme.atlassian.net", account: "Jin Liu")]
        _ = F.load(e, [F.inbox(), ScriptFixtures.pocket(), slackCLI()], select: "slack-cli", now: F.at(9, 32))
        return e
    }
}

/// The run sheet as the app presents it: dimmed screen behind, the sheet card in front.
private struct RunSheetOver<Base: View>: View {
    @ObservedObject var store: ActionsStore
    let state: ButtonRunSheetState
    let base: Base

    var body: some View {
        ZStack(alignment: .top) {
            base
            Color(red: 29 / 255, green: 28 / 255, blue: 26 / 255).opacity(0.28)
            ButtonRunSheet(store: store, state: state)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color.white))
                .shadow(color: .black.opacity(0.18), radius: 24, y: 8)
                .padding(.top, 90)
        }
    }
}

extension StatesSnapshot {
    static func scriptActionStates() {
        let f = Flow.collectors
        typealias S = ScriptActionFixtures

        // A · the library: Folder and Pocket collect; Slack CLI only offers commands to buttons.
        var e = S.engine()
        main("sa-library", f, "Automations", "A · Slack CLI offers commands", "COLLECT ON A SCHEDULE and COMMANDS FOR BUTTONS; the script's COMMANDS block shows send and Used by Slack message › Send in Slack.",
             e, section: .collectors, size: CGSize(width: 1200, height: 860)) { CollectorsScreen() }

        // B · a Slack message whose Send in Slack runs Slack CLI › send.
        e = S.engine()
        e.actions.tab = "slack"
        e.actions.selected["slack"] = "s1"
        main("sa-slack-item", f, "Actions · Slack messages", "B · Send in Slack is a button", "Linked to Slack CLI › send; ＋ Button adds another (shown when the footer has room).", e, section: .actions,
             size: CGSize(width: 1440, height: 760)) {
            ActionsScreen()
        }

        // C · the first run shows the exact command and every argument.
        e = S.engine()
        e.actions.tab = "slack"
        e.actions.selected["slack"] = "s1"
        main("sa-slack-confirm", f, "Actions · Slack messages", "C · First run: the exact command", "The command line and each argument before anything runs; Ask me every time; Run.",
             e, section: .actions) {
            RunSheetOver(store: e.actions, state: S.sheet(.confirm), base: ActionsScreen())
        }

        // D · running: the output streams into the same sheet, with Stop.
        e = S.engine()
        e.actions.tab = "slack"
        e.actions.selected["slack"] = "s1"
        let started = ActionFixtures.at(15, 53)
        e.actions.items["s1"]?.activeRun = ActiveButtonRun(runId: "run-2", buttonId: S.sendButton.id)
        e.actions.items["s1"]?.runs = [ActionButtonRun(runId: "run-2", buttonId: S.sendButton.id, label: S.sendButton.label, startedAt: started)]
        e.collectors.ordered["run-2"] = [CollectorOutputChunk(stream: "stdout", text: "Looking up Mei Tanaka… U07MEI2K4\n", at: started),
                                         CollectorOutputChunk(stream: "stdout", text: "Opening a direct message… D07MEI9QX\n", at: started.addingTimeInterval(0.4))]
        main("sa-slack-running", f, "Actions · Slack messages", "D · Running", "The output streams into the sheet; Stop and Hide.", e, section: .actions) {
            RunSheetOver(store: e.actions, state: S.sheet(.running, runID: "run-2"), base: ActionsScreen())
        }

        // E · success: marked sent, the ts saved from the output, Last run on the item.
        e = S.engine()
        let ended = ActionFixtures.at(15, 53).addingTimeInterval(1.2)
        e.actions.items["s1"]?.status = .sent
        e.actions.items["s1"]?.events.append(ActionEvent(at: ended, event: "sent", detail: "Send in Slack"))
        e.actions.items["s1"]?.runs = [ActionButtonRun(runId: "run-2", buttonId: S.sendButton.id, label: S.sendButton.label, startedAt: started, endedAt: ended,
                                                       durationMs: 1200, result: "success", exitCode: 0,
                                                       stdoutTail: "Looking up Mei Tanaka… U07MEI2K4\nOpening a direct message… D07MEI9QX\n{\"ok\": true, \"channel\": \"D07MEI9QX\", \"ts\": \"1759780412.004100\"}\n",
                                                       externalKey: "1759780412.004100")]
        e.actions.tab = "slack"
        main("sa-slack-sent", f, "Actions · Slack messages", "E · Sent", "The sheet's result line and output with the ts; the message is marked sent and has left the list. The sheet closes after 1.5 s.",
             e, section: .actions) {
            RunSheetOver(store: e.actions, state: S.sheet(.finished, runID: "run-2"), base: ActionsScreen())
        }

        // F · failure: stderr on the item, Try again; it stays Ready to send.
        e = S.engine()
        e.actions.tab = "slack"
        e.actions.selected["slack"] = "s1"
        e.actions.items["s1"]?.runs = [ActionButtonRun(runId: "run-1", buttonId: S.sendButton.id, label: S.sendButton.label, startedAt: started, endedAt: ended,
                                                       durationMs: 900, result: "failed", exitCode: 1,
                                                       stderrTail: "Looking up Mei Tanaka…\nerror: no Slack user named “Mei Tanaka” in acme.slack.com\n",
                                                       message: "Exited with 1")]
        main("sa-slack-failed", f, "Actions · Slack messages", "F · Couldn't send", "The error on the item with Show log; the message stays Ready to send.", e, section: .actions) {
            ActionsScreen()
        }

        // Settings → Actions → Slack message → Buttons.
        e = S.engine()
        natural("sa-card-settings", f, "Settings", "Buttons on a type", "One list per type, in footer order; Edit, the switch and Add button.", e) {
            ActionTypeButtonsSection(typeID: "slack", label: "slack message")
                .padding(.horizontal, 22).frame(width: 640).background(RoundedRectangle(cornerRadius: 14).fill(Color.white))
        }

        // The button editor: mapping and the core's preview on the selected message.
        e = S.engine()
        natural("sa-card-editor", f, "Actions", "The button editor", "Runs Slack CLI › Send a message; each argument a template; the preview on the selected item.", e) {
            ButtonEditorSheet(target: ButtonEditorTarget(typeID: "slack", button: S.sendButton, itemID: "s1"), close: {}, preview: S.preview)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color.white))
        }

        // Declaring a command on the automation.
        e = S.engine()
        natural("sa-card-command", f, "Automations", "Declaring a command", "send: a word, an optional --thread, the target and the text after --.", e) {
            CommandEditorSheet(command: S.send, taken: []) { _ in }
                .background(RoundedRectangle(cornerRadius: 14).fill(Color.white))
        }

        // Buttons on every type: a to-do with its own button and ＋ Button.
        e = S.engine()
        e.actions.tab = "todo"
        e.actions.selected["todo"] = "t2"
        main("sa-card-todo", f, "Actions · To do", "Buttons on every type", "A to-do's footer: Send to me in Slack and ＋ Button.", e, section: .actions) {
            ActionsScreen()
        }

        // Adding an automation: the first step.
        e = S.engine()
        var first = AddDraft()
        first.setRole(.commands)
        e.collectors.adding = first
        main("sa-card-add", f, "Automations", "Adding an automation", "Step 1, What it does: Collect, Commands for buttons (picked) or Both; a collector keeps today's steps.", e, section: .collectors) {
            CollectorsScreen()
        }
    }
}
