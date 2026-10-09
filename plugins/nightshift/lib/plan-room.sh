#!/usr/bin/env bash
# plan-room.sh — a planning conversation that implements nothing until the owner leaves it.
#
# Entering writes the marker unbound; the next tool call, a probe, binds it to the conversation that
# made it, the way Start binds a shift. While it binds a conversation, hardhat holds that
# conversation to reading and to writing the plan into the staging folder. Other conversations in
# the project work normally. No conversation may touch the marker: only the owner leaves.
#
# The marker is three lines: the bound conversation (empty until the probe), its host, and when the
# room was entered.

ns_plan_room_file() { ns_layout_path "$1" plan-room; }

# ns_plan_room_open <nightshift-dir> — status 0 while the plan room is open.
ns_plan_room_open() {
  local f
  f="$(ns_plan_room_file "$1")" || return 1
  [ -f "$f" ] && [ ! -L "$f" ]
}

# ns_plan_room_line <nightshift-dir> <n> — one line of the marker.
ns_plan_room_line() {
  ns_plan_room_open "$1" || return 1
  sed -n "${2}p" "$(ns_plan_room_file "$1")" | tr -d '\r'
}

# ns_plan_room_enter <nightshift-dir> <host> — open the room, unbound. An open room is left as it is.
ns_plan_room_enter() {
  local f
  ns_plan_room_open "$1" && return 0
  f="$(ns_plan_room_file "$1")" || return 1
  [ ! -L "$f" ] || return 1
  mkdir -p "${f%/*}" 2>/dev/null || return 1
  printf '\n%s\n%s\n' "$2" "$(date +%s)" >"$f"
}

# ns_plan_room_bind <nightshift-dir> <session> <host> — bind an unbound room to this conversation.
# Status 1 when the room is already bound to another one or there is no session to bind.
ns_plan_room_bind() {
  local rc=0
  [ -n "$2" ] || return 1
  ns_lock "$1" || return 1
  _ns_plan_room_bind_locked "$@" || rc=$?
  ns_unlock "$1"
  return "$rc"
}

_ns_plan_room_bind_locked() {
  local f bound tmp
  bound="$(ns_plan_room_line "$1" 1)" || return 1
  if [ -n "$bound" ]; then
    [ "$bound" = "$2" ]
    return
  fi
  f="$(ns_plan_room_file "$1")"
  tmp="$f.$$"
  printf '%s\n%s\n%s\n' "$2" "$3" "$(ns_plan_room_line "$1" 3)" >"$tmp" && mv "$tmp" "$f"
}

# ns_plan_room_binds <nightshift-dir> <session> — status 0 when the open room binds this conversation.
ns_plan_room_binds() {
  local bound
  [ -n "${2:-}" ] || return 1
  bound="$(ns_plan_room_line "$1" 1)" || return 1
  [ -n "$bound" ] && [ "$bound" = "$2" ]
}

# ns_plan_room_place <nightshift-dir> — where the plan is written: the staging folder, or in a
# workspace laid out before it existed, the drafting table.
ns_plan_room_place() {
  ns_layout_path "$1" staging 2>/dev/null || ns_layout_path "$1" drafting-table
}

# ns_plan_room_place_name <nightshift-dir> — that place as a message names it.
ns_plan_room_place_name() {
  local rel
  if ns_layout_rel_set rel "$1" staging; then
    printf '.nightshift/%s/' "$rel"
  else
    ns_layout_name "$1" drafting-table
  fi
}

# ns_plan_room_message <nightshift-dir> — what the planning conversation is told when it reaches for
# something the plan room does not allow.
ns_plan_room_message() {
  printf 'BLOCKED: the plan room is open, so nothing is implemented in this conversation. Tell the owner they are in the plan room and that this change was not made. Here you read, explore and write the plan into %s. To build, the owner leaves the plan room: they type /nightshift:plan-exit, or approve the plan and type /nightshift:start.' \
    "$(ns_plan_room_place_name "$1")"
}

# ns_plan_room_marker_message — what any conversation is told when it reaches for the marker.
ns_plan_room_marker_message() {
  printf 'BLOCKED: the plan room marker is the owner'"'"'s. Only the owner leaves the plan room, with /nightshift:plan-exit or by typing /nightshift:start.'
}

# ns_plan_room_withdraw <nightshift-dir> <session> — take back a room that was never bound, because
# the conversation that asked for it is working the shift: fencing it would leave the shift unable to
# work or to clock out.
ns_plan_room_withdraw() {
  [ -z "$(ns_plan_room_line "$1" 1)" ] || return 1
  rm -f "$(ns_plan_room_file "$1")" 2>/dev/null || return 1
  ns_shift_log "$1" "plan room not opened: conversation $2 is working the shift"
}

# ns_plan_room_on_shift_message — what that conversation is told.
ns_plan_room_on_shift_message() {
  printf 'BLOCKED: this conversation is working the shift, so it cannot enter the plan room, and the plan room was not opened. Plan in another conversation, or stop the shift first.'
}

# The words that close a plan-record entry, after a ` · ` separator. Archive files those entries
# with their shift; the others are plans still being worked out.
NS_PLAN_RECORD_CLOSED='captured|dropped'

# ns_open_entries <file> <dispositions> — the first line of each `- ` entry that carries none of the
# dispositions: below the file's rule, or anywhere in a file that has none.
ns_open_entries() {
  [ -f "$1" ] && [ ! -L "$1" ] || return 0
  awk -v op=open -v dispositions="$2" -f "$_NS_INBOX_AWK" "$1" | tr -d '\r'
}

# ns_plan_record_open <nightshift-dir> — the first line of each open plan in the plan record.
ns_plan_record_open() {
  local f
  ns_layout_set f "$1" plan-record || return 0
  ns_open_entries "$f" "$NS_PLAN_RECORD_CLOSED"
}

# ns_plan_room_exit_word <prompt> — `plan-exit` or `start` when the owner's prompt is an exit
# command: its first word is /nightshift:plan-exit or /nightshift:start, or the same name after `$`,
# the way Codex mentions a skill. Anything else, the same words mid-sentence included, is not.
ns_plan_room_exit_word() {
  local first
  first="$(printf '%s\n' "$1" | tr -d '\r' | awk 'NF { print $1; exit }')"
  case "$first" in
    /nightshift:plan-exit | "\$nightshift:plan-exit") printf 'plan-exit' ;;
    /nightshift:start | "\$nightshift:start") printf 'start' ;;
    *) return 1 ;;
  esac
}

# ns_plan_room_leave <nightshift-dir> <how> — the owner leaves: the marker goes and the shift log
# says how. Status 1 when no room was open or the marker could not be removed.
ns_plan_room_leave() {
  local f bound
  ns_plan_room_open "$1" || return 1
  bound="$(ns_plan_room_line "$1" 1)"
  f="$(ns_plan_room_file "$1")"
  rm -f "$f" 2>/dev/null && [ ! -e "$f" ] || return 1
  ns_shift_log "$1" "plan room closed by the owner: $2${bound:+ (conversation $bound)}"
}

# ns_plan_room_left_context <word> — what the conversation is told after the owner's command closed
# the room.
ns_plan_room_left_context() {
  if [ "$1" = start ]; then
    printf 'nightshift: the owner left the plan room by starting the shift. Nothing is fenced any more.'
  else
    printf 'nightshift: the owner left the plan room. Nothing is fenced any more; to build the plan, promote it into the punch list and Start.'
  fi
}

# ns_plan_review <nightshift-dir> — what the plan room walks the owner through, one
# `review <kind> <text>` line each: the latest morning page and the receipts index, every parked
# decision and snag still open, and every item still open or stopped while no shift is running.
# `review none` when there is nothing. A workspace that Archive has filed reads what it left live.
ns_plan_review() {
  local ns="$1" dir name f punch armed ended any=0 line
  ns_layout_set dir "$ns" receipts
  name="$(ns_receipts_morning_names "$dir" | tail -n1)"
  if [ -n "$name" ]; then
    printf 'review morning %s/%s\n' "$(ns_layout_name "$ns" receipts)" "$name"
    any=1
  fi
  ns_layout_set f "$ns" receipts-index
  if [ -f "$f" ] && [ ! -L "$f" ]; then
    printf 'review receipts %s\n' "$(ns_layout_name "$ns" receipts-index)"
    any=1
  fi
  ns_layout_set f "$ns" parking-lot
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    printf 'review parked %s\n' "${line#- }"
    any=1
  done < <(ns_open_entries "$f" "$NS_REVIEW_DISPOSITIONS")
  ns_layout_set f "$ns" snag-log
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    printf 'review snag %s\n' "${line#- }"
    any=1
  done < <(ns_open_entries "$f" "$NS_REVIEW_DISPOSITIONS")
  ns_layout_set punch "$ns" punch-list
  ns_layout_set armed "$ns" armed
  ns_layout_set ended "$ns" ended
  # A running shift's items are that shift's to work, not the owner's to decide.
  if [ ! -f "$armed" ] || { [ -f "$ended" ] && [ ! -L "$ended" ]; }; then
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      printf 'review %s\n' "$line"
      any=1
    done < <(ns_punch_items "$punch" | awk '
      /^- \[ \]/ { kind = "open" }
      /^- \[-\]/ { kind = "stopped" }
      /^- \[( |-)\]/ {
        line = $0
        sub(/^- \[.\][[:space:]]*/, "", line)
        sub(/[[:space:]]*<!--.*-->[[:space:]]*$/, "", line)
        print kind " " line
      }')
  fi
  [ "$any" -eq 1 ] || printf 'review none\n'
}
