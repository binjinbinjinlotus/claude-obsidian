---
title: Floating icon
status: built
updated: 2026-10-01
---

# Floating icon

An always-on-top flask that works without opening the main window. Code:
`clients/macos/Sources/Distill/FloatingIcon.swift`.

## Behavior

- Non-activating panel on every Space and over full-screen apps.
- **Click** opens the main window (or the quick ask window while its answer is pending). **Drag** (past 4 pt) moves it; the position
  is saved (`floatingIconOrigin`) and ignored if its display is gone.
- **Drop** files on it to queue them.
- **Right-click**: active vault, Open Distill, Paste into Queue, Process Now,
  Hide Floating Icon. ⌘I toggles it (`showFloatingIcon`).

Counts come from the app's mirror of the core (`AppModel`: queue and job
events). Drop and Paste go through [intake](intake-paste-drop.md), and Process Now
calls `POST /v1/queue/process`.

## States

| State | Look |
| --- | --- |
| Empty | white circle, low lime liquid |
| Queued | liquid rises with the count, blue count badge |
| Working | light-blue liquid, bubbles, blue ring |
| Needs approval | peach liquid, dark-peach count badge |
| Drag over | light-blue face, blue ring |
| Quick answer pending | green (lime) ring until the quick ask answer is seen |

**Hover** about 0.3 s opens the quick-actions menu (Ask, Add note, Paste
clipboard, Open Distill): see [Quick actions and shortcuts](quick-actions.md).
While the green ring shows, a click reopens the quick ask window.
