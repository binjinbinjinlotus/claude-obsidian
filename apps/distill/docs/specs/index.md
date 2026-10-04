---
type: meta
title: Distill Spec Index
status: developing
created: 2026-10-01
updated: 2026-10-02
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

## Architecture

- [Architecture](architecture.md): the Node + TypeScript core owns all state and serves a local API (token, lock file, events); the CLI, agent plugin and macOS app are clients.

## Core

- [AI runners](ai-runners.md): Claude Code, Codex, OpenAI, OpenRouter and Vercel AI SDK; per-task runner/model/effort; Keychain secrets.
- [Claude runner](claude-runner.md): how `claude -p` is invoked, isolation flags, sessions, resume, structured output.
- [Approval and review](approval-and-review.md): two-phase runs, the approval gate, core-applied transactions, recovery.
- [Queue and batching](queue-and-batching.md): queue folder, 10-minute settle wait, schedule, inbox moves, progress steps; folder items, .gdoc items that wait, the queue scan (Refresh and the periodic check; core, API, CLI built).
- [Job kinds](job-kinds.md): ingest and labels; the extension point for new kinds of work.
- [Vaults and settings](vaults-and-settings.md): vault profiles, stored settings, validation.

## Features

- [Ask](ask.md): answers from the vault with citations; label/source filters (Any/All, unconfirmed), history, Stop.
- [Write a note](notes-composer.md): text notes with images inside the text (hover → Extract content), source, and the label step.
- [Actions](actions.md): to-dos and action types (Slack, Jira, Confluence, …) found in processed notes and Ask answers; confirm, draft, improve, handlers, History, connections. Core, API, CLI and macOS UI built (selection bar for selected answer text not yet).
- [Markdown editing](markdown-editing.md): Markdown in note, question and reply inputs; style bar, selection bubble, links and the `[[` note picker, shortcuts, paste.
- [Labels and sources](labels-and-sources.md): taxonomy, AI suggestions, confirmation through Review, the Labels screen.
- [Collectors](collectors.md): built-in (Folder) and custom-script collectors that fill the queue on a schedule; ledger and dedupe, cron schedule, script contract, consent. Core, API, CLI and macOS UI built.
- [Activity log and trash](activity-log.md): what changed, when and from where (app, CLI, agent, scheduler) for chats, collectors, actions, batches, the queue, connections and settings; deletes of chats and collectors go to a 30-day trash with Restore. Core, API and CLI built; Mac UI designed (History → Activity).
- [Intake: paste and drop](intake-paste-drop.md): how dropped files and pasted screenshots/text enter the queue.

## macOS app

- [App shell and visual design](app-shell.md): windows, sidebar sections, theme tokens, loading states.
- [Floating icon](floating-icon.md): the always-on-top flask, states, hover menu, click/drag/drop.
- [Quick actions and shortcuts](quick-actions.md): quick ask and quick note windows, recorded global shortcuts.
- [App icon](app-icon.md): the generated .icns.
- [Headless and snapshot modes](headless-and-snapshot.md): `--snapshot` renders; headless runs moved to the CLI.
- [Tooling](tooling.md): build, install, control script, `/distill` skill, tests.

## Data and process

- [User data](user-data.md): where settings and history live, why updates never lose them, backups and restore.
- [Design process and design system](design-process.md): canvas first, shared components, one-to-one mapping to the Swift views.
- [Decisions](decisions.md): dated log of product and technical decisions and why.
