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
differs from the boards. **Script files, TypeScript and packages** (v6,
2026-10-04) are built in the core, API, CLI and the Mac app (board
CollectorsScriptFiles, canvas v67; see "Built in the Mac app: script files,
packages, Test run, Run now (v6)"). See "Script files and packages (v6)". The contract is in
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

- **Source:** a script Distill keeps as a real file in the collector's own
  folder (code written in the app), or the user's own file. Since v6 code
  is never stored in `collectors.json`; see "Script files and packages
  (v6)". The language is zsh, Python (`python3`), JavaScript (`node`) or
  TypeScript (`typescript`, on Node), resolved on the user's login-shell
  `PATH` when the run starts. A script runs as `<interpreter> <path>
  <vault> <queue>`.
- **Packages:** a script Distill keeps can have a `package.json`
  (JavaScript, TypeScript) or a `requirements.txt` (Python) next to it;
  Distill installs them into that folder.
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
- **Run now** starts a run at once. It does not move the schedule. Every
  collector has it, whatever its kind or state (off, failed, never run);
  see "Run now everywhere (v6, built)".
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
  a file source, or the stored code for inline. Since v6 it also covers the
  package manifest of a script Distill keeps (see "Script files and packages
  (v6)"): installing packages runs third-party code. Before every run the core
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
- **Deleting a collector deletes its run history**; the ledger stays. Since
  v6 its script folder goes to a trash for 30 days (see below).
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
  minutes). Since v6 a script Distill keeps runs from its file in its
  folder. Only an old inline record that could not be moved to a file (the
  write failed) is still written to a temp file with exactly the hashed
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

### Built: subfolders and .gdoc (core, 2026-10-04)

Code: `collectSubfolder` in `core/src/collectors/folder.ts`. Tests:
`core/src/collectors/collectors.test.ts` ("includeSubfolders …", "a
subfolder is one folder item …").

- **`folder.includeSubfolders`:** new collectors get `true` (as designed).
  A collector saved before this build has no field and reads as **off**, so
  an existing collector doesn't start taking subfolders the user kept in its
  folder without them choosing it. `PATCH {folder: {includeSubfolders}}`
  takes a boolean (anything else is `invalid_request`).
- **Order:** subfolders run before top-level files, by name.
- **A subfolder** is walked like a queue folder item (hidden files, symlinks
  and `.DS_Store` skipped; 8 levels at most). Partial downloads inside →
  "Waiting · still downloading"; any file changed within the settle delay →
  "Waiting · still changing"; deeper than 8 levels → "Skipped · too deep".
  Each file is checked against the ledger (path+size+mtime, else sha256).
  - Nothing new → counted in `counts.skipped`; a line ("already collected")
    only when a file matched by content alone, like top-level files.
  - More than 200 new files or 500 MB of them → "Skipped · too big".
  - Copy: only the new files are copied into `<name>` (`name 2` on a
    clash), relative paths and mtimes kept, then `.distill-folder.json`
    with the whole tree, files collected before marked `seenBefore`. If a
    file in the source changed while copying, the copy is removed and the
    folder waits for the next run.
  - Move: the whole folder moves (an exclusive `mkdir` claims the name,
    then a rename), then the manifest is written into it.
- **Run line:** one per folder item: `{name: "Tea trip/", kind: "folder",
  outcome, queueName, fileCount, newCount, size}` (size = the new files'
  bytes). A folder counts as one in `counts.copied`/`moved` and
  `counts.added`; `filesAdded` gets its queue name.
- **Ledger:** one entry per new file (one per distinct sha256 inside a
  folder): `name` is `<folder>/<path inside>`, `sourcePath` the file's own
  path, `queueName` `<queue folder name>/<path inside>`. "Already collected:
  N files" and Forget all now count every ledger entry under the source
  folder, nested files included (before: direct children only).
- **`.gdoc`:** collected like any file (top level, or inside a subfolder);
  in the queue it waits ("needs Google Drive access").
- **Script runs:** "files added" now also names folders that appeared in
  the queue folder during the run.

## Script files and packages (v6)

Owner request (2026-10-04): "the script should be saved as a script, not
inline in json, it should support zsh, python3, js and typescript; it should
support package install for js and typescript; all collectors should support
run now." Built in the core, API and CLI on 2026-10-04 (`core/src/collectors/files.ts`,
`packages.ts`, hooks in `index.ts`; tests in `files.test.ts` and
`server/http-collectors.test.ts`). Designed on canvas board
CollectorsScriptFiles (frames T–Z2); Mac UI not built.

### Where scripts live

```
<state>/collectors/scripts/<collector-id>/
  collector.zsh | collector.py | collector.js | collector.ts   the script
  package.json (JavaScript, TypeScript) | requirements.txt (Python)   optional
  node_modules/ | .venv/                                        installed packages
```

- `collectors.json` stores `script.source = {file: <absolute path>, managed:
  true}`. The user's own file stays `{file}` (no `managed`), runs from where
  it is, and Distill never writes to it.
- Files are written atomically, mode 0600, folders 0700.
- Old clients keep working: `{inline: code}` on create or PATCH is written to
  the managed file; `{file: <the managed path>}` sent back unchanged stays
  managed; an old app reads the managed path like any file. `{file}`
  pointing at **another** collector's managed file (the app's Duplicate)
  gives the new collector its own copy, manifest included.
- **Migration:** at start, every inline script is written to its folder with
  the exact same bytes (node code keeps `collector.mjs`, the extension its
  inline code always ran with), after `collectors.json` is copied to
  `collectors.json.pre-script-files-<time>` next to it. The hash doesn't
  change, so an allowed script stays allowed. It is idempotent: identical
  bytes already in the folder are reused. A script whose file can't be
  written stays inline and still runs.
- A managed path from another state dir (a restore, another
  `DISTILL_STATE_DIR`) is re-pointed at this state dir's folder on load.
- **Language change** renames the managed file to the new extension
  (TypeScript needs `.ts`); a file already holding that name is kept as
  `<name>.old-<time>`. It clears consent, as before.
- **Delete → Distill's trash** (one trash, [Activity log and
  trash](activity-log.md)): before the delete, the trash copies the folder
  without `node_modules`/`.venv` to `<state>/trash/<trash-id>.files/` next
  to the record (`<trash-id>.json`); then the collector removes its folder.
  The item lists `scriptFolder: true`, counts the folder in `sizeBytes`, and
  goes after 30 days (or by the count and size caps) with its folder.
- **Restore** (`POST /v1/trash/:id/restore`) copies the folder back to
  `collectors/scripts/<id>/` (a new id when the old one is taken) and
  re-points the record. The collector comes back off with consent cleared;
  allowing it installs its packages again. A record from before script
  files (inline code) comes back as a file. A folder an earlier v6 build
  moved to `<state>/collectors/trash/` is still found on restore; that
  folder isn't written any more and its leftovers go after 30 days.
- The collectors service on its own (no activity layer, as in its unit
  tests) leaves the folder in place on delete: nothing destroys a script
  without a copy.

### Languages

| Language | `interpreter` | File | Runs with |
| --- | --- | --- | --- |
| zsh | `zsh` | `collector.zsh` | `zsh` |
| Python | `python3` | `collector.py` | the folder's `.venv/bin/python3` once packages were installed (a symlink to the same `python3`), else `python3` |
| JavaScript | `node` | `collector.js` | `node` |
| TypeScript | `typescript` | `collector.ts` | `node` with its built-in type stripping |

TypeScript: the core asks the login shell's `node` for its version and
`process.features.typescript` (cached 10 minutes). Node 22.18+ / 23.6+ strip
types by default (no flag, no warning); 22.6–22.17 get
`--experimental-strip-types --disable-warning=ExperimentalWarning`; older
Node fails the run (`interpreterMissing`, "TypeScript needs Node 22.6 or
later … or add tsx to package.json and Install"). Stripping handles erasable
syntax only (no `enum`, `namespace`, parameter properties). When the folder
has `tsx` installed (a devDependency the user adds), the core runs
`node node_modules/tsx/dist/cli.mjs collector.ts` instead.

### Packages

- **Manifest:** `package.json` for JavaScript and TypeScript, `requirements.txt`
  for Python, in the script's folder; zsh has none. Packages are for scripts
  Distill keeps, not the user's own file (Node resolves packages from the
  script's location, so a folder elsewhere wouldn't be found).
- **When packages install** (the owner: "all package install should be
  completed when adding the script"):
  - **On Allow:** allowing a version whose packages aren't installed for
    its manifest installs them at once (trigger `allow`). That covers adding
    a script (add → review and allow → installing → ready or failed) and
    OK after a manifest change. The collector shows `state: installing`,
    then `ready` or `failed`, before its first scheduled run.
  - **Install** (`POST …/install`, trigger `manual`), also with `{clean:
    true}`.
  - **Safety net before a run** (trigger `beforeRun`): packages went missing
    (`node_modules` deleted by hand). An install of this exact manifest that
    already failed isn't retried by every run: the run fails at once
    (`installFailed`) until Install or a new manifest.
- **How:**
  - `package.json`: `npm install --no-audit --no-fund`, with the `npm` next to
    the `node` scripts run with (so nvm versions match), else `npm` on PATH.
  - `requirements.txt`: `python3 -m venv --symlinks .venv` only when there
    is no working venv, then `.venv/bin/python3 -m pip install
    --disable-pip-version-check -r requirements.txt`. A manifest change
    installs into the existing venv; never `--copies`, never `--clear`.
  - cwd is the script's folder; the environment is a run's (login PATH, no
    `DISTILL_*` variables, plus `npm_config_update_notifier=false`).
  - Timeout 10 minutes; Stop (`POST …/install/stop`) ends it the way Stop
    ends a script.
  - Output: stdout and stderr interleaved, the last 64 KB, with
    `user:password@` in URLs and `_authToken`/`token`/`password` values
    masked (in the stored tail and the live events).
  - `{clean: true}` removes `node_modules` / `.venv` first.
  - The newest install is kept in `<state>/collectors/installs/<id>.json`
    with the manifest hash of the last successful one.
- **One operation per collector:** Install refuses (`busy`) while a run
  goes; Run now, Test run and a scheduled tick during an install queue the
  run (`waiting: 'install'`), so "Allow and run" works. Installs don't wait
  for a batch (they don't touch the queue or the vault).
- A run that installed first carries `installId`; when that install fails
  the run is `failed`, code `installFailed`, and doesn't start the script.
  A failed install with the change still pending raises `needsAttention`.
- An empty manifest (no packages) needs no install.
- `status.script.manifest.state`: `none` (no packages), `ready`,
  `installing`, `failed` (the last install of this manifest failed),
  `needsInstall`.

### Python venv and the Keychain

The owner accepts one Keychain prompt, not one on every reinstall or
restart. macOS asks again when the program reading an item changes. A venv
made with `--symlinks` has `.venv/bin/python3 → python3.13 → the
framework's python3.13`, the same binary as the login shell's `python3`
(checked by a test with a real venv), so there may be no prompt at all.

- **Never touch the venv:** core start, the inline migration, a state-dir
  re-point, an app or core reinstall, Run now and a manifest change (it
  installs into the same venv). Tested: same inode and mtime after a
  restart, a re-point and a second install.
- **Can bring a prompt:** upgrading or reinstalling Python (the binary
  changes for every program that uses it); a clean reinstall only when
  Python's own path changed since the venv was made; a new collector or a
  restored one (its own venv, but the same binary, so usually no prompt).
- Distill's own secrets go through `/usr/bin/security`, which an app
  reinstall doesn't change.

### Test run

A Test run executes the script exactly like a real run (same consent,
interpreter, packages, environment, timeout, Stop and output capture), but
`$2` and `DISTILL_QUEUE_DIR` are a scratch folder Distill owns,
`<state>/collectors/test-runs/<id>/`, so nothing feeds the next batch.

- `POST /v1/collectors/:id/test` → `{run}` (trigger `test`); scripts only.
  Busy like Run now; it waits for an install; it doesn't wait for a batch.
- The run records `outputDir` and the names it produced in `filesAdded`;
  the app lists them with Reveal in Finder.
- **Kept until the next test run** (the folder is emptied when the next one
  starts), removed when the collector is deleted, and pruned after 7 days at
  core start.
- Not a scheduled run: it is in the run history but never sets
  `status.lastRun`, the sidebar count or the schedule, and the Folder
  ledger is never involved (scripts aren't deduped). `status.script.lastTestRun`
  is the newest one.
- Logged as `collector.test_run`.

### Consent with packages

- The consent hash is `sha256(script)` when there is no manifest (exactly as
  before v6), else `sha256("distill-collector-consent-v2\nscript <sha256 of
  script>\n<manifest name> <sha256 of manifest>\n")`. Editing the manifest
  in the app or in another editor means "Needs your OK", like editing code.
- Install needs the current version allowed (`invalid_state` otherwise).
- `script.allowedFiles {script, manifest}` records each file's hash at
  Allow, so `status.script.changes` can say what changed since ("script",
  "manifest", or both).
- **Not covered:** `package-lock.json` (npm writes it during install) and
  versions a range resolves to at install time. Installs only happen when
  the manifest changed or the user asks.
- An older core restored from a backup sees a different hash for a script
  with a manifest and asks for consent again (it fails closed).

### API (v6)

| Method and path | Core method | Returns |
| --- | --- | --- |
| `GET /v1/collectors/:id/script` | `getCollectorScript(id)` | `CollectorScriptFiles`: path, dir, managed, interpreter, code, sha256 (script alone), manifest {name, path, text, sha256} |
| `PUT /v1/collectors/:id/script {code?, manifest?, baseSha256?, baseManifestSha256?}` | `writeCollectorScript(id, update)` | the files as saved; 409 when the file changed on disk since `base…` was read, or for the user's own file |
| `POST /v1/collectors/:id/install {clean?}` | `installCollectorPackages(id, {clean})` | `{install}` (running); 409 without consent or while busy |
| `POST /v1/collectors/:id/install/stop` | `stopCollectorInstall(id)` | `{install}` or `{install: null}` |
| `GET /v1/collectors/:id/install` | `getCollectorInstall(id)` | `{install}` with `outputTail`, or `{install: null}` |
| `POST /v1/collectors/:id/test` | `testCollector(id)` | `{run}` (trigger `test`, `outputDir`) |

- `NewCollectorInput.script.manifest` sets the manifest at creation.
- `Collector.status.script`: `path`, `dir`, `managed`, `manifest`
  (`name`, `path`, `exists`, `hasDependencies`, `packageCount`, `sha256`,
  `installedSha256`, `needsInstall`, `installing`, `lastInstall` without
  output, `state`), `changes` and `lastTestRun`.
- `CollectorInstall.trigger`: `manual`, `allow`, `beforeRun`.
  `CollectorRun.waiting` adds `install`; `CollectorTrigger` adds `test`;
  `CollectorRun.outputDir` (test runs).
- Events: `collector.install.started {install}`, `collector.install.output
  {collectorId, installId, text}` (throttled by the process, at most 16 KB
  each), `collector.install.finished {install}`.
- New error code `installFailed`; `CollectorRun.installId`.
- CLI: `distill collectors list` prints each script's file path.

### Run now everywhere (v6, built)

What was wrong in the Mac app (the core already ran every kind in every
state): Run now was a hover-only icon in the list; the detail hid it while
a script waited for the user's OK and while the Edit form was open; the ⋯
menus had no Run now. The design (boards Collectors, CollectorsScript,
CollectorsScriptFiles):

- the same title-row slot for every kind and state: Run now; Stop while
  running or installing; **Allow and run** when the script needs the
  user's OK (it allows the version shown, then runs it once);
- it stays while editing (it runs the saved version);
- first item in every ⋯ menu; the selected list row always shows its play
  button;
- a manual run's result shows at once in the status card: one sentence
  ("Run now · added 2 files at 10:42 AM") and the last output lines, with
  Copy output and Hide; failures show stderr in peach.

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

### Built in the Mac app: Include subfolders (2026-10-04, canvas v64)

- **Add, step 2:** "Include subfolders, each as one folder item", on by
  default; the new collector always sends `includeSubfolders`.
- **Edit:** a Subfolders row ("Include subfolders" and the board's hint);
  the From hint now names Google Docs. The patch sends `includeSubfolders`
  only when it changed. Duplicate copies it (an old collector with no field
  duplicates as off, so the copy doesn't start taking subfolders).
- **Settings block:** "Subfolders · Collected as folder items", or "Left
  alone" when off (the board draws only the on state).
- **Run lines:** a subfolder line reads "Copied — Tea tasting trip/ (folder ·
  5 new of 12 files)" (`kind`, `newCount`, `fileCount`; "4 files" when it
  waited or failed), a collected .gdoc "… (waits in the queue: needs Google
  Drive access)". A run that took a subfolder counts items in its summary
  ("Copied 3 items"). The brief's "tea-notes/ · 4 new of 12" was written
  before the board; the app follows the board's wording.
- Code: `FolderCollectorSettings.includeSubfolders` / `subfolders`,
  `FolderPatch.includeSubfolders`, `CollectorRunFile.kind/fileCount/newCount`,
  `CollectorText.runFileName`; `SubfoldersSwitch` in CollectorsComponents.swift.
  Snapshots: `collectors-add-folder`, `collectors-folder(-edit)(-900)`,
  `collectors-folder-history` (the fixtures now match the board).

### Built in the Mac app: script files, packages, Test run, Run now (v6)

Built 2026-10-04 from canvas v67 (board CollectorsScriptFiles, the changed
Collectors and CollectorsScript boards, ScriptEditor, PackagesPanel,
ScriptConsent and CollectorRow).

- **Code:** DistillKit `CollectorScripts.swift` (CollectorScriptStatus,
  CollectorManifestStatus, CollectorInstall, CollectorScriptFiles,
  CollectorScriptUpdate with explicit nulls, the script / install /
  install-stop / test routes), `Collectors.swift` (`managed`,
  `allowedFiles`, `status.script`, `CollectorRun.installId/outputDir`,
  `installFailed`, the `typescript` interpreter), three
  `collector.install.*` events in `Models.swift`, wording in
  `CollectorText.swift`. The app: `CollectorsStore+Scripts.swift` (Allow and
  run, Test run, installs and live output, the shown result, Reveal, Open in
  editor), `CollectorsScriptViews.swift` (ScriptEditor, PackagesPanel, a plain
  code view), `CollectorsStatusCard.swift`, the v6 `ScriptEditForm` and Add
  step 2 in `CollectorsSheets.swift`. Snapshots: `SnapshotCollectorScripts.swift`
  (frames T–Z2 with their ids, 890 pt variants, the four add cards, the delete
  card, an edit conflict, one collector with "Not now").
- **Run now slot:** the title row holds Run now, Stop (running or
  installing; Stop during an install also stops the run waiting for it) or
  Allow and run (allows `status.currentSha256`, then runs). It stays while
  editing. Scripts show a quiet Test run link before it. Run now is disabled
  while the last install of this manifest failed (the board's X2). ⋯ starts
  with Run now (Stop while active; nothing while a script needs the OK, since
  that needs the code on screen). The selected list row always shows its play
  button (not while running or needing the OK).
- **Status card:** installing (elapsed, why, the live output; the run that
  waits shows in Recent runs as "Run now · waits for packages"), install
  failed (its output from `GET …/install`, Install again, Open package.json),
  the result of a run started here (one sentence, the schedule, the last
  output lines, Copy output and Hide; it gives way to any newer run), a Test
  run (blue-grey: its files with sizes, Reveal in Finder, Show output,
  "Schedule unchanged"), and Ready after the install on Allow.
- **Editing:** a v6 script's form is Kept by Distill / Your own file, the
  ScriptEditor (language picker; the file with Reveal and Open; code), the
  PackagesPanel for a kept script (editable manifest, Install, ⋯ Clean
  reinstall… and Open), and "Schedule and Advanced" folded to one line (it
  also holds Into, the vault). Code and manifest save only through
  `PUT …/script` with the hashes the editor loaded, never through PATCH; a
  409 shows "Changed on disk since you opened it" with **Reload** (drop the
  edits) and **Keep editing** (keep the text, save against the file as it is
  now). PATCH carries language, timeout, schedule, vault and the switch
  between kept and your own file (to kept: the code once as `inline`, which
  the core writes to the new managed file).
- **Add, step 2:** Kept by Distill (default) with the language picker, a
  starting template per language and the manifest for JavaScript, TypeScript
  and Python, or Your own file. The sheet scrolls in a short window.
- **Consent:** the card names what changed (`changes`) and, for a new script
  with packages, that allowing installs them. A changed manifest shows at
  once under WHAT CHANGED; the code under Show script / Show changes.
- **Open in editor:** a `.ts` file (often claimed by a video player) or a
  script Terminal would run opens in the default plain-text editor.
- **Code fields** are an NSTextView with smart quotes, dashes and
  replacements off (they broke JSON and shell quoting) and no wrapping, so
  line numbers stay aligned.
- Where the app differs from the boards: see [Decisions](decisions.md),
  2026-10-04, "Collectors v6 in the Mac app".

## Open questions

The owner answered the questions from the first draft on 2026-10-04 (see
[Decisions](decisions.md)):

- one list for all vaults, each collector picking its target vault;
- Folder copies by default, with Move as an option;
- dedupe is by content (above);
- the queue path is shown with `~`, and hover and Copy give the full path.

Open from v6 (script files and packages), for the owner:

- Packages only for scripts Distill keeps. Should Python packages also work
  for the user's own file (its `requirements.txt` and `.venv` in Distill's
  folder for it)? Node can't do that cleanly.
- Answered 2026-10-04: one extra Keychain prompt is fine, not one per
  reinstall or restart (see "Python venv and the Keychain"); packages
  install when a script is added; Test run built; restore through the one
  trash (Activity). `--ignore-scripts` stays open: npm install scripts run
  under the manifest OK.
