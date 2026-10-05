---
title: Approval and review
status: built
updated: 2026-10-05
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

**The core enforces the gate** (decision 2026-10-04). One classifier,
`gateBreakingReason` in `core/src/runners/permissions.ts`, decides whether a
rule would let the agent change the vault before review. Gate-breaking rules:

- bare `Bash`, `Bash(*)`;
- any rule that mentions `transaction apply`, in any spelling;
- a Bash prefix rule whose prefix also starts the core's apply command, such
  as `Bash(python3:*)` or `Bash(/usr/bin/python3:*)`;
- a Bash rule for a shell interpreter (`sh`, `bash`, `zsh`, `env`, `xargs`,
  `eval`, …);
- an Edit/Write/MultiEdit/NotebookEdit rule that is bare, not `//abs`, keeps
  a glob after one trailing `/**` or `/*`, or resolves (`..` and symlinks
  included) outside **this** job's directory.

It is used in three places:

- `planningTools` drops such rules from Settings → extra allowed tools and
  from the job's grants at use time. Saved settings are never rewritten.
  Codex, which turns directory Edit rules into sandbox writable roots, gets
  the filtered list.
- `allow()` refuses the whole call with `invalid_request` before changing
  anything. The message starts with each refused rule and why ("Distill
  can't allow <rule> (<why>). It would change the vault without your
  review…"), so the rules fit the app's three-line error banner.
- The approval screen's warning (`bypassesApproval`) uses the job's own
  folder.

The one-turn apply rule that Approve adds is not filtered.

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
  review. The core refuses the gate-breaking ones (see Phase 1).
- **Reject**: ends the job. Inbox files are kept.

Layout (canvas: "Review"): the details column shows the heading, then what
needs the user (plan error, Claude's questions, the blocked-tools card with
**Allow & continue**), then the stats and the change list, so Allow & continue
is visible without scrolling at the 900 × 600 minimum window. The conversation
column starts at the top; a long thread opens at its latest turn. The reply box
shows the placeholder "e.g. Add this to the Green tea page instead" whenever it
is empty (the text view redraws fully when it turns empty or non-empty).

API clients get `suggestedRule` (string or `null`) on every denial of a job
the server returns, so Allow can show and send the exact rule without
re-deriving it. While Approve applies, the core emits `apply` progress
(key = job id, `Applying N changes`) until the job leaves `running`; clients
keep Approve and Reject disabled meanwhile.

Finished jobs (completed, failed, rejected, cancelled) can be removed from the
list with `deleteJob` (`DELETE /v1/jobs/:id`); a job still running or waiting
for review cannot (409). The job directory in the vault is kept. When the
queue folder is the vault's `inbox/`, a job whose files are still in `inbox/`
cannot be deleted either: its files would go back into the next batch.
`GET /v1/jobs/:id/resume` returns the argv that reopens the job's AI session
in a terminal (the runner's `resumeCommand`; none for label jobs).

On exit 75 (stale hashes) Claude is told to rebuild, re-inspect, and ask again.
On `ERR LOCK_TIMEOUT` it is told not to rebuild, only to inspect the same
bundle again and ask again.

**What Distill records after an agent apply** (decision 2026-10-04). When
Approve starts the agent's apply turn, the core remembers the approved plan
for that turn only. On `done`, the job records `operationID` and
`changedPaths` only if that turn was the approved apply turn and
`status.operation_id` equals `plan.operation_id`. The paths come from the
inspected plan (`plan.changed_paths`), never from the model, and an app turn
says "Applied <op>:" with the paths, as the core-applies path does.
Otherwise nothing is recorded:

- a `done` in the apply turn that names another operation: "Nothing recorded
  as applied: the turn did not report the approved operation <op>…";
- a `done` in any other turn: "Nothing was applied: this turn had no
  approved plan to apply."

`nothing_to_do` never records changed paths. A committed transaction leaves
no record under `.vault-meta/transactions`, so the plan is the trusted
source. "Finding actions" (`onJobApplied`) runs only after a verified
apply, and the `apply` progress finishes as "Applied" only then (otherwise
"Not applied").

## Labels in Review (built 2026-10-05)

Canvas: Review, ReviewStates. Code: `core/src/engine/review-labels.ts`, the
engine's "labels in Review" section.

- When a batch's plan is valid, the core reads the bundle's **source pages**:
  Markdown writes under `wiki/` with `labels_by` or `type: source`. Each
  becomes an `approval.sources` entry: page, title, `source` (`source_path`),
  labels, and `by` (`ai` = suggested, shown dashed; `user`; `none`). Concept
  and entity tags are the agent's and are not label suggestions.
- **Approving confirms the labels shown** (decision 2026-10-05). The bundle is
  never rewritten at approve time. Instead the core writes a label revision
  next to it:
  - `labels-<n>/` holds new drafts for the source pages only, with
    `labels_by: user` and no `labels_reviewed` / `labels_origin`;
  - `bundle-labels-<n>.json` is the bundle with those writes repointed and
    their `sha256` updated; everything else is copied as is.
  - The revision is inspected. Only a clean inspect replaces
    `approval.bundlePath` and `approval.plan`, so the approval hash always
    matches what Review shows. The original bundle is never modified.
  - `approval.labels.state` is `confirming` while this runs (Approve and
    edits are refused with a clear message), then `confirmed`.
  - A refused revision (for example `wiki/index.md` changed since the batch
    was built) keeps the original bundle and plan: `unconfirmed`, with a
    message saying why and that approving applies the labels as suggestions.
- `approval.unconfirmed` is the twin with labels left unconfirmed (at first
  the batch's own bundle). **Approve, review labels later** applies it.
- **Edit in Review** (`editReviewLabels`, `POST /v1/jobs/:id/labels`): a new
  revision with the edited pages' labels (confirmed), and a new twin carrying
  the same edit. A refused inspect is a `conflict`; nothing changes.
- A batch already in Review when a build with this starts (or interrupted
  while confirming) gets the same treatment at startup. One from before labels
  existed, whose text sources have no labels, gets them suggested 3 at a time
  (`labels.state` `suggesting`, `done`/`total`, per-source `state`) and then
  the confirm revision. The job stays in Review throughout.

## Approving part of a batch (built 2026-10-05)

Canvas: ReviewChoose. `approve(id, { labels?, pages? })`, `POST
/v1/jobs/:id/approve` with `{labels, pages}`.

- Sources can be **picked** (all are at first). Picking every source that is
  not removed is a normal approval.
- **Remove** (`removeReviewSource`, `POST /v1/jobs/:id/sources {page,
  removed}`) marks a source removed on the job. It is never added to the
  vault, its inbox file stays, and Undo (`removed: false`) works while the
  batch is in Review.
- A subset (or any removed source) makes the batch's **own** session
  (`job.sessionID`, never another batch's) build a new bundle,
  `bundle-part-<n>.json`, for exactly the picked sources:
  - each picked source page reused byte for byte (the prompt gives its file
    and sha256);
  - unpicked and removed sources left out;
  - bookkeeping (index, log, hot cache, overview, ledgers) and concept and
    entity pages regenerated for just those sources.
- `job.pendingPart` records what was approved. When the change comes back
  the core checks it: every picked page has the sha256 the user saw, and no
  unpicked or removed page is in it. A mismatch removes the plan and says so.
- A matching change is shown with `approval.rebuilt` and approved **once
  more**: the regenerated pages are text the user has not seen.
- After it applies, `Job.parts` gains `{operationID, pages, labels, at}` and
  the sources left are rebuilt in the same session (`rebuilt.reason
  remaining`) for a later approval. Rejecting a rebuilt change rejects the
  rest of the batch too.
- Exit 75 on a core apply of a batch with sources (not `LOCK_TIMEOUT` or
  `OPERATION_ID_REUSED`) is rebuilt the same way (`stale`).
- Only the approved plan's operation is recorded as applied, as before.

### The session seam

Every turn on a batch's AI session goes through `resumeBatchSession({ job,
prompt, extraTools?, first?, signal })`, which returns `{ kind: 'result' }`
or `{ kind: 'session_unavailable', reason }`. On the latter nothing runs, the
batch goes back to Review with `approval.sessionUnavailable`, and Approve is
refused. Detection (`sessionUnavailableReason`) and the "start a new session"
confirmation (`SessionReplaceConfirm`) belong to session-continuity.

## Core applies (label jobs, runners without tool permissions)

Some jobs have no agent that can be limited to one exact apply command (TS core):

- **Label jobs** (`labels` kind, `appliesInCore`): `confirmLabels` and
  `suggestLabelsForPages` build the bundle deterministically in the job
  directory (`core/src/labels/transaction.ts`), with the current SHA-256 of
  each page in `expected_hashes`, then run `transaction inspect` (same code
  path as above).
- **Any job whose runner lacks `toolPermissions`** (for example a
  `sandboxedWrites` runner): phase 1 is unchanged, approval is not.

On **Approve** the core runs
`python3 <core> transaction apply <bundle> --vault <vault> --approved-plan-sha256 <sha>`
itself (never an agent) and completes the job with the core's
`changed_paths` and `operation_id`. Exit 75 is any `TransactionConflict`,
so the core reads the code from `ERR <CODE>:` on stderr (decision
2026-10-04):

- `LOCK_TIMEOUT`: another process held the vault lock. Nothing changed, so
  the job goes back to awaiting approval with its plan kept, and the app turn
  says to approve again to try again.
- `OPERATION_ID_REUSED`: a label job rebuilds with a new id ("This operation
  ID was already used…"). Other jobs clear the plan, and the plan error says
  the operation may already be applied: check the vault log, then reply to
  rebuild with a new ID, or reject.
- Anything else (a page changed after review): a label job rebuilds its
  bundle from `request.json` with a **new** operation id (the core treats a
  reused id as a replay), re-inspects and asks again. Other jobs go back to
  awaiting approval with the plan cleared ("The vault changed after this
  plan was reviewed (transaction apply exited 75, <CODE>)"). Reply and Allow are
refused (`invalid_state`) for label jobs; Reject works as for ingest. Cancel
does not interrupt a running apply.

Bundle shape (page rewrites only; a frontmatter edit keeps every other byte):

```json
{
  "schema": "claude-obsidian.transaction.v1",
  "operation_id": "job-20261001-154200-ab12-1f2e3d4c",
  "operation_type": "markdown",
  "expected_hashes": { "wiki/sources/a.md": "<sha256 of the current file>" },
  "writes": [{ "path": "wiki/sources/a.md", "mode": "replace", "content": "<whole new file>" }]
}
```

## Concurrency and recovery

- A running job blocks the next batch (`batchBlocker`). Since 2026-10-05 a
  batch waiting in Review does not: several batches can wait, listed oldest
  first, and a plan that goes stale because another batch applied first is
  rebuilt in its own session (above). Label jobs still need a free vault:
  `confirmLabels` and `suggestLabelsForPages` return `busy` while another job
  holds it.
- A job found `running` at launch becomes `awaitingApproval` with a note; the
  user can reply to resume the same session. A label job interrupted while
  applying keeps its reviewed plan so it can be approved again (an operation
  that already applied replays as a no-op).
- When a new job needs approval the main window switches to Review and the
  floating icon and Dock show a count.
