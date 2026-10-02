---
title: Headless and snapshot modes
status: built
updated: 2026-10-01
---

# Headless and snapshot modes

## Headless runs: use the core

The app's `--run-once` mode was retired with the Swift engine. The binary now
prints a pointer and exits 2. Headless work goes through the core instead:

```bash
# A running core (started by the app or on demand by the CLI):
distill status [--json]
distill note add --title "…" --text "…"

# A single batch against a throwaway vault and a temp state dir (dev only):
cd apps/distill/core
node --import tsx src/dev/run-once.ts --vault PATH --state-dir TEMP_DIR \
  [--queue PATH] [--model ID] [--product-root PATH] [--approve]
```

`--state-dir` keeps a dev run away from the real
`~/Library/Application Support/Distill`.

## `--snapshot` (clients/macos/Sources/Distill/Snapshot.swift)

```bash
Distill --snapshot OUT_DIR --state-dir DIR
```

Renders Queue, Review (first pending job), Settings and the floating icon to
PNGs without a display. It needs no core: settings.json and jobs.json in `DIR`
are decoded with the DistillKit DTOs, and the queue comes from listing the
active vault's queue folder. That listing exists only for snapshots. All of
this goes into a fixture `AppModel` that never connects or sends anything. The
`snapshotMode` environment swaps `ScrollView` for a plain stack and hides
AppKit-backed controls (drop target, text editor) that `ImageRenderer` cannot
draw. Native fields and switches still render as placeholders. For design QA only.
