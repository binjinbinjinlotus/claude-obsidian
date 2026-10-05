---
type: spec
title: Live log
status: built
created: 2026-10-05
updated: 2026-10-05
tags:
  - distill
  - logs
  - collectors
  - batches
---

# Live log

What a batch, a collector run, a package install or a Test run is doing,
as it happens and afterwards. The owner asked: "Is there any log that can
indicate the progress of the file batching?" and "is it possible to see the
live log when a collector is running?". One of their batches started at
03:33:13Z, and Claude's first step came at 03:37:08Z. The app showed
nothing for those four minutes, which went to suggesting labels, one file
at a time.

Canvas: row 9, boards **LiveLog** (batches) and **CollectorsLog**
(collectors), and the **LogLine** component (row 0). Swift:
`Sources/Distill/LiveLog.swift`, logic in `Sources/DistillKit/LiveLog.swift`.

## Where it opens

The log opens in place of the screen it came from, with "‹ back".
Collectors → All runs and Activity's narrow detail already work this way.
It works the same at 890 pt and needs no panel or extra window.

| From | Link | Back to |
| --- | --- | --- |
| Queue, a running batch | The batch card's **Now** line and **Show steps** | ‹ Queue |
| Review, History → Jobs | **Show steps** next to the batch's times; **Show steps** on a running job's card | ‹ the batch |
| A collector's status card | **Show log** over the last lines: running, installing, Run now result, failed run, failed install | ‹ the collector |
| A Test run result | **Show log** (it replaces Show output) | ‹ the collector |
| All runs, an opened script run | **Open log** next to Copy output | ‹ All runs |

In an 890 pt window, a collector log takes the whole window: no list, no
header.

## What it shows

A batch's log groups its steps by phase. The phases are Getting ready,
Claude's (or Codex's) steps, Checking, Your review and Applying. Each step
is in plain words and carries a quiet mark: done, running, waiting, waiting
for you, or failed.

- **Getting ready**: "Moved 22 files from the queue to your inbox". Then
  "Suggesting labels · 14 of 22", with a thin bar and one line per file.
  Up to three files can be labeled at once (the label pool), so up to three
  lines can be running together. While labels are being suggested, older
  finished files fold into "N files done".
- **The AI's steps**:
  - Reads, searches, commands, writes and edits fold when three or more
    come in a row, for example "Read 22 sources", "Searched 3 times" or
    "Writing drafts · 9 so far". Each fold opens to its steps.
  - The AI's own status messages appear in italics, cut to 280 characters.
- **Checking**: "Checked the changes with the vault core · 31 changes", or
  the core's error.
- **Your review**: "Waiting for your review". Once you act it becomes "You
  approved", "You answered" or "You rejected the changes". Blocked tools
  and questions appear here too.
- **Applying**: "Applied 31 changes to Research · op-…", then "Found 5
  actions to confirm".

The time shows only when the minute changes. **Details** adds the raw line
under each step: the tool and its target, such as a path, a line range, a
search pattern, or the first 120 characters of a command. **Copy** copies
every step as plain text, folded or not, with the raw line in brackets.

A collector log shows the output in the order the script printed it:

- stdout in white;
- stderr in peach, with a peach gutter;
- the command and Distill's own `[…]` lines in grey;
- a faint time whenever the second changes.

The header also shows what ran the script, from `run.runtime` or
`install.runtime`, for example "python3 (.venv) · ~/…/.venv/bin/python3".
An opened run in All runs shows it next to OUTPUT. Copy copies the output
as printed, with stderr lines marked `err`.

Both logs follow the newest line. Scrolling up stops it and shows **Jump to
latest**. After the run the same view stays readable and shows what was
kept.

## Plain words

| What the AI did | What the log says |
| --- | --- |
| Read a batch source (inbox/, .raw/) | Read “Kettle comparison” |
| Read a vault page (wiki/) | Read your page “index” |
| Read anything else (skills, code) | Read provenance.md |
| Grep / Glob | Searched for “…” / Looked for files (…) |
| Bash | Ran a command: shasum. A recognizable `cat`/`sed -n`/`head` of one file reads as Read “…”, and `transaction inspect` as Checked the plan with the vault core |
| Write / Edit in the job folder | Wrote a draft (s01.md) / Edited a draft (s02.md) |
| Skill | Started the wiki-ingest instructions |
| TodoWrite, Task, WebFetch, WebSearch | Updated its plan; Started a helper: …; Looked up host; Searched the web for “…” |
| The structured answer (StructuredOutput) | Left out: it is the result, not a step |
| Anything else | Used <tool> |

Codex steps use the same words. It reads files with shell commands, so a
recognizable read of one file shows as Read “…”. Batches never run on a
model API, because those runners have no tools and so give no steps.

## What is kept, and never

- **Kept**: each step's plain words, the file or page name, and the tool
  with its target. A job keeps at most **2,000 steps / 512 KB** in
  `<state>/steps/<job-id>.jsonl` (mode 0600, one JSON line per new or
  changed step, the last line of an id wins). Past that limit, one line
  "Later steps weren't kept" closes the log. A log is removed with its job:
  deleting the job does it, and at start the core drops logs of jobs that
  are no longer listed (History keeps 300).
- **Never kept**: what a file says, what a tool returned, a draft's text,
  or anything that looks like a key or token. Keys and tokens become •••
  (the same patterns as in Activity: `sk-…`, `xox…`, `ghp_…`, Bearer,
  `token=`). The raw transcript stays where Claude Code keeps it, and Open
  in Terminal still resumes the session.
- **Batches from before this shipped**: the view says "Steps weren't kept
  for this batch" and points to the conversation.
- **Collector runs**: `run.outputLog` holds both streams in order, the last
  64 KB, with one stream's output within one second merged into a single
  chunk. Runs saved before it show Output, then stderr, from the separate
  64 KB tails. Live chunks are throttled per stream, every 250 ms, so the
  order *between* streams while a run is live is approximate. The saved
  `outputLog` is exact.

## Contract (v7, additive)

- `RunRequest.onStep(step: RunnerStep)`: the runner reports each tool call
  (`tool`, with an id when it has one), each tool that finished (`toolDone`)
  and each status message (`message`).
  - **Claude Code** switches to `--output-format stream-json --verbose`, and
    only when `onStep` is set. It reads lines as they arrive (`runProcess`
    `onStdoutLine`).
  - The last `result` event carries the same fields as the `json` envelope
    (`result`, `is_error`, `total_cost_usd`, `session_id`,
    `structured_output`, `permission_denials`) and decodes through
    `parseClaudeJSON`. This was checked against the real CLI with
    `--json-schema` on 2026-10-05: the structured output was identical in
    both modes.
  - Steps of a subagent (with `parent_tool_use_id` set) are left out.
  - Ask, labels and actions still use `json`.
  - **Codex** reads its existing `--json` lines as they arrive:
    `command_execution`, `file_change`, `web_search`, `mcp_tool_call` and
    `agent_message`. The final JSON answer is not a note.
- `Progress.current`: the file being labeled. It rides on the existing
  batch progress events, so no extra events are sent.
- `JobStep` / `JobStepsPage`; the event `{type: 'job.step', jobId, step}`,
  sent for a new step or a changed one (same id); `GET /v1/jobs/:id/steps` →
  `{jobId, steps, kept, truncated?}`.
- `CollectorRun.outputLog: {stream, text, at}[]`.
- Engine: an additive `EngineStepSink` (`runnerStep`, `labelFile`) passed in
  `EngineOptions.steps`. Every other step is derived from `job` and
  `progress` events in `core/src/steps/`.
- DistillKit decodes all of it leniently. A `job.step` this build can't
  read becomes `.unknown`.

## Known gaps

- Review and History → Jobs boards on the canvas are hand-made (outside the
  schema) and don't draw Show steps yet; LiveLog frames E and G do.
- The order between stdout and stderr is approximate while a run is live
  (see above).
