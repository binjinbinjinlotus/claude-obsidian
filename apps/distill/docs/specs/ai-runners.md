---
title: AI runners
status: built
updated: 2026-10-01
---

# AI runners

Distill talks to AI through pluggable **runners**. Code: TS core
`core/src/runners/` (all runners); the Swift app
`clients/macos/Sources/WorkerCore/Runners/` has Claude Code only.

Status:

| Runner (`id`) | Kind | Status | Verified how |
| --- | --- | --- | --- |
| Claude Code (`claude-code`) | agent | **built** | argv tests and real runs (see [Claude runner](claude-runner.md)) |
| Codex (`codex`) | agent | **built**, partly verified | Flags come from `codex exec --help` and `codex exec resume --help` (codex-cli 0.155.0-alpha). Real `codex exec` and `codex exec resume` calls accepted the full argv. The start call emitted `thread.started`, `turn.started`, `error` and `turn.failed`; the resume call reached the auth step. `--strict-config` accepted every `-c` key and rejected a bogus one. The login had expired, so no model turn ran: schema acceptance and runtime sandbox confinement are **unverified** |
| OpenAI API (`openai`) | modelAPI | **built**, unverified live | request/response tests with a fake fetch; no API key on the dev machine |
| OpenRouter (`openrouter`) | modelAPI | **built**, unverified live | same as OpenAI |
| Vercel AI SDK (`ai-sdk`) | modelAPI | **built**, unverified live | the real bridge runs in tests against stub `ai` / `@ai-sdk/openai` modules |
| Settings UI | — | **designed** | canvas: Settings → "AI runners", "Default model for each task" |

Every runner except Claude Code is off until its id is in
`settings.enabledRunners`. `listRunners()` / `setRunnerSecret()`
(`runners/admin.ts`) back the Settings screen.

## Pieces

| Type | Role |
| --- | --- |
| `AgentRunner` (protocol) | One backend: `id`, `displayName`, `capabilities`, `models`, `effortLevels`, `defaultModel`, `problems(settings)`, `run(request, settings, process)`, optional `resumeCommand`. |
| `Runners.all` | Registry. Add a backend by conforming to `AgentRunner` and appending it here. |
| `RunRequest` | Runner-neutral turn: cwd, prompt, start/resume session, `ModelSelection`, permission rules (Claude Code syntax), readable dirs, plugin dir, output schema, system prompt, env. |
| `RunResult` | Runner-neutral result: session id, text, error flag, cost, structured output, permission denials, raw bytes. |
| `ModelSelection` | `runnerID` + `model` + optional `effort`. "Choosing a model" always means choosing all three. |
| `AITask` | `ingest`, `ask`, `labelSuggest`, `imageText`. Each declares `requiredCapabilities`. |
| `RunnerCapabilities` | `agentTools`, `toolPermissions`, `sandboxedWrites`, `sessionResume`, `structuredOutput`, `effort`, `vision`. |

## Rules

- A task only runs on a runner whose capabilities cover it
  (`runner.supports(task)`); pickers only list such runners
  (`Runners.candidates(for:settings:)`). The engine re-checks before every turn.
- `ingest` needs `agentTools + sessionResume + structuredOutput` plus either
  `toolPermissions` (enforceable allow-lists, Claude Code) or
  `sandboxedWrites` (write confinement, Codex; see the gate below). Plain
  model APIs cannot run it; they are meant for `labelSuggest` and `imageText`,
  and for Ask only once the app supplies the page text itself.
- A `toolPermissions` runner that cannot enforce a permission rule it is given
  must refuse the turn rather than ignore the rule. A `sandboxedWrites` runner
  is the exception: directory-wide `Edit(//abs/**)` rules become its writable
  folders, file-level Edit grants are dropped (stricter), and command rules
  (`Bash(...)`) are superseded by write confinement. The core, never the agent,
  runs `transaction apply`.
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

## Codex runner (`runners/codex.ts`)

Capabilities: `agentTools`, `sandboxedWrites`, `sessionResume`,
`structuredOutput`, `effort`. Not `toolPermissions`, so Codex can run
`ingest` (through the sandboxed-writes gate below) and `labelSuggest`, but is
never offered for Ask. Not `vision` either: `--image` is passed when a request
has images, but Codex is not a candidate for `imageText`.

Binary: `runnerOptions.codex.path`, else the first of `~/.local/bin/codex`,
`/opt/homebrew/bin/codex`, `/usr/local/bin/codex`,
`/Applications/Codex.app/Contents/Resources/codex`.

Invocation (flags verified in `--help` output of codex-cli 0.155.0-alpha):

- First turn: `codex exec --json --skip-git-repo-check --ignore-user-config
  --ignore-rules -C <workspace> --sandbox <mode> -m <model> -c … -- -`
- Later turns: `codex exec resume --json --skip-git-repo-check
  --ignore-user-config --ignore-rules -m <model> -c … -- <thread-id> -`.
  `exec resume` accepts neither `-s`, `-C` nor `--add-dir`, so the sandbox is
  always also set through `-c` config keys.
- `-c` keys: `sandbox_mode`, `approval_policy="never"`,
  `sandbox_workspace_write.writable_roots=[…]`, `…network_access=false`,
  `…exclude_slash_tmp=true`, `…exclude_tmpdir_env_var=true`, and
  `model_reasoning_effort` when an effort is chosen. The CLI accepted all of
  them in a real run, and `--strict-config` (which rejects unknown override
  keys) accepted them all, so they are recognized config fields. Whether they
  confine writes at runtime is **unverified**: `codex sandbox` in this version
  needs a permission profile, so it could not be tested without a model turn.
  This matters most on resume, where the `-c` keys are the only confinement.
- `--ignore-user-config` / `--ignore-rules` keep the user's own
  `config.toml` (MCP servers, model, approvals) and exec-policy rules out of the
  run, mirroring Claude's `--setting-sources ''`. Auth still comes from
  `CODEX_HOME`.
- The prompt goes over stdin (`-`); `--` ends options so `--image` (variadic on
  `exec`) cannot swallow the positional arguments. Codex has no system-prompt
  flag, so the first turn's prompt starts with `<instructions>…</instructions>`.
- Writable roots are the directory-wide `Edit(//abs/**)` rules of the request
  (the job directory for ingest). File-level Edit grants are skipped, which is
  stricter. With no such rule the sandbox is `read-only`. The process cwd (the
  Codex workspace) is the job directory under `<vault>/.vault-meta/worker/`,
  never the vault, so start and resume use the same workspace. Reading is
  expected to stay unrestricted (vault and product root readable): that is
  workspace-write's documented default, **unverified** on this alpha.
- Output: JSONL events. `thread.started.thread_id` becomes the session id (the
  engine stores it; Codex cannot take an app-chosen id). The last
  `item.completed` `agent_message` is the result text, parsed as JSON when an
  output schema was given. `turn.failed` / `error` set `isError`. Codex reports
  tokens, not money, so `costUSD` is 0. It reports no permission denials.
- `--output-schema <file>`: the schema is written to a temp file, removed after
  the turn. It goes through the strict rewrite described under model APIs
  (every property required; optional ones nullable; nulls stripped after
  parsing), because OpenAI structured output rejects optional properties.
  Whether Codex needs that rewrite is unverified.
- Effort levels `low|medium|high|xhigh`: the set every model in
  `codex debug models` accepts (some also take `max`/`ultra`). Models come from
  the same catalog (`gpt-5.5` default).
- `resumeCommand`: `codex resume <id> -m <model>`.

## Model API runners

`openai` (Responses API, `POST {base}/responses`) and `openrouter` (chat
completions, `POST {base}/chat/completions`) use Node's built-in `fetch`. No
dependencies. They serve `labelSuggest` (`structuredOutput`) and `imageText`
(`vision`); OpenAI also declares `effort` (`reasoning.effort`:
`minimal|low|medium|high`). Each call is stateless: there are no sessions, and
`sessionID` echoes the request's.

- Base URL: `runnerOptions.<id>.baseURL` (defaults `https://api.openai.com/v1`,
  `https://openrouter.ai/api/v1`).
- System prompt: OpenAI `instructions`; OpenRouter a `system` message.
- Images (`RunRequest.images`): PNG, JPEG, GIF or WebP, at most 15 MB each,
  read and sent as base64 data URLs (OpenAI `input_image`, OpenRouter
  `image_url` parts). Other types are refused before any request.
- Structured output: a `json_schema` response format. If every object in the
  schema lists its properties, it is sent in **strict** mode after a rewrite
  (all properties required, optional ones nullable, `additionalProperties:
  false`), and those nulls are stripped from the parsed result. Otherwise it is
  sent with `strict: false`. A ```` ```json ```` fence around the answer is
  tolerated. A non-JSON answer is `malformedOutput`.
- Cost: OpenRouter's `usage.cost` (requested with `usage: {include: true}`);
  OpenAI returns none (0).
- Errors: HTTP failures become `RunnerError('apiError')` with a hint (401/403
  key rejected, 429 rate limit or credits, 5xx provider error) plus the
  provider's message. A refusal, an `incomplete` response or a cut-off
  (`finish_reason: length`) returns `isError: true`. Abort is `cancelled`.
- Models: a curated list (OpenAI `gpt-5-mini` default; OpenRouter
  `google/gemini-2.5-flash` default). Any model id works.

### Vercel AI SDK (`ai-sdk`)

The SDK is a library, so `@distill/core` does not depend on it. The user
installs it in a folder of their choice
(`npm i ai @ai-sdk/openai`, or `@ai-sdk/anthropic`, `@ai-sdk/google`,
`@openrouter/ai-sdk-provider`) and sets `runnerOptions["ai-sdk"].packageDir`
(and optionally `provider`, default `openai`, and `baseURL`). The runner spawns
`<settings.nodePath or this node> runners/ai-sdk-bridge.mjs` with cwd =
`packageDir` and sends one JSON request on stdin (prompt, system, schema, image
data URLs, and the API key, which never goes on argv). The bridge resolves `ai`
and the provider from `packageDir` and calls `generateObject` (or
`generateText` with `Output.object` where `generateObject` is gone), then
prints one JSON result. Models are `provider:model` (e.g.
`anthropic:claude-haiku-4-5`); a bare id uses the configured provider.
`problems()` reports a missing node, bridge, `packageDir`, `ai` package or
provider package. Capabilities are conservative: `structuredOutput` only
(images are passed through, but `vision` is not claimed). The API key is
optional, because provider packages also read their own env vars.
`tsc` does not emit `.mjs`, so the bridge is found next to the module or back in
`src/runners/`.

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

### Ask in context mode (designed)

Model APIs cannot open files. For Ask on such runners the app retrieves the
relevant pages itself (respecting label/source filters, using
`scripts/retrieve.py` or a frontmatter scan), sends their text with the
question, and asks for an answer that cites page paths. Ask therefore accepts
either `agentTools` (agent mode) or a new `contextOnly` path. Not built: today
Ask requires `agentTools + toolPermissions + sessionResume`.

### API keys (`runners/secrets.ts`)

Keys are stored in the macOS login Keychain, never in `settings.json`: service
`com.claude-obsidian.distill`, account `<runnerID>.<name>` (e.g.
`openrouter.apiKey`), through `/usr/bin/security`, with argv only and no shell.

- Write: `security -i` reads
  `add-generic-password -U -s … -a … -X <hex>` from **stdin**, so the value never
  appears on argv where `ps` could see it. (`-w <value>` on argv would, and
  `-w` as the last option prompts on a TTY.)
- Read: `find-generic-password … -g`, parsing the `password:` line on stderr.
  `-w` is not used because it prints non-ASCII values as bare hex.
- Delete: `delete-generic-password`. Status 44 means not found.
- `hasSync` (used by the synchronous `problems()`) checks presence without
  reading the value, cached for 30 s.
- Env fallbacks for headless use: `OPENAI_API_KEY`, `OPENROUTER_API_KEY`. The
  store wins; an env var counts as `isSet` in `listRunners`.
- On other platforms nothing is stored; only the env fallbacks work.
- `setRunnerSecret(runner, name, null)` clears a key. An unknown runner is
  `not_found`; an undeclared secret name or an empty value is `invalid_request`.
- Verified: a real round trip (set, update, non-ASCII read, delete) against a
  throwaway service, cleaned up afterwards. Tests use an in-memory store.

## Adding a runner (checklist)

1. New file in `core/src/runners/` (TS core) or
   `clients/macos/Sources/WorkerCore/Runners/` (Swift app), conforming to `AgentRunner`.
2. Declare honest capabilities; list models and effort levels.
3. Report setup problems (binary path, API key) from `problems(_:)`.
4. Append to `defaultRunners()` (`Runners.all` in Swift), add any settings it needs (with defaults in the
   tolerant decoder), and unit-test the request mapping.
