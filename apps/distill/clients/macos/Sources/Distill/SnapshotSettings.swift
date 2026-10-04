import AppKit
import SwiftUI
import DistillKit

// Settings window states for `--states` (canvas: SettingsNav, Settings): each
// section in the nav layout, search, the Actions pages and Connections.

extension StatesSnapshot {
    nonisolated static let settingsSize = CGSize(width: 1140, height: 720)

    /// The Settings window at its default size, opened at `target`.
    static func settingsWindow(_ file: String, _ state: String, _ desc: String, _ e: AppModel,
                               target: SettingsTarget = SettingsTarget(.vaults), query: String = "",
                               size: CGSize = settingsSize, advanced: Bool = false, defaults: [String: Any] = [:]) {
        let ui = e.settingsUI
        ui.target = target
        ui.query = query
        let view = SettingsView(showAdvanced: advanced).environmentObject(e).frame(width: size.width, height: size.height)
        shoot(file, .app, "Settings", state, desc, defaults: defaults, live: true, liveSize: size, view)
    }

    static func settingsNavStates() {
        // Every section, as picked in the nav.
        for section in SettingsSection.allCases {
            let e = engine { $0.enabledRunners = ["claude-code", "ai-sdk"] }
            settingsWindow("settings-nav-\(section.rawValue)", "\(section.group.title) · \(section.title)",
                           "Nav selects \(section.title); its own page opens at the top.", e, target: SettingsTarget(section))
        }

        // Search.
        var e = engine()
        settingsWindow("settings-search-prompt", "Search · “prompt”",
                       "7 settings match: Actions 6 (Create and Improve prompt per type), Models for tasks 1. Other sections dimmed.", e, query: "prompt")
        e = engine()
        settingsWindow("settings-search-none", "Search · no results", "No settings match “webhook”, with Clear search.", e, query: "webhook")

        // Actions: sources with some detection off, a type turned off.
        e = engine {
            SettingsEdits.setActions(&$0) { p in
                p.setType("confluence", detected: false, from: .ask)
                p.setConfirm(.ask, false)
                p.setTypeValue("slack", "draftWhen", .string("onRequest"))
            }
        }
        settingsWindow("settings-actions-sources", "Actions · sources edited",
                       "Ask answers: Confluence not detected, confirm off. Slack drafts only when asked.", e, target: SettingsTarget(.actions))

        e = engine()
        e.settingsUI.typesLoad = .unavailable
        settingsWindow("settings-actions-old-core", "Actions · older core", "The core can’t list action types: calm “Update the Distill core” note.",
                       e, target: SettingsTarget(.actions))

        // Type pages.
        e = engine()
        settingsWindow("settings-type-slack", "Actions › Slack message", "Defaults: written when a note is processed, Sonnet, both prompts at Default, Send in Slack coming later.",
                       e, target: SettingsTarget(.actions, actionType: "slack"), size: CGSize(width: 1140, height: 1000))
        let jiraEdited: (inout DistillKit.Settings) -> Void = { s in
            SettingsEdits.setActions(&s) { p in
                p.setTypeValue("jira", "draftPrompt", .string("Draft a Jira ticket for project {project} from {excerpt}.\nSummary: one line, starts with a verb. Description sections: Context, Steps, Acceptance criteria.\nAlways link the incident number if the note has one, and add the label from {labels}."))
                p.setFieldDefault("jira", "project", "PX")
                p.setFieldDefault("jira", "issueType", "Task")
            }
        }
        e = engine(jiraEdited)
        settingsWindow("settings-type-jira-edited", "Actions › Jira ticket · prompt edited",
                       "Create prompt Edited (Reset to default on), Create in Jira locked to your click, default project PX.",
                       e, target: SettingsTarget(.actions, actionType: "jira"), size: CGSize(width: 1140, height: 1080))
        e = engine(jiraEdited)
        e.settingsUI.fixtureConfirmReset = "draft"
        settingsWindow("settings-type-jira-reset-confirm", "Actions › Jira ticket · reset confirmation",
                       "“Reset the create prompt?” with Cancel and Reset.", e, target: SettingsTarget(.actions, actionType: "jira"),
                       size: CGSize(width: 1140, height: 1080))
        e = engine()
        e.settingsUI.promptUndo = ["jira.draft": "My old prompt"]
        settingsWindow("settings-type-jira-reset-undo", "Actions › Jira ticket · after reset",
                       "Back to Default, with Undo reset until Settings closes.", e, target: SettingsTarget(.actions, actionType: "jira"),
                       size: CGSize(width: 1140, height: 1080))
        e = engine { SettingsEdits.setActions(&$0) { $0.setTypeValue("confluence", "enabled", .bool(false)) } }
        settingsWindow("settings-type-confluence-off", "Actions › Confluence page · off", "Type off: its items become to-dos; settings dimmed.",
                       e, target: SettingsTarget(.actions, actionType: "confluence"), size: CGSize(width: 1140, height: 1000))

        // To-do defaults with a custom retention.
        e = engine { SettingsEdits.setActions(&$0) { p in p.historyDays = 0; p.remindOverdue = true; p.todoGroup = "note" } }
        settingsWindow("settings-todo-edited", "To-do defaults · edited", "Group by note, keep forever, remind on.", e, target: SettingsTarget(.todo))

        // Connections in each state.
        func connections(_ file: String, _ state: String, _ desc: String, _ setup: (SettingsStore) -> Void) {
            let e = engine()
            setup(e.settingsUI)
            settingsWindow(file, state, desc, e, target: SettingsTarget(.connections))
        }
        let site = "https://acme.atlassian.net"
        func atlassian(_ status: ConnectionInfo.Status, site: String? = nil, account: String? = nil, message: String? = nil) -> ConnectionInfo {
            ConnectionInfo(id: "atlassian", label: "Atlassian", status: status, site: site, account: account, message: message, usedBy: ["jira", "confluence"])
        }
        connections("settings-connections-none", "Connections · not connected", "Slack not needed yet; Atlassian: Sign in in your browser.") {
            $0.connections = [atlassian(.notConnected)]
            $0.connectionsLoad = .loaded
        }
        connections("settings-connections-signing-in", "Connections · signing in", "Browser opened: paste site, email and API token, then Connect.") {
            $0.connections = [atlassian(.notConnected, site: site)]
            $0.connectionsLoad = .loaded
            $0.signingIn = ["atlassian"]
            $0.fixtureForm = ("jin@acme.test", "not-a-real-token")
        }
        connections("settings-connections-connecting", "Connections · connecting", "Connect pressed: the core checks the token.") {
            $0.connections = [atlassian(.notConnected, site: site)]
            $0.connectionsLoad = .loaded
            $0.signingIn = ["atlassian"]
            $0.connectionBusy = ["atlassian": "Connecting…"]
            $0.fixtureForm = ("jin@acme.test", "")
        }
        connections("settings-connections-refused", "Connections · token refused", "Atlassian refused the token; the form stays with the message.") {
            $0.connections = [atlassian(.notConnected, site: site)]
            $0.connectionsLoad = .loaded
            $0.signingIn = ["atlassian"]
            $0.connectionError = ["atlassian": "Couldn’t sign in: Atlassian refused the email or API token."]
            $0.fixtureForm = ("jin@acme.test", "")
        }
        connections("settings-connections-connected", "Connections · connected", "Site and account, Disconnect.") {
            $0.connections = [atlassian(.connected, site: site, account: "Jin Liu")]
            $0.connectionsLoad = .loaded
        }
        connections("settings-connections-expired", "Connections · sign-in expired", "Token no longer accepted: Sign in in your browser again.") {
            $0.connections = [atlassian(.expired, site: site, account: "Jin Liu")]
            $0.connectionsLoad = .loaded
        }
        connections("settings-connections-error", "Connections · denied", "The sign-in was denied: Try again.") {
            $0.connections = [atlassian(.error, site: site, message: "Atlassian said access was denied. Nothing changed. You can try again.")]
            $0.connectionsLoad = .loaded
        }
        connections("settings-connections-old-core", "Connections · older core", "The core has no connections routes: “Update the Distill core”.") {
            $0.connectionsLoad = .unavailable
        }
    }
}
