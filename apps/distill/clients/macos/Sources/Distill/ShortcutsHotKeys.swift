import AppKit
import Carbon.HIToolbox
import Combine
import DistillKit

/// Registers the shortcuts recorded in Settings as system-wide hot keys
/// (Carbon `RegisterEventHotKey`: works from any app, needs no Accessibility
/// permission). A press posts the quick window's notification. Nothing is
/// registered while a shortcut is unset; settings changes re-register.
@MainActor
final class GlobalShortcuts {
    static let shared = GlobalShortcuts()

    private var refs: [ShortcutAction: EventHotKeyRef] = [:]
    private var registered: [ShortcutAction: KeyShortcut] = [:]
    private var handler: EventHandlerRef?
    private var cancellable: AnyCancellable?
    /// True while a recorder is listening, so the old combination does not fire.
    var suspended = false {
        didSet { if suspended != oldValue { apply(suspended ? [:] : desired) } }
    }
    private var desired: [ShortcutAction: KeyShortcut] = [:]

    private static let signature: OSType = 0x4453_544C // "DSTL"

    func observe(_ engine: AppModel) {
        cancellable = engine.$settings
            .map { Self.shortcuts(from: $0.shortcuts) }
            .removeDuplicates()
            .sink { [weak self] wanted in
                guard let self else { return }
                self.desired = wanted
                if !self.suspended { self.apply(wanted) }
            }
    }

    nonisolated static func shortcuts(from settings: ShortcutSettings?) -> [ShortcutAction: KeyShortcut] {
        var out: [ShortcutAction: KeyShortcut] = [:]
        if let s = settings?.ask.flatMap(KeyShortcut.init) { out[.ask] = s }
        if let s = settings?.addNote.flatMap(KeyShortcut.init) { out[.addNote] = s }
        return out
    }

    private func apply(_ wanted: [ShortcutAction: KeyShortcut]) {
        installHandlerIfNeeded()
        for action in ShortcutAction.allCases where registered[action] != wanted[action] {
            if let ref = refs.removeValue(forKey: action) { UnregisterEventHotKey(ref) }
            registered[action] = nil
            guard let shortcut = wanted[action] else { continue }
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: Self.signature, id: UInt32(ShortcutAction.allCases.firstIndex(of: action)! + 1))
            let status = RegisterEventHotKey(shortcut.carbonKeyCode, shortcut.carbonModifiers, id,
                                             GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                refs[action] = ref
                registered[action] = shortcut
            } else {
                NSLog("Distill: could not register shortcut %@ (%d)", shortcut.stringValue, status)
            }
        }
    }

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr, id.signature == GlobalShortcuts.signature else { return OSStatus(eventNotHandledErr) }
            let index = Int(id.id) - 1
            guard ShortcutAction.allCases.indices.contains(index) else { return OSStatus(eventNotHandledErr) }
            let action = ShortcutAction.allCases[index]
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: action.notification, object: nil)
            }
            return noErr
        }, 1, &spec, nil, &handler)
    }
}
