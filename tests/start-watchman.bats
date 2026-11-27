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
  # Its own session and process group: a host tearing down the launching session's group
  # cannot end it.
  [ "$(ps -o pgid= -p "$pid" | tr -d ' ')" = "$pid" ]
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

@test "a live watchman with no pid file is not joined by a second" {
  canon="$(cd -P "$P" && pwd)"
  wm="$BATS_TEST_TMPDIR/watchman.sh"
  printf '#!/bin/sh\nsleep 300\n' >"$wm"
  chmod +x "$wm"
  "$wm" --project "$canon" &
  wpid=$!
  cleanup_unrecorded() {
    pkill -P "$wpid" 2>/dev/null || true
    kill "$wpid" 2>/dev/null || true
    wait "$wpid" 2>/dev/null || true
  }
  rm -f "$P/.nightshift/.watchman"
  run launch --project "$P" --host claude
  # After run, so the trap does not fire when run itself returns.
  trap cleanup_unrecorded RETURN
  [ "$status" -eq 0 ]
  [ "$output" = "watchman already watching (pid $wpid)" ]
  kill -0 "$wpid"
  [ ! -e "$P/.nightshift/.watchman" ]
}

@test "a watchman for another project does not block this one" {
  other="$(cd -P "$BATS_TEST_TMPDIR" && pwd)/other-project"
  wm="$BATS_TEST_TMPDIR/watchman.sh"
  printf '#!/bin/sh\nsleep 300\n' >"$wm"
  chmod +x "$wm"
  "$wm" --project "$other" &
  wpid=$!
  cleanup_other() {
    pkill -P "$wpid" 2>/dev/null || true
    kill "$wpid" 2>/dev/null || true
    wait "$wpid" 2>/dev/null || true
  }
  run launch --project "$P" --host claude
  trap cleanup_other RETURN
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qF 'watchman started'
  [ "$output" != "watchman already watching (pid $wpid)" ]
  kill -0 "$wpid"
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

@test "each run of a workspace gets its own watchman, named by its run" {
  w="$(cd -P "$(two_runs watch-runs)" && pwd)"
  wm="$BATS_TEST_TMPDIR/watchman.sh"
  printf '#!/bin/sh\nsleep 300\n' >"$wm"
  chmod +x "$wm"
  "$wm" --project "$w" --run a &
  wpid=$!
  cleanup_runs() {
    local p
    for p in "$wpid" "$(sed -n 1p "$w/.nightshift/runs/b/run/.watchman" 2>/dev/null)"; do
      [ -n "$p" ] || continue
      pkill -P "$p" 2>/dev/null || true
      kill "$p" 2>/dev/null || true
    done
    wait "$wpid" 2>/dev/null || true
  }
  run env NIGHTSHIFT_RUN=a "$LAUNCHER" --project "$w" --host claude 3>&-
  a_output="$output"
  run env NIGHTSHIFT_RUN=b "$LAUNCHER" --project "$w" --host claude 3>&-
  trap cleanup_runs RETURN
  # Run a is already watched; run b's watchman starts beside it, with its run on its command line.
  [ "$a_output" = "watchman already watching (pid $wpid)" ]
  [ "$status" -eq 0 ]
  pid="$(sed -n 1p "$w/.nightshift/runs/b/run/.watchman")"
  [ "$output" = "watchman started (pid $pid)" ]
  ps -o command= -p "$pid" | grep -qF -- '--run b'
  # With several runs and none named, the launcher names them instead of guessing.
  run env -u NIGHTSHIFT_RUN "$LAUNCHER" --project "$w" --host claude 3>&-
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -qF 'several runs and none named'
}
