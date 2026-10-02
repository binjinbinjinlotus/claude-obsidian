---
title: App icon
status: built
updated: 2026-10-01
---

# App icon

The bundle's icon for the Dock, Finder and Spotlight. Canvas artboard: "App icon".

## Design

White rounded-square tile with a soft sky-blue curve at the bottom; the flask
in slate outline with lime liquid and two small bubbles (blue, peach). Previewed
at 512, 128, 64 and 32 px to check it still reads small.

## Build

- `clients/macos/Sources/Distill/AppIcon.swift` draws the icon in SwiftUI
  (the canvas SVG's 40×44 flask; the tile is 824 of 1024 px with the 22.5 %
  corner radius). `Distill --snapshot OUT.iconset --app-icon` writes the ten
  iconset PNGs (`icon_16x16.png` … `icon_512x512@2x.png`).
- `clients/macos/scripts/make-icon.sh` renders them and runs `iconutil` into
  `clients/macos/Resources/AppIcon.icns` (checked in).
- `build-app.sh` copies `AppIcon.icns` into `Contents/Resources` and sets
  `CFBundleIconFile`.
