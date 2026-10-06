import AppKit
import SwiftUI
import DistillKit

/// Actions → Highlights (spec actions-routing.md; canvas actions-highlights-list / -note): one card per
/// note or meeting, newest first. What the note's wiki page already says (summary, key points,
/// decisions) is read from the page and linked to it; Distill adds only Others' actions, which reach
/// the page through the next batch you approve.
struct HighlightsScreen: View {
    @EnvironmentObject var engine: AppModel
    @ObservedObject var store: ActionsStore
    @State private var search = ""

    private var visible: [HighlightNote] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return store.highlights.filter { n in
            if store.highlightsMeetings && !n.isMeeting { return false }
            if q.isEmpty { return true }
            var words: [String] = [n.title]
            words += n.people
            words += n.wiki?.keyPoints.map(\.text) ?? []
            words += n.others.flatMap { g in g.items.map(\.title) }
            return words.contains { $0.lowercased().contains(q) }
        }
    }

    var body: some View {
        let list = visible
        let selected = list.first { $0.notePath == store.selected["highlights"] }
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("ACTIONS").font(Theme.body(11, .heavy)).kerning(0.6).foregroundStyle(Theme.faint)
                    Text("Highlights").font(Theme.display(30)).lineLimit(1)
                    Text("What happened in your notes and meetings, and what others are doing").font(Theme.body(13)).foregroundStyle(Theme.muted)
                }
                Spacer(minLength: 0)
                SoftButton(title: "History", fill: .white, size: .small, stroke: true, systemImage: "clock") { store.historyRequest += 1 }
            }
            .padding(.horizontal, 32).padding(.top, 28)
            HStack(spacing: 8) {
                ActionSearchField(text: $search, placeholder: "Search highlights", width: 220)
                Spacer(minLength: 8)
                GrayToggle(options: [(false, "All notes"), (true, "Meetings")], selection: $store.highlightsMeetings)
            }
            .padding(.horizontal, 32).padding(.top, 14).padding(.bottom, 8)
            if !store.highlightsLoaded {
                ActionShimmerRows(count: 3).padding(.horizontal, 20)
                Spacer()
            } else if store.highlights.isEmpty {
                ActionsEmpty(icon: "sparkles", title: "No highlights yet",
                             message: "When a note names things other people will do, Distill lists them here with what the note’s wiki page says. Tell Distill whose items are yours in Settings → Actions.") {
                    SoftButton(title: "Who you handle items for", fill: .white, size: .small, stroke: true) { store.openSettings("actions/people") }
                }
            } else {
                GeometryReader { geo in
                    HStack(alignment: .top, spacing: 8) {
                        Scrolling {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Newest first · one card per note or meeting").font(Theme.body(12)).foregroundStyle(Theme.muted)
                                    .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 2)
                                let columns = selected == nil ? [GridItem(.flexible(), spacing: 12, alignment: .top), GridItem(.flexible(), spacing: 12, alignment: .top)] : [GridItem(.flexible(), alignment: .top)]
                                LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                                    ForEach(list) { note in
                                        HighlightCard(store: store, note: note, selected: note.notePath == selected?.notePath)
                                    }
                                }
                                .padding(.top, 4).padding(.trailing, 4)
                            }
                            .padding(.trailing, selected == nil ? 32 : 8).padding(.bottom, 60)
                        }
                        .frame(maxWidth: .infinity)
                        if let selected {
                            HighlightDetail(store: store, note: selected)
                                .paneWidth(.todoDetail, automatic: min(460, geo.size.width * 0.55), container: geo.size.width)
                                .frame(maxHeight: .infinity, alignment: .top)
                                .overlay(alignment: .leading) { Rectangle().fill(Theme.border).frame(width: 1) }
                        }
                    }
                    .padding(.leading, 20)
                }
            }
        }
        .onAppear { if !store.highlightsLoaded || store.client != nil { store.loadHighlights() } }
    }
}

/// People chips: the user in blue, others in turn pink, lime, amber, sky.
enum PersonColors {
    static let palette: [(Color, Color)] = [(Theme.pinkTint, Theme.pinkInk), (Theme.limeTint, Theme.limeInk),
                                            (Color(hex: 0xFFF1D6), Color(hex: 0x8A5A00)), (Theme.skyTint, Theme.skyInk)]
    static func of(_ index: Int, you: Bool) -> (Color, Color) {
        you ? (Theme.primaryTint, Theme.primary) : palette[max(0, index) % palette.count]
    }

    /// One color per person across Highlights: the order they first appear in (the user excluded).
    static func of(_ name: String, in notes: [HighlightNote], you: String?) -> (Color, Color) {
        if name == you { return (Theme.primaryTint, Theme.primary) }
        var order: [String] = []
        for n in notes { for p in n.people + n.others.map(\.person) where p != you && !order.contains(p) { order.append(p) } }
        return of(order.firstIndex(of: name) ?? 0, you: false)
    }
}

struct PersonChip2: View {
    let name: String
    var colors: (Color, Color)
    var full = false

    var body: some View {
        HStack(spacing: 5) {
            Text(Routing.initials(name)).font(Theme.body(8, .bold)).foregroundStyle(colors.1)
                .frame(width: 18, height: 18).background(Circle().fill(colors.0))
            Text(full ? name : Routing.firstName(name)).font(Theme.body(11.5))
        }
        .padding(.leading, 2).padding(.trailing, 8).frame(height: 22)
        .background(Capsule().fill(Theme.panel))
    }
}

/// The note's people, the user first.
struct HighlightPeople: View {
    @ObservedObject var store: ActionsStore
    let note: HighlightNote

    var body: some View {
        FlowLayout(spacing: 5) {
            ForEach(Array(note.people.enumerated()), id: \.offset) { k, name in
                PersonChip2(name: name, colors: PersonColors.of(name, in: store.highlights, you: store.people.first?.name))
            }
        }
    }
}

/// One note on the Highlights list.
struct HighlightCard: View {
    @ObservedObject var store: ActionsStore
    let note: HighlightNote
    var selected = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: note.isMeeting ? "person.2" : "doc.text").font(.system(size: 12)).foregroundStyle(Theme.muted)
                Text(note.title).font(Theme.body(14, .bold)).lineLimit(1)
                Spacer(minLength: 4)
                Text(Routing.highlightWhen(note)).font(Theme.body(11.5)).foregroundStyle(Theme.faint).lineLimit(1)
            }
            HighlightPeople(store: store, note: note)
            if let points = note.wiki?.keyPoints, !points.isEmpty {
                ContextLabel(text: "From the wiki page")
                ForEach(Array(points.prefix(3).enumerated()), id: \.offset) { _, p in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text("•").foregroundStyle(Theme.faint)
                        Text(p.text).foregroundStyle(Theme.softInk).fixedSize(horizontal: false, vertical: true)
                    }
                    .font(Theme.body(12.5))
                }
            } else if note.wiki == nil {
                Text("The note’s wiki page isn’t there.").font(Theme.body(12).italic()).foregroundStyle(Theme.faint)
            }
            Text(Routing.highlightCounts(note)).font(Theme.body(11.5)).foregroundStyle(Theme.muted)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white).shadow(color: .black.opacity(0.05), radius: 3, y: 2))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(selected ? Theme.primary : Theme.border, lineWidth: selected ? 1.5 : 1))
        .contentShape(Rectangle())
        .onTapGesture { store.selected["highlights"] = selected ? nil : note.notePath }
    }
}

/// A note's Highlights: From the wiki page (Open page; its summary, key points and decisions with their
/// lines), Others' actions by person (Track as Pending, It's mine), Your items; Copy as summary, Open note.
struct HighlightDetail: View {
    @EnvironmentObject var engine: AppModel
    @ObservedObject var store: ActionsStore
    let note: HighlightNote

    private var vault: String? { engine.activeVault?.path }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Scrolling {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 8) {
                        Pill(text: "Highlights", fill: Color(hex: 0xF3FDE4), ink: Theme.limeInk)
                        Text(([note.isMeeting ? "Meeting" : "Note", Routing.highlightWhen(note)]).joined(separator: " · "))
                            .font(Theme.body(12)).foregroundStyle(Theme.muted)
                    }
                    Text(note.title).font(Theme.display(18)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    HighlightPeople(store: store, note: note)
                    wikiBlock
                    othersBlock
                    yoursBlock
                }
                .padding(.horizontal, 22).padding(.top, 4).padding(.bottom, 20)
            }
            Divider().overlay(Theme.border)
            HStack(spacing: 8) {
                ActionButton(title: "Copy as summary", kind: .soft, height: 30) { store.copySummary(note) }
                Spacer(minLength: 6)
                ActionButton(title: "Open note", kind: .primary, height: 30) { ActionContextOpen.openPage(note.notePath, vault: vault) }
            }
            .padding(.horizontal, 22).padding(.vertical, 12)
        }
    }

    @ViewBuilder private var wikiBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ContextLabel(text: "From the wiki page")
                Spacer(minLength: 4)
                if note.wiki != nil { ContextLink(title: "Open page", icon: "book") { ActionContextOpen.openPage(note.notePath, vault: vault) } }
            }
            if let wiki = note.wiki {
                (Text("Sources › ").foregroundColor(Theme.muted) + Text(wiki.title).fontWeight(.bold).foregroundColor(Theme.ink))
                    .font(Theme.body(11.5))
                if let s = wiki.summary { Text(s).font(Theme.body(12.5)).lineSpacing(2).fixedSize(horizontal: false, vertical: true).textSelection(.enabled) }
                lines("Key points", wiki.keyPoints)
                lines("Decisions", wiki.decisions)
                if wiki.keyPoints.isEmpty && wiki.decisions.isEmpty && wiki.summary == nil {
                    Text("The page has no summary, key points or decisions yet.").font(Theme.body(12).italic()).foregroundStyle(Theme.faint)
                }
            } else {
                Text("The note’s wiki page isn’t there, so there is nothing to show from it.").font(Theme.body(12).italic()).foregroundStyle(Theme.faint)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.panel))
    }

    @ViewBuilder private func lines(_ title: String, _ list: [HighlightNote.Wiki.Line]) -> some View {
        if !list.isEmpty {
            ContextLabel(text: title).padding(.top, 2)
            ForEach(Array(list.enumerated()), id: \.offset) { _, l in
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text("•").foregroundStyle(Theme.faint)
                    Text(l.text).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button("line \(l.line)") { ActionContextOpen.openPage(note.notePath, vault: vault) }
                        .buttonStyle(.plain).font(Theme.body(11, .semibold)).foregroundStyle(Theme.primary)
                }
                .font(Theme.body(12.5))
            }
        }
    }

    @ViewBuilder private var othersBlock: some View {
        if !note.others.isEmpty {
            let waiting = note.others.flatMap(\.items).contains { !$0.onPage }
            VStack(alignment: .leading, spacing: 8) {
                ContextLabel(text: waiting ? "Others’ actions · added to the wiki page in the next batch" : "Others’ actions · on the wiki page")
                ForEach(Array(note.others.enumerated()), id: \.offset) { k, g in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            let c = PersonColors.of(g.person, in: store.highlights, you: store.people.first?.name)
                            Text(Routing.initials(g.person)).font(Theme.body(8, .bold)).foregroundStyle(c.1)
                                .frame(width: 18, height: 18).background(Circle().fill(c.0))
                            Text(g.person).font(Theme.body(12.5, .bold))
                        }
                        ForEach(g.items) { item in
                            HStack(alignment: .firstTextBaseline, spacing: 7) {
                                (Text(item.title) + Text(Routing.by(item.due, now: store.fixtureNow ?? Date()).map { " · by \($0)" } ?? "").foregroundColor(Theme.muted))
                                    .font(Theme.body(12.5)).fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 4)
                                if let line = item.line {
                                    Text("line \(line)").font(Theme.body(11, .semibold)).foregroundStyle(Theme.primary)
                                }
                            }
                            .padding(.leading, 24)
                            HStack(spacing: 10) {
                                Button("Track as Pending") { if let a = store.routed[item.id] { store.trackAsPending(a) } }
                                Button("It’s mine") { if let a = store.routed[item.id] { store.claim(a) } }
                            }
                            .buttonStyle(.plain).font(Theme.body(11.5, .semibold)).foregroundStyle(Theme.primary)
                            .padding(.leading, 24)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var yoursBlock: some View {
        let lists = note.yours.lists.sorted { ($0.key == "todo" ? "" : $0.key) < ($1.key == "todo" ? "" : $1.key) }
        VStack(alignment: .leading, spacing: 4) {
            ContextLabel(text: "Your items")
            if lists.isEmpty && note.yours.waiting.isEmpty {
                Text("None from this note.").font(Theme.body(12.5)).foregroundStyle(Theme.muted)
            }
            if !lists.isEmpty {
                let n = lists.reduce(0) { $0 + $1.value }
                HStack(spacing: 0) {
                    Text("\(n) went to your lists: ").font(Theme.body(12.5))
                    ForEach(Array(lists.enumerated()), id: \.offset) { k, e in
                        if k > 0 { Text(" · ").font(Theme.body(12.5)) }
                        Button("\(e.key == "todo" ? "To do" : store.type(e.key)?.label ?? e.key) \(e.value)") { store.open(tab: store.listTypes.contains { $0.id == e.key } ? e.key : "todo") }
                            .buttonStyle(.plain).font(Theme.body(11.5, .semibold)).foregroundStyle(Theme.primary)
                    }
                }
            }
            if !note.yours.waiting.isEmpty {
                HStack(spacing: 0) {
                    Text("\(note.yours.waiting.count) went to Pending: ").font(Theme.body(12.5))
                    ForEach(Array(note.yours.waiting.enumerated()), id: \.offset) { k, w in
                        if k > 0 { Text(" · ").font(Theme.body(12.5)) }
                        Button("\(Routing.firstName(w.person)): \(shortWhat(w.what))") { store.open(tab: "pending", select: w.id) }
                            .buttonStyle(.plain).font(Theme.body(11.5, .semibold)).foregroundStyle(Theme.primary)
                    }
                }
                .lineLimit(1)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.panel))
    }

    /// "the ticket links" → "ticket links".
    private func shortWhat(_ s: String) -> String {
        s.hasPrefix("the ") ? String(s.dropFirst(4)) : s
    }
}
