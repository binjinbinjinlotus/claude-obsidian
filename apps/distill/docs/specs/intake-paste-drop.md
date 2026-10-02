---
title: "Intake: paste and drop"
status: built
updated: 2026-10-01
---

# Intake: paste and drop

Code: `clients/macos/Sources/Distill/Intake.swift` (`PasteboardIntake`, `DropTargetView`),
`clients/macos/Sources/WorkerCore/Queue.swift` (`QueueIntake`).

- **Drop** files on the Queue drop panel or the floating icon: they are copied
  into the queue; originals stay where they were.
- **Paste**: ⌘V in the main window (when no text field is editing), ⇧⌘V from the
  Queue menu, or right-click on the floating icon → Paste into Queue.
  - File URLs on the clipboard are copied like a drop.
  - Images become `Screenshot <yyyy-MM-dd HHmmss>.png`.
  - Text becomes `Clipping <yyyy-MM-dd HHmmss>.md`.
- **Choose files** on the Queue screen opens a file picker.

Image handling beyond "a file in the queue" (keep vs. extract text) is part of
[Write a note](notes-composer.md), which is designed but not built.
