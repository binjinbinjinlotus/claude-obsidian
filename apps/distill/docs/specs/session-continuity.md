---
type: spec
title: Session continuity
status: designed
created: 2026-10-05
updated: 2026-10-05
tags:
  - distill
  - runners
  - approval
  - ask
---

# Session continuity

## The rule (system-wide)

If an AI session that Distill would resume no longer exists, for whatever
reason, Distill tells you that a new session will be used and waits for your
OK. It never resumes into nothing and never swaps sessions silently. This
holds for every place that reuses a session (owner, 2026-10-05).

Design: canvas row "10 · Session continuity". The boards are
`SessionContinuity` (one frame per place) and `SessionReplaceConfirmStates`.
The component is `SessionReplaceConfirm`. The schema lives in
`design/components.json` and `design/screens/session.json`.

## Where a session is reused

| Place | Code | Runners |
| --- | --- | --- |
| Review: Approve & apply (agent apply only; kinds that apply in the core have no session) | `engine approve` → `runTurn` `{resume}` | Claude Code, Codex |
| Review: Send reply, including a cancelled batch, a batch whose worker quit mid-turn, and a batch whose first turn never ran | `engine reply` → `runTurn` | Claude Code, Codex |
| Review: Allow (denied tools) | `engine allow` → `runTurn` | Claude Code, Codex |
| Ask follow-ups, main window and Quick Ask | `ask/index.ts` `{resume}`; Mac `AskModel.send` | Claude Code, Codex |
| Open in Terminal | `jobResumeCommand`, `GET /v1/jobs/:id/resume`; the Mac fallback `terminalScript(for:)` | Claude Code, Codex |
| CLI `distill ask --conversation ID`, and the `distill-ask` skill that wraps it | `cli.ts` | through Ask |

These places never reuse a session, because they start a fresh one on every
call:

- action draft and improve (`actions/ai.ts runStructured`);
- label suggestions (`labels/suggest.ts`);
- image text.

They don't need the confirmation. OpenAI, OpenRouter and the Vercel AI SDK are
stateless: they have no `sessionResume`, and they can't run ingest or Ask. For
those runners, "unavailable" only ever means that a batch's runner is gone.

Ask also starts a new session on purpose when the runner, vault, filter scope
or workspace changes. That is your own change, not a lost session, so it keeps
its notice and gets no confirmation. A new session never crosses a filter
scope with replayed history: earlier turns' page text would leak into a
narrower filter.

## Detection: positive evidence only

| Reason code | Evidence |
| --- | --- |
| `notFound` | The runner refused to resume. Claude Code exits 1 with empty stdout and stderr `No conversation found with session ID: <id>`. Codex exits 1 with stderr `… no rollout found for thread id <id>`. Both were verified against the real CLIs (Claude Code 2.1.289) using a temp config home. The phrase and the exact requested ID must both match. |
| `missing` | Checked before the resume. The runner's session store is readable, but no file for `<id>` exists under it. For Claude Code that is `$CLAUDE_CONFIG_DIR` or `~/.claude`, then `projects/*/<id>.jsonl`. For Codex it is `$CODEX_HOME` or `~/.codex`, then `sessions/**/rollout-*-<id>.jsonl`. An unreadable or absent root means unknown, and the resume goes ahead. |
| `neverStarted` | The job itself shows that no worker turn ever ran. This comes from the job, not the filesystem. |
| `runnerGone` | The job's runner is unknown, or it no longer has `sessionResume`. |

Every other runner error (auth, rate limit, exit 1 with other text, malformed
output) stays an ordinary failure.

## API (additive)

- Error `409 {error: {code: "session_unavailable", message, place, reason,
  detail}}`, where `place` is `batch`, `conversation` or `terminal`.
  `message` is the plain sentence and `detail` the technical line, without
  content.
- To continue in a new session, send the same call again with
  `newSession: true`:
  - `POST /v1/jobs/:id/approve`, `/reply` and `/allow`;
  - `POST /v1/ask`;
  - `GET /v1/jobs/:id/resume?newSession=1`.
  The approval-plan check, the gate check on allowed rules and the vault and
  busy checks therefore stay on one path.
- When a batch's resume fails after its turn has started, the job snapshot is
  restored: state, approval, turns and granted tools. The progress event is
  closed, and the job carries `sessionUnavailable: {place, reason, message,
  detail, action, at}`. The app shows the confirmation from that marker.
  Cancel dismisses it on the client, and the next turn that succeeds clears
  it.
- An activity entry, `session.replaced`, records the place and the reason,
  never content.

## What a new session gets

- **A batch** gets its sources (files and folders), its label plan
  (`labels.json`), the conversation so far as a short summary, the current
  plan or bundle path, and then the pending action. If the first turn never
  ran, it gets the kind's first prompt. An approved apply runs the same
  command, which is pinned by `--approved-plan-sha256`. The new `sessionID`
  is stored on the job.
- **A conversation** gets the earlier questions and answers replayed (bounded)
  ahead of the question, under the same scope. The conversation stores the new
  `sessionID`.
- **Terminal** opens a fresh interactive session primed with the batch. The
  batch keeps its own session record.

## Clients

- Mac: `SessionReplaceConfirm` appears where you acted. In Review it sits above
  the footer, whose buttons are dimmed. In Ask it takes the place of the
  pending question. Open in Terminal shows it as a popover. Cancel changes
  nothing (Ask puts the question back in the box). Continue sends the same
  call again with `newSession`.
- CLI: prints the sentence and the detail, asks nothing, and exits 1.
  `--new-session` continues. `--json` returns the typed error.
