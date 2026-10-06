---
type: meta
title: Distill Spec Index
status: developing
created: 2026-10-01
updated: 2026-10-05
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
- [Approval and review](approval-and-review.md): two-phase runs, the approval gate (enforced in the core), core-applied transactions, verified applies, recovery; labels in Review, pick and remove sources, Approve, review labels later, approving part of a batch (parts, Discard this part / Reject batch), several batches waiting oldest first.
- [Review queue](review-queue.md): approve several batches and they apply one at a time per vault; after each apply, waiting batches are re-checked, and stale plans are rebuilt (unapproved: before you look; approved: rebuilt, then one more OK); exit 75 reads Updating; bounded self-recovery with its own model (Opus by default); Review's batch tabs become a left list with readable names. Built (canvas row 16, board ReviewQueue; recovery within its bounds (the agent where it can choose, $0 for session-gone, the journal rule for not-recorded), retries only under the approved hash, split and discard as owner-confirmed proposals; the Couldn't fix card with Rebuild, What was tried and Continue in a new session; `distill status`).
- [Queue and batching](queue-and-batching.md): queue folder (`inbox/` create-only), settle wait (10 minutes by default, 0–24 h), schedule, the label gate, inbox moves, progress steps; folder items, .gdoc items that wait, the queue scan (Refresh and the periodic check; core, API, CLI and Mac app built).
- [Job kinds](job-kinds.md): ingest and labels; the extension point for new kinds of work (`core/src/engine/job-kinds.ts`).
- [Vaults and settings](vaults-and-settings.md): vault profiles (the vault marker checked on every use), stored settings, validation; the Settings window (one page per section, search).

## Features

- [Ask](ask.md): answers from the vault with citations; label/source filters (Any/All, unconfirmed), history, Stop.
- [Write a note](notes-composer.md): text notes with images inside the text (hover → Extract content), source, and the label step.
- [Actions](actions.md): to-dos and action types (Slack, Jira, Confluence, …) found in processed notes and Ask answers; confirm (Add as another type at confirm time), Jira pickers from the account, draft, improve, handlers, History, connections (connected or Set up connection, no Connecting state; Atlassian API token). Core, API, CLI and macOS UI built (selection bar for selected answer text not yet).
- [Action context](action-context.md): actions found in the batch before Review, from every line of the original plus the wiki; each item points at the original's lines (`.raw/captured/`) and its wiki sections; a preview before Create draft; drafts written from both; Ask actions get the closest lines of the cited pages' original, or are wiki only; no repeats on re-read or repair. Core, API, CLI and Mac UI built.
- [Action summary](action-summary.md): every found action carries a 2–4 sentence summary (what it is about, context, who, what was asked and by when) written at finding time; a To confirm row shows one line of it and a clean source name; clicking a row selects it into the right pane with the summary, FROM (Open original lines, Open wiki section), fields and what Create draft will write; ↑/↓ and Return; older items summarized on first open; "Found by by" and Markdown in source names fixed. Built (Ask rows show the summary; their click-to-open is not built yet).
- [Action buttons and script commands](action-buttons.md): buttons on any action type (Settings → Actions → a type, or ＋ Button in the tab) that run a stored script's command with arguments mapped from the item (`{fields.to}`, `{body}`, …); argv only, never a shell; exact command line shown before the first run; live output; the result (exit, output, key or URL) kept on the item; Send in Slack linked to the Slack CLI; Collectors renamed Automations; Add asks What it does (Collect, Commands, Both). Built.
- [Markdown editing](markdown-editing.md): Markdown in note, question and reply inputs; style bar, selection bubble, links and the `[[` note picker, shortcuts, paste.
- [Labels and sources](labels-and-sources.md): taxonomy, AI suggestions (queue files labeled before the batch, 3 at a time), confirmation through Review, the Labels screen.
- [Collectors](collectors.md): built-in (Folder) and custom-script collectors that fill the queue on a schedule; ledger and dedupe, cron schedule, script contract, consent, script files and packages. Core, API, CLI and macOS UI built, script files and packages included (Mac UI from canvas v67).
- [Activity log and trash](activity-log.md): what changed, when and from where (app, CLI, agent, scheduler) for chats, collectors, actions, batches, the queue, connections and settings; deletes of chats and collectors go to a 30-day trash with Restore. Core, API, CLI and Mac UI (History → Activity) built.
- [Session continuity](session-continuity.md): when an AI session Distill would resume is gone, it asks before using a new one (batches, Ask, Terminal, CLI). Core, API, CLI and Mac UI built.
- [Clean up inbox](inbox-cleanup.md): move files already in the knowledge base (ledger entry, unchanged, pages exist) from inbox/ to the Trash, only when you ask; from History, Review and Settings → Batching. Core, API and Mac UI built.
- [Full reads](full-read.md): batches sized to what one session can read; coverage counted by the core from the tool results; automatic continuations, fresh-session parts and a hard stop that can't be approved; detail level and the page-vs-source check; originals archived in .raw/captured/ with each batch; automatic repair. Built (core, API, CLI, Mac UI).
- [Live log](live-log.md): a batch's steps in plain words (labels per file, the AI's steps, the core's check, your review, applying) and a collector's output in order, live and kept; Show steps / Show log / Open log open it in place. Core, API and Mac UI built.
- [Intake: paste and drop](intake-paste-drop.md): how dropped files and pasted screenshots/text enter the queue.

## macOS app

- [App shell and visual design](app-shell.md): windows, sidebar sections, theme tokens, loading states.
- [Floating icon](floating-icon.md): the always-on-top flask, states, hover menu, click/drag/drop.
- [Quick actions and shortcuts](quick-actions.md): quick ask and quick note windows, recorded global shortcuts.
- [App icon](app-icon.md): the generated .icns.
- [Resizable panes](resizable-panes.md): drag the divider between two columns on every split screen (sidebar, Review’s Conversation, History, Actions, Activity, Collectors, Settings nav); min and max per column, double-click for the automatic width, widths remembered per screen in UI preferences. Built (macOS).
- [Headless and snapshot modes](headless-and-snapshot.md): `--snapshot` renders; headless runs moved to the CLI.
- [Tooling](tooling.md): build, install, control script, `/distill` skill, tests.

## Data and process

- [User data](user-data.md): where settings and history live, why updates never lose them, backups and restore.
- [Design process and design system](design-process.md): canvas first, shared components, one-to-one mapping to the Swift views.
- [Decisions](decisions.md): dated log of product and technical decisions and why.
