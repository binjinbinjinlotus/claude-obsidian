---
title: Vaults and settings
status: built
updated: 2026-10-01
---

# Vaults and settings

Code: `clients/macos/Sources/WorkerCore/Settings.swift`, UI in `clients/macos/Sources/Distill/SettingsView.swift`.

## Vaults

- A vault is a folder containing `.claude-obsidian.json`; others are refused
  with a hint to run `claude-obsidian.py init` or `adopt`.
- Several vaults can be added; one is active. The sidebar switcher and the
  Settings vault cards change it. Each vault has its own queue folder (edit via
  the card's "…" menu, including "use the vault's inbox/").
- All runs, the queue and the inbox belong to the active vault.

## Stored settings

`~/Library/Application Support/Distill/settings.json` (`WorkerSettings`).
Missing keys fall back to defaults so older files keep loading.

| Key | Default |
| --- | --- |
| `batchIntervalMinutes` | 10 |
| `settleSeconds` | 10 |
| `autoProcessEnabled` | true |
| `model` | `sonnet` (Haiku/Sonnet/Opus cards, pinned IDs, or custom) |
| `claudePath` | `~/.local/bin/claude` |
| `pythonPath` | `/usr/bin/python3` |
| `productRoot` | `ClaudeObsidianProductRoot` from Info.plist (the checkout it was built from) |
| `extraAllowedTools` | empty |

Jobs live in `jobs.json` next to it (newest first, capped at 300).

## Validation

`SetupValidator.problems` reports: no vault, not a vault, missing `claude`,
missing core script, queue inside `.raw/` or `.vault-meta/`. Problems block
batching and are listed at the bottom of Settings.
