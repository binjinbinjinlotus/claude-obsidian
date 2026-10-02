---
title: Vaults and settings
status: built
updated: 2026-10-02
---

# Vaults and settings

The core owns settings: `core/src/store/settings.ts`, `GET`/`PUT /v1/settings`.
The macOS UI lives in `clients/macos/Sources/Distill/SettingsView.swift` (window,
group pages, Vaults, Batching, Advanced), `SettingsNav.swift` (section list,
search results), `SettingsCatalog.swift` (sections and search index),
`SettingsSections.swift`, `SettingsModels.swift`, `SettingsActions.swift` and
`SettingsConnections.swift`. The DTO is in
`clients/macos/Sources/DistillKit/Models.swift` (`Settings`) and
`ActionSettings.swift` (`actionPreferences`, connections).
Canvas: SettingsNav, Settings.

## Window, sections and search

- The Settings window opens at 1140×720 (min 900×600). Its left column,
  `SettingsSectionNav` (236 pt), lists the sections in three groups:
  - **General**: Vaults, Batching (Batch every and Wait before picking up a
    file), Sources, Labels, Ask history, Keyboard shortcuts.
  - **AI**: AI runners, Models for tasks. Advanced (model, paths, extra
    allowed tools) is a disclosure at the end of the AI page.
  - **Actions**: Actions, To-do defaults, Connections.
- Picking a section shows its group's page, one scroll with an h2 per
  section, scrolled to that section. An action type opens its own page
  (Actions › Slack message) with a "‹ Actions" link back.
- Setup problems and an unreachable core (with Retry) show at the top of
  every page.
- **Search** sits above the list. Typing filters settings across every
  section: results are grouped under their section ("Actions › Jira
  ticket"), matching words are highlighted, the list shows a count per section
  and dims sections with no match. With no match it shows "No settings match
  “…”" and Clear search. Esc or × clears. Clicking a result opens its section.
  Every word of the query must appear in a setting's title, note or keywords.
- The index is data (`SettingsIndex.fixed` plus one set of entries per action
  type from the core), not written per view. Making a new setting searchable
  means adding one entry.
- **Deep links.** `AppModel.openSettings(section:)` posts
  `distill.openSettingsSection` with a section id; AppDelegate selects it and
  shows the window, so the window doesn't need to exist yet. Ids: `vaults`,
  `batching`, `sources`, `labels`, `ask-history`, `shortcuts`, `runners`,
  `models`, `actions`, `todo`, `connections`, and `actions/<typeID>` for a
  type's page. The Actions screens' "Sign in to Jira" opens `connections`. An
  image's "Settings" link (Extract content failed) opens `models`, where
  Text from images is set.
- Models for tasks lists Adding notes, Ask a question, Label suggestions, Text
  from images and Finding actions. Action drafts link to Actions, because
  writing and improving are set per type.

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
| `enabledRunners`, `taskDefaults`, v2 keys | see `contracts.ts`; Settings edits them (Sources, Labels, Ask history, Keyboard shortcuts, AI runners, Models for tasks) |
| `actionPreferences` (v3) | `DEFAULT_ACTION_PREFERENCES`; Settings → Actions and To-do defaults edit it. See [Actions](actions.md#settings). |

The core keeps jobs in `jobs.json` next to settings (newest first, capped at 300).

## Editing from the app

The Settings window edits a local copy. About 0.5 s after the last change, the
app sends only the changed top-level keys with `PUT /v1/settings`. A cleared
optional, such as `nodePath`, is sent as `null`. The core's answer and its
`settings` event become the new copy. Before any core is running, the app reads
`nodePath` and `productRoot` straight from settings.json, read-only, so it can
start one.

The core merges a patch one top-level key at a time, so an edit inside
`actionPreferences` sends that whole object. The app keeps the object as it
arrived (raw JSON with typed accessors): nested keys this build doesn't know
are sent back unchanged. Untouched, `actionPreferences` is never written.

## Validation

The core reports setup problems in `GET /v1/status` (`problems`: no vault, not
a vault, missing `claude`, missing core script, queue inside `.raw/` or
`.vault-meta/`, runner problems). They block batching and are listed at the
top of every Settings page. A core that cannot be reached shows there too, with Retry.
