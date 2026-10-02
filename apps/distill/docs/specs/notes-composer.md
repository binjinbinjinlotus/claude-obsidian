---
title: Write a note
status: designed
updated: 2026-10-01
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

The composer writes one note file plus its images into the queue, with a small
manifest recording each image's choice, the source and the labels. The ingest
prompt reads the manifest so Claude follows the user's choices instead of
guessing. The note still goes through Review before anything is written.
