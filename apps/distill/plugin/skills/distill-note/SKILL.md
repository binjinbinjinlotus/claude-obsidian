---
name: distill-note
description: "Queue something the user wants to remember as a note for Distill to ingest into their Obsidian vault, using `distill note add`. Use when the user says remember this, save this to my notes, add a note, jot this down, or capture this (text, a file, or images). The note only enters the queue; the user approves vault changes in the Distill app and agents cannot approve them."
---

# Queue a note with Distill

`distill note add` writes a note (and optional images) into Distill's queue.
Distill ingests the queue in batches and **stops for the user's approval**
before anything is written to the vault. Approval happens only in the Distill
app: there is no CLI command to approve, apply, reply to or reject a change,
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

## Output

Success is one JSON object on stdout, exit code 0:

```json
{ "notePath": "/…/inbox/gyokuro-at-60-c.md", "queued": ["/…/inbox/gyokuro-at-60-c.md", "/…/inbox/setup.jpg"] }
```

Errors are `{"error": {"code": "…", "message": "…"}}` with exit code 1 (or 2
for a usage mistake).

## What to tell the user

Say the note is **queued**, not saved: Distill will propose the vault change
and the user must approve it in the Distill app. Do not claim it is in the
vault, and do not offer to approve it for them.

If `distill` is not found, tell the user to install it by following
`apps/distill/plugin/README.md`.
