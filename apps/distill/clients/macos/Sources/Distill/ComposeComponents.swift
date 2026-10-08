import AppKit
import SwiftUI
import DistillKit

// Small controls shared by Write a note, the quick note, Labels and Settings.
// They are plain SwiftUI shapes (not AppKit-backed) so `--snapshot` renders
// them; text inputs swap for static text in snapshots.

/// The design's on/off switch (40×24, blue when on).
struct PillSwitch: View {
    @Binding var isOn: Bool
    var label: String
    var width: CGFloat = 40
    var height: CGFloat = 24

    var body: some View {
        Button { isOn.toggle() } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule().fill(isOn ? Theme.primary : Color(hex: 0xD6D3CC))
                Circle().fill(Color.white).padding(3)
                    .shadow(color: .black.opacity(0.12), radius: 1, y: 1)
            }
            .frame(width: width, height: height)
            .animation(.easeOut(duration: 0.12), value: isOn)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

/// The canvas SegmentedPills is the same component as Segmented (AskParts.swift).
typealias SegmentedPills<T: Hashable> = Segmented<T>

/// A white field-looking button with a ▾ that opens a menu. In snapshots the
/// menu is replaced by its label.
struct DropdownButton<Items: View>: View {
    let title: String
    var width: CGFloat? = nil
    var height: CGFloat = 32
    var radius: CGFloat = 10
    var font: Font = Theme.body(12, .semibold)
    /// A leading SF Symbol (the Filter and sort buttons of the Actions toolbar).
    var systemImage: String? = nil
    /// Filters are set: blue tint, blue ring, bold blue title ("Filter · 2").
    var active = false
    /// Set: a plain button that runs this (it opens a popover) instead of a menu of `items`.
    var action: (() -> Void)? = nil
    @ViewBuilder var items: Items
    @Environment(\.snapshotMode) private var snapshot

    var body: some View {
        if snapshot {
            face
        } else if let action {
            Button(action: action) { face }
                .buttonStyle(.plain)
                .fixedSize(horizontal: width == nil, vertical: true)
        } else {
            Menu { items } label: { face }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
                .fixedSize(horizontal: width == nil, vertical: true)
        }
    }

    private var face: some View {
        HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage).font(.system(size: 11, weight: .bold)).foregroundStyle(active ? Theme.primary : Theme.muted)
            }
            Text(title).font(active ? Theme.body(12, .bold) : font).lineLimit(1).foregroundStyle(active ? Theme.primary : Theme.ink)
            Spacer(minLength: systemImage == nil ? 4 : 0)
            Text("▾").font(Theme.body(11)).foregroundStyle(active ? Theme.primary : Theme.faint)
        }
        .padding(.horizontal, 10)
        .frame(width: width, height: height)
        .frame(maxWidth: width == nil && action == nil && systemImage == nil ? .infinity : nil)
        .background {
            if radius * 2 >= height { Capsule().fill(active ? Theme.primaryTint : Color.white) }
            else { RoundedRectangle(cornerRadius: radius).fill(active ? Theme.primaryTint : Color.white) }
        }
        .overlay {
            if radius * 2 >= height { Capsule().strokeBorder(active ? ActionsTheme.selectedStroke : Theme.border) }
            else { RoundedRectangle(cornerRadius: radius).strokeBorder(active ? ActionsTheme.selectedStroke : Theme.border) }
        }
        .contentShape(Rectangle())
    }
}

extension DropdownButton where Items == EmptyView {
    /// A dropdown-looking button that opens something other than a menu (the Filter popover).
    init(title: String, width: CGFloat? = nil, height: CGFloat = 32, radius: CGFloat = 10, font: Font = Theme.body(12, .semibold),
         systemImage: String? = nil, active: Bool = false, action: @escaping () -> Void) {
        self.init(title: title, width: width, height: height, radius: radius, font: font, systemImage: systemImage, active: active,
                  action: action, items: { EmptyView() })
    }
}

/// Plain text field without chrome; static text in snapshots.
struct BareTextField: View {
    let placeholder: String
    @Binding var text: String
    var font: Font = Theme.body(13)
    var color: Color = Theme.ink
    var onSubmit: () -> Void = {}
    @Environment(\.snapshotMode) private var snapshot

    var body: some View {
        if snapshot {
            Text(text.isEmpty ? placeholder : text).font(font)
                .foregroundStyle(text.isEmpty ? Theme.faint : color)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain).font(font).foregroundStyle(color)
                .onSubmit(onSubmit)
        }
    }
}

// BareTextEditor (Markdown note text) lives in MarkdownEditor.swift.

/// A label chip. Suggested chips are dashed (green = existing, peach = new);
/// confirmed ones are solid.
struct LabelChip: View {
    enum Style { case suggestedExisting, suggestedNew, plain, muted }
    let name: String
    var style: Style = .plain
    var sparkle = false
    var height: CGFloat = 26
    var showNewTag = true
    var onRemove: (() -> Void)? = nil
    var onTap: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 4) {
            Text((sparkle ? "✦ " : "") + "#" + name).font(Theme.body(12, .semibold)).lineLimit(1)
            if style == .suggestedNew && showNewTag {
                Text("new").font(Theme.body(10, .bold)).opacity(0.7)
            }
            if let onRemove {
                Button(action: onRemove) {
                    Text("×").font(Theme.body(13)).frame(width: 16, height: 16).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(name)")
            }
        }
        .padding(.leading, 10).padding(.trailing, onRemove == nil ? 10 : 4)
        .frame(height: height)
        .foregroundStyle(ink)
        .background(Capsule().fill(fill))
        .overlay(border)
        .contentShape(Capsule())
        .onTapGesture { onTap?() }
    }

    private var ink: Color {
        switch style {
        case .suggestedExisting: return Theme.limeInk
        case .suggestedNew: return Theme.peachInk
        case .plain: return Theme.primary
        case .muted: return Theme.faint
        }
    }

    private var fill: Color {
        switch style {
        case .suggestedExisting: return Color(hex: 0xF3FDE4)
        case .suggestedNew: return Color(hex: 0xFFF4EE)
        case .plain: return Theme.primaryTint
        case .muted: return Theme.panel
        }
    }

    @ViewBuilder private var border: some View {
        switch style {
        case .suggestedExisting: Capsule().strokeBorder(Theme.lime, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
        case .suggestedNew: Capsule().strokeBorder(Theme.peach, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
        case .muted: Capsule().strokeBorder(Theme.border, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
        case .plain: EmptyView()
        }
    }
}

/// "+ label" inline input: Return adds what was typed.
struct AddLabelField: View {
    var placeholder = "+ label"
    var width: CGFloat = 80
    var height: CGFloat = 26
    let onAdd: (String) -> Bool
    @State private var text = ""

    var body: some View {
        BareTextField(placeholder: placeholder, text: $text, font: Theme.body(12)) {
            if onAdd(text) { text = "" }
        }
        .padding(.horizontal, 10)
        .frame(width: width, height: height)
        .background(Capsule().fill(Theme.panel))
    }
}

/// " · 0:41" after 3 s (nothing before), for status lines that continue after it.
struct ElapsedSuffix: View {
    let start: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let seconds = max(0, Int(context.date.timeIntervalSince(start)))
            if seconds >= 3 { Text(" · " + ElapsedText.format(seconds)).monospacedDigit() }
        }
    }
}

/// Small rounded button used across these screens (Skip, Confirm, Retry…).
struct SmallButton: View {
    let title: String
    var fill: Color = Theme.panel
    var ink: Color = Theme.ink
    var height: CGFloat = 30
    var weight: Font.Weight = .semibold
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).font(Theme.body(12, weight)).lineLimit(1)
                .padding(.horizontal, 12).frame(height: height)
                .foregroundStyle(ink)
                .background(Capsule().fill(fill))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
