load ../helpers

# The Codex watchman is the outside half for codex-owned shifts. Everything here runs with
# NIGHTSHIFT_WATCH_SLEEP=0 (the test speed lever) and small --max-wakes bounds. The agent is
# always stubbed: these tests prove the DECISIONS, not the codex CLI.

setup() {
  WATCHMAN="$BATS_TEST_DIRNAME/../../plugins/nightshift/runtime/codex/watchman.sh"
  P="$BATS_TEST_TMPDIR/proj"
  mkdir -p "$P/.nightshift"
  cp "$BATS_TEST_DIRNAME/../../plugins/nightshift/config/nightshift-rules-template.json" "$P/.nightshift/rules.json"
  printf '## Items\n- [ ] **1.**\n' >"$P/.nightshift/punch-list.md"
  # An unattended revival needs a scope it can vouch for, and these fixtures record none — the
  # shipped inherit setting would refuse. A site that means to be revived says which scope a
  # revival may use, and these tests are about reviving.
  jq '.recovery.launchScope = "host-default"' "$P/.nightshift/rules.json" >"$P/.nightshift/r.json"
  mv "$P/.nightshift/r.json" "$P/.nightshift/rules.json"

  # a recorded codex shift whose rollout is a plain file the tests control
  ROLLOUT="$BATS_TEST_TMPDIR/rollout.jsonl"
  printf '{"type":"session_meta"}\n' >"$ROLLOUT"
  printf 'dead-sid\n%s\n99999\nnever\ncodex\n' "$ROLLOUT" >"$P/.nightshift/.shift-session"
  : >"$P/.nightshift/.shift-armed"
  printf '%s dead-sid\n' "$(($(date +%s) - 100000))" >"$P/.nightshift/.shift-pulse"

  BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$BIN"
  cat >"$BIN/tick.sh" <<'STUB'
#!/usr/bin/env bash
echo "called $NIGHTSHIFT_REVIVAL" >>.nightshift/agent-calls
if ! grep -qE '^- \[ \]' .nightshift/punch-list.md \
  || { [ -f .nightshift/deadline ] && [ "$(date +%s)" -ge "$(tr -d '[:space:]' <.nightshift/deadline)" ]; }; then
  : >.nightshift/.ended
  rm -f .nightshift/.shift-armed .nightshift/.shift-lease
  exit 0
fi
awk 'BEGIN{d=0} !d && /^- \[ \]/{sub(/\[ \]/,"[x]");d=1} {print}' .nightshift/punch-list.md >.nightshift/pl.tmp
mv .nightshift/pl.tmp .nightshift/punch-list.md
STUB
  chmod +x "$BIN"/*.sh
}

watch() { # watch [extra args...] — fast defaults, stubbed agent
  env NIGHTSHIFT_WATCH_SLEEP=0 NIGHTSHIFT_WATCH_RETRY="0 0" \
    "$WATCHMAN" --project "$P" --interval 20 --agent "bash $BIN/tick.sh" "$@"
}

calls() { grep -c called "$P/.nightshift/agent-calls" 2>/dev/null || echo 0; }

@test "interval 0 is the disabled spelling: exits at once, arms nothing" {
  run "$WATCHMAN" --project "$P" --interval 0
  [ "$status" -eq 0 ]
  [ ! -f "$P/.nightshift/.watchman" ]
}

@test "a missing rules file refuses to arm" {
  rm "$P/.nightshift/rules.json"
  run "$WATCHMAN" --project "$P"
  [ "$status" -eq 1 ]
  printf '%s' "$output" | grep -qF '/nightshift:setup'
  printf '%s' "$output" | grep -qF 'ask Nightshift to set up on Codex'
}

@test "refuses to double-arm while another watchman is alive" {
  printf '%s\n' "$$" >"$P/.nightshift/.watchman"
  run watch --max-wakes 1
  [ "$status" -eq 1 ]
  printf '%s' "$output" | grep -q 'already watching'
}

@test "a stop-work order stands it down" {
  touch "$P/.nightshift/STOP"
  run watch --max-wakes 3
  [ "$status" -eq 0 ]
  [ "$(calls)" -eq 0 ]
}

# The mirror of the Claude watchman's host guard: a shift another host owns is never revived
# from here — its own watchman minds it.
@test "a claude-owned shift stands the codex watchman down" {
  printf 'sid\n\n\n\nclaude\n' >"$P/.nightshift/.shift-session"
  run watch --max-wakes 1
  [ "$status" -eq 0 ]
  [ "$(calls)" -eq 0 ]
  grep -q 'owned by claude' "$P/.nightshift/shift-log.md"
}

@test "a record with no host line is claude's — stood down, never adopted" {
  printf 'sid\n\n\n\n' >"$P/.nightshift/.shift-session"
  run watch --max-wakes 1
  [ "$status" -eq 0 ]
  [ "$(calls)" -eq 0 ]
}

@test "a dead record with open boxes is revived, marked as a revival" {
  run watch --max-wakes 1
  [ "$status" -eq 0 ]
  [ "$(calls)" -ge 1 ]
  grep -q 'called 1' "$P/.nightshift/agent-calls" # NIGHTSHIFT_REVIVAL=1 reached the child
  grep -q 'resume attempt 1' "$P/.nightshift/shift-log.md"
}

@test "a Codex revival receives the exact lease generation written before spawn" {
  cat >"$BIN/tick.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n%s\n' "$NIGHTSHIFT_LEASE_GENERATION" "$NIGHTSHIFT_LEASE_NONCE" >.nightshift/lease-env
sed -n '3,4p' .nightshift/.shift-lease >.nightshift/lease-at-spawn
STUB
  chmod +x "$BIN/tick.sh"

  run watch --max-wakes 1
  [ "$status" -eq 0 ]
  [ -n "$(sed -n 1p "$P/.nightshift/lease-env")" ]
  [ "$(sed -n 1p "$P/.nightshift/lease-env")" = "$(sed -n 1p "$P/.nightshift/lease-at-spawn")" ]
  [ "$(sed -n 2p "$P/.nightshift/lease-env")" = "$(sed -n 2p "$P/.nightshift/lease-at-spawn")" ]
}

@test "the recorded pid alive with a matching start time stands it by" {
  start="$(ps -o lstart= -p $$ | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  printf 'sid\n%s\n%s\n%s\ncodex\n' "$ROLLOUT" "$$" "$start" >"$P/.nightshift/.shift-session"
  run watch --max-wakes 2
  [ "$status" -eq 0 ]
  [ "$(calls)" -eq 0 ]
}

@test "a growing rollout is a pulse: stood by, not revived" {
  # The appender must provably beat every wake, or the first zero-sleep wake reads a quiet
  # rollout and revives — a race, not a verdict. It writes every 0.1s and the watchman sleeps a
  # full second per wake, and the test waits for the first append before arming.
  ( while sleep 0.1; do echo x >>"$ROLLOUT"; done ) &
  appender=$!
  base="$(wc -c <"$ROLLOUT")"
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ "$(wc -c <"$ROLLOUT")" != "$base" ] && break
    sleep 0.2
  done
  run env NIGHTSHIFT_WATCH_SLEEP=1 NIGHTSHIFT_WATCH_RETRY="0 0"     "$WATCHMAN" --project "$P" --interval 20 --agent "bash $BIN/tick.sh" --max-wakes 3
  kill "$appender" 2>/dev/null || true
  [ "$status" -eq 0 ]
  [ "$(calls)" -eq 0 ]
}

@test "all boxes ticked with no .ended gets one clock-out spawn, then down" {
  printf '## Items\n- [x] **1.**\n' >"$P/.nightshift/punch-list.md"
  : >"$P/.nightshift/.shift-armed"
  run watch --max-wakes 3
  [ "$status" -eq 0 ]
  [ "$(calls)" -eq 1 ]
  [ -f "$P/.nightshift/.ended" ]
  [ ! -f "$P/.nightshift/.shift-armed" ]
  [ ! -f "$P/.nightshift/.shift-lease" ]
  grep -q 'never clocked out' "$P/.nightshift/shift-log.md"
}

@test "a failed Codex terminal clock-out stands down after one attempt" {
  cat >"$BIN/fail.sh" <<'STUB'
#!/usr/bin/env bash
echo "called $NIGHTSHIFT_REVIVAL" >>.nightshift/agent-calls
exit 1
STUB
  chmod +x "$BIN/fail.sh"
  printf '## Items\n- [x] **1.**\n' >"$P/.nightshift/punch-list.md"

  run watch --agent "bash $BIN/fail.sh" --max-wakes 5
  [ "$status" -eq 0 ]
  [ "$(calls)" -eq 1 ]
  [ ! -f "$P/.nightshift/.ended" ]
  [ "$(sed -n 1p "$P/.nightshift/.watch-reason" | tr -d '[:space:]')" = "clock-out-failed" ]
  grep -qF 'clock-out attempt 1/1' "$P/.nightshift/shift-log.md"
}

@test "a spent deadline with a failed Codex clock-out is bounded" {
  cat >"$BIN/fail.sh" <<'STUB'
#!/usr/bin/env bash
echo "called $NIGHTSHIFT_REVIVAL" >>.nightshift/agent-calls
exit 1
STUB
  chmod +x "$BIN/fail.sh"
  echo $(($(date +%s) - 60)) >"$P/.nightshift/deadline"
  run watch --agent "bash $BIN/fail.sh" --max-wakes 5
  [ "$status" -eq 0 ]
  [ "$(calls)" -eq 1 ]
  [ "$(sed -n 1p "$P/.nightshift/.watch-reason" | tr -d '[:space:]')" = "clock-out-failed" ]
}

@test "default Codex watchman config cannot loop a failed terminal clock-out" {
  cat >"$BIN/fail.sh" <<'STUB'
#!/usr/bin/env bash
echo "called $NIGHTSHIFT_REVIVAL" >>.nightshift/agent-calls
exit 1
STUB
  chmod +x "$BIN/fail.sh"
  printf '## Items\n- [x] **1.**\n' >"$P/.nightshift/punch-list.md"
  run env NIGHTSHIFT_WATCH_SLEEP=0 NIGHTSHIFT_WATCH_RETRY="0 0" \
    "$WATCHMAN" --project "$P" --interval 20 --agent "bash $BIN/fail.sh"
  [ "$status" -eq 0 ]
  [ "$(calls)" -eq 1 ]
  [ "$(sed -n 1p "$P/.nightshift/.watch-reason" | tr -d '[:space:]')" = "clock-out-failed" ]
}

@test "a spent deadline with a dead session gets the clock-out spawn" {
  echo $(($(date +%s) - 60)) >"$P/.nightshift/deadline"
  run watch --max-wakes 1
  [ "$status" -eq 0 ]
  [ "$(calls)" -eq 1 ]
  grep -q 'past the deadline' "$P/.nightshift/shift-log.md"
}

@test ".ended stands it down before anything else spawns" {
  touch "$P/.nightshift/.ended"
  run watch --max-wakes 3
  [ "$status" -eq 0 ]
  [ "$(calls)" -eq 0 ]
}

reason() { sed -n 1p "$P/.nightshift/.watch-reason" | tr -d '[:space:]'; }

@test "Codex stop-work records owner-stop" {
  touch "$P/.nightshift/STOP"
  run watch --max-wakes 3
  [ "$(reason)" = "owner-stop" ]
}

@test "Codex .ended records completed" {
  touch "$P/.nightshift/.ended"
  run watch --max-wakes 3
  [ "$(reason)" = "completed" ]
}

@test "Codex foreign host records wrong-host" {
  printf 'sid\n\n\n\nclaude\n' >"$P/.nightshift/.shift-session"
  run watch --max-wakes 1
  [ "$(reason)" = "wrong-host" ]
}

@test "a run leased to Codex before its worker records a session is the Codex watchman's" {
  rm -f "$P/.nightshift/.shift-session"
  printf '\ncodex\n1\ncodex.1.test\n\n\n' >"$P/.nightshift/.shift-lease"
  run watch --max-wakes 1
  [ "$(reason)" != "wrong-host" ]
}

@test "a symlink shift-session is not a Codex-owned record" {
  printf 'dead-sid\n%s\n99999\nnever\ncodex\n' "$ROLLOUT" >"$P/.nightshift/session-plant"
  rm -f "$P/.nightshift/.shift-session"
  ln -s session-plant "$P/.nightshift/.shift-session"
  run watch --max-wakes 1
  [ "$(reason)" = "wrong-host" ]
}

@test "Codex ticked boxes record completed" {
  printf '## Items\n- [x] **1.**\n' >"$P/.nightshift/punch-list.md"
  run watch --max-wakes 3
  [ "$(reason)" = "completed" ]
}

@test "Codex spent deadline records deadline" {
  echo $(($(date +%s) - 60)) >"$P/.nightshift/deadline"
  run watch --max-wakes 1
  [ "$(reason)" = "deadline" ]
}

@test "Codex live pid records silent-standby" {
  start="$(ps -o lstart= -p $$ | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  printf 'sid\n%s\n%s\n%s\ncodex\n' "$ROLLOUT" "$$" "$start" >"$P/.nightshift/.shift-session"
  run watch --max-wakes 2
  [ "$(reason)" = "silent-standby" ]
}

@test "Codex successful resume records revived" {
  printf 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee\n%s\n99999\nnever\ncodex\n' "$ROLLOUT" >"$P/.nightshift/.shift-session"
  run watch --max-wakes 1
  [ "$(reason)" = "revived" ]
}

@test "watchRetrySeconds sets the number of Codex revival attempts" {
  cat >"$BIN/fail.sh" <<'STUB'
#!/usr/bin/env bash
echo "called $NIGHTSHIFT_REVIVAL" >>.nightshift/agent-calls
exit 1
STUB
  chmod +x "$BIN/fail.sh"
  run env NIGHTSHIFT_WATCH_SLEEP=0 NIGHTSHIFT_WATCH_RETRY="0 0 0 0" \
    "$WATCHMAN" --project "$P" --interval 20 --agent "bash $BIN/fail.sh" --max-wakes 1
  [ "$(calls)" -eq 5 ]
}

@test "Codex failed revival records exhausted-retry" {
  cat >"$BIN/fail.sh" <<'STUB'
#!/usr/bin/env bash
echo "called $NIGHTSHIFT_REVIVAL" >>.nightshift/agent-calls
exit 1
STUB
  chmod +x "$BIN/fail.sh"
  run env NIGHTSHIFT_WATCH_SLEEP=0 NIGHTSHIFT_WATCH_RETRY="0 0" \
    "$WATCHMAN" --project "$P" --interval 20 --agent "bash $BIN/fail.sh" --max-wakes 1
  [ "$(reason)" = "exhausted-retry" ]
}

@test "Codex missing rules record unreadable-rules" {
  rm "$P/.nightshift/rules.json"
  run "$WATCHMAN" --project "$P"
  [ "$(reason)" = "unreadable-rules" ]
  printf '%s' "$output" | grep -qF '/nightshift:setup on Claude Code; ask Nightshift to set up on Codex'
}

@test "an unsupported Codex identity stands down without invoking Codex" {
  printf 'thread_abc\n%s\n99999\nnever\ncodex\n' "$ROLLOUT" >"$P/.nightshift/.shift-session"
  cat >"$BIN/codex" <<'STUB'
#!/usr/bin/env bash
echo "invoked $*" >>.nightshift/agent-calls
exit 0
STUB
  chmod +x "$BIN/codex"
  punch="$(cat "$P/.nightshift/punch-list.md")"
  run env PATH="$BIN:$PATH" NIGHTSHIFT_WATCH_SLEEP=0 NIGHTSHIFT_WATCH_RETRY="0 0" \
    "$WATCHMAN" --project "$P" --interval 20 --max-wakes 1
  [ "$status" -eq 0 ]
  [ "$(reason)" = "non-resumable-session" ]
  [ ! -f "$P/.nightshift/agent-calls" ]
  [ "$(cat "$P/.nightshift/punch-list.md")" = "$punch" ]
  grep -q 'not resuming' "$P/.nightshift/shift-log.md"
}

@test "a rollout path is malformed and never resumed or replaced" {
  printf '/tmp/rollout.jsonl\n%s\n99999\nnever\ncodex\n' "$ROLLOUT" >"$P/.nightshift/.shift-session"
  cat >"$BIN/codex" <<'STUB'
#!/usr/bin/env bash
echo invoked >>.nightshift/agent-calls
exit 0
STUB
  chmod +x "$BIN/codex"
  run env PATH="$BIN:$PATH" NIGHTSHIFT_WATCH_SLEEP=0 NIGHTSHIFT_WATCH_RETRY="0 0" \
    "$WATCHMAN" --project "$P" --interval 20 --max-wakes 1
  [ "$(reason)" = "non-resumable-session" ]
  [ ! -f "$P/.nightshift/agent-calls" ]
}

@test "a missing Codex session id uses the fresh fallback, never claims revived" {
  printf '\n%s\n99999\nnever\ncodex\n' "$ROLLOUT" >"$P/.nightshift/.shift-session"
  cat >"$BIN/codex" <<'STUB'
#!/usr/bin/env bash
echo "called $NIGHTSHIFT_REVIVAL" >>.nightshift/agent-calls
awk 'BEGIN{d=0} !d && /^- \[ \]/{sub(/\[ \]/,"[x]");d=1} {print}' .nightshift/punch-list.md >.nightshift/pl.tmp
mv .nightshift/pl.tmp .nightshift/punch-list.md
STUB
  chmod +x "$BIN/codex"
  run env PATH="$BIN:$PATH" NIGHTSHIFT_WATCH_SLEEP=0 NIGHTSHIFT_WATCH_RETRY="0 0" \
    "$WATCHMAN" --project "$P" --interval 20 --max-wakes 1
  [ "$(reason)" = "fresh-fallback" ]
  [ "$(calls)" -ge 1 ]
  if grep -q 'exec resume' "$P/.nightshift/agent-calls"; then
    return 1
  fi
}

@test "a resumable UUID is passed to exec resume and not replaced" {
  sid='aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
  printf '%s\n%s\n99999\nnever\ncodex\n' "$sid" "$ROLLOUT" >"$P/.nightshift/.shift-session"
  cat >"$BIN/codex" <<'STUB'
#!/usr/bin/env bash
echo "called $*" >>.nightshift/agent-calls
awk 'BEGIN{d=0} !d && /^- \[ \]/{sub(/\[ \]/,"[x]");d=1} {print}' .nightshift/punch-list.md >.nightshift/pl.tmp
mv .nightshift/pl.tmp .nightshift/punch-list.md
STUB
  chmod +x "$BIN/codex"
  run env PATH="$BIN:$PATH" NIGHTSHIFT_WATCH_SLEEP=0 NIGHTSHIFT_WATCH_RETRY="0 0" \
    "$WATCHMAN" --project "$P" --interval 20 --max-wakes 1
  [ "$(reason)" = "revived" ]
  grep -q 'exec resume' "$P/.nightshift/agent-calls"
  grep -q "$sid" "$P/.nightshift/agent-calls"
}

@test "identity rejection still holds on a linked workspace" {
  host="$BATS_TEST_TMPDIR/host-link"
  mkdir -p "$host"
  printf 'thread_abc\n%s\n99999\nnever\ncodex\n' "$ROLLOUT" >"$P/.nightshift/.shift-session"
  bash "$BATS_TEST_DIRNAME/../../plugins/nightshift/runtime/link-workspace.sh" \
    --host-root "$host" --workspace "$P" >/dev/null
  cat >"$BIN/codex" <<'STUB'
#!/usr/bin/env bash
echo invoked >>.nightshift/agent-calls
exit 0
STUB
  chmod +x "$BIN/codex"
  run env PATH="$BIN:$PATH" NIGHTSHIFT_WATCH_SLEEP=0 \
    "$WATCHMAN" --project "$P" --interval 20 --max-wakes 1
  [ "$(reason)" = "non-resumable-session" ]
  [ ! -f "$P/.nightshift/agent-calls" ]
}
@test "a clean session end stands the Codex watchman down without reviving" {
  echo 'clean session end (other)' >"$P/.nightshift/.session-end"
  run watch --max-wakes 3
  [ "$status" -eq 0 ]
  [ "$(calls)" -eq 0 ]
  grep -q 'the owner closed it' "$P/.nightshift/shift-log.md"
  [ "$(reason)" = "clean-session-end" ]
}

@test "a fresh pulse stands the Codex watchman by" {
  printf '%s dead-sid\n' "$(date +%s)" >"$P/.nightshift/.shift-pulse"
  run watch --max-wakes 2
  [ "$status" -eq 0 ]
  [ "$(calls)" -eq 0 ]
}

@test "a stale pulse with no growth and no session-end revives" {
  printf '%s dead-sid\n' "$(($(date +%s) - 100000))" >"$P/.nightshift/.shift-pulse"
  run watch --max-wakes 1
  [ "$status" -eq 0 ]
  [ "$(calls)" -ge 1 ]
  grep -q 'resume attempt 1' "$P/.nightshift/shift-log.md"
}

# Disarm is total on every host: with the marker gone there is no shift to revive, and the
# lease a failed ladder took goes back to the recorded conversation.
@test "a missing armed marker stands the Codex watchman down" {
  rm -f "$P/.nightshift/.shift-armed"
  run watch --max-wakes 3
  [ "$status" -eq 0 ]
  [ "$(calls)" -eq 0 ]
  grep -qF 'watchman: the armed marker is gone — standing down' "$P/.nightshift/shift-log.md"
  [ "$(reason)" = "owner-disarm" ]
  [ ! -e "$P/.nightshift/.shift-armed" ]
}

@test "an exhausted Codex ladder hands the lease back to the recorded conversation" {
  cat >"$BIN/fail.sh" <<'STUB'
#!/usr/bin/env bash
echo called >>.nightshift/agent-calls
exit 1
STUB
  chmod +x "$BIN/fail.sh"
  run env NIGHTSHIFT_WATCH_SLEEP=0 NIGHTSHIFT_WATCH_RETRY="0" \
    "$WATCHMAN" --project "$P" --interval 20 --agent "bash $BIN/fail.sh" --max-wakes 1
  [ "$status" -eq 0 ]
  [ "$(reason)" = "exhausted-retry" ]
  [ "$(sed -n 1p "$P/.nightshift/.shift-lease")" = "dead-sid" ]
  [ -z "$(sed -n 4p "$P/.nightshift/.shift-lease")" ]
}

# A failed model request closes the turn and leaves the session open and quiet.
errored_turn() { # <codex_error_info>
  printf '{"timestamp":"t","type":"event_msg","payload":{"type":"task_started"}}\n' >>"$ROLLOUT"
  printf '{"timestamp":"t","type":"event_msg","payload":{"type":"task_complete","turn_id":"x","completed_at":1790378886,"error":{"message":"unexpected status 401 Unauthorized","codex_error_info":"%s"}}}\n' \
    "$1" >>"$ROLLOUT"
}

@test "a live session whose last turn ended on an API error is revived, and the gap is recorded" {
  errored_turn other
  start="$(ps -o lstart= -p $$ | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  printf 'sid\n%s\n%s\n%s\ncodex\n' "$ROLLOUT" "$$" "$start" >"$P/.nightshift/.shift-session"
  printf '%s sid\n' "$(date +%s)" >"$P/.nightshift/.shift-pulse"
  run watch --max-wakes 1
  [ "$status" -eq 0 ]
  [ "$(calls)" -ge 1 ]
  grep -qF 'the last turn ended on an API error (other)' "$P/.nightshift/shift-log.md"
  grep -qxF "$(printf '1790378886\tthe session stopped on an API error (other)')" "$P/.nightshift/usage/pauses.tsv"
}

@test "a clean last turn is not a wedge" {
  printf '{"type":"event_msg","payload":{"type":"task_complete","completed_at":1,"error":null}}\n' >>"$ROLLOUT"
  start="$(ps -o lstart= -p $$ | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  printf 'sid\n%s\n%s\n%s\ncodex\n' "$ROLLOUT" "$$" "$start" >"$P/.nightshift/.shift-session"
  run watch --max-wakes 1
  [ "$(calls)" -eq 0 ]
  ! grep -qF 'API error' "$P/.nightshift/shift-log.md" || false
}

quota_fixture() {
  cp "$BATS_TEST_DIRNAME/../fixtures/codex-limits/$1.jsonl" "$ROLLOUT"
}

@test "Codex quota reset comes from the failed turn's exhausted windows or explicit error" {
  . "$BATS_TEST_DIRNAME/../../plugins/nightshift/lib/lib.sh"
  for pair in primary:2000001921 weekly:2000540730 both:2000540730 explicit:2000000600 missing: stale: partial:; do
    quota_fixture "${pair%%:*}"
    [ "$(ns_codex_limit_reset "$ROLLOUT")" = "${pair#*:}" ] || { echo "reset mismatch for $pair"; return 1; }
  done
  quota_fixture primary
  printf '{"type":"event_msg","payload":{"type":"task_started"}}\n' >>"$ROLLOUT"
  [ -z "$(ns_codex_limit_reset "$ROLLOUT")" ]
  [ -z "$(ns_codex_turn_error "$ROLLOUT")" ]
}

watch_quota() { # <poll timestamps...>
  export QUOTA_CLOCK="$BATS_TEST_TMPDIR/clock"
  printf '2000000000\n' >"$QUOTA_CLOCK"
  printf '%s\n' "$@" >"$QUOTA_CLOCK.polls"
  export QUOTA_SID='eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee'
  printf '%s\n%s\n\n\ncodex\n' "$QUOTA_SID" "$ROLLOUT" >"$P/.nightshift/.shift-session"
  cat >"$BIN/date" <<'STUB'
#!/bin/bash
if [ "$*" = '+%s' ]; then cat "$QUOTA_CLOCK"; else exec /bin/date "$@"; fi
STUB
  cat >"$BIN/sleep" <<'STUB'
#!/bin/bash
if [ "$1" != "$NIGHTSHIFT_WATCH_SLEEP" ]; then exec /bin/sleep "$@"; fi
poll=$(cat "$QUOTA_CLOCK.poll" 2>/dev/null || printf '0')
poll=$((poll + 1))
printf '%s\n' "$poll" >"$QUOTA_CLOCK.poll"
sed -n "${poll}p" "$QUOTA_CLOCK.polls" >"$QUOTA_CLOCK"
STUB
  cat >"$BIN/codex" <<'STUB'
#!/bin/bash
printf '%s %s %s %s\n' "$(cat "$QUOTA_CLOCK")" "$1" "$2" "$3" >>.nightshift/codex-calls
[ -z "${QUOTA_FAIL:-}" ] || exit 1
[ "$1 $2 $3" = "exec resume $QUOTA_SID" ] || exit 1
[ -n "$NIGHTSHIFT_LEASE_NONCE" ] && [ "$NIGHTSHIFT_LEASE_NONCE" = "$(sed -n 4p .nightshift/.shift-lease)" ] || exit 1
printf '## Items\n- [x] **1.**\n' >.nightshift/punch-list.md
STUB
  chmod +x "$BIN/date" "$BIN/sleep" "$BIN/codex"
  env PATH="$BIN:$PATH" NIGHTSHIFT_WATCH_SLEEP=123 NIGHTSHIFT_WATCH_RETRY='0 0' \
    "$WATCHMAN" --project "$P" --interval 1 --max-wakes "$#"
}

@test "Codex waits for the primary reset then resumes the recorded chat on that poll" {
  quota_fixture primary
  run watch_quota 2000001920
  [ "$status" -eq 0 ]
  [ "$(reason)" = usage-limit ]
  [ "$(sed -n 2p "$P/.nightshift/.watch-reason")" = 2000001921 ]
  [ ! -e "$P/.nightshift/codex-calls" ]
  rm "$BATS_TEST_TMPDIR/clock.poll"

  run watch_quota 2000001920 2000001921
  [ "$status" -eq 0 ]
  [ "$(cat "$P/.nightshift/codex-calls")" = '2000001921 exec resume eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee' ]
  [ "$(reason)" = revived ]
}

@test "Codex reports an unknown reset and uses the bounded retry ladder" {
  quota_fixture stale
  export QUOTA_FAIL=1
  run watch_quota 2000000001
  [ "$status" -eq 0 ]
  [ "$(wc -l <"$P/.nightshift/codex-calls" | tr -d ' ')" -eq 3 ]
  [ "$(reason)" = exhausted-retry ]
  grep -qF 'Codex usage limit reset time is unknown' "$P/.nightshift/shift-log.md"
}

@test "watchAfterUsageLimit false holds the Codex chat even after its reset" {
  quota_fixture primary
  jq '.watchAfterUsageLimit = false' "$P/.nightshift/rules.json" >"$P/.nightshift/r.json"
  mv "$P/.nightshift/r.json" "$P/.nightshift/rules.json"
  run watch_quota 2000001920 2000001921
  [ "$status" -eq 0 ]
  [ ! -e "$P/.nightshift/codex-calls" ]
  [ "$(reason)" = usage-limit ]
}

@test "a removed watchman pidfile stands the Codex watchman down" {
  cat >"$BIN/unclaim.sh" <<'STUB'
#!/usr/bin/env bash
echo called >>.nightshift/agent-calls
rm -f .nightshift/.watchman
exit 0
STUB
  chmod +x "$BIN/unclaim.sh"
  run watch --agent "bash $BIN/unclaim.sh" --max-wakes 2
  [ "$status" -eq 0 ]
  [ "$(calls)" -ge 1 ]
  grep -qF 'watchman: the watchman pidfile is gone — standing down' "$P/.nightshift/shift-log.md"
}
