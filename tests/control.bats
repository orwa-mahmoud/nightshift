load helpers

PLUGIN="$(cd -P "$BATS_TEST_DIRNAME/../plugins/nightshift" && pwd -P)"
STOP="$PLUGIN/runtime/stop-shift.sh"
RESET="$PLUGIN/runtime/reset-shift.sh"
PURGE="$PLUGIN/runtime/purge-workspace.sh"
LIB="$PLUGIN/lib/lib.sh"
CONTROL="$PLUGIN/lib/control.sh"
LINKER="$PLUGIN/runtime/link-workspace.sh"
START="$PLUGIN/skills/start/SKILL.md"
CODEX_HOOKS="$HOOKS/codex"

stop_cmd() { # <project>
  printf '%s --project %s' "$STOP" "$1"
}

@test "control helpers are executable and hooks do not load control.sh" {
  [ -x "$STOP" ]
  [ -x "$RESET" ]
  [ -x "$PURGE" ]
  if grep -R --include='*.sh' -F 'lib/control.sh' "$PLUGIN/hooks"; then
    return 1
  fi
}

@test "start refuses a paused shift with an expired deadline" {
  grep -qF 'ns_control_start_refuse_reason' \
    "$BATS_TEST_DIRNAME/../plugins/nightshift/lib/preflight-explain.txt"
  grep -qF 'Get-NSControlStartRefuseReason' \
    "$BATS_TEST_DIRNAME/../plugins/nightshift/lib/preflight-explain.txt"
  grep -qi 'deadline is cleared only if it has already passed' "$START"
}

@test "Stop writes STOP and keeps hardhat armed until ENDED" {
  p="$(new_project)"
  punch_open "$p"
  future=$(( $(date +%s) + 3600 ))
  printf '%s\n' "$future" >"$p/.nightshift/deadline"
  printf 'keep-me\n' >"$p/.nightshift/parking-lot.md"
  run "$STOP" --project "$p"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF 'deadline preserved'
  [ -f "$p/.nightshift/STOP" ]
  [ -f "$p/.nightshift/.shift-armed" ]
  [ ! -f "$p/.nightshift/.ended" ]
  [ -f "$p/.nightshift/deadline" ]
  [ "$(cat "$p/.nightshift/deadline")" = "$future" ]
  [ -f "$p/.nightshift/parking-lot.md" ]
  [ -f "$p/.nightshift/punch-list.md" ]
  [ -f "$p/.nightshift/rules.json" ]
  grep -q 'stopped by owner' "$p/.nightshift/shift-log.md"
  run hardhat_bash "$p" "git push" NIGHTSHIFT_FORBIDDEN_COMMANDS='git push'
  is_deny "$output"
  punch_done "$p"
  run hardhat_bash "$p" "git push" NIGHTSHIFT_FORBIDDEN_COMMANDS='git push'
  is_deny "$output"
  : >"$p/.nightshift/.ended"
  run hardhat_bash "$p" "git push" NIGHTSHIFT_FORBIDDEN_COMMANDS='git push'
  is_allow
  run "$STOP" --project "$p"
  [ "$status" -eq 0 ]
}

@test "Stop kills a verified watchman and refuses a reused or unverified PID" {
  p="$(new_project)"
  punch_open "$p"

  # Keep the shell (no exec): verification matches watchman.sh in ps args when
  # .watchman has no start-time line. After exec, Linux shows only "sleep".
  wm="$BATS_TEST_TMPDIR/watchman.sh"
  printf '#!/bin/sh\nsleep 300\n' >"$wm"
  chmod +x "$wm"
  "$wm" &
  wpid=$!
  printf '%s\n' "$wpid" >"$p/.nightshift/.watchman"
  run "$STOP" --project "$p"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF 'watchman stopped'
  if kill -0 "$wpid" 2>/dev/null; then
    return 1
  fi
  [ ! -f "$p/.nightshift/.watchman" ]

  p2="$(new_project unverified)"
  punch_open "$p2"
  sleep 300 &
  spid=$!
  printf '%s\n' "$spid" >"$p2/.nightshift/.watchman"
  run "$STOP" --project "$p2"
  [ "$status" -eq 2 ]
  printf '%s' "$output" | grep -qF 'watchman unverified'
  kill -0 "$spid"
  [ -f "$p2/.nightshift/.watchman" ]
  [ -f "$p2/.nightshift/.shift-armed" ]
  kill "$spid"
  wait "$spid" 2>/dev/null || true

  p3="$(new_project reused)"
  punch_open "$p3"
  sleep 300 &
  rpid=$!
  printf '%s\nnot-this-start\n' "$rpid" >"$p3/.nightshift/.watchman"
  run "$STOP" --project "$p3"
  [ "$status" -eq 0 ]
  kill -0 "$rpid"
  [ ! -f "$p3/.nightshift/.watchman" ]
  kill "$rpid"
  wait "$rpid" 2>/dev/null || true
}

@test "Stop keeps the lease and still allows the trusted helper through a recovery nonce" {
  p="$(new_project)"
  punch_open "$p"
  bash -c '. "$1"; ns_lease_takeover "$2/.nightshift" shift-session claude' \
    nightshift "$LIB" "$p"
  [ -f "$p/.nightshift/.shift-lease" ]
  run "$STOP" --project "$p"
  [ "$status" -eq 0 ]
  [ -e "$p/.nightshift/.shift-lease" ]
  [ -f "$p/.nightshift/.shift-armed" ]

  q="$(new_project nonce)"
  punch_open "$q"
  printf 'shift-session\n\n%s\n\nclaude\n' "$$" >"$q/.nightshift/.shift-session"
  start="$(ps -o lstart= -p $$ | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  printf 'shift-session\nclaude\n2\nnonce1\n%s\n%s\n' "$$" "$start" >"$q/.nightshift/.shift-lease"
  printf 'clock-out-failed\n\n' >"$q/.nightshift/.watch-reason"
  cmd="$(stop_cmd "$q")"
  out="$(jq -nc --arg sid 'shift-session' --arg c "$cmd" \
    '{tool_name:"Bash",session_id:$sid,tool_input:{command:$c}}' |
    env CLAUDE_PROJECT_DIR="$q" bash "$HOOKS/hardhat.sh")"
  [ -z "$out" ]
  out="$(jq -nc --arg sid 'helper-tab' --arg c "$cmd" \
    '{tool_name:"Bash",session_id:$sid,tool_input:{command:$c}}' |
    env CLAUDE_PROJECT_DIR="$q" bash "$HOOKS/hardhat.sh")"
  [ -z "$out" ]
  out="$(jq -nc --arg sid 'shift-session' \
    '{tool_name:"Bash",session_id:$sid,tool_input:{command:"echo hi"}}' |
    env CLAUDE_PROJECT_DIR="$q" bash "$HOOKS/hardhat.sh")"
  is_deny "$out"
  run "$STOP" --project "$q"
  [ "$status" -eq 0 ]
  [ -e "$q/.nightshift/.shift-lease" ]
  [ -f "$q/.nightshift/.shift-armed" ]
  [ -f "$q/.nightshift/.shift-session" ]
}

@test "hardhat allows only the trusted Stop helper and still protects the lease" {
  p="$(new_project)"
  punch_open "$p"
  cmd="$(stop_cmd "$p")"
  run hardhat_bash "$p" "$cmd"
  is_allow
  run bash -c 'jq -nc --arg c "$2" '\''{tool_name:"Bash",tool_input:{command:$c}}'\'' | env CODEX_PROJECT_DIR="$1" bash "$3/hardhat.sh"' \
    _ "$p" "$cmd" "$CODEX_HOOKS"
  is_allow
  run hardhat_bash "$p" "touch .nightshift/STOP"
  is_deny "$output"
  run hardhat_bash "$p" "rm -f .nightshift/.shift-lease"
  is_deny "$output"
  run hardhat_bash "$p" "$cmd; rm -f .nightshift/.shift-lease"
  is_deny "$output"
  other="$(new_project other)"
  punch_open "$other"
  run bash -c '. "$1"; . "$2"; ns_hardhat_trusted_shift_control "$3" "$4" "$5"' \
    nightshift "$PLUGIN/lib/lib.sh" "$HOOKS/shared/hardhat-core.sh" \
    "$(stop_cmd "$other")" "$PLUGIN" "$p"
  [ "$status" -ne 0 ]
}

@test "Start resume after Stop keeps a future deadline and refuses an expired paused deadline" {
  p="$(new_project)"
  punch_open "$p"
  future=$(( $(date +%s) + 7200 ))
  printf '%s\n' "$future" >"$p/.nightshift/deadline"
  run "$STOP" --project "$p"
  [ "$status" -eq 0 ]
  reason="$(bash -c '. "$1"; . "$2"; ns_control_start_refuse_reason "$3/.nightshift"' \
    nightshift "$LIB" "$CONTROL" "$p")"
  [ -z "$reason" ]

  printf '1\n' >"$p/.nightshift/deadline"
  reason="$(bash -c '. "$1"; . "$2"; ns_control_start_refuse_reason "$3/.nightshift"' \
    nightshift "$LIB" "$CONTROL" "$p")"
  [ -n "$reason" ]
  printf '%s' "$reason" | grep -q 'refusing to invent a time budget'
  : >"$p/.nightshift/.ended"
  reason="$(bash -c '. "$1"; . "$2"; ns_control_start_refuse_reason "$3/.nightshift"' \
    nightshift "$LIB" "$CONTROL" "$p")"
  [ -z "$reason" ]
}

@test "Reset removes the deadline and runtime markers but preserves durable content" {
  p="$(new_project)"
  punch_open "$p"
  future=$(( $(date +%s) + 3600 ))
  printf '%s\n' "$future" >"$p/.nightshift/deadline"
  printf 'parked\n' >"$p/.nightshift/parking-lot.md"
  printf 'orders\n' >"$p/.nightshift/work-orders.md"
  mkdir -p "$p/.nightshift/receipts" "$p/.nightshift/archive"
  printf 'r\n' >"$p/.nightshift/receipts/one.md"
  printf 'a\n' >"$p/.nightshift/archive/keep.md"
  printf 'research\n' >"$p/.nightshift/product-research.md"
  printf 'opp\n' >"$p/.nightshift/opportunity-map.md"
  printf 'snag\n' >"$p/.nightshift/snag-log.md"
  printf 'log\n' >"$p/.nightshift/shift-log.md"
  printf 'artifact\n' >"$p/.nightshift/work-mode"
  : >"$p/.nightshift/.shift-session"
  printf '{"schemaVersion":1,"shiftId":"9f2c40ab77e51d63","createdAt":"2026-09-02T02:30:00Z","source":"composition","deadlineEpoch":null,"verificationLevel":"final","toolingPolicy":"existing-tools"}\n' \
    >"$p/.nightshift/shift-policy.json"
  printf '{"schemaVersion":1,"verificationProfile":"fast","hours":null,"toolingPolicy":"existing-tools","execution":"review-first","updatedAt":"2026-09-02T02:30:00Z"}\n' \
    >"$p/.nightshift/shift-defaults.json"
  run "$RESET" --project "$p"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF 'deadline removed'
  [ -d "$p/.nightshift" ]
  [ ! -f "$p/.nightshift/deadline" ]
  [ ! -f "$p/.nightshift/STOP" ]
  [ ! -f "$p/.nightshift/.shift-armed" ]
  [ ! -f "$p/.nightshift/.shift-session" ]
  [ ! -e "$p/.nightshift/shift-policy.json" ]
  [ -f "$p/.nightshift/shift-defaults.json" ]
  [ -f "$p/.nightshift/punch-list.md" ]
  grep -q '\- \[ \]' "$p/.nightshift/punch-list.md"
  [ -f "$p/.nightshift/rules.json" ]
  [ -f "$p/.nightshift/parking-lot.md" ]
  [ -f "$p/.nightshift/work-orders.md" ]
  [ -f "$p/.nightshift/receipts/one.md" ]
  [ -f "$p/.nightshift/archive/keep.md" ]
  [ -f "$p/.nightshift/product-research.md" ]
  [ -f "$p/.nightshift/opportunity-map.md" ]
  [ -f "$p/.nightshift/snag-log.md" ]
  [ -f "$p/.nightshift/shift-log.md" ]
  [ -f "$p/.nightshift/work-mode" ]
  grep -q 'shift policy cleared' "$p/.nightshift/shift-log.md"
  run "$RESET" --project "$p"
  [ "$status" -eq 0 ]
}

@test "Reset refuses while provision-transaction.json is open" {
  p="$(new_project)"
  printf '{"schemaVersion":1,"stage":"apply","capabilityId":"test","failed":false}\n' \
    >"$p/.nightshift/provision-transaction.json"
  run "$RESET" --project "$p"
  [ "$status" -eq 1 ]
  printf '%s' "$output" | grep -qF 'provision-transaction.json'
  [ -f "$p/.nightshift/provision-transaction.json" ]
}

@test "Stop preserves tonight's shift policy; only Reset clears it" {
  p="$(new_project)"
  punch_open "$p"
  printf '{"schemaVersion":1,"shiftId":"9f2c40ab77e51d63","createdAt":"2026-09-02T02:30:00Z","source":"composition","deadlineEpoch":null,"verificationLevel":"final","toolingPolicy":"existing-tools"}\n' \
    >"$p/.nightshift/shift-policy.json"
  run "$STOP" --project "$p"
  [ "$status" -eq 0 ]
  [ -f "$p/.nightshift/shift-policy.json" ]
  run "$RESET" --project "$p"
  [ "$status" -eq 0 ]
  [ ! -e "$p/.nightshift/shift-policy.json" ]
}

@test "Purge deletes only the validated .nightshift directory and requires exact confirmation" {
  p="$(new_project)"
  punch_open "$p"
  printf 'secret\n' >"$p/README.md"
  printf '{"schemaVersion":1,"shiftId":"9f2c40ab77e51d63","createdAt":"2026-09-02T02:30:00Z","source":"composition","deadlineEpoch":null,"verificationLevel":"final","toolingPolicy":"existing-tools"}\n' \
    >"$p/.nightshift/shift-policy.json"
  printf '{"schemaVersion":1,"verificationProfile":"fast","hours":null,"toolingPolicy":"existing-tools","execution":"review-first","updatedAt":"2026-09-02T02:30:00Z"}\n' \
    >"$p/.nightshift/shift-defaults.json"
  ns="$(cd -P "$p/.nightshift" && pwd -P)"
  run "$PURGE" --project "$p"
  [ "$status" -eq 1 ]
  [ -d "$p/.nightshift" ]
  run "$PURGE" --project "$p" --confirm-path /tmp/wrong
  [ "$status" -eq 1 ]
  [ -d "$p/.nightshift" ]
  run "$PURGE" --project "$p" --confirm-path "$ns"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF 'plugin install was not touched'
  [ ! -e "$p/.nightshift" ]
  [ ! -e "$p/.nightshift/shift-policy.json" ]
  [ ! -e "$p/.nightshift/shift-defaults.json" ]
  [ -f "$p/README.md" ]
  [ -d "$p/.git" ]
  run "$PURGE" --project "$p" --confirm-path "$ns"
  [ "$status" -eq 0 ]
}

@test "Purge refuses symlinks, malformed links, and broad paths" {
  p="$(new_project)"
  punch_open "$p"
  rm -rf "$p/.nightshift"
  mkdir -p "$BATS_TEST_TMPDIR/elsewhere/.nightshift"
  ln -s "$BATS_TEST_TMPDIR/elsewhere/.nightshift" "$p/.nightshift"
  canon="$(bash -c '. "$1"; . "$2"; ns_control_canon_path "$3/.nightshift"' \
    nightshift "$LIB" "$CONTROL" "$p")"
  run "$PURGE" --project "$p" --confirm-path "$canon"
  [ "$status" -eq 1 ]
  [ -L "$p/.nightshift" ]
  [ -d "$BATS_TEST_TMPDIR/elsewhere/.nightshift" ]

  host="$(new_project host)"
  printf 'relative/path\n' >"$host/.nightshift-link"
  run "$PURGE" --project "$host" --confirm-path "$host/.nightshift"
  [ "$status" -eq 1 ]

  run "$PURGE" --project / --confirm-path /.nightshift
  [ "$status" -eq 1 ]
  [ -d / ]

  if [ -n "${HOME:-}" ] && [ -d "$HOME" ]; then
    run "$PURGE" --project "$HOME" --confirm-path "$HOME/.nightshift"
    [ "$status" -eq 1 ]
  fi
}

@test "Stop follows .nightshift-link and Purge from the task root removes the link" {
  host="$(new_project host)"
  workspace="$(new_workspace linked)"
  punch_open "$workspace"
  bash "$LINKER" --host-root "$host" --workspace "$workspace" >/dev/null
  future=$(( $(date +%s) + 3600 ))
  printf '%s\n' "$future" >"$workspace/.nightshift/deadline"
  run "$STOP" --project "$host"
  [ "$status" -eq 0 ]
  [ -f "$workspace/.nightshift/STOP" ]
  [ -f "$workspace/.nightshift/.shift-armed" ]
  [ -f "$workspace/.nightshift/deadline" ]
  [ -f "$host/.nightshift-link" ]
  ns="$(cd -P "$workspace/.nightshift" && pwd -P)"
  run "$PURGE" --project "$host" --confirm-path "$ns"
  [ "$status" -eq 0 ]
  [ ! -e "$workspace/.nightshift" ]
  [ ! -e "$host/.nightshift-link" ]
  [ -d "$workspace" ]
}

@test "helpers require --project and do not default to the working directory" {
  p="$(new_project)"
  punch_open "$p"
  run bash -c 'cd "$1" && "$2"' _ "$p" "$STOP"
  [ "$status" -eq 1 ]
  printf '%s' "$output" | grep -qF -- '--project is required'
  [ -f "$p/.nightshift/.shift-armed" ]
}
