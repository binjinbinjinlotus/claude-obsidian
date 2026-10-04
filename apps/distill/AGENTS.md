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
| [Markdown editing](docs/specs/markdown-editing.md) | built |
| [Labels and sources](docs/specs/labels-and-sources.md) | built |
| [Quick actions and shortcuts](docs/specs/quick-actions.md) | built |
| [App icon](docs/specs/app-icon.md) | built |
| [Actions](docs/specs/actions.md) | built (core, API, CLI, macOS UI; answer selection bar not yet) |
| [Collectors](docs/specs/collectors.md) | built (core, API, CLI, macOS UI; queue rows don't name the collector yet) |

## Layout

- `core/src/contracts.ts`: the shared contract every layer builds against (lead-owned).
- `core/src/engine/`: queue, batches, jobs, approval state machine, notes, progress.
- `core/src/ask/`, `core/src/labels/`: Ask (filters, history, cancel) and labels.
- `core/src/actions/`: actions (registry of types and handlers, actions.json,
  finding, drafts) and connections (Atlassian).
- `core/src/collectors/`: collectors (cron scheduler, Folder runs and ledger,
  script runs and consent, run history; collectors.json).
- `core/src/runners/`: AI backends behind `AgentRunner` (Claude Code, Codex,
  OpenAI, OpenRouter, Vercel AI SDK) and Keychain secrets.
- `core/src/store/`: settings.json / jobs.json; `core/src/server/`: the local
  HTTP API, token and lock file.
- `cli/`: the `distill` CLI (ask, note add/label, history, status, actions,
  collectors list/run/history, serve, plugin install). It never approves and
  never consents to a collector script.
- `plugin/`: agent skills (`distill-ask`, `distill-note`) for Claude Code and Codex.
- `clients/macos/Sources/DistillKit/`: UI-free Swift client (DTOs, CoreClient,
  CoreLauncher). `clients/macos/Sources/Distill/`: the AppKit/SwiftUI app.
- `clients/macos/Tests/`: DistillKitTests and DistillTests.
- `clients/macos/scripts/`: `build-app.sh`, `distill.sh`, `make-icon.sh`.

## Specs and decisions

Every change that builds, alters or removes a feature updates its spec in
`docs/specs/` in the same commit (status `designed` → `built` when it
ships), and every product or technical decision gets a dated entry in
`docs/specs/decisions.md` (newest first; supersede, never rewrite). New specs
are listed in `docs/specs/index.md`. Visible changes go to the design canvas
first (`docs/specs/design-process.md`).

## User data is permanent

Settings, job history and Ask history live in `~/Library/Application Support/Distill`
(`settings.json`, `jobs.json`, `ask/*.json`; API keys in the Keychain). The user keeps
updating the app, so no build, update or schema change may lose them.

- Updates replace only the app bundle. `distill.sh update` backs the data up to
  `<state>/backups/<time>` first (newest 10 kept) and checks it afterwards;
  `distill.sh backups` / `restore NAME` put a backup back.
- Schema changes are additive. Decode leniently: a missing or wrong-typed field
  takes its default; unknown keys survive a save (`encodeSettings`, `encodeJob`).
  Never rename or repurpose a stored field; add a new one and read the old one.
- A file this build can't read is set aside first (`preserveUnreadable` →
  `<file>.unreadable-<time>`), never overwritten silently. Ask chat files that
  can't be read are skipped, never deleted.
- Tests and agents use a temp `DISTILL_STATE_DIR`; never the real state dir.

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
