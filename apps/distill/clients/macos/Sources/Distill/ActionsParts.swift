import AppKit
import SwiftUI
import DistillKit

// Shared pieces of the Actions screens (canvas row 6: ActionsTodo, ActionsSlack,
// ActionsJira, ActionsConfluence, ActionsHistory, ActionsAsk).

enum ActionsTheme {
    static let selectedFill = Color(hex: 0xF2F7FF)
    static let selectedStroke = Color(hex: 0xBFD5FA)
    static let ring = Color(hex: 0xB5B1A9)
    static let quoteBar = Color(hex: 0xD6D3CC)
    static let medium = Color(hex: 0xB7791F)
    static let doneFill = Color(hex: 0xF3FDE4)
    static let changedFill = Color(hex: 0xF3FDE4)

    /// Icon tile per type: (SF symbol, fill, ink), as the canvas ActionRow draws them.
    static func typeStyle(_ id: String) -> (String, Color, Color) {
        switch id {
        case "todo": return ("checkmark.circle", Theme.primaryTint, Theme.primary)
        case "slack": return ("text.bubble", Theme.pinkTint, Theme.pinkInk)
        case "jira": return ("ticket", Theme.skyTint, Theme.skyInk)
        case "confluence": return ("doc.text", Theme.limeTint, Theme.limeInk)
        case "email": return ("envelope", Theme.peachTint, Theme.peachInk)
        default: return ("bolt", Theme.peachTint, Theme.peachInk)
        }
    }

    static func personColors(_ name: String) -> (Color, Color) {
        if name.hasPrefix("You") { return (Theme.limeTint, Theme.limeInk) }
        let i = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF } % 3
        return [(Theme.pinkTint, Theme.pinkInk), (Theme.skyTint, Theme.skyInk), (Theme.peachTint, Theme.peachInk)][i]
    }

    static func priorityInk(_ p: String?) -> Color {
        switch p?.lowercased() {
        case "high": return Theme.peachInk
        case "medium": return medium
        default: return Theme.faint
        }
    }
}

// MARK: Buttons

/// The 32 pt (or 30 / 26) capsule buttons of the Actions boards.
struct ActionButton: View {
    enum Kind { case primary, soft, done, plain }
    let title: String
    var icon: String? = nil
    var kind: Kind = .soft
    var height: CGFloat = 32
    var trailing: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let icon { Image(systemName: icon).font(.system(size: height < 30 ? 10 : 11, weight: .bold)) }
                Text(title).font(Theme.body(height < 30 ? 12 : 13, .semibold)).lineLimit(1)
                if let trailing { Text(trailing).font(Theme.body(10, .bold)).foregroundStyle(Theme.faint) }
            }
            .fixedSize()
            .padding(.horizontal, height < 30 ? 12 : 16).frame(height: height)
            .foregroundStyle(ink)
            .background(Capsule().fill(fill))
            .overlay(Capsule().strokeBorder(stroke, lineWidth: 1))
            .shadow(color: kind == .primary ? Theme.primary.opacity(0.25) : .clear, radius: 6, y: 4)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var fill: Color {
        switch kind { case .primary: Theme.primary; case .soft: .white; case .done: ActionsTheme.doneFill; case .plain: Theme.panel }
    }
    private var ink: Color {
        switch kind { case .primary: .white; case .soft, .plain: Theme.ink; case .done: Theme.limeInk }
    }
    private var stroke: Color {
        switch kind { case .primary, .plain: .clear; case .soft: Theme.border; case .done: Theme.lime }
    }
}

/// A disabled dashed slot for a handler that comes later ("Send in Slack · Later").
struct LaterSlot: View {
    let title: String
    var icon = "paperplane"

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: icon).font(.system(size: 11, weight: .bold))
            Text(title).font(Theme.body(13, .semibold))
            Text("Later").font(Theme.body(10, .bold)).foregroundStyle(Theme.faint)
        }
        .fixedSize()
        .foregroundStyle(ActionsTheme.ring)
        .padding(.horizontal, 14).frame(height: 32)
        .overlay(Capsule().strokeBorder(ActionsTheme.quoteBar, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])))
        .help("Coming later")
    }
}

// MARK: Small labels

/// Status pills on the Actions boards: the shared Pill, small.
struct StatusBadge: View {
    let text: String
    var fill: Color = Theme.panel
    var ink: Color = Theme.softInk
    var icon: String? = nil
    var busy = false

    var body: some View {
        Pill(text: text, fill: fill, ink: ink, size: .small, systemImage: icon, busy: busy)
    }
}

struct PersonChip: View {
    let name: String
    var size: CGFloat = 16
    var showName = true
    var short = true

    var body: some View {
        let colors = ActionsTheme.personColors(name)
        HStack(spacing: 5) {
            Text(ActionText.initials(name)).font(.system(size: size * 0.56, weight: .bold)).foregroundStyle(colors.1)
                .frame(width: size, height: size).background(Circle().fill(colors.0))
            if showName {
                Text(short ? (name.hasPrefix("You") ? "You" : String(name.split(separator: " ").first ?? "")) : name)
                    .lineLimit(1)
            }
        }
        .fixedSize()
    }
}

struct LabelTag: View {
    let name: String
    var size: CGFloat = 11
    var body: some View {
        Text("#\(name)").font(Theme.body(size, .semibold)).foregroundStyle(Theme.limeInk).lineLimit(1).fixedSize()
    }
}

struct PriorityTag: View {
    let priority: String
    var size: CGFloat = 11
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "flag.fill").font(.system(size: size - 2))
            Text(priority).font(Theme.body(size, .semibold))
        }
        .foregroundStyle(ActionsTheme.priorityInk(priority))
        .fixedSize()
    }
}

struct DueBadge: View {
    let due: String
    var now = Date()

    var body: some View {
        let bucket = ActionDue.bucket(due, now: now)
        let (fill, ink): (Color, Color) = switch bucket {
        case .overdue: (Theme.peachTint, Theme.peachInk)
        case .today: (Theme.primaryTint, Theme.primary)
        default: (Theme.panel, Theme.softInk)
        }
        if let text = ActionDue.short(due, now: now) {
            StatusBadge(text: text, fill: fill, ink: ink, icon: "calendar")
        }
    }
}

/// Group header in a list: "OVERDUE 1".
struct ActionGroupHeader: View {
    let title: String
    let count: Int
    var icon: String? = nil
    var ink: Color = Theme.faint

    var body: some View {
        HStack(spacing: 6) {
            if let icon { Image(systemName: icon).font(.system(size: 9, weight: .bold)) }
            Text(title).font(Theme.body(10, .heavy)).kerning(0.6)
            Text("\(count)").font(Theme.body(10, .bold)).foregroundStyle(Theme.faint)
        }
        .foregroundStyle(ink)
        .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: Header and filters

/// "ACTIONS / To do / Found in your notes · last found today at 3:44 PM in Tea club planning", with buttons.
struct ActionsHeader<Buttons: View>: View {
    let eyebrow: String
    let title: String
    var subtitle: (Date, String?)? = nil
    @ViewBuilder var buttons: Buttons

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(eyebrow).font(Theme.body(11, .heavy)).kerning(0.6).foregroundStyle(Theme.faint)
                Text(title).font(Theme.display(30)).lineLimit(1)
                if let (date, note) = subtitle {
                    (Text("Found in your notes · last found \(HistoryTime.phrase(date))")
                     + (note.map { Text(" in ") + Text($0).fontWeight(.semibold).foregroundColor(Theme.ink) } ?? Text("")))
                        .font(Theme.body(13)).foregroundStyle(Theme.muted).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            buttons
        }
        .padding(.horizontal, 32).padding(.top, 28)
    }
}

/// The search field of a filter row.
struct ActionSearchField: View {
    @Binding var text: String
    var placeholder: String
    var width: CGFloat = 190

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.faint)
            TextField(placeholder, text: $text).textFieldStyle(.plain).font(Theme.body(12))
                .onExitCommand { text = "" }
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(Theme.faint) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10).frame(width: width, height: 30)
        .background(Capsule().fill(Theme.panel))
    }
}

/// A filter chip: "Due ▾" while unused, "Due: Today, This week ▾ ×" in blue once set.
struct FilterMenuChip<Panel: View>: View {
    let title: String
    var value: String? = nil
    var onClear: (() -> Void)? = nil
    @Binding var open: Bool
    @ViewBuilder var panel: Panel

    var body: some View {
        HStack(spacing: 5) {
            Button { open.toggle() } label: {
                HStack(spacing: 5) {
                    Text(value.map { "\(title): \($0)" } ?? title).font(Theme.body(12, value == nil ? .semibold : .bold)).lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                }
                .fixedSize()
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if value != nil, let onClear {
                Button(action: onClear) { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).frame(width: 16, height: 16) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.leading, 10).padding(.trailing, value == nil ? 10 : 6).frame(height: 28)
        .foregroundStyle(value == nil ? Theme.softInk : Theme.primary)
        .background(Capsule().fill(value == nil ? Color.clear : Theme.primaryTint))
        .overlay(Capsule().strokeBorder(value == nil ? Theme.border : .clear))
        .overlay(alignment: .topLeading) {
            if open {
                panel.offset(y: 34).zIndex(10)
            }
        }
        .zIndex(open ? 10 : 0)
    }
}

/// The floating panel used by chips and menus (renders in snapshots too, unlike NSMenu).
struct ActionMenuPanel<Content: View>: View {
    var title: String? = nil
    var width: CGFloat = 240
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let title {
                Text(title).font(Theme.body(10, .heavy)).kerning(0.6).foregroundStyle(Theme.faint)
                    .padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 4)
            }
            content
        }
        .padding(6)
        .frame(width: width, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white)
            .shadow(color: .black.opacity(0.14), radius: 14, y: 8))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.border))
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct ActionMenuRow: View {
    let title: String
    var detail: String? = nil
    var icon: String? = nil
    var iconStyle: (Color, Color)? = nil
    var checked = false
    var badge: String? = nil
    var disabled = false
    var trailing: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let icon {
                    if let iconStyle {
                        Image(systemName: icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(iconStyle.1)
                            .frame(width: 26, height: 26).background(RoundedRectangle(cornerRadius: 8).fill(iconStyle.0))
                    } else {
                        Image(systemName: icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.muted).frame(width: 16)
                    }
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(Theme.body(13, .semibold)).lineLimit(1)
                    if let detail { Text(detail).font(Theme.body(11)).foregroundStyle(Theme.muted).lineLimit(1) }
                }
                Spacer(minLength: 6)
                if let trailing { Text(trailing).font(Theme.body(11)).foregroundStyle(Theme.faint) }
                if let badge { StatusBadge(text: badge, fill: disabled ? Theme.panel : Theme.primaryTint, ink: disabled ? Theme.faint : Theme.primary) }
                if checked { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.primary) }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .opacity(disabled ? 0.55 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}

// MARK: Context

/// FROM <note> · time / “quote” / Why: … / Found by Sonnet · Created …
struct ActionContextBlock: View {
    @EnvironmentObject var engine: AppModel
    let item: ActionItem
    var showFoundLine = true
    /// actions-routing.md (Pending detail): the full "FROM THE ORIGINAL" header with its caption, no FROM row.
    var full = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if !full || item.context.isEmpty {
                HStack(spacing: 8) {
                    Text("FROM").font(Theme.body(10, .heavy)).kerning(0.5).foregroundStyle(Theme.faint)
                    source
                }
            }
            if !item.context.isEmpty {
                // v11 (action-context.md): the original's lines and the wiki section, each with Open.
                ActionContextSections(item: item, compact: !full)
            } else if let quote = item.source.quote, !quote.isEmpty {
                Text("“\(quote)”").font(Theme.body(12).italic()).foregroundStyle(Theme.softInk)
                    .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 10).padding(.vertical, 2)
                    .overlay(alignment: .leading) { Rectangle().fill(ActionsTheme.quoteBar).frame(width: 3) }
            }
            if let why = item.why, !why.isEmpty {
                (Text("Why: ").fontWeight(.bold).foregroundColor(Theme.ink) + Text(why))
                    .font(Theme.body(12)).foregroundStyle(Theme.softInk).fixedSize(horizontal: false, vertical: true)
            }
            if case .ask(_, _, _, let cited, _, _) = item.source, let first = cited.first {
                HStack(spacing: 5) {
                    Image(systemName: "doc.text").font(.system(size: 10))
                    Text("Answer cites").foregroundStyle(Theme.muted)
                    Text(((first as NSString).lastPathComponent as NSString).deletingPathExtension).fontWeight(.semibold).foregroundStyle(Theme.primary)
                }
                .font(Theme.body(11))
            }
            if showFoundLine {
                HStack(spacing: 6) {
                    Image(systemName: item.source.isManual ? "person" : "sparkle").font(.system(size: 10))
                    Text(foundLine).lineLimit(1)
                }
                .font(Theme.body(11)).foregroundStyle(Theme.muted)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.panel))
    }

    @ViewBuilder private var source: some View {
        let when = HistoryTime.phrase(sourceDate)
        switch item.source {
        case .note(_, let path, _, _):
            Button { openNote(path) } label: {
                (Text(Image(systemName: "doc.text")).foregroundColor(Theme.primary) + Text(" ")
                 + Text(ActionList.noteTitle(item) ?? "Note").fontWeight(.semibold).foregroundColor(Theme.primary)
                 + Text(" · \(when)").foregroundColor(Theme.muted))
                .font(Theme.body(12)).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.primary)
        case .ask(let id, _, _, _, _, _):
            let exists = engine.ask.conversations.contains { $0.id == id } || engine.ask.main.conversationID == id
            Button { if exists { engine.ask.open(conversationID: id); engine.ask.showAskRequest += 1 } } label: {
                HStack(spacing: 5) {
                    Image(systemName: "bubble.left").font(.system(size: 10, weight: .semibold))
                    Text("Ask chat").fontWeight(.semibold).foregroundStyle(exists ? Theme.primary : Theme.softInk)
                    Text(" · \(when)").foregroundStyle(Theme.muted)
                }
                .font(Theme.body(12)).lineLimit(1)
            }
            .buttonStyle(.plain)
            .help(exists ? "Open the chat" : "The chat is no longer in History; the quoted lines are kept")
        default:
            Text("Added by you · \(when)").font(Theme.body(12)).foregroundStyle(Theme.muted)
        }
    }

    private var sourceDate: Date { item.events.first?.at ?? item.createdAt }

    private var foundLine: String {
        let created = "Created \(HistoryTime.phrase(item.createdAt))"
        switch item.source {
        case .manual: return "Added by you · \(created)"
        case .agent: return "Added by an agent · \(created)"
        default:
            // The stored detail is already "by Sonnet"; never "Found by by Sonnet".
            let model = item.lastEvent("found")?.detail ?? item.draftModel ?? "Sonnet"
            let by = model.hasPrefix("by ") ? model : "by \(model)"
            return "Found \(by) · \(created)"
        }
    }

    private func openNote(_ path: String?) {
        guard let path, let vault = item.vaultPath ?? engine.activeVault?.path else { return }
        let full = path.hasPrefix("/") ? path : URL(fileURLWithPath: vault).appendingPathComponent(path).path
        guard FileManager.default.fileExists(atPath: full) else { return }
        var components = URLComponents(string: "obsidian://open")!
        components.queryItems = [URLQueryItem(name: "path", value: full)]
        if let url = components.url, NSWorkspace.shared.urlForApplication(toOpen: url) != nil { NSWorkspace.shared.open(url) }
        else { NSWorkspace.shared.open(URL(fileURLWithPath: full)) }
    }
}

// MARK: States

/// Shown while a draft is written or improved: the model, and Cancel.
struct ActionRunLine: View {
    let title: String
    var cancel: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 10) {
            Spinner(size: 14)
            Text(title).font(Theme.body(13, .semibold)).foregroundStyle(Theme.ink)
            Spacer(minLength: 8)
            if let cancel {
                Button("Cancel", action: cancel).buttonStyle(.plain).font(Theme.body(12, .semibold))
                    .padding(.horizontal, 12).frame(height: 28).background(Capsule().fill(Color.white))
            }
        }
    }
}

/// A peach (or blue / green) callout with a title, text and buttons.
struct ActionCallout<Buttons: View>: View {
    var icon: String = "exclamationmark.circle.fill"
    var tint: Color = Theme.peachInk
    var fill: Color = Theme.gapFill
    let title: String
    var text: String? = nil
    @ViewBuilder var buttons: Buttons

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).font(.system(size: 14, weight: .semibold)).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(Theme.body(13, .bold)).fixedSize(horizontal: false, vertical: true)
                if let text { Text(text).font(Theme.body(12)).foregroundStyle(Theme.softInk).fixedSize(horizontal: false, vertical: true) }
                HStack(spacing: 8) { buttons }.padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(fill))
    }
}

/// Bottom toast: "Completed “…”  Undo  History".
struct ActionToastView: View {
    let toast: ActionToast
    var openHistory: () -> Void
    var dismiss: () -> Void
    /// ⌘Z undoes the toast's action, except while an editor is open (its own Undo wins).
    var undoShortcut = true

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 13)).foregroundStyle(Theme.lime)
            Text(toast.text).font(Theme.body(13, .semibold)).foregroundStyle(.white).lineLimit(1)
            if let undo = toast.undo {
                Button("Undo") { undo(); dismiss() }.buttonStyle(.plain).font(Theme.body(13, .bold)).foregroundStyle(Color(hex: 0x9CC2FF))
                    .keyboardShortcut(undoShortcut ? KeyboardShortcut("z", modifiers: .command) : nil)
            }
            if let open = toast.open {
                Button(toast.openTitle) { open(); dismiss() }.buttonStyle(.plain).font(Theme.body(13, .bold)).foregroundStyle(Color(hex: 0x9CC2FF))
            }
            if toast.history {
                Button("History") { openHistory(); dismiss() }.buttonStyle(.plain).font(Theme.body(13, .bold)).foregroundStyle(Color(hex: 0x9CC2FF))
            }
        }
        .padding(.horizontal, 18).frame(height: 42)
        .background(Capsule().fill(Theme.ink).shadow(color: .black.opacity(0.2), radius: 12, y: 6))
        .padding(.bottom, 22)
    }
}

/// Shimmer rows while the first load runs (never an empty state).
struct ActionShimmerRows: View {
    var count = 5
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(0..<count, id: \.self) { i in
                HStack(spacing: 12) {
                    Shimmer(width: 18, height: 18, radius: 9)
                    VStack(alignment: .leading, spacing: 6) {
                        Shimmer(width: [300, 240, 330, 210, 280][i % 5], height: 12)
                        Shimmer(width: [170, 140, 190, 120, 150][i % 5], height: 9)
                    }
                    Spacer()
                    Shimmer(width: 56, height: 22, radius: 11)
                }
                .padding(.horizontal, 12)
            }
        }
        .padding(.top, 14)
    }
}

/// "Finding actions in 2 notes with Sonnet… · Started at 3:43 PM".
struct FindingStrip: View {
    let title: String
    let start: Date

    var body: some View {
        HStack(spacing: 10) {
            Spinner(size: 15)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.body(13, .bold))
                Text("Started at \(ActionsClock.time(start))").font(Theme.body(11)).foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.primaryTint))
    }
}

enum ActionsClock {
    /// "3:43 PM" (the Mac's 12/24-hour setting).
    static func time(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f.string(from: date)
    }
}

/// Calm full-screen states: empty, update the core, type turned off.
struct ActionsEmpty<Buttons: View>: View {
    var icon = "checklist"
    /// The icon tile: (fill, ink); a type's own colours on its tab.
    var colors: (Color, Color) = (Theme.limeTint, Theme.limeInk)
    let title: String
    let message: String
    @ViewBuilder var buttons: Buttons

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 22, weight: .semibold)).foregroundStyle(colors.1)
                .frame(width: 52, height: 52).background(RoundedRectangle(cornerRadius: 16).fill(colors.0))
            Text(title).font(.system(size: 20, weight: .semibold, design: .rounded))
            Text(message).font(Theme.body(14)).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) { buttons }.padding(.top, 4)
        }
        .frame(maxWidth: 380)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The job's actions line (History → Jobs, Review once applied): "Found 5 actions to
/// confirm · 3 to-dos, 1 Slack message, 1 Jira ticket · Review them"; while the step
/// runs, the loading pattern; when it failed, Try again.
struct JobActionsLine: View {
    @EnvironmentObject var engine: AppModel
    let job: Job
    let summary: JobActionsSummary

    var body: some View {
        // v11: while the batch waits in Review, its "Actions found" group shows them (ReviewActionsFound).
        if summary.foundInBatch && job.state == .awaitingApproval { EmptyView() } else { line }
    }

    /// "2 already in Actions" for a re-read or repair (v11).
    private var duplicatesText: String {
        guard let d = summary.duplicates, d > 0 else { return "" }
        return " · \(d) already in Actions"
    }

    @ViewBuilder private var line: some View {
        let store = engine.actions
        switch summary.status {
        case "finding":
            let p = engine.progress[job.id]
            let n = max(1, job.files.filter { !$0.hasSuffix(QueueRows.manifestSuffix) }.count)
            HStack(spacing: 10) {
                Spinner(size: 15)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Finding actions in \(n == 1 ? "1 note" : "\(n) notes")…").font(Theme.body(13, .bold))
                    Text("\(ModelChoice.shortName(p?.model ?? summary.model ?? "sonnet")) · started at \(ActionsClock.time(p?.startedAt ?? job.updatedAt)) · \(summary.foundInBatch ? "while the batch was read" : "after the batch was applied")")
                        .font(Theme.body(11)).foregroundStyle(Theme.muted)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
            .background(RoundedRectangle(cornerRadius: 14).fill(Theme.primaryTint))
        case "failed":
            ActionCallout(title: "Couldn't find actions in \(job.displayTitle)",
                          text: "\(summary.error ?? "The action step failed.") The changes were applied; only the action step failed.") {
                ActionButton(title: "Try again", kind: .soft, height: 28) { store.findAgain(jobID: job.id) }
            }
        default:
            if let line = ActionCounts.jobLine(summary) {
                HStack(spacing: 10) {
                    Image(systemName: "checklist").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.primary)
                        .frame(width: 30, height: 30).background(RoundedRectangle(cornerRadius: 9).fill(Theme.primaryTint))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(summary.pending > 0 ? line : "Added \(ActionCounts.phrase(summary.byType, types: store.types))").font(Theme.body(13, .bold))
                        Text(ActionCounts.phrase(summary.byType, types: store.types) + duplicatesText).font(Theme.body(12)).foregroundStyle(Theme.muted)
                    }
                    Spacer(minLength: 8)
                    ActionButton(title: summary.pending > 0 ? "Review them" : "Open in Actions", kind: .soft, height: 30) { store.openJob(job.id) }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.border))
            }
        }
    }
}
