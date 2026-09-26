#!/usr/bin/env bats
# Start arms the watchman through one launcher: the workspace given explicitly, the watchman's own
# output kept, and success only once the watchman holds its pid file and the log shows it armed.

load helpers

RT="$BATS_TEST_DIRNAME/../plugins/nightshift/runtime"
LAUNCHER="$RT/start-watchman.sh"

setup() {
  P="$(cd -P "$(new_project launch)" && pwd)"
  printf '## Items\n- [ ] **1. Open.**\n' >"$P/.nightshift/punch-list.md"
}

# The watchman outlives the test by design, so its sleep goes with it, and every launch closes
# the descriptor bats waits on (fd 3); a detached process holding it keeps the run open.
teardown() {
  local pid
  pid="$(sed -n 1p "$P/.nightshift/.watchman" 2>/dev/null)"
  [ -n "$pid" ] || return 0
  pkill -P "$pid" 2>/dev/null || true
  kill "$pid" 2>/dev/null || true
}

launch() { "$LAUNCHER" "$@" 3>&-; }

# From a shell left inside the state folder, the way the report found it: the dispatcher still
# resolves the workspace, and the launcher hands the watchman that path.
launch_from() {
  (cd "$1" && env -u CLAUDE_PROJECT_DIR -u CODEX_PROJECT_DIR -u CURSOR_PROJECT_DIR \
    -u NIGHTSHIFT_WORKSPACE NIGHTSHIFT_HOST=claude "$RT/ns" start-watchman --host claude 3>&-)
}

@test "a launch from inside .nightshift arms the watchman for the workspace" {
  run launch_from "$P/.nightshift"
  [ "$status" -eq 0 ]
  pid="$(sed -n 1p "$P/.nightshift/.watchman")"
  [ "$output" = "watchman started (pid $pid)" ]
  kill -0 "$pid"
  grep -qE 'watchman armed' "$P/.nightshift/shift-log.md"
  grep -qF "start-watchman: launching the claude watchman for $P" "$P/.nightshift/watchman.log"
  [ ! -e "$P/.nightshift/.nightshift" ]
}

@test "a second launch names the live watchman instead of starting another" {
  run launch --project "$P" --host claude
  [ "$status" -eq 0 ]
  pid="$(sed -n 1p "$P/.nightshift/.watchman")"
  run launch --project "$P" --host claude
  [ "$status" -eq 0 ]
  [ "$output" = "watchman already watching (pid $pid)" ]
  [ "$(grep -c 'watchman armed' "$P/.nightshift/shift-log.md")" -eq 1 ]
}

@test "a watchman that cannot arm is reported in its own words and nothing is left running" {
  rm "$P/.nightshift/rules.json"
  run launch --project "$P" --host claude
  [ "$status" -eq 2 ]
  printf '%s\n' "$output" | grep -qF 'start-watchman: the watchman exited before it armed (status 1)'
  printf '%s\n' "$output" | grep -qF 'watchman: watchMinutes missing or not whole minutes'
  printf '%s\n' "$output" | grep -qF "the full output is in $P/.nightshift/watchman.log"
  grep -qF 'watchman: watchMinutes missing' "$P/.nightshift/watchman.log"
  [ ! -e "$P/.nightshift/.watchman" ]
}

@test "the launcher needs the workspace and a host it has a watchman for" {
  run launch --host claude
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -qF -- '--project is required'
  run launch --project "$P" --host other
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -qF -- '--host must be claude, codex or cursor'
  [ ! -e "$P/.nightshift/watchman.log" ]
}
