---
type: spec
title: Decisions
status: built
created: 2026-10-02
updated: 2026-10-04
tags:
  - distill
  - decisions
---

# Decisions

Newest first. Each entry: what was decided, why, and where it lives. Add an
entry in the same change that makes a decision; never rewrite an old one —
supersede it with a new entry.

## 2026-10-04

- **Collectors (designed, not built): defaults chosen for the open
  questions.** Spec: [Collectors](collectors.md). Canvas: row "7 ·
  Collectors" (Collectors, CollectorsScript) and the queue path on Queue
  (Main, MainLoading, MainEmpty). These are the defaults; the user can
  overturn any of them.
  - **Sidebar item, no Settings section.** Collectors sits under Queue
    because it feeds the queue. Collectors have runs and errors, so they
    are not preferences, and editing them in two places would drift.
  - **The list is global, with a target vault on each collector.** It
    defaults to the active vault. This is still open in the spec.
  - **Folder always moves (never copies).** It skips hidden files,
    subfolders, and files changed within the settle delay (the same 10
    minutes as batching). On a name clash it adds " 2" and never
    overwrites.
  - **Dedupe is by content.** The vault ledger is keyed by sha256, with
    path, size and mtime as a shortcut that skips hashing. A file whose
    content was collected before is skipped and stays in the source
    folder, whatever its name. Same path with new content is collected
    again. The ledger outlives the collector.
  - **One schedule model: 5-field cron in local time; presets are
    shorthands.** The cron is always shown next to the preset. A missed
    run catches up once, a tick that overlaps a running run is skipped,
    and at most 2 collectors run at once.
  - **Script contract.** The script gets `$1` (vault) and `$2` (queue
    folder) plus `DISTILL_VAULT` and `DISTILL_QUEUE_DIR`. It runs in a
    fresh temporary working folder with stdin closed. The timeout is 5
    minutes by default and 1 hour at most; Distill sends SIGTERM, then
    SIGKILL 10 s later. Exit 0 is success. Files a failed or timed-out run
    wrote stay in the queue.
  - **Consent is bound to the script's sha256.** The core checks the hash
    before every run. A changed file or a saved inline edit pauses the
    collector until the user allows the new version. No sandbox is
    promised. Scripts never run during note processing.
  - **Run history lives in the collector, not in History.** It is kept for
    30 days or the last 200 runs, with the last 64 KB of stdout and
    stderr. History → Jobs keeps showing the batches, and queue rows name
    the collector. There is no notification on success; a macOS
    notification is sent only on the first failure after a success.
  - **The queue path on Queue is shown with `~`.** Copy copies the
    absolute path, and the hover shows it. The Folder default source is
    `~/Distill Inbox`, and Distill creates it on first save.
  - **API and contract are proposed only.** The lead owns `contracts.ts`.
- **Design schema: page boards.** Main and MainLoading moved from
  `legacy/gen_audit.py` into `design/screens/queue.json`. They are a new
  "page" board kind (one window, the document wrapper and the `sc-for`
  script kept verbatim) and were imported byte for byte with
  `tools/import_board.py --page`. `gen_audit.py` must no longer run over
  them. A screen file can add its canvas row title (`rowNote`), and row
  lists can use a row component other than ActionRow.

- **Settings shows one page per section, matching the canvas; the group
  pages were a deviation.** The SettingsNav board draws each nav item as its
  own page (To-do defaults and Connections each fill the page alone), but the
  app rendered three long group pages (General, AI, Actions) and scrolled to
  the section, so the view showed the end of the previous section and the
  start of the next, and the remembered position was shared per group. Now
  each section is a page with its own scroll view: its title and note as the
  header, then only its content; no group header. Advanced stays at the end
  of AI runners (most of it configures how the Claude Code runner and the
  core start; its search entry already pointed there). Supersedes the scroll
  memory entry below in two points: an unvisited page opens at its top (not
  at a heading on a shared page), and "Open Actions ›" now counts as a deep
  link (top of Actions) rather than a nav pick. Search results land on the
  matched row where there is one; every search entry is checked to have its
  row. → [vaults-and-settings](vaults-and-settings.md#window-sections-and-search)
- **Settings fits narrow windows; minimum 820×600 (was 900×600).** The
  Models for tasks row (title 190 pt + three fixed pickers) needed ~650 pt
  of page, so at 900 the content was wider than the window and SwiftUI
  centred and clipped it: the nav lost its left edge, the right column its
  right. The page column is now `minWidth: 0` and clipped (as the main
  window), and rows reflow (pickers under the title, one runner column,
  counters and connection buttons under their text). The minimum went below
  the user's usual ~890 pt so that width is reachable and tested. The narrow
  reflow is not drawn on the canvas yet. → [vaults-and-settings](vaults-and-settings.md#window-sections-and-search)
- **Settings remembers scroll per section, in memory, per window session.**
  An unvisited section opens at its top; a visited one where you left it;
  search results and deep links go to the section; closing Settings or
  quitting forgets it all. Read and set through the page's NSScrollView
  (macOS 14 has no SwiftUI offset API); where to land is decided when the
  page is asked for, because a new scroll view reports 0 before it is
  restored. The window's content is rebuilt on reopen. → [vaults-and-settings](vaults-and-settings.md#window-sections-and-search)

- **Atlassian sign-in stays a pasted API token (for now):** browser sign-in was
  considered via Atlassian's remote MCP server (OAuth 2.1 + PKCE, no shipped
  secret), a hosted token broker, or Claude's Atlassian connector. The user chose
  to keep the token flow; revisit with a spike on the MCP route. → [actions](actions.md)

## 2026-10-03

- **Actions redesign (canvas v57): Complete everywhere, one toolbar, list
  plus detail.** Complete ("you've handled it") is a handler of every type,
  Slack included. It works from ready, created and sent (and open), moves
  the item to `done` whatever the external status says, records the status
  it left as the `done` event's detail, and Undo (`restoreAction`) puts it
  back exactly there. Bulk Complete shows one toast, "Completed N · Undo",
  and its Undo restores all of them (before, only the last one came back).
  To do keeps only its checkbox: to-do rows get no hover Complete, since the
  checkbox already is Complete. The automatic Done when Jira or Confluence
  reports Done on refresh is kept; its Undo returns the item to created.
  Slack's empty state has one primary action, Open To do, because messages
  come from notes and to-dos (Send to), not from a blank compose. History →
  Actions filters dates by presets only (Today, This week, Last 30 days); no
  date-range picker until someone needs one. See [Actions](actions.md).
- **The schema owns the Actions boards from canvas v57:** ActionsTodo,
  ActionsSlack, ActionsJira, ActionsConfluence and ActionsHistory render from
  `design/screens/actions.json`; edits go there (and to its fragments), never
  to `gen_actions.py`, which must not regenerate them. Fragments (bespoke
  markup in `screens/actions/`) are an allowed migration step; each becomes a
  component when it is next touched. ActionsOverview and ActionsAsk stay
  legacy for now.
- **The design is a schema in the repo (`apps/distill/design/`):** the
  canvas is rendered from `tokens.json` (generated from Theme.swift),
  `components.json` + `components/<Name>.dc.html` (one entry per Swift view)
  and `screens/*.json` (base screens, states as overrides, boards as ordered
  state lists) by `render.py`. Why: every state was a hand-generated copy
  made by unversioned scratchpad scripts, so one change meant regenerating
  and checking many copies. `test_design.py` (in `make test`) fails when a
  component, prop or token drifts from Swift. A prop the view derives is
  `"swift": false` with a `why`; a prop designed but not built is
  `"swiftPending"`. The old generators live in `design/legacy/` until their
  boards move over. Publishing stays manual (the lead). See
  [Design process](design-process.md).

## 2026-10-02

- **One Swift view per canvas component (IconButton, Segmented):**
  `IconButton(systemImage, size, tint, fill, help)` in Theme.swift replaces
  every hand-drawn icon-only button (⋯, pencil, trash, xmark, pin, stop,
  gear, terminal); call sites pass size/tint/iconSize so nothing moves.
  `Segmented` and `SegmentedPills` were the same view, so `Segmented` keeps
  the superset (font, track, help) and `SegmentedPills` is a typealias; the
  canvas keeps both names. → [design-process](design-process.md)
- **Undo of "Add all" dismisses:** confirmed items still untouched since they
  were found count as untouched, so `dismissActions` drops them with no
  History entry (ActionsAsk frame 7) instead of the client falling back to
  remove. → [actions](actions.md)
- **Settings as built (mac-settings):** search lists results by section and
  opens them (it does not filter the controls in place); To-do defaults has
  only the stored settings (group, sort, retention incl. Forever, overdue
  reminder). The board's extra rows (Show, due filter, what new to-dos get,
  completed to-dos, reminder time) are deferred until the contract stores
  them. Connections is one Atlassian card with a pasted API token; field
  defaults live on each type's page. → [vaults-and-settings](vaults-and-settings.md), [actions](actions.md)
- **Actions client (mac-actions):** the sidebar badge counts open to-dos and
  drafts in `ready`; pending items wait in "To confirm" and are not counted
  (matches the SidebarStates numbers). Every Undo is `restore` (complete,
  remove, mark as sent, Send to, a dismissed Ask row); Undo of an automatic
  add or of Add all is `dismiss`; Undo improve is `undo-improve`. To-do group
  and sort start from Settings → To-do defaults; a change on the screen is
  remembered in app defaults (`distill.todo.group` / `.sort`). Menus inside
  scrolling lists (answer buttons, Found rows, Slack recipient) are popovers
  in the app and drawn panels in snapshots; the To do filter menus are drawn
  panels. History's "Kept until" follows `historyDays`. → [actions](actions.md)
- **Selected answer text is not an action source yet:** Ask answers render as
  a SwiftUI `Text`, whose selection the app can't read, so "To-do from
  selected text" is listed disabled and the selection bar (Add as to-do /
  Send to / Copy) waits for a selectable answer view. → [ask](ask.md)
- **Open in Actions from the Ask screen leaves Ask,** which deletes the chat
  when Keep history is off (as leaving Ask always does). Items keep the quote
  and question; their "Ask chat" source stops being a link once the chat is
  gone. → [ask](ask.md), [actions](actions.md)
- **Settings uses the shared `ActionTypeInfo`** (`SettingsActionType` is now a
  typealias with Settings helpers); the private JSON decoding is gone.
- **Settings window built with section navigation and search** (mac-settings):
  - Picking a section shows its group's page (General, AI, Actions and
    connections), scrolled to that section. This follows the Settings board,
    which shows each group as one page with an h2 per section. Search results
    are a list of settings that open their section. They don't filter the
    live controls in place.
  - The search index is data, `SettingsIndex`. Each action type adds its own
    entries from the core's type list. Why: a new setting must be searchable
    by adding one entry.
  - Advanced moves to the end of the AI page. Setup problems move to the top
    of every page.
  - Deep links use section ids through the `distill.openSettingsSection`
    notification. The image "Settings" link opens Models for tasks (Text from
    images).
  - `actionPreferences` is kept as raw JSON in the app, because the core
    merges settings one top-level key at a time and unknown nested keys must
    survive.
  - Finding actions is stored once, in `actionPreferences.findSelection`.
    Both Settings rows edit it. The core reads findSelection, then
    taskDefaults.actionFind, then Sonnet.
  - To-do defaults ship only what the contract stores: group, sort, history
    days and remind overdue. The board's Show, Due date filter, New to-dos
    get, Completed to-dos and reminder time wait for contract fields.
  - Connections show one Atlassian card for Jira and Confluence, not two
    rows, because it is one sign-in. Its sign-in panel holds the site, email
    and API-token form, since a pasted token replaces the board's
    browser-only flow.
  - Field defaults live on each type's page, not on the Connections card.
  - Prompt editors use the shared Markdown editor. Placeholders aren't tinted
    blue as on the board.

  → [vaults-and-settings](vaults-and-settings.md), [actions](actions.md#settings)
- **PrimaryButton and SoftButton take a size**: regular 40, small 30, mini 26
  (font 14/13/12, padding 20/14/11, SoftButton regular 18), with
  PrimaryButton `enabled` (45% when off) and SoftButton `stroke`. Existing
  call sites stay regular. → [app-shell](app-shell.md)
- **Action sources say more:** an item from Ask records its turn
  (`turnIndex`) and whether it restates the answer's gap (`gap`; the Ask Gap
  callout then hides). A manual item records who added it (`by: 'agent'` for
  the CLI/API, absent = the user), so the "added by" filter can tell them
  apart. → [actions](actions.md)
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
