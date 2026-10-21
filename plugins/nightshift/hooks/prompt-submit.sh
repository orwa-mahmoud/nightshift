#!/usr/bin/env bash
# prompt-submit.sh — UserPromptSubmit hook. While the plan room binds this conversation, each owner
# message carries one line reminding the model that it is planning, not building.
#
# Claude Code adds `hookSpecificOutput.additionalContext` to what the model reads with the prompt. A
# prompt that is the owner's own exit command adds nothing: the room closes as it expands. Another
# conversation in the project, or no open room, adds nothing either.
#
# The prompt always goes through: this hook never blocks one.
set -u

_here="${BASH_SOURCE[0]%/*}"; [ "$_here" != "${BASH_SOURCE[0]}" ] || _here=.
# shellcheck source=plugins/nightshift/hooks/shared/idle.sh
. "$_here/shared/idle.sh"
# shellcheck source=plugins/nightshift/lib/lib.sh
. "$_here/../lib/lib.sh"

INPUT="$(ns_read_stdin_bounded 2)"
HOST_DIR="${CLAUDE_PROJECT_DIR:-}"
if command -v jq >/dev/null 2>&1; then
  SID="$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)"
  PROMPT="$(printf '%s' "$INPUT" | jq -r '.prompt // empty' 2>/dev/null || true)"
  [ -n "$HOST_DIR" ] || HOST_DIR="$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)"
else
  SID="$(printf '%s' "$INPUT" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
  PROMPT="$(printf '%s' "$INPUT" | sed -n 's/.*"prompt"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
  [ -n "$HOST_DIR" ] || HOST_DIR="$(printf '%s' "$INPUT" | sed -n 's/.*"cwd"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
fi
[ -n "$HOST_DIR" ] || exit 0
ns_plan_room_exit_word "$PROMPT" >/dev/null && exit 0
PROJECT_DIR="$(ns_workspace_root "$HOST_DIR" 2>/dev/null)" || exit 0
NS="$PROJECT_DIR/.nightshift"
ns_plan_room_binds "$NS" "$SID" || exit 0

CONTEXT="$(ns_plan_room_reminder "$NS")"
if command -v jq >/dev/null 2>&1; then
  jq -nc --arg c "$CONTEXT" '{hookSpecificOutput:{hookEventName:"UserPromptSubmit",additionalContext:$c}}'
else
  printf '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"%s"}}\n' "$CONTEXT"
fi
exit 0
