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

Built in the macOS app (`SettingsActions.swift`, `SettingsConnections.swift`;
section navigation and search in [Vaults and settings](vaults-and-settings.md#window-sections-and-search)).
Everything is stored in `settings.actionPreferences`.

- **Actions** page:
  - **Where actions come from**: one card each for notes processed into the
    wiki and Ask answers. Each has Detect to-dos, Detect Slack, Jira,
    Confluence items (a master switch, plus one tile per type that turns that
    type off for this source: `disabledTypes`), and Ask me to confirm before
    adding. All are on by default and labeled DEFAULT ON. The first edit of a
    source writes its whole object.
  - **Model for finding actions**: `findSelection`. It is the same value as
    Models for tasks → Finding actions. Both the app and the core read
    `findSelection`, then `taskDefaults.actionFind`, then Claude Code · Sonnet
    · Medium.
  - **Action types** from `GET /v1/action-types`: To do (always on), Slack
    message, Jira ticket, Confluence page, and Email ("Coming later"). Each row
    shows when drafts are written and its models, and opens the type's page.
    When the core can't list types (501 or 404), the registry's built-in list
    shows with a calm "Update the Distill core" note.
- **A type's page**:
  - On/off. Off means no list for the type, and its found items become
    to-dos.
  - When to write the draft: when a note is processed (`onFind`) or only when
    I ask (`onRequest`).
  - For Jira and Confluence, "Create in …" is shown locked to "On your click".
  - Field defaults: Jira project and issue type, Confluence space and parent
    page.
  - Model for writing (`draftSelection`), and Improve after I edit
    (`improveAfterEdit`) with its model (`improveSelection`). Both fall back to
    `taskDefaults.actionDraft` / `actionImprove`, then Sonnet.
  - Send in Slack shows as "Coming later".
  - **Create prompt** and **Improve prompt** in the shared Markdown editor,
    with a Default or Edited pill and Insert field ▾ (the type's
    `placeholders`, inserted at the cursor). Reset to default asks "Reset the
    create prompt?". The user's text can be brought back with Undo reset until
    Settings closes. A prompt equal to the default is stored as absent, so the
    core uses its built-in prompt.
- **To-do defaults**: Group by (due, note, none), Sort (due, created,
  priority, note), Keep action history (30 days, 90 days, 1 year, Forever = 0,
  default 90), and Remind me of overdue to-dos (default off).
- **Connections**: Slack ("Not needed yet — Copy works without connecting",
  Connect disabled). One Atlassian card for Jira and Confluence. The card's
  states:
  - not connected: Sign in in your browser
  - signing in: "Waiting for browser" and the token form
  - connected: site, account, Disconnect
  - sign-in expired: sign in again
  - error or denied: a message and Try again
  - older core: "Update the Distill core"

  `connection` events update the card.

## Connections

Atlassian Cloud REST with the user's email and an API token stored in the
Keychain. "Sign in in your browser" asks the core for the sign-in URL
(`GET /v1/connections/atlassian/sign-in-url?site=`) and opens it in the
default browser. Only http(s) addresses are opened. The user creates an API
token there and pastes it with the site URL and email into the card's form,
which calls `POST /v1/connections/atlassian/connect`. The token field is a
secure field, cleared on submit whatever the answer. It never reaches
settings.json, logs or error messages (`ConnectRequest`'s description hides
it). An OAuth app would need a client secret Distill can't ship; the
`ConnectionInfo` interface allows OAuth later.
