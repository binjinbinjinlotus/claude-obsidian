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

/// Two or more options in a white rounded track; the chosen one is filled blue.
struct SegmentedPills<T: Hashable>: View {
    let options: [(T, String)]
    @Binding var selection: T
    var height: CGFloat = 24
    var font: Font = Theme.body(12, .bold)
    var track: Color = .white

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { option in
                let on = option.0 == selection
                Button { selection = option.0 } label: {
                    Text(option.1).font(font).lineLimit(1)
                        .padding(.horizontal, 10).frame(height: height)
                        .foregroundStyle(on ? Color.white : Theme.muted)
                        .background(RoundedRectangle(cornerRadius: height / 2).fill(on ? Theme.primary : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: height / 2 + 2).fill(track))
        .overlay(RoundedRectangle(cornerRadius: height / 2 + 2).strokeBorder(Theme.border))
    }
}

/// A white field-looking button with a ▾ that opens a menu. In snapshots the
/// menu is replaced by its label.
struct DropdownButton<Items: View>: View {
    let title: String
    var width: CGFloat? = nil
    var height: CGFloat = 32
    var radius: CGFloat = 10
    var font: Font = Theme.body(12, .semibold)
    @ViewBuilder var items: Items
    @Environment(\.snapshotMode) private var snapshot

    var body: some View {
        if snapshot {
            face
        } else {
            Menu { items } label: { face }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
                .fixedSize(horizontal: width == nil, vertical: true)
        }
    }

    private var face: some View {
        HStack(spacing: 6) {
            Text(title).font(font).lineLimit(1).foregroundStyle(Theme.ink)
            Spacer(minLength: 4)
            Text("▾").font(Theme.body(11)).foregroundStyle(Theme.faint)
        }
        .padding(.horizontal, 10)
        .frame(width: width, height: height)
        .frame(maxWidth: width == nil ? .infinity : nil)
        .background(RoundedRectangle(cornerRadius: radius).fill(Color.white))
        .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(Theme.border))
        .contentShape(Rectangle())
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

/// Multi-line note text; static text in snapshots.
struct BareTextEditor: View {
    let placeholder: String
    @Binding var text: String
    var font: Font = Theme.body(15)
    var minHeight: CGFloat = 48
    var maxHeight: CGFloat = 120
    @Environment(\.snapshotMode) private var snapshot

    var body: some View {
        if snapshot {
            Text(text.isEmpty ? placeholder : text).font(font).lineSpacing(5)
                .foregroundStyle(text.isEmpty ? Theme.faint : Color(hex: 0x2A2925))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .topLeading)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder).font(font).foregroundStyle(Theme.faint).padding(.leading, 5).allowsHitTesting(false)
                }
                TextEditor(text: $text)
                    .font(font).lineSpacing(5)
                    .scrollContentBackground(.hidden)
                    .foregroundStyle(Color(hex: 0x2A2925))
            }
            .frame(minHeight: minHeight, maxHeight: maxHeight)
        }
    }
}

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
