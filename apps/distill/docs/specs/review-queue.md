---
type: spec
title: Review queue, automatic refresh, self-recovery and the batch list
status: built
created: 2026-10-05
updated: 2026-10-08
tags:
  - distill
  - review
  - approval
---

# Review queue, automatic refresh, self-recovery and the batch list

Canvas: row 16, board **ReviewQueue** (`design/screens/reviewqueue.json`).

**Build status (2026-10-06): built**, in six steps; see "Built so far" at the end for what differs from the design.

1. Blocked commands answered by Distill, and the plain-words card: **built**.
2. Apply queue: **built**.
3. Exit 75 → refresh: **built** (with step 2).
4. Batch list: **built**.
5. Recovery agent (Opus) and Settings: **built** (for blocked commands; see below).
6. Recovery for other problems, its card, Continue in a new session, `distill status`, the
   stale check in Approve: **built** (2026-10-06; see below).
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
  planSha256?: string;     // approval_sha256 of the plan approved. Present = waiting to apply;
                           // absent = rebuilt, needs the owner's OK again (keeps `order`)
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
  - When the vault is free, take the queued job with the lowest `order`. A head
    without `planSha256` needs the owner. It is never started, and it blocks the
    rest (strict order, below).
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
    (`awaitingApproval` with a note). `startApply` already cleared its
    `queuedApply`, so it is not re-queued: an operation that may have
    half-started is for the journal check (`adoptOutsideApplies`) and recovery,
    not a blind retry.
- **Strict order.** While the head waits for the owner (re-approval or Needs
  you), later queued batches wait too ("Queued · after Telus Daily Stand-up,
  which needs you"). Letting them pass would make the head's rebuilt plan stale
  again, and that loop is what the owner saw.
- **A re-approved head keeps its original `order`.** It goes back to the head of
  the queue, not to the tail.

### Badges and status

- `status().pendingApprovals` and every badge (sidebar, Dock, flask) count
  `awaitingApproval` jobs, except those with `queuedApply.planSha256` set
  (waiting to apply) and those with an active `refresh` or `recovery`.
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
   bundle with the rebuilt one, path by path with `pageShas`. The call is
   `sinceApproved(queuedApply.bundlePath, request.bundlePath)` in
   `checkRebuiltPart`. `sendPartInBackground` replaces `job.approval`, so the
   approved bundle survives only in `queuedApply.bundlePath`. The comparison
   gives:
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
| `denial`: a turn ended with blocked tool calls (`approval.denials`) and no valid plan | the "Claude asked to run" card, which shows raw shell |

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
| `denial` | auto-answer the session (below), at most 2 per batch | the next turn has no new denial for the same command |

**The recovery agent** runs when no rule applies, or when a rule already failed
once for the same signature.

**A missing vault core is never recovery's (2026-10-08).** When the core script
`<productRoot>/scripts/claude-obsidian.py` is gone (a deleted checkout or
worktree), every check fails before it reaches the bundle, so no rule turn or
agent can help. Before any rule turn or agent call (`recover`,
`recoverAfterRule`, `recoverDenial`, and the agent call itself, which wakes and
restarts reach directly) the core first heals the product root when it can
(app-shell.md), then checks the script. Still missing: the batch stops at $0
with no attempt, state `gaveUp`, and the sentence "Distill can't find its vault
core at `<path>`. Rebuild or reinstall Distill from a claude-obsidian checkout
that still exists." It names the path, unlike other recovery sentences: the fix
is the owner's and the path says which checkout was lost. Try recovery again
answers with the same sentence and sends nothing. Setup also lists it as
`missingCore`, which blocks new batches.

Approved batches (round 2, 2026-10-08): with the core missing, Approve sends no
apply turn, and the apply queue neither inspects, rebuilds nor applies. The
batch stays approved and queued under its hash, with one turn "Not applied yet:
<the sentence>"; the queue applies it by itself once the core is back (inspect
proves the hash first). Approving a picked subset or a rebuilt part answers
with the sentence and changes nothing. In the queue, an inspect error that
isn't a changed vault (no changed paths, not the core's exit 75) goes back to
the owner at $0 ("the vault core couldn't check this plan, and your vault
hasn't changed under it") instead of a paid rebuild. When the failed
inspect heals the product root to another checkout, the queue inspects once
more with that one before deciding (2026-10-09).

Live log: a tool call that returned an error ends `failed`; an apply or check
step then reads "Couldn't apply the approved changes" / "Couldn't check the
plan with the vault core", never the past tense.

### Blocked tool commands never reach the owner as raw shell

On 2026-10-05 the owner got a Review card, "Claude asked to run", with
`Bash: diff <(python3 -c "import json;d=json.load(open('…/wiki/meta/ledgers/claim-ledger.json'))…") <(python3 -c "…/.vault-meta/worker/job-2…")`
and "Combined command: reply with guidance instead." (`MainView.swift`
`blocked(_:_:)`). The owner said: "there's no way I can handle something like
this".

The session already has Read, Grep and Glob (`JobContext.planningTools`), so the
AI only needed to use them. Denials are now a recovery case, answered by Distill
first.

1. **Auto-answer (a rule, no AI, no owner).**
   - **When.** In `requestDecision`, a turn ends with `denials` and **no valid
     plan**. A turn with a valid plan shows the plan; its denials are history.
   - **What the core does.** It answers the batch's session itself, once per
     turn, with an app-authored turn, then resumes (`resumeBatchSession`, action
     `reply`). The words come from `denialAnswer(denials, job)` in
     `engine/recovery.ts`:

     > Distill sessions can't run `Bash: diff <(python3 …) …` (no shell or python
     > here). Use Read, Grep or Glob to inspect files instead, for example:
     > `/…/wiki/meta/ledgers/claim-ledger.json`,
     > `/…/.vault-meta/worker/job-2…/bundle.json`. Compare them by reading both.
     > Don't run shell commands or python. Then continue the task and finish
     > with the structured status.

     The paths are the absolute paths found in the denied commands, those in
     the vault or the job directory only, at most 8. The command shown is cut to
     200 characters.
   - **Limits.** At most **2** auto-answers per batch (`recovery.denialAnswers`,
     persisted). Each one is an attempt `{ by: 'rule', fix: 'answer_denial',
     costUSD: 0 }` under the signature `denial`.
   - **Verified by.** The next turn has no denial for the same command.
   - **While it runs,** the batch reads **Recovering** ("Recovering · told Claude
     to read the files instead"), and nothing counts as Needs you.
2. **Recovery agent.** The AI is still blocked after 2 auto-answers. The
   recovery agent gets the facts (the denied commands, the auto-answers sent,
   and the turns) and can pick the new fix **`answer_denial`**, with a
   `guidance` text of at most 1,200 characters.
   - The core sends that text as the app's reply. It refuses guidance that
     names `transaction apply` or suggests allowing a gate-breaking rule
     (`gateBreakingReason`).
   - Other fixes stay open, for example `rebuild_in_session`. The usual bounds
     apply: 2 agent attempts and the cost cap.
3. **The owner card, only as a last resort** (recovery `gaveUp` with the
   signature `denial`). It is the Couldn't fix card, in plain language:
   - **What's wrong** comes from `denialSummary(denials, job)`. It is
     deterministic: a verb from the command (`diff`/`cmp` → compare;
     `cat`/`head`/`less`/`sed -n` → read; `python3 -c`/`node -e` → run a
     script; `rm`/`mv`/`>` → change), plus friendly names for the paths:
     - `wiki/meta/ledgers/claim-ledger.json` → "the claim ledger";
     - the source ledger likewise;
     - `.vault-meta/worker/<this job>/…` → "this batch's copy";
     - `wiki/**.md` → the page title;
     - anything else → its file name.

     For example: "Claude wanted to compare the claim ledger with this batch's
     copy. Distill couldn't let it run that, and told it to read the files
     instead (twice)." When the agent ran, its diagnosis comes next.
   - **Raw commands** are only behind **Show command**, a disclosure that is
     closed by default. Under it are the monospaced `denial.display` lines. A
     denial with a single allowable `suggestedRule` that is a write keeps
     today's checkbox, its "Allowing this lets Claude change files without your
     review." warning, and **Allow & continue**, all inside the disclosure.
   - **Options:** **Let recovery try again** (resets once), **Rebuild**, **Open
     in Terminal**, **Reject**.
   - The old "Claude asked to run" card and "Combined command: reply with
     guidance instead." are gone from Review's default view.
4. **Log.**
   - The live log has a `recover-<n>` step: "Recovering · told Claude to read
     the files instead", or "Recovering · Opus · answering a blocked command".
   - Activity gets `batch.recovery` with `kind: 'denial'`, the fix, the result
     and the cost. The raw command goes in the entry's detail and is redacted by
     `activity/redact.ts`, never in its title.

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
    "fix": "rebuild_in_session | reinspect_same_bundle | wait_then_retry | split_batch | discard_stale_part | answer_denial | new_session | give_up",
    "reason": "≤ 300 chars",
    "guidance": "≤ 1200 chars (answer_denial)",
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
  | `answer_denial` | sends `guidance` as the app's reply in the batch's session and resumes; refused if it names `transaction apply` or a gate-breaking rule | any plan → owner's OK |
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
  - A recovery still working (running or waiting) that hits another signature
    keeps its attempts, its cost and its denial answers (`recoveryFor`), so
    the bounds hold per recovery, not per signature; the new signature gets no
    rule of its own when a rule already ran (2026-10-06).
  - A minute's wake runs only if the recovery is still waiting for it, and an
    agent answer is carried out only while its attempt is the running one: an
    owner's action in between makes them no-ops.
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
- **Activity.** `batch.recovery` entries: `{ job, attempt, kind (= signature,
  e.g. 'denial'), by, model, fix, result, costUSD }`, with the actor `scheduler`, or `app` for Try
  again.
- **Cost.** Shown on each attempt row and summed on the Couldn't fix card.

### Done on a batch that added nothing (2026-10-09)

Done (`finishReview`) on a batch whose change never applied (failed, completed
with no operation, a part left over or needing a rebuild) does not lose its
sources. In the same call, the core (`releaseUnapplied`):

- leaves out sources the owner removed in Review, those of a part that applied,
  those whose source page is in the vault already (`existingSourcePages`, as
  the re-read finds them), and those whose inbox file is gone;
- puts the rest in a re-read plan with `reason: 'released'` and `fromJob`,
  packed by tokens like any re-read. Folder items stay whole.
- The plan never starts from Done, a tick or a job ending (`pumpRereads`
  skips it). It starts from `processQueue`, the timer's batch when automatic
  processing is on, or Process now, before the queue folder, in the active
  vault only; not from the overflow continuation of a split queue. It keeps
  its reason across a restart (`reread.json`).
- The batch keeps `released` (`files`, `inVault`, `missing`, `rereadId`) and
  gets one turn, for example "Not added. Its 2 sources not in your vault are
  read again with the next batch. 2 sources already in your vault stay as they
  are." Activity: `batch.sources_released` (from the job change).
- Once per batch: Done again changes nothing. A batch whose sources are
  already being read again (the owner's `distill batch reread --job`) gets
  `released.alreadyRereading` and "Not added. Its sources are already being
  read again." with no second plan.
- A fully applied batch (`completed` with an operation, no part left) is
  untouched: no field, no turn, no plan. So are rejected and cancelled
  batches: the owner stopped them, so sending their sources again is theirs.

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

1. Drop the extension. A **slugged** name (no spaces) has its dashes and
   underscores turned into spaces first, so the steps below see words.
2. Remove "Notes by Gemini" and "Transcript", in any case and with any
   separator between the words (`Notes[\s_-]+by[\s_-]+Gemini`).
3. Remove dates: `YYYY[-_ /.]MM[-_ /.]DD` (a space as the separator too, for
   slugged names), and `MM/DD/YYYY` written with `_`.
4. Remove times: `HH[:_.\- ]MM`, optionally `:SS`, optionally ` AM|PM`.
5. Remove time zones: a token of 2–5 capital letters from a list (`IST PST PDT
   EST EDT CST CDT MST MDT UTC GMT CET CEST BST JST AEST AEDT SGT HKT`), or
   `GMT±hh(:mm)`.
6. Collapse the separators left over (` - `, ` – `, ` — `, `_`, runs of spaces
   and dashes) and trim the punctuation at the ends.
7. For a slugged name, a short list of words gets its hyphen back: `stand up` →
   `Stand-up`, `check in`, `follow up`, `kick off`, `sync up`, `one on one`. A
   name with spaces keeps its in-word hyphens.
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
    `SinceApproved` (`RecoveryState` also holds `denialAnswers: number` and
    `summary?: string`; `RecoveryAttempt.fix` includes `answer_denial`);
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
  - `ruleFor(signature, attempts)`;
  - `denialAnswer(denials, job)`, the auto-answer text with the vault and job
    paths;
  - `denialSummary(denials, job)`, the plain-language owner sentence. The Mac
    shows the core's string and never builds one from argv.

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
  - `checkRebuiltPart` sets `sinceApproved(queuedApply.bundlePath,
    request.bundlePath)` when the job has `queuedApply`, then deletes
    `queuedApply.planSha256` (Needs you, `order` kept).
  - `requestDecision` clears `refresh`.
  - `requestDecision`: denials with no valid plan go to `recover(id, 'denial')`.
    Below 2 `recovery.denialAnswers`, it sends `denialAnswer` and resumes
    (`resumeBatchSession`, action `reply`). Then the agent runs (`answer_denial`
    sends `guidance`), then `gaveUp` with `recovery.summary =
    denialSummary(…)`.
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
- **`Distill/MainView.swift` `blocked(_:_:)`:**
  - It is replaced by `RecoveryGaveUpCard` for the signature `denial`: the
    `recovery.summary` sentence first, then the raw `denial.display` lines and
    the existing allow checkbox inside a closed **Show command**
    (`DisclosureGroup`).
  - "Combined command: reply with guidance instead." is removed.
  - A job still in recovery shows `RecoveryNotice`, never the denials.
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
  `review-reapprove`, `review-recovering`, `review-gaveup`,
  `review-recovering-denial` and `review-gaveup-denial`, matching the board.

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
11. Denials (`recovery.test.ts`):
    - A FakeRunner turn ends with a denial (`Bash: diff <(python3 …) …`) and no
      plan. The core sends `denialAnswer`, which names Read, Grep and Glob and
      the ledger and job paths, and resumes the same session.
    - The next scripted turn returns `needs_approval`. Review shows the plan;
      nothing counted as Needs you in between.
    - The cap: three denying turns in a row. Answers 1 and 2 are rules; the
      third goes to the recovery agent, whose `answer_denial` guidance is sent.
      A guidance naming `transaction apply` is refused, the attempt fails, and
      the job ends `gaveUp`, with the signature `denial` and a `recovery.summary`
      like "Claude wanted to compare the claim ledger with this batch's copy…".
    - The `denialSummary` text never contains the argv: no `python3`, `<(`,
      `-c` or absolute path.

**Mac** (`DistillKitTests`):

- `ReviewLogicTests`:
  - the `readableName` cases above;
  - `rowState` for every state;
  - oldest-first order;
  - `nextSelection`.
- `ApplyTimelineTests`: a job with `refresh` is not failed and has heading
  "Updating against the latest pages".
- `ModelsTests`: lenient decode of the new fields; old jobs without them decode.
- Denial card (`DistillTests`, or a snapshot check of `review-gaveup-denial`):
  the card's visible text by default is the summary and the options. No
  `denial.display` text appears until Show command is opened.
- `SettingsEditsTests`: the Recovery fallback is Opus.
- The snapshot states render; the design drift test passes.

## Built so far

### Step 1: blocked commands (2026-10-05)

- Core: `engine/recovery.ts` (`denialAnswer`, `denialSummary`, `friendlyPath`,
  `recoveryFor`, `MAX_DENIAL_ANSWERS = 2`); `recoverDenial(id)` in
  `engine/index.ts`, called from `requestDecision` when a turn ends with
  denials and no valid plan. The answer is an `app` turn in the conversation
  and the session is resumed with `replyPrompt`. A plan that comes back marks
  the recovery `fixed`.
- **Differences from the design:**
  - An **apply turn** with a blocked call is never answered: the approved
    command is what ran or was refused there (`requestDecision(…, applyTurn)`).
  - **Existing stuck batches:** `start()` runs the rule once for any batch
    waiting with denials, no plan and no `recovery` (a batch an older build
    left waiting), so the owner's current one is answered after the update.
  - Reply, Allow and Reject clear `recovery` (the owner acted).
  - The card's first option is **Tell Claude to read the files** (the owner's
    reply, a fixed text) until the recovery agent lands in step 5, which adds
    **Let recovery try again**. A batch from an older core with denials and
    no `recovery` shows the same card with a plain fallback sentence.
  - "Recover automatically" (Settings) arrives with step 5; until then the
    rule always runs.
- Mac: `ReviewQueue.swift` (DistillKit types, `BlockedText`),
  `BlockedCommandCard.swift`; `MainView.blocked` uses it. Show command opens
  by itself only when a rule is ticked (the existing Allow flow).
- Tests: `engine/recovery.test.ts` (3), `engine.test.ts` "blocked commands"
  (4), `ReviewQueueTests` (2). Snapshot states `review-recovering-denial` and
  `review-gaveup-denial`.

### Steps 2 and 3: the apply queue and the refresh (2026-10-05)

- Core: `engine/apply-queue.ts` (`staleFor`, `queueOrder`, `isBookkeeping`,
  `sinceApproved`); in `engine/index.ts` the queue gate in `approve`,
  `pumpApplies`, `refreshWaiting`, `refreshJob`, `unqueue`, the LOCK wait,
  `needsOwner` for `status().pendingApprovals`. `POST /v1/jobs/:id/unqueue`
  (activity `batch.unqueued`). `ApprovalRequest.sinceApproved`.
- **Differences from the design:**
  - **No separate `startApply`.** `approve` applies at once when nothing is
    ahead in the vault (so a gone session still reaches the caller), and
    queues otherwise. The pump calls `approve(id, …, fromQueue)` after
    `transaction inspect` proves the approved hash; every check and apply exit
    is the one Approve already has.
  - While an apply runs, `queuedApply` stays on the job **without**
    `planSha256` (it keeps its `order`). A batch that comes back (exit 75, a
    restart mid-apply) therefore never re-applies by itself.
  - **One rebuild per change.** A batch is rebuilt at most once for each apply
    that lands in its vault (in memory). A plan still stale after its rebuild
    changed for another reason (an edit outside Distill): it goes to the owner
    with "Reply to have it rebuilt", never into a loop.
  - **Rebuilds only after an apply lands**, never at start or after a
    planning turn. At start only the queue moves. A plan made stale before
    this build, or by a hand edit, keeps today's handling until the next apply
    in its vault.
  - **LOCK_TIMEOUT** keeps the approval (`planSha256` set back) and holds the
    vault's queue 30 s, then 2 min; after that the owner is asked. The turn
    says "Distill tries again shortly".
  - An apply turn (Claude's session) that came back with stale pages also
    goes to the refresh (`staleFor` on the approved bundle).
- Mac: `ReviewQueueText` (needs-owner rule, queued and approve notes, What
  changed lines), `SinceApproved`, `CoreClient.unqueue`; `AppModel.pendingApprovals`
  uses the core's rule (badges). Review: a blue "Queued · applies after …"
  notice, footer **Don't apply yet** and a disabled **Queued**; "Applies after
  …" next to Approve when another batch is ahead; `SinceApprovedCard`
  ("Rebuilt after you approved it", What changed since you approved);
  `ApplyTimeline.updating` ("Updating against the latest pages", never a
  failure); pills Queued, Updating…, Recovering, Needs you.
- Tests: `apply-queue.test.ts` (3), `engine.test.ts` "the apply queue" (4) and
  the exit-75 tests rewritten (LOCK waits under the same approval; stale is
  rebuilt and asks once more). `ReviewQueueTests` (5). Snapshot states
  `review-queued`, `review-reapprove`, `review-updating`.

### Step 4: the batch list (2026-10-05)

- DistillKit: `ReviewBatches.readableName`, `batchDate`, `rowState`
  (`ReviewRowState`), `ordinal`, `nextSelection`. `ReviewQueueText.shortName`
  uses the readable name too.
- Mac: `ReviewBatchList.swift` (`ReviewBatchList`, `ReviewBatchRow`) beside
  the batch with `.paneWidth(.reviewList, automatic: 260)` (220–380, in
  `fixedKeys`); ↑/↓ through `onMoveCommand`; when the selected batch leaves,
  the next row is selected. `JobTabs` is removed. `Job.displayTitle` uses
  `readableName`.
- **Differences from the design:**
  - The list keeps the order `ApplyTimeline.reviewList` already had (waiting
    batches oldest first, then approved ones not yet Done), not one single
    oldest-first sort: an approved batch that finished stays below the ones
    still waiting.
  - A `Working` state exists for a batch whose turn is running for another
    reason (a reply).
- Tests: `ReviewBatchListTests` (the spec's name table plus a transcript
  case, row states, next selection, ordinals, the date). Snapshot state
  `review-list`; `review-multiple` now shows the list.

### Step 5: the recovery agent and Settings (2026-10-05)

- Core: task `recovery` (`TASK_REQUIREMENTS.recovery = [['structuredOutput']]`,
  default Claude Code · Opus · medium, `taskDefaults.recovery` overrides);
  `Settings.recovery` (`automatic`, `maxAttempts` 1–5, `maxCostUSD`), read
  through `recoveryPreferences`. `engine/recovery.ts`: `RECOVERY_SCHEMA`,
  `parseRecoveryAnswer`, `validateFix` (fixes allowed per problem; guidance
  that names the vault apply or asks for a tool rule is refused),
  `recoveryFacts`, `recoveryPrompt`. `runRecoveryAgent` in the engine uses
  `runStructured` (no tools, a fresh session, a scratch directory under the
  state dir; never the vault). `tryRecoveryAgain` = `POST /v1/jobs/:id/recover`
  (activity `batch.recovery`).
- Recovery is not part of the setup check: a recovery runner that isn't ready
  never stops batching (it ends in Couldn't fix).
- Mac: `AITask.recovery`, `fallbackSelection(.recovery)` = Opus · medium; the
  Recovery row in Settings → AI models; the Recovery group (Recover
  automatically, Attempts per problem, Cost limit per batch);
  `RecoveryPreferences`; `CoreClient.recover`; the card's **Let recovery try
  again** and "Tried twice · last by Opus · $0.04".
- **Not built yet after step 5:** the items listed then are built in step 6
  below; what is still open is listed there.
- Tests: `engine.test.ts` "blocked commands" (6: the agent's guidance is sent
  and the plan comes back; guidance naming the apply is refused; the cost
  limit and Recover automatically; Try again), `recovery.test.ts` (4),
  `backends.test.ts` task lists, `RecoverySettingsTests` (2).

### Step 6: recovery for other problems, and what was left (2026-10-06)

- **Core, recovery for `stale-again`, `plan-error`, `runner-failed`**
  (`recover(id, signature)` in `engine/index.ts`):
  - A rule first, at most once and $0: `plan-error` and `runner-failed` get one
    fixed reply in the batch's session (rebuild the plan; continue after the
    error). For `stale-again` the rule is the refresh itself.
  - Then the recovery agent, with the new fix `rebuild_in_session` (optional
    guidance, checked like `answer_denial`'s). For `stale-again` it forces one
    more refresh.
  - **A minute between agent attempts** (`RECOVERY_BACKOFF_MS`): the recovery
    reads `waiting` with `waitUntil`; `start()` resumes a waiting attempt, and
    an agent call a restart cut off is tried again.
  - Triggers: a resumed turn (not an apply) that throws → `runner-failed`; a
    recovery turn that errors escalates; a plan error with no plan and no
    denials → `plan-error`; the pump's second stale plan → `stale-again`.
  - A gone session during recovery gives up with `proposal: 'new_session'`.
  - A **failed** batch under recovery can be rejected (`reject`), so it can
    leave Review.
- **Activity and live log:** `batch.queued`, `batch.refresh` and
  `batch.recovery` for automatic attempts too; live-log steps `queued-<n>`,
  `updating-…` and `recover-<i>`.
- **Mac, the recovery card** (`RecoveryCard` in `BlockedCommandCard.swift`,
  words in `RecoveryText`, `ReviewQueue.swift`):
  - Recovering: a blue notice, "Recovering · Opus · asking Claude to rebuild
    the plan", what's wrong, "Tried twice · last by Opus · $0.03". Nothing
    needs the owner.
  - Waiting: "Recovering · next try at 10:42 AM" (`RecoveryState.waitUntil`).
    The pill reads Recovering while running or waiting.
  - Gave up: the peach "Distill couldn’t fix this" card with the core's
    sentence, the attempts line, **Let recovery try again**, **Open in
    Terminal**, **Reject batch**.
  - While recovery works on a plan error, the raw "Can't apply this plan yet"
    callout waits.
  - A failed batch with a recovery stays in Review's list
    (`ApplyTimeline.reviewList`); once recovery gave up its row reads Couldn't
    fix, its pill Needs you, and it counts in the badges (`needsOwner`, core
    and Swift).
- **Continue in a new session** (`recovery.proposal == 'new_session'`, on both
  cards): the button opens the usual `SessionReplaceConfirm` in the card,
  headed "Recovery suggests a new session"; only its **Continue** sends
  `reply(newSession: true)` with a fixed text (`RecoveryText.newSessionReply`).
  It is hidden when the job already has a gone-session marker, since that
  confirmation already shows under the batch. The owner's new session clears
  the recovery.
- **`distill status`** lists approvals waiting to apply, in order ("Applies:
  1. Product sync (approved, waiting its turn in Research)"), and batches
  recovery works on ("Recovery: Tea · the vault core couldn’t check its plan ·
  next try at …"). `StatusResponse.applyQueue` and `recovering`
  (`queueStatus` in `engine/apply-queue.ts`).
- **Approve with nothing ahead** runs `staleFor` on the bundle first. A plan
  the vault already overtook goes straight to the refresh ("Your vault changed
  since this plan was built, so it is rebuilt first"), never an apply turn. If
  the refresh can't start, Approve goes on as before.
- **No recovery is left "Recovering" (2026-10-06, the owner's stuck batch).**
  A recovery reads `running` only while a turn or a recovery agent call works
  on it. `settleRecovery` runs when every turn ends and after every agent
  call: a turn that neither fixed it (a valid plan) nor started it again (new
  denials, a plan error, a runner error) fails the running attempt. A rule's
  attempt escalates once to the agent, anything else gives up ("Distill
  answered Claude’s blocked command, but Claude stopped with questions instead
  of a plan."). `start()` settles a recovery left running with nothing in
  flight the same way. Every recovery reply (`denialAnswer`, `rebuildText`)
  now says Distill runs `transaction inspect` and the approved apply itself,
  and, for an approved batch, that the apply waits in Distill's queue and is
  retried (`whoApplies`). The Mac says Recovering only while
  `RecoveryText.isActive` (a turn runs, an agent attempt runs, or a next try
  is scheduled); otherwise the batch reads Needs you. Snapshot state
  `review-gaveup-questions`.
- **After a spent rule (2026-10-06).** `recoverAfterRule`:
  - **`lock`:** after the 30 s and 2 min waits, the batch goes back to the
    owner as before and the recovery agent runs within its bounds, keeping the
    hash the owner approved (`approvedSha256`). Its fixes are
    `reinspect_same_bundle`, `wait_then_retry` or `give_up`. A retry that hits
    the lock again continues the same attempts (the recovery stays on the
    batch while it applies), so two agent attempts per recovery is the limit.
    Fixed with it: the pump reset the lock count before every try, so the
    30 s / 2 min rule never ended; the count now resets when an apply lands.
  - **`session-gone`** (the queue found the batch's session gone): $0, no
    agent. Its only fixes are a new session, which only the owner may start,
    or giving up, so it gives up at once with `proposal: 'new_session'` and a
    plain sentence; the existing new-session confirmation is the way on.
  - **`not-recorded`:** the rule from the table, the vault journal: an apply
    turn that didn't report the approved operation is recorded as applied when
    `.vault-meta/transactions/<op>/journal.json` is `complete` with the
    approved hash ("found in the vault’s journal"). Without it nothing is
    guessed; the turn still says to check the vault log. No agent: its only
    fix is `give_up`, and the batch is already finished (Not added).
  - **`full-read-stop`:** unchanged. Its only fix is `give_up`, and Review
    already shows the v10 option for the stopped sources; a Couldn't fix card
    on top would only repeat it.
- **The other four fixes (2026-10-06).** The agent's schema has `waitFor`
  and `groups`, its facts list the pages the batch changes, other batches
  touching them, the source pages, a waiting rebuilt part and whether an
  approved apply waits. `validateFix(answer, signature, FixContext)` checks
  each fix against the batch, never the agent's word:
  - **`reinspect_same_bundle`** (lock): needs the hash the owner approved
    (`recovery.approvedSha256`). The recovery waits with `wake: 'retry'`; when
    it wakes, the batch goes back to the queue under that exact hash only if
    the plan still has it, and the pump's `transaction inspect` proves the
    bytes before the apply. A plan that changed goes to the owner.
  - **`wait_then_retry`** (lock, stale-again): `waitFor` must be another
    batch in the same vault touching the same pages. The retry runs one
    backoff (1 minute) later, the same way, with no agent call; a restart
    resumes it as a retry (`wake`).
  - **`split_batch`** (stale-again, plan-error) and **`discard_stale_part`**
    (stale-again): **proposals** the owner confirms on the card, which narrows
    the design table (decision 2026-10-06). `groups` must hold every active
    source exactly once, in two or more groups; the card's "Rebuild N sources
    first" approves the first group (`approve` with `pages`, so
    `startPart('partial')`). Discard needs a waiting rebuilt part; the card's
    "Discard the rebuilt part" rejects the part, never the batch.
  - The owner's own action (a pick, a discard, Don't apply yet) clears the
    recovery. A batch back in the queue under its approved hash counts as
    worked on (not settled, not Needs you).
  - Snapshot states `review-gaveup-split` and `review-gaveup-discard`.
- **Rebuild and What was tried (2026-10-06).** The Couldn't fix card has
  **Rebuild against the latest pages**: the owner's reply with a fixed text
  (`RecoveryText.rebuildReply`), so it clears the recovery, works for a stopped
  batch too, and a gone session asks first as every reply does. WHAT WAS TRIED
  lists one row per attempt ("Opus · asked Claude to rebuild the plan · didn’t
  help · $0.04"), words from `RecoveryText.fixWords`, which Activity's Fix row
  uses too; an attempt's raw error is never shown.
- **Lock, last fixes (2026-10-06).** The 30 s / 2 min count belongs to the
  batch that met the lock: another batch starts at 30 s (the last one may
  have failed another way, been rejected or taken out of the queue). When the
  rule is spent and recovery takes over, the conversation says "the vault
  stayed locked for several minutes. Distill’s recovery is looking at it";
  "Approve again when it is closed" comes only when recovery is off, or on the
  Couldn't fix card once it gives up.
- **Fixed after review (2026-10-06).** Let recovery try again on a lock goes
  back to the agent and keeps the approved hash; on session-gone it is hidden
  and refused (only the new-session confirmation goes on). Rebuild is hidden
  for a labels confirmation (no session). A stale-again recovery from the
  pump takes the batch out of the queue first, keeping the approved hash on
  the recovery, so a recovery that gives up reads Needs you instead of
  Queued.
- **Still open:**
- Tests: `session-continuity.test.ts` (runner-failed recovery; a stopped batch
  can be rejected; a gone session proposes a new one and only the owner's
  Continue starts it), `engine.test.ts` (plan-error rule then agent with the
  minute's wait; a plan the vault overtook is rebuilt at Approve without an
  apply), `cli.test.ts` (status lists the apply queue and recovering batches),
  `ReviewQueueTests.testRecoveryWordsForOtherProblems`. Snapshot states
  `review-recovering-plan-error`, `review-waiting-backoff`,
  `review-gaveup-runner`, `review-gaveup-new-session`.
