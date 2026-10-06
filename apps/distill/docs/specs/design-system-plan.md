---
type: spec
title: Design system and canvas structure plan
status: designed
created: 2026-10-06
updated: 2026-10-06
tags:
  - distill
  - design
---

# Design system and canvas structure plan

A proposal, not built. It audits how Distill's design lives in Claude Design
today, records what was proved on private test artifacts on 2026-10-06, and
proposes a structure and a migration. Related: [design-process.md](design-process.md).

## The short answer

- **Pages work.** On the current Design type release (`1791299306-e8c1`), a
  canvas with explicit `pages`, per-board and per-note `page` keys and
  `launch.page` draws. That held for a small canvas and for all 141 real
  boards split over 7 pages, and for a board on one page importing a
  component on another. The 2026-10-06 blank canvas was not caused by using
  pages per the docs. Each page also has its own link (`#page-<id>`), which
  gives the owner a deep link per area.
- **A Design System artifact works.** A Design System holding Distill's
  tokens (from `Theme.swift`) and two real components (`PrimaryButton`,
  `Pill`) installs on a canvas, and boards mount the components by name.
- **A hidden component kit works too.** `.dc.html` files under
  `project/ds/<folder>/` are not boards, and a board can still `<dc-import>`
  them by a root path (`name="ds/kit/Chip2"`). The current 44 components can
  leave the canvas without a rewrite. This behaviour is not documented.
- **Recommended:** one *Distill* Design System (tokens + components), and
  one canvas per product area with a page per flow. Every board takes its
  colours from tokens. Each state becomes its own board instead of a
  2520 px sheet. `render.py` stays the only writer. Migrate in seven small
  steps (below).

## Evidence (test artifacts, all private)

| Test | Artifact | What it held | Result |
| --- | --- | --- | --- |
| A: pages, small | https://claude.ai/artifact/9GkGrDLDaXZaWDRgTAu2kU | 2 pages (Shell, Review), 2 boards each, a `title1` note per page with `page`, `launch.page` = review | Opened on Review with only its note and boards. On the first load the two frames stayed white until the canvas was clicked; then both drew. |
| B: pages + cross-page import | https://claude.ai/artifact/VKsyEjY1sv87vv8fvUWYEN | A, plus `Chip.dc.html` on page Shell, imported by a board on page Review | Drew without a click: "Imported from page Shell" chip shown inside Review one. With `launch.page` = shell, the Shell page showed Shell one, Shell two and the Chip board. Opening `…#page-39984a4260aa` showed Review whatever `launch.page` said. |
| B (later): hidden kit | same | `project/ds/kit/Chip2.dc.html` and `Nest.dc.html`, not in `boards` | `<dc-import name="ds/kit/Chip2">` drew; `name="Chip2"` (bare) drew an empty placeholder. Inside `ds/kit/Nest`, the bare `Chip2` failed and `ds/kit/Chip2` drew: import names resolve from `project/`, not from the importing file. Neither kit file appeared as a board on any page. |
| C: real boards on pages | https://claude.ai/artifact/D6uy69PjyLsb9ipxCj6M6Z | All 141 boards of the main canvas (read from it, unchanged) on 7 pages: 0 Components (84), 1 Capture & Queue (17), 2 Review (13), 3 Ask (3), 4 Actions (12), 5 Automations (6), 6 Settings & Shell (6); 19 row notes | Launch page Capture & Queue: a blank window (no toolbar) for about 40 s, then all 17 boards drew, with their Sidebar, Pill and button imports from page 0. Launch page Actions: toolbar after about 60 s, all boards drawn by about 90 s. |
| DS: tokens + components | https://claude.ai/artifact/QENafzc1iM5wYA3gKnMsmz | `tokens.json` (20 colours, 2 families, 6 type styles, 5 spacing, 2 radius, 4 size tokens), `components/bundle.js` (`window.Distill`: PrimaryButton, Pill), `bundle.css` on token variables, previews, README, cover | The page opened. The cover drew in Distill's colours from the tokens. No `tokens.css` was written to its files (`list` showed none); the page only generates it in the browser. |
| DS install | https://claude.ai/artifact/3dgqZT45pbx1QgYQ7zf6xb | `designSystems` record; `ds/distill/tokens.json`, `bundle.js` and `bundle.css` copied server side with `{artifact, path}`; a `tokens.css` written by hand; two boards using `<x-import component-from-global-scope="Distill.PrimaryButton" …>` | Both boards drew after a click on the canvas: four PrimaryButtons (regular, small, mini, disabled at 45%), five Pills (count, Ready with checkmark, Writing with spinner, small stroked Draft, dashed Not set), and a card built from token variables. Clicking Approve in Play was not verified: the test browser's clicks did not reach controls inside the editor. |

Viewer behaviour observed in these tests:

- Large canvases show a blank window with no toolbar for 40–60 s before
  anything draws. Splitting into pages did not make the first draw faster.
- Some loads left the frames white until the first click on the canvas.
- One tab crashed ("Error loading tab") 20 s after opening test A.
- Every board shows scrollbars, even when its root is exactly `w`×`h`.
- The page menu and sidebar did not respond to the test browser's clicks,
  so pages were switched with `launch.page` or a `#page-<id>` link.

What blanked `VSqHFPZjcqY2bMqFEnPqpG` is still open. Its failing index (one page
`distill` holding all 141 boards, `launch.page` = distill) is valid per the
docs, and test C shows the same boards draw on pages. The likeliest causes are
the long first draw read as "blank", or stale state in that artifact (the
decision log says it stayed blank after its index matched a working copy).
Neither is a reason to avoid pages.

## Audit against the Design type's guidance

### 1. One huge canvas

141 boards over about 75,000 × 76,000 px, 17 rows, one page. The canvas has no
table of contents, single boards can't be linked (the viewer rewrites the
hash), and the first draw takes 30 s or more. The type supports up to 40
pages per canvas and up to 512 files. A page per area with its own link solves
findability; separate canvases are what make each one load faster.

### 2. Components are boards

84 of 141 boards are row-0 component boards: 44 components plus 40 states
boards. The type renders every `.dc.html` outside `project/ds/` as a board
("EVERY `.dc.html` outside `project/ds/` shows, listed or not"), so any
component a screen imports must sit on the canvas. Both ways out were
proved: a real design system bundle mounted by name, or a hidden kit under
`project/ds/`.

### 3. No design system and no tokens on the canvas

`designSystems` is `[]`. `design/tokens.json` is extracted from
`Theme.swift`, but nothing on the canvas reads it. `render.py` and the
templates write literal values instead: the component templates hold 555 hex
literals (54 distinct), and the screen fragments under `screens/` hold 8,893
(70 distinct), against 20 colour tokens. Changing `Theme.primary` means
finding and changing `#1F6FEB` in hundreds of places. The Theme menu shows
bare hexes, and editing a colour on the canvas changes one element.

The type's `tokens.json` is a list (`{"tokens":[{"name","value","usage"}]}`);
ours is a name-to-value map that the Design System page cannot read. The
proof converted it.

### 4. Drift between canvas and Swift is checked by name only

`test_design.py` checks component and prop names, not values. Example:
the canvas Pill draws its small text at 10.5 px; `Theme.swift:250` uses 11
(`Theme.body(size == .small ? 11 : 12, .bold)`).

### 5. Boards are sheets, not artboards

Screen boards are 2520 px wide sheets of many app windows with captions; the
largest is `ScriptActions` at 2520 × 7428, and 15 boards are 4000 px or more
in one direction. The type wants one artboard per frame ("Multi-frame design
explorations are ARTBOARDS: put each frame in its own `.dc.html` entry"),
with option and rationale text in notes or the reply, not in the artboard. As
sheets, a state has no name strip, can't be selected or commented on its own,
and a change to one state rewrites a 150 KB file. The schema already has
317 states with ids (`screens/*.json`) that could each be a board.

### 6. Notes and titles

17 `title1` notes, one per flow, are the only navigation, and several are
whole sentences ("10 · Session continuity (when an AI session is gone,
Distill asks before using a new one)") that shrink to fit at 72 px.
Explanatory text lives inside boards as captions. The type intends `title1` for a row title of 72 px at most `maxW`
wide, and stickies for comments.

### 7. Interactive vs static

No board has `is_interactive`, and none uses `expand`. The app windows are
static mock states, which is right for a state catalogue. A few flows would
read better as one clickable board with state (approve → applying → done) and
the Play button. This is optional.

### 8. The render pipeline

`render.py` + schema + drift test is the right idea: boards are generated,
never hand-edited, and positions the owner changes are kept. What costs effort
today:

- Every UI change re-renders big sheets, and publishing them means sending
  hundreds of KB (3.5 MB of board source in total).
- Tokens are copied into templates, not referenced.
- 84 component boards must be placed and kept in row 0.
- Legacy generators (`design/legacy/`) still own boards the schema doesn't
  (Capture, Ask, Settings, Markdown and others).
- `drop_pages` in `render.py` now removes pages outright, which blocks the
  structure proposed here.

## Target structure

### The Distill Design System (one artifact)

A Design System artifact named **Distill**, namespace `Distill`, folder
`distill` on every canvas.

- `tokens.json`, generated from `Theme.swift` by `tokens.py`, in the type's
  list shape. It holds the 20 colours (named as in Swift: `window`, `panel`,
  `ink`, `primary`, `limeTint`, `limeInk`, …), the families `display` and
  `body`, type styles for each Theme size in use, spacing (button gap and
  padding, pill padding), radius (`radius-card` 18, `radius-capsule`) and
  size (button and pill heights, `iconButton` 26, `tile` 40). `vaultChips`
  becomes four aliased pairs.
- `tokens.css`, generated by `tokens.py` too, in the format the page
  compiles (`:root { --primary: #1F6FEB; … }`). The page doesn't write the
  file, and canvases need it for the components' stylesheet.
- `components/bundle.js` (`window.Distill`) and `bundle.css`: the shared
  components, each named as its Swift view and with its props, drawn with
  token variables only. Start with the most-imported (PrimaryButton,
  SoftButton, IconButton, Pill, Tile, LabelChip, FilterChip, SourceChip,
  DropdownButton, Segmented, PillSwitch, CapsuleSwitch, Sidebar,
  WindowShell). The states boards become `components/<Name>/preview.html`
  cards with a README taken from the `intro` text in `components.json`.
- `README.md`: the brand book (calm white windows, one blue action, tints
  with their inks), sources, and the Swift mapping table now in
  design-process.md.

### Area canvases (one per area, pages per flow)

Each canvas installs the Distill system, so boards mount its components by
name. Components not yet in the bundle go into a hidden kit under
`project/ds/distill-kit/` (proved), so no canvas carries component boards.

| Canvas | Page | Boards today (become one board per state) |
| --- | --- | --- |
| Distill · Capture & Queue | Queue | Main, MainEmpty, MainLoading, MainFolder, MainLabels, MainLabelGate, QueueItems, QueueRows, QueueLabelGate, InboxCleanup |
| | Capture | Capture, CaptureLoading, ComposeSizing, ImagesInline |
| | Quick access | Floating, QuickActions, QuickSizing |
| Distill · Review | Review | Review, ReviewChoose, ReviewLoading, ReviewProgress, ReviewStates |
| | Review queue | ReviewQueue, ReviewQueueRules |
| | Full reads and sessions | FullRead, SessionContinuity, HistoryJob |
| | Labels | LabelFlows, Notes, NotesLoading |
| Distill · Ask | Ask | Ask, AskLoading, History |
| Distill · Actions | Overview and routing | ActionsOverview, ActionsRouting |
| | To do | ActionsTodo |
| | Slack | ActionsSlack |
| | Jira | ActionsJira, ActionsJiraFields |
| | Confluence | ActionsConfluence |
| | History and Ask | ActionsHistory, ActionsAsk |
| | Context and summary | ActionContext, ActionSummary |
| | Buttons and scripts | ScriptActions |
| Distill · Automations | Collectors | Collectors, CollectorsScript, CollectorsScriptFiles |
| | Logs | LiveLog, CollectorsLog |
| | Activity | Activity |
| Distill · Settings & Shell | Settings | Settings, SettingsNav |
| | Shell | Panes, Loading, Markdown, AppIcon |

Row 0's 84 boards go to the Design System (as previews) and to the hidden kit.
The small review canvas (`9nRSxwhoygmEWAqyxKpy7e`) stays for one-off
proposals.

`docs/specs/design-process.md` keeps one table of canvas and page links (each
page by its `#page-<id>` link): the owner's index.

Why separate canvases and not only pages: test C shows pages fix
findability, not load time (40–90 s with everything in one artifact). With
components in the system and the kit, no board imports across canvases, so
splitting costs nothing.

### Naming and layout convention

- Canvas: `Distill · <Area>`. Page: the flow, in the app's words. Page ids:
  short kebab-case (`review-queue`); they never change, because links use
  them.
- Board file: `<Screen>-<state-id>.dc.html`, where the state id is the
  `Distill --snapshot --states` id where one exists (`ActionsJira-signin.dc.html`).
  Board `title`: the state's label as the app shows it ("Jira · not
  connected").
- One app window per board at the window's real size (the base `window`
  size in the schema). Cards and close-ups are their own boards at their own
  size.
- Layout per page: rows of one sub-flow, left to right in the order a person
  meets them, 80 px apart, rows 120 px apart, plus 300 px for a row title.
  A `title1` note per row (no text past `maxW`). Captions become stickies
  under the board, never text inside it.
- A built-app snapshot sits on the same page, right after its design board,
  titled `… (built)`.

## How the pipeline changes

`render.py` stays the only writer; the schema and the drift test stay.

1. `tokens.py` writes three files: `design/tokens.json` (as now, for the
   drift test), `design/ds/tokens.json` (the list shape) and
   `design/ds/tokens.css`.
2. Templates and fragments reference tokens: `var(--primary)` instead of
   `#1F6FEB`. A one-off rewrite maps each exact hex that equals a token to its
   variable; the drift test then fails on any hex in a template that matches
   a token, and reports hex values that match none, as a list of colours
   still to name.
3. Components: `components.json` stays the source. A new
   `design/ds/build.py` writes `components/bundle.js` from each component's
   React port (`design/ds/src/<Name>.js`, plain `React.createElement`, no
   build step), `bundle.css`, `index.d.ts` from the props, and a
   `preview.html` per component from its `states`. Until a component is
   ported, `render.py` writes its template to `project/ds/distill-kit/<Name>.dc.html`
   and imports it as `ds/distill-kit/<Name>`.
4. Screens: one board per state (`frame` sections become boards; `card`
   sections become small boards). `screens/*.json` gains `canvas` and `page`
   per section, and `render.py --canvas <area>` writes that canvas's
   `canvas.json` with `pages`. `drop_pages` goes; a test checks each board's
   `page` is a listed page id and each import resolves.
5. Publishing: `render.py` prints, per canvas, only the boards that changed.
   A token or component change publishes the system and re-copies its files
   onto each canvas (`{artifact, path}` entries: no board files change). A
   screen change publishes a few small state boards.
6. Drift test, added: token values in `ds/tokens.json` equal `Theme.swift`;
   each bundled component's props equal the Swift view's.

What a UI update costs afterwards:

| Change | Today | After |
| --- | --- | --- |
| A colour, size or radius in Theme.swift | Find the hex or number in templates and fragments; re-render and publish many large boards | `tokens.py`; publish the system and copy `tokens.css` to the canvases. No board changes |
| A component's look (Pill, buttons, …) | Edit the template; re-render every board that imports it; publish them | Edit its source; publish the system; copy the bundle to the canvases |
| One screen state | Re-render and publish a 100–170 KB sheet | Re-render and publish one small board |
| Finding a design | Pan a 75,000 px canvas | Open the area canvas from the index, then pick the page |

## Migration (each step verifiable, nothing lost)

Before any step: read every board and `canvas.json` from the live canvas into
a dated scratch folder and commit nothing from it. The main canvas is the
rollback until step 7.

1. **Pages on the current canvas (no file changes).** Add the 7 pages of
   test C to the main canvas's `canvas.json`, set `page` on boards and notes,
   and repack rows per page. In `render.py`, replace `drop_pages` with
   page-aware placement. Check: each page's link opens that page with all its
   boards drawn; the board count stays 141.
2. **Create the Distill Design System.** Tokens only plus README and cover,
   generated by `tokens.py`. Check: its Colors, Typography, Spacing and
   Radius sections list every token; `test_design.py` checks the values
   against Theme.swift.
3. **Tokens in templates.** Rewrite hexes to `var(--…)`, link
   `ds/distill/tokens.css` in every board head, and install the system on
   the main canvas. Check: a pixel diff of every board rendered before and
   after (the offscreen WKWebView renderer, `tools/snap.swift`) shows no
   change; then change one token on a test copy and see every board follow.
4. **Hidden kit.** Move the 44 component templates to
   `project/ds/distill-kit/`, rewrite imports to `ds/distill-kit/<Name>`, and
   keep the 40 states boards on page 0 until step 5. Check: every board renders
   byte-identical output (offscreen); the canvas loses 44 boards.
5. **Bundle the shared components,** a few per step, most-imported first.
   Each moves from the kit to `bundle.js` plus a preview card, and its states
   board leaves the canvas. Check per component: offscreen renders of its
   states before and after match within anti-aliasing; the drift test passes.
6. **One board per state,** one area at a time, starting with Actions
   (103 states). Check: each old sheet's frames all have a board; the owner
   reviews the page.
7. **Split into area canvases.** Create each `Distill · <Area>` canvas, install
   the system, publish its pages, and add its links to design-process.md.
   Check: each loads in under 15 s; every state id in `screens/*.json`
   maps to exactly one board on exactly one canvas (a test). Then mark the
   main canvas "archived" in its title and stop publishing to it. Never
   delete it.

Steps 1–3 already give the owner pages with links, a real design system and
one-place token changes. Steps 4–7 can wait.

## Risks

- **Viewer bugs.** We saw a 40–90 s blank before the first draw, frames that
  stayed white until a click, one tab crash, a canvas
  (`VSqHFPZjcqY2bMqFEnPqpG`) that stayed blank for good, and a `"bool"` prop
  editor that was invalid. Mitigations: small canvases, each step on a test
  copy first, and the main canvas kept until the area canvases are trusted.
- **Undocumented behaviour.** Root-path `<dc-import name="ds/…">` and the hidden kit
  work but are not in the type's docs, so a type release could change them.
  The bundle (documented) is the long-term home, and the kit is a bridge.
- **The page doesn't write `tokens.css`.** Canvases need it for
  `bundle.css`. We generate it ourselves in the format the type documents. If
  the page starts writing its own, compare the two and drop ours.
- **Porting effort.** 44 components from `x-dc` templates to React; the
  larger ones (Sidebar, FilterPanel, QueueRowView, ScriptEditor) are real
  work. Port by import count and leave rare ones in the kit.
- **Installed copies go stale.** Each canvas holds a copy of the system,
  pinned by `version`. `render.py` must re-copy after each system publish; a
  test compares each canvas's `designSystems[].version` with the system's.
- **Editing in place.** Boards mounting `x-import` components edit only in
  source, not in the properties panel. Markup around them stays editable.
- **More boards.** One board per state turns 57 screen boards into about
  317 state boards across six canvases (largest: Actions, about 110). That
  is within the 512-file cap, and each board is small.
- **Owner process.** The owner checks only the real app and the canvas. Each
  migration step ends with a canvas link and a one-line "what moved"; no
  local previews.

## Not done here

`decisions.md` (the pages finding reverses part of the 2026-10-06 decision)
and the spec `index.md` still need an entry for this plan once the owner
picks a direction.
