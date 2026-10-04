import AppKit
import SwiftUI
import DistillKit

// The five Collectors components of the design schema (components.json):
// CollectorRow, QueuePath, ScheduleField, RunLogEntry and ScriptConsent. Each
// keeps the schema's name and props; the screen (CollectorsScreen.swift) feeds them.

enum CollectorsTheme {
    static let scriptTint = Color(hex: 0xEDE7FF)
    static let scriptInk = Color(hex: 0x5B3FC4)
    static let amberTint = Color(hex: 0xFFF4D6)
    static let amberInk = Color(hex: 0x8A5A00)
    static let selectedFill = Color(hex: 0xF2F7FF)
    static let selectedStroke = Color(hex: 0xBFD5FA)
    static let errorFill = Color(hex: 0xFFF1EA)
    static let errorStroke = Color(hex: 0xFFD9C6)
    static let runningFill = Color(hex: 0xEEF4FF)
    static let body = Color(hex: 0x48463F)
    static let terminal = Color(hex: 0x1F1E1C)
    static let terminalInk = Color(hex: 0xE8E6E1)
    static let mono = Font.system(size: 11, design: .monospaced)

    /// (tile fill, tile ink, SF Symbol) for a kind.
    static func kind(_ kind: String) -> (Color, Color, String) {
        kind == "script" ? (scriptTint, scriptInk, "terminal") : (Theme.limeTint, Theme.limeInk, "folder")
    }
}

/// Snapshots: folders count as present (renders never depend on the real file system).
private struct FixtureFoldersKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var fixtureFolders: Bool {
        get { self[FixtureFoldersKey.self] }
        set { self[FixtureFoldersKey.self] = newValue }
    }
}

// MARK: - CollectorRow

/// One collector in the list: kind tile, name, one status line, and a pill only
/// for Running, Failed and Needs your OK. Off rows are dimmed. Hover shows Run now and ⋯.
struct CollectorRow<MenuItems: View>: View {
    /// "folder" or "script".
    var kind: String
    var title: String
    var summary: String
    /// The pill text (Running, Failed, Needs your OK).
    var status: String = ""
    /// on | off | running | error | consent
    var statusKind: String = "on"
    var selected = false
    /// Drawn hovered (snapshots); the row also tracks the pointer.
    var hover = false
    var width: CGFloat? = nil
    var runEnabled = true
    var onSelect: () -> Void = {}
    var onRun: (() -> Void)? = nil
    @ViewBuilder var menu: MenuItems
    @State private var hovered = false

    private var bad: Bool { statusKind == "error" || statusKind == "consent" }
    private var statusColors: (Color, Color) {
        switch statusKind {
        case "running": return (Theme.primaryTint, Theme.primary)
        case "error": return (Theme.peachTint, Theme.peachInk)
        case "consent": return (CollectorsTheme.amberTint, CollectorsTheme.amberInk)
        case "off": return (Theme.panel, Theme.muted)
        default: return (Color(hex: 0xF3FDE4), Theme.limeInk)
        }
    }

    var body: some View {
        let k = CollectorsTheme.kind(kind)
        let showHover = (hover || hovered) && !selected
        HStack(spacing: 10) {
            Image(systemName: k.2).font(.system(size: 12, weight: .semibold)).foregroundStyle(k.1)
                .frame(width: 28, height: 28).background(RoundedRectangle(cornerRadius: 8).fill(k.0))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Theme.body(13, .semibold)).foregroundStyle(Theme.ink).lineLimit(1)
                Text(summary).font(Theme.body(11)).foregroundStyle(bad ? statusColors.1 : Theme.muted).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if showHover, onRun != nil || MenuItems.self != EmptyView.self {
                HStack(spacing: 2) {
                    if let onRun, runEnabled {
                        IconButton(systemImage: "play.fill", tint: Theme.primary, iconSize: 10, help: "Run now", action: onRun)
                    }
                    Menu { menu } label: {
                        Image(systemName: "ellipsis").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.muted)
                            .frame(width: 26, height: 26).contentShape(Circle())
                    }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                    .help("More")
                }
            } else if !status.isEmpty, statusKind == "running" || bad {
                Pill(text: status, fill: statusColors.0, ink: statusColors.1, size: .small, busy: statusKind == "running")
            }
        }
        .padding(.leading, 12).padding(.trailing, 10).padding(.vertical, 10)
        .frame(width: width)
        .frame(maxWidth: width == nil ? .infinity : nil)
        .background(RoundedRectangle(cornerRadius: 12).fill(selected ? CollectorsTheme.selectedFill : showHover ? Theme.panel : .clear))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(CollectorsTheme.selectedStroke, lineWidth: selected ? 1.5 : 0))
        .opacity(statusKind == "off" && !selected ? 0.6 : 1)
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture(perform: onSelect)
        .onHover { hovered = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }
}

// MARK: - QueuePath

/// A queue folder's path with Copy path and Reveal in Finder. Shown with `~`,
/// truncated in the middle; hover and Copy give the absolute path. Missing: peach, with Create folder.
struct QueuePath: View {
    /// The absolute path.
    var path: String
    var label: String = ""
    /// default | hover | copied | missing (snapshots force one; the app derives hover, copied and missing).
    var state: String = "default"
    /// regular | compact
    var size: String = "regular"
    var width: CGFloat? = nil
    var onCreate: (() -> Void)? = nil
    @State private var hovered = false
    @State private var copiedAt: Date?
    @Environment(\.fixtureFolders) private var fixtureFolders

    private var compact: Bool { size == "compact" }
    private var font: Font { Theme.body(compact ? 12 : 12.5, .medium) }
    private var missing: Bool {
        state == "missing" || (state == "default" && !fixtureFolders && !path.isEmpty && !FileManager.default.fileExists(atPath: path))
    }
    private var copied: Bool { state == "copied" || copiedAt != nil }
    private var shown: String { CollectorText().tilde(path) }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder").font(.system(size: 12, weight: .medium)).foregroundStyle(missing ? Theme.peachInk : Theme.faint)
            if !label.isEmpty { Text(label).font(Theme.body(compact ? 12 : 12.5)).foregroundStyle(Theme.faint).fixedSize() }
            Text(shown).font(font).foregroundStyle(missing ? Theme.peachInk : CollectorsTheme.body)
                .lineLimit(1).truncationMode(.middle)
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 5).fill(state == "hover" || hovered ? Color(hex: 0xEFEDE8) : .clear))
                .onHover { hovered = $0 }
                .help(path)
                .layoutPriority(-1)
            if missing {
                Text("is missing").font(Theme.body(compact ? 12 : 12.5, .semibold)).foregroundStyle(Theme.peachInk).fixedSize()
                if let onCreate {
                    Button(action: onCreate) {
                        Text("Create folder").font(Theme.body(compact ? 12 : 12.5, .semibold)).foregroundStyle(Theme.primary)
                            .padding(.horizontal, 8).frame(height: 26).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).fixedSize()
                }
            } else {
                HStack(spacing: 0) {
                    Button(action: copy) {
                        HStack(spacing: 4) {
                            Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 10, weight: .bold))
                            Text(copied ? "Copied" : (compact ? "Copy" : "Copy path")).font(Theme.body(compact ? 12 : 12.5, .semibold))
                        }
                        .foregroundStyle(copied ? Theme.limeInk : Theme.primary)
                        .padding(.horizontal, 8).frame(height: 26)
                        .background(Capsule().fill(copied ? Color(hex: 0xF3FDE4) : .clear))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Copy \(path)")
                    Button(action: reveal) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.up.forward.square").font(.system(size: 10, weight: .bold))
                            Text(compact ? "Reveal" : "Reveal in Finder").font(Theme.body(compact ? 12 : 12.5, .semibold))
                        }
                        .foregroundStyle(Theme.primary)
                        .padding(.horizontal, 8).frame(height: 26)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Show the folder in Finder")
                }
                .fixedSize()
            }
        }
        .frame(width: width, alignment: .leading)
        .frame(height: 28)
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
        let at = Date()
        copiedAt = at
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { if copiedAt == at { copiedAt = nil } }
    }

    private func reveal() {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}

// MARK: - ScheduleField

/// One schedule control: a preset, a time for daily presets, and a plain-English
/// preview with the next run. The cron shows for Custom, or under Advanced (`showCron`).
struct ScheduleField: View {
    @Binding var draft: ScheduleDraft
    var preview: String
    var next: String
    var invalid = false
    /// Drawn with the preset menu open (snapshots).
    var menuOpen = false
    var showCron = false
    var width: CGFloat? = nil

    /// "15min", "hourly", "daily", "weekdays" or "custom" (the schema's names).
    var preset: String { draft.preset == .every15 ? "15min" : draft.preset.rawValue }
    var time: String { CollectorText().clock(Calendar.current.date(from: DateComponents(year: 2026, month: 1, day: 5, hour: draft.hour, minute: draft.minute)) ?? Date()) }
    var cron: String { draft.cron }

    static func title(_ p: SchedulePreset) -> String {
        switch p {
        case .every15: return "Every 15 minutes"
        case .hourly: return "Every hour"
        case .daily: return "Every day"
        case .weekdays: return "Weekdays"
        default: return "Custom (cron)"
        }
    }

    private var custom: Bool { draft.preset == .custom }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                DropdownButton(title: Self.title(draft.preset), width: 150, height: 30, systemImage: "clock", active: menuOpen) {
                    ForEach(SchedulePreset.all, id: \.self) { p in
                        Button(Self.title(p)) {
                            if p == .custom, draft.customCron.isEmpty { draft.customCron = draft.cron }
                            draft.preset = p
                        }
                    }
                }
                if draft.hasTime {
                    Text("at").font(Theme.body(12)).foregroundStyle(Theme.muted)
                    DatePicker("", selection: timeBinding, displayedComponents: .hourAndMinute)
                        .labelsHidden().datePickerStyle(.field).fixedSize()
                        .font(Theme.body(12, .semibold))
                } else if !custom {
                    Text(draft.preset == .every15 ? "starting on the hour" : "on the hour").font(Theme.body(12)).foregroundStyle(Theme.muted)
                }
            }
            HStack(spacing: 8) {
                if custom || showCron {
                    Text("CRON").font(Theme.body(10, .heavy)).kerning(0.6).foregroundStyle(Theme.faint).fixedSize()
                    TextField("m h dom mon dow", text: Binding(get: { draft.cron }, set: { draft.setCron($0) }))
                        .textFieldStyle(.plain).font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(custom ? Theme.ink : Theme.muted)
                        .padding(.horizontal, 10).frame(width: 140, height: 28)
                        .background(RoundedRectangle(cornerRadius: 8).fill(custom ? Color.white : Theme.panel))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(invalid ? Color(hex: 0xFF9A6B) : custom ? CollectorsTheme.selectedStroke : Theme.border,
                                                                           lineWidth: invalid || custom ? 1.5 : 1))
                }
                (Text(preview).fontWeight(.semibold).foregroundColor(invalid ? Theme.peachInk : Theme.ink)
                 + Text(next.isEmpty ? "" : " · " + next).foregroundColor(invalid ? Theme.peachInk : CollectorsTheme.body))
                    .font(Theme.body(12)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(width: width, alignment: .leading)
    }

    private var timeBinding: Binding<Date> {
        Binding(get: {
            Calendar.current.date(from: DateComponents(year: 2026, month: 1, day: 5, hour: draft.hour, minute: draft.minute)) ?? Date()
        }, set: { d in
            let c = Calendar.current.dateComponents([.hour, .minute], from: d)
            draft.hour = c.hour ?? 9
            draft.minute = c.minute ?? 0
        })
    }
}

// MARK: - RunLogEntry

/// One run in a collector's history: result, time, what it did, duration (exit
/// code for scripts). Opened: Folder runs list each file; script runs show output.
struct RunLogEntry: View {
    /// success | nothing | failed | timedout | skipped | running
    var result: String
    var time: String
    var summary: String
    var meta: String = ""
    /// files | stdout | stderr
    var outputKind: String = "files"
    var lines: [String] = []
    var expanded = false
    var width: CGFloat? = nil
    var onToggle: (() -> Void)? = nil

    private var dot: (Color, Color, String?) {
        switch result {
        case "success": return (Color(hex: 0xF3FDE4), Theme.limeInk, "checkmark")
        case "nothing": return (Theme.panel, Theme.faint, "minus")
        case "failed": return (Theme.peachTint, Theme.peachInk, "exclamationmark")
        case "timedout": return (CollectorsTheme.amberTint, CollectorsTheme.amberInk, "clock")
        case "running": return (Theme.primaryTint, Theme.primary, nil)
        default: return (Theme.panel, Theme.muted, "forward.end")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let onToggle, !lines.isEmpty {
                Button(action: onToggle) { header.contentShape(Rectangle()) }.buttonStyle(.plain)
            } else {
                header
            }
            if expanded, !lines.isEmpty {
                if outputKind == "files" { fileLines } else { output }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 9)
        .frame(width: width, alignment: .leading)
        .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(expanded ? Theme.panel : .clear))
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(dot.0)
                if let icon = dot.2 { Image(systemName: icon).font(.system(size: 9, weight: .heavy)).foregroundStyle(dot.1) }
                else { Spinner(size: 10) }
            }
            .frame(width: 20, height: 20)
            Text(time).font(Theme.body(12, .bold)).monospacedDigit().foregroundStyle(Theme.ink).lineLimit(1).fixedSize()
            Text(summary).font(Theme.body(12))
                .foregroundStyle(result == "failed" ? Theme.peachInk : result == "timedout" ? CollectorsTheme.amberInk : CollectorsTheme.body)
                .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            if !meta.isEmpty { Text(meta).font(Theme.body(11)).monospacedDigit().foregroundStyle(Theme.faint).lineLimit(1).fixedSize() }
            if !lines.isEmpty {
                Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.faint)
            }
        }
    }

    private var fileLines: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                let parts = line.components(separatedBy: " — ")
                let what = parts.count > 1 ? parts[0] : line
                let name = parts.count > 1 ? parts.dropFirst().joined(separator: " — ") : ""
                let quiet = what.hasPrefix("Skipped") || what.hasPrefix("Waiting") || what.hasPrefix("Ignored")
                let failed = what.hasPrefix("Error")
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(what).font(Theme.body(12, .semibold))
                        .foregroundStyle(failed ? Theme.peachInk : quiet ? CollectorsTheme.amberInk : Theme.limeInk)
                        .frame(width: 190, alignment: .leading).lineLimit(1)
                    Text(name).font(Theme.body(12)).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.middle)
                }
            }
        }
        .padding(.leading, 30)
    }

    private var output: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(outputKind == "stderr" ? "STDERR" : "OUTPUT").font(Theme.body(10, .heavy)).kerning(0.6)
                    .foregroundStyle(outputKind == "stderr" ? Theme.peachInk : Theme.faint)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
                } label: { Text("Copy output").font(Theme.body(11, .semibold)).foregroundStyle(Theme.primary) }
                .buttonStyle(.plain)
            }
            TerminalLines(lines: lines, stderr: outputKind == "stderr")
        }
        .padding(.leading, 30)
    }
}

/// Dark output box (live output, stderr in the status card, an opened run).
struct TerminalLines: View {
    var lines: [String]
    var stderr = false
    var maxLines = 400

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(lines.suffix(maxLines).enumerated()), id: \.offset) { _, line in
                Text(line.isEmpty ? " " : line).font(CollectorsTheme.mono).lineSpacing(2)
                    .foregroundStyle(stderr && !line.hasPrefix("$") ? Theme.peach : CollectorsTheme.terminalInk)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(CollectorsTheme.terminal))
    }
}

// MARK: - ScriptConsent

/// The explicit consent for a custom script: nothing runs before it. The
/// allowance is the script's sha256, so a changed script asks again.
struct ScriptConsent: View {
    /// ask | changed | allowed
    var state: String
    var interpreter: String = "python3"
    var source: String = ""
    var hash: String = ""
    var allowedText: String = ""
    var width: CGFloat? = nil
    /// Why Allow is off (the script can't be read), or nil.
    var problem: String? = nil
    var busy = false
    var onAllow: () -> Void = {}
    var onSecond: () -> Void = {}
    var onRevoke: () -> Void = {}

    private var changed: Bool { state == "changed" }

    var body: some View {
        Group {
            if state == "allowed" { allowed } else { card }
        }
        .frame(width: width, alignment: .leading)
        .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
    }

    private var allowed: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.shield").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.limeInk)
            Text(allowedText).font(Theme.body(12)).foregroundStyle(Theme.limeInk).frame(maxWidth: .infinity, alignment: .leading)
            Button("Revoke", action: onRevoke).buttonStyle(.plain).font(Theme.body(12, .semibold)).foregroundStyle(Theme.primary)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(hex: 0xF3FDE4)))
    }

    private var commandText: some View {
        Text("\(interpreter) \(source)").font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.ink)
            .lineLimit(1).truncationMode(.middle)
    }

    private var hashText: some View {
        Text(hash).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Theme.faint).lineLimit(1).fixedSize()
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.shield").font(.system(size: 16, weight: .semibold)).foregroundStyle(CollectorsTheme.amberInk)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 4) {
                    Text(changed ? "The script changed since you allowed it" : "Allow Distill to run this script?")
                        .font(Theme.body(14, .bold)).foregroundStyle(Theme.ink)
                    Text(changed
                         ? "Distill paused this collector. Check the change, then allow this version. Until then it does not run, on schedule or with Run now."
                         : "Distill will run this code on your Mac as you. It can read and change anything you can and use the network. It runs only on this schedule or with Run now, never while your notes are processed.")
                        .font(Theme.body(12.5)).foregroundStyle(CollectorsTheme.body).lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            // The command and its hash side by side; in a narrow pane the hash goes under it.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    commandText.fixedSize()
                    Spacer(minLength: 0)
                    hashText
                }
                VStack(alignment: .leading, spacing: 3) {
                    commandText.frame(maxWidth: .infinity, alignment: .leading)
                    hashText
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(hex: 0xF0E3BD)))
            .padding(.leading, 28)
            if let problem {
                Text(problem).font(Theme.body(12)).foregroundStyle(Theme.peachInk).padding(.leading, 28)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                PrimaryButton(title: changed ? "Allow this version" : "Allow and turn on", systemImage: "checkmark", size: .small,
                              enabled: problem == nil && !busy, action: onAllow)
                    .fixedSize()
                SoftButton(title: changed ? "Show script" : "Not now", fill: .white, size: .small, stroke: true, action: onSecond).fixedSize()
            }
            .padding(.leading, 28)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(hex: 0xFFF8E6)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color(hex: 0xF5D98B)))
    }
}

// MARK: - Include subfolders

/// The Folder collector's "Include subfolders" switch (Add step 2, the Edit form): each top-level
/// subfolder becomes one folder item in the queue.
struct SubfoldersSwitch: View {
    @Binding var isOn: Bool
    var title: String

    var body: some View {
        HStack(spacing: 8) {
            PillSwitch(isOn: $isOn, label: title, width: 34, height: 20)
            Text(title).font(Theme.body(12.5)).foregroundStyle(CollectorsTheme.body)
                .onTapGesture { isOn.toggle() }
                .accessibilityHidden(true)
        }
    }
}
