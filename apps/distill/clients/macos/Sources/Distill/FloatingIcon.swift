import AppKit
import Combine
import SwiftUI
import DistillKit

/// Always-on-top draggable flask. Click opens Distill, drag moves it, dropping
/// files or right-click → Paste adds to the queue. The liquid rises with the
/// queue and changes color while Claude works or waits for approval.
@MainActor
final class FloatingIconController {
    private let panel: NSPanel
    private let iconView: FloatingIconView
    private static let originKey = "floatingIconOrigin"
    private static let size: CGFloat = 88 // 64pt face plus room for badge and shadow

    var isVisible: Bool { panel.isVisible }
    var frame: NSRect { panel.frame }
    /// The hover menu (Ask, Add note, Paste clipboard, Open Distill).
    private(set) var hoverMenu: HoverMenuController?

    init(engine: AppModel, onOpen: @escaping () -> Void, onMenu: ((HoverMenuController.Action) -> Void)? = nil) {
        let size = Self.size
        panel = NSPanel(
            contentRect: NSRect(origin: Self.savedOrigin() ?? Self.defaultOrigin(size: size),
                                size: NSSize(width: size, height: size)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false // the face draws its own soft shadow

        iconView = FloatingIconView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        iconView.engine = engine
        iconView.onClick = onOpen
        iconView.onMoved = { origin in
            UserDefaults.standard.set(NSStringFromPoint(origin), forKey: Self.originKey)
        }
        iconView.onHide = { [weak panel] in
            panel?.orderOut(nil)
            UserDefaults.standard.set(false, forKey: "showFloatingIcon")
        }
        if let onMenu {
            let menu = HoverMenuController(anchor: { [weak panel] in panel?.isVisible == true ? panel?.frame : nil }, perform: onMenu)
            hoverMenu = menu
            iconView.onHover = { inside in inside ? menu.hoverBegan() : menu.hoverEnded() }
            iconView.onPress = { menu.cancel() }
        }
        let face = NSHostingView(rootView: FloatingFace(dropState: iconView.dropState).environmentObject(engine))
        face.frame = iconView.bounds
        face.autoresizingMask = [.width, .height]
        iconView.addSubview(face)
        panel.contentView = iconView
    }

    func show() { panel.orderFrontRegardless() }
    func hide() { hoverMenu?.cancel(); panel.orderOut(nil) }

    private static func savedOrigin() -> NSPoint? {
        guard let s = UserDefaults.standard.string(forKey: originKey) else { return nil }
        let p = NSPointFromString(s)
        // Ignore positions on a display that is no longer attached.
        return NSScreen.screens.contains { $0.visibleFrame.insetBy(dx: -40, dy: -40).contains(p) } ? p : nil
    }

    private static func defaultOrigin(size: CGFloat) -> NSPoint {
        let frame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(x: frame.maxX - size - 16, y: frame.minY + 110)
    }
}

final class DropState: ObservableObject {
    @Published var targeted = false
}

/// SwiftUI drawing of the floating flask; all mouse handling stays in AppKit.
struct FloatingFace: View {
    @EnvironmentObject var engine: AppModel
    @ObservedObject var dropState: DropState

    var body: some View {
        let pending = engine.pendingApprovals.count
        let working = !engine.runningJobs.isEmpty
        let queued = engine.queued.count
        let targeted = dropState.targeted

        let liquid: Color = pending > 0 ? Theme.peach : (working ? Theme.working : Theme.lime)
        let level: Double = targeted ? 0.45 : (pending > 0 || working ? 0.75 : min(0.9, Double(queued) * 0.2))

        ZStack(alignment: .topTrailing) {
            Circle()
                .fill(targeted ? Theme.primaryTint : Color.white)
                .overlay(Circle().strokeBorder(Theme.primary, lineWidth: targeted ? 2 : (working ? 3 : 0)))
                .overlay(FlaskView(level: level, liquid: liquid, bubbles: working, lineWidth: 2.2).padding(14))
                .frame(width: 64, height: 64)
                .shadow(color: .black.opacity(0.16), radius: 8, y: 4)
                .padding(12)

            QuickAskRing(ask: engine.ask)

            if pending > 0 {
                badge("\(pending)", fill: Theme.peachInk, ink: .white)
            } else if queued > 0 && !working {
                badge("\(queued)", fill: Theme.primaryTint, ink: Theme.primary)
            }
        }
        .frame(width: 88, height: 88)
        .animation(.spring(duration: 0.35), value: level)
        .animation(.easeOut(duration: 0.15), value: targeted)
    }

    private func badge(_ text: String, fill: Color, ink: Color) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(ink)
            .padding(.horizontal, 6)
            .frame(minWidth: 22, minHeight: 22)
            .background(Capsule().fill(fill))
            .overlay(Capsule().strokeBorder(Color.white, lineWidth: 2))
            .padding(.top, 6).padding(.trailing, 6)
    }
}

/// Green ring while a quick ask answer is on its way (or waiting to be seen) with its window closed.
struct QuickAskRing: View {
    @ObservedObject var ask: AskModel

    var body: some View {
        Circle().strokeBorder(Theme.lime, lineWidth: 3)
            .frame(width: 64, height: 64)
            .padding(12)
            .opacity(ask.quickInBackground ? 1 : 0)
            .animation(.easeOut(duration: 0.2), value: ask.quickInBackground)
            .allowsHitTesting(false)
    }
}

final class FloatingIconView: DropTargetView {
    var onClick: (() -> Void)?
    /// Pointer entered (true) or left (false) the flask face.
    var onHover: ((Bool) -> Void)?
    /// Mouse down on the flask (click or drag start).
    var onPress: (() -> Void)?
    private var trackingArea: NSTrackingArea?
    var onMoved: ((NSPoint) -> Void)?
    var onHide: (() -> Void)?
    let dropState = DropState()
    private var dragStartMouse: NSPoint?
    private var dragStartOrigin: NSPoint?
    private var dragged = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        onTargetChange = { [weak self] on in self?.dropState.targeted = on }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds.insetBy(dx: 12, dy: 12),
                                  options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }

    /// Clicks and drags land here, not on the SwiftUI face.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return bounds.insetBy(dx: 12, dy: 12).contains(local) ? self : nil
    }

    // MARK: Click vs drag

    override func mouseDown(with event: NSEvent) {
        onPress?()
        dragStartMouse = NSEvent.mouseLocation
        dragStartOrigin = window?.frame.origin
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStartMouse, let origin = dragStartOrigin, let window else { return }
        let now = NSEvent.mouseLocation
        let dx = now.x - start.x, dy = now.y - start.y
        if !dragged, hypot(dx, dy) < 4 { return }
        dragged = true
        window.setFrameOrigin(NSPoint(x: origin.x + dx, y: origin.y + dy))
    }

    override func mouseUp(with event: NSEvent) {
        if dragged, let origin = window?.frame.origin {
            onMoved?(origin)
        } else {
            onClick?()
        }
        dragStartMouse = nil
        dragged = false
    }

    override func rightMouseDown(with event: NSEvent) {
        onPress?()
        let menu = NSMenu()
        if let vault = MainActor.assumeIsolated({ engine?.activeVault }) {
            menu.addItem(.init(title: "Vault: \(vault.name)", action: nil, keyEquivalent: ""))
            menu.addItem(.separator())
        }
        for (title, action) in [("Open Distill", #selector(menuOpen)), ("Paste into Queue", #selector(menuPaste)),
                                ("Process Now", #selector(menuProcess)), ("Hide Floating Icon", #selector(menuHide))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @MainActor @objc func menuOpen() { onClick?() }
    @MainActor @objc func menuPaste() {
        guard let engine else { return }
        PasteboardIntake.ingest(NSPasteboard.general, engine: engine)
    }
    @MainActor @objc func menuProcess() { engine?.processQueue(force: true) }
    @MainActor @objc func menuHide() { onHide?() }
}
