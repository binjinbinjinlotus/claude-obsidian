---
type: spec
title: Decisions
status: built
created: 2026-10-02
updated: 2026-10-04
tags:
  - distill
  - decisions
---

# Decisions

Newest first. Each entry: what was decided, why, and where it lives. Add an
entry in the same change that makes a decision; never rewrite an old one —
supersede it with a new entry.

## 2026-10-04

- **A kept script saved in another editor is logged; a spec error never drops
  an entry.** Spec: [Activity log](activity-log.md) → Edits outside Distill.
  The owner's "Meeting Note" save at 22:41:07 had no activity entry.
  - **No request reached the core.** The file kept its 22:29:40 birth time,
    and its folder kept its 22:29 mtime. Every core write is a temp file plus
    a rename, which changes both; a temp state dir confirmed this.
    `~/.idlerc/recent-files.lst` and `breakpoints.lst` were written at 22:41
    and list this file. IDLE is the Mac's default app for `.py`, and **Open
    in editor** opened it there.
  - **Not the wrapper, not the core 79304 build.** That core started with the
    app at 22:39:03. Its first entry (seq `0001`) is the 22:41:55 consent, so
    it never tried to log a save. The app's own Save (`PUT …/script`) logs
    exactly one `collector.script_saved` against a real core: core test, and
    `CollectorSaveLiveTests` through the app's store.
  - **Decision:** the core keeps `script.knownFiles` (the script and manifest
    hashes it last wrote or saw). It compares them at ticks, reads, and before
    consent, runs, saves and installs. A difference logs one
    `collector.script_changed_outside`, source `scheduler`, with sizes and
    12-character hashes. That entry lands before the consent that covers the
    change.
    - Not a file watcher: the tick bounds the delay to 15 s, and a watcher is
      one more thing to keep alive.
    - Not the user's own files: editing them in another editor is expected.
  - **Also:** `instrumentCore` used to swallow a throwing `ok` with no entry.
    It now writes a plain entry with `describeError` and warns in
    `server.log`. A throwing `fail` can no longer replace the core's error.
- **Script editor crash fixed: the selection is clamped, never dropped.** The
  app quit at 22:41:41 (crash report `Distill-2026-10-04-224141.ips`). The
  exception came from `NSTextView setSelectedRanges` in
  `PlainCodeView.updateNSView`. When the editor's text was replaced from
  outside with shorter text while the caret sat past the new end, the old code
  filtered every range out and handed AppKit an empty list, which it rejects.
  Ranges are now clamped to the new length, with the caret at the end if
  nothing is left.
- **Scripts are told the run's trigger: `DISTILL_RUN_TRIGGER`.** Spec:
  [Collectors](collectors.md) → Script contract, Test run. The owner Test-ran
  the meeting-notes script. Its 30 notes went to the test folder, as designed,
  but the script also saved them in its own "already downloaded" file. A real
  run would then have found nothing new. Scripts now get
  `DISTILL_RUN_TRIGGER` (`now`, `schedule`, `catchup` or `test`), so a script
  can skip saving its state on a Test run. `apps/scripts/meeting-notes` does
  that now, and it also skips video and audio recordings by default (that
  test run downloaded 1.4 GB of them).
- **JavaScript and TypeScript collectors run on Distill's own Node, and npm
  installs never change `package.json` (core built).** Spec:
  [Collectors](collectors.md) → "Languages" ("Which Node") and "Packages".
  - **Found on the owner's Mac:** `zsh -l` puts `/usr/local/bin/node`
    v14.16.0 (npm 6.14) ahead of nvm's 22.22.1. The core took `node` and
    `npm` from the login shell's PATH, but the app runs the core on 22.22.1.
    - TypeScript failed ("needs Node 22.6").
    - The JavaScript starter template's `import` failed.
    - npm 6 rewrote `package.json` during the install. The manifest hash
      moved, so a successful install read `needsInstall` again, and the
      script read "changed since you allowed it".
  - **Rule:** JavaScript and TypeScript always run on the core's own Node,
    `process.execPath` (the app's `settings.nodePath` or highest nvm Node).
    npm is the copy that ships with it, run by it:
    `../lib/node_modules/npm/bin/npm-cli.js`, never through the shebang.
    That Node's folder comes first on PATH for those runs and for installs.
    - We rejected "the login shell's node when it is new enough".
      Distill already requires its own Node, so this needs nothing new, and
      one rule is easier to predict than a version check per language.
    - npm builds native addons for the Node that installs them, so install
      and run must use the same Node. The login-shell rule would break that
      whenever the two differ.
    - zsh and Python are unchanged.
  - **Which Node ran is recorded:** `run.runtime` / `install.runtime`
    (`{label: "Node 22.22.1", path, version}`), in the Activity details as
    `runtime`. The Mac app doesn't show it yet; that needs a canvas pass.
  - **Installs put `package.json` back byte for byte** when npm rewrote it,
    whatever the outcome. This works for any npm version. `--no-save` would
    also stop lockfile writes and depends on npm's behaviour. The consent
    hash stays bound to what the owner read.
  - **Before → after on the owner's setup** (a temp state dir, the real
    login shell PATH):
    - A TypeScript run went from failed ("/usr/local/bin/node is 14.16.0")
      to success on "Node 22.22.1".
    - A `file:`-dependency install went from success but `needsInstall`,
      consent moved and the next run `notTrusted`, to success, `ready`, the
      same bytes and consent, and the next run succeeding.
    - Forcing Distill's Node to v14 (real npm 6): the install still ends
      `ready` with the same bytes.

- **Activity log fixes from the Mac Activity screen: settings in Settings'
  words, readable paths, scripts written in Distill (core built; Mac
  DistillKit reads the new keys).** Spec: [Activity log and
  trash](activity-log.md) → "What is logged", "Redaction".
  - **Settings summaries use Settings' names**, as on the canvas v66 card:
    "Changed settings: Ask history (Keep history off)". One table in the
    core, `core/src/activity/settings-labels.ts`, maps dotted keys to the
    Settings section and label and values to words (On/Off, "15 minutes",
    "Every 5 min", "Forever", "Claude Code · sonnet"). Absent settings read
    their defaults, so "— → false" reads "On → Off". Unknown keys keep the
    raw key. Each leaf key gets its own section: `askPreferences.labelMatch`
    is under Labels, not Ask history. The Swift catalog can't be imported
    by the core, so the table is the one place, and a core test checks that
    its section titles and labels still appear in the Mac's
    `Settings*.swift`. A few names the log needs that Settings has no single
    string for ("Keep history", "Days", "Active vault", "Runner options")
    are listed in that test.
  - **`details.changes` is unchanged** (raw `key: old → new`), for scripts
    and older apps. **New, additive: `details.readableChanges`**, one
    "Label: Old → New" line per setting. Newer Mac builds show it. Prompts,
    runner options and action-type settings say only "changed".
  - **Paths are not secrets.** The two guesses (32+ hex and a 40+ run mixing
    upper case, lower case and digits) no longer run inside file paths
    (`/…`, `~/…`, spaces included when another `/` follows) or path-keyed
    details (`scriptFile`, `vault`, `folder`, `…Path`, `…Dir`). URLs are
    not treated as paths. Precise shapes (sk-, ghp_, xox, AKIA, AIza,
    ya29, ATATT, JWT, Bearer/Basic, URL credentials, key=value, PEM) still
    run everywhere, paths included. Before: `/[redacted].py`, and "Into"
    showed as `[redacted]`.
  - **Scripts written in Distill:** collector facts add `scriptManaged:
    true` for `{file, managed: true}` sources. `scriptFile` stays, for Show
    in Finder. The Mac shows "N lines · size, written in Distill" for these,
    and the path for the user's own files. Line counts no longer count a
    final newline as a line. Entries written before this change have no
    flag and still show the path. No path-sniffing fallback (my call).
- **Collectors v6 in the Mac app (canvas v67, built straight from the
  design as the owner approved).** Spec: [Collectors](collectors.md) →
  "Built in the Mac app: script files, packages, Test run, Run now (v6)".
  Choices and differences from the boards:
  - **The editor saves code and manifest only through `PUT …/script`**,
    with the hashes it loaded; PATCH never carries a kept script's code. A
    409 keeps the draft and offers Reload or Keep editing, so a change made
    in another editor is never overwritten silently.
  - **A manual run's result stays until Hide or a newer run**, and only for
    runs started in this app session (a CLI Run now shows as the normal last
    run). Test run results have no Hide (as on the board); a newer run
    replaces them.
  - **Test run file sizes** come from a read-only stat of the run's
    `outputDir` (the contract has no sizes); a missing file shows no size.
  - **WHAT CHANGED shows the manifest as it is now, without "+" marks**:
    the core doesn't keep the allowed manifest's text, so the app can't diff
    it. The PackagesPanel still draws "+" lines when given them.
  - **Run now is disabled while the manifest's last install failed** (board
    X2); Test run stays available, as drawn, and records "Not run · packages
    aren't installed".
  - **⋯ has no Run now while a script needs the OK.** Allowing from a menu
    would skip seeing the code; the title row's Allow and run sits next to
    it.
  - **Schedule and Advanced also holds Into (the vault)** in a script's form:
    the board folds it away, but the vault must stay editable.
  - **The Settings line for a kept script reads "collector.py · Python"**
    on every board (frame T's "· in Distill's collectors folder" was
    dropped for one calm form); W adds a Packages line.
  - **Code fields are an NSTextView** with smart quotes, dashes and text
    replacement off and no wrapping (SwiftUI's TextEditor can substitute
    quotes under the system's smart-quotes setting, which would break
    package.json and shell code; wrapped lines broke the line numbers in the
    first render).
  - **`.ts` opens in the default text editor** when the system's handler is
    a media player or none (`.ts` is also MPEG-2 transport stream).
  - **Found, not fixed here (core):** the core runs the login shell's
    `node`/`npm`. On this Mac that is `/usr/local/bin/node` v14 with npm
    6.14, not nvm's Node 22. npm 6 rewrites `package.json` while installing
    (formatting), so the manifest hash changes after a successful install:
    the collector reads `needsInstall`, and the consent hash moves. The live
    test writes its manifest in npm's format to avoid it. TypeScript also
    needs Node 22.6+, which that login shell doesn't give.

- **Collectors v6 follow-up: install on add, Test run, venv and Keychain,
  one trash (core built; boards updated, unpublished).** Specs:
  [Collectors](collectors.md) → "Script files and packages (v6)",
  [Activity log and trash](activity-log.md) → "Recovery". Supersedes, from
  the v6 entry below: installs only on Install / before a run, and the
  collectors' own `collectors/trash/`.
  - **Packages install on Allow** (adding a script, or OK after a manifest
    change), trigger `allow`; install before a run stays only as a safety
    net for missing packages. A failed install of a manifest is **not
    retried by every run** (my call): the run fails at once until Install
    or a new manifest, so a broken install doesn't run every hour.
  - **Run now / Test run / a scheduled tick during an install wait for it**
    (`waiting: 'install'`) instead of `busy` or "Skipped", so "Allow and
    run" works in one click.
  - **Venv:** `python3 -m venv --symlinks`, created only when there is no
    working venv; a manifest change installs into it; nothing on start,
    migration, re-point or reinstall touches it. Tested with a real venv
    (its python resolves to the base binary; inode and mtime unchanged).
  - **Test run:** scratch folder `<state>/collectors/test-runs/<id>/`,
    **kept until the next test run** (emptied when it starts), deleted with
    the collector, pruned after 7 days. In the run history with trigger
    `test`, never `lastRun` or the sidebar count. In the app: a quiet
    "Test run" link before Run now on script collectors (Run now stays the
    one button; also second in the script ⋯ menu), and its result card is
    blue-grey so it never reads as a real run (board CollectorsScriptFiles,
    frame V2).
  - **One trash:** Distill's trash copies a script collector's folder
    (without `node_modules`/`.venv`) as `<trash-id>.files/` before the
    delete; Restore copies it back and re-points the record; the 30-day,
    200-item, 50 MB policy covers both. `collectors/trash/` is no longer
    written; leftovers from the earlier build are found on restore and
    pruned after 30 days. The collectors service alone never removes a
    script folder.
  - **Chats deleted while Keep history is off go to the trash for 24 hours**
    (owner); actions deleted forever and jobs removed from the list stay
    out.
  - **Activity entries:** `collector.script_saved` (parts, sizes, hash
    prefixes), `collector.install` (from the finished event),
    `collector.install_stopped`, `collector.test_run`; never script text,
    manifests or install output.
  - **Activity log rotation keeps an empty live file** after rotating, which
    fixed a size test that depended on entry sizes.
  - `/v1/activity` and `/v1/trash` shapes are unchanged; trash items may
    carry `details.scriptFolder: true` and `details.reason:
    'keep-history-off'`, and `expiresAt` can be 24 hours out.

- **Activity built in the Mac app (canvas v66, mac activity).** Spec:
  [Activity log and trash](activity-log.md) → macOS app.
  - The Mac app sends `X-Distill-Client: app` on every request (open question
    2), so the log no longer depends on the User-Agent guess.
  - Filter families: Queue includes notes (a note is added to the queue),
    Batches includes label runs (they are jobs), and Settings includes runner
    keys and connections (configuration). Automatic is the `scheduler`
    source; Today starts at local midnight.
  - "In trash", "Restored" and "no longer in the trash" come from
    `GET /v1/trash` plus the `*.restored` entries (their `trashId`), never from
    memory, so Restore isn't offered after a relaunch for a copy that is gone.
    A 404 on Restore says the copy expired; a 409 shows the core's message.
  - "Kept N days" is `expiresAt − deletedAt`, so the owner's 24-hour trash for
    chats closed with Keep history off reads "Kept 24 hours" with no app
    change.
  - "Show everything for X" adds a removable "For: X" chip; it is offered for
    chats, collectors, actions, batches and connections (queue ids are file
    paths), and not for an expired chat.
  - The narrow layout starts under 920 pt of content (a window under about
    1140 pt): the list then keeps about 480 pt beside the 400 pt detail. At
    a 1000 pt window the wide layout left the summary about 100 pt (with a
    tag and "time · source"), so it is narrow there too. The canvas's 890 pt
    frame is a snapshot size; the app can't be narrower than 900. Snapshot
    guards `activity-width-1140` / `-1100` show both sides.
  - Deviations from the board: the detail shows only facts the core logs. The
    collector "Last run" says the total collected ("2 files collected"), not
    what that run added. The failed run's card leaves out "The next run at …
    tries again", because the entry has no schedule. The "(its weekday
    schedule)" and "(you approved it)" asides aren't shown.
  - Live events join the list when no filter excludes them; with a search the
    page is asked for again (debounced), because the core also matches
    details.
- **Activity log: the owner's answers.** Spec: [Activity log and
  trash](activity-log.md).
  - The Activity design under History (canvas v66) is approved; build the Mac
    screen.
  - The limits stay: a 30-day trash, and a log of 180 days (about 22 MB at
    most).
  - Chats deleted while Keep history is off **do** go to the trash, kept for
    24 hours.
  - Actions deleted forever, and jobs removed from the list, do **not** go to
    the trash. They stay logged with the reason.
  - Scheduled runs that found nothing stay out of the log; there is no "Show
    routine runs" switch.
- **No Connecting state: connected, or Set up connection (canvas v59,
  mac-connections).** Specs: [Actions](actions.md) → Settings · Connections,
  Connections, Toolbar. The owner: "let not display the connecting at all. It
  will be either connected or it needs to set up the connection." Built:
  - The Actions toolbar, empty states and the "isn't connected" card say
    **Set up connection** and open Settings → Connections; the expired card
    says **Update the token**. `ToolbarConnection` has two cases. The
    `jira-frame-4` / `confluence-frame-4` snapshot states are gone.
  - Settings → Connections: the Atlassian token form is open whenever it
    isn't connected (no "Sign in in your browser", "Waiting for browser",
    Open the page again or Cancel). **Get an API token** only opens the
    page. The app's `signingIn` set and `startSignIn`/`cancelSignIn` are
    removed; DistillKit still decodes `signing_in` (additive decoding) and the
    UI shows it as not connected, like `expired` and `error`.
  - Connect shows no "Connecting…": the button is disabled while the request
    runs. The client waits 45 s for `POST /connect` (the core gives Atlassian
    30 s), so a refusal or a slow site always ends in the core's answer.
  - A refused token (the core's 400 "didn't accept that email and API token")
    shows the canvas 9b banner and keeps the form filled, **including the
    token**, until Atlassian accepts one. This supersedes "cleared on submit
    whatever the answer": the token lives only in the view's memory.
  - The core's `not_connected` / `auth_expired` messages now say to paste an
    API token in Settings → Connections, not "Sign in"; the Mac card appends
    its own next step to the shorter expired message.
  - Not built from v59: the connected card's default project / issue type /
    space pickers (the core has no projects or spaces route yet), and the
    account as an email (the core stores Atlassian's display name).
- **Queue folders, Google Docs, Refresh and the queue check built in the Mac
  app (mac-queue-items, canvas v64).** Specs: [Queue and
  batching](queue-and-batching.md) → "Built in the Mac app",
  [Collectors](collectors.md) → "Include subfolders". Decisions taken while
  building:
  - **Refresh shows a result only when pressed.** Window and periodic scans
    (`queue.scanned`) move "checked at" and the list silently; a result after
    every focus change would be noise.
  - **Window scan on the main window only, every 15 s at most,** so the quick
    panels, Settings and fast window switching don't rescan.
  - **"Used in" is a heuristic.** The core keeps no source → page map, so
    Review matches each file's vault path or its path from the batch folder in
    the changed pages' text (bundle writes while waiting, vault pages once
    applied). "Not used" only when every page was read and some file
    matched: the core's prompt doesn't fix how pages cite inputs, and the
    real citation form wasn't checked against a live ingest, so a batch where
    nothing matches shows no suffixes rather than "not used" everywhere. A
    core field would make it exact.
  - **The tree follows the spec's 5 entries per folder,** not the board's
    one-photo example. Too deep and Empty folder get their own pills; other
    Refresh results read "1 new item found · 1 item gone" and "2 items
    changed".
  - **Folder rows in a running batch and in History read the folder from the
    vault's inbox** (read-only walk, like the core's), since a job keeps only
    `folders` and `files`.
  - **Only https links on docs.google.com or drive.google.com open** from a
    .gdoc row, a second check after the core's.
  - **Remove of a folder asks first** (a system confirmation, Move to Trash);
    files keep the one-click ×.
  - **Collector run lines follow the board** ("Tea tasting trip/ (folder · 5
    new of 12 files)"), and a run with a subfolder counts items.
- **Collector scripts as real files, TypeScript, packages, and Run now
  everywhere (owner request; core, API and CLI built; Mac UI designed on
  board CollectorsScriptFiles, not built).** Spec: [Collectors](collectors.md)
  → "Script files and packages (v6)". Supersedes "inline code stored in the
  collector's record" from the first Collectors entries. Decided by default
  (owner may revisit):
  - **Storage:** one folder per script Distill keeps,
    `<state>/collectors/scripts/<id>/collector.<ext>` plus its manifest and
    installed packages; `collectors.json` keeps `{file, managed: true}`
    with the real absolute path, so an older core (or the shipped app)
    still runs and shows it. The user's own file stays supported and is
    never written by Distill.
  - **Migration at start, not on demand:** same bytes, so consent survives;
    `collectors.json.pre-script-files-<time>` is written next to the file
    (not in `<state>/backups/`, which `distill.sh` prunes and restores
    from). Migrated node code keeps `.mjs` so it runs exactly as before; new
    JavaScript is `collector.js` (Node's module detection handles `import`).
  - **Old clients keep working:** `{inline}` is still accepted and written
    to the managed file; a `{file}` equal to the managed path stays managed;
    a `{file}` inside another collector's folder (Duplicate) makes a copy, so
    deleting the original can't break the duplicate.
  - **Delete → trash for 30 days**, without `node_modules`/`.venv` (they
    can be reinstalled and can be large), with the record as
    `collector.json`. Kept simple for the lead: the activity-log teammate
    may build a shared trash; this one can fold into it.
  - **TypeScript runtime: Node's built-in type stripping, no new
    dependency.** Node 22.22.1 (the owner's) strips by default without a
    warning; 22.6–22.17 get the flag; older Node fails with a clear message.
    Fallback: if the user adds `tsx` to the script's package.json and
    installs, tsx runs it (for `enum`/`namespace`). The version probe runs
    on the login shell's `node`, not the core's.
  - **Packages: JavaScript/TypeScript via `npm install` in the folder, and
    Python too (my call):** `requirements.txt` → a `.venv` in the folder,
    and runs use `.venv/bin/python3`. The owner's meeting-notes script needs
    pip packages, and a per-collector venv avoids `pip install --user` into
    the shared Python. Packages only for scripts Distill keeps (Node
    resolves packages from the script's location).
  - **Consent covers the manifest** (installing runs third-party code):
    without a manifest the hash is exactly `sha256(script)` as before; with
    one it is a hash over both files' hashes. The lockfile is not covered
    (npm writes it during install), documented as a known gap. Installs
    need the current version allowed. `allowedFiles` records each file's
    hash so the consent card can say what changed.
  - **Installs:** explicit (`POST …/install`) and before a run when the
    manifest changed since the last successful install (or packages are
    missing). One operation per collector (Run now / Install refuse while
    the other runs). 10-minute timeout, Stop, last 64 KB of interleaved
    output with URL credentials and auth tokens masked. Installs don't wait
    for batches. npm lifecycle scripts are allowed (packages like esbuild
    need them); consent to the manifest covers them.
  - **Saving from the app can't clobber an external edit:** `PUT …/script`
    takes the sha256 the editor loaded and refuses when the file changed.
  - **Run now:** the core already ran every kind in every state; the Mac app
    hid it (hover-only in the list, hidden while a script needs OK and while
    editing, missing from ⋯). Designed: one title-row slot for every state,
    "Allow and run" when a script needs OK (calmer than a disabled button
    with a reason), first item in ⋯, a play button on the selected row, and
    the manual run's result plus output tail in the status card. "Save and
    run" was dropped: a saved change always needs a new OK first.
- **Activity log and trash (owner request: "a log system for the app
  activity"; built in the core, API and CLI; Mac UI designed, not built).**
  Spec: [Activity log and trash](activity-log.md). Three chats and a script
  collector disappeared, the owner had deleted them, and nothing could show
  it. Decisions and defaults, each one open to veto:
  - **Log in the core, not in clients.** One wrapper over the core facade,
    plus the core's event stream for what happens without a request. A mapped
    type classifies every core method (logged, read, event or quiet), so a new
    method fails typecheck until someone decides. Clients log nothing.
  - **Sources come from a header.** The CLI sends
    `X-Distill-Client: cli` or `agent` (`agent` inside Claude Code or Codex;
    `DISTILL_CLIENT` overrides). The Mac app is recognised by its URLSession
    User-Agent until it sends `app` (open question). Unidentified HTTP is
    `api`. Timers enter a `scheduler` context explicitly, rather than
    treating "no context" as the scheduler, so tests and dev scripts read as
    `core`. Background work inherits the source of the request that started
    it, and runs are attributed by their `trigger`.
  - **Never log content or secrets.** Titles, ids, counts, sizes, paths and
    changed keys only. Questions, answers, note text, replies, action bodies
    and script bodies are never logged; a script is described by size, line
    count and a 12-character hash prefix. Everything also passes a redactor:
    known token shapes, `key=value` with a secret-looking key, Bearer, URLs
    with credentials, long hex or base64. Details whose key looks secret are
    dropped.
  - **Distill's trash for chats and collectors**, because the log alone could
    not have brought the script back. The copy is written before the delete,
    and a delete whose copy can't be written is refused. Kept 30 days, at most
    200 items and 50 MB. Restore: a collector comes back off with consent
    cleared; a chat is refused if its id exists. The CLI restores chats only
    (it never adds collectors).
  - **Not trashed:**
    - chats deleted while Keep history is off (the user chose not to keep
      chats; logged with that reason)
    - retention removals (logged as `chat.expired` and `action.expired`)
    - actions deleted forever
    - jobs removed from the list
    - queue files, which already go to the macOS Trash and are logged with
      that path
  - **Quiet by default:** scheduled runs that found nothing, and skipped
    ticks, aren't logged (they are in run history); queue scans are logged
    only when files appeared or went; settings saves that change nothing
    leave no line; core warnings aren't logged.
  - **Storage:** `<state>/activity/activity.jsonl`, append-only JSON Lines,
    0600. One O_APPEND write per entry, at most 8 KB, so concurrent writers
    never interleave. Rotation at 2 MB under a lock directory (stale after
    30 s). Keep 10 rotated files and 180 days. Both `activity/` and `trash/`
    stay out of `distill.sh backup` and restore, so history is never rewound.
  - **API and CLI:**
    - `GET /v1/activity` filters by type or family, kind, object, source,
      since/until, text and outcome. `limit` is 50 by default (max 500), with
      a time-sortable id as the cursor.
    - `GET /v1/trash` and `POST /v1/trash/:id/restore`.
    - `distill activity` and `distill trash`.
    - Contract additions are additive: the activity types, a `conflict` error
      code, and an `activity` CoreEvent.
  - **A restored chat starts its retention days again** (`updatedAt` = the
    restore time). Without this, a chat older than `historyDays` would be
    removed again by the next hourly sweep, right after Restore.
  - **Mac UI placement: History → Activity**, a fourth History sub-item.
    History already answers "what happened" and is where a missing chat would
    be looked for. Settings is configuration. A new window would be a new kind
    of place for one list. Calm by default: one line per entry, pills only for
    failures, details and recovery in the detail pane. At 890 pt the detail is
    pushed in place of the list.

- **Queue folders, Google Docs and the queue scan built in the core, API
  and CLI (core-queue).** Specs: [Queue and batching](queue-and-batching.md)
  → "Built in the core", [Collectors](collectors.md) → "Built: subfolders and
  .gdoc". Built to the design above; decisions taken while building:
  - **Root cause of the missing folder:** the scanner kept regular files
    only. A 5-second rescan already existed, so no watcher was added, and
    top-level files removed by hand already dropped out within 5 s.
  - **Two scan depths.** The 5-second tick reuses each folder's last walk
    while its own mtime is unchanged; Refresh, the window-active scan, the
    queue check and every batch walk folders again. That keeps the tick
    cheap with big folders, gives the queue check a job, and keeps the wait
    rule exact at pickup even with the check Off.
  - **`POST /v1/queue/scan` returns the designed counts plus the entries**
    (`addedEntries`, `removedEntries`, `changedEntries`, `entries`) and a
    `trigger`, because the owner asked for what changed, not only how
    much. Every full scan emits `queue.scanned` (older Mac builds decode
    unknown events as `.unknown`), so "checked at …" can follow the periodic
    check.
  - **Extra folder problems beyond "too big":** `'too deep'` (more than 8
    levels; the owner asked for a depth limit) and `'empty folder'`. A
    walk stops after 5000 entries and counts as too big, so a huge folder
    can't stall the tick. A folder whose only files are `.gdoc` waits like
    a `.gdoc`.
  - **Folder files get no per-file AI labels**, and "N sources" counts a
    folder once.
  - **`includeSubfolders`: new collectors on (as designed); collectors saved
    before this build read as off**, so an existing collector doesn't start
    taking subfolders without the user choosing it.
  - **`.gdoc` link validation:** https on docs.google.com or
    drive.google.com only, else built from a valid `doc_id`; anything else
    is "no link inside". The `email` field is never read out.
  - **Inbox mode:** when the queue folder is the vault's `inbox/`, existing
    subfolders there that no batch took become folder items and will be
    batched.
  - Drop and paste intake still skip folders (`copyIntoQueue`); only
    folders moved in by hand or by a collector become items.

- **Queue: folders, Google Docs, Refresh and the queue check (owner
  request; designed, built next).** Specs: [Queue and
  batching](queue-and-batching.md) → "Folders, Google Docs and syncing", and
  [Collectors](collectors.md). Open points decided by default:
  - **Sync is a periodic rescan, not a file watcher.** It runs every 5
    minutes by default, when the window becomes active, and on Refresh.
    Watchers miss events on synced folders. The setting lives on Settings →
    Batching: Every minute, 5 min, 15 min, 1 hour or Off.
  - **Refresh sits next to the queue path** (Copy path · Reveal in Finder ·
    Refresh), because it re-syncs that folder. Its result shows for 4 s,
    then "checked at …".
  - **A top-level folder is one item.** Limits are 200 files and 500 MB; a
    bigger folder gets the problem "Too big", even for Process now. A folder
    counts as one item and one source. The settle wait uses the newest
    change inside. In the batch the folder moves whole to the inbox, every
    file is a source by its relative path, and a tree block (paths, names,
    sizes) goes into the prompt.
  - **A .gdoc waits; it is not processed** (coordinator, 2026-10-04,
    superseding a first draft that queued it as a link note). A local .gdoc
    is only a pointer, so its content can't be read. The row says "Google
    Doc · needs Google Drive access", has a Waiting pill and a short hint,
    and is held out of every batch, Process now included. Google Drive
    fetching is being decided separately.
  - **The Folder collector's Include subfolders is on by default.** The
    dedupe unit is the file hash. A subfolder is collected when any file in
    it is new or changed. In copy mode only the new and changed files are
    copied, and the manifest keeps the full tree. The collector also
    collects .gdoc files, which then wait in the queue.
  - **QueueRowView is the canvas component for queue rows** and maps to the
    Swift view of the same name; kind, expanded, tree and hint are
    `swiftPending`. The legacy QueueRows board is not migrated; the
    QueueRowView states board supersedes it for folder and Google Doc
    rows.

- **Collectors macOS UI built (mac-collectors).** From canvas v63; spec
  [Collectors](collectors.md) → "macOS app (built)". Decisions taken while
  building:
  - The sidebar count is computed from `status.needsAttention`, never drawn
    from the board (board E shows none with a failed and a waiting row).
  - A running Folder run reads "Copying…": the core has no per-file progress
    while it runs. Adding progress is a core change for later.
  - Daily schedules in list rows keep AM/PM ("Daily at 7:00 AM").
  - In a 900 pt window the list narrows to 240 pt and the title row wraps its
    controls under the name, so the name isn't cut.
  - The Add and Already collected sheets are drawn in the window over a
    dimmed backdrop, as the boards draw them, not as system sheets.
  - Queue → Create folder creates the queue folder from the app (the same
    `mkdir -p` the core does when files arrive), so no core route was added.
  - Not built: the "Collected by …" line on queue rows (needs a `QueueEntry`
    field in the core) and first-failure notifications.

- **Collectors: the one-way batch gate is accepted for v1 (lead).** A script
  never starts while a job in its vault is running, but a batch that starts
  while a script runs doesn't wait for it. That's safe enough, because a
  batch only takes files that have stayed unchanged for the wait-before-pickup
  time, so a half-written file isn't taken. Revisit if scripts write
  anywhere other than the queue folder.
- **Collectors built in the core, API and CLI; the contract is final for
  the Mac UI.** Code: `core/src/collectors/`, routes under
  `/v1/collectors`, `distill collectors list|run|history`. Spec:
  [Collectors](collectors.md) → "API and contract (built)". The decisions
  taken while building:
  - **The proposal's shapes are kept**, under `/v1` like every route. Runs
    gained `queued` (waiting for one of the 2 slots, or for a batch in the
    same vault) and `stopped` (Stop), plus `counts`, `error {code,
    message}`, `skipReason` and `sha256`, because the UI's lines ("Copied 3
    files · skipped 2 already collected", "Not run · the script changed")
    need them. `Collector.status` is computed on read, never stored.
  - **Events keep the spec's dotted names** (`collector.changed`,
    `collector.run.started|output|finished`), unlike the older one-word
    event types, so the spec and the wire agree.
  - **"While a batch applies" means a job in that vault in state
    `running`** (agent turns and the apply). A batch waiting for approval
    can sit for days, so it does not hold scripts. A held script run waits
    in the queue instead of being skipped, so a daily schedule doesn't lose
    its day. Folder runs are never held.
  - **Catch-up:** a due tick handled more than 2 minutes late, or with two
    or more ticks missed, is one `catchup` run. The last tick is stored in
    `collectors.json`, so a restart catches up too. Turning a collector on
    or changing its schedule never catches up the time before.
  - **Consent extras:** changing the interpreter clears consent (the same
    code under another interpreter is another program). A script is
    always created off. A refused scheduled run is recorded once per hash,
    not on every tick.
  - **Forget returns what it removed and Undo is a core call**
    (`collected/restore`), so Undo survives a refresh. Forget rewrites the
    ledger atomically, keeping lines it can't read; collecting only appends.
  - **Deleting a collector deletes its run history**; the ledger stays.
  - **Unchanged, already collected files get no per-file line** (only the
    count), so run history doesn't grow with the size of a copy-mode
    folder; `…/runs` returns the newest 50 by default.
  - **Open for the lead: the batch gate covers one direction.** A script
    never starts during a batch in its vault, but one already running when
    a batch starts or is approved is not waited for.
  - **Scripts run with the core's environment minus every `DISTILL_*`
    variable**, plus the four documented ones, and the login shell's
    `PATH`. No sandbox, as the spec says.
  - **No built-in registry yet.** Folder is the only built-in; the registry
    comes with the second one, additively.

- **Collectors UI: a calmer pass (the owner found it crowded).** The detail
  now answers one question at a glance: a status card with the last run,
  then a compact read-only settings block with Edit (the form opens in
  place), then the last three runs. Script internals (interpreter, timeout,
  cron, arguments) sit under a collapsed Advanced row. Per-file results and
  output show only in an opened run. List rows have one status line, and a
  pill only when something needs a look. Adding is a three-step sheet
  (kind, source, schedule) with defaults. The header has a single button,
  and the queue path moved into the Into setting. The content decisions are
  unchanged. Spec: [Collectors](collectors.md).

- **Collectors: the owner's answers.** These supersede the defaults in the
  "Collectors (designed, not built)" entry below where they differ. Spec:
  [Collectors](collectors.md).
  - **One list for all vaults.** Each collector picks its target vault.
  - **Folder copies by default and leaves the original in place.** Moving
    is optional: the Folder detail has "After collecting: Keep the original
    (copy) / Move it to the queue", with Keep as the default. Run history
    and per-file lines say Copied or Moved to match. This replaces "Folder
    always moves".
  - **Already collected is visible.** Because originals stay in the folder,
    the ledger is what stops repeat copies. The detail shows "Already
    collected: 128 files" with View…, and each file in that list can be
    forgotten so it is collected again.
  - **Dedupe by content is the owner's choice, not a default.** An edited
    file (same name, new content) is collected again. An identical copy
    under another name is skipped. Forget in the Already collected list
    lets a file be collected again.
  - **The queue path is shown as `~/…`.** The full path is on hover and on
    Copy path.

- **Collectors (designed, not built): defaults chosen for the open
  questions.** Spec: [Collectors](collectors.md). Canvas: row "7 ·
  Collectors" (Collectors, CollectorsScript) and the queue path on Queue
  (Main, MainLoading, MainEmpty). These are the defaults; the user can
  overturn any of them.
  - **Sidebar item, no Settings section.** Collectors sits under Queue
    because it feeds the queue. Collectors have runs and errors, so they
    are not preferences, and editing them in two places would drift.
  - **The list is global, with a target vault on each collector.** It
    defaults to the active vault. This is still open in the spec.
  - **Folder always moves (never copies).** It skips hidden files,
    subfolders, and files changed within the settle delay (the same 10
    minutes as batching). On a name clash it adds " 2" and never
    overwrites.
  - **Dedupe is by content.** The vault ledger (Folder collectors only;
    script runs never enter it) is keyed by sha256, with
    path, size and mtime as a shortcut that skips hashing. A file whose
    content was collected before is skipped and stays in the source
    folder, whatever its name. Same path with new content is collected
    again. The ledger outlives the collector.
  - **One schedule model: 5-field cron in local time; presets are
    shorthands.** The cron is always shown next to the preset. A missed
    run catches up once, a tick that overlaps a running run is skipped,
    and at most 2 collectors run at once.
  - **Script contract.** The script gets `$1` (vault) and `$2` (queue
    folder) plus `DISTILL_VAULT` and `DISTILL_QUEUE_DIR`. It runs in a
    fresh temporary working folder with stdin closed. The timeout is 5
    minutes by default and 1 hour at most; Distill sends SIGTERM, then
    SIGKILL 10 s later. Exit 0 is success. Files a failed or timed-out run
    wrote stay in the queue.
  - **Consent is bound to the script's sha256.** The core checks the hash
    before every run. A changed file or a saved inline edit pauses the
    collector until the user allows the new version. No sandbox is
    promised. Scripts never run during note processing.
  - **Run history lives in the collector, not in History.** It is kept for
    30 days or the last 200 runs, with the last 64 KB of stdout and
    stderr. History → Jobs keeps showing the batches, and queue rows name
    the collector. There is no notification on success; a macOS
    notification is sent only on the first failure after a success.
  - **The queue path on Queue is shown with `~`.** Copy copies the
    absolute path, and the hover shows it. This is open: the user asked for
    the "full path". The Folder default source is
    `~/Distill Inbox`, and Distill creates it on first save.
  - **API and contract are proposed only.** The lead owns `contracts.ts`.
- **Design schema: page boards.** Main and MainLoading moved from
  `legacy/gen_audit.py` into `design/screens/queue.json`. They are a new
  "page" board kind (one window, the document wrapper and the `sc-for`
  script kept verbatim) and were imported byte for byte with
  `tools/import_board.py --page`. `gen_audit.py` must no longer run over
  them. A screen file can add its canvas row title (`rowNote`), and row
  lists can use a row component other than ActionRow.

- **Settings shows one page per section, matching the canvas; the group
  pages were a deviation.** The SettingsNav board draws each nav item as its
  own page (To-do defaults and Connections each fill the page alone), but the
  app rendered three long group pages (General, AI, Actions) and scrolled to
  the section, so the view showed the end of the previous section and the
  start of the next, and the remembered position was shared per group. Now
  each section is a page with its own scroll view: its title and note as the
  header, then only its content; no group header. Advanced stays at the end
  of AI runners (most of it configures how the Claude Code runner and the
  core start; its search entry already pointed there). Supersedes the scroll
  memory entry below in two points: an unvisited page opens at its top (not
  at a heading on a shared page), and "Open Actions ›" now counts as a deep
  link (top of Actions) rather than a nav pick. Search results land on the
  matched row where there is one; every search entry is checked to have its
  row. → [vaults-and-settings](vaults-and-settings.md#window-sections-and-search)
- **Settings fits narrow windows; minimum 820×600 (was 900×600).** The
  Models for tasks row (title 190 pt + three fixed pickers) needed ~650 pt
  of page, so at 900 the content was wider than the window and SwiftUI
  centred and clipped it: the nav lost its left edge, the right column its
  right. The page column is now `minWidth: 0` and clipped (as the main
  window), and rows reflow (pickers under the title, one runner column,
  counters and connection buttons under their text). The minimum went below
  the user's usual ~890 pt so that width is reachable and tested. The narrow
  reflow is not drawn on the canvas yet. → [vaults-and-settings](vaults-and-settings.md#window-sections-and-search)
- **Settings remembers scroll per section, in memory, per window session.**
  An unvisited section opens at its top; a visited one where you left it;
  search results and deep links go to the section; closing Settings or
  quitting forgets it all. Read and set through the page's NSScrollView
  (macOS 14 has no SwiftUI offset API); where to land is decided when the
  page is asked for, because a new scroll view reports 0 before it is
  restored. The window's content is rebuilt on reopen. → [vaults-and-settings](vaults-and-settings.md#window-sections-and-search)

- **Atlassian sign-in stays a pasted API token (for now):** browser sign-in was
  considered via Atlassian's remote MCP server (OAuth 2.1 + PKCE, no shipped
  secret), a hosted token broker, or Claude's Atlassian connector. The user chose
  to keep the token flow; revisit with a spike on the MCP route. → [actions](actions.md)

## 2026-10-03

- **Actions redesign (canvas v57): Complete everywhere, one toolbar, list
  plus detail.** Complete ("you've handled it") is a handler of every type,
  Slack included. It works from ready, created and sent (and open), moves
  the item to `done` whatever the external status says, records the status
  it left as the `done` event's detail, and Undo (`restoreAction`) puts it
  back exactly there. Bulk Complete shows one toast, "Completed N · Undo",
  and its Undo restores all of them (before, only the last one came back).
  To do keeps only its checkbox: to-do rows get no hover Complete, since the
  checkbox already is Complete. The automatic Done when Jira or Confluence
  reports Done on refresh is kept; its Undo returns the item to created.
  Slack's empty state has one primary action, Open To do, because messages
  come from notes and to-dos (Send to), not from a blank compose. History →
  Actions filters dates by presets only (Today, This week, Last 30 days); no
  date-range picker until someone needs one. See [Actions](actions.md).
- **The schema owns the Actions boards from canvas v57:** ActionsTodo,
  ActionsSlack, ActionsJira, ActionsConfluence and ActionsHistory render from
  `design/screens/actions.json`; edits go there (and to its fragments), never
  to `gen_actions.py`, which must not regenerate them. Fragments (bespoke
  markup in `screens/actions/`) are an allowed migration step; each becomes a
  component when it is next touched. ActionsOverview and ActionsAsk stay
  legacy for now.
- **The design is a schema in the repo (`apps/distill/design/`):** the
  canvas is rendered from `tokens.json` (generated from Theme.swift),
  `components.json` + `components/<Name>.dc.html` (one entry per Swift view)
  and `screens/*.json` (base screens, states as overrides, boards as ordered
  state lists) by `render.py`. Why: every state was a hand-generated copy
  made by unversioned scratchpad scripts, so one change meant regenerating
  and checking many copies. `test_design.py` (in `make test`) fails when a
  component, prop or token drifts from Swift. A prop the view derives is
  `"swift": false` with a `why`; a prop designed but not built is
  `"swiftPending"`. The old generators live in `design/legacy/` until their
  boards move over. Publishing stays manual (the lead). See
  [Design process](design-process.md).

## 2026-10-02

- **One Swift view per canvas component (IconButton, Segmented):**
  `IconButton(systemImage, size, tint, fill, help)` in Theme.swift replaces
  every hand-drawn icon-only button (⋯, pencil, trash, xmark, pin, stop,
  gear, terminal); call sites pass size/tint/iconSize so nothing moves.
  `Segmented` and `SegmentedPills` were the same view, so `Segmented` keeps
  the superset (font, track, help) and `SegmentedPills` is a typealias; the
  canvas keeps both names. → [design-process](design-process.md)
- **Undo of "Add all" dismisses:** confirmed items still untouched since they
  were found count as untouched, so `dismissActions` drops them with no
  History entry (ActionsAsk frame 7) instead of the client falling back to
  remove. → [actions](actions.md)
- **Settings as built (mac-settings):** search lists results by section and
  opens them (it does not filter the controls in place); To-do defaults has
  only the stored settings (group, sort, retention incl. Forever, overdue
  reminder). The board's extra rows (Show, due filter, what new to-dos get,
  completed to-dos, reminder time) are deferred until the contract stores
  them. Connections is one Atlassian card with a pasted API token; field
  defaults live on each type's page. → [vaults-and-settings](vaults-and-settings.md), [actions](actions.md)
- **Actions client (mac-actions):** the sidebar badge counts open to-dos and
  drafts in `ready`; pending items wait in "To confirm" and are not counted
  (matches the SidebarStates numbers). Every Undo is `restore` (complete,
  remove, mark as sent, Send to, a dismissed Ask row); Undo of an automatic
  add or of Add all is `dismiss`; Undo improve is `undo-improve`. To-do group
  and sort start from Settings → To-do defaults; a change on the screen is
  remembered in app defaults (`distill.todo.group` / `.sort`). Menus inside
  scrolling lists (answer buttons, Found rows, Slack recipient) are popovers
  in the app and drawn panels in snapshots; the To do filter menus are drawn
  panels. History's "Kept until" follows `historyDays`. → [actions](actions.md)
- **Selected answer text is not an action source yet:** Ask answers render as
  a SwiftUI `Text`, whose selection the app can't read, so "To-do from
  selected text" is listed disabled and the selection bar (Add as to-do /
  Send to / Copy) waits for a selectable answer view. → [ask](ask.md)
- **Open in Actions from the Ask screen leaves Ask,** which deletes the chat
  when Keep history is off (as leaving Ask always does). Items keep the quote
  and question; their "Ask chat" source stops being a link once the chat is
  gone. → [ask](ask.md), [actions](actions.md)
- **Settings uses the shared `ActionTypeInfo`** (`SettingsActionType` is now a
  typealias with Settings helpers); the private JSON decoding is gone.
- **Settings window built with section navigation and search** (mac-settings):
  - Picking a section shows its group's page (General, AI, Actions and
    connections), scrolled to that section. This follows the Settings board,
    which shows each group as one page with an h2 per section. Search results
    are a list of settings that open their section. They don't filter the
    live controls in place.
  - The search index is data, `SettingsIndex`. Each action type adds its own
    entries from the core's type list. Why: a new setting must be searchable
    by adding one entry.
  - Advanced moves to the end of the AI page. Setup problems move to the top
    of every page.
  - Deep links use section ids through the `distill.openSettingsSection`
    notification. The image "Settings" link opens Models for tasks (Text from
    images).
  - `actionPreferences` is kept as raw JSON in the app, because the core
    merges settings one top-level key at a time and unknown nested keys must
    survive.
  - Finding actions is stored once, in `actionPreferences.findSelection`.
    Both Settings rows edit it. The core reads findSelection, then
    taskDefaults.actionFind, then Sonnet.
  - To-do defaults ship only what the contract stores: group, sort, history
    days and remind overdue. The board's Show, Due date filter, New to-dos
    get, Completed to-dos and reminder time wait for contract fields.
  - Connections show one Atlassian card for Jira and Confluence, not two
    rows, because it is one sign-in. Its sign-in panel holds the site, email
    and API-token form, since a pasted token replaces the board's
    browser-only flow.
  - Field defaults live on each type's page, not on the Connections card.
  - Prompt editors use the shared Markdown editor. Placeholders aren't tinted
    blue as on the board.

  → [vaults-and-settings](vaults-and-settings.md), [actions](actions.md#settings)
- **PrimaryButton and SoftButton take a size**: regular 40, small 30, mini 26
  (font 14/13/12, padding 20/14/11, SoftButton regular 18), with
  PrimaryButton `enabled` (45% when off) and SoftButton `stroke`. Existing
  call sites stay regular. → [app-shell](app-shell.md)
- **Action sources say more:** an item from Ask records its turn
  (`turnIndex`) and whether it restates the answer's gap (`gap`; the Ask Gap
  callout then hides). A manual item records who added it (`by: 'agent'` for
  the CLI/API, absent = the user), so the "added by" filter can tell them
  apart. → [actions](actions.md)
- **Fresh quick note has no source** (shows "+ Source"), even though Write a
  note remembers the last source. Clicking the flask while its green ring
  shows (a quick ask still answering) opens that chat on the Ask screen.
  → [quick-actions](quick-actions.md), [floating-icon](floating-icon.md)
- **Actions core (core-actions).** Decided while building:
  - `historyDays <= 0` keeps action History forever (Settings "Forever"); the
    decoder does not clamp it.
  - `dismissActions` doubles as Undo for items added without confirmation,
    when they are untouched since found (only found / drafted events): they
    become `dismissed`, with no History entry. No separate method.
  - Route table as in [actions](actions.md) → API. A failed handler (Jira 400,
    not connected, offline) returns 200 with the item and `error` set; the
    draft is never lost to an HTTP error.
  - The action tasks (`actionFind`, `actionDraft`, `actionImprove`) never
    block batching; a broken runner shows as a failed "Finding actions" step.
    Why: actions are optional after the apply; ingest must not stop for them.
  - A batch is searched once (`processedJobs` in actions.json, recorded before
    the model runs), so a restart or a repeated job event never finds twice.
  - A user-edited prompt never loses the item context: it is always appended
    after the instructions, with the note text wrapped as data.
  - Atlassian: the email and API token go to the Keychain; the site, display
    name and account id to `<state>/connections.json` (no secrets).
    `listConnections` never reaches the network; a 401 marks it expired.
  - An interrupted `creating` comes back `ready` with an error asking the
    user to check Jira / Confluence before retrying (it may have been
    created). Why: never create twice silently.
  - Dedupe goes beyond live items for quotes: a line already handled (done,
    removed, sent, dismissed) is never suggested again when a later batch
    rewrites the same page (same note and quote, or a quote of 24+ characters
    from any page). The title rule still counts live items only, so a
    recurring to-do can come back. Within one run only the title rule applies
    (one sentence can hold a to-do and a message). Why: a compounding wiki
    rewrites pages; dismissed items kept coming back.
  - `restoreAction` is the one Undo: removed → where it was; done → open /
    created; sent by Mark as sent → ready; sent by Send to → back, and the
    item it became is deleted while untouched (else `invalid_state`);
    dismissed → pending (or where an auto-added item was).
  - "Try again" for a failed find: `POST /v1/jobs/:id/actions/find`
    (`findJobActions`, an engine extra like `deleteJob`).
  - Models (lead): finding `findSelection` → `taskDefaults.actionFind` →
    Claude Code · Sonnet · medium; drafts / improve per type
    `draftSelection` / `improveSelection` → `taskDefaults.actionDraft` /
    `actionImprove` → Claude Code · Sonnet. Settings writes only
    `actionPreferences` for these.
  → [actions](actions.md)
- **Design follow-ups (lead, from the canvas audit):** the flask hover menu
  gets an "Actions N" entry, while the flask badge stays queue-only. Every
  elapsed timer becomes a clock time ("started at 3:12 PM"), including "Still
  working". The Ask Gap callout shows only when the gap did not become an
  action. The Settings board is split into General / AI / Actions &
  connections windows. Job.actionsFound records what a batch found.
  → [actions](actions.md), [app-shell](app-shell.md)
- **Design system with components mapped one-to-one to Swift views.** Shared
  parts (sidebar, window shells, style bar, buttons, chips) are defined once
  and imported on the canvas; a Distill design system artifact follows, with
  each component named after its Swift view and props equal to its states.
  Why: changing a menu must not mean editing every board. → [design-process](design-process.md)
- **Pages with more than 2 tabs use sidebar sub-items** instead of a tab bar
  (Actions, History, Labels). Why: the tab bar was too crowded. → [actions](actions.md), [app-shell](app-shell.md)
- **Specs and this log are updated with every feature and decision.** Why:
  user request. → [index](index.md)
- **Actions** (to-dos and action types from notes and Ask answers). Decided
  with the design:
  - Types and handlers are registry data, so Email or Send in Slack can be
    added without changing the contract.
  - Confirm before adding is ON by default for both notes and Ask (user: "it
    should default ask the user to confirm first"; configurable per source).
    This replaces the earlier "extract automatically" for notes.
  - Actions are found after Approve & apply, as the last batch step.
  - Jira and Confluence items are created only on the user's click; drafts
    may be written on finding (default) or on request.
  - Improve after edit uses Sonnet by default (configurable); to-dos get no
    improve pass. Each type has a default draft prompt and improve prompt,
    editable with Reset to default.
  - Copying a Slack message isn't sending: **Mark as sent** ends it.
  - Atlassian: one connection for Jira and Confluence; API token in the
    Keychain, opened via the browser (OAuth needs a client secret we can't ship).
  - Status of created items: manual Refresh only for now.
  - History keeps removed/done/sent actions 90 days (configurable).
  → [actions](actions.md)
- **Settings get section navigation and search.** Why: too many settings to
  scroll. → [actions](actions.md), canvas SettingsNav
- **Quick windows open a third bigger (560 × 214) and start fresh after
  close**, centered; a dragged size is still kept as the opening size; a quick
  ask still answering keeps going and lands in History. → [quick-actions](quick-actions.md)
- **Canvas first, then build.** Every visible change goes to the canvas
  before code; the user may waive the separate confirmation per request.
  → [design-process](design-process.md)
- **User data is permanent.** Updates replace only the app bundle; backups
  before every update; schema changes are additive; unreadable files are set
  aside, never overwritten. → [user-data](user-data.md)
- **New chat never discards a running question.** It moves to the background
  and lands in History; only Stop stops it. → [ask](ask.md)
- **Images stay inside the text** (no Keep / Extract switch). Hover →
  Extract content replaces the image with its text in place (⌘Z restores).
  "Text from images" defaults to Claude Code · Haiku · Low. → [notes-composer](notes-composer.md), [markdown-editing](markdown-editing.md)
- **Quick ask's model/filter row and the quick note's source sit at the
  bottom**, above the footer; extra height goes to the content. → [quick-actions](quick-actions.md)
- **Quick windows handle ⌘X/C/V/A/Z themselves** (non-activating panels never
  reach the Edit menu). → [quick-actions](quick-actions.md)
- **Queue shows one row per note** (its manifest and images are members);
  "still changing" marks files modified after the core first saw them; the
  flask and sidebar counts equal the visible rows. → [queue-and-batching](queue-and-batching.md)
- **Times are clock times, never ticking counters** ("Ready at 3:14 AM",
  "Asked today at 3:40 AM"). Jobs: "Finished at" for success, "Ended at" for
  failed or cancelled (user: keep the split). → [queue-and-batching](queue-and-batching.md), [app-shell](app-shell.md)
- **Markdown in every text input**, with a style bar. → [markdown-editing](markdown-editing.md)
- **Quick windows: centered, close button, resizable, grow downward and
  scroll only at the screen limit; no scroll-bar strips.** → [quick-actions](quick-actions.md)
- **Settle wait defaults to 10 minutes** (configurable). → [queue-and-batching](queue-and-batching.md)
- **Loading states on every screen that waits for AI.** → [app-shell](app-shell.md)
- **No local previews** (no HTTP servers, browser pages or Playwright); the
  user checks only the real app and the canvas. → [design-process](design-process.md)

## Earlier (2026-10-01)

- **Labels**: the Labels review screen replaces Notes ("don't duplicate
  Obsidian"); notes written in the app wait for the user's confirmation;
  queue-folder files get AI labels marked unconfirmed; the CLI returns
  suggestions with a request ID and falls back to AI labels. Ask filters:
  Any/All labels (configurable default), include unconfirmed (default on).
  → [labels-and-sources](labels-and-sources.md), [ask](ask.md)
- **Ask history kept 10 days**, configurable, pinned chats kept. → [ask](ask.md)
- **Agents cannot approve vault changes**: no approve/confirm command in the
  CLI or plugin. → [approval-and-review](approval-and-review.md)
- **One Node + TypeScript core owns all state**; the CLI, the agent plugin
  and the macOS app are clients of its local API. → [architecture](architecture.md)
