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
  **Built in the core 2026-10-04:** top-level folders are folder items and
  `.gdoc` files are Google Doc items; see "Folders, Google Docs and syncing"
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
  note never loses its manifest. A folder item goes to the Trash whole
  (`name 2` on a clash; the name is claimed with an exclusive `mkdir`, so an
  existing Trash folder is never replaced). Also refused for paths outside
  the folder and symlinks (`invalid_request`) and, when the queue is the
  inbox, items a batch already took (`invalid_state`).

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

## Folders, Google Docs and syncing (designed and built 2026-10-04)

Canvas: Main, MainLoading, MainEmpty, MainFolder, QueueItems; components
QueueRowView (folder and Google Doc states) and QueueRefresh. The core, API,
CLI and Mac app are built (see "Built in the core" and "Built in the Mac app"
at the end of this section).

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
  entry with the relative path and size (`.gdoc` entries say "Google Doc,
  not read"), then "Treat these as one source; the paths and names are context."
  `.gdoc` files inside are listed but never sent as sources (see below).
- **Review:** sources list the folder once ("Tea tasting trip/ · folder · 12
  files · 3 folders"). Show files lists each file with the pages it was used
  in, or "not used". Changes cite files by their path inside the folder.
- **History → Jobs:** the folder is one source row with its file count and
  inbox location. It expands to the same read-only tree.

### Google Doc items (.gdoc)

- A `.gdoc` file (at the top level, or inside a folder item) is only a
  pointer: JSON with `url` and `doc_id`, among other fields. The document's
  content is not on disk, so Distill cannot read it. The core parses the
  pointer, and the title is the file name without `.gdoc`.
- **Queue entry:** `kind: 'gdoc'`, `gdoc: { title, url, docId }`,
  `waiting: 'google-drive'`. If the file has no `url` or `doc_id` (often
  because Drive hasn't synced it yet), the entry gets
  `problem: 'no link inside'` instead.
- **Row** (QueueRowView, kind gdoc):
  - doc icon and the title;
  - "Google Doc · needs Google Drive access · added 2:55 AM";
  - **Open in Google Docs**, which opens `url`;
  - a **Waiting** pill (amber);
  - the hint "Distill can't open Google Docs yet, so this waits here and
    isn't processed. To include it now, download it as .docx or PDF and drop
    that."
- **Not processed.** The item is held out of every batch, Process now
  included. It stays in the queue until the user removes it or Google Drive
  access exists. It counts toward the queue count, but it never makes a
  batch start on its own. A `.gdoc` inside a folder item is listed in the
  tree as "not read" and is not given to the AI as a source. Review lists it
  under the folder as "not read: needs Google Drive access".
- **Google Drive fetch:** designed separately. The coordinator and the owner
  are deciding it, including automatic collection of meeting notes. Until
  then, no link note and no other ingestion of `.gdoc` content.

### Built in the core (2026-10-04)

Code: `scanQueueFolder`, `walkFolder`, `folderTreeEntries`,
`folderSourceBlock`, `parseGoogleDoc`, `claimItems` in
`core/src/engine/queue.ts`; `scanQueueNow` and `processQueue` in
`core/src/engine/index.ts`; `folderPrompt` in `job-kinds.ts`. Tests:
`core/src/engine/queue-folders.test.ts`.

- **Why the folder never showed up:** the scanner (`pendingFiles`) kept
  regular files only (`lstat().isFile()`). There was no missing watcher: a
  5-second tick already rescanned the top level, which is also why top-level
  files removed by hand already disappeared within 5 s. `pendingFiles` stays
  file-only for the note-manifest lookups; the queue list and batches use
  `scanQueueFolder`.
- **Two kinds of scan.**
  - The 5-second tick reads the top level and reuses each folder's last
    walk while the folder's own mtime is unchanged (entries added or removed
    directly inside move it; changes deeper down don't).
  - A **full scan** walks every folder again: Refresh and the window-active
    scan (`POST /v1/queue/scan {trigger: 'manual' | 'window'}`, default
    manual), the queue check every `queueScanMinutes`, and every batch
    (`processQueue` never trusts the cache, so the wait rule holds for the
    newest change inside a folder even when the queue check is Off).
- **Scan result** (`QueueScanResult`): `added`, `removed`, `changed` (counts,
  as designed), `checkedAt`, `trigger` (`manual | window | periodic`),
  `problem` when the queue folder exists but can't be read, plus
  `addedEntries`, `removedEntries` (as last listed), `changedEntries` and
  `entries`. It compares with the list the core last had, so a change the
  5-second tick already listed is not counted again. "Changed" ignores
  `settled`, `readyAt` and `changing`, which move with the clock. Every full
  scan emits `queue.scanned {result}`; the `queue` event still goes out only
  when the list changed. `status()` adds `lastQueueScanAt` ("checked at …")
  and `nextQueueScanAt` (null when Off).
- **`settings.queueScanMinutes`:** absent = 5; 0 = Off; decoded leniently
  (mistyped = absent, clamped to 0…1440) and never written unless set.
  Changing it reschedules the next check from now.
- **Folder entries:** `kind: 'folder'`, `fileCount` (files present, `.gdoc`
  included; hidden files, partial downloads and `.distill-folder.json` not
  counted), `folderCount`, `size`, `modified` (newest file inside; the
  folder's own mtime only when it has no files), `tree` (`{path, size, kind:
  'file' | 'dir' | 'gdoc', seenBefore?}`, dirs carry their files' total,
  sorted by path, capped at 500) and `treeTruncated`. Symlinks are skipped.
  Folders' own mtimes never count for the wait, because Finder rewrites
  `.DS_Store` when the user only looks.
- **Problems** hold a folder out of every batch, Process now included:
  `'too big'` (more than 200 source files or 500 MB of them, or more than
  5000 entries walked), `'too deep'` (a file more than 8 levels down:
  `folder/a/b/c.md` is level 3; not in the design, added because the owner
  asked for a depth limit), `'empty folder'` (no files at all; not in the
  design) and the usual "can't read" sentence. A folder whose only files are
  `.gdoc` pointers gets `waiting: 'google-drive'` instead.
- **Batch:** a folder moves whole to `inbox/<yyyy-MM-dd>/<name>` (`name 2`
  on a clash). Its sources (not hidden, partial, `.gdoc` or `seenBefore`) go
  into `job.files` one by one; the folder itself goes into the new
  `job.folders`. Its `.gdoc` pointers never enter the vault: before the
  move they step into a hidden staging folder in the queue folder, then
  come back as a folder of the original name (" 2" if taken), at their
  relative paths, where they keep waiting ("google-drive"). Subfolders
  left empty by that are not moved. The moved folder's
  `.distill-folder.json` records each pointer (path, size, kind `gdoc`; no
  contents), so the prompt still lists it as "Google Doc, not read" and
  the header still counts it. When the queue is the inbox, folders stay where they are
  and a folder counts as taken once any of its files is in a job. "Reading N
  sources" and the app turn count a folder as one. Files inside a folder get
  no per-file AI labels (one folder would otherwise cost one label call per
  file).
- **Prompt:** after the manifest section, one block per folder:
  `In inbox/<date>/:`, then `Folder source: <name>/ (12 files, 3 folders,
  18.4 MB)`, one line per tree entry (`- name/dir/`, `- name/file.md (1.2
  KB)`, `- name/x.gdoc (Google Doc, not read)`, `- name/old.md (4 B, seen
  before, not a source)`), then "Treat these as one source; the paths and
  names are context." Paths are relative to the batch folder; no queue or
  home path reaches the runner.
- **`.gdoc`:** `kind: 'gdoc'`, `gdoc: {title, url, docId}`, `waiting:
  'google-drive'`; never batched. The link must be https on
  `docs.google.com` or `drive.google.com`; with no usable `url`, it is
  built from a valid `doc_id` (`https://docs.google.com/document/d/<id>/edit`).
  Anything else, malformed JSON or a file over 64 KB stays `kind: 'gdoc'`
  with `problem: 'no link inside'`, no `gdoc` object and no `waiting` (the
  row takes its title from `name`); it is held out like any problem. The
  `email` field is never read out (not in entries, events, logs or prompts).
  The wait rule still applies to the pointer file's mtime, but it is
  irrelevant while the item waits.
- **Folder collector manifest** (`.distill-folder.json`, written by the
  Folder collector into a subfolder item; see [Collectors](collectors.md)):
  `{version: 1, name, collectorId, collectedAt, tree}`. Entries marked
  `seenBefore` are listed in the queue tree and the prompt but are never
  sources; ones the collector didn't copy appear in the tree only. Being
  hidden, the manifest itself is never counted or sent.

### Built in the Mac app (2026-10-04)

Built from canvas v64. Code: DistillKit `Models.swift` (QueueEntry v5
fields, `QueueTreeEntry`, `QueueScanResult`, status scan times, `Job.folders`,
`Settings.queueScanMinutes`, the `queue.scanned` event), `QueueItems.swift`
(folder and Google Doc wording, `QueueTree.lines`, `Job.sources`,
`QueueRefreshState`, `QueueScanInterval`), `QueueFolderWalk.swift`,
`SourceUsage.swift`, `CoreClient.scanQueue`; the app's `QueueRowViews.swift`
(QueueRowView, QueueTreeView, QueueRefresh), `AppModel+Queue.swift`,
`JobSources.swift`, `MainView.swift` (QueueView, JobDetailView) and
`SettingsView.swift` (Batching). Tests: `QueueItemsTests`,
`QueueScanClientTests`, `QueueRefreshTests`. Snapshot states:
`SnapshotQueueItems.swift` (`queue`, `queue-900`, `queue-refreshed(-900)`,
`queue-running(-900)`, `queue-row-states`, `queue-refresh-states`,
`queue-card-settings`, `queue-card-review`, `queue-card-history`;
`queue-empty` shows "Nothing new").

- **Refresh** sits after Reveal in Finder (on a second line when the window
  is too narrow for one). "Checking…" is disabled while `POST /v1/queue/scan
  {trigger: manual}` runs; the result shows for 4 s, then "checked at …"
  (`max(status.lastQueueScanAt, the newest scan the app saw)`). The scan's
  `entries` replace the list at once and added rows flash once. A periodic or
  window scan (`queue.scanned`) moves "checked at" and the list but shows no
  result. An older core (404) falls back to re-reading the list, with no
  banner and no "checked at".
- **Window scan:** `POST /v1/queue/scan {trigger: window}` when the main
  window becomes key (never the quick panels or Settings), at most every 15 s,
  only with a live core. At launch the window is key before the core answers,
  so the scan runs once it connects.
- **Folder rows** expand from a click on the name or the chevron, which is a
  button ("Show what is inside …") for VoiceOver and keyboard users.
- **Title:** "N items in the queue" ("1 item"); a folder is one item, and a
  running batch counts a folder once ("3 in this batch").
- **Rows:** a folder row has the folder tile, the chevron (only when it has a
  tree), the meta from the board ("12 files · 3 folders · 18.4 MB · moved in
  at 2:40 AM"; folders left out at 0; "a file changed at …" while the wait
  runs; no time on a problem row or in a batch). The tree is rebuilt from the
  core's flat list: 5 entries per folder, then "… N more" with their size;
  folders show their file count, a .gdoc "not read", a file the collector took
  before "seen before · size"; when the core cut the list, a last line says so.
  A Google Doc row has the doc tile, "Google Doc · needs Google Drive access ·
  added 2:55 AM", Open in Google Docs (only an https link on docs or drive
  .google.com opens), the amber Waiting pill and the hint (both dropped while
  a batch runs, as on the board). Status order: problem, then waiting, then
  the batch. Pills: "Too big", "Too deep", "Empty folder", "Couldn’t read"
  (any other problem, a .gdoc with no link included), "Waiting".
- **Remove** of a folder asks first ("Move “Tea tasting trip” to the
  Trash?"); the core moves the whole folder to the Trash.
- **In a batch** a folder is one In batch row; its counts and tree are read
  from the folder in the vault's inbox (read-only).
- **Review → Sources in this batch · N:** the folder once ("folder · 12 files
  · 3 folders", Show files), then each file with the pages it was used in, a
  .gdoc inside as "not read: needs Google Drive access". **History:** the
  folder once ("· 12 files · in inbox/2026-10-04/") expanding to the tree.
  "Used in" is a heuristic over the changed pages' text (the bundle's writes
  while waiting, the vault's pages once applied): a page uses a file when it
  mentions its vault path or its path from the batch folder. "Not used" only
  when every page was read and at least one file matched; otherwise no file
  has a suffix (the citation form of real ingest pages isn't fixed: pages may
  cite a `.raw/` copy or only the source ledger).
- **Settings → Batching:** "Check the queue folder for changes" with Every
  minute, Every 5 min, Every 15 min, Every hour and Off; a value set elsewhere
  shows as it is ("Every 30 min"). Written only when the user picks one. In
  Settings search.

Where the app differs from the boards (also in [Decisions](decisions.md)):

- The tree shows 5 entries per folder as specified; the board's photos/ line
  shows one photo, then "… 7 more".
- Too deep and Empty folder have their own pills (the canvas draws neither).
- Refresh's other results: "1 new item found · 1 item gone", "2 items
  changed" (gray). The board draws only the four designed ones.
- Review doesn't group images ("photos/ (8 images) · described in …"); each
  file has its own line.
- The QueueItems card "What the AI is given" is the core's prompt; it has no
  app view and no snapshot. The board id `queue` can't be a snapshot id (ids
  are hyphenated); its state is `queue` + `queue-900`.
