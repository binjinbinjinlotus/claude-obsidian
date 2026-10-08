---
name: distill-note
description: "Queue something the user wants to remember as a note for Distill to ingest into their Obsidian vault, using `distill note add`, then label it by request ID with `distill note label` from Distill's suggestions. Use when the user says remember this, save this to my notes, add a note, jot this down, or capture this (text, a file, or images). The note only enters the queue; the user approves vault changes in the Distill app and agents cannot approve changes or confirm labels."
---

# Queue a note with Distill

`distill note add` writes a note (and optional images) into Distill's queue.
The queue folder may be the vault's `inbox/` (the user's intake, which
claude-obsidian keeps outside its transactions), so the note file itself can
land there at once. Distill ingests the queue in batches and **stops for the
user's approval** before anything is written to the vault's knowledge
(`wiki/`, `.raw/`). Approval happens only in the Distill app: there is no CLI command to approve, apply, reply to or reject a change,
and you must not look for one or edit the vault directly instead.

## When to use

- "Remember that...", "save this to my notes", "add a note about...",
  "capture this meeting outcome", "keep this screenshot with the note".
- The user wants information kept in their own knowledge base, not just in
  this conversation.

Ask one short question first if the title or what to include is unclear.
Save only what the user selected; never a whole transcript by default.

## How to call it

Always pass `--json`. Give a short, specific title and the text:

```bash
distill note add --title "Gyokuro at 60 °C" \
  --text "Steep 2 minutes at 60 °C; second infusion 1 minute." \
  --source in-person --ref "with Mei" --json
```

| Flag | Meaning |
| --- | --- |
| `--title T` | required; becomes the note's title |
| `--text "..."` | the note body (Markdown) |
| `--file PATH` | read the body from a file instead |
| `-` | read the body from stdin (use for long or multi-line text) |
| `--image PATH` | attach an image and **keep** it in the vault (default) |
| `--image PATH:extract` | read the image's text into the note; the image is **not** stored |
| `--source S` | where it came from, e.g. `slack`, `meeting`, `in-person`, `web` |
| `--ref "..."` | free-text reference: a link, channel or person (`#tea-club · with Mei`) |
| `--label L` | a label you choose (repeatable); skips AI suggestions |
| `--no-suggest` | no AI label suggestion (and no waiting for one) |
| `--vault PATH` | a vault other than the active one |

Use only one of `--text`, `--file` or `-`. A note needs text or at least one
image. Prefer stdin for long text so the shell does not mangle it:

```bash
distill note add --title "Q3 pricing decision" --source meeting --ref "pricing sync 2026-10-01" --json - <<'EOF'
We keep the annual plan at $96 ...
EOF
```

Images: choose `:extract` for screenshots of text (cards, slides, receipts)
where only the words matter, and keep the default for photos, diagrams and
anything whose look matters. If unsure, keep the image.

Set `--source` and `--ref` whenever you know where the information came from;
it is how the user later filters and trusts the note.

## Labels: the request-ID loop

Labels are the note's tags; the user filters Ask by them. There are three ways
to label a note you add:

1. **You already know the labels** (the user named them): pass them up front
   with `--label` (repeatable). Distill makes no suggestion and the call is fast.
2. **Default: let Distill suggest, then decide.** Without `--label`, `note add`
   asks a model for label suggestions and waits for them (a few seconds; give
   the command a timeout of at least 2 minutes). The result has a `requestID`
   and `suggestedLabels`. Pick the labels, then send them back:

   ```bash
   distill note label req-7 --label tea --label gyokuro --json
   ```

3. **`--no-suggest`**: no suggestion and no labels from you. Use it only when
   the user does not want labels.

How to choose in step 2:

- Prefer suggestions with `"existing": true` (labels already used in the
  vault). Add a new one (`"existing": false`) only when no existing label fits.
  You may drop suggestions or add your own; 1 to 4 labels is usual.
- Labels have no spaces; a leading `#` is dropped.
- If `suggestError` is set instead, choose labels yourself from the note's
  content (or skip labeling) and say suggestions were unavailable.
- `note label` replaces labels sent before for that request ID and only works
  while the note is still in the queue. After the next batch picks it up, it
  fails with `invalid_state`: tell the user, and do not retry.
- If you send no labels before the batch, Distill may apply its own
  suggestions marked **unconfirmed** (the user's Settings → Labels decides).

Labels you send with `--label` or `note label` count as chosen labels. They
still reach the vault only through the user's approval of the ingest.

## Output

Success is one JSON object on stdout, exit code 0. `note add`:

```json
{
  "notePath": "/…/inbox/gyokuro-at-60-c.md",
  "queued": ["/…/inbox/gyokuro-at-60-c.md", "/…/inbox/setup.jpg"],
  "requestID": "req-7",
  "suggestedLabels": [{ "name": "tea", "existing": true }, { "name": "gyokuro", "existing": false }]
}
```

`suggestedLabels` is present only when a suggestion was made, and
`suggestError` (a string) only when it failed. `note label`:

```json
{ "notePath": "/…/inbox/gyokuro-at-60-c.md", "labels": ["tea", "gyokuro"] }
```

Errors are `{"error": {"code": "…", "message": "…"}}` with exit code 1 (or 2
for a usage mistake).

## What agents cannot do

You cannot approve, apply, reply to or reject a vault change, and you cannot
confirm AI labels on pages already in the vault. The CLI has no command for
any of these; they happen only in the Distill app. `note label` is not
approval: it only sets the labels of a note still in the queue.

## What to tell the user

Say the note is **queued**, not saved: Distill will propose the vault change
and the user must approve it in the Distill app. Name the labels you chose.
Do not claim it is in their knowledge base (even when the queue is the
vault's `inbox/`), and do not offer to approve it for them.

If `distill` is not found, tell the user to install it by following
`apps/distill/plugin/README.md`.
