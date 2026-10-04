import SwiftUI
import DistillKit

// Settings → Connections (canvas: SettingsNav 8, 9, 9b). Atlassian is one
// connection for Jira and Confluence on one site. It is connected, or the form
// for site, email and API token is open: there is no "connecting" or
// "waiting for the browser" state. "Get an API token" only opens Atlassian's
// token page. The core checks the token and keeps it in the Keychain; it never
// reaches settings.json or logs.

struct ConnectionsSettings: View {
    @ObservedObject var ui: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if ui.connectionsLoad == .unavailable {
                CoreUpdateNote(text: "Update the Distill core to connect Jira and Confluence. Slack messages work without connecting.")
            }
            SlackConnectionCard().settingsAnchor("Slack")
            if ui.connectionsLoad != .unavailable {
                AtlassianConnectionCard(ui: ui, info: ui.connection("atlassian") ?? Self.atlassianPlaceholder,
                                        email: ui.fixtureForm?.email ?? "", token: ui.fixtureForm?.token ?? "")
                    .settingsAnchor("Atlassian")
            }
        }
    }

    static let atlassianPlaceholder = ConnectionInfo(id: "atlassian", label: "Atlassian", status: .notConnected, usedBy: ["jira", "confluence"])
}

/// The rounded card every connection sits in.
private struct ConnectionCard<Header: View, Detail: View>: View {
    @ViewBuilder var header: Header
    @ViewBuilder var detail: Detail

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            detail
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.white))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.border))
    }
}

private struct ConnectionHeader<Trailing: View>: View {
    let tiles: [String]
    let title: String
    let subtitle: String
    @ViewBuilder var trailing: Trailing

    /// Pill and button keep their full labels. Beside the title while the title
    /// keeps 220 pt; in a narrower window they move under it.
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                tilesView
                titleView.frame(minWidth: 220, maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 12) { trailing }.fixedSize()
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    tilesView
                    titleView.frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: 12) { trailing }.fixedSize()
            }
        }
    }

    private var tilesView: some View {
        HStack(spacing: -8) {
            ForEach(tiles, id: \.self) { ActionTypeTile(id: $0, size: 34).overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white, lineWidth: 2)) }
        }
    }

    private var titleView: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(Theme.body(14, .bold))
            Text(subtitle).font(Theme.body(12)).foregroundStyle(Theme.muted).lineLimit(2)
        }
    }
}

struct SlackConnectionCard: View {
    var body: some View {
        ConnectionCard {
            ConnectionHeader(tiles: ["slack"], title: "Slack", subtitle: "Not needed yet — Copy works without connecting") {
                StatePill(text: "Not connected")
                SoftButton(title: "Connect", tint: Color(hex: 0xB5B1A9), fill: Theme.panel, size: .small, stroke: true, systemImage: "link") {}
                    .disabled(true)
                    .help("Sending in Slack comes later")
            }
        } detail: { EmptyView() }
    }
}

struct AtlassianConnectionCard: View {
    @EnvironmentObject var engine: AppModel
    @ObservedObject var ui: SettingsStore
    let info: ConnectionInfo
    @State private var site: String
    @State private var email: String
    @State private var token: String

    /// `email` / `token` start filled only in snapshots.
    init(ui: SettingsStore, info: ConnectionInfo, email: String = "", token: String = "") {
        self.ui = ui
        self.info = info
        _site = State(initialValue: info.site ?? "")
        _email = State(initialValue: email.isEmpty ? (info.account?.contains("@") == true ? info.account! : "") : email)
        _token = State(initialValue: token)
    }

    /// Connected, or not: expired, a denied sign-in and an older core's
    /// "signing in" all read as not connected, with the token form open.
    private var connected: Bool { info.status == .connected }
    private var busy: Bool { ui.connectionBusy.contains(info.id) }
    private var problem: ConnectionProblem? { ui.connectionError[info.id] }

    var body: some View {
        ConnectionCard {
            ConnectionHeader(tiles: ["jira", "confluence"], title: "Jira and Confluence", subtitle: subtitle) {
                if connected {
                    StatePill(text: "Connected", systemImage: "checkmark", fill: Theme.limeTint.opacity(0.6), ink: Theme.limeInk)
                    SoftButton(title: "Disconnect", tint: Theme.peachInk, fill: .clear, size: .small) { engine.disconnect(info.id) }
                        .disabled(busy)
                } else {
                    StatePill(text: "Not connected")
                }
            }
        } detail: {
            if connected {
                if let problem { problemBanner(problem).padding(.leading, 46) }
            } else {
                tokenForm.padding(.leading, 46)
            }
        }
    }

    private var host: String {
        let s = info.site ?? site
        return s.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private var subtitle: String {
        if connected {
            return [host.isEmpty ? nil : host, info.account.map { "as \($0)" }].compactMap { $0 }.joined(separator: " · ")
        }
        if info.status == .expired { return host.isEmpty ? "The token stopped working; paste a new one" : "\(host) · the token stopped working; paste a new one" }
        return "One connection for Jira and Confluence on one Atlassian site"
    }

    /// Canvas SettingsNav 9 and 9b: open whenever it isn't connected. Connect
    /// turns on once all three are filled; a refusal keeps what was typed.
    private var tokenForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            field("Site", "https://your-site.atlassian.net", text: $site)
            field("Email", "you@example.com", text: $email)
            HStack(spacing: 12) {
                label("API token")
                SecureField("", text: $token, prompt: Text("Paste the token").foregroundStyle(Theme.faint))
                    .textFieldStyle(.plain).font(Theme.body(13))
                    .padding(.horizontal, 10).frame(height: 30)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Color.white))
                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.border))
                    .onSubmit(connect)
            }
            if let problem { problemBanner(problem) }
            HStack(spacing: 8) {
                PrimaryButton(title: "Connect", size: .small, enabled: canConnect, action: connect)
                SoftButton(title: "Get an API token", fill: .white, size: .small, stroke: true, systemImage: "arrow.up.right") {
                    engine.openTokenPage(info.id, site: site.isEmpty ? nil : site)
                }
                .help("Opens Atlassian’s API token page in your browser")
            }
            .padding(.leading, 92)
        }
    }

    private var canConnect: Bool {
        !busy && ![site, email, token].contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private func connect() {
        guard canConnect else { return }
        // The token stays in the form only until Atlassian accepts it; it is
        // never written anywhere but the Keychain (by the core).
        engine.connect(info.id, site: site, email: email, token: token) { ok in
            if ok { token = "" }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text).font(Theme.body(13, .semibold)).foregroundStyle(Theme.muted).frame(width: 80, alignment: .leading)
    }

    private func field(_ name: String, _ placeholder: String, text: Binding<String>) -> some View {
        HStack(spacing: 12) {
            label(name)
            TextField("", text: text, prompt: Text(placeholder).foregroundStyle(Theme.faint))
                .textFieldStyle(.plain).font(Theme.body(13))
                .padding(.horizontal, 10).frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color.white))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.border))
        }
    }

    private func problemBanner(_ problem: ConnectionProblem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Theme.peachInk).padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text(problem.title).font(Theme.body(13, .bold)).foregroundStyle(Theme.peachInk)
                    .fixedSize(horizontal: false, vertical: true)
                if !problem.detail.isEmpty {
                    Text(problem.detail).font(Theme.body(12)).foregroundStyle(Color(hex: 0x48463F)).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 13).padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(hex: 0xFFF4EE)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(hex: 0xFFD9C5)))
    }
}
