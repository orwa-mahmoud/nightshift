load helpers

HOOKS="$BATS_TEST_DIRNAME/../plugins/nightshift/hooks"
CODEX_HOOKS="$HOOKS/codex"

@test "command, tool-deny, and scrub decisions live in the shared core" {
  for fn in ns_hardhat_command_reason ns_hardhat_tool_deny_reason \
    ns_hardhat_required_tool_deny_reason ns_hardhat_scrub ns_hardhat_rules_has \
    ns_hardhat_is_command_tool ns_hardhat_trusted_shift_control; do
    grep -qF "$fn" "$HOOKS/shared/hardhat-core.sh" || { echo "missing $fn"; return 1; }
  done
  grep -qF 'ns_hardhat_command_reason' "$HOOKS/hardhat.sh"
  grep -qF 'ns_hardhat_command_reason' "$HOOKS/codex/hardhat.sh"
  grep -qF 'ns_hardhat_required_tool_deny_reason' "$HOOKS/hardhat.sh"
  grep -qF 'ns_hardhat_required_tool_deny_reason' "$HOOKS/codex/hardhat.sh"
}

@test "both hardhats and gates share one ownership protocol" {
  LIB_DIR="$BATS_TEST_DIRNAME/../plugins/nightshift/lib"
  for fn in ns_shift_unbound ns_shift_rebind ns_shift_authorize ns_shift_ownership \
    ns_lease_reclaim_recorded; do
    grep -qF "$fn() {" "$LIB_DIR"/*.sh || { echo "missing $fn"; return 1; }
  done
  grep -qF 'ns_shift_unbound claude hardhat' "$HOOKS/hardhat.sh"
  grep -qF 'ns_shift_rebind claude' "$HOOKS/hardhat.sh"
  grep -qF 'ns_shift_authorize claude' "$HOOKS/hardhat.sh"
  grep -qF 'ns_shift_unbound codex hardhat' "$HOOKS/codex/hardhat.sh"
  grep -qF 'ns_shift_authorize codex' "$HOOKS/codex/hardhat.sh"
  grep -qF 'ns_shift_unbound cursor hardhat' "$HOOKS/cursor/hardhat.sh"
  grep -qF 'ns_shift_authorize cursor' "$HOOKS/cursor/hardhat.sh"
  grep -qF 'ns_shift_unbound claude gate' "$HOOKS/clock-out-gate.sh"
  grep -qF 'ns_shift_ownership claude' "$HOOKS/clock-out-gate.sh"
  grep -qF 'ns_shift_unbound codex gate' "$HOOKS/codex/clock-out-gate.sh"
  grep -qF 'ns_shift_ownership codex' "$HOOKS/codex/clock-out-gate.sh"
  grep -qF 'ns_shift_unbound cursor gate' "$HOOKS/cursor/clock-out-gate.sh"
  grep -qF 'ns_shift_ownership cursor' "$HOOKS/cursor/clock-out-gate.sh"
  awk '/ns_shift_unbound/{u=NR} /ns_session_claim/{if(!c)c=NR} END{exit !(u && c && u<c)}' "$HOOKS/hardhat.sh"
  awk '/ns_shift_unbound/{u=NR} /ns_session_claim/{if(!c)c=NR} END{exit !(u && c && u<c)}' "$HOOKS/codex/hardhat.sh"
  awk '/ns_shift_unbound/{u=NR} /ns_session_claim/{if(!c)c=NR} END{exit !(u && c && u<c)}' "$HOOKS/cursor/hardhat.sh"
  awk '/ns_hardhat_binding_probe/{p=NR} /ns_shift_authorize/{a=NR} END{exit !(p && a && p<a)}' "$HOOKS/hardhat.sh"
  awk '/ns_hardhat_binding_probe/{p=NR} /ns_shift_authorize/{a=NR} END{exit !(p && a && p<a)}' "$HOOKS/codex/hardhat.sh"
  # The owner's Stop, reset, and purge helpers are reachable from a fenced conversation only
  # if that allowance is consulted before the ownership protocol runs. Every host, every time.
  for h in "$HOOKS/hardhat.sh" "$HOOKS/codex/hardhat.sh" "$HOOKS/cursor/hardhat.sh"; do
    awk '/ns_hardhat_trusted_shift_control/{t=NR} /ns_shift_unbound/{u=NR} END{exit !(t && u && t<u)}' "$h" \
      || { echo "the helper allowance runs after the ownership protocol: $h"; return 1; }
  done
}

@test "both watchmen spawn through one child runner" {
  LIB_DIR="$BATS_TEST_DIRNAME/../plugins/nightshift/lib"
  CLAUDE_WM="$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/claude/watchman.sh"
  CODEX_WM="$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/codex/watchman.sh"
  CURSOR_WM="$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/cursor/watchman.sh"
  grep -qF 'ns_watchman_run_child() {' "$LIB_DIR"/*.sh
  grep -qF 'ns_watchman_clockout_pending() {' "$LIB_DIR"/*.sh
  grep -qF 'ns_watchman_run_child' "$CLAUDE_WM"
  grep -qF 'ns_watchman_run_child' "$CODEX_WM"
  grep -qF 'ns_watchman_run_child' "$CURSOR_WM"
  grep -qF 'ns_watchman_clockout_pending' "$CLAUDE_WM"
  grep -qF 'ns_watchman_clockout_pending' "$CODEX_WM"
  grep -qF 'clock_out_direct' "$CURSOR_WM"
}

# Table: command -> expected (deny|allow) -> reason fragment
parity_row() {
  local cmd="$1" expect="$2" needle="$3"
  p="$(new_project)"
  punch_open "$p"
  run hardhat_bash "$p" "$cmd" NIGHTSHIFT_FORBIDDEN_COMMANDS='git push' \
    NIGHTSHIFT_PROTECTED_DIRS='secrets' NIGHTSHIFT_EXPECTED_EMAIL='dev@example.com'
  if [ "$expect" = deny ]; then
    is_deny "$output" || { echo "claude allow: $cmd -> $output"; return 1; }
    printf '%s' "$output" | grep -qF "$needle" || { echo "claude reason: $output"; return 1; }
  else
    is_allow || { echo "claude deny: $cmd -> $output"; return 1; }
  fi
  claude="$output"

  run bash -c 'jq -nc --arg c "$2" '\''{tool_name:"Bash",tool_input:{command:$c}}'\'' | env CODEX_PROJECT_DIR="$1" NIGHTSHIFT_FORBIDDEN_COMMANDS="git push" NIGHTSHIFT_PROTECTED_DIRS="secrets" NIGHTSHIFT_EXPECTED_EMAIL="dev@example.com" bash "$3/hardhat.sh"' \
    _ "$p" "$cmd" "$CODEX_HOOKS"
  if [ "$expect" = deny ]; then
    is_deny "$output" || { echo "codex allow: $cmd -> $output"; return 1; }
    printf '%s' "$output" | grep -qF "$needle" || { echo "codex reason: $output"; return 1; }
  else
    is_allow || { echo "codex deny: $cmd -> $output"; return 1; }
  fi
}

@test "table-driven hardhat parity across hosts" {
  parity_row 'git push origin main' deny 'forbidden'
  parity_row 'git status' allow ''
  parity_row 'git add secrets/key' deny 'protected'
  parity_row 'echo hi' allow ''
}

@test "each host question tool reads its own native rule" {
  p="$(new_project)"
  punch_open "$p"
  rules='{"AskUserQuestion":"claude park","request_user_input":"codex park"}'
  run hardhat_ask "$p" NIGHTSHIFT_TOOL_RULES="$rules"
  is_deny "$output"
  printf '%s' "$output" | grep -q 'claude park'
  claude_reason="$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason')"
  run bash -c 'jq -nc '\''{tool_name:"request_user_input",tool_input:{}}'\'' | env CODEX_PROJECT_DIR="$1" NIGHTSHIFT_TOOL_RULES="$3" bash "$2/hardhat.sh"' _ "$p" "$CODEX_HOOKS" "$rules"
  is_deny "$output"
  printf '%s' "$output" | grep -q 'codex park'
  codex_reason="$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason')"
  [ "$claude_reason" != "$codex_reason" ]
}
