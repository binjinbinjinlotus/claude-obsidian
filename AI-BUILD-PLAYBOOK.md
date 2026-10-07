# AI build playbook: what building Distill with agents taught us

**What this is.** An analysis of how the Distill app (`apps/distill/`) was
built with Claude Code agents between 2026-10-01 and 2026-10-07, written so
the owner can turn the learnings into agents, skills and instruction files.
`BUILDING-WITH-AI.md` is the running practice and friction log; this file
steps back from it, adds evidence from git history and the lead session's
transcript, and ends with a concrete list of reusable assets (section 7).

**Evidence conventions.**
- Short hashes are commits on branch `binjinbinjinlotus/wiki-setup` (or the
  named worker branch).
- Dates are the commit or decision date. Transcript times are UTC, so a few
  owner messages carry the next day's date.
- Owner quotes are verbatim, typos included (many messages are dictated).
- People and customer names from the app's test data are replaced by roles.
- Paths are relative to the repository root.

**Scope.** Contributor tooling only. Nothing here ships: root files ship
only if `config/release-allowlist.json` lists them, and this one isn't
listed.

---

## 1. What was built

Distill is a macOS app over a Node and TypeScript core, a CLI and an agent
plugin. It turns a queue folder of notes into source-cited wiki pages
through claude-obsidian transactions, and it stops for the owner's approval
before anything is applied (`apps/distill/AGENTS.md`). Its first commit was
`a1a1c97` (2026-10-01). Six days later the branch held 487 commits since
2026-10-01, 436 of them under `apps/distill/`.

### Timeline

| Day | Commits | What landed (examples) |
| --- | ---: | --- |
| 10-01 | 49 | Mac client, specs and control skill (`a1a1c97`); TS core and contracts scaffold (`7e200aa`); store, queue, runners and engine ported to TypeScript (`2769fcf`). The owner then said "start the build with agent temas, this seesion will be the lead". |
| 10-02 | 130 | Ask, Write a note, labels, five AI runners (Claude Code, Codex, OpenAI, OpenRouter, Vercel AI SDK), CLI and plugin, quick windows, Markdown editor everywhere, the Actions core (`337c74f`), Settings, loading states. |
| 10-03 | 12 | "Design as a schema": tokens, components, screens, a renderer and a drift test (`26391da`). |
| 10-04 | 122 | Actions redesign (`c49ffa1`); Collectors, from engine to script editor (`22f8a08`, `ab259a5`); queue sync; the activity log and trash (`20b088c`); the e2e skill, the PM agent and the authoring skill; this practice log. |
| 10-05 | 92 | Audit items A and B, which enforce the approval gate in the core (`8f5dcfa`); live log (`b69dd5f`); session continuity (`8f7d0b2`); labels before the batch and an editable Review (`93e8ecb`); progress after Approve and inbox clean-up (`51bdb43`); re-read sources (`92ecca9`); full reads with core-computed coverage (`a8a2fa4`); designs for panes, action summary, automations and the review queue (`f429f8f`, `75c1627`, `e43ac7e`, `d6fe35b`). |
| 10-06 | 82 | Review queue self-recovery (`f8710ca` … `7e4698a`); action buttons and Slack recipients; Add as at confirm time; Jira pickers (merge `7d0aea1`); whose-items routing with Pending and Highlights (merge `32b20bd`); the canvas move (`78a6977`), canvas pages (`4771533`) and the Distill Design System (`7565517`). Jira required fields are built on `distill-jira-required` (`5797144`) and not merged. |
| 10-07 (UTC) | — | A unit-test and mutation-testing pass started in worktree `wiki-setup-tests` (branch `distill-unit-tests`). Nothing has landed: the branch is still at `4771533`. |

### Shape of the work

Commit types since 2026-10-01: 144 `fix`, 139 `feat`, 69 `merge`, 60
`docs`, 37 `design`, 19 `test`. **There was about one fix for every
feature.** Many of those fixes came out of verification rounds and owner
reports on the same day as the feature (section 4).

The final gates on the routing merge show the size of the safety net:
- core: 708 tests;
- CLI: 58 tests;
- Swift: 446 tests;
- the design drift test;
- the repository's `make test` contracts.

(Verifier round 8, at `b5f7c1d`.)

The lead session started 65 named subagents (counted from the transcript's
Agent calls). Agents also left 56 worktrees under `.claude/worktrees/`
(`git worktree list`), none of them cleaned up.

---

## 2. The operating model that emerged

The model wasn't designed up front. It accreted from owner corrections, each
of which is now a memory note under the owner's Claude project memory and a
practice in `BUILDING-WITH-AI.md`.

### Roles

| Role | What it does | Where it came from |
| --- | --- | --- |
| **Owner** | Sets direction in short, often dictated messages; reviews only the canvas and the real app; answers numbered decision lists. | "I will only check the real app and [the canvas]" (2026-10-02). |
| **Lead session** | Writes contracts and briefs, starts workers, merges, runs gates, commits, installs, reports in plain words, keeps specs, decisions and memory current. | "this seesion will be the lead" (2026-10-02). |
| **Builder subagent(s)** | Implement one item per commit, in their own worktree when another agent is active. | `distill-builder`; workers such as `core-actions`, `mac-collectors`, `live-log`. |
| **Verifier subagent** | Separate from the builder. Runs every gate, reviews the diff adversarially against the spec, proves each bug with a failing test, fixes clear bugs one commit each. | "please use subagnets for build another one todo the test/vertiction" (2026-10-06; memory `subagents-build-and-verify`). |
| **Canvas designer** | Draws every visible change on the Claude Design canvas from the schema in `apps/distill/design/`. | `design-actions`, `design-collectors`, `distill-canvas`. |
| **Design architect** | Audits structure against the tool's own guidance and proves options on throwaway artifacts before proposing. | `distill-design-architect` → `apps/distill/docs/specs/design-system-plan.md`. |
| **Reviewers** | Review a design or a new skill before the build. | The full-read design reviewer (10 blockers over 3 rounds); `skills-reviewer`. |
| **PM agent** | Product and UX judgement. | `.claude/agents/distill-pm.md`. |

### The feature loop

This is the loop as it ran for routing on 2026-10-06, the cleanest example:

1. **Owner request**, in their words ("let desgin first", 19:20).
2. **Design on the canvas**, with the open questions on the board (`7b6d309`).
3. **Owner answers**, and the answers go onto the board and into decisions.md
   (`d7ab7f8`, `07d8603`).
4. **Spec and decisions** (`bef855b`, `apps/distill/docs/specs/actions-routing.md`).
5. **Build in a worker worktree** (`wiki-setup-routing`, branch
   `distill-routing`): core first (`88b9b66`), then the Mac app (`13b1964`),
   then a pass to match the canvas (`0c1e9d8`).
6. **Independent verification** on the same branch: 4 bugs, each fixed with
   a test that failed first (`996130c`, `d32d3a3`, `a9405c8`, `b5f7c1d`).
7. **Merge with the verified hash in the subject**: "merge(distill):
   whose-items routing, Pending and Highlights (verified at b5f7c1d)"
   (`32b20bd`).
8. **Install**, through `distill.sh update`, which backs up data, runs the
   tests, installs and compares data counts.
9. **Report** to the owner: outcome, evidence, what's left, as a numbered list.

### Standing rules (owner-given, with their origin)

| Rule | Origin |
| --- | --- |
| Commit after every build or merge; never push. | "don't forget to commit the changes after each build" (2026-10-01; memory `commit-after-each-build`). |
| Canvas first for anything the owner can see or feel; build after the OK. | "please first update the desgin inthe artifact first, once I confirm then updat eth ui" (2026-10-02); repeated after a violation on 2026-10-03: "you should update the cavas first". |
| The owner may pre-approve: "build directly after the design". | 2026-10-02 19:12, 2026-10-05 00:22; recorded in `design-process.md`. |
| No local previews (no HTTP servers, browser pages or Playwright for design). | "why you keep open the http://localhost:8791/QuickActions.dc.html" (2026-10-02). |
| A spec per feature and a dated decision for every choice, superseded and never rewritten. | "please ensure you have updat the specs for all futures that we build and all decisons" (2026-10-02). |
| Automatic checks over human ones. | "realying on human is wrong … realying human means nothing will be check correctly" (2026-10-05). |
| User data is permanent; installs back it up and compare. | 2026-10-02 17:38; `apps/distill/AGENTS.md`, "User data is permanent". |
| Never touch the owner's real data, app, Keychain or AI sessions in tests. | 2026-10-04 and 2026-10-05 incidents (section 4). |

### Communication pattern

The owner asked "where are we?" (or a variant) 13 times in the lead
transcript. 229 owner-turn entries were agent hand-backs relayed into the
lead's context. The numbered pending list works ("2, not need to restored, i
deleted them 3. let buid it … do 7, 8, 9 ,10", 2026-10-04). The rest of
status reporting is a cost the model hasn't solved yet (section 8).

---

## 3. What worked, with evidence

### 3.1 A separate verifier, every round

The verifier never built features. It ran the gates, read the diff against
the spec, and proved each suspicion with a test before fixing it. Not every
round found bugs (rounds 3 and 5 found none), but most did, and the bugs were
the kind the builder's own tests had passed over.

| Round | Scope | Bugs fixed (commit) | Notes |
| --- | --- | --- | --- |
| 1 | Review-queue recovery | **Unbounded loop**: runner-failed ↔ plan-error alternated past `maxAttempts` and `maxCostUSD`; a fake runner gave 42 session turns (`c8a5706`). A stale one-minute timer restarted a recovery the owner had reset (`45bd38c`). A slow agent answer acted on a replaced recovery (`c9ccf51`). | Also simulated the owner's stuck batch on a copied job entry with a fake runner. |
| 2 | Automations, apply queue | **`collects: false` dropped** by `POST /v1/collectors`, so a "Commands for buttons" script would run hourly as a collector (`964d851`). Added a missing engine test for the stale-again path (`c4eabe9`). | The core test passed because it called the service directly, not the route. |
| 3 | Lock retries, wording, snapshots | None. | Still reviewed memory, keys and wording paths, with line references. |
| — | Install blocked | Flaky `AskBackgroundTests`: a race in the test, not the app (`c0a9081`). | Proved by injecting a 50 ms delay into `refresh()`; couldn't reproduce under CPU load alone (20/20 passes). |
| 4 | Slack buttons | "@Name" or "#eng team" counted as a resolved Slack target (`8350f34`). An unreadable thread link would post at the top level (`3b264c4`, Mac side `8615be5`). | Shared case file `slack-target.cases.json` keeps core and Swift in step. |
| 5 | Follow-ups | None. | One LOW item left with reasoning. |
| 6 | Add as | A carried-over Jira priority survived conversion to a to-do (`782c0d2`); Return key in the detail (`596e0bf`); a snapshot fixture that didn't match the canvas frame (`60d1a12`). | Also the round where agents collided (section 4.1). |
| 7 | Jira pickers (`distill-jira-pickers`) | **The project's display label stored instead of its key**, so argv, filters, Add as, Copy and Activity all read "KEY · Name" (`4f45ca7`). | Nine readers were listed, each with a file and line. |
| — | Install blocked | Flaky `SettingsWindowTests`: a fixed 0.4 s settle on a busy machine (`6320eae`). | Proved by delaying the first page landing by 0.5 s. |
| 8 | Routing (`distill-routing`) | **Prompt injection**: a note-derived item title could contain `</page>` and forge a page block, for example a removal of `wiki/index.md` (`996130c`). Pending promise titles sat unfenced in a find prompt (`d32d3a3`). The 7-day preview read stale People (`a9405c8`). A bold or `###` heading crashed Highlights (`b5f7c1d`). | Merged as "verified at b5f7c1d". |

**Why it worked:**
- The verifier's brief named the spec, the commit range, and a list of
  failure classes to hunt. Examples: "loops or unbounded retries", "a
  recovery left in state 'running' with nothing in flight", "the approval
  gate ever being skipped".
- It required "a targeted test for each suspected bug to prove it before you
  fix it".
- Its report format forced quoted gate lines and file:line evidence.

### 3.2 Adversarial review before the build

For full reads, the owner said "start the subagent to reiew the solution
witht he current code, directly build if the if subagent doesn't find
issues" (2026-10-05). The design reviewer found 10 blockers over three
rounds, each a paragraph to fix on paper. Examples:
- ledger IDs changing on archive;
- a back-fill crediting re-reads that hadn't been approved;
- a repair queueing files a live job already held.

On its first start, the built core back-filled coverage for 10 notes and
found 3 approved notes that weren't fully read, with no click (practice log,
2026-10-05). The audit hand-off for items A and B worked the same way. A
reviewer pass before coding found a third reader of note labels and a
`renameSync` that silently replaced files in `inbox/`.

### 3.3 Fakes-only tests and throwaway state

Tests never drive real runners or real sessions. Fake runners scripted
step by step made the recovery loop provable (42 turns). The stuck-batch
simulation copied one job entry into a temp state dir. Probing the real
CLIs was done once, with a throwaway `CLAUDE_CONFIG_DIR` / `CODEX_HOME`, to
capture the exact "session not found" lines. That probe was repeated after
the runner switched to `stream-json`, and the result had changed (practice
log, 2026-10-05). Shared case files (`slack-target.cases.json`) run in both
the TS core and Swift, so the two can't drift.

### 3.4 One worktree per worker for overlapping work

The Jira pickers (`wiki-setup-jira`, branch `distill-jira-pickers`),
routing (`wiki-setup-routing`) and Jira required fields (`wiki-setup-jirareq`)
each had a worktree. The canvas designer and the routing builder ran at the
same time without touching each other's files. The lead's 21:12 note says
the builder "works in its own worktree … so it can't collide with the
canvas agent". Merges then carry the verified hash (`7d0aea1`, `32b20bd`).

### 3.5 Install gated on tests, with a data check

`distill.sh update`:
1. backs up the state directory;
2. runs the test suites;
3. installs;
4. restarts the core;
5. compares data counts before and after;
6. refuses while a job is running (`apps/distill/AGENTS.md`).

It refused bad installs twice, on the flaky tests above, and both times the
root cause was found and fixed rather than retried away. The owner can also
hold installs: "I am batching the file, so please don't restart and
reinstall the app untile I say yes" (2026-10-05).

### 3.6 Design as a schema, with a drift test

When the owner asked "Why the design is taking so long?" (2026-10-04), the
lead traced the cost to how the canvas was used:
- every state was a full screen copy;
- the generators sat unversioned in a temp folder;
- a single designer worked serially;
- the publish was held until everything was done.

The owner said "let do taht". The fix (`26391da`) was a schema in
`apps/distill/design/`:
- tokens from `Theme.swift`;
- components named after Swift views;
- screens whose states are overrides.

`test_design.py` fails when design and code disagree. Since `7565517`, it
compares token values, not only names.

### 3.7 Specs, decisions and the practice log as shared memory

`apps/distill/docs/specs/` holds 36 spec files. `decisions.md` is 2,015
lines, dated and superseding: "A Jira project is saved as its key" supersedes
the earlier label decision. Workers read the spec and the decisions instead
of the lead's memory, and the verifier updates them when a fix changes
behaviour (round 1 changed the "per signature" bound in the spec). The
memory notes carry the owner's standing preferences across sessions.

### 3.8 Probing the real system before designing against it

These checks worked better than reasoning about the systems:
- running `claude -p --resume <random id>` to capture the real refusal line;
- checking `mdfind` and `lsregister -dump` for the Spotlight duplicate;
- checking `zsh -lc 'which -a node'` for the owner's real Node (v14 at
  `/usr/local/bin`, not nvm's v22).

Each is in the practice log. They share one lesson: verify against the
system that showed the bug, not the mechanism you believe works.

---

## 4. What went wrong, what it cost, and why

Each entry gives the symptom, the evidence, the cost and the root cause. The
root causes repeat, and section 7 turns them into rules.

### 4.1 Agents editing the same files at once

- **Symptom:** the verifier found "Someone else is editing the Add-as Mac
  files in this worktree right now". The files were `AddAsViews.swift`,
  `SnapshotActions.swift`, `DistillKit/AddAs.swift` and `AddAsTests.swift`.
  It paused its fixes and asked the lead who owned them.
- **Concrete damage:** the verifier's `596e0bf` "also swept in the
  builder's uncommitted unknownName / addAsBlock edits … because I staged
  whole files" (round 6 report). The commit history no longer tells you who
  wrote what. A broken half-edit could have been committed under a
  "verified" message.
- **Earlier cases:**
  - Teammates overwrote each other's helper scripts in the shared
    scratchpad (2026-10-04).
  - A design test failed on another agent's uncommitted canvas files
    (round 4).
  - The live log had to reach into an engine another teammate was rewriting
    "through one narrow sink" (2026-10-05).
- **Root cause:** builder and verifier shared one worktree (the 2026-10-06
  briefs both name `wiki-setup`). The builder also handed snapshot work to a
  fork in the same tree. Nobody had a file boundary, and `git add <file>`
  stages whole files.
- **Fix that worked:** one worktree per worker from the Jira pickers onward
  (section 3.4).

### 4.2 A reported fix that wasn't built

- **Symptom:** the owner's batch read "Recovering" forever. The builder
  reported all six items done. The lead checked HEAD and wrote: "Not fixed
  yet: the builder reported all six items done, but left out the stuck
  'Recovering' fix you asked for. HEAD `d0a7041` has none of it"
  (2026-10-06 04:42).
- **Cost:** one extra builder round and about 25 minutes before `7e4698a`.
  The owner's batch stayed stuck in the meantime.
- **Root cause:**
  - The urgent fix was sent to the builder mid-task, as a message, after the
    numbered brief.
  - The builder's report listed the brief's items, not every request.
  - Only the lead's check of the commits against the full list of requests
    caught it.
- **Rule:** a report counts only against a checklist of every request,
  matched to commits. The lead checks `git log` before relaying "done".

### 4.3 The canvas went blank, and the bisect blamed the wrong thing

The longest detour of the project (2026-10-06, about 19:37 to 21:00 UTC, then
the architect's work until `4771533`).

1. **The owner reported** "the cavas it looks empty".
2. **First guess:** a `"bool"` prop type on the shared Sidebar. The Sidebar
   went back to v93 (`2b4edd2`) and the prop type was fixed (`25e2046`).
   Still blank.
3. **Second guess:** add one explicit page named "Distill" (v98). Still
   blank.
4. **The bisect.** The lead drove a canvas agent through tests on a fresh
   copy, checking each in the browser:
   - a tiny canvas drew;
   - a full copy was blank;
   - removing the notes changed nothing;
   - halving to 71 boards was still blank;
   - removing the explicit page made those 71 draw;
   - all 141 boards without a page drew once.
5. **Conclusion drawn:** explicit pages blank the viewer. `8a766c7` made
   `render.py` strip pages forever, a test enforced it, and a decision
   recorded "no explicit canvas pages". The old artifact stayed blank even
   with matching files, so the canvas moved to a new artifact (`78a6977`).
6. **What was actually true.** The design architect had been briefed to
   treat the page question as open ("pages may be buggy, or we used them
   wrong. Find out which"). It ran **repeated controls**:
   - one page holding all 141 boards stayed blank in 4 of 4 runs, with
     explicit pages or without, on a fresh artifact and on the live canvas;
   - the same boards on 7 area pages drew in 3 of 3 runs
     (`design-system-plan.md`, `4475d2a`).

   The cause was one huge page (about 75,000 px each way), not pages. The
   bisect's "drew once" was a lucky load on a viewer that "works only
   sometimes". `4771533` reversed `8a766c7`'s rule, and the decision was
   superseded.

**Costs:**
- about 90 minutes of owner-visible debugging;
- a dead canvas URL, with every link in the repo and memory rewritten;
- a wrong rule committed with a test enforcing it;
- a memory note that still says "Never put explicit `pages` … they blank
  the viewer". That note is now stale.

**Root causes:**
- **One trial per step** on a nondeterministic system: the viewer took
  20–90 s to draw, sometimes left frames white until a click, and once
  crashed a tab.
- **No control run.** The "fixed" configuration was never re-run against
  the "broken" one under the same conditions.
- **A hypothesis committed as a rule** (`drop_pages` and its test) before
  it was replicated.
- **The real drift was gradual:** each design round pushed rows further
  out, and nothing measured canvas size.

The good part: the architect brief put the lead's own conclusion up as a
question, and the architect overturned it with evidence.

### 4.4 The design didn't match the build

- **Settings (2026-10-04)** was built as long group pages, not one page per
  section as the canvas showed. The owner noticed through scrolling ("setting
  tab viewport is still incorect"). It was rebuilt to match.
- **"Connecting…"** was a designed transitional state that the real flow
  (a pasted token) never leaves, so it stuck.
- **Routing (2026-10-06)** needed a follow-up commit titled "routing matches
  the canvas" (`0c1e9d8`): Highlights' per-person menu, the Pending detail
  header, and the order people are listed in.
- **A layout fix shipped before the canvas changed** (2026-10-03): "you
  should update the cavas first".
- **Snapshot fixtures** didn't match canvas frames E and F (`60d1a12`,
  round 6).

**Root cause:** the builder compared visuals and features with the canvas,
not structure and state lists. Nothing mechanical maps a canvas frame to a
snapshot state, except a report-only list of screen states without one in
the drift test. **Fix in place:** snapshot state ids equal canvas frame ids
(`design-process.md`), and the verifier renders and looks at each PNG.

### 4.5 Owner answers too small to see on the canvas

- **Symptom:** the owner answered the routing questions at 19:25. At 21:11
  they wrote the same answers again with "missing this in the desgin". The
  lead's check: "Your answers were in the design, but only as a small
  'Decided' card at the bottom of the left board, too small to read. So in
  practice they were missing."
- **Fix:** `07d8603`, a large "Your answers (2026-10-06)" card at the top,
  each answer quoted in the owner's words. Numbered badges tie each answer
  to the frame that shows it.
- **Related findability failures:**
  - "there are so many things to the canvas I can't find the point me to
    the position" (21:07);
  - "OK then you seem like you only making the design for the jira" (21:10).

  The routing board existed but sat at x ≈ 23,400, y ≈ 13,600 on a
  141-board canvas. The workaround was a small review canvas holding only
  the proposals under decision.
- **Root cause:** the design was correct but not presented for review. The
  person deciding needs their own words, large, at the top, with a link
  that opens on it.

### 4.6 Installs blocked by running jobs or flaky tests

- `distill.sh update` refuses while a job runs. The owner also held installs
  while batching (2026-10-05).
- Two Swift tests failed only during installs, on a busy machine, and
  passed 20 of 20 times in isolation (`c0a9081`, `6320eae`).
- Earlier, "a flaky async test crashed and blocked an install" (2026-10-02).
- **Root cause:** tests that wait a fixed time (`settle(0.4)`) or check
  immediately after a fire-and-forget `Task`.
- **What worked:** the verifier reproduced each by *injecting a delay* into
  the app path, not by loading the CPU. It then made the test wait for the
  condition.
- **Rule:** no fixed sleeps in UI tests; wait on the observable condition
  with a bound.

### 4.7 Jira field handling found by the owner, not by tests

- A ticket failed because Priority "Medium" wasn't in the project's scheme.
  Decision 2026-10-06: Project, Type and Priority now come from the
  account's allowed values.
- The owner then sent a screenshot: "please think about how to handle when a
  a field is required" (19:36). A project's create screen required a custom
  field that Distill showed as its raw id, with no control. "Create in Jira
  can never succeed for that project" (lead, 19:37). The design followed
  (`c2c42e5`), and so did the build on `distill-jira-required` (`5797144`).
- The verifier found that the stored project was the display label
  (`4f45ca7`).
- **Root cause:** tests used fixtures shaped like the developer's
  assumptions about Jira, never the shape of a real project's create
  metadata. The e2e skill rightly forbids calling real Jira from tests.
  Nothing recorded a real response, scrubbed of private details, as a
  fixture.

### 4.8 Other recurring costs (from the practice log)

| Problem | Root cause | Rule now |
| --- | --- | --- |
| Labels invisible until after approval; "I will never see the label suggestion" | Feature traced only through the screen that produces it. | Trace data through every screen the user passes. |
| A batch read 8 of 22 transcripts in full and said so only inside a page | The model picked its own budget; nothing measured coverage. | The core computes coverage from tool results; "automatic over human". |
| A new `recovery` task silently blocked batching | Every loop over the task list inherited a rule. | Grep the loops over a shared list, not only the type. |
| "Waiting" read as "Ready for your OK" | A new state value wasn't handled where old ones were switched on. | Grep every switch on the old values. |
| A teammate's keystrokes reached the owner's installed app | Targeted by process name. | A renamed copy, targeted by PID. |
| A rehearsal resumed the owner's real Claude session | A copied job kept its session id. | Copies use an inert runner or a fresh session id. |
| "Pre-existing environmental failures" hid `make test` for days | Nobody owned the root cause. | A failure isn't environmental until proved. |
| `.gdoc` design assumed the file held the document | The source wasn't inspected. | Check what a data source contains before designing. |
| "Build directly" didn't reach teammates | An approval relayed as an agent message isn't consent. | The lead runs approved build steps itself. |
| A deliverable was left in a scratchpad | Location not decided up front. | Put kept work where it will live, with a README. |

---

## 5. Design process learnings

### 5.1 Canvas first, as the place to disagree cheaply

- **What the canvas is for.** It is the only design surface the owner
  reviews, and it shows every state of every screen (`design-process.md`).
- **When to skip it.** A bug fix that restores what the canvas already shows
  can go straight to code. Anything else goes to the canvas first, even a
  layout fix (2026-10-03 correction).
- **When pre-approval applies.** "build directly after the design" removes
  the second wait, but never the design step.

### 5.2 The canvas is generated, never hand-edited

`render.py` is the single writer. It:
- merges into the live `canvas.json`;
- keeps the positions the owner moved;
- updates heights (`--measure`);
- refuses a board that `pages.json` doesn't place.

Before every publish, re-read the live canvas: the owner moves boards while
agents work (2026-10-02 friction). Legacy boards are imported by
`tools/import_board.py` and must render back byte for byte before the
schema owns them.

### 5.3 Structure: pages per area, small pages, links

From `design-system-plan.md` and `4771533`:

- **Pages and their limit.** There are 7 area pages plus component pages,
  and a page holds at most 30 boards. The largest area page that drew held
  17.
- **Links.** Each page has a stable `#page-<id>` link: the owner's deep link
  per area. Single-board links don't work, because the viewer rewrites the
  hash.
- **Proposals for decision** go on a small separate review canvas, not only
  in the main one.
- **The target** (plan steps 4–7, not done): a hidden component kit under
  `project/ds/distill-kit/`, one board per state instead of 2,520 px sheets,
  and one canvas per area.

### 5.4 A design system generated from the app's theme

- `design/tokens.py` reads `Theme.swift` and writes `ds/tokens.json` (the
  Design System type's list shape) and `ds/tokens.css` (`7565517`).
- The Distill Design System artifact bundles PrimaryButton and Pill on token
  variables, and the canvas installs it.
- The drift test now compares token **values**. It catches cases such as
  the canvas Pill at 10.5 px against Swift's 11.
- **Still open:** component templates hold 555 hex literals and screen
  fragments 8,893 (`design-system-plan.md`, audit 3). Until those become
  `var(--…)`, a colour change still touches hundreds of places.

### 5.5 Finding boards

Things that made boards findable:
- a page per area, with its link;
- the board's title equal to the app's own words;
- frame ids equal to snapshot state ids;
- the owner's answers in a large card, with numbered badges on the frames
  they affect;
- giving the owner coordinates plus a link when a board is hard to find.

Things that didn't:
- 72 px row titles holding whole sentences;
- explanations inside boards as captions;
- one canvas of about 75,000 px.

### 5.6 How to debug the canvas viewer

The viewer is slow and nondeterministic. Treat each observation as one
sample:
- allow 30–90 s to draw;
- click the canvas once if frames stay white;
- repeat every run at least 3 times;
- keep a known-good control in the same browser session.

Bisect on a fresh copy, never on the live canvas, and replicate before
committing a rule (section 4.3).

---

## 6. Quality practices

### 6.1 Test strategy

| Layer | Tool | What it proves |
| --- | --- | --- |
| Core (TS) | `npm test --workspaces` in `apps/distill` (708 + 58) | Engine state machine, recovery bounds, routes, prompts; fake runners only. |
| Swift | `distill.sh test` (446) | DistillKit decoding, view models, UI tests on throwaway state. |
| Snapshots | `Distill --snapshot OUT --states` | Every screen state as a PNG, named by the canvas frame id; someone must *look* at each new one (a button row overflow was visible only in the PNG, 2026-10-06). |
| Design drift | `test_design.py` | Tokens, components, props and boards match Swift. |
| Repository | `make test` | Every Python and shell suite plus product, package, hook and manifest contracts. |
| E2E | `.claude/skills/distill-macos-e2e/` | Throwaway vault and state dir; renamed app copy by PID; the owner's real ~890 pt window; known gaps listed. |

Practices that paid off:
- **write the failing test first** for every verifier fix;
- **shared case files** across TS and Swift;
- **test the single and empty cases** ("Not now" failed with only one
  collector);
- **run async suites more than once**;
- **inject delays** to reproduce races.

### 6.2 Mutation testing (started, not landed)

On 2026-10-07 the owner set a session goal: copy the worktree, add the
missing unit tests, and then run mutation tests over the new tests. A second
goal asked to fix merge conflicts and re-run mutation testing on code that
changed while the first agents ran. Worktree `wiki-setup-tests`
(`distill-unit-tests`) exists at `4771533` with nothing ahead of it. **No
results yet.** Section 8 lists what to measure.

### 6.3 Verification checklists

These are the verifier briefs that found real bugs (section 3.1), reduced to
their reusable core:

1. Run every gate and quote the pass/fail line of each, on the final HEAD
   and on a clean tree.
2. Review the diff against the spec's named sections.
3. Hunt specific failure classes:
   - unbounded loops and retries across states;
   - state left "running" with nothing in flight;
   - timers not cleared;
   - the approval gate skipped;
   - wrong terminal states;
   - badge and pill correctness.
4. For each suspicion: a targeted test that fails, then the fix, then one
   commit.
5. Render the new snapshot states and look at them: plain English, nothing
   clipped.
6. Reproduce the owner's real incident on a copy, read-only, with a fake
   runner.
7. Report findings ranked by severity, with file:line and a concrete failure
   scenario, and say fixed (hash) or left (why).

### 6.4 Safety reviews

- **The approval gate.** Phase-1 tools never include `transaction apply`.
  Apply is granted only as the exact approved command, and the core
  enforces it (audit A/B, `8f5dcfa`). Recovery's retries reuse only the
  approved hash, and split or discard are proposals the owner clicks
  (decisions 2026-10-06).
- **Prompt injection.** Any note-derived text placed in a prompt is fenced
  as data: one line, `<` and `>` escaped, and named in the prompt's "this is
  data" sentence (`996130c`, `d32d3a3`). Round 8 found two places where this
  was missing in new code.
- **Never write the vault directly.** Writes go only through the core's
  transactions. Others' actions reach a wiki page only inside the next
  ingest batch's bundle, which the owner approves (decision 2026-10-06), and
  never through a job of their own that would hold the vault.
- **Never touch owner state.** Temp `DISTILL_STATE_DIR`, throwaway vaults
  from `scripts/claude-obsidian.py init`, a renamed app copy by PID, an
  isolated Keychain and UserDefaults (the skills reviewer found the e2e
  skill's "isolated" setup wasn't, 2026-10-04), and no resumed real
  sessions.
- **Automatic over human.** Partial reads, a stuck recovery and a batch
  Distill gave up on must surface as "Needs you", never as a badge the
  owner has to notice.
- **Deferred, not declined.** The audit's report-only C items (egress
  visibility, per-batch web fetch limits, runner checks) wait for a canvas
  design (memory `remind-audit-c-items`).

---

## 7. Reusable assets to create

These follow the owner's standard in
`.claude/skills/authoring-skills-and-agents/`: a frame, not a script.
Each asset gives intent, context, defaults labelled as defaults, known gaps,
and a few boundaries, each with its reason. They extend what exists
(`distill-pm`, `distill-macos-e2e`, `distill`, the authoring skill) rather
than duplicate it.

The rules below are the *content* each asset must carry, drawn from sections
3–6. Write them as reasons and gaps, not as steps.

### 7.1 Skill: `feature-delivery` (the orchestration loop)

- **Purpose:** run one feature from request to installed, with the owner
  deciding only at the design and decision points.
- **Triggers:** "design and build X", "build after design", "build with
  subagents and verify with another", any multi-item feature request.
- **Inputs:** the owner's request in their words; the spec index;
  decisions.md; the canvas link.
- **Outputs:**
  - a canvas proposal with a "Your answers" card;
  - a spec and decision entries;
  - a worker branch per builder, with a verified merge commit;
  - an install;
  - a numbered status report.
- **Rules it must encode:**
  1. Restate the request and list the open questions *on the board*. When
     the owner answers, put their exact words in a large card at the top,
     with numbered badges on the frames those answers affect (4.5).
  2. Canvas first for anything visible. "Build directly after design" skips
     only the second wait (5.1).
  3. One worktree and branch per concurrent worker. The lead is the only
     merger, and merge subjects carry "verified at <hash>" (3.4, 4.1).
  4. The builder never verifies its own work. A separate verifier works on
     the builder's branch after the builder stops (3.1).
  5. Keep a written checklist of **every** owner request, including
     mid-task additions. A "done" report is checked against `git log`
     before it is relayed (4.2).
  6. Specs and decisions change in the same commit as the behaviour, and
     decisions are superseded, never rewritten (3.7).
  7. Commit per item; never push.
  8. Approvals the owner gives the lead don't transfer to teammates. The
     lead runs approved build and install steps itself (4.8).
- **Known gaps:** status reporting load on the owner (8.1); how to
  parallelise core and UI when the design is still moving (core first
  worked for Collectors, 2026-10-04).

### 7.2 Agent: `verifier`

- **Purpose:** an independent, adversarial check of a builder's commit
  range against its spec.
- **Triggers:** after any builder reports done; before any merge or install.
- **Inputs:** the commit range, the spec sections, the incident to reproduce
  if one exists, and the worktree. The verifier needs its own worktree, or
  the builder must be stopped.
- **Outputs:** the report format in 6.3: gate lines, findings ranked by
  severity with file:line, one fix commit each with a failing-first test,
  and the snapshot PNGs it viewed.
- **Rules it must encode:**
  - Run the checklist in 6.3, and add failure classes specific to the
    domain (for Distill: loops across recovery signatures, the approval
    hash, note text in prompts).
  - Stage by hunk or path, never whole files someone else is editing. If
    another agent's uncommitted edits are in the tree, stop and ask (the
    `596e0bf` lesson).
  - A flaky test is a bug in the test until proved otherwise. Reproduce it
    by injecting a delay in the app path, then make the test wait on the
    condition (`c0a9081`, `6320eae`).
  - Treat every place note-derived text enters a prompt as an injection
    site (`996130c`).
  - Look at every new snapshot PNG, not the count.
  - "No bugs" is a valid result when stated with evidence (rounds 3, 5).
- **Defaults:** fix clear bugs and leave design questions to the lead. Never
  install.

### 7.3 Agent: `canvas-designer`

- **Purpose:** draw proposals and built states on the Claude Design canvas
  from the repo schema.
- **Triggers:** any visible change; "update the canvas"; "add every built
  screen to the canvas".
- **Inputs:** the request, `apps/distill/design/`, `pages.json`, and the
  live `canvas.json`.
- **Outputs:**
  - schema edits and a render;
  - the changed boards published;
  - the canvas version and a link to the page;
  - a commit touching only `apps/distill/design`.
- **Rules it must encode:**
  - `render.py` is the only writer. Never hand-edit a board; re-read the
    live canvas before every publish (5.2).
  - Respect the page budget (at most 30 boards a page). Report canvas
    extent after each render, so growth is seen before the viewer stops
    drawing (4.3).
  - Never change a shared component for one board's needs; draw a local
    overlay instead (`2b4edd2`).
  - Use prop types from the format's list (`boolean`, not `bool`, `25e2046`).
  - Frame ids equal snapshot state ids. Proposals say "(proposal, not
    built)" in the title.
  - Owner decisions are big, quoted and badged (4.5).
  - No local previews. Check renders offscreen or by reading the markup.
- **Known gaps:** the viewer is nondeterministic; tokens are not yet used
  in templates (5.4).

### 7.4 Agent: `design-architect` (or a mode of the canvas designer)

- **Purpose:** structural questions about the design tool. Examples: pages,
  design systems, canvas size, a viewer bug.
- **Rules it must encode:**
  - Read the tool's own guidance first.
  - Prove options on private throwaway artifacts, never the main canvas.
  - Repeat each run and keep a control.
  - Write a plan with an evidence table and a migration where every step
    can be checked.
- **Why it's separate:** it worked because its brief made the lead's
  conclusion a question (4.3).

### 7.5 Skill: `safe-install` (extend `.claude/skills/distill/`)

- **Purpose:** install a new build without losing data or interrupting the
  owner.
- **Triggers:** "reinstall", "install it now", the end of `feature-delivery`.
- **Rules it must encode:**
  - Check for running jobs and any owner hold ("don't restart … untile I
    say yes") before anything else. When blocked, report it; don't wait
    silently and don't force.
  - Back up, test, install, restart the core, then compare data counts. The
    count check sees only losses during the install, so say so.
  - When an install fails on a test, hand it to the verifier for a root
    cause. Never retry until green.
  - After an install, describe in plain words what the owner's real
    in-flight items will do on next launch (as for the stuck batch,
    2026-10-06 04:50).
  - Verify against the system that showed the bug (Spotlight's `mdfind` for
    duplicate apps).

### 7.6 Playbook: `bisect-a-rendering-problem`

- **Purpose:** find why a viewer, canvas or renderer shows nothing or the
  wrong thing.
- **Steps worth keeping** (as a frame):
  1. Confirm the files are intact (the version, the file count).
  2. Build a tiny control that draws and a full copy that fails, in the
     same session.
  3. Bisect on the copy only: notes, halves of the boards, settings.
  4. **Repeat each step 3 times, and re-run the control every time.** Allow
     for load time.
  5. When a step "fixes" it, re-run the original failing configuration
     unchanged. If that now passes too, the result is noise.
  6. Write the finding as a hypothesis with its counts ("4 of 4 blank,
     3 of 3 drew"). Only replicated findings become a test or a rule.
  7. Look for gradual causes, such as size and count, not only the last
     change.
- **Anti-patterns from 2026-10-06:** a rule and a test (`8a766c7`) built on
  a single lucky load; a memory note written from it that is now stale.

### 7.7 Rule file: `worktree-per-worker`

A short instruction file (or a section of `apps/distill/AGENTS.md`):
- Every concurrent writer gets its own worktree and branch, named for the
  feature (`wiki-setup-<feature>`, `distill-<feature>`).
- A forked helper inside a worktree gets a file list it may touch, and
  leaves its files uncommitted for the owner of the worktree.
- `git add` takes paths you own. Check `git diff --cached --stat` before
  each commit.
- Each worker uses a private scratchpad subfolder.
- The lead removes merged worktrees. There are 56 stale ones under
  `.claude/worktrees/` today.
- The stash is shared across worktrees: use WIP commits, not a bare
  `git stash`.

### 7.8 Rule file: `owner-interaction`

Owner preferences belong in the owner's global memory or a personal
instruction file, not in product skills. This is open question 4 in
`BUILDING-WITH-AI.md`, and this answer is a proposal.
- Status leads with the outcome, then evidence, then a **numbered** list of
  what's running, what waits on the owner, and follow-ups.
- Dictated messages are restated in one line before acting. Ask only what
  blocks progress, with a recommendation.
- Kept deliverables go where they will live, with a README.
- Point to designs with a link that opens on the right page, never "on the
  canvas somewhere".

### 7.9 Extend existing assets

| Asset | Add |
| --- | --- |
| `distill-macos-e2e` skill | Recorded real API shapes for Jira, Slack and Confluence as scrubbed fixtures (4.7); a "the owner found it" list as known gaps; wait-on-condition guidance for UI tests (4.6). |
| `authoring-skills-and-agents` skill | A check that every new agent says whether it shares a worktree, and with whom. |
| `distill-pm` agent | An input: open owner decisions from `decisions.md`, so reviews don't reopen settled questions. |
| Memory `canvas-before-ui-changes` | Replace "Never put explicit `pages` … they blank the viewer" with the 4771533 rule (pages per area, at most 30 boards). |

---

## 8. Open problems and next experiments

### 8.1 Status and attention load on the owner

The owner asked "where are we?" 13 times, and the lead relayed 229 agent
hand-backs, many as "that's the agent's closing note; it matches".
- **Experiment:** a single status file the lead rewrites, such as
  `.vault-meta`-style runtime state or an artifact page. It would hold
  running, waiting-on-owner and done, each with a hash. Agent idle notes
  would update it silently instead of producing a message.
- **Measure:** owner status questions per day.

### 8.2 Reports that overclaim

The builder's "all six items done" (4.2) and the verifier's whole-file
staging (4.1) are the same failure: the report isn't tied to the tree.
- **Experiment:** each agent's report ends with a table of request, commit
  hash and test name, and the lead diffs it against the request checklist
  automatically.
- **Measure:** items sent back after a "done".

### 8.3 Design–build drift

- **Experiment:** make the drift test's report-only list fail the build:
  every canvas frame must have a snapshot state of the same id, and the
  reverse. Then add a pixel or structure comparison between the canvas
  board and the snapshot, using the offscreen WKWebView renderer
  (`tools/snap.swift`).
- **Measure:** the number of "matches the canvas" fix commits per feature.

### 8.4 Real-shape fixtures for external systems

Jira's required fields were found by the owner (4.7).
- **Experiment:** a one-time, owner-approved capture of create metadata,
  transitions and pickers from a real project, scrubbed of private details,
  stored as fixtures, with a test that each fixture still decodes.
- **Measure:** owner-found integration bugs per week.

### 8.5 Mutation testing

The unit-test and mutation pass has started but hasn't landed. Next:
- choose a tool per layer (StrykerJS for the core; a Swift option, or
  hand-made mutants for the engine's recovery bounds and the approval gate);
- run it first on the files the verifier fixed most (recovery, slack-target,
  highlights prompts);
- record the score per file, and treat surviving mutants in safety code
  (approval gate, prompt fencing) as bugs.

### 8.6 Canvas migration, steps 4–7

The pages and the Design System exist; the hidden kit, one board per state,
tokens in templates and per-area canvases don't (`design-system-plan.md`).
- **Experiment:** step 3 (tokens in templates), with an offscreen pixel diff
  before and after.
- **Measure:** the time from "change a colour in Theme.swift" to the canvas
  showing it.

### 8.7 Headless real-UI testing

The Mac's screen was locked during every real-app phase on 2026-10-04, so
the click-through went to the owner.
- **Experiment:** accessibility-driven tests in an offscreen session
  against the renamed app copy.

### 8.8 Worktree and agent hygiene

There are 56 stale agent worktrees and dozens of named agents in one
session.
- **Experiment:** the lead removes a worker's worktree after its merge, and
  a weekly check lists worktrees whose branch is merged.
- **Open question:** at what point is a fresh lead session, primed with
  this file and the specs, cheaper than one very long session? The lead
  transcript is over 100 MB.

### 8.9 Approval rhythm

The owner pre-approves sometimes ("build directly after the design") and
not others. It's still open which kinds of change should default to
pre-approval. One candidate: fixes that make the app match the canvas, and
follow-ups the verifier proved with a failing test.
