import SwiftUI
import DistillKit

// Settings → Connections (canvas: SettingsNav 8, 9). Atlassian is one sign-in
// for Jira and Confluence on one site: "Sign in in your browser" opens the
// API-token page, and the token is pasted here with the site and email. The
// core keeps the token in the Keychain; it never reaches settings.json or logs.

struct ConnectionsSettings: View {
    @ObservedObject var ui: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if ui.connectionsLoad == .unavailable {
                CoreUpdateNote(text: "Update the Distill core to connect Jira and Confluence. Slack messages work without connecting.")
            }
            SlackConnectionCard()
            if ui.connectionsLoad != .unavailable {
                AtlassianConnectionCard(ui: ui, info: ui.connection("atlassian") ?? Self.atlassianPlaceholder,
                                        email: ui.fixtureForm?.email ?? "", token: ui.fixtureForm?.token ?? "")
            }
            Text("Jira and Confluence on the same Atlassian site use one sign-in; signing in to one connects both.")
                .font(Theme.body(12)).foregroundStyle(Theme.muted)
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

    /// The browser page was opened here (or the core says it waits for a sign-in).
    private var signingIn: Bool { ui.signingIn.contains(info.id) || info.status == .signingIn }
    private var busy: String? { ui.connectionBusy[info.id] }
    private var error: String? { ui.connectionError[info.id] }

    var body: some View {
        ConnectionCard {
            ConnectionHeader(tiles: ["jira", "confluence"], title: "Jira and Confluence", subtitle: subtitle) {
                statusPill
                action
            }
        } detail: {
            if signingIn && info.status != .connected {
                signInPanel
            } else if info.status == .error {
                problemPanel(title: "Couldn’t sign in to Atlassian",
                             message: info.message ?? "The browser said access was denied. Nothing changed. You can try again.")
            } else if let error {
                Text(error).font(Theme.body(12)).foregroundStyle(Theme.peachInk)
            }
        }
    }

    private var host: String {
        let s = info.site ?? site
        return s.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private var subtitle: String {
        switch info.status {
        case .connected:
            return [host.isEmpty ? nil : host, info.account.map { "as \($0)" }].compactMap { $0 }.joined(separator: " · ")
        case .expired: return host.isEmpty ? "Sign-in expired" : "\(host) · sign-in expired"
        case .error: return host.isEmpty ? "Couldn’t sign in" : host
        case .signingIn, .notConnected:
            return signingIn && !host.isEmpty ? host : "One sign-in for Jira and Confluence on one Atlassian site"
        }
    }

    @ViewBuilder private var statusPill: some View {
        switch info.status {
        case .connected: StatePill(text: "Connected", systemImage: "checkmark", fill: Theme.limeTint.opacity(0.6), ink: Theme.limeInk)
        case .expired: StatePill(text: "Sign-in expired", systemImage: "exclamationmark", fill: Theme.peachTint, ink: Theme.peachInk)
        case .error: StatePill(text: "Couldn’t sign in", systemImage: "exclamationmark", fill: Theme.peachTint, ink: Theme.peachInk)
        case .signingIn, .notConnected:
            if signingIn {
                HStack(spacing: 5) {
                    Spinner(color: Theme.primary, size: 10)
                    Text("Waiting for browser").font(Theme.body(11, .bold))
                }
                .padding(.horizontal, 9).frame(height: 22)
                .foregroundStyle(Theme.primary)
                .background(Capsule().fill(Theme.primaryTint))
            } else {
                StatePill(text: "Not connected")
            }
        }
    }

    @ViewBuilder private var action: some View {
        switch info.status {
        case .connected:
            SoftButton(title: busy ?? "Disconnect", tint: Theme.peachInk, fill: .clear, size: .small) { engine.disconnect(info.id) }
                .disabled(busy != nil)
        case .error:
            EmptyView() // the problem panel below has Try again
        default:
            if !signingIn {
                PrimaryButton(title: "Sign in in your browser", systemImage: "safari", size: .small) {
                    engine.startSignIn(info.id, site: site.isEmpty ? nil : site)
                }
            }
        }
    }

    private var signInPanel: some View {
        HStack(alignment: .top, spacing: 10) {
            Spinner(color: Theme.primary, size: 12).padding(.top, 3)
            VStack(alignment: .leading, spacing: 8) {
                Text("Finish signing in, in your browser").font(Theme.body(13, .bold)).foregroundStyle(Theme.primary)
                Text("We opened Atlassian’s API token page. Create a token there, then paste it here with your site and email. The token goes to your Keychain.")
                    .font(Theme.body(12)).foregroundStyle(Color(hex: 0x48463F)).fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 6) {
                    field("Site", "https://your-site.atlassian.net", text: $site)
                    field("Email", "you@example.com", text: $email)
                    HStack(spacing: 8) {
                        Text("API token").font(Theme.body(12, .semibold)).foregroundStyle(Theme.muted).frame(width: 70, alignment: .leading)
                        SecureField("", text: $token, prompt: Text("Paste the token").foregroundStyle(Theme.faint))
                            .textFieldStyle(.plain).font(Theme.body(12))
                            .padding(.horizontal, 10).frame(height: 30)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white))
                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
                            .onSubmit(connect)
                    }
                }
                if let error {
                    Text(error).font(Theme.body(12)).foregroundStyle(Theme.peachInk).fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    PrimaryButton(title: busy ?? "Connect", size: .small, enabled: canConnect, action: connect)
                    SoftButton(title: "Open the page again", fill: .white, size: .small, stroke: true, systemImage: "arrow.up.right") {
                        engine.startSignIn(info.id, site: site.isEmpty ? nil : site)
                    }
                    SoftButton(title: "Cancel", size: .small) {
                        token = ""
                        engine.cancelSignIn(info.id)
                    }
                }
            }
        }
        .padding(.horizontal, 13).padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(hex: 0xF2F7FF)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(hex: 0xD6E4FB)))
    }

    private var canConnect: Bool {
        busy == nil && ![site, email, token].contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private func connect() {
        guard canConnect else { return }
        let secret = token
        token = "" // never kept in the view, whatever the answer
        engine.connect(info.id, site: site, email: email, token: secret) { _ in }
    }

    private func field(_ label: String, _ placeholder: String, text: Binding<String>) -> some View {
        HStack(spacing: 8) {
            Text(label).font(Theme.body(12, .semibold)).foregroundStyle(Theme.muted).frame(width: 70, alignment: .leading)
            TextField("", text: text, prompt: Text(placeholder).foregroundStyle(Theme.faint))
                .textFieldStyle(.plain).font(Theme.body(12))
                .padding(.horizontal, 10).frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.white))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
        }
    }

    private func problemPanel(title: String, message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Theme.peachInk).padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(Theme.body(13, .bold)).foregroundStyle(Theme.peachInk)
                Text(message).font(Theme.body(12)).foregroundStyle(Color(hex: 0x48463F)).fixedSize(horizontal: false, vertical: true)
                SoftButton(title: "Try again", fill: .white, size: .small, stroke: true) { engine.startSignIn(info.id, site: site.isEmpty ? nil : site) }
                    .padding(.top, 4)
            }
        }
        .padding(.horizontal, 13).padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(hex: 0xFFF4EE)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(hex: 0xFFD9C5)))
    }
}
