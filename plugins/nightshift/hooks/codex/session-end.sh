#!/usr/bin/env bash
# session-end.sh — Codex SessionEnd hook. A clean close mid-shift is the owner's
# hand on the door. Codex fires this event with reason `other` for close,
# archive/delete, and idle unload (~30 min with no client). Do not filter
# aborted/user_close — that would no-op the hook.
#
# Inert outside an active shift. A watchman-spawned revival never writes the
# marker: its exit is not the owner's hand on the door.
set -u

_here="${BASH_SOURCE[0]%/*}"; [ "$_here" != "${BASH_SOURCE[0]}" ] || _here=.
# shellcheck source=plugins/nightshift/hooks/shared/idle.sh
. "$_here/../shared/idle.sh"
# shellcheck source=plugins/nightshift/lib/lib.sh
. "$_here/../../lib/lib.sh"
# shellcheck source=plugins/nightshift/hooks/codex/lib-io.sh
. "$_here/lib-io.sh"

[ "${NIGHTSHIFT_REVIVAL:-}" != "1" ] || exit 0

codex_read_input "$@"
HOST_DIR="$(codex_project_dir)"
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

SID="${CODEX_SESSION_ID:-}"
if [ -f "$SESSION" ] && [ ! -L "$SESSION" ]; then
  REC="$(sed -n 1p "$SESSION" 2>/dev/null)"
  [ -n "$REC" ] && [ "$SID" != "$REC" ] && exit 0
fi

if command -v jq >/dev/null 2>&1; then
  REASON="$(printf '%s' "${CODEX_RAW:-}" | jq -r '.reason // "other"' 2>/dev/null || printf 'other')"
else
  REASON="$(printf '%s' "${CODEX_RAW:-}" | sed -n 's/.*"reason"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
  REASON="${REASON:-other}"
fi

[ -L "$SESSION_END" ] && rm -f "$SESSION_END"
printf '%s · clean session end (%s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$REASON" >"$SESSION_END"
# The session is over while the shift is not: whatever passes until something works again is a
# gap nobody spent. Recorded so the duration line can list it, never subtracted silently.
ns_usage_pause "$NS" "the session ended and the shift was revived" || :
exit 0
