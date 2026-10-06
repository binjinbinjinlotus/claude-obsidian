---
type: spec
title: Action summary (what a found action is about)
status: designed
created: 2026-10-05
updated: 2026-10-05
tags:
  - distill
  - actions
---

# Action summary: know what a found action is about before you act

Canvas: row 14, board `ActionSummary.dc.html`
(`apps/distill/design/screens/actionsummary.json`). Builds on
[Action context](action-context.md), which gave every item its original's
lines and wiki sections.

## The ask

The owner wrote:

> "for the all item in the actions, let ensure it including a title and a
> summary of what it is about. eg. for todo, I should able to click on the item
> to confirm, then it will show the full summary of what about, then I can
> thinking about what action to perform. same for the jira, slack, confluence.
> The current issue is, I have no idea about what it is about, where's coming
> from until I add it to the todo, create a slack msg, or create a draft jira
> etc..."

## What was wrong

- A To confirm row shows a title and "To-do · **✍ Quick notes**".
  - Nothing says what the action is about.
  - The source name leaks its Markdown: `pageTitle` is the page's first
    `# heading` or `title:` as written (`titleOfPage`, `core/src/actions/context.ts`).
- The context is there, but it sits behind a chevron that expands the row in
  place (`ActionConfirmRow`).
- The right pane only shows open or done to-dos. `TodoScreen.selectedItem` (`ActionsScreen.swift`)
  rejects `pending`, and the pane is hidden when there are no open to-dos.
  - With 12 to confirm and no open to-dos, there is no pane at all.
- The FROM card reads "Found by by Sonnet". The `found` event's detail is
  stored as `by Sonnet` (`buildItem`). The card then prefixes it again with
  "Found by" (`ActionContextBlock.foundLine`, `ActionsParts.swift`).

## 1. A summary on every found action

`ActionItem.summary?: string | null` is a new, additive top-level field.

**What it is.** Two to four plain sentences that say:

- what the action is about;
- the context needed to act;
- who is involved;
- what was asked or decided, and by when.

It contains no Markdown. It invents no names, dates or details.

**What it is not:**

- It is not `body`. Body is the to-do's note or the draft written later.
- It is not `why`, which stays one sentence.
- It is not the quote.

The board's "What a summary is" card has a good example and a bad one.

**When it is written.** It is written at finding time by the same structured
run that finds the item. That run sees the original's lines (in windows) and
the source's new wiki page. It costs no extra call.

- **Notes:** the batch pass (`index.ts` around line 973).
- **Ask:** `detectAsk` (around line 1470).

**Prompt.** The instruction is not added to `DEFAULT_FIND_PROMPT`. It goes in
the part `buildFindPrompt` always appends, so a user-edited `findPrompt`
still asks for it:

```
For each action, also return summary: 2–4 plain sentences (no Markdown) on what it is
about, the context needed to act, who is involved, and what was asked or decided and by
when, from the documents only. Write it for someone who hasn't read them.
```

**Schema.** `FIND_SCHEMA.items[].summary: {type: string}` is optional. It is
not in `required`, so an old prompt or a model that omits it still parses.

**Parsing.**

- `parseFound` trims it and strips Markdown with the same helper used for
  titles (section 4).
- It caps the summary at 800 characters.
- Empty becomes `null`.

**Where it is carried.**

- `buildItem` sets it. That covers both the note and the Ask paths.
- `sendActionTo` copies it to the new item.
- `createAction` (manual and agent items) leaves it `null`.
- `ActionPatch` does not include it. The summary describes the source, so it
  is not something to edit.

**Older items: a backfill on first open.**

- When an item without a summary is selected and rests for 600 ms, the app
  calls `POST /v1/actions/:id/summarize`.
- It is written from `draftContextFor(item)`. That is the stored
  `raw.excerpt` or the original's lines ±25, the wiki sections, and for items
  without `raw`, the note around the quote.
- It uses the find model (`findSelection`, task `actionFind`), so there is no
  new `AITask` and no new setting.
- Arrowing through rows starts nothing until a row rests.
- Meanwhile the pane shows "Summarizing…" with Why and the original's lines
  already filled (state C). The row shows Why in place of the summary line.
- If summarizing fails, the pane says "Couldn't summarize · Try again" and
  keeps Why and the quote. The row stays usable.
- Manual items have nothing to summarize. Their pane shows the body; no
  Summarizing state.

## 2. Click a To confirm row: the right pane

On To do and on the Slack, Jira and Confluence screens, a click on a To
confirm row selects it, and the right pane shows `ConfirmDetail`.
`ConfirmDetail` is a new view; `TodoDetail` stays for open and done to-dos.
From top to bottom it shows:

1. **Header.**
   - "To confirm" pill;
   - type tile and target ("Jira ticket · PAY · Task", "To-do · due Wed",
     "Slack message · to Mei");
   - position ("2 of 12") and ↑/↓ buttons.
2. **The title**, at 18 pt.
3. **What it's about:** the summary in full, or Summarizing… (section 1).
4. **FROM**, the existing `ActionContextSections` content in a card:
   - the clean source name, the date and its kind (meeting transcript, quick
     note, Ask chat);
   - **Open original lines 210–212**, which opens the archived original at
     those lines;
   - **Open wiki section**, which opens the wiki page at the heading;
   - the wiki section's name;
   - the original's lines, with the quoted lines highlighted;
   - Why;
   - "Found by Sonnet · Sep 30 at 4:12 PM".
5. **Already filled** fields, and "Not set yet".
6. **What Add does** (to-do) or **What Create draft will write** (Slack, Jira
   and Confluence). This reuses `ActionContextText.willWrite`. For a to-do,
   Add puts the summary into the to-do's note when the body is empty
   (section 5).
7. **Footer:** Dismiss on the left; Add to To do or Create draft on the right,
   with a "↩ adds" hint.

A To-do screen's To confirm group lists pending items of every type, so the
pane there shows Jira, Slack and Confluence items too.

After Add, Create draft or Dismiss, the selection moves to the next To confirm
row. After the last one, it moves to the first open to-do.

**Keyboard.** These keys work while the list has focus (a row was clicked, or
Tab moved into it):

| Key | What it does |
| --- | --- |
| ↑ / ↓ | move between rows; the pane follows |
| Return | Add or Create draft |
| Delete | Dismiss |
| ⌘Return | Add, even while a text field has focus |

Return never fires inside the title editor, Add to-do or search.

**The chevron goes** on To do and the type screens. The pane replaces the
inline preview, and two ways to see the same thing is one too many.

The row keeps its inline expand where there is no right pane:

- Review's "Actions found" (`ReviewActionsFound`);
- Ask's "found in this answer".

## 3. Rows

```
[tile] Cap payment client retries at 3 with exponential backoff from 500 ms   (one line)
       The payment client retried failed calls every 200 ms with no limit, …  (one line of the summary)
       Jira ticket · PAY · Task · Tomasz and Jin · Sep 30
```

- **The meta line** shows the type and target, the clean source name and the
  date found. "lines 210–214" moves to the pane.
- **Without a summary**, the second line shows "Why: …" in italics. With
  neither, there is no second line.
- **The buttons leave the row** on screens with a pane. Add and Dismiss sit
  in the pane's footer, and "Add all" and "Dismiss all" stay on the group.
  - Owner decision 3 below covers this.
  - Ask and Review keep the row buttons.
- **On Ask, a click on the row** (anywhere but the buttons) opens it in place
  with the summary in full, where it came from and what Create draft writes.
  - Editing the title moves to a pencil button. Today a click on the title
    edits it.

## 4. Fixes

**Source names lose their Markdown.** A new `plainTitle(s)` helper strips:

- `**`, `__`, `*` and `_` emphasis;
- backticks;
- a leading `#`;
- `[[link|alias]]` (keeping the alias, else the link);
- `[text](url)`, keeping the text.

It then collapses spaces. Emoji stay.

- **Core:** apply it in `titleOfPage` and wherever `pageTitle` is set.
- **App:** apply it again in `ActionContextText.sourceName` (DistillKit), so
  items stored before the fix show clean.

**"Found by by".** The stored detail is already "by Sonnet". In
`ActionContextBlock.foundLine`, show "Found \(detail)" when the detail starts
with "by ", else "Found by \(detail)". Stored data is not rewritten.

## 5. Decisions for the owner (recommended defaults)

1. **Backfill older items automatically on first open**, after the selection
   rests for 600 ms. The alternative is a "Summarize" button.
   - "Summarize all" on the group runs them one at a time.
2. **The summary isn't editable**, and Improve doesn't touch it.
3. **Add and Dismiss leave the row on screens with a pane.** They sit in the
   pane's footer, and "Add all" and "Dismiss all" stay. The alternative keeps
   the row buttons as today. That is busier, but you can act without
   selecting.
4. **Plain Return adds while the list has focus.** The alternative is ⌘Return
   only.
5. **Ask: a row click opens the row; the pencil edits the title.**
6. **Keep emoji in source names** ("✍ Quick notes").
7. **A to-do added from a found item takes the summary as its note** when it
   has no body, so the To do pane still says what it is about.

## 6. Build plan

**Core (`apps/distill/core`)**

1. In `contracts.ts`, add `summary?: string | null` to `ActionItem`.
2. In `actions/ai.ts`, add `summary: {type: 'string'}` to `FIND_SCHEMA`
   item properties (not required).
3. In `actions/prompts.ts`:
   - `buildFindPrompt` appends the summary instruction after the types list,
     with the context block that is always added.
   - Add `buildSummarizePrompt(item, ctx: DraftContext)` and
     `SUMMARIZE_SCHEMA = {summary: string}`.
4. In `actions/index.ts`:
   - Add `Found.summary`.
   - `parseFound` reads, cleans and caps it.
   - `buildItem` sets `summary`.
   - `sendActionTo` copies it.
   - `createAction` sets `summary: null`.
   - Add `summarize(id, signal)`. It builds `draftContextFor(item)` and runs
     `runStructured` with task `actionFind` and the find selection. It writes
     `summary`, adds an event `summarized` with detail `by <model>`, and
     de-duplicates concurrent calls per id the way `draft()` does.
5. Add `plainTitle()` to `actions/context.ts`. Use it in `titleOfPage`, where
   `pageTitle` is set, and on `summary`.
6. Add `summarizeAction(id, {signal})` to the core interface.
7. In `server/http.ts`, add `POST /v1/actions/:id/summarize`, modelled on
   `/draft` with `abortOnClose`.
8. Add `summarizeAction` to `server/fake-core.ts`, and add `summary` to
   `sampleAction()`.
9. Tests:
   - `actions.test.ts`: `parseFound` with and without `summary`; `sendActionTo`
     copies it; summarize on an older item, using the draft context.
   - `context.test.ts`: `plainTitle` cases.
   - `http-actions.test.ts`: the new route.

**CLI.** Optional: `distill actions summarize ID`. Not needed for the owner.

**Mac (`apps/distill/clients/macos`)**

1. **DistillKit.**
   - `Actions.swift`: add `ActionItem.summary: String?` (lossy decode) and add
     it to `init`.
   - `ActionContext.swift`: `ActionContextText.sourceName` runs a Swift
     `plainTitle`. Add `ActionContextText.foundLine(detail:)`.
   - Client: add `summarizeAction(id:)`.
2. **ActionsStore.**
   - Add `summarize(_ id:)`, with in-flight state in `running[id] = "summarize"`
     and failures shown in the pane.
   - Add `selectedPending: String?` per screen, or reuse `selected[type]` and
     allow pending items.
   - Add `selectNext(after:)` for Add, Dismiss and keys.
3. **`ConfirmDetail`**, a new view in `ActionPreview.swift`. It is built from
   these parts:
   - header;
   - title;
   - summary block (Summarizing… and failed states);
   - `ActionContextSections` in a card;
   - `ActionPreview.filled`;
   - `willWrite` (to-do: the "summary becomes the note" sentence);
   - footer.

   A `.task(id: item.id)` sleeps 600 ms, then calls `store.summarize` when
   `summary == nil` and the source isn't manual.
4. **`ActionConfirmRow`.**
   - Add a `mode: .select(isSelected, onSelect)` or `.expand` parameter. In
     `.select` mode: no chevron, no inline `ActionPreview`, no row buttons;
     the selected style is a white fill with the selected stroke.
   - Title at `lineLimit(1)`; a summary line at `lineLimit(1)`, falling back
     to an italic Why.
   - Meta: target, `sourceName` and the date found.
   - Review keeps `.expand`.
5. **`ToConfirmGroup`.**
   - Takes `selected: Binding<String?>`.
   - Makes the list `.focusable()` with `.onKeyPress(.upArrow/.downArrow/.return/.delete)`,
     following the pattern in `MarkdownEditorBar.swift:320`.
   - The `expanded` state is removed for `.select` mode, and the snapshot
     `previewing` state is reworked into a selected id.
6. **`TodoScreen` (`ActionsScreen.swift`).**
   - `selectedItem` accepts `pending` items. A pending one shows
     `ConfirmDetail`, otherwise `TodoDetail`.
   - The pane condition becomes "a selected item exists, or `visible`, or
     `toConfirm` is non-empty". The default selection is the first To confirm
     row, else the first open to-do.
7. **`ActionsTypeScreen.swift`.** The same: `selected` looks in `pending` as
   well as `ordered`. A pending one shows `ConfirmDetail` in the detail
   column.
8. **`AskActions.swift` `AskFoundBlock.row`.**
   - Add the summary line.
   - A row click toggles in-place detail: summary in full, the FROM line with
     Open original lines, and willWrite.
   - The title edit moves to a pencil `IconButton`.
9. **`ActionsParts.swift` `ActionContextBlock.foundLine`**: no more
   "Found by by".
10. **A to-do's note.** When a pending to-do with an empty body is confirmed,
    the core `confirmActions` sets `body = summary`. Do it in the core, not
    the app, so CLI confirms match.
11. **Snapshot states**, matching the canvas ids:
    - `asum-todo-confirm`;
    - `asum-jira-confirm`;
    - `asum-todo-summarizing`.
12. **Checks.**
    - `make test`.
    - Write `Distill --snapshot OUT --states` to a temporary directory and
      compare the three states against the board.

## Contract (additive)

- `ActionItem.summary?: string | null`
- `FIND_SCHEMA.items[].summary` (optional)
- `POST /v1/actions/:id/summarize` → `ActionItem`
- event `summarized` (detail `by <model>`)

Older clients ignore the field. Older items decode with `summary: null`.

## Open risks

- **Cost and latency.** Finding writes a few more output tokens per item. The
  backfill is one small run per opened item.
- **Long summaries.** A model may write long ones. The 800-character cap and
  one-line rows keep the list readable.
- **The original is gone.** A summary from wiki-only context is thinner. The
  pane's FROM card already says "wiki only".
