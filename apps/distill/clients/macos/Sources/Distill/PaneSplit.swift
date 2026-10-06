import AppKit
import SwiftUI

// Resizable panes (docs/specs/resizable-panes.md; canvas: PaneHandle, Panes).
// One modifier, `.paneWidth(_:automatic:)`, replaces the fixed `.frame(width:)` of the column you
// drag. It overlays a PaneHandle on the column's inner edge and keeps the width in Distill's UI
// preferences (@AppStorage "distill.pane.…"). A missing, zero or non-finite value is the automatic
// width (today's width), so nothing changes until the user drags. Only a drag writes.

/// Which side of the column the handle sits on: `.trailing` for a left column (sidebar, lists),
/// `.leading` for a right column (Review's Conversation, To do's and Activity's detail).
enum PaneEdge: Equatable { case leading, trailing }

/// The handle's look (canvas PaneHandle `state`).
enum PaneHandleState: String { case idle, hover, dragging, limit }

/// One resizable column.
struct PaneSpec: Equatable {
    /// UserDefaults key.
    let key: String
    let min: CGFloat
    let max: CGFloat
    /// Width of the container that is not this column: the other column's minimum plus padding,
    /// gaps and lines. The column never grows past `container − reserved` (unless its automatic
    /// width already does, so today's layout is never squeezed further).
    let reserved: CGFloat
    let edge: PaneEdge
    /// Distance from the column's edge to the middle of the boundary (half the gap, or the line).
    var gap: CGFloat = 0
    /// VoiceOver: "Resize <label>".
    let label: String

    static let sidebar = PaneSpec(key: "distill.pane.sidebar", min: 200, max: 320, reserved: 580, edge: .trailing, label: "sidebar")
    static let settingsNav = PaneSpec(key: "distill.pane.settings.nav", min: 200, max: 320, reserved: 480, edge: .trailing, label: "settings list")
    /// Review: details keep 360 (+ 2 × 32 padding + the 24 gap).
    static let reviewConversation = PaneSpec(key: "distill.pane.review.conversation", min: 220, max: 520, reserved: 64 + 24 + 360,
                                             edge: .leading, gap: 12, label: "conversation")
    static let historyConversation = PaneSpec(key: "distill.pane.history.conversation", min: 220, max: 520, reserved: 64 + 24 + 360,
                                              edge: .leading, gap: 12, label: "conversation")
    /// History → Jobs: the detail keeps its padding, the 24 gap, 360 for the details and the Conversation's 220.
    static let historyList = PaneSpec(key: "distill.pane.history.list", min: 240, max: 480, reserved: 1 + 64 + 24 + 360 + 220,
                                      edge: .trailing, gap: 0.5, label: "job list")
    static let historyActions = PaneSpec(key: "distill.pane.history.actions", min: 260, max: 520, reserved: 1 + 360,
                                         edge: .trailing, gap: 0.5, label: "history list")
    static let activityDetail = PaneSpec(key: "distill.pane.activity.detail", min: 320, max: 640, reserved: 1 + 320,
                                         edge: .leading, gap: 0.5, label: "activity detail")
    static let todoDetail = PaneSpec(key: "distill.pane.todo.detail", min: 280, max: 560, reserved: 20 + 8 + 320,
                                     edge: .leading, label: "to-do detail")
    static let collectorsList = PaneSpec(key: "distill.pane.collectors.list", min: 220, max: 460, reserved: 20 + 28 + 24 + 360,
                                         edge: .trailing, gap: 12, label: "collector list")
    /// Review's batch list (review-queue.md): the detail keeps its padding, 360 and the Conversation's 220.
    static let reviewList = PaneSpec(key: "distill.pane.review.list", min: 220, max: 380, reserved: 1 + 64 + 24 + 360 + 220,
                                     edge: .trailing, gap: 0.5, label: "batch list")
    /// Actions → Slack, Jira, Confluence, …: one width per type.
    static func actionsList(_ type: String) -> PaneSpec {
        PaneSpec(key: "distill.pane.actions.\(type).list", min: 240, max: 480, reserved: 20 + 24 + 14 + 360,
                 edge: .trailing, gap: 7, label: "list")
    }

    /// Every fixed key (snapshot defaults reset these; per-type Actions keys are reset by prefix).
    static let fixedKeys = [sidebar, settingsNav, reviewConversation, historyConversation, historyList, historyActions,
                            activityDetail, todoDetail, collectorsList, reviewList].map(\.key)
}

/// The width rules, UI-free (PaneLayoutTests).
enum PaneLayout {
    /// A stored value: nil (automatic) unless finite and positive.
    static func saved(_ raw: Double) -> CGFloat? {
        raw.isFinite && raw > 0 ? CGFloat(raw) : nil
    }

    /// The largest width this column may take in `container` (nil or ≤ 0 = unknown: only `max`).
    static func upper(_ spec: PaneSpec, automatic: CGFloat, container: CGFloat?) -> CGFloat {
        guard let container, container > 0 else { return spec.max }
        // The other column keeps its min, but today's automatic width is never squeezed further.
        let room = Swift.max(container - spec.reserved, Swift.min(automatic, spec.max))
        return Swift.max(spec.min, Swift.min(spec.max, room))
    }

    static func clamp(_ w: CGFloat, _ spec: PaneSpec, automatic: CGFloat, container: CGFloat?) -> CGFloat {
        Swift.min(Swift.max(w, spec.min), upper(spec, automatic: automatic, container: container))
    }

    /// The width shown: the saved one (or the automatic one), clamped. Never writes.
    static func width(saved raw: Double, automatic: CGFloat, spec: PaneSpec, container: CGFloat?) -> CGFloat {
        guard let w = saved(raw) else { return automatic }
        return clamp(w, spec, automatic: automatic, container: container)
    }

    /// A drag: the start width plus the translation (a right column grows when dragged left).
    static func dragged(start: CGFloat, translation: CGFloat, edge: PaneEdge) -> CGFloat {
        edge == .trailing ? start + translation : start - translation
    }

    /// Where a drag ended up: the clamped width and whether it hit a limit (min, max or the other column's min).
    static func drag(start: CGFloat, translation: CGFloat, spec: PaneSpec, automatic: CGFloat, container: CGFloat?) -> (width: CGFloat, limit: PaneLimit?) {
        let proposed = dragged(start: start, translation: translation, edge: spec.edge)
        let lo = spec.min, hi = upper(spec, automatic: automatic, container: container)
        if proposed <= lo { return (lo, .min) }
        if proposed >= hi { return (hi, .max) }
        return (proposed, nil)
    }
}

enum PaneLimit { case min, max }

// MARK: - The handle's look

/// The divider's look (canvas component PaneHandle). `line`: draw the 1 pt border when idle; in the
/// app the screens keep drawing their own border, so `.paneWidth` passes false.
struct PaneHandle: View {
    var state: PaneHandleState = .idle
    var line: Bool = true

    var body: some View {
        let wide = state == .dragging || state == .limit
        ZStack {
            Rectangle().fill(lineColor).frame(width: wide ? 2 : 1)
            if state != .idle {
                RoundedRectangle(cornerRadius: 2).fill(gripColor).frame(width: 4, height: 32)
            }
        }
        .frame(width: 9)
        .frame(maxHeight: .infinity)
    }

    private var lineColor: Color {
        switch state {
        case .idle: return line ? Theme.border : .clear
        case .hover: return Color(hex: 0xD9D6CF)
        case .dragging: return Theme.primary
        case .limit: return Theme.peachInk
        }
    }

    private var gripColor: Color {
        switch state {
        case .idle: return .clear
        case .hover: return Theme.faint
        case .dragging: return Theme.primary
        case .limit: return Theme.peachInk
        }
    }
}

// MARK: - The modifier

/// The container width the panes clamp against (set by `.paneContainer()`; 0 = unknown).
private struct PaneContainerWidthKey: EnvironmentKey { static let defaultValue: CGFloat = 0 }

extension EnvironmentValues {
    var paneContainerWidth: CGFloat {
        get { self[PaneContainerWidthKey.self] }
        set { self[PaneContainerWidthKey.self] = newValue }
    }
}

extension View {
    /// The column you drag: its width, the handle on its inner edge, the remembered value.
    /// `container`: the width the columns share, when the call site already measures it.
    func paneWidth(_ spec: PaneSpec, automatic: CGFloat, container: CGFloat? = nil) -> some View {
        modifier(PaneWidth(spec: spec, automatic: automatic, container: container))
    }

    /// Measures the row that holds resizable columns, so they keep the other column's minimum.
    func paneContainer() -> some View { modifier(PaneContainer()) }
}

private struct PaneContainer: ViewModifier {
    @State private var width: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .environment(\.paneContainerWidth, width)
            .background(GeometryReader { g in
                Color.clear
                    .onAppear { width = g.size.width }
                    .onChange(of: g.size.width) { _, w in width = w }
            })
    }
}

struct PaneWidth: ViewModifier {
    let spec: PaneSpec
    let automatic: CGFloat
    var container: CGFloat?
    @AppStorage private var stored: Double
    @Environment(\.paneContainerWidth) private var measured
    @Environment(\.snapshotMode) private var snapshot
    @State private var start: CGFloat?
    @State private var live: CGFloat?
    @State private var limit: PaneLimit?
    @State private var hovering = false

    init(spec: PaneSpec, automatic: CGFloat, container: CGFloat? = nil) {
        self.spec = spec
        self.automatic = automatic
        self.container = container
        _stored = AppStorage(wrappedValue: 0, spec.key)
    }

    /// Width of the grab area, inside the column's edge.
    static let hitWidth: CGFloat = 14

    private var room: CGFloat? { container ?? (measured > 0 ? measured : nil) }
    private var shown: CGFloat { live ?? PaneLayout.width(saved: stored, automatic: automatic, spec: spec, container: room) }

    func body(content: Content) -> some View {
        content
            .frame(width: shown)
            .overlay(alignment: spec.edge == .trailing ? .trailing : .leading) {
                if !snapshot { handle }
            }
            .zIndex(1)
    }

    private var state: PaneHandleState {
        if limit != nil { return .limit }
        if live != nil { return .dragging }
        return hovering ? .hover : .idle
    }

    private var handle: some View {
        // The grab area lies inside the column, on its inner edge, and is an AppKit view: the main window
        // moves by its background (isMovableByWindowBackground), so a SwiftUI gesture on a clear area
        // lost the drag to the window. PaneGrabView says it doesn't move the window and owns the drag.
        return PaneHandle(state: state, line: false)
            .frame(width: Self.hitWidth, alignment: spec.edge == .trailing ? .trailing : .leading)
            .frame(maxHeight: .infinity)
            .overlay {
                PaneGrab(
                    onHover: { hovering = $0 },
                    onDrag: { dx in
                        let s = start ?? shown
                        if start == nil { start = s }
                        let r = PaneLayout.drag(start: s, translation: dx, spec: spec, automatic: automatic, container: room)
                        live = r.width
                        limit = r.limit
                        return cursorFor(r.limit)
                    },
                    onEnd: {
                        if let w = live { stored = Double(w) }
                        start = nil; live = nil; limit = nil
                    },
                    onDoubleClick: { reset() })
            }
            .onDisappear { hovering = false; start = nil; live = nil; limit = nil }
            .accessibilityElement()
            .accessibilityLabel("Resize \(spec.label)")
            .accessibilityAddTraits(.allowsDirectInteraction)
            .accessibilityAdjustableAction { direction in
                let step: CGFloat = direction == .increment ? 20 : -20
                stored = Double(PaneLayout.clamp(shown + step, spec, automatic: automatic, container: room))
            }
    }

    /// ↔ normally; one-way at a limit (at the min the column can only grow, at the max only shrink).
    private func cursorFor(_ limit: PaneLimit?) -> NSCursor {
        guard let limit else { return .resizeLeftRight }
        let right = (spec.edge == .trailing) == (limit == .min)
        return right ? .resizeRight : .resizeLeft
    }

    private func reset() {
        withAnimation(.easeOut(duration: 0.2)) { stored = 0 }
    }
}


// MARK: - The grab area (AppKit)

/// The divider's mouse area. An NSView, so it can refuse to move the window (`mouseDownCanMoveWindow`),
/// keep the ↔ cursor with a cursor rect, and track the drag in window coordinates.
struct PaneGrab: NSViewRepresentable {
    var onHover: (Bool) -> Void
    /// The drag's x translation since mouse down; returns the cursor to show (one-way at a limit).
    var onDrag: (CGFloat) -> NSCursor
    var onEnd: () -> Void
    var onDoubleClick: () -> Void

    func makeNSView(context: Context) -> PaneGrabView { PaneGrabView() }

    func updateNSView(_ view: PaneGrabView, context: Context) {
        view.onHover = onHover
        view.onDrag = onDrag
        view.onEnd = onEnd
        view.onDoubleClick = onDoubleClick
    }
}

final class PaneGrabView: NSView {
    var onHover: (Bool) -> Void = { _ in }
    var onDrag: (CGFloat) -> NSCursor = { _ in .resizeLeftRight }
    var onEnd: () -> Void = {}
    var onDoubleClick: () -> Void = {}
    private var startX: CGFloat?
    private var tracking: NSTrackingArea?

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { onHover(true) }
    override func mouseExited(with event: NSEvent) { if startX == nil { onHover(false) } }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onDoubleClick(); return }
        startX = event.locationInWindow.x
    }

    override func mouseDragged(with event: NSEvent) {
        guard let startX else { return }
        onDrag(event.locationInWindow.x - startX).set()
    }

    override func mouseUp(with event: NSEvent) {
        guard startX != nil else { return }
        startX = nil
        onEnd()
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        if !inside { onHover(false) }
        window?.invalidateCursorRects(for: self)
    }
}
