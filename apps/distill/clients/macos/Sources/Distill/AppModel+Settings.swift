import AppKit
import Combine
import DistillKit

/// Settings window state that isn't stored in settings.json: the selected
/// section, the search query, the action types and connections from the core,
/// and the last Connect failure. One per AppModel (like NotesStore).
@MainActor
final class SettingsStore: ObservableObject {
    enum Load: Equatable { case idle, loading, loaded, unavailable, failed(String) }

    @Published var target = SettingsTarget(.vaults)
    /// Bumped whenever something asks to show `target`, so the page scrolls even to the same section.
    @Published var scrollRequest = 0
    @Published var query = ""

    @Published var actionTypes: [SettingsActionType] = SettingsActionType.builtIn
    @Published var typesLoad: Load = .idle
    @Published var connections: [ConnectionInfo] = []
    @Published var connectionsLoad: Load = .idle
    /// A request to the core for this connection is running (Connect or
    /// Disconnect). Only disables the buttons: there is no "Connecting…" state.
    @Published var connectionBusy: Set<String> = []
    /// Why the last Connect or Disconnect failed, per connection (never contains the token).
    @Published var connectionError: [String: ConnectionProblem] = [:]
    /// Prompts replaced by Reset to default ("jira.draft" → the user's text), undoable until Settings closes.
    @Published var promptUndo: [String: String] = [:]

    /// Snapshot fixtures only: a reset confirmation open on this prompt ("draft" / "improve").
    var fixtureConfirmReset: String?
    /// Snapshots: the People page's 7-day preview (the app asks the core).
    var fixtureRoutingPreview: RoutingPreview?
    /// Snapshot fixtures only: what the Atlassian sign-in form shows (the token is fake).
    var fixtureForm: (email: String, token: String)?

    fileprivate static var stores: [ObjectIdentifier: SettingsStore] = [:]

    static func of(_ engine: AppModel) -> SettingsStore {
        let key = ObjectIdentifier(engine)
        if let s = stores[key] { return s }
        let s = SettingsStore()
        stores[key] = s
        return s
    }

    // MARK: Scroll memory
    //
    // Every section (and every action type) is its own page. A page you haven't
    // visited in this Settings session opens at its top; one you have reopens
    // where you left it. Search results and deep links always open the page at
    // its top, or at the matched row. In memory only: `closed()` (the window
    // closing) and quitting forget everything.

    /// Where the next shown page lands. Decided when the page is asked for,
    /// because a freshly built scroll view reports 0 before it is restored.
    enum Landing: Equatable {
        /// The top of the page.
        case top
        /// A remembered offset from the top.
        case offset(CGFloat)
        /// A row on the page (a search result), by its anchor key (`SettingsAnchor.key`).
        case row(String)
    }

    /// Set until the page has scrolled to it; while set, scrolling isn't recorded.
    var landing: Landing?
    /// Where each page visited in this session was left (offset from the top).
    private(set) var offsets: [SettingsTarget: CGFloat] = [:]
    /// The rows each page reports (anchor key → distance from the page's top), for search landings.
    var anchors: [SettingsTarget: [String: CGFloat]] = [:]

    /// The section nav and links back inside Settings ("‹ Actions", an action type row):
    /// back where you left the page, or its top.
    func select(_ t: SettingsTarget) {
        query = ""
        landing = landing(for: t)
        target = t
        scrollRequest += 1
    }

    /// Search results, deep links ("connections", "actions/jira") and "Open Actions ›":
    /// the page's top, or `row` on it, ignoring memory.
    func show(_ t: SettingsTarget, row: String? = nil) {
        query = ""
        landing = row.map { .row(SettingsAnchor.key($0)) } ?? .top
        anchors[t] = nil // wait for the page to report its rows as laid out now
        target = t
        scrollRequest += 1
    }

    /// A search result: its row, or the page's top when the result is the section itself.
    func show(_ entry: SettingsEntry) {
        show(entry.target, row: entry.title == entry.target.section.title && entry.target.actionType == nil ? nil : entry.title)
    }

    /// Shows a section ("connections", "actions/jira"); unknown ids are ignored.
    func open(_ id: String) {
        guard let t = SettingsTarget(id: id) else { return }
        show(t)
    }

    func landing(for t: SettingsTarget) -> Landing { offsets[t].map { .offset($0) } ?? .top }

    /// The current page scrolled to `y` (by the user, or by landing).
    func remember(_ y: CGFloat) {
        guard landing == nil, query.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        offsets[target] = y
    }

    /// The Settings window closed: forget positions, row anchors and prompt-reset undos.
    func closed() {
        offsets = [:]
        anchors = [:]
        landing = nil
        promptUndo = [:]
    }

    func type(_ id: String) -> SettingsActionType? { actionTypes.first { $0.id == id } }
    func connection(_ id: String) -> ConnectionInfo? { connections.first { $0.id == id } }
}

extension AppModel {
    var settingsUI: SettingsStore { SettingsStore.of(self) }

    /// Opens Settings at a section ("connections", "models", "actions/jira", …).
    /// Posts "distill.openSettingsSection"; AppDelegate selects it and shows the window.
    func openSettings(section: String) {
        NotificationCenter.default.post(name: .distillOpenSettingsSection, object: section)
    }

    // MARK: Action types

    func loadActionTypes() {
        guard let client else { return }
        let store = settingsUI
        if store.typesLoad != .loaded { store.typesLoad = .loading }
        Task {
            do {
                let list = try await client.actionTypes()
                if !list.isEmpty { store.actionTypes = list }
                store.typesLoad = .loaded
            } catch {
                if let e = error as? CoreClientError, e.isNotAvailable {
                    store.typesLoad = .unavailable
                } else {
                    store.typesLoad = .failed("\(error)")
                }
            }
        }
    }

    // MARK: Connections

    func loadConnections() {
        guard let client else { return }
        let store = settingsUI
        if store.connectionsLoad != .loaded { store.connectionsLoad = .loading }
        Task {
            do {
                store.connections = try await client.connections()
                store.connectionsLoad = .loaded
            } catch {
                if let e = error as? CoreClientError, e.isNotAvailable {
                    store.connectionsLoad = .unavailable
                } else {
                    store.connectionsLoad = .failed("\(error)")
                }
            }
        }
    }

    func applyConnection(_ c: ConnectionInfo) {
        let store = settingsUI
        if let i = store.connections.firstIndex(where: { $0.id == c.id }) { store.connections[i] = c } else { store.connections.append(c) }
        if c.status == .connected { store.connectionError[c.id] = nil }
    }

    /// "Get an API token": opens Atlassian's API token page (the core names it)
    /// in the default browser. Nothing waits for it: the token form stays as it is.
    func openTokenPage(_ id: String, site: String?) {
        let store = settingsUI
        guard let client else {
            store.connectionError[id] = ConnectionProblem(title: "The Distill core isn’t running", detail: "Start Distill’s core, then try again.")
            return
        }
        Task {
            do {
                NSWorkspace.shared.open(try await client.signInURL(id, site: site))
            } catch {
                store.connectionError[id] = ConnectionProblem(title: Self.connectionMessage(error, "Couldn’t open the token page"), detail: "")
            }
        }
    }

    /// Sends site, email and token to the core, which checks them with
    /// Atlassian and keeps the token in the Keychain. `done(true)`: connected,
    /// the form clears. `done(false)`: still not connected, nothing saved, and
    /// `connectionError` says why. No in-between state is shown while it runs.
    func connect(_ id: String, site: String, email: String, token: String, done: @escaping (Bool) -> Void) {
        let store = settingsUI
        guard let client else {
            store.connectionError[id] = ConnectionProblem(title: "The Distill core isn’t running", detail: "Nothing was saved.")
            done(false)
            return
        }
        guard !store.connectionBusy.contains(id) else { return }
        store.connectionBusy.insert(id)
        store.connectionError[id] = nil
        let request = ConnectRequest(site: site.trimmingCharacters(in: .whitespacesAndNewlines),
                                     email: email.trimmingCharacters(in: .whitespacesAndNewlines),
                                     token: token.trimmingCharacters(in: .whitespacesAndNewlines))
        Task {
            defer { store.connectionBusy.remove(id) }
            do {
                let info = try await client.connect(id, request)
                self.applyConnection(info)
                if info.status == .connected {
                    done(true)
                } else {
                    store.connectionError[id] = info.message.map { ConnectionProblem(title: $0, detail: "Nothing was saved.") } ?? .tokenRefused
                    done(false)
                }
            } catch {
                store.connectionError[id] = ConnectionProblem.connectFailed(error)
                done(false)
            }
        }
    }

    func disconnect(_ id: String) {
        let store = settingsUI
        guard let client, !store.connectionBusy.contains(id) else { return }
        store.connectionBusy.insert(id)
        Task {
            defer { store.connectionBusy.remove(id) }
            do { self.applyConnection(try await client.disconnect(id)) } catch {
                store.connectionError[id] = ConnectionProblem(title: Self.connectionMessage(error, "Couldn’t disconnect"), detail: "")
            }
        }
    }

    /// A short message for the card. Only the core's own message is shown (it never echoes a token).
    nonisolated static func connectionMessage(_ error: Error, _ prefix: String) -> String {
        if let e = error as? CoreClientError {
            if e.isNotAvailable { return "Update the Distill core to connect accounts." }
            if case .api(_, _, let message) = e { return "\(prefix): \(message)" }
            if e.isUnreachable { return "\(prefix): the Distill core isn’t running." }
        }
        return "\(prefix)."
    }
}

/// What the Atlassian card shows when Connect didn't connect. The connection
/// stays "not connected"; the form keeps what was typed.
struct ConnectionProblem: Equatable {
    var title: String
    var detail: String

    /// Atlassian answered 401/403 to the site, email and token (canvas SettingsNav 9b).
    static let tokenRefused = ConnectionProblem(title: "Atlassian didn’t accept this token",
                                                detail: "Check the site and email, or create a new token. Nothing was saved.")

    /// A failed POST /connect. The core says "… didn't accept that email and API
    /// token" for a refused token; any other answer is shown in its own words.
    static func connectFailed(_ error: Error) -> ConnectionProblem {
        if let e = error as? CoreClientError, !e.isNotAvailable, case .api(_, let code, let message) = e {
            if code == "invalid_request" && message.contains("accept") { return .tokenRefused }
            return ConnectionProblem(title: message, detail: "Nothing was saved.")
        }
        return ConnectionProblem(title: AppModel.connectionMessage(error, "Couldn’t connect"), detail: "Nothing was saved.")
    }
}

extension Notification.Name {
    /// Object: the Settings section id (see SettingsCatalog).
    static let distillOpenSettingsSection = Notification.Name("distill.openSettingsSection")
}
