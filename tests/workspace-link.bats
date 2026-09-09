load helpers

RUNTIME="$BATS_TEST_DIRNAME/../plugins/nightshift/runtime"
LIB="$BATS_TEST_DIRNAME/../plugins/nightshift/lib/lib.sh"
CODEX_HOOKS="$HOOKS/codex"

@test "an absent link keeps the task root authoritative" {
  host="$(new_project host)"
  expected="$(cd -P "$host" && pwd)"
  run bash -c '. "$1"; ns_workspace_root "$2"' _ "$LIB" "$host"
  [ "$status" -eq 0 ]
  [ "$output" = "$expected" ]
}

@test "link-workspace records one canonical absolute target and keeps it local" {
  host="$(new_project host)"
  workspace="$BATS_TEST_TMPDIR/workspace with spaces"
  mkdir -p "$workspace/.nightshift"
  expected="$(cd -P "$workspace" && pwd)"
  run bash "$RUNTIME/link-workspace.sh" --host-root "$host" --workspace "$workspace"
  [ "$status" -eq 0 ]
  [ "$(cat "$host/.nightshift-link")" = "$expected" ]
  grep -qxF '.nightshift-link' "$host/.git/info/exclude"
  [ -z "$(git -C "$host" status --short -- .nightshift-link)" ]
}

@test "link-workspace refuses an unknown flag with usage" {
  host="$(new_project host)"
  workspace="$BATS_TEST_TMPDIR/workspace-unknown-flag"
  mkdir -p "$workspace/.nightshift"
  run bash "$RUNTIME/link-workspace.sh" --host-root "$host" --bogus x --workspace "$workspace"
  [ "$status" -eq 2 ]
  printf '%s' "$output" | grep -qF 'link-workspace: unknown argument: --bogus'
  [ ! -e "$host/.nightshift-link" ]
}

@test "link-workspace rejects relative and uninitialized targets" {
  host="$(new_project host)"
  mkdir -p "$BATS_TEST_TMPDIR/no-state"
  run bash "$RUNTIME/link-workspace.sh" --host-root "$host" --workspace relative
  [ "$status" -ne 0 ]
  run bash "$RUNTIME/link-workspace.sh" --host-root "$host" --workspace "$BATS_TEST_TMPDIR/no-state"
  [ "$status" -ne 0 ]
  [ ! -e "$host/.nightshift-link" ]
}

@test "Claude gate and hardhat enforce the linked authoritative workspace" {
  host="$(new_project host)"
  rm -rf "$host/.nightshift"
  workspace="$(new_project workspace)"
  punch_open "$workspace"
  bash "$RUNTIME/link-workspace.sh" --host-root "$host" --workspace "$workspace" >/dev/null

  run gate "$host"
  is_block "$output"
  run hardhat_bash "$host" "git push origin main" NIGHTSHIFT_FORBIDDEN_COMMANDS='git push'
  is_deny "$output"
}

@test "Codex gate and hardhat enforce the linked authoritative workspace" {
  host="$(new_project host)"
  rm -rf "$host/.nightshift"
  workspace="$(new_project workspace)"
  punch_open "$workspace"
  bash "$RUNTIME/link-workspace.sh" --host-root "$host" --workspace "$workspace" >/dev/null

  run bash -c 'jq -nc '\''{hook_event_name:"Stop",session_id:"test-shift-session",transcript_path:""}'\'' | env CODEX_PROJECT_DIR="$1" bash "$2/clock-out-gate.sh"' _ "$host" "$CODEX_HOOKS"
  is_block "$output"
  run bash -c 'jq -nc --arg c "git push origin main" '\''{tool_name:"Bash",tool_input:{command:$c}}'\'' | env CODEX_PROJECT_DIR="$1" NIGHTSHIFT_FORBIDDEN_COMMANDS="git push" bash "$2/hardhat.sh"' _ "$host" "$CODEX_HOOKS"
  is_deny "$output"
}

@test "malformed links fail closed on both hosts" {
  host="$(new_project host)"
  printf 'relative/path\n' >"$host/.nightshift-link"
  run gate "$host"
  is_block "$output"
  printf '%s' "$output" | grep -q 'invalid'
  run bash -c 'jq -nc '\''{hook_event_name:"Stop",session_id:"test-shift-session"}'\'' | env CODEX_PROJECT_DIR="$1" bash "$2/clock-out-gate.sh"' _ "$host" "$CODEX_HOOKS"
  is_block "$output"
}

@test "blank extra lines and broken symlinks are invalid rather than absent" {
  host="$(new_project host)"
  workspace="$(new_project workspace)"
  printf '%s\n\n' "$workspace" >"$host/.nightshift-link"
  run bash -c '. "$1"; ns_workspace_root "$2"' _ "$LIB" "$host"
  [ "$status" -eq 2 ]

  rm "$host/.nightshift-link"
  ln -s "$BATS_TEST_TMPDIR/missing-target" "$host/.nightshift-link"
  run bash -c '. "$1"; ns_workspace_root "$2"' _ "$LIB" "$host"
  [ "$status" -eq 2 ]
}

@test "Claude clean-session markers land in the linked workspace" {
  host="$(new_project host)"
  rm -rf "$host/.nightshift"
  workspace="$(new_project workspace)"
  punch_open "$workspace"
  printf 'linked-session\n\n\n\nclaude\n' >"$workspace/.nightshift/.shift-session"
  bash "$RUNTIME/link-workspace.sh" --host-root "$host" --workspace "$workspace" >/dev/null
  jq -nc '{session_id:"linked-session",reason:"exit"}' |
    env CLAUDE_PROJECT_DIR="$host" bash "$HOOKS/session-end.sh"
  grep -q 'clean session end' "$workspace/.nightshift/.session-end"
}
