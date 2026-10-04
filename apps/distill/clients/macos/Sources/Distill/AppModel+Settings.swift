import AppKit
import Combine
import DistillKit

/// Settings window state that isn't stored in settings.json: the selected
/// section, the search query, the action types and connections from the core,
/// and an Atlassian sign-in in progress. One per AppModel (like NotesStore).
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
    /// Connections whose browser sign-in was opened here and whose token form shows.
    @Published var signingIn: Set<String> = []
    /// A request to the core for this connection is running.
    @Published var connectionBusy: [String: String] = [:]
    /// The last failure per connection (never contains the token).
    @Published var connectionError: [String: String] = [:]
    /// Prompts replaced by Reset to default ("jira.draft" → the user's text), undoable until Settings closes.
    @Published var promptUndo: [String: String] = [:]

    /// Snapshot fixtures only: a reset confirmation open on this prompt ("draft" / "improve").
    var fixtureConfirmReset: String?
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
    // A page you haven't visited in this Settings session opens at the top of
    // its section; one you have reopens where you left it. Search results and
    // deep links from other screens always go to the section. In memory only:
    // `closed()` (the window closing) and quitting forget everything.

    /// Where the next shown page lands. Decided when the page is asked for,
    /// because a freshly built scroll view reports 0 before it is restored.
    enum Landing: Equatable {
        /// The section's heading (offset 0 for a group's first section and for type pages).
        case sectionTop
        /// A remembered offset from the top.
        case offset(CGFloat)
    }

    /// Set until the page has scrolled to it; while set, scrolling isn't recorded.
    var landing: Landing?
    /// Where each page visited in this session was left (offset from the top).
    private(set) var offsets: [SettingsTarget: CGFloat] = [:]

    /// The section nav and links inside Settings: back where you left it, or the section's top.
    func select(_ t: SettingsTarget) {
        query = ""
        landing = landing(for: t)
        target = t
        scrollRequest += 1
    }

    /// Search results and deep links ("connections", "actions/jira"): the section itself, ignoring memory.
    func show(_ t: SettingsTarget) {
        query = ""
        landing = .sectionTop
        target = t
        scrollRequest += 1
    }

    /// Shows a section ("connections", "actions/jira"); unknown ids are ignored.
    func open(_ id: String) {
        guard let t = SettingsTarget(id: id) else { return }
        show(t)
    }

    func landing(for t: SettingsTarget) -> Landing { offsets[t].map { .offset($0) } ?? .sectionTop }

    /// The current page scrolled to `y` (by the user, or by landing).
    func remember(_ y: CGFloat) {
        guard landing == nil, query.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        offsets[target] = y
    }

    /// The Settings window closed: forget positions and prompt-reset undos.
    func closed() {
        offsets = [:]
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
        if c.status == .connected { store.signingIn.remove(c.id); store.connectionError[c.id] = nil }
    }

    /// "Sign in in your browser": opens the core's sign-in (API token) page in
    /// the default browser and shows the token form.
    func startSignIn(_ id: String, site: String?) {
        let store = settingsUI
        store.signingIn.insert(id)
        store.connectionError[id] = nil
        guard let client else { store.connectionError[id] = "The Distill core is not connected."; return }
        Task {
            do {
                let url = try await client.signInURL(id, site: site)
                NSWorkspace.shared.open(url)
            } catch {
                store.connectionError[id] = Self.connectionMessage(error, "Couldn’t open the sign-in page")
            }
        }
    }

    func cancelSignIn(_ id: String) {
        settingsUI.signingIn.remove(id)
        settingsUI.connectionError[id] = nil
    }

    /// Sends site, email and token to the core (which keeps the token in the
    /// Keychain). `done(true)` clears the form; the token is never kept here.
    func connect(_ id: String, site: String, email: String, token: String, done: @escaping (Bool) -> Void) {
        let store = settingsUI
        guard let client else { store.connectionError[id] = "The Distill core is not connected."; done(false); return }
        store.connectionBusy[id] = "Connecting…"
        store.connectionError[id] = nil
        let request = ConnectRequest(site: site.trimmingCharacters(in: .whitespacesAndNewlines),
                                     email: email.trimmingCharacters(in: .whitespacesAndNewlines),
                                     token: token.trimmingCharacters(in: .whitespacesAndNewlines))
        Task {
            defer { store.connectionBusy[id] = nil }
            do {
                let info = try await client.connect(id, request)
                self.applyConnection(info)
                if info.status == .connected {
                    store.signingIn.remove(id)
                    done(true)
                } else {
                    store.connectionError[id] = info.message ?? "Couldn’t sign in. Check the site, email and token."
                    done(false)
                }
            } catch {
                store.connectionError[id] = Self.connectionMessage(error, "Couldn’t sign in")
                done(false)
            }
        }
    }

    func disconnect(_ id: String) {
        let store = settingsUI
        guard let client else { return }
        store.connectionBusy[id] = "Disconnecting…"
        Task {
            defer { store.connectionBusy[id] = nil }
            do { self.applyConnection(try await client.disconnect(id)) } catch {
                store.connectionError[id] = Self.connectionMessage(error, "Couldn’t disconnect")
            }
        }
    }

    /// A short message for the card. Only the core's own message is shown (it never echoes a token).
    static func connectionMessage(_ error: Error, _ prefix: String) -> String {
        if let e = error as? CoreClientError {
            if e.isNotAvailable { return "Update the Distill core to connect accounts." }
            if case .api(_, _, let message) = e { return "\(prefix): \(message)" }
            if e.isUnreachable { return "\(prefix): the Distill core isn’t running." }
        }
        return "\(prefix)."
    }
}

extension Notification.Name {
    /// Object: the Settings section id (see SettingsCatalog).
    static let distillOpenSettingsSection = Notification.Name("distill.openSettingsSection")
}
