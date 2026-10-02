---
title: App icon
status: designed
updated: 2026-10-01
---

# App icon

The bundle ships without an icon today, so macOS shows its blank grid
placeholder in the Dock and Finder. Canvas artboard: "App icon".

## Design

White rounded-square tile with a soft sky-blue curve at the bottom; the flask
in slate outline with lime liquid and two small bubbles (blue, peach). Previewed
at 512, 128, 64 and 32 px to check it still reads small.

## Build plan

- Draw the icon at 1024 px (SwiftUI `ImageRenderer` of the flask, or an SVG
  export), produce an `.iconset` with `sips`, convert with `iconutil`.
- `build-app.sh` copies `AppIcon.icns` into `Contents/Resources` and sets
  `CFBundleIconFile`.
