import AppKit
import SwiftUI
import DistillKit

/// One Queue row (canvas: "Queue rows: every state", Main). Times are clock
/// times from the core, so nothing here ticks.
struct QueueRowView: View {
    let title: String
    let meta: String
    let tileName: String
    let status: QueueRowStatus
    var help: String? = nil
    var noteTile = false
    var onRemove: (() -> Void)? = nil
    var onReveal: (() -> Void)? = nil

    var body: some View {
        let style = noteTile ? ("NOTE", Theme.limeTint, Theme.limeInk) : FileStyle.tile(for: tileName)
        HStack(spacing: 14) {
            Tile(text: style.0, fill: style.1, ink: style.2)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.body(14, .semibold)).lineLimit(1).truncationMode(.middle)
                Text(meta).font(Theme.body(12)).foregroundStyle(Theme.muted).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            QueueStatusPill(status: status).help(help ?? "")
            if status.removable, let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.faint)
                        .frame(width: 30, height: 30).contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Remove from queue (moves to Trash)")
                .accessibilityLabel("Remove \(title) from the queue")
            } else {
                Color.clear.frame(width: 30, height: 30) // keeps pills aligned on locked rows
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .contentShape(Rectangle())
        .contextMenu { if let onReveal { Button("Show in Finder", action: onReveal) } }
    }
}

/// "Ready at 3:14 AM" (gray), "Ready" (green), "In batch" (blue), "Next batch" (gray), "Couldn't read" (peach).
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
        }
    }
}
