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
- **Notes skip the wait.** Every file of a note written by `addNote` (the
  `.md`, its `<stem>.distill.json` manifest and the images the manifest lists)
  is ready at once, so the next batch takes the whole set together
  (`noteSetPaths`, `readyFiles` in `core/src/engine/queue.ts`).
- **Problems**: a file the core can't read is marked with `problem` and left
  out of batches (even Process now) until the user removes it.
- Queue entries (`QueueEntry`, built by `queueList` in `queue.ts`):
  `settled`; `readyAt` = modified + `settleSeconds`, rounded up to the
  second, absent once ready; `kind` (`note` for a note row, else `file`);
  `problem` (a reason); `changing` (true while not settled when the file's
  mtime moved past the mtime the core first saw for that path; omitted when
  false; the engine keeps first-seen mtimes in memory and forgets a path once
  it leaves the queue or the vault changes).
- **One row per note.** A note set whose `.md` is queued is listed once, for
  the `.md`, with `members` (its `.distill.json` manifest, then the listed
  images present in the queue) and `note` from the manifest: `source` (the
  taxonomy label, "in-person" → "In person"; free text as given),
  `labelsConfirmed` (manifest `labels` present, even empty) and `imageCount`.
  Members are not listed on their own. A member's problem is carried up to
  the note row ("<file>: <reason>"). An orphan manifest or image (its `.md`
  gone) is an ordinary row again.
- `status().queueCount` counts these rows, not files.
  The core re-emits the queue only when an entry changes (for example
  `settled` flips), so clients never need a ticking timer.
- The queue may not be inside the vault's `.raw/` or `.vault-meta/`.
- **Remove** (`removeQueueEntry(path)`, `DELETE /v1/queue/entries`): moves a
  pending file of the active queue folder to the user's Trash (`~/.Trash`,
  collisions become `name 2.ext`). Removing a note row moves its whole set
  (images, manifest, then the `.md`). Removing a member alone (a manifest or
  image whose `.md` is still queued) is refused with `invalid_request`, so the
  note never loses its manifest. Also refused for paths outside the folder,
  folders and symlinks (`invalid_request`) and, when the queue is the inbox,
  files a batch already took (`invalid_state`).

## Queue screen

Canvas: "Queue rows: every state" and Main. Code: `QueueView` in
`MainView.swift`, `QueueRowViews.swift`, formatting in
`DistillKit/QueueRows.swift`. Nothing on this screen ticks.

- Header: "N sources in the queue" and **Next batch at 5:30 AM · every 2
  hours** (a clock time; it changes only when the schedule does). When the
  window is narrow (900 pt) the Drop files | Write a note switch and Process
  now move under the title instead of squeezing it.
- Row meta line: **Pasted at 3:04 AM · 36 KB** (Screenshot/Clipping files
  made by paste intake), **Dropped at … · size** (anything else), plus
  **· still changing** when `changing`. Notes: **Written note · In person ·
  labels confirmed** (+ **· 1 image** / **· N images**); a note with nothing
  to summarize, or from an older core without `note`, shows **Written note ·
  Added at …**. Another day adds the date ("Sep 3 at 2:12 AM").
- Status pills: **Ready at 3:14 AM** (gray; tooltip explains the wait and that
  Process now skips it), **Ready** (green; notes are Ready immediately), **In
  batch** (blue; the row is locked, no ×), **Next batch** (gray; added while
  a batch runs), **Couldn’t read** (peach; the core's reason in the tooltip).
- A note shows as one row (its title); × removes the whole note (the core
  trashes its members; the client drops them from its list too).
  `QueueRows.visible` hides any path in another row's `members` and, for an
  older core that sends no `members`, every `.distill.json` sidecar.
  Right-click → Show in Finder.
- `QueueRows.count` is the number of rows the screen shows; the sidebar
  badge, the floating icon's badge and liquid level, and the snapshot status
  all use it.

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
