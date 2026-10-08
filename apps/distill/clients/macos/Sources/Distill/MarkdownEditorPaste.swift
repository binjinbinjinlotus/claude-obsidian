import AppKit

// Paste into a Markdown editor: rich text from a web page, Slack or a document
// (HTML or RTF on the pasteboard) becomes Markdown; plain or Markdown text is
// pasted as written. Images are not handled here (compose's image intake owns ⌘V
// for an image-only clipboard). UI-free, so it is unit tested.

enum MarkdownPaste {
    /// The text to insert for this pasteboard, or nil when it holds no text.
    static func text(from pb: NSPasteboard) -> String? {
        let plain = pb.string(forType: .string)
        if let plain, looksLikeMarkdown(plain) { return plain }
        if let html = pb.string(forType: .html) ?? pb.data(forType: .html).flatMap({ String(data: $0, encoding: .utf8) }),
           let md = htmlToMarkdown(html) {
            return md
        }
        if let rtf = pb.data(forType: .rtf), let a = NSAttributedString(rtf: rtf, documentAttributes: nil),
           let md = attributedToMarkdown(a) {
            return md
        }
        return plain
    }

    private static let blockMarkdownRE = try! NSRegularExpression(
        pattern: "^[ \\t]{0,3}(#{1,6}[ \\t]|[-*+][ \\t]|\\d{1,9}[.)][ \\t]|>|```|~~~)", options: [.anchorsMatchLines])
    private static let inlineMarkdownRE = try! NSRegularExpression(
        pattern: "\\*\\*[^*\\n]+\\*\\*|__[^_\\n]+__|~~[^~\\n]+~~|`[^`\\n]+`|\\[\\[[^\\]\\n]+\\]\\]|\\[[^\\]\\n]+\\]\\([^)\\s]+\\)")

    /// Text that already carries Markdown syntax (kept exactly as written).
    static func looksLikeMarkdown(_ s: String) -> Bool {
        let r = NSRange(location: 0, length: (s as NSString).length)
        return blockMarkdownRE.firstMatch(in: s, range: r) != nil || inlineMarkdownRE.firstMatch(in: s, range: r) != nil
    }

    // MARK: HTML

    /// Markdown for an HTML fragment, or nil when it has no formatting worth keeping
    /// (then the plain text is pasted instead, with its own line breaks).
    static func htmlToMarkdown(_ html: String) -> String? {
        let wrapped = html.range(of: "<html", options: .caseInsensitive) == nil ? "<html><body>\(html)</body></html>" : html
        guard let doc = try? XMLDocument(xmlString: wrapped, options: [.documentTidyHTML, .nodeLoadExternalEntitiesNever]),
              let root = doc.rootElement() else { return nil }
        let body = (try? root.nodes(forXPath: "//body").first) ?? root
        var w = HTMLWalker()
        let raw = w.render(body)
        guard w.styled else { return nil }
        return tidy(raw)
    }

    /// Collapse runs of blank lines, trim spaces at line ends and around the whole text.
    static func tidy(_ s: String) -> String {
        var lines = s.components(separatedBy: "\n").map { line -> String in
            var l = line
            while l.hasSuffix(" ") { l.removeLast() }
            return l
        }
        var out: [String] = []
        for l in lines where !(l.isEmpty && (out.last?.isEmpty ?? true)) { out.append(l) }
        while out.last?.isEmpty == true { out.removeLast() }
        lines = out
        return lines.joined(separator: "\n")
    }

    private struct HTMLWalker {
        var styled = false
        var inPre = false
        var lists: [(ordered: Bool, index: Int)] = []

        mutating func render(_ node: XMLNode) -> String {
            switch node.kind {
            case .text:
                let s = node.stringValue ?? ""
                if inPre { return s }
                return s.replacingOccurrences(of: "[\\s\\u00A0]+", with: " ", options: .regularExpression)
            case .element:
                return element(node as! XMLElement)
            default:
                return children(node)
            }
        }

        mutating func children(_ node: XMLNode) -> String {
            (node.children ?? []).map { render($0) }.joined()
        }

        mutating func element(_ e: XMLElement) -> String {
            let name = (e.name ?? "").lowercased()
            let style = (e.attribute(forName: "style")?.stringValue ?? "").lowercased().replacingOccurrences(of: " ", with: "")
            switch name {
            case "script", "style", "head", "title", "meta", "link", "img", "svg", "button", "noscript":
                return ""
            case "h1", "h2", "h3", "h4", "h5", "h6":
                styled = true
                let level = Int(String(name.last!))!
                return "\n\n" + String(repeating: "#", count: level) + " " + oneLine(children(e)) + "\n\n"
            case "p":
                return "\n\n" + children(e).trimmingCharacters(in: .whitespaces) + "\n\n"
            case "div", "section", "article", "header", "footer", "main", "figure", "figcaption", "tr":
                return "\n" + children(e) + "\n"
            case "td", "th":
                return children(e).trimmingCharacters(in: .whitespaces) + " "
            case "br":
                return "\n"
            case "hr":
                return "\n\n---\n\n"
            case "strong", "b":
                if style.contains("font-weight:normal") || style.contains("font-weight:400") { return styledSpan(e, style: style) }
                return wrap("**", children(e))
            case "em", "i", "cite":
                return wrap("*", children(e))
            case "s", "del", "strike":
                return wrap("~~", children(e))
            case "code", "kbd", "samp", "tt":
                if inPre { return children(e) }
                let inner = oneLine(children(e))
                guard !inner.isEmpty else { return "" }
                styled = true
                let fence = inner.contains("`") ? "``" : "`"
                return fence + inner + fence
            case "pre":
                styled = true
                inPre = true
                let inner = children(e)
                inPre = false
                var code = inner
                while code.hasSuffix("\n") { code.removeLast() }
                return "\n\n```\n" + code + "\n```\n\n"
            case "a":
                let inner = children(e)
                guard let href = e.attribute(forName: "href")?.stringValue, !href.isEmpty, !href.hasPrefix("#"),
                      !href.lowercased().hasPrefix("javascript:") else { return inner }
                let label = oneLine(inner)
                guard !label.isEmpty else { return "" }
                styled = true
                let lead = inner.hasPrefix(" ") ? " " : "", trail = inner.hasSuffix(" ") ? " " : ""
                return lead + "[\(label)](\(href.replacingOccurrences(of: " ", with: "%20")))" + trail
            case "ul", "ol":
                styled = true
                lists.append((name == "ol", 0))
                let inner = children(e)
                lists.removeLast()
                return (lists.isEmpty ? "\n\n" : "\n") + inner + (lists.isEmpty ? "\n\n" : "\n")
            case "li":
                guard !lists.isEmpty else { return "\n" + children(e) }
                lists[lists.count - 1].index += 1
                let list = lists[lists.count - 1]
                let indent = String(repeating: "\t", count: lists.count - 1)
                var marker = list.ordered ? "\(list.index). " : "- "
                if let box = (try? e.nodes(forXPath: "./input[@type='checkbox'] | ./p/input[@type='checkbox']"))?.first as? XMLElement {
                    marker = "- [\(box.attribute(forName: "checked") != nil ? "x" : " ")] "
                }
                let inner = children(e)
                    .replacingOccurrences(of: "\n\n", with: "\n")
                    .trimmingCharacters(in: CharacterSet(charactersIn: " \n"))
                return "\n" + indent + marker + inner
            case "input":
                return ""
            case "blockquote":
                styled = true
                let inner = MarkdownPaste.tidy(children(e).trimmingCharacters(in: .whitespacesAndNewlines))
                let quoted = inner.components(separatedBy: "\n").map { $0.isEmpty ? ">" : "> " + $0 }.joined(separator: "\n")
                return "\n\n" + quoted + "\n\n"
            case "span", "font", "u":
                return styledSpan(e, style: style)
            default:
                return children(e)
            }
        }

        /// Slack and Google Docs style text with CSS instead of tags.
        mutating func styledSpan(_ e: XMLElement, style: String) -> String {
            var inner = children(e)
            if style.contains("text-decoration:line-through") || style.contains("text-decoration-line:line-through") { inner = wrap("~~", inner) }
            if style.contains("font-style:italic") { inner = wrap("*", inner) }
            if let r = style.range(of: "font-weight:(bold|bolder|[6-9]00)", options: .regularExpression), !r.isEmpty { inner = wrap("**", inner) }
            return inner
        }

        /// Marks hug the text: " foo " → " **foo** ".
        mutating func wrap(_ mark: String, _ inner: String) -> String {
            let core = inner.trimmingCharacters(in: .whitespaces)
            guard !core.isEmpty, !core.contains("\n\n") else { return inner }
            styled = true
            let lead = inner.hasPrefix(" ") ? " " : "", trail = inner.hasSuffix(" ") ? " " : ""
            return lead + mark + core + mark + trail
        }

        func oneLine(_ s: String) -> String {
            s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        }
    }

    // MARK: RTF

    /// Markdown for rich text (bold, italic, strikethrough, links, bullets), or nil when it has none.
    static func attributedToMarkdown(_ a: NSAttributedString) -> String? {
        var styled = false
        var out = ""
        let full = NSRange(location: 0, length: a.length)
        a.enumerateAttributes(in: full) { attrs, range, _ in
            var s = (a.string as NSString).substring(with: range)
            guard !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { out += s; return }
            func wrap(_ mark: String) {
                // Per line, so marks never span a line break.
                s = s.components(separatedBy: "\n").map { part in
                    let core = part.trimmingCharacters(in: .whitespaces)
                    guard !core.isEmpty else { return part }
                    let lead = part.prefix { $0 == " " }, trail = String(part.reversed().prefix { $0 == " " })
                    return lead + mark + core + mark + trail
                }.joined(separator: "\n")
                styled = true
            }
            if let font = attrs[.font] as? NSFont {
                let traits = font.fontDescriptor.symbolicTraits
                if traits.contains(.bold) { wrap("**") }
                if traits.contains(.italic) { wrap("*") }
            }
            if let strike = attrs[.strikethroughStyle] as? Int, strike != 0 { wrap("~~") }
            if let link = attrs[.link] {
                let url = (link as? URL)?.absoluteString ?? (link as? String) ?? ""
                if !url.isEmpty {
                    s = "[\(s.trimmingCharacters(in: .whitespaces))](\(url))"
                    styled = true
                }
            }
            out += s
        }
        // Bullets from text lists ("\t•\tItem").
        let lines = out.components(separatedBy: "\n").map { line -> String in
            let t = line.trimmingCharacters(in: .whitespaces)
            for bullet in ["•", "◦", "▪", "–"] where t.hasPrefix(bullet) {
                styled = true
                return "- " + t.dropFirst(bullet.count).trimmingCharacters(in: .whitespaces)
            }
            return line
        }
        guard styled else { return nil }
        return tidy(lines.joined(separator: "\n"))
    }
}
