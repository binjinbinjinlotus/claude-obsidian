# Slack CLI

`slack_cli.py` reads and sends Slack messages as **you**, using the same session
the Slack web app uses. It can only reach conversations your account can already
see. Distill runs `send` from the **Send in Slack** button (section 5), and will
use it later to collect Slack messages into the vault.

Two files work together:

| File | Where it runs | What it does |
|---|---|---|
| `extract_slack_creds.js` | Your browser's DevTools console, in a logged-in Slack tab | Downloads `slack_c.json` with your token and cookie |
| `slack_cli.py` | Terminal | Loads `slack_c.json` into the macOS Keychain once, then reads and sends messages |

Your secrets stay in the macOS Keychain, under the service `slack_cli`. No
credentials file is left on disk.

> [!warning] Treat `slack_c.json` like a password
> The token and cookie give full access to your Slack account. Import the file
> and delete it straight away (`--delete-source` does both).

---

## 1. Install the Python packages

Once, with the same `python3` Distill will use:

```bash
python3 -m pip install --user requests keyring
python3 -m pip install --user python-dotenv   # optional, only for a .env file
```

## 2. Get your credentials from the browser

Slack needs two values together:

- **Token** (`xoxc-…`): the script reads it from the page for you.
- **`d` cookie** (`xoxd-…`): the browser hides it from page scripts, so you copy
  it by hand.

1. Open Slack in Chrome (`app.slack.com` or `your-workspace.slack.com`) and wait
   until the workspace has loaded.
2. Copy the cookie first:
   1. Open DevTools: **Cmd+Option+I**.
   2. Go to **Application → Storage → Cookies →** your Slack domain.
   3. Find the row named **`d`** and copy its **Value**. It starts with
      `xoxd-` and contains `%2F`, `%2B` or `%3D`. Copy it exactly as shown;
      do not decode it.
3. Go to the **Console** tab. If Chrome warns about pasting code, type
   `allow pasting` and press Enter.
4. Paste the whole of `extract_slack_creds.js` and press Enter.
5. If you are signed in to several workspaces, enter the number of the one you
   want.
6. When asked, paste the `d` cookie value.

The browser downloads `slack_c.json`, usually to `~/Downloads`. You can move or
rename it to anything you like; the next step takes its path.

## 3. Put the credentials in the Keychain

Give `import` the path to the JSON file. It can be in any folder and have any
name:

```bash
cd apps/scripts/slack
python3 slack_cli.py import ~/Downloads/slack_c.json --delete-source
python3 slack_cli.py import ~/secrets/work-slack.json        # any name works
```

`--delete-source` deletes the file once its contents are in the Keychain.

It checks the credentials with Slack and prints who you are:

```text
stored credentials in the keychain for Jin (U0123ABCD) in Acme
deleted /Users/you/Downloads/slack_c.json
```

Check at any time with:

```bash
python3 slack_cli.py creds
```

## 4. Use it

A **target** is `#channel`, `@user-handle`, or a raw ID (`C…`, `G…`, `D…`, `U…`).

| Command | What it does |
|---|---|
| `channels` | List the channels you are in |
| `dms` | List your DMs and group DMs |
| `history <target> [--limit N] [--all] [--days N]` | Messages from a channel or DM |
| `thread <target> <thread_ts>` | Every reply in a thread |
| `catchup <target> [--days N]` | New messages and new thread replies since your last `catchup` |
| `unread [--days N] [--mark]` | Unread messages across all channels and DMs |
| `send <target> "<text>" [--thread TS]` | Post a message, or reply in a thread |
| `mark <target> [--ts TS]` | Mark a conversation read |
| `creds` | Show where the credentials come from and who you are |
| `logout` | Remove the credentials from the Keychain |

Examples:

```bash
python3 slack_cli.py history '#general' --days 7
python3 slack_cli.py thread '#general' 1759600000.123456
python3 slack_cli.py catchup '#team-standup' --days 3
python3 slack_cli.py unread --days 2
python3 slack_cli.py send @alex "Notes are in the vault" --thread 1759600000.123456
```

Each message prints as `[date time] name: text  (ts …)`. Use the `ts` value for
`thread`, `send --thread` and `mark --ts`.

### Reading never marks anything read

`history`, `thread`, `catchup` and `unread` only read. Your read state in Slack
changes only when you run `mark` or `unread --mark`.

`catchup` remembers where it stopped in a local file,
`~/.slack_cli_state.json` (change it with `SLACK_CLI_STATE`). That file is not
Slack's read state.

## 5. Send from Distill (the Send in Slack button)

Distill can run `send` for a Slack message under **Actions**. Distill passes
no Slack secret: the script reads its own Keychain item. Finish steps 1–3
first (`python3 slack_cli.py creds` prints your name).

### 5.1 Add the automation

**Automations → Add a script → Custom script → Continue**, then:

| Field | Value |
|---|---|
| Name | `Slack CLI` |
| Your script | **Your own file** |
| File (Choose…) | the full path to `apps/scripts/slack/slack_cli.py` in your checkout (in the file picker, **⌘⇧G** and paste it) |
| Run with | Python (`python3`) |

Click **Add**, open the new **Slack CLI** automation and give it your **OK**.
A button can't run it until you do. Under **COMMANDS**, turn **Collect on a
schedule** off. The card then says "Off: it only runs from buttons."

### 5.2 Add the `send` command

On the Slack CLI automation, **COMMANDS → Add command**. Add four arguments
in this order. Use **↑** to move a row up.

| # | Kind | Name | Value / flag | Required | Pattern | Hint |
|---|---|---|---|---|---|---|
| 1 | Word | `word` (any name) | `send` | — | — | — |
| 2 | Flag | `thread` | `--thread` | off | *empty* | *empty* |
| 3 | Value | `target` | — | on | `^(#\S+\|@\S+\|[CGDUW][A-Z0-9]+)$` | `#channel, @handle or an ID` |
| 4 | Value | `text` | — | on | *empty* | *empty* |

(In the pattern, `\|` is only Markdown table escaping. Type a plain `|`.)

Then:

| Field | Value |
|---|---|
| Name | `send` |
| Put "--" before the values | on |
| Timeout | 60 s |
| The last JSON line it prints | off (the CLI doesn't print JSON) |
| Key pattern | `ts ([0-9]+\.[0-9]+)\)` (the grey text is only a placeholder; type it) |
| Link pattern | *empty* (the CLI prints no link) |

Before you save, **Shows as** must read:

```text
send --thread <thread>? -- <target> <text>
```

If `<target>` is missing, or the pattern is on the `thread` row, fix it first.
A pattern on `thread` blocks every thread reply, and a missing target means
Slack gets no recipient.

The key pattern reads the ts from the line `send` prints
(`sent to #general (channel, ts 1759600000.123456)`) and saves it on the item.

### 5.3 Add the button

**Settings → Actions → Slack message → Buttons → New button**, or **＋ Button**
on a Slack message item:

| Field | Value |
|---|---|
| Label | `Send in Slack` |
| Runs | `Slack CLI › send` |
| `thread` | `{fields.thread}` (the ts of the thread to reply in; left out when the message has none) |
| `target` | `{fields.to}` |
| `text` | `{body}` |
| When it works | **Mark it sent** |
| Save the key or link it prints on the item | on |
| Ask before running | off (on shows the command every time) |
| Show it as | **The Send button** |

The preview should look like:

```text
python3 …/apps/scripts/slack/slack_cli.py send -- @mei.tanaka 'Hi Mei, …'
```

### 5.4 Send

1. Open a Slack message under **Actions**. The **To** row says where it goes:
   a channel, a person, or a thread. If it holds a plain name like "Mei
   Tanaka", it asks **Who is Mei Tanaka in Slack?**: type their `@handle` or
   `U…` ID and click **Save**. Distill remembers it for this vault, so the
   next message to the same name finds them (the To menu has **Change who …
   is** and **Forget …**). Until then **Send in Slack** is off. To reply in a
   thread, paste the message's Slack link in the To menu.
2. Click **Send in Slack**. The first run, and the first run after any change,
   shows the exact command. Approve it.
3. When it works, the item becomes **sent** and keeps the message `ts` as its
   key. If it fails, the run shows Slack's error (for example
   `channel '#x' not found`) and the item stays as it was.

> [!note] Formatting
> `{body}` is sent as Markdown, so `**bold**` arrives in Slack with the
> asterisks. Write Slack's own marks (`*bold*`, `~strike~`) in the message
> for now.

## Where credentials come from

Every run looks in this order:

1. The macOS Keychain (service `slack_cli`)
2. The `SLACK_TOKEN` and `SLACK_COOKIE` environment variables, or a `.env` file
   in the current folder if `python-dotenv` is installed

`SLACK_COOKIE` can be the encoded value from DevTools, a decoded value, or
`d=xoxd-…`. The CLI always sends it encoded, the way the browser does.

## Troubleshooting

| Message | What to do |
|---|---|
| `<path> not found` | Check the path you gave `import`, or run step 2 again |
| `SLACK_COOKIE must start with xoxd-` | You copied the wrong cookie. Copy the Value of the row named exactly `d` |
| `auth.test failed: invalid_auth` | The session ended (you logged out, or Slack expired it). Repeat steps 2 and 3 |
| `auth.test failed: not_authed` | The cookie is missing. Run `creds`, then repeat step 3 |
| `channel '#x' not found or you're not in it` | Join the channel in Slack, or use its `C…` ID |
| `the 'keyring' package is required` | Run step 1 |

Logging out of Slack in the browser ends this session too. Repeat steps 2 and 3
to get a new one.
