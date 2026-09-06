#!/usr/bin/env bash
# session-end.sh — SessionEnd hook. A clean exit mid-shift is the owner's hand on the door.
#
# The night watchman (runtime/claude/watchman.sh) revives a session that dies mid-shift — but a session
# the owner ended on purpose (/exit, a clean quit) must stay ended. Crashes, kills and API deaths
# never reach this hook, which is exactly the tell: a marker present means a hand closed the
# session, no marker means it died. The watchman stands down on the marker; Start and the Hunt cut
# clear it, which is what re-arms the night.
#
# Inert outside an active shift: no punch list, no open box, or an already-ended shift writes
# nothing, so ordinary sessions leave no residue.
set -u

_here="${BASH_SOURCE[0]%/*}"; [ "$_here" != "${BASH_SOURCE[0]}" ] || _here=.
# shellcheck source=plugins/nightshift/lib/lib.sh
. "$_here/../lib/lib.sh"

# A watchman-spawned revival carries this mark. Its exit — finished, or dead on the API again —
# is never the owner's hand on the door; writing the marker for it would stand the watchman down
# mid-outage after the first revival.
[ "${NIGHTSHIFT_REVIVAL:-}" != "1" ] || exit 0

INPUT="$(cat)"
HOST_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
PROJECT_DIR="$(ns_workspace_root "$HOST_DIR" 2>/dev/null)" || exit 0
STATE_KIND="$(ns_state_kind "$PROJECT_DIR")"
case "$STATE_KIND" in
  malformed | future) exit 0 ;;
esac
NS="$PROJECT_DIR/.nightshift"
PUNCH="$NS/punch-list.md"

if [ ! -f "$NS/.shift-armed" ] || [ ! -f "$PUNCH" ] || { [ -f "$NS/.ended" ] && [ ! -L "$NS/.ended" ]; }; then
  exit 0
fi
# A failed count is not zero. An unreadable punch list leaves the shift standing, so the
# session end is still recorded.
OPEN="$(ns_open_boxes "$PUNCH")" || OPEN=1
[ "$OPEN" -gt 0 ] || exit 0

# jq preferred, sed fallback — same policy as hardhat: a missing jq never disables the hook.
# Only the shift's own session ending is the owner's hand on the door — a helper tab closing in
# the same project proves nothing about the shift.
if command -v jq >/dev/null 2>&1; then
  SID="$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)"
else
  SID="$(printf '%s' "$INPUT" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
fi
if [ -f "$NS/.shift-session" ] && [ ! -L "$NS/.shift-session" ]; then
  REC="$(sed -n 1p "$NS/.shift-session" 2>/dev/null)"
  [ -n "$REC" ] && [ "$SID" != "$REC" ] && exit 0
fi

# After recovery, the stale IDE process still carries the same conversation id. Closing that
# stale panel must not masquerade as the recovered owner's clean exit and stand the watchman down.
# Only the current process lease may write the marker; a missing lease keeps legacy behavior.
if [ -e "$NS/.shift-lease" ] || [ -L "$NS/.shift-lease" ]; then
  CURRENT_PID="$(ns_ancestor_pid claude "$$" 2>/dev/null || true)"
  CURRENT_START=""
  [ -z "$CURRENT_PID" ] || CURRENT_START="$(ns_process_start "$CURRENT_PID" 2>/dev/null || true)"
  ns_lease_allows "$NS" "$SID" claude "$CURRENT_PID" "$CURRENT_START" \
    "${NIGHTSHIFT_LEASE_NONCE:-}" "${NIGHTSHIFT_LEASE_GENERATION:-}" || exit 0
fi

if command -v jq >/dev/null 2>&1; then
  REASON="$(printf '%s' "$INPUT" | jq -r '.reason // "unknown"' 2>/dev/null || printf 'unknown')"
else
  REASON="$(printf '%s' "$INPUT" | sed -n 's/.*"reason"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
  REASON="${REASON:-unknown}"
fi

[ -L "$NS/.session-end" ] && rm -f "$NS/.session-end"
printf '%s · clean session end (%s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$REASON" >"$NS/.session-end"
# The session is over while the shift is not: whatever passes until something works again is a
# gap nobody spent. Recorded so the duration line can list it, never subtracted silently.
ns_usage_pause "$NS" "the session ended and the shift was revived" || :
exit 0
