---
title: Tooling
status: built
updated: 2026-10-05
---

# Tooling

| Command | What it does |
| --- | --- |
| `apps/distill/clients/macos/scripts/build-app.sh [--install]` | Runs `npm ci` (when `package-lock.json` is newer than `node_modules`) and `npm run build --workspaces` (when core/cli sources are newer than `cli/dist/main.js`) in `apps/distill`. Then does a release Swift build to `apps/distill/clients/macos/build/Distill.app`, with Info.plist holding the bundle id `com.claude-obsidian.distill` and `ClaudeObsidianProductRoot` (the checkout the app runs the core from), plus an ad-hoc signature. `--install` copies the app to `~/Applications`. |
| `apps/distill/clients/macos/scripts/distill.sh toggle\|start\|stop\|restart\|core-stop\|update\|status\|test` | Day-to-day control. `stop`, `restart`, `update` and `core-stop` refuse while a job is running (exit 2) unless `--force`. The script counts jobs with `GET /v1/status` on the live core, found through `server.json` + token and verified as a `main.js serve` process. With no live core it falls back to `jobs.json`, which covers an old Swift-engine app during the switch. `stop` quits the app only, and the core keeps running. `core-stop` sends SIGTERM to the core's pid. `status` shows the app, the core (pid, port, version, state dir) and job counts. `update` runs the tests first, installs only if they pass, and relaunches the app if it was running. It does not restart the core: after core changes, run `core-stop` and the app or CLI starts the new build. `DISTILL_STATE_DIR` and `DISTILL_JOBS` override the paths for testing. |
| `/distill` | Project skill at `.claude/skills/distill/SKILL.md` that maps requests like "toggle Distill" or "I changed the wrapper" to the script. |
| `distill.sh backup [TAG]\|backups\|restore NAME` | Back up the user's data, list backups, put one back ([User data](user-data.md) → Backups). `update` takes a backup first. |
| `make test-distill-design` | `apps/distill/design/test_design.py`: the design schema against the Swift app (tokens, components and their props, templates, boards). Part of `make test`. See [Design process](design-process.md). |
| `.claude/skills/distill-macos-e2e/` | Project skill for end-to-end testing of the Mac app and its core (isolated state, Keychain and defaults; never the owner's installed app). |
| `.claude/agents/distill-pm.md`, `.claude/skills/authoring-skills-and-agents/` | The product-review agent, and the skill for writing this repo's skills and agents (2026-10-04). |
| `swift test --package-path apps/distill/clients/macos` | DistillKit unit tests. They cover DTO decoding against core-written and Swift-written JSON, settings patches, SSE parsing, node discovery (fake file system, real nvm version list), the launcher with temp state dirs and a fake spawner, and `CoreClient` against a `URLProtocol` stub (auth header, routes, bodies, error shape). |
| `DISTILL_LIVE_TESTS=1 swift test --package-path apps/distill/clients/macos --filter LiveCoreTests` | Opt-in end-to-end check. It starts a real core through `CoreLauncher` in a temp state dir with a minimal `PATH`, then calls status, a settings round-trip with its event, the error shape and token rejection, and stops that core. It needs the TS workspace built. |

`apps/` is outside `config/release-allowlist.json`, so nothing here ships in the
plugin release artifact.
