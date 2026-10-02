---
title: Queue and batching
status: built
updated: 2026-10-02
---

# Queue and batching

Sources collect in a per-vault queue folder and are processed together on a
schedule, not one by one. Code: `clients/macos/Sources/WorkerCore/Queue.swift`,
`clients/macos/Sources/WorkerCore/BatchInterval.swift`, `WorkerEngine.tick/processQueue`.

## Queue folder

- Each vault profile has its own queue folder. Default:
  `~/Documents/Distill Queue/<vault name>`. It may also be the vault's `inbox/`.
- Pending files: top-level, non-hidden regular files. Folders are left alone.
  Partial downloads are skipped (`.crdownload .part .download .tmp .partial`).
- Settle delay (`settleSeconds`, default 600 s = 10 minutes in the TS core;
  configurable in Settings → Batch; an explicit value is always honored): a
  file must be unmodified that long
  before it is batched.
- The queue may not be inside the vault's `.raw/` or `.vault-meta/`.
- **Remove** (`removeQueueEntry(path)`, `DELETE /v1/queue/entries`): moves a
  pending file of the active queue folder to the user's Trash (`~/.Trash`,
  collisions become `name 2.ext`); a note's `.distill.json` manifest goes with
  its `.md`. Refused for paths outside the folder, folders and symlinks
  (`invalid_request`) and, when the queue is the inbox, files a batch already
  took (`invalid_state`).

## Schedule

- Interval is stored as total minutes and edited as days (0–30), hours (0–23)
  and minutes (0–59), minimum 1 minute (`BatchInterval`). Presets: 5 min,
  15 min, 1 hour, Daily.
- A 5-second tick refreshes the queue; when `nextBatchAt` passes and automatic
  batching is on, a batch runs and the next one is scheduled.
- **Process now** (⌘R) runs a batch immediately and ignores the settle delay.

## Batch

1. Blocked when setup is invalid or another job holds the vault.
2. Settled files are moved into `<vault>/inbox/` (name collisions become
   `name 2.ext`). When the queue is the inbox, files stay and only unclaimed
   ones are taken.
3. One job is created for all of them (the queue-consuming `JobKind`, today
   Ingest).
4. Labels (TS core; see [Labels and sources](labels-and-sources.md)): the core
   decides each input's labels from its manifest and the `labeling` settings.
   When an input needs an AI suggestion (a queue-folder text file, or a CLI
   note with nothing confirmed), a pre-step runs the `labelSuggest` runner
   before the first turn. Its cost is recorded as an app turn; a failed
   suggestion leaves that input unlabeled; Cancel during the pre-step cancels
   the job. The plan is saved as `labels.json` in the job directory.
5. The first turn starts. Its prompt has a **Labels** section that lists, per
   input, the exact properties for its source page: confirmed → `tags` +
   `labels_by: user`; unconfirmed AI → `tags` + `labels_by: ai`,
   `labels_reviewed: false`, `labels_origin`; otherwise no labels. The
   approval gate is unchanged.

## Progress

A batch emits `batch` progress keyed by its job id (see
[Architecture](architecture.md)):

| `stepIndex` points at | While | Message |
| --- | --- | --- |
| `Suggesting labels` (only with a pre-step) | the label pre-step; `done`/`total` count files | `Suggesting labels for N sources` |
| `Read sources` | the agent turn | `Reading N sources into <vault name>` |
| `Drafting page changes` | the core inspects the bundle the turn wrote | `Checking the page changes` |
| `Ready for review` | finished: the job awaits approval or completed | `Ready for review` / `Done` |

`Moved to inbox` is done once the job exists. The runner gives no signal
inside a turn, so reading and drafting are not told apart while the turn
runs. Reply and Allow turns start a new run of the same key at `Drafting page
changes`. Failed and cancelled batches finish with `Failed` (and `error`) or
`Cancelled`.
