import AppKit
import SwiftUI
import DistillKit

/// A TextField that keeps what you type as you type it (FieldDraft, actions.md When field edits
/// save) and saves the normalised value after a short pause, on Return, when it loses focus, when
/// `key` changes (another item: saved to the old one), when it goes away and when a window closes.
/// Style it like a TextField; the modifiers apply to the field inside.
struct DraftTextField: View {
    let placeholder: String
    /// Whose value this is (an item id); `save` gets the key the text belongs to.
    let key: String
    /// The stored value, normalised.
    let value: String
    var axis: Axis = .horizontal
    let normalize: (String) -> String?
    let save: (_ key: String, _ value: String) -> Void

    @State private var draft: FieldDraft?
    @State private var pause: Task<Void, Never>?
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: Binding(get: { draft?.text ?? value }, set: { edit($0) }), axis: axis)
            .focused($focused)
            .onSubmit { finish() }
            .onChange(of: focused) { _, now in if !now { finish() } }
            .onChange(of: key) { load() }
            .onChange(of: value) { load() }
            .onDisappear { finish() }
            // The main window is kept when closed, so it may not disappear: save without touching the text.
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { _ in flush() }
    }

    private func edit(_ text: String) {
        var d = draft ?? FieldDraft(key: key, value: value)
        d.text = text
        draft = d
        pause?.cancel()
        pause = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            if !Task.isCancelled { flush() }
        }
    }

    /// Saves while you may still be typing: the text stays as typed.
    private func flush() {
        pause?.cancel()
        guard var d = draft else { return }
        let out = d.save(normalize)
        draft = d
        if let out { save(d.key, out) }
    }

    private func finish() {
        pause?.cancel()
        guard var d = draft else { return }
        let out = d.finish(normalize)
        draft = d
        if let out { save(d.key, out) }
    }

    private func load() {
        guard var d = draft else { return }
        if d.key != key { pause?.cancel() }
        let out = d.load(key: key, value: value, editing: focused, normalize)
        draft = d
        if let out { save(out.key, out.value) }
    }
}
