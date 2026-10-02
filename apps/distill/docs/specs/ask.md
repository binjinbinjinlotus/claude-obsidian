---
title: Ask
status: designed
updated: 2026-10-01
---

# Ask

Ask questions answered only from the active vault, with citations. Canvas
artboards: "Ask", "Quick actions from the floating flask".

## Behavior

- New sidebar section **Ask**; also reachable from the flask's hover menu as a
  quick window (see [Quick actions](quick-actions.md)).
- Each question runs `claude -p` with the `claude-obsidian:wiki-query` skill,
  read-only tools only. Follow-ups resume the same session; **New chat** starts
  a new one.
- Answer shows numbered citations, source cards (page title, source, labels;
  click opens in Obsidian), and a **Gap** note when the vault does not cover
  part of the question.
- **Save answer to vault** starts a normal job (the `save` skill) that goes
  through Review. **Copy** copies the answer.
- **Model** picker and **Effort** switch (Low / Medium / High / Max) per
  question. Effort maps to `claude --effort` (`low|medium|high|xhigh|max`).

## Scope

- Default: **all notes**. Filters apply only when the user adds them
  ("+ Limit by label", "+ Limit by source"). Semantics in
  [Labels and sources](labels-and-sources.md).
- When filtered, the app computes the matching pages itself and allows Claude to
  `Read` only those paths, so the limit is enforced, not just requested.

## Open questions

- Effort default (proposed: Medium).
- Whether past conversations are kept in History or only a short recent list.
