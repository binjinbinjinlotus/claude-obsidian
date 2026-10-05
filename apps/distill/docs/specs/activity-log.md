---
type: spec
title: Activity log and trash
status: built
created: 2026-10-04
updated: 2026-10-04
tags:
  - distill
  - activity
  - user-data
---

# Activity log and trash

Build status: **built in the core, the API and the CLI** (2026-10-04;
`core/src/activity/`, routes in `core/src/server/http.ts`, `distill activity`
and `distill trash`). **Mac UI: built** (2026-10-04, History → Activity,
canvas row "8 · Activity"; see "macOS app").

## Why

On 2026-10-04 three Ask chats and a Script collector disappeared.
`collectors.json` had been emptied at 19:04, and the inline script couldn't be
recovered. The owner had deleted them, but nothing in Distill could show that,
so the investigation took a long time and suspected the wrong cause. The owner
asked for "a log system for the app activity".

Goal: anyone can answer **"what changed, when, and from where?"** for the
owner's data and settings, and every deletion can be traced. A deleted chat or
collector can be got back for 30 days.

## What is logged

Logging happens in the core, at its mutation points, so every client (the Mac
app, the CLI, the agent plugin, curl) is covered the same way.

- **One wrapper over the core facade** (`instrumentCore` in
  `core/src/activity/instrument.ts`). Every `DistillCore` method, plus the
  engine extras, is classified in one mapped type. A method added to the
  contract fails typecheck until someone decides whether it is logged. A test
  also checks that every function on `createCore()` is classified.
  - logged: wrapped here (success and failure)
  - read: changes nothing
  - event: logged from the event stream, because it also happens without a
    request (batches, runs, scans)
  - quiet: changes nothing the user keeps (Stop on an Ask turn, Extract
    content)
- **The core's event stream** (`createEventLogger`) logs what the core does on
  its own: batches moving on, collector runs, history retention and queue scans.

| Family | Types | Notes |
|---|---|---|
| Ask chats | `chat.created`, `chat.updated` (a follow-up), `chat.pinned`, `chat.unpinned`, `chat.deleted`, `chat.expired`, `chat.restored` | Title, turn count, size and dates only. Questions and answers are never logged. |
| Collectors | `collector.created`, `.updated`, `.enabled`, `.disabled`, `.consented`, `.consent_revoked`, `.deleted`, `.restored`, `.stopped`, `.forgot`, `.forget_undone`, `.folder_created`, `.run` | Script: interpreter, file path or inline **size and line count**, schedule, vault, and a 12-character consent hash prefix. Never the body. |
| Actions | `action.created`, `.updated` (which fields changed, not what they say), `.confirmed`, `.dismissed`, `.drafted`, `.improved`, `.improve_undone`, `.performed`, `.sent`, `.removed`, `.restored`, `.deleted`, `.expired`, `.found` | Title, type and status. |
| Batches (jobs) | `batch.started`, `.ready`, `.approved`, `.replied` (length only), `.allowed` (tool rules), `.rejected`, `.cancelled`, `.applied` (changed paths, operation id), `.failed`, `.deleted`; `labels.suggest_started`, `labels.confirm_started` | Ingest results are `batch.applied` and `batch.failed`. |
| Queue and notes | `queue.added`, `queue.removed` (with the macOS Trash as its recovery), `queue.scanned` (only when files appeared or went outside Distill), `note.added` (title, labels, file count; never the text), `note.labeled` | |
| Connections | `connection.connected`, `connection.disconnected` | Site and status. Never the token or the email. |
| Settings and keys | `settings.changed` (`key: old → new` for short values; `key: changed` for lists and secret-looking keys; no line when nothing changed), `runner.secret_saved`, `runner.secret_cleared` | For keys, only which runner and which key name. The value is never read. |

Failures are logged with `outcome: "failed"` and the error message, shortened
and redacted: a refused delete, a consent with a stale hash, a failed batch, a
failed run, a restore conflict.

### Not logged (defaults; veto any)

- Reads, and Ask questions and answers, note text, reply text, action bodies,
  and script bodies.
- Scheduled collector runs that found nothing, and skipped scheduled ticks.
  They are already in the collector's run history, and at every 15 minutes
  they would bury everything else. Runs started with Run now are always
  logged.
- `queue.scanned` that only saw sizes or times change.
- Pruning that is bookkeeping, not user data: `jobs.json` beyond 300 jobs, and
  collector run history beyond 30 days or 200 runs.
- Actions found automatically after an Ask answer (they wait for you to
  confirm, and the confirm is logged). Actions found after a batch are logged
  as `action.found`.
- Core `log` warnings.

## Each entry

One JSON object per line (`ActivityEntry` in `contracts.ts`):

```json
{"id":"1791155040000-0001-a1b2c3","at":"2026-10-04T23:04:00.000Z","type":"collector.deleted",
 "source":"app","object":{"kind":"collector","id":"col-…","name":"Meeting notes"},
 "summary":"Deleted the script collector “Meeting notes”","outcome":"ok",
 "details":{"kind":"script","interpreter":"python3","scriptBytes":2140,"scriptLines":61,"schedule":"0 * * * *"},
 "recovery":{"kind":"trash","trashId":"trash-1791155040000-0a1b2c3d","expiresAt":"2026-11-03T23:04:00.000Z"},
 "pid":4242}
```

- `id` sorts by time: 13-digit milliseconds, then a per-process sequence and a
  random suffix. It is also the pagination cursor.
- `object` holds the stable id and the human name at the time of the change,
  so a deleted thing still has a name.
- `recovery` appears on deletes:
  - `trash`: a trash id and its expiry
  - `macosTrash`: queue files moved to the macOS Trash
  - `none`: no copy, with the reason

### Sources: who asked

| Source | Means | How it is known |
|---|---|---|
| `app` | the Mac app | `X-Distill-Client: app`, sent on every request by `CoreClient.makeRequest` (2026-10-04). Older Mac builds are still recognised by their URLSession User-Agent (`Distill/<build> CFNetwork/… Darwin/…`) |
| `cli` | the `distill` CLI typed by a person | `X-Distill-Client: cli` (the CLI sends it) |
| `agent` | the CLI run by an AI agent: the plugin skills in Claude Code or Codex | the CLI sends `agent` when `CLAUDECODE=1` or a `CODEX_SANDBOX*` variable is set; `DISTILL_CLIENT=cli|agent` overrides |
| `scheduler` | Distill on its own | the engine and collector timers enter a scheduler context; scheduled runs (`trigger` schedule/catch-up); retention |
| `api` | an HTTP request that didn't say who it is (curl) | none of the above |
| `core` | in-process calls with no request (tests, dev scripts) | |

The HTTP server reads the source once per request and runs the handler inside
it (`AsyncLocalStorage`, `core/src/activity/context.ts`). Background work a
request starts inherits it. For example, a batch you start with Process now
logs `batch.applied` as `app`.

## Recovery: Distill's trash

Deleting an Ask chat or a collector first writes a copy to
`<state>/trash/<trash-id>.json`. Then the delete runs.

- **If the copy can't be written, the delete is refused**, with the message
  "Couldn't keep a copy in Distill's trash, so nothing was deleted". If the
  delete then fails, the copy is removed.
- **What's kept:**
  - chats: the chat file, every turn included
  - collectors: the whole record, including an inline script. That is what
    would have saved the Meeting notes script.
- **Retention:** 30 days, at most 200 items and 50 MB, oldest first. The
  newest item is always kept. Pruning runs on every write and every listing.
- **Safety:** the directory is mode 0700 and the files 0600. Listing
  (`GET /v1/trash`, `distill trash`) never returns the payload, only the name,
  dates, size and facts (turn count; interpreter, script size and lines).
- **Restore** (`POST /v1/trash/:id/restore`):
  - A chat goes back under its id. If that id is taken, the restore is refused
    (409). Its `updatedAt` becomes the restore time, so Ask history retention
    counts its days again; otherwise an old chat would be swept again within
    the hour. The write is a temp file plus a create-only link (atomic).
  - A collector keeps its id unless that id is taken. It comes back **off**,
    with consent cleared, so a restored script is reviewed before it runs
    again. Its run history is not restored (deleting removes the runs file),
    and Folder collectors keep their ledger anyway.
  - Restores are logged (`chat.restored`, `collector.restored`).
  - The CLI restores chats only. It never adds collectors, so collectors are
    restored in the app.
- **Not trashed (defaults):**
  - **Chats deleted while Keep Ask history is off.** The app deletes each chat
    when it is closed, so you have chosen not to keep chats. The entry says
    `reason: keep-history-off` with `recovery.kind: none`. The core can't
    tell a close from an explicit delete in that mode, so it reads the setting
    as a proxy.
  - **Chats removed by retention** (`chat.expired`, older than
    `historyDays`, not pinned) and actions removed by History retention
    (`action.expired`). Both are logged as `scheduler`.
  - Actions deleted forever from History: they are already a second-step
    delete.
  - Jobs deleted from the list: only the record goes. Applied pages stay in
    the vault, and the vault's `wiki/log.md` lists the operation.
  - Queue files: they already go to the macOS Trash, and the entry records it
    (`~/.Trash/<name>`; a numbered name when one is taken).

## Storage

- `<state>/activity/activity.jsonl`: append-only JSON Lines, mode 0600, in a
  0700 directory. It is a local file and never leaves the Mac.
- **Writes:** one `appendFileSync` per entry: a single O_APPEND write of at
  most 8 KB (larger `details` are dropped and marked `truncated`). Lines from
  the server, its scheduler and any other process sharing the state dir never
  interleave. A log that can't be written never fails the change it records.
- **Rotation:**
  - Past 2 MB, the live file is renamed to
    `activity-<UTC time>-<pid>-<random>.jsonl`, under a lock directory
    (`.rotate.lock`, taken over after 30 s).
  - Rotated files are kept up to 10 files and 180 days, so at most about
    22 MB.
  - Reads order rotated files by their last write, newest first, and stop
    once a page is full.
- **Backups:** `activity/` and `trash/` are not in `distill.sh backup` and are
  never overwritten by a restore. The log is append-only history and must
  not be rewound. Both are permanent user data ([User data](user-data.md)).

## API

| Route | Does |
|---|---|
| `GET /v1/activity` | Newest first. Query parameters below. Returns `{entries, nextCursor}`. |
| `GET /v1/trash` | `{items: TrashItem[]}`, newest first, no payloads. |
| `POST /v1/trash/:id/restore` | `{item, objectID, note?}`. Errors: 404 for unknown or expired; 409 when a chat with that id exists. |

`GET /v1/activity` query parameters:

- `type`: types or families, comma-separated; `collector` matches
  `collector.*`.
- `kind`: an object kind.
- `object`: an object id.
- `source`: sources, comma-separated.
- `since` (inclusive) and `until` (exclusive): ISO times.
- `q`: text in the summary, type, name, id, error or details.
- `outcome`: `ok` or `failed`.
- `limit`: default 50, from 1 to 500.
- `cursor`: the previous page's `nextCursor`.

Contract additions (additive, in `contracts.ts`):
- types: `ActivitySource`, `ActivityObject`, `ActivityEntry`, `ActivityQuery`,
  `ActivityPage`, `TrashItem`, `RestoreResult` and `ActivityApi`
- error code: `CoreErrorCode` `conflict` (409)
- event: a `{type: "activity", entry}` CoreEvent for each new line. Older Mac
  builds decode it as unknown.

`ServerCore` adds `Partial<ActivityApi>`, so a core without it answers 501.

## CLI

- `distill activity`: filters and paging, with `--json`:
  - `--type T`… and `--kind K`
  - `--object ID`
  - `--source S`…
  - `--since` and `--until`: a date, a time, or an age like `30m`, `24h`, `7d`
  - `--search TEXT`
  - `--failed`
  - `--limit N` and `--cursor C`

  Each line is local time, source, summary and `[type]`. Deletes add where the
  copy is and the restore command.
- `distill trash [list]` and `distill trash restore ID` (chats only), with
  `--json`.

## macOS app

Canvas row "8 · Activity", boards **Activity** and **ActivityRowStates**, and
the Sidebar's new History sub-item. **Built 2026-10-04** (canvas v66 approved):

- Code: `Sources/Distill/ActivityScreen.swift` (screen, detail, Filter
  popover, empty states), `ActivityRow.swift` (the canvas component, mapped in
  `design/components.json`), `ActivityStore.swift` (loading, paging, live
  events, Restore, links); DistillKit `Activity.swift` (DTOs and routes) and
  `ActivityText.swift` (filter, words, detail facts). Snapshot states
  `activity*` in `SnapshotActivity.swift` match the board's frames.
- Data: page 1 of `GET /v1/activity` for the current filter (50 at a time;
  older pages load when the list's end comes into view), plus `GET /v1/trash`
  and the `chat.restored` / `collector.restored` entries. "In trash",
  "Restored" and a gone copy are worked out from those, so a relaunch shows the
  same state and Restore is never offered for a copy that is gone.
- Live: each `activity` event joins the list when no filter excludes it; with a
  search the page is asked for again (the core matches details too).
- Filter mapping: Queue = `queue`, `note`; Batches = `batch`, `labels`;
  Settings = `settings`, `runner`, `connection`; Automatic = `scheduler`;
  Today = since local midnight. "Show everything for X" adds a removable
  "For: X" chip (object id).
- The detail's facts come from the keys the core writes (`instrument.ts`);
  unknown keys show as they are. Kept N days/hours is `expiresAt − deletedAt`
  (24 hours for chats closed with Keep history off).
- Links: Open collector / Open run log (Collectors, All runs), Open in History
  (History → Jobs, that job), Open chat, Ask history settings, Show in Finder
  (the file in `~/.Trash`, else the Trash folder). Links to a thing that is
  gone are disabled.
- Narrow: under 760 pt of content (a 900 pt window) the detail column goes and
  a chosen entry is pushed in place with "‹ Activity" (Esc goes back).

- **Where it lives: History → Activity**, a fourth sub-item after Jobs, Ask
  chats and Actions. History is where the app already answers "what
  happened", and where a missing chat would be looked for first. Settings
  holds configuration, not a record. A separate window would add a new kind of
  place for one list. The sidebar's sub-items already scale to four.
- **The list:**
  - One calm line per entry (`ActivityRow`): a small family tile, the summary,
    and a muted "time · source".
  - Day headings: Today, Yesterday, then the date.
  - Only failures get a pill (peach "Failed"). A delete with a trash copy
    shows a quiet "In trash" tag.
- **Filters:** the Actions toolbar again (search, Filter · N, chips). The
  Filter popover has three short choices and one switch:
  - What: All, Chats, Collectors, Actions, Batches, Queue, Settings
  - From: Anywhere, Mac app, CLI, Agent, Automatic
  - When: Any time, Today, 7 days, 30 days
  - Only failures
- **Detail:** on the right in a wide window. It shows:
  - what happened, then When, From, the object and the type
  - "What was there": the facts from `details`
  - the recovery card:
    - Distill's trash: **Restore**, with "comes back off; you'll review the
      script"
    - macOS Trash: **Show in Finder**
    - none: the reason, in muted text
  - **Show everything for this collector** (filters by object id)
- **After Restore:** the card turns green ("Restored at 7:12 PM; it's off
  until you allow its script") with **Open collector**, and a "Restored" line
  joins the top of the list.
- **Empty:** "Nothing has changed yet". A filter with no results shows "No
  activity matches" with **Clear filters**.
- **Narrow window (890 pt):** the list takes the full width (no detail column);
  choosing an entry pushes its detail in place with "‹ Activity" to go back.
  Chips that don't fit collapse into "+N", as on Actions.

## Open questions

1. Should chats deleted while Keep history is off also go to the trash (for
   example for 24 hours), as a guard against surprises?
2. ~~Should the Mac app send `X-Distill-Client: app` explicitly?~~ Done
   2026-10-04: `CoreClient.makeRequest` sends it on every request.
3. Is a 30-day trash, 180 days and about 22 MB of log right?
4. Should the trash also keep actions deleted forever, and jobs deleted from
   the list?
5. Should scheduled runs that found nothing appear in the log, behind a "Show
   routine runs" switch?
