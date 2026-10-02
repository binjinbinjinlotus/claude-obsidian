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
#   update     run tests, rebuild, install to ~/Applications, relaunch if it was running
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
    do_stop
    "$APP_DIR/scripts/build-app.sh" --install
    if (( was_running )); then do_start; else echo "Not relaunched (was stopped). Run: $SCRIPT start"; fi
    ;;
  status)  do_status ;;
  test)    swift test --package-path "$APP_DIR" ;;
  *)
    sed -n '2,15p' "$SCRIPT" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac
