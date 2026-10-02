import AppKit
import SwiftUI
import DistillKit

// The shared Markdown editor (docs/specs/markdown-editing.md): plain Markdown
// text styled live, an optional style bar, the selection bubble, the link and
// note picker, and the shortcuts. Used by Write a note, the quick note, Ask,
// quick ask and the Review reply box.

/// Which bar an editor shows.
enum MarkdownBarStyle: Equatable {
    case none
    /// Always shown, every button (Write a note).
    case full
    /// Always shown, the common buttons (Review reply).
    case compact
    /// Compact, shown when the quick windows' Aa is on (`distill.markdownBar.quick`).
    case quick
    /// Compact, shown when Ask's Aa is on (`distill.markdownBar.ask`).
    case ask
}

enum MarkdownBarKeys {
    static let quick = "distill.markdownBar.quick"
    static let ask = "distill.markdownBar.ask"
}

private struct MarkdownBarOverrideKey: EnvironmentKey {
    static let defaultValue: Bool? = nil
}

private struct MarkdownFixtureKey: EnvironmentKey {
    static let defaultValue: MarkdownEditorFixture? = nil
}

extension EnvironmentValues {
    /// Forces the Aa bars on or off (snapshots), instead of the stored preference.
    var markdownBarOverride: Bool? {
        get { self[MarkdownBarOverrideKey.self] }
        set { self[MarkdownBarOverrideKey.self] = newValue }
    }

    /// Snapshot state for editors below (cursor styles, a highlighted selection).
    var markdownFixture: MarkdownEditorFixture? {
        get { self[MarkdownFixtureKey.self] }
        set { self[MarkdownFixtureKey.self] = newValue }
    }
}

/// What a `--snapshot` editor shows that the live one gets from the cursor.
struct MarkdownEditorFixture {
    var active = MarkdownParser.ActiveStyles()
    var pressed: MarkdownBarItem? = nil
    var highlight: NSRange? = nil
}

struct MarkdownEditor: View {
    @Binding var text: String
    var placeholder: String = ""
    var textSize: CGFloat = 13
    var minHeight: CGFloat = 0
    /// .infinity: report the full content height, never scroll.
    var maxHeight: CGFloat = .infinity
    var minLines: Int = 1
    var maxLines: Int? = nil
    /// Take the height offered from outside (at least minHeight) and scroll inside, with a fade at the cut edge.
    var fillsHeight = false
    var bar: MarkdownBarStyle = .none
    var barSpacing: CGFloat = 10
    var submit: MarkdownSubmitMode = .commandReturn
    var onSubmit: (() -> Void)? = nil
    var autoFocus = false
    var disabled = false
    var onHeightChange: ((CGFloat) -> Void)? = nil
    /// Put the text (not the bar) on a gray rounded box.
    var textBox = false

    @StateObject private var controller = MarkdownEditorController()
    @AppStorage(MarkdownBarKeys.quick) private var quickBar = false
    @AppStorage(MarkdownBarKeys.ask) private var askBar = false
    @Environment(\.markdownBarOverride) private var barOverride
    @Environment(\.markdownFixture) private var fixture
    @Environment(\.snapshotMode) private var snapshot

    private var barVariant: MarkdownBarVariant? {
        switch bar {
        case .none: return nil
        case .full: return .full
        case .compact: return .compact
        case .quick: return (barOverride ?? quickBar) ? .compact : nil
        case .ask: return (barOverride ?? askBar) ? .compact : nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: barSpacing) {
            if let variant = barVariant {
                MarkdownStyleBar(variant: variant, active: snapshot ? (fixture?.active ?? .init()) : controller.active,
                                 pressed: snapshot ? fixture?.pressed : nil) { item, frame in
                    controller.barAction(item, frame: frame)
                }
                .disabled(disabled)
                .opacity(disabled ? 0.5 : 1)
            }
            Group { if snapshot { snapshotText } else { liveText } }
                .padding(textBox ? 12 : 0)
                .background { if textBox { RoundedRectangle(cornerRadius: 14).fill(Theme.panel) } }
        }
        .frame(maxHeight: fillsHeight ? .infinity : nil, alignment: .top)
    }

    // MARK: Live

    private var lineH: CGFloat { controller.lineHeight }
    private var insets: CGFloat { MarkdownEditorController.inset * 2 }
    private var minH: CGFloat { max(minHeight, lineH * CGFloat(minLines) + insets) }
    private var maxH: CGFloat {
        let byLines = maxLines.map { lineH * CGFloat($0) + insets } ?? .infinity
        return max(minH, min(maxHeight, byLines))
    }
    private var fitted: CGFloat { min(max(controller.contentHeight, minH), maxH) }
    private var scrolls: Bool { fillsHeight || controller.contentHeight > maxH + 0.5 }

    private var liveText: some View {
        // The closure captures fresh state each render.
        controller.onSubmit = onSubmit
        controller.submitMode = submit
        return MarkdownTextArea(text: $text, controller: controller, size: textSize, placeholder: placeholder,
                         editable: !disabled, scrolls: scrolls, autoFocus: autoFocus)
            .frame(height: fillsHeight ? nil : fitted)
            .frame(minHeight: fillsHeight ? minH : nil, maxHeight: fillsHeight ? .infinity : nil)
            .mask(fade)
            .opacity(disabled ? 0.6 : 1)
            .onChange(of: controller.contentHeight) { _, h in onHeightChange?(h) }
    }

    /// A soft fade where scrolled text is cut off (not at the end).
    private var fade: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color.black)
            if scrolls && !controller.atBottom {
                LinearGradient(colors: [.black, .black.opacity(0)], startPoint: .top, endPoint: .bottom).frame(height: 18)
            }
        }
    }

    // MARK: Snapshot

    private var snapshotText: some View {
        MarkdownStyledText(text: text, size: textSize, placeholder: placeholder, highlight: fixture?.highlight)
            .frame(maxWidth: .infinity, minHeight: minH, alignment: .topLeading)
            .frame(maxHeight: fillsHeight ? .infinity : nil, alignment: .topLeading)
    }
}

// MARK: - The inputs the app uses

/// Multi-line note text (Write a note, quick note): Markdown, ⌘Return submits.
/// `bar`: Write a note passes `.full`; the quick note's default `.quick` follows its Aa.
struct BareTextEditor: View {
    let placeholder: String
    @Binding var text: String
    /// Kept for existing callers; the editor's size is `textSize`.
    var font: Font = Theme.body(15)
    var minHeight: CGFloat = 48
    var maxHeight: CGFloat = 120
    var bar: MarkdownBarStyle = .quick
    var fillsHeight = false
    var textSize: CGFloat = 13
    var onSubmit: (() -> Void)? = nil
    var onHeightChange: ((CGFloat) -> Void)? = nil

    var body: some View {
        MarkdownEditor(text: $text, placeholder: placeholder, textSize: textSize, minHeight: minHeight, maxHeight: maxHeight,
                       fillsHeight: fillsHeight, bar: bar, barSpacing: bar == .full ? 14 : 10,
                       submit: .commandReturn, onSubmit: onSubmit, onHeightChange: onHeightChange)
    }
}

/// The question field (Ask, quick ask): Markdown, Return sends, ⇧Return adds a line,
/// 1–5 lines then it scrolls. `bar`: Ask passes `.ask`; quick ask's default `.quick` follows its Aa.
struct QuestionField: View {
    @Binding var text: String
    let placeholder: String
    var size: CGFloat = 15
    var disabled = false
    var bar: MarkdownBarStyle = .quick
    let submit: () -> Void

    var body: some View {
        MarkdownEditor(text: $text, placeholder: placeholder, textSize: size, minLines: 1, maxLines: 5,
                       bar: bar, barSpacing: 8, submit: .returnKey, onSubmit: submit, autoFocus: true, disabled: disabled)
            // Wrap at the available width; never ask for the text's own width (it would widen the window).
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Review: "Reply to Claude". A compact bar, always shown, above the gray reply box.
struct ReplyEditor: View {
    @Binding var text: String

    var body: some View {
        MarkdownEditor(text: $text, placeholder: "e.g. Add this to the Green tea page instead", textSize: 13,
                       minHeight: 52, maxHeight: 140, bar: .compact, barSpacing: 10, submit: .commandReturn, textBox: true)
    }
}

/// The Aa button bound to a stored bar preference (`MarkdownBarKeys`); snapshots
/// follow `markdownBarOverride` instead.
struct MarkdownBarAaButton: View {
    @AppStorage private var on: Bool
    var height: CGFloat
    @Environment(\.markdownBarOverride) private var barOverride

    init(key: String, height: CGFloat = 24) {
        _on = AppStorage(wrappedValue: false, key)
        self.height = height
    }

    var body: some View {
        MarkdownBarToggle(isOn: Binding(get: { barOverride ?? on }, set: { on = $0 }), height: height)
    }
}
