import AppKit
import SwiftUI

// The AppKit side of the Markdown editor: an NSTextView (TextKit 1) that keeps
// plain Markdown, draws quote bars and code bands, shows a placeholder, pastes
// rich text as Markdown and hands keys to the controller; a scroll view that
// only ever shows an overlay scroller; and the representable that hosts them.

final class MarkdownTextView: NSTextView {
    weak var controller: MarkdownEditorController?
    var placeholderString = "" { didSet { if oldValue != placeholderString { needsDisplay = true } } }
    var placeholderSize: CGFloat = 13

    // Copy and drag out plain Markdown only; take only text in.
    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string] }
    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string] }

    override func paste(_ sender: Any?) {
        if isEditable, let controller, controller.pasteImages(from: .general) { return }
        guard isEditable, let text = MarkdownPaste.text(from: .general) else {
            super.paste(sender)   // nothing textual (an image): compose's image intake handles ⌘V before this
            return
        }
        if let controller, controller.embedsKnownImage(text) {
            controller.insertMarkdown(text)
            return
        }
        insertText(text, replacementRange: selectedRange())
    }

    /// Copy and drag write Markdown: an image is its `![[name]]`.
    override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        guard let storage = textStorage, selectedRange().length > 0, storage.string.contains("\u{FFFC}") else {
            return super.writeSelection(to: pboard, types: types)
        }
        let markdown = MarkdownEditorController.markdown(from: storage.attributedSubstring(from: selectedRange()))
        pboard.declareTypes([.string], owner: nil)
        return pboard.setString(markdown, forType: .string)
    }

    /// A drop of Markdown that embeds this note's images puts the images back.
    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        if type == .string, let controller, let text = pboard.string(forType: .string), controller.embedsKnownImage(text) {
            return controller.insertMarkdown(text)
        }
        return super.readSelection(from: pboard, type: type)
    }

    override func pasteAsRichText(_ sender: Any?) { paste(sender) }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, isEditable, controller?.handleKeyEquivalent(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        super.insertText(string, replacementRange: replacementRange)
        guard !hasMarkedText() else { return }
        let typed = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
        controller?.didType(typed)
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { controller?.focusChanged(true) }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { controller?.focusChanged(false) }
        return ok
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { controller?.closePanels() } else { controller?.didMoveToWindow() }
    }

    // MARK: Drawing

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let lm = layoutManager, let tc = textContainer, let storage = textStorage, storage.length > 0 else { return }
        let origin = textContainerOrigin
        let full = NSRange(location: 0, length: storage.length)
        storage.enumerateAttribute(.markdownCodeBlock, in: full) { value, range, _ in
            guard value != nil else { return }
            var union = NSRect.null
            lm.enumerateLineFragments(forGlyphRange: lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)) { r, _, _, _, _ in
                union = union.union(r)
            }
            guard !union.isNull else { return }
            let band = NSRect(x: origin.x - 6, y: union.minY + origin.y - 2, width: tc.size.width + 12, height: union.height + 4)
            MarkdownTheme.codeFill.setFill()
            NSBezierPath(roundedRect: band, xRadius: 6, yRadius: 6).fill()
        }
        if let r = controller?.extractedHighlight, r.length > 0 {
            // Just extracted from an image: tinted for a few seconds.
            var union = NSRect.null
            lm.enumerateLineFragments(forGlyphRange: lm.glyphRange(forCharacterRange: r, actualCharacterRange: nil)) { _, used, _, _, _ in
                union = union.union(used)
            }
            if !union.isNull {
                let band = NSRect(x: origin.x - 8, y: union.minY + origin.y - 6, width: tc.size.width + 16, height: union.height + 12)
                MarkdownTheme.extractedFill.setFill()
                NSBezierPath(roundedRect: band, xRadius: 8, yRadius: 8).fill()
            }
        }
        storage.enumerateAttribute(.markdownQuote, in: full) { value, range, _ in
            guard value != nil else { return }
            lm.enumerateLineFragments(forGlyphRange: lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)) { r, _, _, _, _ in
                MarkdownTheme.quoteBar.setFill()
                NSRect(x: origin.x, y: r.minY + origin.y + 1, width: 3, height: r.height - 2).fill()
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !hasMarkedText(), !placeholderString.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: MarkdownTheme.font(placeholderSize), .foregroundColor: MarkdownTheme.placeholder,
            .paragraphStyle: MarkdownStyler.paragraph(placeholderSize),
        ]
        let o = textContainerOrigin
        let pad = textContainer?.lineFragmentPadding ?? 0
        let width = bounds.width - o.x * 2 - pad * 2
        (placeholderString as NSString).draw(with: NSRect(x: o.x + pad, y: o.y, width: max(10, width), height: bounds.height - o.y),
                                             options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)
    }
}

/// Never shows a scroll-bar strip: the scroller is always the overlay kind, shown
/// only while scrolling. When the text fits, wheel events go to the enclosing view.
final class MarkdownScrollView: NSScrollView {
    var scrolls = true { didSet { hasVerticalScroller = scrolls } }
    var onLayout: (() -> Void)?

    override var scrollerStyle: NSScroller.Style {
        get { .overlay }
        set { super.scrollerStyle = .overlay }
    }

    override func scrollWheel(with event: NSEvent) {
        let fits = (documentView?.frame.height ?? 0) <= contentView.bounds.height + 0.5
        if !scrolls || fits { nextResponder?.scrollWheel(with: event) } else { super.scrollWheel(with: event) }
    }

    override func layout() {
        super.layout()
        // The text is exactly as wide as the visible area (autoresizing alone drifts from the initial size).
        if let doc = documentView, abs(doc.frame.width - contentSize.width) > 0.5 {
            doc.setFrameSize(NSSize(width: contentSize.width, height: doc.frame.height))
        }
        onLayout?()
    }
}

struct MarkdownTextArea: NSViewRepresentable {
    @Binding var text: String
    let controller: MarkdownEditorController
    var size: CGFloat
    var placeholder: String
    var editable: Bool
    var scrolls: Bool
    var autoFocus: Bool
    /// Images inside the text (Write a note, quick note); nil = text only.
    var images: InlineImageHost? = nil

    func makeNSView(context: Context) -> MarkdownScrollView {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)

        let tv = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 20), textContainer: container)
        tv.controller = controller
        tv.delegate = controller
        tv.isRichText = true
        tv.importsGraphics = false
        tv.allowsImageEditing = false
        tv.usesFontPanel = false
        tv.usesRuler = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.smartInsertDeleteEnabled = false
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainerInset = NSSize(width: 0, height: MarkdownEditorController.inset)
        tv.insertionPointColor = NSColor(hex: 0x1D1C1A)
        tv.selectedTextAttributes = [.backgroundColor: MarkdownTheme.selection]
        tv.linkTextAttributes = [:]
        tv.typingAttributes = MarkdownStyler.baseAttributes(size: size)
        tv.placeholderString = placeholder
        tv.placeholderSize = size
        tv.setAccessibilityPlaceholderValue(placeholder)

        let scroll = MarkdownScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrolls = scrolls
        scroll.documentView = tv
        scroll.contentView.postsBoundsChangedNotifications = true
        scroll.onLayout = { [weak controller] in controller?.layoutChanged() }

        controller.attach(tv, scroll: scroll, size: size)
        controller.setText = { value in if self.text != value { self.text = value } }
        controller.imageHost = images
        controller.load(text)
        controller.autoFocus = autoFocus
        return scroll
    }

    func updateNSView(_ scroll: MarkdownScrollView, context: Context) {
        controller.setText = { value in if self.text != value { self.text = value } }
        controller.update(size: size)
        if scroll.scrolls != scrolls { scroll.scrolls = scrolls }
        guard let tv = controller.textView else { return }
        tv.placeholderString = placeholder
        tv.placeholderSize = size
        if tv.isEditable != editable {
            tv.isEditable = editable
            tv.isSelectable = true
        }
        let hadImages = controller.imageHost != nil
        controller.imageHost = images
        if images == nil {
            if hadImages { controller.refreshImageOverlays() }
            if tv.string != text, !tv.hasMarkedText() { controller.load(text) }
        } else if controller.markdownText() != text, !tv.hasMarkedText() {
            controller.load(text)
        } else {
            controller.refreshImageOverlays()
        }
    }

    @available(macOS 13.0, *)
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MarkdownScrollView, context: Context) -> CGSize? {
        // Take the offered width (never ask for the text's own width: that widens windows).
        CGSize(width: proposal.width ?? nsView.frame.width, height: proposal.height ?? controller.contentHeight)
    }

    static func dismantleNSView(_ scroll: MarkdownScrollView, coordinator: ()) {
        (scroll.documentView as? MarkdownTextView)?.controller?.dismantle()
    }
}

// MARK: Floating panels (bubble, heading menu, note picker)

/// A borderless child window for a SwiftUI piece that floats over the editor.
@MainActor
final class MarkdownFloatingPanel {
    private final class Panel: NSPanel {
        var keyable = false
        override var canBecomeKey: Bool { keyable }
    }

    private final class Host: NSHostingView<AnyView> {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    /// Room around the content for its shadow.
    static let pad: CGFloat = 24
    private var panel: Panel?
    private weak var parent: NSWindow?
    private var monitor: Any?
    private var onDismiss: (() -> Void)?

    var isShown: Bool { panel != nil }
    /// Placed above its anchor: grow upward when the content changes.
    var growsUp = false
    var window: NSWindow? { panel }

    /// `place` gets the content size and returns the content's bottom-left in screen coordinates.
    func show<V: View>(_ view: V, parent: NSWindow, key: Bool, place: (CGSize) -> CGPoint, onDismiss: (() -> Void)? = nil) {
        close()
        growsUp = false
        let host = Host(rootView: AnyView(view.padding(Self.pad).environment(\.colorScheme, .light)))
        let fitting = host.fittingSize
        let p = Panel(contentRect: NSRect(origin: .zero, size: fitting), styleMask: [.borderless, .nonactivatingPanel],
                      backing: .buffered, defer: true)
        p.keyable = key
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.isReleasedWhenClosed = false
        p.becomesKeyOnlyIfNeeded = !key
        p.hidesOnDeactivate = true
        p.contentView = host
        let content = CGSize(width: fitting.width - Self.pad * 2, height: fitting.height - Self.pad * 2)
        let origin = place(content)
        p.setFrameOrigin(NSPoint(x: origin.x - Self.pad, y: origin.y - Self.pad))
        parent.addChildWindow(p, ordered: .above)
        if key { p.makeKeyAndOrderFront(nil) } else { p.orderFront(nil) }
        panel = p
        self.parent = parent
        self.onDismiss = onDismiss
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            if let self, event.window !== self.panel { self.dismiss() }
            return event
        }
    }

    /// Resize to the content after it changed (e.g. new search results); keeps the top edge.
    func refit() {
        guard let p = panel, let host = p.contentView as? Host else { return }
        let size = host.fittingSize
        guard abs(size.height - p.frame.height) > 0.5 || abs(size.width - p.frame.width) > 0.5 else { return }
        let y = growsUp ? p.frame.minY : p.frame.maxY - size.height
        p.setFrame(NSRect(x: p.frame.minX, y: y, width: size.width, height: size.height), display: true)
    }

    func dismiss() {
        let callback = onDismiss
        close()
        callback?()
    }

    func close() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let panel {
            parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        panel = nil
        onDismiss = nil
    }
}
