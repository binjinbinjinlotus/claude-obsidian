---
title: AI runners
status: built
updated: 2026-10-01
---

# AI runners

Distill talks to AI through pluggable **runners**. Claude Code is the only one
today; Codex, OpenRouter, OpenAI-compatible APIs and the Vercel AI SDK are
planned. Code: `clients/macos/Sources/WorkerCore/Runners/`.

Status: the code structure and per-task selection are **built** (Claude Code only); the Codex, OpenRouter, OpenAI API and Vercel AI SDK runners and the Settings UI
are **designed** (canvas: Settings → "AI
runners", "Default model for each task").

## Pieces

| Type | Role |
| --- | --- |
| `AgentRunner` (protocol) | One backend: `id`, `displayName`, `capabilities`, `models`, `effortLevels`, `defaultModel`, `problems(settings)`, `run(request, settings, process)`, optional `resumeCommand`. |
| `Runners.all` | Registry. Add a backend by conforming to `AgentRunner` and appending it here. |
| `RunRequest` | Runner-neutral turn: cwd, prompt, start/resume session, `ModelSelection`, permission rules (Claude Code syntax), readable dirs, plugin dir, output schema, system prompt, env. |
| `RunResult` | Runner-neutral result: session id, text, error flag, cost, structured output, permission denials, raw bytes. |
| `ModelSelection` | `runnerID` + `model` + optional `effort`. "Choosing a model" always means choosing all three. |
| `AITask` | `ingest`, `ask`, `labelSuggest`, `imageText`. Each declares `requiredCapabilities`. |
| `RunnerCapabilities` | `agentTools`, `toolPermissions`, `sessionResume`, `structuredOutput`, `effort`, `vision`. |

## Rules

- A task only runs on a runner whose capabilities cover it
  (`runner.supports(task)`); pickers only list such runners
  (`Runners.candidates(for:settings:)`). The engine re-checks before every turn.
- `ingest` needs `agentTools + toolPermissions + sessionResume +
  structuredOutput`: the approval gate depends on enforceable allow-lists and on
  resuming the same session. Plain model APIs cannot run it; they are meant for
  `labelSuggest` and `imageText`, and for Ask only once the app supplies the
  page text itself.
- A runner that cannot enforce a permission rule it is given must refuse the
  turn rather than ignore the rule.
- Each job stores its `runnerID`, `model` and `effort`, so resumes use the same
  backend even if defaults change later. Jobs saved before runners existed have
  no `runnerID` and are treated as Claude Code.

## Settings

Stored in `settings.json`:

- `enabledRunners`: ids turned on (default `["claude-code"]`).
- `taskDefaults`: `{ "<task>": { "runnerID", "model", "effort" } }`.
- Missing entries fall back to `defaultSelection(for:)`: Claude Code, the legacy
  `model` field for `ingest`/`ask`, Haiku for `labelSuggest`.
- `SetupValidator` checks every runner that some task is set to use.

## Claude Code runner

`ClaudeCodeRunner` maps a `RunRequest` to `claude -p` flags, including
`--effort` (`low|medium|high|xhigh|max`). Details: [Claude runner](claude-runner.md).

## Planned runners (designed, build next)

| Runner | Kind | Tasks it can serve | Notes |
| --- | --- | --- | --- |
| **Codex** (`codex exec`) | Agent CLI | all, with the gate below | Session resume, JSON-schema output, reasoning effort and images are expected from its CLI; verify exact flags at build time (not installed on the dev machine yet). |
| **OpenRouter** | HTTP model API (OpenAI-compatible) | `labelSuggest`, `imageText`, Ask in context mode | Model list fetched from the API; structured output, images and reasoning effort depend on the chosen model, so capabilities are per model. |
| **OpenAI API** | HTTP model API | `labelSuggest`, `imageText`, Ask in context mode | Responses API: JSON-schema output, images, `reasoning.effort`. |
| **Vercel AI SDK** | Local Node bridge | same as model APIs | The SDK is a TypeScript library, not a service: Distill ships a small bridge script (`apps/distill/core/bridges/ai-sdk/`) that reads a `RunRequest` as JSON on stdin and calls `generateObject`/`generateText` with the configured provider. Needs Node (found: v22). |

### Approval gate for agents without per-command allow-lists

Claude Code enforces "only these commands" rules. Codex instead sandboxes by
writable folders. For such runners:

- Phase 1 runs with the job directory as the only writable folder, so the agent
  can read the vault and write its bundle but cannot change the vault.
- The **app itself** runs the exact approved
  `transaction apply … --approved-plan-sha256 <sha>` after the user approves,
  instead of granting the agent permission to run it. This keeps the gate
  identical for every runner. A new capability, `sandboxedWrites`, marks runners
  that can be confined this way; `ingest` accepts `toolPermissions` or
  `sandboxedWrites`.

### Ask in context mode

Model APIs cannot open files. For Ask on such runners the app retrieves the
relevant pages itself (respecting label/source filters, using
`scripts/retrieve.py` or a frontmatter scan), sends their text with the
question, and asks for an answer that cites page paths. Ask therefore accepts
either `agentTools` (agent mode) or a new `contextOnly` path.

### API keys

Keys for OpenRouter, OpenAI and AI SDK providers are stored in the macOS
Keychain, never in `settings.json`. Settings → AI runners → **Set up** opens a
sheet to enter and test a key; only the runner's enabled flag and non-secret
options (base URL, provider) go into `settings.json`.

## Adding a runner (checklist)

1. New file in `clients/macos/Sources/WorkerCore/Runners/`, conforming to `AgentRunner`.
2. Declare honest capabilities; list models and effort levels.
3. Report setup problems (binary path, API key) from `problems(_:)`.
4. Append to `Runners.all`, add any settings it needs (with defaults in the
   tolerant decoder), and unit-test the request mapping.
