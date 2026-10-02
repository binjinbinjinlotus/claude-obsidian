import AppKit
import Combine
import SwiftUI
import DistillKit

enum MarkdownSubmitMode {
    /// Ask: Return sends, ⇧Return adds a line.
    case returnKey
    /// Notes: ⌘Return sends, Return adds a line.
    case commandReturn
}

/// Vault pages for the note picker. The app asks the core (`GET /v1/pages`);
/// snapshots and tests set their own.
@MainActor
enum MarkdownPageSearch {
    static var provider: ((String) async -> [PageRef])? = nil

    static func search(_ query: String) async -> [PageRef] {
        if let provider { return await provider(query) }
        guard let engine = (NSApp.delegate as? AppDelegate)?.engine, let client = engine.client else { return [] }
        return (try? await client.searchPages(query, vaultPath: engine.activeVault?.path, limit: 8)) ?? []
    }
}

/// Owns one editor's text view: styling, height, keys, commands, the selection
/// bubble, the heading menu and the link / note picker.
@MainActor
final class MarkdownEditorController: NSObject, ObservableObject, NSTextViewDelegate {
    static let inset: CGFloat = 2

    @Published private(set) var active = MarkdownParser.ActiveStyles()
    @Published private(set) var contentHeight: CGFloat = 0
    @Published private(set) var atBottom = true
    @Published private(set) var focused = false

    private(set) weak var textView: MarkdownTextView?
    private weak var scrollView: MarkdownScrollView?
    var setText: ((String) -> Void)?
    var submitMode: MarkdownSubmitMode = .commandReturn
    var onSubmit: (() -> Void)?
    var autoFocus = false
    private(set) var size: CGFloat = 13
    private var lastWidth: CGFloat = 0

    let picker = MarkdownPickerState()
    private var pickerAnchor: Int?          // `[[` typed: the note list follows the typed text
    private var linkSelection: NSRange?     // ⌘K: the selection to link
    private var linkWindow: NSWindow?
    private let bubble = MarkdownFloatingPanel()
    private let menu = MarkdownFloatingPanel()
    private let pickerPanel = MarkdownFloatingPanel()
    private var searchTask: Task<Void, Never>?
    private var bubbleWork: DispatchWorkItem?
    private var queryWatch: AnyCancellable?
    private var boundsWatch: NSObjectProtocol?
    private var keyWatch: NSObjectProtocol?

    // MARK: Lifecycle

    func attach(_ tv: MarkdownTextView, scroll: MarkdownScrollView, size: CGFloat) {
        textView = tv
        scrollView = scroll
        self.size = size
        boundsWatch = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView,
                                                             queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateAtBottom() }
        }
    }

    deinit {
        if let boundsWatch { NotificationCenter.default.removeObserver(boundsWatch) }
        if let keyWatch { NotificationCenter.default.removeObserver(keyWatch) }
    }

    func didMoveToWindow() {
        guard let tv = textView, let window = tv.window else { return }
        if let keyWatch { NotificationCenter.default.removeObserver(keyWatch) }
        keyWatch = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // The ⌘K popover takes key on purpose; anything else hides the floaters.
                if self.linkWindow == nil || NSApp.keyWindow !== self.linkWindow { self.hideBubble(); self.menu.close() }
            }
        }
        if autoFocus {
            DispatchQueue.main.async { [weak tv] in
                guard let tv, let w = tv.window else { return }
                w.makeFirstResponder(tv)
            }
        }
        updateHeight()
    }

    /// Replace the text from the binding (keeps the selection where it can).
    func load(_ text: String) {
        guard let tv = textView else { return }
        let sel = tv.selectedRange()
        tv.string = text
        restyle()
        let length = (text as NSString).length
        tv.setSelectedRange(NSRange(location: min(sel.location, length), length: 0))
        updateHeight()
    }

    func update(size newSize: CGFloat) {
        guard newSize != size else { return }
        size = newSize
        textView?.typingAttributes = MarkdownStyler.baseAttributes(size: size)
        restyle()
        updateHeight()
    }

    func layoutChanged() {
        guard let tv = textView else { return }
        if abs(tv.frame.width - lastWidth) > 0.5 {
            lastWidth = tv.frame.width
            updateHeight()
        }
        updateAtBottom()
    }

    private func restyle() {
        guard let tv = textView, let storage = tv.textStorage, !tv.hasMarkedText() else { return }
        MarkdownStyler.apply(to: storage, size: size)
        tv.typingAttributes = MarkdownStyler.baseAttributes(size: size)
        tv.needsDisplay = true
    }

    /// Height of the laid-out text (with insets), published for the SwiftUI frame.
    private func updateHeight() {
        guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
        lm.ensureLayout(for: tc)
        var used = lm.usedRect(for: tc).height
        if used < 1 { used = lineHeight }
        let h = ceil(used + Self.inset * 2)
        if abs(h - contentHeight) > 0.5 {
            DispatchQueue.main.async { [weak self] in self?.contentHeight = h }
        }
    }

    /// One line of body text (for min/max lines).
    var lineHeight: CGFloat {
        let font = MarkdownTheme.font(size)
        return ceil(NSLayoutManager().defaultLineHeight(for: font) + MarkdownTheme.lineSpacing(size))
    }

    private func updateAtBottom() {
        guard let scroll = scrollView, let doc = scroll.documentView else { return }
        let bottom = scroll.contentView.bounds.maxY >= doc.frame.height - 1
        if bottom != atBottom { atBottom = bottom }
    }

    func focusChanged(_ isFocused: Bool) {
        focused = isFocused
        if !isFocused { hideBubble(); menu.close() }
    }

    func closePanels() {
        hideBubble()
        menu.close()
        closePicker()
    }

    // MARK: NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        guard let tv = textView else { return }
        restyle()
        setText?(tv.string)
        updateHeight()
        hideBubble()
        refreshAnchoredPicker()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard let tv = textView else { return }
        active = MarkdownParser.activeStyles(in: tv.string, selection: tv.selectedRange())
        scheduleBubble()
        if pickerAnchor != nil { refreshAnchoredPicker() }
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard let tv = self.textView else { return false }
        let anchored = pickerAnchor != nil && pickerPanel.isShown
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            if anchored { commitAnchoredPicker(); return true }
            let flags = NSApp.currentEvent?.modifierFlags.intersection(.deviceIndependentFlagsMask) ?? []
            if flags.contains(.shift) || flags.contains(.option) {
                tv.insertNewlineIgnoringFieldEditor(nil)
                return true
            }
            if flags.contains(.command) {
                // ⌘Return reached the text view: nothing else (a button shortcut) took it.
                if let onSubmit { onSubmit() }
                return true
            }
            switch MarkdownCommands.returnKey(text: tv.string, selection: tv.selectedRange(), submitOnReturn: submitMode == .returnKey) {
            case .edit(let e):
                apply(e)
            case .submit(let e):
                if let e { apply(e) }
                onSubmit?()
            case .newline:
                return false
            }
            return true
        case #selector(NSResponder.insertLineBreak(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            return false
        case #selector(NSResponder.insertTab(_:)):
            if anchored { commitAnchoredPicker(); return true }
            if let e = MarkdownCommands.edit(.indent, text: tv.string, selection: tv.selectedRange()) { apply(e); return true }
            if submitMode == .returnKey { tv.window?.selectNextKeyView(nil); return true }
            return false
        case #selector(NSResponder.insertBacktab(_:)):
            if let e = MarkdownCommands.edit(.outdent, text: tv.string, selection: tv.selectedRange()) { apply(e); return true }
            tv.window?.selectPreviousKeyView(nil)
            return true
        case #selector(NSResponder.moveUp(_:)):
            if anchored { picker.move(-1); return true }
            return false
        case #selector(NSResponder.moveDown(_:)):
            if anchored { picker.move(1); return true }
            return false
        case #selector(NSResponder.cancelOperation(_:)):
            if anchored { closePicker(); return true }
            if bubble.isShown { hideBubble(); return true }
            if menu.isShown { menu.close(); return true }
            return false
        default:
            return false
        }
    }

    // MARK: Keys

    /// The shortcuts table on Markdown.dc.html. Letters by character (any layout), digits by key.
    func handleKeyEquivalent(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let ch = (event.charactersIgnoringModifiers ?? "").lowercased()
        let code = event.keyCode
        var command: MarkdownCommand?
        switch flags {
        case [.command]:
            switch ch {
            case "b": command = .bold
            case "i": command = .italic
            case "e": command = .code
            case "k": openLinkPopover(); return true
            default: break
            }
        case [.command, .shift]:
            switch (ch, code) {
            case ("x", _): command = .strike
            case (_, 28): command = .list(.bullet)       // 8
            case (_, 26): command = .list(.numbered)     // 7
            case (_, 25): command = .list(.checklist)    // 9
            case (_, 47): command = .quote               // .
            default: break
            }
        case [.command, .option]:
            switch (ch, code) {
            case (_, 29): command = .heading(0)
            case (_, 18): command = .heading(active.heading == 1 ? 0 : 1)
            case (_, 19): command = .heading(active.heading == 2 ? 0 : 2)
            case (_, 20): command = .heading(active.heading == 3 ? 0 : 3)
            case ("c", _), ("ç", _): command = .codeBlock
            default: break
            }
        default: break
        }
        guard let command else { return false }
        run(command)
        return true
    }

    // MARK: Commands

    func run(_ command: MarkdownCommand) {
        guard let tv = textView, tv.isEditable else { return }
        if tv.window?.firstResponder !== tv { tv.window?.makeFirstResponder(tv) }
        guard let e = MarkdownCommands.edit(command, text: tv.string, selection: tv.selectedRange()) else { return }
        apply(e)
    }

    func apply(_ e: MarkdownEdit) {
        guard let tv = textView, let storage = tv.textStorage else { return }
        guard tv.shouldChangeText(in: e.range, replacementString: e.replacement) else { return }
        storage.replaceCharacters(in: e.range, with: NSAttributedString(string: e.replacement, attributes: tv.typingAttributes))
        tv.didChangeText()
        tv.setSelectedRange(e.selection)
        tv.scrollRangeToVisible(e.selection)
    }

    /// A bar or bubble button. `frame` is the button's frame in its window's SwiftUI (global) space.
    func barAction(_ item: MarkdownBarItem, frame: CGRect) {
        switch item {
        case .bold: run(.bold)
        case .italic: run(.italic)
        case .strike: run(.strike)
        case .code: run(.code)
        case .codeBlock: run(.codeBlock)
        case .quote: run(.quote)
        case .bullet: run(.list(.bullet))
        case .numbered: run(.list(.numbered))
        case .checklist: run(.list(.checklist))
        case .heading: showHeadingMenu(below: frame)
        case .link, .wikilink: hideBubble(); openLinkPopover()
        }
    }

    // MARK: Type-to-format

    func didType(_ typed: String) {
        guard let tv = textView, typed == " " || typed == "[" else { return }
        let r = MarkdownCommands.afterTyping(typed, text: tv.string, cursor: tv.selectedRange().location)
        if let e = r.edit { apply(e) }
        if let anchor = r.pickerAnchor { openAnchoredPicker(anchor) }
    }

    // MARK: Selection bubble

    private func scheduleBubble() {
        bubbleWork?.cancel()
        guard let tv = textView, tv.selectedRange().length > 0, tv.window?.firstResponder === tv, pickerAnchor == nil, linkWindow == nil else {
            hideBubble()
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if NSEvent.pressedMouseButtons != 0 { self.scheduleBubble(); return }
            self.showBubble()
        }
        bubbleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
    }

    private func showBubble() {
        guard let tv = textView, let window = tv.window, tv.selectedRange().length > 0 else { return }
        let first = tv.firstRect(forCharacterRange: NSRange(location: tv.selectedRange().location, length: 0), actualRange: nil)
        let view = MarkdownSelectionBubble { [weak self] item, _ in self?.bubbleAction(item) }
        bubble.show(view, parent: window, key: false) { size in
            let top = first.maxY + 6
            let fitsAbove = top + size.height <= min(window.frame.maxY, (window.screen ?? NSScreen.main)?.visibleFrame.maxY ?? .greatestFiniteMagnitude)
            let y = fitsAbove ? top : first.minY - 6 - size.height
            return CGPoint(x: max(window.frame.minX + 4, first.minX - 8), y: y)
        }
    }

    private func bubbleAction(_ item: MarkdownBarItem) {
        switch item {
        case .link, .wikilink:
            hideBubble()
            openLinkPopover()
        default:
            barAction(item, frame: .zero)
            scheduleBubble()
        }
    }

    private func hideBubble() {
        bubbleWork?.cancel()
        bubble.close()
    }

    // MARK: Heading menu

    private func showHeadingMenu(below frame: CGRect) {
        guard let tv = textView, let window = tv.window else { return }
        if menu.isShown { menu.close(); return }
        hideBubble()
        let current = active.heading
        let view = MarkdownHeadingMenu(current: current) { [weak self] level in
            self?.menu.close()
            self?.run(.heading(level))
        }
        // SwiftUI global frames are top-left based in the window's content view.
        let contentHeight = window.contentView?.frame.height ?? window.frame.height
        let local = NSRect(x: frame.minX, y: contentHeight - frame.maxY, width: frame.width, height: frame.height)
        let screen = window.convertToScreen(local)
        menu.show(view, parent: window, key: false) { size in
            CGPoint(x: screen.minX, y: screen.minY - 6 - size.height)
        }
    }

    // MARK: Link popover (⌘K) and note picker ([[)

    func openLinkPopover() {
        guard let tv = textView, let window = tv.window, tv.isEditable else { return }
        closePicker()
        hideBubble()
        let selection = tv.selectedRange()
        linkSelection = selection
        picker.query = ""
        picker.index = 0
        picker.pickNote = false
        let selected = selection.length > 0 ? (tv.string as NSString).substring(with: selection) : ""
        search(selected.count <= 60 ? selected : "", fallbackToAll: true)
        queryWatch = picker.$query.dropFirst().removeDuplicates().sink { [weak self] q in
            self?.search(MarkdownCommands.looksLikeURL(q) ? "" : q, fallbackToAll: false)
        }
        let rect = tv.firstRect(forCharacterRange: selection, actualRange: nil)
        let view = MarkdownLinkPopover(picker: picker, showsField: true,
                                       commit: { [weak self] in self?.commitLink() },
                                       cancel: { [weak self] in self?.closePicker(refocus: true) })
        pickerPanel.show(view, parent: window, key: true, place: { size in
            CGPoint(x: rect.minX - 2, y: rect.minY - 8 - size.height)
        }, onDismiss: { [weak self] in self?.closePicker(refocus: false) })
        linkWindow = pickerPanel.window
    }

    private func commitLink() {
        guard let tv = textView, let selection = linkSelection else { return closePicker(refocus: true) }
        let query = picker.query.trimmingCharacters(in: .whitespaces)
        let edit: MarkdownEdit?
        if !picker.pickNote, MarkdownCommands.looksLikeURL(query) {
            edit = MarkdownCommands.link(url: query, text: tv.string, selection: selection)
        } else if let page = picker.selected {
            edit = MarkdownCommands.wikilink(page, text: tv.string, selection: selection)
        } else if !query.isEmpty {
            edit = MarkdownCommands.wikilink(PageRef(path: query + ".md", title: query), text: tv.string, selection: selection)
        } else {
            edit = nil
        }
        closePicker(refocus: true)
        if let edit { apply(edit) }
    }

    private func openAnchoredPicker(_ anchor: Int) {
        guard let tv = textView, let window = tv.window else { return }
        closePicker()
        hideBubble()
        pickerAnchor = anchor
        picker.query = ""
        picker.index = 0
        picker.pickNote = true
        search("", fallbackToAll: true)
        let rect = tv.firstRect(forCharacterRange: NSRange(location: max(0, anchor - 2), length: 0), actualRange: nil)
        let view = MarkdownLinkPopover(picker: picker, showsField: false,
                                       commit: { [weak self] in self?.commitAnchoredPicker() },
                                       cancel: { [weak self] in self?.closePicker() })
        pickerPanel.show(view, parent: window, key: false, place: { size in
            CGPoint(x: rect.minX - 2, y: rect.minY - 6 - size.height)
        }, onDismiss: { [weak self] in self?.pickerAnchor = nil })
    }

    private func refreshAnchoredPicker() {
        guard let anchor = pickerAnchor, let tv = textView else { return }
        guard let q = MarkdownCommands.pickerQuery(text: tv.string, anchor: anchor, cursor: tv.selectedRange().location) else {
            closePicker()
            return
        }
        if q != picker.query {
            picker.query = q
            search(q, fallbackToAll: false)
        }
    }

    private func commitAnchoredPicker() {
        guard let tv = textView, let anchor = pickerAnchor else { return }
        let cursor = tv.selectedRange().location
        let page = picker.selected ?? (picker.query.isEmpty ? nil : PageRef(path: picker.query + ".md", title: picker.query))
        let range = MarkdownCommands.pickerRange(text: tv.string, anchor: anchor, cursor: cursor)
        closePicker()
        guard let page else { return }
        apply(MarkdownCommands.wikilink(page, text: tv.string, selection: tv.selectedRange(), replacing: range))
    }

    private func closePicker(refocus: Bool = false) {
        searchTask?.cancel()
        queryWatch = nil
        pickerAnchor = nil
        let selection = linkSelection
        linkWindow = nil
        linkSelection = nil
        pickerPanel.close()
        if refocus, let tv = textView, let window = tv.window {
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(tv)
            if let selection, NSMaxRange(selection) <= (tv.string as NSString).length { tv.setSelectedRange(selection) }
        }
    }

    private func search(_ query: String, fallbackToAll: Bool) {
        searchTask?.cancel()
        picker.searching = true
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            var results = await MarkdownPageSearch.search(query)
            if results.isEmpty && fallbackToAll && !query.isEmpty { results = await MarkdownPageSearch.search("") }
            guard !Task.isCancelled, let self else { return }
            self.picker.results = results
            self.picker.index = 0
            self.picker.searching = false
            DispatchQueue.main.async { self.pickerPanel.refit() }
        }
    }
}
