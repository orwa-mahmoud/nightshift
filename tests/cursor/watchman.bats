load ../helpers

setup() {
  WATCHMAN="$BATS_TEST_DIRNAME/../../plugins/nightshift/runtime/cursor/watchman.sh"
  P="$BATS_TEST_TMPDIR/proj"
  mkdir -p "$P/.nightshift"
  cp "$BATS_TEST_DIRNAME/../../plugins/nightshift/skills/nightshift/references/nightshift-rules-template.json" "$P/.nightshift/rules.json"
  printf '## Items\n- [ ] **1.**\n' >"$P/.nightshift/punch-list.md"
  # Cursor names no scope for a session's permissions, so the shipped inherit setting has nothing
  # to inherit and a revival refuses. A site that means to be revived says which scope a revival
  # may use, and these tests are about reviving.
  jq '.recovery.launchScope = "host-default"' "$P/.nightshift/rules.json" >"$P/.nightshift/r.json"
  mv "$P/.nightshift/r.json" "$P/.nightshift/rules.json"
  : >"$P/.nightshift/.shift-armed"
  printf 'origin-ide\n%s\n\n\ncursor\n' "$BATS_TEST_TMPDIR/origin.jsonl" >"$P/.nightshift/.shift-session"
  : >"$BATS_TEST_TMPDIR/origin.jsonl"

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
  cat >"$BIN/agent" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${AGENT_LOG:-/tmp/agent-argv}"
if [ "$1" = "create-chat" ]; then
  printf 'minted-from-agent\n'
  exit 0
fi
exit 0
STUB
  chmod +x "$BIN"/*.sh "$BIN/agent"
}

watch() {
  env NIGHTSHIFT_WATCH_SLEEP=0 NIGHTSHIFT_WATCH_RETRY="0 0" \
    "$WATCHMAN" --project "$P" --interval 20 --agent "bash $BIN/tick.sh" "$@"
}

calls() { grep -c called "$P/.nightshift/agent-calls" 2>/dev/null || echo 0; }

stale_pulse() {
  local sid="${1:-origin-ide}"
  printf '%s %s\n' "$(($(date +%s) - 100000))" "$sid" >"$P/.nightshift/.shift-pulse"
}

@test "interval 0 is the disabled spelling: exits at once, arms nothing" {
  run "$WATCHMAN" --project "$P" --interval 0
  [ "$status" -eq 0 ]
  [ ! -f "$P/.nightshift/.watchman" ]
}

@test "a claude-owned shift stands the cursor watchman down" {
  printf 'sid\n\n\n\nclaude\n' >"$P/.nightshift/.shift-session"
  run watch --max-wakes 1
  [ "$status" -eq 0 ]
  [ "$(calls)" -eq 0 ]
  grep -q 'owned by claude' "$P/.nightshift/shift-log.md"
}

@test "a clean session end stands it down" {
  echo 'clean session end (user_close)' >"$P/.nightshift/.session-end"
  run watch --agent "bash $BIN/tick.sh" --max-wakes 3
  [ "$status" -eq 0 ]
  grep -q 'the owner closed it' "$P/.nightshift/shift-log.md"
  [ "$(calls)" -eq 0 ]
}

@test "empty pid with no pulse on the first wake stands by" {
  run watch --max-wakes 1
  [ "$status" -eq 0 ]
  [ "$(calls)" -eq 0 ]
  [ ! -f "$P/.nightshift/.shift-worker" ]
  if grep -q 'minting a CLI worker' "$P/.nightshift/shift-log.md"; then
    return 1
  fi
}

@test "a stale pulse with no growth and no session-end mints a CLI worker then resumes it" {
  stale_pulse
  run watch --max-wakes 1
  [ "$status" -eq 0 ]
  [ "$(calls)" -ge 1 ]
  [ "$(cat "$P/.nightshift/.shift-worker")" = "minted-cli-worker" ]
  [ "$(sed -n 1p "$P/.nightshift/.shift-session")" = "origin-ide" ]
  grep -q 'minting a CLI worker' "$P/.nightshift/shift-log.md"
  grep -q 'agent --resume="minted-cli-worker"' "$P/.nightshift/parking-lot.md"
  grep -q 'run this in a terminal' "$P/.nightshift/parking-lot.md"
  grep -q 'ask Nightshift to stop' "$P/.nightshift/parking-lot.md"
}

@test "a missing pulse with an old enough armed marker mints a CLI worker" {
  touch -t 202001010000 "$P/.nightshift/.shift-armed"
  run watch --max-wakes 1
  [ "$status" -eq 0 ]
  [ "$(calls)" -ge 1 ]
  [ "$(cat "$P/.nightshift/.shift-worker")" = "minted-cli-worker" ]
  grep -q 'minting a CLI worker' "$P/.nightshift/shift-log.md"
}

@test "a live lease pid stands by even if the pulse is stale" {
  stale_pulse
  start="$(ps -o lstart= -p $$ | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  printf 'origin-ide\ncursor\n1\n\n%s\n%s\n' "$$" "$start" >"$P/.nightshift/.shift-lease"
  run watch --max-wakes 1
  [ "$status" -eq 0 ]
  [ "$(calls)" -eq 0 ]
  [ ! -f "$P/.nightshift/.shift-worker" ]
}

@test "mint-failed skips create-chat and still resumes an existing worker" {
  stale_pulse
  printf 'kept-cli-worker\n' >"$P/.nightshift/.shift-worker"
  : >"$P/.nightshift/.mint-failed"
  AGENT_LOG="$P/.nightshift/agent-argv"
  run env PATH="$BIN:$PATH" AGENT_LOG="$AGENT_LOG" NIGHTSHIFT_WATCH_SLEEP=0 NIGHTSHIFT_WATCH_RETRY="0 0" \
    "$WATCHMAN" --project "$P" --interval 20 --max-wakes 1
  [ "$status" -eq 0 ]
  [ "$(cat "$P/.nightshift/.shift-worker")" = "kept-cli-worker" ]
  [ -f "$AGENT_LOG" ]
  grep -q 'resume=kept-cli-worker' "$AGENT_LOG"
  if grep -q 'create-chat' "$AGENT_LOG"; then
    return 1
  fi
}

@test "a second wake resumes the stored CLI worker instead of minting again" {
  stale_pulse
  printf 'kept-cli-worker\n' >"$P/.nightshift/.shift-worker"
  run watch --max-wakes 1
  [ "$status" -eq 0 ]
  [ "$(cat "$P/.nightshift/.shift-worker")" = "kept-cli-worker" ]
  grep -q 'resuming CLI worker kept-cli-worker' "$P/.nightshift/shift-log.md"
  if grep -q 'minting a CLI worker' "$P/.nightshift/shift-log.md"; then
    return 1
  fi
}

@test "the live agent binary never receives the origin IDE conversation id" {
  stale_pulse
  AGENT_LOG="$P/.nightshift/agent-argv"
  run env PATH="$BIN:$PATH" AGENT_LOG="$AGENT_LOG" NIGHTSHIFT_WATCH_SLEEP=0 NIGHTSHIFT_WATCH_RETRY="0 0" \
    "$WATCHMAN" --project "$P" --interval 20 --max-wakes 1
  [ "$status" -eq 0 ]
  [ -f "$AGENT_LOG" ]
  grep -q 'create-chat' "$AGENT_LOG"
  grep -q 'resume=minted-from-agent' "$AGENT_LOG"
  if grep -q 'origin-ide' "$AGENT_LOG"; then
    return 1
  fi
  [ "$(cat "$P/.nightshift/.shift-worker")" = "minted-from-agent" ]
}

@test "a CLI-store origin is recorded as the worker without minting a new id" {
  cli_transcript="$BATS_TEST_TMPDIR/.cursor/chats/cli-origin/chat.jsonl"
  mkdir -p "$(dirname "$cli_transcript")"
  : >"$cli_transcript"
  printf 'cli-origin\n%s\n\n\ncursor\n' "$cli_transcript" >"$P/.nightshift/.shift-session"
  stale_pulse cli-origin
  run watch --max-wakes 1
  [ "$status" -eq 0 ]
  [ "$(cat "$P/.nightshift/.shift-worker")" = "cli-origin" ]
  [ "$(sed -n 1p "$P/.nightshift/.shift-session")" = "cli-origin" ]
}

# Disarm is total on every host: with the marker gone there is no shift to revive.
@test "a missing armed marker stands the cursor watchman down" {
  rm -f "$P/.nightshift/.shift-armed"
  run watch --max-wakes 3
  [ "$status" -eq 0 ]
  [ "$(calls)" -eq 0 ]
  grep -qF 'watchman: the armed marker is gone — standing down' "$P/.nightshift/shift-log.md"
  [ "$(sed -n 1p "$P/.nightshift/.watch-reason" | tr -d '[:space:]')" = "owner-disarm" ]
  [ ! -e "$P/.nightshift/.shift-armed" ]
}
