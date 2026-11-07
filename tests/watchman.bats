load helpers

# The watchman is the outside half of the product: hooks cannot fire in a dead session, so a
# separate process revives a site that is mid-shift AND quiet. Everything here runs with
# NIGHTSHIFT_WATCH_SLEEP=0 (the test speed lever) and small --max-wakes bounds.

setup() {
  WATCHMAN="$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/claude/watchman.sh"
  SESSION_END="$BATS_TEST_DIRNAME/../plugins/nightshift/hooks/session-end.sh"
  P="$BATS_TEST_TMPDIR/proj"
  mkdir -p "$P/.nightshift"
  cp "$BATS_TEST_DIRNAME/../plugins/nightshift/skills/nightshift/references/nightshift-rules-template.json" "$P/.nightshift/rules.json"
  printf '## Items\n- [ ] **1.**\n' >"$P/.nightshift/punch-list.md"
  : >"$P/.nightshift/.shift-armed" # as start does — the watchman only works an armed site
  # An unattended revival needs a scope it can vouch for. Claude Code names none, so the shipped
  # inherit setting has nothing to inherit and refuses; a site that means to be revived says which
  # scope a revival may use. These tests are about reviving, so they say it.
  jq '.recovery.launchScope = "host-default"' "$P/.nightshift/rules.json" >"$P/.nightshift/r.json"
  mv "$P/.nightshift/r.json" "$P/.nightshift/rules.json"

  BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$BIN"
  # logs the call, then ticks the first open box (CWD is the project — watchman cd's there)
  cat >"$BIN/tick.sh" <<'STUB'
#!/usr/bin/env bash
echo called >>.nightshift/agent-calls
if ! grep -qE '^- \[ \]' .nightshift/punch-list.md \
  || { [ -f .nightshift/deadline ] && [ "$(date +%s)" -ge "$(tr -d '[:space:]' <.nightshift/deadline)" ]; }; then
  : >.nightshift/.ended
  rm -f .nightshift/.shift-armed .nightshift/.shift-lease
  exit 0
fi
awk 'BEGIN{d=0} !d && /^- \[ \]/{sub(/\[ \]/,"[x]");d=1} {print}' .nightshift/punch-list.md >.nightshift/pl.tmp
mv .nightshift/pl.tmp .nightshift/punch-list.md
STUB
  # logs the call and fails — the API-down shape
  cat >"$BIN/fail.sh" <<'STUB'
#!/usr/bin/env bash
echo called >>.nightshift/agent-calls
exit 1
STUB
  chmod +x "$BIN"/*.sh
}

watch() { # watch [extra watchman args...] — fast defaults
  env NIGHTSHIFT_WATCH_SLEEP=0 NIGHTSHIFT_WATCH_RETRY="0 0" \
    "$WATCHMAN" --project "$P" --interval 20 "$@"
}

calls() { grep -c called "$P/.nightshift/agent-calls" 2>/dev/null || echo 0; }

recorded_read() {
  jq -nc --arg sid "$2" \
    '{tool_name:"Read",session_id:$sid,transcript_path:"",tool_input:{file_path:"README.md"}}' |
    CLAUDE_PROJECT_DIR="$1" bash "$HOOKS/hardhat.sh"
}

@test "interval 0 is the disabled spelling: exits at once, arms nothing" {
  run "$WATCHMAN" --project "$P" --interval 0
  [ "$status" -eq 0 ]
  [ ! -f "$P/.nightshift/.watchman" ]
}

@test "refuses to double-arm while another watchman is alive" {
  printf '%s\n' "$$" >"$P/.nightshift/.watchman"
  run watch --max-wakes 1
  [ "$status" -eq 1 ]
  printf '%s' "$output" | grep -q 'already watching'
}

@test "a symlink watchman pidfile does not block a new watchman" {
  printf '%s\n' "$$" >"$P/.nightshift/watchman-plant"
  ln -s watchman-plant "$P/.nightshift/.watchman"
  run watch --agent "bash $BIN/tick.sh" --max-wakes 5
  [ "$status" -eq 0 ]
  [ ! -L "$P/.nightshift/.watchman" ]
  [ "$(sed -n 1p "$P/.nightshift/watchman-plant")" = "$$" ]
  if printf '%s' "$output" | grep -q 'already watching'; then
    return 1
  fi
}

@test "a stop-work order stands it down" {
  touch "$P/.nightshift/STOP"
  run watch --agent "bash $BIN/tick.sh" --max-wakes 3
  [ "$status" -eq 0 ]
  grep -q 'stop-work order — standing down' "$P/.nightshift/shift-log.md"
  [ "$(calls)" -eq 0 ]
}

@test "an already-ended shift stands it down" {
  touch "$P/.nightshift/.ended"
  run watch --agent "bash $BIN/tick.sh" --max-wakes 3
  [ "$status" -eq 0 ]
  [ "$(calls)" -eq 0 ]
}

@test "a clean session end stands it down — the owner closed it on purpose" {
  echo 'clean session end (prompt_input_exit)' >"$P/.nightshift/.session-end"
  run watch --agent "bash $BIN/tick.sh" --max-wakes 3
  [ "$status" -eq 0 ]
  grep -q 'the owner closed it' "$P/.nightshift/shift-log.md"
  [ "$(calls)" -eq 0 ]
}

@test "a symlink session-end marker does not stand the watchman down" {
  echo 'plant' >"$P/.nightshift/session-end-plant"
  ln -s session-end-plant "$P/.nightshift/.session-end"
  run watch --agent "bash $BIN/tick.sh" --max-wakes 3
  [ "$status" -eq 0 ]
  [ "$(reason)" != "clean-session-end" ]
  if grep -q 'the owner closed it' "$P/.nightshift/shift-log.md"; then
    return 1
  fi
}

@test "a quiet site with open boxes is resumed, then clocked out" {
  run watch --agent "bash $BIN/tick.sh" --max-wakes 5
  [ "$status" -eq 0 ]
  if grep -qE '^- \[ \]' "$P/.nightshift/punch-list.md"; then
    return 1
  fi
  [ "$(calls)" -eq 2 ] # one resume that ticked the box, one clock-out spawn
  grep -q 'resume attempt 1' "$P/.nightshift/shift-log.md"
  grep -q 'never clocked out — spawning the clock-out' "$P/.nightshift/shift-log.md"
}

@test "a Claude revival receives the exact lease generation written before spawn" {
  cat >"$BIN/lease-env.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n%s\n' "$NIGHTSHIFT_LEASE_GENERATION" "$NIGHTSHIFT_LEASE_NONCE" >.nightshift/lease-env
# Generation and nonce are on the lease before the child starts. A noop exit is not a
# revival, so the live lease is restored (or dropped) after wait.
sed -n '3,4p' .nightshift/.shift-lease >.nightshift/lease-at-spawn
STUB
  chmod +x "$BIN/lease-env.sh"

  run watch --agent "bash $BIN/lease-env.sh" --max-wakes 1
  [ "$status" -eq 7 ]
  [ -n "$(sed -n 1p "$P/.nightshift/lease-env")" ]
  [ "$(sed -n 1p "$P/.nightshift/lease-env")" = "$(sed -n 1p "$P/.nightshift/lease-at-spawn")" ]
  [ "$(sed -n 2p "$P/.nightshift/lease-env")" = "$(sed -n 2p "$P/.nightshift/lease-at-spawn")" ]
}

@test "project-file churn alone is not life — a dead site is revived through it" {
  RDY="$BATS_TEST_TMPDIR/.churn-ready"
  ( touch "$P/beat"; : >"$RDY"; while :; do sleep 0.15; touch "$P/beat"; done ) &
  toucher=$!
  wait_writer "$RDY"
  run env NIGHTSHIFT_WATCH_SLEEP=1 NIGHTSHIFT_WATCH_RETRY="0 0" \
    "$WATCHMAN" --project "$P" --interval 20 --agent "bash $BIN/tick.sh" --max-wakes 4
  kill "$toucher" 2>/dev/null || true
  [ "$status" -eq 0 ]
  [ "$(calls)" -eq 2 ] # revived through the churn, then clocked out
}

@test "an API-down agent gets exactly 3 tries per wake, every wake" {
  run watch --agent "bash $BIN/fail.sh" --max-wakes 2
  [ "$status" -eq 7 ]
  [ "$(calls)" -eq 6 ]
  grep -q 'attempts failed' "$P/.nightshift/shift-log.md"
}

@test "all boxes ticked without .ended spawns exactly one clock-out" {
  printf '## Items\n- [x] **1.**\n' >"$P/.nightshift/punch-list.md"
  : >"$P/.nightshift/.shift-armed"
  run watch --agent "bash $BIN/tick.sh" --max-wakes 3
  [ "$status" -eq 0 ]
  [ "$(calls)" -eq 1 ]
  [ -f "$P/.nightshift/.ended" ]
  [ ! -L "$P/.nightshift/.ended" ]
  [ ! -f "$P/.nightshift/.shift-armed" ]
  [ ! -f "$P/.nightshift/.shift-lease" ]
}

@test "a failed terminal clock-out stands down after one attempt" {
  printf '## Items\n- [x] **1.**\n' >"$P/.nightshift/punch-list.md"
  printf 'shift-session\n/tmp/t.jsonl\n%s\n\nclaude\n' "$$" >"$P/.nightshift/.shift-session"
  run watch --agent "bash $BIN/fail.sh" --max-wakes 5
  [ "$status" -eq 0 ]
  [ "$(calls)" -eq 1 ]
  [ ! -f "$P/.nightshift/.ended" ]
  [ "$(sed -n 1p "$P/.nightshift/.watch-reason" | tr -d '[:space:]')" = "clock-out-failed" ]
  grep -qF 'clock-out attempt 1/1' "$P/.nightshift/shift-log.md"
  grep -q 'standing down' "$P/.nightshift/shift-log.md"
  [ -z "$(sed -n 4p "$P/.nightshift/.shift-lease")" ]
}

@test "default watchman config cannot loop a failed terminal clock-out" {
  printf '## Items\n- [x] **1.**\n' >"$P/.nightshift/punch-list.md"
  run env NIGHTSHIFT_WATCH_SLEEP=0 NIGHTSHIFT_WATCH_RETRY="0 0" \
    "$WATCHMAN" --project "$P" --interval 20 --agent "bash $BIN/fail.sh"
  [ "$status" -eq 0 ]
  [ "$(calls)" -eq 1 ]
  [ "$(sed -n 1p "$P/.nightshift/.watch-reason" | tr -d '[:space:]')" = "clock-out-failed" ]
}

@test "a failed terminal clock-out lets the recorded session operate again" {
  printf '## Items\n- [ ] **1.**\n' >"$P/.nightshift/punch-list.md"
  printf '%s' "$(( $(date +%s) - 60 ))" >"$P/.nightshift/deadline"
  : >"$P/.nightshift/.shift-armed"
  printf 'shift-session\n/tmp/t.jsonl\n%s\n\nclaude\n' "$$" >"$P/.nightshift/.shift-session"
  run watch --agent "bash $BIN/fail.sh" --max-wakes 5
  [ "$status" -eq 0 ]
  [ "$(calls)" -eq 1 ]
  [ -z "$(sed -n 4p "$P/.nightshift/.shift-lease")" ]
  run recorded_read "$P" shift-session
  is_allow
}

@test "failed clock-out with every box ticked cannot loop across wakes" {
  printf '## Items\n- [x] **1.**\n' >"$P/.nightshift/punch-list.md"
  : >"$P/.nightshift/.shift-armed"
  printf 'test-shift-session\n/tmp/t.jsonl\n%s\n\nclaude\n' "$$" >"$P/.nightshift/.shift-session"
  run env NIGHTSHIFT_WATCH_SLEEP=0 NIGHTSHIFT_WATCH_RETRY="0 0" \
    "$WATCHMAN" --project "$P" --interval 20 --agent "bash $BIN/fail.sh"
  [ "$status" -eq 0 ]
  [ "$(calls)" -eq 1 ]
  [ ! -f "$P/.nightshift/.ended" ]
  [ "$(sed -n 1p "$P/.nightshift/.watch-reason" | tr -d '[:space:]')" = "clock-out-failed" ]
  [ -z "$(sed -n 4p "$P/.nightshift/.shift-lease")" ]
  [ "$(sed -n 1p "$P/.nightshift/.shift-lease")" = "test-shift-session" ]
  run gate "$P"
  is_release
  [ -f "$P/.nightshift/.ended" ]
}

@test "quitting time with a dead site and a failed clock-out is bounded" {
  printf '%s' "$(( $(date +%s) - 60 ))" >"$P/.nightshift/deadline"
  run watch --agent "bash $BIN/fail.sh" --max-wakes 5
  [ "$status" -eq 0 ]
  [ "$(calls)" -eq 1 ]
  [ ! -f "$P/.nightshift/.ended" ]
  [ "$(sed -n 1p "$P/.nightshift/.watch-reason" | tr -d '[:space:]')" = "clock-out-failed" ]
}

@test "quitting time with a dead site spawns the clock-out and stands down" {
  printf '%s' "$(( $(date +%s) - 60 ))" >"$P/.nightshift/deadline"
  run watch --agent "bash $BIN/tick.sh" --max-wakes 3
  [ "$status" -eq 0 ]
  [ "$(calls)" -eq 1 ]
  grep -q 'quitting time passed' "$P/.nightshift/shift-log.md"
}

@test "an option with no value exits instead of spinning" {
  run "$WATCHMAN" --interval
  [ "$status" -eq 1 ]
  printf '%s' "$output" | grep -q -- '--interval needs a value'
}

@test "Windows session-end marker matches POSIX wording" {
  grep -qF ' · clean session end' "$BATS_TEST_DIRNAME/../plugins/nightshift/hooks/session-end.sh"
  # The same separator, spelled by its code so the script stays ASCII.
  grep -qF "'{0} {3} clean session end ({1}){2}'" "$BATS_TEST_DIRNAME/../plugins/nightshift/hooks/windows/session-end.ps1"
  grep -qF '$reason, [Environment]::NewLine, [char]0x00B7' "$BATS_TEST_DIRNAME/../plugins/nightshift/hooks/windows/session-end.ps1"
  if grep -qF ' - clean session end' "$BATS_TEST_DIRNAME/../plugins/nightshift/hooks/windows/session-end.ps1"; then
    return 1
  fi
  grep -qF '[ -L "$SESSION_END" ]' "$BATS_TEST_DIRNAME/../plugins/nightshift/hooks/session-end.sh"
  grep -qF 'Test-NSReparsePoint $sessionEnd' "$BATS_TEST_DIRNAME/../plugins/nightshift/hooks/windows/session-end.ps1"
  grep -qF '[ ! -L "$SESSION" ]' "$BATS_TEST_DIRNAME/../plugins/nightshift/hooks/session-end.sh"
}

@test "session-end hook writes the marker only during an active shift" {
  p="$(new_project)"
  punch_open "$p"
  printf '{"reason":"prompt_input_exit"}' | CLAUDE_PROJECT_DIR="$p" bash "$SESSION_END"
  grep -q 'clean session end (prompt_input_exit)' "$p/.nightshift/.session-end"
}

@test "session-end writes the marker only for an owner reason" {
  p="$(new_project)"
  punch_open "$p"
  for reason in prompt_input_exit logout clear resume; do
    rm -f "$p/.nightshift/.session-end"
    printf '{"reason":"%s"}' "$reason" | CLAUDE_PROJECT_DIR="$p" bash "$SESSION_END"
    grep -q "clean session end ($reason)" "$p/.nightshift/.session-end"
  done
  for reason in other unknown exit bypass_permissions_disabled; do
    rm -f "$p/.nightshift/.session-end"
    printf '{"reason":"%s"}' "$reason" | CLAUDE_PROJECT_DIR="$p" bash "$SESSION_END"
    [ ! -f "$p/.nightshift/.session-end" ]
  done
  rm -f "$p/.nightshift/.session-end"
  printf '{"session_id":"no-reason"}' | CLAUDE_PROJECT_DIR="$p" bash "$SESSION_END"
  [ ! -f "$p/.nightshift/.session-end" ]
}

@test "an other session end leaves a dead shift to be revived" {
  printf '{"reason":"other"}' | CLAUDE_PROJECT_DIR="$P" bash "$SESSION_END"
  [ ! -f "$P/.nightshift/.session-end" ]
  run watch --agent "bash $BIN/tick.sh" --max-wakes 3
  [ "$status" -eq 0 ]
  [ "$(calls)" -ge 1 ]
  if grep -q 'the owner closed it' "$P/.nightshift/shift-log.md"; then
    return 1
  fi
}

@test "session-end hook replaces a symlink marker with a regular file" {
  p="$(new_project)"
  punch_open "$p"
  printf 'plant\n' >"$p/.nightshift/session-end-plant"
  ln -s session-end-plant "$p/.nightshift/.session-end"
  printf '{"reason":"prompt_input_exit"}' | CLAUDE_PROJECT_DIR="$p" bash "$SESSION_END"
  [ -f "$p/.nightshift/.session-end" ]
  [ ! -L "$p/.nightshift/.session-end" ]
  grep -q 'clean session end (prompt_input_exit)' "$p/.nightshift/.session-end"
}

@test "session-end hook is inert while the shift is unarmed" {
  p="$(new_project)"
  punch_open "$p"
  rm "$p/.nightshift/.shift-armed"
  printf '{"reason":"prompt_input_exit"}' | CLAUDE_PROJECT_DIR="$p" bash "$SESSION_END"
  [ ! -f "$p/.nightshift/.session-end" ]
}

@test "session-end ignores an open checkbox outside the Items list" {
  p="$(new_project)"
  touch "$p/.nightshift/.shift-armed"
  printf '%s\n' '- [ ] planning example' '## Items' '- [x] **1. done.**' >"$p/.nightshift/punch-list.md"
  printf '{"reason":"prompt_input_exit"}' | CLAUDE_PROJECT_DIR="$p" bash "$SESSION_END"
  [ ! -f "$p/.nightshift/.session-end" ]
}

@test "session-end hook is inert when the shift is done or absent" {
  p="$(new_project)"
  punch_done "$p"
  printf '{"reason":"prompt_input_exit"}' | CLAUDE_PROJECT_DIR="$p" bash "$SESSION_END"
  [ ! -f "$p/.nightshift/.session-end" ]
  q="$(new_project other)"
  printf '{"reason":"prompt_input_exit"}' | CLAUDE_PROJECT_DIR="$q" bash "$SESSION_END"
  [ ! -f "$q/.nightshift/.session-end" ]
}

@test "the default agent continues the conversation, with a fresh-session final fallback" {
  # A fake `claude` on PATH: --continue always fails (a broken transcript), plain -p succeeds
  # and ticks the box — proving the last retry saves the night when the transcript cannot.
  cat >"$BIN/claude" <<'STUB'
#!/usr/bin/env bash
if printf '%s' "$*" | grep -q '^agents'; then echo "[]"; exit 0; fi
if ! grep -qE '^- \[ \]' .nightshift/punch-list.md; then
  if printf '%s' "$*" | grep -q -- '--continue'; then echo continue >>.nightshift/agent-calls
  else echo fresh >>.nightshift/agent-calls
  fi
  : >.nightshift/.ended
  rm -f .nightshift/.shift-armed .nightshift/.shift-lease
  exit 0
fi
if printf '%s' "$*" | grep -q -- '--continue'; then
  echo continue >>.nightshift/agent-calls
  exit 1
fi
echo fresh >>.nightshift/agent-calls
awk 'BEGIN{d=0} !d && /^- \[ \]/{sub(/\[ \]/,"[x]");d=1} {print}' .nightshift/punch-list.md >.nightshift/pl.tmp
mv .nightshift/pl.tmp .nightshift/punch-list.md
STUB
  chmod +x "$BIN/claude"
  run env PATH="$BIN:$PATH" NIGHTSHIFT_WATCH_SLEEP=0 NIGHTSHIFT_WATCH_RETRY="0 0" \
    "$WATCHMAN" --project "$P" --interval 20 --max-wakes 4
  [ "$status" -eq 0 ]
  if grep -qE '^- \[ \]' "$P/.nightshift/punch-list.md"; then
    return 1
  fi
  [ "$(grep -c continue "$P/.nightshift/agent-calls")" -eq 3 ] # 2 wake retries + the clock-out
  [ "$(grep -c fresh "$P/.nightshift/agent-calls")" -eq 1 ]    # the fallback that revived it
  grep -q 'fresh-session fallback' "$P/.nightshift/shift-log.md"
}

# Esc means stop, platform-wide. Claude Code writes "Request interrupted by user" into the
# session transcript; a 500 or a crash never does. That marker in the tail is how the watchman
# tells an owner's pause from a dead site.
@test "an Esc-paused session is stood by, never resumed" {
  T="$BATS_TEST_TMPDIR/transcripts"
  mkdir -p "$T"
  printf '{"type":"message","content":"working"}\n{"type":"user","content":"[Request interrupted by user]"}\n' >"$T/session.jsonl"
  run env NIGHTSHIFT_WATCH_SLEEP=0 NIGHTSHIFT_WATCH_RETRY="0 0" NIGHTSHIFT_WATCH_TRANSCRIPTS="$T" \
    "$WATCHMAN" --project "$P" --interval 20 --agent "bash $BIN/tick.sh" --max-wakes 3
  [ "$status" -eq 7 ]
  [ "$(calls)" -eq 0 ]
  grep -q 'owner pressed Esc — standing by' "$P/.nightshift/shift-log.md"
  [ "$(grep -c 'standing by' "$P/.nightshift/shift-log.md")" -eq 1 ] # logged once, not every wake
}

@test "a transcript without an interrupt in its tail is revived" {
  T="$BATS_TEST_TMPDIR/transcripts"
  mkdir -p "$T"
  printf '{"type":"user","content":"[Request interrupted by user]"}\n' >"$T/session.jsonl"
  for i in $(seq 1 30); do printf '{"type":"assistant","content":"work %s"}\n' "$i" >>"$T/session.jsonl"; done
  run env NIGHTSHIFT_WATCH_SLEEP=0 NIGHTSHIFT_WATCH_RETRY="0 0" NIGHTSHIFT_WATCH_TRANSCRIPTS="$T" \
    "$WATCHMAN" --project "$P" --interval 20 --agent "bash $BIN/tick.sh" --max-wakes 5
  [ "$status" -eq 0 ]
  if grep -qE '^- \[ \]' "$P/.nightshift/punch-list.md"; then
    return 1
  fi
  [ "$(calls)" -eq 2 ]
}

# The Esc tell reads the SHIFT'S recorded transcript — a second tab's interrupt proves nothing.
@test "the shift's own transcript decides Esc, not the newest in the project" {
  T="$BATS_TEST_TMPDIR/transcripts"
  mkdir -p "$T"
  printf '{"type":"user","content":"[Request interrupted by user]"}\n' >"$T/shift.jsonl"
  sleep 0.01
  printf '{"type":"message","content":"other tab, still working"}\n' >"$T/other.jsonl" # newer, clean
  printf 'sid-shift\n%s\n' "$T/shift.jsonl" >"$P/.nightshift/.shift-session"
  run env NIGHTSHIFT_WATCH_SLEEP=0 NIGHTSHIFT_WATCH_RETRY="0 0" NIGHTSHIFT_WATCH_TRANSCRIPTS="$T" \
    "$WATCHMAN" --project "$P" --interval 20 --agent "bash $BIN/tick.sh" --max-wakes 3
  [ "$status" -eq 7 ]
  [ "$(calls)" -eq 0 ]
  grep -q 'standing by' "$P/.nightshift/shift-log.md"
}

@test "another tab's Esc does not block the revival of a dead shift session" {
  T="$BATS_TEST_TMPDIR/transcripts"
  mkdir -p "$T"
  printf '{"type":"message","content":"working"}\n' >"$T/shift.jsonl"
  sleep 0.01
  printf '{"type":"user","content":"[Request interrupted by user]"}\n' >"$T/other.jsonl" # newer!
  printf 'sid-shift\n%s\n' "$T/shift.jsonl" >"$P/.nightshift/.shift-session"
  run env NIGHTSHIFT_WATCH_SLEEP=0 NIGHTSHIFT_WATCH_RETRY="0 0" NIGHTSHIFT_WATCH_TRANSCRIPTS="$T" \
    "$WATCHMAN" --project "$P" --interval 20 --agent "bash $BIN/tick.sh" --max-wakes 5
  [ "$status" -eq 0 ]
  if grep -qE '^- \[ \]' "$P/.nightshift/punch-list.md"; then
    return 1
  fi
}

# The default revival is the shift's exact conversation, by id — with the layered fallback.
@test "the default agent resumes the recorded session by id" {
  printf 'abc-123\n\n' >"$P/.nightshift/.shift-session"
  cat >"$BIN/claude" <<'STUB'
#!/usr/bin/env bash
if ! grep -qE '^- \[ \]' .nightshift/punch-list.md && [[ "$*" != agents* ]]; then
  case "$*" in
    *--resume*) echo "resume:$1 $2" >>.nightshift/agent-calls ;;
    *--continue*) echo continue >>.nightshift/agent-calls ;;
    *) echo fresh >>.nightshift/agent-calls ;;
  esac
  : >.nightshift/.ended
  rm -f .nightshift/.shift-armed .nightshift/.shift-lease
  exit 0
fi
case "$*" in
  agents*) echo "[]" ;;
  *--resume*) echo "resume:$1 $2" >>.nightshift/agent-calls; exit 1 ;;
  *--continue*) echo "continue" >>.nightshift/agent-calls; exit 1 ;;
  *) echo fresh >>.nightshift/agent-calls
     awk 'BEGIN{d=0} !d && /^- \[ \]/{sub(/\[ \]/,"[x]");d=1} {print}' .nightshift/punch-list.md >.nightshift/pl.tmp
     mv .nightshift/pl.tmp .nightshift/punch-list.md ;;
esac
STUB
  chmod +x "$BIN/claude"
  run env PATH="$BIN:$PATH" NIGHTSHIFT_WATCH_SLEEP=0 NIGHTSHIFT_WATCH_RETRY="0 0" \
    NIGHTSHIFT_WATCH_TRANSCRIPTS=/tmp/nowhere \
    "$WATCHMAN" --project "$P" --interval 20 --max-wakes 4
  [ "$status" -eq 0 ]
  grep -q 'resume:--resume abc-123' "$P/.nightshift/agent-calls"
  [ "$(grep -c fresh "$P/.nightshift/agent-calls")" -eq 1 ]
}

@test "session-end writes the marker only for the shift's own session" {
  p="$(new_project)"
  punch_open "$p"
  printf 'right-id\n\n' >"$p/.nightshift/.shift-session"
  printf '{"reason":"prompt_input_exit","session_id":"wrong-id"}' | CLAUDE_PROJECT_DIR="$p" bash "$SESSION_END"
  [ ! -f "$p/.nightshift/.session-end" ]
  printf '{"reason":"prompt_input_exit","session_id":"right-id"}' | CLAUDE_PROJECT_DIR="$p" bash "$SESSION_END"
  grep -q 'clean session end (prompt_input_exit)' "$p/.nightshift/.session-end"
}

# ---- v0.5.2: the liveness ladder — strong positive evidence of death, or stand by ----

# Primary pulse: a session streams every turn into its transcript even when the work writes no
# project files. Transcript movement alone means alive.
@test "transcript activity alone keeps the watchman standing by" {
  T="$BATS_TEST_TMPDIR/transcripts"
  mkdir -p "$T"
  printf '{"type":"message","content":"working"}\n' >"$T/shift.jsonl"
  printf 'sid-shift\n%s\n' "$T/shift.jsonl" >"$P/.nightshift/.shift-session"
  RDY="$BATS_TEST_TMPDIR/.pulse-ready"
  ( printf '{"type":"message","content":"x"}\n' >>"$T/shift.jsonl"; : >"$RDY"
    while :; do sleep 0.15; printf '{"type":"message","content":"x"}\n' >>"$T/shift.jsonl"; done ) &
  toucher=$!
  wait_writer "$RDY"
  # SLEEP=2, not 1: the pulse is `transcript -nt sentinel`, and -nt compares whole seconds. At a
  # one-second wake the appends and the sentinel share a second often enough to read a streaming
  # session as dead — a flake in the test, at a cadence the shipped ten-minute interval never sees.
  run env NIGHTSHIFT_WATCH_SLEEP=2 NIGHTSHIFT_WATCH_RETRY="0 0" NIGHTSHIFT_WATCH_TRANSCRIPTS="$T" \
    "$WATCHMAN" --project "$P" --interval 20 --agent "bash $BIN/tick.sh" --max-wakes 2
  kill "$toucher" 2>/dev/null || true
  [ "$status" -eq 7 ]
  [ "$(calls)" -eq 0 ]
}

@test "a helper transcript's activity is not the shift's pulse" {
  T="$BATS_TEST_TMPDIR/transcripts"
  mkdir -p "$T"
  printf '{"type":"message","content":"working"}\n' >"$T/shift.jsonl"
  printf 'sid-shift\n%s\n' "$T/shift.jsonl" >"$P/.nightshift/.shift-session"
  RDY="$BATS_TEST_TMPDIR/.other-ready"
  ( printf '{"type":"message","content":"other"}\n' >>"$T/other.jsonl"; : >"$RDY"
    while :; do sleep 0.15; printf '{"type":"message","content":"other"}\n' >>"$T/other.jsonl"; done ) &
  toucher=$!
  wait_writer "$RDY"
  run env NIGHTSHIFT_WATCH_SLEEP=1 NIGHTSHIFT_WATCH_RETRY="0 0" NIGHTSHIFT_WATCH_TRANSCRIPTS="$T" \
    "$WATCHMAN" --project "$P" --interval 20 --agent "bash $BIN/tick.sh" --max-wakes 4
  kill "$toucher" 2>/dev/null || true
  [ "$status" -eq 0 ]
  [ "$(calls)" -eq 2 ] # revived despite the helper's noise, then clocked out
}

@test "a fresh shift-pulse keeps a quiet live tab standing by" {
  printf '%s sid-shift\n' "$(date +%s)" >"$P/.nightshift/.shift-pulse"
  printf 'sid-shift\n/tmp/t.jsonl\n99999\nnever\nclaude\n' >"$P/.nightshift/.shift-session"
  run watch --agent "bash $BIN/tick.sh" --max-wakes 2
  [ "$status" -eq 7 ]
  [ "$(calls)" -eq 0 ]
}

@test "a helper session id does not write the shift-pulse" {
  : >"$P/.nightshift/.shift-armed"
  printf 'sid-shift\n\n\n\nclaude\n' >"$P/.nightshift/.shift-session"
  jq -nc '{session_id:"helper-id"}' | CLAUDE_PROJECT_DIR="$P" bash "$HOOKS/pulse.sh"
  [ ! -f "$P/.nightshift/.shift-pulse" ]
  jq -nc '{session_id:"sid-shift"}' | CLAUDE_PROJECT_DIR="$P" bash "$HOOKS/pulse.sh"
  grep -qE '^[0-9]+ sid-shift$' "$P/.nightshift/.shift-pulse"
}

# The process witness: the recorded pid alive with a quiet, unerrored transcript is long silent
# work — a 25-minute test run writes nothing anywhere. Never spawn beside it.
@test "the shift's own live process holds the watchman through a silent stretch" {
  start="$(ps -o lstart= -p $$ | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  printf 'sid-shift\n\n%s\n%s\n' "$$" "$start" >"$P/.nightshift/.shift-session"
  run env NIGHTSHIFT_WATCH_SLEEP=0 NIGHTSHIFT_WATCH_RETRY="0 0" NIGHTSHIFT_WATCH_TRANSCRIPTS=/tmp/nowhere \
    "$WATCHMAN" --project "$P" --interval 20 --agent "bash $BIN/tick.sh" --max-wakes 3
  [ "$status" -eq 7 ]
  [ "$(calls)" -eq 0 ]
  grep -q 'long silent work; standing by' "$P/.nightshift/shift-log.md"
  [ "$(grep -c 'standing by' "$P/.nightshift/shift-log.md")" -eq 1 ] # logged once, not every wake
}

# The wedge: process alive, transcript quiet, and the host's own API-error event — flagged
# "isApiErrorMessage":true, as Claude Code writes it — as the transcript's last word. A session
# sitting at an errored prompt with nobody there. This one is revived.
@test "a live shift process at an errored prompt is the wedge — revived" {
  T="$BATS_TEST_TMPDIR/transcripts"
  mkdir -p "$T"
  printf '%s\n%s\n' \
    '{"type":"assistant","message":{"content":[{"type":"text","text":"working"}]}}' \
    '{"type":"assistant","message":{"model":"<synthetic>","content":[{"type":"text","text":"API Error: 500 Internal server error"}]},"error":"server_error","isApiErrorMessage":true,"apiErrorStatus":500}' \
    >"$T/shift.jsonl"
  start="$(ps -o lstart= -p $$ | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  printf 'sid-shift\n%s\n%s\n%s\n' "$T/shift.jsonl" "$$" "$start" >"$P/.nightshift/.shift-session"
  run env NIGHTSHIFT_WATCH_SLEEP=0 NIGHTSHIFT_WATCH_RETRY="0 0" NIGHTSHIFT_WATCH_TRANSCRIPTS="$T" \
    "$WATCHMAN" --project "$P" --interval 20 --agent "bash $BIN/tick.sh" --max-wakes 4
  [ "$status" -eq 0 ]
  [ "$(calls)" -eq 2 ]
  grep -q 'probable wedge' "$P/.nightshift/shift-log.md"
  grep -q 'claude --resume sid-shift' "$P/.nightshift/shift-log.md" # the morning deep link
}

# A 500 can land before the first tool call records the shift's identity: no pid on file, the
# wedged claude process alive in the project, and the newest conversation ending in the host's
# own error event. Still the wedge — --continue resumes that very conversation. Without the
# tell, this session would out-wait the night as "a live claude session in the project".
@test "a 500 before any recorded identity is still the wedge — revived" {
  T="$BATS_TEST_TMPDIR/transcripts"
  mkdir -p "$T"
  printf '{"type":"assistant","message":{"model":"<synthetic>","content":[{"type":"text","text":"API Error: 500 Internal server error"}]},"error":"server_error","isApiErrorMessage":true,"apiErrorStatus":500}\n' >"$T/shift.jsonl"
  cat >"$BIN/pgrep" <<'STUB'
#!/usr/bin/env bash
echo 999999
STUB
  cat >"$BIN/ps" <<'STUB'
#!/usr/bin/env bash
echo "/fake/bin/claude"
STUB
  cat >"$BIN/lsof" <<STUB
#!/usr/bin/env bash
echo "p999999"
echo "n$P"
STUB
  chmod +x "$BIN/pgrep" "$BIN/ps" "$BIN/lsof"
  run env PATH="$BIN:$PATH" NIGHTSHIFT_WATCH_SLEEP=0 NIGHTSHIFT_WATCH_RETRY="0 0" \
    NIGHTSHIFT_WATCH_TRANSCRIPTS="$T" \
    "$WATCHMAN" --project "$P" --interval 20 --agent "bash $BIN/tick.sh" --max-wakes 4
  [ "$status" -eq 0 ]
  [ "$(calls)" -eq 2 ]
  grep -q 'probable wedge' "$P/.nightshift/shift-log.md"
}

# A session merely TALKING about API errors is not the wedge — prose quoting the flag arrives
# with its quotes escaped, and a user message carries no isApiErrorMessage field at all.
@test "prose mentioning API errors does not read as the wedge" {
  T="$BATS_TEST_TMPDIR/transcripts"
  mkdir -p "$T"
  printf '{"type":"user","message":{"role":"user","content":"the host flags failures with \\"isApiErrorMessage\\":true — handle the \\"API Error: 500\\" case"}}\n' >"$T/shift.jsonl"
  start="$(ps -o lstart= -p $$ | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  printf 'sid-shift\n%s\n%s\n%s\n' "$T/shift.jsonl" "$$" "$start" >"$P/.nightshift/.shift-session"
  run env NIGHTSHIFT_WATCH_SLEEP=0 NIGHTSHIFT_WATCH_RETRY="0 0" NIGHTSHIFT_WATCH_TRANSCRIPTS="$T" \
    "$WATCHMAN" --project "$P" --interval 20 --agent "bash $BIN/tick.sh" --max-wakes 2
  [ "$status" -eq 7 ]
  [ "$(calls)" -eq 0 ]
  grep -q 'long silent work; standing by' "$P/.nightshift/shift-log.md"
}

# An owner pasting last night's error report as a prompt is a session with its owner AT the
# keyboard — the pasted text is a user message, not the host's flagged event. Never the wedge.
@test "an owner-pasted error report is not the wedge" {
  T="$BATS_TEST_TMPDIR/transcripts"
  mkdir -p "$T"
  printf '{"type":"user","message":{"role":"user","content":"API Error: 500 Internal server error — this killed the run last night, investigate"}}\n' >"$T/shift.jsonl"
  start="$(ps -o lstart= -p $$ | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  printf 'sid-shift\n%s\n%s\n%s\n' "$T/shift.jsonl" "$$" "$start" >"$P/.nightshift/.shift-session"
  run env NIGHTSHIFT_WATCH_SLEEP=0 NIGHTSHIFT_WATCH_RETRY="0 0" NIGHTSHIFT_WATCH_TRANSCRIPTS="$T" \
    "$WATCHMAN" --project "$P" --interval 20 --agent "bash $BIN/tick.sh" --max-wakes 2
  [ "$status" -eq 7 ]
  [ "$(calls)" -eq 0 ]
  grep -q 'long silent work; standing by' "$P/.nightshift/shift-log.md"
}

# A recovered error is history, not a wedge: retry succeeded, work continued, then a long
# silent stretch — the error is still inside the tail window but no longer the last word.
# Spawning here would put a second writer beside a living session, the exact failure the
# ladder exists to prevent.
@test "an error the session already recovered from is not the wedge" {
  T="$BATS_TEST_TMPDIR/transcripts"
  mkdir -p "$T"
  printf '%s\n%s\n' \
    '{"type":"assistant","message":{"model":"<synthetic>","content":[{"type":"text","text":"API Error: 500 Internal server error"}]},"error":"server_error","isApiErrorMessage":true,"apiErrorStatus":500}' \
    '{"type":"assistant","message":{"content":[{"type":"text","text":"back on it — running the suite"}]}}' \
    >"$T/shift.jsonl"
  start="$(ps -o lstart= -p $$ | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  printf 'sid-shift\n%s\n%s\n%s\n' "$T/shift.jsonl" "$$" "$start" >"$P/.nightshift/.shift-session"
  run env NIGHTSHIFT_WATCH_SLEEP=0 NIGHTSHIFT_WATCH_RETRY="0 0" NIGHTSHIFT_WATCH_TRANSCRIPTS="$T" \
    "$WATCHMAN" --project "$P" --interval 20 --agent "bash $BIN/tick.sh" --max-wakes 2
  [ "$status" -eq 7 ]
  [ "$(calls)" -eq 0 ]
  grep -q 'long silent work; standing by' "$P/.nightshift/shift-log.md"
}

@test "a dead recorded pid is strong evidence — revived" {
  bash -c ':' &
  deadpid=$!
  wait "$deadpid" 2>/dev/null || true
  printf 'sid-shift\n\n%s\n\n' "$deadpid" >"$P/.nightshift/.shift-session"
  run env NIGHTSHIFT_WATCH_SLEEP=0 NIGHTSHIFT_WATCH_RETRY="0 0" NIGHTSHIFT_WATCH_TRANSCRIPTS=/tmp/nowhere \
    "$WATCHMAN" --project "$P" --interval 20 --agent "bash $BIN/tick.sh" --max-wakes 4
  [ "$status" -eq 0 ]
  [ "$(calls)" -eq 2 ]
}

# A pid wears the number but not the birthday: a mismatched start time means the shift's
# process is gone and something else inherited its pid.
@test "a reused pid is not the shift's process — revived" {
  printf 'sid-shift\n\n%s\n%s\n' "$$" "Thu Jan  1 00:00:00 1970" >"$P/.nightshift/.shift-session"
  run env NIGHTSHIFT_WATCH_SLEEP=0 NIGHTSHIFT_WATCH_RETRY="0 0" NIGHTSHIFT_WATCH_TRANSCRIPTS=/tmp/nowhere \
    "$WATCHMAN" --project "$P" --interval 20 --agent "bash $BIN/tick.sh" --max-wakes 4
  [ "$status" -eq 0 ]
  [ "$(calls)" -eq 2 ]
}

# No pid recorded: any claude process working in this project is reason enough not to spawn.
# Not identity — just the conservative reading of an uncertain site.
@test "with no recorded pid, a claude process in the project stands the watchman by" {
  cat >"$BIN/pgrep" <<'STUB'
#!/usr/bin/env bash
echo 999999
STUB
  cat >"$BIN/ps" <<'STUB'
#!/usr/bin/env bash
echo "/fake/bin/claude"
STUB
  cat >"$BIN/lsof" <<STUB
#!/usr/bin/env bash
echo "p999999"
echo "n$P"
STUB
  chmod +x "$BIN/pgrep" "$BIN/ps" "$BIN/lsof"
  run env PATH="$BIN:$PATH" NIGHTSHIFT_WATCH_SLEEP=0 NIGHTSHIFT_WATCH_RETRY="0 0" \
    NIGHTSHIFT_WATCH_TRANSCRIPTS=/tmp/nowhere \
    "$WATCHMAN" --project "$P" --interval 20 --agent "bash $BIN/tick.sh" --max-wakes 3
  [ "$status" -eq 7 ]
  [ "$(calls)" -eq 0 ]
  grep -q 'a claude session is live in this project — standing by' "$P/.nightshift/shift-log.md"
}

# ---- v0.5.2: pre-spawn re-checks and the recorded retry baseline ----

@test "session activity during the retry sleep cancels the remaining attempts" {
  T="$BATS_TEST_TMPDIR/transcripts"
  mkdir -p "$T"
  printf '{"type":"message","content":"working"}\n' >"$T/shift.jsonl"
  printf 'sid-shift\n%s\n' "$T/shift.jsonl" >"$P/.nightshift/.shift-session"
  cat >"$BIN/claude" <<'STUB'
#!/usr/bin/env bash
case "$*" in agents*) echo "[]" ;; esac
STUB
  chmod +x "$BIN/claude"
  # Quiet for the first wake, then the session streams again — like a real session coming back.
  # The flag is set before the quiet period, not after: waiting on the stream would remove the
  # silence this test is about, but the subshell still has to be scheduled before the watchman runs.
  RDY="$BATS_TEST_TMPDIR/.back-ready"
  ( : >"$RDY"; sleep 1
    while :; do printf '{"type":"message","content":"back"}\n' >>"$T/shift.jsonl"; sleep 0.3; done ) &
  appender=$!
  wait_writer "$RDY"
  run env PATH="$BIN:$PATH" NIGHTSHIFT_WATCH_SLEEP=0 NIGHTSHIFT_WATCH_RETRY="2" NIGHTSHIFT_WATCH_TRANSCRIPTS="$T" \
    "$WATCHMAN" --project "$P" --interval 20 --agent "bash $BIN/fail.sh" --max-wakes 1
  kill "$appender" 2>/dev/null || true
  [ "$status" -eq 7 ]
  [ "$(calls)" -eq 1 ]
  grep -q 'session activity during retries — holding the remaining attempts' "$P/.nightshift/shift-log.md"
}

# A failed resume may append its own API-error event to the shift transcript. Re-baselining
# after each attempt keeps the watchman from mistaking its own noise for site life.
@test "the watchman's own failed attempt cannot fool the retry check" {
  T="$BATS_TEST_TMPDIR/transcripts"
  mkdir -p "$T"
  printf '{"type":"message","content":"working"}\n' >"$T/shift.jsonl"
  printf 'sid-shift\n%s\n' "$T/shift.jsonl" >"$P/.nightshift/.shift-session"
  cat >"$BIN/fail-noisy.sh" <<STUB
#!/usr/bin/env bash
echo called >>.nightshift/agent-calls
printf '{"type":"assistant","message":{"model":"<synthetic>","content":[{"type":"text","text":"API Error: 500"}]},"error":"server_error","isApiErrorMessage":true,"apiErrorStatus":500}\n' >>"$T/shift.jsonl"
exit 1
STUB
  chmod +x "$BIN/fail-noisy.sh"
  run env NIGHTSHIFT_WATCH_SLEEP=0 NIGHTSHIFT_WATCH_RETRY="0 0" NIGHTSHIFT_WATCH_TRANSCRIPTS="$T" \
    "$WATCHMAN" --project "$P" --interval 20 --agent "bash $BIN/fail-noisy.sh" --max-wakes 1
  [ "$status" -eq 7 ]
  [ "$(calls)" -eq 3 ] # all three attempts ran; none was fooled by the previous one's writes
  if grep -q 'during retries' "$P/.nightshift/shift-log.md"; then
    return 1
  fi
}

# ---- v0.5.2: the revival chain — recorded conversation, --continue, fresh session ----

@test "a failed resume degrades to --continue before the fresh session" {
  printf 'abc-123\n\n\n\n' >"$P/.nightshift/.shift-session"
  cat >"$BIN/claude" <<'STUB'
#!/usr/bin/env bash
if ! grep -qE '^- \[ \]' .nightshift/punch-list.md && [[ "$*" != agents* ]]; then
  case "$*" in
    *--resume*) echo resume >>.nightshift/agent-calls ;;
    *--continue*) echo continue >>.nightshift/agent-calls ;;
    *) echo fresh >>.nightshift/agent-calls ;;
  esac
  : >.nightshift/.ended
  rm -f .nightshift/.shift-armed .nightshift/.shift-lease
  exit 0
fi
case "$*" in
  agents*) echo "[]" ;;
  *--resume*) echo resume >>.nightshift/agent-calls; exit 1 ;;
  *--continue*) echo continue >>.nightshift/agent-calls; exit 1 ;;
  *) echo fresh >>.nightshift/agent-calls
     awk 'BEGIN{d=0} !d && /^- \[ \]/{sub(/\[ \]/,"[x]");d=1} {print}' .nightshift/punch-list.md >.nightshift/pl.tmp
     mv .nightshift/pl.tmp .nightshift/punch-list.md ;;
esac
STUB
  chmod +x "$BIN/claude"
  run env PATH="$BIN:$PATH" NIGHTSHIFT_WATCH_SLEEP=0 NIGHTSHIFT_WATCH_RETRY="0 0" \
    NIGHTSHIFT_WATCH_TRANSCRIPTS=/tmp/nowhere \
    "$WATCHMAN" --project "$P" --interval 20 --max-wakes 4
  [ "$status" -eq 0 ]
  [ "$(sed -n 1p "$P/.nightshift/agent-calls")" = "resume" ]
  [ "$(sed -n 2p "$P/.nightshift/agent-calls")" = "continue" ]
  [ "$(sed -n 3p "$P/.nightshift/agent-calls")" = "fresh" ]
  grep -q 'resuming the recorded conversation' "$P/.nightshift/shift-log.md"
  grep -q -- '--continue fallback' "$P/.nightshift/shift-log.md"
  grep -q 'fresh-session fallback' "$P/.nightshift/shift-log.md"
}

@test "a successful resume never falls to --continue or a fresh session" {
  printf 'abc-123\n\n\n\n' >"$P/.nightshift/.shift-session"
  cat >"$BIN/claude" <<'STUB'
#!/usr/bin/env bash
if ! grep -qE '^- \[ \]' .nightshift/punch-list.md && [[ "$*" != agents* ]]; then
  case "$*" in
    *--resume*) echo resume >>.nightshift/agent-calls ;;
    *--continue*) echo continue >>.nightshift/agent-calls ;;
    *) echo fresh >>.nightshift/agent-calls ;;
  esac
  : >.nightshift/.ended
  rm -f .nightshift/.shift-armed .nightshift/.shift-lease
  exit 0
fi
case "$*" in
  agents*) echo "[]" ;;
  *--resume*) echo resume >>.nightshift/agent-calls
     awk 'BEGIN{d=0} !d && /^- \[ \]/{sub(/\[ \]/,"[x]");d=1} {print}' .nightshift/punch-list.md >.nightshift/pl.tmp
     mv .nightshift/pl.tmp .nightshift/punch-list.md ;;
  *--continue*) echo continue >>.nightshift/agent-calls ;;
  *) echo fresh >>.nightshift/agent-calls ;;
esac
STUB
  chmod +x "$BIN/claude"
  run env PATH="$BIN:$PATH" NIGHTSHIFT_WATCH_SLEEP=0 NIGHTSHIFT_WATCH_RETRY="0 0" \
    NIGHTSHIFT_WATCH_TRANSCRIPTS=/tmp/nowhere \
    "$WATCHMAN" --project "$P" --interval 20 --max-wakes 4
  [ "$status" -eq 0 ]
  if grep -q continue "$P/.nightshift/agent-calls"; then
    return 1
  fi
  if grep -q fresh "$P/.nightshift/agent-calls"; then
    return 1
  fi
  [ "$(grep -c resume "$P/.nightshift/agent-calls")" -eq 2 ] # the revival and the clock-out
}

# A watchman-spawned revival is marked; its own exit is never the owner's hand on the door.
@test "a marked revival session's exit never writes the clean-end marker" {
  p="$(new_project)"
  punch_open "$p"
  printf 'right-id\n\n\n\n' >"$p/.nightshift/.shift-session"
  printf '{"reason":"prompt_input_exit","session_id":"right-id"}' |
    NIGHTSHIFT_REVIVAL=1 CLAUDE_PROJECT_DIR="$p" bash "$SESSION_END"
  [ ! -f "$p/.nightshift/.session-end" ]
}

# ---- session-first: folder noise never mutes the owner or masks a death ----

# The bug the dogfood caught: a detached loop writing project files muted the Esc
# acknowledgment forever. The owner's signal is read FIRST now.
@test "Esc is acknowledged even while project files churn" {
  T="$BATS_TEST_TMPDIR/transcripts"
  mkdir -p "$T"
  printf '{"type":"message","content":"working"}\n{"type":"user","content":"[Request interrupted by user]"}\n' >"$T/shift.jsonl"
  start="$(ps -o lstart= -p $$ | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  printf 'sid-shift\n%s\n%s\n%s\n' "$T/shift.jsonl" "$$" "$start" >"$P/.nightshift/.shift-session"
  RDY="$BATS_TEST_TMPDIR/.detached-live-ready"
  ( touch "$P/detached-writer"; : >"$RDY"; while :; do sleep 0.15; touch "$P/detached-writer"; done ) &
  toucher=$!
  wait_writer "$RDY"
  run env NIGHTSHIFT_WATCH_SLEEP=1 NIGHTSHIFT_WATCH_RETRY="0 0" NIGHTSHIFT_WATCH_TRANSCRIPTS="$T" \
    "$WATCHMAN" --project "$P" --interval 20 --agent "bash $BIN/tick.sh" --max-wakes 2
  kill "$toucher" 2>/dev/null || true
  [ "$status" -eq 7 ]
  [ "$(calls)" -eq 0 ]
  grep -q 'owner pressed Esc — standing by' "$P/.nightshift/shift-log.md"
}

@test "a dead shift is revived even while a detached writer churns the project" {
  T="$BATS_TEST_TMPDIR/transcripts"
  mkdir -p "$T"
  printf '{"type":"message","content":"working"}\n' >"$T/shift.jsonl"
  bash -c ':' &
  deadpid=$!
  wait "$deadpid" 2>/dev/null || true
  printf 'sid-shift\n%s\n%s\n\n' "$T/shift.jsonl" "$deadpid" >"$P/.nightshift/.shift-session"
  RDY="$BATS_TEST_TMPDIR/.detached-dead-ready"
  ( touch "$P/detached-writer"; : >"$RDY"; while :; do sleep 0.15; touch "$P/detached-writer"; done ) &
  toucher=$!
  wait_writer "$RDY"
  run env NIGHTSHIFT_WATCH_SLEEP=1 NIGHTSHIFT_WATCH_RETRY="0 0" NIGHTSHIFT_WATCH_TRANSCRIPTS="$T" \
    "$WATCHMAN" --project "$P" --interval 20 --agent "bash $BIN/tick.sh" --max-wakes 4
  kill "$toucher" 2>/dev/null || true
  [ "$status" -eq 0 ]
  [ "$(calls)" -eq 2 ] # revived despite the churn, then clocked out
}

# The registry witness: `claude agents --json` is the host's own roster.
@test "the registry listing the recorded session stands the watchman by" {
  printf 'sid-shift\n\n\n\n' >"$P/.nightshift/.shift-session"
  cat >"$BIN/claude" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  agents*) printf '[{"sessionId":"sid-shift","kind":"interactive"}]\n' ;;
esac
STUB
  chmod +x "$BIN/claude"
  run env PATH="$BIN:$PATH" NIGHTSHIFT_WATCH_SLEEP=0 NIGHTSHIFT_WATCH_RETRY="0 0" \
    NIGHTSHIFT_WATCH_TRANSCRIPTS=/tmp/nowhere \
    "$WATCHMAN" --project "$P" --interval 20 --agent "bash $BIN/tick.sh" --max-wakes 3
  [ "$status" -eq 7 ]
  [ "$(calls)" -eq 0 ]
  grep -q 'long silent work; standing by' "$P/.nightshift/shift-log.md"
}

@test "a clean roster without the recorded session is death — revived" {
  printf 'sid-shift\n\n\n\n' >"$P/.nightshift/.shift-session"
  cat >"$BIN/claude" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  agents*) printf '[{"sessionId":"someone-else"}]\n' ;;
esac
STUB
  chmod +x "$BIN/claude"
  run env PATH="$BIN:$PATH" NIGHTSHIFT_WATCH_SLEEP=0 NIGHTSHIFT_WATCH_RETRY="0 0" \
    NIGHTSHIFT_WATCH_TRANSCRIPTS=/tmp/nowhere \
    "$WATCHMAN" --project "$P" --interval 20 --agent "bash $BIN/tick.sh" --max-wakes 4
  [ "$status" -eq 0 ]
  [ "$(calls)" -eq 2 ]
}

# A stale recorded pid must not read as death while the host still lists the session.
@test "the registry rescues a stale pid — listed session is alive, not revived over" {
  bash -c ':' &
  deadpid=$!
  wait "$deadpid" 2>/dev/null || true
  printf 'sid-shift\n\n%s\n\n' "$deadpid" >"$P/.nightshift/.shift-session"
  cat >"$BIN/claude" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  agents*) printf '[{"sessionId":"sid-shift","kind":"interactive"}]\n' ;;
esac
STUB
  chmod +x "$BIN/claude"
  run env PATH="$BIN:$PATH" NIGHTSHIFT_WATCH_SLEEP=0 NIGHTSHIFT_WATCH_RETRY="0 0" \
    NIGHTSHIFT_WATCH_TRANSCRIPTS=/tmp/nowhere \
    "$WATCHMAN" --project "$P" --interval 20 --agent "bash $BIN/tick.sh" --max-wakes 3
  [ "$status" -eq 7 ]
  [ "$(calls)" -eq 0 ]
}

# The revival order is the owner's to word; the default carries the contract.
@test "the revival order is the owner's to word" {
  cat >"$BIN/hear.sh" <<'STUB'
#!/usr/bin/env bash
echo called >>.nightshift/agent-calls
printf '%s\n' "$1" >.nightshift/heard
if ! grep -qE '^- \[ \]' .nightshift/punch-list.md; then
  : >.nightshift/.ended
  rm -f .nightshift/.shift-armed .nightshift/.shift-lease
  exit 0
fi
awk 'BEGIN{d=0} !d && /^- \[ \]/{sub(/\[ \]/,"[x]");d=1} {print}' .nightshift/punch-list.md >.nightshift/pl.tmp
mv .nightshift/pl.tmp .nightshift/punch-list.md
STUB
  chmod +x "$BIN/hear.sh"
  run env NIGHTSHIFT_WATCH_SLEEP=0 NIGHTSHIFT_WATCH_RETRY="0 0" \
    NIGHTSHIFT_REVIVAL_PROMPT="wake up and weld" \
    "$WATCHMAN" --project "$P" --interval 20 --agent "bash $BIN/hear.sh" --max-wakes 5
  [ "$status" -eq 0 ]
  grep -q "wake up and weld" "$P/.nightshift/heard"
}

# A successful revival is morning news, not a page: it lands in the parking lot; the push is
# reserved for the failure that needs the owner.
@test "a revival writes a parking-lot notice and does not page the owner" {
  wl="$BATS_TEST_TMPDIR/page.log"
  printf 'sid-shift\n\n\n\n' >"$P/.nightshift/.shift-session"
  run env NIGHTSHIFT_WATCH_SLEEP=0 NIGHTSHIFT_WATCH_RETRY="0 0" NIGHTSHIFT_WATCH_TRANSCRIPTS=/tmp/nowhere \
    NIGHTSHIFT_NOTIFY_CMD="printf '%s\n' \"\$NIGHTSHIFT_SUMMARY\" >> $wl" \
    "$WATCHMAN" --project "$P" --interval 20 --agent "bash $BIN/tick.sh" --max-wakes 4
  [ "$status" -eq 0 ]
  grep -q 'revived it' "$P/.nightshift/parking-lot.md"
  grep -q 'claude --resume sid-shift' "$P/.nightshift/parking-lot.md"
  [ ! -f "$wl" ] # no page for a night that fixed itself
}

@test "a dead session no attempt could revive pages the owner exactly once" {
  wl="$BATS_TEST_TMPDIR/down.log"
  printf 'sid-shift\n\n\n\n' >"$P/.nightshift/.shift-session"
  run env NIGHTSHIFT_WATCH_SLEEP=0 NIGHTSHIFT_WATCH_RETRY="0 0" NIGHTSHIFT_WATCH_TRANSCRIPTS=/tmp/nowhere \
    NIGHTSHIFT_NOTIFY_CMD="printf '%s\n' \"\$NIGHTSHIFT_SUMMARY\" >> $wl" \
    "$WATCHMAN" --project "$P" --interval 20 --agent "bash $BIN/fail.sh" --max-wakes 3
  [ "$status" -eq 7 ]
  [ "$(wc -l <"$wl" | tr -d ' ')" -eq 1 ] # once per outage, not once per wake
  grep -q 'revival failed' "$wl"
  grep -q 'claude --resume sid-shift' "$wl"
}

# Inheriting a scope means reproducing what the session had. Claude Code names no scope for a
# session's permissions, so the shipped inherit setting has nothing to inherit — and a revival at
# whatever the host defaults to is a guess about permissions, not a narrowing.

@test "a revival is refused when there is nothing to inherit, and says what would authorize one" {
  jq 'del(.recovery)' "$P/.nightshift/rules.json" >"$P/.nightshift/r.json"
  mv "$P/.nightshift/r.json" "$P/.nightshift/rules.json"
  run env NIGHTSHIFT_WATCH_SLEEP=0 NIGHTSHIFT_WATCH_RETRY="0 0" NIGHTSHIFT_WATCH_TRANSCRIPTS=/tmp/nowhere \
    "$WATCHMAN" --project "$P" --interval 20 --agent "bash $BIN/tick.sh" --max-wakes 2
  # No child was ever spawned, and the work is exactly where it was.
  [ ! -f "$P/.nightshift/agent-calls" ]
  grep -qE '^- \[ \]' "$P/.nightshift/punch-list.md"
  grep -qF 'nothing to inherit' "$P/.nightshift/shift-log.md"
  grep -qF 'recovery.launchScope to host-default' "$P/.nightshift/shift-log.md"
  [ "$(sed -n 1p "$P/.nightshift/.watch-reason")" = recovery-scope-unavailable ]
}

@test "an owner who authorized a scope by name still gets their revival" {
  # The same site, with the one line that says which scope a revival may use.
  run env NIGHTSHIFT_WATCH_SLEEP=0 NIGHTSHIFT_WATCH_RETRY="0 0" \
    "$WATCHMAN" --project "$P" --interval 20 --agent "bash $BIN/tick.sh" --max-wakes 5
  [ "$status" -eq 0 ]
  [ -f "$P/.nightshift/agent-calls" ]
  grep -qF 'reviving under launch scope host-default' "$P/.nightshift/shift-log.md"
}

@test "a policy that cannot be read refuses in its own words, not as an unrecorded scope" {
  printf '{ "schemaVersion": 1,\n' >"$P/.nightshift/shift-policy.json"
  jq 'del(.recovery)' "$P/.nightshift/rules.json" >"$P/.nightshift/r.json"
  mv "$P/.nightshift/r.json" "$P/.nightshift/rules.json"
  run env NIGHTSHIFT_WATCH_SLEEP=0 NIGHTSHIFT_WATCH_RETRY="0 0" NIGHTSHIFT_WATCH_TRANSCRIPTS=/tmp/nowhere \
    "$WATCHMAN" --project "$P" --interval 20 --agent "bash $BIN/tick.sh" --max-wakes 2
  [ ! -f "$P/.nightshift/agent-calls" ]
  grep -qF 'cannot be read' "$P/.nightshift/shift-log.md"
}

# One copy: the watchman reads its orders from the rules file; env stays the override.
@test "the revival order is read from the rules file" {
  jq '.revivalPrompt = "weld from the file" | .recovery.launchScope = "host-default"' \
    "$BATS_TEST_DIRNAME/../plugins/nightshift/skills/nightshift/references/nightshift-rules-template.json" >"$P/.nightshift/rules.json"
  cat >"$BIN/hear2.sh" <<'STUB'
#!/usr/bin/env bash
echo called >>.nightshift/agent-calls
printf '%s\n' "$1" >.nightshift/heard
if ! grep -qE '^- \[ \]' .nightshift/punch-list.md; then
  : >.nightshift/.ended
  rm -f .nightshift/.shift-armed .nightshift/.shift-lease
  exit 0
fi
awk 'BEGIN{d=0} !d && /^- \[ \]/{sub(/\[ \]/,"[x]");d=1} {print}' .nightshift/punch-list.md >.nightshift/pl.tmp
mv .nightshift/pl.tmp .nightshift/punch-list.md
STUB
  chmod +x "$BIN/hear2.sh"
  run env NIGHTSHIFT_WATCH_SLEEP=0 NIGHTSHIFT_WATCH_RETRY="0 0" \
    "$WATCHMAN" --project "$P" --interval 20 --agent "bash $BIN/hear2.sh" --max-wakes 5
  [ "$status" -eq 0 ]
  grep -q "weld from the file" "$P/.nightshift/heard"
}

# The watchman refuses to arm without its orders — loudly, naming the repair.
@test "a missing rules file refuses to arm the watchman" {
  rm "$P/.nightshift/rules.json"
  run env NIGHTSHIFT_WATCH_SLEEP=0 \
    "$WATCHMAN" --project "$P" --interval 20 --agent "bash $BIN/tick.sh" --max-wakes 2
  [ "$status" -eq 1 ]
  printf '%s' "$output" | grep -qF '/nightshift:setup'
  printf '%s' "$output" | grep -qF 'ask Nightshift to set up on Codex'
  grep -q 'cannot arm' "$P/.nightshift/shift-log.md"
}

# The session record names its host so two watchmen can share a project without fighting over it.
# Reviving another host's shift would spawn claude at a session a different agent is working.
@test "the watchman stands down on a shift owned by another host" {
  printf 'sid\n/tmp/t.jsonl\n99999\nstart\ncodex\n' >"$P/.nightshift/.shift-session"
  run watch --agent "bash $BIN/tick.sh" --max-wakes 1
  [ "$status" -eq 0 ]
  [ "$(calls)" -eq 0 ]
  grep -q 'owned by codex' "$P/.nightshift/shift-log.md"
}

@test "the watchman stands down on a cursor-owned shift" {
  printf 'sid\n/Users/o/.cursor/projects/x/u.jsonl\n99999\nstart\ncursor\n' >"$P/.nightshift/.shift-session"
  run watch --agent "bash $BIN/tick.sh" --max-wakes 1
  [ "$status" -eq 0 ]
  [ "$(calls)" -eq 0 ]
  grep -q 'owned by cursor' "$P/.nightshift/shift-log.md"
}

# A record written before hosts were named can only be Claude's — nothing else could write one.
@test "a record with no host is treated as claude" {
  printf 'sid\n/tmp/t.jsonl\n99999\nstart\n' >"$P/.nightshift/.shift-session"
  run watch --agent "bash $BIN/tick.sh" --max-wakes 1
  ! grep -q 'owned by' "$P/.nightshift/shift-log.md" || false
  [ "$(calls)" -ge 1 ]
}

reason() { sed -n 1p "$P/.nightshift/.watch-reason" | tr -d '[:space:]'; }

@test "stop-work records owner-stop and nothing else" {
  touch "$P/.nightshift/STOP"
  run watch --agent "bash $BIN/tick.sh" --max-wakes 3
  [ "$status" -eq 0 ]
  [ "$(reason)" = "owner-stop" ]
  [ "$(wc -l <"$P/.nightshift/.watch-reason" | tr -d ' ')" -le 2 ]
}

@test "an ended shift records completed" {
  touch "$P/.nightshift/.ended"
  run watch --agent "bash $BIN/tick.sh" --max-wakes 3
  [ "$(reason)" = "completed" ]
}

@test "a clean session end records clean-session-end" {
  echo 'clean session end (prompt_input_exit)' >"$P/.nightshift/.session-end"
  run watch --agent "bash $BIN/tick.sh" --max-wakes 3
  [ "$(reason)" = "clean-session-end" ]
}

@test "ticked boxes without .ended record completed after the clock-out spawn" {
  printf '## Items\n- [x] **1.**\n' >"$P/.nightshift/punch-list.md"
  run watch --agent "bash $BIN/tick.sh" --max-wakes 3
  [ "$(reason)" = "completed" ]
}

@test "quitting time records deadline" {
  printf '%s' "$(( $(date +%s) - 60 ))" >"$P/.nightshift/deadline"
  run watch --agent "bash $BIN/tick.sh" --max-wakes 3
  [ "$(reason)" = "deadline" ]
}

@test "a foreign host records wrong-host" {
  printf 'sid\n/tmp/t.jsonl\n99999\nstart\ncodex\n' >"$P/.nightshift/.shift-session"
  run watch --agent "bash $BIN/tick.sh" --max-wakes 1
  [ "$(reason)" = "wrong-host" ]
}

@test "a symlink shift-session does not record a foreign host" {
  printf 'sid\n/tmp/t.jsonl\n99999\nstart\ncodex\n' >"$P/.nightshift/session-plant"
  ln -s session-plant "$P/.nightshift/.shift-session"
  run watch --agent "bash $BIN/tick.sh" --max-wakes 1
  [ "$(reason)" != "wrong-host" ]
}

@test "Esc standby records esc-standby without transcript content" {
  T="$BATS_TEST_TMPDIR/transcripts"
  mkdir -p "$T"
  printf '{"type":"message","content":"secret-prompt-xyz"}\n{"type":"user","content":"[Request interrupted by user]"}\n' >"$T/session.jsonl"
  run env NIGHTSHIFT_WATCH_SLEEP=0 NIGHTSHIFT_WATCH_RETRY="0 0" NIGHTSHIFT_WATCH_TRANSCRIPTS="$T" \
    "$WATCHMAN" --project "$P" --interval 20 --agent "bash $BIN/tick.sh" --max-wakes 3
  [ "$(reason)" = "esc-standby" ]
  if grep -q 'secret-prompt-xyz' "$P/.nightshift/.watch-reason"; then
    return 1
  fi
}

@test "a live silent process records silent-standby" {
  start="$(ps -o lstart= -p $$ | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  printf 'sid-shift\n\n%s\n%s\n' "$$" "$start" >"$P/.nightshift/.shift-session"
  run env NIGHTSHIFT_WATCH_SLEEP=0 NIGHTSHIFT_WATCH_RETRY="0 0" NIGHTSHIFT_WATCH_TRANSCRIPTS=/tmp/nowhere \
    "$WATCHMAN" --project "$P" --interval 20 --agent "bash $BIN/tick.sh" --max-wakes 3
  [ "$(reason)" = "silent-standby" ]
}

@test "failed revival attempts record exhausted-retry" {
  run watch --agent "bash $BIN/fail.sh" --max-wakes 2
  [ "$(reason)" = "exhausted-retry" ]
}

@test "a successful resume records revived" {
  printf 'abc-123\n\n\n\n' >"$P/.nightshift/.shift-session"
  cat >"$BIN/claude" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  agents*) echo "[]" ;;
  *--resume*) echo resume >>.nightshift/agent-calls
     awk 'BEGIN{d=0} !d && /^- \[ \]/{sub(/\[ \]/,"[x]");d=1} {print}' .nightshift/punch-list.md >.nightshift/pl.tmp
     mv .nightshift/pl.tmp .nightshift/punch-list.md ;;
  *) echo other >>.nightshift/agent-calls ;;
esac
STUB
  chmod +x "$BIN/claude"
  run env PATH="$BIN:$PATH" NIGHTSHIFT_WATCH_SLEEP=0 NIGHTSHIFT_WATCH_RETRY="0 0" \
    NIGHTSHIFT_WATCH_TRANSCRIPTS=/tmp/nowhere \
    "$WATCHMAN" --project "$P" --interval 20 --max-wakes 1
  [ "$(reason)" = "revived" ]
}

@test "a child that exits 0 without moving the shift is not a revival" {
  cat >"$BIN/noop.sh" <<'STUB'
#!/usr/bin/env bash
echo called >>.nightshift/agent-calls
exit 0
STUB
  chmod +x "$BIN/noop.sh"
  run watch --agent "bash $BIN/noop.sh" --max-wakes 1
  [ "$(reason)" != "revived" ]
  [ "$(reason)" = "exhausted-retry" ]
  grep -qE '^- \[ \]' "$P/.nightshift/punch-list.md"
}

@test "the fresh-session fallback records fresh-fallback, not revived" {
  printf 'abc-123\n\n\n\n' >"$P/.nightshift/.shift-session"
  cat >"$BIN/claude" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  agents*) echo "[]" ;;
  *--resume*) echo resume >>.nightshift/agent-calls; exit 1 ;;
  *--continue*) echo continue >>.nightshift/agent-calls; exit 1 ;;
  *) echo fresh >>.nightshift/agent-calls
     awk 'BEGIN{d=0} !d && /^- \[ \]/{sub(/\[ \]/,"[x]");d=1} {print}' .nightshift/punch-list.md >.nightshift/pl.tmp
     mv .nightshift/pl.tmp .nightshift/punch-list.md ;;
esac
STUB
  chmod +x "$BIN/claude"
  run env PATH="$BIN:$PATH" NIGHTSHIFT_WATCH_SLEEP=0 NIGHTSHIFT_WATCH_RETRY="0 0" \
    NIGHTSHIFT_WATCH_TRANSCRIPTS=/tmp/nowhere \
    "$WATCHMAN" --project "$P" --interval 20 --max-wakes 1
  [ "$(reason)" = "fresh-fallback" ]
}

@test "watchman resolves watchAgent from rules before the default ladder" {
  # Pin the seam; full spawn coverage for verbatim --agent remains in neighboring tests.
  grep -qF 'watchAgent' "$WATCHMAN"
  grep -qF 'NIGHTSHIFT_WATCH_AGENT' "$WATCHMAN"
  grep -qF 'claude --continue -p' "$WATCHMAN"
  CODEX_W="$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/codex/watchman.sh"
  grep -qF 'watchAgent' "$CODEX_W"
  WIN_W="$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/windows/watchman.ps1"
  grep -qF 'watchAgent' "$WIN_W"
}

@test "missing rules record unreadable-rules" {
  rm "$P/.nightshift/rules.json"
  run env NIGHTSHIFT_WATCH_SLEEP=0 \
    "$WATCHMAN" --project "$P" --interval 20 --agent "bash $BIN/tick.sh" --max-wakes 2
  [ "$(reason)" = "unreadable-rules" ]
  printf '%s' "$output" | grep -qF '/nightshift:setup on Claude Code; ask Nightshift to set up on Codex'
}

# ---- disarm is total, and a dead attempt never keeps the lease ----
#
# The armed marker is the shift itself. Once it is gone the watchman holds no opinion about the
# site: no liveness reading, no spawn, no clock-out — and it never writes the marker back. The
# lease is the other half: every attempt takes it, so a ladder that revives nothing has to give
# it back, or the conversation the record names is fenced out of its own project.

lease_line() { sed -n "$1p" "$P/.nightshift/.shift-lease"; }

# A host roster that lists nobody: the registry witness saying the recorded session is gone.
empty_roster() {
  cat >"$BIN/claude" <<'STUB'
#!/usr/bin/env bash
case "$*" in agents*) echo "[]" ;; esac
exit 0
STUB
  chmod +x "$BIN/claude"
}

@test "a missing armed marker stands the watchman down at the first tick" {
  rm -f "$P/.nightshift/.shift-armed"
  run watch --agent "bash $BIN/tick.sh" --max-wakes 3
  [ "$status" -eq 0 ]
  [ "$(calls)" -eq 0 ]
  grep -qF 'watchman: the armed marker is gone — standing down' "$P/.nightshift/shift-log.md"
  [ "$(reason)" = "owner-disarm" ]
  [ ! -e "$P/.nightshift/.shift-armed" ] # never created, never touched
}

@test "a disarmed site is stood down before the clock-out and the deadline" {
  printf '## Items\n- [x] **1.**\n' >"$P/.nightshift/punch-list.md"
  printf '%s' "$(( $(date +%s) - 60 ))" >"$P/.nightshift/deadline"
  rm -f "$P/.nightshift/.shift-armed"
  run watch --agent "bash $BIN/tick.sh" --max-wakes 3
  [ "$status" -eq 0 ]
  [ "$(calls)" -eq 0 ]
  [ ! -f "$P/.nightshift/.ended" ]
  [ "$(reason)" = "owner-disarm" ]
}

# The fresh-session rung starts a session that carries only the punch list. It is the strongest
# claim on the night and the last one to make, so it needs the marker at the moment it fires.
@test "a marker removed mid-ladder stops before the fresh-session fallback" {
  printf 'abc-123\n\n\n\n' >"$P/.nightshift/.shift-session"
  cat >"$BIN/claude" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  agents*) echo "[]"; exit 0 ;;
  *--resume*) echo resume >>.nightshift/agent-calls ;;
  *--continue*) echo continue >>.nightshift/agent-calls ;;
  *) echo fresh >>.nightshift/agent-calls ;;
esac
rm -f .nightshift/.shift-armed
exit 1
STUB
  chmod +x "$BIN/claude"
  run env PATH="$BIN:$PATH" NIGHTSHIFT_WATCH_SLEEP=0 NIGHTSHIFT_WATCH_RETRY="0 0" \
    NIGHTSHIFT_WATCH_TRANSCRIPTS=/tmp/nowhere \
    "$WATCHMAN" --project "$P" --interval 20 --max-wakes 3
  [ "$status" -eq 0 ]
  [ "$(sed -n 1p "$P/.nightshift/agent-calls")" = "resume" ]
  [ "$(wc -l <"$P/.nightshift/agent-calls" | tr -d ' ')" -eq 1 ]
  if grep -q fresh "$P/.nightshift/agent-calls"; then
    return 1
  fi
  if grep -q 'fresh-session fallback' "$P/.nightshift/shift-log.md"; then
    return 1
  fi
  grep -qF 'watchman: the armed marker is gone — standing down' "$P/.nightshift/shift-log.md"
  [ "$(reason)" = "owner-disarm" ]
}

# An account that has hit a usage limit fails every attempt of every wake. The knock doubles its
# wait instead of arriving every interval until morning, and life on the site puts it back.
@test "an API-limited ladder doubles the wait and a pulse puts it back" {
  T="$BATS_TEST_TMPDIR/transcripts"
  mkdir -p "$T"
  printf '{"type":"assistant","message":{"content":[{"type":"text","text":"working"}]}}\n' >"$T/shift.jsonl"
  printf 'sid-shift\n%s\n\n\nclaude\n' "$T/shift.jsonl" >"$P/.nightshift/.shift-session"
  empty_roster
  # Fails the way a rate-limited host fails: nothing done, the limit recorded in the transcript.
  cat >"$BIN/limited.sh" <<STUB
#!/usr/bin/env bash
echo called >>.nightshift/agent-calls
printf '%s\n' '{"type":"assistant","message":{"model":"<synthetic>","content":[{"type":"text","text":"API Error: 429 rate_limit_error"}]},"error":"rate_limit_error","isApiErrorMessage":true,"apiErrorStatus":429}' >>"$T/shift.jsonl"
exit 1
STUB
  # The wake sleep is the watchman's own clock. This stub records every wait and scripts the
  # site's timeline with it: a pulse before wake 2, gone again before wake 3.
  cat >"$BIN/sleep" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$1" >>"$BATS_TEST_TMPDIR/sleeps"
case "\$1" in 0 | 0.*) exit 0 ;; esac
n=\$(( \$(cat "$BATS_TEST_TMPDIR/wakes" 2>/dev/null || echo 0) + 1 ))
printf '%s\n' "\$n" >"$BATS_TEST_TMPDIR/wakes"
[ "\$n" != 2 ] || printf '%s sid-shift\n' "\$(date +%s)" >"$P/.nightshift/.shift-pulse"
[ "\$n" != 3 ] || rm -f "$P/.nightshift/.shift-pulse"
exit 0
STUB
  chmod +x "$BIN/limited.sh" "$BIN/sleep"
  run env PATH="$BIN:$PATH" NIGHTSHIFT_WATCH_SLEEP=1 NIGHTSHIFT_WATCH_RETRY="0 0" \
    NIGHTSHIFT_WATCH_TRANSCRIPTS="$T" \
    "$WATCHMAN" --project "$P" --interval 20 --agent "bash $BIN/limited.sh" --max-wakes 3
  [ "$status" -eq 7 ]
  [ "$(reason)" = "exhausted-retry" ]
  [ "$(grep -cF 'watchman: all 3 attempts failed (api down?) — backing off, knocking again in 40m' \
    "$P/.nightshift/shift-log.md")" -eq 2 ] # doubled on wake 1, reset by the pulse, doubled again
  if grep -qF 'knocking again in 80m' "$P/.nightshift/shift-log.md"; then
    return 1
  fi
  # The waits themselves: the interval, twice the interval, then the interval again.
  [ "$(grep -v '^0' "$BATS_TEST_TMPDIR/sleeps" | tr '\n' ' ')" = "1 2 1 " ]
}

@test "the API backoff never waits longer than an hour" {
  T="$BATS_TEST_TMPDIR/transcripts"
  mkdir -p "$T"
  printf 'sid-shift\n%s\n\n\nclaude\n' "$T/shift.jsonl" >"$P/.nightshift/.shift-session"
  empty_roster
  cat >"$BIN/limited.sh" <<STUB
#!/usr/bin/env bash
echo called >>.nightshift/agent-calls
printf '%s\n' '{"type":"assistant","message":{"model":"<synthetic>","content":[{"type":"text","text":"Claude usage limit reached"}]},"error":"usage_limit","isApiErrorMessage":true}' >>"$T/shift.jsonl"
exit 1
STUB
  chmod +x "$BIN/limited.sh"
  run env PATH="$BIN:$PATH" NIGHTSHIFT_WATCH_SLEEP=0 NIGHTSHIFT_WATCH_RETRY="0 0" \
    NIGHTSHIFT_WATCH_TRANSCRIPTS="$T" \
    "$WATCHMAN" --project "$P" --interval 40 --agent "bash $BIN/limited.sh" --max-wakes 2
  [ "$status" -eq 7 ]
  [ "$(grep -cF 'backing off, knocking again in 60m' "$P/.nightshift/shift-log.md")" -eq 2 ]
  if grep -qF 'knocking again in 80m' "$P/.nightshift/shift-log.md"; then
    return 1
  fi
}

# A failure with no limit behind it is not an outage: the knock keeps its interval, in the
# wording the morning already knows.
@test "a failure without API evidence keeps the interval and the existing line" {
  empty_roster
  printf 'sid-shift\n\n\n\nclaude\n' >"$P/.nightshift/.shift-session"
  run env PATH="$BIN:$PATH" NIGHTSHIFT_WATCH_SLEEP=0 NIGHTSHIFT_WATCH_RETRY="0 0" \
    NIGHTSHIFT_WATCH_TRANSCRIPTS=/tmp/nowhere \
    "$WATCHMAN" --project "$P" --interval 20 --agent "bash $BIN/fail.sh" --max-wakes 2
  [ "$status" -eq 7 ]
  [ "$(grep -cF 'watchman: all 3 attempts failed (api down?) — knocking again in 20m' \
    "$P/.nightshift/shift-log.md")" -eq 2 ]
  if grep -q 'backing off' "$P/.nightshift/shift-log.md"; then
    return 1
  fi
}

# Every attempt takes the lease for its own child. When the whole ladder fails, the lease goes
# back to the recorded conversation, so reopening it needs nothing from the owner.
@test "an exhausted ladder hands the lease back to the recorded conversation" {
  bash -c ':' &
  deadpid=$!
  wait "$deadpid" 2>/dev/null || true
  printf 'test-shift-session\n\n%s\n\nclaude\n' "$deadpid" >"$P/.nightshift/.shift-session"
  empty_roster
  run env PATH="$BIN:$PATH" NIGHTSHIFT_WATCH_SLEEP=0 NIGHTSHIFT_WATCH_RETRY="0 0" \
    NIGHTSHIFT_WATCH_TRANSCRIPTS=/tmp/nowhere \
    "$WATCHMAN" --project "$P" --interval 20 --agent "bash $BIN/fail.sh" --max-wakes 1
  [ "$status" -eq 7 ]
  [ "$(lease_line 1)" = "test-shift-session" ]
  [ "$(lease_line 2)" = "claude" ]
  [ "$(lease_line 3)" -ge 2 ] # every attempt advanced the generation; the restore advances it too
  [ -z "$(lease_line 4)" ]    # no recovery nonce
  [ -z "$(lease_line 5)" ]    # and no dead holder pid to fence the conversation with
  run recorded_read "$P" test-shift-session
  is_allow
}

# The restored lease names the recorded process while that process is alive — the wedge case,
# where the conversation still has a host but nobody at the keyboard.
@test "the restored lease names the recorded process while it is alive" {
  T="$BATS_TEST_TMPDIR/transcripts"
  mkdir -p "$T"
  printf '%s\n' \
    '{"type":"assistant","message":{"model":"<synthetic>","content":[{"type":"text","text":"API Error: 500 Internal server error"}]},"error":"server_error","isApiErrorMessage":true,"apiErrorStatus":500}' \
    >"$T/shift.jsonl"
  start="$(ps -o lstart= -p $$ | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  printf 'test-shift-session\n%s\n%s\n%s\nclaude\n' "$T/shift.jsonl" "$$" "$start" >"$P/.nightshift/.shift-session"
  empty_roster
  run env PATH="$BIN:$PATH" NIGHTSHIFT_WATCH_SLEEP=0 NIGHTSHIFT_WATCH_RETRY="0 0" \
    NIGHTSHIFT_WATCH_TRANSCRIPTS="$T" \
    "$WATCHMAN" --project "$P" --interval 20 --agent "bash $BIN/fail.sh" --max-wakes 1
  [ "$status" -eq 7 ]
  [ "$(lease_line 1)" = "test-shift-session" ]
  [ -z "$(lease_line 4)" ]
  [ "$(lease_line 5)" = "$$" ]
  [ "$(lease_line 6)" = "$start" ]
}

# A site that came back mid-ladder is not left holding a dead attempt's lease either.
@test "a ladder held by returning session activity hands the lease back" {
  T="$BATS_TEST_TMPDIR/transcripts"
  mkdir -p "$T"
  printf '{"type":"message","content":"working"}\n' >"$T/shift.jsonl"
  printf 'test-shift-session\n%s\n\n\nclaude\n' "$T/shift.jsonl" >"$P/.nightshift/.shift-session"
  empty_roster
  RDY="$BATS_TEST_TMPDIR/.return-ready"
  ( : >"$RDY"; sleep 1
    while :; do printf '{"type":"message","content":"back"}\n' >>"$T/shift.jsonl"; sleep 0.3; done ) &
  appender=$!
  wait_writer "$RDY"
  run env PATH="$BIN:$PATH" NIGHTSHIFT_WATCH_SLEEP=0 NIGHTSHIFT_WATCH_RETRY="2" NIGHTSHIFT_WATCH_TRANSCRIPTS="$T" \
    "$WATCHMAN" --project "$P" --interval 20 --agent "bash $BIN/fail.sh" --max-wakes 1
  kill "$appender" 2>/dev/null || true
  [ "$status" -eq 7 ]
  grep -q 'during retries — holding the remaining attempts' "$P/.nightshift/shift-log.md"
  [ "$(lease_line 1)" = "test-shift-session" ]
  [ -z "$(lease_line 4)" ]
}

# The pidfile is the watchman's claim on the site. Reset and purge take it away; a second
# watchman replaces the pid inside it. Neither leaves this loop anything to watch.
@test "a removed watchman pidfile stands the watchman down at the tick" {
  cat >"$BIN/unclaim.sh" <<'STUB'
#!/usr/bin/env bash
echo called >>.nightshift/agent-calls
rm -f .nightshift/.watchman
exit 1
STUB
  chmod +x "$BIN/unclaim.sh"
  run watch --agent "bash $BIN/unclaim.sh" --max-wakes 3
  [ "$status" -eq 0 ]
  [ "$(calls)" -eq 3 ] # the wake that lost the pidfile still finished its own ladder
  grep -qF 'watchman: the watchman pidfile is gone — standing down' "$P/.nightshift/shift-log.md"
  [ "$(reason)" = "stand-down" ]
}

@test "a pidfile taken over by another watchman stands this one down and leaves it alone" {
  cat >"$BIN/takeover.sh" <<'STUB'
#!/usr/bin/env bash
echo called >>.nightshift/agent-calls
printf '999999\n' >.nightshift/.watchman
exit 1
STUB
  chmod +x "$BIN/takeover.sh"
  run watch --agent "bash $BIN/takeover.sh" --max-wakes 3
  [ "$status" -eq 0 ]
  grep -qF 'watchman: another watchman owns this site — standing down' "$P/.nightshift/shift-log.md"
  [ "$(sed -n 1p "$P/.nightshift/.watchman")" = "999999" ] # the other claim survives the exit
}

# ---------------------------------------------------------------------------------------------
# What a revived session is allowed to do is the owner's, and the same words in a message are not
# the host reporting a failure.

@test "a revival inherits the scope the shift was started under, and never widens it" {
  p="$(new_project watch-scope)"
  # Shipped: inherit whatever the shift itself was running under.
  run bash -c '. "$1"; ns_recovery_launch_scope "$2"' _ "$BATS_TEST_DIRNAME/../plugins/nightshift/lib/lib.sh" "$p"
  [ "$output" = inherit-recorded-scope ]

  # With nothing recorded there is nothing to inherit, and the host's own default is a guess about
  # permissions rather than a narrowing. So the answer is a refusal, and it says why.
  run bash -c '. "$1"; ns_recovery_effective_scope "$2" codex' _ "$BATS_TEST_DIRNAME/../plugins/nightshift/lib/lib.sh" "$p"
  [ "$output" = "unavailable:unrecorded" ]
  run bash -c '. "$1"; ns_recovery_refusal unavailable:unrecorded' _ "$BATS_TEST_DIRNAME/../plugins/nightshift/lib/lib.sh"
  printf '%s' "$output" | grep -qF 'nothing to inherit'

  # With the scope the arming session actually reported, that is what a revival asks for.
  jq -n '{schemaVersion: 1, shiftId: "9f2c40ab77e51d63", createdAt: "2026-09-02T00:00:00Z",
          source: "composition", verificationLevel: "none", toolingPolicy: "existing-tools",
          launchScope: "workspace-write", launchProvenance: "observed"}' \
    >"$p/.nightshift/shift-policy.json"
  run bash -c '. "$1"; ns_recovery_effective_scope "$2" codex' _ "$BATS_TEST_DIRNAME/../plugins/nightshift/lib/lib.sh" "$p"
  [ "$output" = "recorded:workspace-write" ]

  # A scope the host never reported is not something to inherit either.
  jq '.launchProvenance = "unavailable" | .launchScope = "unknown"' \
    "$p/.nightshift/shift-policy.json" >"$p/pol.json"
  mv "$p/pol.json" "$p/.nightshift/shift-policy.json"
  run bash -c '. "$1"; ns_recovery_effective_scope "$2" codex' _ "$BATS_TEST_DIRNAME/../plugins/nightshift/lib/lib.sh" "$p"
  [ "$output" = "unavailable:unrecorded" ]

  # A policy that cannot be read says so in its own words, rather than reporting no scope.
  printf '{ "schemaVersion": 1,\n' >"$p/.nightshift/shift-policy.json"
  run bash -c '. "$1"; ns_recovery_effective_scope "$2" codex' _ "$BATS_TEST_DIRNAME/../plugins/nightshift/lib/lib.sh" "$p"
  [ "$output" = "unavailable:unreadable" ]
  jq -n '{schemaVersion: 1, shiftId: "9f2c40ab77e51d63", createdAt: "2026-09-02T00:00:00Z",
          source: "composition", verificationLevel: "none", toolingPolicy: "existing-tools"}' \
    >"$p/.nightshift/shift-policy.json"

  # A legacy broad grant refuses rather than enabling bypass.
  jq '.recovery.launchScope = "host-grant"' "$p/.nightshift/rules.json" >"$p/r.json"
  mv "$p/r.json" "$p/.nightshift/rules.json"
  run bash -c '. "$1"; ns_recovery_effective_scope "$2" codex' _ "$BATS_TEST_DIRNAME/../plugins/nightshift/lib/lib.sh" "$p"
  [ "$output" = unavailable:host-grant ]

  # And the narrowest choice is still available by name.
  jq '.recovery.launchScope = "host-default"' "$p/.nightshift/rules.json" >"$p/r.json"
  mv "$p/r.json" "$p/.nightshift/rules.json"
  run bash -c '. "$1"; ns_recovery_effective_scope "$2" codex' _ "$BATS_TEST_DIRNAME/../plugins/nightshift/lib/lib.sh" "$p"
  [ "$output" = host-default ]

  # An explicit host-default choice uses the host configuration, even after a broader session.
  jq -n '{schemaVersion: 1, shiftId: "9f2c40ab77e51d63", createdAt: "2026-09-02T00:00:00Z",
          source: "composition", verificationLevel: "none", toolingPolicy: "existing-tools",
          launchScope: "danger-full-access", launchProvenance: "observed"}' \
    >"$p/.nightshift/shift-policy.json"
  run bash -c '. "$1"; ns_recovery_effective_scope "$2" codex' _ "$BATS_TEST_DIRNAME/../plugins/nightshift/lib/lib.sh" "$p"
  [ "$output" = host-default ]
}

@test "a mid-shift rules.json change of recovery.launchScope is what the next wake reads" {
  p="$(new_project watch-scope-live)"
  # The snapshot froze inherit. The owner's file is the one they can change while the shift runs.
  jq -n '{schemaVersion: 1, shiftId: "9f2c40ab77e51d63", createdAt: "2026-09-02T00:00:00Z",
          source: "composition", verificationLevel: "none", toolingPolicy: "existing-tools",
          recovery: {launchScope: "inherit-recorded-scope"}}' \
    >"$p/.nightshift/shift-policy.json"
  jq '.recovery.launchScope = "host-default"' "$p/.nightshift/rules.json" >"$p/r.json"
  mv "$p/r.json" "$p/.nightshift/rules.json"
  run bash -c '. "$1"; ns_recovery_effective_scope "$2" cursor' _ "$BATS_TEST_DIRNAME/../plugins/nightshift/lib/lib.sh" "$p"
  [ "$output" = host-default ]
}

@test "a workspace that predates the setting is not read as having chosen the broad grant" {
  p="$(new_project watch-scope-legacy)"
  # A rules file from before recovery.launchScope existed. Its old behaviour was the built-in
  # broad launch, but that was a default nobody chose — so it inherits rather than escalates.
  jq 'del(.recovery)' "$p/.nightshift/rules.json" >"$p/r.json"
  mv "$p/r.json" "$p/.nightshift/rules.json"
  run bash -c '. "$1"; ns_recovery_launch_scope "$2"' _ "$BATS_TEST_DIRNAME/../plugins/nightshift/lib/lib.sh" "$p"
  [ "$output" = inherit-recorded-scope ]
  # And it inherits nothing, because nothing was recorded — so the revival is refused rather than
  # launched at a scope nobody can vouch for.
  run bash -c '. "$1"; ns_recovery_effective_scope "$2" codex' _ "$BATS_TEST_DIRNAME/../plugins/nightshift/lib/lib.sh" "$p"
  [ "$output" = "unavailable:unrecorded" ]
}

@test "what the host reports is what gets recorded, and silence is not a scope" {
  run bash -c '. "$1"; CODEX_SANDBOX_MODE=workspace-write ns_launch_observed codex' _ "$BATS_TEST_DIRNAME/../plugins/nightshift/lib/lib.sh"
  [ "$output" = "$(printf 'workspace-write\tobserved')" ]
  run bash -c '. "$1"; unset CODEX_SANDBOX_MODE CODEX_SANDBOX; ns_launch_observed codex' _ "$BATS_TEST_DIRNAME/../plugins/nightshift/lib/lib.sh"
  [ "$output" = "$(printf 'unknown\tunavailable')" ]
  # Claude Code and Cursor hand a session its permissions at launch and name none of it
  # anywhere a hook can read, so there is nothing to observe and nothing claims otherwise.
  for h in claude cursor; do
    run bash -c '. "$1"; ns_launch_observed "$2"' _ "$BATS_TEST_DIRNAME/../plugins/nightshift/lib/lib.sh" "$h"
    [ "$output" = "$(printf 'unknown\tunavailable')" ] || { echo "$h claimed $output"; return 1; }
  done
}

@test "a recorded scope this host cannot ask for refuses the revival instead of guessing" {
  p="$(new_project watch-scope-unsupported)"
  # The arming session reported a sandbox mode codex exec has no flag for. Reviving anyway would
  # run at some other scope, so the answer says so and the watchman stands down on it.
  jq -n '{schemaVersion: 1, shiftId: "9f2c40ab77e51d63", createdAt: "2026-09-02T00:00:00Z",
          source: "composition", verificationLevel: "none", toolingPolicy: "existing-tools",
          launchScope: "some-future-mode", launchProvenance: "observed"}' \
    >"$p/.nightshift/shift-policy.json"
  run bash -c '. "$1"; ns_recovery_effective_scope "$2" codex' _ "$BATS_TEST_DIRNAME/../plugins/nightshift/lib/lib.sh" "$p"
  [ "$output" = "unavailable:unsupported:some-future-mode" ]
  run bash -c '. "$1"; ns_recovery_refusal unavailable:unsupported:some-future-mode' _ "$BATS_TEST_DIRNAME/../plugins/nightshift/lib/lib.sh"
  printf '%s' "$output" | grep -qF "'some-future-mode'"

  # Only the modes codex actually takes pass through to a flag.
  for m in read-only workspace-write; do
    jq --arg m "$m" '.launchScope = $m' "$p/.nightshift/shift-policy.json" >"$p/pol.json"
    mv "$p/pol.json" "$p/.nightshift/shift-policy.json"
    run bash -c '. "$1"; ns_recovery_effective_scope "$2" codex' _ "$BATS_TEST_DIRNAME/../plugins/nightshift/lib/lib.sh" "$p"
    [ "$output" = "recorded:$m" ] || { echo "$m -> $output"; return 1; }
  done

  for m in danger-full-access dangerously-skip-permissions bypass-permissions bypassPermissions; do
    jq --arg m "$m" '.launchScope = $m' "$p/.nightshift/shift-policy.json" >"$p/pol.json"
    mv "$p/pol.json" "$p/.nightshift/shift-policy.json"
    for h in codex claude cursor; do
      run bash -c '. "$1"; ns_recovery_effective_scope "$2" "$3"' _ "$BATS_TEST_DIRNAME/../plugins/nightshift/lib/lib.sh" "$p" "$h"
      [ "$output" = "unavailable:unsupported:$m" ] || { echo "$h/$m -> $output"; return 1; }
    done
  done

  # Claude and Cursor name no scope at all, so a recorded one is never handed to them.
  jq '.launchScope = "workspace-write"' "$p/.nightshift/shift-policy.json" >"$p/pol.json"
  mv "$p/pol.json" "$p/.nightshift/shift-policy.json"
  for h in claude cursor; do
    run bash -c '. "$1"; ns_recovery_effective_scope "$2" "$3"' _ "$BATS_TEST_DIRNAME/../plugins/nightshift/lib/lib.sh" "$p" "$h"
    [ "$output" = "unavailable:unsupported:workspace-write" ] || { echo "$h -> $output"; return 1; }
  done
}

@test "the Codex watchman stops the ladder when it cannot reproduce the recorded scope" {
  codex="$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/codex/watchman.sh"
  # It refuses rather than spawns, says what the owner can do about it, and does not spend the
  # remaining rungs re-asking a question whose answer cannot change.
  grep -qF 'unavailable:*' "$codex"
  grep -qF 'RECOVERY_REFUSED=1' "$codex"
  grep -qF 'recovery-scope-unavailable' "$codex"
  grep -qF 'ns_recovery_repair' "$codex"
  grep -qF 'recovery.launchScope to host-default' "$BATS_TEST_DIRNAME/../plugins/nightshift/lib/state.sh"
  if grep -qF 'danger-full-access' "$codex"; then return 1; fi
}

@test "the Codex and Cursor revivals ask for the scope rather than assuming one" {
  codex="$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/codex/watchman.sh"
  cursor="$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/cursor/watchman.sh"
  win="$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/windows/watchman.ps1"
  for f in "$codex" "$cursor"; do
    grep -qF 'ns_recovery_effective_scope' "$f" || { echo "$f assumes a scope"; return 1; }
    grep -qF 'reviving under launch scope' "$f" || { echo "$f does not say which scope"; return 1; }
  done
  # The recorded scope is passed through rather than replaced by the broad one.
  grep -qF 'recorded:*' "$codex"
  grep -qF 'Get-NSRecoveryEffectiveScope' "$win"
  grep -qF 'reviving under launch scope' "$win"
  if grep -qE -- '--dangerously-skip-permissions|--yolo|--trust|danger-full-access' "$win"; then return 1; fi
  grep -qF 'unavailable:*' "$win"
  # And Windows CI runs the resolver suite that proves it, rather than assuming parity.
  logic="$BATS_TEST_DIRNAME/windows/recovery-scope-logic.ps1"
  [ -f "$logic" ]
  grep -qF 'recovery-scope-logic.ps1' "$BATS_TEST_DIRNAME/windows/run.ps1"
}

@test "Windows resolves the recovery scope the same way POSIX does" {
  if ! command -v pwsh >/dev/null 2>&1; then
    return 0
  fi
  run pwsh -NoProfile -NonInteractive -File "$BATS_TEST_DIRNAME/windows/recovery-scope-logic.ps1"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "a quoted API error is text about a failure, not the host reporting one" {
  # The shipped tell requires the host's own marker on the line, so the check below is the
  # program that actually runs and not a copy of it that could drift.
  W="$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/claude/watchman.sh"
  awk '/^api_limited_tail\(\)/, /^}/' "$W" | grep -qF 'isApiErrorMessage' \
    || { echo "the outage tell no longer requires the host marker"; return 1; }
  awk '/^api_limited_tail\(\)/, /^}/' "$W" | grep -qF 'tolower($0) ~ /error' \
    && { echo "the outage tell still reads any line that mentions an error"; return 1; }

  # The same words a person can type, with no marker from the host: the ordinary interval stands.
  T="$BATS_TEST_TMPDIR/quoted"
  mkdir -p "$T"
  printf '%s\n' '{"type":"user","message":{"content":[{"type":"tool_result","content":"API Error: 429 rate_limit_error"}]}}' >"$T/shift.jsonl"
  run bash -c '
    tail -n 25 "$1" | awk "
      /[^\\\\]\"isApiErrorMessage\"[[:space:]]*:[[:space:]]*true/ { last = tolower(\$0) }
      END {
        exit (last ~ /(rate|usage)[ _-]?limit/ ||
              last ~ /(^|[^0-9])(429|529)([^0-9]|\$)/ ||
              last ~ /(^|[^a-z])api([^a-z]|\$)/) ? 0 : 1
      }"' _ "$T/shift.jsonl"
  [ "$status" -ne 0 ]
  # The host marking its own API error is evidence, and still is.
  printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"API Error: 429 rate_limit_error"}]},"isApiErrorMessage":true,"apiErrorStatus":429}' >>"$T/shift.jsonl"
  run bash -c '
    tail -n 25 "$1" | awk "
      /[^\\\\]\"isApiErrorMessage\"[[:space:]]*:[[:space:]]*true/ { last = tolower(\$0) }
      END {
        exit (last ~ /(rate|usage)[ _-]?limit/ ||
              last ~ /(^|[^0-9])(429|529)([^0-9]|\$)/ ||
              last ~ /(^|[^a-z])api([^a-z]|\$)/) ? 0 : 1
      }"' _ "$T/shift.jsonl"
  [ "$status" -eq 0 ]
}

# A usage limit is a wedge like any other and is revived, unless the owner turned that off: then
# the limit is recorded and the shift waits for them.
@test "watchAfterUsageLimit false holds a usage-limit wedge for the owner" {
  T="$BATS_TEST_TMPDIR/transcripts"
  mkdir -p "$T"
  printf '%s\n' \
    '{"type":"assistant","message":{"model":"<synthetic>","content":[{"type":"text","text":"Claude AI usage limit reached"}]},"error":"rate_limit","isApiErrorMessage":true}' \
    >"$T/shift.jsonl"
  start="$(ps -o lstart= -p $$ | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  printf 'sid-shift\n%s\n%s\n%s\n' "$T/shift.jsonl" "$$" "$start" >"$P/.nightshift/.shift-session"
  jq '.watchAfterUsageLimit = false' "$P/.nightshift/rules.json" >"$P/.nightshift/r.json"
  mv "$P/.nightshift/r.json" "$P/.nightshift/rules.json"
  run env NIGHTSHIFT_WATCH_SLEEP=0 NIGHTSHIFT_WATCH_RETRY="0 0" NIGHTSHIFT_WATCH_TRANSCRIPTS="$T" \
    "$WATCHMAN" --project "$P" --interval 20 --agent "bash $BIN/tick.sh" --max-wakes 2
  [ "$(calls)" -eq 0 ]
  [ "$(sed -n 1p "$P/.nightshift/.watch-reason")" = usage-limit ]
  [ "$(grep -c 'revival after a usage limit is off' "$P/.nightshift/shift-log.md")" -eq 1 ]
}

# A missing Nightshift program is that file, not an unreadable policy and not a silent inherit.
@test "a missing jq filter is reported as a missing Nightshift file" {
  copy="$BATS_TEST_TMPDIR/jq-missing"
  cp -R "$BATS_TEST_DIRNAME/../plugins/nightshift" "$copy"
  rm -f "$copy/lib/policy-emit.jq"
  jq -n '{schemaVersion:1,shiftId:"9f2c40ab77e51d63",createdAt:"2026-09-02T00:00:00Z",source:"composition",verificationLevel:"none",toolingPolicy:"existing-tools"}' \
    >"$P/.nightshift/shift-policy.json"
  jq 'del(.recovery)' "$P/.nightshift/rules.json" >"$P/.nightshift/r.json"
  mv "$P/.nightshift/r.json" "$P/.nightshift/rules.json"
  run bash -c '. "$1"; ns_recovery_effective_scope "$2" claude; printf "\n"; ns_recovery_refusal "$(ns_recovery_effective_scope "$2" claude)"' _ "$copy/lib/lib.sh" "$P"
  printf '%s\n' "$output" | grep -qF 'Nightshift file missing:'
  printf '%s\n' "$output" | grep -qF 'policy-emit.jq'
  printf '%s\n' "$output" | grep -qv 'cannot be read'
  printf '%s\n' "$output" | grep -qv 'inherit-recorded-scope'
}

@test "a host-default that cannot be read is not replaced by inherit-recorded-scope" {
  copy="$BATS_TEST_TMPDIR/awk-missing"
  cp -R "$BATS_TEST_DIRNAME/../plugins/nightshift" "$copy"
  rm -f "$copy/lib/rules-read.awk"
  run bash -c '. "$1"; ns_recovery_launch_scope "$2"' _ "$copy/lib/lib.sh" "$P"
  printf '%s\n' "$output" | grep -q '^unavailable:missing-file:'
  printf '%s\n' "$output" | grep -qF 'rules-read.awk'
  printf '%s\n' "$output" | grep -qv 'inherit-recorded-scope'
  run bash -c '. "$1"; ns_recovery_effective_scope "$2" claude; ns_recovery_refusal "$(ns_recovery_effective_scope "$2" claude)"' _ "$copy/lib/lib.sh" "$P"
  printf '%s\n' "$output" | grep -qF 'Nightshift file missing:'
  printf '%s\n' "$output" | grep -qF 'rules-read.awk'
  printf '%s\n' "$output" | grep -qv 'cannot be read'
  printf '%s\n' "$output" | grep -qv 'set recovery.launchScope to host-default'
}

# Point the host's own plugin record at a replacement install.
plant_host_install() { # host home root
  case "$1" in
    claude)
      mkdir -p "$2/.claude/plugins"
      jq -n --arg p "$3" '{version:2,plugins:{"nightshift@nightshift":[{installPath:$p}]}}' \
        >"$2/.claude/plugins/installed_plugins.json"
      ;;
    codex)
      mkdir -p "$2/.codex"
      printf '[plugins."nightshift@nightshift"]\nenabled = true\n' >"$2/.codex/config.toml"
      rm -rf "$2/.codex/plugins/cache/nightshift/nightshift/9.9.9"
      mkdir -p "$2/.codex/plugins/cache/nightshift/nightshift"
      cp -R "$3" "$2/.codex/plugins/cache/nightshift/nightshift/9.9.9"
      ;;
    cursor)
      rm -rf "$2/.cursor/plugins/cache/fixture/nightshift/rev"
      mkdir -p "$2/.cursor/plugins/cache/fixture/nightshift"
      cp -R "$3" "$2/.cursor/plugins/cache/fixture/nightshift/rev"
      ;;
  esac
}

host_install_root() { # host home planted-root
  case "$1" in
    claude) printf '%s' "$3" ;;
    codex) printf '%s' "$2/.codex/plugins/cache/nightshift/nightshift/9.9.9" ;;
    cursor) printf '%s' "$2/.cursor/plugins/cache/fixture/nightshift/rev" ;;
  esac
}

phys_dir() { (cd -P "$1" && pwd); }

wait_watchman_armed() {
  local _
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40 41 42 43 44 45 46 47 48 49 50; do
    if [ -f "$P/.nightshift/shift-log.md" ] && grep -q 'armed · every' "$P/.nightshift/shift-log.md"; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

@test "a removed install re-runs from the host record and revives" {
  src="$BATS_TEST_DIRNAME/../plugins/nightshift"
  for host in claude codex cursor; do
    rm -f "$P/.nightshift/agent-calls" "$P/.nightshift/shift-log.md" "$P/.nightshift/parking-lot.md" "$P/.nightshift/.watchman" "$P/.nightshift/.hook-copies" "$P/.nightshift/.ended" "$P/.nightshift/.session-end"
    : >"$P/.nightshift/.shift-armed"
    printf '%s sid\n' "$(($(date +%s) - 3000))" >"$P/.nightshift/.shift-pulse"
    printf 'sid\n\n\n\n%s\n' "$host" >"$P/.nightshift/.shift-session"
    printf '## Items\n- [ ] **1.**\n' >"$P/.nightshift/punch-list.md"
    old="$BATS_TEST_TMPDIR/old-$host"
    new="$BATS_TEST_TMPDIR/new-$host"
    home="$BATS_TEST_TMPDIR/home-$host"
    rm -rf "$old" "$new" "$home"
    cp -R "$src" "$old"
    cp -R "$src" "$new"
    oldv="$(sed -n 's/^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$new/.claude-plugin/plugin.json" | head -n1)"
    sed "s/\"version\": \"$oldv\"/\"version\": \"9.9.9\"/" "$new/.claude-plugin/plugin.json" >"$new/.claude-plugin/plugin.json.new"
    mv "$new/.claude-plugin/plugin.json.new" "$new/.claude-plugin/plugin.json"
    plant_host_install "$host" "$home" "$new"
    current="$(phys_dir "$(host_install_root "$host" "$home" "$new")")"
    env HOME="$home" NIGHTSHIFT_WATCH_SLEEP=2 NIGHTSHIFT_WATCH_RETRY="0 0" \
      "$old/runtime/$host/watchman.sh" --project "$P" --interval 20 --agent "bash $BIN/tick.sh" --max-wakes 2 &
    child=$!
    wait_watchman_armed
    rm -rf "$old"
    wait "$child" || true
    echo "host $host log:"
    cat "$P/.nightshift/shift-log.md"
    grep -qF "re-running 9.9.9 at $current" "$P/.nightshift/shift-log.md"
    grep -qF "$oldv" "$P/.nightshift/shift-log.md"
    [ "$(calls)" -ge 1 ]
    if [ -f "$P/.nightshift/parking-lot.md" ]; then
      grep -qv 'no current install' "$P/.nightshift/parking-lot.md"
    fi
  done
}

@test "a hooks copy with a different version re-runs once from that copy" {
  src="$BATS_TEST_DIRNAME/../plugins/nightshift"
  old="$BATS_TEST_TMPDIR/hooks-old"
  new="$BATS_TEST_TMPDIR/hooks-new"
  rm -rf "$old" "$new"
  cp -R "$src" "$old"
  cp -R "$src" "$new"
  oldv="$(sed -n 's/^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$new/.claude-plugin/plugin.json" | head -n1)"
  sed "s/\"version\": \"$oldv\"/\"version\": \"9.9.9\"/" "$new/.claude-plugin/plugin.json" >"$new/.claude-plugin/plugin.json.new"
  mv "$new/.claude-plugin/plugin.json.new" "$new/.claude-plugin/plugin.json"
  new="$(phys_dir "$new")"
  printf 'sid\n\n\n\nclaude\n' >"$P/.nightshift/.shift-session"
  printf '100\tclaude\tsid\t%s\t9.9.9\n' "$new" >"$P/.nightshift/.hook-copies"
  rm -f "$P/.nightshift/agent-calls" "$P/.nightshift/shift-log.md" "$P/.nightshift/parking-lot.md"
  printf '## Items\n- [ ] **1.**\n' >"$P/.nightshift/punch-list.md"
  env HOME="$BATS_TEST_TMPDIR/empty-home" NIGHTSHIFT_WATCH_SLEEP=0 NIGHTSHIFT_WATCH_RETRY="0 0" \
    "$old/runtime/claude/watchman.sh" --project "$P" --interval 20 --agent "bash $BIN/tick.sh" --max-wakes 2
  grep -qF "is not the hooks' copy 9.9.9 at $new" "$P/.nightshift/shift-log.md"
  [ "$(grep -c "re-running from the hooks' copy" "$P/.nightshift/shift-log.md")" -eq 1 ]
  [ "$(calls)" -ge 1 ]
  if [ -f "$P/.nightshift/parking-lot.md" ]; then
    grep -qv 'cannot be used' "$P/.nightshift/parking-lot.md"
  fi
}

@test "no current install stands down once after the confirming wake" {
  src="$BATS_TEST_DIRNAME/../plugins/nightshift"
  old="$BATS_TEST_TMPDIR/gone-old"
  home="$BATS_TEST_TMPDIR/gone-home"
  rm -rf "$old" "$home"
  mkdir -p "$home"
  cp -R "$src" "$old"
  printf 'sid\n\n\n\nclaude\n' >"$P/.nightshift/.shift-session"
  rm -f "$P/.nightshift/agent-calls" "$P/.nightshift/shift-log.md" "$P/.nightshift/parking-lot.md"
  printf '## Items\n- [ ] **1.**\n' >"$P/.nightshift/punch-list.md"
  env HOME="$home" NIGHTSHIFT_WATCH_SLEEP=1 NIGHTSHIFT_WATCH_RETRY="0 0" \
    "$old/runtime/claude/watchman.sh" --project "$P" --interval 20 --max-wakes 4 &
  child=$!
  wait_watchman_armed
  rm -rf "$old"
  wait "$child" || true
  [ "$(grep -c 'checking once more on the next wake' "$P/.nightshift/shift-log.md")" -eq 1 ]
  [ "$(grep -c 'standing down' "$P/.nightshift/shift-log.md")" -eq 1 ]
  [ "$(grep -c 'no current install' "$P/.nightshift/parking-lot.md")" -eq 1 ]
  [ ! -f "$P/.nightshift/agent-calls" ]
  grep -qv 'cannot be read' "$P/.nightshift/shift-log.md"
}

@test "a watchman whose script is gone names the removed install" {
  mkdir -p "$BATS_TEST_TMPDIR/empty-home"
  printf '99\nscript:%s/no/watchman.sh\nversion:0.30.1\n' "$BATS_TEST_TMPDIR" >"$P/.nightshift/.watchman"
  printf 'sid\n\n\n\nclaude\n' >"$P/.nightshift/.shift-session"
  run env HOME="$BATS_TEST_TMPDIR/empty-home" bash -c \
    '. "$1"; ns_watchman_removed_sentence "$2" "$3" 99' _ \
    "$BATS_TEST_DIRNAME/../plugins/nightshift/lib/lib.sh" "$P/.nightshift" "$P/.nightshift/.watchman"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qF 'watchman running from a removed install (version 0.30.1)'
  printf '%s\n' "$output" | grep -qF 'current install is none'
  printf '%s\n' "$output" | grep -qF 'kill 99'
}

@test "a Cursor launch record keeps the model and does not grow flags" {
  p="$(new_project cursor-launch-record)"
  lib="$BATS_TEST_DIRNAME/../plugins/nightshift/lib/lib.sh"
  out="$BATS_TEST_TMPDIR/launch-read"
  donef="$BATS_TEST_TMPDIR/launch-done"
  script="$BATS_TEST_TMPDIR/launch-note.sh"
  jq '.recovery.cursorFlags = ["--trust", "--sandbox"]' "$p/.nightshift/rules.json" >"$p/r.json"
  mv "$p/r.json" "$p/.nightshift/rules.json"
  rm -f "$out" "$donef"
  cat >"$script" <<EOF
#!/bin/bash
. "$lib"
ns_cursor_launch_note "$p/.nightshift" '{"model_id":"composer-2","model":"other"}'
ns_cursor_launch_read "$p/.nightshift" >"$out"
touch "$donef"
EOF
  chmod +x "$script"
  python3 -c '
import os, sys
if os.fork() > 0:
    os.wait()
    raise SystemExit(0)
if os.fork() > 0:
    os._exit(0)
os.setsid()
os.execv(sys.argv[1], [sys.argv[1]])
' "$script"
  i=0
  while [ ! -f "$donef" ] && [ "$i" -lt 50 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -f "$donef" ]
  [ "$(head -n 1 "$out")" = "$(printf '\t0\t1\t0\t1\t1')" ]
  if grep -q 'composer-2' "$p/.nightshift/.cursor-launch"; then return 1; fi
  jq '.recovery.cursorFlags = ["--force", "--trust"]' "$p/.nightshift/rules.json" >"$p/r.json"
  mv "$p/r.json" "$p/.nightshift/rules.json"
  run bash -c '. "$1"; ns_cursor_launch_note "$2" "$3"; ns_cursor_launch_read "$2"' _ \
    "$lib" "$p/.nightshift" '{"model_id":"other-model"}'
  [ "$output" = "$(printf '\t0\t1\t0\t1\t1')" ]
}

LIB="$BATS_TEST_DIRNAME/../plugins/nightshift/lib/lib.sh"
IDLE_WORKER=0
IDLE_CHILD=0

stop_idle_worker() {
  if [ "$IDLE_CHILD" != 0 ]; then kill "$IDLE_CHILD" 2>/dev/null || true; fi
  if [ "$IDLE_WORKER" != 0 ]; then kill "$IDLE_WORKER" 2>/dev/null || true; fi
  if [ "$IDLE_WORKER" != 0 ]; then wait "$IDLE_WORKER" 2>/dev/null || true; fi
  IDLE_WORKER=0
  IDLE_CHILD=0
}

begin_idle_worker() { # sleep | cpu | busy
  local kind="$1" childf _
  stop_idle_worker
  childf="$BATS_TEST_TMPDIR/idle-child"
  rm -f "$childf"
  case "$kind" in
    sleep)
      bash -c 'sleep 60 & echo $! >"$1"; wait' _ "$childf" &
      ;;
    cpu)
      bash -c 'while :; do :; done' &
      ;;
    busy)
      # Linux reports the executable's name; macOS reports the name set with exec -a.
      case "$(uname -s)" in
        Linux)
          cp /bin/sleep "$BATS_TEST_TMPDIR/npm"
          bash -c '"$1" 60 & echo $! >"$2"; wait' _ "$BATS_TEST_TMPDIR/npm" "$childf" &
          ;;
        *)
          bash -c 'exec -a npm /bin/sleep 60 & echo $! >"$1"; wait' _ "$childf" &
          ;;
      esac
      ;;
  esac
  IDLE_WORKER=$!
  if [ "$kind" != cpu ]; then
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
      [ -s "$childf" ] && break
      sleep 0.05
    done
    IDLE_CHILD="$(tr -d '[:space:]' <"$childf")"
  fi
  kill -0 "$IDLE_WORKER"
}

plant_idle_session() { # host [transcript]
  local start transcript="${2:-}"
  start="$(ps -o lstart= -p "$IDLE_WORKER" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  printf 'sid-shift\n%s\n%s\n%s\n%s\n' "$transcript" "$IDLE_WORKER" "$start" "$1" \
    >"$P/.nightshift/.shift-session"
  printf '%s sid-shift\n' "$(($(date +%s) - 100000))" >"$P/.nightshift/.shift-pulse"
}

seed_idle_due() {
  local now
  now="$(date +%s)"
  printf 'since=%s\ncpu=0\nbytes=0\npids=%s\nfails=0\nepisode=0\nstuck=0\nnoticed=0\nevidence=seed\n' \
    "$((now - 180))" "$IDLE_WORKER" >"$P/.nightshift/.idle-watch"
}

seed_idle_open() {
  local now
  now="$(date +%s)"
  printf 'since=%s\ncpu=0\nbytes=0\npids=%s\nfails=0\nepisode=0\nstuck=0\nnoticed=0\nevidence=seed\n' \
    "$now" "$IDLE_WORKER" >"$P/.nightshift/.idle-watch"
}

reset_idle_site() {
  rm -f "$P/.nightshift/agent-calls" "$P/.nightshift/shift-log.md" "$P/.nightshift/.watchman" \
    "$P/.nightshift/.ended" "$P/.nightshift/.shift-lease" "$P/.nightshift/parking-lot.md"
  printf '## Items\n- [ ] **1.**\n' >"$P/.nightshift/punch-list.md"
  : >"$P/.nightshift/.shift-armed"
}

worker_alive() { kill -0 "$IDLE_WORKER" 2>/dev/null; }

@test "the idle verdict waits out the window and treats every busy signal as life" {
  run bash -c '. "$1"; ns_idle_verdict stale 0 1 0 0 1000 1030 1 0' _ "$LIB"
  [ "$output" = pending ]
  run bash -c '. "$1"; ns_idle_verdict stale 0 1 0 0 1000 1060 1 0' _ "$LIB"
  [ "$output" = due ]
  run bash -c '. "$1"; ns_idle_verdict fresh 0 1 0 0 1000 9999 1 0' _ "$LIB"
  [ "$output" = busy ]
  run bash -c '. "$1"; ns_idle_verdict stale 1 1 0 0 1000 9999 1 0' _ "$LIB"
  [ "$output" = busy ]
  run bash -c '. "$1"; ns_idle_verdict stale 0 1 0 1 1000 9999 1 0' _ "$LIB"
  [ "$output" = busy ]
  run bash -c '. "$1"; ns_idle_verdict stale 0 1 100 0 1000 9999 1 0' _ "$LIB"
  [ "$output" = busy ]
  run bash -c '. "$1"; ns_idle_verdict stale 0 0 0 0 1000 9999 1 0' _ "$LIB"
  [ "$output" = unavailable ]
  run bash -c '. "$1"; ns_idle_verdict stale 0 1 0 0 1000 9999 1 1' _ "$LIB"
  [ "$output" = stuck ]
}

@test "an idle live worker is stopped after the window and revived on every host" {
  for host in cursor codex claude; do
    begin_idle_worker sleep
    plant_idle_session "$host"
    seed_idle_due
    reset_idle_site
    run env NIGHTSHIFT_WATCH_SLEEP=0 NIGHTSHIFT_WATCH_RETRY="0" NIGHTSHIFT_IDLE_WINDOW=1 \
      NIGHTSHIFT_IDLE_GRACE=0 \
      "$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/$host/watchman.sh" \
      --project "$P" --interval 20 --agent "bash $BIN/tick.sh" --max-wakes 1
    if worker_alive; then
      echo "$host left the idle worker running"
      printf '%s\n' "$output"
      cat "$P/.nightshift/shift-log.md" 2>/dev/null || true
      stop_idle_worker
      return 1
    fi
    [ "$(calls)" -eq 1 ] || { echo "$host calls=$(calls)"; cat "$P/.nightshift/shift-log.md"; stop_idle_worker; return 1; }
    grep -q 'worker alive but idle' "$P/.nightshift/shift-log.md" \
      || { echo "$host did not log the idle evidence"; cat "$P/.nightshift/shift-log.md"; stop_idle_worker; return 1; }
    lease_pid="$(sed -n 5p "$P/.nightshift/.shift-lease" 2>/dev/null | tr -d '[:space:]')"
    [ -n "$lease_pid" ] && [ "$lease_pid" != "$IDLE_WORKER" ] \
      || { echo "$host lease was not transferred (pid '$lease_pid')"; stop_idle_worker; return 1; }
    if [ "$IDLE_CHILD" != 0 ] && kill -0 "$IDLE_CHILD" 2>/dev/null; then
      echo "$host left the idle child running"
      stop_idle_worker
      return 1
    fi
    stop_idle_worker
  done
}

@test "a worker inside the idle window is not stopped" {
  begin_idle_worker sleep
  plant_idle_session cursor
  seed_idle_open
  reset_idle_site
  run env NIGHTSHIFT_WATCH_SLEEP=0 NIGHTSHIFT_WATCH_RETRY="0" NIGHTSHIFT_IDLE_WINDOW=1 \
    NIGHTSHIFT_IDLE_GRACE=0 \
    "$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/cursor/watchman.sh" \
    --project "$P" --interval 20 --agent "bash $BIN/tick.sh" --max-wakes 1
  worker_alive || { echo "stopped inside the window"; cat "$P/.nightshift/shift-log.md"; stop_idle_worker; return 1; }
  [ "$(calls)" -eq 0 ]
  [ -f "$P/.nightshift/.idle-watch" ]
  stop_idle_worker
}

@test "a quiet worker that burns CPU is not stopped" {
  begin_idle_worker cpu
  local _ cents t
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    t="$(ps -o time= -p "$IDLE_WORKER" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    cents="$(bash -c '. "$1"; ns_cpu_centiseconds "$2"' _ "$LIB" "$t")"
    [ "${cents:-0}" -ge 100 ] && break
    sleep 0.2
  done
  [ "${cents:-0}" -ge 100 ] || { echo "cpu never accumulated ($cents)"; stop_idle_worker; return 1; }
  plant_idle_session cursor
  seed_idle_due
  reset_idle_site
  run env NIGHTSHIFT_WATCH_SLEEP=0 NIGHTSHIFT_WATCH_RETRY="0" NIGHTSHIFT_IDLE_WINDOW=1 \
    NIGHTSHIFT_IDLE_GRACE=0 \
    "$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/cursor/watchman.sh" \
    --project "$P" --interval 20 --agent "bash $BIN/tick.sh" --max-wakes 1
  worker_alive || { echo "stopped a busy worker"; cat "$P/.nightshift/shift-log.md"; stop_idle_worker; return 1; }
  [ "$(calls)" -eq 0 ]
  [ ! -f "$P/.nightshift/.idle-watch" ]
  stop_idle_worker
}

@test "a fresh pulse or a growing transcript keeps an idle-looking worker" {
  begin_idle_worker sleep
  plant_idle_session cursor
  seed_idle_due
  printf '%s sid-shift\n' "$(date +%s)" >"$P/.nightshift/.shift-pulse"
  reset_idle_site
  run env NIGHTSHIFT_WATCH_SLEEP=0 NIGHTSHIFT_WATCH_RETRY="0" NIGHTSHIFT_IDLE_WINDOW=1 \
    NIGHTSHIFT_IDLE_GRACE=0 \
    "$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/cursor/watchman.sh" \
    --project "$P" --interval 20 --agent "bash $BIN/tick.sh" --max-wakes 1
  worker_alive || { echo "fresh pulse did not protect the worker"; cat "$P/.nightshift/shift-log.md"; stop_idle_worker; return 1; }
  [ "$(calls)" -eq 0 ]
  stop_idle_worker

  T="$BATS_TEST_TMPDIR/idle-transcript"
  mkdir -p "$T"
  printf 'one\n' >"$T/out.jsonl"
  begin_idle_worker sleep
  plant_idle_session cursor "$T/out.jsonl"
  seed_idle_due
  reset_idle_site
  ( sleep 0.2; printf 'two\n' >>"$T/out.jsonl" ) &
  writer=$!
  run env NIGHTSHIFT_WATCH_SLEEP=1 NIGHTSHIFT_WATCH_RETRY="0" NIGHTSHIFT_IDLE_WINDOW=1 \
    NIGHTSHIFT_IDLE_GRACE=0 \
    "$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/cursor/watchman.sh" \
    --project "$P" --interval 20 --agent "bash $BIN/tick.sh" --max-wakes 1
  wait "$writer" 2>/dev/null || true
  worker_alive || { echo "transcript growth did not protect the worker"; cat "$P/.nightshift/shift-log.md"; stop_idle_worker; return 1; }
  [ "$(calls)" -eq 0 ]
  stop_idle_worker
}

@test "a build child keeps the worker, and two failed revivals park one notice" {
  begin_idle_worker busy
  plant_idle_session cursor
  seed_idle_due
  reset_idle_site
  run env NIGHTSHIFT_WATCH_SLEEP=0 NIGHTSHIFT_WATCH_RETRY="0" NIGHTSHIFT_IDLE_WINDOW=1 \
    NIGHTSHIFT_IDLE_GRACE=0 \
    "$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/cursor/watchman.sh" \
    --project "$P" --interval 20 --agent "bash $BIN/tick.sh" --max-wakes 1
  worker_alive || { echo "stopped a worker with a busy child"; cat "$P/.nightshift/shift-log.md"; stop_idle_worker; return 1; }
  [ "$(calls)" -eq 0 ]
  stop_idle_worker

  begin_idle_worker sleep
  plant_idle_session cursor
  seed_idle_due
  reset_idle_site
  run env NIGHTSHIFT_WATCH_SLEEP=0 NIGHTSHIFT_WATCH_RETRY="0" NIGHTSHIFT_IDLE_WINDOW=1 \
    NIGHTSHIFT_IDLE_GRACE=0 \
    "$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/cursor/watchman.sh" \
    --project "$P" --interval 20 --agent "bash $BIN/fail.sh" --max-wakes 3
  [ "$(calls)" -eq 4 ] || { echo "calls=$(calls)"; cat "$P/.nightshift/shift-log.md"; stop_idle_worker; return 1; }
  [ "$(grep -c 'revival failed twice' "$P/.nightshift/parking-lot.md")" -eq 1 ]
  stop_idle_worker
}
