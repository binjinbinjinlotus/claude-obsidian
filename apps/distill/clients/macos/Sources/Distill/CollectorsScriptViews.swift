import AppKit
import SwiftUI
import DistillKit

// Collectors v6 components of the design schema (components.json): ScriptEditor (the Script field of
// a custom collector's Edit form and Add step 2) and PackagesPanel (a kept script's package manifest
// with Install). Each keeps the schema's name and props; the screen feeds them.

/// The schema's language names ↔ the core's interpreters.
enum ScriptLanguage {
    static let all: [(String, String)] = [("zsh", "zsh"), ("python", "Python"), ("javascript", "JavaScript"), ("typescript", "TypeScript")]

    static func of(_ i: CollectorInterpreter) -> String {
        switch i.rawValue {
        case "python3": return "python"
        case "node": return "javascript"
        case "typescript": return "typescript"
        default: return "zsh"
        }
    }

    static func interpreter(_ language: String) -> CollectorInterpreter {
        switch language {
        case "python": return .python3
        case "javascript": return .node
        case "typescript": return .typescript
        default: return .zsh
        }
    }
}

// MARK: - ScriptEditor

/// The language picker, where the file lives (Reveal in Finder, Open in editor), and the code of a
/// script Distill keeps. Your own file shows its path with Choose… and no code box.
struct ScriptEditor: View {
    /// zsh | python | javascript | typescript
    var language: String
    /// managed | external
    var source: String = "managed"
    /// The file (absolute or with ~); empty for your own file not chosen yet.
    var path: String = ""
    @Binding var code: String
    var width: CGFloat? = nil
    /// Narrow pane: "Reveal" and "Open".
    var compact = false
    /// The file exists yet (a new script's path is where it will be: no Reveal or Open).
    var fileExists = true
    var onLanguage: (String) -> Void = { _ in }
    var onReveal: () -> Void = {}
    var onOpen: () -> Void = {}
    var onChoose: () -> Void = {}

    private var external: Bool { source == "external" }

    private var runsWith: String {
        if external { return "your own file" }
        switch language {
        case "python": return "python3 · packages from requirements.txt"
        case "javascript": return "node · packages from package.json"
        case "typescript": return "node, types stripped · packages from package.json"
        default: return "zsh"
        }
    }

    private var hint: String {
        if external { return "Your own file: Distill runs it from there and asks again when it changes. Packages are yours to install." }
        if language == "typescript" { return "Runs on your Node (22.6 or later) with the types stripped. For enums or decorators, add tsx to package.json." }
        return "Saved as a real file in the collector’s folder, so you can edit it in any editor. A saved change asks for your OK again."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    picker
                    Spacer(minLength: 8)
                    Text(runsWith).font(Theme.body(11.5)).foregroundStyle(Theme.faint).lineLimit(1).fixedSize()
                }
                VStack(alignment: .leading, spacing: 6) {
                    picker
                    Text(runsWith).font(Theme.body(11.5)).foregroundStyle(Theme.faint).lineLimit(1)
                }
            }
            HStack(spacing: 6) {
                Image(systemName: "doc").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.faint)
                Text(path.isEmpty ? "No file chosen" : CollectorText().tilde(path))
                    .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(path.isEmpty ? Theme.faint : CollectorsTheme.body)
                    .lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(CollectorText().expand(path))
                if fileExists, !path.isEmpty {
                    link(compact ? "Reveal" : "Reveal in Finder", onReveal)
                    link(compact ? "Open" : "Open in editor", onOpen)
                }
                if external { link("Choose…", onChoose) }
            }
            if !external {
                CodeEditor(text: $code, minLines: 5, maxHeight: 300)
            }
            Hint(hint)
        }
        .frame(width: width, alignment: .leading)
        .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
    }

    private var picker: some View {
        SegmentedPills(options: ScriptLanguage.all, selection: Binding(get: { language }, set: { onLanguage($0) }), height: 26, track: Theme.panel)
    }

    private func link(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(Theme.body(12, .semibold)).foregroundStyle(Theme.primary).lineLimit(1).fixedSize()
                .padding(.horizontal, 4).frame(height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - PackagesPanel

/// A kept script's package manifest (package.json → npm into node_modules/, requirements.txt → pip
/// into .venv/), one status line, Install (or Stop while installing) and ⋯ (Clean reinstall, Open in
/// editor). In the Edit form the manifest is editable; in the consent card it is read-only.
struct PackagesPanel: View {
    /// package.json | requirements.txt
    var manifest: String = "package.json"
    /// none | ready | needsInstall | installing | failed (as the core reports) | needsOK (the change waits for the OK)
    var state: String = "ready"
    /// The manifest's text (read-only); a line starting with "+" is drawn as added.
    var lines: String = ""
    /// Install output lines (installing, failed, or `expanded`).
    var output: [String] = []
    /// The status line (defaults from the state).
    var summary: String = ""
    var expanded = false
    var width: CGFloat? = nil
    /// Edit form: the manifest as an editable field instead of `lines`.
    var text: Binding<String>? = nil
    /// Install is offered (nil hides Install, Stop and ⋯, as in Add).
    var onInstall: (() -> Void)? = nil
    var installEnabled = true
    var onStop: () -> Void = {}
    var onCleanInstall: (() -> Void)? = nil
    var onOpen: (() -> Void)? = nil

    private var py: Bool { manifest == "requirements.txt" }

    private var statusInk: Color {
        switch state {
        case "none": return Theme.muted
        case "ready": return Theme.limeInk
        case "installing": return Theme.primary
        case "failed": return Theme.peachInk
        case "needsOK": return CollectorsTheme.amberInk
        default: return Theme.ink
        }
    }

    private var defaultSummary: String {
        switch state {
        case "none": return "No packages. Add one to install it into this folder."
        case "ready": return "Installed · ready"
        case "needsInstall": return "Not installed yet · Install now, or it installs before the next run"
        case "installing": return "Installing…"
        case "failed": return "Couldn’t install · runs wait until it installs"
        case "needsOK": return "Changed · installs when you allow it"
        default: return ""
        }
    }

    private var hint: String {
        if state == "needsOK" { return "Installing runs code from the package’s authors, so a change to \(manifest) asks first, like the script." }
        return py ? "Installed with pip into .venv/ in the collector’s folder; the script runs with that Python."
            : "Installed with npm into node_modules/ in the collector’s folder."
    }

    private var showOutput: Bool { !output.isEmpty && (state == "installing" || state == "failed" || expanded) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // The status beside the manifest name while it fits; on its own line in a narrow pane.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { chip; statusText.fixedSize(); Spacer(minLength: 0); controls }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) { chip; Spacer(minLength: 0); controls }
                    statusText.fixedSize(horizontal: false, vertical: true)
                }
            }
            editorOrLines
            if showOutput { outputBox }
            Hint(hint)
        }
        .frame(width: width, alignment: .leading)
        .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
    }

    private var chip: some View {
        Text(manifest).font(.system(size: 11.5, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.ink)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.panel))
            .fixedSize()
    }

    private var statusText: some View {
        HStack(spacing: 6) {
            if state == "installing" { Spinner(size: 11) }
            Text(summary.isEmpty ? defaultSummary : summary).font(Theme.body(12)).foregroundStyle(statusInk)
                .help(summary.isEmpty ? defaultSummary : summary)
        }
    }

    @ViewBuilder private var controls: some View {
        HStack(spacing: 8) {
                if let onInstall {
                    if state == "installing" {
                        SoftButton(title: "Stop", fill: .white, size: .small, stroke: true, systemImage: "xmark", action: onStop).fixedSize()
                    } else {
                        SoftButton(title: "Install", fill: .white, size: .small, stroke: true, systemImage: "square.and.arrow.down", action: onInstall)
                            .fixedSize()
                            .disabled(!installEnabled || state == "needsOK" || state == "none")
                            .opacity(!installEnabled || state == "needsOK" || state == "none" ? 0.45 : 1)
                    }
                    if onCleanInstall != nil || onOpen != nil {
                        Menu {
                            if let onCleanInstall { Button("Clean reinstall…", action: onCleanInstall).disabled(state == "installing" || state == "needsOK") }
                            if let onOpen { Button("Open \(manifest) in editor", action: onOpen) }
                        } label: {
                            Image(systemName: "ellipsis").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.muted)
                                .frame(width: 26, height: 26).contentShape(Circle())
                        }
                        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                        .help("Clean reinstall, Open in editor")
                    }
                }
        }
    }

    @ViewBuilder private var editorOrLines: some View {
        if let text {
            CodeEditor(text: text, minLines: 3, maxHeight: 220, stroke: state == "needsOK" ? Color(hex: 0xF5D98B) : Theme.border,
                       strokeWidth: 1, placeholder: py ? "# one package per line, e.g. requests>=2.32" : "{ \"dependencies\": {} }")
        } else {
            ManifestLines(text: lines, empty: py ? "# one package per line, e.g. requests>=2.32" : "{ \"dependencies\": {} }",
                          stroke: state == "needsOK" ? Color(hex: 0xF5D98B) : Theme.border)
        }
    }

    private var outputBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(state == "failed" ? "INSTALL OUTPUT · STDERR" : "INSTALL OUTPUT").font(Theme.body(10, .heavy)).kerning(0.6)
                    .foregroundStyle(state == "failed" ? Theme.peachInk : Theme.faint)
                Spacer()
                CopyOutputButton(lines: output)
            }
            TerminalLines(lines: Array(output.suffix(8)), stderr: false)
        }
    }
}

/// A manifest drawn read-only with line numbers; "+" lines are tinted as added.
struct ManifestLines: View {
    var text: String
    var empty: String
    var stroke: Color = Theme.border

    var body: some View {
        let raw = text.components(separatedBy: "\n")
        let lines = raw.last == "" ? Array(raw.dropLast()) : raw
        VStack(alignment: .leading, spacing: 0) {
            if text.isEmpty {
                row(1, empty, ink: Theme.faint, added: false)
            } else {
                ForEach(Array(lines.prefix(200).enumerated()), id: \.offset) { i, line in
                    let added = line.hasPrefix("+")
                    row(i + 1, added ? String(line.dropFirst()) : line, ink: Theme.ink, added: added)
                }
            }
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(stroke))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .textSelection(.enabled)
    }

    private func row(_ n: Int, _ s: String, ink: Color, added: Bool) -> some View {
        HStack(spacing: 12) {
            Text("\(n)").foregroundStyle(Color(hex: 0xC2BEB6)).frame(width: 16, alignment: .trailing)
            Text(s.isEmpty ? " " : s).foregroundStyle(ink).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .font(.system(size: 11.5, design: .monospaced))
        .frame(height: 18)
        .padding(.horizontal, 12)
        .background(added ? Color(hex: 0xF3FDE4) : .clear)
    }
}

/// "Copy output" (turns into "Copied" for two seconds).
struct CopyOutputButton: View {
    var lines: [String]
    var title = "Copy output"
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
        } label: {
            Text(copied ? "Copied" : title).font(Theme.body(11, .semibold)).foregroundStyle(copied ? Theme.limeInk : Theme.primary)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Plain code text view

/// An NSTextView for code: monospaced, no smart quotes, dashes, spelling or link detection.
struct PlainCodeView: NSViewRepresentable {
    @Binding var text: String
    var font: NSFont

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        guard let tv = scroll.documentView as? NSTextView else { return scroll }
        tv.delegate = context.coordinator
        tv.font = font
        tv.textColor = NSColor(Theme.ink)
        tv.drawsBackground = false
        tv.isRichText = false
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.isGrammarCheckingEnabled = false
        tv.smartInsertDeleteEnabled = false
        tv.textContainerInset = NSSize(width: 0, height: 0)
        tv.textContainer?.lineFragmentPadding = 5
        // No wrapping: one text line per numbered line; long lines scroll sideways.
        scroll.hasHorizontalScroller = true
        tv.isHorizontallyResizable = true
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.string = text
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.text = $text
        guard let tv = scroll.documentView as? NSTextView, tv.string != text else { return }
        let selected = tv.selectedRanges.map(\.rangeValue)
        tv.string = text
        // AppKit throws on an empty selection list, and the text can come back shorter (a save or reload),
        // so ranges are clamped to the new text, never dropped.
        tv.selectedRanges = Self.clampedSelection(selected, length: (text as NSString).length).map { NSValue(range: $0) }
    }

    /// The old selection fitted to text of `length` UTF-16 units: each range clamped, duplicates removed,
    /// and never empty (the caret goes to the end when nothing is left).
    static func clampedSelection(_ ranges: [NSRange], length: Int) -> [NSRange] {
        var out: [NSRange] = []
        for r in ranges {
            let start = min(max(r.location, 0), length)
            let end = min(max(r.location + r.length, start), length)
            let c = NSRange(location: start, length: end - start)
            if !out.contains(where: { NSEqualRanges($0, c) }) { out.append(c) }
        }
        if out.count > 1 { out.removeAll { $0.length == 0 } }
        return out.isEmpty ? [NSRange(location: length, length: 0)] : out
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            text.wrappedValue = tv.string
        }
    }
}
