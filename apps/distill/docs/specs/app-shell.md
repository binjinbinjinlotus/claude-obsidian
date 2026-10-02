---
title: App shell and visual design
status: built
updated: 2026-10-01
---

# App shell and visual design

Code: `clients/macos/Sources/Distill/AppDelegate.swift`, `MainView.swift`, `SettingsView.swift`,
`Theme.swift`. Design canvas: https://claude.ai/artifact/VSqHFPZjcqY2bMqFEnPqpG

## Windows and menus

- AppKit lifecycle (`main.swift` → `AppDelegate`), SwiftUI content.
- Main window 1120×720 (min 900×600) and Settings window use a transparent,
  title-less title bar so the traffic lights sit on the light sidebar.
- Menus: Distill (Settings ⌘,), Edit, Queue (Paste into Queue ⇧⌘V, Process
  Queue Now ⌘R), Window (Show Worker ⌘0, Toggle Floating Icon ⌘I).

## Sections

- **Queue**: heading with count and next-batch line, Process now, drop panel
  with a flask that fills with the queue, file list.
- **Review**: jobs waiting for approval (see [Approval and review](approval-and-review.md)).
- **History**: all other jobs with status dots and details.
- Sidebar footer: active vault switcher with model and status.

## Visual language ("clean and joyful")

- Neutrals: window `#FFFFFF`, panel `#F6F5F2`, border `#ECEAE5`, ink `#1D1C1A`,
  muted `#6B6862`.
- Primary action: sky blue `#1F6FEB` (tint `#E3EEFF`).
- Accents (fill / ink): lime `#E9FBC9`/`#3D6110` for new things, peach
  `#FFE4D6`/`#B03A0A` for needs-attention, plus pink and sky for avatars.
- No dark surfaces, no purple.
- Type: SF Rounded heavy for headings (stands in for Bricolage Grotesque),
  system font for body.
- Shared pieces in `Theme.swift`: `FlaskView`, `PrimaryButton`, `SoftButton`,
  `Pill`, `Tile`, `card()`.
