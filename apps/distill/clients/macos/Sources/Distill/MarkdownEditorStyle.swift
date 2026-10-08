import AppKit
import SwiftUI

// Live Preview styling for the Markdown editor: the text stays Markdown, the
// marks are faded, the content is styled. One styled NSAttributedString feeds
// both the NSTextView (app) and the SwiftUI rendering (`--snapshot`).

enum MarkdownTheme {
    static let text = NSColor(hex: 0x2A2925)
    static let mark = NSColor(hex: 0xB5B1A9)
    static let muted = NSColor(hex: 0x6B6862)
    static let faint = NSColor(hex: 0x9B978F)
    static let placeholder = NSColor(hex: 0x9B978F)
    static let link = NSColor(hex: 0x1F6FEB)
    static let codeFill = NSColor(hex: 0xF6F5F2)
    static let quoteBar = NSColor(hex: 0xE1DED8)
    static let selection = NSColor(hex: 0xCFE0FF)
    /// Text just extracted from an image.
    static let extractedFill = NSColor(hex: 0xF3FDE4)

    /// Line height ≈ 1.6 × the font size (13 → 21, as in the design).
    static func lineSpacing(_ size: CGFloat) -> CGFloat { round(size * 0.42) }

    static func font(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        .systemFont(ofSize: size, weight: weight)
    }

    static func headingFont(_ level: Int, base: CGFloat) -> NSFont {
        let scale: CGFloat = [1: 1.45, 2: 1.3, 3: 1.15][level] ?? 1.05
        let f = NSFont.systemFont(ofSize: round(base * scale), weight: .bold)
        return f.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: f.pointSize) } ?? f
    }

    static func code(_ size: CGFloat) -> NSFont { .monospacedSystemFont(ofSize: size - 1, weight: .regular) }
}

extension NSAttributedString.Key {
    /// Marks a quote line: the text view draws a bar at its left edge.
    static let markdownQuote = NSAttributedString.Key("distill.markdownQuote")
    /// Marks a fenced code block line: drawn on a full-width tinted band.
    static let markdownCodeBlock = NSAttributedString.Key("distill.markdownCodeBlock")
}

enum MarkdownStyler {
    static func baseAttributes(size: CGFloat) -> [NSAttributedString.Key: Any] {
        [.font: MarkdownTheme.font(size), .foregroundColor: MarkdownTheme.text, .paragraphStyle: paragraph(size)]
    }

    static func paragraph(_ size: CGFloat, indent: CGFloat = 0, headIndent: CGFloat? = nil) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = MarkdownTheme.lineSpacing(size)
        p.paragraphSpacing = 2
        p.firstLineHeadIndent = indent
        p.headIndent = headIndent ?? indent
        p.defaultTabInterval = 24
        p.tabStops = []
        return p
    }

    /// Every (range, attributes) to apply over the base attributes, in order.
    static func runs(for text: String, size: CGFloat) -> [(NSRange, [NSAttributedString.Key: Any])] {
        let ns = text as NSString
        var out: [(NSRange, [NSAttributedString.Key: Any])] = []
        let base = MarkdownTheme.font(size)

        // Hanging indents: wrapped list lines line up with the item's text.
        for line in MarkdownParser.lines(text) {
            switch line.kind {
            case .list:
                let prefix = ns.substring(with: NSRange(location: line.range.location, length: line.contentStart - line.range.location))
                let width = (prefix as NSString).size(withAttributes: [.font: base, .paragraphStyle: paragraph(size)]).width
                out.append((line.range, [.paragraphStyle: paragraph(size, headIndent: ceil(width))]))
            case .quote:
                out.append((line.range, [.paragraphStyle: paragraph(size, indent: 11), .markdownQuote: true]))
            default: break
            }
        }

        for span in MarkdownParser.spans(in: text) {
            switch span.kind {
            case .heading(let level):
                let font = MarkdownTheme.headingFont(level, base: size)
                let p = NSMutableParagraphStyle()
                p.lineSpacing = MarkdownTheme.lineSpacing(size) * 0.6
                p.paragraphSpacing = 4
                p.paragraphSpacingBefore = 2
                out.append((span.full, [.font: font, .paragraphStyle: p]))
            case .quote:
                out.append((span.content, [.foregroundColor: MarkdownTheme.muted]))
            case .listItem:
                break
            case .checkedItem:
                out.append((span.content, [.foregroundColor: MarkdownTheme.faint, .strikethroughStyle: NSUnderlineStyle.single.rawValue]))
            case .codeBlock:
                out.append((span.full, [.font: MarkdownTheme.code(size), .markdownCodeBlock: true, .foregroundColor: MarkdownTheme.text]))
            case .bold:
                out.append((span.content, [.markdownTrait: NSFontTraitMask.boldFontMask.rawValue]))
            case .italic:
                out.append((span.content, [.markdownTrait: NSFontTraitMask.italicFontMask.rawValue]))
            case .strike:
                out.append((span.content, [.strikethroughStyle: NSUnderlineStyle.single.rawValue]))
            case .code:
                out.append((span.full, [.font: MarkdownTheme.code(size), .backgroundColor: MarkdownTheme.codeFill]))
            case .link:
                out.append((span.content, [.foregroundColor: MarkdownTheme.link, .underlineStyle: NSUnderlineStyle.single.rawValue]))
            case .wikilink:
                out.append((span.content, [.foregroundColor: MarkdownTheme.link, .markdownTrait: NSFontTraitMask.boldFontMask.rawValue,
                                           .markdownWeight: NSFont.Weight.semibold.rawValue]))
            }
            // Marks: faded (and never struck through or underlined). Code block fences and heading marks keep their font.
            for m in span.marks where m.length > 0 {
                var attrs: [NSAttributedString.Key: Any] = [.foregroundColor: MarkdownTheme.mark]
                switch span.kind {
                case .bold, .italic, .strike, .link, .wikilink, .code:
                    attrs[.strikethroughStyle] = 0
                    attrs[.underlineStyle] = 0
                    attrs[.markdownTrait] = 0
                    if span.kind == .code { attrs[.backgroundColor] = NSColor.clear }
                default: break
                }
                out.append((m, attrs))
            }
        }
        return out
    }

    /// Restyle `storage` (whose string is the Markdown) in place.
    static func apply(to storage: NSTextStorage, size: CGFloat) {
        let full = NSRange(location: 0, length: storage.length)
        // Images inside the text are attachments: styling must not drop them.
        var attachments: [(NSRange, Any)] = []
        storage.enumerateAttribute(.attachment, in: full) { value, range, _ in
            if let value { attachments.append((range, value)) }
        }
        storage.beginEditing()
        storage.setAttributes(baseAttributes(size: size), range: full)
        for (range, value) in attachments { storage.addAttribute(.attachment, value: value, range: range) }
        for (range, attrs) in runs(for: storage.string, size: size) where NSMaxRange(range) <= storage.length {
            var plain = attrs
            plain[.markdownTrait] = nil
            plain[.markdownWeight] = nil
            storage.addAttributes(plain, range: range)
            if let raw = attrs[.markdownTrait] as? UInt {
                if raw == 0 {
                    // A mark inside bold/italic: plain weight.
                    storage.enumerateAttribute(.font, in: range) { value, r, _ in
                        guard let f = value as? NSFont else { return }
                        storage.addAttribute(.font, value: NSFontManager.shared.convert(f, toNotHaveTrait: [.boldFontMask, .italicFontMask]), range: r)
                    }
                } else {
                    let weight = (attrs[.markdownWeight] as? CGFloat).map { NSFont.Weight($0) }
                    storage.enumerateAttribute(.font, in: range) { value, r, _ in
                        guard let f = value as? NSFont else { return }
                        storage.addAttribute(.font, value: convert(f, trait: NSFontTraitMask(rawValue: raw), weight: weight), range: r)
                    }
                }
            }
        }
        storage.endEditing()
    }

    static func convert(_ font: NSFont, trait: NSFontTraitMask, weight: NSFont.Weight?) -> NSFont {
        if trait.contains(.boldFontMask), let weight {
            let d = font.fontDescriptor.addingAttributes([.traits: [NSFontDescriptor.TraitKey.weight: weight]])
            return NSFont(descriptor: d, size: font.pointSize) ?? font
        }
        if trait.contains(.italicFontMask) {
            let d = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(.italic))
            return NSFont(descriptor: d, size: font.pointSize) ?? NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        }
        let bold = NSFontManager.shared.convert(font, toHaveTrait: trait)
        if bold.fontDescriptor.symbolicTraits.contains(.bold) { return bold }
        let d = font.fontDescriptor.addingAttributes([.traits: [NSFontDescriptor.TraitKey.weight: NSFont.Weight.bold]])
        return NSFont(descriptor: d, size: font.pointSize) ?? font
    }

    /// The styled text (for snapshots and tests).
    static func styled(_ text: String, size: CGFloat) -> NSAttributedString {
        let storage = NSTextStorage(string: text)
        apply(to: storage, size: size)
        return storage
    }
}

extension NSAttributedString.Key {
    /// Internal: a font trait to add over whatever font the range has (0 = remove bold/italic).
    static let markdownTrait = NSAttributedString.Key("distill.markdownTrait")
    static let markdownWeight = NSAttributedString.Key("distill.markdownWeight")
}

// MARK: - SwiftUI rendering (snapshots)

/// The editor's styled text drawn with SwiftUI, line by line (quote bars, code bands).
/// `--snapshot` uses it because ImageRenderer cannot draw an NSTextView.
struct MarkdownStyledText: View {
    let text: String
    let size: CGFloat
    var placeholder = ""
    /// Highlight (UTF-16 range) drawn like a selection.
    var highlight: NSRange? = nil

    var body: some View {
        if text.isEmpty {
            Text(placeholder).font(.system(size: size)).foregroundStyle(Color(nsColor: MarkdownTheme.placeholder))
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            let styled = MarkdownStyler.styled(text, size: size)
            let lines = MarkdownParser.lines(text)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    lineView(styled, line)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private func lineView(_ styled: NSAttributedString, _ line: MarkdownLine) -> some View {
        let sub = line.range.length > 0 ? styled.attributedSubstring(from: line.range) : NSAttributedString(string: " ", attributes: MarkdownStyler.baseAttributes(size: size))
        let isQuote = line.kind == .quote
        let isCode = line.kind == .code || line.kind == .fence
        Text(Self.attributed(sub, highlight: highlight.map { NSRange(location: $0.location - line.range.location, length: $0.length) }))
            .lineSpacing(MarkdownTheme.lineSpacing(size))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, isQuote ? 11 : 0)
            .padding(.vertical, isCode ? 1 : 1.5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(alignment: .leading) {
                if isQuote { Rectangle().fill(Color(nsColor: MarkdownTheme.quoteBar)).frame(width: 3) }
                if isCode { Rectangle().fill(Color(nsColor: MarkdownTheme.codeFill)) }
            }
    }

    static func attributed(_ source: NSAttributedString, highlight: NSRange? = nil) -> AttributedString {
        let ns = NSMutableAttributedString(attributedString: source)
        if let h = highlight {
            let clamped = NSIntersectionRange(h, NSRange(location: 0, length: ns.length))
            if clamped.length > 0 { ns.addAttribute(.backgroundColor, value: MarkdownTheme.selection, range: clamped) }
        }
        var out = AttributedString()
        ns.enumerateAttributes(in: NSRange(location: 0, length: ns.length)) { attrs, range, _ in
            var run = AttributedString((ns.string as NSString).substring(with: range))
            if let f = attrs[.font] as? NSFont { run.font = Font(f as CTFont) }
            if let c = attrs[.foregroundColor] as? NSColor { run.foregroundColor = Color(nsColor: c) }
            if let c = attrs[.backgroundColor] as? NSColor, c != .clear { run.backgroundColor = Color(nsColor: c) }
            if let s = attrs[.strikethroughStyle] as? Int, s != 0 { run.strikethroughStyle = .single }
            if let u = attrs[.underlineStyle] as? Int, u != 0 { run.underlineStyle = .single }
            out += run
        }
        return out
    }
}
