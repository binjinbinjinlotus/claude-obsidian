---
title: Tooling
status: built
updated: 2026-10-01
---

# Tooling

| Command | What it does |
| --- | --- |
| `apps/distill/clients/macos/scripts/build-app.sh [--install]` | Release build → `apps/distill/clients/macos/build/Distill.app` (Info.plist with bundle id `com.claude-obsidian.distill`, product root, ad-hoc signature); `--install` copies it to `~/Applications`. |
| `apps/distill/clients/macos/scripts/distill.sh toggle\|start\|stop\|restart\|update\|status\|test` | Day-to-day control. `stop`/`restart`/`update` refuse while a job is running (exit 2) unless `--force`. `update` runs the tests first and installs only if they pass, then relaunches if the app was running. `DISTILL_JOBS` overrides the job file for testing. |
| `/distill` | Project skill at `.claude/skills/distill/SKILL.md` that maps requests like "toggle Distill" or "I changed the wrapper" to the script. |
| `swift test --package-path apps/distill/clients/macos` | WorkerCore unit tests: result parsing, invocation args, permission rules, quoting, queue scanning/claiming, validation, batch interval. |

`apps/` is outside `config/release-allowlist.json`, so nothing here ships in the
plugin release artifact.
