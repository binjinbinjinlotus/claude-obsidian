import Foundation
import DistillKit

// UI-free label logic: normalization (same rules as core/src/labels/vault.ts)
// and the label step that follows "Add to queue" in the composer and the
// quick-note window. See docs/specs/labels-and-sources.md.

enum LabelName {
    /// Lower case, no `#`, spaces → `-`, only letters, digits, `_`, `-`, `/`.
    /// Purely numeric values are dropped (nil).
    static func normalize(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while s.hasPrefix("#") { s.removeFirst() }
        s = s.split(whereSeparator: { $0.isWhitespace }).joined(separator: "-")
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-/"))
        s = String(String.UnicodeScalarView(s.unicodeScalars.filter { allowed.contains($0) }))
        guard !s.isEmpty, !s.allSatisfy(\.isNumber) else { return nil }
        return s
    }

    /// Several labels typed in one field ("tea, brewing #gyokuro").
    static func parseList(_ raw: String) -> [String] {
        dedupe(raw.split(whereSeparator: { $0 == "," || $0 == "#" }).compactMap { normalize(String($0)) })
    }

    static func dedupe(_ labels: [String]) -> [String] {
        var seen = Set<String>()
        return labels.filter { seen.insert($0).inserted }
    }
}

/// What happens after a note is queued: suggestions arrive (or fail), the user
/// edits the chosen set, then applies it (labelNote) or skips (nothing is sent,
/// the note stays unlabeled). Nothing is ever applied on its own.
struct LabelStep: Equatable {
    enum Phase: Equatable {
        /// Waiting for the `labelSuggestions` event for `requestID`.
        case suggesting
        /// Suggestions arrived, failed, or were not requested: the user picks.
        case choosing
        case applying
        case applied
        case skipped
    }

    let requestID: String
    let title: String
    let startedAt: Date
    private(set) var phase: Phase
    private(set) var suggestions: [LabelSuggestion] = []
    /// The labels that Apply will send, in display order.
    private(set) var chosen: [String] = []
    /// Labels the user typed (shown even if not suggested).
    private(set) var own: [String] = []
    private(set) var suggestError: String?
    private(set) var applyError: String?

    init(requestID: String, title: String, suggesting: Bool, startedAt: Date = Date()) {
        self.requestID = requestID
        self.title = title
        self.startedAt = startedAt
        phase = suggesting ? .suggesting : .choosing
    }

    var isOpen: Bool { phase == .suggesting || phase == .choosing || phase == .applying }
    var canApply: Bool { (phase == .choosing || phase == .suggesting) && !chosen.isEmpty }
    /// Every chip on screen: suggestions (existing first), then the user's own.
    var chips: [LabelSuggestion] {
        let suggested = suggestions.sorted { $0.existing && !$1.existing }
        let names = Set(suggested.map(\.name))
        return suggested + own.filter { !names.contains($0) }.map { LabelSuggestion(name: $0, existing: true) }
    }

    func isChosen(_ name: String) -> Bool { chosen.contains(name) }

    /// The `labelSuggestions` event (or the `addNote` result). Other notes' events are ignored.
    mutating func received(requestID: String, labels: [LabelSuggestion], error: String?) {
        guard requestID == self.requestID, phase == .suggesting || phase == .choosing else { return }
        if let error, labels.isEmpty {
            suggestError = error
        } else {
            suggestError = nil
            suggestions = LabelName.dedupe(labels.compactMap { LabelName.normalize($0.name) })
                .map { name in LabelSuggestion(name: name, existing: labels.first { LabelName.normalize($0.name) == name }?.existing ?? false) }
            chosen = LabelName.dedupe(chosen + suggestions.map(\.name))
        }
        if phase == .suggesting { phase = .choosing }
    }

    /// Adds labels the user typed; returns false when nothing valid was typed.
    @discardableResult
    mutating func add(_ raw: String) -> Bool {
        guard isOpen, phase != .applying else { return false }
        let names = LabelName.parseList(raw)
        guard !names.isEmpty else { return false }
        own = LabelName.dedupe(own + names)
        chosen = LabelName.dedupe(chosen + names)
        return true
    }

    /// × on a chip: an own label disappears, a suggestion is just unchosen.
    mutating func remove(_ name: String) {
        guard phase != .applying else { return }
        chosen.removeAll { $0 == name }
        own.removeAll { $0 == name }
    }

    mutating func toggle(_ name: String) {
        if chosen.contains(name) { remove(name) } else if suggestions.contains(where: { $0.name == name }) { chosen.append(name) }
    }

    mutating func applyStarted() {
        guard canApply else { return }
        applyError = nil
        phase = .applying
    }

    mutating func applySucceeded(labels: [String]) {
        chosen = labels.isEmpty ? chosen : labels
        phase = .applied
    }

    mutating func applyFailed(_ error: Error) {
        phase = .choosing
        applyError = Self.message(for: error)
    }

    mutating func skip() {
        guard phase != .applying else { return }
        phase = .skipped
    }

    static func message(for error: Error) -> String {
        if let e = error as? CoreClientError {
            switch e.code {
            case "invalid_state": return "The batch already took this note, so label it from Labels instead."
            case "not_found": return "This note is no longer in the queue."
            default: return e.description
            }
        }
        return "\(error)"
    }
}
