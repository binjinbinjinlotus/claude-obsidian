---
title: Quick actions and shortcuts
status: built
updated: 2026-10-01
---

# Quick actions and shortcuts

Act from the floating flask without opening the main window. Canvas artboards:
"Quick actions from the floating flask", "Settings" (Keyboard shortcuts).

## Hover menu (built)

- Hovering the flask for about 0.3 s fans out pill buttons: **Ask**,
  **Add note**, **Paste clipboard**, **Open Distill**. It opens toward the
  screen center and closes when the pointer leaves. A click still opens the app.
- Code: `clients/macos/Sources/Distill/HoverMenu.swift`. The pills are a
  separate borderless panel; the menu closes once the pointer has been outside
  both the flask and the pills for 0.25 s. Mouse down or a drag on the flask
  cancels it. **Add note** posts `distill.openQuickNote`; anything (global
  shortcuts, menus) can open quick ask with `distill.openQuickAsk`.

## Quick windows

- Appear beside the flask; Esc closes.
- **Quick ask** (built, `QuickAsk.swift`): question field, short answer (first
  paragraph) with up to three source chips, model · effort chip, "All notes"
  with **+ Limit** (labels and sources), chips, and the **Any label | All
  labels** + **Include unconfirmed** row on one line. **Continue in Distill**
  hands the chat (even mid-run) to the full Ask screen. Esc closes the window
  but keeps the run: the flask gets a green ring while the answer is on its way
  or unseen, and clicking the flask then reopens the window instead of the app.
  Opening it again after a seen answer starts a new chat.
- **Quick note**: title, text, source, images with Keep / Extract text,
  **Add to queue** (⌘↩). Labels are suggested after queueing, like the full
  composer. Closes after saving; the flask's
  count goes up.

## Keyboard shortcuts

- Settings → Keyboard shortcuts has two recorders: **Ask a question** and
  **Add a note**.
- Both are **unset by default**; the app does not pick key combinations. The
  user clicks "Record shortcut" and presses keys; × clears it.
- Recorded shortcuts are global (work from any app) and open the matching quick
  window.
