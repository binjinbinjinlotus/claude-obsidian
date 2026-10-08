import AppKit
import SwiftUI

enum SettingsWindowSize {
    static let initial = NSSize(width: 1140, height: 720)
    /// Every page fits from here: rows reflow instead of widening the window.
    static let minimum = NSSize(width: 820, height: 600)
    /// The section nav's fixed width.
    static let nav: CGFloat = 236
}

/// The Settings window. Closing it ends the Settings session: remembered
/// scroll positions and prompt-reset undos are dropped, and the next open
/// builds the page fresh (a reused hosting view would keep its old offset).
@MainActor
final class SettingsWindowController {
    let engine: AppModel
    private(set) var window: NSWindow?
    private var closeObserver: NSObjectProtocol?

    init(engine: AppModel) { self.engine = engine }

    deinit { if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) } }

    /// Creates the window, or rebuilds its content when it was closed, and shows it.
    func show() {
        if let window {
            if !window.isVisible { window.contentViewController = Self.content(engine) }
        } else {
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: SettingsWindowSize.initial),
                styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false)
            window.title = "Distill Settings"
            AppDelegate.styleChrome(window)
            window.isReleasedWhenClosed = false
            window.contentViewController = Self.content(engine)
            // The SwiftUI frame asks for the same minimum; set it here too so AppKit enforces it.
            window.contentMinSize = SettingsWindowSize.minimum
            window.setContentSize(SettingsWindowSize.initial)
            window.center()
            closeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.engine.settingsUI.closed() }
            }
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
    }

    private static func content(_ engine: AppModel) -> NSViewController {
        NSHostingController(rootView: SettingsView().environmentObject(engine))
    }
}

/// Reads and sets the scroll offset of each Settings page's NSScrollView (a
/// SwiftUI ScrollView on macOS 14 has no offset API). Offsets are distances
/// from the top of the page. Each page is built fresh when it is shown, so the
/// scroll view is looked up per page: the old page's view may still be around
/// (and still posting) while the new one appears.
@MainActor
final class SettingsScroller {
    private final class Entry {
        weak var scroll: NSScrollView?
        var observer: NSObjectProtocol?
        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    }

    /// The page being shown (its target id: "vaults", "connections", "actions/jira").
    var page = ""
    /// Called with the current page's offset whenever it scrolls (by the user or by `set`).
    var onScroll: (CGFloat) -> Void = { _ in }
    private var entries: [String: Entry] = [:]

    func attach(_ scroll: NSScrollView, page: String) {
        if let entry = entries[page], entry.scroll === scroll { return }
        let entry = Entry()
        entry.scroll = scroll
        scroll.contentView.postsBoundsChangedNotifications = true
        entry.observer = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self, weak scroll] _ in
            MainActor.assumeIsolated {
                // Only the page on screen records; a page being torn down doesn't.
                guard let self, let scroll, self.page == page, self.entries[page]?.scroll === scroll,
                      let y = self.offset else { return }
                self.onScroll(y)
            }
        }
        entries[page] = entry
    }

    /// The current page's scroll view, once it is in the window.
    var scrollView: NSScrollView? {
        guard let scroll = entries[page]?.scroll, scroll.window != nil else { return nil }
        return scroll
    }

    private var maxOffset: CGFloat {
        guard let scroll = scrollView, let doc = scroll.documentView else { return 0 }
        return max(0, doc.frame.height - scroll.contentView.bounds.height)
    }

    var offset: CGFloat? {
        guard let scroll = scrollView else { return nil }
        let y = scroll.contentView.bounds.origin.y
        return scroll.documentView?.isFlipped ?? true ? y : maxOffset - y
    }

    /// Scrolls the current page to `y` from the top, clamped to the page.
    func set(_ y: CGFloat) {
        guard let scroll = scrollView else { return }
        let top = min(max(0, y), maxOffset)
        let origin = scroll.documentView?.isFlipped ?? true ? top : maxOffset - top
        scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.origin.x, y: origin))
        scroll.reflectScrolledClipView(scroll.contentView)
    }
}

/// Rows a search result can land on. A row reports where it sits on its page
/// (distance from the page's top, in the `space` coordinate space) under the
/// key of the search entry's title (`SettingsIndex`), passed explicitly where
/// the row's label reads differently.
enum SettingsAnchor {
    static let space = "settings.page"

    /// "Include notes whose labels aren’t confirmed yet" and "…aren't…" are one key.
    static func key(_ title: String) -> String {
        title.lowercased().replacingOccurrences(of: "’", with: "'")
    }

    struct Positions: PreferenceKey {
        static let defaultValue: [String: CGFloat] = [:]
        static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
            value.merge(nextValue()) { min($0, $1) }
        }
    }
}

extension View {
    /// Marks this row as where the search result `title` lands on its page.
    func settingsAnchor(_ title: String) -> some View {
        background(GeometryReader { g in
            Color.clear.preference(key: SettingsAnchor.Positions.self,
                                   value: [SettingsAnchor.key(title): g.frame(in: .named(SettingsAnchor.space)).minY])
        })
    }
}

/// Put inside a page's ScrollView content: registers the enclosing NSScrollView for `page`.
struct SettingsScrollProbe: NSViewRepresentable {
    let scroller: SettingsScroller
    let page: String

    func makeNSView(context: Context) -> Probe { Probe(scroller: scroller, page: page) }
    func updateNSView(_ view: Probe, context: Context) {
        view.scroller = scroller
        view.page = page
        view.attach()
    }

    final class Probe: NSView {
        var scroller: SettingsScroller
        var page: String

        init(scroller: SettingsScroller, page: String) {
            self.scroller = scroller
            self.page = page
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            attach()
        }

        func attach() {
            guard window != nil else { return }
            var v = superview
            while let current = v {
                if let scroll = current as? NSScrollView {
                    MainActor.assumeIsolated { scroller.attach(scroll, page: page) }
                    return
                }
                v = current.superview
            }
        }
    }
}
