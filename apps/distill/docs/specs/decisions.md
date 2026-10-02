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

- **Fresh quick note has no source** (shows "+ Source"), even though Write a
  note remembers the last source. Clicking the flask while its green ring
  shows (a quick ask still answering) opens that chat on the Ask screen.
  → [quick-actions](quick-actions.md), [floating-icon](floating-icon.md)
- **Actions core (core-actions).** Decided while building:
  - `historyDays <= 0` keeps action History forever (Settings "Forever"); the
    decoder does not clamp it.
  - `dismissActions` doubles as Undo for items added without confirmation,
    when they are untouched since found (only found / drafted events): they
    become `dismissed`, with no History entry. No separate method.
  - Route table as in [actions](actions.md) → API. A failed handler (Jira 400,
    not connected, offline) returns 200 with the item and `error` set; the
    draft is never lost to an HTTP error.
  - The action tasks (`actionFind`, `actionDraft`, `actionImprove`) never
    block batching; a broken runner shows as a failed "Finding actions" step.
    Why: actions are optional after the apply; ingest must not stop for them.
  - A batch is searched once (`processedJobs` in actions.json, recorded before
    the model runs), so a restart or a repeated job event never finds twice.
  - A user-edited prompt never loses the item context: it is always appended
    after the instructions, with the note text wrapped as data.
  - Atlassian: the email and API token go to the Keychain; the site, display
    name and account id to `<state>/connections.json` (no secrets).
    `listConnections` never reaches the network; a 401 marks it expired.
  - An interrupted `creating` comes back `ready` with an error asking the
    user to check Jira / Confluence before retrying (it may have been
    created). Why: never create twice silently.
  - Dedupe goes beyond live items for quotes: a line already handled (done,
    removed, sent, dismissed) is never suggested again when a later batch
    rewrites the same page (same note and quote, or a quote of 24+ characters
    from any page). The title rule still counts live items only, so a
    recurring to-do can come back. Within one run only the title rule applies
    (one sentence can hold a to-do and a message). Why: a compounding wiki
    rewrites pages; dismissed items kept coming back.
  - `restoreAction` is the one Undo: removed → where it was; done → open /
    created; sent by Mark as sent → ready; sent by Send to → back, and the
    item it became is deleted while untouched (else `invalid_state`);
    dismissed → pending (or where an auto-added item was).
  - "Try again" for a failed find: `POST /v1/jobs/:id/actions/find`
    (`findJobActions`, an engine extra like `deleteJob`).
  - Models (lead): finding `findSelection` → `taskDefaults.actionFind` →
    Claude Code · Sonnet · medium; drafts / improve per type
    `draftSelection` / `improveSelection` → `taskDefaults.actionDraft` /
    `actionImprove` → Claude Code · Sonnet. Settings writes only
    `actionPreferences` for these.
  → [actions](actions.md)
- **Design follow-ups (lead, from the canvas audit):** the flask hover menu
  gets an "Actions N" entry, while the flask badge stays queue-only. Every
  elapsed timer becomes a clock time ("started at 3:12 PM"), including "Still
  working". The Ask Gap callout shows only when the gap did not become an
  action. The Settings board is split into General / AI / Actions &
  connections windows. Job.actionsFound records what a batch found.
  → [actions](actions.md), [app-shell](app-shell.md)
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
