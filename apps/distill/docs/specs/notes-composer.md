---
title: Write a note
status: built
updated: 2026-10-02
---

# Write a note

Type knowledge directly, with images, a source and labels. Canvas artboards:
"Write a note (text + images)", quick-note window in "Quick actions".

## Composer

- The Queue screen gets a switch: **Drop files** | **Write a note**.
- Fields: title, text, **Source** (see [Labels and sources](labels-and-sources.md)),
  images. Labels are not picked here: they are suggested after the note is
  queued, from its actual content.
- **Add to queue** (⌘↩) saves; **Discard** clears. A summary line states what
  will be saved, e.g. "one note with 1 image attached and 1 image read as text".

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
- An image-only clipboard still becomes an image (see below). Title and source
  fields stay plain text.

## Images

Each image added in the composer (⌘V or Add image) has a two-way switch:

| Choice | Result |
| --- | --- |
| **Keep image** (default) | Stored in the vault as an attachment and embedded in the note. |
| **Extract text** | Claude reads the text out of the image into the note; the image is not stored. |

The default is Keep so an image is never dropped silently. A plain ⌘V on the
Queue screen keeps today's behavior (the image becomes a queued file); only
images inside the composer get the switch.

## Queue format

`addNote` (`core/src/engine/notes.ts`) writes one note file plus its images
into the queue, with a manifest `<stem>.distill.json`:

| Field | Meaning |
| --- | --- |
| `title`, `source`, `sourceRef` | Provenance for the ingest prompt. |
| `images[]` | `{file, mode: keep or extract}` per image. |
| `requestID` | UUID returned by `addNote`; `labelNote` finds the note by it. |
| `origin` | `app` (default) or `cli`; decides the fallback when nothing is confirmed. |
| `labels` | Confirmed labels (present, even empty, = confirmed). Also written as the note's `tags`. |
| `suggestedLabels`, `suggestError` | AI suggestions once known. Never applied for `app` notes. |

Suggest modes: `wait` runs the suggestion first and then writes the files (the
batch can never pick a note up mid-wait; a failure becomes `suggestError` and
the note is still queued); `background` writes, then suggests and emits a
`labelSuggestions` event, updating the manifest only while the note is still
in the queue; `none` skips. Validation runs before any AI call.

`labelNote(requestID, labels)` rewrites the manifest and the queued note's
`tags` (nothing else in the file changes). Once a batch has claimed the note:
`invalid_state`; unknown request: `not_found`.

The ingest prompt reads the manifest so Claude follows the user's choices
instead of guessing; its label fields are bookkeeping, and the prompt's own
Labels section decides labels. The note still goes through Review before
anything is written.
