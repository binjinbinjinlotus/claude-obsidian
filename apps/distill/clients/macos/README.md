# Distill (macOS)

A native Mac wrapper that runs claude-obsidian unattended with `claude -p`.
Drop or paste sources, let them batch on a schedule, and approve each vault
change before it is applied. Approving or replying resumes the **same** Claude
session (`claude -p --resume <session-id>`).

This app is contributor tooling. `apps/` is outside `config/release-allowlist.json`,
so it never ships in the plugin release artifact.

## Build and run

```bash
apps/distill/clients/macos/scripts/build-app.sh            # → apps/distill/clients/macos/build/Distill.app
apps/distill/clients/macos/scripts/build-app.sh --install  # also copies it to ~/Applications
swift test --package-path apps/distill/clients/macos       # WorkerCore unit tests
```

Day-to-day control (also available as the `/distill` project skill):

```bash
apps/distill/clients/macos/scripts/distill.sh toggle    # start if stopped, quit if running
apps/distill/clients/macos/scripts/distill.sh update    # after code changes: test, rebuild, reinstall, relaunch
apps/distill/clients/macos/scripts/distill.sh status    # app state + running / awaiting-approval jobs
```

`stop`, `restart` and `update` refuse to quit while a job is running. Pass
`--force` to quit anyway.

Requires macOS 14+, the Swift 5.10+ toolchain, an authenticated `claude` CLI, and
a vault created with `scripts/claude-obsidian.py init` or `adopt`.

## Using it

1. **Pick a vault.** Choose the vault root (the folder that contains
   `.claude-obsidian.json`) from the toolbar or Settings. You can keep several
   vaults and switch between them. Every vault has its own queue folder.
2. **Feed the queue.** Drag files onto the window or the floating icon, or press
   ⌘V (⇧⌘V from any worker window) to paste a screenshot, a copied file, or
   text. Pasted images are saved as `Screenshot <timestamp>.png` and text as
   `Clipping <timestamp>.md`. Dropped files are copied, so your originals stay
   where they are. Anything you save into the queue folder also counts.
3. **Batching.** Every *N* minutes (1/5/10/15/30/60/120 or a custom value), all
   files that have stopped changing are moved into `<vault>/inbox/` and handled
   together by one job. **Process Now** (⌘R) runs a batch immediately.
4. **Approve.** When Claude has an inspected transaction bundle, the job moves to
   **Needs your approval**. The floating icon and the Dock show a red badge.
   - **Approve & Apply** resumes the session and allows only the exact command
     `transaction apply <bundle> --vault <vault> --approved-plan-sha256 <sha>`.
   - **Reply** sends feedback, such as "skip the second file" or "merge into the
     existing page". Claude rebuilds the bundle and asks again.
   - **Blocked tool calls**: if Claude was denied a tool, tick it and choose
     **Allow Selected & Continue**. The permission is kept for the rest of that job.
   - **Reject** stops the job. Inbox files are kept.
   - **Open Session in Terminal** reopens the same session interactively.
5. **Model.** Choose the model for new jobs from the toolbar: Opus, Sonnet, or
   Haiku (latest), a pinned model ID, or a custom ID in Settings. A job keeps
   its model when it is resumed.

### Floating icon

The floating icon stays on top on every Space. Click it to open the worker,
drag it to move it (its position is remembered), and drop files on it to queue
them. Right-click it to paste, process, or hide it. Toggle it with ⌘I.

## Safety model

- **Two phases.** The first turn can read anything, write only to
  `<vault>/.vault-meta/worker/<job-id>/`, and run only `transaction inspect`,
  `doctor`, `lint`, and `shasum` through the core. It is never allowed to run
  `transaction apply`. That permission is granted on resume, and only for the
  approved hash.
- **The plan comes from the app.** The app runs `transaction inspect` itself, so
  the changed paths and approval hash on the approval screen come from the core,
  not from Claude's summary.
- **One job per vault.** A vault has one running or awaiting-approval job at a
  time, so a new batch never builds against hashes a pending approval is about
  to change. New files wait in the queue in the meantime.
- **Inspectable runs.** Each turn's raw `claude` JSON is stored next to the
  bundle as `turn-N.json`. Job history lives in
  `~/Library/Application Support/Distill/`.

## Headless mode

```bash
Distill.app/Contents/MacOS/Distill --run-once \
  --vault ~/Vaults/research --queue ~/Desktop/to-ingest --model sonnet [--approve]
```

This mode batches the queue once, prints the approval request, and with
`--approve` applies a valid plan and prints the changed paths.

## Extending

`Sources/WorkerCore` has no UI and holds all the behavior:

| File | Role |
| --- | --- |
| `JobKind.swift` | `JobKind` protocol, `JobKinds.all` registry, the shared `WorkerProtocol` (system prompt, output schema, approve, reply, and allow prompts) |
| `WorkerEngine.swift` | Schedule, batching, the per-vault lock, and the run → approval → resume state machine |
| `Runners/` | AI backends behind `AgentRunner` (Claude Code today): request mapping, results, permission denials |
| `Queue.swift` | Queue scanning, settle delay, moving files into the inbox, paste and drop intake |

To add a capability (for example a scheduled `wiki-lint` sweep or a `save`
digest), conform a new type to `JobKind` and register it in `JobKinds.all`. The
approval UI, resume, cost tracking, and terminal hand-off work for every kind.
