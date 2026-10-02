---
type: spec
title: Actions
status: designed
created: 2026-10-02
updated: 2026-10-02
tags:
  - distill
  - actions
---

# Actions

Things to do that Distill finds in processed notes and in Ask answers.
Canvas: row "6 · Actions from your notes" (ActionsOverview, ActionsAsk,
ActionsTodo, ActionsSlack, ActionsJira, ActionsConfluence, ActionsHistory,
SettingsNav). Contract: `core/src/contracts.ts` → "Actions (actions.json)",
"Connections", `DistillCore` v3. Code: `core/src/actions/`.

## Model

- Every item has a **type**. `todo` is the catch-all: anything that needs the
  user and that Distill can't do itself. Other types are things Distill can
  do through **handlers**: `slack` (Copy now; Send later), `jira` and
  `confluence` (Create, Refresh, Mark done). `email` is reserved.
- Types and handlers are registry data (`core/src/actions/registry.ts`):
  adding a type or a handler never changes the contract or the clients'
  generic rendering. Clients render unknown types from `ActionTypeInfo`.
- Status: pending (to confirm) → open / ready → creating → created → done;
  sent (messages); removed (History, restorable); dismissed (found, never
  added). Every change appends to the item's `events` timeline.

## Where items come from

- **Notes**: after Approve & apply, the batch's last step "Finding actions"
  reads the changed pages and source notes (task `actionFind`, default
  Claude Code · Sonnet). The finished job shows "Found 5 actions to confirm ·
  Review them".
- **Ask answers**: after each answer, detection runs in the background (does
  not delay the answer) and shows "Found in this answer" under it. Any answer
  also has **Add to to-do ▾ / Send to ▾**, and selected text gets a small bar
  (Add as to-do, Send to, Copy).
- Settings → Actions → **Where actions come from**: per source (notes, Ask):
  Detect to-dos, Detect Slack/Jira/Confluence items (per type), **Ask me to
  confirm before adding**. All default ON. With confirm ON, found items wait
  in a "To confirm" group; with it OFF they are added ("Added 1 to-do and
  created 3 drafts · Undo").
- Duplicates: an item already open (same source note and quote, or same
  normalized title and type) shows "Already in …" instead of a copy.
  Dismissed items are not suggested again in the same chat.

## Lists and handlers

- Sidebar **Actions** with sub-items To do · Slack messages · Jira tickets ·
  Confluence pages (pages with more than 2 tabs use sidebar sub-items, not a
  tab bar). The badge counts open to-dos plus drafts ready to copy or create.
- To-do: filters (status, due, person, note, label, priority, created, added
  by, vault, search), group and sort, add by hand, edit, complete with Undo,
  bulk select, **Send to ▾** (the item moves to that type's list and keeps
  `fromActionID`).
- Drafts are written on finding (`draftWhen: onFind`, default for Slack, Jira,
  Confluence) or only on **Create message / Write draft** (`onRequest`).
- Editing uses the shared Markdown editor; **Done** runs the type's improve
  prompt (task `actionImprove`, default Sonnet) with Undo (`previousBody`).
  To-dos get no improve pass.
- Slack: context (note, quoted lines, Why), recipient (typed freely; no Slack
  lookup yet), **Copy** then **Mark as sent** (copying isn't sending). A
  disabled **Send in Slack · Later** slot marks the future handler.
- Jira / Confluence: created only on the user's click, never during
  processing. Created items show key/link and status (manual **Refresh**;
  Done in Jira → done). Errors: not connected / sign-in expired →
  "Sign in to Jira in your browser", refused (field marked), unreachable.
  Removing a created item removes it from Distill only.
- History → Actions: removed, done, sent; Restore; Delete forever (the only
  confirm). Kept `historyDays` (default 90). A restored item of a type now
  off comes back as a to-do. A type turned off loses its sub-item and its
  items fall back to to-dos.

## Settings

Settings get section navigation and search. Actions page: the sources above;
per type: on/off, when to write the draft, draft model and improve model
(default Sonnet), draft prompt and improve prompt (each with Reset to
default), field defaults (Jira project/type, Confluence space). To-do
defaults (sort, group, remind overdue: off). Connections: Atlassian (one
sign-in for Jira and Confluence on one site), Slack (not needed for Copy).

## Connections

Atlassian Cloud REST with the user's email and an API token stored in the
Keychain. "Sign in in your browser" opens Atlassian's API-token page; the
user signs in there and pastes the token (an OAuth app would need a client
secret Distill can't ship; the `ConnectionInfo` interface allows OAuth later).
