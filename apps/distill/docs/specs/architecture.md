---
title: Architecture (core, CLI, plugin, clients)
status: designed
updated: 2026-10-01
---

# Architecture

Distill is split into one **core** that owns all behavior and state, and thin
**clients** that only display and send commands: the macOS app today, a web or
mobile app later, the `distill` CLI, and AI agents through the plugin.

```
                      ┌──────────────────────────────────────────┐
  clients/macos ─────▶│  core (Node + TypeScript)                │──▶ AI runners
  clients/web   ─────▶│   engine · scheduler · queue · jobs      │    (Claude Code, Codex,
  cli (distill) ─────▶│   runners · labels/sources · Ask         │     OpenRouter, OpenAI,
  plugin skills ──CLI▶│   local HTTP API + event stream          │     Vercel AI SDK)
                      └───────────────┬──────────────────────────┘
                                      │ subprocess
                                      ▼
                       scripts/claude-obsidian.py  (Python core: the only
                       thing that writes the vault, via transactions)
```

## Layout

```
apps/distill/
  AGENTS.md  docs/specs/          shared by every layer
  core/                           Node + TypeScript: engine, runners, HTTP API
  cli/                            `distill` command (thin client of core)
  plugin/                         agent skills + Claude Code / Codex packaging
  clients/
    macos/                        Swift app (built today)
    web/  ios/ …                  future clients
```

## Rules the design must keep

1. **One owner of state.** Only the core server schedules batches, claims queue
   files, writes `jobs.json`/`settings.json` and runs AI turns. Clients and the
   CLI never do. The Swift `WorkerEngine` is retired when the macOS client
   switches to the API and must never run alongside the server. A lock file
   under `~/Library/Application Support/Distill/` keeps a second server from
   starting.
2. **The vault is written only by the Python core**, through reviewed
   transactions. The TS core orchestrates; it does not reimplement transactions.
3. **The approval gate stays with a person.** Approve/apply exist only in UI
   clients. The CLI exposes `ask` (read-only) and `note add` (queues a note,
   which still goes through Review). The plugin's skills tell agents plainly
   that they cannot approve changes.
4. **Local API security.** Bind to `127.0.0.1` only (or a Unix socket);
   require a per-user token stored in a `0600` file next to the settings; reject
   requests whose `Host`/`Origin` are not local. Remote access for web/mobile is
   out of scope until a separate auth design exists.
5. **State compatibility.** Keep today's `settings.json` / `jobs.json` format
   and location so existing settings carry over.

## Core API (sketch)

| Method | Path | Purpose |
| --- | --- | --- |
| GET | `/v1/status` | server, vault, runners, setup problems |
| GET/PUT | `/v1/settings` | settings (no secrets) |
| GET | `/v1/queue` · POST `/v1/queue/files` · POST `/v1/queue/process` | queue |
| POST | `/v1/notes` | add a written note (text, images with keep/extract, source) |
| GET | `/v1/jobs` · GET `/v1/jobs/:id` | jobs and history |
| POST | `/v1/jobs/:id/approve` · `/reply` · `/allow` · `/reject` · `/cancel` | review actions (UI clients only) |
| POST | `/v1/ask` | ask a question (runner/model/effort, optional label/source filters); follow-ups by session id |
| GET | `/v1/labels` · `/v1/sources` | taxonomy |
| GET | `/v1/events` | server-sent events: queue, job and approval changes |

## CLI

```bash
distill ask "How hot for sencha?" [--label tea] [--source slack] \
            [--runner claude-code --model sonnet --effort medium] [--json]
distill note add --title "Gyokuro at 60 °C" [--text "…" | --file note.md | -] \
            [--image card.png:extract] [--image setup.jpg] \
            [--source in-person --ref "with Mei"] [--json]
distill status            # server, vault, queue, pending reviews
distill serve             # run the core server in the foreground
```

The CLI talks to the running server and starts it if it is not running. `--json`
gives stable machine-readable output for agents.

## Plugin

`apps/distill/plugin/` holds portable Agent Skills (only `name` and
`description` in frontmatter, as in the repo's `skills/`):

- `distill-ask`: when and how to call `distill ask`, how to cite the answer.
- `distill-note`: how to call `distill note add`, choosing a source, images.

Packaging:

- **Claude Code**: `.claude-plugin/plugin.json` plus a local
  `marketplace.json`. Install with
  `claude plugin marketplace add <path>` then
  `claude plugin install distill@<marketplace>` (commands verified with
  `claude plugin --help`). This is separate from the repo-root claude-obsidian
  plugin.
- **Codex**: copy or link the skills into `~/.agents/skills/<name>/` (older
  location `~/.codex/skills/`). Locations come from third-party guides; confirm
  against OpenAI's docs at build time.
- `distill plugin install --target claude|codex` automates both.

## Runtime and secrets

- Node: GUI apps do not see an nvm `PATH`. Either bundle a Node runtime with
  the app, or use a `nodePath` setting like `claudePath` (decision pending).
- API keys (OpenRouter, OpenAI, AI SDK providers) live in the macOS Keychain,
  accessed from Node through the `security` command; never in `settings.json`.

## Port parity checklist (must hold before the macOS client switches)

- Two-phase run; the core runs `transaction inspect` itself for the approval screen.
- Apply allowed only as the exact approved command (or run by the core for
  sandbox-style runners); paths shell-quoted.
- One `--allowedTools` argv entry per rule; `Edit(//…)` rules; no suggested rule
  for compound commands; bypass warnings.
- Settle delay, partial-download skip, inbox move with collision names, queue =
  inbox mode, one job per vault.
- Recovery of jobs that were mid-turn; resume keeps the same session id.
- Capability check per task; per-job runner/model/effort.
- Port the 19 Swift unit tests to TypeScript first, then rerun the
  throwaway-vault end-to-end test through the core (the CLI is the harness).

## Proposed build order

1. Core in TypeScript at parity with today's Swift engine (+ tests, e2e).
2. CLI: `ask`, `note add`, `status`, `serve`.
3. Plugin: skills + Claude Code and Codex install.
4. macOS client talks to the core API; Swift engine removed.
5. Designed features built once in the core, then surfaced in clients: Ask,
   Write a note, labels/sources, Notes screen, quick actions and shortcuts,
   runner settings, the four new runners, app icon.

## Open decisions

- Transport: localhost HTTP + token (proposed) or Unix socket.
- Server lifecycle: started by the Mac app, by the CLI on demand, or a
  login item (launchd).
- Node: bundled runtime or system install with a `nodePath` setting.
- Confirm the build order above.
