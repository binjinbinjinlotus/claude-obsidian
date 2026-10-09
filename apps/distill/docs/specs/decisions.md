---
type: spec
title: Decisions
status: built
created: 2026-10-02
updated: 2026-10-08
tags:
  - distill
  - decisions
---

# Decisions

Newest first. Each entry: what was decided, why, and where it lives. Add an
entry in the same change that makes a decision; never rewrite an old one —
supersede it with a new entry.

## 2026-10-09

**Done on a batch that added nothing releases its sources (2026-10-09).** The owner pressed Done on
job-20261008-101155-3caf, a failed batch whose apply never ran; it left Review and nothing said its
sources were never added (`claimedFiles` counts every listed job's files, in any state, so the queue
never offered them again). They recovered it by hand with `distill batch reread --job`. Decided:
(a) Done keeps doing what it did (`reviewDoneAt`) and, on a batch whose change never fully applied,
also releases its sources the vault doesn't hold to a re-read. Not "back to the queue": with the
default queue outside the vault the files were moved into `inbox/<date>/` and a scan never sees them
again; a re-read of inbox paths works for both queue setups, and the old batch keeps its claim, so an
inbox queue doesn't also offer them.
(b) The re-read waits for a batch the normal rules allow (`processQueue`: the timer's batch or
Process now). Re-reads otherwise start on the next tick, which would make Done a paid run.
(c) Left out: sources removed in Review, an applied part's, those already in the vault (the re-read's
`existingSourcePages`), and those whose inbox file is gone. Sources that couldn't be read in full
are released too: they were never added, and the full-read repair skips files a waiting re-read
holds.
(d) No UI change: the turn, Activity, and `released` on the job carry it; the error card and Done
are as they were.

**Round 3 of the missing-core work (2026-10-09).**
(a) Apply and check steps read in the present while they run ("Applying the approved changes",
"Checking the plan with the vault core") and in the past only when the tool's result says they
worked; a failed one reads "Couldn’t …". The other tool steps keep one wording: they never claim a
result. A step closed without a result keeps its running words, which claim nothing.
(b) The core event is `settings.repaired` with `key: 'productRoot'`, in the `<noun>.<past verb>`
form of `repair.queued` and `actions.routed`; the Activity type stays
`settings.product_root_repaired`.
(c) A failed inspect that heals the product root is inspected once more with the healed root: the
old error was about the old root.
(d) `stopForMissingCore` no longer falls back to the recovery's own approved hash: the same-signature
recovery already carries it through the spread, and a new signature's recovery never has one.
(e) Not done: counting a batch held for a missing core as Needs you. Both rules (core `needsOwner`,
Swift `ReviewQueueText.needsOwner`) read only the job, and a held batch is a queued approval like
any other. Counting it needs a new marker on the job, or a gave-up recovery on a queued batch (a
combination nothing shows today, with Try recovery again meaning something new), or the setup
problems passed into the Swift rule. Each is more than reusing the badge, so it waits for the owner.

## 2026-10-08

**A missing core holds approved batches; only a changed vault is rebuilt (2026-10-08, round 2).**
The verifier found two paths that still paid with the core gone: the apply queue read a failed
inspect as a stale plan and resumed the session with the rebuild prompt (which the live log then
called "the vault changed after you reviewed this batch"), and Approve sent the apply turn
unchecked. Decided:
(a) With the core missing, Approve and the queue send nothing; the batch stays approved and queued
under its hash and applies by itself once the core is back. Holding beats Couldn't fix here: the
owner already approved, and the fix (restoring the checkout) needs no second decision.
(b) The queue rebuilds only for a vault that really changed: changed paths, a plan with another
hash, or the core's conflict (exit 75). Any other inspect error goes back to the owner at $0:
a rebuild can't fix a bundle or tool the core rejects, and a paid turn should never be the first
response to an error nobody has read.
(c) A tool step whose result is an error ends failed; apply and check steps lose their past tense.
A step whose result never arrives still ends `done` (`closeRunning`): no existing state means
"unknown", and adding one is a contract and UI change.
(d) A session-gone batch keeps its approved hash (the pump read it after deleting it).

**A deleted checkout heals itself and never reaches AI recovery (2026-10-08).** The owner deleted
a merged worktree; the installed app's Info.plist `ClaudeObsidianProductRoot` and settings.json
`productRoot` both still pointed there. The core reported `missingCore`, yet a batch's plan check
failed with "No such file or directory", went to recovery (the rule turn, then Opus) and cost $0.08
before saying "Distill couldn't fix this". Decided, under the rule that safeguards check and repair
themselves:
(a) The app's launcher takes the first product-root candidate that has both the built CLI and
`scripts/claude-obsidian.py`, skipping a deleted one (`CoreLauncher.productRoot`).
(b) The core heals a saved root without the core script to the checkout it runs from, only when that
one has the script; saved and logged as `settings.product_root_repaired` (`healProductRoot`). It is
not done inside `decodeSettings`, so a codec round-trip never rewrites a value silently and tests
can't heal to the developer's checkout; the engine heals at load and before every setup check.
(c) A missing core script stops recovery at $0 before any rule turn or agent call, checked by
existence (not by matching the error text, which a missing python would also produce). The owner's
sentence names the path, an exception to the plain-words rule that keeps paths out: the path is the
fix. The card stays the existing Couldn't fix card with the core's sentence (no new card state);
a distinct setup card would go to the design canvas first.

**The To-do detail scrolls; its footer is pinned (2026-10-08).** The owner reported "missing
scrolling": a to-do with a long original pushed Remove, Complete and Send to out of the window.
The detail's content now scrolls above a footer that never moves (`PinnedFooterScroll`,
`ScrollChrome.swift`), back at the top when another item is selected. No divider above the footer
and the fade only when the content overflows, so a detail that fits looks exactly as before. To
confirm, Pending and Highlights already scrolled with a pinned footer; they now also open at the top
when another item is selected (`.id` on their scroll view).

## 2026-10-07

**Track as Pending from To confirm, and Move to Pending for an added to-do (2026-10-07).**
The owner reviewed the board "Actions · Track as Pending", said "build it" and accepted every
answer the frames assumed:
(a) To confirm offers Track as Pending… for any found type, in Add as… after a divider; an added
item gets Move to Pending… only when it is a to-do (a message, ticket or page you added is
something you send; dismiss or remove it instead).
(b) By is optional: "It is filled from the item’s due date when there is one; × clears it. With no
date the Pending row reads “no date” and never turns Overdue."
(c) Undo in the toast restores the item where it was (To confirm, or the to-do list) with the same
status and fields; the core keeps that in `trackedFrom` and Undo works while nothing has happened
to it in Pending.
(d) The key is ⇧⌥Return; Return and ⌥Return are unchanged, and it never fires in a text field.
(e) Move to Pending… sits at the end of the to-do's Send to, after a divider (not the ⋯ menu).
(f) It stays the same item (id, note, line, Why, labels); Activity records "Tracked “…” as Pending
· waiting on <name> (found as <type>)".
Choices made while building: the "In Pending it will read" preview uses the Pending row's own
words ("by Thu", not the board's "by today"), so the two can't differ; the CLI gets no command
for it, since the CLI deliberately has no confirm command and this confirms a To confirm item; and
Activity is append-only, so Undo adds
a "Restored" entry rather than removing the "Tracked" one (the card said "Undo removes the
entry"). Spec: [actions-routing.md](actions-routing.md), Track as Pending.

**Free-text fields keep what you type and save after a pause (2026-10-07).**
The to-do Title, People and Labels fields and a name in Settings → People read
the stored value back on every key, so a trimmed save removed the space or
comma you had just typed. They now keep a draft (`FieldDraft`,
`DraftTextField`): the text stays as typed, and the trimmed value is saved
after a 0.7 s pause, on Return, on focus loss, on switching items and when a
window closes. An empty title or name is not saved. Quitting within the pause
can still lose that last edit (no quit hook yet). See
[actions.md](actions.md) (the to-do detail, edit in place).

**A new person stays on the page until named (2026-10-07).** The core drops
a person with an empty name, so "＋ Add a person" saved a blank row that
vanished on the reply. The row is now kept by the page (`PeopleEdit`) and
joins Settings with its first name; a second add while one is unnamed keeps
that row. A type's ＋ with nobody left to add adds a person who handles that
type once named. The routing preview names notes found before routing
(`beforeRouting`) instead of counting them. See
[actions-routing.md](actions-routing.md).

## 2026-10-06

**The Distill Design System exists and the canvas installs it (2026-10-06).**
Step 2 of [design-system-plan.md](design-system-plan.md):
https://claude.ai/artifact/K5knKHsvunBdHR2iyowDW7 holds the tokens, a README
and the first two components, PrimaryButton and Pill (`window.Distill`).
`design/tokens.py` generates its `tokens.json` (the list shape the page reads)
and a `tokens.css` from Theme.swift. The source lives in `design/ds/`.
`test_design.py` compares the values, not only the names, with Theme.swift.
The Design System page doesn't write `tokens.css`, and its type says never to
publish one, so `tokens.css` goes only onto canvases, as
`project/ds/distill/tokens.css`. The main canvas's `designSystems` record pins
the version; `tokens.json` and the bundle are copied onto the canvas server
side.

**Swift mutation testing uses our own harness, `scripts/mutate.py` (2026-10-06).**
Muter would not install (Homebrew: "Your Xcode (16.4) at /Applications/Xcode.app
is too outdated"), so a small harness applies one classic operator at a time in
throwaway copies of the package (never the checkout), rebuilds, and runs only the
test classes that exercise the file. Build failures are invalid and left out;
score = killed / (killed + survived). `--kit-only` builds DistillKit and its tests
alone, which makes a mutant about 10 s; its scores are a lower bound, since
DistillTests are left out. Survivors are either killed by a stronger test or
written down as equivalent (or not killable on this machine, such as a hard-coded
en_US locale). See [Tooling](tooling.md).

**The canvas has a page per area, and pages stay small (2026-10-06).** This
supersedes the "no explicit canvas pages" part of "The design canvas moves to a
fresh artifact". Pages did not blank the viewer: one page holding all 141 boards
did. That one page never drew, with explicit pages or without (4 of 4 runs), while
the same boards on 7 area pages drew (3 of 3), as recorded in
[design-system-plan.md](design-system-plan.md). The owner approved steps 1–3 of
that plan. `design/pages.json` now places every board on a page and a row:
Capture & Queue, Review, Ask, Actions, Automations, Settings & Shell, and three
component pages. `render.py` refuses a board that pages.json doesn't place, a
page holds at most 30 boards (the largest area page that drew held 17), the
canvas opens on the first page, and `test_design.py` checks all three. Each page
has its own link (`#page-<id>`), so page ids never change. Row notes moved from
`rowNote` in `screens/*.json` to pages.json.
**Jira required fields are filled by type, by name (2026-10-06).** Built from the
ActionsJiraFields frames K–N (spec [actions.md](actions.md#jira-required-fields-2026-10-06-owner-request)).
Choices made while building:
- The screen is always read before Create (cached an hour), so a required field is refused
  before any POST in plain words ("Fill in Team first"), never Jira's 400.
- Values are stored on the item as `jira.<fieldId>` in text form; the core maps them to Jira's
  shapes at Create. The UI never shows the id.
- A kind the Mac doesn't know reads as one Distill can't fill: Create stays off and Open in Jira
  passes everything else along. Better than sending a guess.
- "From the note" for several choices records the names the note gave, so a chip you add later
  isn't tagged.
- "Use for future TLS Tasks" shows after you pick a value on this ticket (as on the canvas, it
  isn't shown on values that were already there); Settings lists and removes the saved values.
- Settings keeps one Jira page: the section sits under Defaults rather than on its own
  "Jira ticket defaults" page as on the canvas, so Defaults stay in one place.

**Whose items Distill handles is built (2026-10-06).** The ActionsRouting design is now in
the core and the Mac app (spec [actions-routing.md](actions-routing.md)). Choices made while
building:
- A promise to you goes to Pending even from someone whose items you handle. The canvas puts
  Aditya's ticket links in Pending while you handle his to-dos.
- A name that fits two people is unclear and asks "Whose is this?".
- Routing stays off until you have a name or an alias. Until then every item goes to your
  lists, so no list empties on the first batch after an update.
- Ask finds are not routed.
- Pending items are a `route` on the action, not a new status, because `pending` already
  means To confirm.

**Others' actions reach the wiki inside the next ingest batch, not a job of their own
(2026-10-06).** A core-built job like Confirm labels would hold the vault while it waits in
Review (`holdsVault(awaitingApproval)`) and stop the queue until you act. So when an ingest
batch starts, its prompt carries the exact "## Others' actions" section for up to 10 pages
whose section differs from what Highlights says. The section reaches the page in that batch's
bundle, which you approve. Distill compares instead of tracking, so a skipped or rejected
batch leaves the page due for the next one, and It's mine removes the line the same way. This
replaces "Highlights reads the wiki; it adds only Others' actions" as the how; the what is
unchanged.

**Pending only suggests that something arrived is built (2026-10-06).** A later batch sees the
open promises and can mark one "Looks received in <note>"; the item stays open until you press
Mark received.

**The design canvas moves to a fresh artifact; no explicit canvas pages
(2026-10-06).** The old canvas (`VSqHFPZjcqY2bMqFEnPqpG`) went blank: the
toolbar loads but no board draws, even with a canvas.json that draws
elsewhere. A bisect on a fresh copy found that explicit `pages`, a
`launch.page` and per-board or per-note `page` keys blank the viewer; without
them all 141 boards and 17 notes draw (allow about 30 s). The old artifact
stayed blank after its canvas.json matched the working copy, so it holds state
a publish can't replace. The canvas is now
https://claude.ai/artifact/7PAQ8AKofpY9yPvakwvUMB, and the old one gets no
further publishes. `render.py` never writes pages, and its merge drops any it
finds (`drop_pages`, checked by `test_design.py`).

**Highlights reads the wiki; it adds only Others' actions (2026-10-06).**
The owner: "Yes, but shouldn't the wiki already highlight it." A note's
Highlights shows what its wiki source page already holds (summary, key points,
decisions), read from the page and linked to it, and never extracts key points
on its own. It adds only what the wiki lacks, Others' actions by person, which
go into the source page as an "Others' actions" section through the normal
batch with the owner's approval, never written directly. Design only, not
built: canvas board ActionsRouting (`actions-highlights-note`).

**Pending only suggests that something arrived (2026-10-06).** A later note
showing a promise was delivered gives "Looks received in <note>. Mark
received?". Pending never closes an item on its own. Design only:
ActionsRouting (`actions-pending-list`).

**Anyone not in the People list goes to Highlights (2026-10-06).** Items whose
owner isn't in Settings → Actions → Whose items Distill handles go to the
note's Highlights under Others' actions. There is no separate default and no
setting for it. Design only: ActionsRouting (`routing-card-rule`).

**A Jira project is saved as its key; the picker shows its name (2026-10-06).**
Supersedes saving "TLS · Telus Platform": anything else reading
`fields.project` (a button's `{fields.project}` argv, the Project filter,
Add as, Copy, Activity, the extractor's own values) got the display text.
The picker stores the key and shows "key · name" from Jira's list, or offline
from the names cached at the last load.

**Jira fields come from the account, and Distill checks them before Create
(2026-10-06).** A ticket failed because Priority "Medium" isn't in the
project's scheme. Project, Type and Priority are now picked from what the
connected account allows (cached an hour per account and site), and a value
outside those lists is refused in plain words before anything is sent. When
Jira can't be reached for the lists, Create still goes ahead and Jira checks:
the lists help, they never become a second way to fail. (actions.md, Jira
pickers.)

**Add as converts the found item in place, at confirm time (2026-10-06).**
The owner wanted to choose the destination when confirming instead of adding
a to-do and then Send to. Confirm takes an optional target type and field
overrides; the pending item keeps its id, source, line, wiki refs, Why and
labels, and only its type, title, body and fields change. Send to (which
makes a new item and marks the old one sent) stays for items already added.
Fields are validated against the target type's schema, so a required field
can't be skipped. (actions.md, Add as at confirm time.)

**A Slack message Distill can't address reads Needs a recipient (2026-10-06,
owner decision).** "Ready to send" on a message whose To is a name Distill
doesn't know promised a send the button would refuse. When an enabled button
sends to `{fields.to}` and the name has no remembered @handle, the row and the
status filter say **Needs a recipient** instead (action-buttons.md, Where to
send). Also from the round-4 check: a To row like "@Mei Tanaka" or "#eng team"
is refused like a plain name, and a button that fills in a thread refuses a
thread link Distill can't read rather than posting at the top level.

**A Slack name is resolved by the owner once per vault, never sent raw
(2026-10-06).** The extractor keeps a person's name as written, so a button
bound to `{fields.to}` sent "Aditya Pradhan" and the script's pattern refused
it. The name stays on the item; the core resolves it through names the owner
saved ("Who is Aditya Pradhan in Slack?"), per vault, in core state
(`actions/slack-people.json`; the vault gets only approved notes). Until it
resolves, the run is refused in plain words and Send is off. Exact match only,
so a first name never picks someone. A thread a button can't reach, or a
group, is refused rather than posted somewhere else. Find in Slack waits for a
declared lookup command; none is guessed. (action-buttons.md, Where to send.)

**The button editor never shows an argument's name twice (2026-10-06).** The
owner's `text` argument read "text / text required": its hint only repeated
the name, and the name could wrap. A hint that comes from the same word as the
name (`text`, `<text>`, `--text`, any case) is dropped for the generic "{a
field} or text"; a real hint ("#channel, @handle or an ID") stays. Names sit
on one line that never wraps; the grey note gives way first.
(`ScriptCommandArg.editorNote` / `editorPlaceholder`, action-buttons.md.)

**Rebuild on the Couldn't fix card is a reply (2026-10-06).** It sends a fixed
"rebuild against the pages as they are now" reply rather than a new core
action: the owner's click resets recovery like any reply, it works for a
stopped batch, and a gone session gets the usual confirmation. No new route.

**Recovery after a spent rule: an agent call only where it can choose
(2026-10-06).** Lock hands over to the recovery agent after its waits (it can
check again, wait for another batch, or give up). Session-gone and
full-read-stop have nothing an agent may do for the owner (a new session is
the owner's; full-read-stop's v10 option is already in Review), and
not-recorded has the journal rule, so none of them spends an agent call. Also:
the lock count reset before every try, which made the 30 s / 2 min rule
endless; it resets when an apply lands.

**Recovery's split and discard are proposals; its retries reuse only the
approved hash (2026-10-06).** The design table had `split_batch` start a part
and `discard_stale_part` reject the rebuilt part by themselves. Built as
proposals instead: the card shows "Rebuild N sources first" or "Discard the
rebuilt part", and nothing changes until the owner clicks. Why: both change
what is in the batch, and the owner asked that recovery never change a batch
without them. `reinspect_same_bundle` and `wait_then_retry` act on their own,
but only by putting the batch back in the queue under the hash the owner
approved (kept on the recovery, since the queue drops it when it asks the
owner); the pump's inspect proves the bytes, so nothing new is ever applied
without an approval.

**Add automation asks what it does first (2026-10-06).** Collect keeps
today's steps after it; Commands for buttons and Both are scripts, and
Commands is saved with `collects: false`. Commands are declared on the saved
script, not in the Add sheet (the frame's "Commands (or later)"): one editor
for commands, in one place.

**"Ready to send" follows the Send slot (2026-10-06).** A ready Slack message
reads "Ready to send" when the built-in Send works or a button (turned on)
holds the Send slot; otherwise "Ready to paste". Why: the button sends it, so
"paste" was wrong. The status filter uses the same words.

**Recovery bounds hold across signatures (2026-10-06, verification).** A
recovery that hit another signature while it still worked started fresh, so
`runner-failed` and `plan-error` (or `denial` and `plan-error`) took turns
running their free rule forever: 42 session turns in a test with a runner that
alternates. Now `recoveryFor` carries the attempts, cost and denial answers
over while the recovery is running or waiting; a gave-up or fixed one still
starts fresh. The bounds in review-queue.md (Bounds, No loop) are per recovery,
not per signature. Also: a minute's wake and a recovery agent answer act only
on the recovery they were for, never on one the owner's action replaced.

**A recovery settles when its turn ends without a result (2026-10-06).** The
owner's batch read "Recovering" forever: Distill answered a blocked command,
and Claude came back with questions, no denials and no plan, which nothing
handled. Now a recovery is `running` only while a turn or an agent call works
on it; otherwise the rule's attempt escalates once to the recovery agent, then
the batch needs the owner. A start-up sweep settles recoveries an older build
left running. Recovery replies tell the session that Distill inspects and
applies, so it stops asking the owner for commands it can't have.

**A failed batch recovery gave up on counts as Needs you (2026-10-06).**
Supersedes "Badges still count only waiting batches" in the entry below: now
that such a batch can be rejected, it counts in the badges and its pill reads
Needs you, as the spec's Couldn't fix state says. Why: never rely on the owner
noticing a batch Distill gave up on.

**Recovery covers stale-again, plan errors and failed runs (2026-10-06).**
Step 6 of [Review queue](review-queue.md); extends the 2026-10-05 entry
"Recovery agent: built for blocked commands first". Each of these signatures
gets one $0 rule reply in the batch's session first (for stale-again, the
refresh), then the recovery agent with `rebuild_in_session`. Agent attempts wait
a minute apart (`waiting` + `waitUntil`, resumed at start). Why: the owner's
rule is automatic checks over human, and the minute lets the vault or the
session settle instead of spending a second call at once.

**A failed batch under recovery stays in Review and can be rejected
(2026-10-06).** A reply turn that fails used to drop the batch into History
only. While recovery works on it, or after it gave up, it stays in Review's
list (Couldn't fix) and Reject batch ends it. Why: the owner would otherwise
lose sight of a batch Distill is still trying to fix. Badges still count only
waiting batches.

**Continue in a new session from recovery is a button, never automatic
(2026-10-06).** When recovery suggests a new session (`proposal:
'new_session'`, also set when the session is gone during recovery), the card
offers Continue in a new session. It opens the usual SessionReplaceConfirm
("Recovery suggests a new session"), and only its Continue starts the session.
This keeps the 2026-10-05 session-continuity rule: a new session always asks
first.

**Approve checks the plan's hashes before an apply turn (2026-10-06).** With
nothing ahead in the vault, Approve runs the cheap `staleFor` check on the
bundle. A stale plan goes straight to the refresh and asks once more, instead
of an apply turn that would only return exit 75. Why: an apply turn costs
tokens and time, and the answer is already known on disk. Inspect stays the
authority; this check only skips a turn that can't succeed.

**`distill status` shows the apply queue and recovery (2026-10-06).** The
status response gains `applyQueue` and `recovering` (additive). The CLI still
never approves.

**Button approvals are their own Activity entry (2026-10-06).** A run that
approves its command logs `action.button_approved` before
`action.button_run`. Why: the approval is the owner's consent to an exact
command and should be findable on its own; repeated runs are only runs.

## 2026-10-05

**Recovery agent: built for blocked commands first (2026-10-05).** Step 5 of
[Review queue](review-queue.md). The `recovery` task defaults to Claude Code ·
Opus · medium, as the owner asked ("we default use the opus"), and can be
changed in Settings → AI models → Recovery. Settings → Recovery has Recover
automatically (on), attempts per problem (2) and a cost limit per batch
($1.00). The agent is one structured call with no tools and no vault access;
the core checks its fix (never the vault apply, never a tool rule). It runs
for blocked commands, which is the owner's reported case. Stale plans and locks
keep the deterministic rules from steps 2–3, and the agent for those
signatures is left open in the spec. Recovery is not part of the setup check, so
a recovery runner that isn't ready never stops batching.

**Apply queue: build choices (2026-10-05, built).** Steps 2–3 of
[Review queue](review-queue.md). (1) Approve applies at once when nothing is
ahead in the vault and queues otherwise; the queue re-enters Approve only after
`transaction inspect` proves the approved hash. (2) A batch is rebuilt at most
once per apply that lands in its vault, so a plan made stale by an outside edit
never loops; it goes to the owner. (3) Stale plans are rebuilt only after an
apply lands, not at start: a restart never spends tokens by itself.
(4) LOCK_TIMEOUT keeps the approval and retries after 30 s and 2 min, then asks.

**Blocked commands: two build choices (2026-10-05, built).** Step 1 of
[Review queue](review-queue.md). (1) An apply turn with a blocked call is not
answered by Distill: the approved command is what ran there. (2) A batch an
older build left waiting on blocked calls gets Distill's answer once when the
core starts, so the owner's stuck batch is resumed after the update in its own
session. This uses its runner, which costs tokens.

**Automations: the defaults are confirmed and built (2026-10-05).** The owner
said "go for 1 and 2" to the two open choices in
[Action buttons](action-buttons.md): (1) the sidebar name is **Automations**,
with Collect and Commands as roles and the data names unchanged; (2) commands
are declared in Distill by the owner, not discovered from the script. Built
in the core (96cc0c1) and the Mac app. The Swift model is `AutomationButton`
because the app already has a SwiftUI `ActionButton`.

**A blocked tool command never reaches the owner as raw shell (2026-10-05,
designed).** The owner got "Claude asked to run" with `Bash: diff <(python3
-c …) <(python3 -c …)` and "Combined command: reply with guidance instead."
They said: "there's no way I can handle something like this". The session
already had Read, Grep and Glob. Spec: [Review queue](review-queue.md),
"Blocked tool commands".

- **The core answers first.** A turn that ends with denials and no plan is
  answered by the core: "that isn't allowed in Distill sessions; use Read, Grep
  or Glob on these paths; no shell or python". Then the session resumes.
  - This is a fixed rule, at most 2 per batch, $0.
- **Then the recovery agent.** It has a new fix, `answer_denial`, whose guidance
  the core checks and sends.
- **The owner card is the last resort, in plain words.** The sentence comes from
  the core's `denialSummary`. Raw commands, and the allow checkbox for a single
  write rule, sit only under **Show command**.
  - Options: Let recovery try again, Rebuild, Open in Terminal, Reject.
- Logged as `batch.recovery` with `kind: denial`.

**Several approvals go into a queue, one apply at a time per vault. A stale
approved plan is rebuilt and asked once more; the approval never carries over
(2026-10-05, designed).** The owner approved several batches at once. All but
the first hit exit 75 `EXPECTED_HASH_MISMATCH` and each needed a reply and a new
OK. The owner's rule: "automatic checks over human". Spec:
[Review queue](review-queue.md), canvas row 16.

- **The apply queue.**
  - Approve records `job.queuedApply`, and `pumpApplies` starts one apply per
    vault, oldest approval first.
  - Before the head starts, `transaction inspect` runs on its approved bundle.
    The same `approval_sha256` applies under the owner's approval. The gate is
    used as the freshness check, so batches that don't overlap need no re-ask.
- **Approved-but-stale: option A (rebuild, then one more OK), not B (carry the
  approval over when only bookkeeping changed).**
  - `plan_approval_sha256` binds every write's bytes and mode, and writes are
    whole-file `create`/`replace`. A regenerated log or hot cache is a hash the
    owner never approved.
  - B needs bookkeeping as approved deltas rendered by the Python core (a
    transaction v2, the repository's mutation protocol).
  - `hot.md` is free text, not a mechanical merge.
  - The stale rebuild rewrites concept and entity pages.
  - B is deferred as an owner decision that needs that format change.
  - The re-ask is made cheap: the sources are proven unchanged, and "What
    changed since you approved" lists only the differing pages.
  - Honest cost: almost every queued batch after the first still needs one
    click, because every batch writes log and hot cache.
- **Unapproved stale batches are rebuilt automatically, only once the vault's
  queue is empty,** so a rebuild never goes stale again at once. Exit 75 reads
  "Updating against the latest pages", never "Not added".
- **Self-recovery (owner, verbatim: "we default use the opus, and we should able
  to change the model in the setting").**
  - Deterministic rules run first.
  - Then a recovery task (`AITask.recovery`, default Claude Code · Opus · medium,
    Settings → AI models → Recovery) picks one fix from a fixed list that the core
    validates and executes. It is one structured call, with no tools, session or
    vault access.
  - It never applies anything, and any new plan needs the owner's OK.
  - It is automatic, bounded to 2 attempts per batch per failure and $1.00 per
    batch, and it never re-enters itself. Then "I couldn't fix this" offers the
    options.
  - It doesn't use a new session by itself: session continuity asks first.
- **Review's batch tabs become a left list** (`ReviewBatchList`, `.paneWidth(.reviewList)`).
  - Rows are oldest first by creation and never jump.
  - Gemini file names are cleaned in DistillKit (`readableName`).

**Review status after a failed apply follows the plan, and a Terminal apply is
found in the vault's journal (2026-10-05).** The owner asked for the status to
update correctly "if the user fixes the issue with the conversation or opens the
terminal directly".

- **A rebuilt plan replaces the failure card.** The approved plan's hash is
  stored; a different plan in Review means the failure is history.
- **The vault's transaction journal is the evidence of an apply made outside
  Distill.** The model's word is not used; the plan's operation and hash must
  match a `complete` journal.
- **Send reply never stays disabled after an apply returned to Review,** and a
  reply's text is kept until the core takes it.

**Action buttons and script commands: designed, defaults proposed (2026-10-05).** Spec:
[Action buttons and script commands](action-buttons.md). Canvas: row 15, board
ScriptActions. Status designed; the owner has not confirmed these yet.

The owner asked to extend collectors into "action performers" that also store
the scripts actions run, to add buttons to every action type in Settings or in
the type's tab, to link each button to a script with mapped arguments (the
Slack CLI's send for "Send in Slack"), to show the result, and to find a
better name. Proposed defaults:

- **Name: Automations** (the sidebar label for Collectors). Collect and
  Commands are roles. A Folder automation collects; the Slack CLI offers
  commands. Records, ids, `/v1/collectors` and the CLI keep "collector", so
  there is no migration. The alternatives are Scripts, Helpers, Runbooks and
  Tools. The test: the name must fit a Folder collector, which is not a
  script.
- **Commands are declared by hand in the app** (`script.commands`). They are
  not parsed from `--help`, which would mean running unconsented code, and not
  read from a file next to the script, because Distill never writes to the
  owner's own file.
- **A command's argv is words and flags, then `--`, then positionals**
  (`endOptions` on by default). It was checked against a copy of the Slack
  CLI's argparse on python3 3.13.2: a text like `-x` or `--done` fails without
  `--` and works with it.
- **Templates:** `{title}`, `{body}`, `{summary}`, `{fields.<key>}`, … Each
  template is one argv element. Substitution is a single pass. An unknown
  placeholder is an error. An empty optional flag is left out with its flag.
- **Ask before running is on by default** (per button). Each button is
  approved on its first run, and again after any change to the command, the
  mapping or the script version. The run sheet always shows the exact
  command line then.
- **Only the app runs buttons.** The CLI and agents list and preview.
- **Button runs are script runs with `trigger: action`** in the script's run
  history.
  - They never set `lastRun` or the sidebar count.
  - The timeout is 60 s by default.
  - They don't wait for collector slots or batches.
  - There is one run per item at a time.
- **On success:** read a JSON line or a pattern from stdout into
  `item.external`, then Mark as sent, Complete, or nothing. On failure: the
  stderr tail and Try again, and after a timeout "It may have run already".
- **Send in Slack** becomes a button in the reserved send slot:
  - it runs `slack_cli.py send [--thread] -- <target> <text>`, with `target ←
    {fields.to}` (pattern #channel, @handle or an ID) and `text ← {body}`;
  - on success it marks the message sent and stores the ts as `external.key`.
- **`{body}` is the stored Markdown, unconverted.**
- **Secrets:** Distill passes none of its own. Scripts read their own Keychain
  items, as the Slack CLI does. "Script secrets" (env from Distill's Keychain,
  per script) are designed for a second pass.
- **Not changed:** the approval gate, the consent per script version, the
  network policy, and the absence of any sandbox.
- **Suggested to the owner, not done:** a `--json` flag on the Slack CLI's
  `send` that prints the permalink.

**Action summary: every found action says what it is about (2026-10-05).** Spec:
[Action summary](action-summary.md). Canvas: row 14, board ActionSummary.

The owner asked for a title and a summary on every action, and to click an
item to confirm and "show the full summary of what about" before choosing what
to do. The owner confirmed building the design as soon as it was ready ("let build
after design"), so the defaults below are the recommended ones.

- **`ActionItem.summary` is written at finding time.** It is 2–4 plain
  sentences, from the original's lines and the wiki, in the same find run.
  - It is separate from `body` and `why`.
  - It is optional in `FIND_SCHEMA`.
  - The instruction goes in the always-appended part of the find prompt, so
    an edited prompt still asks for it.
- **Older items are summarized on first open, automatically**, after the
  selection rests for 600 ms.
  - `POST /v1/actions/:id/summarize` writes it from the draft context with the
    find model, so there is no new task or setting.
  - The alternative is a Summarize button.
- **The summary is not editable.**
- **A To confirm row click selects it into the right pane (`ConfirmDetail`)**
  on To do and on the Slack, Jira and Confluence screens.
  - The inline chevron goes on those screens.
  - Review and Ask keep the in-place expand, because they have no pane.
- **Add and Dismiss move from the row to the pane's footer** on screens with a
  pane. "Add all" and "Dismiss all" stay. The alternative keeps the row
  buttons.
- **Keys work while the list has focus:** ↑/↓ move, Return adds, Delete
  dismisses, and ⌘Return adds from anywhere. After an action the selection
  moves to the next row. The alternative is ⌘Return only.
- **Ask: a row click opens the row; editing the title moves to a pencil.**
- **Source names lose their Markdown in the core and the app.** Emoji stay.
- **"Found by by" is fixed in the app.** The stored detail stays "by Sonnet".
- **A to-do confirmed with an empty body takes the summary as its note.**

**Slack CLI saved as a future Distill collector (2026-10-05).** Code:
`apps/scripts/slack/` (`slack_cli.py`, `extract_slack_creds.js`, README).
The owner supplied both scripts for later use in Distill; not wired into the
app yet.

- **The `d` cookie stays URL-encoded end to end.** The browser sends it
  encoded; the extract script no longer decodes it, and the CLI re-encodes a
  decoded value (`normalize_cookie`), so either form works.
- **`import` takes the JSON path as a required argument** (any folder, any
  name; the owner asked for this, since the file can be saved anywhere). It rejects a token not starting `xoxc-` or a
  cookie not starting `xoxd-` before touching the Keychain.
- **The `catchup` checkpoint lives in `~/.slack_cli_state.json`**, not the
  current folder, so a run from the repo never leaves state there.
  `slack_c.json` and `.env` are git-ignored in that folder.

**Resizable panes: a draggable divider on every split screen (2026-10-05).**
Spec: [Resizable panes](resizable-panes.md). Canvas: row 13, board Panes.

The owner asked: "for any UI with the open left section, I am able to change
the size." The owner confirmed
these defaults directly in the lead's session on 2026-10-05 ("yes, build
both").

- **Every split screen gets a handle:**
  - the sidebar;
  - Review's Conversation;
  - History: the Jobs list and its Conversation, Actions, Activity;
  - Actions: To do and each action type;
  - Collectors;
  - the Settings nav.

  Ask, Write a note, Labels and Queue have one column.
- **The automatic width is today's width.** A missing key changes nothing on
  screen, and double-click returns to it.
- **Each column has a min and a max, and the other column keeps its min.**
  For example, Review's details keep 360 pt and the Conversation runs 220–520
  pt.
- **No drag-to-collapse.** The existing narrow-window rules (Review 780,
  Activity 920, Collectors 760) still do the hiding.
- **Widths are kept per screen in Distill's UI preferences**
  (`@AppStorage("distill.pane.…")`, a `Double`), not in `settings.json`. The
  core does not change. Only a drag writes; a window resize only clamps.
- **The sidebar and the Settings nav are resizable too, at 200–320 pt.** They
  are the "left section" in the owner's words.
- **The mechanism is a SwiftUI modifier and a `PaneHandle` view**, not
  `NSSplitView` or `HSplitView`, for two reasons:
  - `ImageRenderer` snapshots can't draw AppKit split views.
  - The screens' `GeometryReader` narrow rules stay as they are.

**Action context: actions found in the batch, from the original and the wiki
(2026-10-05).** Spec: [Action context](action-context.md). The owner asked for
actions made from "the raw source + the wiki", pointing at the raw source, and
for a preview before Create draft; then said "please design and build
directly". The five open choices below took the recommended default and are
recorded as the owner's pre-approval of 2026-10-05.

1. **Finding runs in the batch, as a separate pass fed by the core**, not
   inside the ingest session. When the change reaches Review, the core sends
   every line of every source (the reading copy, in windows of at most 24K
   tokens) with the source's page draft as wiki context. Why: the AI's own
   list can't be checked for what it left out, a core-fed pass is complete by
   construction, and the ingest session's continuations stay for reading.
   Supersedes the post-apply "Finding actions" step's 12,000 / 60,000
   character cuts, which left most of a long meeting unread.
2. **Items enter Actions when their source's pages apply.** Before that they
   live in the job's side file (`<job dir>/actions-found.json`); Review shows
   them as information, with the preview. Reject adds nothing; part of a batch
   adds only the applied sources'; Jira and Confluence creation stays the
   owner's click.
3. **The pass runs on the batch's own runner** when Settings → Model for
   finding actions is another provider, so whole transcripts go nowhere the
   batch didn't.
4. **Ask actions get the closest lines of the cited pages' archived original**
   (word overlap, at least 40%, labelled "closest lines", never "quoted"), or
   are marked wiki only with the reason.
5. **Re-reads and repairs find actions too.** A content-hash dedupe (same
   original sha256, same type, overlapping lines or the same quote, in any
   status) keeps them from adding what was already found, done, removed or
   dismissed; older items without `raw` are located by their quote.

Also decided while building:

- **Line numbers come from the core**, by searching the quote in the
  original; the model's lines are only a hint. A quote not found keeps the
  item with `match: none` and no lines.
- **A source not looked through in full is tried again by itself** when the
  batch applies (a failed window, or Distill quitting mid-pass); after that it
  shows as failed with Try again, naming the lines.
- **Open original uses the default app**, not Obsidian: Obsidian doesn't show
  `.raw/` (a dot folder).

**Full reads, built (2026-10-05).** Spec: [Full reads](full-read.md),
section "Built".

- **Re-read groups are packed by tokens, not by 3.** This supersedes "Sources
  per batch by default: 3" in the re-read entry below:
  - `rereadSources` with no `perBatch` packs by the batch budget;
  - `tokenBudget` (at least 1,000) overrides the budget;
  - `perBatch` still groups by count, 1 to 10;
  - `distill batch reread` takes `--tokens N` or `--per-batch N`.
  Reason: three long transcripts can pass what one session reads, and three
  short notes waste sessions.
- **A missing source still fails its batch by name.** This also holds for an
  archived `.raw/captured/<sha256>.<ext>` path whose bytes no longer match its
  name. The long-line fact no longer says to name the lines in `skipped`: the
  reading copy splits them.
- **Batches route to a runner with verifiable reads** (`ingestSelection`).
  The task's route list is unchanged, so the gate runs only where
  `readCoverage` is.
- **Back-fill counts only applied changes**, and **the repair skips any
  source a live job or a waiting re-read holds**. The scan runs again after
  each apply. Reason: the owner's re-read groups were still running when the
  build first started.
- **A refused resume of an automatic continuation starts a fresh session.**
  Nobody is asked to replace the session.
- **The manifest key of a re-read or repair bundle** is the original inbox
  path (`.raw/.manifest.json` is keyed by it, and the core only merges).

**Full reads, after the design review (2026-10-05).** Spec: [Full
reads](full-read.md).

- **Re-reads and repairs pack by token budget.** This supersedes the default
  group of 3 in the re-read entry below. `rereadSources` takes a
  `tokenBudget`, the same budget as normal batches.
- **The next repair batch starts when the previous one applies**, not when it
  reaches Review. So no repair bundle goes stale against another one.
- **Automatic batch size is 100K on the owner's Sonnet.** The CLI reports
  `modelUsage.contextWindow` = 1,000,000 (verified on CLI 2.1.289).
- **Compaction is designed for its absence.** `compact_boundary` isn't
  verified in `-p`, so either it or a sharp drop in context counts. The
  draft-after-read order applies only after one.
- **Moving a ledger locator to `.raw/captured/` migrates the record.** The bundle
  adds the new record with `supersedes`, removes the old one, and moves its
  claim references. Lookups key on `content_sha256`.
- **Cost is shown as an estimate at list price**, or in tokens.

**Owner decisions on full reads (2026-10-05).** These supersede the "vetoable
default" wording in the entry below.

- **`.raw/` archiving goes through the ingest bundle (Option A).** The owner
  confirmed it. Each batch's bundle creates `.raw/captured/<sha256>.<ext>` and
  points the ledger locator there. Clean up inbox only clears inbox copies.
- **Codex ingest is deferred.** Batches run only on runners with verifiable
  reads (`readCoverage`; today Claude Code). The follow-up is logged as a
  Distill To do (`act-026ab6c5…`).

Full reads (designed). The owner: "relying on human is wrong. we need the
solution to be more automatic". Canvas: FullRead (row 11). Spec: [Full
reads](full-read.md).

- **Coverage comes from the tool results, never from the AI.**
  - The core reads each Read result's returned span (`tool_use_result.file`)
    from the turn's stream.
  - The live log is not the evidence: it is capped and keeps words only.
  - Reason: two of the owner's "whole" reads were cut at lines 139 and 221
    with no error (`truncatedByTokenCap`).
- **The core makes a reading copy before the turn.**
  - Embedded image lines become placeholders, and long lines are split. The
    estimate and the coverage use the copy.
  - A file the core can't decode is unreadable by the core's decision.
- **Missing lines are fixed without asking.**
  - Up to 3 automatic continuations name the exact ranges.
  - What is still left becomes an `unread` part in the same job, read again
    in a new session.
  - Review only ever shows 100% coverage, as information.
  - The only owner-facing stop is a file that can't be read. It is excluded
    from the change and can't be approved.
- **Batch size is a token budget.**
  - Automatic = 30% of the model's context, at most 100K: 60K on a 200K
    model, so the session stays clear of compaction.
  - The rest runs right after.
- **Archive with the batch (Option A).** The ingest bundle creates
  `.raw/captured/<sha256>.<ext>` and points the ledger locator at it, so
  `.raw/` changes only through the reviewed transaction. Clean up then only
  clears inbox copies. Adopted as the default on the lead's recommendation;
  the owner may veto it (fallback: a separate `capture apply` at clean-up).
- **Partial is data.** It is the core's coverage record keyed by sha256, not
  page prose. Existing pages are re-read automatically: all 22 of the
  owner's, since prose can't be trusted.
- **Ingest needs the `readCoverage` runner capability.** Codex is off for
  ingest until core-fed sections exist. Adopted as the default on the lead's
  recommendation; the owner may veto it.

Full reads and re-reading sources. The owner's 22-note batch
(`job-20261004-233313-0018`) read the Gemini summaries and only 8 files in
full, following the ingest skill's "bounded first tranche". The owner wants the
notes re-read in full, through Review as usual. This is core and CLI only, with
no new UI. Specs: [Queue and batching](queue-and-batching.md) → Re-read sources,
[Architecture](architecture.md).

- **Every ingest prompt asks for a full read** (`FULL_READ_PROMPT` in
  `engine/job-kinds.ts`):
  - The source budget is the full size of every file. The existing-page budget
    stays the skill's default.
  - Read each file to its end in consecutive sections, using only the Read tool.
    When a Read returns fewer lines than asked, continue from its last line.
  - Skip lines that are only embedded base64 images.
  - Process one file at a time: draft its source page before opening the next
    file, then update the shared pages and build one bundle.
  - For meetings, write a detailed source page: per-topic Discussion and Open
    questions, as well as key points, decisions and actions.
  - Mark a page partial only when a file truly can't be read.
  
  This replaces "default existing-page budget from the skill".
- **Ingest turns always stream** (stream-json), even without a live-log sink,
  so the record shows which tool calls read the sources.
- **Re-read groups hold 3 sources by default** (`perBatch`, from 1 to 10). The
  limit is what one session can hold. The 22 notes of that batch hold about 800 KB of text (measured, base64 image lines left out; 3.9 MB raw),
  roughly 210–260k tokens. Three full transcripts come to about 30–100k tokens,
  which leaves room for the existing pages and the bundle. One batch of 22 is
  what read in part.
- **Each group is its own ingest batch, with a fresh session.** Groups run one
  at a time per vault, under the existing `batchBlocker` rule: a running batch
  blocks, and a batch waiting in Review doesn't. Groups that haven't started
  are kept in `<state>/reread.json`, so they survive a core restart.
- **Files are read in place.** Nothing is moved or copied, and nothing is
  written into `inbox/`. A file that is missing is refused by name when the
  re-read is requested. If it goes missing later, that group's batch fails by
  name and the next group still runs. A re-read never quietly reads only part
  of what was asked.
- **Each prompt names the existing pages.** It gives each file's size as text
  and the existing source page, found read-only through the source ledger's
  `pages` or `source_path`. It says to update that page and not create a
  second one, and not to skip a source for having the same SHA-256 (the
  skill's "unchanged input" check). The labels on each existing page are
  written back unchanged; no label suggestions run.
- **`--job` drops note manifests.** It takes the batch's files minus note
  manifests, which are instructions whose images were handled at the first
  ingest. Each folder stays one source.
- **Cancelling a re-read batch drops its groups that haven't started.** A
  failed or rejected group doesn't stop the rest.
- **Finding actions stays on for re-read batches.** Its dedupe already skips
  lines found before, in any status. Only new parts of the transcripts can add
  items.

Review after Approve and Clean up inbox. The owner: "add a manual cleanup
button" and "I can see the progress after I approved". Canvas: ReviewProgress,
InboxCleanup, ApplyProgress. Specs: [Clean up inbox](inbox-cleanup.md),
[Approval and review](approval-and-review.md) → After you approve, [Live
log](live-log.md).

- **Inbox clean-up is manual only.** Distill never cleans `inbox/` on its own;
  a button does, after a confirm that lists what moves and what stays and why.
  This keeps the 2026-10-04 inbox rule (no automatic delete) and the
  claude-obsidian rule that `inbox/` is the user's.
- **A file can go only when the ledger proves it is in the knowledge base**:
  a `file` entry whose locator names it, the same sha256 now, and every page
  of that entry present. The ledger is read, never written.
- **Matching:** NFC on both sides; a case-only match counts only with one
  matching entry whose hash agrees; with several entries for a locator the one
  whose hash matches wins.
- **Units:** a note goes with its `.distill.json` and listed images; a folder
  item goes whole, only when every source file inside passes, with its
  `.distill-folder.json`. A "seen before" file needs its own entry, so a
  folder holding one stays (conservative; the collector's own record is not
  proof the file is in this vault).
- **Never** a file a running or waiting batch holds, or a queued file not yet
  batched (the queue may be `inbox/`).
- **Checked again at Move**; a file that changed after the preview stays.
- **The Trash, never rm.** The core asks Finder first (Put Back works) and
  falls back to the queue's no-overwrite rename into `~/.Trash`; the result
  says which, and the words follow it.
- **Review keeps an approved batch until Done.** Its steps come from the live
  log (new steps `start`, `apply`, `added`; `JobStep.hint`), and the counts
  from `job.approvedChange`, recorded at Approve from the plan and the vault
  before the apply. It never counts as needing the user and never blocks a
  batch. Only batches (`ingest`) stay until Done; a label confirmation from
  the Labels screen leaves Review once it is applied, as before, so it never
  needs an extra click.

- **Backups include collector scripts and batch step logs.** Since script
  files (2026-10-04), a kept script's code lives only in
  `collectors/scripts/<id>/`. `distill.sh backup` copied `collectors.json` but
  not the scripts, so a restore could bring back collectors pointing at code
  the backup didn't hold, against "user data is permanent". Backups now copy
  `collectors/scripts/` (without `node_modules` and `.venv`, which an install
  recreates) and `steps/`. Restore copies them back next to what's there.
  Test-run output and install logs stay out, because they are scratch.
  Found by the specs audit.
Labels before the batch, labels in Review, and a Review that approves part of a
batch. The owner: "I will never see the label suggestion in the queue … in
review I don't see any label." Canvas: Review, ReviewStates, ReviewChoose,
MainLabels, MainLabelGate, QueueLabelGate (v70–v71). Specs: [Labels and
sources](labels-and-sources.md), [Approval and
review](approval-and-review.md), [Queue and batching](queue-and-batching.md),
[Vaults and settings](vaults-and-settings.md).

- **Queue files get labels before the batch, 3 at a time.** Every text file
  that is Ready in the queue and is not a Distill note gets labels suggested
  in the background by a pool of at most 3, until every file is labeled.
  - State lives in Distill's `labels/notes.json` overlay keyed
    `file:<sha256 of the content>`, never in the file. One model for both
    placements: a queue that is `<vault>/inbox` must not be edited, and the
    key follows the content into `inbox/`.
  - A restart finds the files without a result and queues them again.
  - The batch reuses these labels and labels only what is left, also 3 at a
    time, with per-file `labelSuggest` progress (`item`, `group`).
- **The label gate (default, owner may veto).** A batch takes a text file only
  once its labels are in: suggested, confirmed, or the file's own tags.
  - A file still being labeled, or whose suggestion failed, stays for the next
    batch. Files the AI can't label (PDFs, images) go as before, and so does
    everything when `labeling.autoLabelQueueFolder` is off.
  - A failed suggestion is retried by itself up to 3 times (once per batch
    run), then waits for the user: Retry, + Add, or **Send without labels**.
  - Process now applies the same gate and logs what waits; the app says "3
    notes are still being labeled; they'll go in the next batch."
- **Approving confirms the labels shown (default, owner may veto).** Pages are
  written with `labels_by: user` and no `labels_reviewed`, so they don't come
  back in Labels → To review.
  - The bundle is never rewritten at approve time. When a batch reaches
    Review the core writes a label revision (`bundle-labels-<n>.json`, new
    draft files for the source pages only) and inspects it. Only a clean
    inspect replaces the bundle and plan, so the approval hash always matches
    what is shown. Approve is refused while that check runs.
  - If the vault core refuses the revision (for example the index changed
    since the batch was built), the original bundle and plan stay and Review
    says the labels stay unconfirmed, and why.
  - An edit in Review makes a new revision the same way; a refused edit
    changes nothing (`conflict`).
- **Approve, review labels later.** A second approve action applies the
  unconfirmed twin: the bundle as the batch wrote it, with the user's own edits
  kept confirmed. The pages then wait in Labels → To review.
  - Also for a batch already in Review when the core starts, which is the
    owner's 22-file job. Its twin is the original bundle, inspected again at
    startup so the approval hash is fresh. Labels suggested at startup go into
    the twin as the AI's, unconfirmed. (The first build left these jobs
    without "later"; the owner asked for it precisely for this job.)
- **Rejecting a rebuilt part discards only that part.** The owner: "For the
  files that I haven't approved or removed, it should stay in the review tab."
  Nothing is applied. Picked sources go back to the batch's Review as it was
  before the pick. What is left after a part applied stays in Review without
  a plan, and Approve rebuilds it again in the same session. Only an explicit
  "Reject batch" ends the batch. Supersedes the first build, where rejecting a
  rebuilt part rejected the rest of the batch.
- **Approving part of a batch needs a rebuilt change and a second approval.**
  The index, log, hot cache, overview and ledgers cover the whole batch, so a
  subset can't be cut out of a bundle.
  - The batch's **own** session (`job.sessionID`) rebuilds the change for just
    the picked sources, reusing their source-page files byte for byte.
  - Distill checks the result: every picked source page has the sha256 the
    user saw, and no page of an unpicked or removed source is in it.
  - Page equality is not enough to apply: the regenerated pages are text the
    user has not seen, so they approve once more.
  - After the part applies, the sources left are rebuilt in the same session
    for a later approval. `Job.parts` records each applied part (History).
  - Only the approved plan's operation is recorded as applied (unchanged).
- **Remove takes a source out of the batch.** It is marked removed on the job,
  never added to the vault, and its inbox file stays (Distill never deletes
  inbox files). Undo works while the batch is in Review.
- **Several batches can wait in Review; oldest first.** A batch waiting in
  Review no longer blocks the next batch; only a running one does. Review
  lists pending batches oldest first: the oldest was built against the oldest
  vault and should go in first. A batch whose plan went stale (apply exit 75,
  not a lock or a reused id) is rebuilt in its own session and checked the
  same way.
- **`resumeBatchSession` is the one path to a batch's AI session.** It is
  session-continuity's helper (merged 2026-10-05): approve, approve-later,
  the rebuild of a picked part and its apply all go through it. A gone
  session puts the job back exactly as it was and the app shows
  `SessionReplaceConfirm` (ReviewStates frame 9). Continue sends the same
  approval with `newSession`: the same plan and bundle (the label revision,
  approve-later's unconfirmed bundle, or the part's rebuilt bundle), and for a
  pick the same sources. The refused call's approve options (`labels`,
  `pages`) ride on the `session_unavailable` details and the job marker, so
  Continue never widens a part into the whole batch.
  - A part's rebuild the core starts itself (what is left after a part
    applied, or after the vault changed) first leaves its sources waiting in
    Review with no plan (`approval.needsRebuild`). A gone session leaves
    exactly that, with the marker; Continue rebuilds in a new session.
- **"Wait before picking up a file" is hours and minutes, 0 to 24 hours**
  (was minutes and seconds, up to 59:59). 0 means no wait. The core clamps
  `settleSeconds` to 0..86400.
- **A lost AI session is never replaced silently (system-wide).** Spec:
  [Session continuity](session-continuity.md).
  - The owner's rule covers every place that resumes a session: batches
    (approve, reply, allow), Ask follow-ups, Open in Terminal and
    `distill ask --conversation`. Wherever Distill would resume a session that
    no longer exists, it shows one shared confirmation, `SessionReplaceConfirm`,
    and continues in a new session only after your OK.
  - Detection uses positive evidence only: the runner's not-found error with
    the exact ID, a missing transcript under a readable store, a job that never
    ran a turn, or a runner that's gone. Ordinary failures stay failures.
  - Actions, label suggestions and image text are not covered. They start a
    fresh session on every call, so they never resume one.
  - Ask's deliberate resets (runner, vault, scope or workspace changed) keep
    their notice. They are your change, not a lost session.

- **Live log: one view for a batch's steps and a collector's output, opened
  in place.** Spec: [Live log](live-log.md). The owner asked for the
  progress of a batch and for a collector's live output. A real batch
  showed nothing for four minutes, from 03:33:13Z to 03:37:08Z, while
  labels were suggested file by file.
  - **In place, not a panel or a window.** A side panel crowds an 890 pt
    window. A separate window splits the app. Collectors' All runs and
    Activity's narrow detail already push a view with "‹ back". The batch
    card on Queue keeps a one-line **Now** so the common question needs no
    click.
  - **Claude Code streams only when the live log asks.** `stream-json
    --verbose` is chosen when `RunRequest.onStep` is set, so it covers
    batch turns only; Ask, labels and actions keep `json`. Its final
    `result` event decodes through the same `parseClaudeJSON`. With the
    real CLI and `--json-schema`, the structured output came out identical
    in both modes. The alternative was tailing Claude's transcript file
    (`~/.claude/projects/<cwd>/<session>.jsonl`). It was rejected because
    the path and format are Claude Code internals; stream-json is the
    published interface.
  - **Steps are plain words with the raw target behind Details, and never
    contents.** No file text, tool results, draft text or keys. The AI's
    own notes are cut to 280 characters. Each job keeps 2,000 steps or
    512 KB, and the log goes when the job goes.
  - **The engine change is a sink, not a rewrite.** Another teammate is
    editing the engine. Only runner steps and per-file label progress come
    through `EngineOptions.steps`. Every other step is derived from `job`
    and `progress` events in `core/src/steps/`. The label loop gets two
    calls and a `current` field on its existing progress events, which
    holds up as that loop becomes a three-wide pool.
  - **Collector output is kept in order from now on.** `run.outputLog`
    holds the last 64 KB with stream and time. Older runs show Output, then
    stderr, rather than a guessed interleaving.
  - **The runtime shows quietly.** The log header and an opened run show
    the runtime, for example "python3 (.venv) · ~/…/python3", from
    `run.runtime` and `install.runtime`. Owner-approved, 2026-10-05.
  - **No stale marks, no silent blank, no wipe.** Once a job is no longer
    running, nothing in its log spins, and once it is finished nothing
    says "waiting for you". The core closes blocked tools and questions
    with the review and settles running steps when a job fails or is
    cancelled. The app settles logs written before that, and steps cut off
    by the cap or a restart. An older core without the steps route shows
    "Update the Distill core", as Actions and Collectors do, not an empty
    log. Pruning at start is skipped when the job list is empty, so a
    `jobs.json` set aside as unreadable never deletes every log.

## 2026-10-04

- **Follow-ups to the audit fixes, from a review pass.** Specs: [Approval and
  review](approval-and-review.md), [Labels and
  sources](labels-and-sources.md), [Queue and
  batching](queue-and-batching.md).
  - An unverified agent apply finished its `apply` progress as "Applied",
    which contradicted the job's own turn. It now says "Not applied" unless
    an operation was recorded.
  - `queueIsInbox` compared `path.resolve` strings while the placement check
    resolves symlinks. A vault saved through a symlink, with the queue saved
    as the real `…/inbox`, passed placement but switched off every inbox-mode
    protection. Both now compare resolved paths.
  - The `allow()` refusal names the rules first, so they fit the app's
    three-line error banner.

- **Exit 75 from `transaction apply` is worded by its error code.** Spec:
  [Approval and review](approval-and-review.md) → Core applies. Audit item
  B5.
  - Before, every exit 75 said "The vault changed after this plan was
    reviewed". But exit 75 is any `TransactionConflict`, including
    `LOCK_TIMEOUT` and `OPERATION_ID_REUSED`.
  - **Decision:** the core reads `ERR <CODE>:` from stderr.
    - `LOCK_TIMEOUT` keeps the plan and says another process held the vault
      lock; approve again to try again. Nothing changed, so the reviewed plan
      still holds.
    - `OPERATION_ID_REUSED` says the ID was already used and the operation
      may already be applied. Label jobs still rebuild with a fresh ID.
    - Every other code keeps the "vault changed" wording and adds the code.
  - The agent's approved-apply prompt also says not to rebuild on
    `LOCK_TIMEOUT`.

- **The ingest prompt names the wiki-ingest skill's absolute path for every
  runner.** Spec: [Job kinds](job-kinds.md) → Ingest. Audit item B4.
  - The prompt named only `claude-obsidian:wiki-ingest`. Codex gets no
    plugin or skill path: it runs with `--ignore-user-config`, and its cwd
    is the job folder. So it could not load the skill.
  - **Decision:** the prompt adds "If that skill is not loaded, read
    `<productRoot>/skills/wiki-ingest/SKILL.md` with the Read tool". Paths
    in the skill are resolved against its folder or the product root. This
    goes to every runner; Claude Code still loads the plugin skill as
    before.

- **Every vault use needs `.claude-obsidian.json`, not only batches.**
  Specs: [Vaults and settings](vaults-and-settings.md) → Vaults,
  [Ask](ask.md) → Isolation. Audit item B3.
  - Before, the marker was checked only through `batchBlocker` and
    `status`. `resolveVault` (labels, notes, page search, label review)
    only checked that the vault was in Settings, and Ask checked only for
    `wiki/`.
  - **Decision:** `resolveVault` refuses a vault without the marker
    (`invalid_state`, with the `init`/`adopt` hint). Ask requires the marker
    and keeps its `wiki/` check. Ask still accepts an explicit `vaultPath`
    that isn't in Settings, which the root vault-resolution order (explicit
    `--vault` first) allows. The Ask and activity test fixtures now create
    the marker.

- **After an agent apply, Distill records what it approved, not what the
  model reports.** Spec: [Approval and review](approval-and-review.md) →
  What Distill records after an agent apply. Audit item B2.
  - Before, a `done` recorded `status.operation_id` and
    `status.changed_paths` straight from the model. A `done` in a turn that
    never ran an approved apply also completed the job, possibly with a
    made-up operation ID, and triggered "Finding actions".
  - **Decision:** `approve()` passes the approved plan to that one turn. On
    `done`, the job records the operation only when the turn was the apply
    turn and `operation_id` equals `plan.operation_id`, and takes the paths
    from `plan.changed_paths`. An app turn says "Applied <op>:". Otherwise
    nothing is recorded, and an app turn says so. The job still completes,
    because a `done` is the agent's final word. `nothing_to_do` never records
    paths. The plan is the trusted source, because a committed transaction
    leaves nothing under `.vault-meta/transactions` (checked on a real
    vault).
- **The core enforces the approval gate on tool rules.** Spec: [Approval
  and review](approval-and-review.md) → Phase 1. Audit item B1.
  - Before, `settings.extraAllowedTools` and `job.grantedTools` reached
    phase 1 unfiltered, and `allow()` stored any rule. The only check was
    the UI's substring test (`!rule.includes('/.vault-meta/worker/')`), so
    `…/worker/../../wiki/**` or another job's folder passed.
  - **Decision:** one classifier, `gateBreakingReason`
    (`runners/permissions.ts`), used by `planningTools` (filters at use
    time; never rewrites settings), `allow()` (refuses the whole call with
    a `CoreError` naming each rule) and `bypassesApproval`. The Swift
    warning now resolves `..` and checks the job's own folder.
  - Beyond the audit list, exact rules for shell interpreters are refused,
    not only prefix rules: `Bash(sh /job/x.sh)` would run a script the agent
    wrote. Any spelling of `transaction apply` (extra spaces, quotes) is
    refused too.
  - Any Bash grant still shows the warning, because even an exact
    `Bash(cp … wiki/x)` writes. Prefix rules for other write-capable
    programs (`cp`, `mv`, `tee`, `python3 <script>`, `node`, `perl`) are
    not refused; they are listed as residual risk rather than a denylist.

- **Inside the vault, the queue may only be exactly `<vault>/inbox`, and a
  Folder collector may not read from a vault.** Specs: [Vaults and
  settings](vaults-and-settings.md) → Validation, [Queue and
  batching](queue-and-batching.md) → Queue folder,
  [Collectors](collectors.md) → Folder and the script contract. Audit item
  A3.
  - Before, the validator rejected only a queue under `.raw/` or
    `.vault-meta/`. A queue set to the vault root or `wiki/` passed, and a
    batch would then move `wiki/` pages into `inbox/`.
  - **Decision:** `queuePlacementProblem` (in `engine/validator.ts`) resolves
    symlinks and respects folder boundaries. It reports the existing
    `queueIsVaultInternal` code for anything inside the vault except
    exactly `<vault>/inbox`. DistillKit decodes problems as plain strings,
    so a new code would also have worked, but reusing the code keeps
    clients unchanged. Batches are blocked. `addNote` and `addQueueFiles`
    refuse with `invalid_state`, and collector runs fail with code `other`
    and the reason. The owner's sibling queue
    (`~/Documents/Distill Queue/MyKnowledgeVault`) stays valid.
  - A Folder collector source inside any configured vault is refused on
    create and update. A saved one that becomes invalid fails its run
    visibly (`failed`, code `other`); the scheduler does not skip it
    silently.
  - Script collectors keep `DISTILL_VAULT`. `collectors.md` now states that
    a consented script must write only to `DISTILL_QUEUE_DIR`.

- **Only the core removes queue files; the app's Trash fallback is gone.**
  Spec: [Queue and batching](queue-and-batching.md) → Remove.
  - `AppModel.removeFromQueue` used to move files to the Trash itself when
    there was no client or the core answered "not available". That skipped
    the core's guard against removing an `inbox/` file a batch already took.
  - **Decision:** drop the fallback (option one of the audit's two). With no
    core, the app shows "Can't remove … while the Distill core isn't
    running." The core ships with the app, so an older core without
    `removeQueueEntry` is no longer a case to support. `AppModel.trash(_:)`
    had no other caller and was removed.

- **The meeting-notes script never replaces a file in the queue.** Code:
  `apps/scripts/meeting-notes/fetch_meeting_notes.py` (`place_new`); its
  README. Follows the inbox rule below.
  - When a Drive file changed, `part.replace(path)` overwrote the earlier
    download, which may sit in the vault's `inbox/`.
  - **Decision:** the `.part` temp file is kept, then hard-linked in
    create-only (an exclusive create where hard links don't work). A taken
    name becomes `name (2).ext`. A changed file arrives as a new file next
    to the old one.
  - The owner's collector runs a saved copy of the script. The new version
    reaches it only when it is pasted into the collector's script editor and
    allowed.

- **When the queue is `inbox/`, a note's label state lives in Distill's
  state.** Spec: [Notes composer](notes-composer.md). Follows the inbox rule
  below.
  - Before, `labelNote` rewrote the note's `tags` and its `.distill.json`
    manifest, and a background suggestion rewrote the manifest. With the
    queue set to `inbox/`, those are files already in the inbox.
  - **Decision:** in inbox mode those writes go to
    `<state>/labels/notes.json` instead (keyed by requestID, newest 2000
    kept). The queue row's `labelsConfirmed` and the batch's label plan
    merge it over the manifest, so what reaches the wiki is unchanged. When
    the queue is elsewhere, the files are still in the queue, not the vault,
    and are edited as before.

- **A batch's move into `inbox/` is create-only.** Spec: [Queue and
  batching](queue-and-batching.md) → Batch, Folders. Follows the inbox rule
  below.
  - Loose files now move with `moveIntoDirNoOverwrite` (hard link, then
    unlink, or an exclusive copy). Folder items move with
    `moveFolderIntoDirNoOverwrite` (an exclusive `mkdir` claims the name).
    Before, the batch checked `existsSync` and then used `renameSync`, which
    silently replaces a file that appears in between.
  - A folder item's `.gdoc` pointers are recorded in its
    `.distill-folder.json` while the folder is still in the queue folder.
    Before, that file was rewritten inside `inbox/<date>/<name>` after the
    move.

- **Distill may add new files to `inbox/`; it never edits one already there.**
  Specs: [Architecture](architecture.md) rule 2, [Queue and
  batching](queue-and-batching.md) → Queue folder. Owner-approved from the
  compliance audit (item A).
  - claude-obsidian keeps `inbox/` outside the transaction system:
    `claude_obsidian/transaction.py` lets no operation write `inbox/` (only
    setup writes `inbox/.gitkeep`), and `skills/wiki-ingest/SKILL.md` says
    files already there "remain user-owned and read-only".
  - **Decision:** Distill may ADD new files to `inbox/` without a
    transaction, the way a user drops a file there by hand. It must never
    edit, overwrite or automatically delete a file already there. Every
    `wiki/` and `.raw/` change still goes only through the reviewed
    transaction.
  - Architecture rule 2 said "the vault is written only by the Python core",
    and the `distill-note` skill promised nothing reaches the vault before
    approval. Both were wrong when the queue is `inbox/`; both now name the
    exception.

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
