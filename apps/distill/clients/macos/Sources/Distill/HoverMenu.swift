import AppKit
import SwiftUI
import DistillKit

/// The flask's hover menu (canvas: "Quick actions from the floating flask",
/// panel 1): after ~0.3 s of hover, four pills fan out toward the screen
/// center; the menu closes when the pointer leaves both the flask and the pills.
@MainActor
final class HoverMenuController {
    enum Action: CaseIterable { case ask, addNote, paste, open }

    private let panel: NSPanel
    private var openTimer: Timer?
    private var watchTimer: Timer?
    private var outsideSince: Date?
    private var anchor: () -> NSRect?
    private let perform: (Action) -> Void
    private static let size = NSSize(width: 236, height: 4 * 42 + 3 * 8 + 24)

    var isOpen: Bool { panel.isVisible }

    init(anchor: @escaping () -> NSRect?, perform: @escaping (Action) -> Void) {
        self.anchor = anchor
        self.perform = perform
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
    }

    /// Pointer entered the flask: open after a short hover.
    func hoverBegan() {
        openTimer?.invalidate()
        guard !isOpen else { return }
        openTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.open() }
        }
    }

    /// Pointer left the flask before the menu opened.
    func hoverEnded() {
        if !isOpen { openTimer?.invalidate(); openTimer = nil }
    }

    /// Click or drag on the flask: no menu.
    func cancel() {
        openTimer?.invalidate(); openTimer = nil
        close()
    }

    private func open() {
        guard let flask = anchor() else { return }
        let screen = NSScreen.screens.first { $0.frame.intersects(flask) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? flask
        let toLeft = flask.midX > visible.midX
        let upward = flask.midY < visible.midY
        let size = Self.size
        // Pills end at the flask's face (12 pt inset inside the 88 pt panel).
        let x = toLeft ? flask.minX + 4 - size.width : flask.maxX - 4
        let y = upward ? flask.minY + 6 : flask.maxY - 6 - size.height
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: false)
        let host = FirstMouseHostingView(rootView: HoverMenuView(alignTrailing: toLeft, bottomAligned: upward) { [weak self] action in
            self?.close()
            self?.perform(action)
        })
        host.frame = NSRect(origin: .zero, size: size)
        panel.contentView = host
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            panel.animator().alphaValue = 1
        }
        startWatching()
    }

    func close() {
        watchTimer?.invalidate(); watchTimer = nil
        outsideSince = nil
        panel.orderOut(nil)
    }

    /// Closes once the pointer has been outside the flask and the pills
    /// (with the gap between them) for a moment.
    private func startWatching() {
        watchTimer?.invalidate()
        watchTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let mouse = NSEvent.mouseLocation
                let flask = self.anchor()?.insetBy(dx: 8, dy: 8) ?? .zero
                let zone = flask.union(self.panel.frame).insetBy(dx: -6, dy: -6)
                if zone.contains(mouse) {
                    self.outsideSince = nil
                } else if let since = self.outsideSince {
                    if Date().timeIntervalSince(since) > 0.25 { self.close() }
                } else {
                    self.outsideSince = Date()
                }
            }
        }
    }
}

struct HoverMenuView: View {
    var alignTrailing = true
    var bottomAligned = true
    let action: (HoverMenuController.Action) -> Void

    var body: some View {
        VStack(alignment: alignTrailing ? .trailing : .leading, spacing: 8) {
            if bottomAligned { Spacer(minLength: 0) }
            HoverPill(title: "Ask", icon: "bubble.left", primary: true) { action(.ask) }
            HoverPill(title: "Add note", icon: "plus", iconFill: Theme.limeTint, iconInk: Theme.limeInk) { action(.addNote) }
            HoverPill(title: "Paste clipboard", icon: "clipboard") { action(.paste) }
            HoverPill(title: "Open Distill", icon: "arrow.right") { action(.open) }
            if !bottomAligned { Spacer(minLength: 0) }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignTrailing ? .trailing : .leading)
    }
}

struct HoverPill: View {
    let title: String
    let icon: String
    var primary = false
    var iconFill: Color = Theme.panel
    var iconInk: Color = Theme.softInk
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 12, weight: .bold))
                    .foregroundStyle(primary ? Color.white : iconInk)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(primary ? Color.white.opacity(0.2) : iconFill))
                Text(title).font(Theme.body(14, .semibold)).foregroundStyle(primary ? Color.white : Theme.ink)
                Spacer(minLength: 0)
            }
            .padding(.leading, 7).padding(.trailing, 8)
            .frame(width: 200, height: 42)
            .background(Capsule().fill(primary ? Theme.primary : (hovered ? Color(hex: 0xFBFAF8) : Color.white))
                .shadow(color: .black.opacity(0.14), radius: 8, y: 6))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}
