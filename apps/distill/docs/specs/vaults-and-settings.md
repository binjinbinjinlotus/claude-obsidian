---
title: Vaults and settings
status: built
updated: 2026-10-04
---

# Vaults and settings

The core owns settings: `core/src/store/settings.ts`, `GET`/`PUT /v1/settings`.
The macOS UI lives in `clients/macos/Sources/Distill/SettingsView.swift` (window,
one page per section, Vaults, Batching, Advanced), `SettingsNav.swift` (section list,
search results), `SettingsCatalog.swift` (sections and search index),
`SettingsSections.swift`, `SettingsModels.swift`, `SettingsActions.swift` and
`SettingsConnections.swift`; `SettingsWindow.swift` holds the window
(size, close hook), the scroll position helper and the row anchors search
results land on. The DTO is in
`clients/macos/Sources/DistillKit/Models.swift` (`Settings`) and
`ActionSettings.swift` (`actionPreferences`, connections).
Canvas: SettingsNav, Settings.

## Window, sections and search

- The Settings window opens at 1140×720 (min 820×600). Its left column,
  `SettingsSectionNav` (236 pt), lists the sections in three groups:
  - **General**: Vaults, Batching (Batch every and Wait before picking up a
    file), Sources, Labels, Ask history, Keyboard shortcuts.
  - **AI**: AI runners, Models for tasks. Advanced (model, paths, extra
    allowed tools) is a disclosure at the end of the AI runners page
    (`SettingsSection.advancedHome`): most of it configures how the Claude
    Code runner and the core start. Its search entry points there.
  - **Actions**: Actions, To-do defaults, Connections.
- **One page per section**, as on the canvas (SettingsNav frames): picking
  a section shows its own page, with its own scroll view. The page header
  is the section's title (26 pt) and note; below it is only that section's
  content. The group (General, AI, Actions) is a nav heading only and has
  no page header. An action type opens its own page (Actions › Slack
  message) with a "‹ Actions" link back. `SettingsPage` is what a page
  shows inside its scroll view.
- **Narrow windows.** Every page fits from the minimum width up; the
  section nav (236 pt) is never squeezed or cut off. The page column is
  `minWidth: 0` and clipped, so a page can never widen the window, and rows
  reflow instead:
  - Models for tasks: the runner, model and effort pickers move under the
    task's title when the row doesn't fit beside it (below about 1000 pt).
  - AI runners: two columns while each card keeps 290 pt, one column below
    that (so one column at the usual ~890 pt).
  - Batching: the "Wait before picking up a file" counters move under the
    text when it would get less than 240 pt.
  - Connections: the status pill and button move under the title when the
    title would get less than 220 pt; button labels are never cut.
  - Action types list: the model summary column shrinks (190 → 90 pt) before
    anything else.
  `SettingsWindowTests` measures every page (each section and each action
  type) at the minimum and at 890 pt, and checks in the real window that
  every page starts right of the whole nav and never scrolls sideways.
  Snapshot states: `settings-page-<section>-{min,890}` and
  `settings-type-<type>-{min,890}` show each page whole; `settings-nav-<section>`
  shows each page's top at the default 1140 pt.
- **Scroll position.** Each page remembers where you left it, for this
  Settings session only:
  - A page you haven't visited since Settings opened opens at its top.
  - A page you have visited reopens at the scroll position you left it
    at, clamped if the page got shorter. Pages of one nav group don't share
    a position. This applies to the section list and to the links back
    inside Settings (an action type row, "‹ Actions").
  - Search results, deep links from other screens (`openSettings`) and
    "Open Actions ›" always open the page at its top, ignoring the
    remembered position. A search result for a specific row (Labels › "CLI:
    use AI labels if none are sent back", Actions › Jira ticket › "Improve
    prompt") scrolls to that row; a result that is the section itself, and
    Queue folder (inside the vault editor sheet), opens at the top. Rows
    report where they sit with `.settingsAnchor(<search entry title>)`;
    `SettingsRow` does it for its title. "Advanced" also expands the
    disclosure. `SettingsWindowTests` checks that every search entry finds
    its row.
  - Closing the Settings window forgets every position (and the prompt
    "Undo reset"s); so does quitting. Positions live in memory
    (`SettingsStore.offsets`), never on disk. Each page is built fresh when
    shown, so no old offset survives in a scroll view either.
- Setup problems and an unreachable core (with Retry) show at the top of
  every page.
- **Search** sits above the list. Typing filters settings across every
  section: results are grouped under their section ("Actions › Jira
  ticket"), matching words are highlighted, the list shows a count per section
  and dims sections with no match. With no match it shows "No settings match
  “…”" and Clear search. Esc or × clears. Clicking a result opens its page at that
  setting's row.
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
  `claude-obsidian.py init` or `adopt`. The core checks it again on every use,
  not only for batches (decision 2026-10-04). Labels, notes, page search and
  label review answer `invalid_state` with the same hint when the marker is
  gone, and Ask refuses the vault.
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
| `extraAllowedTools` | empty (rules that would get round the approval gate are ignored at use time, never removed: [Approval and review](approval-and-review.md) → Phase 1) |
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
a vault, missing `claude`, missing core script, a queue folder inside the
vault other than exactly `<vault>/inbox` (`queueIsVaultInternal`: the vault
root, `wiki/`, `.raw/`, `.vault-meta/` or a folder under `inbox/`; paths are
compared after resolving symlinks), runner problems). The same check refuses
notes and drops into such a queue folder (`invalid_state`) and fails collector
runs (decision 2026-10-04). They block batching and are listed at the
top of every Settings page. A core that cannot be reached shows there too, with Retry.
