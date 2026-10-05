# Building Distill with AI: practice log

**Why this file exists.** It records how the owner works with Claude to build the
Distill app: what worked, what broke, and what we changed because of it. After the
first beta, the owner will review it and turn the practice into a reusable skill,
so the next product starts with these lessons instead of hitting the same limits.

**How to read it.**
- **Practices** are what we do now, each with the reason.
- **Friction log** lists the issues and limits we hit, newest first, each with what
  we changed.
- **Open questions** collects ideas to settle before writing the skill.

**Keeping it current.** The assistant appends to this file during the work.
- Add a new practice when the owner introduces or corrects a way of working.
- Add a friction entry when something goes wrong, is slow, or has to be redone.

Keep entries short and concrete, and date them. This file is contributor-only.
Root files ship only if listed in `config/release-allowlist.json`, and this one
isn't.

---

## Practices

### Roles and flow
- **The owner directs and reviews; Claude is the lead.** The lead writes contracts
  and briefs, starts teammates (subagents) in isolated git worktrees, merges,
  tests, commits and reinstalls. Teammates return drafts and evidence; the lead
  integrates. This keeps parallel work from colliding and gives one place where
  quality is checked.
- **Design first, on a shared canvas.** Every visible change goes to the design
  canvas (a claude.ai Design artifact) before code. Code waits for the owner's
  OK. The owner reviews only the canvas and the real app. *Why:* a cheap place to
  disagree, before code makes the change expensive.
- **The canvas as a schema in the repo.** The canvas comes from
  `apps/distill/design/`, in three layers:
  - tokens from `Theme.swift`;
  - components that map one-to-one onto Swift views;
  - screens whose states are small overrides, not copies.

  A drift test fails when the design and the code disagree. *Why:* editing
  hand-made boards got very slow (see 2026-10-04).
- **Publish in pieces.** Publish each board as soon as it's done; don't hold
  everything for one big reveal.
- **Commit after every build or merge; never push** without explicit approval.
- **Specs and decisions alongside the code.**
  - `apps/distill/docs/specs/` holds a spec per feature.
  - `decisions.md` is a dated log of every choice, including defaults the owner
    didn't pick, so they can veto them later.
- **Reinstall without losing data.** `distill.sh update` backs up the data, runs
  the tests, installs, and compares data counts before and after. Restart the
  core after every install so the new UI never talks to an old core.

### Testing
- **Test what the user runs, not a proxy.**
  - Snapshots, unit tests and fixtures are not the app: test at the owner's
    real window size (~890 pt) and with real-shaped data.
  - Report what wasn't checked, alongside what passed.
  - Known blind spots live in `.claude/skills/distill-macos-e2e/`.
- **Never touch the owner's real data or app.**
  - Use throwaway vaults and a temp state dir.
  - Drive a renamed copy of the app, targeted by PID.

### Writing skills and agents
- **A frame, not a script.** Skills and agents set intent, context, preferences
  (labelled as defaults), known gaps and a few boundaries, each with its reason.
  They invite the model to go beyond the text.
  - See `.claude/skills/authoring-skills-and-agents/`.
  - *Why:* current models follow instructions literally, so every rule caps
    them.
- **Specialist agents for judgement work.** For example, `.claude/agents/distill-pm.md`
  is a senior product manager for UI/UX and market reviews.

### Communicating
- **The owner speaks in short, sometimes dictated messages, often mid-task.** The
  lead restates its understanding of a request, picks sensible defaults, and
  asks only what blocks progress, with a recommendation.
- **Plain-language status.** Lead with the outcome, then the evidence, then
  what's left.
- **A numbered list of pending work.** When decisions pile up, the lead lists
  everything open, numbered and grouped (running, waiting on the owner,
  follow-ups). The owner answers several in one short message ("2 no, 3
  build it, do 7–10"). *Why:* questions scattered across long replies got
  lost.

---

## Friction log (newest first)

### 2026-10-05

- **A batch looked frozen for four minutes.** One of the owner's batches
  started at 03:33:13Z and Claude's first step came at 03:37:08Z. The app
  showed nothing in between, while labels were suggested one file at a time.
  The owner asked whether any log showed a batch's progress or a collector's
  output.
  - *Change:* the live log (a batch's steps in plain words, a collector's
    output in order, live and kept), and labels suggested 3 at a time.
  - *Also:* another teammate was editing the engine at the same time, so
    the live log reached into it through one narrow sink and derived every
    other step from existing events, instead of rewriting the engine.
- **Labels were invisible until after approval.** The batch suggested labels
  inside its own run and wrote them to pages as unconfirmed. Review never showed
  them, and only collector-free notes got chips in the queue. The owner found it
  by looking at a real 22-file batch: "I will never see the label suggestion."
  - *Lesson:* trace a feature's data through every screen the user passes, not
    only the one that produces it. A value that exists only inside a bundle is
    invisible to the user.
  - *Change:* labels are suggested in the queue (3 at a time), shown and edited
    in Review, and approving confirms what was shown. The approval hash is
    recomputed through a label revision, never by editing an approved bundle.
- **Scope grew three times during one task.** Pick and remove per source, the
  label gate, approve without labels, then the session-gone rule.
  - *Lesson:* commit at each scope change and keep the seams explicit
    (`resumeBatchSession`), so a teammate can own the cross-cutting part.
- **A rehearsal on a copy beat reasoning about the real job.** Copying the
  pending job, its worker folder and the six bookkeeping files into a
  throwaway vault showed exactly what the reinstall will do (labels confirmed
  in revision 1, no AI call), without touching the owner's data.
- **Probing the real CLIs paid off twice for session continuity.** The rule is
  "never resume into a session that is gone", and it depends on telling a
  missing session apart from any other failure. Guessing that from error text
  would have been fragile. So the teammate ran `claude -p --resume <random
  id>` and `codex exec resume <random id>` once each, with a throwaway
  `CLAUDE_CONFIG_DIR` / `CODEX_HOME` so the owner's transcripts were never
  touched. That gave the exact refusal lines, which the code matches together
  with the exact session id.
  - The probe was repeated after the live-log merge switched Claude Code to
    `stream-json`, and the result had changed. Claude Code now also prints an
    error `result` event on stdout, so the old "empty stdout" path no longer
    ran and a refused resume would have looked like an ordinary failed turn.
    The detection now checks stderr before it parses stdout.
  - Lesson: when a teammate changes how a runner is invoked, probe the edge
    cases again rather than trusting the earlier result.

### 2026-10-05
- **A rehearsal touched the owner's real AI session.** To test the reinstall,
  a teammate copied the owner's pending batch and called approve with the real
  runners. That resumed the owner's real Claude session and added one turn to
  its transcript (Claude refused, because the vault didn't match). The real
  vault was unchanged.
  - *Change:* the e2e skill now says copied jobs must use an inert runner or
    a fresh session ID.
  - *Lesson:* copying a record also copies the pointers inside it, such as
    session IDs and paths. Cut those links before exercising the copy.

### 2026-10-04
- **An edit outside Distill left no trace in the activity log.** The owner
  saved a kept collector script at 22:41 and found no activity entry. The
  evidence showed that no request had reached the core: the file kept its
  birth time, and IDLE's recent-files list named it. Open in editor had
  opened the `.py` in IDLE, the Mac's default app for it.
  - *Change:* the core remembers the hashes of the script files it last
    wrote or saw, and logs a change made elsewhere once, before the consent
    that covers it.
- **The script editor crashed the app** (22:41:41, from the macOS crash
  report). Text replaced from outside with shorter text left the old
  selection past the end, and the code handed AppKit an empty selection
  list, which it rejects.
  - *Change:* the selection is clamped to the new text and never empty; a
    unit test covers it.
- **An audit handoff worked well as a spec, but it listed symptoms, not every
  reader.** A compliance audit found where Distill broke claude-obsidian's
  rules: it edited files in `inbox/`, the core didn't enforce the approval
  gate, and it trusted the model's apply report. The owner approved items A
  and B, and a teammate built them from the handoff, one commit per item.
  The handoff gave file and line evidence, which made the work fast. A
  reviewer pass before coding still caught gaps the handoff left:
  - a third reader of note labels (the queue row);
  - a queue set to `wiki/` still received notes and drops even after the
    validator blocked batches;
  - `renameSync` silently replacing a file in `inbox/`.
  - *Lesson:* when a rule says "never write X", list every writer and every
    reader of X before coding, not only the lines the audit named. A short
    advisor or reviewer pass before the first edit is cheap insurance.
- **The worktree sandbox refused long shell heredocs.** Multi-line
  `python3 - <<EOF` edits containing `$` or `\n` were rejected as "too
  complex to verify", and one Write aimed at the shared checkout instead of
  the worktree was blocked.
  - *Change:* write edit scripts to a private scratchpad folder and run them
    as `python3 <file>`, or use the Edit tool. Always build paths from the
    worktree root.
- **Green tests, broken on the owner's Mac.** Collector scripts ran with the
  login shell's `node`, which on this Mac is v14 (`/usr/local/bin`), not
  nvm's v22. TypeScript and npm installs passed every test but would have
  failed for the owner. A teammate's live run against a real core caught it.
  - *Lesson:* check the owner's actual toolchain (`zsh -lc 'which -a …'`), not
    the agent's PATH. Added to the e2e skill's known gaps.
- **Teammates collided in the shared scratchpad.** One overwrote another's
  helper script and briefly used another's QA folder.
  - *Change:* briefs and the e2e skill now say to use a private subfolder.
- **The owner's own deletions looked like data loss.** Three Ask chats and a
  Script collector disappeared. With no activity record, we spent a long time
  investigating and suspected a teammate's stray input. In the end the owner
  had deleted them.
  - *Change:* an activity log for the app (what changed, when, from where),
    designed on the canvas first.
  - *Lesson:* an app that holds user data needs an activity log and an undo or
    trash for deletes from the start, not after the first scare.
- **A deliverable was left in a temporary folder.** The meeting-notes script
  was written to the session's scratchpad, so the owner had to ask where it
  was. It then moved twice: to `~/Scripts`, then `apps/scripts/`, then its
  own folder with a README.
  - *Lesson:* anything the owner will keep goes where it will live from the
    start (ask if unclear), and comes with its setup instructions.
- **"Pre-existing environmental failures" sat unexamined.** `make test` stopped
  on Python suites for days under that label, so the full gate never ran.
  - *Change:* a teammate now finds the root cause of each one.
  - *Lesson:* a failure is not "environmental" until someone has proved it.
- **Designed around a file with no content.** The `.gdoc` plan assumed Google
  Drive's local `.gdoc` files held the document. They are only links, and the
  owner caught it.
  - *Lesson:* check what a data source actually contains before designing
    around it.
- **"Not now" did nothing with only one collector.** The tests covered several
  collectors, not one.
  - *Lesson:* test the single-item and empty cases, not only the typical one.
- **Collectors went from request to installed in one pass:** canvas, redesign,
  then building the core and the Mac app in parallel. The core was built while
  the UI was still being polished, because it doesn't depend on layout. That
  saved a full round.
  - *Limit hit:* the Mac's screen was locked during every real-app phase, so
    the click-through went to the owner.
  - *Idea:* a way to test the real UI headlessly (accessibility-driven, in an
    offscreen session) would remove this recurring gap.
- **A reviewer subagent found real holes in the new skills.**
  - The e2e skill's "isolated" setup didn't isolate the Keychain or
    UserDefaults: a test core could overwrite the owner's real API keys.
  - The PM agent didn't know the product's stage or audience.
  - The authoring skill broke two of its own rules.
  - *Change:* applied the ranked fixes.
  - *Lesson:* review every new skill or agent with a fresh subagent, and try
    it on a real task with and without it.
- **A teammate's input hit the owner's installed app.** Keystrokes and a resize
  sent to "Distill" by process name reached the real app. Its Settings opened
  and the window size changed. The same day the owner's 3 Ask chats were
  deleted; there's no proof of the cause, and a backup exists.
  - *Change:* the e2e skill now requires a renamed copy targeted by PID, and no
    Return or clicks on unconfirmed windows.
  - *Also learned:* the reinstall data check compares only before and after the
    install, so it can't see a loss that happened earlier.
- **Settings was built as long group pages, not one page per section** as the
  canvas showed. The owner noticed through scrolling behaviour.
  - *Change:* rebuilt to match the canvas.
  - *Lesson:* compare the structure with the design, not only the visuals.
- **"Connecting…" got stuck** after the owner left the token setup. The design
  had a transitional state that the real flow (a pasted token) never ends.
  - *Change:* states are now only connected or set it up.
  - *Lesson:* don't design states that the implementation can't leave.
- **Canvas edits were very slow.**
  - *Causes:* every state was a full screen copy; the generators sat in a temp
    folder, unversioned; a single teammate worked through the boards one after
    another; and the lead held the publish until everything was done.
  - *Change:* the design schema in the repo, publishing in pieces, and splitting
    boards across teammates.
- **The scope grew mid-design,** from one filter bar to every Actions tab, and
  that restarted work.
  - *Lesson:* when the owner widens the scope, publish what's done first, then
    start the larger pass.
- **The real-app test was skipped because the screen was locked.** That's
  recorded in the e2e skill. The owner tests by hand when automation can't.

### 2026-10-03
- **A layout fix shipped before the canvas was updated.** The owner corrected
  this: "you should update the canvas first".
  - *Change:* even layout bug fixes go to the canvas first, unless they restore
    what the canvas already shows.
- **The stopgap fix looked bad.** Wrapping the filter chips onto two lines fixed
  the cut-off, but the owner called the result ugly.
  - *Lesson:* judge fixes by eye, not only "nothing is cut off".
- **Tests passed, but the app broke at the real window size.** Snapshots render
  roomy fixed sizes; the owner runs about 890 pt.
  - *Change:* narrow-width checks are in the e2e skill and in the tests.

### 2026-10-02
- **Messages crossed between the lead and teammates.** Teammates reported work
  the lead had already asked for again, and replies arrived after new briefs.
  - *Lesson:* keep briefs complete and self-contained; check the files before
    re-asking.
- **The live canvas changed under us.** The owner moved and resized boards in the
  editor while teammates rebuilt.
  - *Change:* always re-read the live canvas and merge onto it before
    publishing.
- **A flaky async test crashed and blocked an install.** A task outlived its
  model.
  - *Change:* run the suite more than once after async changes.

---

## Open questions for the skill

- **How much of this generalises beyond a macOS app?** Canvas-first and the
  schema probably do. The installer and core specifics don't.
- **Should the design schema become its own reusable tool?** For example, a
  "design-as-schema" starter.
- **Approval rhythm.** The owner sometimes approves in advance ("after the design
  is built, directly build"). Where is that the right default?
- **Where should the owner's own preferences live,** for example "no local
  previews" and "commit after each build"? In the skill, or in the owner's global
  memory?
