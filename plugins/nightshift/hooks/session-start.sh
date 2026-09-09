#!/usr/bin/env bash
# session-start.sh — Claude Code SessionStart, for the two sources that mean the conversation no
# longer holds what it was told: `compact` and `resume`.
#
# Two things happen, and only in the session that owns the shift:
#
#   .context-reset   a marker the next clock-out block consumes, so that block carries the whole
#                    contract again rather than the short reminder. A compacted conversation has
#                    lost the message it was shortening against.
#   one line back    said once, so the model reloads the skill, the contract that binds it, and
#                    the section it was working before it carries on.
#
# It starts the way the pulse and the gate start: read the state directory, and leave immediately
# when there is no armed shift or the session on stdin is not the one holding it. An ordinary
# conversation, a second tab on the same project, and a project with no shift never see the line
# and never pay for the hook.
#
# Codex and Cursor expose no equivalent event. For them the reminder limit is the only reset, and
# the docs say so. Where either later exposes one, this marker is the seam.
set -u

_here="${BASH_SOURCE[0]%/*}"; [ "$_here" != "${BASH_SOURCE[0]}" ] || _here=.
# shellcheck source=plugins/nightshift/lib/lib.sh
. "$_here/../lib/lib.sh"

INPUT="$(ns_read_stdin_bounded 2)"
HOST_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
PROJECT_DIR="$(ns_workspace_root "$HOST_DIR" 2>/dev/null)" || exit 0
STATE_KIND="$(ns_state_kind "$PROJECT_DIR")"
case "$STATE_KIND" in
  malformed | future) exit 0 ;;
esac
NS="$PROJECT_DIR/.nightshift"

[ -f "$NS/.shift-armed" ] || exit 0

if command -v jq >/dev/null 2>&1; then
  SOURCE="$(printf '%s' "$INPUT" | jq -r '.source // empty' 2>/dev/null || true)"
  SID="$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)"
else
  SOURCE="$(printf '%s' "$INPUT" | sed -n 's/.*"source"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
  SID="$(printf '%s' "$INPUT" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
fi

# Only the two sources that mean context was lost. A fresh start or a cleared conversation is not
# a reset of anything this shift said.
case "$SOURCE" in
  compact | resume) ;;
  *) exit 0 ;;
esac

# The session that owns the shift, and no other.
REC="$(ns_session_line "$NS" 1)"
[ -n "$REC" ] || exit 0
[ -n "$SID" ] && [ "$SID" = "$REC" ] || exit 0

[ -L "$NS/.context-reset" ] && rm -f "$NS/.context-reset"
: >"$NS/.context-reset" 2>/dev/null || :

LINE='nightshift: context was compacted — reload the nightshift skill, the contract in punch-list.md, and the active receipt under receipts/ before continuing.'
ACTIVE="$(ns_items_section "$NS/punch-list.md" 2>/dev/null | awk '
  /^- \[ \]/ {
    line = $0
    sub(/^- \[ \][[:space:]]*\*\*/, "", line)
    sub(/[[:space:]]+—.*$/, "", line)
    sub(/[[:space:]]+-[[:space:]].*$/, "", line)
    sub(/\*\*.*$/, "", line)
    gsub(/[[:space:]]+$/, "", line)
    print line
    exit
  }
')"
if [ -n "$ACTIVE" ]; then
  LINE="$LINE Receipts: one file per item under .nightshift/receipts/; the current item is ${ACTIVE} → $(ns_receipt_basename "$ACTIVE").md."
fi
if command -v jq >/dev/null 2>&1; then
  jq -nc --arg c "$LINE" '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$c}}'
else
  printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}\n' \
    "$(printf '%s' "$LINE" | tr -d '\000-\037' | sed 's/\\/\\\\/g; s/"/\\"/g')"
fi
exit 0
