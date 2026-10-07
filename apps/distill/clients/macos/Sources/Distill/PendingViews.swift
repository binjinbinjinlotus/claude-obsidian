import AppKit
import SwiftUI
import DistillKit

/// Actions → Pending (spec actions-routing.md; canvas actions-pending-list / -detail): what other people
/// said they would do for you, by person or by date. A later note that looks like delivery only
/// suggests "Mark received?"; nothing closes on its own.
struct PendingScreen: View {
    @EnvironmentObject var engine: AppModel
    @ObservedObject var store: ActionsStore
    @State private var search = ""
    /// Snapshots fix "today" (Overdue, "by Fri").
    var now: Date { store.fixtureNow ?? Date() }

    private var visible: [ActionItem] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return store.waiting }
        return store.waiting.filter { item in
            [item.title, Routing.owner(item, people: store.people), ActionList.noteTitle(item) ?? "", item.what ?? ""]
                .contains { $0.lowercased().contains(q) }
        }
    }

    var body: some View {
        let groups = Routing.pendingGroups(visible, byDate: store.pendingByDate, people: store.people, now: now)
        let ordered = groups.flatMap(\.items)
        let selected = ordered.first { $0.id == store.selected["pending"] } ?? ordered.first
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("ACTIONS").font(Theme.body(11, .heavy)).kerning(0.6).foregroundStyle(Theme.faint)
                    Text("Pending").font(Theme.display(30)).lineLimit(1)
                    Text("Waiting on others · what people said they would do for you").font(Theme.body(13)).foregroundStyle(Theme.muted)
                }
                Spacer(minLength: 0)
                SoftButton(title: "History", fill: .white, size: .small, stroke: true, systemImage: "clock") { store.historyRequest += 1 }
            }
            .padding(.horizontal, 32).padding(.top, 28)
            HStack(spacing: 8) {
                ActionSearchField(text: $search, placeholder: "Search pending", width: 220)
                Spacer(minLength: 8)
                Text("Group by").font(Theme.body(12)).foregroundStyle(Theme.muted)
                GrayToggle(options: [(false, "Person"), (true, "Date")], selection: $store.pendingByDate)
            }
            .padding(.horizontal, 32).padding(.top, 14).padding(.bottom, 8)
            if store.phase != .loaded {
                ActionShimmerRows(count: 3).padding(.horizontal, 20)
                Spacer()
            } else if store.waiting.isEmpty {
                ActionsEmpty(icon: "clock", title: "Nobody owes you anything right now",
                             message: "When a note says someone will do something for you (“I’ll send you the links by Friday”), it waits here until you mark it received.") {
                    SoftButton(title: "Who you handle items for", fill: .white, size: .small, stroke: true) { store.openSettings("actions/people") }
                }
            } else {
                GeometryReader { geo in
                    HStack(alignment: .top, spacing: 8) {
                        Scrolling {
                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(groups) { g in
                                    groupHeader(g)
                                    ForEach(g.items) { row($0, selected: $0.id == selected?.id) }
                                }
                            }
                            .padding(.trailing, 8).padding(.bottom, 60)
                        }
                        .frame(maxWidth: .infinity)
                        if let selected {
                            PendingDetail(store: store, item: selected, now: now)
                                .paneWidth(.todoDetail, automatic: min(440, geo.size.width * 0.5), container: geo.size.width)
                                .frame(maxHeight: .infinity, alignment: .top)
                                .overlay(alignment: .leading) { Rectangle().fill(Theme.border).frame(width: 1) }
                        }
                    }
                    .padding(.leading, 20)
                }
            }
        }
    }

    private func groupHeader(_ g: Routing.PendingGroup) -> some View {
        HStack(spacing: 8) {
            if store.pendingByDate {
                Text(g.title.uppercased()).font(Theme.body(10, .heavy)).kerning(0.6)
                    .foregroundStyle(g.title == "Overdue" ? Theme.peachInk : Theme.faint)
            } else {
                PersonAvatar(name: g.title, size: 20)
                Text(g.title).font(Theme.body(12.5, .bold))
            }
            Text("\(g.items.count)").font(Theme.body(11, .bold)).foregroundStyle(Theme.faint)
        }
        .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 4)
    }

    private func row(_ item: ActionItem, selected: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "clock").font(.system(size: 13)).foregroundStyle(Theme.faint).padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(Theme.body(13.5, .semibold)).lineLimit(2)
                PendingMeta(store: store, item: item, now: now)
                if let r = item.received {
                    Button { store.markReceived(item) } label: {
                        Text(Routing.receivedLine(r)).font(Theme.body(11.5, .semibold)).foregroundStyle(Theme.primary)
                    }
                    .buttonStyle(.plain).padding(.top, 4)
                    .help(r.quote.map { "“\($0)”" } ?? "Mark it received")
                }
            }
            Spacer(minLength: 6)
            if Routing.overdue(item.due, now: now) {
                Pill(text: "Overdue", fill: Theme.peachTint, ink: Theme.peachInk)
            } else if let by = Routing.by(item.due, now: now) {
                Pill(text: by, fill: Theme.panel, ink: Theme.softInk)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 12).fill(selected ? Color.white : .clear))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? Theme.primary : .clear, lineWidth: 1.5))
        .contentShape(Rectangle())
        .onTapGesture { store.selected["pending"] = item.id }
        .contextMenu {
            Button("Mark received") { store.markReceived(item) }
            Button("Nudge") { store.selected["pending"] = item.id; store.startNudge(item) }
            Button("Not waiting anymore") { store.stopWaiting(item) }
        }
    }
}

/// "from Aditya Pradhan · promised in 📄 2026-10-05 AI FE Platform Sync · by Fri".
struct PendingMeta: View {
    @ObservedObject var store: ActionsStore
    let item: ActionItem
    var now = Date()

    var body: some View {
        let note = ActionList.noteTitle(item)
        (Text(Routing.pendingMeta(item, people: store.people) + " ")
         + (note.map { Text(Image(systemName: "doc.text")).foregroundColor(Theme.faint) + Text(" \($0)") } ?? Text("a note"))
         + Text(" · " + Routing.pendingDate(item.due, now: now)))
            .font(Theme.body(11)).foregroundStyle(Theme.muted).lineLimit(1)
    }
}

/// The selected promise: who and by when, what you are waiting for, the quote with its lines, Why,
/// and Not waiting anymore · Nudge · Mark received. Nudge opens an Add as Slack message panel here.
struct PendingDetail: View {
    @ObservedObject var store: ActionsStore
    let item: ActionItem
    var now = Date()

    var body: some View {
        let person = Routing.owner(item, people: store.people)
        VStack(alignment: .leading, spacing: 0) {
            Scrolling {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 8) {
                        Pill(text: "Pending", fill: Theme.primaryTint, ink: Theme.primary)
                        PersonAvatar(name: person, size: 20)
                        Text("Waiting on \(person)" + (Routing.by(item.due, now: now).map { " · by \($0)" } ?? ""))
                            .font(Theme.body(12)).foregroundStyle(Theme.muted).lineLimit(1)
                    }
                    Text(item.title).font(Theme.display(18)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    if let r = item.received {
                        HStack(spacing: 8) {
                            Image(systemName: "tray.and.arrow.down").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.primary)
                            Text(Routing.receivedLine(r)).font(Theme.body(12.5, .semibold)).foregroundStyle(Theme.primary)
                            Spacer(minLength: 0)
                        }
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.primaryTint))
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text("WHAT YOU’RE WAITING FOR").font(Theme.body(10, .heavy)).kerning(0.6).foregroundStyle(Theme.faint)
                        Text(item.summary ?? item.why ?? item.title).font(Theme.body(13.5)).lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                    ActionContextBlock(item: item, full: true)
                    if store.nudging[item.id] != nil { NudgePanel(store: store, item: item) }
                }
                .padding(.horizontal, 22).padding(.top, 4).padding(.bottom, 20)
            }
            Divider().overlay(Theme.border)
            HStack(spacing: 8) {
                ActionButton(title: "Not waiting anymore", kind: .plain, height: 30) { store.stopWaiting(item) }
                Spacer(minLength: 6)
                if store.nudging[item.id] == nil {
                    ActionButton(title: "Nudge", kind: .soft, height: 30) { store.startNudge(item) }
                }
                ActionButton(title: "Mark received", icon: "checkmark", kind: .primary, height: 30) { store.markReceived(item) }
            }
            .padding(.horizontal, 22).padding(.vertical, 12)
        }
    }
}

/// Nudge · Add as Slack message: To (the person, with their @handle from People) and the prefilled text.
struct NudgePanel: View {
    @ObservedObject var store: ActionsStore
    let item: ActionItem

    var body: some View {
        let draft = Binding(get: { store.nudging[item.id] ?? NudgeDraft(to: "", text: "") }, set: { store.nudging[item.id] = $0 })
        let style = ActionsTheme.typeStyle("slack")
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: style.0).font(.system(size: 11, weight: .semibold)).foregroundStyle(style.2)
                    .frame(width: 22, height: 22).background(RoundedRectangle(cornerRadius: 7).fill(style.1))
                Text("Nudge · Add as Slack message").font(Theme.body(13.5, .bold))
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                Text("To").font(Theme.body(12)).foregroundStyle(Theme.muted).frame(width: 40, alignment: .leading)
                Text("Person").font(Theme.body(10, .bold)).foregroundStyle(Theme.muted)
                    .padding(.horizontal, 7).frame(height: 18).background(Capsule().fill(Color(hex: 0xF0EEEA)))
                TextField("Who it goes to", text: draft.to).textFieldStyle(.plain).font(Theme.body(13, .bold))
            }
            HStack(alignment: .top, spacing: 8) {
                Text("Text").font(Theme.body(12)).foregroundStyle(Theme.muted).frame(width: 40, alignment: .leading).padding(.top, 6)
                TextField("Message", text: draft.text, axis: .vertical).textFieldStyle(.plain).font(Theme.body(12.5))
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color(hex: 0xD6D3CC)))
            }
            HStack(spacing: 6) {
                Spacer()
                ActionButton(title: "Cancel", kind: .soft, height: 30) { store.nudging[item.id] = nil }
                ActionButton(title: "Add as Slack message", icon: "plus", kind: .primary, height: 30) { store.sendNudge(item) }
                    .disabled(draft.wrappedValue.to.trimmingCharacters(in: .whitespaces).isEmpty
                              || draft.wrappedValue.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(hex: 0xF2C6D8), lineWidth: 1.5))
    }
}

/// Gray track, white selected segment ("Group by  Person | Date", "All notes | Meetings").
struct GrayToggle<Value: Hashable>: View {
    let options: [(Value, String)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.0) { value, label in
                let on = value == selection
                Button { selection = value } label: {
                    Text(label).font(Theme.body(12, .semibold)).foregroundStyle(on ? Theme.ink : Theme.muted)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 7).fill(on ? Color.white : .clear)
                            .shadow(color: .black.opacity(on ? 0.12 : 0), radius: 1, y: 1))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.panel))
    }
}
