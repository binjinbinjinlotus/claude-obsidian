---
type: spec
title: User data
status: built
created: 2026-10-02
updated: 2026-10-02
tags:
  - distill
  - data
---

# User data

The user keeps updating Distill as features land. No build, update or schema
change may lose their settings or history.

## Where it lives

Everything is on the Mac, in the state directory
`~/Library/Application Support/Distill` (override: `DISTILL_STATE_DIR`).
Nothing goes into the vault except approved notes and pages.

| What | Where |
|---|---|
| Settings | `settings.json` |
| Job history (batches, reviews) | `jobs.json` |
| Ask history | `ask/<chat-id>.json`, one file per chat |
| Actions (to-dos, drafts, History) | `actions.json` (v3) |
| Connection details without secrets (Atlassian site, display name) | `connections.json` (v3, mode 0600) |
| API keys and connection tokens | macOS Keychain, never a file |
| Backups | `backups/<time>[-tag]/` |
| Runtime only | `server.json`, `server.log`, `token`, `ask/workspace/` |

Retention is the user's choice: Ask chats older than `askPreferences.historyDays`
(default 10) are deleted unless pinned; removed/done/sent actions after
`actionPreferences.historyDays` (default 90).

## Rules for every change

- **Updates replace only the app bundle.** `build-app.sh --install` removes
  `~/Applications/Distill.app` and nothing else.
- **Schema changes are additive.** Decoders are lenient: a missing or
  wrong-typed field takes its default. Unknown keys survive a save
  (`encodeSettings`, `encodeJob` keep the last-read raw object). Never rename
  or repurpose a stored field; add a new one and keep reading the old one.
- **A file this build can't read is set aside, never overwritten.** Before
  any save could replace it, the core copies it byte for byte to
  `<file>.unreadable-<time>` (`preserveUnreadable` in `core/src/store/json.ts`):
  a `settings.json` that doesn't parse, a `jobs.json` that isn't a list or
  holds a job this build can't decode, an `actions.json` that doesn't parse
  (an action item this build can't decode is also written back untouched).
  The same bytes are copied once.
- **Ask chat files that can't be read are skipped**, never deleted.
- **Writes are atomic** (temp file, fsync, rename).
- **Tests and agents use a temp `DISTILL_STATE_DIR`**, never the real one.

## Backups

`apps/distill/clients/macos/scripts/distill.sh`:

- `update` backs up first (`backups/<time>-update`), installs, then compares
  settings / job / chat counts before and after and prints
  "Your data is intact: settings kept · N jobs · M Ask chats", or a WARNING
  with how to restore.
- `backup [TAG]` copies `settings.json`, `jobs.json`, `ask/*.json` and any
  `*.unreadable-*` files. The newest 10 backups are kept; names sort by time
  (a same-second counter is zero-padded).
- `backups` lists them, newest first.
- `restore NAME` refuses while the app or the core runs, backs up the current
  data (`before-restore`), then copies the backup back.

Tests: `core/src/store/store.test.ts` ("user data survives builds that cannot
read it").
