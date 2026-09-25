load helpers

FIX="$BATS_TEST_DIRNAME/fixtures/hooks/v1"
CODEX_HOOKS="$HOOKS/codex"

replay() { # <host-dir> <adapter> <fixture>
  local host="$1" adapter="$2" fixture="$3" sid
  # The fixture's conversation is the shift's own, bound as Start's probe binds it.
  sid="$(jq -r '.session_id // empty' "$fixture")"
  [ -z "$sid" ] || bind_session "$host" "$sid" "${adapter%%-*}"
  case "$adapter" in
    claude-stop) env CLAUDE_PROJECT_DIR="$host" bash "$HOOKS/clock-out-gate.sh" <"$fixture" ;;
    claude-hardhat) env CLAUDE_PROJECT_DIR="$host" NIGHTSHIFT_FORBIDDEN_COMMANDS='git push' bash "$HOOKS/hardhat.sh" <"$fixture" ;;
    codex-stop) env CODEX_PROJECT_DIR="$host" bash "$CODEX_HOOKS/clock-out-gate.sh" <"$fixture" ;;
    codex-hardhat) env CODEX_PROJECT_DIR="$host" NIGHTSHIFT_FORBIDDEN_COMMANDS='git push' bash "$CODEX_HOOKS/hardhat.sh" <"$fixture" ;;
    *) echo "unknown adapter: $adapter" >&2; return 2 ;;
  esac
}

clear_ownership() { rm -f "$1/.nightshift/.shift-session" "$1/.nightshift/.shift-lease"; }

assert_expect() { # expect  (reads $status/$output)
  case "$1" in
    block) is_block "$output" ;;
    deny) is_deny "$output" ;;
    claude-allow) is_allow ;;
    codex-release)
      [ "$status" -eq 0 ]
      printf '%s' "$output" | jq -e '.continue == true' >/dev/null
      ;;
    *) echo "unknown expect: $1" >&2; return 2 ;;
  esac
}

@test "every v1 fixture is sanitized structural JSON" {
  n=0
  for f in "$FIX"/claude/*.json "$FIX"/codex/*.json; do
    n=$((n + 1))
    jq -e 'type == "object"' "$f" >/dev/null || { echo "not an object: $f"; return 1; }
    ! grep -qiE 'sk-[a-zA-Z0-9]|BEGIN (RSA |OPENSSH )?PRIVATE|password=|"prompt"|api[_-]?key' "$f" \
      || { echo "sensitive-looking content: $f"; return 1; }
    grep -qF 'fixture-session' "$f" || grep -q 'tool_name' "$f" || true
  done
  [ "$n" -ge 12 ]
}

@test "Claude Stop fixtures block open work through the real adapter" {
  p="$(new_project)"
  punch_open "$p"
  for f in stop-valid stop-absent-optional stop-unexpected stop-reordered; do
    run replay "$p" claude-stop "$FIX/claude/$f.json"
    [ "$status" -eq 0 ] || { echo "non-zero: $f"; return 1; }
    assert_expect block || { echo "expected block: $f -> $output"; return 1; }
  done
}

@test "Codex Stop fixtures block open work through the real adapter" {
  p="$(new_project)"
  punch_open "$p"
  for f in stop-valid stop-absent-optional stop-reordered; do
    run replay "$p" codex-stop "$FIX/codex/$f.json"
    [ "$status" -eq 0 ] || { echo "non-zero: $f"; return 1; }
    assert_expect block || { echo "expected block: $f -> $output"; return 1; }
  done
}

@test "Claude and Codex Stop fixtures agree on the shared block decision" {
  p="$(new_project)"
  punch_open "$p"
  run replay "$p" claude-stop "$FIX/claude/stop-valid.json"
  claude_out="$output"
  is_block "$claude_out"
  clear_ownership "$p"
  run replay "$p" codex-stop "$FIX/codex/stop-valid.json"
  is_block "$output"
}

@test "Ask fixtures deny on both hosts" {
  p="$(new_project)"
  punch_open "$p"
  run replay "$p" claude-hardhat "$FIX/claude/ask-valid.json"
  assert_expect deny
  run replay "$p" codex-hardhat "$FIX/codex/ask-valid.json"
  assert_expect deny
}

@test "forbidden Bash fixtures deny on both hosts" {
  p="$(new_project)"
  punch_open "$p"
  run replay "$p" claude-hardhat "$FIX/claude/bash-forbidden.json"
  assert_expect deny
  run replay "$p" claude-hardhat "$FIX/claude/bash-reordered.json"
  assert_expect claude-allow
  clear_ownership "$p"
  run replay "$p" codex-hardhat "$FIX/codex/bash-forbidden.json"
  assert_expect deny
}

@test "linked workspaces and spaced paths replay through both adapters" {
  host="$BATS_TEST_TMPDIR/host with spaces"
  mkdir -p "$host"
  workspace="$(new_project workspace)"
  punch_open "$workspace"
  bash "$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/link-workspace.sh" \
    --host-root "$host" --workspace "$workspace" >/dev/null

  run replay "$host" claude-stop "$FIX/claude/stop-valid.json"
  assert_expect block
  clear_ownership "$workspace"
  run replay "$host" codex-stop "$FIX/codex/stop-valid.json"
  assert_expect block
  clear_ownership "$workspace"
  run replay "$host" claude-hardhat "$FIX/claude/bash-forbidden.json"
  assert_expect deny
  clear_ownership "$workspace"
  run replay "$host" codex-hardhat "$FIX/codex/bash-forbidden.json"
  assert_expect deny
}

@test "STOP releases on both hosts for the same fixture corpus" {
  p="$(new_project)"
  punch_open "$p"
  : >"$p/.nightshift/STOP"
  run replay "$p" claude-stop "$FIX/claude/stop-valid.json"
  assert_expect claude-allow
  run replay "$p" codex-stop "$FIX/codex/stop-valid.json"
  assert_expect codex-release
}

# Disarm is total, through the real wire format: a lease left behind by a recovery attempt is
# not a rule, and an unarmed site applies none of them on either host.
@test "the fixture corpus passes every rule once the shift is disarmed" {
  p="$(new_project)"
  punch_open "$p"
  session_record "$p" fixture-session "" "" "" claude
  lease_record "$p" fixture-session claude 2 claude.2.4711.8.9 4711 ""
  rm "$p/.nightshift/.shift-armed"
  for f in bash-forbidden bash-reordered ask-valid; do
    run replay "$p" claude-hardhat "$FIX/claude/$f.json"
    assert_expect claude-allow || { echo "rule applied to a disarmed site: $f -> $output"; return 1; }
  done
  run replay "$p" claude-stop "$FIX/claude/stop-valid.json"
  assert_expect claude-allow

  c="$(new_project codex-disarmed)"
  punch_open "$c"
  session_record "$c" fixture-session "" "" "" codex
  lease_record "$c" fixture-session codex 2 codex.2.4711.8.9 4711 ""
  rm "$c/.nightshift/.shift-armed"
  for f in bash-forbidden ask-valid; do
    run replay "$c" codex-hardhat "$FIX/codex/$f.json"
    assert_expect claude-allow || { echo "rule applied to a disarmed site: $f -> $output"; return 1; }
  done
  run replay "$c" codex-stop "$FIX/codex/stop-valid.json"
  assert_expect codex-release
}
