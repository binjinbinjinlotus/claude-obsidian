---
title: Queue and batching
status: built
updated: 2026-10-04
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
  **Designed 2026-10-04:** top-level folders become folder items and `.gdoc`
  files become Google Doc items; see "Folders, Google Docs and syncing"
  below.
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
  the note row ("<file>: <reason>") and holds the whole note out of batches
  (`readyFiles` takes a note set all or nothing). An orphan manifest or image (its `.md`
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

After Approve, once the changes are applied (job `completed` with changed
paths), the batch gets a last step, **Finding actions** ([Actions](actions.md)):
a new run of the same key with steps `Moved to inbox · Read sources · Applied
changes · Finding actions · Done`, message `Finding actions in N notes`, and a
finished message such as `Found 5 actions to confirm: 3 to-dos, 1 Slack
message, 1 Jira ticket`. The job records the result in `actionsFound`
(`finding` → `done` | `failed` | `skipped`), which Review and History → Jobs
show. It runs once per job and never blocks the next batch.

`Moved to inbox` is done once the job exists. The runner gives no signal
inside a turn, so reading and drafting are not told apart while the turn
runs. Reply and Allow turns start a new run of the same key at `Drafting page
changes`. Failed and cancelled batches finish with `Failed` (and `error`) or
`Cancelled`.

## Folders, Google Docs and syncing (designed 2026-10-04)

Canvas: Main, MainLoading, MainEmpty, MainFolder, QueueItems; components
QueueRowView (folder and Google Doc states) and QueueRefresh. Not built yet.

### Sync: Refresh and the queue check

- Today a folder the user moves into the queue folder by hand never shows
  up, because the core lists only regular files. That is fixed by folder
  items (below). A rescan also runs on its own.
- **Queue check:** the core rescans the active queue folder every
  `queueScanMinutes` (new setting, default 5; one of 1, 5, 15, 60, or 0 for
  Off). It also rescans when the app window becomes active and after Refresh.
  The scan works like `queueList` and emits the queue only when an entry was
  added, removed or changed. A file-system watcher is not used, so the
  behaviour is the same for synced folders (iCloud, Google Drive), where
  events are unreliable.
- **Refresh** (Queue screen, after Copy path and Reveal in Finder):
  `POST /v1/queue/scan` runs the scan now and returns
  `{ added: n, removed: n, checkedAt }`.
  - The button shows "Checking…" (disabled) while the scan runs.
  - Then, for 4 seconds, it shows one result: "2 new items found" (green),
    "1 item gone", "Nothing new", or "Can't read the queue folder" (peach).
  - Afterwards it shows "checked at 3:41 AM", the last scan of any kind.
  - New rows flash once.
- **Settings → Batching**, a new last row: "Check the queue folder for
  changes: Every 5 min ▾" (Every minute, Every 5 min, Every 15 min, Every
  hour, Off). Off leaves Refresh and the check when the window opens. Stored
  as `settings.queueScanMinutes`. It is additive and decoded leniently, like
  every setting.

### Folder items

- **What counts:** a non-hidden directory at the top level of the queue
  folder is **one queue item**, of kind `folder`. Symlinks are left alone.
  Hidden files and `.DS_Store` inside are ignored. Nested folders belong to
  the item; they are never separate items.
- **Queue entry** (`QueueEntry`, additive fields): `kind: 'folder'`,
  `fileCount`, `folderCount`, `size` (total bytes), and `tree`. `tree` is a
  list of `{ path, size, kind: 'file' | 'dir' | 'gdoc' }` sorted by path.
  The core caps it at 500 entries; `treeTruncated` is true when it cut the
  list.
- **Row** (QueueRowView, kind folder): folder icon, the folder name, and
  "12 files · 3 folders · 18.4 MB · moved in at 2:40 AM". The chevron (or a
  click on the row) expands a read-only tree. Each folder shows its first 5
  entries, then "… N more"; folders show their file count and files their
  size. The pill and × work as for files. Remove moves the whole folder to
  the Trash.
- **Settle:** a folder is ready when no file inside changed within
  `settleSeconds`, counted from the newest mtime of any file in it. The row
  says "a file changed at 3:05 AM" and the pill "Ready at 3:15 AM".
- **Limits:** up to **200 files and 500 MB** per folder item. A bigger
  folder gets `problem: 'too big'` (pill "Too big", tooltip "Split it into
  smaller folders") and stays out of batches until the user splits or
  removes it. Process now does not override this.
- **Counting:** a folder counts as one item in the sidebar count, the title
  ("4 items in the queue") and "N sources" in the batch.
- **Batch:** the whole folder moves to `inbox/<date>/` keeping its
  structure. Every file inside is a source, addressed by its path relative
  to the batch (`Tea tasting trip/notes/day1-uji.md`). The prompt gets one
  block per folder item:
  `Folder source: <name>/ (12 files, 3 folders, 18.4 MB)`, then one line per
  entry with the relative path and size (`.gdoc` entries say "Google Doc
  link"), then "Treat these as one source; the paths and names are context."
  `.gdoc` files inside follow the Google Doc rule below.
- **Review:** sources list the folder once ("Tea tasting trip/ · folder · 12
  files · 3 folders"). Show files lists each file with the pages it was used
  in, or "not used". Changes cite files by their path inside the folder.
- **History → Jobs:** the folder is one source row with its file count and
  inbox location. It expands to the same read-only tree.

### Google Doc items (.gdoc)

- A `.gdoc` file (top level, or inside a folder item) is a Google Drive
  pointer: JSON with `url` and `doc_id`, among other fields. The core parses
  it. The title is the file name without `.gdoc`.
- **Queue entry:** `kind: 'gdoc'`, `gdoc: { title, url, docId }`. If the
  file has no `url` or `doc_id` (often because Drive hasn't synced it yet),
  the entry gets `problem: 'no link inside'`.
- **Row** (QueueRowView, kind gdoc): doc icon, the title, "Google Doc · link
  only · added 2:55 AM", **Open in Google Docs** (opens `url`), and the hint
  "Distill can't read Google Docs yet, so the vault gets the title and link.
  To include the text, download it as .docx or PDF and drop that too."
- **What the core does:** Distill has no Google access, and the runners are
  not given one, so the core never fetches the document. In the batch it
  replaces the `.gdoc` with a **link note** written to the job directory:
  `# <title>`, `Google Doc: <url>`, `Doc id: <docId>`,
  `From: <file name> (Google Drive)`, and "The document text was not
  available to Distill." The AI may create or update a page with the link,
  and is told never to invent the document's content. The original `.gdoc`
  moves to the inbox like any file. Review marks the source "Google Doc ·
  link only" ("Added as a link on Tea club; the text was not read").
- **Later:** if a Google connection is added (Settings → Connections), the
  core exports the doc as Markdown before the batch, the hint disappears,
  and the row says "Google Doc · text included". Not designed further now.
