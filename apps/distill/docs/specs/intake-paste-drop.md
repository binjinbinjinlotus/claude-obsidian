---
title: "Intake: paste and drop"
status: built
updated: 2026-10-01
---

# Intake: paste and drop

Code: `clients/macos/Sources/Distill/Intake.swift` (`PasteboardIntake`, `DropTargetView`),
`clients/macos/Sources/Distill/AppModel.swift` (`enqueue`). The core copies files
(`POST /v1/queue/files` → `addQueueFiles`, `core/src/engine/queue.ts`).

- **Drop** files on the Queue drop panel or the floating icon. The app sends
  their paths to the core, which copies them into the active vault's queue with
  collision-safe names. Originals stay where they were. Folders are skipped.
- **Paste**: ⌘V in the main window (when no text field is editing), ⇧⌘V from the
  Queue menu, or right-click on the floating icon → Paste into Queue.
  - File URLs on the clipboard are handled like a drop.
  - Images become `Screenshot <yyyy-MM-dd HHmmss>.png` and text becomes
    `Clipping <yyyy-MM-dd HHmmss>.md`, in local time. The app writes the pasted
    data to a temp file with that name, sends it to the core like a drop, then
    deletes the temp file. The core keeps the basename.
- **Choose files** on the Queue screen opens a file picker (handled like a drop).
- **Remove** (× on a queue row) moves that file from the queue folder to the
  Trash. The file belongs to the user, and the core rescans the folder.

Image handling beyond "a file in the queue" (keep vs. extract text) is part of
[Write a note](notes-composer.md) (`POST /v1/notes`). While the composer is on
screen and its window is key, ⌘V adds images (and text) to the note instead
of the queue (`PasteboardIntake.composeTarget`); drops on the Queue panel or
the flask always queue files.
