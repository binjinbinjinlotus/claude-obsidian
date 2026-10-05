#!/usr/bin/env python3
"""
fetch_meeting_notes.py: a Distill collector that pulls meeting notes from Google.

Downloads meeting notes from two places:
  1. Files attached to your Google Calendar events (e.g. "Notes by Gemini" docs)
  2. Files in a Google Drive folder (default: "Meet Recordings")

Google Docs are exported as Markdown, Sheets as CSV, Slides as PDF.
Regular files (PDF, DOCX, ...) are downloaded as-is. Meeting recordings
(video and audio) are skipped unless you pass --include-recordings. Files already downloaded
are skipped unless they changed since the last run.

Secrets live in the macOS Keychain, not in files:
  - the OAuth client (the contents of credentials.json)
  - the OAuth token (refreshed automatically)
Both are under the service "distill.meeting-notes".

Full setup (Google Cloud project, Keychain, schedules): see README.md here.

One-time setup (in Terminal, with the same python3 Distill will use):
  python3 -m pip install --user google-api-python-client google-auth-httplib2 google-auth-oauthlib keyring
  python3 fetch_meeting_notes.py --import-client ~/Downloads/credentials.json   # then delete that file
  python3 fetch_meeting_notes.py --login                                        # opens the browser once

As a Distill collector (Custom script, python3, from this file):
  Distill runs it as:  fetch_meeting_notes.py <vault> <queue folder>
  New notes are written straight into the queue folder.

By hand:
  python3 fetch_meeting_notes.py --out ~/MeetingNotes --days 30
  python3 fetch_meeting_notes.py --match "Notes|Minutes" --folder "Meetings"
"""
import argparse
import datetime as dt
import io
import json
import os
import re
import sys
from pathlib import Path

import keyring
from google.auth.transport.requests import Request
from google.oauth2.credentials import Credentials
from google_auth_oauthlib.flow import InstalledAppFlow
from googleapiclient.discovery import build
from googleapiclient.errors import HttpError
from googleapiclient.http import MediaIoBaseDownload

SCOPES = [
    "https://www.googleapis.com/auth/calendar.readonly",
    "https://www.googleapis.com/auth/drive.readonly",
]
KEYCHAIN_SERVICE = "distill.meeting-notes"
KC_CLIENT = "oauth-client"
KC_TOKEN = "oauth-token"

# Where we remember what was downloaded. It must persist between runs, and it
# must not be the queue folder, whose files move into the vault after a batch.
STATE_DIR = Path(
    os.environ.get("DISTILL_COLLECTOR_STATE")
    or Path.home() / "Library/Application Support/distill-meeting-notes"
)

# A Distill Test run writes into a scratch folder, so it must not mark files as
# downloaded; otherwise the next real run would find nothing new.
TEST_RUN = os.environ.get("DISTILL_RUN_TRIGGER") == "test"

# Google-native types -> (export mime type, file extension)
EXPORTS = {
    "application/vnd.google-apps.document": ("text/markdown", ".md"),
    "application/vnd.google-apps.spreadsheet": ("text/csv", ".csv"),
    "application/vnd.google-apps.presentation": ("application/pdf", ".pdf"),
}


# ── Keychain ─────────────────────────────────────────────────────────────────

def kc_get(account):
    return keyring.get_password(KEYCHAIN_SERVICE, account)


def kc_set(account, value):
    keyring.set_password(KEYCHAIN_SERVICE, account, value)


def import_client(path):
    data = Path(path).expanduser().read_text()
    json.loads(data)  # fail early on a bad file
    kc_set(KC_CLIENT, data)
    print(f"Stored the OAuth client in the Keychain ({KEYCHAIN_SERVICE}). You can delete {path} now.")


def login():
    client = kc_get(KC_CLIENT)
    if not client:
        sys.exit("No OAuth client in the Keychain. Run with --import-client credentials.json first.")
    flow = InstalledAppFlow.from_client_config(json.loads(client), SCOPES)
    creds = flow.run_local_server(port=0)
    kc_set(KC_TOKEN, creds.to_json())
    print("Signed in. The token is in the Keychain.")


def get_creds():
    """Token from the Keychain, refreshed when expired. Never opens a browser."""
    raw = kc_get(KC_TOKEN)
    if not raw:
        sys.exit("Not signed in to Google. In Terminal, run: python3 fetch_meeting_notes.py --login")
    creds = Credentials.from_authorized_user_info(json.loads(raw), SCOPES)
    if not creds.valid:
        if creds.expired and creds.refresh_token:
            creds.refresh(Request())
            kc_set(KC_TOKEN, creds.to_json())
        else:
            sys.exit("The Google sign-in expired. In Terminal, run: python3 fetch_meeting_notes.py --login")
    return creds


# ── Downloading ──────────────────────────────────────────────────────────────

def safe(name):
    return re.sub(r'[\\/:*?"<>|]+', "_", name).strip()[:150]


def load_state(path):
    return json.loads(path.read_text()) if path.exists() else {}


def save_state(path, state):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(state, indent=2))
    tmp.replace(path)  # atomic, so a killed run never leaves half a file


def download(drive, file_id, out_dir, state, prefix="", recordings=False):
    """Download or export one Drive file. Returns True if a file was written."""
    try:
        meta = drive.files().get(
            fileId=file_id, fields="id,name,mimeType,modifiedTime", supportsAllDrives=True
        ).execute()
    except HttpError as e:
        print(f"  ! cannot read {file_id}: {e.reason}")
        return False

    if state.get(file_id) == meta["modifiedTime"]:
        return False  # unchanged since last run

    mime = meta["mimeType"]
    if not recordings and mime.startswith(("video/", "audio/")):
        return False  # recordings are large and have no text to distill
    if mime in EXPORTS:
        export_mime, ext = EXPORTS[mime]
        request = drive.files().export_media(fileId=file_id, mimeType=export_mime)
    elif mime.startswith("application/vnd.google-apps"):
        return False  # folders, forms, shortcuts: nothing to download
    else:
        ext = ""  # regular files already carry their extension
        request = drive.files().get_media(fileId=file_id, supportsAllDrives=True)

    path = out_dir / f"{prefix}{safe(meta['name'])}{ext}"
    try:
        buf = io.BytesIO()
        downloader = MediaIoBaseDownload(buf, request)
        done = False
        while not done:
            _, done = downloader.next_chunk()
        # Write under a hidden name, then rename, so Distill never sees half a file.
        part = out_dir / f".{path.name}.part"
        part.write_bytes(buf.getvalue())
        part.replace(path)
    except HttpError as e:
        # Common cause: the owner disabled download/copy for viewers
        print(f"  ! cannot download '{meta['name']}': {e.reason}")
        return False

    state[file_id] = meta["modifiedTime"]
    print(f"  + {path.name}")
    return True


def from_calendar(cal, drive, since, until, match, out_dir, state, recordings):
    print("Calendar attachments:")
    page = None
    while True:
        resp = cal.events().list(
            calendarId="primary",
            timeMin=since.isoformat(),
            timeMax=until.isoformat(),
            singleEvents=True,
            orderBy="startTime",
            pageToken=page,
            fields="nextPageToken,items(summary,start,attachments)",
        ).execute()
        for ev in resp.get("items", []):
            day = (ev["start"].get("dateTime") or ev["start"].get("date"))[:10]
            for att in ev.get("attachments", []):
                if match and not re.search(match, att.get("title", ""), re.I):
                    continue
                if att.get("fileId"):
                    download(drive, att["fileId"], out_dir, state, prefix=f"{day} ", recordings=recordings)
        page = resp.get("nextPageToken")
        if not page:
            break


def from_drive_folder(drive, folder_name, since, match, out_dir, state, recordings):
    print(f"Drive folder '{folder_name}':")
    escaped = folder_name.replace("\\", "\\\\").replace("'", "\\'")
    folders = drive.files().list(
        q=f"mimeType='application/vnd.google-apps.folder' and name='{escaped}' and trashed=false",
        fields="files(id)",
    ).execute().get("files", [])
    if not folders:
        print("  (folder not found)")
        return

    for folder in folders:
        page = None
        while True:
            resp = drive.files().list(
                q=f"'{folder['id']}' in parents and trashed=false "
                  f"and modifiedTime >= '{since.strftime('%Y-%m-%dT%H:%M:%SZ')}'",
                fields="nextPageToken,files(id,name,modifiedTime)",
                pageToken=page,
                supportsAllDrives=True,
                includeItemsFromAllDrives=True,
            ).execute()
            for f in resp.get("files", []):
                if match and not re.search(match, f["name"], re.I):
                    continue
                download(drive, f["id"], out_dir, state, prefix=f"{f['modifiedTime'][:10]} ", recordings=recordings)
            page = resp.get("nextPageToken")
            if not page:
                break


def main():
    p = argparse.ArgumentParser(description="Download meeting notes from Calendar and Drive.")
    # Distill passes these two positionally; both are optional when run by hand.
    p.add_argument("vault", nargs="?", help=argparse.SUPPRESS)
    p.add_argument("queue", nargs="?", help=argparse.SUPPRESS)
    p.add_argument("--days", type=int, default=7, help="look back this many days (default 7)")
    p.add_argument("--folder", default="Meet Recordings", help="Drive folder name to scan")
    p.add_argument("--out", default=None, help="output directory (default: Distill's queue folder)")
    p.add_argument("--match", default=None, help="regex; only files whose name matches")
    p.add_argument("--include-recordings", action="store_true", help="also download video/audio recordings")
    p.add_argument("--import-client", metavar="CREDENTIALS_JSON", help="store the OAuth client in the Keychain")
    p.add_argument("--login", action="store_true", help="sign in to Google in the browser (one time)")
    args = p.parse_args()

    if args.import_client:
        return import_client(args.import_client)
    if args.login:
        return login()

    out = args.out or args.queue or os.environ.get("DISTILL_QUEUE_DIR")
    if not out:
        sys.exit("No output folder: pass --out, or run it as a Distill collector.")
    out_dir = Path(out).expanduser()
    out_dir.mkdir(parents=True, exist_ok=True)
    state_path = STATE_DIR / "downloaded.json"
    state = load_state(state_path)

    creds = get_creds()
    cal = build("calendar", "v3", credentials=creds, cache_discovery=False)
    drive = build("drive", "v3", credentials=creds, cache_discovery=False)

    until = dt.datetime.now(dt.timezone.utc)
    since = until - dt.timedelta(days=args.days)

    try:
        from_calendar(cal, drive, since, until, args.match, out_dir, state, args.include_recordings)
        from_drive_folder(drive, args.folder, since, args.match, out_dir, state, args.include_recordings)
    finally:
        if TEST_RUN:
            print("Test run: not remembering these files, so a real run downloads them again.")
        else:
            save_state(state_path, state)


if __name__ == "__main__":
    main()
