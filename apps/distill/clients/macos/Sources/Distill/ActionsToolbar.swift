import AppKit
import SwiftUI
import DistillKit

/// The canvas ActionsToolbar (components.json): one line on every Actions tab.
/// Search, Filter ▾ ("Filter · N" in the active style once filters beyond the
/// default are set), one removable FilterChip per filter, a "+N" chip for the
/// ones that don't fit (it opens the panel), then the right slot: sort (To do,
/// Slack, History) or the connection (Jira, Confluence). It never wraps and never
/// asks for more width than it has: the chips that fit are computed from the width.
struct ActionsToolbar<SortItems: View, Panel: View>: View {
    typealias Right = ToolbarRight
    typealias Connection = ToolbarConnection

    @Binding var search: String
    var placeholder = "Search to-dos"
    /// Shows the focused field (snapshots); in the app the field's own focus does.
    var focus = false
    var searchWidth: CGFloat = 190
    var chips: [FacetChip] = []
    /// nil: as many as fit (the app); a number pins it (snapshots of a narrow window use the width instead).
    var visibleChips: Int? = nil
    var right: Right = .sort
    var sortTitle = "Due date"
    var connection: Connection = .connected
    var site = "acme.atlassian.net"
    var service = "Atlassian"
    /// nil: the width it is given.
    var width: CGFloat? = nil
    /// The open panel: nil closed, "" at the top, or a section key (a chip was clicked).
    @Binding var panel: String?
    /// Snapshots draw the panel in place; the app uses a popover.
    var inlinePanel = false
    var removeChip: (FacetChip) -> Void = { _ in }
    var connect: () -> Void = {}
    /// Set: the sort button runs this (To do draws its group and sort panel); else a menu of `sortItems`.
    var sortAction: (() -> Void)? = nil
    @ViewBuilder var sortItems: SortItems
    @ViewBuilder var panelContent: (String) -> Panel

    var body: some View {
        GeometryReader { geo in
            let total = width ?? geo.size.width
            let fit = plan(total)
            HStack(spacing: ToolbarFit.gap) {
                ToolbarSearchField(text: $search, placeholder: placeholder, forceFocus: focus)
                    .frame(width: fit.searchWidth)
                filterButton
                ForEach(chips.prefix(fit.visibleChips)) { chip in
                    FilterChip(text: chip.text, onRemove: { removeChip(chip) })
                        .contentShape(Capsule())
                        .onTapGesture { panel = chip.section }
                        .help("Change this filter")
                }
                if fit.visibleChips < chips.count {
                    FilterChip(text: "+\(chips.count - fit.visibleChips)", fill: Theme.border, ink: Theme.softInk)
                        .contentShape(Capsule())
                        .onTapGesture { panel = chips[fit.visibleChips].section }
                        .help(chips.dropFirst(fit.visibleChips).map(\.text).joined(separator: ", "))
                }
                Spacer(minLength: ToolbarFit.minGap)
                rightSlot(compact: fit.compactRight)
            }
            .frame(width: total, height: 30, alignment: .leading)
        }
        .frame(width: width)
        .frame(height: 30)
        .zIndex(panel != nil ? 20 : 0)
    }

    // MARK: Filter

    private var filterTitle: String { chips.isEmpty ? "Filter" : "Filter · \(chips.count)" }

    private var filterButton: some View {
        DropdownButton(title: filterTitle, height: 30, radius: 15, systemImage: "line.3.horizontal.decrease", active: !chips.isEmpty) {
            panel = panel == nil ? "" : nil
        }
        .fixedSize()
        .help("Filter")
        .overlay(alignment: .topLeading) {
            if inlinePanel, let section = panel { panelContent(section).offset(y: 38).fixedSize() }
        }
        .popover(isPresented: Binding(get: { panel != nil && !inlinePanel }, set: { if !$0 { panel = nil } }), arrowEdge: .bottom) {
            panelContent(panel ?? "")
        }
    }

    // MARK: Right slot

    @ViewBuilder private func rightSlot(compact: Bool) -> some View {
        switch right {
        case .sort:
            if let sortAction {
                DropdownButton(title: sortTitle, height: 30, radius: 15, systemImage: "arrow.up.arrow.down", action: sortAction).fixedSize()
            } else {
                DropdownButton(title: sortTitle, height: 30, radius: 15, systemImage: "arrow.up.arrow.down") { sortItems }.fixedSize()
            }
        case .connection:
            HStack(spacing: 8) {
                if !compact || connection == .connected { status }
                switch connection {
                case .connected: EmptyView()
                case .disconnected:
                    PrimaryButton(title: "Connect now", systemImage: "link", size: .mini, action: connect)
                        .help("Opens Settings → Connections")
                case .connecting:
                    HStack(spacing: 6) {
                        Spinner(color: .white, size: 10)
                        Text("Connecting…").font(Theme.body(12, .semibold))
                    }
                    .foregroundStyle(.white).padding(.horizontal, 11).frame(height: 26)
                    .background(Capsule().fill(Theme.primary)).fixedSize()
                    .help("Finish signing in, in your browser")
                }
            }
            .fixedSize()
        case .none:
            EmptyView()
        }
    }

    private var status: some View {
        let connected = connection == .connected
        let ink = connected ? Theme.limeInk : Theme.peachInk
        return HStack(spacing: 5) {
            Image(systemName: connected ? "globe" : "xmark.circle").font(.system(size: 11, weight: .semibold)).foregroundStyle(ink)
            (Text("\(connected ? site : service) · ") + Text(connected ? "connected" : "not connected").fontWeight(.bold).foregroundColor(ink))
                .font(Theme.body(12)).foregroundStyle(Theme.muted).lineLimit(1)
        }
        .fixedSize()
    }

    // MARK: Fit

    private func plan(_ total: CGFloat) -> ToolbarFit {
        let measure = ToolbarMeasure.self
        let filter = measure.dropdown(filterTitle)
        let rightFull: CGFloat, rightCompact: CGFloat
        switch right {
        case .sort: rightFull = measure.dropdown(sortTitle); rightCompact = rightFull
        case .none: rightFull = 0; rightCompact = 0
        case .connection:
            let statusW = measure.text("\(connection == .connected ? site : service) · ", 12) + measure.text(connection == .connected ? "connected" : "not connected", 12, .bold) + 17
            let button: CGFloat = connection == .connected ? 0 : measure.text(connection == .connecting ? "Connecting…" : "Connect now", 12, .semibold) + (connection == .connecting ? 39 : 39)
            rightFull = statusW + (button > 0 ? 8 + button : 0)
            rightCompact = connection == .connected ? statusW : button
        }
        var fit = ToolbarFit.plan(total: Double(total), search: Double(searchWidth), filter: Double(filter),
                                  right: Double(rightFull), rightCompact: Double(rightCompact),
                                  chips: chips.map { Double(measure.chip($0.text)) },
                                  plus: { Double(measure.text("+\($0)", 12, .bold) + 22) })
        if let visibleChips { fit.visibleChips = min(visibleChips, chips.count) }
        return fit
    }
}

extension ActionsToolbar where Panel == EmptyView {
    /// No Filter panel (a toolbar without filters).
    init(search: Binding<String>, placeholder: String, right: Right = .none, @ViewBuilder sortItems: () -> SortItems) {
        self.init(search: search, placeholder: placeholder, right: right, panel: .constant(nil), sortItems: sortItems, panelContent: { _ in EmptyView() })
    }
}

enum ToolbarRight: String { case sort, connection, none }
enum ToolbarConnection: String { case connected, disconnected, connecting }

/// Text widths for the toolbar's fit (system font, as Theme.body).
enum ToolbarMeasure {
    static func text(_ s: String, _ size: CGFloat, _ weight: NSFont.Weight = .regular) -> CGFloat {
        ceil((s as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight)]).width)
    }
    /// FilterChip: 11 + text + 4 + × 18 + 5.
    static func chip(_ s: String) -> CGFloat { text(s, 12, .bold) + 38 }
    /// DropdownButton with an icon: 10 + icon 13 + 6 + text + 6 + ▾ 8 + 10.
    static func dropdown(_ s: String) -> CGFloat { text(s, 12, .semibold) + 55 }
}

/// The toolbar's search field: grey at rest; white with a 2 pt blue ring while focused.
struct ToolbarSearchField: View {
    @Binding var text: String
    var placeholder: String
    var forceFocus = false
    @FocusState private var focused: Bool

    var body: some View {
        let on = focused || forceFocus
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.faint)
            TextField(placeholder, text: $text).textFieldStyle(.plain).font(Theme.body(12))
                .focused($focused)
                .onExitCommand { text = "" }
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(Theme.faint) }
                    .buttonStyle(.plain).help("Clear the search")
            }
        }
        .padding(.horizontal, 10).frame(height: 30)
        .background(Capsule().fill(on ? Color.white : Theme.panel))
        .overlay(Capsule().strokeBorder(on ? Theme.primary : .clear, lineWidth: 2))
    }
}
