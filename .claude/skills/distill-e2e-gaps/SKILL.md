---
name: distill-e2e-gaps
description: Known blind spots when an AI end-to-end tests the Distill macOS app (apps/distill/clients/macos). A checklist of gaps that earlier AI test passes missed and the user then found by hand. Read it before saying a Distill UI change is tested, reviewing snapshots, or reinstalling for the user. Triggers: e2e test Distill, test the Mac app, verify the UI, did you test it, check before reinstall.
---

# Distill e2e: the gaps we already know

**This is not a testing guide.** You can work out how to build, drive and
inspect the app yourself. This file only lists the places where earlier AI
test passes said "verified" and the user then found the bug in the real app
within minutes. Treat each item as "did I actually look at this?", not as a
step to follow.

The list is incomplete. A clean run of everything below is not proof the
change works. When you or the user find a new miss, add it here: one item,
what was missed, and why the test didn't see it.

## Why tests pass and the app is still broken

Most misses shared one cause: **the test exercised something that was not
what the user runs.**

- **Snapshots are not the app.**
  - `--snapshot --states` renders one fixed, roomy window size, draws popovers
    in place, and uses fixture data.
  - The user runs a ~890 pt wide window, with real popovers and their own
    data.
- **A unit test of a view is not the window it lives in.** For example, a
  test that sends an action to a window that isn't key.
- **The core under test is not the core the app talks to.** After a
  reinstall, the old core keeps running until it is stopped.
- **"Rendered" is not "looked at."** One pass rendered 248 PNGs and opened 16.

## Known gaps

### Layout and size
- **Narrow windows.** A row wider than the window doesn't clip on the right.
  It pushes the whole screen wider, centres it, and cuts off the left, so the
  title and the search field disappeared on To do. Check at the window's
  minimum width and at ~890 pt, not only at the snapshot size.
- **Long content.** Controls meant to stay pinned at the bottom (the model
  row, the source picker in quick windows) scrolled away once the text got
  long. Test with long and multi-line text, and with images inside the text.
- **Empty and error states together.** The canvas drew "not connected" inside
  an item card. With no items there was no card, so there was nothing to
  click. Check each empty state combined with each connection or error state.

### Windows and focus
- **Quick windows are non-activating `NSPanel`s.** ⌘C, ⌘V, ⌘X, ⌘A, ⌘Z
  silently did nothing there, but worked in the main window. A test that
  calls `NSApp.sendAction` passes anyway, because the test window isn't key.
  Check the key equivalents in each window type.
- **Close means fresh.** Closing a quick window and reopening it showed the
  old draft and source. Check close → reopen for both quick windows, and also
  close while a run is in progress.

### Work in progress vs. navigation
- **Leaving mid-request.** Clicking New chat while an answer was streaming
  lost the question. For any long call (Ask, draft, improve, extract, batch),
  try navigating away, closing the window and opening another item while it
  runs. Then come back and check that the result arrived and is in History.
- **Quitting mid-request.** A new chat's first question is lost if the app or
  core quits before the answer. Still open, so don't claim otherwise.
- **Leaving a screen can delete data.** With Keep history off, leaving Ask
  deletes the chat. "Open" on an item found in Ask leaves Ask, so the item's
  chat link goes dead.

### Undo, History and lifecycle
- **Undo must reach the designed state, not just "something".** After "Add
  all", Undo got a 409 from the core. The client quietly removed the items
  instead, so they landed in History as Removed instead of disappearing. Check
  where the item ends up (list, History, gone) against the canvas, and watch
  for errors that a fallback is hiding.
- **Bulk actions.** Completing several items showed one toast per item, and
  Undo restored only the last one.
- **Automatic vs. by-hand paths.** Duplicate detection ("Already in …")
  worked when run by hand, but the automatic run after an answer never
  reported duplicates. Test the automatic path; don't stop at the button.

### Install, data and the core
- **Reinstall must keep user data.** Use `distill.sh update`, which backs up
  and compares counts. Read the "Your data is intact: …" line, and treat any
  WARNING as a failure.
- **Stale core.** After installing, run `distill.sh core-stop` and confirm
  `status` shows a new core PID. Otherwise you are testing the new UI against
  the old core. That is exactly how "Update the Distill core" states and 501s
  slip through.
- **The installer runs the tests.** A flaky crash blocked an install: "Attempted
  to read an unowned reference but object … was already destroyed". A `Task`
  outlived its `AppModel`. A suite that passed once proves little; run it a
  few times after touching async code.
- **Real-shaped state.** The user's `settings.json` has `taskDefaults: {}`
  and older fields. Fixtures that set every field hide the default path. Use
  a copy of a realistic state in a temp `DISTILL_STATE_DIR`, never the real
  `~/Library/Application Support/Distill`.

### Design parity
- **The canvas is the spec:** https://claude.ai/artifact/VSqHFPZjcqY2bMqFEnPqpG.
  - The user compares the app against it, board by board.
  - Check the states your change touches, including wording: "Mark done" vs
    "Complete", "Finished at" vs "Ended at".
  - Check that each canvas component still matches its Swift view, using the
    table in `apps/distill/docs/specs/design-process.md`.
- **Features that quietly turn off.** "To-do from selected text" ships
  disabled, because a SwiftUI `Text` selection can't be read. When a control
  is disabled, say so; don't count it as tested.
- **Keyboard and selection.** ⌘A select-all and ⇧-click range selection were
  missing in lists, and ⌘N, Esc and ⏎ were inconsistent. Try them on every new
  list or editor.

## Boundaries that still apply
- Use throwaway vaults and a temp `DISTILL_STATE_DIR` only.
- Don't open local HTTP servers, browser previews or Playwright pages for the
  UI. The user checks only the real app and the canvas.
- Secrets stay in the Keychain, never in files or logs.
- When you report, list what you did **not** check, alongside what passed.
