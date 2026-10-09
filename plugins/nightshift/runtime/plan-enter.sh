#!/usr/bin/env bash
# plan-enter.sh — open the plan room. Nothing is implemented in the conversation that enters it
# until the owner leaves it.
#
#   plan-enter.sh --project DIR [--host claude|codex|cursor]
#
# The room opens unbound; the caller's very next tool call is the probe that binds it to that
# conversation: `: nightshift-plan-probe` in a POSIX shell. An open room is left as it is.
#
# Exit: 0 open · 1 usage/resolve
set -u

_here="${BASH_SOURCE[0]%/*}"; [ "$_here" != "${BASH_SOURCE[0]}" ] || _here=.
# shellcheck source=plugins/nightshift/lib/lib.sh
. "$_here/../lib/lib.sh"

PROJECT=""
HOST_NAME="${NIGHTSHIFT_HOST:-claude}"
while [ $# -gt 0 ]; do
  case "$1" in
    --project)
      [ $# -ge 2 ] || { printf 'plan-enter: --project needs a value\n' >&2; exit 1; }
      PROJECT="$2"
      shift 2
      ;;
    --host)
      [ $# -ge 2 ] || { printf 'plan-enter: --host needs a value\n' >&2; exit 1; }
      HOST_NAME="$2"
      shift 2
      ;;
    -h | --help)
      awk 'NR == 1 { next } !/^#/ { exit } { sub(/^# ?/, ""); print }' "$0"
      exit 1
      ;;
    *) printf 'plan-enter: unknown argument: %s\n' "$1" >&2; exit 1 ;;
  esac
done
[ -n "$PROJECT" ] || { printf 'plan-enter: --project is required\n' >&2; exit 1; }
case "$HOST_NAME" in claude | codex | cursor) ;; *) printf 'plan-enter: unknown host: %s\n' "$HOST_NAME" >&2; exit 1 ;; esac

WORKSPACE="$(ns_workspace_root "$PROJECT" 2>/dev/null)" || { printf 'plan-enter: no workspace at %s\n' "$PROJECT" >&2; exit 1; }
NS="$WORKSPACE/.nightshift"
[ -d "$NS" ] && [ ! -L "$NS" ] || { printf 'plan-enter: no .nightshift/ at %s — run Setup first\n' "$WORKSPACE" >&2; exit 1; }

# record — the plan record, created on first entry, every plan it holds open, and what waits for the
# owner's review: entering resumes from both.
record() {
  local open
  bash "$_here/scaffold.sh" --project "$WORKSPACE" plan-record >/dev/null 2>&1 \
    || printf 'plan-enter: could not create %s\n' "$(ns_layout_name "$NS" plan-record)" >&2
  printf 'plan record %s\n' "$(ns_layout_name "$NS" plan-record)"
  open="$(ns_plan_record_open "$NS")"
  if [ -n "$open" ]; then
    printf '%s\n' "$open" | sed 's/^/open plan: /'
  else
    printf 'open plan: none\n'
  fi
  ns_plan_review "$NS"
}

if ns_plan_room_open "$NS"; then
  bound="$(ns_plan_room_line "$NS" 1)"
  if [ -n "$bound" ]; then
    printf 'plan room already open, bound to conversation %s\n' "$bound"
  else
    printf 'plan room already open, waiting for its conversation: run : nightshift-plan-probe next\n'
  fi
  record
  exit 0
fi
ns_plan_room_enter "$NS" "$HOST_NAME" || { printf 'plan-enter: could not write %s\n' "$(ns_layout_name "$NS" plan-room)" >&2; exit 1; }
ns_shift_log "$NS" "plan room opened ($HOST_NAME)"
printf 'plan room open: run : nightshift-plan-probe as the next tool call to bind it to this conversation\n'
printf 'plan goes in %s\n' "$(ns_plan_room_place_name "$NS")"
record
