#!/usr/bin/env bash
# prompt-expansion.sh — UserPromptExpansion hook. The owner's own command closes the plan room.
#
# Claude Code fires this event only when the owner types a command, before it expands, with the
# command's name in `command_name` (`nightshift:plan-exit`) and the typed line in `prompt`. A
# command the model runs through the Skill tool never reaches it, and neither does any other prompt,
# so typing /nightshift:plan-exit or /nightshift:start is the one way a conversation leaves the room.
# /nightshift:start clears the marker here, before Start's own preflight runs.
#
# The command always expands: this hook never blocks one.
set -u

_here="${BASH_SOURCE[0]%/*}"; [ "$_here" != "${BASH_SOURCE[0]}" ] || _here=.
# shellcheck source=plugins/nightshift/hooks/shared/idle.sh
. "$_here/shared/idle.sh"
# shellcheck source=plugins/nightshift/lib/lib.sh
. "$_here/../lib/lib.sh"

INPUT="$(ns_read_stdin_bounded 2)"
HOST_DIR="${CLAUDE_PROJECT_DIR:-}"
if command -v jq >/dev/null 2>&1; then
  NAME="$(printf '%s' "$INPUT" | jq -r '.command_name // empty' 2>/dev/null || true)"
  [ -n "$HOST_DIR" ] || HOST_DIR="$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)"
else
  NAME="$(printf '%s' "$INPUT" | sed -n 's/.*"command_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
  [ -n "$HOST_DIR" ] || HOST_DIR="$(printf '%s' "$INPUT" | sed -n 's/.*"cwd"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
fi
WORD="$(ns_plan_room_exit_word "/$NAME")" || exit 0
[ -n "$HOST_DIR" ] || exit 0
PROJECT_DIR="$(ns_workspace_root "$HOST_DIR" 2>/dev/null)" || exit 0
NS="$PROJECT_DIR/.nightshift"
ns_plan_room_leave "$NS" "typed the $WORD command" || exit 0

CONTEXT="$(ns_plan_room_left_context "$WORD")"
if command -v jq >/dev/null 2>&1; then
  jq -nc --arg c "$CONTEXT" '{hookSpecificOutput:{hookEventName:"UserPromptExpansion",additionalContext:$c}}'
else
  printf '{"hookSpecificOutput":{"hookEventName":"UserPromptExpansion","additionalContext":"%s"}}\n' "$CONTEXT"
fi
exit 0
