# Distill (apps/distill): Agent Instructions

Distill is the app layer for claude-obsidian. It batches sources from a queue
folder, runs an AI runner (Claude Code today) against the selected vault, and
stops for the user's approval before anything is applied. Today it is a macOS
client (`clients/macos/`); the planned shape is one Node + TypeScript core with
a CLI, an agent plugin and thin clients. See
[Architecture](docs/specs/architecture.md). It is contributor tooling: `apps/`
is outside `config/release-allowlist.json` and never ships in the plugin
release. The repository-wide rules in `../../AGENTS.md` still apply.

## Start here

1. Read [docs/specs/index.md](docs/specs/index.md) and the specs for the area
   you will touch.
2. Visual design lives on the canvas:
   https://claude.ai/artifact/VSqHFPZjcqY2bMqFEnPqpG. Show design changes there
   before building UI.

## Spec index

| Spec | Status |
| --- | --- |
| [Architecture](docs/specs/architecture.md) | designed |
| [AI runners](docs/specs/ai-runners.md) | built (Settings UI designed) |
| [Claude runner](docs/specs/claude-runner.md) | built |
| [Approval and review](docs/specs/approval-and-review.md) | built |
| [Queue and batching](docs/specs/queue-and-batching.md) | built |
| [Intake: paste and drop](docs/specs/intake-paste-drop.md) | built |
| [Vaults and settings](docs/specs/vaults-and-settings.md) | built |
| [Job kinds](docs/specs/job-kinds.md) | built |
| [App shell and visual design](docs/specs/app-shell.md) | built |
| [Floating icon](docs/specs/floating-icon.md) | built |
| [Headless and snapshot modes](docs/specs/headless-and-snapshot.md) | built |
| [Tooling](docs/specs/tooling.md) | built |
| [Ask](docs/specs/ask.md) | designed |
| [Write a note](docs/specs/notes-composer.md) | designed |
| [Labels and sources](docs/specs/labels-and-sources.md) | designed |
| [Quick actions and shortcuts](docs/specs/quick-actions.md) | designed (hover menu, quick ask built) |
| [App icon](docs/specs/app-icon.md) | built |

## Layout

- `clients/macos/Sources/WorkerCore/`: UI-free behavior (settings, queue, job kinds, engine).
  Everything testable lives here.
- `clients/macos/Sources/WorkerCore/Runners/`: AI backends behind the `AgentRunner` protocol
  (Claude Code today). New backends go here.
- `clients/macos/Sources/Distill/`: AppKit/SwiftUI shell (windows, floating icon, intake,
  theme, headless and snapshot modes).
- `clients/macos/Tests/WorkerCoreTests/`: unit tests.
- `clients/macos/scripts/`: `build-app.sh`, `distill.sh`.

## Rules

- Keep the approval gate intact: phase-1 tools never include
  `transaction apply`; apply is granted only as the exact approved command.
  See [Approval and review](docs/specs/approval-and-review.md).
- Writes to the vault happen only through the core's transactions, never
  directly from the app or from Claude outside the job directory.
- When behavior changes, update the matching spec in the same change; flip
  `status: designed` to `built` when a feature ships, and keep
  `docs/specs/index.md` and the table above in sync.
- Verify with `apps/distill/clients/macos/scripts/distill.sh test` (unit tests) and, for UI,
  `Distill --snapshot` renders. End-to-end runs use a throwaway vault from
  `scripts/claude-obsidian.py init`, never the user's real vault.
- Install and relaunch with `apps/distill/clients/macos/scripts/distill.sh update`; it refuses
  while a job is running.
