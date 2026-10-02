---
type: spec
title: Design process and design system
status: developing
created: 2026-10-02
updated: 2026-10-02
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
