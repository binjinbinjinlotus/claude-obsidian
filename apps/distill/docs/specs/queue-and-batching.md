---
title: Queue and batching
status: built
updated: 2026-10-01
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
- Settle delay (default 10 s, Settings): a file must be unmodified that long
  before it is batched.
- The queue may not be inside the vault's `.raw/` or `.vault-meta/`.

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
   Ingest) and its first turn starts.
