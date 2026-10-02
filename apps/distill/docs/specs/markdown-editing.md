---
title: Markdown editing
status: built
updated: 2026-10-02
---

# Markdown editing

Note bodies (Write a note, quick note), Ask questions (Ask, quick ask) and the
Review reply box accept full Markdown. Canvas artboard: "Markdown editing"
(Markdown.dc.html). Titles, source links and label fields stay plain text.

## Editor

One shared editor (`clients/macos/Sources/Distill/MarkdownEditor*.swift`), an
NSTextView in an NSViewRepresentable:

- The text is plain Markdown, stored exactly as typed. It is styled while you
  type, like Obsidian's Live Preview. Headings, bold, italic, strikethrough,
  inline code, fenced code blocks (a tinted band), quotes (a bar on the left),
  lists, checklists (done items struck through and faded), links and wikilinks
  are styled, and their marks stay visible but faded.
- There is never a scroll-bar strip. The scroller is always the overlay kind,
  shown only while scrolling. When the text fits, wheel events go to the
  enclosing view.
- The editor reports its content height. Containers clamp it with min and max
  height, or min and max lines:
  - `maxHeight: .infinity` means full height, never scrolling (the quick note).
  - `fillsHeight` takes the height offered from outside and scrolls inside,
    with a soft fade at the cut edge (Write a note).
- Submit modes:
  - **Ask**: Return sends, ⇧Return adds a line.
  - **Notes**: ⌘Return sends (or is left to the screen's own ⌘↩ button), and
    Return adds a line.
  - Inside a list, Return continues it (`- `, `2. `, `- [ ] `). Return on an
    empty item ends the list (a nested item moves out a level). In Ask, Return
    on an empty item sends.
  - Return inside a fenced code block is always a newline.
- Pure logic, unit tested in `Tests/DistillTests/MarkdownEditor*Tests.swift`:
  - `MarkdownEditorParser.swift`: style spans.
  - `MarkdownEditorCommands.swift`: toggles, Return, type-to-format, links.
  - `MarkdownEditorPaste.swift`: paste.

  All ranges are UTF-16.

## Style bar

| Variant | Buttons | Where |
| --- | --- | --- |
| Full | B I S, H▾, bullet, numbered, checklist, quote, inline code, code block, link, note link | Write a note: always shown, between the title and the text. |
| Compact | B I, H▾, bullet, checklist, inline code, link, note link | Review reply (always shown, above the reply box). Ask and quick windows: shown by **Aa**. |

- Buttons light up for the style at the cursor.
- **H▾** opens a menu with Normal text and Heading 1–3, showing their
  shortcuts. The current level is highlighted.
- **Aa** toggles the compact bar. The choice is remembered in
  `@AppStorage("distill.markdownBar.ask")` for the Ask screen (its Aa is in
  the question field). The quick windows use
  `@AppStorage("distill.markdownBar.quick")`: their Aa sets it, and their
  editors read it.

## Selection bubble

Selecting text shows a dark bubble next to the selection with B, I, S, inline
code, link and note link. It appears in every editor, even when the bar is
hidden.

## Links and the note picker

- **⌘K**, or the link or note-link button, opens a popover with a field for a
  URL or a note name, plus vault notes.
  - A URL writes `[text](url)`. The selection becomes the text, and a bare
    domain gets `https://`.
  - Picking a note writes `[[Note]]`.
- Typing `[[` opens the same note list under the cursor and auto-closes with
  `]]`. Typing filters the list. ↑ and ↓ choose, Return or Tab picks, and Esc
  closes it.
- Notes come from the core's `searchPages(query, {vaultPath, limit})` through
  `GET /v1/pages?q=&vault=&limit=`, which returns `{pages: [{path, title}]}`.
  - It scans `wiki/**/*.md` in the vault, skipping system pages (index, log,
    hot, `wiki/meta/`). The title is the frontmatter `title`, or else the file
    name.
  - Ranking order: exact match, prefix, word prefix, all words, substring, then
    in-order letters. The file name counts slightly less than the title, and
    accents are folded.
  - The default limit is 8 and the maximum is 50. A bad `limit` returns 400.
- Obsidian resolves `[[…]]` by file name, so the link is `[[file name]]`. When
  the title differs from the file name, the link is `[[file name|Title]]`.

## Keyboard shortcuts

| Style | Keys | Markdown |
| --- | --- | --- |
| Bold | ⌘B | `**text**` |
| Italic | ⌘I | `*text*` |
| Strikethrough | ⌘⇧X | `~~text~~` |
| Inline code | ⌘E | `` `code` `` |
| Link | ⌘K | `[text](url)` or `[[Note]]` |
| Heading 1–3 | ⌘⌥1–3 (⌘⌥0 normal) | `#` `##` `###` |
| Bullet list | ⌘⇧8 | `- item` |
| Numbered list | ⌘⇧7 | `1. item` |
| Checklist | ⌘⇧9 | `- [ ] item` |
| Quote | ⌘⇧. | `> text` |
| Code block | ⌘⌥C | ```` ``` ```` |
| Indent / outdent | Tab / ⇧Tab | nested lists (a tab) |

Inline styles toggle: a styled selection or cursor is unwrapped. List, quote
and heading commands work on every selected line. Outside a list, Tab types a
tab in notes and moves focus in Ask.

## Type-to-format and paste

| You type | Result |
| --- | --- |
| `#` + space | Heading 1 (`##` for 2, `###` for 3) |
| `-` or `*` + space | Bullet list |
| `1.` + space | Numbered list |
| `[ ]` + space | Checklist item (`- [ ] `) |
| `>` + space | Quote |
| ```` ``` ```` + Return | Code block (the closing fence is added) |
| `[[` | Note picker |
| Return on an empty list item | Ends the list |
| Paste from a web page or Slack | Converted to Markdown |
| Paste Markdown | Kept as written |

Paste:

- Text that already carries Markdown syntax is pasted as is.
- Otherwise HTML on the pasteboard is converted: headings, bold, italic,
  strikethrough, links, lists (nested and task lists), code, code blocks and
  quotes. This includes Slack and Google Docs CSS spans.
- HTML with no formatting falls back to the plain text, and RTF is used when
  there is no HTML.
- Copy writes plain Markdown only (an image is its `![[name]]`).
- In editors that take images (Write a note, quick note) an image clipboard
  (image files, or picture data with no text) inserts the images at the
  cursor; pasted or dropped Markdown that embeds one of the note's images
  shows it as an image again. Other editors leave an image-only clipboard
  alone.

## Images inside the text

Write a note and the quick note pass an `InlineImageHost`
(`MarkdownEditorImages.swift`). In the text view an image is one U+FFFC
character with an `InlineImageAttachment` (TextKit 1 cell sized to the image's
aspect, at most the box width and 320 pt tall); the binding and the draft keep
`![[name]]`. Conversion happens only where text enters (`load`, paste, drop)
or leaves (`setText`, copy) the view, styling keeps the attachments, and a
command over a range that holds an image re-attaches it. Hover chrome,
selection ring, reading shimmer and failure strip are SwiftUI views placed
over each image; the extracted text is tinted and gets an "Extracted from …
· Undo ⌘Z" line for a few seconds. Insert, remove and extract are single undo
steps. Behavior: [Write a note](notes-composer.md#images).

## Snapshots

`Snapshot+Markdown.swift` renders `editor-full.png`, `editor-heading-menu.png`,
`editor-bubble.png`, `editor-link.png` and `ask-aa.png`. ImageRenderer cannot
draw an NSTextView, so in `--snapshot` the editor draws the same styled text
with SwiftUI (`MarkdownStyledText`). `markdownBarOverride` replaces the stored
Aa preference there.
