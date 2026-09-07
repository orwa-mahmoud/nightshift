load helpers

LIB="$BATS_TEST_DIRNAME/../plugins/nightshift/lib/lib.sh"
CLAUDE_WM="$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/claude/watchman.sh"
CODEX_WM="$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/codex/watchman.sh"
START="$BATS_TEST_DIRNAME/../plugins/nightshift/skills/start/SKILL.md"

@test "kill -0 classifies live, dead, and malformed pids without ps" {
  run bash -c '. "$1"
    ns_pid_alive "$$"
    echo live:$?
    ns_pid_alive 999999
    echo dead:$?
    ns_pid_alive "not-a-pid"
    echo bad:$?
  ' _ "$LIB"
  printf '%s' "$output" | grep -q 'live:0'
  printf '%s' "$output" | grep -q 'dead:1'
  printf '%s' "$output" | grep -q 'bad:2'

  empty="$BATS_TEST_TMPDIR/empty-bin"
  mkdir -p "$empty"
  for c in bash sed; do
    src="$(command -v "$c")" || continue
    ln -s "$src" "$empty/$c"
  done
  run env PATH="$empty" bash -c '. "$1"
    ns_have_cmd ps; echo ps:$?
    ns_recorded_process "$$" "ignored-start"
    echo rec:$?
  ' _ "$LIB"
  printf '%s' "$output" | grep -q 'ps:1'
  printf '%s' "$output" | grep -q 'rec:0'
}

@test "both watchmen share the process helpers and the unavailable reason" {
  grep -qF 'ns_recorded_process' "$CLAUDE_WM"
  grep -qF 'ns_recorded_process' "$CODEX_WM"
  grep -qF 'ns_have_cmd pgrep' "$CLAUDE_WM"
  grep -qF 'ns_have_cmd pgrep' "$CODEX_WM"
  grep -qF 'process-evidence-unavailable' "$CLAUDE_WM"
  grep -qF 'process-evidence-unavailable' "$CODEX_WM"
  # Liveness is a verdict's meaning now, so it travels on the watchman explanation.
  grep -qF 'kill -0' "$BATS_TEST_DIRNAME/../plugins/nightshift/lib/preflight-explain.txt"
  grep -qF 'process-evidence-unavailable' "$BATS_TEST_DIRNAME/../plugins/nightshift/lib/preflight-explain.txt"
}

@test "missing lsof and pgrep never count as a dead process" {
  empty="$BATS_TEST_TMPDIR/no-lsof"
  mkdir -p "$empty"
  for c in bash sed; do
    src="$(command -v "$c")" || continue
    ln -s "$src" "$empty/$c"
  done
  run env PATH="$empty" bash -c '. "$1"
    ns_have_cmd pgrep; echo pgrep:$?
    ns_have_cmd lsof; echo lsof:$?
    ns_pid_alive "$$"; echo live:$?
  ' _ "$LIB"
  printf '%s' "$output" | grep -q 'pgrep:1'
  printf '%s' "$output" | grep -q 'lsof:1'
  printf '%s' "$output" | grep -q 'live:0'
}
