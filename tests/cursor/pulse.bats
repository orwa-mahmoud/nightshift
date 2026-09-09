load ../helpers

HOOKS="$BATS_TEST_DIRNAME/../../plugins/nightshift/hooks"
CURSOR_PULSE="$HOOKS/cursor/pulse.sh"

cursor_pulse() {
  local p="$1" sid="$2"
  jq -nc --arg p "$p" --arg sid "$sid" \
    '{hook_event_name:"postToolUse",conversation_id:$sid,session_id:$sid,cwd:$p,tool_name:"Read"}' |
    env CURSOR_PROJECT_DIR="$p" bash "$CURSOR_PULSE"
}

@test "cursor pulse helpers do not write" {
  p="$(new_project)"
  punch_open "$p"
  printf 'bound-id\n\n\n\ncursor\n' >"$p/.nightshift/.shift-session"
  cursor_pulse "$p" helper-id
  [ ! -f "$p/.nightshift/.shift-pulse" ]
  cursor_pulse "$p" bound-id
  grep -qE '^[0-9]+ bound-id$' "$p/.nightshift/.shift-pulse"
}

@test "cursor origin does not write the pulse once a worker exists" {
  p="$(new_project)"
  punch_open "$p"
  printf 'origin-ide\n\n\n\ncursor\n' >"$p/.nightshift/.shift-session"
  printf 'live-cli-worker\n' >"$p/.nightshift/.shift-worker"
  cursor_pulse "$p" origin-ide
  [ ! -f "$p/.nightshift/.shift-pulse" ]
  cursor_pulse "$p" live-cli-worker
  grep -qE '^[0-9]+ live-cli-worker$' "$p/.nightshift/.shift-pulse"
}

@test "cursor pulse overwrites rather than appending" {
  p="$(new_project)"
  punch_open "$p"
  printf 'bound-id\n\n\n\ncursor\n' >"$p/.nightshift/.shift-session"
  printf '1 bound-id\n2 leftover\n' >"$p/.nightshift/.shift-pulse"
  cursor_pulse "$p" bound-id
  [ "$(wc -l <"$p/.nightshift/.shift-pulse" | tr -d ' ')" -eq 1 ]
  grep -qE '^[0-9]+ bound-id$' "$p/.nightshift/.shift-pulse"
  if grep -q leftover "$p/.nightshift/.shift-pulse"; then
    return 1
  fi
}

@test "cursor stop pulse produces no stdout" {
  p="$(new_project)"
  punch_open "$p"
  printf 'bound-id\n\n\n\ncursor\n' >"$p/.nightshift/.shift-session"
  out="$(jq -nc --arg p "$p" \
    '{hook_event_name:"stop",conversation_id:"bound-id",session_id:"bound-id",cwd:$p,status:"completed"}' |
    env CURSOR_PROJECT_DIR="$p" bash "$CURSOR_PULSE")"
  printf '%s' "$out" | grep -qF 'additional_context'
  printf '%s' "$out" | grep -qF 'receipts: item'
}
