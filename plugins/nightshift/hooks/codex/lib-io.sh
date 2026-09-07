#!/usr/bin/env bash
# lib-io.sh — the Codex adaptation seam. Every byte of Codex's wire format lives here and
# nowhere else: what arrives on stdin, what a block or a denial looks like on stdout, and how
# a hook finds the project. The decision hooks beside this file never parse or print protocol
# themselves, so a change in Codex's contract lands here and the decisions do not move.
#
# Contract: https://developers.openai.com/codex/hooks. Every hook receives one JSON object on
# stdin (session_id, transcript_path as string|null, cwd, tool_name, tool_input, ...). A Stop
# hook forces continuation with {"decision":"block","reason":...} — the reason becomes an
# automatic continuation prompt. Stop expects JSON on stdout whenever it exits 0 — the docs
# call plain text invalid for the event — so a permitted stop answers {"continue":true} rather
# than betting that silence parses as consent. A PreToolUse hook denies with the
# hookSpecificOutput permissionDecision shape; there, exit 0 with no output lets the call
# proceed (plain text on stdout is ignored for PreToolUse).

# codex_read_input — stdin to fields, exported for the caller:
#   CODEX_SESSION_ID  CODEX_TRANSCRIPT_PATH  CODEX_TOOL_NAME  CODEX_TOOL_CMD
#   CODEX_CWD         CODEX_TOOL_FILEPATH    CODEX_RAW
# session_id, transcript_path, cwd, and tool_name are the documented common fields;
# tool_input.command is the documented input for Bash and apply_patch — for apply_patch it
# carries the patch text itself. Stdin is read under a bound, so neither a manual run nor a
# descriptor that never closes hangs the hook. jq is preferred; the sed fallback keeps every
# guard alive on a box without it. When
# no command can be extracted the raw payload stands in as the match target — a broken parse
# must never disable a string guard.
codex_read_input() {
  CODEX_RAW="$(ns_read_stdin_bounded 2)"
  if command -v jq >/dev/null 2>&1; then
    CODEX_SESSION_ID="$(printf '%s' "$CODEX_RAW" | jq -r '.session_id // empty' 2>/dev/null || true)"
    CODEX_TRANSCRIPT_PATH="$(printf '%s' "$CODEX_RAW" | jq -r '.transcript_path // empty' 2>/dev/null || true)"
    CODEX_TOOL_NAME="$(printf '%s' "$CODEX_RAW" | jq -r '.tool_name // empty' 2>/dev/null || true)"
    CODEX_TOOL_CMD="$(printf '%s' "$CODEX_RAW" | jq -r '.tool_input.command // empty' 2>/dev/null || true)"
    CODEX_CWD="$(printf '%s' "$CODEX_RAW" | jq -r '.cwd // empty' 2>/dev/null || true)"
    # UNVERIFIED: tool_input.file_path — docs silent (MCP tools send their own arguments);
    # kept as a belt so an MCP-style editor that does carry it is still recognized.
    CODEX_TOOL_FILEPATH="$(printf '%s' "$CODEX_RAW" | jq -r '.tool_input.file_path // empty' 2>/dev/null || true)"
  else
    # Extract the command value rather than falling back to the whole payload here — a caller's
    # quote-scrub would otherwise strip the command string itself and a match would slip through.
    CODEX_SESSION_ID="$(printf '%s' "$CODEX_RAW" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
    CODEX_TRANSCRIPT_PATH="$(printf '%s' "$CODEX_RAW" | sed -n 's/.*"transcript_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
    CODEX_TOOL_NAME="$(printf '%s' "$CODEX_RAW" | sed -n 's/.*"tool_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
    CODEX_TOOL_CMD="$(printf '%s' "$CODEX_RAW" | sed -n 's/.*"command"[[:space:]]*:[[:space:]]*"\(.*\)".*/\1/p')"
    CODEX_CWD="$(printf '%s' "$CODEX_RAW" | sed -n 's/.*"cwd"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
    CODEX_TOOL_FILEPATH="$(printf '%s' "$CODEX_RAW" | sed -n 's/.*"file_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
  fi
  [ -n "$CODEX_TOOL_CMD" ] || CODEX_TOOL_CMD="$CODEX_RAW"
  export CODEX_RAW CODEX_SESSION_ID CODEX_TRANSCRIPT_PATH CODEX_TOOL_NAME \
    CODEX_TOOL_CMD CODEX_CWD CODEX_TOOL_FILEPATH
}

# codex_input_mentions_tool <name> — true when the raw payload names the tool even though
# field extraction failed. The belt under the parse: a mangled payload must still trip the
# rules keyed to a tool's name.
codex_input_mentions_tool() {
  printf '%s' "${CODEX_RAW:-}" | grep -q '"tool_name"[[:space:]]*:[[:space:]]*"'"$1"'"'
}

# codex_project_dir — where the shift lives. The documented carrier is the payload's cwd, and
# hooks run with the session cwd as their working directory, so $PWD is its twin.
# UNVERIFIED: CODEX_PROJECT_DIR — docs name no project-dir env var for hooks; honored first as
# an explicit override for harnesses and for sessions rooted below the project.
codex_project_dir() {
  printf '%s' "${CODEX_PROJECT_DIR:-${CODEX_CWD:-$PWD}}"
}

# The emitters interpolate owner config and git output; escaping lives here so a stray quote
# or backslash can never break the JSON and void the decision.
_codex_json_escape() {
  printf '%s' "$1" | tr -d '\000-\037' | sed 's/\\/\\\\/g; s/"/\\"/g'
}

# codex_emit_block <reason> — the documented Stop continuation: Codex turns the reason into an
# automatically created continuation prompt that acts as a new user prompt.
codex_emit_block() {
  if command -v jq >/dev/null 2>&1; then
    jq -nc --arg r "$1" '{decision:"block",reason:$r}'
  else
    printf '{"decision":"block","reason":"%s"}\n' "$(_codex_json_escape "$1")"
  fi
}

# codex_emit_release — the documented no-op for a permitted stop. Static JSON, no
# interpolation, so no escaping and no jq dependency.
codex_emit_release() {
  printf '{"continue":true}\n'
}

# codex_emit_deny <reason> — the documented PreToolUse denial; the model reads
# permissionDecisionReason back.
codex_emit_deny() {
  if command -v jq >/dev/null 2>&1; then
    jq -nc --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  else
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$(_codex_json_escape "$1")"
  fi
}
