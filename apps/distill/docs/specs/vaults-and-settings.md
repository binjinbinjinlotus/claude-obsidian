---
title: Vaults and settings
status: built
updated: 2026-10-01
---

# Vaults and settings

The core owns settings: `core/src/store/settings.ts`, `GET`/`PUT /v1/settings`.
The macOS UI lives in `clients/macos/Sources/Distill/SettingsView.swift`, the DTO in
`clients/macos/Sources/DistillKit/Models.swift` (`Settings`).

## Vaults

- A vault is a folder containing `.claude-obsidian.json`. The app checks this
  before adding one and refuses other folders, with a hint to run
  `claude-obsidian.py init` or `adopt`.
- Several vaults can be added and one is active. The sidebar switcher and the
  Settings vault cards change it. Each vault has its own queue folder, edited
  from the card's "…" menu (including "use the vault's inbox/").
- All runs, the queue and the inbox belong to the active vault.

## Stored settings

`~/Library/Application Support/Distill/settings.json`, or `$DISTILL_STATE_DIR`.
Only the core writes it. Missing keys fall back to defaults, and the core keeps
unknown keys.

| Key | Default |
| --- | --- |
| `batchIntervalMinutes` | 10 |
| `settleSeconds` | 600 (10 minutes): a file is batched only once unchanged this long. Settings → "Wait before picking up a file" edits it as minutes + seconds (0–59 each). Process now ignores it. |
| `autoProcessEnabled` | true |
| `model` | `sonnet` (Haiku/Sonnet/Opus cards, pinned IDs, or custom) |
| `claudePath` | `~/.local/bin/claude` |
| `pythonPath` | `/usr/bin/python3` |
| `nodePath` | unset: the app looks for node itself (see [App shell](app-shell.md#finding-the-core)) |
| `productRoot` | the checkout the core runs from |
| `extraAllowedTools` | empty |
| `enabledRunners`, `taskDefaults`, v2 keys | see `contracts.ts` (the app decodes them and does not edit them yet) |

The core keeps jobs in `jobs.json` next to settings (newest first, capped at 300).

## Editing from the app

The Settings window edits a local copy. About 0.5 s after the last change, the
app sends only the changed top-level keys with `PUT /v1/settings`. A cleared
optional, such as `nodePath`, is sent as `null`. The core's answer and its
`settings` event become the new copy. Before any core is running, the app reads
`nodePath` and `productRoot` straight from settings.json, read-only, so it can
start one.

## Validation

The core reports setup problems in `GET /v1/status` (`problems`: no vault, not
a vault, missing `claude`, missing core script, queue inside `.raw/` or
`.vault-meta/`, runner problems). They block batching and are listed at the
bottom of Settings. A core that cannot be reached shows there too, with Retry.
