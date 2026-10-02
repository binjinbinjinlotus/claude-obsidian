---
title: Labels and sources
status: built (core labels; app UI, Notes screen and Ask filters designed)
updated: 2026-10-02
---

# Labels and sources

Two ways to describe a note: **where it came from** (source) and **what it is
about** (labels). Canvas artboards: "Write a note", "Ask", "Settings", "Notes".

## Sources

- Stored on the note as the existing `source_type` property plus an optional
  link/channel/person (for example `#tea-club · with Mei`). No core changes.
- Grouped, editable in Settings → Sources (add, rename, remove, new group).
  Starting set:
  - Discussion: Slack, Meeting, GitHub review, Jira comment, Email, In person
  - Reference: Web page, Document, Paper
  - Personal: Remember this, Idea
- Optional on a note, pre-filled with the last choice (proposed).

## Labels

- Stored as normal Obsidian tags (`tags:`), so they also work in Obsidian search.
  The page's frontmatter is the **only** record of whether labels are
  confirmed (no separate store):
  - `labels_by: ai | user`: who chose them.
  - `labels_reviewed: false`: AI labels not yet confirmed (absent = confirmed).
  - `labels_origin: queue-folder | cli | suggest`: where unconfirmed AI labels came from.
- Labels are normalized everywhere (`core/src/labels/vault.ts`): lower case, no
  `#`, spaces → `-`, only letters, digits, `_`, `-`, `/`; purely numeric values
  dropped; deduped. Labels a caller types (addNote, labelNote, confirmLabels)
  are rejected if they contain whitespace, as the server does.
- Existing labels are read from `wiki/**/*.md` frontmatter (local, free).
  System pages (`index.md`, `_index.md`, `hot.md`, `log.md`, `overview.md`,
  `dashboard.md`, `wiki/meta/**`, `type: meta`) are not notes and are skipped.
- The suggestions appear on the queued item in the Queue screen as dashed chips
  (green = existing, peach = new) with accept ✓ / dismiss ×, plus "Accept all".
  The user can also type any label. (App UI: designed.)
- Settings → Labels (model, on/off, rename/merge) is designed, not built.

### Suggestions (`core/src/labels/suggest.ts`)

- The `labelSuggest` task: `settings.taskDefaults.labelSuggest`, else Claude
  Code + Haiku + effort low. Any runner with `structuredOutput` works.
- One run per note, JSON-schema output `{labels: string[]}`, with the vault's
  existing labels in the prompt (most used first, up to 200). Claude Code runs
  with **no tools** (`--tools ""`, no allow rules) in the empty scratch
  directory `<state dir>/labels/scratch`, so it only reads the prompt.
- Output is normalized, capped at 5, and each label is marked `existing`.
- Suggestions use the note's text, title and source; image text is not read.

### How notes get labels

| Where the note comes from | Labels |
| --- | --- |
| Distill app (`addNote`, origin `app`, suggest `background`) | The note is queued, then a `labelSuggestions` event carries the suggestions (and `costUSD` when a call ran). The user confirms with `labelNote(requestID, labels)`. Never confirmed = no labels (no fallback). |
| CLI (origin `cli`, suggest `wait`) | `addNote` returns `requestID` + `suggestedLabels` (+ `costUSD`). The caller may `labelNote` until the batch picks the note up (then `invalid_state`). Nothing confirmed and `labeling.cliFallbackToAI` (default on) → the AI labels apply unconfirmed, `labels_origin: cli`. |
| `labels` on addNote | Confirmed (`labels_by: user`); no suggestion is made. |
| `labelNote(requestID, [])` | Confirmed: no labels. No AI fallback, no flags. |
| Any other file in the queue folder | `labeling.autoLabelQueueFolder` (default on): the batch suggests labels for text files (`.md .txt .html .csv .json` ...) before the first turn, applied unconfirmed with `labels_origin: queue-folder`. A dropped `.md` that already has `tags` keeps them as the user's choice (no AI call). Binary files (PDF, images) and failed suggestions stay unlabeled. |

While a note's suggestion runs (wait or background) the core emits
`labelSuggest` progress keyed `note:<requestID>` (runner and model of the
`labelSuggest` task), ended by one `finished` event (with `error` when the
suggestion failed).

The batch passes each input's labels to the ingest turn (see
[Queue and batching](queue-and-batching.md)); the agent writes them on the
source page built from that input.

### Labels screen (core API)

- `labelReview()`: `toReview` = pages with `labels_reviewed: false` (with
  origin); `unlabeled` = note pages under `wiki/` with no tags.
- `listLabels()`: every label with `count` and `unconfirmed`.
- `suggestLabelsForPages(paths)`: AI labels for existing **unlabeled** pages,
  written with `labels_by: ai`, `labels_reviewed: false`,
  `labels_origin: suggest`.
  - Pages that already have tags are skipped before the job starts; the first
    turn says how many (`Suggest labels for 2 pages. Skipped 1 page that
    already has labels.`) and the review lists them under skipped. When every
    page has tags: `invalid_request`, no job.
  - It returns the job at once in `running`. Suggestions run one page at a
    time with `labelPages` progress (key = job id, `done`/`total`), then
    "Preparing the change for Review" while the bundle is built and inspected;
    the job moves to `awaitingApproval` (a `job` event) and the progress
    finishes.
  - `cancel(id)` while suggesting keeps the pages that finished: with at least
    one, the bundle is built from them (the rest are listed as `not done
    (stopped)`) and the job awaits approval; with none it is `cancelled`.
  - A job interrupted by a quit while suggesting has no plan yet; after
    recovery it can only be rejected (run it again).
- `confirmLabels(items)`: writes exactly the given tags with `labels_by: user`
  and removes `labels_reviewed` / `labels_origin` (empty list = no labels).
- Both return a `labels` job awaiting approval; the core builds, inspects and
  applies the transaction itself ([Approval and review](approval-and-review.md)).
  Every other byte of the page is kept.

## Filter semantics (Ask)

- Default: all notes; no filter.
- Choosing a source **group** includes every source in it; choosing a source
  inside the group narrows to it (Discussion + Slack = Slack only).
- Filters of different kinds combine with AND (a label and a source must both
  match). Several labels: proposed OR within labels (to confirm).
- Exact for single-source note pages; a synthesized page that merges several
  sources matches if any of its sources match.

## Backfilling older notes (Notes screen)

- New sidebar section **Notes** listing the vault's notes with filters
  **Unlabeled**, **No source**, **All**, + Label, + Source, and search.
- For the selected notes Claude suggests labels (reusing existing ones first);
  each row shows source (or dashed "Add source") and label chips to accept,
  remove or add.
- Bulk **Set source…** / **Add label…**, then **Send N notes to Review**:
  metadata edits rewrite notes, so they go through the normal approval gate as
  one transaction.
