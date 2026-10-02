import SwiftUI
import DistillKit

// The style bar (full and compact), the heading menu, the dark selection bubble,
// the link / note picker and the Aa toggle, drawn as on the design canvas
// (Markdown.dc.html). Plain SwiftUI, so `--snapshot` renders them as the app does.

enum MarkdownBarVariant { case full, compact }

enum MarkdownBarItem: Hashable {
    case bold, italic, strike, heading, bullet, numbered, checklist, quote, code, codeBlock, link, wikilink

    var help: String {
        switch self {
        case .bold: return "Bold ⌘B"
        case .italic: return "Italic ⌘I"
        case .strike: return "Strikethrough ⌘⇧X"
        case .heading: return "Heading"
        case .bullet: return "Bullet list ⌘⇧8"
        case .numbered: return "Numbered list ⌘⇧7"
        case .checklist: return "Checklist ⌘⇧9"
        case .quote: return "Quote ⌘⇧."
        case .code: return "Inline code ⌘E"
        case .codeBlock: return "Code block ⌘⌥C"
        case .link: return "Link ⌘K"
        case .wikilink: return "Link to a note [["
        }
    }

    static func groups(_ variant: MarkdownBarVariant) -> [[MarkdownBarItem]] {
        switch variant {
        case .full: return [[.bold, .italic, .strike], [.heading], [.bullet, .numbered, .checklist], [.quote], [.code, .codeBlock], [.link, .wikilink]]
        case .compact: return [[.bold, .italic], [.heading], [.bullet, .checklist], [.code], [.link, .wikilink]]
        }
    }

    func isOn(_ a: MarkdownParser.ActiveStyles) -> Bool {
        switch self {
        case .bold: return a.bold
        case .italic: return a.italic
        case .strike: return a.strike
        case .heading: return a.heading > 0
        case .bullet: return a.list == .bullet
        case .numbered: return a.list == .numbered
        case .checklist: return a.list == .checklist
        case .quote: return a.quote
        case .code: return a.code
        case .codeBlock: return a.codeBlock
        case .link: return a.link
        case .wikilink: return a.wikilink
        }
    }
}

private let barInk = Color(hex: 0x48463F)
private let barDivider = Color(hex: 0xE1DED8)

/// The style bar. `pressed` forces an item to look on (snapshots: an open menu or popover).
struct MarkdownStyleBar: View {
    var variant: MarkdownBarVariant
    var active: MarkdownParser.ActiveStyles
    var pressed: MarkdownBarItem? = nil
    /// The Image button at the end (editors that take images inline).
    var onImage: (() -> Void)? = nil
    var perform: (MarkdownBarItem, CGRect) -> Void

    var body: some View {
        HStack(spacing: 1) {
            let groups = MarkdownBarItem.groups(variant)
            ForEach(Array(groups.enumerated()), id: \.offset) { i, group in
                if i > 0 { Rectangle().fill(barDivider).frame(width: 1, height: 16).padding(.horizontal, 3) }
                ForEach(group, id: \.self) { item in
                    MarkdownBarButton(item: item, on: item.isOn(active) || pressed == item, dark: false, perform: perform)
                }
            }
            if let onImage {
                Rectangle().fill(barDivider).frame(width: 1, height: 16).padding(.horizontal, 3)
                MarkdownImageButton(action: onImage)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 11).fill(Theme.panel))
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Text style")
    }
}

/// "Image": insert an image at the cursor (or paste ⌘V, or drop).
struct MarkdownImageButton: View {
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "photo").font(.system(size: 12, weight: .semibold))
                Text("Image").font(.system(size: 12, weight: .bold))
            }
            .padding(.horizontal, 8).frame(height: 28)
            .foregroundStyle(barInk)
            .background(RoundedRectangle(cornerRadius: 8).fill(hover ? Color(hex: 0xF6F5F2) : Color.white))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("Insert image (or paste ⌘V, or drop)")
        .accessibilityLabel("Insert image")
    }
}

struct MarkdownBarButton: View {
    let item: MarkdownBarItem
    var on: Bool
    var dark: Bool
    var perform: (MarkdownBarItem, CGRect) -> Void
    @State private var frame: CGRect = .zero
    @State private var hover = false

    var body: some View {
        Button { perform(item, frame) } label: {
            MarkdownBarIcon(item: item)
                .frame(width: 28, height: 28)
                .foregroundStyle(dark ? Color.white : (on ? Theme.primary : barInk))
                .background(RoundedRectangle(cornerRadius: 8).fill(background))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(item.help)
        .accessibilityLabel(item.help)
        .accessibilityAddTraits(on ? .isSelected : [])
        .background(GeometryReader { g in
            Color.clear.onAppear { frame = g.frame(in: .global) }.onChange(of: g.frame(in: .global)) { _, f in frame = f }
        })
    }

    private var background: Color {
        if dark { return hover ? Color.white.opacity(0.14) : .clear }
        if on { return Theme.primaryTint }
        return hover ? Color(hex: 0xECEAE5) : .clear
    }
}

/// Icons drawn from the design's 24-unit SVG paths.
struct MarkdownBarIcon: View {
    let item: MarkdownBarItem

    var body: some View {
        switch item {
        case .bold: Text("B").font(.system(size: 13, weight: .bold))
        case .italic: Text("I").font(.custom("Georgia-Italic", size: 14))
        case .strike: Text("S").font(.system(size: 13)).strikethrough()
        case .heading:
            HStack(spacing: 0) {
                Text("H").font(.system(size: 12, weight: .heavy))
                Text("▾").font(.system(size: 9, weight: .heavy)).offset(y: 1)
            }
        case .wikilink: Text("[[ ]]").font(.system(size: 11, weight: .heavy)).kerning(-0.5)
        case .link: Image(systemName: "link").font(.system(size: 13, weight: .semibold))
        case .quote: Image(systemName: "quote.opening").font(.system(size: 12, weight: .bold))
        case .bullet: IconCanvas { p in
                for y in [6.0, 12, 18] { p.move(to: .init(x: 9, y: y)); p.addLine(to: .init(x: 20, y: y)) }
            } fills: { p in
                for y in [6.0, 12, 18] { p.addEllipse(in: CGRect(x: 2.7, y: y - 1.3, width: 2.6, height: 2.6)) }
            }
        case .numbered:
            ZStack(alignment: .topLeading) {
                IconCanvas { p in
                    for y in [6.0, 12, 18] { p.move(to: .init(x: 10, y: y)); p.addLine(to: .init(x: 20, y: y)) }
                }
                VStack(alignment: .leading, spacing: -2.4) {
                    ForEach(["1", "2", "3"], id: \.self) { Text($0).font(.system(size: 4.6, weight: .bold)) }
                }
                .offset(x: 0.6, y: 1.2)
            }
            .frame(width: 15, height: 15)
        case .checklist: IconCanvas { p in
                p.addRoundedRect(in: CGRect(x: 3, y: 4, width: 7, height: 7), cornerSize: CGSize(width: 1.5, height: 1.5))
                p.move(to: .init(x: 4.5, y: 7.5)); p.addLine(to: .init(x: 6, y: 9)); p.addLine(to: .init(x: 9, y: 6))
                p.move(to: .init(x: 13, y: 7.5)); p.addLine(to: .init(x: 21, y: 7.5))
                p.addRect(CGRect(x: 3, y: 14, width: 7, height: 7))
                p.move(to: .init(x: 13, y: 17.5)); p.addLine(to: .init(x: 21, y: 17.5))
            }
        case .code: IconCanvas { p in
                p.move(to: .init(x: 8, y: 8)); p.addLine(to: .init(x: 4, y: 12)); p.addLine(to: .init(x: 8, y: 16))
                p.move(to: .init(x: 16, y: 8)); p.addLine(to: .init(x: 20, y: 12)); p.addLine(to: .init(x: 16, y: 16))
            }
        case .codeBlock: IconCanvas(lineWidth: 2) { p in
                p.addRoundedRect(in: CGRect(x: 3, y: 4, width: 18, height: 16), cornerSize: CGSize(width: 3, height: 3))
                p.move(to: .init(x: 9, y: 10)); p.addLine(to: .init(x: 7, y: 12)); p.addLine(to: .init(x: 9, y: 14))
                p.move(to: .init(x: 15, y: 10)); p.addLine(to: .init(x: 17, y: 12)); p.addLine(to: .init(x: 15, y: 14))
            }
        }
    }
}

/// A 15×15 icon from strokes (and optional fills) in a 24×24 space.
private struct IconCanvas: View {
    var lineWidth: CGFloat = 2.2
    var strokes: (inout Path) -> Void
    var fills: ((inout Path) -> Void)? = nil

    init(lineWidth: CGFloat = 2.2, _ strokes: @escaping (inout Path) -> Void, fills: ((inout Path) -> Void)? = nil) {
        self.lineWidth = lineWidth
        self.strokes = strokes
        self.fills = fills
    }

    var body: some View {
        Canvas { ctx, size in
            let s = size.width / 24
            ctx.scaleBy(x: s, y: s)
            var p = Path()
            strokes(&p)
            ctx.stroke(p, with: .foreground, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
            if let fills {
                var f = Path()
                fills(&f)
                ctx.fill(f, with: .foreground)
            }
        }
        .frame(width: 15, height: 15)
    }
}

// MARK: Heading menu

struct MarkdownHeadingMenu: View {
    var current: Int
    var choose: (Int) -> Void

    private let rows: [(Int, String, CGFloat)] = [(0, "Normal text", 13), (1, "Heading 1", 18), (2, "Heading 2", 15), (3, "Heading 3", 13)]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(rows, id: \.0) { row in
                HeadingRow(level: row.0, title: row.1, size: row.2, on: row.0 == current) { choose(row.0) }
            }
        }
        .padding(6)
        .frame(width: 170)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white))
        .compositingGroup()
        .shadow(color: Color(hex: 0x1D1C1A).opacity(0.18), radius: 13, y: 10)
    }

    private struct HeadingRow: View {
        let level: Int, title: String, size: CGFloat, on: Bool
        let action: () -> Void
        @State private var hover = false

        var body: some View {
            Button(action: action) {
                HStack {
                    Text(title).font(.system(size: size, weight: .bold, design: .rounded)).foregroundStyle(Theme.ink)
                    Spacer(minLength: 8)
                    Text("⌘⌥\(level)").font(.system(size: 10)).foregroundStyle(Theme.faint)
                }
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8).fill(on ? Theme.primaryTint : (hover ? Theme.panel : .clear)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hover = $0 }
        }
    }
}

// MARK: Selection bubble

struct MarkdownSelectionBubble: View {
    var perform: (MarkdownBarItem, CGRect) -> Void
    static let items: [MarkdownBarItem] = [.bold, .italic, .strike, .code, .link, .wikilink]

    var body: some View {
        HStack(spacing: 1) {
            ForEach(Self.items, id: \.self) { item in
                MarkdownBarButton(item: item, on: false, dark: true, perform: perform)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.ink))
        .compositingGroup()
        .shadow(color: Color(hex: 0x1D1C1A).opacity(0.25), radius: 10, y: 8)
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Style selection")
    }
}

// MARK: Link / note picker

/// ⌘K: a field for a URL or a note name, plus vault notes. `[[`: the note list only,
/// filtered by what is typed in the editor.
struct MarkdownLinkPopover: View {
    @ObservedObject var picker: MarkdownPickerState
    var showsField: Bool
    var commit: () -> Void
    var cancel: () -> Void
    @FocusState private var fieldFocused: Bool
    @Environment(\.snapshotMode) private var snapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsField && snapshot {
                Text(picker.query.isEmpty ? "Paste a link or type a note name…" : picker.query)
                    .font(.system(size: 12)).foregroundStyle(picker.query.isEmpty ? Theme.faint : Theme.ink)
                    .padding(.horizontal, 10).frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Theme.panel))
            } else if showsField {
                TextField("", text: $picker.query, prompt: Text("Paste a link or type a note name…").foregroundStyle(Theme.faint))
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .padding(.horizontal, 10).frame(height: 30)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Theme.panel))
                    .focused($fieldFocused)
                    .onSubmit(commit)
                    .onKeyPress(.downArrow) { picker.move(1); return .handled }
                    .onKeyPress(.upArrow) { picker.move(-1); return .handled }
                    .onExitCommand(perform: cancel)
                    .onAppear { fieldFocused = true }
            }
            if showsField && MarkdownCommands.looksLikeURL(picker.query) {
                HStack(spacing: 6) {
                    Image(systemName: "link").font(.system(size: 11, weight: .semibold))
                    Text("Link to \(MarkdownCommands.normalizedURL(picker.query))").lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    Text("↩").foregroundStyle(Theme.faint)
                }
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.primary)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.primaryTint))
            }
            Text("Notes in your vault").font(.system(size: 11)).foregroundStyle(Theme.muted)
            if picker.results.isEmpty {
                Text(picker.searching ? "Searching…" : (picker.query.isEmpty ? "Type a note name" : "No matching notes"))
                    .font(.system(size: 12)).foregroundStyle(Theme.faint)
                    .padding(.horizontal, 8).padding(.vertical, 3)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(picker.results.enumerated()), id: \.element.path) { i, page in
                        Button {
                            picker.index = i
                            picker.pickNote = true
                            commit()
                        } label: {
                            Text("[[\(page.title)]]").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.ink).lineLimit(1)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: 7).fill(highlighted(i) ? Theme.primaryTint : .clear))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, -8)
            }
        }
        .padding(10)
        .frame(width: 330, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white))
        .compositingGroup()
        .shadow(color: Color(hex: 0x1D1C1A).opacity(0.18), radius: 13, y: 10)
    }

    private func highlighted(_ i: Int) -> Bool {
        i == picker.index && !(showsField && MarkdownCommands.looksLikeURL(picker.query))
    }
}

/// What the note picker shows; shared by the popover and the editor's key handling.
@MainActor
final class MarkdownPickerState: ObservableObject {
    @Published var query = ""
    @Published var results: [PageRef] = []
    @Published var index = 0
    @Published var searching = false
    /// Set when a row was clicked (a note, even if the field holds a URL).
    var pickNote = false

    var selected: PageRef? { results.indices.contains(index) ? results[index] : nil }

    func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        index = (index + delta + results.count) % results.count
    }
}

// MARK: Aa toggle

/// Shows or hides a compact style bar (Ask, quick windows).
struct MarkdownBarToggle: View {
    @Binding var isOn: Bool
    var height: CGFloat = 24

    var body: some View {
        Button { isOn.toggle() } label: {
            Text("Aa").font(.system(size: height >= 26 ? 12 : 11, weight: .heavy))
                .foregroundStyle(isOn ? Theme.primary : barInk)
                .padding(.horizontal, height >= 26 ? 9 : 8).frame(height: height)
                .background(Capsule().fill(isOn ? Theme.primaryTint : Theme.panel))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(isOn ? "Hide text style bar" : "Show text style bar")
        .accessibilityLabel("Text style bar")
        .accessibilityValue(isOn ? "Shown" : "Hidden")
    }
}
