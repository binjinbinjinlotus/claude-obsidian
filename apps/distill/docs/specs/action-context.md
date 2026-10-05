---
type: spec
title: Action context (raw source + wiki)
status: built
created: 2026-10-05
updated: 2026-10-05
tags:
  - distill
  - actions
  - batches
---

# Action context: actions found in the batch, from the original and the wiki

Build status: **built 2026-10-05** (core, HTTP API, CLI, macOS UI). The owner
said "please design and build directly"; the five decisions below took their
recommended defaults as the owner's pre-approval.

| Part | Where |
| --- | --- |
| Locating lines, windows, wiki sections, closest lines, originals | `core/src/actions/context.ts` |
| The job's side file and the window prompt | `core/src/actions/batch.ts` |
| The pass, commit per part, dedupe, Ask context, draft context | `core/src/actions/index.ts` (`findForReview`, `findInJob`, `commitJob`, `jobActions`, `askContext`, `draftContextFor`) |
| Hooks | `engine/index.ts` `onReviewReady` (in `requestDecision`), `onJobEnded` (in `mutate`); composed in `core/src/index.ts` |
| API, CLI | `GET /v1/jobs/:id/actions`; `distill actions found <job-id>` |
| Mac | `DistillKit/ActionContext.swift`, `Distill/ActionPreview.swift`, `Distill/ReviewActionsFound.swift`, `SnapshotActionContext.swift` |
| Tests | `core/src/actions/context.test.ts`, `actions.test.ts`, `e2e.test.ts`, `server/http-actions.test.ts`, CLI; `Tests/DistillKitTests/ActionContextTests.swift` |

**How the build differs from the design above, and why.**

- The side file is `<job dir>/actions-found.json` (not `actions.json`, so it
  is never mistaken for Distill's own `actions.json`).
- Wiki refs are computed when the pass runs, from the change's page drafts;
  they are not read again at commit.
- A source not looked through in full is **tried again by itself when the
  batch applies** (a failed window, or Distill quitting mid-pass: a pass that
  isn't running any more shows as failed). After that it shows as failed with
  Try again, naming the lines.
- The progress key in Review is `actions:job:<id>` (kind `actions`); the
  post-apply pass for older jobs keeps the job id and the batch steps.
- `JobActionsSummary.lines` is updated after each window, so Review's strip
  counts lines as they are looked through.
- Not built: Ask's found rows don't use the new preview yet (they keep their
  own rows; the item detail shows the context).

Actions (to-dos, Slack, Jira and Confluence items) are found **inside the
batch, before Review**. Every line of every source is looked through. Each item
points at the exact lines of the original (`.raw/captured/…`) and at the wiki
pages and sections it relates to. Drafts are written from those lines plus that
wiki context, never from the first 12,000 characters of a note.

> "a lot the detail are removed after added to the wiki, then the item in the
> action become unreadable and difficult to understand. so in the batch it
> doing two thing: create the todo item based the file it is current
> processing + with the info in the wiki; adding the file to the wiki. then
> source of the action should be point to the raw source … and the additional
> info from the wiki." (the owner, 2026-10-05)

> "I want to know what it is going to create before I hit Create draft." (the
> owner)

Canvas: row 12, board **ActionContext** (`design/screens/actioncontext.json`).
Related specs: [Actions](actions.md), [Full reads](full-read.md),
[Approval and review](approval-and-review.md), [Ask](ask.md).

## What was wrong

- Finding ran **after apply** ("Finding actions"). `documentsForJob` cut each
  document at 12,000 characters and the batch at 60,000, and skipped what did
  not fit. The owner's meeting transcripts reach about 130 KB, so most of a long
  meeting was never looked at for actions, with no word about it. That breaks
  the owner's rule that nothing is missed silently.
- A batch applied in parts was searched once: `processedJobs` records the job
  id, so part 2's sources were never searched.
- An item's only context was one quoted sentence and a link to the note. The
  wiki page that note became is a summary, so the item read as a fragment.
- The draft prompt cut the note at 12,000 characters too: a line at minute 50
  of a meeting was not in the draft's context.

## 1. Where finding runs

**A separate pass, run by the core, inside the batch** (decision 2026-10-05,
pre-approved). When a batch reaches Review (its plan is valid), the core starts
"Finding actions" in the background. Review opens at once; its "Actions found"
section fills when the pass ends.

**Why not the ingest session itself** (the rejected alternative):

- The AI's own list can't be checked for what it left out. A core-fed pass is
  complete by construction: the core sends every line and records the ranges.
- The ingest session already carries the gate's continuations (at most 3); a
  second job in it would compete for that budget and for context.
- It would need a second untrusted output from the session (a side file the
  AI writes), with its own validation and retries.

The pass still combines the two things the owner asked for: the **original's
lines** (the reading copy, every section) and **the wiki** (the source's page
draft from this batch's bundle, plus the list of pages the change writes).

### How a long source is covered completely

- The text is the batch's **reading copy** (`<job dir>/read/<n>.md`,
  [Full reads](full-read.md) section 1): copy line n is source line n, images
  are one placeholder line, a long line's pieces sit after the last line as
  `L<n>↪ …`. A job without a copy (older jobs, Try again) gets one made the same
  way into `<job dir>/actions/read/`.
- The copy's planned sections are grouped into **windows of at most 24K tokens**
  (about 62 KB of text), in order. A 130 KB transcript (about 100 KB of text
  once images are placeholders) is 2 windows. Every window is one tool-less,
  structured run.
- Each window is sent with its line numbers (`210\t…`), the source's page draft
  (the wiki context, at most 12,000 characters), and the paths and titles of
  the pages the change writes.
- The core records each window's range. The union must equal every line of the
  copy; a window that fails is tried once more, then the source is marked
  failed with its reason ("lines 401–812 weren't looked through: …"), never
  dropped silently.
- 3 windows run at a time. Review shows "Looked through 9,412 of 9,412 lines".

### Runner and model

The pass uses Settings → Actions → **Model for finding actions**
(`findSelection` → `taskDefaults.actionFind` → Claude Code · Sonnet · medium).
**When that runner is not the batch's own runner, the pass runs on the batch's
runner with the same model id when it has one, else its default model**, so a
whole transcript never goes to a provider the batch didn't use (decision
2026-10-05, pre-approved). The old post-apply step sent up to 60 KB per batch
to the `actionFind` runner; the new pass sends every line, so the egress rule
matters more.

Cost, expected: about 1.1 × the sources' tokens as input. On Sonnet that is
about $0.35 for a 100K-token batch, against about $2.6 for the batch.

### Where found items live before apply

`<job dir>/actions-found.json` (the job’s side file, never the vault, never
`<state>/actions.json`):

```json
{
  "version": 1,
  "sources": {
    "inbox/2026-09-30 Tomasz _ Jin.md": {
      "sha256": "…", "page": "wiki/sources/Tomasz and Jin 2026-09-30.md",
      "status": "done", "lines": 812, "looked": [[1, 412], [413, 812]],
      "model": "Sonnet", "at": "2026-10-05T09:22:10Z"
    }
  },
  "proposals": [
    { "item": { "id": "act-…", "type": "jira", "status": "pending", "title": "Cap payment client retries at 3", "…": "…" },
      "file": "inbox/2026-09-30 Tomasz _ Jin.md", "page": "wiki/sources/Tomasz and Jin 2026-09-30.md",
      "state": "waiting" }
  ]
}
```

Nothing outside Distill's state changes before approval: no vault write, no
`actions.json` item, no Jira or Confluence call. Jira and Confluence creation
stays the owner's click on the item.

### When items enter Actions

- **Apply** (every part): the core commits the proposals whose source page is
  in an applied part (`job.parts[].pages`; a batch with no parts: every source
  of the applied plan). Commit runs `addFound` with the dedupe below, so
  `state` becomes `added` or `duplicate`. It is idempotent: it runs on every
  apply and again when a pass finishes after the apply.
- **Confirm on** (default): added as `pending`, in To confirm. **Confirm off**:
  added as open / ready, drafts start, and the "Added … · Undo" toast shows.
- **Reject**: nothing is added. Proposals become `notApplied`; the side file
  stays with the job directory.
- **Part of a batch**: only the picked sources' proposals commit. A removed
  source's proposals become `notApplied`. The rest commit when their part
  applies.
- **A split** (`covered` / `unread` parts): the pass runs on each part's
  sources when that part reaches Review; a source is looked through once per
  job (keyed by file and sha256).
- **A rebuild after a reply or a label change**: the found items stay (they
  are keyed by the source, not the bundle); their wiki refs are the drafts'
  sections when they were found.
- **Re-reads and repair batches** find actions like any batch. The dedupe
  stops repeats (below).

### Dedupe across batches

The existing rules stay (same source note and quote; same 24+ character quote
from any note; same normalized title and type among live items; dismissed in
the same Ask chat). Added, because re-reads and repair read the same content
from `.raw/captured/<sha>.md` instead of `inbox/…`:

- **Same content**: an item in any status (also done, removed, sent,
  dismissed) whose `raw.sha256` equals the new item's, with the same type and
  overlapping line ranges, or the same normalized quote, is the same action.
- **Older items without `raw`** (found before this design): their note path's
  file, when it still hashes to the new item's sha256, or their quote located
  in the new original's text, gives them the same line range for the check.
- Within one pass only the title rule applies, as today ("book the room and
  tell Mei" is two actions on one line). Across windows of one source, items
  with overlapping lines and the same type and title are one.

### After apply, for older jobs and Try again

`findInJob` (after apply) keeps working for jobs that have no side file (they
reached Review before this build) and for Try again. It runs the **same
windowed pass** over the job's sources, read from `.raw/captured/<sha>.*` or
their inbox path, with the changed pages as wiki context. The 12,000-character
cut and the 60,000 limit are gone. A source whose original can't be found is
named in the summary ("1 source's original is gone"), never skipped silently.

## 2. Each item carries the original and the wiki

Additive fields on `ActionItem.source` (both `note` and `ask` kinds):

| Field | What |
| --- | --- |
| `raw.path` | `.raw/captured/<sha>.<ext>` once archived (the batch's bundle archives it, [Full reads](full-read.md) section 4), else the inbox path |
| `raw.inboxPath` | where the source was when found |
| `raw.sha256` | the original's content hash (lookups and dedupe key on it) |
| `raw.lines` | `[from, to]`, 1-based, inclusive, in the original |
| `raw.excerpt` | those lines' text, at most 1,500 characters |
| `raw.match` | `quote` (the quoted words were found on these lines), `closest` (Ask: the lines sharing the most words), `none` (no match; no lines) |
| `wiki[]` | `{path, title, heading, excerpt}`: the pages and sections it relates to (excerpt at most 800 characters) |
| `contextNote` | plain words for a missing `raw` ("the cited pages have no archived original") |

**The lines come from the core, never from the model.** The model returns its
quote and the window's line numbers it saw. The core searches the copy for the
quote (normalized: case, quotes, punctuation and spacing ignored), first in the
lines the model named ±3, then in the whole copy. An appendix line `L<n>↪ …`
maps back to source line n. A quote that can't be found keeps the item, with
`match: none` and no lines; the preview then says "Quote not found in the
original" and shows the model's quote as the model's words, not as the
original's lines.

**The wiki refs are checked too.** A `wiki[].path` must be a page the change
writes or a page that exists; a `heading` must be a heading of that page; a
ref that fails either is dropped. The source page itself is always the first
ref (section: the heading whose text holds the quote, when one does).

**At commit**, `raw.path` is pointed at `.raw/captured/<sha>.*` when it exists
and hashes the same; otherwise it stays the inbox path. When the owner opens
it, the app tries the archive, then the inbox path, then shows "The original
is gone".

### The draft prompt

`buildDraftPrompt` gets a context, not a truncated note:

- `<original path="…" lines="190–240">`: the item's lines ±25 lines (at most
  12,000 characters, centred on the lines), read from `raw.path` (archive,
  then inbox); `raw.excerpt` when the file is gone.
- `<wiki path="…" heading="…">`: each wiki ref's section (at most 4,000
  characters each, up to 3), read from the vault; the stored excerpt when the
  page is gone.
- An older item (no `raw`): its note's text in a window **centred on the
  located quote** (at most 12,000 characters), not the first 12,000.

## 3. Actions from Ask

Ask answers come from the wiki only. After detection, the core attaches raw
context to each found item:

1. For each cited page (in order): the source-ledger records whose `pages`
   include it, or the page's `source_path`, give the original's sha256.
2. The original is `.raw/captured/<sha>.*`, else the ledger locator when it
   still hashes the same.
3. In that original, the **closest lines**: the window of 8 lines that shares
   the most distinct words (4+ letters) with the item's title, quote and why.
   It counts only when at least 40% of those words are on it. Then `raw.match
   = closest`, shown as "Closest lines in the original", never as a quote.
4. The cited page's section with the most shared words is the `wiki` ref.

When no cited page has an archived or still-matching original, or no lines
reach 40%, the item is **wiki only**: `raw` is absent (or `match: none` with
the path, when an original exists), `contextNote` says why, and the draft uses
the wiki sections only. The preview says "Wiki only · the cited pages have no
archived original" (decision 2026-10-05, pre-approved).

## 4. Data model and migration

- All new fields are optional and additive. `decodeSource` reads them
  leniently (a wrong-typed field is dropped; `lines` must be two positive
  integers, from ≤ to). Unknown keys inside `source` survive a save now (the
  raw source object is merged on encode), so a later build's keys aren't lost.
- Existing items keep working: no `raw` means the old FROM block, and drafts
  use the quote-centred note window.
- `JobActionsSummary` gains `stage`, `proposed`, `lines`, `linesOf`, `sources`
  and `duplicates`. Old jobs have none of them and read as before.
- New API: `GET /v1/jobs/:id/actions` → `JobActions {summary, proposals}`
  (404 for an unknown job; an empty list for a job with no side file).
  `POST /v1/jobs/:id/actions/find` (Try again) also works for a batch in
  Review: it runs the pass again for its failed sources.
- Swift: `ActionSource` stays a positional enum. `ActionItem` decodes
  `context` (`raw`, `wiki`, `contextNote`) from the same `source` object and
  writes it back on encode.

## 5. What the owner sees

**To confirm row → preview.** The row shows the full title (two lines, no cut)
and "Jira ticket · PAY" / "Slack message · to Mei" / "To-do · due Fri". A
chevron (or a click on the row) expands it in place:

- **Why** (one sentence).
- **From the original**: the source's title, "lines 210–214", the quoted lines
  with their line numbers, and **Open original** (the default app; Obsidian
  doesn't show `.raw/`) and Show in Finder. For Ask: "Closest lines in the
  original" or "Wiki only · …".
- **From the wiki**: page › section, a few lines, **Open page** (Obsidian).
- **Already filled**: the fields with values (project PAY, issue type Task, to
  Mei, due 2026-10-09), and "Not set yet: assignee".
- **What Create draft will write**: "Writes a Jira ticket draft with Sonnet
  from lines 185–239 of the original and 1 wiki section. Nothing is created in
  Jira until you click Create in Jira." For a to-do: "Add puts it in To do as
  it is; nothing is written by AI." For Slack: "… Nothing is sent: you copy it
  into Slack."
- Add / Create draft and × stay on the row.

**Item detail.** The FROM block keeps the source line and adds "Original ·
lines 210–214" with the quoted lines (line numbers in the margin) and "Wiki ·
page › section" with its lines, each with Open. An older item without `raw`
shows the old block.

**Review: "Actions found".** A group under Sources (`ReviewGroupHeader`
"Actions found · 5"):

- while the pass runs: "Looking for actions in 9 sources · lines 1–4,870 of
  9,412" with the loading pattern;
- then one row per proposal (type tile, full title, "Tomasz and Jin · lines
  210–214"), expanding to the same preview;
- a line: "Looked through 9,412 of 9,412 lines. They go to To confirm when you
  approve." (confirm off: "They are added when you approve.");
- a source removed from the batch dims its rows ("Not added: its source is
  left out");
- failed: "Couldn't look through lines 401–812 of “Tomasz and Jin”: <reason>"
  with Try again.

It is information: Approve doesn't wait for it and never depends on it.

**History → Jobs** (`JobActionsLine`): "Found 5 actions · 3 to confirm, 2
already in Actions"; the "after the batch was applied" wording becomes "while
the batch was read".

## Contract (additive)

| Area | Addition |
| --- | --- |
| `ActionSource` (note, ask) | `raw?: ActionRawRef`, `wiki?: ActionWikiRef[]`, `contextNote?` |
| `JobActionsSummary` | `stage?`, `proposed?`, `lines?`, `linesOf?`, `sources?`, `duplicates?` |
| Types | `ActionRawRef`, `ActionWikiRef`, `JobActionProposal`, `JobActions` |
| Engine extra | `jobActions(id)`; options `onReviewReady(job, {pages, written})`, `onJobEnded(job)` |
| API | `GET /v1/jobs/:id/actions` |
| CLI | `distill actions found <job-id> [--json]` (read-only) |
| Job dir | `<job dir>/actions-found.json` (proposals), `<job dir>/actions/read/` (copies made for the pass) |

## Decisions (pre-approved by the owner, 2026-10-05)

1. Finding runs in the batch as a separate pass fed by the core, not inside
   the ingest session.
2. Items enter Actions when their source's pages apply; Review shows them as
   information with the preview.
3. The pass runs on the batch's own runner when the finding model is on
   another provider.
4. Ask actions get the closest lines of the cited pages' archived original, or
   are marked wiki only.
5. Re-reads and repairs find actions too; the content-hash dedupe stops
   repeats, including of done, removed and dismissed items.

## Open risks

- The quote search is exact after normalization. A model that paraphrases its
  quote gets `match: none` (no lines) more often than expected; to measure on
  the owner's next batch.
- Dedupe by overlapping lines can merge two different actions of the same type
  on the same lines; the title rule within one pass keeps them apart, across
  batches the second is held back as a duplicate.
- Ask's closest lines are a word-overlap heuristic: right for a specific
  action, weak for a vague one. They are labelled "closest", and below 40% the
  item is wiki only.
- Cost: whole transcripts are now read for actions (about $0.35 per 100K-token
  batch on Sonnet).
