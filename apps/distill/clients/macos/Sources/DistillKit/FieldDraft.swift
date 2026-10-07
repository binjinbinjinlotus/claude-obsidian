import Foundation

// A free-text field's edit in progress (actions.md, When field edits save). What you type
// stays exactly as typed: it is normalised (trimmed, labels split) only when it is saved,
// and the saved value is never read back into the field while you are typing. Before this,
// the fields read the item back on every key, so "Linu " came back as "Linu" and the space
// vanished.

public struct FieldDraft: Equatable, Sendable {
    /// What the draft belongs to (an item id, a person id). A new key saves the old draft first.
    public private(set) var key: String
    /// The text as typed.
    public var text: String
    /// The value as stored, normalised; what `text` is compared against.
    public private(set) var saved: String

    public init(key: String, value: String) {
        self.key = key
        self.text = value
        self.saved = value
    }

    /// The normalised value to save now, or nil when it matches what is stored or can't be saved
    /// (`normalize` returns nil, e.g. an empty title). Never touches `text`.
    public mutating func save(_ normalize: (String) -> String?) -> String? {
        guard let value = normalize(text), value != saved else { return nil }
        saved = value
        return value
    }

    /// Leaving the field (Return, focus loss, the editor closing): save, then show the stored
    /// form, so " Linu Chui " reads "Linu Chui" and an empty title goes back to the old one.
    public mutating func finish(_ normalize: (String) -> String?) -> String? {
        let value = save(normalize)
        text = saved
        return value
    }

    /// The stored value for `key`, as the view sees it now. Another key (you picked another item)
    /// returns the old draft's pending save, as (old key, value), and starts over. The same key
    /// updates `saved`, and shows the value only while you are not typing in the field.
    public mutating func load(key: String, value: String, editing: Bool,
                              _ normalize: (String) -> String?) -> (key: String, value: String)? {
        guard key == self.key else {
            let old = self.key
            let pending = save(normalize)
            self = FieldDraft(key: key, value: value)
            return pending.map { (old, $0) }
        }
        saved = value
        if !editing { text = value }
        return nil
    }
}

/// How each to-do field is normalised when it saves.
public enum FieldText {
    /// Leading and trailing spaces and newlines go; inner spaces stay ("Linu Chui").
    public static func trimmed(_ text: String) -> String? {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A title or a person's name can't be empty: nil keeps the old one.
    public static func nonEmpty(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// "tea-club, #project-x," → ["tea-club", "project-x"].
    public static func labels(_ text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "#")) }
            .filter { !$0.isEmpty }
    }

    /// Labels as the field shows them: "tea-club, project-x".
    public static func labelText(_ text: String) -> String? { labels(text).joined(separator: ", ") }
}
