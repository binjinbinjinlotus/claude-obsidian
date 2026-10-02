---
name: distill-ask
description: "Answer a question from the user's own notes (their Obsidian vault managed by Distill) with numbered citations, using the read-only `distill ask` command. Use when the user asks what their notes, vault, wiki, knowledge base or second brain say about something, or asks to recall something they saved earlier. Not for general knowledge questions or for saving new notes (use distill-note)."
---

# Ask the user's notes with Distill

`distill ask` answers a question only from the user's active vault and cites
the pages it used. It is read-only: it never changes the vault.

## When to use

- The user asks about their own notes: "what did I write about X", "check my
  vault for Y", "according to my notes...", "did I save anything on Z?".
- You need a fact the user recorded earlier (decisions, recipes, settings,
  meeting outcomes) and the user expects it to come from their notes.

Do not use it for general knowledge, for web research, or to save something
(use the `distill-note` skill for that).

## How to call it

Always pass `--json` and quote the question:

```bash
distill ask "How hot should the water be for sencha?" --json
```

Scope defaults to **all notes**. Add filters only when the user asks for them:

| Flag | Meaning |
| --- | --- |
| `--label L` (repeatable) | only pages with label `L` |
| `--source S` (repeatable) | only pages from source `S` (e.g. `slack`, `meeting`, `in-person`) |
| `--conversation ID` | follow-up question in the same conversation (use the `conversationID` from the previous answer) |
| `--runner R --model M` | use a specific runner and model (`--model` is required when `--runner` differs from the default) |
| `--effort E` | `low`, `medium`, `high`, `xhigh` or `max`; omit to use the user's default |
| `--vault PATH` | a vault other than the active one |

Only set runner, model or effort when the user asks for them (for example
"think harder" means a higher `--effort`).

The first call may print nothing for a few seconds while the Distill server
starts in the background. Answers can take a minute; do not retry early.

## Output

Success is one JSON object on stdout, exit code 0:

```json
{
  "conversationID": "…",
  "answer": "Brew sencha at 70-80 °C [1].",
  "citations": [{ "n": 1, "path": "wiki/tea/sencha.md", "title": "Sencha" }],
  "gaps": ["No notes on cold brewing."],
  "selection": { "runnerID": "claude-code", "model": "sonnet", "effort": "medium" },
  "costUSD": 0.01
}
```

Errors are `{"error": {"code": "…", "message": "…"}}` with exit code 1 (or 2
for a usage mistake).

## How to present the answer

1. Give the `answer`, keeping its `[n]` markers.
2. List the citations below it as `[n] title (path)`. Never invent citations,
   page paths or quotes that are not in the response.
3. If `gaps` is not empty, say plainly which parts the notes do not cover.
   Do not fill those gaps with your own knowledge unless the user asks, and
   then label that part as not from their notes.
4. Keep the `conversationID` for follow-up questions on the same topic.

## When it fails

- `distill: command not found`: the Distill CLI is not installed. Tell the
  user to follow `apps/distill/plugin/README.md`; do not try other commands.
- An error mentioning setup problems or no vault: report the message and
  suggest `distill status` or opening the Distill app.
- `server_start_failed` / `server_unreachable`: report the message, including
  the log path it gives.
