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
  mkdir -p "${f%/*}" 2>/dev/null || return 1
  printf '\n%s\n%s\n' "$2" "$(date +%s)" >"$f"
}

# ns_plan_room_bind <nightshift-dir> <session> <host> — bind an unbound room to this conversation.
# Status 1 when the room is already bound to another one or there is no session to bind.
ns_plan_room_bind() {
  local f bound tmp
  [ -n "$2" ] || return 1
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
