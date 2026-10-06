---
type: spec
title: Whose items Distill handles, Pending and Highlights
status: built
created: 2026-10-06
updated: 2026-10-06
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
  - People: a name, then "The notes call them" alias chips with × and ＋, and Remove.
  - "＋ Add a person".
  - Each type's "Handles items for" chips with × and a ＋ menu, plus a plain line under them,
    such as "Your to-dos, and the ones you do for Aditya."
  - A preview line: "In the last 7 days this would have sent N to your lists, N to Pending and
    N to Highlights." It comes from `POST /v1/actions/routing-preview` with the People being
    edited.
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
| `POST /v1/actions/:id/track-pending` | `trackAsPending` |
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
- Whose is this and Track as Pending log `action.routed`. It's mine logs `action.claimed`.
- Mark received logs `action.received`, and Not waiting anymore logs `action.not_waiting`.
- Nudge logs `action.nudged` with who it goes to, never the text.
- People changes read "Whose items Distill handles: changed". Names and aliases are not logged.

## Not built

- `routing-card-rule` and `card-answers` are explanation cards on the board, not app screens,
  so they have no snapshot.
- Ask finds are not routed. They stay yours, as before.
- "Someone…" picks from People only. Typing a new name there is not built; add the person in
  Settings first.
