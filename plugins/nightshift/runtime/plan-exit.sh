#!/usr/bin/env bash
# plan-exit.sh — the owner leaves the plan room from a terminal.
#
#   plan-exit.sh --project DIR
#
# The terminal exit on every host, and the only one on a host whose prompt hook did not see the
# owner's command. Hardhat refuses this command to every agent tool call while the room is open, so
# running it is the owner's own act.
#
# Exit: 0 closed, or no room was open · 1 usage/resolve/could not remove the marker
set -u

_here="${BASH_SOURCE[0]%/*}"; [ "$_here" != "${BASH_SOURCE[0]}" ] || _here=.
# shellcheck source=plugins/nightshift/lib/lib.sh
. "$_here/../lib/lib.sh"

PROJECT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --project)
      [ $# -ge 2 ] || { printf 'plan-exit: --project needs a value\n' >&2; exit 1; }
      PROJECT="$2"
      shift 2
      ;;
    -h | --help)
      awk 'NR == 1 { next } !/^#/ { exit } { sub(/^# ?/, ""); print }' "$0"
      exit 1
      ;;
    *) printf 'plan-exit: unknown argument: %s\n' "$1" >&2; exit 1 ;;
  esac
done
[ -n "$PROJECT" ] || { printf 'plan-exit: --project is required\n' >&2; exit 1; }

WORKSPACE="$(ns_workspace_root "$PROJECT" 2>/dev/null)" || { printf 'plan-exit: no workspace at %s\n' "$PROJECT" >&2; exit 1; }
NS="$WORKSPACE/.nightshift"
if [ ! -d "$NS" ] || [ -L "$NS" ]; then
  printf 'plan-exit: no .nightshift/ at %s\n' "$WORKSPACE" >&2
  exit 1
fi

if ! ns_plan_room_open "$NS"; then
  printf 'plan room was not open\n'
  exit 0
fi
ns_plan_room_leave "$NS" "ran plan-exit in a terminal" \
  || { printf 'plan-exit: could not remove %s\n' "$(ns_layout_name "$NS" plan-room)" >&2; exit 1; }
printf 'plan room closed: nothing is fenced any more\n'
