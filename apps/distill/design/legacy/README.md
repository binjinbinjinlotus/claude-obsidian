# Legacy canvas generators

`boards/` holds the 23 boards these generators made that are not in the
schema yet, copied verbatim from the canvas on 2026-10-06 (v12). `render.py`
publishes them from here like any other board (kind `legacy`), so the canvas
never holds a board the repo doesn't. Edit a board here only as a stopgap;
the way out is moving it into `screens/`, which deletes its file here.

Versioned copies of the ad-hoc Python generators that built the design canvas
before the schema (`../components.json`, `../screens/`, `../render.py`). They
were copied unchanged from the session scratchpad at canvas v57 (2026-10-03), so they still
expect that layout: `distill-design/project/` next to them, a compiled
`snapbin` (from `../tools/snap.swift`), and `board-bak-audit/` for
`gen_audit.py`. They get retired board by board: when a board moves into the
schema, its generator code is deleted here.

| File | Boards | Status |
| --- | --- | --- |
| `gen_components.py`, `gen_controls.py` | row 0 component and states boards | migrated to `components.json` + `components/`; kept only because the scripts below import them. Do not run them over row 0. |
| `gen_actions.py` | ActionsOverview, ActionsAsk (still legacy); ActionsTodo, ActionsSlack, ActionsJira, ActionsConfluence, ActionsHistory | the last five render from `screens/actions.json` since canvas v57 (2026-10-03). **Do not run `rebuild.sh` / `gen_actions.py` over them**: it would overwrite the schema output. |
| `gen_audit.py` | Settings, SettingsNav and the audited app boards | Main and MainLoading render from `screens/queue.json` (page boards) since 2026-10-04: **do not run `gen_audit.py` over them**. The rest are not migrated. |
| `gen_md.py`, `gen_compose.py`, `gen_images.py`, `gen_sizing.py` | Markdown, ComposeSizing, ImagesInline, QuickSizing | not migrated |
| `wire_buttons.py`, `wire_controls.py` | swap inline buttons and controls on the legacy boards for `<dc-import>` | retire with the boards they patch |
| `place_row0.py`, `fit_heights.py`, `rebuild.sh` | canvas.json placement and heights | replaced by `render.py --canvas` / `--measure` |
| `symbols.py` | icon name → SF Symbol → path data | replaced by `../data/icons.json` |
| `components_sizes.json`, `actions_sizes.json` | measured heights | replaced by `../sizes.json` |
