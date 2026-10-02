---
title: Job kinds
status: built
updated: 2026-10-01
---

# Job kinds

The extension point for new kinds of work. Code: `clients/macos/Sources/WorkerCore/JobKind.swift`.

```swift
public protocol JobKind: Sendable {
    var id: String { get }
    var displayName: String { get }
    var consumesQueue: Bool { get }          // queue batches create this kind
    func initialPrompt(_ ctx: JobContext) -> String
    func allowedTools(_ ctx: JobContext) -> [String]
}
```

Register a kind in `JobKinds.all`. Every kind gets the shared machinery for
free: session start/resume, structured status, approval screen, reply, allow,
reject, cost tracking, Open Session in Terminal, and recovery.

## Built kinds

- **Ingest** (`ingest`, consumes the queue): runs the
  `claude-obsidian:wiki-ingest` skill on the batch, builds one
  `claude-obsidian.transaction.v1` bundle in the job directory, inspects it,
  and stops at `needs_approval`.

- **Labels** (`labels`, task `labelSuggest`, TS core only): created by
  `confirmLabels` / `suggestLabelsForPages`. No agent turn: the core writes the
  bundle, inspects it and, on approval, applies it itself. `sessionID` is an
  unused UUID; `model` is `none` for confirm jobs.

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
