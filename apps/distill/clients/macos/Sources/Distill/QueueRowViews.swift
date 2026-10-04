import AppKit
import SwiftUI
import DistillKit

/// One Queue row (canvas: QueueRowView, Main, MainFolder). A file, a folder (one item: folder icon,
/// "12 files · 3 folders · 18.4 MB", a chevron that expands a read-only tree) or a Google Doc (doc
/// icon, "Google Doc · needs Google Drive access", Open in Google Docs, a Waiting pill and a hint).
/// Times are clock times from the core, so nothing here ticks.
struct QueueRowView: View {
    let title: String
    let meta: String
    let tileName: String
    let status: QueueRowStatus
    var help: String? = nil
    var noteTile = false
    /// file | folder | gdoc (a note is a file with `noteTile`).
    var kind: QueueEntry.Kind = .file
    /// A folder's tree starts open (snapshots); a click on the row or the chevron toggles it.
    var expanded = false
    /// A folder's tree lines (QueueTree.lines).
    var tree: [QueueTreeLine] = []
    /// The line under a Google Doc row.
    var hint: String? = nil
    /// The row just appeared through a scan: it flashes once.
    var flash = false
    var onRemove: (() -> Void)? = nil
    var onReveal: (() -> Void)? = nil
    /// Google Doc rows: opens the doc's link.
    var onOpenLink: (() -> Void)? = nil
    @State private var toggled: Bool?
    @State private var flashOn = false

    private var isOpen: Bool { kind == .folder && (toggled ?? expanded) && !tree.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if let hint { hintLine(hint) }
            if isOpen { QueueTreeView(lines: tree).padding(.leading, 54).padding(.trailing, 44) }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 14).fill(isOpen ? Color(hex: 0xFBFAF8) : .clear))
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.primaryTint.opacity(flashOn ? 0.9 : 0)))
        .contentShape(Rectangle())
        .contextMenu { if let onReveal { Button("Show in Finder", action: onReveal) } }
        .onAppear { if flash { pulse() } }
        .onChange(of: flash) { _, on in if on { pulse() } }
    }

    private var header: some View {
        HStack(spacing: 14) {
            icon
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).font(Theme.body(14, .semibold)).lineLimit(1).truncationMode(.middle)
                    if kind == .folder, !tree.isEmpty {
                        Button(action: toggle) {
                            Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                                .font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.faint)
                                .frame(width: 16, height: 16).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(isOpen ? "Hide what is inside" : "Show what is inside")
                        .accessibilityLabel(isOpen ? "Hide what is inside \(title)" : "Show what is inside \(title)")
                    }
                }
                if let onOpenLink {
                    // The link follows the meta; in a narrow window it moves under it rather than cutting the meta.
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 4) { metaText.fixedSize(); openLink(onOpenLink, dot: true) }
                        VStack(alignment: .leading, spacing: 2) { metaText; openLink(onOpenLink, dot: false) }
                    }
                } else {
                    metaText
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { if kind == .folder, !tree.isEmpty { toggle() } }
            QueueStatusPill(status: status).help(help ?? "")
            if status.removable, let onRemove {
                IconButton(systemImage: "xmark", size: 30, tint: Theme.faint, iconSize: 12,
                           help: kind == .folder ? "Remove from queue (moves the folder to Trash)" : "Remove from queue (moves to Trash)",
                           label: "Remove \(title) from the queue", action: onRemove)
            } else {
                Color.clear.frame(width: 30, height: 30) // keeps pills aligned on locked rows
            }
        }
    }

    private var metaText: some View {
        Text(meta).font(Theme.body(12)).foregroundStyle(Theme.muted).lineLimit(1)
    }

    private func openLink(_ action: @escaping () -> Void, dot: Bool) -> some View {
        Button(action: action) {
            Text(dot ? "· Open in Google Docs" : "Open in Google Docs").font(Theme.body(12, .semibold)).foregroundStyle(Theme.primary)
                .lineLimit(1).fixedSize().contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open this document in your browser")
    }

    @ViewBuilder private var icon: some View {
        switch kind {
        case .folder: SymbolTile(systemImage: "folder", fill: Color(hex: 0xFFF4D6), ink: Color(hex: 0x8A5A00))
        case .gdoc: SymbolTile(systemImage: "doc.text", fill: Color(hex: 0xDDF2FF), ink: Color(hex: 0x0B5C86))
        default:
            let style = noteTile ? ("NOTE", Theme.limeTint, Theme.limeInk) : FileStyle.tile(for: tileName)
            Tile(text: style.0, fill: style.1, ink: style.2)
        }
    }

    private func hintLine(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.circle").font(.system(size: 11, weight: .semibold))
            Text(text).font(Theme.body(11.5)).fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Color(hex: 0x8A5A00))
        .padding(.leading, 54).padding(.trailing, 44)
    }

    private func toggle() {
        withAnimation(.easeOut(duration: 0.15)) { toggled = !(toggled ?? expanded) }
    }

    private func pulse() {
        flashOn = true
        withAnimation(.easeOut(duration: 1.2).delay(0.25)) { flashOn = false }
    }
}

/// A 40 pt rounded tile with an SF Symbol (folder and Google Doc rows).
struct SymbolTile: View {
    let systemImage: String
    var fill: Color
    var ink: Color
    var size: CGFloat = 40

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.42, weight: .medium))
            .foregroundStyle(ink)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.25).fill(fill))
    }
}

/// A folder's read-only tree: folders bold with their file count, files with their size, a
/// Google Doc "not read", "… N more" after 5 entries per folder.
struct QueueTreeView: View {
    let lines: [QueueTreeLine]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                HStack(spacing: 6) {
                    Image(systemName: symbol(line)).font(.system(size: 10, weight: .medium))
                        .foregroundStyle(line.kind == .dir ? Color(hex: 0x8A5A00) : Theme.faint)
                        .frame(width: 12)
                    Text(line.name).font(Theme.body(12, line.kind == .dir ? .semibold : .regular))
                        .foregroundStyle(line.kind == .truncated ? Theme.muted : Theme.ink)
                        .lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(line.detail).font(Theme.body(11.5)).foregroundStyle(Theme.faint).lineLimit(1).fixedSize()
                }
                .padding(.vertical, 2)
                .padding(.leading, CGFloat(line.depth) * 16)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.panel))
    }

    private func symbol(_ line: QueueTreeLine) -> String {
        switch line.kind {
        case .dir: return "folder"
        case .gdoc: return "doc.text"
        case .truncated: return "ellipsis"
        case .file, .more: return "doc"
        }
    }
}

/// "Ready at 3:14 AM" (gray), "Ready" (green), "In batch" (blue), "Next batch" (gray), "Couldn't read",
/// "Too big" (peach), "Waiting" (amber).
struct QueueStatusPill: View {
    let status: QueueRowStatus

    var body: some View {
        let (fill, ink) = colors
        Text(QueueRows.pillText(status))
            .font(Theme.body(12, .semibold)).lineLimit(1).fixedSize()
            .padding(.horizontal, 10).frame(height: 24)
            .foregroundStyle(ink)
            .background(Capsule().fill(fill))
    }

    private var colors: (Color, Color) {
        switch status.tone {
        case .gray: return (Theme.panel, Color(hex: 0x48463F))
        case .green: return (Color(hex: 0xF3FDE4), Theme.limeInk)
        case .blue: return (Theme.primaryTint, Theme.primary)
        case .peach: return (Color(hex: 0xFFF4EE), Theme.peachInk)
        case .amber: return (Color(hex: 0xFFF4D6), Color(hex: 0x8A5A00))
        }
    }
}

// MARK: - QueueRefresh

/// Refresh on the Queue screen, after Copy path and Reveal in Finder (canvas: QueueRefresh).
/// "Checking…" (disabled) while the core scans, then one result for 4 seconds, then "checked at …".
struct QueueRefresh: View {
    var state: QueueRefreshState = .idle
    /// "checked at 3:41 AM"; nil before the first scan (an older core).
    var checked: String? = nil
    var onRefresh: () -> Void = {}

    /// The result note, for the schema's `found` / `error` props.
    var found: String? { if case .found(let t) = state { return t }; return nil }
    var error: String? { if case .error(let t) = state { return t }; return nil }

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onRefresh) {
                HStack(spacing: 5) {
                    if state == .checking {
                        Spinner(color: Theme.primary, size: 11)
                    } else {
                        Image(systemName: "arrow.clockwise").font(.system(size: 10, weight: .bold))
                    }
                    Text(state == .checking ? "Checking…" : "Refresh").font(Theme.body(12.5, .semibold))
                }
                .foregroundStyle(state == .checking ? Theme.muted : Theme.primary)
                .padding(.horizontal, 8).frame(height: 26)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(state == .checking)
            .help("Check the queue folder for files and folders added outside Distill")
            if let (text, ink, fill, bold) = note {
                Text(text).font(Theme.body(12, bold ? .semibold : .regular)).foregroundStyle(ink).lineLimit(1)
                    .padding(.horizontal, 8).frame(height: 22)
                    .background(Capsule().fill(fill))
                    .transition(.opacity)
            }
        }
        .fixedSize()
        .animation(.easeOut(duration: 0.15), value: state)
    }

    private var note: (String, Color, Color, Bool)? {
        switch state {
        case .checking: return nil
        case .idle: return checked.map { ($0, Theme.faint, .clear, false) }
        case .found(let t): return (t, Theme.limeInk, Color(hex: 0xF3FDE4), true)
        case .nothing(let t): return (t, Theme.muted, Theme.panel, true)
        case .error(let t): return (t, Theme.peachInk, Color(hex: 0xFFE4D6), true)
        }
    }
}
