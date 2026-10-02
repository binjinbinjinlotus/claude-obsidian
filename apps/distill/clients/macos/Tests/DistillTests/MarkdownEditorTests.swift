import AppKit
import XCTest
import DistillKit
@testable import Distill

/// Helpers: "|" marks the cursor, "«…»" a selection, in test strings.
private func split(_ marked: String) -> (String, NSRange) {
    var s = marked
    if let a = s.range(of: "«"), let b = s.range(of: "»") {
        let start = (String(s[..<a.lowerBound]) as NSString).length
        let inner = (String(s[a.upperBound..<b.lowerBound]) as NSString).length
        s.removeSubrange(b)
        s.removeSubrange(a)
        return (s, NSRange(location: start, length: inner))
    }
    let r = s.range(of: "|")!
    let at = (String(s[..<r.lowerBound]) as NSString).length
    s.removeSubrange(r)
    return (s, NSRange(location: at, length: 0))
}

private func mark(_ text: String, _ sel: NSRange) -> String {
    let ns = text as NSString
    if sel.length == 0 { return ns.replacingCharacters(in: sel, with: "|") }
    return ns.substring(to: sel.location) + "«" + ns.substring(with: sel) + "»" + ns.substring(from: NSMaxRange(sel))
}

private func runCommand(_ command: MarkdownCommand, _ marked: String) -> String? {
    let (text, sel) = split(marked)
    guard let e = MarkdownCommands.edit(command, text: text, selection: sel) else { return nil }
    let (out, outSel) = e.applied(to: text)
    return mark(out, outSel)
}

final class MarkdownParserTests: XCTestCase {
    private func spans(_ text: String, _ kind: MarkdownSpanKind) -> [String] {
        let ns = text as NSString
        return MarkdownParser.spans(in: text).filter { $0.kind == kind }.map { ns.substring(with: $0.content) }
    }

    private func marks(_ text: String, _ kind: MarkdownSpanKind) -> [String] {
        let ns = text as NSString
        return MarkdownParser.spans(in: text).filter { $0.kind == kind }.flatMap(\.marks).map { ns.substring(with: $0) }
    }

    func testInlineStyles() {
        let t = "Use **60 °C** for *gyokuro* and ~~never~~ `30 s` boiling"
        XCTAssertEqual(spans(t, .bold), ["60 °C"])
        XCTAssertEqual(marks(t, .bold), ["**", "**"])
        XCTAssertEqual(spans(t, .italic), ["gyokuro"])
        XCTAssertEqual(spans(t, .strike), ["never"])
        XCTAssertEqual(spans(t, .code), ["30 s"])
        XCTAssertEqual(spans("a __b__ _c_ snake_case_word", .bold), ["b"])
        XCTAssertEqual(spans("a __b__ _c_ snake_case_word", .italic), ["c"])
        XCTAssertEqual(spans("2 * 3 * 4", .italic), [], "spaces after * are not emphasis")
    }

    func testNothingStyledInsideCode() {
        let t = "`**not bold**` and **bold**"
        XCTAssertEqual(spans(t, .bold), ["bold"])
        XCTAssertEqual(spans("```\n**x**\n# no\n```\n**y**", .bold), ["y"])
        XCTAssertEqual(spans("```\n**x**\n# no\n```\n**y**", .heading(1)), [])
    }

    func testLinksAndWikilinks() {
        let t = "See [[Sencha basics]] and [the shop](https://ex.com/a_b_c) or [[Kyoto|shops]]"
        XCTAssertEqual(spans(t, .wikilink), ["Sencha basics", "Kyoto|shops"])
        XCTAssertEqual(spans(t, .link), ["the shop"])
        XCTAssertEqual(marks(t, .link), ["[", "](https://ex.com/a_b_c)"])
        XCTAssertEqual(spans(t, .italic), [], "underscores inside a URL are not italic")
    }

    func testBlocks() {
        let t = "## Brewing\n- First\n1. One\n- [x] Done\n- [ ] Todo\n> quote\n\tnot code"
        XCTAssertEqual(spans(t, .heading(2)), ["Brewing"])
        XCTAssertEqual(marks(t, .heading(2)), ["## "])
        XCTAssertEqual(spans(t, .listItem(.bullet)), ["First"])
        XCTAssertEqual(spans(t, .listItem(.numbered)), ["One"])
        XCTAssertEqual(spans(t, .listItem(.checklist)), ["Done", "Todo"])
        XCTAssertEqual(marks(t, .listItem(.checklist)), ["- [x] ", "- [ ] "])
        XCTAssertEqual(spans(t, .checkedItem), ["Done"])
        XCTAssertEqual(spans(t, .quote), ["quote"])
        XCTAssertEqual(spans("#nope\n####### seven", .heading(1)), [])
    }

    func testCodeBlockSpanIncludesFences() {
        let t = "a\n```swift\nlet x = 1\n```\nb"
        let block = MarkdownParser.spans(in: t).first { $0.kind == .codeBlock }!
        XCTAssertEqual((t as NSString).substring(with: block.full), "```swift\nlet x = 1\n```")
        XCTAssertEqual((t as NSString).substring(with: block.content), "let x = 1")
        let open = "```\nunclosed"
        let b2 = MarkdownParser.spans(in: open).first { $0.kind == .codeBlock }!
        XCTAssertEqual(NSMaxRange(b2.full), (open as NSString).length)
    }

    func testUTF16RangesWithEmoji() {
        let t = "🍵 **tea** 🫖 *pot*"
        XCTAssertEqual(spans(t, .bold), ["tea"])
        XCTAssertEqual(spans(t, .italic), ["pot"])
        let bold = MarkdownParser.spans(in: t).first { $0.kind == .bold }!
        XCTAssertEqual(bold.full.location, 3, "🍵 is two UTF-16 units")
    }

    func testActiveStylesAtCursor() {
        let (t, sel) = split("Use **60| °C** and")
        let a = MarkdownParser.activeStyles(in: t, selection: sel)
        XCTAssertTrue(a.bold)
        XCTAssertFalse(a.italic)
        let (h, hs) = split("## Bre|wing\n- item")
        XCTAssertEqual(MarkdownParser.activeStyles(in: h, selection: hs).heading, 2)
        let (l, ls) = split("## Brewing\n- it|em")
        XCTAssertEqual(MarkdownParser.activeStyles(in: l, selection: ls).list, .bullet)
        XCTAssertEqual(MarkdownParser.activeStyles(in: l, selection: ls).heading, 0)
    }
}

final class MarkdownCommandTests: XCTestCase {
    func testWrapAndUnwrapBold() {
        XCTAssertEqual(runCommand(.bold, "Use «60 °C» for"), "Use **«60 °C»** for")
        XCTAssertEqual(runCommand(.bold, "Use **«60 °C»** for"), "Use «60 °C» for")
        XCTAssertEqual(runCommand(.bold, "Use **60| °C** for"), "Use 60| °C for")
        XCTAssertEqual(runCommand(.bold, "a «word »b"), "a **«word»** b", "outer spaces stay outside the marks")
        XCTAssertEqual(runCommand(.bold, "a | b"), "a **|** b")
        XCTAssertEqual(runCommand(.italic, "«x»"), "*«x»*")
        XCTAssertEqual(runCommand(.italic, "**bold *«it»* bold**"), "**bold «it» bold**")
        XCTAssertEqual(runCommand(.strike, "«gone»"), "~~«gone»~~")
        XCTAssertEqual(runCommand(.code, "run «npm test»"), "run `«npm test»`")
    }

    func testHeadingLevels() {
        XCTAssertEqual(runCommand(.heading(2), "Bre|wing"), "## Bre|wing")
        XCTAssertEqual(runCommand(.heading(1), "## Bre|wing"), "# Bre|wing")
        XCTAssertEqual(runCommand(.heading(0), "### Bre|wing"), "Bre|wing")
        XCTAssertEqual(runCommand(.heading(3), "- ite|m"), "### ite|m")
        XCTAssertEqual(runCommand(.heading(1), "|"), "# |")
    }

    func testListToggling() {
        XCTAssertEqual(runCommand(.list(.bullet), "ite|m"), "- ite|m")
        XCTAssertEqual(runCommand(.list(.bullet), "- ite|m"), "ite|m")
        XCTAssertEqual(runCommand(.list(.numbered), "«a\nb\nc»"), "«1. a\n2. b\n3. c»")
        XCTAssertEqual(runCommand(.list(.bullet), "«1. a\n2. b»"), "«- a\n- b»")
        XCTAssertEqual(runCommand(.list(.checklist), "- ite|m"), "- [ ] ite|m")
        XCTAssertEqual(runCommand(.list(.checklist), "- [x] ite|m"), "ite|m")
        XCTAssertEqual(runCommand(.list(.bullet), "\t- ne|sted"), "\tne|sted", "indent is kept")
        XCTAssertEqual(runCommand(.quote, "sa|id"), "> sa|id")
        XCTAssertEqual(runCommand(.quote, "> sa|id"), "sa|id")
    }

    func testCodeBlockToggle() {
        XCTAssertEqual(runCommand(.codeBlock, "|"), "```\n|\n```")
        XCTAssertEqual(runCommand(.codeBlock, "«let x = 1»"), "```\n«let x = 1»\n```")
        XCTAssertEqual(runCommand(.codeBlock, "```\nlet |x\n```"), "let |x")
    }

    func testIndentOutdent() {
        XCTAssertEqual(runCommand(.indent, "- a\n- b|"), "- a\n\t- b|")
        XCTAssertEqual(runCommand(.outdent, "- a\n\t- b|"), "- a\n- b|")
        XCTAssertEqual(runCommand(.outdent, "- a\n    - b|"), "- a\n- b|")
        XCTAssertNil(runCommand(.indent, "plain|"), "Tab outside a list types a tab")
    }

    func testLinkAndWikilink() {
        let (t, sel) = split("Bought from «the Kyoto shop» last week.")
        let e = MarkdownCommands.link(url: "kyoto.example.com/tea", text: t, selection: sel)
        XCTAssertEqual(mark(e.applied(to: t).text, e.selection), "Bought from [the Kyoto shop](https://kyoto.example.com/tea)| last week.")
        let page = PageRef(path: "wiki/sources/Kyoto tea shops.md", title: "Kyoto tea shops")
        let w = MarkdownCommands.wikilink(page, text: t, selection: sel)
        XCTAssertEqual(w.applied(to: t).text, "Bought from [[Kyoto tea shops|the Kyoto shop]] last week.")
        let (t2, s2) = split("See |")
        XCTAssertEqual(MarkdownCommands.wikilink(page, text: t2, selection: s2).applied(to: t2).text, "See [[Kyoto tea shops]]")
        XCTAssertTrue(MarkdownCommands.looksLikeURL("https://a.b"))
        XCTAssertTrue(MarkdownCommands.looksLikeURL("example.com"))
        XCTAssertFalse(MarkdownCommands.looksLikeURL("Sencha basics"))
    }
}

final class MarkdownTypingTests: XCTestCase {
    private func ret(_ marked: String, submit: Bool = false) -> String {
        let (t, sel) = split(marked)
        switch MarkdownCommands.returnKey(text: t, selection: sel, submitOnReturn: submit) {
        case .newline: return "newline"
        case .submit(nil): return "submit"
        case .submit(let e?): let (o, s) = e.applied(to: t); return "submit:" + mark(o, s)
        case .edit(let e): let (o, s) = e.applied(to: t); return mark(o, s)
        }
    }

    func testListContinuation() {
        XCTAssertEqual(ret("- First steep|"), "- First steep\n- |")
        XCTAssertEqual(ret("* a|"), "* a\n* |")
        XCTAssertEqual(ret("1. one|"), "1. one\n2. |")
        XCTAssertEqual(ret("9) nine|"), "9) nine\n10) |")
        XCTAssertEqual(ret("- [x] done|"), "- [x] done\n- [ ] |")
        XCTAssertEqual(ret("\t- nested|"), "\t- nested\n\t- |")
        XCTAssertEqual(ret("- spl|it"), "- spl\n- |it")
        XCTAssertEqual(ret("> said|"), "> said\n> |")
    }

    func testReturnOnEmptyItemEndsTheList() {
        XCTAssertEqual(ret("- a\n- |"), "- a\n|")
        XCTAssertEqual(ret("- a\n\t- |"), "- a\n- |", "a nested empty item moves out a level")
        XCTAssertEqual(ret("- a\n- |", submit: true), "submit:- a\n|", "Ask: an empty item sends")
    }

    func testSubmitModes() {
        XCTAssertEqual(ret("plain|"), "newline")
        XCTAssertEqual(ret("plain|", submit: true), "submit")
        XCTAssertEqual(ret("- item|", submit: true), "- item\n- |", "Ask: Return in a list adds an item")
        XCTAssertEqual(ret("```\nco|de\n```", submit: true), "newline", "Return inside code is a newline")
    }

    func testFenceOpensCodeBlock() {
        XCTAssertEqual(ret("```|"), "```\n|\n```")
        XCTAssertEqual(ret("```swift|"), "```swift\n|\n```")
        XCTAssertEqual(ret("```\nx\n```|", submit: true), "submit")
    }

    func testTypeToFormat() {
        let (t, sel) = split("[ ] |")
        let r = MarkdownCommands.afterTyping(" ", text: t, cursor: sel.location)
        let e = try! XCTUnwrap(r.edit)
        XCTAssertEqual(mark(e.applied(to: t).text, e.selection), "- [ ] |")
        let (t2, s2) = split("see [[|")
        let r2 = MarkdownCommands.afterTyping("[", text: t2, cursor: s2.location)
        XCTAssertEqual(r2.pickerAnchor, 6)
        XCTAssertEqual(mark(r2.edit!.applied(to: t2).text, r2.edit!.selection), "see [[|]]")
        XCTAssertEqual(MarkdownCommands.pickerQuery(text: "see [[Sen]]", anchor: 6, cursor: 9), "Sen")
        XCTAssertEqual(MarkdownCommands.pickerRange(text: "see [[Sen]]", anchor: 6, cursor: 9), NSRange(location: 4, length: 7))
        XCTAssertNil(MarkdownCommands.pickerQuery(text: "see [[Sen]] x", anchor: 6, cursor: 13))
        XCTAssertNil(MarkdownCommands.afterTyping(" ", text: "# ", cursor: 2).edit, "# + space is already a heading")
    }
}

final class MarkdownPasteTests: XCTestCase {
    func testHTMLToMarkdown() throws {
        let html = """
        <meta charset="utf-8"><h2>Brewing</h2><p>Use <strong>60 °C</strong> for <em>gyokuro</em>,
        see <a href="https://example.com/tea">the shop</a>.</p>
        <ul><li>First steep</li><li>Second <code>30 s</code><ul><li>nested</li></ul></li></ul>
        <ol><li>one</li><li>two</li></ol>
        <pre><code>let x = 1
        let y = 2</code></pre>
        <blockquote><p>Soft water is best.</p></blockquote>
        """
        let md = try XCTUnwrap(MarkdownPaste.htmlToMarkdown(html))
        XCTAssertEqual(md, """
        ## Brewing

        Use **60 °C** for *gyokuro*, see [the shop](https://example.com/tea).

        - First steep
        - Second `30 s`
        \t- nested

        1. one
        2. two

        ```
        let x = 1
        let y = 2
        ```

        > Soft water is best.
        """)
    }

    func testSlackAndDocsStyledSpans() throws {
        let html = #"<b style="font-weight:normal;"><span style="font-weight:700">Bold</span> and <span style="font-style:italic">it</span> and <span style="text-decoration:line-through">x</span></b>"#
        XCTAssertEqual(MarkdownPaste.htmlToMarkdown(html), "**Bold** and *it* and ~~x~~")
    }

    func testPlainHTMLFallsBackToPlainText() {
        XCTAssertNil(MarkdownPaste.htmlToMarkdown("<div><span style=\"color:red\">just text</span></div>"))
    }

    func testMarkdownIsKeptAsWritten() {
        XCTAssertTrue(MarkdownPaste.looksLikeMarkdown("## Title\nbody"))
        XCTAssertTrue(MarkdownPaste.looksLikeMarkdown("some **bold** text"))
        XCTAssertTrue(MarkdownPaste.looksLikeMarkdown("- a\n- b"))
        XCTAssertFalse(MarkdownPaste.looksLikeMarkdown("Just a sentence. With 2 * 3."))
        let pb = NSPasteboard(name: NSPasteboard.Name("distill-test-\(UUID().uuidString)"))
        pb.clearContents()
        pb.declareTypes([.string, .html], owner: nil)
        pb.setString("- a\n- **b**", forType: .string)
        pb.setString("<ul><li>a</li><li><b>b</b></li></ul>", forType: .html)
        XCTAssertEqual(MarkdownPaste.text(from: pb), "- a\n- **b**")
        pb.clearContents()
        pb.declareTypes([.string, .html], owner: nil)
        pb.setString("Title\nUse 60 °C", forType: .string)
        pb.setString("<h1>Title</h1><p>Use <b>60 °C</b></p>", forType: .html)
        XCTAssertEqual(MarkdownPaste.text(from: pb), "# Title\n\nUse **60 °C**")
        pb.releaseGlobally()
    }

    func testRTFToMarkdown() throws {
        let a = NSMutableAttributedString(string: "Plain ", attributes: [.font: NSFont.systemFont(ofSize: 12)])
        a.append(NSAttributedString(string: "bold", attributes: [.font: NSFont.boldSystemFont(ofSize: 12)]))
        a.append(NSAttributedString(string: " and ", attributes: [.font: NSFont.systemFont(ofSize: 12)]))
        a.append(NSAttributedString(string: "link", attributes: [.font: NSFont.systemFont(ofSize: 12), .link: URL(string: "https://a.b")!]))
        XCTAssertEqual(MarkdownPaste.attributedToMarkdown(a), "Plain **bold** and [link](https://a.b)")
        XCTAssertNil(MarkdownPaste.attributedToMarkdown(NSAttributedString(string: "plain")))
    }
}
