# Meeting notes collector

`fetch_meeting_notes.py` downloads your meeting notes from Google, so Distill can
add them to your vault. It looks in two places:

1. Files attached to your Google Calendar events, such as Gemini's "Notes by
   Gemini" docs.
2. A Google Drive folder, by default **Meet Recordings**.

| Google file | Saved as |
|---|---|
| Google Docs | Markdown (`.md`) |
| Google Sheets | CSV (`.csv`) |
| Google Slides | PDF (`.pdf`) |
| Anything else (PDF, DOCX, …) | The file as it is |
| Meeting recordings (video, audio) | Skipped, unless you pass `--include-recordings` |

It downloads each file once. A file comes down again only if it has changed in
Google since the last run.

Your Google secrets stay in the macOS Keychain. No `credentials.json` or
`token.json` is left on disk.

Setup takes about 15 minutes, once:

1. [Create a Google Cloud project](#1-create-a-google-cloud-project)
2. [Install Python packages](#2-install-the-python-packages)
3. [Put the secrets in the Keychain](#3-put-the-secrets-in-the-keychain)
4. [Try a run by hand](#4-try-a-run-by-hand)
5. [Run it on a schedule](#5-run-it-on-a-schedule)

---

## 1. Create a Google Cloud project

The script needs its own OAuth client, a "Desktop app" ID that lets it ask you
for read-only access.

1. **Create a project.**
   1. Open <https://console.cloud.google.com/>.
   2. Sign in with the Google account whose meetings you want.
   3. In the project picker at the top, choose **New project**.
   4. Name it, for example `meeting-notes`, then choose **Create** and select
      the new project.
2. **Turn on the two APIs.** Go to **APIs & Services → Library**, then search
   for and **Enable** each of these:
   - **Google Calendar API**
   - **Google Drive API**
3. **Set up the consent screen.** Go to **APIs & Services → OAuth consent
   screen**. Newer consoles call it **Google Auth Platform → Branding /
   Audience**.
   1. **User type:**
      - Choose **Internal** if your account belongs to a Google Workspace
        organization (a work or school account) and the option is offered.
      - Otherwise choose **External**.
   2. Fill in the app name (for example `Meeting notes`), your email as the
      support email, and your email as the developer contact. Save.
   3. If you chose **External**: under **Test users** (or **Audience**), add
      your own Google address. Leave the app in **Testing**.
   4. **Scopes:** you can skip this page. The script asks for exactly these
      two, both read-only:
      - `https://www.googleapis.com/auth/calendar.readonly`
      - `https://www.googleapis.com/auth/drive.readonly`
4. **Create the OAuth client.**
   1. Go to **APIs & Services → Credentials → Create credentials → OAuth
      client ID** (newer consoles: **Clients → Create client**).
   2. Set **Application type** to **Desktop app**. Name it, then choose
      **Create**.
   3. Choose **Download JSON**. You'll have a file like
      `client_secret_1234….apps.googleusercontent.com.json` in Downloads.
      This is the `credentials.json` used in step 3.

> **External apps in Testing sign you out every 7 days.** Google expires their
> refresh tokens weekly, so the script will stop with "The Google sign-in
> expired" and you'll need to run `--login` again. There are two ways to avoid
> that:
> - Use an **Internal** app (Workspace accounts only).
> - Choose **Publish app** on the consent screen. Read-only scopes need no
>   Google review for personal use; you'll see an "unverified app" warning
>   when you sign in, which you can pass through.

## 2. Install the Python packages

Use the `python3` your login shell finds. That's the one Distill and your
schedule will run, and the Keychain trusts the exact program that saved the
secrets. Check it:

```sh
which python3      # e.g. /Library/Frameworks/Python.framework/Versions/3.13/bin/python3
python3 --version  # 3.9 or newer
```

Install the packages for that interpreter:

```sh
python3 -m pip install --user google-api-python-client google-auth-httplib2 google-auth-oauthlib keyring
```

## 3. Put the secrets in the Keychain

In the commands below, `SCRIPT` is the full path to `fetch_meeting_notes.py`
in this folder.

**Store the OAuth client.** This copies the downloaded JSON into the Keychain:

```sh
python3 SCRIPT --import-client ~/Downloads/client_secret_*.json
```

Once it prints `Stored the OAuth client in the Keychain`, delete the JSON file
from Downloads.

**Sign in, once.** This opens your browser:

```sh
python3 SCRIPT --login
```

1. Pick your account.
2. If you see "Google hasn't verified this app", choose **Continue**. It's
   your own app.
3. Allow read-only access to Calendar and Drive.

The script prints `Signed in. The token is in the Keychain.`

**What's in the Keychain:**
- **Service:** `distill.meeting-notes`, with two items:
  - `oauth-client`: your OAuth client.
  - `oauth-token`: your sign-in. The script refreshes it on each run and saves
    it back.
- **To see them:** open **Keychain Access**, choose the **login** keychain,
  and search for `distill.meeting-notes`. Or in Terminal:

  ```sh
  security find-generic-password -s distill.meeting-notes -a oauth-token >/dev/null && echo "signed in"
  ```

**If macOS asks whether `python3` may use the Keychain**, choose **Always
Allow**. This usually happens after Python was upgraded or reinstalled, because
the Keychain trusts the exact program that saved the item. If a scheduled run
can't show that prompt, it fails instead; run any command in Terminal once and
choose **Always Allow**.

**To sign out or start over:**

```sh
security delete-generic-password -s distill.meeting-notes -a oauth-token    # sign out
security delete-generic-password -s distill.meeting-notes -a oauth-client   # remove the OAuth client
```

You can also revoke the script's access at
<https://myaccount.google.com/permissions>.

## 4. Try a run by hand

Download the last 7 days into a test folder:

```sh
python3 SCRIPT --out ~/Desktop/meeting-notes-test
```

Each saved file prints as a `+ YYYY-MM-DD Name.md` line. Run it again and
nothing downloads, because nothing changed.

| Option | Default | Meaning |
|---|---|---|
| `--out DIR` | Distill's queue folder | Where files go |
| `--days N` | `7` | How far back to look |
| `--folder NAME` | `Meet Recordings` | Drive folder to scan, by name |
| `--match REGEX` | none | Only files whose name matches, e.g. `"Notes\|Minutes"` |
| `--include-recordings` | off | Also download video and audio recordings (often hundreds of MB each) |
| `--import-client FILE` | | Store the OAuth client in the Keychain |
| `--login` | | Sign in in the browser |

The script remembers what it downloaded in
`~/Library/Application Support/distill-meeting-notes/downloaded.json`. That's
outside the output folder on purpose, so Distill never adds it to your vault.
Delete the file to download everything again.

A scheduled run never opens a browser. If you aren't signed in, it stops with a
message telling you to run `--login` in Terminal.

## 5. Run it on a schedule

There are two ways. Use one, not both.

### Option A: as a Distill collector (recommended)

Distill runs the script on its schedule, and new notes land straight in its
queue.

1. Open **Distill → Collectors → New collector → Custom script**.
2. Fill in the collector:
   - **Script:** choose `fetch_meeting_notes.py` from this folder. Distill
     stores the path, so keep the file where it is.
   - **Interpreter:** `python3`.
   - **Schedule:** `*/15 * * * *`, which means every 15 minutes.
3. Allow it when Distill shows the script for review.
   - Distill remembers your OK for this exact version of the file. If you edit
     the script, it asks again.

**Use your own file, or paste a copy.** Choosing the file keeps the collector
on this file, so edits here reach it, after you allow the new version.
Pasting the code into Distill's editor gives the collector its own copy, so
later edits here don't reach it until you paste them again.

**Test run vs Run now.** Test run writes into a scratch folder that Distill
owns, so nothing reaches the queue. That's on purpose: it lets you see what
the script would add. The script doesn't remember files from a test run
(Distill tells it with `DISTILL_RUN_TRIGGER=test`), so the next **Run now**
or scheduled run downloads them into the queue.

How Distill runs it:

```text
python3 fetch_meeting_notes.py <vault> <queue folder>
```

- It runs as you, with your login shell's `PATH`, in a temporary folder.
- It is stopped after 5 minutes by default.
- With no `--out`, the script writes into the queue folder.
- Each run's output shows under the collector's runs.

**The Keychain when Distill runs it.** You don't set anything up in Distill.
Run step 3 once in Terminal, and every collector run reads the same Keychain
items. This works for three reasons:

- The run is you: Distill starts the script as your user, in your login
  session, so it opens the same **login** keychain.
- It finds the same Python: Distill picks `python3` from your login shell's
  `PATH`, which is the one step 3 used. Check which that is:

  ```sh
  zsh -lc 'which python3'   # must match the python3 you used in step 3
  ```

  If it differs, redo step 3 with that exact path, for example
  `/Library/Frameworks/Python.framework/Versions/3.13/bin/python3 SCRIPT --login`.
- It never needs a browser: a run only refreshes the token and saves it back
  to the Keychain.

To check it, choose **Run now** on the collector. If macOS asks whether
`python3` may use the Keychain, choose **Always Allow**. Otherwise later runs
wait on that prompt until Distill stops them after 5 minutes. If the run says
`Not signed in to Google` or `The Google sign-in expired`, run `--login` in
Terminal, then choose **Run now** again.

Distill can't pass extra options yet. To change `--days`, `--folder` or
`--match`, edit the defaults in `main()` in the script, then allow the new
version.

### Option B: as a plain cron job

Use this to collect notes into any folder without Distill.

1. Make a log folder:

   ```sh
   mkdir -p ~/Library/Logs/meeting-notes
   ```

2. Open your crontab with `crontab -e` and add one line. cron has an almost
   empty `PATH`, so use full paths, and put the line on one line:

   ```cron
   */15 * * * * /Library/Frameworks/Python.framework/Versions/3.13/bin/python3 /FULL/PATH/TO/fetch_meeting_notes.py --out "$HOME/MeetingNotes" >> "$HOME/Library/Logs/meeting-notes/cron.log" 2>&1
   ```

   - Replace the interpreter with your `which python3` output.
   - Replace the script path with the full path to this file.

3. Check it after 15 minutes:

   ```sh
   crontab -l                                      # the line is there
   tail -f ~/Library/Logs/meeting-notes/cron.log   # each run's output
   ```

Things to know about cron on macOS:
- **Login required:** cron runs only while you're logged in. The Keychain is
  locked otherwise, so a run fails with a Keychain error.
- **Protected folders:** writing to Desktop, Documents, Downloads or iCloud
  Drive needs **System Settings → Privacy & Security → Full Disk Access** for
  `/usr/sbin/cron`. A folder like `~/MeetingNotes` needs nothing.
- **Missed runs:** runs missed while the Mac sleeps are skipped, not caught up.
  The next run looks back `--days`, so nothing is lost.

## Troubleshooting

| Message | Fix |
|---|---|
| `No OAuth client in the Keychain` | Run `--import-client` (step 3). |
| `Not signed in to Google` | Run `--login` in Terminal. |
| `The Google sign-in expired` | Run `--login`. If this happens weekly, see the note in step 1. |
| `ModuleNotFoundError: No module named 'google'` or `'keyring'` | The packages went to another Python. Rerun step 2 with the `python3` the schedule uses. |
| `! cannot download '…'` | The owner turned off download or copy for viewers. Ask for access, or skip it with `--match`. |
| `(folder not found)` | No Drive folder has that exact name. Check `--folder`. |
| `Error 403: access_denied` on sign-in | Your address isn't a test user (step 1.3), or the APIs aren't enabled (step 1.2). |
| A Keychain prompt keeps coming back | Python's path changed. Choose **Always Allow**, or redo step 3 with the current `python3`. |
