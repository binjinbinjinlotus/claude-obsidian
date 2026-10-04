---
type: spec
title: Collectors
status: designed
created: 2026-10-04
updated: 2026-10-04
tags:
  - distill
  - collectors
  - queue
---

# Collectors

Build status: **designed** (canvas row "7 · Collectors": boards Collectors and
CollectorsScript; queue path on Main, MainLoading and MainEmpty). Nothing is
built yet. The contract section below is **proposed**: the lead owns
`core/src/contracts.ts`.

Collectors bring material into a vault's queue folder automatically, on a
schedule. They only fill the queue. What they bring is batched, reviewed and
applied like a file the user drops, so nothing reaches the vault without
approval ([Queue and batching](queue-and-batching.md),
[Approval and review](approval-and-review.md)).

## Where it lives

- A **Collectors** sidebar item directly under Queue, because it feeds the
  queue. It shows a peach count only when collectors need the user: the last
  run failed, or a script waits for consent. Otherwise it shows no count.
- The screen is a list plus a detail, like the Actions lists: `CollectorRow`
  rows on the left (kind tile, name, last-run line, status pill), the
  selected collector's settings and run history on the right. **Add
  collector** is in the header, and the header shows the active vault's queue
  folder (`QueuePath`).
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

- **Settings:** the source folder (default `~/Distill Inbox`, created on
  first save if it is missing), the target vault (the active vault by
  default), and the schedule (default every hour).
- **Run:** it moves every regular file at the top level of the source folder
  into the target vault's queue folder. "Moves" means the file leaves the
  source.
- **It leaves these where they are:**
  - hidden files (names starting with `.`) and macOS metadata such as
    `.DS_Store` and `Icon\r`;
  - subfolders. They are not entered in v1; folders inside are left alone.
  - **partial files**: a file whose mtime is within the queue's settle delay
    (`settleSeconds`, 10 minutes by default; the same rule as batching). It is
    shown as "Waiting · still changing", and a later run picks it up.
  - **files already collected**: see the ledger below. These are shown as
    "Skipped · already collected" and stay in the source folder.
- **Name clashes:** if the queue folder already has a file with that name,
  the moved file gets " 2", " 3", and so on before its extension. The
  existing file is never replaced.
- **Errors:**
  - Source folder missing: the run fails, nothing moves, and the user is
    offered Choose…, Create folder or Turn off.
  - No permission (macOS privacy): the run fails, and the user is offered
    Choose again… (so macOS asks) or Open System Settings.
  - Target queue folder missing: the run fails, and the user is offered
    Create folder (the same path).
  - One file that fails to move: the error is logged on its line, and the
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

- The core keeps one ledger per collector kind and vault in its state
  directory: `<state>/collectors/ledger-<vault-id>.jsonl`, append-only, under
  the user-data rules in [User data](user-data.md). Each entry holds the
  source path, size, mtime, sha256, collected-at time, collector id, and the
  queue file name.
- **The ledger is keyed by content (sha256).** A file whose sha256 is already
  in the vault's ledger is skipped and left where it is, whatever its name
  and wherever it came from. So "gyokuro copy.md" with the same bytes is
  skipped too, and a file the user puts back after it was collected is not
  collected again.
- Same path with new content is a new file and is collected again; the ledger
  gets a second entry for that path.
- Hashing is cheap to avoid: if path, size and mtime all equal an entry, the
  run treats the file as already collected without hashing it. Otherwise it
  hashes before moving.
- The ledger outlives the collector. Deleting a Folder collector keeps its
  ledger, so a new Folder collector on the same folder does not take old
  files again. A **Forget collected files** action, behind a confirmation,
  is the only way to clear it.
- Custom scripts are not deduped by Distill: they own what they write. The
  ledger records files that appear in the queue during their run, for the
  run log only.

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

- `ScheduleField` shows the expression next to every preset (read-only unless
  the preset is Custom), a plain-English preview ("Mon, Wed and Fri at
  8:30 AM"), and the next run. An invalid expression keeps Save off.
  Seconds, `@reboot` and nicknames are not accepted; `@hourly` and `@daily`
  are accepted and shown as their preset.
- The core's scheduler wakes for the earliest next run across collectors.
  The schedule is independent of the batch schedule. A collected file waits
  for the next batch; when a file that has already settled is moved, it keeps
  its mtime, so it is ready at once.
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

## API and contract (proposed)

The lead decides the final shapes in `core/src/contracts.ts`.

```ts
type CollectorKind = 'folder' | 'script';           // built-ins add kinds via the registry
interface Collector {
  id: string; kind: CollectorKind; name: string; vaultPath: string;
  enabled: boolean; schedule: { cron: string; preset?: 'every15' | 'hourly' | 'daily' | 'weekdays' | 'custom' };
  folder?: { source: string };                       // kind folder
  script?: { source: { file: string } | { inline: string }; interpreter: 'zsh' | 'python3' | 'node';
             timeoutSeconds: number; allowedSha256?: string; allowedAt?: string };
  createdAt: string; updatedAt: string;
}
interface CollectorRun {
  id: string; collectorId: string; trigger: 'schedule' | 'now' | 'catchup';
  startedAt: string; endedAt?: string;
  result: 'running' | 'success' | 'nothing' | 'failed' | 'timedout' | 'skipped' | 'notTrusted';
  exitCode?: number; filesAdded: string[];
  files?: { name: string; outcome: 'moved' | 'skipped' | 'waiting' | 'error'; reason?: string }[];
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
- Events: `collector.run.started`, `collector.run.output` (throttled),
  `collector.run.finished`, `collector.changed`.
- Collectors are stored in `<state>/collectors.json`, with additive schema
  and lenient decoding. They are not in `settings.json`, because runs and
  consent change often.

## Open questions

See the 2026-10-04 entry in [Decisions](decisions.md) for the defaults
chosen. Still open for the user:

1. Should collectors be per vault (the list follows the active vault), or
   global with a target vault each? The design shows a global list, with the
   target on each collector.
2. Should Folder ever copy instead of move, for example from a synced folder
   the user wants to keep? The design always moves.
3. Is the content-keyed dedupe right? With it, a file the user re-drops into
   `~/Distill Inbox` on purpose stays skipped. The alternative is to key the
   ledger by path and content.
