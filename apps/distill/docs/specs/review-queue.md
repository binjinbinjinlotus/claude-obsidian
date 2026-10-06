---
type: spec
title: Review queue, automatic refresh, self-recovery and the batch list
status: designed
created: 2026-10-05
updated: 2026-10-05
tags:
  - distill
  - review
  - approval
---

# Review queue, automatic refresh, self-recovery and the batch list

Canvas: row 16, board **ReviewQueue** (`design/screens/reviewqueue.json`).
Related specs: [Approval and review](approval-and-review.md) (the gate, parts,
exit 75), [Session continuity](session-continuity.md), [Full reads](full-read.md),
[Live log](live-log.md), [Activity log](activity-log.md),
[Resizable panes](resizable-panes.md).

## Why

On 2026-10-05 the owner approved several Review batches at once. They share
pages: `wiki/hot.md`, `wiki/log.md`, the ledgers, and concept and entity pages.

- The first one applied.
- Every other one hit exit 75 `EXPECTED_HASH_MISMATCH` and showed "Not added to
  your vault". The refusal itself was correct and protected the vault.
- Claude rebuilt each one, and each rebuilt plan needed a fresh OK.

The owner's rule is "automatic checks over human": Distill must not depend on
the owner knowing the order.

The owner added (verbatim): "for the queued, please adding a solution of how to
do the self recovering. we default use the opus, and we should able to change
the model in the setting. the reason for that it be because, when the issue
happen it is nearly very difficult for the user to recover or fix the issue by
itself, it will keep rerun and nothing will fix".

About the batch tabs, the owner said: "it is very bad, it list out each batch
much better".

## 1. The apply queue (one apply at a time per vault)

**Approve never starts a second apply on a vault that is already applying.** It
queues instead.

### Data

The job stays `awaitingApproval`. A new field marks it as queued; there is no
new `JobState`, so older clients still decode it.

```ts
interface QueuedApply {
  at: string;              // when the owner approved (ISO)
  order: number;           // queue position key: the first approve's time in ms; a re-approval keeps it
  planSha256: string;      // approval_sha256 of the plan approved
  bundlePath: string;      // the exact bundle approved (approval.unconfirmed.bundlePath for "labels later")
  labels: 'confirm' | 'later';
  carries: 'confirm' | 'later'; // what applyingLabels gets (approval.rebuilt?.labels ?? mode)
  pages?: string[];        // a pick, when the approval was a part
}
// Job: queuedApply?: QueuedApply; refresh?: RefreshState; recovery?: RecoveryState
```

`approvedChange` is still set **when the apply starts**, not at queue time, so
`planReplaced`, `showsInReview` and the apply card mean what they mean today.

### Engine

- **`approve(id, opts)`** runs every check it runs today: plan valid, labels in,
  picks, stopped sources. A pick that needs a part rebuild (`startPart('partial')`)
  is unchanged and does not queue: it is a rebuild, not an apply.
- It then records `job.queuedApply` from the plan and bundle it resolved, and
  calls **`pumpApplies(vault)`**.
- `approve` keeps its three apply exits, moved unchanged into
  **`startApply(id, queued)`**:
  - `applyByCore`;
  - `continueInNewSession(…, 'approve', …)`;
  - `resumeBatchSession` with the one-turn apply rule.

  A refused session (`session_unavailable`) still throws to the caller. That only
  happens when the queue was empty, because the apply started inside the request.
  When it happens later, from the pump, it goes to recovery (section 3).
- **`pumpApplies(vault)`** follows `pumpRereads`: it is synchronous from the
  check to the start, one at a time per vault.
  - The vault is busy when an apply is in flight there, meaning a job in
    `running` with an active `apply` progress, or a label job applying in the
    core, or when the head is being refreshed (below).
  - When the vault is free, take the queued job with the lowest `order`.
  - **Freshness, the cheap filter:** `staleFor(job)` reads `queued.bundlePath`,
    takes `expected_hashes` (path → sha256, or `null` for a page that must not
    exist), and hashes the current files. `null` means the file is missing.
  - **Freshness, the authority:** run `transaction inspect` on the same bundle.
    - If its `approval_sha256` equals `queued.planSha256`, start the apply under
      the original approval. The gate holds trivially: the approved hash is the
      hash applied. This covers every queued batch that doesn't overlap.
    - If the filter found stale paths, or inspect returned a different hash or
      refused, the head is **approved-but-stale** (section 2, decision A).
- The pump runs:
  - after every apply ends: success, exit 75, failure or cancel, in `applyInCore`
    and in `handle` (`done` / `failed` of an apply turn);
  - after `adoptOutsideApplies` records an apply made outside Distill;
  - after a reject or a Don't-apply-yet;
  - in `start()`;
  - on every tick (cheap: nothing to do when the queue is empty).
- **Reject and Cancel** on a queued job remove `queuedApply`. Reject works as
  today; Cancel of a queued job just un-queues it.
- **Don't apply yet:** `POST /v1/jobs/:id/unqueue` removes `queuedApply`; the
  batch is back to Ready, with its plan.
- **Restart:**
  - `queuedApply` is stored on the job, so the queue survives a restart, and
    `start()` pumps it.
  - A job found `running` mid-apply at launch keeps today's handling
    (`awaitingApproval` with a note). If it still has `queuedApply` it is not
    re-queued: an operation that may have half-started is for the journal check
    (`adoptOutsideApplies`) and recovery, not a blind retry.
- **Strict order.** While the head waits for the owner (re-approval or Needs
  you), later queued batches wait too ("Queued · after Telus Daily Stand-up,
  which needs you"). Letting them pass would make the head's rebuilt plan stale
  again, and that loop is what the owner saw.
- **A re-approved head keeps its original `order`.** It goes back to the head of
  the queue, not to the tail.

### Badges and status

- `status().pendingApprovals` and every badge (sidebar, Dock, flask) count
  `awaitingApproval` jobs **without** `queuedApply` and without an active
  `refresh` or `recovery`.
- A Needs-you job counts: a rebuilt head waiting for its OK once more, or a
  recovery that gave up.
- `batchBlocker` is unchanged: queued batches never block the next batch.

## 2. Automatic refresh

After each apply, the core re-checks every **waiting** batch in that vault
against the vault (`staleFor`).

### Not yet approved and stale: rebuilt before the owner looks

- **When.** It is rebuilt only when the vault's apply queue is empty and no apply
  is in flight. A rebuild while an apply is queued would go stale again at once.
  The pump starts these rebuilds after the queue drains, one at a time per vault,
  oldest first.
- **How.**
  - With sources: today's stale part, `startPart(id, 'stale')` →
    `sendPartInBackground`, in the batch's own session.
  - Without sources (an older job, or a plan from a reply): the same request is
    sent as an app-authored reply, `staleRebuildPrompt()`. Its words are what the
    plan error asks the owner to reply today: "The vault changed after this plan
    was built (another batch applied first). Rebuild the bundle against the pages
    as they are now, run `transaction inspect`, and finish with
    `needs_approval`."
- **What it records.** `job.refresh = { since, reason: 'stale', stalePaths,
  approved: false, attempt }`, cleared when the rebuilt plan arrives.
- **In Review.** The row and the heading say **Updating…**, and Approve is
  disabled with "Updating against the latest pages". When the plan comes back,
  `checkRebuiltPart` has already proven the source pages byte-identical, and the
  batch reads **Ready**.

### Approved (queued) and stale: decision A, rebuild and ask once more

The head of the queue is stale:

1. The head is rebuilt the same way, at once. The queue is held for it, so
   nothing can make it stale again. It records `job.refresh = { …, approved:
   true }`, and the row says **Updating…**.
2. The rebuilt plan comes back. `checkRebuiltPart` proves the source pages are
   the bytes the owner approved.
3. The core computes **`approval.sinceApproved`** by comparing the approved
   bundle with the rebuilt one, path by path with `pageShas`:
   - `sources: 'same'`: always true after `checkRebuiltPart`;
   - `content`: concept, entity and other `wiki/**` pages whose bytes differ, with
     added and dropped pages;
   - `bookkeeping`: `wiki/hot.md`, `wiki/log.md`, `wiki/index.md`,
     `wiki/overview.md` and `wiki/meta/ledgers/*`, listed as written again.
4. The batch shows **Needs you · approve the rebuilt plan**. It keeps its
   `queuedApply.order` but drops `planSha256`; the new approval sets it again. It
   carries a **What changed since you approved** card:
   - "Your 3 source pages: unchanged";
   - "2 concept pages differ: Retry policy, Auth" (each opens a diff of approved
     against rebuilt);
   - "Bookkeeping written again: log, hot cache, index, 2 ledgers".
5. One click on **Approve rebuilt plan** re-queues it at its old position. It is
   the head, so it starts at once, and nothing else applied in between.

**Why A, not B (carry the approval over).** The gate in
[Approval and review](approval-and-review.md) is that the approved hash equals
the applied hash. B can't keep it:

- **`approval_sha256` binds bytes.** `plan_approval_sha256`
  (`claude_obsidian/transaction.py`) hashes the expanded bundle and every
  prepared write's bytes and file modes, together with the vault identity.
  Writes are `create` or `replace` with whole content. Any regenerated byte in
  `hot.md` or `log.md` gives a new hash, so B would apply a hash the owner never
  approved, by construction.
- **Making B sound needs a transaction format change**, outside Distill. The
  bundle would carry bookkeeping as approved deltas (a log entry to prepend,
  index lines, ledger records), and the Python core would render them onto the
  current file at apply time, with the approval hash binding the deltas and not
  the result. That touches the repository's mutation protocol (`AGENTS.md`:
  `claude-obsidian.transaction.v1`), its ledger validation, and every skill that
  writes bookkeeping.
- **`hot.md` is not a mechanical merge.** It is bounded recent context, rewritten
  as a whole by the AI. Regenerating it is a content decision, so the condition
  "no new content decisions" fails for it.
- **The stale rebuild rewrites concept and entity pages.** `partPrompt` tells the
  session to write them again for the vault as it is now, and two batches that
  touch the same concept page produce new prose. Those pages must be seen.

**What this does and doesn't fix (honest).** Every batch writes `hot.md` and
`log.md`, so nearly every queued batch after the first is stale and needs **one
more OK**.

What the queue removes:

- order-dependence;
- the "Not added" failure cards;
- the owner having to reply "rebuild";
- applies racing each other.

The extra OK is made cheap: one click, with the What changed card showing that
the sources are untouched. B stays on record as a deferred option that needs the
owner's call and a transaction v2 (`decisions.md`, 2026-10-05).

### Exit 75 in Review

An apply that ends in exit 75 with a code other than `LOCK_TIMEOUT` or
`OPERATION_ID_REUSED` (for example `EXPECTED_HASH_MISMATCH`) is **never** shown
as a failure.

- The apply card's heading is **Updating against the latest pages**, the
  timeline's failed step turns blue (running), and the hint is "Another batch
  changed the same pages first. This batch's session is rebuilding the plan
  against the pages as they are now." Then the batch reads Ready, or Needs you
  if it had been approved.
- Mac: `ApplyTimeline.make` reads `job.refresh`. `isFailed` is false while
  `refresh` is set. `heading` returns "Updating against the latest pages", and
  the stage is `.applying` with state "running".
- The agent path: when Claude's apply turn reports exit 75 (`failed`, or
  `needs_input`, with the conflict in the summary or the denials), the core
  routes it to the same refresh, not to `requestDecision`'s question. The core's
  own signal is a re-check: `staleFor(job)` returning paths after an apply turn
  that did not record the operation.

## 3. Self-recovery

A batch that can't make progress on its own gets a bounded, visible recovery
step, so the owner is not left re-running something that never fixes itself.

### When it runs

The triggers, by **failure signature** (`kind` plus a short key):

| Signature | Today |
| --- | --- |
| `stale-again`: exit 75 after a refresh rebuild, or a refresh rebuild whose plan is stale on arrival | loops |
| `lock`: `LOCK_TIMEOUT` | "approve again" |
| `plan-error`: rebuilt part mismatch, bundle outside the job dir, no `bundle_path`, inspect refused | "Reply to Claude to try again" |
| `not-recorded`: an apply turn that came back without the approved operation | "Check the vault log" |
| `full-read-stop`: a source couldn't be read in full | can't be approved |
| `session-gone` during a queued or background step | SessionReplaceConfirm |
| `runner-failed`: the runner failed or the core stopped mid-apply | failed |

### Rules first, then the agent

Deterministic rules come first, with no AI. They are cheap, immediate, and
verifiable.

| Signature | Rule | Verified by |
| --- | --- | --- |
| `lock` | wait 30 s, then 2 min; re-inspect the same bundle; if the hash is unchanged, apply under the same approval | inspect `approval_sha256` = approved |
| first stale | the automatic refresh (section 2) | `checkRebuiltPart` |
| `not-recorded` | check the vault journal (`adoptOutsideApplies`); if `complete` with the approved hash, record it as applied | journal |
| `session-gone` | none: session continuity asks first (owner decision, row 10). Needs you with SessionReplaceConfirm, pre-selected | owner |
| `full-read-stop` | none: excluding sources changes what is approved; the v10 path offers it | owner |

**The recovery agent** runs when no rule applies, or when a rule already failed
once for the same signature.

### The recovery agent

- **Task `recovery`.**
  - `AITask` adds `'recovery'`, and `TASK_REQUIREMENTS.recovery =
    [['structuredOutput']]`.
  - `defaultSelection(s, 'recovery') = { runnerID: DEFAULT_RUNNER_ID, model:
    'opus', effort: 'medium' }`, mirrored by Swift `SettingsEdits.fallbackSelection`.
  - The owner changes it in **Settings → AI models → Recovery**, with the same
    runner, model and effort picker as the other task rows (`taskDefaults.recovery`).
- **How it runs.** It makes one structured-output call, following
  `actions/ai.ts`:
  - no tools, no session, no vault access;
  - it never writes anything;
  - the core builds the facts and executes the chosen fix.
- **Facts** (`recoveryFacts(job)`, capped at about 24k characters):
  - the job's last 12 turns, each cut to 1,500 characters;
  - the live-log steps of the failing attempt;
  - the failing step, with its code and the first 20 stderr lines;
  - the stale paths, each with its expected and current sha256;
  - other jobs (queued, running or in Review) whose bundles touch the same
    paths, with their states;
  - the vault journal state for the job's operation ids
    (`.vault-meta/transactions/<op>/journal.json`);
  - earlier recovery attempts and their results.
- **Answer schema:**

  ```json
  { "diagnosis": "≤ 400 chars, plain words for the owner",
    "fix": "rebuild_in_session | reinspect_same_bundle | wait_then_retry | split_batch | discard_stale_part | new_session | give_up",
    "reason": "≤ 300 chars",
    "waitFor": "job id (wait_then_retry)",
    "groups": [["wiki/sources/a.md"]] }
  ```

  `groups` is for `split_batch`.
- **What the core does with each fix** (the core validates it first; an invalid
  answer counts as a failed attempt):

  | Fix | Core action | Gate |
  | --- | --- | --- |
  | `rebuild_in_session` | the stale part request in the batch's session | new plan → owner's OK |
  | `reinspect_same_bundle` | inspect again; same hash → re-queue under the same approval | approved = applied |
  | `wait_then_retry` | `waitFor` must exist and touch the same paths; retry after it ends | as the retried step |
  | `split_batch` | `groups` must split the active sources; one part is rebuilt, the rest wait (`startPart('partial')`) | new plan → owner's OK |
  | `discard_stale_part` | today's discard of a rebuilt part (`reject(id)`) | nothing applied |
  | `new_session` | **proposal only**: Needs you with SessionReplaceConfirm, "Recovery suggests a new session" | owner |
  | `give_up` | the Couldn't fix state | owner |

- **The gate stays.**
  - Recovery never applies anything itself.
  - A new plan always needs the owner's OK.
  - The only continuation without the owner is `reinspect_same_bundle` or the
    `lock` rule, where inspect proves the approval hash unchanged.
  - It never carries an approval over to different bytes.

### Bounds

- **Attempts.** At most **2** per batch per signature (`settings.recovery.maxAttempts`,
  1–5). The backoff is 1 min before the second attempt; the `lock` rule waits
  30 s and then 2 min.
- **Persisted.** `job.recovery = { state: 'running' | 'waiting' | 'gaveUp' |
  'fixed', signature, attempts: [{ at, by: 'rule' | 'agent', runnerID?, model?,
  fix, diagnosis?, result: 'fixed' | 'failed' | 'running', error?, costUSD }] }`.
  It survives a restart, and `start()` resumes a `waiting` attempt when its time
  has come.
- **No loop.**
  - Recovery never triggers recovery: a failure inside an attempt ends that
    attempt as failed.
  - A refresh rebuild that goes stale again counts toward `stale-again`.
  - Attempts reset only when the owner acts: Approve, Reply, Try recovery again,
    Reject.
- **Cost cap.** **$1.00 per batch** by default (`settings.recovery.maxCostUSD`).
  - Each agent attempt adds `RunResult.costUSD`.
  - Before an agent call, the core checks the sum; at or above the cap it goes
    straight to Couldn't fix ("Stopped at the $1.00 recovery limit").
  - Runners that accept a budget get the remaining amount.
  - Rule attempts cost $0.
- **Automatic or a button: automatic.** The owner's rule is automatic checks over
  human, and the bounds above keep it from looping or spending. **Try recovery
  again** exists only in the Couldn't fix state, and it resets the attempts once.
  Settings → Recovery has "Recover automatically" (on) for an owner who wants it
  manual.

### The "I couldn't fix this" state

`recovery.state = 'gaveUp'`, which counts as Needs you. Review shows a peach
card with:

- **What's wrong**, in plain words: the agent's last diagnosis, or the rule's
  ("Another app kept your vault locked for 3 minutes").
- **What was tried**: each attempt with its fix, its result and its cost.
- **Options**, the ones that apply:
  - **Rebuild against the latest pages**;
  - **Continue in a new session** (SessionReplaceConfirm);
  - **Open in Terminal** (the existing resume command);
  - **Try recovery again**;
  - **Reject batch**.

### Visible

- **Live log.** One step per attempt: `recover-<n>` "Recovering · Opus ·
  rebuilding against the latest pages", running and then done or failed. The
  detail holds the diagnosis and the cost. A rule step reads "Recovering · waiting
  for the vault lock (30 s)".
- **Review.** A blue notice on the batch with the same words, plus the attempt
  rows. The batch row's state reads **Recovering**.
- **Activity.** `batch.recovery` entries: `{ job, attempt, signature, by,
  model, fix, result, costUSD }`, with the actor `scheduler`, or `app` for Try
  again.
- **Cost.** Shown on each attempt row and summed on the Couldn't fix card.

## 4. The batch list (Review)

The horizontal pills (`JobTabs`, `MainView.swift`) are replaced by a **left
column** in Review: `ReviewBatchList`.

- **When.** It is shown when Review has two or more batches; one batch shows no
  column, as today.
- **Width.** `.paneWidth(.reviewList, automatic: 260)`, with a range of 220–380,
  and a new `PaneSpec.reviewList` in `PaneSplit.fixedKeys`.
- **The Conversation column.** JobDetailView's narrow rule measures its own
  width, so the list makes the Conversation fold behind **Conversation · N**
  sooner: below a window of about 1,300 pt with the list shown. The table row in
  `resizable-panes.md` is updated when built.
- **Each row:**
  - **Name.** `ReviewBatches.readableName(job)` in DistillKit; rules below.
  - **Date.** The batch's date as "Oct 5": the date found in the first source's
    name, otherwise `createdAt`.
  - **Sources.** "3 sources", or "14 left" after a part applied.
  - **State.** One pill: **Ready** (peach), **Updating…** (blue, spinner),
    **Queued · 2nd** (grey), **Applying** (blue), **Added** (green), **Needs you**
    (peach, bold), **Recovering** (blue), **Couldn't fix** (peach). It comes from
    `ReviewBatches.rowState(job)`, using the same facts as ApplyTimeline.
- **Order.** Oldest first, by the batch's `createdAt`, for every state. Rows
  never jump when the state changes, and the apply order is the same order.
  The waiting-first split in `ApplyTimeline.reviewList` becomes a single
  oldest-first sort.
- **Selection** stays as today:
  - the selected id is kept;
  - when the selected batch leaves (Done or Reject), the **next** row is selected,
    or the previous one at the end.
- **Keyboard.** ↑/↓ moves the selection when Review has focus and no text field
  is editing (`onMoveCommand` on the list).
- **Footer.**
  - When another apply is in flight on the vault, Approve's label says
    **Approve · applies after Product sync**.
  - A queued batch's footer shows **Don't apply yet** and Reject.

### Readable names (`ReviewBatches.readableName`)

Applied to the first source's file name, before the old `pretty()` step that
turns `-` into spaces:

1. Drop the extension.
2. Remove "Notes by Gemini" and "Transcript", in any case.
3. Remove dates: `YYYY[-_ /.]MM[-_ /.]DD`, and `MM/DD/YYYY` written with `_`.
4. Remove times: `HH[:_.-]MM`, optionally `:SS`, optionally ` AM|PM`.
5. Remove time zones: a token of 2–5 capital letters from a list (`IST PST PDT
   EST EDT CST CDT MST MDT UTC GMT CET CEST BST JST AEST AEDT SGT HKT`), or
   `GMT±hh(:mm)`.
6. Collapse the separators left over (` - `, `_`, runs of spaces and dashes) and
   trim the punctuation at the ends.
7. A **slugged** name (no spaces originally) has its dashes turned into spaces,
   then a short list of words gets its hyphen back: `stand up` → `Stand-up`,
   `check in`, `follow up`, `kick off`, `sync up`, `one on one`. A name with
   spaces keeps its in-word hyphens.
8. Capitalise the first letter. When nothing is left, fall back to today's
   `displayTitle`.
9. Add `+N` for the other sources (a folder counts once).

Cases for the unit tests (`ReviewLogicTests`):

| File | Name |
| --- | --- |
| `2026-10-05 Telus Daily Stand-up - 2026_10_05 19_00 IST - Notes by Gemini.gdoc` (+2) | Telus Daily Stand-up +2 |
| `2026-10-05-Telus-Daily-Stand-up-2026-10-05-19-00-IST-Notes-by-Gemini` | Telus Daily Stand-up |
| `Product sync - 2026_10_04 09_30 PDT - Notes by Gemini.gdoc` | Product sync |
| `Weekly sync – 2026-10-03 14.00 GMT+5:30.md` | Weekly sync |
| `2026-10-05.md` | 2026 10 05 (fallback) |
| `tea-club-notes.md` | Tea club notes |

## Build plan

### Core (`core/src`)

- **`contracts.ts`:**
  - `AITask` gains `'recovery'`, and `TASK_REQUIREMENTS.recovery`;
  - new types `QueuedApply`, `RefreshState`, `RecoveryState`, `RecoveryAttempt`,
    `SinceApproved`;
  - `Job.queuedApply?`, `Job.refresh?`, `Job.recovery?`,
    `ApprovalRequest.sinceApproved?`;
  - `Settings.recovery?: { automatic, maxAttempts, maxCostUSD }`;
  - `Progress.kind` gains `'recovery'`.
- **`store/settings.ts`:**
  - `defaultSelection` for `recovery` is Opus, effort medium;
  - decode and encode `recovery` leniently (additive);
  - `recoveryPreferences(s)` returns the defaults: `{ automatic: true,
    maxAttempts: 2, maxCostUSD: 1 }`.
- **`store/jobs.ts` (`encodeJob`/decode):** the three new job fields, each lenient.
- **New `engine/apply-queue.ts`:**
  - `staleFor(vaultPath, bundlePath)`, which returns `{ path, expected, current }[]`;
  - `sinceApproved(approvedBundle, rebuiltBundle)`;
  - `isBookkeeping(path)`;
  - `queueOrder(jobs, vault)`.

  All of them are pure, apart from file reads.
- **New `engine/recovery.ts`:**
  - `recoveryFacts(job, ctx)`;
  - `RECOVERY_SCHEMA`;
  - `parseRecoveryAnswer`;
  - `validateFix(answer, job, jobs)`;
  - `ruleFor(signature, attempts)`.

  It runs `runRecovery(selection, facts)` through `runners.get(...).run`, with
  structured output and no tools.
- **`engine/index.ts`:**
  - `approve` records `queuedApply` and calls `pumpApplies`. Its three exits move
    into `startApply(id, queued)`, which sets `approvedChange` and clears
    `queuedApply`.
  - New `pumpApplies(vault)` and `refreshWaiting(vault)`, the latter after an
    apply, only when the queue is empty.
  - New `unqueue(id)`.
  - `applyInCore` exit 75: the stale branch goes to `refresh` (with sources:
    `startPart('stale')` as today; without sources: `staleRebuildPrompt`), never
    the "plan cleared" error. `LOCK_TIMEOUT` goes to the `lock` rule.
  - `handle`: an apply turn that did not record the operation, and where
    `staleFor` finds paths, goes to refresh; otherwise `not-recorded` goes to
    recovery.
  - `checkRebuiltPart` sets `sinceApproved` when the job had `queuedApply`.
  - `requestDecision` clears `refresh`.
  - New `recover(id, signature)` and `tryRecoveryAgain(id)`.
  - `status().pendingApprovals` excludes queued, refreshing and recovering jobs.
  - `start()` pumps applies and resumes recovery waits.
  - `reject` and `cancel` clear `queuedApply`.
  - The pump is called from `adoptOutsideApplies` and `tick`.
- **`steps/index.ts` and `steps/words.ts`:**
  - `recover-<n>` steps with the words above;
  - a `queued` step "Queued · applies after X";
  - an `updating` step "Updating against the latest pages".
- **`activity`:** `batch.recovery`, `batch.queued` and `batch.unqueued` entries
  (logged in `activity/instrument.ts`).
- **`engine/job-kinds.ts`:** `staleRebuildPrompt()`.

### API (`core/src/server`) and CLI

- `POST /v1/jobs/:id/approve` is unchanged in shape; the job it returns may carry
  `queuedApply`.
- `POST /v1/jobs/:id/unqueue`.
- `POST /v1/jobs/:id/recover` (Try recovery again).
- The settings PUT accepts `recovery` and `taskDefaults.recovery`.
- CLI: `distill status` lists queued and recovering batches. The CLI never
  approves, as before.

### Mac (`clients/macos`)

- **`DistillKit/Models.swift`:**
  - `AITask.recovery`;
  - `QueuedApply`, `RefreshState`, `RecoveryState`, `RecoveryAttempt`,
    `SinceApproved`, each lenient;
  - `Job` fields;
  - `RecoveryPreferences` in settings.
- **`DistillKit/ReviewLogic.swift`:** in `ReviewBatches`, `readableName`,
  `batchDate`, `rowState` (enum `ReviewRowState`), `ordered` (createdAt only),
  `nextSelection(after:in:)`.
- **`DistillKit/ApplyTimeline.swift`:**
  - `reviewList` becomes one oldest-first list;
  - `make` reads `refresh`, giving "Updating against the latest pages" and not
    failed;
  - `tabSubtitle` is replaced by `rowState`.
- **`DistillKit/CoreClient.swift`:** `unqueue(id)` and `recover(id)`.
- **`Distill/MainView.swift`:**
  - `ReviewSection` lays out `ReviewBatchList | JobDetailView` with
    `.paneWidth(.reviewList, automatic: 260)`;
  - `JobTabs` is removed;
  - `displayTitle` uses `readableName`.
- **New `Distill/ReviewBatchList.swift`:** `ReviewBatchList` and `ReviewBatchRow`,
  with `onMoveCommand` for ↑/↓.
- **`Distill/JobReview.swift`:**
  - the footer: Approve label "Approve · applies after X", Don't apply yet, and
    "Approve rebuilt plan";
  - `SinceApprovedCard`, `RecoveryNotice` and `RecoveryGaveUpCard`.
- **`Distill/ApplyProgress.swift`:** the Updating state (a blue running step) and
  the recovery attempt rows.
- **`Distill/PaneSplit.swift`:** `PaneSpec.reviewList` (220–380), added to
  `fixedKeys`.
- **Settings:**
  - `SettingsModels.swift` and `SettingsEdits.swift` get a Recovery row in AI
    models, with `fallbackSelection(.recovery)` = Claude Code · Opus · medium;
  - a Recovery group: Recover automatically, attempts, cost limit.
- **`AppModel`:** the badges exclude queued, refreshing and recovering jobs (the
  same rule as the core).
- **Snapshot states:** `review-list`, `review-queued`, `review-updating`,
  `review-reapprove`, `review-recovering` and `review-gaveup`, matching the board.

### Tests (fake runner)

**Core**, in `core/src/engine/apply-queue.test.ts` and
`core/src/engine/recovery.test.ts`. They use the real Python core, a temp vault
and `FakeRunner`, as `review-labels.test.ts` does, with a temp
`DISTILL_STATE_DIR`.

1. Two batches share `wiki/log.md`. Approve both while the first's apply is held
   (a fake `launch` that waits):
   - the second gets `queuedApply` and does not start;
   - after the first applies, the second's inspect hash differs, and it is
     rebuilt by the fake runner's scripted `needs_approval`;
   - it shows `sinceApproved.sources = 'same'` and Needs you;
   - re-approve: it applies, and `order` is kept.
2. Two batches that don't overlap: the second applies under its original
   approval (inspect hash equal), with no re-ask.
3. An unapproved stale batch is rebuilt only after the queue drains; `refresh`
   is set while the rebuild runs, and `pendingApprovals` excludes it.
4. Core apply exit 75 `EXPECTED_HASH_MISMATCH` → refresh, never `planError`.
   `LOCK_TIMEOUT` → the lock rule retries; a fake clock advances 30 s.
5. Restart with a queued job: `start()` pumps it.
6. Reject or unqueue removes it from the queue.
7. Recovery agent: a `FakeRunner` with `structuredOutput` returns each fix.
   - The core validates it: a bad `waitFor` or bad `groups` is a failed attempt.
   - The core executes it.
   - `new_session` never runs a session; it sets the marker.
   - `give_up` → gaveUp.
8. Bounds:
   - two failed attempts → gaveUp, and a third failure never calls the runner;
   - a cost cap with `costUSD: 0.6` per attempt stops before the second call;
   - a stale-again loop ends at 2;
   - attempts reset on Approve.
9. The recovery selection defaults to Opus; `taskDefaults.recovery` overrides it.
10. Swift parity (`swift-parity.test.ts`): `AI_TASKS` includes `recovery`.

**Mac** (`DistillKitTests`):

- `ReviewLogicTests`:
  - the `readableName` cases above;
  - `rowState` for every state;
  - oldest-first order;
  - `nextSelection`.
- `ApplyTimelineTests`: a job with `refresh` is not failed and has heading
  "Updating against the latest pages".
- `ModelsTests`: lenient decode of the new fields; old jobs without them decode.
- `SettingsEditsTests`: the Recovery fallback is Opus.
- The snapshot states render; the design drift test passes.
