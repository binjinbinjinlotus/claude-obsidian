# Distill (apps/distill): Agent Instructions

Distill is the app layer for claude-obsidian. It batches sources from a queue
folder, runs an AI runner (Claude Code, Codex, or a model API) against the
selected vault, and stops for the user's approval before anything is applied.
One Node + TypeScript core (`core/`) owns all state and serves a local API; the
CLI (`cli/`), the agent plugin (`plugin/`) and the macOS app (`clients/macos/`)
are clients of it. See [Architecture](docs/specs/architecture.md). It is contributor tooling: `apps/`
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
| [Architecture](docs/specs/architecture.md) | built |
| [AI runners](docs/specs/ai-runners.md) | built (Codex sandbox unverified) |
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
| [Ask](docs/specs/ask.md) | built |
| [Write a note](docs/specs/notes-composer.md) | built |
| [Labels and sources](docs/specs/labels-and-sources.md) | built |
| [Quick actions and shortcuts](docs/specs/quick-actions.md) | built |
| [App icon](docs/specs/app-icon.md) | built |

## Layout

- `core/src/contracts.ts`: the shared contract every layer builds against (lead-owned).
- `core/src/engine/`: queue, batches, jobs, approval state machine, notes, progress.
- `core/src/ask/`, `core/src/labels/`: Ask (filters, history, cancel) and labels.
- `core/src/runners/`: AI backends behind `AgentRunner` (Claude Code, Codex,
  OpenAI, OpenRouter, Vercel AI SDK) and Keychain secrets.
- `core/src/store/`: settings.json / jobs.json; `core/src/server/`: the local
  HTTP API, token and lock file.
- `cli/`: the `distill` CLI (ask, note add/label, history, status, serve,
  plugin install). It never approves.
- `plugin/`: agent skills (`distill-ask`, `distill-note`) for Claude Code and Codex.
- `clients/macos/Sources/DistillKit/`: UI-free Swift client (DTOs, CoreClient,
  CoreLauncher). `clients/macos/Sources/Distill/`: the AppKit/SwiftUI app.
- `clients/macos/Tests/`: DistillKitTests and DistillTests.
- `clients/macos/scripts/`: `build-app.sh`, `distill.sh`, `make-icon.sh`.

## Rules

- Keep the approval gate intact: phase-1 tools never include
  `transaction apply`; apply is granted only as the exact approved command.
  See [Approval and review](docs/specs/approval-and-review.md).
- Writes to the vault happen only through the core's transactions, never
  directly from the app or from Claude outside the job directory.
- When behavior changes, update the matching spec in the same change; flip
  `status: designed` to `built` when a feature ships, and keep
  `docs/specs/index.md` and the table above in sync.
- Verify with `npm test --workspaces` in `apps/distill` (core, CLI),
  `apps/distill/clients/macos/scripts/distill.sh test` (Swift) and, for UI,
  `Distill --snapshot` renders. End-to-end runs use a throwaway vault from
  `scripts/claude-obsidian.py init`, never the user's real vault.
- Install and relaunch with `apps/distill/clients/macos/scripts/distill.sh update`; it refuses
  while a job is running.
