---
type: spec
title: Whose items Distill handles, Pending and Highlights
status: built
created: 2026-10-06
updated: 2026-10-07
tags:
  - distill
  - actions
---

# Whose items Distill handles, Pending and Highlights

Canvas: board `ActionsRouting.dc.html` on https://claude.ai/artifact/7PAQ8AKofpY9yPvakwvUMB
(`apps/distill/design/screens/routing.json`): `settings-actions-people`, `routing-card-rule`,
`actions-confirm-routed`, `actions-pending-list`, `actions-pending-detail`,
`actions-highlights-list`, `actions-highlights-note`. Builds on [Actions](actions.md) and
[Action context](action-context.md).

## The ask

Most action items in meeting notes belong to other people. Before this, every one of them
landed in the owner's Actions lists. Now an item goes to your lists only when its owner is
someone you handle that type for. What others owe you goes to Pending, and everyone else's
goes to the note's Highlights.

## People (Settings → Actions → Whose items Distill handles)

- `actionPreferences.people`: `[{id, name, aliases}]`. The user's entry has id `you` and is
  always listed first. Others get a stable id (`p-xxxxxxxx`).
- `actionPreferences.types.<type>.handlesFor`: the People ids whose items of that type go to
  your lists. When absent it is `["you"]`.
- The page shows:
  - People: a name, then "The notes call them" alias chips with × and ＋, and Remove. The
    alias field opens focused; Return or clicking away adds a typed name, Esc closes it.
  - "＋ Add a person". The new row stays on the page, focused, until it has a name, and is
    saved to Settings only then (the core drops a person with an empty name). Adding again
    while it is unnamed keeps that row, so a name typed in it is not lost.
  - Each type's "Handles items for" chips with × and a ＋ menu (named people not there yet,
    then "Add a person…"), plus a plain line under them, such as "Your to-dos, and the ones
    you do for Aditya." With nobody left to add, ＋ adds a person instead of a menu. A person added from a type's ＋
    handles that type from their first name, in the same save.
  - A preview line: "In the last 7 days this would have sent N to your lists, N to Pending and
    N to Highlights." It comes from `POST /v1/actions/routing-preview` with the People being
    edited. It counts items found from notes in those days while routing was on; items found
    before have no owner and are not counted, and the line says so ("15 items found before
    routing aren't counted: they have no owner.", `beforeRouting`).
- Routing is on only once the user has a name or an alias. Until then every found item goes to
  your lists as before, the find prompt is unchanged, and the page says so.

## Routing at finding time (core `actions/routing.ts`)

The find step (batch windows; Ask finds are not routed) records for each item:

- `owner`: who has to do it, as the note writes it, or `me` for the user.
- `owedTo`: for a promise, who it is for.
- `what`: the thing promised, such as "the ticket links".
- `due`.

The instruction is added after the user-editable find prompt, so an edited prompt never
drops it. It names the user's name and aliases.

The core matches each name to People. The match is exact: the whole name, trimmed and
case-insensitive, on a name or an alias. `me`, `I` and `the user` mean you. A name that fits
two people counts as unclear.

The rules are checked in order:

1. No owner, or an ambiguous one: the item goes to your lists, To confirm, with
   `ownerUnclear`. The row asks "Whose is this?" (You · Someone… · Not mine). This holds even
   when confirm is off.
2. Owed to you by someone else: Pending (`route: "waiting"`), whoever it is, including people
   not in People.
3. The owner is one of the type's `handlesFor`: your lists. The row reads "for Aditya" when the
   owner isn't you.
4. Anything else: the note's Highlights, under Others' actions (`route: "others"`).

`route` absent means your lists, so items found before routing stay where they are. Only new
finds route.

Pending and Highlights items:

- are never To confirm and never drafted;
- are left out of a batch's "Found N actions" count (`JobActionsSummary.waiting` / `others`
  count them apart);
- are left out of `GET /v1/actions` unless `?route=waiting|others|all` is passed.

History lists every route.

To confirm shows "6 items for other people went to Highlights · 2 to Pending · Show". It
counts the items from the same batches as the items waiting there.

## Pending

Actions → Pending, a sidebar sub-item with its count.

- The list:
  - Grouped by person or by date (Group by Person | Date).
  - Each row: "from Aditya Pradhan · promised in <note> · by Fri", with a date pill or a peach
    Overdue pill.
- The detail:
  - Who it's waiting on and by when.
  - WHAT YOU'RE WAITING FOR.
  - A full FROM THE ORIGINAL header (Open original, Show in Finder, the lines), Why, and Found by.
  - Not waiting anymore · Nudge · Mark received.
- Mark received: status `done`, with event `received`. It is restorable.
- Not waiting anymore: status `removed`, with event `not-waiting`. It goes to History.
- Nudge opens an "Add as Slack message" panel:
  - To: the person, with their `@handle` from People when there is one.
  - Text: prefilled "Hi Aditya, any update on the ticket links?".
  - The panel adds a ready Slack message with `fromActionID` set to the pending item.
  - The pending item gets a `nudged` event and stays open.
- A later batch gets the open Pending promises in its find prompt (up to 30), fenced as data in
  a `<pending>` block, one line each, with `<` and `>` escaped. When its lines
  look like delivery, the item gets `received: {notePath, pageTitle, quote}` once that page
  applies. The row then reads "Looks received in 2026-10-06 Standup. Mark received?".
  - It is only a suggestion. Nothing closes on its own.

### Track as Pending from To confirm and To do (2026-10-07, built)

Owner request: an item in To confirm, or a to-do already added, that someone else will do goes to
Pending instead. Canvas: board "Actions · Track as Pending" (`ActionsTrackPending.dc.html`, page
4 Actions; `design/screens/trackpending.json`), frames A–G plus the Keyboard and What changes
cards. The owner's answers to the board's questions are in [Decisions](decisions.md) (2026-10-07).

- To confirm (any found type): Add as… gets a divider and "Track as Pending…" ("Someone else will
  do it; you wait", ⇧⌥↩) after the types; the keys line adds "⇧⌥Return tracks as Pending…". The
  row's context menu reads Add as ▸, Track as Pending… (⇧⌥↩), Dismiss (⌫).
- An added to-do (open): "Move to Pending…" at the end of Send to, after a divider; Send to's last
  line then reads "A type makes it a draft you check first; Move to Pending makes it something you
  wait for." Slack messages, Jira tickets and Confluence pages you added don't get it.
- The panel (in the detail, where Add as's panel goes; What it's about and What Add does are hidden
  while it is open):
  - Waiting on: a People picker filled with the item's owner when it isn't you ("Aditya Pradhan
    @aditya · the item's owner"); for a to-do, its person when People knows them. Open, it lists
    IN THIS NOTE (whose items, who they're for and who a message goes to in the item's note,
    People order first; never you), then PEOPLE (everyone else), and "Or type any name; someone
    not in People is kept as written." Typing keeps its spaces (`DraftTextField`).
  - By: optional, filled from the due date (the to-do's, else the promise's); × clears it. With no
    date the Pending row has no "by" and never turns Overdue.
  - "Filled from its owner and due date. It leaves To confirm; nothing is sent to Aditya." (To
    confirm, once someone is filled in), and "IN PENDING IT WILL READ" with the row as Pending
    shows it ("from Aditya Pradhan · promised in Testing sync · by Fri", the same words).
  - Footer: Cancel · Track as Pending (To confirm), or Cancel · Move to Pending on the right (a
    to-do). ⌘Return tracks; Esc cancels.
- When the owner is you, the panel reads "the owner is you", a peach note quotes the note's line
  ("The note says you would do this (“me: migrate all existing tests”), so there is no one to fill
  in. Pick who you are waiting on."), the Waiting on list opens, and the button is off with "Fill in
  who you're waiting on". Picking you is refused ("Pick someone other than you").
- Keys: ⇧⌥Return opens the panel for the selected To confirm row (list or detail) or the selected
  to-do; Return and ⌥Return are unchanged; none fire inside a text field.
- After: the item leaves its list, the next To confirm row is selected, Pending's count goes up,
  and the toast reads "Tracked as Pending · waiting on Aditya · Undo". Undo puts it back where it
  was (To confirm or the to-do list), with the same status and fields, and selects it.
- Core: `POST /v1/actions/:id/track-pending {waitingOn, by?}` (`trackAsPending(id, req?)`).
  - `waitingOn` is a People id, else a name matched on People names and aliases, else kept as
    written; `by` is YYYY-MM-DD or null.
  - The item keeps its id, note, line, Why and labels. It gets route `waiting`, status `open`,
    owner and ownerID = the person, owedTo you, `due` = by, and loses "owner unclear". Where it was
    (route, status, owner, owedTo and due) is kept in `trackedFrom` for Undo.
  - Event `pending` "waiting on Aditya Pradhan (found as to-do)", or "(moved from To do)".
  - Activity (`action.routed`): "Tracked “…” as Pending · waiting on Aditya Pradhan (found as
    to-do)", with details from (to confirm | to do), the type, the People id (or "named") and by.
  - Undo is `restoreAction`: while `pending` is still the item's last event, it puts the route,
    status and fields back (event `restored` "from Pending"); after a Nudge or a receive it is
    refused ("It has changed in Pending since; it stays there."). An item tracked and undone can
    still be dismissed.
  - Refused: an empty Waiting on ("Fill in who you’re waiting on.", `missing: ["Waiting on"]`),
    you, a By that isn't YYYY-MM-DD, an item already in Pending, one done, removed, dismissed or
    sent, an added item that isn't a to-do, and a busy one.
  - Highlights' Track as Pending (an Others' action) still sends no body and works as before.
- Code: core `actions/index.ts trackAsPending`, `restoreAction`; `server/http.ts`;
  `activity/instrument.ts`. Mac: `DistillKit/TrackPending.swift` (prefill, choices, words,
  `CoreClient.trackAsPending(_:waitingOn:by:)`), `TrackPendingViews.swift` (panel, Waiting on,
  footer), `AddAsViews.swift` (menu row, keys), `ActionPreview.swift` (row menu, detail),
  `ActionsScreen.swift` (Send to, the to-do detail, list keys). Tests: `actions.test.ts` ("Track
  as Pending from To confirm…", "Move to Pending…"), `http-actions.test.ts`, `activity.test.ts`,
  `TrackPendingTests`, `TrackPendingAppTests`. Snapshot states `tp-menu`, `tp-panel`,
  `tp-rowmenu` (the context menu drawn as the board draws it; a native menu isn't captured),
  `tp-after`, `tp-mine`, `tp-list-sendto`, `tp-list-panel`.
- Not built: the CLI has no command for it (the CLI has no confirm command by design). Activity
  is append-only, so Undo adds a "Restored" entry instead of removing the "Tracked" one.

## Highlights

Actions → Highlights: one card per note with routed items, newest first, filtered by All
notes | Meetings.

- The card shows:
  - The note's people (you first).
  - Up to three key points from the wiki page.
  - "Others' actions 5 · Decisions 2 · Your items: 3 in your lists, 2 Pending".
- The note pane shows:
  - From the wiki page: Open page, Sources › title, the summary, KEY POINTS and DECISIONS, each
    with its line.
  - OTHERS' ACTIONS by person. Track as Pending and It's mine appear once per person and act on all
    of that person's items in the note; each line's … menu holds the same two choices for that one item.
  - People (in Pending's By person, and in Others' actions) are listed People-list entries first, in
    list order, then others in the order the notes first name them.
  - YOUR ITEMS, linking to your lists and Pending.
  - Copy as summary and Open note.
- The summary, key points and decisions are read from the note's wiki source page
  (`highlights.ts pageFacts`). Distill never extracts them.
  - The summary is a Summary/TL;DR/Overview section, else the first paragraph.
  - Key points come from a "Key points/Key takeaways/Highlights" section.
  - Decisions come from a "Decisions" section.
  - `type/kind/source_type: meeting`, `date` and `duration` come from the page's frontmatter.
  - A page without those sections shows them empty.
- Track as Pending moves the item to Pending, owed to you.
- It's mine moves it to its type's list as yours (`claimed` event).

### Others' actions in the wiki

- Each source page with Others' actions should hold a `## Others' actions` section, one line per
  item: `- **Vladan Dimitrijevic**: Benchmark the Redis cache on staging (by 2026-10-07)`.
- Distill never writes it.
  - When an ingest batch starts, the core compares each such page's section with what it
    should say. Up to 10 pages that differ go into that batch's first prompt, with the exact
    text and "change nothing else on these pages" (`othersActionsPrompt`, `RereadFacts.othersActions`).
  - The lines come from notes, so the prompt fences each page's text in a `<page>` block marked
    as data to copy exactly. A line is one line with `<` and `>` written as `&lt;` and `&gt;`, so
    no note text can open or close a block.
  - The section's text replaces the old section in place (or goes at the end), with one blank line
    between it and the rest; a section on the page's first line stays the first line.
  - The section reaches the page only in that batch's bundle, which the user approves in Review.
- Nothing is tracked per item:
  - A batch that skipped a page, got it wrong or was rejected leaves it due for the next batch.
  - It's mine or Track as Pending removes the line the same way. An empty list removes the
    section.
- The pane says "added to the wiki page in the next batch" until the page holds the line, then
  "on the wiki page".

## API

| Route | Method |
|---|---|
| `GET /v1/actions?route=list\|waiting\|others\|all` | `listActions` (default `list`) |
| `POST /v1/actions/:id/owner {owner: "you" \| id \| name \| null}` | `assignActionOwner` (Whose is this?; null = Not mine) |
| `POST /v1/actions/:id/track-pending {waitingOn?, by?}` | `trackAsPending` (no body: Highlights; To confirm and To do send `waitingOn`) |
| `POST /v1/actions/:id/claim` | `claimAction` (It's mine) |
| `POST /v1/actions/:id/received` | `markReceived` |
| `POST /v1/actions/:id/stop-waiting` | `stopWaiting` |
| `POST /v1/actions/:id/nudge {to, text}` | `nudgeAction` → `{item, message}` |
| `POST /v1/actions/routing-preview {people?, types?}` | `routingPreview` |
| `GET /v1/highlights`, `GET /v1/highlights/note?path=` | `listHighlights`, `getHighlight` |

## Activity

- Each batch gets one `action.routed` entry, from the `actions.routed` event, for example
  "Sorted the actions found in job-…: 3 to your lists, 1 to ask whose, 2 to Pending, 6 to
  Highlights".
- Whose is this and Track as Pending log `action.routed` (from To confirm or To do: "Tracked “…” as
  Pending · waiting on Aditya Pradhan (found as to-do)"). It's mine logs `action.claimed`.
- Mark received logs `action.received`, and Not waiting anymore logs `action.not_waiting`.
- Nudge logs `action.nudged` with who it goes to, never the text.
- People changes read "Whose items Distill handles: changed". Names and aliases are not logged.

## Not built

- `routing-card-rule` and `card-answers` are explanation cards on the board, not app screens,
  so they have no snapshot.
- Ask finds are not routed. They stay yours, as before.
- "Someone…" picks from People only. Typing a new name there is not built; add the person in
  Settings first.
