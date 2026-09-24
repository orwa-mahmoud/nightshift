#!/usr/bin/env bash
# session-end.sh — Cursor sessionEnd hook. Owner interrupt / clean close mid-shift.
#
# Cursor documents reason: completed | aborted | error | window_close | user_close.
# Owner hand on the door: aborted or user_close. Those write .session-end so the
# Cursor watchman can stand down. Closing the origin IDE tab while a CLI worker is
# recorded is not a clean close — the worker still owns the night.
# Inert outside an active shift. Never arms Claude or Codex watchmen.
set -u

_here="${BASH_SOURCE[0]%/*}"; [ "$_here" != "${BASH_SOURCE[0]}" ] || _here=.
# shellcheck source=plugins/nightshift/hooks/shared/idle.sh
. "$_here/../shared/idle.sh"
# shellcheck source=plugins/nightshift/lib/lib.sh
. "$_here/../../lib/lib.sh"
# shellcheck source=plugins/nightshift/hooks/cursor/lib-io.sh
. "$_here/lib-io.sh"

[ "${NIGHTSHIFT_REVIVAL:-}" != "1" ] || exit 0

cursor_read_input "$@"
HOST_DIR="$(cursor_project_dir)"
PROJECT_DIR="$(ns_workspace_root "$HOST_DIR" 2>/dev/null)" || exit 0
STATE_KIND="$(ns_state_kind "$PROJECT_DIR")"
case "$STATE_KIND" in
  malformed | future) exit 0 ;;
esac
NS="$PROJECT_DIR/.nightshift"
declare PUNCH ARMED ENDED SESSION SESSION_END
ns_layout_set PUNCH "$NS" punch-list
ns_layout_set ARMED "$NS" armed
ns_layout_set ENDED "$NS" ended
ns_layout_set SESSION "$NS" session
ns_layout_set SESSION_END "$NS" session-end

if [ ! -f "$ARMED" ] || [ ! -f "$PUNCH" ] || { [ -f "$ENDED" ] && [ ! -L "$ENDED" ]; }; then
  exit 0
fi
# A failed count is not zero. An unreadable punch list leaves the shift standing, so the
# session end is still recorded.
OPEN="$(ns_open_boxes "$PUNCH")" || OPEN=1
[ "$OPEN" -gt 0 ] || exit 0

SID="${CURSOR_SESSION_ID:-}"
REASON="${CURSOR_SESSION_END_REASON:-unknown}"

if [ -f "$SESSION" ] && [ ! -L "$SESSION" ]; then
  REC="$(sed -n 1p "$SESSION" 2>/dev/null)"
  WORKER="$(ns_cursor_worker_id "$NS")"
  if [ -n "$WORKER" ]; then
    [ -n "$SID" ] && [ "$SID" = "$WORKER" ] || exit 0
  else
    [ -n "$REC" ] && [ -n "$SID" ] && [ "$SID" != "$REC" ] && exit 0
  fi
  HOST_LINE="$(sed -n 5p "$SESSION" 2>/dev/null)"
  [ -z "$HOST_LINE" ] || [ "$HOST_LINE" = "cursor" ] || exit 0
fi

case "$REASON" in
  aborted | user_close) ;;
  *) exit 0 ;;
esac

[ -L "$SESSION_END" ] && rm -f "$SESSION_END"
printf '%s · clean session end (%s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$REASON" >"$SESSION_END"
exit 0
