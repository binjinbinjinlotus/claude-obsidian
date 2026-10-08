# Distill (macOS)

The Mac client for Distill. Drop or paste sources, let the core batch them on a
schedule, and approve each vault change before it is applied.

The app is a **thin client of the Distill core** (`apps/distill/core`, Node +
TypeScript). The core owns settings, the queue, the schedule, jobs and the AI
runners, and serves them on a local HTTP API (`127.0.0.1`, bearer token). The
app only shows that state and sends commands. See
[Architecture](../../docs/specs/architecture.md) and
[App shell](../../docs/specs/app-shell.md).

This app is contributor tooling. `apps/` is outside `config/release-allowlist.json`,
so it never ships in the plugin release artifact.

## Build and run

```bash
apps/distill/clients/macos/scripts/build-app.sh            # TS workspace build (if stale) + Distill.app
apps/distill/clients/macos/scripts/build-app.sh --install  # also copies it to ~/Applications
swift test --package-path apps/distill/clients/macos       # DistillKit unit tests
```

Day-to-day control (also available as the `/distill` project skill):

```bash
apps/distill/clients/macos/scripts/distill.sh toggle     # start if stopped, quit if running
apps/distill/clients/macos/scripts/distill.sh update     # after code changes: test, rebuild, reinstall, relaunch
apps/distill/clients/macos/scripts/distill.sh status     # app + core + running / awaiting-approval jobs
apps/distill/clients/macos/scripts/distill.sh core-stop  # stop the core server
```

`stop`, `restart`, `update` and `core-stop` refuse while a job is running.
Pass `--force` to go ahead anyway.

Requires macOS 14+, the Swift 5.10+ toolchain, Node.js 20+, an authenticated
`claude` CLI, and a vault created with `scripts/claude-obsidian.py init` or `adopt`.

## How the app finds the core

1. State dir: `$DISTILL_STATE_DIR`, else `~/Library/Application Support/Distill`.
2. If `server.json` names a live process with a port, the app connects with the
   token in `<state>/token`.
3. Otherwise it starts `node <product root>/apps/distill/cli/dist/main.js serve`
   detached (its own session, output appended to `<state>/server.log`) and
   waits for `server.json`. The product root comes from `$DISTILL_PRODUCT_ROOT`,
   the `ClaudeObsidianProductRoot` key in Info.plist (set by `build-app.sh`),
   or `productRoot` in settings.json.
4. Node is found without the shell PATH: Settings → node (`nodePath`), the
   highest `~/.nvm/versions/node/*/bin/node`, `/opt/homebrew/bin/node`,
   `/usr/local/bin/node`, `/usr/bin/node`. Versions below 20 are skipped.

Quitting the app leaves the core running, since the `distill` CLI and agents may
be using it. Use `distill.sh core-stop` to stop it. If the core goes away, the
app shows a banner with **Retry**, which starts it again.

## Using it

1. **Pick a vault** in Settings or the sidebar switcher (a folder containing
   `.claude-obsidian.json`). Each vault has its own queue folder.
2. **Feed the queue.** Drop files on the window or the floating icon, or paste
   (⌘V, ⇧⌘V) a screenshot, copied files or text. The core copies files into the
   queue. Pasted images become `Screenshot <timestamp>.png` and text becomes
   `Clipping <timestamp>.md`.
3. **Batching** happens in the core on the interval from Settings. **Process
   Now** (⌘R) asks the core for a batch right away.
4. **Review.** Approve & apply, reply, allow blocked tools, reject or cancel.
   Each action is an API call; the core runs the AI turn and the approved
   `transaction apply`.

## Code

| Path | Role |
| --- | --- |
| `Sources/DistillKit/Models.swift` | Codable mirrors of `core/src/contracts.ts`, with tolerant decoding |
| `Sources/DistillKit/CoreClient.swift` | Every API route, error shape, and the SSE event stream parser |
| `Sources/DistillKit/CoreLauncher.swift` | State paths, `server.json`/token, node discovery, detached `serve` |
| `Sources/Distill/AppModel.swift` | What the windows show; events, debounced settings patches, commands |
| `Sources/Distill/*View.swift`, `FloatingIcon.swift`, `Intake.swift` | AppKit/SwiftUI shell |
| `Sources/Distill/Snapshot.swift` | `--snapshot` design QA from fixture files (no core) |

The Swift engine (`WorkerEngine`, runners, queue scanning, job kinds) was
retired when the app moved onto the core. Two engines on one state dir would
both process the queue. New behavior goes in the core, and the app surfaces it.
