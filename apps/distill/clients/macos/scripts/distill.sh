#!/bin/zsh
# Control the Distill Mac app and the Distill core it talks to.
#
# Usage: apps/distill/clients/macos/scripts/distill.sh <command> [--force]
#   toggle     stop the app if it is running, otherwise start it
#   start      open the installed app (it starts the core if none is running)
#   stop       quit the app (refuses while a job is running; --force overrides).
#              The core keeps running: the CLI and agents may be using it.
#   restart    stop, then start
#   core-stop  stop the core server (SIGTERM; refuses while a job is running; --force overrides)
#   update     back up your data, run tests, rebuild, install to ~/Applications,
#              check your data is still there, relaunch if it was running
#   backup [TAG]  copy settings, job history and Ask history to <state>/backups/<time>
#   backups    list the backups (newest first)
#   restore NAME  put a backup back (app and core must be stopped; backs up the current data first)
#   status     show the app, the core, and running / awaiting-approval jobs
#   test       run the DistillKit unit tests
set -euo pipefail

SCRIPT="${0:A}"
APP_DIR="${SCRIPT:h:h}"
BUNDLE_ID="com.claude-obsidian.distill"
INSTALLED="$HOME/Applications/Distill.app"
STATE_DIR="${DISTILL_STATE_DIR:-$HOME/Library/Application Support/Distill}"
JOBS="${DISTILL_JOBS:-$STATE_DIR/jobs.json}"

cmd="${1:-status}"
force=0
[[ "${2:-}" == "--force" || "${1:-}" == "--force" ]] && force=1

is_running() { pgrep -f "Distill.app/Contents/MacOS/Distill" >/dev/null 2>&1; }

# Prints one line: "<live 0|1> <pid> <port> <version> <running> <awaiting> <source>".
# Asks the core's API when a live core holds server.json (its pid must be a
# `main.js serve` process, so a stale file with a reused pid is ignored).
# Without a core, counts jobs.json: an old Swift-engine app may still be the
# one running jobs during the switch to the core.
core_info() {
  python3 - "$STATE_DIR" "$JOBS" <<'PY'
import json, os, subprocess, sys, urllib.request
state, jobs_path = sys.argv[1], sys.argv[2]
def from_jobs():
    try:
        states = [j.get("state") for j in json.load(open(jobs_path))]
    except Exception:
        states = []
    return states.count("running"), states.count("awaitingApproval")
try:
    lock = json.load(open(os.path.join(state, "server.json")))
    pid, port = int(lock["pid"]), int(lock["port"])
    cmdline = subprocess.run(["ps", "-p", str(pid), "-o", "command="], capture_output=True, text=True).stdout
    if "main.js serve" not in cmdline and "main.ts serve" not in cmdline:
        raise RuntimeError("stale server.json")
except Exception:
    r, a = from_jobs()
    print(0, 0, 0, "-", r, a, "jobs.json")
    sys.exit(0)
try:
    token = open(os.path.join(state, "token")).read().strip()
    req = urllib.request.Request(f"http://127.0.0.1:{port}/v1/status", headers={"Authorization": f"Bearer {token}"})
    with urllib.request.urlopen(req, timeout=5) as resp:
        s = json.load(resp)
    print(1, pid, port, s.get("version") or lock.get("version") or "-", s.get("runningJobs", 0), s.get("pendingApprovals", 0), "core")
except Exception:
    r, a = from_jobs()
    print(1, pid, port, lock.get("version") or "-", r, a, "jobs.json")
PY
}

refuse_if_running() {
  local what="$1"
  read live pid port version running awaiting source <<< "$(core_info)"
  if (( running > 0 && ! force )); then
    echo "Refusing to $what: $running job(s) are running (an apply may be in progress)."
    echo "Wait for them to finish, or re-run with --force."
    exit 2
  fi
}

do_start() {
  if [[ ! -d "$INSTALLED" ]]; then
    echo "Not installed. Run: $SCRIPT update"
    exit 1
  fi
  if is_running; then echo "Already running."; return; fi
  open "$INSTALLED"
  echo "Started."
}

do_stop() {
  if ! is_running; then echo "Not running."; return; fi
  refuse_if_running "quit"
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  for _ in {1..20}; do is_running || break; sleep 0.5; done
  if is_running; then
    pkill -f "Distill.app/Contents/MacOS/Distill" || true
  fi
  echo "Stopped the app."
  read live pid port version running awaiting source <<< "$(core_info)"
  (( live )) && echo "The core keeps running (pid $pid). Stop it with: $SCRIPT core-stop"
  (( awaiting > 0 )) && echo "$awaiting job(s) still await approval; they will be there on next start."
  return 0
}

do_core_stop() {
  read live pid port version running awaiting source <<< "$(core_info)"
  if (( ! live )); then echo "Core: not running."; return; fi
  refuse_if_running "stop the core"
  kill -TERM "$pid"
  for _ in {1..40}; do kill -0 "$pid" 2>/dev/null || break; sleep 0.25; done
  if kill -0 "$pid" 2>/dev/null; then echo "Core (pid $pid) did not exit yet."; exit 1; fi
  echo "Core stopped (pid $pid)."
}

do_status() {
  if is_running; then echo "App: running"; else echo "App: stopped"; fi
  [[ -d "$INSTALLED" ]] && echo "Installed: $INSTALLED" || echo "Installed: no"
  read live pid port version running awaiting source <<< "$(core_info)"
  if (( live )); then
    echo "Core: running (pid $pid, 127.0.0.1:$port, version $version, state $STATE_DIR)"
  else
    echo "Core: not running (state $STATE_DIR)"
  fi
  echo "Jobs running: $running · awaiting approval: $awaiting (from $source)"
}

# ───────────── user data: settings, job history, Ask history ─────────────
# Updates replace only the app bundle; this data lives in $STATE_DIR and must
# survive every update. `update` backs it up first and checks it afterwards.
BACKUPS="$STATE_DIR/backups"
KEEP_BACKUPS=10

# Prints one line: "<settings 0|1> <jobs> <chats>".
data_summary() {
  local settings=0 jobs=0 chats
  [[ -f "$STATE_DIR/settings.json" ]] && settings=1
  if [[ -f "$JOBS" ]]; then
    jobs=$(python3 -c 'import json,sys
try: print(len(json.load(open(sys.argv[1]))))
except Exception: print(-1)' "$JOBS")
  fi
  chats=$(print -l "$STATE_DIR"/ask/*.json(N) | grep -c . || true)
  echo "$settings $jobs $chats"
}

describe_data() {
  local settings jobs chats
  read settings jobs chats <<< "$1"
  echo "settings $( (( settings )) && echo kept || echo none) · $jobs jobs · $chats Ask chats"
}

do_backup() {
  local name dest
  name="$(date +%Y%m%d-%H%M%S)${1:+-$1}"
  dest="$BACKUPS/$name"
  local i=2
  while [[ -e "$dest" ]]; do dest="$BACKUPS/$name-$(printf %02d $i)"; (( i++ )); done
  mkdir -p "$dest/ask"
  [[ -f "$STATE_DIR/settings.json" ]] && cp -p "$STATE_DIR/settings.json" "$dest/"
  [[ -f "$JOBS" ]] && cp -p "$JOBS" "$dest/jobs.json"
  for f in "$STATE_DIR"/*.unreadable-*(N); do cp -p "$f" "$dest/"; done
  for f in "$STATE_DIR"/ask/*.json(N); do cp -p "$f" "$dest/ask/"; done
  chmod 700 "$BACKUPS" "$dest"
  local old=( "$BACKUPS"/*(N/On[$((KEEP_BACKUPS + 1)),-1]) )
  (( ${#old} )) && rm -rf -- "${old[@]}"
  echo "Backed up your data ($(describe_data "$(data_summary)")) to $dest"
}

do_backups() {
  local dirs=( "$BACKUPS"/*(N/On) )
  if (( ! ${#dirs} )); then echo "No backups in $BACKUPS"; return; fi
  for d in "${dirs[@]}"; do
    local n=$(print -l "$d"/ask/*.json(N) | grep -c . || true)
    echo "${d:t}  ($([[ -f $d/settings.json ]] && echo settings || echo 'no settings'), $n Ask chats)"
  done
}

do_restore() {
  local name="${1:-}" src
  [[ -n "$name" ]] || { echo "Usage: $SCRIPT restore NAME (see: $SCRIPT backups)"; exit 1; }
  src="$BACKUPS/$name"
  [[ -d "$src" ]] || { echo "No backup named $name in $BACKUPS"; exit 1; }
  if is_running; then echo "Quit the app first: $SCRIPT stop"; exit 1; fi
  read live pid port version running awaiting source <<< "$(core_info)"
  if (( live )); then echo "Stop the core first: $SCRIPT core-stop"; exit 1; fi
  do_backup before-restore
  [[ -f "$src/settings.json" ]] && cp -p "$src/settings.json" "$STATE_DIR/settings.json"
  [[ -f "$src/jobs.json" ]] && cp -p "$src/jobs.json" "$JOBS"
  mkdir -p "$STATE_DIR/ask"
  for f in "$src"/ask/*.json(N); do cp -p "$f" "$STATE_DIR/ask/"; done
  echo "Restored $name ($(describe_data "$(data_summary)")). Start with: $SCRIPT start"
}

case "$cmd" in
  toggle)  if is_running; then do_stop; else do_start; fi ;;
  start)   do_start ;;
  stop)    do_stop ;;
  restart) do_stop; do_start ;;
  core-stop) do_core_stop ;;
  update)
    was_running=0
    is_running && was_running=1
    if ! swift test --package-path "$APP_DIR" > /tmp/distill-test.log 2>&1; then
      grep -E "error:|failed" /tmp/distill-test.log | head -20
      echo "Tests failed; not installing. Full log: /tmp/distill-test.log"
      exit 1
    fi
    grep -E "Executed .* tests" /tmp/distill-test.log | tail -1
    before="$(data_summary)"
    do_backup update
    do_stop
    "$APP_DIR/scripts/build-app.sh" --install
    after="$(data_summary)"
    read b_settings b_jobs b_chats <<< "$before"
    read a_settings a_jobs a_chats <<< "$after"
    if (( a_settings < b_settings || a_jobs < b_jobs || a_chats < b_chats )); then
      echo "WARNING: data changed during the update: before $(describe_data "$before"), now $(describe_data "$after")."
      echo "Your backup: $SCRIPT backups, then $SCRIPT restore NAME"
    else
      echo "Your data is intact: $(describe_data "$after")"
    fi
    if (( was_running )); then do_start; else echo "Not relaunched (was stopped). Run: $SCRIPT start"; fi
    ;;
  backup)  do_backup "${2:-}" ;;
  backups) do_backups ;;
  restore) do_restore "${2:-}" ;;
  status)  do_status ;;
  test)    swift test --package-path "$APP_DIR" ;;
  *)
    sed -n '2,15p' "$SCRIPT" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac
