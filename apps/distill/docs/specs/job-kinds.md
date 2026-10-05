---
title: Job kinds
status: built
updated: 2026-10-05
---

# Job kinds

The extension point for new kinds of work. Code: `core/src/engine/job-kinds.ts`.

```ts
export interface JobKind {
  readonly id: string;
  readonly displayName: string;
  readonly consumesQueue: boolean;   // queue batches create this kind
  readonly task: AITask;             // which per-task runner/model/effort setting it uses
  readonly appliesInCore?: boolean;  // the core builds the bundle and runs the approved apply
  initialPrompt(ctx: JobContext): string;
  allowedTools(ctx: JobContext): string[];
}
```

Register a kind in `JOB_KINDS`. Every kind gets the shared machinery for
free: session start/resume, structured status, approval screen, reply, allow,
reject, cost tracking, Open Session in Terminal, and recovery.

## Built kinds

- **Ingest** (`ingest`, consumes the queue): runs the
  `claude-obsidian:wiki-ingest` skill on the batch, builds one
  `claude-obsidian.transaction.v1` bundle in the job directory, inspects it,
  and stops at `needs_approval`. The prompt also names the skill's absolute
  path, `<productRoot>/skills/wiki-ingest/SKILL.md`, and its folder, so a
  runner that loads no plugin can still read and follow it. Codex runs with
  `--ignore-user-config` and its cwd in the job folder (decision 2026-10-04).

- **Labels** (`labels`, task `labelSuggest`, TS core only): created by
  `confirmLabels` / `suggestLabelsForPages`. No agent turn: the core writes the
  bundle, inspects it and, on approval, applies it itself. `sessionID` is an
  unused UUID; `model` is `none` for confirm jobs. `suggestLabelsForPages`
  returns its job while still `running` and suggests page by page in the
  background (`labelPages` progress); it has no resume command.

In the TS core (`core/src/engine/job-kinds.ts`) a kind may set
`appliesInCore: true`: approval runs the exact apply in the core instead of
resuming a session, and reply/allow are refused. The same apply path is used
for any job whose runner lacks `toolPermissions`
([Approval and review](approval-and-review.md)).

## Rules for new kinds

- Start from `ctx.planningTools`; never add `transaction apply` to phase 1.
- Write only inside `ctx.stateDirectory`.
- Use `ctx.coreCommand` / `ctx.quotedVault` verbatim in prompts so permission
  rules match.
- Read-only kinds (for example Ask) still end with a structured status.
