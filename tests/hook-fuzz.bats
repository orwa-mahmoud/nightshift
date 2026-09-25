load helpers

CODEX_HOOKS="$HOOKS/codex"
OUTSIDE="$BATS_TEST_TMPDIR/outside"

setup() {
  mkdir -p "$OUTSIDE"
}

bounded() {
  perl -e 'alarm 8; exec @ARGV' -- "$@"
}

# invoke <project> <hook> <payload> [ENV=VAL ...]
invoke() {
  local p="$1" hook="$2" payload="$3"
  shift 3
  printf '%s' "$payload" | bounded env "$@" PROJECT_PLACEHOLDER=1 bash "$hook"
}

assert_contained() {
  [ "$status" -le 1 ]
  [ ! -e "$OUTSIDE/pwned" ]
}

@test "truncated and non-object JSON fails closed on every adapter" {
  p="$(new_project)"
  punch_open "$p"
  for payload in '{' '{]' '"nope"' '[]' '' '{"session_id":'; do
    run invoke "$p" "$HOOKS/clock-out-gate.sh" "$payload" CLAUDE_PROJECT_DIR="$p"
    assert_contained || { echo "claude stop: $payload"; return 1; }
    run invoke "$p" "$HOOKS/hardhat.sh" "$payload" CLAUDE_PROJECT_DIR="$p"
    assert_contained || { echo "claude hat: $payload"; return 1; }
    run invoke "$p" "$CODEX_HOOKS/clock-out-gate.sh" "$payload" CODEX_PROJECT_DIR="$p"
    assert_contained || { echo "codex stop: $payload"; return 1; }
    run invoke "$p" "$CODEX_HOOKS/hardhat.sh" "$payload" CODEX_PROJECT_DIR="$p"
    assert_contained || { echo "codex hat: $payload"; return 1; }
  done
}

@test "wrong JSON types fail closed without executing fields" {
  p="$(new_project)"
  punch_open "$p"
  run invoke "$p" "$HOOKS/hardhat.sh" \
    '{"session_id":1,"transcript_path":false,"tool_name":["Bash"],"tool_input":"nope"}' \
    CLAUDE_PROJECT_DIR="$p"
  assert_contained
  run invoke "$p" "$CODEX_HOOKS/clock-out-gate.sh" \
    '{"session_id":1,"transcript_path":false,"cwd":0}' \
    CODEX_PROJECT_DIR="$p"
  assert_contained
}

@test "hostile strings never reach the shell from either adapter" {
  p="$(new_project)"
  punch_open "$p"
  bind_session "$p" "$(printf '$(touch %s/pwned)' "$OUTSIDE")"
  payload="$(printf '{"tool_name":"Bash","session_id":"$(touch %s/pwned)","tool_input":{"command":"`touch %s/pwned`; git push"}}' "$OUTSIDE" "$OUTSIDE")"
  run invoke "$p" "$HOOKS/hardhat.sh" "$payload" CLAUDE_PROJECT_DIR="$p" NIGHTSHIFT_FORBIDDEN_COMMANDS='git push'
  assert_contained
  is_deny "$output"
  run invoke "$p" "$CODEX_HOOKS/hardhat.sh" "$payload" CODEX_PROJECT_DIR="$p" NIGHTSHIFT_FORBIDDEN_COMMANDS='git push'
  assert_contained
  is_deny "$output"
  [ ! -e "$OUTSIDE/pwned" ]
}

@test "an oversized field stays bounded" {
  p="$(new_project)"
  punch_open "$p"
  big="$(awk 'BEGIN{s="x"; while (length(s)<50000) s=s s; printf "%s", s}')"
  payload="$(printf '{"tool_name":"Bash","session_id":"%s","tool_input":{"command":"true"}}' "$big")"
  run invoke "$p" "$HOOKS/hardhat.sh" "$payload" CLAUDE_PROJECT_DIR="$p"
  assert_contained
}

@test "missing, unreadable, and broken-link state fail closed" {
  p="$(new_project)"
  punch_open "$p"
  chmod 000 "$p/.nightshift/rules.json"
  run invoke "$p" "$HOOKS/clock-out-gate.sh" '{"hook_event_name":"Stop","session_id":"fixture-session"}' CLAUDE_PROJECT_DIR="$p"
  assert_contained
  chmod 644 "$p/.nightshift/rules.json"

  host="$(new_project host)"
  printf 'relative\n' >"$host/.nightshift-link"
  run invoke "$host" "$HOOKS/clock-out-gate.sh" '{"hook_event_name":"Stop","session_id":"fixture-session"}' CLAUDE_PROJECT_DIR="$host"
  is_block "$output"
  run invoke "$host" "$CODEX_HOOKS/clock-out-gate.sh" '{"hook_event_name":"Stop","session_id":"fixture-session"}' CODEX_PROJECT_DIR="$host"
  is_block "$output"

  rm -f "$host/.nightshift-link"
  ln -s /no/such/workspace "$host/.nightshift-link"
  run invoke "$host" "$HOOKS/hardhat.sh" '{"tool_name":"Bash","tool_input":{"command":"true"}}' CLAUDE_PROJECT_DIR="$host"
  assert_contained
}

@test "stale markers and a partial session record stay inside the project" {
  p="$(new_project)"
  punch_open "$p"
  printf 'only-one-line\n' >"$p/.nightshift/.shift-session"
  : >"$p/.nightshift/.ended"
  printf '3\n' >"$p/.nightshift/.stall"
  run invoke "$p" "$HOOKS/hardhat.sh" '{"tool_name":"AskUserQuestion","tool_input":{}}' CLAUDE_PROJECT_DIR="$p"
  assert_contained
  run invoke "$p" "$CODEX_HOOKS/hardhat.sh" '{"tool_name":"request_user_input","tool_input":{}}' CODEX_PROJECT_DIR="$p"
  assert_contained
  run invoke "$p" "$HOOKS/clock-out-gate.sh" '{"hook_event_name":"Stop","session_id":"fixture-session"}' CLAUDE_PROJECT_DIR="$p"
  assert_contained
  [ -d "$p/.nightshift" ]
  [ ! -e "$OUTSIDE/pwned" ]
}

@test "NUL and control bytes do not hang either adapter" {
  p="$(new_project)"
  punch_open "$p"
  run invoke "$p" "$HOOKS/hardhat.sh" "$(printf '{"tool_name":"Bash","tool_input":{"command":"true"}}\1\2')" CLAUDE_PROJECT_DIR="$p"
  assert_contained
  run invoke "$p" "$CODEX_HOOKS/clock-out-gate.sh" "$(printf '{"hook_event_name":"Stop","session_id":"fx"}')" CODEX_PROJECT_DIR="$p"
  assert_contained
}
