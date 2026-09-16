load ../helpers

HOOKS="$BATS_TEST_DIRNAME/../../plugins/nightshift/hooks"
CURSOR_HOOKS="$HOOKS/cursor"

cursor_session_end() {
  local p="$1" sid="$2" reason="${3:-user_close}"
  hook_payload "$(jq -nc --arg p "$p" --arg sid "$sid" --arg reason "$reason" \
    '{hook_event_name:"sessionEnd",conversation_id:$sid,session_id:$sid,cwd:$p,reason:$reason}')" \
    env CURSOR_PROJECT_DIR="$p" bash "$CURSOR_HOOKS/session-end.sh"
}

@test "cursor session-end writes the marker only for the shift's own session" {
  p="$(new_project)"
  punch_open "$p"
  printf 'right-id\n\n\n\ncursor\n' >"$p/.nightshift/.shift-session"
  cursor_session_end "$p" wrong-id user_close
  [ ! -f "$p/.nightshift/.session-end" ]
  cursor_session_end "$p" right-id user_close
  grep -q 'clean session end (user_close)' "$p/.nightshift/.session-end"
}

@test "cursor session-end is inert for a completed reason" {
  p="$(new_project)"
  punch_open "$p"
  printf 'right-id\n\n\n\ncursor\n' >"$p/.nightshift/.shift-session"
  cursor_session_end "$p" right-id completed
  [ ! -f "$p/.nightshift/.session-end" ]
}

@test "cursor session-end ignores the origin tab once a CLI worker is recorded" {
  p="$(new_project)"
  punch_open "$p"
  printf 'origin-ide\n\n\n\ncursor\n' >"$p/.nightshift/.shift-session"
  printf 'live-cli-worker\n' >"$p/.nightshift/.shift-worker"
  cursor_session_end "$p" origin-ide user_close
  [ ! -f "$p/.nightshift/.session-end" ]
}

@test "cursor session-end is inert while the shift is unarmed" {
  p="$(new_project)"
  punch_open "$p"
  rm -f "$p/.nightshift/.shift-armed"
  printf 'right-id\n\n\n\ncursor\n' >"$p/.nightshift/.shift-session"
  cursor_session_end "$p" right-id user_close
  [ ! -f "$p/.nightshift/.session-end" ]
}
