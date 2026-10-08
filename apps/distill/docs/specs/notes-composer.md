---
title: Write a note
status: built
updated: 2026-10-04
---

# Write a note

Type knowledge directly, with images, a source and labels. Canvas artboards:
"Write a note (text + images)", "Images stay inside the text"
(ImagesInline.dc.html), quick-note window in "Quick actions".

## Composer

- The Queue screen gets a switch: **Drop files** | **Write a note**.
- Fields: title, text (with images inside it), **Source** (see
  [Labels and sources](labels-and-sources.md)). Labels are not picked here:
  they are suggested after the note is queued, from its actual content.
- **Add to queue** (⌘↩) saves; **Discard** clears. A summary line counts the
  images that stay: "One note · 2 images." While an image is being read it
  says "One note · reading 1 image…" and Add to queue waits.

## Sizing

Canvas: "Write a note: size and scrolling". Code: `ComposeCardLayout`
(`ScrollChrome.swift`) around the composer card in `ComposeView.swift`.

- The header ("Add to your vault" and the **Drop files | Write a note**
  switch) and the footer (summary, Discard, Add to queue) stay put at every
  window size. The switch never wraps (fixed width).
- The note box fills the card: the window's extra height goes to it, never to
  a blank gap. The source panel and errors stay together at the bottom of the
  card; images are part of the text and scroll with it.
- A note longer than the box scrolls inside the box only (overlay scroller,
  fade at the cut edge; the editor owns that).
- In a short window (down to the 900 × 600 minimum) the box keeps at least 4
  lines and the whole card scrolls, with an overlay bar and a fade.

## Markdown

The note text is Markdown, stored exactly as typed and styled while you type
(see [Markdown editing](markdown-editing.md)).

- **Write a note** always shows the **full style bar** between the title and
  the text. The text area takes the card's leftover height and scrolls inside
  it, with an overlay scroller and a soft fade at the cut edge.
- The **quick note** shows a compact bar when its **Aa** is on
  (`distill.markdownBar.quick`). Its text reports its full height, and the
  window grows or scrolls around it.
- Return adds a line and continues lists. ⌘↩ adds the note to the queue.
- The selection bubble, ⌘K links, the `[[` note picker, the shortcuts and
  rich-text paste (web pages and Slack become Markdown) work in both.
- An image clipboard becomes an image at the cursor (see below). Title and
  source fields stay plain text.

## Images

Canvas: "Images stay inside the text" (ImagesInline.dc.html, 9 states).
Code: `MarkdownEditorImages.swift`, `ComposeDraft.swift`, `AppModel+Notes.swift`
(`insertImages`, `imageHost`, `extractImageText`).

- ⌘V, a drop on the card, or the **Image** button at the end of the full
  style bar puts the image **at the cursor**, on its own line, at its own
  shape (at most the box width and 320 pt tall). Typing carries on under it.
  The quick note does the same (⌘V or a drop); its window grows like it does
  for more lines of text.
- The draft text is Markdown with `![[file name]]` where each image sits.
  Pasted images are staged in a temp folder; chosen or dropped files are used
  where they are. Names are unique within a note and never contain `[ ] | # ^`
  (a clash is copied to the temp folder as `card 2.png`).
- **Hover** an image: **Extract content** (primary pill with a sparkle) and
  **×** in its top-right corner, its name and size bottom-left. Right-click
  has the same actions. A click selects it (blue ring); Delete removes it.
- **Extract content** reads the image with the "Text from images" model
  (Settings; default Claude Code · Haiku · low effort) through
  `POST /v1/images/extract`. The image dims with a shimmer and
  "Reading with Haiku… Cancel". Typing elsewhere continues; Cancel closes the
  request, which stops the runner, and leaves the image as it was.
- On success the image is replaced in place by the returned Markdown (lists,
  headings and tables kept, editable), tinted for a few seconds with
  "✦ Extracted from <name> by Haiku · Undo ⌘Z" under it. ⌘Z (or Undo) brings
  the image back. An extracted image is not saved.
- No text: the image stays with "No text found in this image." (Try again,
  OK). Failure: the image stays with "Couldn’t read this image: <reason>",
  **Try again** and **Settings**.
- Each image has its own actions and reading state. Images that stay are sent
  to `addNote` as `{path, mode: keep}`, in text order; images the text no
  longer embeds (removed or extracted) are not sent.
- A plain ⌘V on the Queue screen keeps today's behavior (the image becomes a
  queued file); only paste into a composer puts it in the note.

## Queue format

`addNote` (`core/src/engine/notes.ts`) writes one note file plus its images
into the queue, with a manifest `<stem>.distill.json`:

| Field | Meaning |
| --- | --- |
| `title`, `source`, `sourceRef` | Provenance for the ingest prompt. |
| `images[]` | `{file, mode: keep or extract}` per image (the app always sends `keep`; `extract` is legacy, for the CLI). |
| `requestID` | UUID returned by `addNote`; `labelNote` finds the note by it. |
| `origin` | `app` (default) or `cli`; decides the fallback when nothing is confirmed. |
| `labels` | Confirmed labels (present, even empty, = confirmed). Also written as the note's `tags`. |
| `suggestedLabels`, `suggestError` | AI suggestions once known. Never applied for `app` notes. |

Images are copied as `<stem> image N.<ext>` (`#[]|^` dropped from the stem).
The note text's `![[<original file name>]]` embeds are rewritten to those
names, so each image stays embedded exactly where it sat; the ingest prompt
tells the agent to keep that spot and use the attachment's name.

Suggest modes: `wait` runs the suggestion first and then writes the files (the
batch can never pick a note up mid-wait; a failure becomes `suggestError` and
the note is still queued); `background` writes, then suggests and emits a
`labelSuggestions` event, updating the manifest only while the note is still
in the queue; `none` skips. Validation runs before any AI call.

`labelNote(requestID, labels)` rewrites the manifest and the queued note's
`tags` (nothing else in the file changes). Once a batch has claimed the note:
`invalid_state`; unknown request: `not_found`.

**When the queue is the vault's `inbox/`** (decision 2026-10-04), the note's
files are created there once and never edited again: claude-obsidian keeps
`inbox/` outside its transactions, and files there are the user's. Label
state set after the note is written (`labelNote`'s labels, a background
suggestion or its error) goes to Distill's state instead, in
`<state>/labels/notes.json` keyed by requestID (`engine/note-labels.ts`).
Readers merge it over the manifest: the queue row's `labelsConfirmed` and the
batch's label plan (`draftBatchLabels`). The note's own `tags` keep what was
written at creation; the labels still reach the wiki through the ingest
prompt's Labels section and the reviewed transaction, as before. `labels: []`
in the overlay still means "confirmed: no labels".

The ingest prompt reads the manifest so Claude follows the user's choices
instead of guessing; its label fields are bookkeeping, and the prompt's own
Labels section decides labels. The note still goes through Review before
anything is written.
