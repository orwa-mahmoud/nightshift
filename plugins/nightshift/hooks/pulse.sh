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
  ns_pulse_owner_ok "$ns" "$sid" || return 0
  ns_report_enabled "${ns%/.nightshift}" || return 0
  [ "$(ns_report "${ns%/.nightshift}" usage)" != off ] || return 0
  # The shift's own start, stood up before the first reading so it sits at zero. A baseline taken
  # after spend had already accrued would swallow the first item's cost. The transcripts go with
  # it: whatever the setting-up conversation already wrote is where reading begins, not byte zero.
  case "$host" in
    claude)
      # shellcheck disable=SC2046 # each subagent path is its own argument
      ns_usage_mark_arm "$ns" "$src" $(ns_usage_subagents "$src" 2>/dev/null) || return 0
      ;;
    *) ns_usage_mark_arm "$ns" || return 0 ;;
  esac
  case "$host" in
    claude)
      offset="$(ns_usage_offset "$ns" "$src")"
      reading="$(ns_usage_read_claude "$src" "$offset" "$(ns_usage_carry "$ns" "$src")")" || return 0
      ns_usage_record "$ns" claude "$(printf '%s' "$reading" | cut -f3)" transcript-incremental \
        "$src" "$(printf '%s' "$reading" | cut -f2)" "$(printf '%s' "$reading" | cut -f1)" \
        "$(printf '%s' "$reading" | cut -f5)" || return 0
      # A Task-spawned agent writes its own transcript beside this one, and its usage is there
      # rather than in the parent. Each is its own segment, so a child that replays history it did
      # not spend cannot inflate the shift.
      ns_usage_subagents "$src" 2>/dev/null | while IFS= read -r agent; do
        [ -n "$agent" ] || continue
        reading="$(ns_usage_read_claude "$agent" "$(ns_usage_offset "$ns" "$agent")" "$(ns_usage_carry "$ns" "$agent")")" || continue
        ns_usage_record "$ns" claude "$(printf '%s' "$reading" | cut -f3)" transcript-incremental \
          "$agent" "$(printf '%s' "$reading" | cut -f2)" "$(printf '%s' "$reading" | cut -f1)" \
          "$(printf '%s' "$reading" | cut -f5)" || continue
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

# ns_usage_carry <nightshift-dir> <id> — the last response identity counted for this transcript.
#
# Handed back to the reader so a response whose lines straddle two reads is counted once. Empty for
# a transcript never read, which is right: there is no half-read response to skip.
ns_usage_carry() {
  local file line
  file="$(ns_usage_dir "$1")/segments.tsv"
  [ -f "$file" ] || return 0
  while IFS= read -r line; do
    case "$line" in
      "$2	"*)
        printf '%s' "$line" | cut -f8
        return 0
        ;;
    esac
  done <"$file"
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

# ns_pulse_receipts_enabled <project> — status 0 unless the owner turned receipts off.
ns_pulse_receipts_enabled() {
  [ "$(ns_receipts "$1" enabled)" != false ]
}

# ns_pulse_receipts_basename <label> — the file stem the notice names.
ns_pulse_receipts_basename() {
  ns_receipt_basename "$1"
}

# ns_pulse_receipts_sections <project> — the approach clause on an item-start notice.
ns_pulse_receipts_sections() {
  local path
  path="$(ns_receipts "$1" templatePath 2>/dev/null)" || path=""
  if [ -n "$path" ]; then
    printf 'follow the owner'\''s template at %s' "$path"
    return 0
  fi
  printf 'sections: What was delivered · Why · Tried and rejected · Verification · Outputs · Parked decisions and snags.'
}

# ns_pulse_receipts_start_line <project> <label>
ns_pulse_receipts_start_line() {
  printf 'receipts: item %s started — open .nightshift/receipts/%s.md with one paragraph on the approach; %s' \
    "$2" "$(ns_pulse_receipts_basename "$2")" "$(ns_pulse_receipts_sections "$1")"
}

# ns_pulse_receipts_tick_line <label>
ns_pulse_receipts_tick_line() {
  printf 'receipts: item %s is ticked — write its closing paragraph in .nightshift/receipts/%s.md now, before starting the next item.' \
    "$1" "$(ns_pulse_receipts_basename "$1")"
}

# ns_pulse_receipts_cadence_line <label>
ns_pulse_receipts_cadence_line() {
  printf 'receipts: progress update due for %s — refresh the progress paragraph in .nightshift/receipts/%s.md: where it stands, what is left.' \
    "$1" "$(ns_pulse_receipts_basename "$1")"
}

# ns_pulse_ticked_labels <project> — every ticked item label, punch-list order, one per line.
ns_pulse_ticked_labels() {
  local punch="$1/.nightshift/punch-list.md"
  [ -f "$punch" ] || return 0
  ns_items_section "$punch" 2>/dev/null | awk '
    /^- \[[xX]\]/ {
      line = $0
      sub(/^- \[[xX]\][[:space:]]*\*\*/, "", line)
      sub(/^- \[[xX]\][[:space:]]*/, "", line)
      sub(/[[:space:]]+—.*$/, "", line)
      sub(/[[:space:]]+-[[:space:]].*$/, "", line)
      sub(/\*\*.*$/, "", line)
      gsub(/[[:space:]]+$/, "", line)
      if (line != "") print line
    }
  '
}

# Previous-pulse facts live under usage/, never in the punch list.
ns_pulse_previous_file() { printf '%s/usage/previous-pulse' "$1"; }
ns_pulse_previous_ticked_file() { printf '%s/usage/previous-ticked' "$1"; }

ns_pulse_previous_get() { # <ns> <key>
  local file line
  file="$(ns_pulse_previous_file "$1")"
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "$2	"*)
        printf '%s' "${line#*$'\t'}"
        return 0
        ;;
    esac
  done <"$file"
  return 1
}

ns_pulse_previous_write() { # <ns> <active> <ticked>
  local dir file
  dir="$1/usage"
  mkdir -p "$dir" 2>/dev/null || return 0
  [ -L "$dir" ] && return 0
  file="$(ns_pulse_previous_file "$1")"
  [ -L "$file" ] && rm -f "$file"
  printf 'active\t%s\nticked\t%s\n' "$2" "$3" >"$file" 2>/dev/null || :
}

# ns_pulse_report_due <ns> <project> — the cadence line, or nothing.
#
# The notice is written to a marker before it is emitted, and cleared when the item's receipt
# file changes or the item is ticked. A marker that names a different item than the one now
# open is rewritten. A revived session still finds the notice; nothing repeats until the window
# resets, so a long pause is one overdue notice rather than one per minute that passed.
ns_pulse_report_due() {
  local ns="$1" project="$2" label due want
  [ -f "$ns/.shift-armed" ] || return 1
  ns_pulse_receipts_enabled "$project" || return 1
  label="$(ns_pulse_active_item "$project")" || return 1
  [ -n "$label" ] || return 1
  want="$(ns_pulse_receipts_cadence_line "$label")"
  if [ -f "$ns/.receipt-due" ] && [ ! -L "$ns/.receipt-due" ]; then
    due="$(cat "$ns/.receipt-due" 2>/dev/null)" || due=""
    case "$due" in
      *"for ${label} —"*|*"for ${label}")
        printf '%s' "$due"
        return 0
        ;;
    esac
    # The marker names a different item than the one now open — regenerate.
  fi
  ns_usage_progress_due "$project" "$label" || {
    # Stale marker for another item: still rewrite so the next pulse names this one.
    if [ -n "${due:-}" ]; then
      printf '%s' "$want" >"$ns/.receipt-due" 2>/dev/null || return 1
      printf '%s' "$want"
      return 0
    fi
    return 1
  }
  printf '%s' "$want" >"$ns/.receipt-due" 2>/dev/null || return 1
  printf '%s' "$want"
}

# ns_pulse_receipts_notice <ns> <project> — start, tick, and cadence lines for this pulse.
#
# Previous-pulse facts are read and rewritten here. Each line is injected once for a change;
# identical cadence text is not re-emitted after the item it names has been ticked.
ns_pulse_receipts_notice() {
  local ns="$1" project="$2" prev_active prev_ticked active ticked line first=1 due
  local labels_file
  [ -f "$ns/.shift-armed" ] || return 1
  ns_pulse_receipts_enabled "$project" || return 1
  prev_active="$(ns_pulse_previous_get "$ns" active 2>/dev/null)" || prev_active=""
  prev_ticked="$(ns_pulse_previous_get "$ns" ticked 2>/dev/null)" || prev_ticked="0"
  case "$prev_ticked" in '' | *[!0-9]*) prev_ticked=0 ;; esac
  active="$(ns_pulse_active_item "$project" 2>/dev/null)" || active=""
  ticked="$(ns_ticked_boxes "$ns/punch-list.md" 2>/dev/null)" || ticked=0
  case "$ticked" in '' | *[!0-9]*) ticked=0 ;; esac
  labels_file="$(ns_pulse_previous_ticked_file "$ns")"
  mkdir -p "$ns/usage" 2>/dev/null || :
  : >"$ns/usage/.ticked-now"
  ns_pulse_ticked_labels "$project" >"$ns/usage/.ticked-now" 2>/dev/null || :
  if [ "$ticked" -gt "$prev_ticked" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      [ -n "$line" ] || continue
      if [ -f "$labels_file" ] && [ ! -L "$labels_file" ]; then
        grep -Fqx -- "$line" "$labels_file" 2>/dev/null && continue
      fi
      if [ "$first" -eq 1 ]; then
        printf '%s' "$(ns_pulse_receipts_tick_line "$line")"
        first=0
      else
        printf '\n%s' "$(ns_pulse_receipts_tick_line "$line")"
      fi
    done <"$ns/usage/.ticked-now"
  fi
  if [ -n "$active" ] && [ "$active" != "$prev_active" ]; then
    if [ "$first" -eq 1 ]; then
      printf '%s' "$(ns_pulse_receipts_start_line "$project" "$active")"
      first=0
    else
      printf '\n%s' "$(ns_pulse_receipts_start_line "$project" "$active")"
    fi
  fi
  due="$(ns_pulse_report_due "$ns" "$project" 2>/dev/null)" || due=""
  if [ -n "$due" ]; then
    if [ "$first" -eq 1 ]; then
      printf '%s' "$due"
      first=0
    else
      printf '\n%s' "$due"
    fi
  fi
  ns_pulse_previous_write "$ns" "$active" "$ticked"
  if [ -L "$labels_file" ]; then
    rm -f "$labels_file"
  fi
  if [ -d "$ns/usage" ] && [ ! -L "$ns/usage" ]; then
    mv "$ns/usage/.ticked-now" "$labels_file" 2>/dev/null || :
  fi
  [ "$first" -eq 0 ]
}

# ns_pulse_active_item <project> — the first still-open item, which is the one being worked.
ns_pulse_active_item() {
  local punch="$1/.nightshift/punch-list.md"
  [ -f "$punch" ] || return 1
  ns_items_section "$punch" 2>/dev/null | awk '
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
ns_pulse_marks() { # <ns> <project> <sid> [transcript]
  local ns="$1" project="$2" sid="$3" src="${4:-}" punch ticked core
  [ -d "$ns" ] || return 0
  # The same three conditions the reading itself needs: an armed shift, owned by this session, with
  # the report on. Anything else is a to-do list in a folder, and it is not billed.
  [ -f "$ns/.shift-armed" ] || return 0
  ns_pulse_owner_ok "$ns" "$sid" || return 0
  ns_report_enabled "$project" || return 0
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
  ns_gate_usage_sync "$ns" "$project" "$punch" "$ticked" "$src" || return 0
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
  INPUT="$(ns_read_stdin_bounded 2)"
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
  ns_pulse_marks "$NS" "$PROJECT_DIR" "$SID" "$TPATH"
  if ns_pulse_owner_ok "$NS" "$SID"; then
    ns_pulse_context claude "$(ns_pulse_receipts_notice "$NS" "$PROJECT_DIR")"
  fi
  exit 0
fi
