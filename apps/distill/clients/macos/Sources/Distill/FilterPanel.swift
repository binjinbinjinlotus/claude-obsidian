import SwiftUI
import DistillKit

/// The canvas FilterPanel (components.json): one menu for every filter of a tab,
/// with per-`kind` sections (ActionFacets.layout). Long sections show the top 5
/// and "Show all N"; the footer has Clear all, the count and Done. Opened from a
/// chip, it starts at that chip's section with its heading in blue.
struct FilterPanel: View {
    /// "todo", "slack", "jira", "confluence" or "history".
    let kind: String
    let sections: [FacetSection]
    /// The section to start at (a chip was clicked); "" or nil = the top.
    var scrollTo: String? = nil
    /// The heading drawn in blue (the section a chip opened).
    var focus: String? = nil
    var width: CGFloat = 300
    /// The most the panel grows to; it scrolls inside.
    var height: CGFloat = 560
    /// Snapshots: start the list at `scrollTo` instead of scrolling (a popover isn't drawn there).
    var inline = false
    var toggle: (String, String) -> Void = { _, _ in }
    var clearAll: () -> Void = {}
    var done: () -> Void = {}
    /// The search inside Person / Recipient / Assignee.
    @State var personQuery: String
    /// Sections showing all their rows ("Show all 7").
    @State var expanded: Set<String>

    init(kind: String, sections: [FacetSection], scrollTo: String? = nil, focus: String? = nil, width: CGFloat = 300, height: CGFloat = 560,
         inline: Bool = false, personQuery: String = "", expanded: Set<String> = [],
         toggle: @escaping (String, String) -> Void = { _, _ in }, clearAll: @escaping () -> Void = {}, done: @escaping () -> Void = {}) {
        self.kind = kind; self.sections = sections; self.scrollTo = scrollTo; self.focus = focus
        self.width = width; self.height = height; self.inline = inline
        self.toggle = toggle; self.clearAll = clearAll; self.done = done
        _personQuery = State(initialValue: personQuery)
        _expanded = State(initialValue: expanded)
    }

    /// Everything chosen, every section.
    var selected: Set<String> { sections.reduce(into: Set<String>()) { $0.formUnion($1.single ? [] : $1.selected) } }
    /// To do's single Status ("open", "completed", "all"); nil for kinds without one.
    var status: String? { sections.first { $0.single }?.selected.first }
    var due: Set<String> { picked("due") }
    var person: Set<String> { picked("person") }
    var label: Set<String> { picked("label") }
    var note: Set<String> { picked("note") }
    var priority: Set<String> { picked("priority") }
    var more: Set<String> { picked("more") }

    private func picked(_ key: String) -> Set<String> { sections.first { $0.id == key }?.selected ?? [] }

    /// "2 filters" / "Status: Open" (To do with nothing set) / "No filters".
    private var summary: String {
        let n = selected.count + (status.map { $0 != "open" ? 1 : 0 } ?? 0)
        if n > 0 { return n == 1 ? "1 filter" : "\(n) filters" }
        return status != nil ? "Status: Open" : "No filters"
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if inline && startIndex > 0 {
                            Capsule().fill(Theme.border).frame(width: width * 0.2, height: 3).frame(maxWidth: .infinity).padding(.bottom, 4)
                        }
                        ForEach(shownSections) { section in
                            sectionView(section).id(section.id)
                        }
                    }
                    .padding(.horizontal, 6).padding(.top, 6).padding(.bottom, 4)
                }
                .frame(height: max(160, height - 50))
                .onAppear {
                    guard !inline, let target = scrollTo, !target.isEmpty else { return }
                    // The popover lays out first; scroll on the next turn of the run loop.
                    DispatchQueue.main.async { proxy.scrollTo(target, anchor: .top) }
                }
            }
            HStack(spacing: 8) {
                LinkButton(title: "Clear all", action: clearAll)
                Text(summary).font(Theme.body(11)).foregroundStyle(Theme.faint).frame(maxWidth: .infinity, alignment: .trailing)
                PrimaryButton(title: "Done", size: .small, action: done).keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 10)
            .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
        }
        .frame(width: width)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .shadow(color: inline ? Theme.ink.opacity(0.18) : .clear, radius: 16, y: 14)
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(inline ? Theme.ink.opacity(0.08) : .clear))
    }

    private var startIndex: Int { sections.firstIndex { $0.id == scrollTo } ?? 0 }
    private var shownSections: [FacetSection] { inline ? Array(sections.dropFirst(startIndex)) : sections }

    // MARK: Section

    @ViewBuilder private func sectionView(_ s: FacetSection) -> some View {
        let n = s.single ? 0 : s.selected.count
        HStack {
            Text(s.title).font(Theme.body(10, .heavy)).kerning(0.6).foregroundStyle(focus == s.id ? Theme.primary : Theme.faint)
            Spacer()
            if n > 0 { Text("\(n) selected").font(Theme.body(10, .bold)).foregroundStyle(Theme.primary) }
        }
        .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 4)
        if let ph = s.searchPlaceholder {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.faint)
                TextField(ph, text: $personQuery).textFieldStyle(.plain).font(Theme.body(12))
            }
            .padding(.horizontal, 10).frame(height: 28)
            .background(Capsule().fill(personQuery.isEmpty ? Theme.panel : Color.white))
            .overlay(Capsule().strokeBorder(personQuery.isEmpty ? .clear : Theme.primary, lineWidth: 2))
            .padding(.horizontal, 6).padding(.top, 2).padding(.bottom, 4)
        }
        let shown = s.visible(query: s.searchPlaceholder == nil ? "" : personQuery, expanded: expanded.contains(s.id))
        ForEach(Array(shown.rows.enumerated()), id: \.element.id) { i, option in
            if let g = option.group, i == 0 || shown.rows[i - 1].group != g, !g.isEmpty {
                Text(g).font(Theme.body(10, .bold)).foregroundStyle(Theme.faint).padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 2)
            }
            row(option, on: s.selected.contains(option.id), single: s.single) { toggle(s.id, option.id) }
        }
        if shown.rows.isEmpty {
            Text(personQuery.isEmpty ? "Nothing yet" : "No one matches “\(personQuery)”").font(Theme.body(12)).foregroundStyle(Theme.faint)
                .padding(.horizontal, 10).padding(.vertical, 6)
        }
        if shown.rows.count < shown.all {
            Button("Show all \(shown.all)") { expanded.insert(s.id) }
                .buttonStyle(.plain).font(Theme.body(12, .semibold)).foregroundStyle(Theme.primary)
                .padding(.leading, 33).padding(.top, 4).padding(.bottom, 6)
        }
    }

    private func row(_ option: FacetOption, on: Bool, single: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: single ? 7 : 4).fill(on ? Theme.primary : Color.white)
                    RoundedRectangle(cornerRadius: single ? 7 : 4).strokeBorder(on ? Theme.primary : ActionsTheme.quoteBar, lineWidth: 1.5)
                    if on { Image(systemName: "checkmark").font(.system(size: 8, weight: .heavy)).foregroundStyle(.white) }
                }
                .frame(width: 14, height: 14)
                Text(option.label).font(Theme.body(13, on ? .semibold : .regular)).foregroundStyle(Theme.ink).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let c = option.count { Text("\(c)").font(Theme.body(11)).foregroundStyle(Theme.faint) }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(on ? ActionsTheme.selectedFill : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}
