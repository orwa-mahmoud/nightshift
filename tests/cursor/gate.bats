load ../helpers

HOOKS="$BATS_TEST_DIRNAME/../../plugins/nightshift/hooks"
CURSOR_HOOKS="$HOOKS/cursor"
FIXTURES="$BATS_TEST_DIRNAME/../fixtures/hooks/v1/cursor"

is_cursor_release() {
  [ "$status" -eq 0 ]
  [ -z "$output" ] || ! printf '%s' "$output" | grep -q 'followup_message'
}

is_cursor_block() {
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.followup_message | type == "string" and length > 0' >/dev/null
}

cursor_gate() {
  local p="$1" fixture="$FIXTURES/stop-completed.json"
  shift
  if [ -n "${1:-}" ] && [ -f "$1" ]; then
    fixture="$1"
    shift
  fi
  bind_session "$p" "$(jq -r '.conversation_id // .session_id' "$fixture")" cursor
  hook_payload "$(jq -nc --argjson base "$(cat "$fixture")" --arg p "$p" '$base + {cwd:$p}')" \
    env "$@" CURSOR_PROJECT_DIR="$p" bash "$CURSOR_HOOKS/clock-out-gate.sh"
}

@test "cursor gate blocks completed stop while a box is open" {
  p="$(new_project)"
  punch_open "$p"
  run cursor_gate "$p" "$FIXTURES/stop-completed.json"
  is_cursor_block
}

@test "cursor gate releases aborted stop with open boxes (owner interrupt)" {
  p="$(new_project)"
  punch_open "$p"
  run cursor_gate "$p" "$FIXTURES/stop-aborted.json"
  is_cursor_release
  [ ! -f "$p/.nightshift/.ended" ]
  [ -f "$p/.nightshift/.shift-armed" ]
}

@test "cursor gate keeps error stop gated when boxes are open" {
  p="$(new_project)"
  punch_open "$p"
  run cursor_gate "$p" "$FIXTURES/stop-error.json"
  is_cursor_block
}

@test "cursor gate releases when every box is ticked" {
  p="$(new_project)"
  punch_done "$p"
  run cursor_gate "$p" "$FIXTURES/stop-completed.json"
  is_cursor_release
  [ -f "$p/.nightshift/.ended" ]
}

@test "cursor gate holds the session its binding probe recorded with cursor as its host" {
  p="$(new_project)"
  punch_open "$p"
  jq -nc --arg p "$p" \
    '{tool_name:"Shell",conversation_id:"fixture-cursor-conversation",transcript_path:"",cwd:$p,tool_input:{command:": nightshift-binding-probe"}}' |
    env CURSOR_PROJECT_DIR="$p" bash "$CURSOR_HOOKS/hardhat.sh"
  run cursor_gate "$p" "$FIXTURES/stop-completed.json"
  is_cursor_block
  [ "$(sed -n 1p "$p/.nightshift/.shift-session")" = "fixture-cursor-conversation" ]
  [ "$(sed -n 5p "$p/.nightshift/.shift-session")" = "cursor" ]
}

# ---- the shift binds one session: everyone else stops freely ----

@test "another conversation's stop is not the shift's business — released" {
  p="$(new_project)"
  punch_open "$p"
  printf 'the-shift\n\n\n\ncursor\n' >"$p/.nightshift/.shift-session"
  run cursor_gate "$p" "$FIXTURES/stop-completed.json"
  is_cursor_release
  [ "$(sed -n 1p "$p/.nightshift/.shift-session")" = "the-shift" ]
  [ ! -f "$p/.nightshift/.ended" ]
}

@test "the recorded shift session itself is still held" {
  p="$(new_project)"
  punch_open "$p"
  printf 'fixture-cursor-conversation\n\n\n\ncursor\n' >"$p/.nightshift/.shift-session"
  run cursor_gate "$p" "$FIXTURES/stop-completed.json"
  is_cursor_block
}

@test "STOP still clocks out from the origin tab while a worker is live" {
  p="$(new_project)"
  punch_open "$p"
  printf 'origin-ide\n\n\n\ncursor\n' >"$p/.nightshift/.shift-session"
  printf 'live-cli-worker\n' >"$p/.nightshift/.shift-worker"
  printf 'stopped by owner\n' >"$p/.nightshift/STOP"
  jq -nc --arg p "$p" \
    '{conversation_id:"origin-ide",session_id:"origin-ide",cwd:$p,hook_event_name:"stop",status:"completed",loop_count:0}' \
    >"$BATS_TEST_TMPDIR/origin-stop.json"
  run cursor_gate "$p" "$BATS_TEST_TMPDIR/origin-stop.json"
  is_cursor_release
  [ -f "$p/.nightshift/.ended" ]
}

@test "cursor abort fixture distinguishes status from completed" {
  aborted="$(jq -r '.status' "$FIXTURES/stop-aborted.json")"
  completed="$(jq -r '.status' "$FIXTURES/stop-completed.json")"
  [ "$aborted" = "aborted" ]
  [ "$completed" = "completed" ]
  [ "$aborted" != "$completed" ]
  [ "$(jq -r '.hook_event_name' "$FIXTURES/stop-aborted.json")" = "stop" ]
}

# Zero open boxes reached by deleting work, or by editing the contract, is not done.
@test "cursor gate blocks a done clock-out after the open item was deleted" {
  p="$(new_project)"
  punch_open "$p"
  arm_snapshot "$p"
  printf '## Items\n- [x] **2. done.**\n' >"$p/.nightshift/punch-list.md"
  run cursor_gate "$p" "$FIXTURES/stop-completed.json"
  is_cursor_block
  [ ! -e "$p/.nightshift/.ended" ]
}

@test "cursor gate blocks a done clock-out after the punch list was deleted" {
  p="$(new_project)"
  punch_open "$p"
  arm_snapshot "$p"
  rm "$p/.nightshift/punch-list.md"
  run cursor_gate "$p" "$FIXTURES/stop-completed.json"
  is_cursor_block
  [ ! -e "$p/.nightshift/.ended" ]
}

@test "cursor gate releases a list finished by ticks alone" {
  p="$(new_project)"
  punch_open "$p"
  arm_snapshot "$p"
  punch_done "$p"
  run cursor_gate "$p" "$FIXTURES/stop-completed.json"
  is_cursor_release
  [ -e "$p/.nightshift/.ended" ]
}

@test "cursor clock-out files the shift policy into the folder it claims for the shift" {
  p="$(new_project)"
  punch_done "$p"
  printf '%s\n' '{"schemaVersion":1,"shiftId":"9f2c40ab77e51d63","createdAt":"2026-09-25T00:00:00Z","source":"composition","verificationLevel":"none","toolingPolicy":"existing-tools"}' >"$p/.nightshift/shift-policy.json"
  run cursor_gate "$p" "$FIXTURES/stop-completed.json"
  is_cursor_release
  d="$p/.nightshift/archive/$(sed -n 's/^archiveFolder=//p' "$p/.nightshift/.ended")"
  [ "$(cat "$d/.shift-id")" = 9f2c40ab77e51d63 ]
  jq -e '.shiftId == "9f2c40ab77e51d63"' "$d/shift-policy.json" >/dev/null
  [ ! -e "$p/.nightshift/shift-policy.json" ]
}
