import AppKit
import SwiftUI
import DistillKit

/// History → Activity (canvas row 8, board Activity): what changed, when, and
/// from where. The header and the Actions toolbar over a day-grouped list, with
/// the selected entry's detail on the right. In a narrow window the list takes
/// the width and an entry's detail is pushed in its place ("‹ Activity").
struct ActivityScreen: View {
    @EnvironmentObject var engine: AppModel

    var body: some View {
        ActivityScreenContent(store: engine.activity)
    }
}

/// What snapshots pin (the app leaves these to the window and the pointer).
struct ActivityScreenUI {
    /// Draw the Filter panel in place instead of a popover.
    var inlinePanel = false
    /// The chips shown before "+N"; nil: as many as fit.
    var visibleChips: Int?
}

struct ActivityScreenContent: View {
    @EnvironmentObject var engine: AppModel
    @ObservedObject var store: ActivityStore
    var ui = ActivityScreenUI()

    /// Under this width the detail column gives way to a pushed detail, so the list keeps about 480 pt
    /// for a summary plus its tag and "time · source" (a 1200 pt window is 980 here; 900 pt is 680).
    static let narrowWidth: CGFloat = 920

    var body: some View {
        GeometryReader { geo in
            content(narrow: geo.size.width < Self.narrowWidth)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
        }
        .onAppear { if store.phase == .idle { store.load() } }
    }

    @ViewBuilder private func content(narrow: Bool) -> some View {
        switch store.phase {
        case .unavailable:
            VStack(spacing: 0) {
                header
                ActionsEmpty(icon: "arrow.triangle.2.circlepath", colors: (Theme.panel, Theme.muted), title: "Update the Distill core",
                             message: "This core doesn't keep an activity log yet. Update Distill (distill.sh update) and it shows up here.") {
                    EmptyView()
                }
            }
        case .failed(let message):
            VStack(spacing: 0) {
                header
                ActionsEmpty(icon: "exclamationmark.triangle", colors: (Theme.peachTint, Theme.peachInk), title: "Couldn't load activity", message: message) {
                    ActionButton(title: "Try again", icon: "arrow.clockwise", kind: .primary) { store.load() }
                }
            }
        case .idle, .loading:
            VStack(alignment: .leading, spacing: 0) {
                header
                VStack(spacing: 6) {
                    ForEach(0..<6, id: \.self) { _ in Shimmer(height: 28, radius: 8) }
                }
                .padding(.horizontal, 32).padding(.top, 28)
                Spacer(minLength: 0)
            }
        case .loaded:
            if store.entries.isEmpty && !store.filter.isActive {
                VStack(spacing: 0) {
                    header
                    ActivityEmpty()
                    Spacer(minLength: 0)
                }
            } else if narrow, store.pushed, let entry = store.current {
                Scrolling {
                    ActivityDetail(store: store, entry: entry, pushed: true)
                        .padding(.horizontal, 28).padding(.top, 26).padding(.bottom, 20)
                }
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    toolbar(narrow: narrow)
                        .padding(.horizontal, 32).padding(.top, 18)
                        .zIndex(5)
                    Rectangle().fill(Theme.border).frame(height: 1).padding(.top, 14)
                    HStack(spacing: 0) {
                        if store.entries.isEmpty {
                            ActivityNoMatches(store: store)
                        } else {
                            list(narrow: narrow)
                            if !narrow, let entry = store.current {
                                Rectangle().fill(Theme.border).frame(width: 1)
                                Scrolling {
                                    ActivityDetail(store: store, entry: entry, pushed: false)
                                        .padding(.leading, 24).padding(.trailing, 26).padding(.top, 22).padding(.bottom, 20)
                                }
                                .frame(width: 400)
                            }
                        }
                    }
                    .frame(maxHeight: .infinity, alignment: .top)
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Activity").font(Theme.display(30)).lineLimit(1)
            Text("What changed, when, and from where. Kept on this Mac.").font(Theme.body(13)).foregroundStyle(Theme.muted).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 32).padding(.top, 30)
    }

    private func toolbar(narrow: Bool) -> some View {
        ActionsToolbar(search: $store.filter.text, placeholder: "Search activity", searchWidth: narrow ? 160 : 220,
                       chips: store.filter.chips, visibleChips: ui.visibleChips, right: .none,
                       panel: $store.panel, inlinePanel: ui.inlinePanel,
                       removeChip: { store.filter.remove($0) },
                       sortItems: { EmptyView() },
                       panelContent: { _ in ActivityFilterPanel(store: store) })
    }

    private func list(narrow: Bool) -> some View {
        let current = narrow ? nil : store.current?.id
        return Scrolling {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(store.groups) { group in
                    Text(group.title).font(Theme.body(10, .heavy)).kerning(0.6).foregroundStyle(Theme.faint)
                        .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 2)
                    ForEach(group.entries) { e in
                        ActivityRow(family: e.family, summary: e.summary, time: store.text.clock(e.at), source: store.text.source(e.source),
                                    outcome: e.failed ? "failed" : "ok", tag: store.tag(e), selected: e.id == current) {
                            store.select(e, narrow: narrow)
                        }
                        .help(e.summary)
                    }
                }
                if store.nextCursor != nil {
                    HStack {
                        Spacer()
                        if store.loadingMore { Spinner(size: 12) } else {
                            LinkButton(title: "Show older") { store.loadMore() }
                        }
                        Spacer()
                    }
                    .padding(.top, 8)
                    .onAppear { store.loadMore() }
                }
            }
            .padding(.top, 4).padding(.leading, 22).padding(.trailing, 14).padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Detail

/// One entry: what happened, when and from where; how to get it back; what was there.
struct ActivityDetail: View {
    @EnvironmentObject var engine: AppModel
    @ObservedObject var store: ActivityStore
    let entry: ActivityEntry
    /// Narrow window: drawn in place of the list, with "‹ Activity".
    var pushed = false

    var body: some View {
        let facts = store.text.facts(entry, now: store.now, vaultName: store.vaultName)
        VStack(alignment: .leading, spacing: 18) {
            if pushed {
                Button { store.back() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left").font(.system(size: 12, weight: .bold))
                        Text("Activity").font(Theme.body(13, .semibold))
                    }
                    .foregroundStyle(Theme.primary).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: [])
                .help("Back to the list")
            }
            title
            card
            factsView(facts)
            links
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var title: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: ActivityRow.icon(entry.family))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(entry.failed ? Theme.peachInk : Theme.muted)
                .frame(width: 36, height: 36)
                .background(RoundedRectangle(cornerRadius: 11).fill(entry.failed ? Theme.peachTint : Theme.panel))
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.summary).font(Theme.display(19)).fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Text(store.text.detailLine(entry, now: store.now)).font(Theme.body(12.5)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Cards

    @ViewBuilder private var card: some View {
        if entry.failed {
            failedCard
        } else if let state = store.recovery(entry) {
            switch state {
            case .inTrash(let id, let expiresAt, let hours):
                cardBox(fill: Theme.panel, ring: Theme.panel) {
                    HStack(spacing: 8) {
                        Image(systemName: "trash").font(.system(size: 13, weight: .semibold))
                        Text(expiresAt.map { "In Distill’s trash until \(store.text.date($0, now: store.now))" } ?? "In Distill’s trash")
                            .font(Theme.body(14, .bold))
                    }
                    .foregroundStyle(Theme.ink)
                    cardText(trashText, ink: Theme.softInk)
                    HStack(spacing: 10) {
                        let busy = store.restoring.contains(id)
                        PrimaryButton(title: busy ? "Restoring…" : "Restore", systemImage: "arrow.uturn.backward", size: .small, enabled: !busy) {
                            store.restore(entry)
                        }
                        .fixedSize()
                        Text(store.text.kept(hours: hours)).font(Theme.body(11.5)).foregroundStyle(Theme.faint)
                    }
                    if let error = store.restoreErrors[id] { cardText(error, ink: Theme.peachInk) }
                }
            case .restored(let at, let objectID):
                cardBox(fill: ActionsTheme.doneFill, ring: Theme.limeTint) {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark").font(.system(size: 13, weight: .bold))
                        Text(store.text.day(at, now: store.now) == "Today" ? "Restored at \(store.text.clock(at))"
                             : "Restored \(store.text.date(at, now: store.now)) at \(store.text.clock(at))")
                            .font(Theme.body(14, .bold))
                    }
                    .foregroundStyle(Theme.limeInk)
                    cardText(restoredText, ink: Theme.softInk)
                    if entry.family == "chat" || entry.family == "collector" {
                        SoftButton(title: entry.family == "chat" ? "Open chat" : "Open collector", fill: .white, size: .small, stroke: true,
                                   systemImage: "arrow.up.right.square") { store.open(entry, objectID: objectID) }
                            .fixedSize()
                            .disabled(!store.canOpen(entry, objectID: objectID))
                    }
                }
            case .trashGone(let expiresAt):
                cardBox(fill: .white, ring: Theme.border) {
                    Text("No longer in Distill’s trash").font(Theme.body(13.5, .bold))
                    cardText(expiresAt.map { $0 <= store.now ? "The copy was kept until \(store.text.date($0, now: store.now))." : nil }
                             .flatMap { $0 } ?? "It was restored or removed somewhere else.", ink: Theme.muted)
                }
            case .macosTrash(let path):
                cardBox(fill: Theme.panel, ring: Theme.panel) {
                    Text("Moved to the macOS Trash").font(Theme.body(13.5, .bold))
                    cardText("As “\((path as NSString).lastPathComponent)” (a numbered name if one was taken).", ink: Theme.muted)
                    SoftButton(title: "Show in Finder", fill: .white, size: .small, stroke: true) { store.showInFinder(path) }
                        .fixedSize()
                }
            case .none(let reason):
                cardBox(fill: .white, ring: Theme.border) {
                    Text("No copy was kept").font(Theme.body(13.5, .bold))
                    cardText(noneText(reason), ink: Theme.muted)
                    if entry.family == "chat" {
                        LinkButton(title: "Ask history settings") { store.openAskSettings() }.padding(.leading, -8)
                    }
                }
            }
        }
    }

    private var failedCard: some View {
        let run = entry.type == "collector.run"
        let exit = entry.int("exitCode"), ms = entry.number("durationMs")
        let title: String = {
            if run, let exit {
                return "The script stopped with exit code \(exit)" + (ms.map { " after \(Self.seconds($0))" } ?? "")
            }
            return entry.error ?? "It didn’t work"
        }()
        var body: [String] = []
        if run && entry.strings("filesAdded").isEmpty { body.append("Nothing was added to the queue.") }
        // The title already says the exit code; a bare "exit 1" error would repeat it.
        if let error = entry.error, error != title, !(run && exit != nil && error.hasPrefix("exit ")) { body.append(error) }
        return cardBox(fill: Theme.gapFill, ring: Theme.peachTint) {
            Text(title).font(Theme.body(13, .bold)).foregroundStyle(Theme.peachInk).fixedSize(horizontal: false, vertical: true)
            if !body.isEmpty { cardText(body.joined(separator: " "), ink: Theme.softInk) }
            if run {
                SoftButton(title: "Open run log", fill: .white, size: .small, stroke: true, systemImage: "list.bullet") {
                    store.open(entry, objectID: nil, runs: true)
                }
                .fixedSize()
                .disabled(!store.canOpen(entry, objectID: nil))
            }
        }
    }

    static func seconds(_ ms: Double) -> String {
        ms < 1000 ? "\(Int(ms)) ms" : String(format: ms < 10_000 ? "%.1f s" : "%.0f s", ms / 1000)
    }

    private var isScript: Bool { entry.string("kind") == "script" || entry.details["interpreter"] != nil }

    private var trashText: String {
        switch entry.family {
        case "collector":
            return isScript
                ? "The collector and its script were kept when you deleted it. Restore brings it back off: you’ll see its script and allow it again before it runs."
                : "The collector was kept when you deleted it. Restore brings it back off, so you can check it before it runs again."
        case "chat":
            return "The chat and its answers were kept when you deleted it. Restore puts it back in Ask history."
        default:
            return "A copy was kept when you deleted it."
        }
    }

    private var restoredText: String {
        let name = entry.object.name.map { "“\($0)”" } ?? "It"
        switch entry.family {
        case "collector":
            return isScript ? "\(name) is back in Collectors. It’s off until you look at its script and allow it."
                : "\(name) is back in Collectors. It’s off until you turn it on."
        case "chat": return "\(name) is back in Ask history."
        default: return "\(name) is back."
        }
    }

    private func noneText(_ reason: String) -> String {
        if entry.string("reason") == "keep-history-off" {
            return "Keep Ask history is off, so Distill deletes a chat when you close it. Turn it on to keep chats (and have deleted ones kept in the trash)."
        }
        if entry.type == "chat.expired" {
            let days = engine.settings.resolvedAskPreferences.resolvedHistoryDays
            return "Ask history keeps unpinned chats for \(days) days after the last message. Pin a chat to keep it."
        }
        return reason.isEmpty ? "Nothing was kept for this one." : reason
    }

    private func cardBox<C: View>(fill: Color, ring: Color, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) { content() }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(ring, lineWidth: 1))
    }

    private func cardText(_ s: String, ink: Color) -> some View {
        Text(s).font(Theme.body(12.5)).foregroundStyle(ink).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Facts

    private func factsView(_ facts: ActivityText.Facts) -> some View {
        let labelWidth: CGFloat = pushed ? 92 : 104
        return VStack(alignment: .leading, spacing: 4) {
            Text(facts.heading).font(Theme.body(10, .heavy)).kerning(0.6).foregroundStyle(Theme.faint)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(facts.rows.enumerated()), id: \.offset) { i, fact in
                    HStack(alignment: .firstTextBaseline, spacing: 14) {
                        Text(fact.label).font(Theme.body(12.5)).foregroundStyle(Theme.muted)
                            .frame(width: labelWidth, alignment: .leading)
                        factValue(fact)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 8)
                    .overlay(alignment: .top) { if i > 0 { Rectangle().fill(Theme.border).frame(height: 1) } }
                }
            }
            if let note = facts.footnote {
                Text(note).font(Theme.body(12)).foregroundStyle(Theme.faint).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 4)
            }
        }
    }

    @ViewBuilder private func factValue(_ fact: ActivityText.Fact) -> some View {
        if fact.code {
            Text(fact.value).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.muted)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 5).fill(Theme.panel))
                .textSelection(.enabled)
        } else {
            (Text(fact.value) + Text(fact.emphasis ?? "").fontWeight(.bold))
                .font(Theme.body(13)).foregroundStyle(Theme.ink).lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    // MARK: Links

    /// Kinds with a stable id worth following: a chat, a collector, an action, a batch (queue ids are file paths).
    static let followable: Set<String> = ["chat", "collector", "action", "batch", "connection"]

    @ViewBuilder private var links: some View {
        let batch = entry.family == "batch" || entry.family == "labels"
        let forThis = store.filter.object?.id == entry.object.id
        if batch && store.canOpen(entry, objectID: nil) {
            LinkButton(title: "Open in History") { store.open(entry, objectID: nil) }.padding(.leading, -8)
        } else if let id = entry.object.id, !forThis, !id.isEmpty, Self.followable.contains(entry.family), entry.type != "chat.expired" {
            LinkButton(title: "Show everything for “\(entry.object.name ?? id)”") { store.showEverything(for: entry) }
                .padding(.leading, -8)
                .help("Filter the list to this \(entry.object.kind)")
        }
    }
}

// MARK: - Filter panel

/// Filter (canvas: Activity · B): three short choices and one switch.
struct ActivityFilterPanel: View {
    @ObservedObject var store: ActivityStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            section("WHAT", ActivityWhat.allCases, \.title, store.filter.what) { store.filter.what = $0 }
            section("FROM", ActivityFrom.allCases, \.title, store.filter.from) { store.filter.from = $0 }
            section("WHEN", ActivityWhen.allCases, \.title, store.filter.when) { store.filter.when = $0 }
            HStack {
                CapsuleSwitch(title: "Only failures", isOn: Binding(get: { store.filter.onlyFailures }, set: { store.filter.onlyFailures = $0 }))
                Spacer(minLength: 8)
                LinkButton(title: "Clear") { store.filter.clearChoices() }
            }
            .padding(.top, 12)
            .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
        }
        .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 14)
        .frame(width: 320, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white)
            .shadow(color: Theme.ink.opacity(0.18), radius: 15, y: 12))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.ink.opacity(0.06), lineWidth: 1))
    }

    private func section<T: Hashable>(_ title: String, _ options: [T], _ label: KeyPath<T, String>, _ current: T,
                                      _ pick: @escaping (T) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(Theme.body(10, .heavy)).kerning(0.6).foregroundStyle(Theme.faint)
            FlowLayout(spacing: 6) {
                ForEach(options, id: \.self) { option in
                    let on = option == current
                    Button { pick(option) } label: {
                        Text(option[keyPath: label]).font(Theme.body(12, on ? .bold : .medium))
                            .foregroundStyle(on ? Theme.primary : Theme.softInk)
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(Capsule().fill(on ? Theme.primaryTint : Theme.panel))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - Empty states

/// Nothing logged yet (canvas: Activity · E).
struct ActivityEmpty: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "clock").font(.system(size: 26, weight: .regular)).foregroundStyle(Theme.flaskLine)
                .frame(width: 60, height: 60).background(RoundedRectangle(cornerRadius: 18).fill(Theme.panel))
            Text("Nothing has changed yet").font(Theme.display(24))
            Text("When you or Distill change your chats, collectors, actions, batches, queue or settings, it shows here: what changed, when, and where it came from (the Mac app, the CLI, an agent, or Distill on its own). It stays on this Mac.")
                .font(Theme.body(13.5)).foregroundStyle(Theme.muted).multilineTextAlignment(.center).lineSpacing(4)
                .frame(maxWidth: 470).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 40).padding(.top, 120)
        .frame(maxWidth: .infinity)
    }
}

/// Filters with no results (canvas: Activity · F).
struct ActivityNoMatches: View {
    @ObservedObject var store: ActivityStore

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass").font(.system(size: 22, weight: .regular)).foregroundStyle(Theme.faint)
            Text("No activity matches").font(Theme.body(15, .bold))
            Text(Self.message(store.filter)).font(Theme.body(12.5)).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                .lineSpacing(3).frame(maxWidth: 360).fixedSize(horizontal: false, vertical: true)
            LinkButton(title: "Clear filters") { store.filter = ActivityFilter() }
        }
        .padding(.horizontal, 40).padding(.top, 90)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// "Nothing in Chats from the CLI mentions “kettle”. Activity is kept for 180 days."
    static func message(_ f: ActivityFilter) -> String {
        var s = "Nothing"
        if let o = f.object { s += " for “\(o.name)”" }
        if f.what != .all { s += " in \(f.what.title)" }
        switch f.from {
        case .anywhere: break
        case .app: s += " from the Mac app"
        case .cli: s += " from the CLI"
        case .agent: s += " from an agent"
        case .automatic: s += " done automatically"
        }
        switch f.when {
        case .any: break
        case .today: s += " today"
        case .week: s += " in the last 7 days"
        case .month: s += " in the last 30 days"
        }
        if f.onlyFailures { s += " failed" }
        if !f.trimmedText.isEmpty { s += (f.onlyFailures ? " and" : "") + " mentions “\(f.trimmedText)”" }
        else if !f.onlyFailures { s += " matches" }
        return s + ". Activity is kept for 180 days."
    }
}
