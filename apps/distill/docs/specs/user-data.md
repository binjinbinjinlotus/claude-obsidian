---
type: spec
title: User data
status: built
created: 2026-10-02
updated: 2026-10-06
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
| Label state for notes waiting in the vault's `inbox/` (labels confirmed or suggested after the note was written; never written into `inbox/`), and since 2026-10-05 for other queue text files (suggested, confirmed, failed attempts, sent without labels) | `labels/notes.json` (notes keyed by requestID, queue files by `file:<sha256 of the content>`; newest 2000) |
| Collectors (settings, consent hashes, last scheduled tick) | `collectors.json` (v4) |
| What Folder collectors already collected (per vault; name, size, mtime, sha256, never content) | `collectors/ledger-<vault-id>.jsonl` (v4, append-only) |
| Collector run history (30 days or the newest 200 runs per collector) | `collectors/runs/<collector-id>.jsonl` (v4) |
| Scripts Distill keeps, with their `package.json` / `requirements.txt` and installed packages | `collectors/scripts/<collector-id>/` (v6; files 0600, folders 0700; `node_modules/`, `.venv/` inside) |
| The newest package install per collector (output tail, manifest hash of the last success) | `collectors/installs/<collector-id>.json` (v6) |
| Test run output, kept until the next Test run, pruned after 7 days | `collectors/test-runs/<collector-id>/` (v6) |
| The copy of `collectors.json` taken before inline scripts moved to files | `collectors.json.pre-script-files-<time>` (v6, once) |
| A batch's live log: its steps in plain words, never contents (2,000 steps / 512 KB per job; removed with the job) | `steps/<job-id>.jsonl` (v7, 0600) |
| Activity log: what changed, when, from where (never secrets or content; 2 MB files, 10 rotated, 180 days) | `activity/activity.jsonl` + `activity/activity-<time>-<pid>-<rand>.jsonl` (v6, append-only, 0600) |
| Distill's trash: deleted Ask chats and collectors, 30 days (at most 200 items, 50 MB) | `trash/<trash-id>.json` (v6, dir 0700, files 0600; holds inline scripts), plus `trash/<trash-id>.files/` for a kept script's folder without `node_modules`/`.venv` |
| Who names are in Slack, per vault (name → @handle, ID or #channel; the Send in Slack To row) | `actions/slack-people.json` (2026-10-06; keyed by vault id; backed up and restored) |
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
  (an action item this build can't decode is also written back untouched),
  a `collectors.json` that doesn't parse (a collector this build can't
  decode is written back untouched), and a ledger or run-history file with a
  line this build can't read (the line is kept on every rewrite).
  The same bytes are copied once.
- **Ask chat files that can't be read are skipped**, never deleted.
- **Writes are atomic** (temp file, fsync, rename).
- **Tests and agents use a temp `DISTILL_STATE_DIR`**, never the real one.

## Backups

`apps/distill/clients/macos/scripts/distill.sh`:

- `update` backs up first (`backups/<time>-update`), installs, then compares
  settings / job / chat counts before and after and prints
  "Your data is intact: settings kept · N jobs · M Ask chats · K actions · C collectors", or a WARNING
  with how to restore.
- `backup [TAG]` copies `settings.json`, `jobs.json`, `ask/*.json`,
  `actions.json`, `connections.json`, `collectors.json`,
  `labels/notes.json`, the
  `collectors/` ledgers and `collectors/runs/` (with their set-aside
  copies) and any `*.unreadable-*` files
  (Keychain secrets stay in the Keychain). The newest 10 backups are kept; names sort by time
  (a same-second counter is zero-padded).
- `activity/` and `trash/` are not backed up and a restore never touches
  them: the log is append-only history and must not be rewound
  ([Activity log and trash](activity-log.md)).
- Collector script files (`collectors/scripts/`, without `node_modules` and
  `.venv`) and the live log's `steps/` are backed up and restored (since
  2026-10-05). `collectors/installs/` (install logs) and
  `collectors/test-runs/` (Test run output) are scratch and are not.
- `backups` lists them, newest first.
- `restore NAME` refuses while the app or the core runs, backs up the current
  data (`before-restore`), then copies the backup back.

Tests: `core/src/store/store.test.ts` ("user data survives builds that cannot
read it").
