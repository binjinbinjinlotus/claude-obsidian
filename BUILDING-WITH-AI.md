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

---

## Friction log (newest first)

### 2026-10-04
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
