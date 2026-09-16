#!/usr/bin/env bash
# before-submit.sh — Cursor beforeSubmitPrompt. Catches the first typed message
# on the origin IDE tab after a CLI worker has taken the shift.
set -u

_here="${BASH_SOURCE[0]%/*}"; [ "$_here" != "${BASH_SOURCE[0]}" ] || _here=.
# shellcheck source=plugins/nightshift/hooks/shared/idle.sh
. "$_here/../shared/idle.sh"
# shellcheck source=plugins/nightshift/lib/lib.sh
. "$_here/../../lib/lib.sh"
# shellcheck source=plugins/nightshift/hooks/cursor/lib-io.sh
. "$_here/lib-io.sh"

cursor_read_input "$@"
SID="${CURSOR_SESSION_ID:-}"
HOST_DIR="$(cursor_project_dir)"
PROJECT_DIR="$(ns_workspace_root "$HOST_DIR" 2>/dev/null)" || exit 0
NS="$PROJECT_DIR/.nightshift"
PUNCH="$NS/punch-list.md"

[ -f "$NS/.shift-armed" ] && [ -f "$PUNCH" ] || exit 0
{ [ -f "$NS/.ended" ] && [ ! -L "$NS/.ended" ]; } && exit 0
# A count that fails is not a verdict. An unreadable punch list is not proof the work is
# done, so the pointer still stands — the same reading the clock-out gate takes.
OPEN="$(ns_open_boxes "$PUNCH")" || OPEN=1
[ "$OPEN" -gt 0 ] || exit 0

if ns_cursor_stale_origin "$NS" "$SID"; then
  if ns_cursor_stop_request "${CURSOR_PROMPT:-}"; then
    exit 0
  fi
  cursor_emit_prompt_block "$(ns_cursor_pointer_message "$NS" "$PROJECT_DIR")"
  exit 0
fi
exit 0
