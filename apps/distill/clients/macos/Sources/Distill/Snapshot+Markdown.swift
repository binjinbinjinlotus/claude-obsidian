import AppKit
import SwiftUI
import DistillKit

/// `--snapshot` fixtures for the Markdown editor (Markdown.dc.html): the full bar,
/// the heading menu, the selection bubble, the link popover, and Ask with Aa on.
@MainActor
enum MarkdownSnapshot {
    static let title = "Kettle settings for the new tea set"
    static let note = """
    ## Brewing
    Use **60 °C** for gyokuro and *never* boiling water.
    - First steep 2 min
    - Second steep `30 s`
    - [x] Buy the 50 g tin
    - [ ] Ask about the spring harvest
    > “Soft water is best.” — the owner
    See [[Sencha basics]] and [the shop](https://…)
    """

    static func run(engine: AppModel, outDir: URL) {
        let size = CGSize(width: 680, height: 460)
        var bold = MarkdownParser.ActiveStyles()
        bold.bold = true
        bold.heading = 0

        render(Card { NoteCard(text: note, fixture: MarkdownEditorFixture(active: bold)) },
               size: size, to: outDir.appendingPathComponent("editor-full.png"))

        var h2 = MarkdownParser.ActiveStyles()
        h2.heading = 2
        render(Card {
            NoteCard(text: "## Brewing\nUse 60 °C for gyokuro.", fixture: MarkdownEditorFixture(active: h2, pressed: .heading), minHeight: 190)
                .overlay(alignment: .topLeading) {
                    MarkdownHeadingMenu(current: 2) { _ in }.offset(x: 92, y: 36 + 37)
                }
        }, size: CGSize(width: 680, height: 400), to: outDir.appendingPathComponent("editor-heading-menu.png"))

        let bubbleText = "Use 60 °C for gyokuro and never boiling water.\n\n\nLet it steep for two minutes before pouring."
        let selected = (bubbleText as NSString).range(of: "steep for two minutes")
        render(Card {
            NoteCard(text: bubbleText, fixture: MarkdownEditorFixture(highlight: selected))
                .overlay(alignment: .topLeading) {
                    MarkdownSelectionBubble { _, _ in }.offset(x: 36, y: 105)
                }
        }, size: CGSize(width: 680, height: 330), to: outDir.appendingPathComponent("editor-bubble.png"))

        let linkText = "Bought from the Kyoto shop last week."
        let picker = MarkdownPickerState()
        picker.results = [PageRef(path: "wiki/sources/Kyoto tea shops.md", title: "Kyoto tea shops"),
                          PageRef(path: "wiki/concepts/sencha.md", title: "Sencha basics")]
        render(Card {
            NoteCard(text: linkText, fixture: MarkdownEditorFixture(pressed: .link, highlight: (linkText as NSString).range(of: "the Kyoto shop")), minHeight: 150)
                .overlay(alignment: .topLeading) {
                    MarkdownLinkPopover(picker: picker, showsField: true, commit: {}, cancel: {}).offset(x: 0, y: 37 + 42 + 30)
                }
        }, size: CGSize(width: 680, height: 380), to: outDir.appendingPathComponent("editor-link.png"))

        // Ask with Aa on: the compact bar above a Markdown question.
        let ask = engine.ask
        AskFixtures.load(ask, vault: engine.activeVault?.path ?? "/Research")
        AskFixtures.answered(ask.main)
        ask.main.draft = "Compare these two:\n- **gyokuro** at 60 °C\n- sencha at 80 °C"
        render(AskSnapshotScreen().environmentObject(engine).environment(\.markdownBarOverride, true),
               size: CGSize(width: 1120, height: 860), to: outDir.appendingPathComponent("ask-aa.png"))
        ask.main.draft = ""
    }

    private static func render<V: View>(_ view: V, size: CGSize, to url: URL) {
        Snapshot.render(view, size: size, to: url)
    }

    /// The canvas's gray stage with the card centered at the top.
    private struct Card<Content: View>: View {
        @ViewBuilder var content: Content

        var body: some View {
            ZStack(alignment: .top) {
                Color(hex: 0xE4E1DB)
                content
                    .padding(.horizontal, 18).padding(.vertical, 16)
                    .frame(width: 600, alignment: .topLeading)
                    .background(RoundedRectangle(cornerRadius: 18).fill(Color.white))
                    .compositingGroup()
                    .shadow(color: Color(hex: 0x1D1C1A).opacity(0.10), radius: 14, y: 12)
                    .padding(.top, 28)
            }
            .foregroundStyle(Theme.ink)
        }
    }

    /// Title, then the note editor with its full bar (as in Write a note).
    private struct NoteCard: View {
        @State var text: String
        var fixture: MarkdownEditorFixture
        var minHeight: CGFloat = 40

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                Text(MarkdownSnapshot.title).font(.system(size: 17, weight: .semibold, design: .rounded))
                BareTextEditor(placeholder: "Write what you want to remember…", text: $text, minHeight: minHeight,
                               maxHeight: .infinity, bar: .full)
                    .environment(\.markdownFixture, fixture)
            }
        }
    }
}
