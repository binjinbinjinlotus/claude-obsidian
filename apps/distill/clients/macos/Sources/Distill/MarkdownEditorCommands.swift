import Foundation
import DistillKit

// Style-bar commands, shortcuts, Return handling and type-to-format, as pure
// text edits on (text, selection). The text view applies one edit through
// shouldChangeText/replaceCharacters/didChangeText, so undo works. UTF-16 ranges.

/// Replace `range` with `replacement`, then select `selection` (in the new text).
struct MarkdownEdit: Equatable {
    var range: NSRange
    var replacement: String
    var selection: NSRange

    func applied(to text: String) -> (text: String, selection: NSRange) {
        ((text as NSString).replacingCharacters(in: range, with: replacement), selection)
    }
}

enum MarkdownCommand: Equatable, Hashable {
    case bold, italic, strike, code
    case heading(Int)            // 0 = normal text
    case list(MarkdownListKind)
    case quote, codeBlock
    case indent, outdent
}

enum MarkdownCommands {
    // MARK: Dispatch

    static func edit(_ command: MarkdownCommand, text: String, selection: NSRange) -> MarkdownEdit? {
        switch command {
        case .bold: return toggleInline("**", kind: .bold, text: text, selection: selection)
        case .italic: return toggleInline("*", kind: .italic, text: text, selection: selection)
        case .strike: return toggleInline("~~", kind: .strike, text: text, selection: selection)
        case .code: return toggleInline("`", kind: .code, text: text, selection: selection)
        case .heading(let level): return setHeading(level, text: text, selection: selection)
        case .list(let kind): return toggleList(kind, text: text, selection: selection)
        case .quote: return toggleQuote(text: text, selection: selection)
        case .codeBlock: return toggleCodeBlock(text: text, selection: selection)
        case .indent: return indent(text: text, selection: selection, outdent: false)
        case .outdent: return indent(text: text, selection: selection, outdent: true)
        }
    }

    // MARK: Inline

    /// Unwrap the span of `kind` around the selection, else wrap the selection
    /// (trimmed of outer spaces), else insert a pair of marks around the cursor.
    static func toggleInline(_ mark: String, kind: MarkdownSpanKind, text: String, selection: NSRange) -> MarkdownEdit {
        let ns = text as NSString
        let markLength = (mark as NSString).length
        let around = MarkdownParser.spans(in: text).filter { $0.kind == kind }.first { s in
            selection.length == 0
                ? selection.location >= s.content.location && selection.location <= NSMaxRange(s.content)
                : NSIntersectionRange(s.full, selection).length == selection.length
        }
        if let s = around {
            let content = ns.substring(with: s.content)
            let open = s.content.location - s.full.location
            let start = max(s.content.location, min(selection.location, NSMaxRange(s.content)))
            let end = max(start, min(NSMaxRange(selection), NSMaxRange(s.content)))
            return MarkdownEdit(range: s.full, replacement: content,
                                selection: NSRange(location: start - open, length: end - start))
        }
        guard selection.length > 0 else {
            return MarkdownEdit(range: selection, replacement: mark + mark,
                                selection: NSRange(location: selection.location + markLength, length: 0))
        }
        var r = selection
        while r.length > 0, let c = ns.substring(with: NSRange(location: r.location, length: 1)).unicodeScalars.first,
              CharacterSet.whitespacesAndNewlines.contains(c) { r.location += 1; r.length -= 1 }
        while r.length > 0, let c = ns.substring(with: NSRange(location: NSMaxRange(r) - 1, length: 1)).unicodeScalars.first,
              CharacterSet.whitespacesAndNewlines.contains(c) { r.length -= 1 }
        if r.length == 0 { r = selection }
        return MarkdownEdit(range: r, replacement: mark + ns.substring(with: r) + mark,
                            selection: NSRange(location: r.location + markLength, length: r.length))
    }

    // MARK: Lines

    /// Lines touched by the selection (a selection ending at a line start leaves that line out).
    static func selectedLines(_ text: String, _ selection: NSRange) -> [MarkdownLine] {
        let all = MarkdownParser.lines(text)
        var end = NSMaxRange(selection)
        if selection.length > 0, let last = MarkdownParser.line(at: end, in: all), last.range.location == end, end > selection.location {
            end -= 1
        }
        return all.filter { line in
            NSMaxRange(line.range) >= selection.location && line.range.location <= end
        }
    }

    /// Rewrites each line's prefix (indent + marker) with `prefix(line, index)`.
    private static func rewritePrefixes(_ text: String, _ selection: NSRange, _ lines: [MarkdownLine],
                                        _ prefix: (MarkdownLine, Int) -> String) -> MarkdownEdit? {
        guard let first = lines.first, let last = lines.last else { return nil }
        let ns = text as NSString
        let block = NSRange(location: first.range.location, length: NSMaxRange(last.range) - first.range.location)
        var out = ""
        var cursorShift = 0
        for (i, line) in lines.enumerated() {
            if i > 0 {
                let gap = NSRange(location: NSMaxRange(lines[i - 1].range), length: line.range.location - NSMaxRange(lines[i - 1].range))
                out += ns.substring(with: gap)
            }
            let oldPrefixLength = line.contentStart - line.range.location
            let newPrefix = prefix(line, i)
            if i == 0 { cursorShift = (newPrefix as NSString).length - oldPrefixLength }
            out += newPrefix + ns.substring(with: NSRange(location: line.contentStart, length: line.contentLength))
        }
        if lines.count == 1 && selection.length == 0 {
            let line = lines[0]
            let newContentStart = line.range.location + (prefix(line, 0) as NSString).length
            let loc = max(newContentStart, selection.location + cursorShift)
            return MarkdownEdit(range: block, replacement: out, selection: NSRange(location: loc, length: 0))
        }
        return MarkdownEdit(range: block, replacement: out, selection: NSRange(location: block.location, length: (out as NSString).length))
    }

    static func setHeading(_ level: Int, text: String, selection: NSRange) -> MarkdownEdit? {
        let lines = selectedLines(text, selection).filter { $0.kind != .code && $0.kind != .fence }
        let marker = level > 0 ? String(repeating: "#", count: min(level, 6)) + " " : ""
        return rewritePrefixes(text, selection, lines) { _, _ in marker }
    }

    static func toggleList(_ kind: MarkdownListKind, text: String, selection: NSRange) -> MarkdownEdit? {
        var lines = selectedLines(text, selection).filter { $0.kind != .code && $0.kind != .fence }
        if lines.count > 1 { lines = lines.filter { $0.contentLength > 0 || $0.marker != "" } }
        let allOn = !lines.isEmpty && lines.allSatisfy { if case .list(let k, _, _) = $0.kind { return k == kind } else { return false } }
        var number = 0
        return rewritePrefixes(text, selection, lines) { line, _ in
            if allOn { return line.indent }
            switch kind {
            case .bullet: return line.indent + "- "
            case .numbered: number += 1; return line.indent + "\(number). "
            case .checklist:
                if case .list(.checklist, let checked, _) = line.kind { return line.indent + (checked ? "- [x] " : "- [ ] ") }
                return line.indent + "- [ ] "
            }
        }
    }

    static func toggleQuote(text: String, selection: NSRange) -> MarkdownEdit? {
        let lines = selectedLines(text, selection).filter { $0.kind != .code && $0.kind != .fence }
        let allOn = !lines.isEmpty && lines.allSatisfy { $0.kind == .quote }
        return rewritePrefixes(text, selection, lines) { line, _ in allOn ? line.indent : line.indent + "> " }
    }

    static func toggleCodeBlock(text: String, selection: NSRange) -> MarkdownEdit? {
        let ns = text as NSString
        // Inside a block: remove its fences.
        if let block = MarkdownParser.spans(in: text).first(where: {
            $0.kind == .codeBlock && selection.location >= $0.full.location && NSMaxRange(selection) <= NSMaxRange($0.full)
        }) {
            let inner = block.content.length > 0 ? ns.substring(with: block.content) : ""
            let openLength = block.content.location - block.full.location
            let loc = max(block.full.location, min(selection.location - openLength, block.full.location + (inner as NSString).length))
            return MarkdownEdit(range: block.full, replacement: inner, selection: NSRange(location: loc, length: 0))
        }
        let lines = selectedLines(text, selection)
        guard let first = lines.first, let last = lines.last else { return nil }
        let block = NSRange(location: first.range.location, length: NSMaxRange(last.range) - first.range.location)
        let body = ns.substring(with: block)
        if body.isEmpty {
            return MarkdownEdit(range: block, replacement: "```\n\n```", selection: NSRange(location: block.location + 4, length: 0))
        }
        let replacement = "```\n" + body + "\n```"
        return MarkdownEdit(range: block, replacement: replacement,
                            selection: NSRange(location: block.location + 4 + (selection.location - block.location), length: selection.length))
    }

    /// Tab / ⇧Tab on list items: nil when no selected line is a list item (Tab then types a tab).
    static func indent(text: String, selection: NSRange, outdent: Bool) -> MarkdownEdit? {
        let lines = selectedLines(text, selection)
        guard lines.contains(where: { if case .list = $0.kind { return true } else { return false } }) else { return nil }
        if outdent && !lines.contains(where: { !$0.indent.isEmpty }) { return nil }
        return rewritePrefixes(text, selection, lines) { line, _ in
            guard case .list = line.kind else { return line.indent + line.marker }
            if !outdent { return "\t" + line.indent + line.marker }
            var indent = line.indent
            if indent.hasPrefix("\t") { indent.removeFirst() } else {
                var n = 0
                while n < 4, indent.hasPrefix(" ") { indent.removeFirst(); n += 1 }
            }
            return indent + line.marker
        }
    }

    // MARK: Links

    /// `[text](url)`: the selection becomes the text; with no selection the URL is the text (selected).
    static func link(url raw: String, text: String, selection: NSRange) -> MarkdownEdit {
        let url = normalizedURL(raw)
        let ns = text as NSString
        let label = selection.length > 0 ? ns.substring(with: selection) : url
        let replacement = "[\(label)](\(url))"
        return MarkdownEdit(range: selection, replacement: replacement,
                            selection: selection.length > 0
                                ? NSRange(location: selection.location + (replacement as NSString).length, length: 0)
                                : NSRange(location: selection.location + 1, length: (label as NSString).length))
    }

    /// `[[Note]]` for a picked page, replacing `replacing` (a typed `[[query]]`) or the selection.
    /// A selection that differs from the page becomes the alias: `[[Note|selection]]`.
    static func wikilink(_ page: PageRef, text: String, selection: NSRange, replacing: NSRange? = nil) -> MarkdownEdit {
        let ns = text as NSString
        var link = page.wikilink
        let range = replacing ?? selection
        if replacing == nil, selection.length > 0 {
            let label = ns.substring(with: selection)
            if label.caseInsensitiveCompare(page.linkTarget) != .orderedSame { link = "[[\(page.linkTarget)|\(label)]]" }
        }
        return MarkdownEdit(range: range, replacement: link,
                            selection: NSRange(location: range.location + (link as NSString).length, length: 0))
    }

    /// Looks like a URL rather than a note name ("example.com", "https://…", "mailto:…").
    static func looksLikeURL(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, !t.contains(" ") else { return false }
        if t.range(of: "^[a-zA-Z][a-zA-Z0-9+.-]*:", options: .regularExpression) != nil { return true }
        return t.range(of: "^[\\w-]+(\\.[\\w-]+)+(/|$)", options: .regularExpression) != nil
    }

    static func normalizedURL(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.range(of: "^[a-zA-Z][a-zA-Z0-9+.-]*:", options: .regularExpression) != nil { return t }
        return looksLikeURL(t) ? "https://" + t : t
    }

    // MARK: Return

    enum ReturnAction: Equatable {
        case edit(MarkdownEdit)            // continue or end a list, open a code block
        case submit(MarkdownEdit?)         // send (after the optional edit)
        case newline                       // the text view's own newline
    }

    /// Return (no Shift). `submitOnReturn`: Ask (Return sends); else notes (⌘Return sends).
    static func returnKey(text: String, selection: NSRange, submitOnReturn: Bool) -> ReturnAction {
        let fallback: ReturnAction = submitOnReturn ? .submit(nil) : .newline
        guard selection.length == 0 else { return fallback }
        let ns = text as NSString
        let all = MarkdownParser.lines(text)
        guard let index = all.firstIndex(where: { selection.location >= $0.range.location && selection.location <= NSMaxRange($0.range) }) else {
            return fallback
        }
        let line = all[index]
        let atEnd = selection.location == NSMaxRange(line.range)
        switch line.kind {
        case .code:
            return .newline
        case .fence:
            let opening = all[..<index].filter { $0.kind == .fence }.count % 2 == 0
            guard opening else { return fallback }
            let closed = all[(index + 1)...].contains { $0.kind == .fence }
            if closed { return .newline }
            guard atEnd else { return .newline }
            return .edit(MarkdownEdit(range: selection, replacement: "\n\n```", selection: NSRange(location: selection.location + 1, length: 0)))
        case .list(let kind, _, let number):
            if line.contentLength == 0 || ns.substring(with: NSRange(location: line.contentStart, length: line.contentLength))
                .trimmingCharacters(in: .whitespaces).isEmpty {
                // Empty item: a nested one moves out a level; a top-level one ends the list.
                if !line.indent.isEmpty, let e = indent(text: text, selection: selection, outdent: true) { return .edit(e) }
                let end = MarkdownEdit(range: line.range, replacement: "", selection: NSRange(location: line.range.location, length: 0))
                return submitOnReturn ? .submit(end) : .edit(end)
            }
            let marker: String
            switch kind {
            case .bullet: marker = line.marker
            case .numbered:
                let delimiter = line.marker.trimmingCharacters(in: .whitespaces).last.map(String.init) ?? "."
                marker = "\((number ?? 0) + 1)\(delimiter) "
            case .checklist:
                let bullet = line.marker.first.map(String.init) ?? "-"
                marker = "\(bullet) [ ] "
            }
            guard selection.location >= line.contentStart else { return fallback }
            let insert = "\n" + line.indent + marker
            return .edit(MarkdownEdit(range: selection, replacement: insert,
                                      selection: NSRange(location: selection.location + (insert as NSString).length, length: 0)))
        case .quote:
            if line.contentLength == 0 {
                let end = MarkdownEdit(range: line.range, replacement: "", selection: NSRange(location: line.range.location, length: 0))
                return submitOnReturn ? .submit(end) : .edit(end)
            }
            if submitOnReturn { return fallback }
            guard selection.location >= line.contentStart else { return fallback }
            let insert = "\n" + line.indent + "> "
            return .edit(MarkdownEdit(range: selection, replacement: insert,
                                      selection: NSRange(location: selection.location + (insert as NSString).length, length: 0)))
        case .heading, .plain:
            return fallback
        }
    }

    // MARK: Type-to-format

    struct TypedResult: Equatable {
        var edit: MarkdownEdit?
        /// `[[` was typed: open the note picker for the text after this location.
        var pickerAnchor: Int?
    }

    /// Called after `typed` was inserted and the cursor sits at `cursor`.
    static func afterTyping(_ typed: String, text: String, cursor: Int) -> TypedResult {
        let ns = text as NSString
        guard cursor <= ns.length else { return TypedResult() }
        if typed == " ", let line = MarkdownParser.line(at: cursor, in: MarkdownParser.lines(text)), line.kind == .plain {
            let before = ns.substring(with: NSRange(location: line.range.location, length: cursor - line.range.location))
            let trimmed = before.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
            if ["[ ]", "[]", "[x]", "[X]"].contains(trimmed), before.hasSuffix(trimmed + " ") {
                let at = line.range.location + (line.indent as NSString).length
                let box = trimmed == "[]" ? "[ ]" : trimmed
                let range = NSRange(location: at, length: (trimmed as NSString).length)
                let replacement = "- " + box
                return TypedResult(edit: MarkdownEdit(range: range, replacement: replacement,
                                                      selection: NSRange(location: cursor + (replacement as NSString).length - range.length, length: 0)))
            }
        }
        if typed == "[", cursor >= 2, ns.substring(with: NSRange(location: cursor - 2, length: 2)) == "[[" {
            let next = cursor < ns.length ? ns.substring(with: NSRange(location: cursor, length: 1)) : ""
            if next == "]" { return TypedResult(edit: nil, pickerAnchor: cursor) }
            return TypedResult(edit: MarkdownEdit(range: NSRange(location: cursor, length: 0), replacement: "]]",
                                                  selection: NSRange(location: cursor, length: 0)),
                               pickerAnchor: cursor)
        }
        return TypedResult()
    }

    /// The typed note query after a `[[` anchor up to the cursor, or nil once the link is left.
    static func pickerQuery(text: String, anchor: Int, cursor: Int) -> String? {
        let ns = text as NSString
        guard anchor >= 2, anchor <= cursor, cursor <= ns.length,
              ns.substring(with: NSRange(location: anchor - 2, length: 2)) == "[[" else { return nil }
        let q = ns.substring(with: NSRange(location: anchor, length: cursor - anchor))
        if q.contains("]") || q.contains("\n") || q.contains("[") { return nil }
        return q
    }

    /// The `[[query]]` range for an anchor (with the auto-closed `]]` when present).
    static func pickerRange(text: String, anchor: Int, cursor: Int) -> NSRange {
        let ns = text as NSString
        var end = cursor
        if end + 2 <= ns.length, ns.substring(with: NSRange(location: end, length: 2)) == "]]" { end += 2 }
        return NSRange(location: anchor - 2, length: end - (anchor - 2))
    }
}
