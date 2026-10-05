---
type: spec
title: Full reads
status: designed
created: 2026-10-05
updated: 2026-10-05
tags:
  - distill
  - batches
  - coverage
  - inbox
---

# Full reads

Every source in a batch is read from its first line to its last. Its page has
to carry what the source says, at the detail the owner chose. Both are checked
before the batch reaches Review.

**The core checks this from the runner's own tool results. The AI's report is
never trusted.** When something is missing, Distill fixes it without asking.
The owner sees the outcome as information, never as a decision.

> "relying on human is wrong. we need the solution to be more automatic.
> relying on human means nothing will be checked correctly" (the owner)

Canvas: row 11, board **FullRead**. Related specs:

- [Queue and batching](queue-and-batching.md): batch packing.
- [Approval and review](approval-and-review.md): the gate and parts.
- [Live log](live-log.md)
- [Clean up inbox](inbox-cleanup.md)
- [Session continuity](session-continuity.md)

The re-read entry point and the ingest prompt text are owned by the
`reread-sources` work. This spec gives that work the facts it needs and does
not edit the prompt.

## What went wrong (2026-10-04, the owner's batch)

**One session.** 22 Gemini meeting notes went in as one batch, in one session
(`61aafdab…`). The run cost $3.24, took 126 turns and read 6.4M cache tokens.

**What was read.**

- 8 files were read whole, in one parallel round. That round took the context
  from 29,067 tokens to 129,523 tokens.
- The other 14 were read with `limit: 110`, and their pages were labelled
  partial.

**The skill told it to.**

- `skills/wiki-ingest/SKILL.md:29-31`: "choose a bounded first tranche".
- `:83`: "label the result partial".

**Two "whole" reads were cut silently.** The tool reported no error, but the
result carried `toolUseResult.file.truncatedByTokenCap: true`.

| File | Lines returned | Lines in the file |
| --- | --- | --- |
| 2026-09-29 AIDR | 1–139 | 644 |
| 2026-09-29 Telus | 1–221 | 787 |

Both files end in one 64 to 88 KB line, an embedded image
(`[image1]: <data:image/png;base64,…>`). **A successful Read is not proof of a
full read.**

The huge image line is the likely cause of those two cuts. The reading copy
removes it, and the coverage gate catches any other cut, whatever its cause.

**Most of the bytes are images.**

- Ten of the 22 files carry base64 image definitions.
- *Tech Talk* is 1,348 KB, and 1,322 KB of it is images. It also has two
  invitee-list lines of 6.3K characters.
- The 23 notes now in inbox/ hold about 826 KB of text, or about 210–260K
  tokens.

**"Partial" is prose only.**

- Pages say "…were not read, so this page is partial".
- Every page has `status: mapped`.
- The ledger has no coverage field.
- `log.md` and `hot.md` repeat the claim in prose.

So existing pages can't be told apart reliably.

**Depth.** A small note (23,750 bytes, 411 lines) became a 2,824-byte page.
That page says the transcript was all read, yet the owner finds information
missing. A full read alone is not enough.

## 1. The reading copy: decided by the core

**When.** Before the first turn, the core prepares every text source of the
batch.

**Where.** The copy goes to `<job dir>/read/<n>.md`, inside `.vault-meta/`, so
nothing in the vault changes.

**The text.**

- The source is decoded as UTF-8, after a BOM check.
- **If decoding fails, the source is unreadable.** The core decides this, never
  the AI. Other cases count as unreadable too:
  - NUL bytes;
  - zero readable lines;
  - a missing or unreadable file.

**The lines.** Copy line *n* is source line *n*, so line numbers stay true.

- A line that is only a data URI becomes a one-line placeholder, for example
  `[image1: embedded PNG, 87 KB, not text]`.
- A line over 1,900 characters keeps its first 1,900 characters in place and
  ends with `→ L<n>↪`.
  - Its remaining pieces go **after the last line** of the copy, each prefixed
    `L<n>↪ `. Nothing is inserted between source lines.
  - Those appendix lines are part of the required ranges.
- `read/<n>.map.json` records the appendix lines and the source line each one
  belongs to.

**What the AI is told.** The prompt gives each source's original path, the
copy's path and its planned sections. The AI reads the copy and cites the
original. This goes through the `reread-sources` prompt helper.

**What it counts for.** The copy is what the token estimate and the coverage
are measured on.

**Other kinds of source.**

| Kind | Handling |
| --- | --- |
| PDF | Read by page, with Read's `pages` (unverified: check that its result reports the pages it returned) |
| Image | One read |
| `.distill.json` manifests, `seenBefore` files, `.gdoc` pointers | Not sources here |
| Folder item | Each file inside is a source |

**On the owner's files.**

| Note | Raw | Text |
| --- | --- | --- |
| Tech Talk | 1.38 MB | about 26 KB of text in the copy |
| 2026-09-30 AI FE 10:09 | 289 KB | about 22 KB |

## 2. Batches sized to what one session can read

### The estimate

A source's estimate in tokens is its copy's bytes divided by **2.6**:

- Measured: the 8 whole reads returned 265,479 characters of tool text,
  including line-number prefixes, and cost 100,456 tokens.
- A PDF counts 1,500 tokens a page.
- An image counts 1,600 tokens.

### The budget

**`settings.batchSourceTokens`**. Absent means **Automatic**.

**Where the window comes from.** The `result` event's
`modelUsage[model].contextWindow`. This was verified on CLI 2.1.289:
`claude-sonnet-5-5` reports 1,000,000.

- It is cached per model id in Distill's state after the first run.
- Until a model has been seen, a small table in the core
  (`runners/models.ts`) is used.
- An unknown model counts as **200K**, the conservative case.

**Automatic** is 30% of the ingest model's context window, capped at 100K:

| Model context | Budget |
| --- | --- |
| 200K | 60K |
| 1M (the owner's Sonnet) | **100K** |

**How 100K fits a 1M session.** It stays far below the point where Claude Code
compacts:

| Part | Tokens |
| --- | --- |
| Measured overhead before the first source | 29K |
| Sources | 100K |
| Detailed drafts, about 0.25 × sources | 25K |
| Existing pages | about 30K |
| Bundle, inspect, continuations and the detail pass | about 25K |
| **Total** | **about 210K** |

On a 200K model, the 60K budget keeps the same parts to about 145K.

**Why 100K is the cap even on 1M.** Cost per source grows with the session's
context, because every turn re-reads it. 100K keeps cost roughly linear, as
the reviewer recommended.

**Settings → Batching → "Batch size"** offers:

- **Automatic**: "Sonnet: up to 100K tokens, about 260 KB of text, 8–10 long
  transcripts".
- **Smaller**: 50K.
- **Larger**: 200K. This needs a 1M-context model; on a smaller model it is
  shown capped.

The setting is clamped to 10K–300K, is additive, and is decoded leniently.

### Packing

**Where.** In `processQueue`, after the label gate and **before**
`claimItems`, `ready` is cut to what fits.

**Which items.**

- Oldest items go first.
- Items are atomic. A folder item, or a note with its manifest and images,
  is never cut.
- An item over the budget on its own gets a batch of its own. It is read in
  sections over several turns, and coverage spans the turns of the session.

**The rest runs right away.** When a job leaves `running` and ready items
remain, the engine calls `processQueue` again. It does not wait for the
schedule. `batchBlocker` blocks only while a batch is running. The Queue card
reads "Batch 1 of 3 · 9 sources · about 96K tokens · about $2.6 at list price",
then "Next batch starts when this one is ready for review".

### Sections

The core plans the sections the prompt lists:

- at most **400 lines and about 8K tokens** each;
- a break falls at a heading, a timestamp (`### **00:05:09**`) or a blank
  line.

A continuation names these exact sections.

### Cost (expected)

**Measured.** The re-read job `job-20261005-123916-df39`:

- 3 notes, 89,957 bytes of text, about 35K tokens;
- 37 turns;
- **$0.93**, the CLI's `total_cost_usd` (`costBasis: list`);
- coverage 100%.

**Scaled.** About **$2.6 per 100K-token batch**, at list price.

**The owner's 22 notes** hold about 826 KB of text, about 320K tokens. That is
4 batches, about **$10–12 at list price**, plus the detail pass (cents).

- The old partial run cost $3.24 and read under half of the text.

**On screen.** The Queue card shows the estimate as "about $2.6 at list price".
A runner with no price shows it in tokens.

## 3. Coverage: computed by the core, from tool results

### The evidence

**Not the live log.** It keeps words only (`words.ts:90-94`) and is capped at
2,000 steps / 512 KB (`steps/index.ts:21-22`).

**Coverage is computed in `handle()` from `result.raw`**, the turn's
stream-json:

- Each successful `Read` result carries a top-level, snake_case
  `tool_use_result` on the `user` event. It holds `file {filePath,
  startLine, numLines, totalLines}` and `truncatedByTokenCap`. This was
  verified on CLI 2.1.289.
- If that object is missing (an older CLI), the first and last line numbers in
  the result text are the fallback.
- Only Read results count.
  - The prompt says to read sources only with the Read tool.
  - Bash, Grep and subagent reads are never credited.
  - `Task` and `Agent` stay out of `INGEST_AVAILABLE_TOOLS`.
- A failed read (`is_error`) credits nothing.

**Stream-json for ingest.** Ingest always runs with `stream: true`, even with
no `onStep` sink (`claude-code.ts:200`). Otherwise `result.raw` holds only the
final envelope.

**Paths.**

- The `filePath` is resolved, including the transcript's
  `MyKnowledgeVault/../../orca/…` forms.
- It is NFC-normalized and made vault-relative.
- It is matched to a copy or a source.
- A read of the copy counts for its source.

### Where it is kept

The job's coverage is kept as an additive field on the job:

```text
job.coverage: {
  sessionID,
  sources: {
    [file]: { sha256, lines, required, read, images, state }
  },
  rounds,
  state
}
```

- The ranges are numbers only.
- It accumulates across the turns of **one session**.
- It is **reset** when the batch moves to a new session. That happens through
  `continueInNewSession`, which may switch runners, or through an `unread`
  part.
- It is saved with `jobs.json`, so a restart keeps it.

**Compaction: designed for its absence.** `compact_boundary` is seen only in
interactive JSONL (`system` / `compact_boundary`). It is not verified in `-p`
stream-json. So:

- **The budget is the main guard.** About 210K of 1M, so `-p` turns are not
  expected to compact.
- **Two signals count as a compaction.** Either is enough:
  - a `compact_boundary` event, if one appears;
  - the context shrinking. A later assistant message's `usage` (input plus
    cache-read plus cache-creation tokens) falls below 60% of the previous
    message's, within one session.
- **After a compaction, and only then**, the draft-after-read order applies,
  within that session. A read range counts only if a later write of that
  source's page follows it.
  - **Draft, page, source.** The final bundle's writes say which
    `content_file` holds which page. Each page names its source through
    `source_path`. A Write or Edit of that `content_file` is a draft write.
  - **Inline pages.** A page written as inline `content` counts the Write of
    `bundle.json` instead.
  - Draft file names are the AI's choice, so the mapping comes from the
    bundle, never from names.
- **Before any compaction, order doesn't matter.** Every returned range
  counts.
- **The prompt helps.** The `reread-sources` helper asks that a long source's
  draft be updated after each section, so a compaction loses at most one
  section.

**The source-coverage index.** Once a batch's pages apply, each source's
result is written to `<state>/coverage/sources.json`, keyed by
`content_sha256`: `{full: true | false, lines, jobId, at, detail}`. This is
the record Clean up and Repair use. **Partial is data from the core, not
prose.**

### The gate: first in `handle()`

**When it runs.** For a reading turn, the gate runs before anything else in
`handle()` when the turn ends in `needs_approval`, `nothing_to_do` **or**
`needs_input`:

- Today `nothing_to_do` completes with no Review. That changes: an unread
  batch can't claim it has nothing to add.
- A `needs_input` with real questions, or with a blocked tool, still reaches
  the owner. The gate runs on the turn after their reply.
- The AI's `skipped` list never exempts a file.

**When it is skipped.** Apply turns (`applyPlan`) and the rebuild of a part
the owner picked (`pendingPart` with reason `partial`, `remaining` or
`stale`) skip it. Those reuse pages that already passed.

**Covered.** The gate goes on to the result checks (section 5).

**Not covered.** Nothing reaches Review. The core **continues the same session
by itself**.

- **How.** A plain `runTurn(id, prompt, { autoContinue: true })` resume. The
  job stays `running` throughout, with no `awaitingApproval` and no
  `needsRebuild`. This is not `sendPartInBackground`.
- **If the session is gone.** The `autoContinue` flag makes a refused resume
  skip `restoreJob` and SessionReplaceConfirm (`index.ts:774-781`). It goes
  straight to the fresh-session path below, with every source of the batch.

The continuation's wording:

> These parts of the batch were not read. Read each one with the Read tool
> exactly as given, then update that source's page draft from what you read,
> rebuild the bundle at the same path, inspect it, and finish with
> `needs_approval`.
> - inbox/2026-09-30 Tomasz _ Jin ….md (copy: read/7.md): lines 111–400,
>   401–647 (offset 111 limit 290; offset 401 limit 247)

**Limits.** At most **3 continuations** per session. The core stops early when
a round credits no new lines.

### Splitting what one session could not read

The split stays inside the **same job**. A new batch can't take these files:
`claimedFiles` (`index.ts:517-518`) and `processQueue` only claim from the
queue. `startPart` and `partPrompt` can't be reused at gate time either:

- they need `approval.bundlePath` and `approval.sources`
  (`index.ts:1217-1234`);
- they pin pages byte for byte (`review-labels.ts:249-252`, `:287`).

So the split is **a dedicated step, `splitCovered(id)`**. It runs after the
3 continuations, and **after the detail pass on the covered sources**, so
their pages are final.

1. **Read the current bundle** with `sourcePages()`.
2. **Map each page to its source** through the page's `source_path`.
   - The prompt must keep `source_path` as the source's inbox (or
     `.raw/captured/`) path, never the reading copy's path.
   - The gate checks it, and sends a continuation on a mismatch.
3. **Build a PendingPart with the new reason `covered`.** The gate skips this
   reason.
   - `expected` holds the covered pages' sha256 values, taken from the current
     bundle.
   - `leaveOut` lists the unread sources.
   - A split prompt, `splitPrompt` (shaped like `partPrompt`, built from
     `sourcePages()` instead of `approval`), asks the same session for
     `bundle-part-<n>.json` with exactly the covered sources.
4. **Verify the rebuilt bundle** with `verifyRebuilt`. The covered pages must be
   byte for byte as expected. There must be **no page and no ledger entry**
   for the unread sources.
5. **The covered part goes to Review.**
6. **If the session is gone at split time,** nothing is split. Every source of
   the batch goes down the fresh-session path.

**The unread sources become the next part**, with the new reason `unread`.

- It starts after the covered part applies (`continueAfterPart`,
  `index.ts:1304-1345`). Review shows it meanwhile as "2 sources are read next
  in a fresh session".
- It starts through a new path, `startUnreadPart(id)`:
  1. Clear `job.sessionID`, so the job gets a new session.
  2. Reset `job.coverage` for those files.
  3. Build the full ingest prompt (`IngestJobKind.initialPrompt`, through a
     `JobContext` limited to the unread files), with `FULL_READ_PROMPT`,
     `RereadFacts` and sections at half size.
  4. The prompt names `bundle-part-<n>.json` and says that the earlier part
     already applied.
  5. Run it as a `first: true` turn.

  Nothing is resumed, so SessionReplaceConfirm can't open. The gate applies
  as to any reading turn.

**The batch reaches Review only at 100% coverage** of the sources in the
part being shown.

### Hard stop: the only thing that reaches the owner

**The causes.**

- The core found the source unreadable while building the copy (section 1).
- An `unread` part, in its own fresh session, still has unread lines after its
  3 continuations.

**Review shows** a group above Sources, "Not added · couldn't be read", with:

- the name;
- the reason in plain words, for example "isn't valid UTF-8 text from line
  412", or "the reads stopped at line 139 of 644 every time, also alone in a
  fresh session";
- **Show in Finder** and **Try again**.

**It can't be approved.**

- The source has no pick box.
- It is not in the bundle. `verifyRebuilt` checked that.
- Approve counts only the others, for example "Approve 21 sources".
- An approve that names its page is refused (`invalid_state`).
- There is **no "approve anyway"** anywhere.

**After the batch is approved.**

- The stopped source shows on Queue under **Held in inbox/**, with the peach
  "Couldn't be read" pill.
- It counts in the sidebar badge.
- Clean up never offers it.
- **Try again** re-checks the bytes. If they are readable now, it calls
  `rereadSources({ files: [file], perBatch: 1 })`.

**Activity:** "Couldn't read “…” in full: <reason>" (`batch.read_stopped`).

### Runners

Coverage needs `tool_use_result` line spans. **Codex can't provide them:**

- It reads through shell `command_execution`, and its output to the model is
  truncated.
- So coverage becomes a **runner capability**, `readCoverage`. Ingest routes
  only to runners that have it, which today is Claude Code.

**Settings → AI → Ingest.** Codex shows as "Can't prove full reads yet". A
saved Codex ingest choice runs on Claude Code, and the app says so once.

**Later option.** Codex ingest with sections fed in by the core: the core puts
each section's text in the prompt, so coverage is by construction.

The owner decided this on 2026-10-05: Codex ingest is deferred, and the
follow-up is a Distill To do (`act-026ab6c5…`).

## 4. Never lose originals: archive with the batch (Option A)

**Where the archive happens.** Every `.raw/` change goes only through a
reviewed transaction (`decisions.md:396`). So the archive happens **inside
the ingest bundle** that the owner reviews:

- For each source, the bundle includes the create-only write
  `.raw/captured/<sha256>.<ext>`:
  - `content_file` is the inbox file;
  - `sha256` is its hash;
  - an identical existing capture is left out.
- This is the same primitive as `capture apply` (`capture.py:965-1031`).
- The ingest operation is allowed to write `.raw/` (`transaction.py:98`,
  `3259-3263`), and only in create mode (`3436-3448`).
- The source-ledger entry's `origin.locator` points at that `.raw/captured/`
  path.
- The core gives the exact write per source to the prompt helper.
- After inspect, the core verifies each source's capture write and locator.
  If one is missing, a continuation names it.

**Ledger IDs change, so records are migrated.**
`stable_source_id` = hash(origin kind + locator + `content_sha256`)
(`ledgers.py:407-414`), and inspect rejects a mismatch. So a source already
in the ledger under its `inbox/` locator gets a **new `src-` ID** when its
locator moves to `.raw/captured/`.

**The migration**, in the same bundle (repair and re-read bundles; a first
ingest has no old record):

1. Remove the old source record.
2. Add the new record, with `supersedes: <old id>` (`ledgers.py:746-748`) and
   the same `pages`.
3. Rewrite every claim-ledger reference from the old ID to the new one.

The core supplies the old ID, the new locator and the claim references to the
prompt helper, as facts.

**After inspect, the core asserts exactly one source record per
`content_sha256`.** A duplicate sends a continuation that names both IDs.

**Lookups key on `content_sha256`.** Two lookups change:

- **Inbox cleanup** (`inbox-cleanup.ts:49-75`) and **the re-read lookup**
  (`reread.ts:181-201`) find a file's record by its `content_sha256`, not by
  locator.
- A page's `source_path` is the fallback.
- A file whose bytes changed has no match, as before.

**Review.** It shows the archive as one line: "22 originals archived in your
vault (.raw/captured/)". This is information.

**Clean up inbox** then needs no Trash-only path. A file can go when:

- the ledger record found by its sha256 has a locator under `.raw/captured/`
  that exists and hashes the same;
- its pages exist;
- the coverage index says `full` for that sha256.

The inbox file then goes to the Trash, as today, and the original stays in
the vault. Files of older batches that have no `.raw` copy stay, with "not
archived yet". They become ready after the repair (section 6), whose bundle
archives them.

**The words.**

| Where | Words |
| --- | --- |
| Button | "Clear inbox · 21 files" |
| Dialog title | "Clear 21 files from inbox?" |
| Dialog body | "Their originals are archived in your vault (.raw/captured/), byte for byte, and are never changed or deleted. The inbox copies go to the Trash." |
| Primary button | "Clear 21 from inbox" |
| Stay reason | "not read in full yet" |
| Stay reason | "not archived yet" |

**Re-reads find their sources** by `content_sha256` → `.raw/captured/`.

**Option A is the owner's decision** (2026-10-05, `decisions.md`).

## 5. Pages that reflect the source

### Detail level, per source type

**`settings.detailLevel`**: `{meeting, conversation, research, other}`. Each
is one of:

| Level | Meaning | Rough size |
| --- | --- | --- |
| **Highlights** | key points, decisions, actions | about 5% of the source text |
| **Detailed** | below | about 15–25% |
| **Near-complete** | every topic, near the source's own wording, minus small talk | about 40–60% |

**Detailed is the default for meetings.**

**Settings → Batching → "How much of each source goes into its page"** has one
row per type.

The detail level goes to the prompt helper (owned by `reread-sources`) as a
per-source instruction and the format below.

### Meeting format (Detailed)

A meeting's source page has:

- Summary;
- Key points;
- Decisions, each with who decided and why;
- Actions, each with owner and due date;
- **Discussion, by topic.** For each topic: what was proposed, objections,
  the reasons given, numbers, dates and names. Speaker attributions are kept
  where they matter.
- **Open questions**;
- People.

### The skill's compilation-value gate

`SKILL.md:75-79` pushes source pages to be short: "A concise, searchable
source may need only its source/ledger record … do not paraphrase merely to
create pages". That conflicts with a detail level. **Both are done:**

**Distill's prompt overrides the gate for the source page.** The
`reread-sources` helper states:

- The detail level the owner chose is the requirement for each source page.
- The compilation-value gate still decides **which concept and entity pages**
  are created or expanded.
- The gate never shortens the source page below the chosen level.

Why both: the prompt binds Distill today, and only the prompt can carry a
per-source level the owner picked.

**The skill is reworded too**, so other hosts behave the same (section 7).

The core has no page-size or format limit to fight:

- `transaction inspect` checks address front matter (`transaction.py:2789`).
- A file may be up to 64 MB.

### Deterministic checks (always, before Review)

These run after coverage reaches 100%.

- **Partial wording.** The core scans each source page draft, and the bundle's
  `wiki/log.md` and `wiki/hot.md` writes, for wording that says the source was
  not fully read:

  ```text
  \bpartial\b
  \bnot (?:been )?read\b
  \bread only (?:up to|the first)\b
  \bonly read (?:for|the)\b
  \bfirst \d+ (?:lines|minutes)\b
  \btranche\b
  ```

  A match triggers a continuation: "All lines of X were read; drop the
  partial wording and update the page from lines …".

  **It never escalates to a hard stop.** The source *was* read. If the
  wording survives the continuations, Review shows the line "The page for X
  still calls itself partial, though every line was read", as information.
- **The page changed.** After a continuation that read new lines, that page
  draft's sha256 must change.
These continuations count toward the 3.

**No size floor gates.** Size is a weak signal. The owner's complaint page
(2,824 of 23,750 bytes, 11.9%) would pass a 10% floor, and a 20% floor would
fail good pages built from repetitive transcripts. The detail pass decides
instead. The ratio is shown only in the live log's Details.

**The test case for the detail pass is that page:** "the full transcript was
all read", 411 lines, yet information is missing. It must come back with
`missing` items, which then get added before Review.

### The detail pass: automatic, before Review

**What it is.** A second pass checks that each page reflects its source.

**How it works.**

1. A **separate, tool-less call** takes the copy, section by section, and the
   page draft. It returns structured output, `missing: [{lines, kind,
   what}]`.
   - **Runner and egress.** It runs on the **ingest runner's own provider**:
     Claude Code, with a small model (Haiku), no tools, a JSON schema and no
     session.
   - It never runs on the `labelSuggest` runner. That can be OpenRouter or
     OpenAI, which would send whole transcripts to a provider the batch never
     used.
   - So the pass adds no new egress.
   - It gets the job's `controller.signal`, so Cancel stops it.
   - To verify at build time: `--tools ''` together with `--json-schema`.
   - `kind` is one of: decision, action, proposal, objection, number, date,
     name, open question.
   - It lists only what the detail level expects and the page lacks.
   - It ignores small talk and repeats.
2. If `missing` is not empty, **one automatic continuation** of the batch
   session says, for example: "Add these to the page of X: lines 210–260:
   the latency numbers Polaris vs the Node BE, Aditya's objection…".
   The session then rebuilds and re-inspects.
3. The pass runs once more. Its result is **information** in Review: "Detail
   check: all 14 topics on the page", or "2 items not on the page: … (left out
   as small talk)".
   - A second miss never blocks: the skill's compilation-value gate makes a
     left-out section legitimate.
   - It never loops.

**Cost.**

- The pass reads about 1.1 × the source tokens on a small model, twice.
- The continuation adds a few turns in the batch session, at about $0.2.
- For the owner's 22 notes (about 230K tokens) that is about 0.5M small-model
  tokens. That is cents per transcript on a small model, against about $2 for
  the batch.

**Where it runs.**

- It runs per source, 3 at a time, as labels do.
- It shows in the live log as "Checking each page against its source · 4 of
  6".

## 6. Repairing what is already there: automatic

**When.** The scan runs at core start (once a day per vault) and after each
applied batch.

**What it finds.** Every source-ledger entry (`origin.kind: file`) whose
`content_sha256` has **no `full: true` record** in the coverage index:

- Prose markers are not used, because they can't be detected reliably.
- On the owner's vault that is **all 22** (and the 23rd note once batched).
  Simply re-reading them all is the repair.

**Finding the bytes.**

1. `.raw/captured/<sha>.*`.
2. Otherwise the locator, if it still hashes the same.
3. Otherwise the source is "original missing": it is logged and not queued.

**Queueing.** The scan calls `rereadSources({ files, tokenBudget, reason:
'repair' })`. `tokenBudget` is a new parameter that replaces `perBatch`, and it
packs files with the same budget as normal batches.

- **One batch at a time. The next starts when the previous one applies**, not
  when it reaches Review. So no repair bundle goes stale against another one,
  and each needs one approval.
- Each batch passes every gate above.
- Its bundle replaces the source page, archives the original into
  `.raw/captured/` and migrates the ledger record (section 4).

**Back-fill from every job with stream turn files.** At first start, the
build computes coverage from the saved `turn-*.json` of every past job whose
turns ran with stream-json. It uses the same parser and the same session
rule, and records the full-read results in the coverage index. The repair
then re-reads only what is still uncovered.

**What is on the owner's vault now:**

- **`reread-20261005-124520-4eb8`**: the remaining 19 notes, in 4 groups
  (5/5/5/4), with stream-json. It was started by the owner on the current
  build.
- **`job-20261005-123403-ddeb`**: the owner's own 10-05 batch of 3 notes. It
  was sent a reply to read everything in full before approval.
- Both are back-filled like any other job. A note they read in full is not
  read again.
- The "19 sources, 3 batches" below is the case where nothing had been
  re-read. The real repair is whatever stays uncovered after the back-fill.

**The first case, kept as an example.** The re-read group 1, job
`job-20261005-123916-df39`:

- 3 notes, 100% covered (checked by the reviewer from its stream);
- the build back-fills those 3 into the coverage index from its saved turn
  files, so they are not read again.

The repair then covers the **other 19**. At about 270K tokens, that is **3
batches**.

**Never twice.** Attempts are recorded in `<state>/repair.json` by sha256. A
source is repaired automatically once. A repair that ends stopped becomes a
hard stop.

**No click starts it.** The owner approves each repair in Review, as with any
change: the approval gate stays.

**Activity:** "19 sources weren't checked for a full read; reading them again
in 3 batches, each after the one before is added" (`batch.repair_queued`).

## Building on the re-read entry point

The `reread-sources` work built this, as of `0330342` and `455b6e1`:

- **The entry point.** `rereadSources(req)`, `POST /v1/batches/reread` and
  `distill batch reread`.
  - It takes `{files | jobId, perBatch (default 3), vaultPath?,
    instruction?}`.
  - Each group becomes its own ingest job, with a fresh session and `files`
    set directly. Nothing is claimed from the queue.
  - Groups run one at a time per vault.
  - `job.reread` records it. Waiting groups are kept in
    `<state>/reread.json`.
- **The prompt.**
  - `FULL_READ_PROMPT` is in every ingest prompt.
  - Per-file facts go in `RereadFacts`, which is `JobContext`'s 5th argument,
    and are rendered by `rereadSourceLine`.
  - Ingest turns always stream.

This design calls it with no click, for **repair** (section 6) and for **Try
again** on a hard stop (`perBatch: 1`).

**Additions to ask for.** These are additive, in `RereadRequest`, `JobReread`
and `RereadFacts`. Prompt text stays with `reread-sources`.

1. `reason: 'repair' | 'retry' | 'manual'`, so Activity and the repair record
   can tell the cases apart.
2. **Archived paths in `files`.** `inboxFileProblem` must accept
   `.raw/captured/<sha>.<ext>` when the ledger maps that sha256. After Option
   A, a source's only copy may be in the archive.
3. **`sections` and `readingCopy` in `RereadFacts`.** All ingest gets them,
   not only re-reads.
4. **`detailLevel` per source.** The detail level reaches the prompt this way.
5. **`tokenBudget`** in place of `perBatch`, for packing (section 6).
6. **Ledger facts** for the migration (section 4): the old ID, the new locator
   and the claim references.
7. **Lookup by `content_sha256`** in `reread.ts:181-201`, with `source_path` as
   the fallback.

These are kept from `reread-sources` (the build owns them now):

- A missing file still fails by name. This also holds for `.raw/captured/`
  paths.
- A new `decisions.md` entry replaces the group size of 3 with the token
  budget.
- "Name them in skipped" comes out of the long-line fact, with matching
  `reread.test.ts` edits.

**Not used for splitting.** A split stays inside the same job as an `unread`
part (section 3), because the covered sources must reach Review together with
their own bundle.

## 7. The skill, for other hosts (proposed wording)

Distill relies on the core. Other hosts follow the skill, so it should stop
asking for tranches.

**`SKILL.md:29-31`.** Replace "For a large batch, choose a bounded first
tranche instead of promising exhaustive processing." with:

> The source budget is the full text of every in-scope source. If the batch
> will not fit in one session, split it into batches that do, and read every
> source of a batch completely. Never sample a source or read only its
> beginning.

**`:83` (Analyze, step 5).** Replace it with:

> Read each in-scope source completely, in consecutive sections when it is
> long, and check that the last line came back: a tool can cut a read
> without an error. Label a result partial only when part of it truly cannot
> be read (unreadable bytes, unsupported media), with the exact missing range
> and why; never because of budget.

**Also needed:** "A re-read of a source replaces its existing page; do not
skip it as unchanged input" (step 1).

**`:75-79` (the compilation-value gate, Analyze step 3).** Keep the gate for
canonical pages, and stop it from thinning the source page. Proposed:

> Apply a compilation-value gate to canonical pages: create or expand a
> concept, entity or synthesis page only when the source adds durable
> synthesis, navigation, a decision or a reusable connection. The gate does
> not shorten a source's own page. That page records what the source says
> at the detail the user asked for (by default, for meetings and
> conversations: decisions, actions, and each topic's proposals, objections,
> reasons, numbers, dates and names), so a reader need not open the source.
> A short, already-searchable source may still need only its ledger record.

These are claude-obsidian product changes. They need `make test` and the
skills reviewer.

## Visible parts (canvas: FullRead)

- **Live log.** A "Reading in full" phase:
  - "Read in full · 18 of 22 sources";
  - "Not read yet: lines 111–647 of “Tomasz and Jin” and 3 more";
  - "Asked Claude to read what was left · round 1 of 3";
  - "Checking each page against its source";
  - "2 sources go to a fresh session: this one ran out of room".

  Details shows the line ranges.
- **Queue card.** "Batch 1 of 3 · 9 sources · about 96K tokens · about $2.6 at
  list price", then "Next batch starts when this one is ready for review".
- **Review.** These lines are information:
  - "Read in full · 20 of 20 sources · 9,412 lines · counted from Claude's
    reads";
  - "Detail check: …";
  - "22 originals archived in your vault";
  - each source row's "647 lines · read in full";
  - the part notice for unread sources.
- **Hard stop.** The "Not added · couldn't be read" group, and Queue's "Held
  in inbox/".
- **Settings → Batching:** Batch size and detail level.
- **Clean up:** "Clear inbox", with its archive wording.

## Contract (proposed, additive; `contracts.ts` is the lead's)

| Area | Addition |
| --- | --- |
| Settings | `batchSourceTokens?`, `detailLevel?`, plus a cached `modelContext` per model id |
| Job | `coverage?`, `stopped?: {file, reason, words}[]`, `batchOf?: {index, total}`, `detailCheck?` |
| PendingPart | reasons `covered` and `unread`; the gate skips `covered` |
| runTurn | option `autoContinue` |
| Runner | capability `readCoverage` |
| JobStep | verbs `coverage`, `continue`, `detail`, `stop` |
| API | `GET /v1/jobs/:id/coverage` (ranges for Details); `POST /v1/batches/reread` takes `tokenBudget` and `reason` |
| Activity | kinds `batch.read_stopped`, `batch.repair_queued` |

## Open questions

Settled by the reviewer and the CLI check (2026-10-05):

- **Stream fields.** `tool_use_result` and `modelUsage[…].contextWindow` are
  verified. `compact_boundary` is not verified in `-p`, so the design works
  without it.
- **Repair.** It packs by token budget, and the next batch starts when the
  previous one applies.
- **Stale overflow batches** keep rebuilding.
- **Unread sources** start after the covered part applies.
- **Image text** comes later.
- **Cost** shows as an estimate at list price, or as tokens.
- **The owner's decisions:** Option A, and Codex deferred.

Still open:

1. **Compaction in `-p`.** Is the 60% usage-drop threshold right? It needs one
   long solo batch to calibrate.
2. **PDF `pages` reads.** Does Read's result report which pages it returned?
   This is unverified, so PDFs are credited only on a result that names its
   pages.
3. **The `--tools ''` and `--json-schema` combination** for the detail pass,
   checked at build time.
