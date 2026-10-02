---
title: Architecture (core, CLI, plugin, clients)
status: built
updated: 2026-10-02
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
   clients. The CLI exposes `ask` and `history` (read-only, plus deleting a
   chat), `note add` (queues a note, which still goes through Review) and
   `note label` (labels for a note still in the queue). Confirming AI labels
   on vault pages is also UI-only. The plugin's skills tell agents plainly
   that they cannot approve changes or confirm labels.
4. **Local API security.** Bind to `127.0.0.1` only (or a Unix socket);
   require a per-user token stored in a `0600` file next to the settings; reject
   requests whose `Host`/`Origin` are not local. Remote access for web/mobile is
   out of scope until a separate auth design exists.
5. **State compatibility.** Keep today's `settings.json` / `jobs.json` format
   and location so existing settings carry over.

## Core API (built: `core/src/server/http.ts`)

Every request needs `Authorization: Bearer <token>` and a local `Host`
(`127.0.0.1`, `localhost`, `[::1]`); a non-local or `null` `Origin` is refused
(403) before the token is checked. Bodies are JSON (`Content-Type:
application/json`, at most 1 MiB). Every error is `{"error": {"code",
"message"}}`: 400 `invalid_request`/`invalid_json`, 401 `unauthorized`, 403
`forbidden_host`/`forbidden_origin`, 404 `not_found` (or `job_not_found`,
`conversation_not_found`), 405 `method_not_allowed`, 409
`invalid_state`/`busy`/`no_vault`, 413, 415, 501 `not_implemented`, 500
`internal_error`. Types are those in `core/src/contracts.ts`.

| Method | Path | Body | Response |
| --- | --- | --- | --- |
| GET | `/v1/status` | | `StatusResponse` |
| GET · PUT | `/v1/settings` | PUT: partial `Settings` | `Settings` (no secrets) |
| GET | `/v1/queue` | | `{entries: QueueEntry[]}` |
| POST | `/v1/queue/files` | `{paths}` | `{entries}` |
| DELETE | `/v1/queue/entries` | `{path}` | `{entries}`: the file (and a note's `.distill.json`) moved to the Trash; 400 outside the active queue folder, 409 when a batch took it |
| POST | `/v1/queue/process` | `{force?}` | `{job: Job \| null}` |
| POST | `/v1/notes` | `AddNoteRequest` (`labels?`, `suggest?: wait\|background\|none`, `origin?: app\|cli`) | 201 `AddNoteResult` |
| POST | `/v1/notes/:requestID/labels` | `{labels: string[]}` | `{notePath, labels}`; 409 once the batch took the note |
| GET | `/v1/labels[?vault=PATH]` | | `{labels: LabelCount[]}` |
| GET | `/v1/labels/review[?vault=PATH]` | | `LabelReview` |
| POST | `/v1/labels/suggest` | `{paths, vaultPath?, selection?}` | `{job}` (UI clients) |
| POST | `/v1/labels/confirm` | `{items: [{path, labels}], vaultPath?}` | `{job}` (UI clients) |
| GET | `/v1/jobs` · `/v1/jobs/:id` | | `{jobs}` · `Job` |
| DELETE | `/v1/jobs/:id` | | `{id, deleted: true}`; 409 unless completed/failed/rejected/cancelled |
| GET | `/v1/jobs/:id/resume` | | `{argv}` that reopens the job's AI session; 404 `no_resume_command` when there is none |
| POST | `/v1/jobs/:id/approve` · `/reply` · `/allow` · `/reject` · `/cancel` | `reply {text}`, `allow {rules}` | `{job}` (UI clients only) |
| POST | `/v1/ask` | `AskRequest` (`labelMatch?: any\|all`, `includeUnconfirmed?`, `conversationID?`: an existing chat, or a new well-formed id) | `AskResponse` (`notices?`); 409 `invalid_state` "Stopped" after a cancel |
| POST | `/v1/conversations/:id/cancel` | | `{id, cancelled: true}`; stops the in-flight turn (no-op when idle) |
| GET | `/v1/progress` | | `{progress: Progress[]}`: work in flight, for clients that connect mid-run |
| GET | `/v1/conversations` | | `{conversations: AskConversationSummary[]}` |
| GET · DELETE | `/v1/conversations/:id` | | `AskConversation` · `{id, deleted: true}` |
| POST | `/v1/conversations/:id/pin` | `{pinned: boolean}` | `AskConversationSummary` |
| GET | `/v1/runners` | | `{runners: RunnerInfo[]}` |
| PUT | `/v1/runners/:id/secrets/:name` | `{value: string}` or `{value: null}` to clear | `{runnerID, name, isSet}` |
| GET | `/v1/events` | | server-sent events, below |

Label names in bodies are trimmed, lose a leading `#`, are de-duplicated and
may not contain whitespace. Omitted `labelMatch`/`includeUnconfirmed` take the
user's `askPreferences`. Sources come from `settings.sourceTaxonomy`; there is
no separate sources route.

**Secrets.** The secret route never echoes, logs or stores the value in the
response; any error message that contains it is redacted (`[redacted]`). The
value goes only to the core, which keeps it in the Keychain.

**Jobs in responses.** Every `Job` the API returns (also inside `job` events)
has `suggestedRule` (string or `null`) on each `approval.denials` entry: the
exact rule Allow would grant (`runners/permissions.ts`), `null` for compound
shell commands. Stored jobs do not change.

**Events.** `GET /v1/events` is `text/event-stream`: `retry: 2000`, then one
`event: <type>\ndata: <CoreEvent JSON>\n\n` per event (`queue`, `job`,
`settings`, `log`, `labelSuggestions`, `conversation`, `progress`), and a
`: keep-alive` comment every 15 s. A deleted job is a `job` event with
`deleted: true` (proposed contract addition).

**Progress (loading states).** Long AI work emits `progress` events
(`Progress` in contracts.ts); each run of a key ends with exactly one event
with `finished: true` (with `error` when it failed). `startedAt` stays the same
for the run, so clients can show an elapsed timer.

| Kind | Key | When | Fields |
| --- | --- | --- | --- |
| `batch` | job id | a batch from creation to review; reply and allow turns | `steps`, `stepIndex`, `runnerID`, `model`; `done`/`total` during the label pre-step |
| `apply` | job id | from Approve until the job leaves `running` | message `Applying N changes`; `runnerID`/`model` only when an agent applies |
| `labelSuggest` | `note:<requestID>` | the suggestion around `addNote` (wait and background) | `runnerID`, `model` |
| `labelPages` | job id | `suggestLabelsForPages` | `done`/`total` pages, then "Preparing the change for Review" |
| `ask` | `ask:<conversationID>` | one Ask runner turn | message `Reading your notes`; `runnerID`, `model`; "Stopped" after a cancel |

Batch steps are `Moved to inbox`, `Suggesting labels` (only with a label
pre-step), `Read sources`, `Drafting page changes`, `Ready for review`;
`stepIndex` is the step in progress (earlier ones are done). Runners report no
progress inside a turn, so `Read sources` covers the whole agent turn and
`Drafting page changes` the core's `transaction inspect` of the bundle; the
finished event of a job that waits for review points at `Ready for review`.

## CLI (built: `cli/src/cli.ts`)

```bash
distill ask "How hot for sencha?" [--label tea]... [--match any|all] \
            [--unconfirmed include|exclude] [--source slack]... \
            [--runner claude-code --model sonnet --effort medium] \
            [--conversation ID] [--vault PATH] [--json]
distill note add --title "Gyokuro at 60 °C" [--text "…" | --file note.md | -] \
            [--image card.png:extract] [--image setup.jpg] \
            [--source in-person --ref "with Mei"] [--label L]... [--no-suggest] [--json]
distill note label <request-id> --label L... [--json]
distill history [--json]          # list Ask conversations
distill history show <id> [--json]
distill history rm <id> [--json]
distill status [--json]           # server, vault, queue, pending reviews
distill serve [--port N]          # run the core server in the foreground
distill plugin install --target claude|codex [--dry-run] [--copy] [--force] [--json]
```

- `note add` always sends `origin: "cli"`. With `--label` it sends the labels
  and `suggest: "none"`; with `--no-suggest`, `suggest: "none"`; otherwise
  `suggest: "wait"`, and the human output prints the request ID, the suggested
  labels (new ones marked `(new)`) and the exact `distill note label …` command
  to keep them.
- `ask` leaves `--match`/`--unconfirmed` out of the request when not given, so
  the server's Ask settings apply; notices print above the answer.
- `ask` picks a new chat's `conversationID` (a UUID) before the request. When
  stdout is a terminal and `--json` is off it follows `ask:<id>` progress over
  `/v1/events` and keeps one status line on stderr (message, runner · model,
  elapsed time after 3 s, "Still working" after 60 s). Ctrl-C posts
  `/v1/conversations/:id/cancel` and exits 130 with code `stopped`; a second
  Ctrl-C quits at once.
- There are no approve, apply, reply, reject or confirm-labels commands:
  approval and label confirmation stay in UI clients. `--help` says so.
- `--json` prints one JSON document (each shape is documented in `--help`);
  errors are `{"error": {"code","message"}}` with exit code 1, or 2 for usage
  (130 for a stopped `ask`).

The CLI talks to the running server and starts it if it is not running.

## Plugin (built: `plugin/`)

`apps/distill/plugin/` holds portable Agent Skills (only `name` and
`description` in frontmatter, as in the repo's `skills/`):

- `distill-ask`: when and how to call `distill ask`, the `--match` and
  `--unconfirmed` filters, history, how to cite the answer and pass on notices.
- `distill-note`: how to call `distill note add`, choosing a source, images,
  and the request-ID labeling loop: read `suggestedLabels` (prefer
  `existing: true`), decide, then `distill note label <request-id> --label …`
  before the next batch. Both skills state that agents cannot approve changes
  or confirm labels.

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

## Server lifecycle and state files (built)

Transport is **localhost HTTP + bearer token** (decided and built): the server
binds `127.0.0.1` only, on a free port unless `distill serve --port N`.
Lifecycle (built for the CLI): `distill serve` runs it in the foreground, and
any other CLI command starts it **on demand**, detached, when no live server
is found. One server runs per state dir (`~/Library/Application
Support/Distill`, or `$DISTILL_STATE_DIR`). The Mac app and a launchd login
item can use the same `distill serve` entry point later.

- `<state dir>/token`: 64 lowercase hex characters (32 random bytes), no
  newline, mode `0600`; created by the first server, tightened to `0600` if
  looser. Clients read it to send `Authorization: Bearer <token>`.
- `<state dir>/server.json` (mode `0600`), written only after the server
  listens, atomically (temp file hard-linked into place, so two servers cannot
  both win):

  ```json
  { "pid": 41235, "port": 52011, "startedAt": "2026-10-01T15:42:00.000Z", "version": "0.1.0" }
  ```

  It is removed on shutdown (SIGINT/SIGTERM or process exit) only by the
  process that owns it. A file whose `pid` is dead is stale: the next server
  replaces it, and clients treat it as "no server".
- `<state dir>/server.log`: stdout and stderr of a server the CLI started,
  appended (mode `0600`). Lines are `distill serve: <message>`, e.g.
  `distill serve: listening on http://127.0.0.1:52011 (pid 41235, state …)`
  and `distill serve: received SIGTERM, shutting down`. When a started server
  exits before it is ready, the CLI reports the log path and the new lines.
  Secret values are never logged.

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

- ~~Transport~~: decided and built, localhost HTTP + token (see
  [Server lifecycle and state files](#server-lifecycle-and-state-files-built)).
- ~~Server lifecycle~~: built for the CLI (on demand, or `distill serve`).
  Whether the Mac app or a launchd login item also starts it is the macOS
  client's call; both would use `distill serve`.
- Node: bundled runtime or system install with a `nodePath` setting.
- Confirm the build order above.
