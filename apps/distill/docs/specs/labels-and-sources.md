---
title: Labels and sources
status: designed
updated: 2026-10-01
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
- The app reads existing labels from the vault's frontmatter (local, free).
- AI suggestions run **after the note is added to the queue**, so they are
  based on what is actually being added (text, extracted image text, source),
  not on a half-written draft. A short `claude -p` call gets the note and the
  existing label list; it prefers existing labels and marks new ones "new".
- The suggestions appear on the queued item in the Queue screen as dashed chips
  (green = existing, peach = new) with accept ✓ / dismiss ×, plus "Accept all".
  The user can also type any label.
- Model for suggestions: selectable in Settings → Labels, **default Haiku**.
  Suggestions can be turned off there.
- Proposed: suggestions still unconfirmed when the batch runs are kept as
  suggestions in Review rather than applied silently (to confirm).
- Settings → Labels lists labels with counts for renaming/merging.

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
