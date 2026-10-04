---
name: distill-macos-e2e
description: End-to-end testing of the Distill macOS app (apps/distill/clients/macos) and its core. A framework for testing it, plus the gaps earlier AI test passes missed. It is not a complete guide; extend it with your own judgement. Use it before saying a Distill UI or behaviour change is tested, before reinstalling for the user, or when asked to e2e test, verify or QA the Mac app.
---

# Distill macOS e2e testing

## How to read this skill

This is a **frame, not a script.** It gives:

1. a framework for an e2e pass: the phases and the tools you have;
2. the **known gaps**: places where earlier AI passes said "verified" and the
   user then found the bug in the real app within minutes.

It is **not a complete guide.** You are expected to:

- design the specific cases for the change in front of you;
- add the checks any careful macOS QA engineer would run, whether or not they
  are listed here. Examples: accessibility, dark mode, multiple displays,
  Retina, slow or failed network, the first launch, a large data set,
  concurrent edits from the CLI;
- go past the known gaps. They are reminders of what got forgotten, not the
  edge of what to test.

When a new miss turns up (you find it, or the user does), add it to
**Known gaps**: one item, what was missed, and why the test didn't see it.

## The framework

Work through these phases. Decide yourself how deep each one goes for the
change at hand.

### 1. Scope from the design
- The design canvas is the spec:
  https://claude.ai/artifact/VSqHFPZjcqY2bMqFEnPqpG.
- Read the boards and states your change touches, and the specs under
  `apps/distill/docs/specs/`. In particular, `design-process.md` maps each
  canvas component to its Swift view.
- List the states you will check before you start, including empty, error,
  loading, disconnected and long-content states, even when the canvas doesn't
  draw them.

### 2. An isolated setup
- **Never** use the user's real vault, or the real
  `~/Library/Application Support/Distill`.
- Make a throwaway vault and a temp state dir. Every layer honours
  `DISTILL_STATE_DIR`:
  - the core launcher (`DistillKit/CoreLauncher.swift`);
  - the CLI (`cli/src/cli.ts`);
  - the snapshot renderer (`--state-dir`).
- Seed realistic state:
  - `distill note add`, `distill actions add`, `distill ask` against a core on
    the temp dir;
  - `node --import tsx apps/distill/core/src/dev/run-once.ts --vault V --state-dir T`
    for a headless batch.
  - Prefer real-shaped data, with old fields and empty defaults, over fixtures
    that set every field.

### 3. Build and the automated layers
- From the distill workspace: TypeScript typecheck with 0 `error TS`, then
  `npm test` for the core and CLI.
- In `clients/macos`: `swift build` and `swift test`. Run the suite more than
  once after touching async code.
- Snapshots: `Distill --snapshot OUT --state-dir T --states`.
  `DISTILL_STATES_ONLY=<prefix>` limits the run to one area. **Open** the PNGs
  for every state you changed and compare them with the canvas.

### 4. The real app
Snapshots and unit tests are not the app (see below). Exercise the built app
itself:

- **Launch it on the temp state.** Run
  `DISTILL_STATE_DIR=T build/Distill.app/Contents/MacOS/Distill`. Stop the
  installed app first, because both use the bundle id
  `com.claude-obsidian.distill`.
- **Drive it.** Choose your own means:
  - keyboard and menu actions through `osascript` / System Events, if
    accessibility is granted;
  - the CLI, to change state underneath the UI;
  - `screencapture -l <windowid>`, to capture real windows at real sizes.
- **Vary the window.** Check the minimum width, about 890 pt (the user's
  usual width), and full screen.
- Check every window type the change touches: the main window, Settings, the
  quick ask and quick note panels, and the flask.

### 5. Install for the user
- Run `apps/distill/clients/macos/scripts/distill.sh update`. It backs up,
  runs the tests, installs and compares data counts. Read the "Your data is
  intact: …" line; treat any WARNING as a failure.
- Then run `distill.sh core-stop`, and confirm with `distill.sh status` that
  the core has a new PID.

### 6. Report
Say what passed, with evidence (test counts, the PNGs or screenshots you
opened). Also say **what you did not check, and why.** "Rendered" is not
"looked at", and "tested" without a list of what was left out is not a claim
the user can trust.

## Why tests pass and the app is still broken

Most misses had one cause: **the test exercised something other than what the
user runs.**

- **Snapshots render one roomy fixed size**, draw popovers in place, and use
  fixture data. The user runs a ~890 pt window with real popovers and their
  own data.
- **A view-level test is not the window the view lives in.** A test that
  sends an action to a window that isn't key passed, while the real panel
  ignored the keys.
- **After a reinstall, the old core keeps running** until it is stopped, so
  the new UI talks to the old core.
- **One pass rendered 248 PNGs and opened 16.**

## Known gaps

### Layout and size
- **Narrow windows.** A row wider than the window didn't clip on the right. It
  widened the whole screen, centred it, and cut off the left edge, so the To do
  title and search field were gone. A quick wrap fixed the cut-off but looked
  bad, so judge the result by eye, not only that nothing is cut off.
- **Long content.** Controls meant to stay pinned at the bottom (the model row,
  the source picker in quick windows) scrolled away when the text got long.
  Test with long, multi-line text and with images inside the text.
- **Empty states combined with error states.** The canvas drew "not connected"
  inside an item card. With no items there was no card, so the user had no way
  to connect.

### Windows and focus
- **Quick windows are non-activating `NSPanel`s.** ⌘C, ⌘V, ⌘X, ⌘A and ⌘Z did
  nothing there, though they worked in the main window. The unit test passed
  because `NSApp.sendAction` went to a window that wasn't key.
- **Close means fresh.** A quick window reopened with the old draft and
  source. Check close → reopen for both quick windows, including closing in
  the middle of a run.

### Work in progress vs. navigation
- **Leaving mid-request.** Clicking New chat while an answer was streaming
  lost the question. For every long call (Ask, draft, improve, extract image
  text, batch), try navigating away and closing the window while it runs.
  Then check that the result arrives and appears in History.
- **Quitting mid-request.** A new chat's first question is lost if the app or
  core quits before the answer. This is still open; don't report it as fixed.
- **Leaving a screen can delete data.** With Keep history off, leaving Ask
  deletes the chat. "Open" on an item found in Ask leaves Ask, so that item's
  chat link goes dead.

### Undo, History and lifecycle
- **Undo must reach the designed end state.** After "Add all", Undo got a 409
  from the core, and the client quietly fell back to Remove. The items landed
  in History as Removed instead of disappearing. Check where the item ends up
  (the list, History, or gone), and look for fallbacks that hide errors.
- **Bulk actions.** Completing several items showed one toast per item, and
  Undo restored only the last one.
- **Automatic vs. by-hand paths.** "Already in …" duplicates showed after a
  by-hand detect, but never after the automatic run following an answer.

### Install, data and the core
- **Reinstall data safety.** History, settings, chats and actions must survive
  every reinstall. `update` checks the counts; read its output.
- **Stale core.** Without `core-stop`, the new UI runs against the old core, so
  routes are missing (501) and you see "Update the Distill core" states.
- **Flaky crashes block installs.** "Attempted to read an unowned reference but
  object … was already destroyed": a `Task` outlived its `AppModel`, and the
  installer's test run failed on it. One passing run proves little.
- **Real-shaped state.** The user's `settings.json` has `taskDefaults: {}`.
  Fixtures that set everything never take the default path.

### Design parity
- **Compare state by state, wording included.** For example: "Mark done" vs
  "Complete", "Finished at" vs "Ended at", and a Connect now button that was on
  the canvas and missing in the app.
- **Disabled is not tested.** "To-do from selected text" ships disabled,
  because a SwiftUI `Text` selection can't be read. Report it as not built.
- **Keyboard and selection.** ⌘A select-all and ⇧-click range selection were
  missing in lists. Try ⌘N, Esc, ⏎ and Tab in every new list or editor.

## Boundaries
- Use throwaway vaults and a temp `DISTILL_STATE_DIR` only. Agents never
  approve vault changes.
- Don't start local HTTP servers, browser previews or Playwright pages for
  the UI. The user checks the real app and the canvas.
- Secrets stay in the Keychain, never in files, logs or screenshots.
- UI changes go to the canvas before code. If testing turns up a design gap,
  raise it; don't patch the UI past the design.
