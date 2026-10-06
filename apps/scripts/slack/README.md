# Slack CLI

`slack_cli.py` reads and sends Slack messages as **you**, using the same session
the Slack web app uses. It can only reach conversations your account can already
see. Distill will use it later to collect Slack messages into the vault.

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

The browser downloads `slack_c.json` to `~/Downloads`.

## 3. Put the credentials in the Keychain

```bash
cd apps/scripts/slack
python3 slack_cli.py import --delete-source
```

With no path, `import` looks for `./slack_c.json`, then
`~/Downloads/slack_c.json`. You can also give a path:
`python3 slack_cli.py import ~/Downloads/slack_c.json --delete-source`.

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
| `slack_c.json not found` | Run step 2 again, or pass the file's path to `import` |
| `SLACK_COOKIE must start with xoxd-` | You copied the wrong cookie. Copy the Value of the row named exactly `d` |
| `auth.test failed: invalid_auth` | The session ended (you logged out, or Slack expired it). Repeat steps 2 and 3 |
| `auth.test failed: not_authed` | The cookie is missing. Run `creds`, then repeat step 3 |
| `channel '#x' not found or you're not in it` | Join the channel in Slack, or use its `C…` ID |
| `the 'keyring' package is required` | Run step 1 |

Logging out of Slack in the browser ends this session too. Repeat steps 2 and 3
to get a new one.
