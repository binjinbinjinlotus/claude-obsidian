import Foundation

// UI-free rules behind the Ask screen and the quick ask window, kept here so
// they are unit-tested (specs: ask.md, labels-and-sources.md, quick-actions.md).

extension AskPreferences {
    /// `DEFAULT_ASK_PREFERENCES` in contracts.ts.
    public static let defaults = AskPreferences(labelMatch: .any, includeUnconfirmed: true, keepHistory: true, historyDays: 10)

    public var resolvedLabelMatch: LabelMatch { labelMatch ?? .any }
    public var resolvedIncludeUnconfirmed: Bool { includeUnconfirmed ?? true }
    public var resolvedKeepHistory: Bool { keepHistory ?? true }
    public var resolvedHistoryDays: Int { historyDays ?? 10 }
}

extension Settings {
    /// `askPreferences` with contract defaults for missing fields.
    public var resolvedAskPreferences: AskPreferences { askPreferences ?? .defaults }
    /// `sourceTaxonomy`, else `DEFAULT_SOURCE_TAXONOMY`.
    public var resolvedSourceTaxonomy: [SourceGroup] {
        if let t = sourceTaxonomy, !t.isEmpty { return t }
        return SourceGroup.defaultTaxonomy
    }
}

/// The scope of one Ask chat: all notes by default, narrowed by labels and sources.
public struct AskFilter: Equatable, Sendable {
    public var labels: [String] = []
    /// Source ids and group ids (a group includes all its sources).
    public var sources: [String] = []
    public var labelMatch: LabelMatch
    public var includeUnconfirmed: Bool

    /// A new chat starts from the user's Ask settings (contract defaults when absent).
    public init(preferences: AskPreferences? = nil) {
        let p = preferences ?? .defaults
        labelMatch = p.resolvedLabelMatch
        includeUnconfirmed = p.resolvedIncludeUnconfirmed
    }

    public var isEmpty: Bool { labels.isEmpty && sources.isEmpty }
    /// "Any label | All labels" only means something with two or more labels.
    public var showsMatchSwitch: Bool { labels.count >= 2 }
    /// "Include unconfirmed" only matters when labels are chosen.
    public var showsUnconfirmedToggle: Bool { !labels.isEmpty }

    /// Trimmed, without a leading `#`, lower case (same as the core).
    public static func normalize(_ label: String) -> String {
        var s = label.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasPrefix("#") { s.removeFirst() }
        return s.lowercased()
    }

    public mutating func addLabel(_ raw: String) {
        let name = Self.normalize(raw)
        guard !name.isEmpty, !name.contains(where: \.isWhitespace), !labels.contains(name) else { return }
        labels.append(name)
    }

    public mutating func removeLabel(_ name: String) { labels.removeAll { $0 == name } }

    public mutating func addSource(_ id: String) {
        guard !id.isEmpty, !sources.contains(id) else { return }
        sources.append(id)
    }

    public mutating func removeSource(_ id: String) { sources.removeAll { $0 == id } }

    /// Fills the filter fields of a request. Fields are left out when they do
    /// not apply, so the core's own defaults stay authoritative.
    public func apply(to request: inout AskRequest) {
        request.labels = labels.isEmpty ? nil : labels
        request.sources = sources.isEmpty ? nil : sources
        request.labelMatch = labels.isEmpty ? nil : labelMatch
        request.includeUnconfirmed = labels.isEmpty ? nil : includeUnconfirmed
    }

    /// The filter a stored request was asked with (to restore a chat's scope).
    public init(request: AskRequest, preferences: AskPreferences? = nil) {
        self.init(preferences: preferences)
        labels = request.labels ?? []
        sources = request.sources ?? []
        if let m = request.labelMatch { labelMatch = m }
        if let u = request.includeUnconfirmed { includeUnconfirmed = u }
    }

    /// "#tea or #gyokuro", "#tea and #gyokuro", "Slack", "All notes".
    public func summary(taxonomy: [SourceGroup]) -> String {
        var parts: [String] = []
        if !labels.isEmpty {
            parts.append(labels.map { "#\($0)" }.joined(separator: labelMatch == .all ? " and " : " or "))
        }
        if !sources.isEmpty {
            parts.append(sources.map { Self.sourceLabel($0, taxonomy: taxonomy) }.joined(separator: " or "))
        }
        return parts.isEmpty ? "All notes" : parts.joined(separator: " · ")
    }

    /// Display name of a source or group id.
    public static func sourceLabel(_ id: String, taxonomy: [SourceGroup]) -> String {
        for g in taxonomy {
            if g.id == id { return g.label }
            if let s = g.sources.first(where: { $0.id == id }) { return s.label }
        }
        return id
    }

    /// "15 pages (3 unconfirmed)" from a notice like "Limited to 15 pages (3 unconfirmed).".
    public static func pageCount(notices: [String]) -> String? {
        for n in notices {
            guard let r = n.range(of: "Limited to ") else { continue }
            var rest = String(n[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            if rest.hasSuffix(".") { rest.removeLast() }
            return rest
        }
        return nil
    }

    /// Notices other than the page count (shown as small info lines).
    public static func infoNotices(_ notices: [String]) -> [String] {
        notices.filter { $0.range(of: "Limited to ") == nil }
    }
}

/// Which runner, model and effort an Ask question uses.
public enum AskSelection {
    /// Enabled runners that can do the `ask` task.
    public static func runners(_ all: [RunnerInfo]) -> [RunnerInfo] {
        all.filter { $0.enabled && $0.tasks.contains(.ask) }
    }

    /// Order: the chat's last selection, then the `ask` task default, then the
    /// legacy `model` setting on the first ask runner. Dropped when its runner
    /// is not available.
    public static func resolve(current: ModelSelection?, settings: Settings, runners: [RunnerInfo]) -> ModelSelection {
        let usable = Self.runners(runners)
        func ok(_ s: ModelSelection?) -> ModelSelection? {
            guard let s else { return nil }
            return usable.isEmpty || usable.contains(where: { $0.id == s.runnerID }) ? s : nil
        }
        if let s = ok(current) { return s }
        if let s = ok(settings.taskDefaults[AITask.ask.rawValue]) { return s }
        if let r = usable.first {
            let model = r.id == "claude-code" ? settings.model : (r.defaultModel.isEmpty ? settings.model : r.defaultModel)
            return ModelSelection(runnerID: r.id, model: model, effort: nil)
        }
        return ModelSelection(runnerID: "claude-code", model: settings.model, effort: nil)
    }

    /// "Low", "Medium", "High", "X-High", "Max".
    public static func effortLabel(_ level: String) -> String {
        switch level.lowercased() {
        case "xhigh": return "X-High"
        default: return level.prefix(1).uppercased() + level.dropFirst()
        }
    }

    /// "Claude Code · Sonnet", "Sonnet · Medium".
    public static func modelLabel(_ selection: ModelSelection, runners: [RunnerInfo]) -> String {
        let runner = runners.first { $0.id == selection.runnerID }
        if let option = runner?.models.first(where: { $0.id == selection.model }) {
            return option.label.replacingOccurrences(of: " (latest)", with: "")
        }
        return ModelChoice.shortName(selection.model)
    }
}

/// Ask history retention on the client side (with Keep off there is no age
/// sweep; the client deletes a chat when the user leaves it).
public enum AskHistoryPolicy {
    /// The conversation to delete when the user leaves `id` (New chat, closing
    /// the Ask screen), or nil to keep it.
    /// - Never deletes a pinned chat, one that is still answering, or one just
    ///   handed to another window ("Continue in Distill").
    public static func conversationToDelete(leaving id: String?, keepHistory: Bool, pinned: Bool,
                                            isRunning: Bool, handedOff: Bool) -> String? {
        guard let id, !keepHistory, !pinned, !isRunning, !handedOff else { return nil }
        return id
    }

    /// Pinned first, then newest message first.
    public static func sorted(_ list: [AskConversationSummary]) -> [AskConversationSummary] {
        list.sorted { a, b in
            if a.pinned != b.pinned { return a.pinned }
            return a.updatedAt > b.updatedAt
        }
    }
}

/// Links that open a vault page in Obsidian.
public enum ObsidianLink {
    /// `obsidian://open?vault=<vault folder name>&file=<vault-relative path>`.
    /// Encoded strictly (unreserved characters only), so `&`, `+`, `#`, `?`
    /// and spaces in names survive.
    public static func url(vaultPath: String, page: String) -> URL? {
        let vault = URL(fileURLWithPath: vaultPath).lastPathComponent
        var file = page
        if file.hasSuffix(".md") { file.removeLast(3) }
        return URL(string: "obsidian://open?vault=\(encode(vault))&file=\(encode(file))")
    }

    static func encode(_ s: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~/")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}

/// Splits an answer into text and `[n]` citation markers.
public enum AskAnswer {
    public enum Piece: Equatable, Sendable {
        case text(String)
        case citation(Int)
    }

    public static func pieces(_ answer: String) -> [Piece] {
        var out: [Piece] = []
        var buffer = ""
        var i = answer.startIndex
        while i < answer.endIndex {
            if answer[i] == "[", let close = answer[i...].firstIndex(of: "]") {
                let inner = answer[answer.index(after: i)..<close]
                let numbers = inner.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                if !numbers.isEmpty, numbers.count <= 6, numbers.allSatisfy({ !$0.isEmpty && $0.count <= 3 && $0.allSatisfy(\.isNumber) }),
                   answer.index(after: close) == answer.endIndex || answer[answer.index(after: close)] != "(" {
                    if !buffer.isEmpty { out.append(.text(buffer)); buffer = "" }
                    out.append(contentsOf: numbers.compactMap { Int($0) }.map(Piece.citation))
                    i = answer.index(after: close)
                    continue
                }
            }
            buffer.append(answer[i])
            i = answer.index(after: i)
        }
        if !buffer.isEmpty { out.append(.text(buffer)) }
        return out
    }
}
