---
title: App shell and visual design
status: built
updated: 2026-10-01
---

# App shell and visual design

Code: `clients/macos/Sources/Distill/AppDelegate.swift`, `AppModel.swift`, `MainView.swift`,
`SettingsView.swift`, `Theme.swift`. Design canvas: https://claude.ai/artifact/VSqHFPZjcqY2bMqFEnPqpG

## Client architecture

The app is a thin client of the core ([Architecture](architecture.md)). It
never writes `settings.json` or `jobs.json`, never scans or claims queue files,
and never runs an AI turn. The Swift `WorkerEngine`, runners, queue scanner and
job kinds were removed when the app switched over: two engines on one state dir
would both process the queue.

- **DistillKit** (`Sources/DistillKit`, UI-free):
  - `Models.swift`: Codable mirrors of `core/src/contracts.ts`. Decoding is
    tolerant: missing keys use contract defaults, wrong-typed fields are dropped,
    malformed list elements are skipped, unknown job states show as failed, and
    dates parse with or without fractional seconds.
  - `CoreClient.swift`: one method per route, including the v2 label,
    conversation and runner routes. It sends `Authorization: Bearer <token>`
    and turns error bodies into `CoreClientError.api(status, code, message)`.
    `isNotAvailable` covers 501 and the 404 an older core returns for routes it
    does not have. The SSE parser decodes each `data:` line as a `CoreEvent`.
  - `CoreLauncher.swift`: see "Finding the core" below.
- **AppModel** (`Sources/Distill/AppModel.swift`) mirrors the core:
  - On launch it finds or starts the core, subscribes to `/v1/events`, then
    loads settings, the queue, jobs and status.
  - Job events upsert by id. Queue events replace the list. Status (problems,
    next batch, counts) is refetched after events and every 30 s.
  - `log` events at warn/error appear in the error banner. That is how
    "Process now" explains a blocked batch.
  - Settings bindings edit a local copy. After 0.5 s the changed top-level keys
    go to `PUT /v1/settings`, with `null` for a cleared optional. Keys the app
    does not model are never sent. While an edit is pending, incoming
    `settings` events do not overwrite it.
  - When the event stream drops, the model re-reads `server.json`, since a
    restarted core has a new port, and reconnects with backoff. If no core is
    alive, the main window and Settings show "Distill's core isn't running" with
    **Retry**, which runs the launcher again.

## Finding the core

1. State dir: `$DISTILL_STATE_DIR`, else `~/Library/Application Support/Distill`.
2. A live `server.json` (pid alive, port > 0) plus `<state>/token` gives the endpoint.
3. Otherwise the app runs `node <productRoot>/apps/distill/cli/dist/main.js serve`
   with `DISTILL_STATE_DIR` set and a fixed `PATH`. The process starts in its
   own session (`posix_spawn` + `SETSID`), with stdout and stderr appended to
   `<state>/server.log`. The app waits up to 20 s for `server.json`. If the
   child exits first, the app checks once more for a live lock (the CLI may have
   won the race), then reports the exit code and the tail of the log.
4. Product root: `$DISTILL_PRODUCT_ROOT`, then Info.plist
   `ClaudeObsidianProductRoot`, then `productRoot` from settings.json (read-only).
5. Node, without the shell PATH (GUI apps do not get nvm):
   - `settings.nodePath`
   - the highest `~/.nvm/versions/node/*/bin/node`, compared by version number
   - `/opt/homebrew/bin/node`
   - `/usr/local/bin/node`
   - `/usr/bin/node`

   Each candidate must run `--version` and report 20 or newer. Otherwise the UI
   lists what was tried and which versions were too old.

Quitting the app leaves the core running, because the CLI and agents may be
using it. `distill.sh core-stop` stops it.

## Windows and menus

- AppKit lifecycle (`main.swift` → `AppDelegate`), SwiftUI content.
- Main window 1120×720 (min 900×600) and Settings window use a transparent,
  title-less title bar so the traffic lights sit on the light sidebar.
- Menus: Distill (Settings ⌘,), Edit, Queue (Paste into Queue ⇧⌘V, Process
  Queue Now ⌘R), Window (Show Worker ⌘0, Toggle Floating Icon ⌘I).

## Sections

- **Queue**: heading with count and next-batch line, Process now, drop panel
  with a flask that fills with the queue, file list.
- **Review**: jobs waiting for approval (see [Approval and review](approval-and-review.md)).
- **History**: all other jobs with status dots and details. (The old local
  "Clear" button is gone: the core owns the job list and has no delete route yet.)
- Sidebar footer: active vault switcher with model and status.
- Bottom banner: connecting to the core, core unreachable (Retry), or the last error.

## Visual language ("clean and joyful")

- Neutrals: window `#FFFFFF`, panel `#F6F5F2`, border `#ECEAE5`, ink `#1D1C1A`,
  muted `#6B6862`.
- Primary action: sky blue `#1F6FEB` (tint `#E3EEFF`).
- Accents (fill / ink): lime `#E9FBC9`/`#3D6110` for new things, peach
  `#FFE4D6`/`#B03A0A` for needs-attention, plus pink and sky for avatars.
- No dark surfaces, no purple.
- Type: SF Rounded heavy for headings (stands in for Bricolage Grotesque),
  system font for body.
- Shared pieces in `Theme.swift`: `FlaskView`, `PrimaryButton`, `SoftButton`,
  `Pill`, `Tile`, `card()`.
