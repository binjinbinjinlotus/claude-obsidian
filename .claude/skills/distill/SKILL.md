---
name: distill
description: Control the Distill Mac wrapper app (apps/distill/clients/macos) for this checkout. Toggle, start, stop, or restart it; check its status; or rebuild and reinstall it after changing the wrapper's code. Triggers: toggle Distill, start/stop/restart Distill, Distill status, update/reinstall/rebuild Distill, I changed the wrapper.
---

# Distill app control

Contributor tooling for `apps/distill/` (the macOS client lives in `apps/distill/clients/macos/`). It is not a product skill, never ships in
the release artifact, and never touches a vault.

All actions go through one script, run from the repository root:

```bash
apps/distill/clients/macos/scripts/distill.sh <command>
```

| User intent | Command |
| --- | --- |
| "toggle Distill", "turn it on/off" | `toggle` |
| "start / open Distill" | `start` |
| "stop / quit Distill" | `stop` |
| "restart Distill" | `restart` |
| "I changed the wrapper", "update / rebuild / reinstall" | `update` |
| "is it running?", "Distill status" | `status` |
| "test the wrapper" | `test` |

With no argument, run `toggle`. If the request is ambiguous, run `status` first and say what you found.

## Rules

- `stop`, `restart`, and `update` refuse while a job is **running**, because an
  apply may be in progress (exit 2). Report that, and do not retry with
  `--force` unless the user explicitly asks to force it. If a forced stop
  interrupted an apply, tell them to run
  `python3 scripts/claude-obsidian.py transaction recover --vault <vault>`.
- Jobs **awaiting approval** survive a stop or update. Mention how many there are;
  they are not a reason to block.
- `update` runs the WorkerCore unit tests first and does not install if they
  fail. Show the failing lines it printed, and fix them only if the user asks.
- `update` relaunches the app only if it was running before. Otherwise it says how to start it.
- After any command, report its output in one or two lines: the app state and job counts.
  Do not paste the build log.
