---
type: spec
title: Actions
status: built
created: 2026-10-02
updated: 2026-10-06
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
  do through **handlers**: `slack` (Copy, Mark as sent, Complete; Send
  later), `jira` and `confluence` (Create, Refresh, Complete). Every type
  has **Complete** ("you've handled it"). `email` is reserved.
- Types and handlers are registry data (`core/src/actions/registry.ts`):
  adding a type or a handler never changes the contract or the clients'
  generic rendering. Clients render unknown types from `ActionTypeInfo`.
- Status: pending (to confirm) → open / ready → creating → created → done;
  sent (messages); done also by Complete from open, ready, created or sent; removed (History, restorable); dismissed (found, never
  added). Every change appends to the item's `events` timeline.

## Where items come from

- **Notes** (since 2026-10-05, [Action context](action-context.md)): while
  the batch waits in Review, the core looks through every line of every
  source (task `actionFind`, default Claude Code · Sonnet, on the batch's own
  runner when that is another provider) with the source's wiki page as
  context. Review shows them under "Actions found"; they enter Actions when
  their source's pages apply. Each item points at the original's lines
  (`source.raw`) and its wiki sections (`source.wiki`). The finished job
  shows "Found 5 actions to confirm · Review them".
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
  disabled **Send in Slack · Later** slot marks the future handler. Designed, not built: the slot
  becomes a button linked to the Slack CLI, and every type can have buttons
  that run a script ([Action buttons and script commands](action-buttons.md)).
- Jira / Confluence: created only on the user's click, never during
  processing. Created items show key/link and status (manual **Refresh**;
  Done in Jira → done). Errors: not connected → "Set up connection"
  (Settings → Connections), sign-in expired → "Update the token" plus Retry,
  refused (field marked), unreachable.
  Removing a created item removes it from Distill only.
- History → Actions: removed, done, sent; Restore; Delete forever (the only
  confirm). Kept `historyDays` (default 90). A restored item of a type now
  off comes back as a to-do. A type turned off loses its sub-item and its
  items fall back to to-dos.

## Add as at confirm time (2026-10-06, owner request)

In **Actions › To do › TO CONFIRM**, an item found as a to-do could only be
added as a to-do (footer: Dismiss | + Add); to send it through a handler the
owner had to add it, then Send to. Now the destination is chosen at confirm
time.

- **Footer:** Dismiss | a split button. The main part reads "Add as <found
  type>" ("Add as to-do"; "Add as Slack message" when found as one). The ▾
  part opens **Add as…**, listing every enabled action type: To-do first,
  then the types that have a handler or button (Slack message, Jira ticket,
  …), each with its icon and a line on what happens ("Ready to send with
  Send in Slack").
- **Panel:** picking another type opens an inline "Add as Slack message"
  panel in the detail, with that type's fields prefilled from the item:
  title → title; summary or body → body or text; people → to; source and
  line kept. The owner edits and clicks "Add as Slack message", or Cancel.
  Required fields left empty block Add, with the field named. For Slack, the
  To row's "Who is X in Slack?" behaviour ([Action buttons](action-buttons.md),
  Where to send) applies right there.
- **Provenance:** converting keeps the source note, line, From the wiki, Why
  and labels (the same item, in place), and Activity records "Added … as
  Slack message (found as to-do)" (`action.confirmed`, `details.foundAs`).
- **Row:** the list row has the same choice in its context menu
  (right-click › Add as ▸ …). Keyboard: Return = Add as the found type;
  ⌥Return opens Add as….
- Add all and Dismiss all are unchanged (each item as its found type). Send
  to (after the fact) stays.
- **Core:** `confirmActions(ids, {as})` with `as = {type, title?, body?,
  fields?}` (`ConfirmAs`), one id at a time. The type must be on (not
  reserved); fields are mapped (same keys kept; a to-do's person → a
  message's To or a ticket's assignee, and back), then the overrides apply;
  an unknown field, a choice outside its list, or an empty required field is
  refused in plain words ("Fill in To first."); defaults fill the rest. The
  item keeps its id and gets events `type` "todo → slack" and `confirmed`
  "as slack (found as todo)". An empty body on a drafting type writes the
  draft. A converted Slack message resolves its To exactly like a found one.
  Tests: `actions.test.ts` ("Add as: …"), `http-actions.test.ts`,
  `activity.test.ts`.
- **Mac (built):** `AddAsViews.swift` (split button, Add as… menu, panel and
  its footer), `DistillKit/AddAs.swift` (options, prefill, what blocks Add,
  the keys, `ConfirmAs` and `CoreClient.confirmAction(_:as:)`). The panel
  sits above What it's about in the To-confirm detail; in a row without the
  right pane it opens under the row. As on the canvas (Version 91): the menu's
  found-type row reads "Found as a to-do" and its last line is "Return adds
  as to-do · ⌥Return opens Add as…"; the panel header notes "filled from the
  to-do"; a blocked footer reads Cancel · "Fill in who it goes to" (a
  Slack To; other fields by label, "Fill in Project") · a disabled "Add as
  Slack message", the reason on its own line when the pane is too narrow.
  A Slack To that is a name nobody has said who it is in Slack, while a
  button sends to To, counts as not filled in ("Who is Vladan Dimitrijevic in
  Slack?" is open; canvas F). Plain Return in the detail adds as the found
  type too (⌘Return is an alias), never while typing in a text field or with
  the panel open; ⌥Return opens Add as….
  Tests: `AddAsTests`. Snapshot states
  `actions-confirm-addas-menu`, `actions-confirm-addas-slack`,
  `actions-confirm-addas-blocked`.

## Jira pickers (2026-10-06, owner request)

The owner's ticket (TLS · Task · Priority Medium) failed with "Jira didn't
create it: Jira didn't create the ticket: The priority selected is invalid."
Project, Type and Priority were free text or a fixed list, not what their
Jira allows, and the banner said "didn't create" twice.

- **Core (built):** `actions/jira-meta.ts` asks the connected account:
  projects it can create issues in (`/rest/api/3/project/search?action=create`,
  paged; key + name), each project's issue types
  (`/rest/api/3/issue/createmeta/{project}/issuetypes`, subtasks left out)
  and a type's create screen (`…/issuetypes/{id}`: its fields and the
  priority scheme's allowed values; no Priority field → `priorities: null`).
  Cached per account and site for an hour; `?refresh=1` reloads. Secrets stay
  in the Keychain (the AtlassianClient). Routes: `GET /v1/jira/projects`,
  `GET /v1/jira/projects/:key/types`, `GET /v1/jira/projects/:key/types/:id/fields`.
  Not connected, unreachable or a Jira error: 409 with `error.jira`
  (`not_connected`, `auth_expired`, `unreachable`, `error`).
- **Check before Create:** a project the account can't use, a type the
  project lacks or a priority outside its scheme marks the field and refuses
  the run in plain words ("Medium isn't a priority in TLS. Pick one."), before
  any write. A case-only difference takes Jira's spelling; a create screen
  without Priority leaves it out of the request. If Jira can't be reached for
  the lists, nothing is blocked: Jira checks on create.
- **Drafts:** a drafted ticket's priority named like the project's ("medium")
  takes the project's spelling; one the project lacks is left empty and the
  field marked ("Medium isn't a priority in TLS, so it was left empty. Pick
  one."). Best effort: not connected or offline changes nothing.
- **One "didn't create":** the banner shows the core's sentence once ("Jira
  didn't create the ticket: The priority selected is invalid.").
- **Mac (built):** `JiraPickerViews.swift` and `DistillKit/JiraPickers.swift`.
  In the Jira ticket detail, Project is a searchable picker ("TLS · Telus
  Platform"; PROJECTS YOU CAN CREATE IN), Type and Priority are pickers
  reloaded when Project changes, with the caption "From your Jira (Jin Liu ·
  updated 3 min ago) · Refresh". A value outside the lists is marked with the
  core's words; a create screen without Priority shows "Priority isn't used in
  this project". Without the lists the values stay as text with "Couldn't
  reach Jira to check these · Retry". The same pickers are in the Add as…
  panel for a Jira ticket and in Settings → Jira ticket (Defaults: project,
  type, priority). As on the canvas (Version 93, board ActionsJiraFields):
  the three are pop-up pickers; the project menu has Search projects, RECENT
  (the current project first, with ✓, then others used on Jira tickets) and
  ALL PROJECTS YOU CAN CREATE IN; Type and Priority open on TYPES IN TLS /
  PRIORITIES IN TLS. A value outside the lists reads "Medium isn't a
  priority in TLS. Pick one:" and the footer says "Pick a priority TLS uses"
  beside a disabled Create in Jira (no banner). The caption sits under the
  ticket's fields ("jin@lotusflare… · updated 2 min ago"). Offline, the
  pickers are muted with the saved values and Create stays on. A refused
  create shows "Nothing was created and your draft is unchanged." (Create in
  the footer retries). Picking a project saves its key ("TLS"), so a
  button's `{fields.project}`, the filters, Add as and Copy read the key; the
  picker shows "TLS · Telus Platform" (`JiraPick.label`), from Jira's list or,
  offline, from the names cached at the last load (`jiraProjectNames`). An
  older saved "TLS · Telus Platform" still works: the core reads the key from
  it. Tests: `JiraPickersTests`. Snapshot states
  `jira-fields-pickers`, `jira-fields-project-menu`, `jira-fields-invalid`,
  `jira-fields-offline`, `jira-fields-error`, `jira-fields-settings`.
- Tests: `actions.test.ts` ("Jira pickers: …", a fake Jira over the fake
  fetch: paging, cache and refresh, refusals before any POST, Jira's
  spelling, no Priority on the screen, unreachable blocks nothing, the
  drafted priority), `http-actions.test.ts` (routes).

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
  Connect disabled). One Atlassian card for Jira and Confluence (canvas
  SettingsNav 8, 9, 9b; v59). It is connected, or it isn't: there is no
  "connecting" or "waiting for the browser" state.
  - connected: "Connected" pill, site · as account, Disconnect
  - not connected: "Not connected" pill and the token form, always open:
    Site, Email, API token, then Connect (on once all three are filled) and
    Get an API token (opens Atlassian's token page in the browser; nothing
    waits for it)
  - token refused: still not connected, the form keeps what was typed, and a
    banner "Atlassian didn’t accept this token · Check the site and email, or
    create a new token. Nothing was saved." Any other failure shows the core's
    own words with "Nothing was saved."
  - sign-in expired, denied, or an older core's `signing_in`: shown as not
    connected with the form (expired adds "the token stopped working; paste a
    new one" to the subtitle)
  - older core: "Update the Distill core"

  `connection` events update the card.

## Connections

Atlassian Cloud REST with the user's email and an API token stored in the
Keychain. "Get an API token" asks the core for the token page URL
(`GET /v1/connections/atlassian/sign-in-url?site=`) and opens it in the
default browser. Only http(s) addresses are opened. The user creates an API
token there and pastes it with the site URL and email into the card's form,
which calls `POST /v1/connections/atlassian/connect` (the app waits 45 s, longer
than the core's 30 s check with Atlassian, so a slow site ends in the core's
answer). While it runs Connect is only disabled; no "Connecting…" label. The
token field is a secure field; it is cleared once Atlassian accepts the token
and kept in the form (memory only) after a refusal so a typo in the site or
email can be fixed. It never reaches
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
| `slack` | to (required) | copy, markSent, complete, send (reserved: "Later") | onFind | yes | — |
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
for drafts, the original's lines around the item (`<original>`, ±25 lines,
max 12 000 characters) and its wiki sections (`<wiki>`, up to 3); an older
item without `raw` gets its note's text centred on its quote (`<source>`,
max 12 000 characters) instead of the note's first 12 000 characters. Notes
and answers are wrapped as data and the model is told to ignore instructions
inside them. Output is structured (find: `items[{type, title, body?,
fields[{key,value}], why, quote, notePath?}]`; draft: `{title, body,
fields}`; improve: `{body}`); a JSON object in the text is the fallback.

### Finding

- **Notes, in the batch** (v11, [Action context](action-context.md)):
  `onReviewReady` → `findForReview` looks through each source's reading copy
  in windows of at most 24K tokens (every line, by construction) and keeps
  the found items in `<job dir>/actions-found.json`; `onJobApplied` →
  `findInJob` adds those whose source page applied (`commitJob`, idempotent,
  per part), and `onJobEnded` marks them not applied. Progress key
  `actions:job:<id>` (kind `actions`) in Review. The 12 000 / 60 000
  character cuts below are gone.
- **Notes, after apply** (`findInJob`, older jobs with no side file and Try
  again): the engine calls `onJobApplied` when a
  queue-consumer (ingest) job turns `completed` with changed paths (both the
  agent-applied and the core-applied path; label jobs never). It runs the
  same windowed pass over the job's source files (inbox, else their archived
  copy through the ledger), with the changed `.md` pages minus
  `wiki/log.md`, `wiki/hot.md`, `wiki/index.md`, `wiki/meta/**`, `.raw/**`,
  `_index.md` as wiki context; with no readable source, those pages are
  looked through themselves. Progress: key = job id, kind
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
  `dismissActions` on items untouched since found (only found / drafted /
  confirmed events, plus confirm's to-do fallback) → `dismissed`, no History
  entry. The same call is the Undo of "Add all" in the Ask block.

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
  complete → `done` (every type; from open, ready, created or sent; refused
  from pending, removed, dismissed, done, while busy, and for a to-do sent to
  another type, which completes there; the external status is left as it is;
  event `done` with detail = the status it left), create → `creating` → `created` with `external {key,
  url, status, checkedAt}`, refresh → the status from Jira / Confluence (Jira
  `statusCategory` done → `done`, kept: the automatic Done; its event detail
  is "in Jira (Done)"). A failed handler returns 200 with the item
  back in its status and `error` set; never an HTTP error.
- `sendActionTo`: from pending/open/ready to an enabled type; the old item →
  `sent` with event `sent-to:<type>` (detail = the new id); the new item keeps
  `fromActionID`, carries title, why, source, labels and matching fields
  (`person` ↔ `to`), and starts its draft right away.
- `removeAction` (not from History) → `removed`, event detail = the status to
  restore. `restoreAction` is every Undo: removed → where it was; done →
  the status Complete recorded (open, ready, created or sent; for an
  automatic Done or an older item: created when it has an external key, else
  open / ready); Mark as sent → ready; Send to →
  back where it was, and the item it became is deleted if still untouched
  (only added / drafted events; otherwise `invalid_state`, "it lives on in
  …"); dismissed → pending (or open/ready for an auto-added item). A type
  that is off now comes back as a to-do. `deleteActionForever`: History or
  dismissed items only.
- Try again: `findJobActions(jobID)` (`POST /v1/jobs/:id/actions/find`)
  reruns "Finding actions" for an applied batch; it returns the job with
  `actionsFound.status = "finding"` at once.
- Handler ids for clients: `copy`, `markSent`, `create`, `refresh`,
  `complete` (labelled "Complete" for every type, also a created ticket or
  page).
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
| POST | `/v1/actions/confirm` | `{ids, as?: {type, title?, body?, fields?}}` (`as`: one id; Add as) | `{actions: ActionItem[]}` |
| POST | `/v1/actions/dismiss` | `{ids}` | `{ids, dismissed: true}` |
| POST | `/v1/actions/:id/draft` | | `ActionItem` (closing the request cancels) |
| POST | `/v1/actions/:id/improve` | | `ActionItem` (closing the request cancels) |
| POST | `/v1/actions/:id/undo-improve` | | `ActionItem` |
| POST | `/v1/actions/:id/perform` | `{handler}` | `ActionItem` (handler failure: 200 with `error`) |
| POST | `/v1/actions/:id/send` | `{type}` | the new `ActionItem` |
| POST | `/v1/actions/:id/remove` | | `ActionItem` |
| POST | `/v1/actions/:id/restore` | | `ActionItem` |
| POST | `/v1/conversations/:id/actions/detect` | `{turnIndex?}` | `{actions: ActionItem[]}` |
| GET | `/v1/jobs/:id/actions` | | `JobActions {summary, proposals}` (v11: what Review shows; 404 unknown job) |
| POST | `/v1/jobs/:id/actions/find` | | `{job}` (Try again; also in Review for failed sources; 409 when the job has no applied changes and isn't in Review) |
| GET | `/v1/jira/projects` | `?refresh=1` | `JiraProjects` (Jira pickers; 409 with `error.jira` when Jira can't be asked) |
| GET | `/v1/jira/projects/:key/types` | `?refresh=1` | `JiraIssueTypes` |
| GET | `/v1/jira/projects/:key/types/:id/fields` | `?refresh=1` | `JiraFields` (`priorities` null: no Priority on the create screen) |
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
- `distill actions found <job-id> [--json]` (v11): what a batch found, where
  each stands (waits for apply, added, already in Actions, not added), the
  original's lines, and how many lines were looked through. Read-only.
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
  off "Added 2 to-dos and created 1 draft · Undo", Undo = dismiss; the same
  for Undo after Add all in Ask; a 409, the item was edited meanwhile, removes it instead). Every other
  Undo is `restore` (complete, remove, mark as sent, Send to, a dismissed Ask
  row); Undo improve is `undo-improve`. Set up connection and Update the token post
  `distill.openSettingsSection` "connections" and open Settings; "Settings for
  this type" posts `actions/<type>`.
- **Toolbar and Filter panel** (built 2026-10-03, canvas v57; `ActionsToolbar.swift`,
  `FilterPanel.swift`, rules in `DistillKit/ActionsFilters.swift`, tested): every
  Actions tab and History → Actions has one toolbar line: search, Filter ▾
  ("Filter · N" in the active blue style once filters beyond the default are
  set; To do's Status: Open is the default and shows no chip), one removable
  FilterChip per filter, a "+N" chip for those that don't fit (it opens the
  panel at the first hidden one), then the right slot: sort on To do and
  Slack (Newest / Oldest first on Slack; To do's group and sort panel),
  connection status on Jira and Confluence ("acme.atlassian.net ·
  connected", or "Atlassian · not connected" + Set up connection, which opens
  Settings → Connections through `openSettings(section: "connections")`; no
  in-between state, v59), nothing on History. It never
  wraps and never asks for more width than it has: `ToolbarFit` decides from
  the measured widths; chips collapse into +N first, then the search narrows
  (160, then 140), and only then does the connection drop its status text.
  The Filter panel (a popover; drawn in place in snapshots) has per-kind
  sections: To do Status (single), Due, Person (search), Label, Source note,
  Priority, More; Slack Status, Recipient, Source note, Label; Jira Status,
  Project, Type, Priority, Assignee, Source note; Confluence Status, Space,
  Source note; History Type, Outcome, Date, Source. A section with more than
  6 rows shows the top 5 and "Show all N"; the footer has Clear all (back to
  Status: Open; search stays), the count ("2 filters", "Status: Open", "No
  filters") and Done. Clicking a chip opens the panel at its section, its
  heading in blue. History's Date is presets only: Today, This week (last 7
  days), Last 30 days. Not built from the template data: To do's Due "Next 7
  days" and "Pick dates…" (Due uses the buckets Overdue, Today, This week,
  Later, No due date) and History's "Pick dates…" (decision 2026-10-03).
- **Rows and Complete** (built, `ActionRow.swift`, `ActionsStore.complete`): the
  Slack, Jira, Confluence and History lists use ActionRow (type tile, title,
  source line, status pill). Hover shows ✓ Complete ("Complete (you've handled
  it)") and ⋯ on the lists, Restore and ⋯ in History. To do keeps its own
  checkbox row and has no hover Complete. Complete (row, detail, bulk bar)
  strikes the row through for 2 s, then it leaves for History as Completed;
  one toast, "Completed · Undo" or "Completed 3 · Undo", whose Undo restores
  every item to the status it left.
- **To do** (built, `ActionsScreen.swift`): header with History and Add
  to-do; the toolbar above; group and sort panel (starts from Settings →
  To-do defaults; a change here is kept in `distill.todo.group` /
  `distill.todo.sort`); grouped rows with note, person, labels, priority and a
  due badge; the detail (fields, FROM context with quote, Why and "Found by",
  "Also from this note"; footer: remove on the left, then Complete, then Send
  to ▾ with the suggested type first and Email disabled); edit in place
  (title, due, priority, people, labels; saved as you type); Add to-do row (↩
  adds, Esc cancels, labels you filter by pre-filled); ⌘/⇧-click selects for
  the bulk bar (Complete, Due date, Priority, Label, Send to, Remove, Clear);
  "To confirm" group with Add / Create draft, ×, Add all, Dismiss all (the
  detail's footer: Dismiss | Add as <found type> ▾, see Add as at confirm
  time); empty,
  no-match (names the filters, Clear filters, Show completed), finding strip,
  first-load shimmer and "Couldn't find actions" with Try again.
- **Handler tabs: Slack, Jira, Confluence and other types** (built,
  `ActionsTypeScreen.swift`, cards in `ActionsTypes.swift`): list plus
  detail on every tab (Slack moved from cards). The list narrows (330 → 250
  pt) before the detail does. Detail footers have one order everywhere: edit
  and remove on the left; Complete (SoftButton), then the primary action on
  the right: Copy (Slack; Create message when not written; Send in Slack once
  that handler exists, the dashed "Send in Slack · Later" slot until then,
  dropped first in a narrow window), Create in Jira / Confluence (Write draft
  when not written), Open in Jira / Confluence for created items. In a narrow
  window the hint goes, then "Create in Jira" / "Open in Jira" shorten to
  "Create" / "Open"; buttons never truncate. Slack messages: recipient (click
  to pick from the note's people and labels or type someone else), Ready to
  paste / Not written / Writing / Editing / Polishing / Copied, the body with
  @mentions and Markdown, Writing with Sonnet… Cancel, editing in the shared
  Markdown editor with the compact bar (⌘↩ Done → improve), Improved by … with
  Undo ⌘Z and Show changes, Copy (Slack marks: `*bold*`, `_italic_`,
  `~strike~`, `<url|text>`) → Copied for 2 s → "Copied. Paste it in Slack."
  with Mark as sent / Not yet. Jira and Confluence: fields from
  `ActionTypeInfo` (the refused field marked), the description as headings,
  bullets and checkboxes, Writing / Improving with Cancel, Creating in Jira…,
  Created with key link, status, "Status from Jira at 3:52 PM · Refresh";
  errors: not connected ("Set up connection" → Settings → Connections, plus
  Settings), sign-in expired ("Update the token" plus Retry), Signed in → Retry, refused,
  unreachable, AI failed. States per tab: empty with one primary action (Slack
  and connected Jira / Confluence: Open To do; not connected: Set up
  connection, in the toolbar too), no results naming the filters
  with Clear filters.
- **History → Actions** (built, `ActionsHistoryView.swift`): the toolbar
  (search, Filter with Type, Outcome, Date, Source) and ActionRows by day.
  Outcomes: Completed (done by Complete), Sent (a to-do sent to another type,
  or a message marked as sent), Created (Jira / Confluence reported Done on
  refresh: the `done` event's detail starts with "in "), Removed, Dismissed
  (found but not added; loaded with `status=…,dismissed&history=1`). Each has
  Restore, except a to-do sent to another type, which shows where it went
  with Open in … (it lives on there; the canvas draws no Restore for it).
  Restoring a dismissed item puts it back in To confirm. The selected item is
  read-only with its timeline ("What happened"), Restore (with "Restored to …
  · Open", the note-gone note, and Restore as a to-do when the type is off),
  Delete forever (the only confirm). Empty: "Nothing here yet" with Open To
  do; no results: names the filters, Clear filters. History → Jobs and Review
  show the job's line from `Job.actionsFound` (Found N actions to confirm · by
  type · Review them / Open in Actions, which open To do filtered to that job;
  finding uses the loading pattern; failed has Try again); Review shows the
  actions found while the batch was read ("Actions found", see [Action
  context](action-context.md)).

- **Ask** (built): see [Ask](ask.md) → Actions in answers.
- **Batch progress** (built): the Queue banner's steps end with "Finding
  actions (after you apply)" while the core's steps stop at review; after
  apply the core's own steps include Finding actions. The banner shows
  "started at 3:41 PM" (a clock time) instead of a ticking counter.
- **Snapshots** (built): `--states` renders flow "6 · Actions from your
  notes" (`SnapshotActions.swift`): every To do, Slack, Jira, Confluence,
  History, Ask and quick ask state above, plus the sidebar collapsed total
  and History › Actions. `DISTILL_STATES_ONLY=<prefix>` renders a subset. The
  v57 frames render under the schema's state ids (`todo-frame-7` at a 900 pt
  window, `todo-card-*`, `slack-frame-2…4`, `jira-frame-3`, `jira-frame-5…6`,
  `confluence-frame-3`, `confluence-frame-5…6`, `*-card-completed`, `history-card-no-results-for-the`)
  plus the open Filter panel per kind (`actions-*-filter`).
- **Live check** (opt-in, `Tests/DistillTests/ActionsLiveTests.swift`): with
  `DISTILL_LIVE_STATE=<temp state dir>` of a running core with seeded actions,
  it completes a Slack message and undoes it, bulk-completes three to-dos and
  undoes all three, checks Set up connection asks Settings for Connections, and
  renders the real screens offscreen at 900 and 1110 pt, with filters set on
  every tab (`DISTILL_LIVE_OUT` keeps the PNGs; they are looked at, not
  measured).
