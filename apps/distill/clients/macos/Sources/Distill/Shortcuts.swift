import AppKit
import Carbon.HIToolbox

/// A global shortcut as stored in `settings.shortcuts` ("ctrl+opt+space").
/// Modifiers come first in a fixed order (ctrl, opt, shift, cmd), then one key.
/// At least one of ctrl/opt/cmd is required, so a plain letter never becomes global.
struct KeyShortcut: Equatable, Hashable {
    struct Modifiers: OptionSet, Hashable {
        let rawValue: Int
        static let control = Modifiers(rawValue: 1)
        static let option = Modifiers(rawValue: 2)
        static let shift = Modifiers(rawValue: 4)
        static let command = Modifiers(rawValue: 8)
    }

    var modifiers: Modifiers
    /// Lower-case key name: "a"…"z", "0"…"9", "space", "return", "f1"…, "left", ",", …
    var key: String

    init(modifiers: Modifiers, key: String) {
        self.modifiers = modifiers
        self.key = key
    }

    /// Parses "ctrl+opt+space" (also accepts "control", "alt", "option", "command", "cmd", "⌘"…).
    init?(_ string: String) {
        let parts = string.lowercased().split(separator: "+", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        // "ctrl++" means the plus key.
        var tokens = parts
        if string.hasSuffix("++") { tokens = Array(parts.dropLast(2)) + ["+"] }
        guard let last = tokens.last, !last.isEmpty else { return nil }
        var mods: Modifiers = []
        for token in tokens.dropLast() {
            switch token {
            case "ctrl", "control", "⌃": mods.insert(.control)
            case "opt", "option", "alt", "⌥": mods.insert(.option)
            case "shift", "⇧": mods.insert(.shift)
            case "cmd", "command", "⌘": mods.insert(.command)
            default: return nil
            }
        }
        let key = Self.aliases[last] ?? last
        guard Self.keyCodes[key] != nil else { return nil }
        guard !mods.intersection([.control, .option, .command]).isEmpty || key.hasPrefix("f") && key.count > 1 else { return nil }
        self.init(modifiers: mods, key: key)
    }

    /// Canonical stored form.
    var stringValue: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("ctrl") }
        if modifiers.contains(.option) { parts.append("opt") }
        if modifiers.contains(.shift) { parts.append("shift") }
        if modifiers.contains(.command) { parts.append("cmd") }
        parts.append(key)
        return parts.joined(separator: "+")
    }

    /// "⌃⌥Space" for display.
    var displayString: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        return s + (Self.symbols[key] ?? key.uppercased())
    }

    // MARK: Carbon

    var carbonKeyCode: UInt32 { UInt32(Self.keyCodes[key] ?? 0) }

    var carbonModifiers: UInt32 {
        var m: UInt32 = 0
        if modifiers.contains(.control) { m |= UInt32(controlKey) }
        if modifiers.contains(.option) { m |= UInt32(optionKey) }
        if modifiers.contains(.shift) { m |= UInt32(shiftKey) }
        if modifiers.contains(.command) { m |= UInt32(cmdKey) }
        return m
    }

    /// From a key-down event while recording; nil if it is not a usable shortcut.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var mods: Modifiers = []
        if flags.contains(.control) { mods.insert(.control) }
        if flags.contains(.option) { mods.insert(.option) }
        if flags.contains(.shift) { mods.insert(.shift) }
        if flags.contains(.command) { mods.insert(.command) }
        guard let key = Self.names[Int(event.keyCode)] else { return nil }
        self.init(modifiers: mods, key: key)
        guard KeyShortcut(stringValue) != nil else { return nil }
    }

    private static let aliases: [String: String] = [
        "enter": "return", "esc": "escape", "spacebar": "space", "del": "delete", "backspace": "delete",
        "up arrow": "up", "down arrow": "down",
    ]

    private static let symbols: [String: String] = [
        "space": "Space", "return": "↩", "tab": "⇥", "delete": "⌫", "escape": "⎋", "forwarddelete": "⌦",
        "left": "←", "right": "→", "up": "↑", "down": "↓", "home": "↖", "end": "↘", "pageup": "⇞", "pagedown": "⇟",
    ]

    static let keyCodes: [String: Int] = {
        var map: [String: Int] = [
            "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E, "f": kVK_ANSI_F,
            "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
            "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R,
            "s": kVK_ANSI_S, "t": kVK_ANSI_T, "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
            "y": kVK_ANSI_Y, "z": kVK_ANSI_Z,
            "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4,
            "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
            "space": kVK_Space, "return": kVK_Return, "tab": kVK_Tab, "delete": kVK_Delete, "escape": kVK_Escape,
            "forwarddelete": kVK_ForwardDelete, "left": kVK_LeftArrow, "right": kVK_RightArrow, "up": kVK_UpArrow,
            "down": kVK_DownArrow, "home": kVK_Home, "end": kVK_End, "pageup": kVK_PageUp, "pagedown": kVK_PageDown,
            "-": kVK_ANSI_Minus, "=": kVK_ANSI_Equal, "[": kVK_ANSI_LeftBracket, "]": kVK_ANSI_RightBracket,
            ";": kVK_ANSI_Semicolon, "'": kVK_ANSI_Quote, ",": kVK_ANSI_Comma, ".": kVK_ANSI_Period,
            "/": kVK_ANSI_Slash, "\\": kVK_ANSI_Backslash, "`": kVK_ANSI_Grave,
        ]
        let fKeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                     kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
        for (i, code) in fKeys.enumerated() { map["f\(i + 1)"] = code }
        return map
    }()

    private static let names: [Int: String] = Dictionary(keyCodes.map { ($0.value, $0.key) }, uniquingKeysWith: { a, _ in a })
}

/// Which quick window a shortcut opens. The notification names are shared
/// with the floating icon's hover menu (mac-flows posts the same names).
enum ShortcutAction: String, CaseIterable {
    case ask, addNote

    static let openQuickAsk = Notification.Name("distill.openQuickAsk")
    static let openQuickNote = Notification.Name("distill.openQuickNote")

    var notification: Notification.Name {
        switch self {
        case .ask: return Self.openQuickAsk
        case .addNote: return Self.openQuickNote
        }
    }
}
