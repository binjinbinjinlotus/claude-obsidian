---
type: spec
title: Resizable panes
status: designed
created: 2026-10-05
updated: 2026-10-05
tags:
  - distill
  - macos
  - layout
---

# Resizable panes

The owner asked for this on 2026-10-05: "for any UI with the open left section, I am able
to change the size. We should enable to change the size of the right and left
section by drag."

Every screen with two or three columns gets a handle on the boundary between
them. You drag the handle to resize the columns, and double-click it to go back
to the automatic width. Widths are remembered per screen across restarts.
Nothing looks different until you drag: the automatic widths are today's widths,
and today's narrow-window rules stay.

Canvas: row "13 · Resizable panes", board **Panes** (frames A–F and two cards),
plus the component **PaneHandle** and its states board in row 0.

## Inventory: every split screen (2026-10-05)

None of these used `HSplitView`, `NavigationSplitView` or `NSSplitView`. Each
was an `HStack` with a fixed or computed frame width.

| Screen | Columns | Built today as | Column you drag | Automatic width | Min – max | The other column keeps | Narrow-window rule (kept) |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Main window (every section) | sidebar \| screen | `Sidebar` `.frame(width: 220)`, a 1 pt edge where the panel meets white | sidebar | 220 | 200 – 320 | screen 580 | none (window min 900) |
| Review | details \| Conversation | `JobDetailView`: `talk = min(300, max(220, inner − 360))`, a 24 pt gap | Conversation (right) | auto 220 – 300 | 220 – 520 | details 360 | below 780 pt the Conversation moves behind **Conversation · N** |
| History → Jobs | list \| details \| Conversation | list `.frame(width: 320)` + `Divider`; `JobDetailView(collapsesConversation: false)` | list (left) and Conversation (right) | 320 · auto | 240 – 480 · 220 – 520 | details 360 | none (Conversation never collapses here) |
| History → Actions | list \| detail | `ActionsHistoryView` list `.frame(width: 340)` + `Divider` | list (left) | 340 | 260 – 520 | detail 360 | none |
| History → Activity | list \| detail | `ActivityScreen` detail `.frame(width: 400)` + 1 pt line | detail (right) | 400 | 320 – 640 | list 320 | below 920 pt the detail opens in place |
| Actions → To do | list \| detail | `TodoScreen` detail `.frame(width: 330)` + 1 pt line | detail (right) | 330 | 280 – 560 | list 320 | none |
| Actions → Slack, Jira, Confluence | list \| detail | `ActionsTypeScreen`: `min(330, max(250, 42%))`, a 14 pt gap | list (left), one width per type | auto 250 – 330 | 240 – 480 | detail 360 | none |
| Collectors | list \| detail | `CollectorsScreen`: 300, or 240 below 760 pt; a 24 pt gap | list (left) | auto 300 / 240 | 220 – 460 | detail 360 | below 760 pt an open run log takes the window |
| Settings window | nav \| page | `SettingsSectionNav` `.frame(width: 236)` | nav (left) | 236 | 200 – 320 | page 480 | none (window min 820) |

Ask, Write a note, Labels and Queue have one column, so there is nothing to
drag. Ask's "Recent questions" live in the sidebar, which resizes with the
sidebar.

## Behaviour

- **Handle.** A 9 pt hit area centred on the boundary. It is an overlay and
  takes no layout width, so no column moves when it appears.
  - Idle: it draws what the screen draws today. That is the 1 pt border line
    where one exists, and nothing where the columns sit apart in a gap
    (Review, the Actions types, Collectors).
- **Hover.** The resize cursor (↔) shows, the line darkens to `#D9D6CF`, and a
  4 × 32 pt grip appears. There is no delay.
- **Dragging.** The line and the grip turn primary blue and are 2 pt wide. Both
  columns follow the pointer.
  - The width is the start width plus the translation, taken in the window's
    coordinate space.
  - It is saved once, when you let go.
- **At a limit.** The limit is the column's min or max, or the other column's
  min. The line and the grip turn peach ink, and the cursor turns one-way (←
  or →). Dragging further does nothing.
- **Double-click.** Puts the automatic width back, animated over 0.2 s, and
  forgets the saved width.
- **VoiceOver.** The handle is an adjustable element labelled "Resize
  <column>". Increment and decrement move it by 20 pt.

## Limits and narrow windows

- The width shown is `clamp(saved ?? automatic, min, min(max, container −
  otherMin − fixed))`, where "fixed" is the padding and gaps around the
  columns. If even the min does not fit, the column gets the min, and the
  existing narrow rule takes over first where one exists.
- **Live window resize clamps only for display.** It never writes the saved
  width, so your width comes back when the window grows again. Only a drag
  writes.
- The narrow thresholds (Review 780, Activity 920, Collectors 760) are
  measured on the container width, as today. They never depend on the saved
  width.
- In History → Jobs, the list and the Conversation share one container. The
  list is clamped first, then the Conversation, so the details always keep
  360.

## Collapse

Dragging never hides a column. Hiding stays with the narrow-window rules.

## Storage

- Widths live in Distill's own UI preferences (`UserDefaults`, via
  `@AppStorage`), the same place as `distill.addMode` and `distill.todo.sort`.
- One `Double` per key:
  - `distill.pane.sidebar`
  - `distill.pane.review.conversation`
  - `distill.pane.history.list`
  - `distill.pane.history.conversation`
  - `distill.pane.history.actions`
  - `distill.pane.activity.detail`
  - `distill.pane.todo.detail`
  - `distill.pane.actions.<type id>.list`
  - `distill.pane.collectors.list`
  - `distill.pane.settings.nav`
- A missing key, 0, or a value that is not finite means the automatic width.
- Nothing goes in `settings.json`, the core does not change, and no schema
  migration is needed.

## Mechanism

**Choice:** one SwiftUI modifier, `.paneWidth(_:)`, in
`clients/macos/Sources/Distill/PaneSplit.swift`. It replaces each
`.frame(width: N)` on the column you drag. It sets the frame and overlays a
`PaneHandle` on the column's inner edge (trailing for a left column, leading
for a right one). It reads and writes the `@AppStorage` key. A `PaneSpec`
holds the key, the min, the max, the other column's min, the fixed width and
the automatic width. The pure function `PaneLayout.width(...)` does the
clamping and is unit-tested.

**Rejected alternatives:**

- **`NSSplitView` through a representable.**
  - Snapshots render with `ImageRenderer`, which draws AppKit views as a
    placeholder, so every split screen would turn grey in `--snapshot`.
  - It would replace the SwiftUI `HStack`s whose `GeometryReader` narrow rules
    the screens depend on.
  - Its autosave stores frame strings, not one width per column.
  - It hosts each column in its own `NSHostingView`, which breaks environment
    objects, popovers and `zIndex` across columns.
- **`HSplitView`.** It is AppKit-backed too, with the same snapshot
  placeholder. It gives no styling of the divider, no per-column max, no
  double-click reset and no persistence.
- **`NavigationSplitView`.** It is built for sidebar navigation, with its own
  toolbar and collapse behaviour. It does not fit list \| detail inside a
  screen or the Review Conversation.

**Details:**

- The cursor uses `NSCursor` push and pop on hover. On macOS 14 there is no
  `.pointerStyle`.
- The cursor is popped on drag end and when the handle disappears.
- In snapshot mode the handle draws its idle look and attaches no hover or
  drag.
- `DragGesture(minimumDistance: 1, coordinateSpace: .global)` leaves
  double-clicks to the tap gesture.

## Snapshots and tests

- Snapshot renders read `@AppStorage` from the in-memory registration domain.
  `SnapshotStates.baseDefaults` sets every pane key to 0 (automatic), so a
  width from one state never leaks into the next. Two states render a dragged
  width (`review-pane-dragged`, `history-panes-dragged`).
- `PaneLayoutTests` (DistillTests) cover:
  - the clamp to min, max and the other column's min;
  - automatic for a missing, zero or non-finite saved value;
  - a narrow container;
  - the drag sign for a left or right column;
  - a window resize that never writes.
