---
type: spec
title: Design process and design system
status: developing
created: 2026-10-02
updated: 2026-10-03
tags:
  - distill
  - design
---

# Design process and design system

## Canvas first

The design canvas is the source of truth for what the app looks like and how
it behaves: https://claude.ai/artifact/VSqHFPZjcqY2bMqFEnPqpG

- Any change the user can see or feel (layout, sizes, window behavior, new
  states, new screens) is drawn on the canvas first and published. App code
  changes after the user confirms. (Since 2026-10-02 the user may say "build
  directly after the design is on the canvas"; then building follows the
  publish without a separate confirmation.)
- A pure bug fix that restores designed behavior can go straight to code;
  the canvas is updated afterwards if the fix adds visible states (example:
  the "answering…" rows in History).
- The canvas is organized by flow, one row per flow, and shows every state
  of every screen. A board that shows the app window must not contradict any
  other board.
- No local previews: no HTTP servers, browser pages or Playwright for design
  work. Boards are checked by offscreen rendering (WKWebView to PNG) or by
  reading the markup; the app is checked with `Distill --snapshot`.
- Built-app boards: `Distill --snapshot OUT --states` renders every screen
  state with a manifest; those renders go on the canvas next to the designs.

## The design as a schema (built 2026-10-03)

The canvas is generated from versioned files in `apps/distill/design/`;
boards are never edited by hand.

### Layers

| Layer | File | What it holds |
| --- | --- | --- |
| Tokens | `tokens.json` | Colours, type, button and pill sizes, radii, strokes. Generated from `Theme.swift` by `tokens.py`; never edited by hand. |
| Components | `components.json` + `components/<Name>.dc.html` | One entry per canvas component: `name` (= the Swift view), `swift` (file, or `null` when no view exists yet), `preview` size, `props` (name, type, default, options; `swift` when the Swift name differs, `"swift": false` + `why` when the view derives it, `swiftPending` when designed but not built), `board` (its states board) and `states` (name, prop values, hint size, caption). The template file holds the markup with `{{…}}` holes and the logic; `@@ICONS@@` / `@@SETTINGS_NAV@@` pull in `data/`. |
| Screens | `screens/actions.json` | `bases`: one per tab, regions (`header`, `toolbar`, `list`, `detail`, `overlay`, `bottom`) filled with component instances (`{"c": "ActionsToolbar", "props": {…}}`), template uses (`{"t": "header", "vars": {…}}`) or html. `states`: an id (= the snapshot state id), a base and an override, e.g. `{"toolbar.chips": ["Due: Today"], "overlay": {"FilterPanel": {"due": "Today"}}}`; never a copy. `boards`: ordered states with labels and captions. |
| Heights | `sizes.json` | Measured height of each generated board (`render.py --measure`). |

### Workflow

1. Edit the schema (a prop default, a template, a state override).
2. `python3 apps/distill/design/render.py OUT --canvas LIVE/canvas.json`
   (add `--measure` when heights may change). It prints the boards that
   changed and writes `OUT/canvas.json`: positions and component frame sizes
   stay as the user left them, heights update, new boards go at the end of
   their row.
3. The lead publishes the changed boards and `canvas.json`.
4. The user reviews on the canvas.
5. Build the Swift change; `make test` (or `python3
   apps/distill/design/test_design.py`) checks the mapping.
6. Render the snapshot states (`Distill --snapshot OUT --states`).

### Add a component

Add the entry to `components.json` (props in the Swift view's order and
names), write `components/<Name>.dc.html` (`<x-dc>` markup, then
`<script type="text/x-dc-logic">` returning the render values; `p` is the
props, `on(v, d)` reads a boolean), list its states and give it a `board`
(`file`, `title`, `heading`, `intro`, `width`, `cols`; `wrap` frames each
cell). A states board shared by several components lists them in
`board.components`; the others point at it with `board.file`. Render; the
new boards are appended to row 0.

### Add a state

Component state: append `{"name", "props", "size", "caption"}` to its
`states`. Screen state: append `{"id", "base", "label", "caption", "set"}`
to `screens/*.json` and put its id in a board's section. Use the id of the
matching `Distill --snapshot --states` render; the drift test lists screen
states without one (report only).

### Drift test

`design/test_design.py`, part of `make test`, fails when `tokens.json`
disagrees with Theme.swift, when a component's `struct` (or typealias) is
missing from its `swift` file, when a prop is not a parameter or stored
property of that struct (scoped to the struct body), when a
`swiftPending` prop exists in Swift (drop the mark), or when templates,
state props or boards don't match. It reports components without a Swift
view and screen states without a snapshot state.

`design/legacy/` holds the old scratchpad generators, retired board by
board (the Actions boards are next).

## Components (designed)

Shared parts are defined once and imported, not copied (user, 2026-10-02:
"after we update the menus we don't have to update the menu all over the
place"):

- Canvas-local shared components (`components/*.dc.html`, row "0 ·
  Components"), imported by every board with `<dc-import>`, each showing all
  its states side by side.
- Next: a Distill design system artifact (Design System type) with the
  tokens from `Theme.swift` at exact values and real components in one
  bundle (`window.Distill`), installed on the canvas and mounted by name in
  every board.

## One-to-one mapping to code (designed)

Every design-system component has the name of its Swift view and props equal
to that view's states (selected item, counts, loading, disabled, …). A table
here lists component → Swift file, and a test fails when a component has no
Swift view of that name or the reverse.

### Component ↔ Swift view

Canvas components (`components/*.dc.html` / `project/<Name>.dc.html`) and the
Swift view of the same name, in `clients/macos/Sources/Distill/`. Built
2026-10-02 for the rows below; `design/test_design.py` checks them (2026-10-03).

| Canvas component | Swift view | File |
| --- | --- | --- |
| PrimaryButton | `PrimaryButton` | Theme.swift |
| SoftButton | `SoftButton` | Theme.swift |
| IconButton | `IconButton(systemImage:size:tint:fill:help:)` (plus `iconSize`, `weight`, `label` to keep a call site's glyph and VoiceOver label) | Theme.swift |
| Pill | `Pill` | Theme.swift |
| Tile | `Tile` | Theme.swift |
| Segmented | `Segmented` | AskParts.swift |
| SegmentedPills | `SegmentedPills` = `Segmented` (typealias; one view, props options, selection, height, font, track, help) | ComposeComponents.swift |
| PillSwitch | `PillSwitch` | ComposeComponents.swift |
| CapsuleSwitch | `CapsuleSwitch` | AskParts.swift |
| LabelChip | `LabelChip` | ComposeComponents.swift |
| FilterChip | `FilterChip` | AskParts.swift |
| SourceChip | `SourceChip` (private) | SettingsSections.swift |
| ModelChip | `ModelChip` | AskParts.swift |
| DropdownButton | `DropdownButton` | ComposeComponents.swift |
| QuickSourceButton | `QuickSourceButton` | QuickNote.swift |
| MarkdownBarToggle | `MarkdownBarToggle` | MarkdownEditorBar.swift |
| SendButton | `SendButton` | AskParts.swift |
| LinkButton | `LinkButton` | AskParts.swift |

IconButton is round (fill and hover fill are circles, as on the canvas); the
hover fill is ink at 6%. Icon-only buttons in rows, cards and toolbars use it
instead of drawing their own. Not IconButton, by design: the clear buttons
inside search fields and FilterMenuChip (part of those components), the
Settings stepper and the image-remove button (shadowed discs), checkboxes,
the Markdown bar buttons, SendButton, and `Menu` labels (the ⋯ on Actions
type pages is a menu, not a button).
