#!/usr/bin/env bash
# pulse.sh — shared overwrite-only writer for .nightshift/.shift-pulse.
#
# Host wrappers parse stdin, then call ns_pulse_emit with the bound session id.
# One line: epoch<space>session-id. Identity check, not the lease: helpers never
# write; Cursor origin IDE stops writing once .shift-worker exists.
# Inert outside an active shift (same as session-end). Silent stdout.
#
# When executed (Claude PostToolUse), parse session_id from stdin and CLAUDE_PROJECT_DIR.

ns_pulse_owner_ok() { # <ns> <sid>
  local rec worker
  [ -n "${2:-}" ] || return 1
  worker="$(ns_cursor_worker_id "$1")"
  if [ -n "$worker" ]; then
    [ "$2" = "$worker" ]
    return
  fi
  rec="$(ns_session_line "$1" 1)"
  [ -n "$rec" ] && [ "$2" = "$rec" ]
}

ns_pulse_emit() { # <ns> <sid>
  local ns="$1" sid="$2" punch epoch open
  [ -n "$ns" ] && [ -n "$sid" ] || return 0
  punch="$ns/punch-list.md"
  if [ ! -f "$ns/.shift-armed" ] || [ ! -f "$punch" ] \
    || { [ -f "$ns/.ended" ] && [ ! -L "$ns/.ended" ]; }; then
    return 0
  fi
  # A failed count is not zero. The session is alive either way, so the pulse stands.
  open="$(ns_open_boxes "$punch")" || open=1
  [ "$open" -gt 0 ] || return 0
  ns_pulse_owner_ok "$ns" "$sid" || return 0
  epoch="$(date +%s)"
  [ -L "$ns/.shift-pulse" ] && rm -f "$ns/.shift-pulse"
  printf '%s %s\n' "$epoch" "$sid" >"$ns/.shift-pulse"
  return 0
}


# ns_pulse_usage <ns> <host> <sid> <transcript-or-payload> — take one reading, if the owner wants
# usage measured and this session owns the shift.
#
# The pulse already fires on every tool call on all three hosts, so the reading rides on something
# that was going to happen anyway: no daemon, no timer, no polling, no second session. On Claude it
# advances the transcript offset and reads only the appended bytes; on Codex it tails the rollout's
# running total; on Cursor there is no transcript and the figures arrive on the payload itself.
#
# Silent, and never fatal: a host that reports nothing leaves no snapshot, and the report says
# `unavailable` rather than zero.
ns_pulse_usage() {
  local ns="$1" host="$2" sid="$3" src="$4" reading fields offset model
  [ -n "$ns" ] && [ -n "$src" ] || return 0
  [ -f "$ns/.shift-armed" ] || return 0
  [ "$(ns_report "${ns%/.nightshift}" usage)" != off ] || return 0
  # The shift's own start, stood up before the first reading so it sits at zero. A baseline taken
  # after spend had already accrued would swallow the first item's cost.
  ns_usage_mark_arm "$ns" || return 0
  case "$host" in
    claude)
      offset="$(ns_usage_offset "$ns" "$src")"
      reading="$(ns_usage_read_claude "$src" "$offset")" || return 0
      ns_usage_record "$ns" claude "$(printf '%s' "$reading" | cut -f3)" transcript-incremental \
        "$src" "$(printf '%s' "$reading" | cut -f2)" "$(printf '%s' "$reading" | cut -f1)" || return 0
      # A Task-spawned agent writes its own transcript beside this one, and its usage is there
      # rather than in the parent. Each is its own segment, so a child that replays history it did
      # not spend cannot inflate the shift.
      ns_usage_subagents "$src" 2>/dev/null | while IFS= read -r agent; do
        [ -n "$agent" ] || continue
        reading="$(ns_usage_read_claude "$agent" "$(ns_usage_offset "$ns" "$agent")")" || continue
        ns_usage_record "$ns" claude "$(printf '%s' "$reading" | cut -f3)" transcript-incremental \
          "$agent" "$(printf '%s' "$reading" | cut -f2)" "$(printf '%s' "$reading" | cut -f1)" || continue
      done
      ;;
    codex)
      reading="$(ns_usage_read_codex "$src")" || return 0
      ns_usage_record "$ns" codex "$(printf '%s' "$reading" | cut -f3)" rollout \
        "$src" 0 "$(printf '%s' "$reading" | cut -f1)" || return 0
      ;;
    cursor)
      reading="$(ns_usage_read_cursor "$src")" || return 0
      ns_usage_record "$ns" cursor "$(printf '%s' "$reading" | cut -f3)" stop-payload \
        "cursor:$sid" 0 "$(printf '%s' "$reading" | cut -f1)" || return 0
      ;;
    *) return 0 ;;
  esac
  return 0
}

# ns_usage_offset <ns> <transcript> — the byte offset this transcript was last read to.
ns_usage_offset() {
  local file line
  file="$(ns_usage_dir "$1")/segments.tsv"
  [ -f "$file" ] || { printf '0'; return 0; }
  while IFS= read -r line; do
    case "$line" in
      "$2	"*)
        printf '%s' "$line" | cut -f5
        return 0
        ;;
    esac
  done <"$file"
  printf '0'
}

# ns_pulse_report_due <ns> <project> — the one line that tells the model an update is due, or
# nothing.
#
# The notice is written to a marker before it is emitted, and cleared when the item's section
# changes. A revived session, or a host that dropped the hook's output, still finds the notice at
# the next pulse; nothing repeats until the window resets, so a long pause is one overdue notice
# rather than one per minute that passed.
ns_pulse_report_due() {
  local ns="$1" project="$2" label
  [ -f "$ns/.shift-armed" ] || return 1
  [ "$(ns_report "$project" enabled)" != false ] || return 1
  label="$(ns_pulse_active_item "$project")" || return 1
  [ -n "$label" ] || return 1
  if [ -f "$ns/.report-due" ] && [ ! -L "$ns/.report-due" ]; then
    printf '%s' "$(cat "$ns/.report-due" 2>/dev/null)"
    return 0
  fi
  ns_usage_progress_due "$project" "$label" || return 1
  printf 'report: progress update due for %s' "$label" >"$ns/.report-due" 2>/dev/null || return 1
  printf 'report: progress update due for %s' "$label"
}

# ns_pulse_active_item <project> — the first still-open item, which is the one being worked.
ns_pulse_active_item() {
  local punch="$1/.nightshift/punch-list.md"
  [ -f "$punch" ] || return 1
  ns_items_section "$punch" 2>/dev/null | awk '
    /^- \[ \]/ {
      line = $0
      sub(/^- \[ \][[:space:]]*\*\*/, "", line)
      sub(/[[:space:]]*[—-].*$/, "", line)
      sub(/\*\*.*$/, "", line)
      gsub(/[[:space:]]+$/, "", line)
      print line
      exit
    }
  '
}

# ns_pulse_context <host> <line> — the notice in the field each host documents for model-visible
# context. Claude Code and Codex read hookSpecificOutput.additionalContext; Cursor reads
# additional_context. Silent when there is nothing to say, so an ordinary pulse stays silent.
ns_pulse_context() {
  local host="$1" line="$2" escaped
  [ -n "$line" ] || return 0
  if command -v jq >/dev/null 2>&1; then
    case "$host" in
      cursor) jq -nc --arg c "$line" '{additional_context:$c}' ;;
      *) jq -nc --arg c "$line" '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:$c}}' ;;
    esac
    return 0
  fi
  escaped="$(printf '%s' "$line" | tr -d '\000-\037' | sed 's/\\/\\\\/g; s/"/\\"/g')"
  case "$host" in
    cursor) printf '{"additional_context":"%s"}\n' "$escaped" ;;
    *) printf '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"%s"}}\n' "$escaped" ;;
  esac
}

# ns_pulse_marks <ns> <project> — mark every item ticked since the last mark, at this moment.
#
# The gate marks on a stop attempt, so two items ticked between stops both get the reading taken at
# the stop: the first is billed everything since the previous mark and the second nothing. The pulse
# fires on the PostToolUse of the edit that ticked the box, so a mark taken here carries the reading
# at the moment the work finished.
#
# It calls the gate's own sync rather than a parallel loop. One code path writes the marks and the
# report lines, whichever side gets there first, and the gate stays as the catch-up for a pulse that
# never fired.
ns_pulse_marks() {
  local ns="$1" project="$2" punch ticked core
  [ -d "$ns" ] || return 0
  punch="$ns/punch-list.md"
  [ -f "$punch" ] || return 0
  # This file's own directory, never the caller's. The Codex and Cursor pulses source this file and
  # set `_here` to their own folder, which has no `shared/` in it.
  core="${BASH_SOURCE[0]%/*}"
  [ "$core" != "${BASH_SOURCE[0]}" ] || core=.
  core="$core/shared/gate-core.sh"
  if ! command -v ns_gate_usage_sync >/dev/null 2>&1; then
    [ -f "$core" ] || return 0
    # shellcheck source=plugins/nightshift/hooks/shared/gate-core.sh
    . "$core" || return 0
  fi
  ticked="$(ns_ticked_boxes "$punch" 2>/dev/null)" || return 0
  case "$ticked" in '' | *[!0-9]*) return 0 ;; esac
  ns_gate_usage_sync "$ns" "$project" "$punch" "$ticked" || return 0
}

# Executed as the Claude wrapper: parse stdin, emit, stay silent.
#
# This block is last on purpose. Bash defines a function when it reaches the definition, so a
# block placed above them runs with those names undefined: the calls below would write
# "command not found" to stderr and the hook would still exit 0, recording nothing. Every test
# that sources this file and calls its functions passes either way.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -u
  _here="${BASH_SOURCE[0]%/*}"; [ "$_here" != "${BASH_SOURCE[0]}" ] || _here=.
  # shellcheck source=plugins/nightshift/lib/lib.sh
  . "$_here/../lib/lib.sh"
  INPUT="$(cat)"
  HOST_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
  PROJECT_DIR="$(ns_workspace_root "$HOST_DIR" 2>/dev/null)" || exit 0
  STATE_KIND="$(ns_state_kind "$PROJECT_DIR")"
  case "$STATE_KIND" in
    malformed | future) exit 0 ;;
  esac
  NS="$PROJECT_DIR/.nightshift"
  if command -v jq >/dev/null 2>&1; then
    SID="$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)"
  else
    SID="$(printf '%s' "$INPUT" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
  fi
  if command -v jq >/dev/null 2>&1; then
    TPATH="$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null || true)"
  else
    TPATH="$(printf '%s' "$INPUT" | sed -n 's/.*"transcript_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
  fi
  ns_pulse_emit "$NS" "$SID"
  ns_pulse_usage "$NS" claude "$SID" "$TPATH"
  ns_pulse_marks "$NS" "$PROJECT_DIR"
  ns_pulse_context claude "$(ns_pulse_report_due "$NS" "$PROJECT_DIR")"
  exit 0
fi
