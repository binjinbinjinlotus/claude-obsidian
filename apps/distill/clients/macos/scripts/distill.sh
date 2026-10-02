#!/bin/zsh
# Control the Distill Mac app.
#
# Usage: apps/distill/clients/macos/scripts/distill.sh <command> [--force]
#   toggle   stop the app if it is running, otherwise start it
#   start    open the installed app
#   stop     quit the app (refuses while a job is running; --force overrides)
#   restart  stop, then start
#   update   run tests, rebuild, install to ~/Applications, relaunch if it was running
#   status   show whether it runs, and its running / awaiting-approval jobs
#   test     run the WorkerCore unit tests
set -euo pipefail

SCRIPT="${0:A}"
APP_DIR="${SCRIPT:h:h}"
BUNDLE_ID="com.claude-obsidian.distill"
INSTALLED="$HOME/Applications/Distill.app"
JOBS="${DISTILL_JOBS:-$HOME/Library/Application Support/Distill/jobs.json}"

cmd="${1:-status}"
force=0
[[ "${2:-}" == "--force" || "${1:-}" == "--force" ]] && force=1

is_running() { pgrep -f "Distill.app/Contents/MacOS/Distill" >/dev/null 2>&1; }

# Prints "<running> <awaiting>" job counts from the app's job store.
job_counts() {
  [[ -f "$JOBS" ]] || { echo "0 0"; return; }
  python3 - "$JOBS" <<'PY'
import json, sys
try:
    jobs = json.load(open(sys.argv[1]))
except Exception:
    jobs = []
states = [j.get("state") for j in jobs]
print(states.count("running"), states.count("awaitingApproval"))
PY
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
  read running awaiting <<< "$(job_counts)"
  if (( running > 0 && ! force )); then
    echo "Refusing to quit: $running job(s) are running (an apply may be in progress)."
    echo "Wait for them to finish, or re-run with --force."
    exit 2
  fi
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  for _ in {1..20}; do is_running || break; sleep 0.5; done
  if is_running; then
    pkill -f "Distill.app/Contents/MacOS/Distill" || true
  fi
  echo "Stopped."
  (( awaiting > 0 )) && echo "$awaiting job(s) still await approval; they will be there on next start."
  return 0
}

do_status() {
  read running awaiting <<< "$(job_counts)"
  if is_running; then echo "App: running"; else echo "App: stopped"; fi
  [[ -d "$INSTALLED" ]] && echo "Installed: $INSTALLED" || echo "Installed: no"
  echo "Jobs running: $running · awaiting approval: $awaiting"
}

case "$cmd" in
  toggle)  if is_running; then do_stop; else do_start; fi ;;
  start)   do_start ;;
  stop)    do_stop ;;
  restart) do_stop; do_start ;;
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
    sed -n '2,13p' "$SCRIPT" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac
