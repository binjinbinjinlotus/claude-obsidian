import AppKit
import Combine
import SwiftUI
import DistillKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    /// The app is a client of the Distill core (one per state dir). Leaving the
    /// app does not stop the core: the CLI or agents may be using it.
    let engine = AppModel(launcher: CoreLauncher(
        paths: StatePaths.resolve(),
        bundledProductRoot: Bundle.main.object(forInfoDictionaryKey: "ClaudeObsidianProductRoot") as? String))
    private var mainWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var floatingIcon: FloatingIconController?
    private var quickAsk: QuickAskController?
    private var pasteMonitor: Any?
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = buildMenu()
        engine.connect()
        engine.installNotesFeatures() // quick note window, global shortcuts, Labels count (AppModel+Notes.swift)
        floatingIcon = FloatingIconController(engine: engine, onOpen: { [weak self] in self?.flaskClicked() },
                                              onMenu: { [weak self] action in self?.hoverMenu(action) })
        quickAsk = QuickAskController(engine: engine, onContinue: { [weak self] in
            self?.quickAsk?.hide()
            self?.showMainWindow()
        })
        // Global shortcuts and other windows ask for the quick windows by notification.
        NotificationCenter.default.addObserver(forName: Self.openQuickAsk, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.showQuickAsk() }
        }
        // Other screens open a Settings section ("connections", "models", "actions/jira").
        NotificationCenter.default.addObserver(forName: .distillOpenSettingsSection, object: nil, queue: .main) { [weak self] note in
            let id = note.object as? String
            MainActor.assumeIsolated {
                if let id { self?.engine.settingsUI.open(id) }
                self?.showSettings()
            }
        }
        if UserDefaults.standard.object(forKey: "showFloatingIcon") as? Bool ?? true {
            floatingIcon?.show()
        }
        installPasteShortcut()
        showMainWindow()
        // First run: once the core answers with no vaults, open Settings.
        engine.$connection
            .first { $0 == .connected }
            .sink { [weak self] _ in
                guard let self, self.engine.settings.vaults.isEmpty else { return }
                self.showSettings()
            }
            .store(in: &cancellables)
        // Open in Actions (from quick ask, a toast or a job): the quick window closes, the main window shows.
        Publishers.Merge(engine.actions.$showRequest.dropFirst(), engine.actions.$historyRequest.dropFirst())
            .sink { [weak self] _ in
                if self?.quickAsk?.isVisible == true { self?.quickAsk?.hide() }
                self?.showMainWindow()
            }
            .store(in: &cancellables)
        engine.$jobs
            .map { $0.filter { $0.state == .awaitingApproval }.count }
            .removeDuplicates()
            .sink { count in NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : nil }
            .store(in: &cancellables)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    // MARK: Quick actions

    static let openQuickAsk = Notification.Name("distill.openQuickAsk")
    static let openQuickNote = Notification.Name("distill.openQuickNote")

    /// Click on the flask: a quick ask question still answering (green ring) opens on
    /// the Ask screen, where its answer arrives; otherwise the app.
    private func flaskClicked() {
        if engine.ask.quickInBackground, let run = engine.ask.quickBackgroundRun { engine.ask.open(conversationID: run.id) }
        showMainWindow()
    }

    private func hoverMenu(_ action: HoverMenuController.Action) {
        switch action {
        case .ask: quickAsk?.show(near: flaskFrame) // from the flask: open on its screen
        case .addNote: QuickNoteController.anchor = flaskFrame; NotificationCenter.default.post(name: Self.openQuickNote, object: nil)
        case .paste: pasteIntoQueue()
        case .open: showMainWindow()
        }
    }

    /// Shortcuts and the Window menu: open on the screen with the pointer.
    @objc func showQuickAsk() { quickAsk?.show(near: nil) }

    private var flaskFrame: NSRect? { floatingIcon?.isVisible == true ? floatingIcon?.frame : nil }

    // MARK: Windows

    @objc func showMainWindow() {
        if mainWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 980, height: 640),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false)
            window.title = "Distill"
            Self.styleChrome(window)
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("DistillMain")
            window.delegate = self
            window.contentViewController = NSHostingController(
                rootView: MainView(openSettings: { [weak self] in self?.showSettings() })
                    .environmentObject(engine))
            // NSHostingController sizes the window to the view's ideal size; pin a sane default.
            window.contentMinSize = NSSize(width: 900, height: 600)
            if !window.setFrameUsingName("DistillMain") || window.frame.width < 900 {
                window.setContentSize(NSSize(width: 1120, height: 720))
                window.center()
            }
            mainWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        mainWindow?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // Closing the main window closes the Ask screen (Keep history off deletes its chat).
        if (notification.object as? NSWindow) === mainWindow { engine.ask.leave(engine.ask.main) }
    }

    /// Light, title-less chrome so the traffic lights sit on the design's own surface.
    private static func styleChrome(_ window: NSWindow) {
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.backgroundColor = .white
        window.appearance = NSAppearance(named: .aqua)
    }

    @objc func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1140, height: 720),
                styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false)
            window.title = "Distill Settings"
            Self.styleChrome(window)
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: SettingsView().environmentObject(engine))
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func toggleFloatingIcon() {
        guard let icon = floatingIcon else { return }
        icon.isVisible ? icon.hide() : icon.show()
        UserDefaults.standard.set(icon.isVisible, forKey: "showFloatingIcon")
    }

    @objc func pasteIntoQueue() {
        if !PasteboardIntake.ingest(NSPasteboard.general, engine: engine) {
            engine.lastError = "Nothing pasteable on the clipboard (files, images, or text)."
        }
    }

    @objc func processNow() { engine.processQueue(force: true) }

    /// ⌘V in a worker window pastes into the queue unless a text field is editing.
    private func installPasteShortcut() {
        pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  event.charactersIgnoringModifiers == "v",
                  let window = NSApp.keyWindow, window === self.mainWindow,
                  !(window.firstResponder is NSText) else { return event }
            self.pasteIntoQueue()
            return nil
        }
    }

    // MARK: Menu

    private func buildMenu() -> NSMenu {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Distill", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(item("Settings…", #selector(showSettings), ","))
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Distill", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Distill", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let queueItem = NSMenuItem()
        let queue = NSMenu(title: "Queue")
        queue.addItem(item("Paste into Queue", #selector(pasteIntoQueue), "V"))
        queue.addItem(item("Process Queue Now", #selector(processNow), "r"))
        queueItem.submenu = queue
        main.addItem(queueItem)

        let windowItem = NSMenuItem()
        let window = NSMenu(title: "Window")
        window.addItem(item("Show Worker", #selector(showMainWindow), "0"))
        window.addItem(item("Toggle Floating Icon", #selector(toggleFloatingIcon), "i"))
        window.addItem(item("Quick Ask", #selector(showQuickAsk), ""))
        window.addItem(.separator())
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = window
        main.addItem(windowItem)
        NSApp.windowsMenu = window
        return main
    }

    private func item(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }
}
