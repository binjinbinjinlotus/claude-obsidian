---
type: spec
title: Actions
status: built
created: 2026-10-02
updated: 2026-10-02
tags:
  - distill
  - actions
---

# Actions

Build status: **core, HTTP API and CLI built** (`core/src/actions/`,
`server/http.ts`, `distill actions`); **macOS client built** (see "macOS
client" below; the selection bar for selected answer text is not built yet).

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

## Implementation (core)

Files in `core/src/actions/`:

| File | What |
| --- | --- |
| `registry.ts` | Built-in types (`todo`, `slack`, `jira`, `confluence`, `email` reserved), their fields, handlers, default draft and improve prompts and placeholders; `effectiveType` merges Settings over the defaults; `registerActionType` / `registerHandler` add more. |
| `index.ts` | `createActionsService`: the `DistillCore` actions and connections methods, finding (`findInJob`, `afterAsk`), drafting / improving, History sweep. |
| `store.ts` | `actions.json` codec (`ActionStore`). |
| `ai.ts` | One structured-output run per task (no tools, empty scratch dir under `<state>/actions/scratch`), schemas. |
| `prompts.ts` | The default find prompt and how draft / improve prompts are assembled. |
| `atlassian.ts` | Connection storage, the Atlassian REST client, Jira and Confluence handlers. |
| `markdown.ts` | Markdown → Jira ADF and → Confluence storage format. |

### Types and handlers

| Type | Fields | Handlers | Draft written | Improve after edit | Connection |
| --- | --- | --- | --- | --- | --- |
| `todo` (catch-all, always on) | due (date), priority, person | complete | — (no prompt) | no | — |
| `slack` | to (required) | copy, markSent, send (reserved: "Later") | onFind | yes | — |
| `jira` | project (required), issueType, priority, assignee | create, refresh, complete | onFind | yes | atlassian |
| `confluence` | space (required), parent | create, refresh, complete | onFind | yes | atlassian |
| `email` (reserved, off) | to, subject | copy, openMail (both reserved) | — | — | — |

Adding a type is one `ActionTypeDef` entry; a handler is
`registerHandler(typeID | '*', handlerID, fn)`; a handler returns
`{status?, external?, event, detail?}` or throws `ActionHandlerError`.
`listActionTypes` reports `defaultDraftPrompt` / `defaultImprovePrompt` and
`placeholders` (`{title} {body} {why} {excerpt} {note_title} {note_path}
{labels} {today}` plus per type `{recipient}`, `{project} {issue_type}
{priority} {assignee}`, `{space} {parent}`). A handler that needs a
connection is `available: false, reason: "Not connected"` until connected.

Settings merge (`actionPreferences.types[id]`): `enabled` (to-do is always
on; reserved types stay off), `draftWhen`, `improveAfterEdit`, prompts (null
or empty = the default), `fieldDefaults` (filled into new items' empty
fields). Model precedence: per type `draftSelection` / `improveSelection`
(finding: `findSelection`) → `taskDefaults.actionDraft | actionImprove |
actionFind` → Claude Code · Sonnet (finding at medium effort). Settings
writes only the `actionPreferences` keys for these. The action tasks never block batching
(they are left out of the setup problems); a broken runner shows as a failed
step instead.

### Prompts

Every prompt is the instructions (the default, or the user's version from
Settings with placeholders filled in) followed by a context block the user
can't remove: the item (title, why, fields, labels, quoted lines, note) and,
for drafts, the source note text (`<source>`, max 12 000 characters). Notes
and answers are wrapped as data and the model is told to ignore instructions
inside them. Output is structured (find: `items[{type, title, body?,
fields[{key,value}], why, quote, notePath?}]`; draft: `{title, body,
fields}`; improve: `{body}`); a JSON object in the text is the fallback.

### Finding

- **Notes** (`findInJob`): the engine calls `onJobApplied` when a
  queue-consumer (ingest) job turns `completed` with changed paths (both the
  agent-applied and the core-applied path; label jobs never). Documents: the
  job's source files first (the new text), then the changed `.md` pages minus
  `wiki/log.md`, `wiki/hot.md`, `wiki/index.md`, `wiki/meta/**`, `.raw/**`,
  `_index.md`; 12 000 characters each, 60 000 in all (a page that doesn't
  fit is skipped, smaller ones after it still go in). Progress: key = job id, kind
  `batch`, steps `Moved to inbox · Read sources · Applied changes · Finding
  actions · Done`, "Finding actions in 2 notes", finished with "Found 5
  actions to confirm: 3 to-dos, 1 Slack message, 1 Jira ticket" / "Added …" /
  "No actions found". `Job.actionsFound` (`engine.setJobActions`) goes
  `finding` → `done` | `failed` | `skipped`. A job is searched once: its id is
  recorded in `actions.json` `processedJobs` before the model runs.
- **Ask** (`afterAsk`): `createCore` wraps `ask`; after the answer returns,
  detection runs in the background (key `actions:<conversationID>`, kind
  `actions`). Documents: the question and answer, plus up to 3 cited pages as
  context. `detectAskActions` runs it by hand (even when detection is off) and
  returns the new items plus the open items they duplicate ("Already in …").
- Type resolution: a type that is unknown, off, reserved, turned off for the
  source (`disabledTypes`), or any type with `detectTypes` off becomes `todo`;
  a to-do with `detectTodos` off is dropped. With both off nothing runs.
- Duplicates: an item in any status (also done, removed, sent, dismissed)
  with the same source note (or Ask chat) and normalized quote, or with the
  same quote of 24+ characters from any page, is not added again, so a later
  batch that rewrites the page never brings handled lines back. A live item
  (pending … created) with the same normalized title and type also counts;
  for Ask, so do dismissed items of the same chat.
  Within one run only the title rule applies, since one sentence can hold
  two actions ("I'll book the room and tell Mei": a to-do and a message).
- Confirm on → `pending`. Confirm off → `open` (to-do), or `open` and a
  background draft → `ready` (types with `draftWhen: onFind`). Undo for those:
  `dismissActions` on items untouched since found (only found / drafted
  events) → `dismissed`, no History entry.

### Lifecycle rules

- `createAction`: unknown or disabled type → `invalid_request`; to-do →
  `open`; a type with a body → `ready`, without → `open` (plus a draft when
  `onFind`). Source defaults to `manual`.
- `updateAction` (pending/open/ready/created; `busy` while drafting or
  creating): a body edit clears `previousBody`; a type change (not when
  created) applies the new type's field defaults.
- `confirmActions`: pending → open/ready; a type turned off since → to-do;
  drafts start when `onFind`. Non-pending ids come back unchanged.
- `draftAction` / `improveAction`: status `drafting` while running (a second
  call → `busy`), progress key `action:<id>` (kind `actions`); cancelling via
  the signal (HTTP: closing the request) returns the item as it was, with no
  error; an AI failure returns it with `error.code = ai_failed`. Drafts fill
  only empty fields. Improve keeps `previousBody`; `undoImprove` puts it back.
- `performAction`: copy (event only; needs text), markSent → `sent`,
  complete → `done`, create → `creating` → `created` with `external {key,
  url, status, checkedAt}`, refresh → the status from Jira / Confluence (Jira
  `statusCategory` done → `done`). A failed handler returns 200 with the item
  back in its status and `error` set; never an HTTP error.
- `sendActionTo`: from pending/open/ready to an enabled type; the old item →
  `sent` with event `sent-to:<type>` (detail = the new id); the new item keeps
  `fromActionID`, carries title, why, source, labels and matching fields
  (`person` ↔ `to`), and starts its draft right away.
- `removeAction` (not from History) → `removed`, event detail = the status to
  restore. `restoreAction` is every Undo: removed → where it was; done →
  open (created when it has an external key); Mark as sent → ready; Send to →
  back where it was, and the item it became is deleted if still untouched
  (only added / drafted events; otherwise `invalid_state`, "it lives on in
  …"); dismissed → pending (or open/ready for an auto-added item). A type
  that is off now comes back as a to-do. `deleteActionForever`: History or
  dismissed items only.
- Try again: `findJobActions(jobID)` (`POST /v1/jobs/:id/actions/find`)
  reruns "Finding actions" for an applied batch; it returns the job with
  `actionsFound.status = "finding"` at once.
- Handler ids for clients: `copy`, `markSent`, `create`, `refresh`,
  `complete` (also "Mark done" for a created ticket or page).
- Retention: on load and at most hourly on `listActions`, removed / done /
  sent / dismissed items whose last event is older than `historyDays` are
  dropped; `historyDays <= 0` keeps them forever. Live items are never dropped.
- Startup recovery: `drafting` → open/ready; `creating` → `ready` with an
  error asking the user to check before retrying (it may exist already).

### actions.json

`<state>/actions.json` = `{version: 1, items: [ActionItem], processedJobs:
[last 500 job ids], …}`, written atomically (`writeFileAtomic`). Decoded
leniently: unknown keys at the top and in every item survive a save; an item
this build can't decode is written back untouched (and the file is copied
first with `preserveUnreadable`); an unparseable file is set aside as
`actions.json.unreadable-<time>` before the first save.

### Connections (built)

- `atlassian`: `connect({site, email, token})` normalizes the site (`acme` →
  `https://acme.atlassian.net`), verifies with `GET /rest/api/3/myself`
  (Basic auth), then stores the email and token in the Keychain
  (`SecretStore` items `atlassian.email` and `atlassian.token`, service
  `com.claude-obsidian.distill`). The site, display name and account id go to
  `<state>/connections.json` (mode 0600, no secrets). `listConnections` reads
  stored state only (no network): connected, not_connected, or expired after
  a 401. `signInURL` →
  `https://id.atlassian.com/manage-profile/security/api-tokens`. `disconnect`
  deletes both secrets.
- `slack`: always `not_connected`, "Copy works without connecting"; connect
  and signInURL → `invalid_request`.
- Jira create: `POST /rest/api/3/issue` with project key, summary, issue
  type (default Task), priority, labels (spaces → dashes), assignee (You /
  your name → your account id; another name only when user search finds
  exactly one), description as ADF. Confluence create: space key → id with
  `GET /wiki/api/v2/spaces?keys=`, parent title → id with `GET
  /wiki/api/v2/pages?space-id=&title=` (numeric ids pass through), then
  `POST /wiki/api/v2/pages` in storage format.
- Errors: no credentials → `not_connected`; 401 → `auth_expired` (the
  connection shows expired); 403 → `not_connected` (no permission); 400/409 →
  `refused` with `field` mapped back (`issuetype` → `issueType`, `summary` →
  `title`, `spaceId` → `space`; others as Jira names them, e.g.
  `components`); network failure → `unreachable`.

## API

All routes need the bearer token, like every other route.

| Method | Path | Body / query | Returns |
| --- | --- | --- | --- |
| GET | `/v1/action-types` | | `{types: ActionTypeInfo[]}` |
| GET | `/v1/actions` | `?type=&status=a,b&history=1&vault=&q=` | `{actions: ActionItem[]}` |
| POST | `/v1/actions` | `NewActionInput` (type defaults to todo) | `ActionItem` (201) |
| GET | `/v1/actions/:id` | | `ActionItem` (404 `action_not_found`) |
| PATCH | `/v1/actions/:id` | `ActionPatch` | `ActionItem` |
| DELETE | `/v1/actions/:id` | | `{id, deleted: true}` (History only, else 409) |
| POST | `/v1/actions/confirm` | `{ids}` | `{actions: ActionItem[]}` |
| POST | `/v1/actions/dismiss` | `{ids}` | `{ids, dismissed: true}` |
| POST | `/v1/actions/:id/draft` | | `ActionItem` (closing the request cancels) |
| POST | `/v1/actions/:id/improve` | | `ActionItem` (closing the request cancels) |
| POST | `/v1/actions/:id/undo-improve` | | `ActionItem` |
| POST | `/v1/actions/:id/perform` | `{handler}` | `ActionItem` (handler failure: 200 with `error`) |
| POST | `/v1/actions/:id/send` | `{type}` | the new `ActionItem` |
| POST | `/v1/actions/:id/remove` | | `ActionItem` |
| POST | `/v1/actions/:id/restore` | | `ActionItem` |
| POST | `/v1/conversations/:id/actions/detect` | `{turnIndex?}` | `{actions: ActionItem[]}` |
| POST | `/v1/jobs/:id/actions/find` | | `{job}` (Try again; 409 when the job has no applied changes) |
| GET | `/v1/connections` | | `{connections: ConnectionInfo[]}` |
| POST | `/v1/connections/:id/connect` | `{site, email, token}` (scrubbed from errors) | `ConnectionInfo` |
| GET | `/v1/connections/:id/sign-in-url` | `?site=` | `{url}` |
| POST | `/v1/connections/:id/disconnect` | | `ConnectionInfo` |

Errors map like every route: `not_found` 404, `invalid_request` 400,
`invalid_state` / `busy` 409. Events: `action` (`deleted: true` when an item
is dropped), `connection`, and `progress`.

## CLI

- `distill actions list [--type T] [--history] [--json]`: open items,
  including found ones ("to confirm").
- `distill actions add "<title>" [--type todo] [--body ..] [--why ..]
  [--due YYYY-MM-DD] [--vault PATH] [--json]`: agents can add to-dos.
- There is no confirm, complete, send or create command: those are the
  user's, in the app.

## Tests

`core/src/actions/actions.test.ts` (registry, Markdown → ADF / storage,
store incl. an unreadable file, finding → pending / confirmed, per-source
detection, dedupe, Ask detection, lifecycle incl. sendActionTo, improve /
undo, cancel, restore as a to-do, History sweep, recovery, connections and
the Jira / Confluence handlers against a fake HTTP), `actions/e2e.test.ts`
(approve → apply → Finding actions through `createCore`),
`store/actions-settings.test.ts`, `server/http-actions.test.ts`, and the
CLI tests. No test calls a real model or Atlassian.

## Labels on actions

`NewActionInput.labels` sets an item's labels and `ActionPatch.labels` replaces them (the To do list's edit, bulk Label, and Add to-do with labels pre-filled). Stored trimmed, without a leading `#`, deduped case-insensitively (`cleanLabels`). Items added through the CLI carry `source.by = 'agent'` and their timeline says "added by an agent".

## macOS client

Status per part; `built` parts ship in `clients/macos`.

- **DistillKit** (built): `Actions.swift` decodes `ActionItem`, `ActionTypeInfo`,
  `ActionHandlerInfo`, `ActionFieldSpec`, `ActionSource`, `ActionError`,
  `ActionEvent`, `JobActionsSummary` (`Job.actionsFound`, kept on re-encode)
  leniently: statuses, type ids, handler ids and error codes stay raw strings,
  an unknown source kind is `.other`, `fields` drops nulls and turns numbers
  into text, a bad list element is skipped. `CoreEvent.action(item, deleted:)`.
  `CoreClient` has one method per route (`actionTypes`, `actions(query)`,
  `action`, `createAction`, `updateAction`, `deleteActionForever`,
  `confirmActions`, `dismissActions`, `draftAction`, `improveAction`,
  `undoImprove`, `performAction(handler:)`, `sendAction(to:)`, `removeAction`,
  `restoreAction`, `detectAskActions`). Draft, improve, detect and perform use
  the long Ask timeout; cancelling the Swift task closes the request (which
  aborts the run in the core) and throws `CancellationError`. Handler failures
  arrive as items with `error`, never as thrown errors. Old cores (501 /
  "no route for" 404) are `isNotAvailable`.
- The ask source decodes `turnIndex` (which answer) and `gap` (the item
  restates the answer's gap); a manual source with `by: "agent"` is `.agent`
  (added by an agent through the CLI).
- **List rules** (built, `ActionsLogic.swift`, tested): the sub-item count is
  open to-dos plus items of other types in `ready` (drafts ready to copy or
  create); pending items wait in "To confirm" and are not counted; the
  collapsed Actions total is the sum over the enabled types. Due dates
  (`YYYY-MM-DD` or ISO time) fall in Overdue / Today / This week (next 7 days)
  / Later / No due date; rows show "Today", "5:00 PM", "Sat" or "Sep 30", the
  detail "Wed, Sep 30 · 2 days late". Group by due, source note, label,
  person, priority, created or none; sort by due, priority, created or title.
  Filters combine (one chip each; several values in a chip mean any of them);
  search covers title, body, why, recipient, person, labels and the quoted
  excerpt and shows the matched line when it isn't the title. History groups
  by day (TODAY, YESTERDAY, SEP 30) and words each entry by what happened:
  Completed, Removed, Sent "to Jira tickets …", Marked as sent, Done "in Jira ·
  checked …". `CoreClient.findJobActions` is Try again for a failed step
  (`POST /v1/jobs/:id/actions/find`).
- **Store and navigation** (built, `ActionsStore.swift`): one store per app
  model mirrors the registry and every item (`GET /v1/action-types`,
  `GET /v1/actions` on connect, History lazily with `history=1`, then
  `action` events). An old core turns the screens into a calm "Update the
  Distill core" state. New note items arriving after load raise one toast per
  batch ("5 actions to confirm from Tea club planning · Open", or with confirm
  off "Added 2 to-dos and created 1 draft · Undo", Undo = dismiss). Every other
  Undo is `restore` (complete, remove, mark as sent, Send to, a dismissed Ask
  row); Undo improve is `undo-improve`. The sign-in buttons post
  `distill.openSettingsSection` "connections" and open Settings; "Settings for
  this type" posts `actions/<type>`.
- **To do** (built, `ActionsScreen.swift`): header with History and Add
  to-do; filter chips Status, Due, Person (with search), Label, Note,
  Priority, More (added by, vault, this batch); group and sort menu (starts from
  Settings → To-do defaults; a change here is kept in `distill.todo.group` /
  `distill.todo.sort`); grouped rows with
  note, person, labels, priority and a due badge; the detail (fields, FROM
  context with quote, Why and "Found by", "Also from this note", Complete,
  Send to ▾ with the suggested type first and Email disabled, Remove); edit in
  place (title, due, priority, people, labels; saved as you type); Add to-do
  row (↩ adds, Esc cancels, labels you filter by pre-filled); Complete strikes
  through for 2 s with Undo; ⌘/⇧-click selects for the bulk bar (Complete,
  Due date, Priority, Label, Send to, Remove, Clear); "To confirm" group with
  Add / Create draft, ×, Add all, Dismiss all; empty, no-match (names the
  filters, Clear filters, Show completed), finding strip, first-load shimmer
  and "Couldn't find actions" with Try again. Menus are drawn panels (not
  NSMenu) so they render in snapshots.
- **Slack and other copy types** (built, `ActionsTypes.swift`): message
  cards with recipient (click to pick from the note's people and labels or
  type someone else), Ready to paste / Not written / Writing / Editing /
  Polishing / Copied at …, the body with @mentions and Markdown, Create
  message, Writing with Sonnet… Cancel, editing in the shared Markdown editor
  with the compact bar (⌘↩ Done → improve), Improved by … with Undo ⌘Z and
  Show changes (changed words tinted 4 s), Copy (Slack marks: `*bold*`,
  `_italic_`, `~strike~`, `<url|text>`) → Copied for 2 s → "Copied. Paste it
  in Slack." with Mark as sent / Not yet, the disabled dashed "Send in Slack ·
  Later" slot while the `send` handler is unavailable.
- **Jira, Confluence and other create types** (built): drafts and created
  items on the left, the card on the right: fields from `ActionTypeInfo`
  (the refused field marked), the description as headings, bullets and
  checkboxes, Write draft, Writing / Improving with Cancel, Create in Jira /
  Creating in Jira…, Created with key link, status, "Status from Jira at
  3:52 PM · Refresh", Open in Jira and Mark done; errors: not connected
  ("Sign in to Jira in your browser" → Settings → Connections), sign-in
  expired (plus Retry), Signed in → Retry (the create handler became
  available), refused, unreachable, AI failed. The header shows connected /
  not connected from the create handler's `available`.
- **History → Actions** (built, `ActionsHistoryView.swift`): search, What
  happened and Type filters, rows by day with what happened and when; the
  selected item read-only with its timeline ("What happened"), Restore (with
  "Restored to … · Open", the note-gone note, and Restore as a to-do when the
  type is off), Delete forever (the only confirm); a sent to-do shows where it
  went with Open in … and no Restore. History → Jobs and Review show the job's
  line from `Job.actionsFound` (Found N actions to confirm · by type · Review
  them / Open in Actions, which open To do filtered to that job; finding uses
  the loading pattern; failed has Try again); Review says before apply that
  actions are looked for after it.
- **Ask** (built): see [Ask](ask.md) → Actions in answers.
- **Batch progress** (built): the Queue banner's steps end with "Finding
  actions (after you apply)" while the core's steps stop at review; after
  apply the core's own steps include Finding actions. The banner shows
  "started at 3:41 PM" (a clock time) instead of a ticking counter.
- **Snapshots** (built): `--states` renders flow "6 · Actions from your
  notes" (`SnapshotActions.swift`): every To do, Slack, Jira, Confluence,
  History, Ask and quick ask state above, plus the sidebar collapsed total
  and History › Actions. `DISTILL_STATES_ONLY=<prefix>` renders a subset.
