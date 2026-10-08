import SwiftUI
import DistillKit

/// The Settings section list (canvas component `SettingsSectionNav`): search
/// on top, then General / AI / Actions. While searching, each section shows
/// its match count and sections without matches are dimmed.
struct SettingsSectionNav: View {
    /// The selected section (no highlight while searching).
    let selected: SettingsSection
    @Binding var query: String
    /// Matches per section while searching; nil when not searching.
    let matches: [SettingsSection: Int]?
    let select: (SettingsSection) -> Void
    @FocusState private var focused: Bool
    @Environment(\.snapshotMode) private var snapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Color.clear.frame(height: 26) // traffic lights
            searchField.padding(.bottom, 2)
            ForEach(SettingsGroup.allCases, id: \.self) { group in
                Text(group.navTitle)
                    .font(Theme.body(10, .heavy)).foregroundStyle(Theme.faint)
                    .padding(.horizontal, 10).padding(.top, 14).padding(.bottom, 4)
                ForEach(group.sections) { item($0) }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 16)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.panel)
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.faint)
            if snapshot {
                // ImageRenderer can't draw a text field.
                Text(query.isEmpty ? "Search settings" : query).font(Theme.body(12))
                    .foregroundStyle(query.isEmpty ? Theme.faint : Theme.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField("", text: $query, prompt: Text("Search settings").foregroundStyle(Theme.faint))
                    .textFieldStyle(.plain).font(Theme.body(12))
                    .focused($focused)
                    .onExitCommand { query = "" }
                    .accessibilityLabel("Search settings")
            }
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark").font(.system(size: 7, weight: .heavy)).foregroundStyle(.white)
                        .frame(width: 16, height: 16).background(Circle().fill(Color(hex: 0xDAD7D0)))
                }
                .buttonStyle(.plain).accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 10).frame(maxWidth: 196).frame(height: 30)
        .background(Capsule().fill(query.isEmpty && !focused ? Color(hex: 0xEDEBE6) : Color.white))
        .overlay(Capsule().strokeBorder(Theme.primary, lineWidth: 2).opacity(query.isEmpty ? 0 : 1))
    }

    private func item(_ section: SettingsSection) -> some View {
        let count = matches?[section] ?? 0
        let isSelected = matches == nil && section == selected
        return Button { select(section) } label: {
            HStack(spacing: 9) {
                Image(systemName: section.systemImage).font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isSelected ? Theme.primary : Theme.muted).frame(width: 16)
                Text(section.title).font(Theme.body(13, isSelected ? .semibold : .regular))
                Spacer(minLength: 0)
                if count > 0 {
                    Text("\(count)").font(Theme.body(11, .bold)).foregroundStyle(Theme.primary)
                        .padding(.horizontal, 7).padding(.vertical, 1)
                        .background(Capsule().fill(Theme.primaryTint))
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 9).fill(Color.white).shadow(color: Theme.ink.opacity(0.08), radius: 1.5, y: 1)
                }
            }
            .contentShape(Rectangle())
            .opacity(matches != nil && count == 0 ? 0.4 : 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(count > 0 ? "\(section.title), \(count) matches" : section.title)
    }
}

/// Results for the search field, grouped by section, matches highlighted.
struct SettingsSearchResults: View {
    @ObservedObject var ui: SettingsStore
    let results: [SettingsEntry]

    var body: some View {
        if results.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: "magnifyingglass").font(.system(size: 22, weight: .semibold)).foregroundStyle(Theme.faint)
                Text("No settings match “\(ui.query.trimmingCharacters(in: .whitespaces))”").font(Theme.body(20, .semibold))
                Text("Try fewer or different words, or pick a section on the left.").font(Theme.body(13)).foregroundStyle(Theme.muted)
                SoftButton(title: "Clear search", fill: .white, size: .small, stroke: true) { ui.query = "" }
                    .padding(.top, 4)
            }
            .padding(.top, 60)
            .frame(maxWidth: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 18) {
                (Text("\(results.count) \(results.count == 1 ? "setting" : "settings")").bold().foregroundColor(Theme.ink)
                    + Text(" match “\(ui.query.trimmingCharacters(in: .whitespaces))”"))
                    .font(Theme.body(13)).foregroundStyle(Theme.muted)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(crumbs, id: \.self) { crumb in
                        Text(crumb).font(Theme.body(11, .bold)).foregroundStyle(Theme.muted)
                            .padding(.top, 10).padding(.bottom, 4)
                        ForEach(results.filter { $0.crumb == crumb }) { row($0) }
                    }
                }
            }
        }
    }

    /// Crumbs in the order their first result appears.
    private var crumbs: [String] {
        var seen = Set<String>()
        return results.map(\.crumb).filter { seen.insert($0).inserted }
    }

    private func row(_ entry: SettingsEntry) -> some View {
        Button { ui.show(entry) } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(highlighted(entry.title)).font(Theme.body(13, .semibold))
                    Text(highlighted(entry.note)).font(Theme.body(12)).foregroundStyle(Theme.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.faint)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func highlighted(_ text: String) -> AttributedString {
        var out = AttributedString(text)
        for range in SettingsIndex.matches(text, ui.query) {
            guard let lower = AttributedString.Index(range.lowerBound, within: out),
                  let upper = AttributedString.Index(range.upperBound, within: out) else { continue }
            out[lower..<upper].backgroundColor = Theme.limeTint
            out[lower..<upper].foregroundColor = Theme.ink
        }
        return out
    }
}
