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
| [Approval and review](docs/specs/approval-and-review.md) | built (labels in Review, pick/remove, approve-later, parts of a batch: core, API, macOS UI) |
| [Queue and batching](docs/specs/queue-and-batching.md) | built (folder items, .gdoc waiting, queue scan: core, API, CLI and Mac UI; label gate and 0–24 h wait; full-read prompt and re-read sources: core, API, CLI, no UI; re-reads pack by tokens) |
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
| [Labels and sources](docs/specs/labels-and-sources.md) | built (queue-file labels and the label gate: core, API, macOS UI) |
| [Quick actions and shortcuts](docs/specs/quick-actions.md) | built |
| [App icon](docs/specs/app-icon.md) | built |
| [Actions](docs/specs/actions.md) | built (core, API, CLI, macOS UI, Add as at confirm time, Jira pickers; answer selection bar not yet) |
| [Action context](docs/specs/action-context.md) | built (core, API, CLI, macOS UI: found in the batch before Review, raw + wiki refs, preview, Review "Actions found") |
| [Collectors](docs/specs/collectors.md) | built (core, API, CLI, macOS UI incl. script files, TypeScript, packages and Test run; queue rows don't name the collector yet) |
| [Activity log and trash](docs/specs/activity-log.md) | built (core, API, CLI, macOS UI) |
| [Session continuity](docs/specs/session-continuity.md) | built (core, API, CLI, macOS UI; Review's approve, approve-later and parts of a batch go through it) |
| [Live log](docs/specs/live-log.md) | built (core, API, macOS UI; no CLI) |
| [Clean up inbox](docs/specs/inbox-cleanup.md) | built (core, API, macOS UI; no CLI) |
| [Full reads](docs/specs/full-read.md) | built (core, API, CLI, Mac UI; the wiki-ingest skill wording) |
| [Action summary](docs/specs/action-summary.md) | built (core, API, macOS; Ask rows show the summary, no click-to-open yet) |
| [Action buttons and script commands](docs/specs/action-buttons.md) | built (canvas row 15, board ScriptActions; `sa-` snapshot states; Add's What it does step; Ready to send for a Send-slot button) |
| [Resizable panes](docs/specs/resizable-panes.md) | built (macOS: every split screen, `PaneSplit.swift`) |
| [Review queue](docs/specs/review-queue.md) | built (apply queue, refresh, batch list, blocked commands; recovery: the agent where it can choose (blocked commands, stale-again, plan errors, failed runs, a held lock), $0 for session-gone, the journal rule for not-recorded (full-read-stop keeps the v10 option); reinspect/wait retries only under the approved hash, split and discard as proposals; the Couldn't fix card with Rebuild, What was tried and Continue in a new session; `distill status`; canvas row 16, board ReviewQueue) |

## Layout

- `core/src/contracts.ts`: the shared contract every layer builds against (lead-owned).
- `core/src/engine/`: queue, batches, jobs, approval state machine, notes, progress.
- `core/src/ask/`, `core/src/labels/`: Ask (filters, history, cancel) and labels.
- `core/src/actions/`: actions (registry of types and handlers, actions.json,
  finding, drafts) and connections (Atlassian).
- `core/src/collectors/`: collectors (cron scheduler, Folder runs and ledger,
  script runs and consent, run history; collectors.json).
- `core/src/activity/`: the activity log (who changed what, logged at the
  core facade and from events; `activity/activity.jsonl`) and Distill's trash
  for deleted chats and collectors (`trash/`).
- `core/src/steps/`: the live log (a job's steps as they happen, saved to
  `steps/<job>.jsonl`, and the plain words for each step).
- `core/src/engine/queue-labels.ts` (labels on queue files, 3 at a time, and
  the label gate) and `engine/review-labels.ts` (labels, picks, removals and
  parts in Review); `engine/session-seed.ts` and `runners/session.ts`: session
  continuity (detecting a gone AI session and seeding a new one).
- `core/src/runners/`: AI backends behind `AgentRunner` (Claude Code, Codex,
  OpenAI, OpenRouter, Vercel AI SDK), the steps they stream, and Keychain
  secrets.
- `core/src/store/`: settings.json / jobs.json; `core/src/server/`: the local
  HTTP API, token and lock file.
- `cli/`: the `distill` CLI (ask, with `--new-session` when a chat's AI session is gone; note add/label, history, status, queue scan, actions,
  collectors list/run/history, activity, trash list/restore, batch reread, serve, plugin install). It never approves and
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
