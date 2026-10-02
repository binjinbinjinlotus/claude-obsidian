---
title: Headless and snapshot modes
status: built
updated: 2026-10-01
---

# Headless and snapshot modes

Two hidden command-line modes of the same binary
(`Distill.app/Contents/MacOS/Distill`).

## `--run-once` (clients/macos/Sources/Distill/HeadlessRun.swift)

```bash
Distill --run-once --vault PATH [--queue PATH] [--model ID] \
  [--product-root PATH] [--state-dir PATH] [--approve]
```

Batches the queue once, prints the approval request, and with `--approve`
approves a valid plan and prints the changed paths. Uses its own state dir when
given, so it does not touch the app's jobs. Used for end-to-end verification
against a throwaway vault.

## `--snapshot` (clients/macos/Sources/Distill/Snapshot.swift)

```bash
Distill --snapshot OUT_DIR --state-dir DIR
```

Renders Queue, Review (first pending job), Settings and the floating icon to
PNGs from the settings/jobs in `DIR`, without a display. The `snapshotMode`
environment swaps `ScrollView` for a plain stack and hides AppKit-backed
controls (drop target, text editor) that `ImageRenderer` cannot draw; native
fields and switches still render as placeholders. For design QA only.
