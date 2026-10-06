#!/usr/bin/env python3
"""
slack_cli.py — read and send Slack messages using your own browser session token.

Auth model: this uses the *user* token (xoxc-...) that the Slack web app itself
uses, together with the `d` cookie (xoxd-...). The Web API rejects an xoxc token
unless the matching cookie is sent, so both are required. Everything runs as *you*
and can only touch conversations your account already has access to.

Getting the credentials: run extract_slack_creds.js (next to this file) in the
DevTools console of a logged-in Slack tab. It downloads slack_c.json.

Credentials: store them once in your OS keychain, then forget about them.
  python3 slack_cli.py import ~/Downloads/slack_c.json --delete-source
  python3 slack_cli.py creds                     # show which store is in use + who you are
  python3 slack_cli.py logout                    # remove creds from the keychain
Resolution order every run: keychain -> SLACK_TOKEN/SLACK_COOKIE env vars.

IMPORTANT — read state:
  Fetching NEVER marks anything as read. conversations.history / .replies do not
  move your read cursor. Read state only changes when you run `mark` (or pass
  --mark to `unread`). The `catchup` checkpoint is a local file, separate from
  Slack's read state — catching up does not mark anything read either.

Setup:
    pip3 install requests keyring
    pip3 install python-dotenv          # optional, only if you prefer a .env file

Commands:
    import  [path] [--delete-source]  load SLACK_TOKEN/SLACK_COOKIE from JSON into keychain
    creds                             show credential source and your identity
    logout                            delete stored credentials from the keychain
    channels                          list channels you're in
    dms                               list your DMs and group DMs
    history <target> [opts]           fetch messages from a channel/DM
    thread  <target> <thread_ts>      fetch every reply in a thread
    catchup <target> [--days N]       new msgs + new thread replies since last check
    unread  [--days N] [--mark]       scan everything for unread messages
    send    <target> <text> [--thread TS]   post a message (optionally into a thread)
    mark    <target> [--ts TS]        mark a conversation read (up to TS, else latest)

Targets: '#channel', '@user', or a raw ID (C…/G…/D…/U…).
"""

import argparse
import json
import os
import sys
import time
from urllib.parse import quote

import requests

try:
    from dotenv import load_dotenv
    load_dotenv()
except ImportError:
    pass  # dotenv is optional

BASE = "https://slack.com/api"
STATE_PATH = os.environ.get("SLACK_CLI_STATE",
                            os.path.expanduser("~/.slack_cli_state.json"))
KEYCHAIN_SERVICE = "slack_cli"
CRED_KEYS = ("SLACK_TOKEN", "SLACK_COOKIE")
CREDS_FILE = "slack_c.json"


class SlackError(RuntimeError):
    pass


def normalize_cookie(cookie):
    """Return the `d` cookie value as the browser sends it: URL-encoded, no `d=`.

    DevTools shows it encoded (xoxd-...%2F...%3D). A value that was decoded
    somewhere along the way contains raw / + = and is re-encoded here, so
    either form works.
    """
    if not cookie:
        return cookie
    value = cookie.strip()
    if value.startswith("d="):
        value = value[2:]
    if "%" not in value:
        value = quote(value, safe="")
    return value


def default_creds_path():
    """slack_c.json in the current directory, else the browser's Downloads."""
    if os.path.exists(CREDS_FILE):
        return CREDS_FILE
    return os.path.expanduser(os.path.join("~", "Downloads", CREDS_FILE))


# --------------------------------------------------------------------------
# Keychain-backed credentials (via the cross-platform `keyring` package:
# macOS Keychain, Windows Credential Locker, Linux Secret Service).
# --------------------------------------------------------------------------

def _get_keyring():
    try:
        import keyring
        return keyring
    except ImportError:
        return None


def store_credentials(token: str, cookie: str):
    kr = _get_keyring()
    if kr is None:
        raise SlackError("the 'keyring' package is required for the keychain: pip3 install keyring")
    kr.set_password(KEYCHAIN_SERVICE, "SLACK_TOKEN", token)
    kr.set_password(KEYCHAIN_SERVICE, "SLACK_COOKIE", cookie)


def clear_credentials() -> bool:
    kr = _get_keyring()
    if kr is None:
        return False
    removed = False
    for key in CRED_KEYS:
        try:
            kr.delete_password(KEYCHAIN_SERVICE, key)
            removed = True
        except Exception:
            pass  # not present is fine
    return removed


def load_from_keychain():
    kr = _get_keyring()
    if kr is None:
        return None, None
    try:
        return (kr.get_password(KEYCHAIN_SERVICE, "SLACK_TOKEN"),
                kr.get_password(KEYCHAIN_SERVICE, "SLACK_COOKIE"))
    except Exception:
        return None, None


def resolve_credentials(token=None, cookie=None):
    """Return (token, cookie, source). Order: explicit args -> keychain -> env."""
    if token and cookie:
        return token, cookie, "args"
    kt, kc = load_from_keychain()
    if kt and kc:
        return kt, kc, "keychain"
    et, ec = os.environ.get("SLACK_TOKEN"), os.environ.get("SLACK_COOKIE")
    if et and ec:
        return et, ec, "env"
    # best-effort mix if only one store is partial
    return (token or kt or et, cookie or kc or ec, "none")


def read_creds_json(path: str):
    """Read the slack_c.json that extract_slack_creds.js downloads.

    Returns (token, cookie, meta); meta is the optional `_meta` block
    (team, url, user_id, exported_at).
    """
    try:
        with open(path) as f:
            data = json.load(f)
    except FileNotFoundError:
        raise SlackError(f"{path} not found. Run extract_slack_creds.js in the Slack tab first.")
    except json.JSONDecodeError as e:
        raise SlackError(f"{path} is not valid JSON: {e}")
    token = (data.get("SLACK_TOKEN") or "").strip()
    cookie = normalize_cookie(data.get("SLACK_COOKIE") or "")
    if not token or not cookie:
        raise SlackError(f"{path} must contain SLACK_TOKEN and SLACK_COOKIE keys")
    if not token.startswith("xoxc-"):
        raise SlackError(f"{path}: SLACK_TOKEN must start with xoxc-")
    if not cookie.startswith("xoxd-"):
        raise SlackError(f"{path}: SLACK_COOKIE must start with xoxd- (copy the `d` cookie's Value)")
    return token, cookie, data.get("_meta") or {}


# --------------------------------------------------------------------------
# Local checkpoint state (for `catchup`). NOT Slack read state.
# --------------------------------------------------------------------------

def _load_state() -> dict:
    try:
        with open(STATE_PATH, "r") as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def _save_state(state: dict):
    tmp = STATE_PATH + ".tmp"
    with open(tmp, "w") as f:
        json.dump(state, f, indent=2)
    os.replace(tmp, STATE_PATH)


class SlackClient:
    def __init__(self, token=None, cookie=None):
        self.token, self.cookie, self.cred_source = resolve_credentials(token, cookie)
        if not self.token or not self.token.startswith("xoxc-"):
            raise SlackError(
                "No valid xoxc- token found. Store one with: "
                "python3 slack_cli.py import slack_c.json  (or set SLACK_TOKEN)."
            )
        if not self.cookie:
            raise SlackError(
                "No `d` cookie found. Store one with: "
                "python3 slack_cli.py import slack_c.json  (or set SLACK_COOKIE)."
            )
        d_value = normalize_cookie(self.cookie)
        self.session = requests.Session()
        self.session.headers.update({"Authorization": f"Bearer {self.token}"})
        self.session.cookies.set("d", d_value, domain=".slack.com")

        self._name_to_channel = {}
        self._id_to_channel_name = {}
        self._id_to_user_name = {}
        self._handles = {}
        self._dm_conversations = []
        self._channels_loaded = False
        self._users_loaded = False

        self.user_id = self._call("auth.test")["user_id"]

    # ---- transport -----------------------------------------------------

    def _call(self, method, http="POST", **params):
        url = f"{BASE}/{method}"
        params = {k: v for k, v in params.items() if v is not None}
        for _ in range(6):
            if http == "GET":
                resp = self.session.get(url, params=params, timeout=30)
            else:
                resp = self.session.post(url, data=params, timeout=30)
            if resp.status_code == 429:
                time.sleep(int(resp.headers.get("Retry-After", "2")))
                continue
            resp.raise_for_status()
            data = resp.json()
            if not data.get("ok"):
                raise SlackError(f"{method} failed: {data.get('error', data)}")
            return data
        raise SlackError(f"{method}: still rate-limited after retries")

    def _paginate(self, method, key, http="GET", **params):
        cursor = ""
        while True:
            data = self._call(method, http=http, cursor=cursor or None, **params)
            for item in data.get(key, []):
                yield item
            cursor = data.get("response_metadata", {}).get("next_cursor", "")
            if not cursor:
                break

    # ---- lookups -------------------------------------------------------

    def _load_channels(self):
        if self._channels_loaded:
            return
        for ch in self._paginate(
            "users.conversations", "channels",
            types="public_channel,private_channel",
            exclude_archived="true", limit=1000,
        ):
            self._name_to_channel[ch["name"]] = ch["id"]
            self._id_to_channel_name[ch["id"]] = ch["name"]
        self._channels_loaded = True

    def _load_users(self):
        if self._users_loaded:
            return
        for u in self._paginate("users.list", "members", limit=1000):
            prof = u.get("profile", {})
            display = prof.get("display_name") or prof.get("real_name") or u.get("name")
            self._id_to_user_name[u["id"]] = display or u["id"]
            if u.get("name"):
                self._handles[u["name"]] = u["id"]
        self._users_loaded = True

    def display_name(self, user_id):
        if not user_id:
            return "?"
        if user_id in self._id_to_user_name:
            return self._id_to_user_name[user_id]
        try:
            info = self._call("users.info", http="GET", user=user_id)
            prof = info["user"].get("profile", {})
            name = (prof.get("display_name") or prof.get("real_name")
                    or info["user"].get("name") or user_id)
            self._id_to_user_name[user_id] = name
            return name
        except SlackError:
            return user_id

    def resolve_channel(self, target):
        target = target.strip()
        if target.startswith("#"):
            self._load_channels()
            name = target[1:]
            if self._name_to_channel.get(name) is None:
                raise SlackError(f"channel '{target}' not found or you're not in it")
            return self._name_to_channel[name]
        if target.startswith("@") or (target[:1] in ("U", "W") and " " not in target):
            if target.startswith("@"):
                self._load_users()
                uid = self._handles.get(target[1:])
                if not uid:
                    raise SlackError(f"user '{target}' not found")
            else:
                uid = target
            return self._call("conversations.open", users=uid)["channel"]["id"]
        return target

    def label_for(self, channel_id):
        if channel_id in self._id_to_channel_name:
            return "#" + self._id_to_channel_name[channel_id]
        for conv in self._dm_conversations:
            if conv["id"] == channel_id:
                return conv["label"]
        return channel_id

    # ---- listings ------------------------------------------------------

    def list_channels(self):
        self._load_channels()
        return sorted((n, c) for n, c in self._name_to_channel.items() if c)

    def list_dms(self):
        if self._dm_conversations:
            return self._dm_conversations
        out = []
        for conv in self._paginate(
            "users.conversations", "channels",
            types="im,mpim", exclude_archived="true", limit=1000,
        ):
            if conv.get("is_im"):
                label = "@" + self.display_name(conv["user"])
            else:
                label = conv.get("name", conv["id"])
            out.append({"id": conv["id"], "label": label})
        self._dm_conversations = out
        return out

    # ---- message fetching ----------------------------------------------

    def history(self, target, limit=50, fetch_all=False, oldest=None, latest=None):
        return self._history_by_id(self.resolve_channel(target), limit, fetch_all, oldest, latest)

    def _history_by_id(self, channel, limit=50, fetch_all=False, oldest=None, latest=None):
        if fetch_all:
            msgs = list(self._paginate(
                "conversations.history", "messages",
                channel=channel, limit=1000, oldest=oldest, latest=latest,
            ))
        else:
            data = self._call("conversations.history", http="GET",
                              channel=channel, limit=limit, oldest=oldest, latest=latest)
            msgs = data.get("messages", [])
        return list(reversed(msgs))

    def thread(self, target, thread_ts, fetch_all=True):
        channel = target if target.startswith(("C", "G", "D")) else self.resolve_channel(target)
        if fetch_all:
            return list(self._paginate(
                "conversations.replies", "messages",
                channel=channel, ts=thread_ts, limit=1000,
            ))
        data = self._call("conversations.replies", http="GET",
                          channel=channel, ts=thread_ts, limit=200)
        return data.get("messages", [])

    def catchup(self, target, days=None):
        channel = self.resolve_channel(target)
        state = _load_state()
        key = f"catchup:{channel}"
        since = state.get(key)
        if since is None and days is not None:
            since = f"{time.time() - days * 86400:.6f}"

        parents = self._history_by_id(channel, fetch_all=True, oldest=since)
        results = []
        newest_ts = since or "0"
        for m in parents:
            results.append(("msg", m))
            if m.get("ts", "0") > newest_ts:
                newest_ts = m["ts"]
            if m.get("reply_count") and m.get("latest_reply", "0") > (since or "0"):
                for r in self.thread(channel, m["ts"]):
                    if r.get("ts") == m.get("ts"):
                        continue
                    if since is None or r.get("ts", "0") > since:
                        results.append(("reply", r))
                        if r.get("ts", "0") > newest_ts:
                            newest_ts = r["ts"]

        if newest_ts and newest_ts != "0":
            state[key] = newest_ts
            _save_state(state)
        return results

    # ---- unread --------------------------------------------------------

    def unread(self, days=None, do_mark=False):
        self._load_channels()
        conversations = [(cid, "#" + name)
                         for cid, name in self._id_to_channel_name.items()]
        for conv in self.list_dms():
            conversations.append((conv["id"], conv["label"]))

        window = f"{time.time() - days * 86400:.6f}" if days else None
        out = []
        for cid, label in conversations:
            try:
                info = self._call("conversations.info", http="GET", channel=cid)
            except SlackError:
                continue
            last_read = info.get("channel", {}).get("last_read", "0")
            oldest = last_read
            if window and window > oldest:
                oldest = window
            if oldest == "0":
                oldest = window

            msgs = self._history_by_id(cid, fetch_all=True, oldest=oldest)
            msgs = [m for m in msgs
                    if m.get("user") != self.user_id and m.get("ts", "0") > last_read]
            if msgs:
                out.append((label, cid, msgs))

        if do_mark:
            for _, cid, msgs in out:
                self.mark_by_id(cid, msgs[-1]["ts"])
        return out

    # ---- write actions -------------------------------------------------

    def send(self, target, text, thread_ts=None):
        channel = self.resolve_channel(target)
        return self._call("chat.postMessage", channel=channel, text=text, thread_ts=thread_ts)

    def mark(self, target, ts=None):
        channel = self.resolve_channel(target)
        if ts is None:
            latest = self._history_by_id(channel, limit=1)
            if not latest:
                raise SlackError("nothing to mark; channel is empty")
            ts = latest[-1]["ts"]
        return self.mark_by_id(channel, ts)

    def mark_by_id(self, channel, ts):
        return self._call("conversations.mark", channel=channel, ts=ts)


def _fmt_ts(ts):
    try:
        return time.strftime("%Y-%m-%d %H:%M", time.localtime(float(ts)))
    except (TypeError, ValueError):
        return ""


def _print_messages(client, messages, kinds=None):
    for i, m in enumerate(messages):
        who = client.display_name(m.get("user", "")) if m.get("user") else m.get("username", "?")
        text = (m.get("text", "") or "").replace("\n", " ")
        prefix = ("  ↳ " if kinds[i] == "reply" else "") if kinds else ""
        print(f"{prefix}[{_fmt_ts(m.get('ts',''))}] {who}: {text}  (ts {m.get('ts','')})")


def main(argv=None):
    p = argparse.ArgumentParser(description="Read and send Slack messages with your session token.")
    sub = p.add_subparsers(dest="cmd", required=True)

    imp = sub.add_parser("import", help="load creds from JSON into the OS keychain")
    imp.add_argument("path", nargs="?", default=None,
                     help="JSON from extract_slack_creds.js "
                          "(default: ./slack_c.json, else ~/Downloads/slack_c.json)")
    imp.add_argument("--delete-source", action="store_true",
                     help="delete the JSON file after a successful import")
    sub.add_parser("creds", help="show credential source and your Slack identity")
    sub.add_parser("logout", help="remove stored credentials from the keychain")

    sub.add_parser("channels", help="list channels you belong to")
    sub.add_parser("dms", help="list your DMs and group DMs")

    h = sub.add_parser("history", help="fetch messages from a channel/DM")
    h.add_argument("target")
    h.add_argument("--limit", type=int, default=50)
    h.add_argument("--all", action="store_true", help="fetch the full history (paginates)")
    h.add_argument("--days", type=int, help="only messages from the last N days")

    t = sub.add_parser("thread", help="fetch every reply in a thread")
    t.add_argument("target")
    t.add_argument("thread_ts")

    c = sub.add_parser("catchup", help="new msgs + thread replies since last check (local checkpoint)")
    c.add_argument("target")
    c.add_argument("--days", type=int, help="on first run, look back N days")

    u = sub.add_parser("unread", help="scan all channels + DMs for unread messages")
    u.add_argument("--days", type=int, help="limit to the last N days")
    u.add_argument("--mark", action="store_true", help="mark scanned conversations read afterward")

    s = sub.add_parser("send", help="post a message")
    s.add_argument("target")
    s.add_argument("text")
    s.add_argument("--thread", dest="thread_ts", help="thread_ts to reply into")

    m = sub.add_parser("mark", help="mark a conversation read")
    m.add_argument("target")
    m.add_argument("--ts", help="mark read up to this ts (default: latest message)")

    args = p.parse_args(argv)

    try:
        # --- credential management: handled before building a client ----
        if args.cmd == "import":
            path = os.path.expanduser(args.path) if args.path else default_creds_path()
            token, cookie, meta = read_creds_json(path)
            store_credentials(token, cookie)
            team = f" in {meta['team']}" if meta.get("team") else ""
            try:
                who = SlackClient(token=token, cookie=cookie)
                print(f"stored credentials in the keychain for "
                      f"{who.display_name(who.user_id)} ({who.user_id}){team}")
            except SlackError as e:
                print(f"stored in keychain, but live verification failed: {e}",
                      file=sys.stderr)
            if args.delete_source:
                os.remove(path)
                print(f"deleted {path}")
            return

        if args.cmd == "logout":
            if clear_credentials():
                print("removed Slack credentials from the keychain")
            else:
                print("no stored credentials to remove (or keyring not installed)")
            return

        if args.cmd == "creds":
            tok, ck, source = resolve_credentials()
            if not (tok and ck):
                print("no credentials found. Run: python3 slack_cli.py import slack_c.json")
                return
            client = SlackClient()
            print(f"source: {client.cred_source}")
            print(f"user:   {client.display_name(client.user_id)} ({client.user_id})")
            return

        # --- everything else needs a live client -----------------------
        client = SlackClient()

        if args.cmd == "channels":
            for name, cid in client.list_channels():
                print(f"{cid}\t#{name}")

        elif args.cmd == "dms":
            for conv in client.list_dms():
                print(f"{conv['id']}\t{conv['label']}")

        elif args.cmd == "history":
            days = getattr(args, "days", None)
            oldest = f"{time.time() - days*86400:.6f}" if days else None
            msgs = client.history(args.target, limit=args.limit,
                                  fetch_all=args.all or bool(days), oldest=oldest)
            _print_messages(client, msgs)

        elif args.cmd == "thread":
            _print_messages(client, client.thread(args.target, args.thread_ts))

        elif args.cmd == "catchup":
            results = client.catchup(args.target, days=args.days)
            if not results:
                print("(nothing new since last check)")
            else:
                kinds = [k for k, _ in results]
                _print_messages(client, [m for _, m in results], kinds=kinds)

        elif args.cmd == "unread":
            found = client.unread(days=args.days, do_mark=args.mark)
            if not found:
                print("(no unread messages)")
            for label, _cid, msgs in found:
                print(f"\n== {label} — {len(msgs)} unread ==")
                _print_messages(client, msgs)
            if args.mark and found:
                print("\n(marked the above conversations as read)")

        elif args.cmd == "send":
            res = client.send(args.target, args.text, thread_ts=args.thread_ts)
            where = "thread" if args.thread_ts else "channel"
            print(f"sent to {client.label_for(res['channel'])} ({where}, ts {res['ts']})")

        elif args.cmd == "mark":
            res = client.mark(args.target, ts=args.ts)
            print(f"marked read up to ts {res.get('ts', args.ts)}")

    except SlackError as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
