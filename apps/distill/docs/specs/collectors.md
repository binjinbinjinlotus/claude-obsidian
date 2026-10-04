---
type: spec
title: Collectors
status: built
created: 2026-10-04
updated: 2026-10-04
tags:
  - distill
  - collectors
  - queue
---

# Collectors

Build status: **built in the core, the API, the CLI and the macOS app**
(2026-10-04; `core/src/collectors/`, routes in `core/src/server/http.ts`,
`distill collectors list|run|history`; the Mac UI from canvas row "7 ·
Collectors", boards Collectors and CollectorsScript, and the queue path on
Main, MainLoading and MainEmpty). See "macOS app (built)" for where the app
differs from the boards. The contract is in
`core/src/contracts.ts`; see "API and contract (built)" for where it differs
from the proposal.

Collectors bring material into a vault's queue folder automatically, on a
schedule. They only fill the queue. What they bring is batched, reviewed and
applied like a file the user drops, so nothing reaches the vault without
approval ([Queue and batching](queue-and-batching.md),
[Approval and review](approval-and-review.md)).

## Where it lives

- A **Collectors** sidebar item directly under Queue, because it feeds the
  queue. It shows a peach count only when collectors need the user: the last
  run failed, or a script waits for consent. Otherwise it shows no count.
- The screen is a list plus a detail, like the Actions lists. **Add
  collector** is the only button in the header.
- **List rows** (`CollectorRow`): kind tile, name, and one status line ("Every
  hour · copied 3 at 9:00 AM"). A healthy collector has no pill; a pill
  appears only for Running, Failed and Needs your OK. Off rows are dimmed.
- **The detail shows less by default.** It answers "is it working, and what
  did it last do?":
  - a title row: name, one quiet line (kind · schedule · next run), the
    on/off switch, **Run now** (Stop while running) and ⋯;
  - a **status card** with the last run in one sentence. Errors, consent,
    running progress and live output appear here and nowhere else. For a
    Folder it ends with the **Already collected: 128 files** link;
  - a compact read-only **Settings** block (Folder: From, After collecting,
    Into with the queue path, Schedule; script: Script, Schedule, Allowed)
    with an **Edit** link. Edit (also in ⋯) turns the block into a form in
    place, with Cancel and Save;
  - for scripts, an **Advanced** row, collapsed by default: interpreter,
    timeout, cron expression and what the script gets;
  - **Recent runs**: the last three runs, one line each; **Show all runs**
    opens the full list. Per-file results and output show only in an opened
    run.
- **Adding** is a short stepped sheet with defaults: 1 Kind (Folder or Custom
  script) → 2 Source (Folder: the folder, default `~/Distill Inbox`, and
  Keep or Move; script: file or inline code and interpreter) → 3 Schedule
  (default every hour) and target vault (the active vault). Folder ends with
  **Add and turn on**. A script ends with **Add**; it is saved off and its
  detail asks for consent, with the code shown.
- **No Collectors section in Settings.** Collectors are objects with run
  history and errors, not preferences, and a second place to edit them would
  drift. Settings → Vaults keeps the queue folder setting. The default
  timeout and history retention are fixed for now (see below). If they become
  user settings later, they go in a "Collectors" block under Settings →
  General.

## Kinds

### Built-in collectors

Distill ships the code, and the user only configures it: a folder, a query,
an API token, instructions, and a schedule. Each built-in declares its
settings in a registry entry, the same way action types do. The detail pane
renders the fields from the registry, so a new built-in never changes the
clients. Tokens go to the Keychain, like runner keys.

The first built-in is **Folder**:

- **Settings:**
  - the source folder (default `~/Distill Inbox`, created on first save if it
    is missing);
  - **Include subfolders** (on by default): each subfolder at the top of the
    source folder is collected as one folder item (see [Queue and
    batching](queue-and-batching.md), "Folder items");
  - **After collecting:** "Keep the original (copy)" (the default) or "Move
    it to the queue";
  - the target vault (the active vault by default);
  - the schedule (default every hour).
- **Run:** it copies every regular file at the top level of the source folder
  into the target vault's queue folder and leaves the original in place.
  `.gdoc` files are collected like files and become Google Doc items in the
  queue, where they wait ("needs Google Drive access") and are not processed. With Include subfolders on, each top-level subfolder is collected
  as one folder item (rules below). With
  "Move it to the queue" the file leaves the source instead. Run history and
  per-file lines say "Copied" or "Moved" to match the setting ("Copied 3 files
  · skipped 2 already collected").
- **It leaves these where they are:**
  - hidden files (names starting with `.`) and macOS metadata such as
    `.DS_Store` and `Icon\r`;
  - subfolders, only when Include subfolders is off.
  - **partial files**: a file whose mtime is within the queue's settle delay
    (`settleSeconds`, 10 minutes by default; the same rule as batching). It is
    shown as "Waiting · still changing", and a later run picks it up.
  - **files already collected**: see the ledger below. These are shown as
    "Skipped · already collected" and are not taken again.
- **Name clashes:** if the queue folder already has a file with that name,
  the incoming file gets " 2", " 3", and so on before its extension. The
  existing file is never replaced.
- **Errors:**
  - Source folder missing: the run fails, nothing is collected, and the user is
    offered Choose…, Create folder or Turn off.
  - No permission (macOS privacy): the run fails, and the user is offered
    Choose again… (so macOS asks) or Open System Settings.
  - Target queue folder missing: the run fails, and the user is offered
    Create folder (the same path).
  - One file that fails to copy or move: the error is logged on its line, and the
    rest of the run continues.

### Custom collectors

The user provides a script, and Distill runs it on a schedule, like a cron
job.

- **Source:** a file path, or inline code edited in the app (stored in the
  collector's record). The interpreter is one of `zsh`, `python3` or `node`,
  resolved on the user's login-shell `PATH` when the run starts. A file
  source runs as `<interpreter> <path> <vault> <queue>`. Inline code is
  written to a temporary file and run the same way.
- Settings: the schedule, a timeout, and on/off.

## Ledger and dedupe

- The core keeps one ledger per vault, used by Folder collectors, in its
  state directory: `<state>/collectors/ledger-<vault-id>.jsonl`, append-only, under
  the user-data rules in [User data](user-data.md). Each entry holds the
  source path, size, mtime, sha256, collected-at time, collector id, and the
  queue file name.
- **Why it matters:** with copy as the default, the originals stay in the
  folder, so the ledger is the only thing that stops every run from copying
  the same files again.
- **Dedupe is by content (the owner's choice, 2026-10-04).** A file whose
  sha256 is already in the vault's ledger is skipped and left where it is,
  whatever its name and wherever it came from. Two examples:
  - **An edited file is collected again.** `tasting-notes.md` was collected
    on Monday; the user edits it on Tuesday. Its content is new, so the next
    run collects it again (the ledger gets a second entry for that path).
  - **An identical copy under another name is skipped.** `gyokuro copy.md`
    has the same bytes as the collected `gyokuro.md`, so it is shown as
    "Skipped · already collected".
- **Already collected is visible.** The Folder detail shows "Already
  collected: 128 files" (the ledger entries whose source is this collector's
  folder) with **View…**. That opens a list of collected files: name, size and
  when, newest first, with search. Each row has **Forget**: it removes that
  entry, so the next run collects the file again if it is still in the
  folder. The row reads "Will be collected again" with Undo until the sheet
  closes. **Forget all…** asks for confirmation first.
  The ledger stores name, size, mtime and sha256, never file content.
- **Subfolders (folder items):**
  - The dedupe unit stays the file: each file inside is hashed and checked
    against the ledger like a top-level file.
  - A subfolder is collected when **any file in it is new or changed**.
  - With Keep the original, only the new and changed files are copied, into
    a folder of the same name with their relative paths kept. The item's
    manifest (`.distill-folder.json`) still lists the whole tree, so the AI
    sees the structure while unchanged files are not processed again.
  - With Move, the whole folder moves. Files already collected inside it are
    marked "seen before" in the manifest and are not given to the AI as
    sources.
  - A subfolder waits until no file in it changed within the settle delay.
  - The folder limits apply: 200 files and 500 MB of new files per item.
    Over the limit, the run logs "Skipped · too big" for that folder and
    collects nothing from it.
  - Run history shows one line per folder item: "Copied — Tea tasting trip/
    (folder · 5 new of 12 files)".
- Hashing is cheap to avoid: if path, size and mtime all equal an entry, the
  run treats the file as already collected without hashing it. Otherwise it
  hashes before copying or moving.
- The ledger outlives the collector. Deleting a Folder collector keeps its
  ledger, so a new Folder collector on the same folder does not take old
  files again. Forget (per file) and Forget all… are the only ways to change
  it.
- Custom scripts are not deduped by Distill: they own what they write. Files
  that appear in the queue during a script run are recorded only in that
  run's record (`runs/<collector-id>.jsonl`), never in the ledger, so they
  never cause a Folder collector to skip anything.

## Schedule model

- Each collector has one schedule. It is stored as a 5-field cron expression
  (`minute hour day-of-month month day-of-week`) in local time. The presets
  are shorthands for it:

  | Preset | Cron |
  | --- | --- |
  | Every 15 minutes | `*/15 * * * *` |
  | Every hour | `0 * * * *` |
  | Every day at T | `M H * * *` |
  | Weekdays at T | `M H * * 1-5` |
  | Custom | anything valid |

- `ScheduleField` shows a preset, a time for daily presets, a plain-English
  preview ("Mon, Wed and Fri at 8:30 AM") and the next run. The cron
  expression shows only for Custom and under Advanced, where editing it
  switches the preset to Custom. An invalid expression keeps Save off.
  Seconds, `@reboot` and nicknames are not accepted; `@hourly` and `@daily`
  are accepted and shown as their preset.
- The core's scheduler wakes for the earliest next run across collectors.
  The schedule is independent of the batch schedule. A collected file waits
  for the next batch. A settled file keeps its mtime when copied (the copy
  preserves it) or moved, so it is ready at once.
- **Missed runs** (the Mac was asleep or the core was off): one catch-up run
  at wake or start, never one per missed tick.
- **Overlap:** if a collector is still running at its next tick, that tick is
  skipped and logged as "Skipped · the 6:00 AM run was still going". The same
  collector never runs twice at once. Different collectors run in parallel,
  at most 2 at a time.
- **Run now** starts a run at once. It does not move the schedule.
- Turning a collector off stops future runs. A run in progress finishes
  (Folder) or keeps running until Stop (script).

## Custom script contract

| What | Value |
| --- | --- |
| argv | `$1` = vault path, `$2` = queue folder path (absolute, no trailing slash) |
| env | `DISTILL_VAULT`, `DISTILL_QUEUE_DIR` (same values), `DISTILL_COLLECTOR_ID`, `DISTILL_RUN_ID`; the user's login environment otherwise; no Distill secrets |
| working directory | a fresh temporary folder (`$TMPDIR/distill-run-<id>`), deleted after the run |
| stdin | closed (`/dev/null`) |
| user | the logged-in user, with the user's permissions (never elevated) |
| where to write | **only the queue folder**. Distill doesn't enforce this; it reports files that appeared in the queue during the run as "files added" |
| partial writes | write to a temporary name and rename it, or rely on the settle delay: a file still changing is not batched |
| exit | `0` = success; anything else = failed. Files the script already wrote stay in the queue |
| timeout | default 5 minutes, maximum 1 hour. At the timeout Distill sends SIGTERM to the process group, then SIGKILL 10 s later; the run is logged as "timed out" |
| output | stdout and stderr captured separately; the last 64 KB of each is kept |

Distill never reads a script's output as note content. Only files in the
queue folder go into batches.

## Consent and safety

- **Nothing runs before explicit consent.** A new custom collector is saved
  off, with a consent card: "Distill will run this code on your Mac as you.
  It can read and change anything you can and use the network." Run now and
  the switch stay disabled until the user chooses **Allow and turn on**.
- **Consent is bound to the script's sha256.** That is the file's content for
  a file source, or the stored code for inline. Before every run the core
  hashes the script. If the hash differs from the allowed one, the run does
  not start ("Not run · the script changed since you allowed it"), the
  collector shows "Needs your OK", and the consent card shows the old and new
  hashes with **Allow this version**. Editing inline code and saving it also
  asks again.
- **Revoke** turns the collector off and clears the allowance.
- **Scripts run only on their schedule or with Run now.** Never as part of
  processing notes, never from Ask, never from an agent or the CLI without the
  same consent record. The CLI can list collectors and their runs; it never
  grants consent.
- **No sandbox is promised.** Distill does not restrict a script's file
  system or network access. The UI says so plainly, and the spec must not
  claim otherwise.
- The approval gate is unchanged. Collected files go through the normal
  batch, review and apply. A collector cannot write to the vault through
  Distill.

## Run history and History

- Each collector keeps its runs: start time, trigger (schedule, Run now,
  catch-up), result (success, nothing new, failed, timed out, skipped,
  running), duration, and exit code (scripts). Folder runs also keep a
  per-file outcome (Moved, Skipped · already collected, Waiting · still
  changing, Error). Script runs also keep the files added and the output
  tails.
- **Retention:** 30 days or the newest 200 runs per collector, whichever
  keeps more. Quiet runs ("Nothing new") collapse in the list ("14 runs with
  nothing new"). The ledger is kept for good: it is what prevents
  re-collecting.
- Stored at `<state>/collectors/runs/<collector-id>.jsonl` and decoded
  leniently, like `jobs.json`.
- **History** (sidebar) does not get a Collectors tab. Collector runs are
  operational logs and live in the collector's detail. What History → Jobs
  already shows is enough: the batch that processed collected files. Queue
  rows and the job's source list name the collector ("Collected by Distill
  Inbox at 9:00 AM").
- **Notifications:** none for success. A failed run, or a script that needs
  consent again, raises the sidebar count. A macOS notification is sent only
  on the first failure after a success, so a broken collector doesn't keep
  notifying every hour.

## Queue folder path (Queue screen)

The Queue screen shows the active vault's queue folder under the "Next batch
at … · every …" line, for every title ("All caught up", "N sources in the
queue", "N in this batch · M waiting"):

- the path, with `~` for the home folder, truncated in the middle;
- hover shows the absolute path;
- **Copy path** copies the absolute path, and the label reads "Copied" for
  2 s;
- **Reveal in Finder** opens the folder;
- if the folder is missing, the path turns peach and **Create folder** is
  offered.

Settings → Vaults keeps its "Queue: <folder name>" summary and the full
editor.

## API and contract (built)

Built 2026-10-04 in `core/src/contracts.ts` (types, `DistillCore` methods in
the "v4: collectors" block, `CoreEvent` variants). The proposal as first
written is kept below for reference; the deviations and what was added
follow it.

### The proposal (2026-10-04, as designed)

```ts
type CollectorKind = 'folder' | 'script';           // built-ins add kinds via the registry
interface Collector {
  id: string; kind: CollectorKind; name: string; vaultPath: string;
  enabled: boolean; schedule: { cron: string; preset?: 'every15' | 'hourly' | 'daily' | 'weekdays' | 'custom' };
  folder?: { source: string; afterCollect: 'copy' | 'move' };  // kind folder; 'copy' by default
  script?: { source: { file: string } | { inline: string }; interpreter: 'zsh' | 'python3' | 'node';
             timeoutSeconds: number; allowedSha256?: string; allowedAt?: string };
  createdAt: string; updatedAt: string;
}
interface CollectorRun {
  id: string; collectorId: string; trigger: 'schedule' | 'now' | 'catchup';
  startedAt: string; endedAt?: string;
  result: 'running' | 'success' | 'nothing' | 'failed' | 'timedout' | 'skipped' | 'notTrusted';
  exitCode?: number; filesAdded: string[];
  files?: { name: string; outcome: 'copied' | 'moved' | 'skipped' | 'waiting' | 'error'; reason?: string }[];
  stdoutTail?: string; stderrTail?: string;
}
```

- Endpoints:
  - `GET /collectors`
  - `POST /collectors`
  - `PATCH /collectors/:id`
  - `DELETE /collectors/:id`
  - `POST /collectors/:id/run`
  - `POST /collectors/:id/stop`
  - `POST /collectors/:id/consent { sha256 }`, which must match the current
    hash;
  - `DELETE /collectors/:id/consent`
  - `GET /collectors/:id/runs`
  - `GET /collectors/:id/collected?query=` (Already collected, newest first)
  - `DELETE /collectors/:id/collected/:sha256` (Forget one; `DELETE /collectors/:id/collected` forgets all)
- Events: `collector.run.started`, `collector.run.output` (throttled),
  `collector.run.finished`, `collector.changed`.
- Collectors are stored in `<state>/collectors.json`, with additive schema
  and lenient decoding. They are not in `settings.json`, because runs and
  consent change often.

### Built: deviations from the proposal, and why

- **Routes are under `/v1`**, like every other route: `/v1/collectors`,
  `/v1/collectors/:id/run`, and so on. Same paths otherwise.
- **`CollectorRun.result` has two more values:**
  - `queued`: a run waits for a free slot (at most 2 collectors at once) or,
    for a script, for a batch in the same vault (`waiting: 'slot' | 'batch'`).
    Without it, Run now while two others run would have nothing to return.
  - `stopped`: the user pressed Stop (otherwise indistinguishable from a
    failure).
- **`CollectorRun` has more fields** the UI needs: `kind`, `vaultPath`,
  `durationMs`, `counts` (copied, moved, skipped, waiting, errors, added; for
  "Copied 3 files · skipped 2 already collected"), `error {code, message}`,
  `skipReason` ("the 6:01 AM run was still going"), `signal`, `sha256` (the
  script hash that ran or was refused), and per-file `queueName` and `size`.
  Error codes: `sourceMissing`, `noPermission`, `queueMissing`,
  `vaultMissing`, `scriptMissing`, `interpreterMissing`, `scriptFailed`,
  `notAllowed` (never allowed), `scriptChanged`, `interrupted` (the core
  stopped mid-run), `other`. `notTrusted` runs carry `notAllowed` or
  `scriptChanged`.
- **`Collector.status`** is computed on every read and never stored:
  `running`, `nextRunAt`, `lastRun` (without files and output tails),
  `currentSha256` and `scriptProblem` (scripts), `needsConsent`,
  `collectedCount` (Folder, "Already collected: N files"), and
  `needsAttention` (the sidebar count: last run failed, timed out or not
  run, or the script needs consent).
- **Ledger entries are `CollectedFile`:** `sha256`, `name`, `sourcePath`,
  `size`, `mtime`, `collectedAt`, `collectorId`, `queueName`, `outcome`
  (copied | moved). The file also stores `mtimeMs` for the path+size+mtime
  shortcut.
- **Undo of Forget is in the core:** `forgetCollected` returns what it
  removed and `POST /v1/collectors/:id/collected/restore {files}` puts it
  back, so Undo works even after the sheet re-fetches.
- **Two small routes were added:** `POST /v1/collectors/:id/create-folder
  {which: 'source' | 'queue'}` (the Create folder buttons) and `POST
  /v1/collectors/check-schedule {cron}` → `{valid, error?, preset?,
  nextRuns[3]}` (ScheduleField's validation and next run).
- **Run now returns `{run}`;** Stop returns `{run}` or `{run: null}` when
  idle; consent `POST` and `DELETE` return the collector.
- **Changing the interpreter clears consent:** the same code under another
  interpreter is another program. A changed source keeps the old
  `allowedSha256` so the consent card can show old and new hashes.
- **A script is always created off**, even when `enabled: true` is sent;
  `PATCH {enabled: true}` without a current consent is `invalid_state`.
- **The ledger is append-only for collecting; Forget rewrites it**
  atomically (temp file and rename), keeping any line this build can't read.
- **Forget all removes the entries whose source is this collector's
  folder.** A file can still be skipped after Forget all when the same bytes
  were collected from another folder into the same vault (dedupe is
  vault-wide). Forget one removes every entry with that sha256 in the vault.
- **Deleting a collector deletes its run history**; the ledger stays.
- **A file skipped because it is unchanged since it was collected (same
  path, size and mtime) gets no per-file line**, only `counts.skipped`.
  With copy as the default every original stays in the folder, so a line
  for each would make every run's record grow with the folder (500 files ≈
  45 KB per run, 30 days of hourly runs ≈ 30 MB). Content matches under
  another name ("gyokuro copy.md") still get their "Skipped · already
  collected" line. `GET …/runs` returns the newest 50 unless `limit` is
  given.
- **The batch gate covers one direction only (open for the lead).** A
  script never *starts* while a batch runs or applies in its vault, but a
  script that is already running when a batch starts (or the user
  approves) is not paused or waited for. Enforcing it would mean the
  engine's batch and apply wait for running scripts in that vault.
- **A core shutdown records running and queued runs as `failed`, code
  `interrupted`**, not `stopped` (which means the user pressed Stop).
- **No built-in registry yet.** Folder is the only built-in, and its fields
  are fixed in the contract (`folder`), so the detail pane can't render
  them from a registry yet. The registry (and a route listing built-in
  kinds and their fields) comes with the second built-in; adding it is
  additive.

### Built: the API

| Method and path | Core method | Returns |
| --- | --- | --- |
| `GET /v1/collectors` | `listCollectors()` | `{collectors}` |
| `POST /v1/collectors` (201) | `createCollector(NewCollectorInput)` | the collector |
| `GET /v1/collectors/:id` | `getCollector(id)` | the collector (404 `collector_not_found`) |
| `PATCH /v1/collectors/:id` | `updateCollector(id, CollectorPatch)` | the collector |
| `DELETE /v1/collectors/:id` | `deleteCollector(id)` (409 while running) | `{id, deleted}` |
| `POST /v1/collectors/:id/run` | `runCollector(id)` (409 if one is queued or running) | `{run}` |
| `POST /v1/collectors/:id/stop` | `stopCollector(id)` | `{run}` or `{run: null}` |
| `POST /v1/collectors/:id/consent {sha256}` | `allowCollector(id, sha256)` (409 on a hash mismatch) | the collector, on |
| `DELETE /v1/collectors/:id/consent` | `revokeCollector(id)` | the collector, off |
| `GET /v1/collectors/:id/runs?limit=` | `listCollectorRuns(id, {limit})` | `{runs}`, newest first |
| `GET /v1/collectors/:id/collected?query=` | `listCollected(id, query)` | `{files}`, newest first |
| `DELETE /v1/collectors/:id/collected/:sha256` | `forgetCollected(id, sha256)` | `{forgotten}` |
| `DELETE /v1/collectors/:id/collected` | `forgetCollected(id)` (Forget all) | `{forgotten}` |
| `POST /v1/collectors/:id/collected/restore {files}` | `restoreCollected(id, files)` | `{restored}` |
| `POST /v1/collectors/:id/create-folder {which}` | `createCollectorFolder(id, which)` | the collector |
| `POST /v1/collectors/check-schedule {cron}` | `checkSchedule(cron)` | `ScheduleCheck` |

Events (SSE `event:` is the type, as for every core event):
`collector.changed` (`{collector, deleted?}`), `collector.run.started`
(`{run}`), `collector.run.output` (`{collectorId, runId, stream, text}`,
the text added since the last event, at most every 250 ms per run) and
`collector.run.finished` (`{run}`).

CLI: `distill collectors list`, `distill collectors run <id>` (waits for the
run; exit 1 when it failed, timed out or was not run) and `distill
collectors history <id> [--limit N]`, all with `--json`. The CLI cannot add,
change, delete or allow a collector.

### Built: behaviour the spec did not pin down

- **Scheduler:** a 15-second tick in the core (`start()`), local time. A
  due tick handled more than 2 minutes late, or with two or more ticks
  missed, runs once with trigger `catchup`; the last handled tick is
  persisted in `collectors.json` (`ticks`), so this works across restarts.
  A new collector, one turned on, or a new schedule counts from that moment
  (no catch-up for time before). On the spring-forward day, a time that
  doesn't exist (2:30 AM) is skipped. Cron day matching follows Vixie cron:
  when both day-of-month and day-of-week are restricted, either matches;
  day-of-week 7 is Sunday; month and weekday names are accepted.
- **"Never run scripts while a batch applies":** a script run waits
  (`queued`, `waiting: 'batch'`) while any job in its vault is `running`
  (agent turns and the apply). A job waiting for approval does not block it.
  Folder runs are not held. Waiting runs start when the job changes state.
- **"Not run" is recorded once:** while a script waits for consent, a
  scheduled tick records a `notTrusted` run only when the last run wasn't
  already one for the same hash, so history doesn't fill up every hour.
- **Folder details:** symlinks are left alone like subfolders; files with a
  partial-download suffix (`.crdownload`, `.part`, `.download`, `.tmp`,
  `.partial`) are "Waiting · still downloading"; hidden files get no line.
  A copy whose source changed while copying is removed and the file waits
  for the next run. Copies keep the original's mtime (set explicitly). If
  every eligible file failed, the run is `failed`; if some were collected,
  it is `success` with `counts.errors`.
- **Scripts:** run as `<interpreter> <script> <vault> <queue>`, with the
  interpreter found on the login shell's `PATH` (`$SHELL -l -c`, cached 10
  minutes). Inline code is written to a temp file with exactly the hashed
  bytes (`collector.zsh`, `.py`, or `.mjs` for node). The environment is the
  core's, minus every `DISTILL_*` variable, plus the four documented ones.
  The working folder is `$TMPDIR/distill-run-<run-id>-XXXX`, deleted after
  the run. A missing queue folder fails the run before the script starts
  (`queueMissing`). After a timeout or Stop the leader gets SIGTERM, the
  group SIGKILL 10 s later, and any stragglers SIGKILL as soon as the
  leader exits. A script with exit 0 and no new files is "Nothing new".
  A file source is hashed right before it starts and run from its path, so
  a change in the milliseconds between hash and start is not caught.
- **Notifications** (first failure after a success) are a client job; not
  built.

## macOS app (built)

Built 2026-10-04 from canvas v63.

- **Code:** `clients/macos/Sources/DistillKit/Collectors.swift` (DTOs,
  lenient: unknown kinds, results, error codes, outcomes, interpreters and
  presets stay raw strings; the `CoreClient` methods for every route) and
  `CollectorText.swift` (all wording: rows, title line, schedules, run lines).
  The app: `CollectorsStore.swift` (state, events, commands),
  `CollectorsScreen.swift` (list, detail, status card, settings, runs),
  `CollectorsSheets.swift` (empty state, Edit form, Add and Already collected
  sheets) and `CollectorsComponents.swift` (CollectorRow, QueuePath,
  ScheduleField, RunLogEntry, ScriptConsent, with the schema's names and
  props). Snapshot states: `SnapshotCollectors.swift`, one per board frame
  (`collectors-*` ids) plus `-900` variants and `collectors-old-core`.
- **Events:** `collector.changed` replaces the collector (status included);
  `run.started` / `run.finished` update the run list; `run.output` appends to
  the live output (last 64 KB per stream). Selecting a collector refetches it,
  because a file script edited on disk sends no event.
- **Old cores:** a core without the routes shows the calm "Update the Distill
  core" state, and the sidebar shows no count.
- **Consent:** Allow sends the core's `status.currentSha256`; the app never
  hashes. When the core can't read the script (no hash), Allow is off and the
  card shows `scriptProblem`.
- **Sheets** are drawn in the window over a dimmed backdrop (as on the boards),
  not as system sheets. Cancel and the close button dismiss them (Esc is wired with `.onExitCommand` and a cancel shortcut, not yet checked in the running app).
- **Queue path:** under the schedule line on every Queue title. Create folder
  makes the active vault's queue folder from the app (`mkdir -p` of the same
  path the core creates when files are added); no core change.

Where the app differs from the boards (also in [Decisions](decisions.md)):

- The sidebar count comes from the data (`needsAttention`). Board E draws no
  count although its list has a Failed and a Needs your OK row; the app shows
  2 there.
- A running Folder run says "Copying…" (or "Moving…"), not "Copying 2 of 5…":
  the core sends no per-file progress while a Folder run runs.
- The list row's daily schedule reads "Daily at 7:00 AM" (the board: "Daily at
  7:00"), so the 12-hour clock isn't ambiguous.
- Below about 760 pt of content width (a 900 pt window) the list column
  narrows from 300 to 240 pt, and the title row puts the switch, Run now and ⋯
  under the name instead of cutting the name. The Edit form puts its labels above the fields below 460 pt, "After collecting" becomes a menu when the two pills don't fit, and the consent card puts the hash under the command.
- Not built: the "Collected by … at …" line on queue rows (card "In the
  queue"): `QueueEntry` doesn't say which collector brought a file. It needs a
  core field. The ⋯ menu is a system menu, so the "⋯ menu" card has no
  snapshot. macOS notifications for a first failure are not built.
- Timeout choices in Edit → Advanced: 1, 5, 15, 30 minutes and 1 hour.

## Open questions

The owner answered the questions from the first draft on 2026-10-04 (see
[Decisions](decisions.md)):

- one list for all vaults, each collector picking its target vault;
- Folder copies by default, with Move as an option;
- dedupe is by content (above);
- the queue path is shown with `~`, and hover and Copy give the full path.

None is open now.
