---
title: Quick actions and shortcuts
status: built
updated: 2026-10-02
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

Canvas: "Quick windows: size, growth and scrolling" (every case) and "Quick
actions" panels 2–5. Code: `QuickWindow.swift` (window shell, resize corner,
`QuickWindowSizer`), `QuickShell.swift` (SwiftUI layout), frame math in
`DistillKit/QuickWindowGeometry.swift` (unit-tested).

- **Opening**: centered horizontally with the top edge 30 % down the visible
  frame (like Spotlight), on the screen with the pointer (shortcuts, Window
  menu) or the flask's screen (hover menu, flask click). A window the user
  dragged reopens at that spot until the app quits (not persisted).
- **Close bar**: QUICK NOTE / QUICK ASK and **×**. × does what Esc does.
- **Growth**: the window fits its content and grows downward; the top edge
  never moves. It stops 8 pt above the bottom of the visible frame; past that
  only the middle scrolls (quick note: title, text with its images and errors;
  quick ask: the answer; the source row and the model/filter row stay with the footer), with an overlay scroller and a soft fade at the cut
  edge. The close bar, the question (quick ask) and the footer stay put. It
  shrinks back as content shrinks. No scroll-bar strip anywhere: the scroll
  views are forced to the overlay style, also under "Show scroll bars: Always".
- **Resize**: the bottom-right corner resizes the window with the
  top-left corner fixed; minimum 360 × 160. The dragged size is a floor saved
  per window in UserDefaults (`distill.quickNote.size`, `distill.quickAsk.size`).
  Bigger than the content: the spare height goes to the text area (a click
  there puts the cursor at the end of the note). Smaller than the content: the
  difference stays hidden and the middle scrolls; later typing grows the
  window by what was added (it doesn't snap back to full height), and once
  everything fits again the window follows the content down to the floor.
- Resizing animates (0.16 s), instantly with Reduce Motion.
- **Aa** in both footers toggles `@AppStorage("distill.markdownBar.quick")`;
  the text editors show their Markdown bar from that key.
- **Quick ask** (built, `QuickAsk.swift`): question field, short answer (first
  paragraph) with up to three source chips, model · effort chip, "All notes"
  with **+ Limit** (labels and sources), chips, and the **Any label | All
  labels** + **Include unconfirmed** row on one line. The question stays at
  the top; the model and filter row (and the Any/All panel when limited) sits
  at the bottom right above the footer however big the window is, and more
  chips wrap upward. The answer fills the space between, so there is never a
  gap between the question and the answer. The row hides while answering. **Continue in Distill**
  hands the chat (even mid-run) to the full Ask screen. Esc closes the window
  but keeps the run: the flask gets a green ring while the answer is on its way
  or unseen, and clicking the flask then reopens the window instead of the app.
  Opening it again after a seen answer starts a new chat.
- **Quick note**: title (wraps to 2 lines, then scrolls in its field), text
  with images inside it (⌘V puts an image at the cursor; hover for **Extract
  content** and ×, same rules as [Write a note](notes-composer.md#images);
  **Add to queue** waits while an image is being read), and the footer **Aa · + Source · ⌘↩ saves ·
  Add to queue** (**Try again** after an error, shown above the footer).
  **+ Source** opens a menu of the Settings sources by group; once one is
  picked the button becomes that source's green chip ("In person ▾"; truncated, never widens
  the window; the same menu changes it or picks **No source**) and a **Link,
  channel or person** field appears on its own row just above the footer
  buttons. Both stay pinned at the bottom however tall the window is dragged;
  the text area takes the extra height. Labels are suggested after
  queueing, like the full composer: the window turns into the label step in
  place (chips wrap, the window resizes) and closes once labels are applied.
  × or Esc during the label step is **Skip** (the note stays queued,
  unlabeled). The flask's count goes up.

## Keyboard shortcuts

- Settings → Keyboard shortcuts has two recorders: **Ask a question** and
  **Add a note**.
- Both are **unset by default**; the app does not pick key combinations. The
  user clicks "Record shortcut" and presses keys; × clears it.
- Recorded shortcuts are global (work from any app) and open the matching quick
  window.
