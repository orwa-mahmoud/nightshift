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
  echo 'clean session end (exit)' >"$P/.nightshift/.session-end"
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
STUB
  chmod +x "$BIN/lease-env.sh"

  run watch --agent "bash $BIN/lease-env.sh" --max-wakes 1
  [ "$status" -eq 7 ]
  [ -n "$(sed -n 1p "$P/.nightshift/lease-env")" ]
  [ "$(sed -n 1p "$P/.nightshift/lease-env")" = "$(sed -n 3p "$P/.nightshift/.shift-lease")" ]
  [ "$(sed -n 2p "$P/.nightshift/lease-env")" = "$(sed -n 4p "$P/.nightshift/.shift-lease")" ]
  sed -n 5p "$P/.nightshift/.shift-lease" | grep -qE '^[0-9]+$'
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
  grep -qF ' · clean session end' "$BATS_TEST_DIRNAME/../plugins/nightshift/hooks/windows/session-end.ps1"
  if grep -qF ' - clean session end' "$BATS_TEST_DIRNAME/../plugins/nightshift/hooks/windows/session-end.ps1"; then
    return 1
  fi
  grep -qF '[ -L "$NS/.session-end" ]' "$BATS_TEST_DIRNAME/../plugins/nightshift/hooks/session-end.sh"
  grep -qF 'Test-NSReparsePoint $sessionEnd' "$BATS_TEST_DIRNAME/../plugins/nightshift/hooks/windows/session-end.ps1"
  grep -qF '[ ! -L "$NS/.shift-session" ]' "$BATS_TEST_DIRNAME/../plugins/nightshift/hooks/session-end.sh"
}

@test "session-end hook writes the marker only during an active shift" {
  p="$(new_project)"
  punch_open "$p"
  printf '{"reason":"exit"}' | CLAUDE_PROJECT_DIR="$p" bash "$SESSION_END"
  grep -q 'clean session end (exit)' "$p/.nightshift/.session-end"
}

@test "session-end hook replaces a symlink marker with a regular file" {
  p="$(new_project)"
  punch_open "$p"
  printf 'plant\n' >"$p/.nightshift/session-end-plant"
  ln -s session-end-plant "$p/.nightshift/.session-end"
  printf '{"reason":"exit"}' | CLAUDE_PROJECT_DIR="$p" bash "$SESSION_END"
  [ -f "$p/.nightshift/.session-end" ]
  [ ! -L "$p/.nightshift/.session-end" ]
  grep -q 'clean session end (exit)' "$p/.nightshift/.session-end"
}

@test "session-end hook is inert while the shift is unarmed" {
  p="$(new_project)"
  punch_open "$p"
  rm "$p/.nightshift/.shift-armed"
  printf '{"reason":"exit"}' | CLAUDE_PROJECT_DIR="$p" bash "$SESSION_END"
  [ ! -f "$p/.nightshift/.session-end" ]
}

@test "session-end ignores an open checkbox outside the Items list" {
  p="$(new_project)"
  touch "$p/.nightshift/.shift-armed"
  printf '%s\n' '- [ ] planning example' '## Items' '- [x] **1. done.**' >"$p/.nightshift/punch-list.md"
  printf '{"reason":"exit"}' | CLAUDE_PROJECT_DIR="$p" bash "$SESSION_END"
  [ ! -f "$p/.nightshift/.session-end" ]
}

@test "session-end hook is inert when the shift is done or absent" {
  p="$(new_project)"
  punch_done "$p"
  printf '{"reason":"exit"}' | CLAUDE_PROJECT_DIR="$p" bash "$SESSION_END"
  [ ! -f "$p/.nightshift/.session-end" ]
  q="$(new_project other)"
  printf '{"reason":"exit"}' | CLAUDE_PROJECT_DIR="$q" bash "$SESSION_END"
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
  printf '{"reason":"exit","session_id":"wrong-id"}' | CLAUDE_PROJECT_DIR="$p" bash "$SESSION_END"
  [ ! -f "$p/.nightshift/.session-end" ]
  printf '{"reason":"exit","session_id":"right-id"}' | CLAUDE_PROJECT_DIR="$p" bash "$SESSION_END"
  grep -q 'clean session end (exit)' "$p/.nightshift/.session-end"
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
  printf '{"reason":"exit","session_id":"right-id"}' |
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

# One copy: the watchman reads its orders from the rules file; env stays the override.
@test "the revival order is read from the rules file" {
  jq '.revivalPrompt = "weld from the file"' \
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
  echo 'clean session end (exit)' >"$P/.nightshift/.session-end"
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

  # With nothing recorded, inheriting cannot mean the broad grant: it falls back to the host's
  # own default. A scope nobody observed is never assumed.
  run bash -c '. "$1"; ns_recovery_effective_scope "$2" codex' _ "$BATS_TEST_DIRNAME/../plugins/nightshift/lib/lib.sh" "$p"
  [ "$output" = host-default ]

  # With the scope the arming session actually reported, that is what a revival asks for.
  jq -n '{schemaVersion: 1, shiftId: "9f2c40ab77e51d63", createdAt: "2026-09-02T00:00:00Z",
          source: "composition", verificationLevel: "none", toolingPolicy: "existing-tools",
          launchScope: "workspace-write", launchProvenance: "observed"}' \
    >"$p/.nightshift/shift-policy.json"
  run bash -c '. "$1"; ns_recovery_effective_scope "$2" codex' _ "$BATS_TEST_DIRNAME/../plugins/nightshift/lib/lib.sh" "$p"
  [ "$output" = "recorded:workspace-write" ]

  # A scope the host never reported stays unavailable, and the fallback is still the narrow one.
  jq '.launchProvenance = "unavailable" | .launchScope = "unknown"' \
    "$p/.nightshift/shift-policy.json" >"$p/pol.json"
  mv "$p/pol.json" "$p/.nightshift/shift-policy.json"
  run bash -c '. "$1"; ns_recovery_effective_scope "$2" codex' _ "$BATS_TEST_DIRNAME/../plugins/nightshift/lib/lib.sh" "$p"
  [ "$output" = host-default ]

  # The broad grant happens only because the owner wrote it in their own file.
  jq '.recovery.launchScope = "host-grant"' "$p/.nightshift/rules.json" >"$p/r.json"
  mv "$p/r.json" "$p/.nightshift/rules.json"
  run bash -c '. "$1"; ns_recovery_effective_scope "$2" codex' _ "$BATS_TEST_DIRNAME/../plugins/nightshift/lib/lib.sh" "$p"
  [ "$output" = host-grant ]

  # And the narrowest choice is still available by name.
  jq '.recovery.launchScope = "host-default"' "$p/.nightshift/rules.json" >"$p/r.json"
  mv "$p/r.json" "$p/.nightshift/rules.json"
  run bash -c '. "$1"; ns_recovery_effective_scope "$2" codex' _ "$BATS_TEST_DIRNAME/../plugins/nightshift/lib/lib.sh" "$p"
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
  run bash -c '. "$1"; ns_recovery_effective_scope "$2" codex' _ "$BATS_TEST_DIRNAME/../plugins/nightshift/lib/lib.sh" "$p"
  [ "$output" = host-default ]
}

@test "what the host reports is what gets recorded, and silence is not a scope" {
  run bash -c '. "$1"; CODEX_SANDBOX_MODE=workspace-write ns_launch_observed codex' _ "$BATS_TEST_DIRNAME/../plugins/nightshift/lib/lib.sh"
  [ "$output" = "$(printf 'workspace-write\tobserved')" ]
  run bash -c '. "$1"; unset CODEX_SANDBOX_MODE CODEX_SANDBOX; ns_launch_observed codex' _ "$BATS_TEST_DIRNAME/../plugins/nightshift/lib/lib.sh"
  [ "$output" = "$(printf 'unknown\tunavailable')" ]
  # Claude Code and Cursor hand a session its permissions at launch and name none of it.
  run bash -c '. "$1"; ns_launch_observed claude' _ "$BATS_TEST_DIRNAME/../plugins/nightshift/lib/lib.sh"
  [ "$output" = "$(printf 'inherited\tobserved')" ]
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
  grep -qF 'Get-NSRecoveryLaunchScope' "$win"
  grep -qF 'reviving under launch scope' "$win"
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
