---
type: meta
title: Distill Spec Index
status: developing
created: 2026-10-01
updated: 2026-10-01
tags:
  - meta
  - index
---

# Distill Spec Index

One spec per feature of the Distill app (`apps/distill`). Each spec states
its `status` in frontmatter:

- `built`: shipped in the app; the spec describes current behavior and code.
- `designed`: agreed on the design canvas, not implemented yet.

Update the spec in the same change that alters a feature's behavior, and
flip `designed` to `built` when it ships. Visual design lives on the canvas:
https://claude.ai/artifact/VSqHFPZjcqY2bMqFEnPqpG

## Architecture (designed)

- [Architecture](architecture.md): core (Node + TypeScript) owning all state, CLI, agent plugin, and thin clients (macOS today, web/mobile later); API sketch, rules, build order.

## Core worker (built)

- [AI runners](ai-runners.md): pluggable runner structure, per-task runner/model/effort, capability rules (Settings UI designed).
- [Claude runner](claude-runner.md): how `claude -p` is invoked, sessions, resume, structured output.
- [Approval and review](approval-and-review.md): two-phase runs, the approval gate, approve/reply/allow/reject, recovery.
- [Queue and batching](queue-and-batching.md): queue folder, settle delay, schedule, moving files into the vault inbox.
- [Intake: paste and drop](intake-paste-drop.md): how dropped files and pasted screenshots/text enter the queue.
- [Vaults and settings](vaults-and-settings.md): vault profiles, stored settings, validation.
- [Job kinds](job-kinds.md): the extension point for new kinds of work.

## App surfaces (built)

- [App shell and visual design](app-shell.md): windows, sidebar sections, theme tokens, settings screen.
- [Floating icon](floating-icon.md): the always-on-top flask, states, click/drag/drop.
- [Headless and snapshot modes](headless-and-snapshot.md): `--run-once` and `--snapshot`.
- [Tooling](tooling.md): build, install, control script, `/distill` skill, tests.
- [Ask](ask.md): question answering over the vault with model, effort and optional filters (core and macOS screen).
- [App icon](app-icon.md): the Dock/Finder icon, drawn in SwiftUI and built into `AppIcon.icns`.

## Designed, not built

- [Write a note](notes-composer.md): text notes with images (keep vs. extract text), source and labels.
- [Labels and sources](labels-and-sources.md): taxonomy, AI label suggestions, filter semantics, Notes screen backfill.
- [Quick actions and shortcuts](quick-actions.md): hover menu on the flask, quick windows, user-recorded shortcuts.

