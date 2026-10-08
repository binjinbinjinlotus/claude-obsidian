# Distill

Distill is a macOS app that turns sources into a source-cited Obsidian wiki. Its look is calm and light: white windows over a warm grey panel, one blue for the main action, and a few soft tints (lime, peach, pink, sky) used as pill and chip fills, each with a dark ink of the same hue.

## Where the values come from

`Theme.swift` in the Mac app (`apps/distill/clients/macos/Sources/Distill/Theme.swift`) is the source of truth. `apps/distill/design/tokens.py` reads it and writes this system's `tokens.json` and the canvases' `tokens.css`; `test_design.py` fails when they disagree. Never edit a value here: change Theme.swift and regenerate.

## Colour

- `window` (white) is every window and card; `panel` (warm grey) is the sidebar, toolbars and quiet fills; `border` draws hairlines.
- Text is `ink`, then `muted` for secondary lines. `faint` is for placeholders and timestamps only: it is below 4.5:1 on `window`.
- `primary` is the single action colour: the PrimaryButton, links, focus and the selected row's outline. `primaryTint` fills selected rows and busy pills.
- A tint always goes with its ink: `limeTint` + `limeInk` (done, ready), `peachTint` + `peachInk` (needs you, counts, warnings), `pinkTint` + `pinkInk` and `skyTint` + `skyInk` (vault chips). `vaultChip1`…`vaultChip4` (and their `Ink`) follow `Theme.vaultChips`, a vault's chip by its place in the list.
- `lime` and `peach` at full strength are joy accents (the app icon's liquid), never text grounds.

## Type

- `display` (Bricolage Grotesque on the canvas, standing in for SF Rounded heavy) for page and window titles.
- `body` (DM Sans, standing in for SF) for everything else. Buttons are semibold (14, 13, 12 by size); pills are bold (12, 11).

## Shape and space

- Buttons, pills and chips are capsules (`radius-capsule`); cards and panels use `radius-card` (18px).
- Buttons: `button-height` 40, `-small` 30, `-mini` 26; padding `button-pad` 20 (SoftButton `button-pad-soft` 18), 14, 11; icon to title `button-gap` 7.
- Pills: `pill-height` 24 and 20, padding 10 and 8, icon to text 5 and 4.

## Components

`components/bundle.js` sets `window.Distill` (React 18). Each component has the name and props of its Swift view, so a canvas board and the app read the same. Bundled so far: PrimaryButton and Pill. The other Distill components still live on the canvas as boards; they move here a few at a time.
