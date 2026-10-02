import Foundation

/// A tool call the runner refused because no permission rule allowed it.
public struct PermissionDenial: Codable, Hashable, Sendable {
    public var toolName: String
    public var input: [String: JSONValue]
    /// `suggestedRule` as the core sent it (string or null); nil when the core sent none.
    public var coreRule: CoreRule?

    public enum CoreRule: Hashable, Sendable {
        case rule(String)
        case noRule
    }

    enum CodingKeys: String, CodingKey { case toolName, input, suggestedRule }

    public init(toolName: String, input: [String: JSONValue], coreRule: CoreRule? = nil) {
        self.toolName = toolName
        self.input = input
        self.coreRule = coreRule
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        toolName = try c.decode(String.self, forKey: .toolName)
        input = (try? c.decodeIfPresent([String: JSONValue].self, forKey: .input)) ?? [:]
        if c.contains(.suggestedRule) {
            if let rule = try? c.decode(String.self, forKey: .suggestedRule) { coreRule = .rule(rule) }
            else if (try? c.decodeNil(forKey: .suggestedRule)) == true { coreRule = .noRule }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(toolName, forKey: .toolName)
        try c.encode(input, forKey: .input)
        switch coreRule {
        case .rule(let r): try c.encode(r, forKey: .suggestedRule)
        case .noRule: try c.encodeNil(forKey: .suggestedRule)
        case nil: break
        }
    }

    /// A rule that would allow exactly this call on resume, or nil when no
    /// exact rule can match (compound shell commands are checked per part).
    /// The core's `suggestedRule` wins when it sent one (string or null).
    public var suggestedRule: String? {
        switch coreRule {
        case .rule(let r): return r
        case .noRule: return nil
        case nil: return localSuggestedRule
        }
    }

    /// The client's own rule for cores that do not send `suggestedRule`.
    public var localSuggestedRule: String? {
        switch toolName {
        case "Bash":
            guard case .string(let cmd)? = input["command"] else { return nil }
            let compound = ["&&", "||", ";", "|", "\n", "$(", "`", "<<"].contains { cmd.contains($0) }
                || cmd.hasPrefix("cd ")
            return compound ? nil : "Bash(\(cmd))"
        case "Read":
            if case .string(let p)? = input["file_path"] { return "Read(/\(p))" }
        case "Write", "Edit", "MultiEdit", "NotebookEdit":
            // Edit rules cover all file-writing tools; Write(...) rules do not match.
            if case .string(let p)? = input["file_path"] { return "Edit(/\(p))" }
        case "WebFetch":
            if case .string(let u)? = input["url"], let host = URL(string: u)?.host {
                return "WebFetch(domain:\(host))"
            }
            return nil
        default: break
        }
        return toolName
    }

    /// Granting this lets Claude change files outside the approval gate.
    public var bypassesApproval: Bool {
        toolName == "Bash" || ((suggestedRule ?? "").hasPrefix("Edit(") && !(suggestedRule ?? "").contains("/.vault-meta/worker/"))
    }

    public var display: String {
        if case .string(let cmd)? = input["command"] { return "\(toolName): \(cmd)" }
        if case .string(let p)? = input["file_path"] { return "\(toolName): \(p)" }
        if case .string(let u)? = input["url"] { return "\(toolName): \(u)" }
        return toolName
    }
}
