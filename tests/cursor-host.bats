#!/usr/bin/env bats
# The Cursor host, driven through its own hooks with its own wire format.
#
# tests/shared-hook-cores.bats proves these adapters carry the same core as Claude's, byte for
# byte. That is evidence about their contents and none about their entry points: what a Cursor
# user actually gets depends on the seam that reads Cursor's payload and writes Cursor's answer,
# and on the entry points reaching the core at all. These run the real hooks.

load helpers

CURSOR="$BATS_TEST_DIRNAME/../plugins/nightshift/hooks/cursor"
CURSOR_WATCHMAN="$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/cursor/watchman.sh"

# cursor_tool <project> <command> [ENV=VAL ...] — a preToolUse payload as Cursor sends it.
cursor_tool() {
  local p="$1" c="$2"
  shift 2
  jq -nc --arg c "$c" --arg w "$p" \
    '{tool_name:"Bash",conversation_id:"conv-1",cwd:$w,tool_input:{command:$c}}' |
    env "$@" CURSOR_PROJECT_DIR="$p" bash "$CURSOR/hardhat.sh"
}

# cursor_stop <project> — a stop payload as Cursor sends it.
cursor_stop() {
  local p="$1"
  shift
  jq -nc --arg w "$p" '{conversation_id:"conv-1",cwd:$w,status:"completed",loop_count:1}' |
    env "$@" CURSOR_PROJECT_DIR="$p" bash "$CURSOR/clock-out-gate.sh"
}

# Cursor denies with {"permission":"deny","agent_message":…} — its own shape, not Claude's.
cursor_denied() {
  printf '%s' "$1" | jq -e '.permission == "deny" and (.agent_message | length) > 0' >/dev/null
}
# Cursor keeps a session going with {"followup_message":…}; empty stdout lets it stop.
cursor_blocked() {
  printf '%s' "$1" | jq -e '(.followup_message | length) > 0' >/dev/null
}

@test "the Cursor guard denies the owner's forbidden command, in Cursor's own answer" {
  p="$(new_project cursor-forbidden)"
  punch_open "$p"
  run cursor_tool "$p" "git push origin HEAD" NIGHTSHIFT_FORBIDDEN_COMMANDS='git .*push'
  [ "$status" -eq 0 ]
  cursor_denied "$output" || { echo "not a Cursor denial: $output"; return 1; }
  printf '%s' "$output" | jq -r .agent_message | grep -qF 'forbidden list'
}

@test "the Cursor guard denies an elevation category the shift does not allow" {
  p="$(new_project cursor-elevation)"
  punch_open "$p"
  run cursor_tool "$p" "sudo apt-get install -y jq"
  cursor_denied "$output" || { echo "not a Cursor denial: $output"; return 1; }
  printf '%s' "$output" | jq -r .agent_message | grep -qF "needs allowance: sudo"
}

@test "the Cursor guard is inert when no shift is running" {
  p="$(new_project cursor-inert)"
  # new_project arms the site; an ordinary session is one that is not on shift.
  rm -f "$p/.nightshift/.shift-armed"
  run cursor_tool "$p" "sudo apt-get install -y jq"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "the Cursor guard reads a here-document the way Claude's does" {
  # The rule is the shared core's, but this proves the Cursor entry point reaches it: a quoted
  # documentation write passes and the same body fed to an interpreter does not.
  p="$(new_project cursor-heredoc)"
  punch_open "$p"
  run cursor_tool "$p" "$(printf "cat > docs/e.md <<'EOF'\nsudo and doas, docker run\nEOF")"
  [ -z "$output" ]
  run cursor_tool "$p" "$(printf "bash <<'EOF'\nsudo id\nEOF")"
  cursor_denied "$output" || { echo "an interpreter payload was allowed: $output"; return 1; }
}

@test "the Cursor gate keeps the session going while a box is open" {
  p="$(new_project cursor-gate-open)"
  punch_open "$p"
  run cursor_stop "$p"
  [ "$status" -eq 0 ]
  cursor_blocked "$output" || { echo "the gate let an unfinished shift stop: $output"; return 1; }
}

@test "the Cursor gate lets the session stop once every box is ticked" {
  p="$(new_project cursor-gate-done)"
  printf '## Items\n- [x] **1. done.**\n' >"$p/.nightshift/punch-list.md"
  run cursor_stop "$p"
  [ "$status" -eq 0 ]
  [ -z "$output" ] || { echo "the gate held a finished shift: $output"; return 1; }
  [ -f "$p/.nightshift/.ended" ]
  [ ! -f "$p/.nightshift/.shift-armed" ]
}

@test "the Cursor seam reads the same payload with no jq on PATH" {
  # The seam has a sed fallback for a host without jq. It has to find the same fields, or a
  # Cursor user without jq silently loses every guard.
  p="$(new_project cursor-no-jq)"
  punch_open "$p"
  bin="$p/bin"
  mkdir -p "$bin"
  for tool in bash sh sed grep awk tr cat sort head cut date env dirname basename ls mv cp rm find wc mkdir printf git; do
    src="$(command -v "$tool" 2>/dev/null)" || continue
    ln -sf "$src" "$bin/$tool"
  done
  payload="$(jq -nc --arg w "$p" \
    '{tool_name:"Bash",conversation_id:"conv-1",cwd:$w,tool_input:{command:"sudo id"}}')"
  run env -i PATH="$bin" HOME="$HOME" CURSOR_PROJECT_DIR="$p" \
    bash -c 'printf "%s" "$1" | bash "$2"' _ "$payload" "$CURSOR/hardhat.sh"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF '"permission":"deny"' \
    || { echo "no denial without jq: $output"; return 1; }
  printf '%s' "$output" | grep -qF 'needs allowance: sudo'
}

# cursor_pulse <project> <conversation-id>
cursor_pulse() {
  env CURSOR_PROJECT_DIR="$1" bash -c 'printf "%s" "$1" | bash "$2"' _ \
    "$(jq -nc --arg id "$2" --arg w "$1" '{conversation_id:$id,cwd:$w}')" "$CURSOR/pulse.sh"
}

@test "the Cursor pulse records the session that owns the shift, and only that one" {
  p="$(new_project cursor-pulse)"
  punch_open "$p"
  printf 'conv-1\n' >"$p/.nightshift/.shift-session"

  # A pulse from some other conversation is not evidence that the shift is alive.
  run cursor_pulse "$p" conv-9
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -e "$p/.nightshift/.shift-pulse" ] || { echo "a stranger's pulse was recorded"; return 1; }

  # The session that owns it is.
  run cursor_pulse "$p" conv-1
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -f "$p/.nightshift/.shift-pulse" ]
  grep -qF conv-1 "$p/.nightshift/.shift-pulse"
}

@test "the Cursor pulse says nothing once the shift is over" {
  p="$(new_project cursor-pulse-ended)"
  punch_open "$p"
  printf 'conv-1\n' >"$p/.nightshift/.shift-session"
  rm -f "$p/.nightshift/.shift-armed"
  : >"$p/.nightshift/.ended"
  run cursor_pulse "$p" conv-1
  [ "$status" -eq 0 ]
  [ ! -e "$p/.nightshift/.shift-pulse" ]
}

@test "the Cursor session end records the ending without ending the shift itself" {
  p="$(new_project cursor-session-end)"
  punch_open "$p"
  run env CURSOR_PROJECT_DIR="$p" bash -c \
    'printf "%s" "$1" | bash "$2"' _ \
    "$(jq -nc --arg w "$p" '{conversation_id:"conv-1",cwd:$w,reason:"window_close"}')" \
    "$CURSOR/session-end.sh"
  [ "$status" -eq 0 ]
  # A closed window is not a clock-out: the shift is still armed and still owes its boxes.
  [ -f "$p/.nightshift/.shift-armed" ]
  [ ! -f "$p/.nightshift/.ended" ]
}

@test "the Cursor watchman stands down on a shift that is not armed" {
  p="$(new_project cursor-watchman)"
  punch_open "$p"
  rm -f "$p/.nightshift/.shift-armed"
  run env NIGHTSHIFT_WATCH_ONESHOT=1 bash "$CURSOR_WATCHMAN" --project "$p" --max-wakes 1 \
    --agent 'true' --interval 1
  [ "$status" -eq 0 ]
  # It leaves no claim behind on a site it is not watching.
  [ ! -f "$p/.nightshift/.watchman" ]
}
