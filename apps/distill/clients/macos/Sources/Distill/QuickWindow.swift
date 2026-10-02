import AppKit
import SwiftUI
import DistillKit

/// The window shell shared by quick note and quick ask (canvas: "Quick
/// windows: size, growth and scrolling"): borderless, rounded, floating,
/// opens centered like Spotlight, grows downward with its content, and has a
/// resize corner whose size is remembered as a floor. Frame math lives in
/// `QuickWindowGeometry` (DistillKit).
class QuickWindow: NSPanel {
    /// Esc and the × button.
    var onCancel: (() -> Void)?

    init(width: CGFloat) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: width, height: 200),
                   styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovableByWindowBackground = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        appearance = NSAppearance(named: .aqua)
        minSize = QuickWindowGeometry.minSize
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { MainActor.assumeIsolated { onCancel?() } }

    /// A non-activating panel leaves Distill inactive, so the Edit menu never sees
    /// ⌘X/C/V/A/Z: send those actions to the focused field ourselves.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if super.performKeyEquivalent(with: event) { return true }
        guard let action = Self.editAction(for: event) else { return false }
        return firstResponder?.tryToPerform(action, with: self) ?? false
    }

    static func editAction(for event: NSEvent) -> Selector? {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased()
        switch (flags, key) {
        case (.command, "x"): return #selector(NSText.cut(_:))
        case (.command, "c"): return #selector(NSText.copy(_:))
        case (.command, "v"): return #selector(NSText.paste(_:))
        case (.command, "a"): return #selector(NSText.selectAll(_:))
        case (.command, "z"): return Selector(("undo:"))
        case ([.command, .shift], "z"): return Selector(("redo:"))
        default: return nil
        }
    }
}

/// Rounded container: the SwiftUI content plus the AppKit resize corner on top.
final class QuickWindowContainer: NSView {
    static let radius: CGFloat = 16

    init<Content: View>(root: Content, onResize: @escaping (NSRect, Bool) -> Void) {
        super.init(frame: NSRect(x: 0, y: 0, width: 420, height: 200))
        wantsLayer = true
        layer?.cornerRadius = Self.radius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.white.cgColor
        let host = FirstMouseHostingView(rootView: root)
        host.sizingOptions = [] // the controller owns the frame; SwiftUI only reports its desired height
        host.autoresizingMask = [.width, .height]
        host.frame = bounds
        addSubview(host)
        let corner = ResizeCornerView(onResize: onResize)
        corner.frame = NSRect(x: bounds.maxX - 18, y: 0, width: 18, height: 18)
        corner.autoresizingMask = [.minXMargin, .maxYMargin]
        addSubview(corner)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

/// The bottom-right grip: drags resize with the top-left corner fixed.
final class ResizeCornerView: NSView {
    private let onResize: (NSRect, Bool) -> Void
    private var startFrame: NSRect?
    private var startMouse: NSPoint = .zero

    init(onResize: @escaping (NSRect, Bool) -> Void) {
        self.onResize = onResize
        super.init(frame: .zero)
        toolTip = "Drag to resize"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath()
        let b = bounds.insetBy(dx: 4, dy: 4)
        path.move(to: NSPoint(x: b.maxX, y: b.minY + 9)); path.line(to: NSPoint(x: b.maxX - 9, y: b.minY))
        path.move(to: NSPoint(x: b.maxX, y: b.minY + 4)); path.line(to: NSPoint(x: b.maxX - 4, y: b.minY))
        path.lineWidth = 1.2
        path.lineCapStyle = .round
        NSColor(white: 0.62, alpha: 1).setStroke()
        path.stroke()
    }

    override func resetCursorRects() {
        if #available(macOS 15.0, *) {
            addCursorRect(bounds, cursor: NSCursor.frameResize(position: .bottomRight, directions: .all))
        } else {
            addCursorRect(bounds, cursor: .crosshair)
        }
    }

    override func mouseDown(with event: NSEvent) {
        startFrame = window?.frame
        startMouse = NSEvent.mouseLocation
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = startFrame, let window else { return }
        let now = NSEvent.mouseLocation
        let visible = window.screen?.visibleFrame ?? start
        let frame = QuickWindowGeometry.resized(start, dx: now.x - startMouse.x, dy: now.y - startMouse.y, visible: visible)
        onResize(frame, false)
    }

    override func mouseUp(with event: NSEvent) {
        guard startFrame != nil, let window else { return }
        startFrame = nil
        onResize(window.frame, true)
    }
}

/// Owns one quick window's frame: opening position, growth with the content,
/// the remembered floor (UserDefaults) and the dragged position (until quit).
@MainActor
final class QuickWindowSizer: NSObject, NSWindowDelegate {
    let window: QuickWindow
    private let sizeKey: String
    private var desired: CGFloat = 0
    private var hidden: CGFloat = 0
    private var floor: CGSize
    private var programmatic = false
    /// Where the user dragged the window, until the app quits.
    private var rememberedTopLeft: NSPoint?

    init(window: QuickWindow, sizeKey: String) {
        self.window = window
        self.sizeKey = sizeKey
        floor = Self.loadFloor(sizeKey)
        super.init()
        window.delegate = self
    }

    /// Installs the SwiftUI content. It reports its desired height through `contentHeight(_:)`.
    func setContent<Content: View>(_ root: Content) {
        window.contentView = QuickWindowContainer(root: root) { [weak self] frame, done in
            MainActor.assumeIsolated { self?.userResize(frame, done: done) }
        }
    }

    /// Opens on `screen`'s visible frame: centered, top 30 % down (or where it was dragged).
    func open(on screen: NSScreen?) {
        let visible = (screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 875)
        var remembered = rememberedTopLeft
        if let p = remembered, !NSScreen.screens.contains(where: { $0.visibleFrame.insetBy(dx: -1, dy: -1).contains(p) }) {
            remembered = nil
        }
        // A remembered spot on another screen wins only when it is still on a screen.
        let target = remembered.flatMap { p in NSScreen.screens.first { $0.visibleFrame.insetBy(dx: -1, dy: -1).contains(p) }?.visibleFrame } ?? visible
        hidden = 0
        let frame = QuickWindowGeometry.openFrame(desired: max(desired, 1), floor: floor, visible: target, remembered: remembered)
        setFrame(frame, animate: false)
    }

    /// The content's natural height changed (typing, images, errors, the label step).
    func contentHeight(_ height: CGFloat) {
        guard abs(height - desired) > 0.5 else { return }
        desired = height
        hidden = QuickWindowGeometry.updatedHiddenOverflow(hidden, desired: desired, floor: floor.height)
        guard window.isVisible else { return }
        refit(animate: true)
    }

    private func refit(animate: Bool) {
        let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? window.frame
        let frame = QuickWindowGeometry.grownFrame(window.frame, desired: desired, floor: floor.height,
                                                   hiddenOverflow: hidden, visible: visible)
        guard frame != window.frame else { return }
        setFrame(frame, animate: animate)
    }

    private func userResize(_ frame: NSRect, done: Bool) {
        setFrame(frame, animate: false)
        guard done else { return }
        floor = frame.size
        hidden = QuickWindowGeometry.hiddenOverflow(desired: desired, height: frame.height)
        UserDefaults.standard.set([frame.width, frame.height], forKey: sizeKey)
    }

    private func setFrame(_ frame: NSRect, animate: Bool) {
        // Moves made here (growth, opening, the corner) are not the user's drag.
        programmatic = true
        if animate && window.isVisible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.16
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                window.animator().setFrame(frame, display: true)
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    self?.programmatic = false
                    self?.window.invalidateShadow()
                }
            }
        } else {
            window.setFrame(frame, display: true)
            window.invalidateShadow()
            programmatic = false
        }
    }

    func windowDidMove(_ notification: Notification) {
        guard !programmatic, window.isVisible, window.inLiveResize == false else { return }
        rememberedTopLeft = NSPoint(x: window.frame.minX, y: window.frame.maxY)
    }

    /// Edge resizes AppKit handles itself also count as a chosen size.
    func windowDidEndLiveResize(_ notification: Notification) {
        userResize(window.frame, done: true)
    }

    private static func loadFloor(_ key: String) -> CGSize {
        if let v = UserDefaults.standard.array(forKey: key) as? [Double], v.count == 2 {
            return CGSize(width: max(v[0], QuickWindowGeometry.minSize.width), height: max(v[1], QuickWindowGeometry.minSize.height))
        }
        return CGSize(width: QuickWindowGeometry.defaultWidth, height: QuickWindowGeometry.minSize.height)
    }

    /// The screen with the pointer (shortcuts), or the flask's (hover menu).
    static func screen(near anchor: NSRect?) -> NSScreen? {
        if let a = anchor, let s = NSScreen.screens.first(where: { $0.frame.intersects(a) }) { return s }
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
    }
}

/// Moves keyboard focus to the note's text view (a click in the spare area under the text).
@MainActor
enum NoteEditorFocus {
    static func focus(in window: NSWindow?) {
        guard let window, let root = window.contentView else { return }
        var best: NSTextView?
        func walk(_ v: NSView) {
            if let t = v as? NSTextView, t.isEditable, !t.isFieldEditor, t.frame.height > (best?.frame.height ?? 0) { best = t }
            v.subviews.forEach(walk)
        }
        walk(root)
        guard let text = best else { return }
        window.makeFirstResponder(text)
        text.setSelectedRange(NSRange(location: (text.string as NSString).length, length: 0))
    }
}
