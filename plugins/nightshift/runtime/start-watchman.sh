#!/usr/bin/env bash
# start-watchman.sh — launch this host's watchman in the background and confirm it armed.
#
#   start-watchman.sh --project DIR --host claude|codex|cursor [-- WATCHMAN-ARGS…]
#
# The watchman is given the workspace explicitly, never the working directory. Its own output is
# appended to run/watchman.log. Success means the watchman's pid file names the launched process
# and the shift log gained its `armed` line; anything short of that is reported with the
# watchman's own words, and a launched process that did not arm is stopped.
#
# Exit: 0 armed, or a live watchman already watches the site · 1 usage/resolve · 2 did not arm
set -u

_here="${BASH_SOURCE[0]%/*}"; [ "$_here" != "${BASH_SOURCE[0]}" ] || _here=.
# shellcheck source=plugins/nightshift/lib/lib.sh
. "$_here/../lib/lib.sh"

PROJECT=""
HOST_NAME=""
while [ $# -gt 0 ]; do
  case "$1" in
    --project)
      [ $# -ge 2 ] || { printf 'start-watchman: --project needs a value\n' >&2; exit 1; }
      PROJECT="$2"
      shift 2
      ;;
    --host)
      [ $# -ge 2 ] || { printf 'start-watchman: --host needs a value\n' >&2; exit 1; }
      HOST_NAME="$2"
      shift 2
      ;;
    --)
      shift
      break
      ;;
    -h | --help)
      awk 'NR == 1 { next } !/^#/ { exit } { sub(/^# ?/, ""); print }' "$0"
      exit 1
      ;;
    *) printf 'start-watchman: unknown argument: %s\n' "$1" >&2; exit 1 ;;
  esac
done
[ -n "$PROJECT" ] || { printf 'start-watchman: --project is required\n' >&2; exit 1; }
case "$HOST_NAME" in
  claude | codex | cursor) ;;
  *) printf 'start-watchman: --host must be claude, codex or cursor\n' >&2; exit 1 ;;
esac

WORKSPACE="$(ns_workspace_root "$(ns_state_dir_owner "$PROJECT")" 2>/dev/null)" || {
  printf 'start-watchman: invalid .nightshift-link at %s\n' "$PROJECT" >&2
  exit 1
}
NS="$WORKSPACE/.nightshift"
[ -d "$NS" ] || { printf 'start-watchman: no .nightshift at %s\n' "$WORKSPACE" >&2; exit 1; }
WATCHMAN="$_here/$HOST_NAME/watchman.sh"
[ -f "$WATCHMAN" ] || { printf 'start-watchman: no %s watchman in this plugin\n' "$HOST_NAME" >&2; exit 1; }

declare PIDFILE LOG OUTPUT
ns_layout_set PIDFILE "$NS" watchman
ns_layout_set LOG "$NS" shift-log
ns_layout_set OUTPUT "$NS" watchman-log

pidfile_pid() {
  [ -f "$PIDFILE" ] && [ ! -L "$PIDFILE" ] || return 1
  sed -n 1p "$PIDFILE" 2>/dev/null | tr -d '[:space:]'
}

# One watchman per site. A live one is already doing this job, and a second would refuse anyway.
held="$(pidfile_pid)" || held=""
case "$held" in
  '' | *[!0-9]*) ;;
  *)
    if kill -0 "$held" 2>/dev/null; then
      printf 'watchman already watching (pid %s)\n' "$held"
      exit 0
    fi
    ;;
esac

mkdir -p "${OUTPUT%/*}" "${LOG%/*}" 2>/dev/null
log_from=0
[ -f "$LOG" ] && log_from="$(wc -c <"$LOG" | tr -d '[:space:]')"
printf '%s · start-watchman: launching the %s watchman for %s\n' \
  "$(date '+%Y-%m-%d %H:%M:%S')" "$HOST_NAME" "$WORKSPACE" >>"$OUTPUT"
output_from="$(wc -l <"$OUTPUT" | tr -d '[:space:]')"

nohup "$WATCHMAN" --project "$WORKSPACE" "$@" >>"$OUTPUT" 2>&1 </dev/null &
child=$!

# Everything the watchman said since this launch, for a refusal to quote.
did_not_arm() {
  printf 'start-watchman: %s\n' "$1" >&2
  sed -n "$((output_from + 1)),\$p" "$OUTPUT" >&2
  printf 'start-watchman: the full output is in %s\n' "$OUTPUT" >&2
  exit 2
}

armed_line() {
  tail -c "+$((log_from + 1))" "$LOG" 2>/dev/null | grep -qE 'watchman( \([a-z]+\))? armed'
}

attempt=0
while [ "$attempt" -lt 150 ]; do
  if [ "$(pidfile_pid)" = "$child" ] && armed_line; then
    printf 'watchman started (pid %s)\n' "$child"
    exit 0
  fi
  if ! kill -0 "$child" 2>/dev/null; then
    wait "$child"
    did_not_arm "the watchman exited before it armed (status $?)"
  fi
  sleep 0.1
  attempt=$((attempt + 1))
done
kill "$child" 2>/dev/null
did_not_arm "the watchman did not arm within 15 seconds and was stopped"
