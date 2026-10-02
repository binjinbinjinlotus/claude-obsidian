---
type: spec
title: Decisions
status: built
created: 2026-10-02
updated: 2026-10-02
tags:
  - distill
  - decisions
---

# Decisions

Newest first. Each entry: what was decided, why, and where it lives. Add an
entry in the same change that makes a decision; never rewrite an old one —
supersede it with a new entry.

## 2026-10-02

- **Design system with components mapped one-to-one to Swift views.** Shared
  parts (sidebar, window shells, style bar, buttons, chips) are defined once
  and imported on the canvas; a Distill design system artifact follows, with
  each component named after its Swift view and props equal to its states.
  Why: changing a menu must not mean editing every board. → [design-process](design-process.md)
- **Pages with more than 2 tabs use sidebar sub-items** instead of a tab bar
  (Actions, History, Labels). Why: the tab bar was too crowded. → [actions](actions.md), [app-shell](app-shell.md)
- **Specs and this log are updated with every feature and decision.** Why:
  user request. → [index](index.md)
- **Actions** (to-dos and action types from notes and Ask answers). Decided
  with the design:
  - Types and handlers are registry data, so Email or Send in Slack can be
    added without changing the contract.
  - Confirm before adding is ON by default for both notes and Ask (user: "it
    should default ask the user to confirm first"; configurable per source).
    This replaces the earlier "extract automatically" for notes.
  - Actions are found after Approve & apply, as the last batch step.
  - Jira and Confluence items are created only on the user's click; drafts
    may be written on finding (default) or on request.
  - Improve after edit uses Sonnet by default (configurable); to-dos get no
    improve pass. Each type has a default draft prompt and improve prompt,
    editable with Reset to default.
  - Copying a Slack message isn't sending: **Mark as sent** ends it.
  - Atlassian: one connection for Jira and Confluence; API token in the
    Keychain, opened via the browser (OAuth needs a client secret we can't ship).
  - Status of created items: manual Refresh only for now.
  - History keeps removed/done/sent actions 90 days (configurable).
  → [actions](actions.md)
- **Settings get section navigation and search.** Why: too many settings to
  scroll. → [actions](actions.md), canvas SettingsNav
- **Quick windows open a third bigger (560 × 214) and start fresh after
  close**, centered; a dragged size is still kept as the opening size; a quick
  ask still answering keeps going and lands in History. → [quick-actions](quick-actions.md)
- **Canvas first, then build.** Every visible change goes to the canvas
  before code; the user may waive the separate confirmation per request.
  → [design-process](design-process.md)
- **User data is permanent.** Updates replace only the app bundle; backups
  before every update; schema changes are additive; unreadable files are set
  aside, never overwritten. → [user-data](user-data.md)
- **New chat never discards a running question.** It moves to the background
  and lands in History; only Stop stops it. → [ask](ask.md)
- **Images stay inside the text** (no Keep / Extract switch). Hover →
  Extract content replaces the image with its text in place (⌘Z restores).
  "Text from images" defaults to Claude Code · Haiku · Low. → [notes-composer](notes-composer.md), [markdown-editing](markdown-editing.md)
- **Quick ask's model/filter row and the quick note's source sit at the
  bottom**, above the footer; extra height goes to the content. → [quick-actions](quick-actions.md)
- **Quick windows handle ⌘X/C/V/A/Z themselves** (non-activating panels never
  reach the Edit menu). → [quick-actions](quick-actions.md)
- **Queue shows one row per note** (its manifest and images are members);
  "still changing" marks files modified after the core first saw them; the
  flask and sidebar counts equal the visible rows. → [queue-and-batching](queue-and-batching.md)
- **Times are clock times, never ticking counters** ("Ready at 3:14 AM",
  "Asked today at 3:40 AM"). Jobs: "Finished at" for success, "Ended at" for
  failed or cancelled (user: keep the split). → [queue-and-batching](queue-and-batching.md), [app-shell](app-shell.md)
- **Markdown in every text input**, with a style bar. → [markdown-editing](markdown-editing.md)
- **Quick windows: centered, close button, resizable, grow downward and
  scroll only at the screen limit; no scroll-bar strips.** → [quick-actions](quick-actions.md)
- **Settle wait defaults to 10 minutes** (configurable). → [queue-and-batching](queue-and-batching.md)
- **Loading states on every screen that waits for AI.** → [app-shell](app-shell.md)
- **No local previews** (no HTTP servers, browser pages or Playwright); the
  user checks only the real app and the canvas. → [design-process](design-process.md)

## Earlier (2026-10-01)

- **Labels**: the Labels review screen replaces Notes ("don't duplicate
  Obsidian"); notes written in the app wait for the user's confirmation;
  queue-folder files get AI labels marked unconfirmed; the CLI returns
  suggestions with a request ID and falls back to AI labels. Ask filters:
  Any/All labels (configurable default), include unconfirmed (default on).
  → [labels-and-sources](labels-and-sources.md), [ask](ask.md)
- **Ask history kept 10 days**, configurable, pinned chats kept. → [ask](ask.md)
- **Agents cannot approve vault changes**: no approve/confirm command in the
  CLI or plugin. → [approval-and-review](approval-and-review.md)
- **One Node + TypeScript core owns all state**; the CLI, the agent plugin
  and the macOS app are clients of its local API. → [architecture](architecture.md)
