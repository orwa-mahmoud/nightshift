#!/usr/bin/env bash
# lib-io.sh — the Cursor adaptation seam. Every byte of Cursor's wire format lives here and
# nowhere else: stdin fields, stop follow-ups, and preToolUse denials. Decision hooks never
# parse or print protocol themselves.
#
# Contract: https://cursor.com/docs/hooks
#   common: conversation_id, session_id, transcript_path, cwd, workspace_roots, ...
#   stop input: status completed|aborted|error, loop_count
#   stop output: {"followup_message":"..."} to continue; empty stdout to allow stop
#   preToolUse deny: {"permission":"deny","agent_message":"..."}
#   sessionEnd: reason completed|aborted|error|window_close|user_close (fire-and-forget)

# cursor_read_input — stdin to fields, exported for the caller:
#   CURSOR_SESSION_ID  CURSOR_TRANSCRIPT_PATH  CURSOR_TOOL_NAME  CURSOR_TOOL_CMD
#   CURSOR_CWD         CURSOR_STOP_STATUS      CURSOR_SESSION_END_REASON  CURSOR_RAW
cursor_read_input() {
  # Hooks receive JSON on stdin, read under a bound: Cursor has been observed to deliver an
  # empty stdin on stop while still setting CURSOR_PROJECT_DIR, and to hand over a descriptor
  # that never closes. Either way the fallbacks below are reached — $1, then HOOK_INPUT.
  CURSOR_RAW="$(ns_read_stdin_bounded 2)"
  if [ -z "$CURSOR_RAW" ] && [ -n "${1:-}" ]; then
    CURSOR_RAW="$1"
  fi
  if [ -z "$CURSOR_RAW" ]; then
    CURSOR_RAW="${CURSOR_HOOK_INPUT:-${HOOK_INPUT:-}}"
  fi
  if command -v jq >/dev/null 2>&1; then
    CURSOR_SESSION_ID="$(printf '%s' "$CURSOR_RAW" | jq -r '.conversation_id // .session_id // empty' 2>/dev/null || true)"
    CURSOR_TRANSCRIPT_PATH="$(printf '%s' "$CURSOR_RAW" | jq -r '.transcript_path // empty' 2>/dev/null || true)"
    CURSOR_TOOL_NAME="$(printf '%s' "$CURSOR_RAW" | jq -r '.tool_name // empty' 2>/dev/null || true)"
    CURSOR_TOOL_CMD="$(printf '%s' "$CURSOR_RAW" | jq -r '.tool_input.command // .tool_input.cmd // empty' 2>/dev/null || true)"
    CURSOR_CWD="$(printf '%s' "$CURSOR_RAW" | jq -r '.cwd // .workspace_roots[0] // empty' 2>/dev/null || true)"
    CURSOR_STOP_STATUS="$(printf '%s' "$CURSOR_RAW" | jq -r '.status // empty' 2>/dev/null || true)"
    CURSOR_SESSION_END_REASON="$(printf '%s' "$CURSOR_RAW" | jq -r '.reason // empty' 2>/dev/null || true)"
    CURSOR_TOOL_FILEPATH="$(printf '%s' "$CURSOR_RAW" | jq -r '.tool_input.file_path // .tool_input.path // empty' 2>/dev/null || true)"
    CURSOR_PROMPT="$(printf '%s' "$CURSOR_RAW" | jq -r '.prompt // empty' 2>/dev/null || true)"
  else
    CURSOR_SESSION_ID="$(printf '%s' "$CURSOR_RAW" | sed -n 's/.*"conversation_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
    [ -n "$CURSOR_SESSION_ID" ] || CURSOR_SESSION_ID="$(printf '%s' "$CURSOR_RAW" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
    CURSOR_TRANSCRIPT_PATH="$(printf '%s' "$CURSOR_RAW" | sed -n 's/.*"transcript_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
    CURSOR_TOOL_NAME="$(printf '%s' "$CURSOR_RAW" | sed -n 's/.*"tool_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
    CURSOR_TOOL_CMD="$(printf '%s' "$CURSOR_RAW" | sed -n 's/.*"command"[[:space:]]*:[[:space:]]*"\(.*\)".*/\1/p')"
    CURSOR_CWD="$(printf '%s' "$CURSOR_RAW" | sed -n 's/.*"cwd"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
    CURSOR_STOP_STATUS="$(printf '%s' "$CURSOR_RAW" | sed -n 's/.*"status"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
    CURSOR_SESSION_END_REASON="$(printf '%s' "$CURSOR_RAW" | sed -n 's/.*"reason"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
    CURSOR_TOOL_FILEPATH="$(printf '%s' "$CURSOR_RAW" | sed -n 's/.*"file_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
    CURSOR_PROMPT="$(printf '%s' "$CURSOR_RAW" | sed -n 's/.*"prompt"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
  fi
  [ -n "$CURSOR_TOOL_CMD" ] || CURSOR_TOOL_CMD="$CURSOR_RAW"
  [ -n "$CURSOR_TRANSCRIPT_PATH" ] || CURSOR_TRANSCRIPT_PATH="${CURSOR_TRANSCRIPT_PATH_ENV:-}"
  export CURSOR_RAW CURSOR_SESSION_ID CURSOR_TRANSCRIPT_PATH CURSOR_TOOL_NAME \
    CURSOR_TOOL_CMD CURSOR_CWD CURSOR_STOP_STATUS CURSOR_SESSION_END_REASON \
    CURSOR_TOOL_FILEPATH CURSOR_PROMPT
}

cursor_input_mentions_tool() {
  printf '%s' "${CURSOR_RAW:-}" | grep -q '"tool_name"[[:space:]]*:[[:space:]]*"'"$1"'"'
}

cursor_project_dir() {
  printf '%s' "${CURSOR_PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-${CURSOR_CWD:-$PWD}}}"
}

_cursor_json_escape() {
  printf '%s' "$1" | tr -d '\000-\037' | sed 's/\\/\\\\/g; s/"/\\"/g'
}

# cursor_emit_block <reason> — documented stop continuation via followup_message.
cursor_emit_block() {
  if command -v jq >/dev/null 2>&1; then
    jq -nc --arg r "$1" '{followup_message:$r}'
  else
    printf '{"followup_message":"%s"}\n' "$(_cursor_json_escape "$1")"
  fi
}

# cursor_emit_release — permitted stop: empty stdout, exit 0.
cursor_emit_release() {
  :
}

# cursor_emit_prompt_block <reason> — documented beforeSubmitPrompt denial.
cursor_emit_prompt_block() {
  if command -v jq >/dev/null 2>&1; then
    jq -nc --arg r "$1" '{continue:false,user_message:$r}'
  else
    printf '{"continue":false,"user_message":"%s"}\n' "$(_cursor_json_escape "$1")"
  fi
}

# cursor_emit_deny <reason> — documented preToolUse denial.
cursor_emit_deny() {
  if command -v jq >/dev/null 2>&1; then
    jq -nc --arg r "$1" '{permission:"deny",agent_message:$r,user_message:$r}'
  else
    printf '{"permission":"deny","agent_message":"%s","user_message":"%s"}\n' \
      "$(_cursor_json_escape "$1")" "$(_cursor_json_escape "$1")"
  fi
}
