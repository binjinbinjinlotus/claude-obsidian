---
type: spec
title: Action buttons and script commands
status: built
created: 2026-10-05
updated: 2026-10-06
tags:
  - distill
  - actions
  - collectors
---

# Action buttons and script commands

Status: **built** (2026-10-05): core, API and CLI (96cc0c1), then the Mac app (see "Built" below). Canvas: row 15,
board `ScriptActions.dc.html` (`apps/distill/design/screens/scriptactions.json`).
Builds on [Collectors](collectors.md) (stored scripts, consent, packages, runs,
the live log) and [Actions](actions.md) (types, handlers, the reserved "Send
in Slack" slot).

## The ask

The owner wrote (2026-10-05, lightly cleaned up from dictation):

> "Currently we have a feature called a collector. Its purpose is just to run
> the script and collect stuff or perform some actions. I want to extend that
> feature so it can act as an action performer. The new action performer
> supports all the features of the current collectors, but on top of that it
> can also store the scripts that the actions run. Currently the Slack message
> has a button for Send in Slack, which will be implemented later. For every
> item under Actions (to-do, Slack message, Jira ticket, Confluence page or
> others), in Settings or inside that tab, I can add buttons and link each
> button to an action performer. For example, I will have a Slack CLI script
> that performs different Slack actions by its arguments. The Send in Slack
> button can then be linked to run that script with the right arguments. We
> will work out, for each handler, which parameters we can offer, and link them
> to the script's parameters. After the action runs, it shows the result.
> `apps/scripts/slack`. Action performer may not be a good name, so please
> also design a good name."

## In one paragraph

A stored script keeps doing everything a collector does, and it can also
offer **commands**. A command is a named way to call the script, with
arguments: for the Slack CLI, `send` takes a target, a text and an optional
thread. On any action type, the owner adds **buttons**. A button runs one
command of one script, and its **argument mapping** fills each argument from
the item: `{fields.to}`, `{body}`, `{title}`, `{summary}`, a literal, and so
on. Before the first run, the run sheet shows the exact command line. Distill
passes the arguments as an argv array, never through a shell. Output streams
into the live log. The result is kept on the item: the exit status, the last
output lines, and optionally an external key or URL read from the output. A
success can also mark the item sent or done. "Send in Slack" stops being a
"Later" placeholder and becomes a button linked to `slack_cli.py send`.

## The name

The owner asked for a better name than "action performer". The thing named
is "a stored script Distill runs on a schedule (collecting) or from an
action's button (doing)". It sits beside the built-in Folder collector,
which is not a script at all.

The test that separates the options: the name has to fit a Folder collector
(collects, not a script) and a commands-only Slack CLI (a script, never
collects) in the same list.

| Name | Fits Folder? | Fits Slack CLI? | Notes |
| --- | --- | --- | --- |
| **Automations** (recommended) | yes | yes | Says "Distill does this for you", whether on a clock or a click. A Folder automation collects; the Slack CLI automation offers commands. One clash: macOS uses "Automation" for a privacy permission, but Distill never asks for that permission. |
| Scripts | weak | yes | The most literal for scripts, and it matches the file you edit. The Folder collector would be a "script" that has no script. |
| Helpers | yes | yes | Friendly, but vague: it doesn't say they run things. |
| Runbooks | weak | yes | Ops vocabulary for stored procedures. Precise for engineers, jargon for anyone else. |
| Tools | yes | yes | Clashes with the AI's tools in the live log, where Claude's "tools" are a different thing. |

**Recommendation: rename the sidebar item Collectors → Automations, and keep
"collect" as a role.** In the app:

- An automation can **Collect** (the schedule, the queue folder, the ledger:
  everything a collector does today) and can offer **Commands** (run from
  buttons).
- A Folder automation only collects. The Slack CLI only offers commands. A
  script can do both.
- The list groups them: "COLLECT ON A SCHEDULE" and "COMMANDS FOR BUTTONS".
  A script that does both shows in the first group with a "2 commands" note.

**The data keeps its names.** `Collector` records, the `col-…` ids,
`collectors.json`, `/v1/collectors`, `distill collectors …` and
`runs/<collector-id>.jsonl` are unchanged, whatever label the owner picks.
The rename is words in the app and the specs, so there is no migration, and
the owner's running collector is untouched. If the owner prefers to keep
"Collectors" as the sidebar name, the rest of this design works unchanged:
only the label and the group names differ.

## Commands: how a script offers them

### Decision: commands are declared in Distill, by the owner

A command is stored on the script's record (`script.commands`). The owner
fills it in the app, in the automation's detail → **Commands** → ＋ Add
command. It is not parsed from `--help`, because reading `--help` means
running the script, and that needs consent. It is not read from a manifest
file next to the script either, because the owner's own file (the Slack CLI)
lives in the repo, and Distill never writes into it.

- Alternative (later, additive): a `distill-commands.json` next to a script
  Distill keeps, imported once into `script.commands`. It isn't needed for
  the Slack CLI.

### A command

```ts
/** One way to call a script with arguments. Stored in ScriptCollectorSettings.commands. */
interface ScriptCommand {
  id: string;            // "send": a slug, unique within the script
  label: string;         // "Send a message"
  description?: string;
  /** In argv order. */
  args: ScriptCommandArg[];
  /** Put "--" before the first positional argument. Default true (see "Arguments that start with -"). */
  endOptions?: boolean;
  /** Default 60, 1…3600. */
  timeoutSeconds?: number;
  /** How to read a key or URL from stdout. Absent means nothing is read. */
  result?: ScriptResultParse;
}

interface ScriptCommandArg {
  /** What a button binds to: "target", "text", "thread". */
  name: string;
  /**
   * word       = a fixed word, e.g. the subcommand "send" (value is the word, never bound);
   * flag       = "--thread VALUE" (two argv elements), left out when its value is empty;
   * switch     = "--all" when the bound value is true / yes / 1, else left out;
   * positional = one argv element.
   */
  kind: 'word' | 'flag' | 'switch' | 'positional';
  flag?: string;          // "--thread" (flag, switch)
  value?: string;         // word: the word itself
  required?: boolean;     // positional default true, flag default false
  /** A regular expression the final value must match, checked in the preview. */
  pattern?: string;
  /** Plain words for the pattern, shown in a problem: "#channel, @handle or an ID". */
  hint?: string;
}

interface ScriptResultParse {
  /** Read the last stdout line that parses as a JSON object: {key?, url?, status?, message?}. */
  json?: boolean;
  /** A regular expression run on stdout; its first group (or a group named key) becomes external.key. */
  keyPattern?: string;
  /** The same for the URL (group 1 or a group named url). */
  urlPattern?: string;
}
```

The argv a command produces is:

```
<interpreter> <script path> <words and flags, in order> [--] <positionals, in order>
```

Words and flags keep their declared order. When `endOptions` is on, all
positionals come after `--`, so a flag can't follow a positional. The editor
orders the rows to match, so the preview never surprises.

### The Slack CLI, as declared (worked example)

`apps/scripts/slack/slack_cli.py` (argparse; see its README). It is added as
an automation with **Your own file** as the source, interpreter `python3`,
Collect off, and two commands:

| Command | argv after the script | Arguments |
| --- | --- | --- |
| `send` · Send a message | `send [--thread TS] -- <target> <text>` | `send` (word); `thread` (flag `--thread`, optional); `target` (positional, required, pattern `^(#\S+\|@\S+\|[CGDUW][A-Z0-9]+)$`, hint "#channel, @handle or an ID"); `text` (positional, required) |
| `mark` · Mark read | `mark [--ts TS] -- <target>` | `mark` (word); `ts` (flag `--ts`, optional); `target` (positional, required, same pattern) |

- Result for `send`: `keyPattern` `ts ([0-9]+\.[0-9]+)\)`. The CLI prints
  `sent to #general (channel, ts 1759600000.123456)`, so the item's
  `external.key` becomes the message ts. It prints no permalink, so there is
  no URL.
- Read-only commands (`history`, `thread`, `catchup`, `unread`, `channels`,
  `dms`) print messages to stdout. They could feed a Slack collector later,
  through a small wrapper that writes files into the queue folder. That is out
  of scope here.
- Its credentials stay where they are: in the macOS Keychain under the
  service `slack_cli`, read by the script itself through `keyring`. Distill
  passes no Slack secret and doesn't need one. A Keychain prompt may appear the
  first time Distill's run of `python3` reads that item; this is the same
  binary as in the owner's terminal, so usually there is none.
- Packages: the README installs `requests keyring` with `pip install --user`
  into the login shell's `python3`. A user's own file runs with that `python3`
  (no `.venv`), so nothing more is needed.

**Owner decision (optional): a `--json` flag on `send`.** If `send` also
printed `{"ok": true, "channel": "C…", "ts": "…", "permalink": "…"}` (one
`chat.getPermalink` call), the button could store a real link to open the
sent message. Distill never edits the owner's script; this is a suggested
change for the owner to make or decline. Without it, the regex above stores
the ts.

### Arguments that start with `-`

Checked on 2026-10-05 against a copy of the CLI's argparse layout (not the
CLI itself) on the owner's `python3` 3.13.2:

| argv after the script | Result |
| --- | --- |
| `send @x "- item"` | works: a value containing a space is taken as positional |
| `send @x "-x"`, `send @x "--done"`, `send @x "--thread"` | **fails** (exit 2): argparse reads the text as an option |
| `send @x -- "--thread"`, `send -- @x "-x"` | works |
| `send --thread 1.2 @x -- "- item"` | works |
| `send @x TEXT`, where TEXT holds `$(rm -rf ~)`, double and single quotes, and backticks | works: the text arrives byte for byte |

So `endOptions` defaults to **on**: Distill puts `--` before the first
positional. A body like `--` or `-x` then reaches the script as text.

## Buttons on action types

### Where you add them

- **Settings → Actions → a type's page → Buttons.** This lists the type's
  buttons in the order they appear on items, with ＋ Add button, Edit, a
  switch, and drag to reorder.
- **From the type's tab:** a quiet dashed **＋ Button** at the end of an
  item's footer (To do, Slack messages, Jira tickets, Confluence pages, and any
  future type). It opens the same editor as a sheet, with the selected item
  as the preview's sample. "Edit button…" is in each custom button's
  right-click menu.

It is one editor in two places, writing to one store.

### A button

Stored in `settings.actionPreferences.types[typeId].buttons`, which is
additive. The Mac app keeps `actionPreferences` as raw JSON (`ActionSettings.swift`),
so an older app editing a type page sends `buttons` back unchanged.

```ts
interface ActionButton {
  id: string;                  // btn-<uuid>
  label: string;               // "Send in Slack"
  icon?: string | null;        // SF Symbol; default "play"
  enabled: boolean;            // default true
  scriptId: string;            // the automation (col-…)
  commandId: string;           // "send"
  /** Argument name → template. Words are never bound. */
  bindings: Record<string, string>;
  /** Show the run sheet and wait for Run. Default true. The first run, and the first run after any change, always asks. */
  confirm: boolean;
  /** What a success does to the item. Default: Slack markSent, Jira and Confluence none, others none. */
  onSuccess: 'none' | 'markSent' | 'complete';
  /** Store the key or URL read from the output in item.external. Default true. */
  storeResult: boolean;
  /** Which item statuses show it. Default ['open', 'ready']. */
  when: ActionStatus[];
  /** send = takes the reserved "Send in Slack" slot (the primary button); primary; or more (the ⋯ menu). Default primary for the first button, more after. */
  slot: 'send' | 'primary' | 'more';
}
```

The core reports buttons to the clients as `ActionTypeInfo.buttons:
ActionButtonInfo[]` (additive): the button, plus `available`, `reason`
("Slack CLI needs your OK", "Script missing", "Command removed"),
`scriptName` and `commandLabel`. When a button has `slot: 'send'`, the
reserved `send` handler is left out of `handlers`, so an older app keeps
showing "Send in Slack · Later" and a new app shows the button instead.

### Argument mapping (templates)

Each argument of the command gets a template. It is literal text with
`{placeholders}`:

| Placeholder | Value |
| --- | --- |
| `{title}` `{body}` `{summary}` `{why}` | the item's title, body (Markdown as stored), summary, why |
| `{fields.<key>}` | any field of the type: `{fields.to}`, `{fields.due}`, `{fields.priority}`, `{fields.person}`, `{fields.project}`, `{fields.issueType}`, `{fields.assignee}`, `{fields.space}`, `{fields.parent}`; future types' fields work the same way |
| `{labels}` | the labels joined with ", " |
| `{quote}` `{excerpt}` | the source quote; the original's lines (`source.raw.excerpt`) |
| `{note_title}` `{note_path}` | as in the prompts (the source page's title and path) |
| `{source.raw}` `{source.wiki}` | the original's vault path (`.raw/captured/…`); the first wiki page's path |
| `{external.key}` `{external.url}` | what an earlier Create or button stored |
| `{item.id}` `{type}` `{today}` `{now}` `{vault}` | the item id, type id, `YYYY-MM-DD`, ISO time, vault path |
| `{{` `}}` | a literal `{` / `}` |

The existing prompt aliases (`{recipient}`, `{project}`, `{issue_type}`, …)
are accepted too, so Insert field ▾ offers one list.

Rules. These are the safety contract, and each one is a test:

1. **One template is one argv element.** Substituting values never splits,
   joins or re-quotes anything. A body with spaces, quotes, `$(…)`,
   backticks, `;`, `|`, newlines or emoji stays one element, byte for byte.
2. **Single pass.** Values are not scanned again: a body that contains
   `{title}` reaches the script as the text `{title}`.
3. **An unknown placeholder is an error**, shown in the preview ("`{fields.channel}`:
   Slack messages have no field channel"). The run is refused. This differs
   from prompts, where unknown words stay as typed.
4. **Empty values:** a required argument that ends up empty is a problem,
   and the run is refused. An optional flag whose value is empty is left out
   with its flag. A switch is on only for `true`, `yes`, `1` or `on`.
5. **A pattern** that doesn't match is a problem with the hint ("To: “Mei
   Tanaka” isn't #channel, @handle or an ID").
6. **NUL characters** are refused, because argv can't carry them. An element
   over 100 KB is refused ("too long for a command line; read
   `DISTILL_ACTION_JSON` instead").

The Slack button's mapping is `target ← {fields.to}`, `text ← {body}`,
`thread ← ` (empty, so it is left out). The To field is free text today
([Actions](actions.md): "no Slack lookup yet"), so "Mei Tanaka" fails the
pattern until the owner types `@mei.tanaka` or a `#channel`. The run sheet
says so and offers **Edit To** on the spot. A Slack people lookup would remove
this step later.

### Preview: the exact command line

The editor shows the preview under the mapping, live as the owner types. The
run sheet shows it before the first run.

```
python3 /Users/jin/…/apps/scripts/slack/slack_cli.py send -- @mei.tanaka 'Hi @Mei, I booked the tasting room…'
```

- It is computed by the core (`previewActionButton`), so it is exactly what
  will run. The display line is shell-quoted only for reading. Below it, a
  numbered **argv** list shows each element on its own line, with its length
  and newlines shown as `⏎`.
- **Preview with ▾** picks the sample item: in Settings, the type's newest
  open item, or a built-in sample when there is none; in the tab, the selected
  item.
- Problems list under it, in peach.

## Running a button

### Consent still applies

- **The script's consent is unchanged:** it is bound to the sha256 of the
  script and its package manifest, as for a collector. A commands-only script
  is added off, like any script, and its detail asks **Allow** (not "Allow and
  turn on", because there is nothing to turn on). A changed script makes every
  button that uses it show "Needs your OK". Pressing one opens the run sheet
  with the consent card: the hashes, what changed, and **Allow this version
  and run**.
- **Each button is approved on its first run.** `approvalHash = sha256(script
  consent hash, the command's JSON, the button's bindings, its scriptId and
  commandId)`. When it differs from the stored one (first run, an edited
  mapping or command, a new script version), the run sheet always opens and
  shows the exact command line, even with Ask before running off. Pressing
  **Run** in that sheet records the approval
  (`<state>/actions/button-approvals.json`, `{buttonId: {hash, at}}`; core
  state, not settings).
- **Only the app runs buttons.** The CLI and agents can list buttons and
  preview a command, but they can't run one, just as they can't grant a
  collector consent. (Owner decision; see "Decisions for the owner".)
  - Enforcement: the CLI and the plugin have no run command. The run and
    approve routes also refuse a request whose source isn't the app (the
    `X-Distill-Client` header or the Mac app's User-Agent, read in
    `activity/context.ts`), answering 403 `forbidden_client`.
  - What this limits: which Distill client offers the action. It is not a
    boundary against a program that holds the local API token and sends the
    app's header. Collector Allow has the same limit today.

### The run sheet

It opens on press when the button asks first, or when it isn't approved
yet.

1. Header: the button's icon and label, "for “Message to Mei Tanaka”", and
   **Runs Slack CLI › send**.
2. **The command line** (preview) and the argv list, with any problems.
3. Footer: Cancel and **Run** (the primary button). The first time, it adds
   "Ask me every time" (on by default; turning it off sets `confirm: false`).
4. After Run, the same sheet becomes the **live log**: output lines stream as
   they print (stdout dark, stderr peach), with the elapsed time and Stop. It
   reuses `LogLine` and the collector live log (`collector.run.output`
   events; [Live log](live-log.md)).
5. On exit, a success closes the sheet after 1.5 s, unless the owner scrolled
   or selected text. The item shows the result. A failure keeps the sheet open
   with the stderr tail, **Try again** and Close.

When it doesn't ask, pressing the button shows a spinner in it, and the item's
**Last run** block streams the last 3 lines; **Show log** opens the full live
log.

### What a run is

A button run is a script run with `trigger: 'action'`, kept in that
automation's run history (`runs/<col-id>.jsonl`; the Mac app decodes
`trigger` as a raw string, so older apps show it). It adds:

```ts
CollectorRun.command?: {
  id: string;               // "send"
  buttonId: string;
  actionId: string;
  argv: string[];           // after the script path; masked like output
}
```

- **Like a Test run, it never sets** `status.lastRun`, the sidebar count or
  the schedule. A failed Send shows on the item, not as a broken collector.
- **Timeout:** the command's `timeoutSeconds`, default 60 s, maximum 1 hour.
  Then SIGTERM to the process group, and SIGKILL 10 s later, as for collectors.
- **Slots:** a button run doesn't wait for the 2 collector slots or for a
  batch, because it doesn't write to the queue or the vault. It is one run per
  item at a time (`busy` otherwise). A scheduled collect of the same script
  can run alongside it.
- **Packages:** a script Distill keeps installs first when its packages are
  missing (`beforeRun`), as today.
- **Environment:** the user's login environment and PATH, as for collectors,
  plus:
  - `DISTILL_RUN_TRIGGER=action`, `DISTILL_RUN_ID`, `DISTILL_COLLECTOR_ID`,
    `DISTILL_COMMAND` (`send`), `DISTILL_ACTION_ID`, `DISTILL_ACTION_TYPE`,
    `DISTILL_VAULT`;
  - `DISTILL_ACTION_JSON`: the path of a 0600 temporary file holding the
    item's JSON, for scripts that want everything (deleted after the run);
  - no `DISTILL_QUEUE_DIR`, because a command doesn't collect.
- **Working directory:** a fresh temporary folder, deleted after the run.
  **stdin:** closed. **User:** the logged-in user.
- **Output:** stdout and stderr, the last 64 KB each plus `outputLog`, with
  the masking used for installs (URL credentials, `Bearer …`, `xox[a-z]-…`
  tokens).
- **Exit 0 = success**, anything else = failed.

### What a success does to the item

In this order:

1. **Read the result:** with `result.json`, the last stdout line that is a
   JSON object (`{key?, url?, status?, message?}`); else `keyPattern` and
   `urlPattern`. Nothing is required: a script that prints nothing still
   succeeds.
2. **Store it** (when `storeResult` is on): `item.external.key` / `.url`, and
   `.status` from the JSON. Existing values are replaced only by values that
   were found.
3. **Status:** `onSuccess` `markSent` → `sent`; `complete` → `done` (detail =
   the status it left, so Restore works as for Complete); `none` → unchanged.
4. **Timeline:** event `ran` with detail `Send in Slack · sent to #general
   (channel, ts 1759600000.123456)` (the button's label, then the JSON
   `message` or the last stdout line, at most 200 characters).
5. **Activity:** `action.button_run` (ok), with details `{button, script,
   command, exitCode, durationMs, runId, externalKey?}`. Never with the argv
   values, which can hold message text.

### What a failure does

- The item keeps its status, and `item.error` is set (`code: 'other'`,
  message: "Send in Slack failed (exit 1)").
- The **Last run** block is peach. It shows the stderr tail (the last 6 lines)
  with **Try again**, **Show log** and **Copy output**. When the run timed
  out or was stopped, it adds "It may have run already. Check Slack before
  trying again." A timeout doesn't prove nothing was sent.
- **Try again** reruns the same button with the item's current values. If the
  mapping changed since, it opens the run sheet.
- Timeline: `run-failed` with "Send in Slack · exit 1 · Error: channel '#x'
  not found or you're not in it". Activity: `action.button_run` (failed).

### Kept on the item

`ActionItem.runs?: ActionButtonRun[]` (additive, newest 10):

```ts
interface ActionButtonRun {
  runId: string; buttonId: string; label: string;
  startedAt: string; endedAt?: string; durationMs?: number;
  result: 'running' | 'success' | 'failed' | 'timedout' | 'stopped' | 'notTrusted';
  exitCode?: number | null;
  /** The last 2 KB of each stream, masked. The full output stays in the run (Show log). */
  stdoutTail?: string; stderrTail?: string;
  external?: { key?: string | null; url?: string | null } | null;
}
```

`ActionItem.activeRun?: {runId, buttonId}` marks a running button, and no
new `ActionStatus` is added. The item's pane shows a **Last run** block
under the body: the label, ✓ or ✕, exit code, duration and time, the last 3
stdout lines, and the stored key or URL (Open when it is a URL). History →
Actions and the timeline list every run.

## Safety

- **The approval gate is untouched.** A button run never writes to the vault
  through Distill, never goes through a batch, and never applies anything.
- **No shell.** The core spawns `<interpreter> <script> …argv` with
  `spawn(command, args)`, `detached`, as `script.ts` already does for
  collectors. No string is ever passed to `sh -c`. A body containing `$(touch
  /tmp/distill-pwned)` reaches the script as that text, and the test checks
  that the file was not created.
- **Consent per script version and approval per button version**, as above.
  Nothing runs from Ask, from finding, from an agent or from the CLI.
- **Secrets stay in the Keychain.**
  - Distill passes none of its own secrets (Atlassian tokens, model keys) to
    any script.
  - A script that needs a secret reads its own Keychain item, as the Slack
    CLI does.
  - Designed for later: **Script secrets**, named values that Distill stores
    in the Keychain (service `Distill script secret`, account
    `<scriptId>/<NAME>`) and passes as environment variables to that script's
    runs only. They are never written to settings, argv, previews, logs or
    Activity, and are masked if a script prints them. Templates can't
    reference a secret, because argv is visible in `ps`.
- **No network policy change.** As with collectors, Distill doesn't sandbox
  a script's files or network, and the consent card says so.
- **No sandbox is promised.** The consent card's words are unchanged.

## Screens (canvas row 15, board ScriptActions)

1. **Automations (the script library):** the renamed Collectors screen, with
   its list grouped into Collect on a schedule and Commands for buttons. The
   selected row is the Slack CLI's detail: status card ("Last command: Send in
   Slack for “Message to Mei Tanaka” · 10:42 AM"), Settings (Script · your
   file, Collect · off, Allowed), **Commands** (send, mark: argument chips and
   "Used by Slack › Send in Slack"), and Recent runs with button runs marked.
2. **Command editor:** the `send` command's arguments in argv order, the `--`
   divider, pattern and hint, timeout, and Read result.
3. **Settings → Actions → Slack message → Buttons, and the button editor:**
   label, icon, Runs (script ▾, command ▾), the argument mapping with Insert
   field ▾, When it works, Save from output, Ask before running, Show on, and
   the live preview with argv and problems.
4. **An item with custom buttons:** a Slack message with **Send in Slack**
   (primary, linked), Copy and Complete, and a to-do with a custom button and
   ＋ Button.
5. **The run sheet:** the first-run confirmation with the command line, then
   the live output.
6. **The result on the item:** success (sent, ts stored, Last run) and failure
   (stderr, Try again).
7. Cards: the name, rules for templates, argv safety tests, what changes in
   the data.

## API (designed)

| Method and path | Core method | Returns |
| --- | --- | --- |
| `PATCH /v1/collectors/:id {script: {commands?, collects?}}` | `updateCollector` | the collector; commands are validated (unique ids, known kinds, compilable patterns) |
| `POST /v1/actions/:id/buttons/:buttonId/preview` | `previewActionButton(id, buttonId)` | `{argv, display, problems: [{arg, message}], approved, script: {state: 'ok' \| 'needsConsent' \| 'missing', name}}` |
| `POST /v1/action-buttons/preview {typeId, button, actionId?}` | `previewButtonDraft` | the same, for an unsaved button in the editor |
| `POST /v1/actions/:id/buttons/:buttonId/run {approve?: hash}` | `runActionButton` | 202 `{run, item}`; 409 `needsApproval {hash, argv, display}`; 409 `notAllowed` (script consent); 409 `busy`; 400 `invalid_request` with problems; 403 `forbidden_client` when the source isn't the app |
| `POST /v1/actions/:id/buttons/:buttonId/stop` | `stopActionButtonRun` | `{run}` |

- Events: `collector.run.started` / `collector.run.output` /
  `collector.run.finished`, reused with `run.command`; `action.updated {item}`
  when the run ends.
- It is not `performAction`. That one awaits the handler inside the request,
  and a 60-second script with live output needs the async run shape that Run
  now has.
- Collectors with `script.collects: false`: Run now, Test run, the schedule and
  turning on are refused (`invalid_state`: "This automation only runs from
  buttons"). It is stored `enabled: false` with a valid `schedule`, so an older
  core never schedules it and an older app decodes it. In an older app, Run now
  would run `slack_cli.py <vault> <queue>`, which argparse rejects (exit 2,
  nothing sent).

## Data changes (all additive)

| Where | What |
| --- | --- |
| `ScriptCollectorSettings` | `collects?: boolean` (absent = true), `commands?: ScriptCommand[]` |
| `CollectorTrigger` | adds `'action'` |
| `CollectorRun` | `command?: {id, buttonId, actionId, argv}` |
| `ActionTypePreferences` | `buttons?: ActionButton[]` |
| `ActionTypeInfo` | `buttons?: ActionButtonInfo[]` |
| `ActionItem` | `runs?: ActionButtonRun[]`, `activeRun?: {runId, buttonId}` |
| new file | `<state>/actions/button-approvals.json` |

No migration. An older core drops nothing: settings keep unknown keys
(`encodeSettings`), and the collectors store merges a record's unknown keys,
nested `script` keys included, back in on save (`collectors/store.ts`), so
an older core keeps `commands` and `collects`.

## Decisions for the owner

Recommended defaults. Each is in [Decisions](decisions.md), 2026-10-05.

1. **Name:** Automations (sidebar label), with Collect and Commands as roles;
   records and API keep "collector". Alternatives: Scripts, Helpers, Runbooks,
   Tools.
2. **Commands are declared by hand in the app**, not parsed from `--help` and
   not read from a file next to the script.
3. **`--` before positionals is on by default.**
4. **Template syntax:** `{title}`, `{fields.to}` and the others above. Unknown
   placeholders are errors, there is one pass, and one template is one argv
   element.
5. **Ask before running is on by default.** It can be turned off per button,
   but the first run and the first run after any change always ask.
6. **Only the app runs buttons.** The CLI and agents can list and preview.
   Alternative: `distill actions run <id> --button <b>` for approved buttons
   with Ask turned off.
7. **The Slack button:** `send` with `target ← {fields.to}` and `text ←
   {body}`; on success Mark as sent, and store the ts as `external.key`. The
   reserved Send slot shows it as the primary button, and Copy stays as a
   secondary button.
8. **Body format:** `{body}` passes the stored Markdown unchanged (Slack shows
   `**bold**` literally). Alternative: a `{body.slack}` transform to Slack
   mrkdwn.
9. **Timeout:** 60 s per command by default.
10. **Button runs live in the script's run history**, with `trigger: action`,
    and never count as a failed collector.
11. **Script secrets:** designed, built in a second pass. The Slack CLI
    doesn't need them.
12. **Optional:** add `--json` to the Slack CLI's `send` for a permalink. This
    is the owner's script and the owner's choice.

## Build plan

Order: core → API → CLI → Mac. Each step is one commit, with `npm test
--workspaces`, and the Swift tests for Mac steps.

**Core** (`apps/distill/core/src`)

1. `contracts.ts`: the types under "Data changes", plus `DistillCore`
   methods `previewActionButton`, `previewButtonDraft`, `runActionButton`,
   `stopActionButtonRun`.
2. `collectors/commands.ts` (new):
   - `renderArg(template, values)`: single pass, `{{`/`}}`, errors for unknown
     placeholders;
   - `buildArgv(command, bindings, values)`: words and flags, `--`,
     positionals, empty-optional dropping, switch truthiness, pattern, NUL and
     size checks;
   - `parseResult(stdout, result)`;
   - `approvalHash(...)`.

   `collectors/commands.test.ts` covers quotes, `$(…)`, backticks, `;`, `|`,
   newlines and emoji (byte for byte), `{title}` inside a body not expanded, an
   unknown placeholder, an empty optional flag left out, a missing required
   argument, a value starting with `-` after `--`, NUL, over 100 KB, a pattern
   miss, a JSON line and a regex result.
3. `collectors/script.ts`: `runScriptCommand` → `startProcess({command:
   interpreter, args: [...interpreterArgs, scriptPath, ...argv]})`, with no
   vault or queue arguments.
4. `collectors/store.ts`: decode and encode `collects` and `commands`, and
   check that unknown keys survive. `collectors/index.ts`: `runCommand(collectorId,
   commandId, argv, ctx)` with trigger `action`:
   - consent check;
   - `beforeRun` install;
   - timeout from the command;
   - no slot or batch wait;
   - not counted in `lastRun` or the sidebar count;
   - the env vars and the `DISTILL_ACTION_JSON` file;
   - output masking extended to `xox?-` tokens;
   - refuse Run now, Test, schedule and turning on for `collects: false`.
5. `actions/buttons.ts` (new):
   - resolve a type's buttons from preferences into `ActionButtonInfo`
     (availability from the script's state);
   - values from an item;
   - preview;
   - `button-approvals.json`;
   - `runActionButton` (busy per item, `activeRun`, success and failure
     effects, `runs` capped at 10, events `ran` and `run-failed`);
   - stop.
6. `actions/registry.ts`: `typeInfo` takes the buttons, and hides the
   reserved `send` handler when a button holds slot `send`. `actions/index.ts`:
   wire the methods. Settings validation for `buttons` (ids, slot, `when`,
   `onSuccess`) is in the settings codec.
7. `activity/instrument.ts`: `action.button_run`, `action.button_approved`,
   and `collector.updated` for command edits.
8. `actions/buttons.test.ts` and an e2e with a fake Python script that prints
   its argv as JSON: exact round trip, `$(touch …)` not created, exit 1 →
   error and Try again, a timeout, a JSON result stored, Mark as sent, and a
   changed script refused until allowed.

**API**

9. `server/http.ts`: the routes in "API (designed)" (run and approve refuse non-app sources), with
   `http-buttons.test.ts`.

**CLI**

10. `cli/src/main.ts`:
    - `distill actions buttons [type]` (lists buttons and their command);
    - `distill actions preview <id> <button>` (prints the argv, one per line);
    - `distill collectors list` shows commands.

    There is no run command (decision 6).

**Mac** (`apps/distill/clients/macos/Sources`)

11. DistillKit:
    - `Collectors.swift`: `ScriptCommand`, `ScriptCommandArg`,
      `ScriptResultParse`, `collects`, `CollectorRun.command`;
    - `ActionSettings.swift`: `buttons` accessors on the raw object;
    - the action DTOs: `ActionTypeInfo.buttons`, `ActionItem.runs` and
      `activeRun`;
    - `CoreClient`: preview, run, stop, draft preview.

    Add decode tests for old and new JSON.
12. `Distill/CollectorsScreen.swift` and `CollectorsComponents.swift`: the
    sidebar label Automations, the list groups, and a Commands-only row.
    `CollectorsScriptViews.swift`: the Commands block and the command editor
    sheet. `CollectorsSheets.swift`: the Add sheet's first step, What it does
    (Collect / Commands / Both). `CollectorsStatusCard.swift`: a
    commands-only status ("Last command …") and Allow without turning on.
13. `Distill/SettingsActions.swift`: the Buttons section on a type's page.
    New `ActionButtonEditor.swift`: the editor (Runs, mapping with Insert
    field ▾, options, live preview through `previewButtonDraft`).
14. New `ActionButtons.swift`: footer buttons from `ActionTypeInfo.buttons`
    (slot send / primary / more), ＋ Button, the run sheet (preview →
    `LogLine` live output), and the Last run block. Wire it into
    `ActionsTypeScreen.swift` / `ActionsParts.swift` (Slack, Jira, Confluence)
    and the to-do detail.
15. `ActivityText.swift`: words for `action.button_run` and
    `action.button_approved`. Snapshot states in `SnapshotActions.swift` and
    `SnapshotCollectorScripts.swift` for each canvas frame.
16. Flip this spec to `built`, and update [Collectors](collectors.md),
    [Actions](actions.md), the index and `apps/distill/AGENTS.md`.

## Built (2026-10-05)

- **Name.** The sidebar and the screen say **Automations**; the data keeps
  `Collector`, `col-…` and `/v1/collectors`. The list groups into COLLECT ON A
  SCHEDULE and COMMANDS FOR BUTTONS (shown only when both groups exist). A
  commands-only script has Run now off (the core refuses it).
- **Script detail.** A COMMANDS block (`ScriptCommandsViews.swift`): the
  Collect on a schedule switch, each command's argv shape
  (`send [--thread <thread>]? -- <target> <text>`), "Used by Slack › Send in
  Slack", Edit and Add command. The command editor sets kind, name, flag or
  word, required, pattern and hint, the `--` rule, the timeout and how to read
  the result; the id is a slug of the name.
- **Buttons editor** (`ButtonEditor.swift`): Settings → Actions → a type →
  Buttons, and ＋ Button on an item. Runs (automation › command), the
  arguments with Insert field ▾, When it works, save the key, Ask before
  running, Show it as (the Send button for Slack, a button, the ⋯ menu), and a
  live preview through `POST /v1/action-buttons/preview` on the selected item
  or a sample. A new button guesses bindings by name (`text` → `{body}`,
  `target` → `{fields.to}`).
- **On items** (`AutomationButtons.swift`): the Send slot replaces Send in
  Slack; other buttons sit before Complete, ⋯ holds the rest. The run sheet
  shows the exact command and each argument, Run approves it, then the same
  sheet streams `collector.run.output` for the run with Stop; a success closes
  after 1.5 s, a failure keeps the stderr with Try again. A refusal for consent
  opens the automation. The Last run block sits under the body on Slack, Jira,
  Confluence and To do.
- **Swift model name.** The app already has a SwiftUI `ActionButton`, so the
  DistillKit model is `AutomationButton` (JSON is unchanged).
- Tests: `AutomationsTests` (decode, slots, settings round trip, routes and
  409 refusals, the commands patch).
- **Added 2026-10-06.** Activity: a run that approves its command (a first run,
  or after the command or script changed) logs `action.button_approved` before
  `action.button_run` (`runActionButton` returns `approved: true`); History →
  Activity shows Button, Action type and, for an approval, what was approved.
  Snapshot states for the board's frames in `SnapshotScriptActions.swift`:
  `sa-library`, `sa-slack-item`, `sa-slack-confirm`, `sa-slack-running`,
  `sa-slack-sent` (the sheet's finished state: a sent message leaves the list),
  `sa-slack-failed`, `sa-card-settings`, `sa-card-editor`, `sa-card-command`,
  `sa-card-todo`, `sa-card-add`; the prose cards have none. The to-do footer
  puts its buttons on their own row when the pane is too narrow for one.
- **What it does (2026-10-06).** Add automation starts with step 1, What it
  does: **Collect on a schedule** (then today's Kind, Source, Schedule),
  **Commands for buttons** (Source, then Commands) or **Both** (Source,
  Schedule, Commands). Commands and Both are scripts; Commands is created with
  `script.collects: false` (`NewCollectorInput.script.collects`, core and
  Swift), so it never collects on its own. The Commands step says where to
  declare them (the saved script's COMMANDS block); the sheet doesn't edit
  commands itself. `AutomationRole` (DistillKit) holds the steps and words.
  Snapshot states `sa-card-add` (Commands picked), `collectors-add` (step 1),
  `collectors-add-kind`, and the Commands path `collectors-add-commands-source`
  and `collectors-add-commands`. For Commands, the Source step's hint says the
  arguments come from buttons (not the vault and queue paths).
- **Argument rows (2026-10-06).** Each row is the name on one line (it never
  wraps), a grey note ("--thread value · optional, left out when empty",
  "required") and the template field. The field's placeholder is the hint,
  unless the hint only repeats the name (`text` for `text`), which showed the
  word twice; then it is "{a field} or text" (`ScriptCommandArg.editorNote`,
  `editorPlaceholder`). Snapshot state `sa-card-editor-empty`.
- **Ready to send (2026-10-06).** A ready Slack message reads "Ready to send"
  when a button holds the Send slot (and is on), not "Ready to paste"
  (`ActionTypeInfo.readyWords`): the row, the detail and the status filter.
- **Needs a recipient (2026-10-06, owner decision).** A ready Slack message whose
  To is a name Distill doesn't know yet, while an enabled button sends to
  `{fields.to}` (or `{recipient}`), reads **Needs a recipient** (peach) instead
  of "Ready to send": the row pill, the detail badge and the status filter,
  which lists it after the ready words when a button sends
  (`ActionTypeInfo.readyWords(for:)`, `ActionFacets.values(…, slackTarget:)`).
  A remembered name, a button that doesn't use the To field, or Copy keep
  "Ready to send"; other To problems (a group, a handle with spaces) keep their
  own words on the To row.

## Where to send (2026-10-06)

The owner's Send in Slack failed with `target: "Aditya Pradhan" isn't
#channel, @handle or an ID`: the extractor writes the name as written into
`fields.to`, and the button maps `target` to `{fields.to}`. Now:

- **The To row has a kind.** Channel (`#name` or a `C…`/`G…` ID), Person (a
  DM: `@handle` or a `U…`/`W…`/`D…` ID) or Thread (the `thread` field holds a
  Slack message link, `channel ts`, or a bare ts; a link's `thread_ts` wins).
  It reads "To [Person] Aditya Pradhan (@aditya) · direct message",
  "To [Channel] #general · channel" or "To [Thread] #eng · reply in its
  thread".
- **A plain name is never sent.** When a button on the type uses `{fields.to}`
  and the name isn't known, the card shows "Who is Aditya Pradhan in Slack?"
  with a field for the `@handle` or ID, and the button is off with the reason
  as its tooltip. The core refuses the run with the same plain words, before
  it builds any argument, so the pattern line never reaches the owner. Copy
  and paste still work with any name; a type with no such button shows no
  question.
- **Remembered names.** Save remembers name → target for the item's vault
  (else the active one) in `<state>/actions/slack-people.json`, keyed by the
  vault id (core state, not the vault: [User data](user-data.md)). Only an
  exact name matches, ignoring case and extra spaces ("Mei" is not "Mei
  Tanaka"). The next item for the same name resolves by itself. The To menu
  has Change who … is and Forget …. A bare lower-case handle gets its `@`;
  anything that isn't `#channel`, `@handle` or an ID is refused, and the field
  also checks the Send button's declared target pattern.
- **Templates.** For a Slack message, `{fields.to}` (and `{recipient}`) is the
  resolved target (a thread's channel for a link) and `{fields.thread}` is the
  ts. The item keeps the name as written.
- **Threads never become channel posts.** A Thread whose button doesn't use
  `{fields.thread}` is refused: "This message replies in a thread, but Send in
  Slack doesn't fill in a thread. Edit the button and set thread to
  {fields.thread}." A new button guesses `thread` → `{fields.thread}`.
- **Groups.** "Mei, Aditya" is refused ("A button sends to one person or one
  channel. Pick one."); the CLI can't send to a group.
- **Extractor.** The Slack type gains a `thread` field, and its description
  (always in the find prompt, also under an edited one) asks for channels as
  `#name` and a Slack message link in `thread` when the source has one.
- **Find in Slack: not built.** It would be offered only when the script
  declares a lookup command in its COMMANDS block. The owner's Slack CLI
  declares only `send`, so there is nothing to offer, and Distill doesn't
  invent one.
- **API.** `GET /v1/slack-people[?vault=]`, `PUT /v1/slack-people` `{name,
  target, vaultPath?}`, `POST /v1/slack-people/forget` `{name, vaultPath?}`,
  `GET /v1/actions/:id/slack-target`. Activity logs `action.slack_name_saved`
  and `action.slack_name_forgot`.
- **One rule, two places.** The core (`actions/slack-target.ts`) decides; the
  app mirrors it to draw the row and turn Send off early
  (`DistillKit/SlackTarget.swift`). Both test suites read
  `core/src/actions/slack-target.cases.json`.
- Tests: `slack-target.test.ts` (shared cases, links, typed handles, the
  store: per vault, change, forget, unreadable file set aside, unknown keys
  kept), `buttons.e2e.test.ts` (refusal in plain words, remember, the next
  item resolves, other vaults, forget; thread with and without
  `{fields.thread}`), `actions.test.ts` (the find prompt), and
  `SlackTargetTests` (shared cases, To row words, Send off, routes).
  Snapshot states `sa-to-unresolved`, `sa-to-resolved`, `sa-to-panel`,
  `sa-to-thread`, `sa-to-thread-off`.

## Open questions

- Find in Slack, once the CLI has a lookup command (`users`, or the
  `dms`/`channels` output parsed) and it is declared in COMMANDS.
- Buttons on Ask's "Found in this answer" rows. These rows are pending items,
  and buttons show only from `open` and `ready`, so not for now.
- Running one button on several selected items (the to-do bulk bar).
