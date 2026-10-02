---
title: Approval and review
status: built
updated: 2026-10-01
---

# Approval and review

Nothing reaches the vault without the user's decision. Code:
`clients/macos/Sources/WorkerCore/WorkerEngine.swift`, `clients/macos/Sources/WorkerCore/JobKind.swift`
(`WorkerProtocol`, `JobContext.planningTools`), UI in
`clients/macos/Sources/Distill/MainView.swift` (`ReviewSection`, `JobDetailView`).

## Phase 1: plan

Allowed tools (`JobContext.planningTools`): `Skill`, `Read`, `Glob`, `Grep`,
`Edit(//<job-dir>/**)` (Edit rules cover Write too), and only these shell
commands: `python3 <core> transaction inspect:*`, `doctor:*`, `lint:*`,
`shasum -a 256:*`, plus Settings → extra allowed tools and rules the user
granted for this job. `transaction apply` is never allowed in this phase.

The system prompt tells Claude to build the bundle without scripts (Write tool
plus `shasum`), run one command at a time with absolute paths, and end with a
structured status.

## The approval screen

On `needs_approval` the app checks that `bundle_path` lies inside the job's own
directory, then runs `transaction inspect` itself. The screen shows the core's
plan (`changed_paths`, `approval_sha256`), not Claude's description of it. A
change is shown as new (+) when the target file does not exist yet.

User actions:

- **Approve & apply** (⌘↩): resumes the session with exactly one extra rule,
  `Bash(<exact apply command with the approved sha>)`. Paths are shell-quoted
  (`shellQuote`) so vaults with spaces work and the rule still matches.
- **Reply**: resumes the session with the user's text; planning tools only.
- **Allow & continue**: grants the selected denied tool calls for the rest of
  the job. Compound shell commands get no rule (Claude Code checks them part by
  part); Bash and out-of-job-dir Edit grants show a warning that they bypass
  review.
- **Reject**: ends the job. Inbox files are kept.

On exit 75 (stale hashes) Claude is told to rebuild, re-inspect, and ask again.

## Concurrency and recovery

- One job per vault holds the vault while `running` or `awaitingApproval`; new
  batches wait (`batchBlocker`), so a bundle is never built against hashes a
  pending approval will change.
- A job found `running` at launch becomes `awaitingApproval` with a note; the
  user can reply to resume the same session.
- When a new job needs approval the main window switches to Review and the
  floating icon and Dock show a count.
