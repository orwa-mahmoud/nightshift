load ../helpers

HOOKS="$BATS_TEST_DIRNAME/../../plugins/nightshift/hooks"
CURSOR_HOOKS="$HOOKS/cursor"

@test "beforeSubmitPrompt blocks the origin tab and names the resume command" {
  p="$(new_project)"
  punch_open "$p"
  printf 'origin-ide\n\n\n\ncursor\n' >"$p/.nightshift/.shift-session"
  cursor_worker_ran "$p" live-cli-worker
  run env CURSOR_PROJECT_DIR="$p" bash "$CURSOR_HOOKS/before-submit.sh" \
    "$(jq -nc --arg p "$p" '{conversation_id:"origin-ide",cwd:$p,prompt:"continue"}')"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.continue == false' >/dev/null
  printf '%s' "$output" | grep -q 'agent --resume='
  printf '%s' "$output" | grep -q 'live-cli-worker'
  printf '%s' "$output" | grep -q 'terminal'
  printf '%s' "$output" | grep -q 'ask Nightshift to stop'
}

@test "beforeSubmitPrompt lets the origin tab ask Nightshift to stop" {
  p="$(new_project)"
  punch_open "$p"
  printf 'origin-ide\n\n\n\ncursor\n' >"$p/.nightshift/.shift-session"
  cursor_worker_ran "$p" live-cli-worker
  run env CURSOR_PROJECT_DIR="$p" bash "$CURSOR_HOOKS/before-submit.sh" \
    "$(jq -nc --arg p "$p" '{conversation_id:"origin-ide",cwd:$p,prompt:"ask Nightshift to stop"}')"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "beforeSubmitPrompt lets another conversation send" {
  p="$(new_project)"
  punch_open "$p"
  printf 'origin-ide\n\n\n\ncursor\n' >"$p/.nightshift/.shift-session"
  cursor_worker_ran "$p" live-cli-worker
  run env CURSOR_PROJECT_DIR="$p" bash "$CURSOR_HOOKS/before-submit.sh" \
    "$(jq -nc --arg p "$p" '{conversation_id:"helper-tab",cwd:$p,prompt:"hi"}')"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "beforeSubmitPrompt lets the origin tab continue when the recorded worker never ran" {
  p="$(new_project)"
  punch_open "$p"
  printf 'origin-ide\n\n\n\ncursor\n' >"$p/.nightshift/.shift-session"
  printf 'never-ran-worker\n' >"$p/.nightshift/.shift-worker"
  run env CURSOR_PROJECT_DIR="$p" bash "$CURSOR_HOOKS/before-submit.sh" \
    "$(jq -nc --arg p "$p" '{conversation_id:"origin-ide",cwd:$p,prompt:"continue"}')"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "beforeSubmitPrompt lets the origin tab continue once a failed revival handed the lease back" {
  p="$(new_project)"
  punch_open "$p"
  printf 'origin-ide\n\n\n\ncursor\n' >"$p/.nightshift/.shift-session"
  printf 'kept-cli-worker\n' >"$p/.nightshift/.shift-worker"
  lease_record "$p" origin-ide cursor 3 "" "" ""
  run env CURSOR_PROJECT_DIR="$p" bash "$CURSOR_HOOKS/before-submit.sh" \
    "$(jq -nc --arg p "$p" '{conversation_id:"origin-ide",cwd:$p,prompt:"continue"}')"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
