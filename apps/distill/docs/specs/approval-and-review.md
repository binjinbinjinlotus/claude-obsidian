---
title: Approval and review
status: built
updated: 2026-10-05
---

# Approval and review

Nothing reaches the vault without the user's decision. Code: the TS core,
`core/src/engine/index.ts` (approve, reply, allow, reject, inspect),
`core/src/engine/job-kinds.ts` (`WorkerProtocol`, `JobContext.planningTools`),
`core/src/engine/review-labels.ts` and `core/src/runners/permissions.ts`. UI
in `clients/macos/Sources/Distill/MainView.swift` (`ReviewSection`,
`JobDetailView`), `JobReview.swift`, `ReviewRows.swift`, and the logic in
`DistillKit/ReviewLogic.swift`.

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

On `needs_approval` the core checks that `bundle_path` lies inside the job's
own directory (otherwise the plan error says it refused to inspect it), then
runs `transaction inspect` itself. The screen shows the core's plan
(`changed_paths`, `approval_sha256`), not Claude's description of it. A
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
- **Reject**: ends the job. Inbox files are kept. On a rebuilt part the app
  shows **Discard this part** and **Reject batch** instead (see "Approving
  part of a batch").

Approve, Reply and Allow resume the batch's AI session. When that session is
gone, nothing is sent: the app asks before a new one is used
([Session continuity](session-continuity.md), "The session seam" below).

**In the Mac app since 2026-10-05** (canvas Review, ReviewStates,
ReviewChoose):

- Several batches can wait; Review lists them oldest first as tabs, each
  with "N sources" or, after a part applied, "N left"
  (`ReviewBatches`).
- The change is shown in folding groups: **New pages** (open), **Updated**
  (folded; its summary names the pages, plus the bookkeeping files) and
  **Sources** (each source with its page and its labels; folded past 6 rows,
  showing the most used labels).
- With more than one source in a pending batch, each source has a pick box
  and the header says "8 of 22 picked · 1 removed", with Pick all / Pick
  none. The Approve button reads "Approve & apply" with everything picked,
  "Approve N sources" for a subset, and "Approve the rebuilt change" on a
  rebuilt part. It is off with "Pick at least one source", while labels are
  being suggested ("Approve when the labels are in") or saved.
- The chevron next to Approve offers **Approve, review labels later** when
  the core prepared the unconfirmed twin or a subset is picked. Otherwise
  the footer says "Approving also confirms the labels shown".
- A source row has **Open page**, **Remove** (Undo while in Review) and an
  editable label line; Done sends `POST /v1/jobs/:id/labels`.
- A batch left without a plan (`approval.needsRebuild`) shows **Rebuild N
  sources**; while a part is rebuilt, "Rebuilding with <model>…".
- History shows "Applied in parts", one line per part ("8 sources at 11:52
  PM · <operation> · labels left to review").

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
keep Approve and Reject disabled meanwhile. Since 2026-10-05 the live log
shows the steps after Approve (see "After you approve").

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

## After you approve (built 2026-10-05)

The owner: "update the review, so I can see the progress after I approved:
when the AI is starting the process, when all the approved files are added to
my knowledgebase". Canvas: ReviewProgress, ApplyProgress. Code: core
`approvedChangeOf`, `finishReview` (engine), the apply steps in
`core/src/steps/index.ts`; Mac `DistillKit/ApplyTimeline.swift`,
`Distill/ApplyProgress.swift`.

- **Review keeps an approved batch** (kind `ingest`; label jobs leave as
  before) until the user presses **Done**
  (`finishReview`, `POST /v1/jobs/:id/done` → `job.reviewDoneAt`). It is in
  History → Jobs as before. Review lists the batches waiting for the user
  first (oldest first), then the approved ones; their tabs say "adding…",
  "added" or "not added". They never count as needing the user: the sidebar,
  Dock and flask badges count `awaitingApproval` only, and an applied batch
  never blocks the next one (`batchBlocker` looks at `running` only). A reply
  after an approval (or a job approved by an older core, with no
  `approvedChange`) is not shown this way.
- **What was approved** is recorded when Approve starts the apply (all three
  paths: agent, core, new session): `job.approvedChange = {at, operationID,
  changes, sources, concepts, entities, otherPages, updated,
  sourcesApproved}`. The counts come from the inspected plan and the vault
  before the apply: a `wiki/**.md` path that doesn't exist yet is new
  (by folder), one that exists is updated. Never from the model. A session
  that turns out gone puts the job back without it (snapshot).
- **The steps** are the batch's live-log steps (no new plumbing): `You
  approved · 22 sources` (the review step), then `start-k` "Claude is
  starting: resuming this batch's session" (agent runs only), `apply-k`
  "Applying 31 changes through the vault core" (waiting until the AI runs the
  `transaction apply` command, then running), `added-k` "Added to Research:
  22 source pages, 3 concepts, 1 entity added · 6 pages updated" with the
  operation id on the apply step, and `actions` (Finding actions).
- **Failures** turn the step peach with a `hint` (what to do), in the words
  Review already uses:
  - the session is gone when the AI starts: "This batch's AI session isn't
    available anymore" and SessionReplaceConfirm, as before Approve;
  - exit 75: "Not added: the vault changed after you reviewed this batch" —
    rebuilt in the batch's own session, then back for the user's OK;
  - `LOCK_TIMEOUT`: "Not added: another app was changing your vault" —
    approve again;
  - `OPERATION_ID_REUSED`: "this change's operation ID was already used";
  - the turn reported another operation: "Nothing recorded as applied:
    Claude didn't report the approved change";
  - the runner failed or was cancelled, or the core stopped mid-apply.
  Finding actions failing is a quiet follow-up: the batch is still added.
- **Review's card** (ApplyProgress) shows the five steps live, with Show
  steps for the whole log. While it runs Approve, Reject and Cancel are gone
  ("Adding to Research · you can leave this screen"). Once everything is done
  the card folds to one line, new pages show **Open**, and the footer has
  **Clean up inbox · N files** ([Clean up inbox](inbox-cleanup.md)) and
  **Done**. A part of a batch says "Part 2 · 8 sources".
- A core apply (labels, runners without tool permissions) has no AI step.

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
  - For a batch already in Review when the core starts, the twin is the
    batch's own bundle **inspected again** at startup, so its approval hash is
    fresh. When labels were suggested at startup (a batch from before labels),
    it is a `suggest` revision of that bundle: those labels written as the
    AI's (`labels_by: ai`, `labels_reviewed: false`). Approve is refused while
    this runs. A twin the core refuses is dropped; Review then offers only
    Approve.
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
  remaining`) for a later approval.
- **Rejecting a rebuilt part discards only that part** (`reject(id)`, the
  default; `POST /v1/jobs/:id/reject`). Nothing is applied and its sources
  stay in the batch:
  - picked sources (`partial`): the Review from before the pick comes back
    (`pendingPart.before`), with every source pending, its labels as shown and
    the same plan;
  - what is left after a part applied (`remaining`) or a change rebuilt after
    the vault changed (`stale`): the sources stay in Review without a plan
    (`approval.needsRebuild`). Approve sends the same request to the batch's
    session again, to a new `bundle-part-<n>.json`, and the result is checked
    as before.
  - Only **Reject batch** (`reject(id, { scope: 'batch' })`, body `{"scope":
    "batch"}`) rejects the whole batch. Parts already applied stay applied.
    The app shows "Discard this part" and "Reject batch" on a rebuilt part.
- Exit 75 on a core apply of a batch with sources (not `LOCK_TIMEOUT` or
  `OPERATION_ID_REUSED`) is rebuilt the same way (`stale`).
- Only the approved plan's operation is recorded as applied, as before.

### The session seam

Every resume of a batch's AI session goes through session-continuity's
`resumeBatchSession({ job, prompt, extraTools?, applyPlan?, action, snapshot?,
text?, rules?, labels?, pages? })` ([Session continuity](session-continuity.md)):
approve, approve-later (the unconfirmed bundle), the rebuild of a picked part,
the apply of a rebuilt part, and a retry after a discarded rebuild. `snapshot`
is the job before the user turn or progress, so Cancel leaves it unchanged.
`labels`/`pages` are the approve options to send again: Continue
(`approve(id, { newSession: true, … })`) applies the same plan and bundle, and
rebuilds the same sources for a part. A part's rebuild the core starts itself
leaves its sources in Review with `approval.needsRebuild` when the session is
gone, with the job marker for the confirmation.

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

## After a failed apply: the conversation and Terminal (2026-10-05)

An approved apply can fail, for example on exit 75 when another batch changed
the same pages first. There are two ways to recover, and Review keeps the status
correct for both.

- **Rebuilt in the conversation.** Each approval records its plan's
  `approval_sha256` (`ApprovedChange.approvalSha256`). Review may later show a
  plan with a different hash: Claude rebuilt it after exit 75, or rebuilt it
  after a reply. In that case the old "Not added to your vault" card is history
  and is hidden, and the batch reads as ready to approve.
  - Older jobs have no stored hash. For them the "Approved <op> (<first
    12>…)" turn gives the approved hash.
- **Applied in Terminal.** The core checks each batch in Review, at start and on
  every tick, against the vault's journal,
  `.vault-meta/transactions/<op>/journal.json`. When the journal says `state:
  complete` with the same `approval_sha256` as the batch's plan, the batch is
  recorded as applied, exactly as an approved apply in the app:
  - its operation;
  - its changed paths, taken from the journal (`changed-paths.json`);
  - its parts, its full-read coverage, and the actions found;
  - an app turn: "Applied <op> outside Distill".

  `ApprovedChange.appliedOutside` marks it. The apply card then shows it added,
  even though an earlier attempt failed.
- **Send reply and Approve** are no longer left disabled after an apply came
  back to Review: the app clears its "applying" mark as soon as Claude answers.
  A reply stays in its box until the core takes it.

