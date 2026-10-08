import Foundation

// The Markdown editor keeps text as plain Markdown, exactly as typed. This
// parser finds what to style (Live Preview): the styled span, and inside it the
// content, so everything else in the span is a faded mark. All ranges are
// UTF-16 (NSString / NSTextView) ranges. UI-free, so it is unit tested.

enum MarkdownListKind: Equatable {
    case bullet, numbered, checklist
}

enum MarkdownSpanKind: Equatable {
    case heading(Int)          // full = whole line, content = text after "## "
    case quote                 // full = whole line, content = text after "> "
    case listItem(MarkdownListKind)   // full = whole line, content = text after the marker
    case checkedItem           // content of a "- [x]" item (struck through, faded)
    case codeBlock             // a fenced block, fences included; content = lines between
    case bold, italic, strike, code
    case link                  // [text](url): content = text
    case wikilink              // [[Note]]: content = Note
}

struct MarkdownSpan: Equatable {
    var kind: MarkdownSpanKind
    var full: NSRange
    var content: NSRange

    /// The marks: parts of `full` outside `content` (faded in the editor).
    var marks: [NSRange] {
        guard content.location != NSNotFound else { return [full] }
        var out: [NSRange] = []
        if content.location > full.location { out.append(NSRange(location: full.location, length: content.location - full.location)) }
        let end = NSMaxRange(full), cEnd = NSMaxRange(content)
        if end > cEnd { out.append(NSRange(location: cEnd, length: end - cEnd)) }
        return out
    }
}

/// One line of the text, with what kind of block it starts.
struct MarkdownLine: Equatable {
    var range: NSRange          // without the line break
    var indent: String          // leading spaces/tabs
    var marker: String          // "- ", "1. ", "- [ ] ", "> ", "## " ("" for none), after the indent
    var kind: Kind

    enum Kind: Equatable {
        case plain, heading(Int), quote, list(MarkdownListKind, checked: Bool, number: Int?), fence, code
    }

    var contentStart: Int { range.location + (indent as NSString).length + (marker as NSString).length }
    var contentLength: Int { NSMaxRange(range) - contentStart }
}

enum MarkdownParser {
    // MARK: Lines

    /// Every line of `text` with its block kind (fenced code tracked across lines).
    static func lines(_ text: String) -> [MarkdownLine] {
        let ns = text as NSString
        var out: [MarkdownLine] = []
        var inFence = false
        var start = 0
        func add(_ range: NSRange) {
            var parsed = classify(ns.substring(with: range), range: range)
            if parsed.kind == .fence {
                inFence.toggle()
            } else if inFence {
                parsed = MarkdownLine(range: range, indent: "", marker: "", kind: .code)
            }
            out.append(parsed)
        }
        for i in 0..<ns.length where ns.character(at: i) == 0x0A {
            // "\r\n": the \r is not part of the line.
            let end = i > start && ns.character(at: i - 1) == 0x0D ? i - 1 : i
            add(NSRange(location: start, length: end - start))
            start = i + 1
        }
        add(NSRange(location: start, length: ns.length - start))
        return out
    }

    /// The line containing UTF-16 offset `location` (a cursor at the very end belongs to the last line).
    static func line(at location: Int, in lines: [MarkdownLine]) -> MarkdownLine? {
        lines.first { location >= $0.range.location && location <= NSMaxRange($0.range) } ?? lines.last
    }

    private static let headingRE = try! NSRegularExpression(pattern: "^(#{1,6})[ \\t]")
    private static let quoteRE = try! NSRegularExpression(pattern: "^>[ \\t]?")
    private static let listRE = try! NSRegularExpression(pattern: "^(?:([-*+])|(\\d{1,9})[.)])[ \\t](\\[([ xX])\\][ \\t])?")
    private static let fenceRE = try! NSRegularExpression(pattern: "^\\s{0,3}(```|~~~)")

    static func classify(_ line: String, range: NSRange) -> MarkdownLine {
        let ns = line as NSString
        let full = NSRange(location: 0, length: ns.length)
        if fenceRE.firstMatch(in: line, range: full) != nil {
            return MarkdownLine(range: range, indent: "", marker: "", kind: .fence)
        }
        var indentLength = 0
        while indentLength < ns.length, [0x20, 0x09].contains(ns.character(at: indentLength)) { indentLength += 1 }
        let indent = ns.substring(to: indentLength)
        let rest = ns.substring(from: indentLength)
        let restRange = NSRange(location: 0, length: (rest as NSString).length)
        if indentLength == 0, let m = headingRE.firstMatch(in: rest, range: restRange) {
            return MarkdownLine(range: range, indent: "", marker: (rest as NSString).substring(with: m.range),
                                kind: .heading(m.range(at: 1).length))
        }
        if let m = quoteRE.firstMatch(in: rest, range: restRange) {
            return MarkdownLine(range: range, indent: indent, marker: (rest as NSString).substring(with: m.range), kind: .quote)
        }
        if let m = listRE.firstMatch(in: rest, range: restRange) {
            let marker = (rest as NSString).substring(with: m.range)
            let number = m.range(at: 2).location != NSNotFound ? Int((rest as NSString).substring(with: m.range(at: 2))) : nil
            if m.range(at: 3).location != NSNotFound {
                let box = (rest as NSString).substring(with: m.range(at: 4))
                return MarkdownLine(range: range, indent: indent, marker: marker,
                                    kind: .list(.checklist, checked: box != " ", number: number))
            }
            return MarkdownLine(range: range, indent: indent, marker: marker,
                                kind: .list(number == nil ? .bullet : .numbered, checked: false, number: number))
        }
        return MarkdownLine(range: range, indent: indent, marker: "", kind: .plain)
    }

    // MARK: Spans

    /// Everything to style in `text`: block spans, then inline spans, in text order per line.
    static func spans(in text: String) -> [MarkdownSpan] {
        let ns = text as NSString
        let all = lines(text)
        var out: [MarkdownSpan] = []
        var fenceStart: Int?
        var fenceContentStart = 0
        for (i, line) in all.enumerated() {
            switch line.kind {
            case .fence:
                if let start = fenceStart {
                    let full = NSRange(location: start, length: NSMaxRange(line.range) - start)
                    let content = NSRange(location: fenceContentStart, length: max(0, line.range.location - 1 - fenceContentStart))
                    out.append(MarkdownSpan(kind: .codeBlock, full: full, content: content))
                    fenceStart = nil
                } else {
                    fenceStart = line.range.location
                    fenceContentStart = min(ns.length, NSMaxRange(line.range) + 1)
                    // An unclosed fence runs to the end of the text.
                    if !all[(i + 1)...].contains(where: { $0.kind == .fence }) {
                        let full = NSRange(location: line.range.location, length: ns.length - line.range.location)
                        let content = NSRange(location: fenceContentStart, length: max(0, ns.length - fenceContentStart))
                        out.append(MarkdownSpan(kind: .codeBlock, full: full, content: content))
                        fenceStart = nil
                        return out
                    }
                }
                continue
            case .code:
                continue
            case .heading(let level):
                out.append(MarkdownSpan(kind: .heading(level), full: line.range,
                                        content: NSRange(location: line.contentStart, length: line.contentLength)))
            case .quote:
                out.append(MarkdownSpan(kind: .quote, full: line.range,
                                        content: NSRange(location: line.contentStart, length: line.contentLength)))
            case .list(let kind, let checked, _):
                let content = NSRange(location: line.contentStart, length: line.contentLength)
                out.append(MarkdownSpan(kind: .listItem(kind), full: line.range, content: content))
                if checked { out.append(MarkdownSpan(kind: .checkedItem, full: content, content: content)) }
            case .plain:
                break
            }
            let content = NSRange(location: line.contentStart, length: line.contentLength)
            if content.length > 0 { out += inlineSpans(ns, in: content) }
        }
        return out
    }

    private static let codeRE = try! NSRegularExpression(pattern: "(`+)(?!`)(.+?)(?<!`)\\1(?!`)")
    private static let wikiRE = try! NSRegularExpression(pattern: "\\[\\[([^\\[\\]\\n]+?)\\]\\]")
    private static let linkRE = try! NSRegularExpression(pattern: "\\[([^\\[\\]\\n]+)\\]\\(([^()\\s]*(?:\\([^()\\s]*\\)[^()\\s]*)*)\\)")
    private static let boldRE = try! NSRegularExpression(pattern: "(\\*\\*|__)(?=\\S)(.+?)(?<=\\S)\\1")
    private static let strikeRE = try! NSRegularExpression(pattern: "~~(?=\\S)(.+?)(?<=\\S)~~")
    private static let italicStarRE = try! NSRegularExpression(pattern: "(?<![*\\\\])\\*(?=[^\\s*])(.+?)(?<=[^\\s*])\\*(?!\\*)")
    private static let italicUnderRE = try! NSRegularExpression(pattern: "(?<![\\w_])_(?=[^\\s_])(.+?)(?<=[^\\s_])_(?![\\w_])")

    /// Inline spans inside `range` of `ns`. Code and links are matched first and
    /// nothing else is styled inside code or inside a URL.
    static func inlineSpans(_ ns: NSString, in range: NSRange) -> [MarkdownSpan] {
        let text = ns as String
        var out: [MarkdownSpan] = []
        var protected: [NSRange] = []   // code spans and link URLs
        func free(_ r: NSRange) -> Bool { !protected.contains { NSIntersectionRange($0, r).length > 0 } }

        for m in codeRE.matches(in: text, range: range) {
            out.append(MarkdownSpan(kind: .code, full: m.range, content: m.range(at: 2)))
            protected.append(m.range)
        }
        for m in wikiRE.matches(in: text, range: range) where free(m.range) {
            out.append(MarkdownSpan(kind: .wikilink, full: m.range, content: m.range(at: 1)))
            protected.append(m.range)
        }
        for m in linkRE.matches(in: text, range: range) where free(m.range) {
            out.append(MarkdownSpan(kind: .link, full: m.range, content: m.range(at: 1)))
            // The URL part is protected; the text may hold bold or italic.
            protected.append(NSRange(location: NSMaxRange(m.range(at: 1)), length: NSMaxRange(m.range) - NSMaxRange(m.range(at: 1))))
        }
        var emphasis: [NSRange] = []
        for (re, kind) in [(boldRE, MarkdownSpanKind.bold), (strikeRE, .strike)] {
            for m in re.matches(in: text, range: range) where free(m.range) {
                let content = m.range(at: m.numberOfRanges - 1)
                out.append(MarkdownSpan(kind: kind, full: m.range, content: content))
                emphasis.append(m.range)
            }
        }
        // Italic must not take a bold's marks: "**x**" is bold, "***x***" is both.
        let boldMarks = out.filter { $0.kind == .bold }.flatMap(\.marks)
        for re in [italicStarRE, italicUnderRE] {
            for m in re.matches(in: text, range: range) where free(m.range) {
                let open = NSRange(location: m.range.location, length: 1)
                let close = NSRange(location: NSMaxRange(m.range) - 1, length: 1)
                if boldMarks.contains(where: { NSIntersectionRange($0, open).length > 0 || NSIntersectionRange($0, close).length > 0 }) { continue }
                out.append(MarkdownSpan(kind: .italic, full: m.range, content: m.range(at: 1)))
            }
        }
        return out
    }

    // MARK: Style at a location

    /// What the bar lights up for the cursor or selection.
    struct ActiveStyles: Equatable {
        var bold = false, italic = false, strike = false, code = false, link = false, wikilink = false
        var heading = 0
        var list: MarkdownListKind?
        var quote = false, codeBlock = false
    }

    static func activeStyles(in text: String, selection: NSRange) -> ActiveStyles {
        var a = ActiveStyles()
        let loc = selection.location
        func covers(_ r: NSRange) -> Bool {
            if selection.length == 0 { return loc >= r.location && loc <= NSMaxRange(r) }
            return NSIntersectionRange(r, selection).length == selection.length
        }
        func coversInline(_ s: MarkdownSpan) -> Bool {
            // A cursor anywhere from the opening mark's end to the closing mark's start counts.
            if selection.length == 0 { return loc >= s.content.location && loc <= NSMaxRange(s.content) }
            return NSIntersectionRange(s.full, selection).length == selection.length
        }
        for s in spans(in: text) {
            switch s.kind {
            case .bold: if coversInline(s) { a.bold = true }
            case .italic: if coversInline(s) { a.italic = true }
            case .strike: if coversInline(s) { a.strike = true }
            case .code: if coversInline(s) { a.code = true }
            case .link: if coversInline(s) { a.link = true }
            case .wikilink: if coversInline(s) { a.wikilink = true }
            case .codeBlock: if covers(s.full) { a.codeBlock = true }
            case .heading, .quote, .listItem, .checkedItem: break
            }
        }
        if let line = line(at: loc, in: lines(text)) {
            switch line.kind {
            case .heading(let level): a.heading = level
            case .quote: a.quote = true
            case .list(let kind, _, _): a.list = kind
            default: break
            }
        }
        return a
    }
}
