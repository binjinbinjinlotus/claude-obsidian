---
type: spec
title: Clean up inbox
status: built
created: 2026-10-05
updated: 2026-10-05
tags:
  - distill
  - inbox
  - queue
---

# Clean up inbox

The owner asked: "let's not do automatic for now, add a manual cleanup
button". Files a batch moved into `inbox/` stay there after they are added to
the knowledge base. Clean up inbox moves the ones that are safely in the
knowledge base to the macOS Trash, and only when the user asks.

Canvas: **InboxCleanup** (row 1) and **ReviewProgress** frame D. Code: core
`core/src/engine/inbox-cleanup.ts` (rules, preview, move), engine
`previewInboxCleanup` / `cleanUpInbox`; Mac `DistillKit/InboxCleanup.swift`
(DTOs and words), `Distill/InboxCleanupViews.swift` (store, sheet, History
button, Settings row).

## The rule

claude-obsidian keeps `inbox/` as the user's: no operation writes it and
nothing deletes from it automatically (`docs/compound-vault-guide.md`,
`skills/wiki-ingest/SKILL.md`; decision 2026-10-04, "Distill may add files to
inbox/, never edit, overwrite or automatically delete"). A clean-up the user
starts is allowed. Distill never runs one on its own: no schedule, no
"after apply".

A file can go only when **all three** hold:

1. `wiki/meta/ledgers/source-ledger.json` has an entry whose
   `origin.kind` is `file` and whose `origin.locator` is the file's
   vault-relative path;
2. the file's sha256 now equals that entry's `content_sha256`: it has not
   changed since it was added;
3. every path in that entry's `pages` exists (an entry with no pages fails).

Matching:

- Paths are compared in Unicode **NFC** on both sides (macOS file names often
  come back NFD).
- When no locator matches exactly, a **case-only** difference counts, but only
  when exactly one entry matches that way and its hash agrees. When several
  entries share a locator (a file re-added after a change), the one whose hash
  matches is used.

Units:

- **A note** goes with its `<stem>.distill.json` manifest and the images the
  manifest lists that are next to it. The `.md` is what is checked; the
  members move with it (as the queue's Remove does).
- **A folder item** (a path in a batch's `folders`) goes as one: only when
  every source file inside passes. Hidden files and `.gdoc` pointers are not
  checked; `.distill-folder.json` goes with the folder. A "seen before" file
  needs its own ledger entry like any other file, so a folder with one stays.
  Otherwise it stays with "3 of 12 files not added yet".
- Anything else under `inbox/` is a file of its own. Hidden files
  (`.gitkeep`) are never offered.

Never offered, whatever the ledger says:

- a file a batch still holds: running, or waiting in Review (including the
  same batch when a part of it is still waiting) — **waiting in Review**;
- when the queue folder is `inbox/` itself, a queued file not yet batched —
  **in the queue**.

Stay reasons, in plain words: not added yet, changed since it was added, its
page is missing, waiting in Review, in the queue (not batched yet), can't be
read.

## Checked twice

The preview (`GET /v1/inbox/cleanup`) is read-only. **Move** sends the paths
the user saw; the core runs every check again and moves only what still
passes. A file that changed in between stays and is reported ("changed, so it
was left alone"). A path that is not offered any more stays too.

## The Trash

- The core asks **Finder** to delete the items (`osascript`, one call for all
  paths, each path as an argument), so **Put Back** works. macOS may ask once
  whether Distill may control Finder.
- If Finder can't be asked (automation refused, no Finder) or refuses a file,
  the core moves it into `~/.Trash` itself with the no-overwrite rename the
  queue uses (`name 2.md` on a clash). Put Back doesn't work for those; the
  result says "drag it back out of the Trash" instead.
- Nothing is ever `rm`'d. `result.method` is `finder`, `rename` or `none`.

## Where

- **A batch in History → Jobs**, once it was added (completed, or applied in
  parts): the footer shows **Clean up inbox · 22 files** (only the files that
  batch used), counted when the job opens. With nothing to move it says "2
  files stay in inbox/ · Why" or "No inbox files left".
- **Review**, after a batch is added: the same button next to **Done**.
- **Settings → Batching → Clean up inbox**: every file in `inbox/` that can
  go, "Review 39 files…" opens a sheet grouped by the batch that added them,
  with select-all; what stays is counted by reason, and Show each file lists
  them.

Before anything moves, the sheet shows what goes (names, with notes'
manifests) and what stays and why. The button carries the count ("Move 21 to
the Trash"). After, a notice says what moved and what stayed.

## Activity

Every clean-up is one Activity line (`queue.inbox_cleaned`, family Queue):
"Cleaned up inbox: 21 files to the Trash, 1 stayed". Details hold the moved
paths, the stayed paths with their reason, the file count and the method.
Names and counts only, never contents. A refused call logs "Couldn't clean up
inbox".

## API (v8, additive)

- `GET /v1/inbox/cleanup[?job=ID][&vault=PATH]` → `InboxCleanupPreview`
  `{vaultPath, jobId?, items: InboxCleanupItem[], stays: InboxCleanupStay[],
  checkedAt}`.
- `POST /v1/inbox/cleanup {paths, jobId?, vaultPath?}` →
  `InboxCleanupResult {moved, stayed, failed, method}`. Paths must be under
  `inbox/` (400 otherwise).
- `DistillCore.previewInboxCleanup?` / `cleanUpInbox?`; `EngineOptions.trashMover`
  (tests inject a fake; with `trashDir` set the rename is used).
- No CLI command yet.

## Known gaps

- The vault-wide sheet groups by batch title from the app's job list; a file
  whose batch was cleared from History shows under "Other files".
- Put Back depends on Finder automation; without it the copy says to drag the
  file back.
