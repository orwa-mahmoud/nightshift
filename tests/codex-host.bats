#!/usr/bin/env bats
# The two Codex hooks nothing else drives: the pulse that records a session is alive, and the
# session end that tells a crash apart from the owner closing the window. Both are read by the
# watchman to decide whether to revive a night, so what they write is the whole point of them.

load helpers

CODEX="$BATS_TEST_DIRNAME/../plugins/nightshift/hooks/codex"

# codex_hook <hook> <project> <session-id> [extra-json] — a Codex payload as the host sends it.
codex_hook() {
  local hook="$1" p="$2" sid="$3" extra="${4:-}"
  [ -n "$extra" ] || extra='{}'
  jq -nc --arg sid "$sid" --arg w "$p" --argjson x "$extra" \
    '{session_id:$sid,cwd:$w} + $x' |
    env CODEX_PROJECT_DIR="$p" bash "$CODEX/$hook.sh"
}

@test "the Codex pulse records the session that owns the shift, and only that one" {
  p="$(new_project codex-pulse)"
  punch_open "$p"
  printf 'sess-1\n' >"$p/.nightshift/.shift-session"

  # A pulse from another session is not evidence that this shift is alive.
  run codex_hook pulse "$p" sess-9
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -e "$p/.nightshift/.shift-pulse" ] || { echo "a stranger's pulse was recorded"; return 1; }

  run codex_hook pulse "$p" sess-1
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -f "$p/.nightshift/.shift-pulse" ]
  grep -qF sess-1 "$p/.nightshift/.shift-pulse"
}

@test "the Codex pulse says nothing once the shift is over" {
  p="$(new_project codex-pulse-ended)"
  punch_open "$p"
  printf 'sess-1\n' >"$p/.nightshift/.shift-session"
  rm -f "$p/.nightshift/.shift-armed"
  : >"$p/.nightshift/.ended"
  run codex_hook pulse "$p" sess-1
  [ "$status" -eq 0 ]
  [ ! -e "$p/.nightshift/.shift-pulse" ]
}

@test "a closed Codex window is recorded with its reason, and is not a clock-out" {
  p="$(new_project codex-session-end)"
  punch_open "$p"
  printf 'sess-1\n' >"$p/.nightshift/.shift-session"
  run codex_hook session-end "$p" sess-1 '{"reason":"window_close"}'
  [ "$status" -eq 0 ]
  [ -f "$p/.nightshift/.session-end" ]
  grep -qF 'clean session end (window_close)' "$p/.nightshift/.session-end"
  # The shift is still owed: closing a window never ticks a box or ends anything.
  [ -f "$p/.nightshift/.shift-armed" ]
  [ ! -f "$p/.nightshift/.ended" ]
  grep -qF -- '- [ ]' "$p/.nightshift/punch-list.md"
}

@test "a session end from another session is not this shift's ending" {
  p="$(new_project codex-session-end-stranger)"
  punch_open "$p"
  printf 'sess-1\n' >"$p/.nightshift/.shift-session"
  run codex_hook session-end "$p" sess-9 '{"reason":"user_close"}'
  [ "$status" -eq 0 ]
  [ ! -e "$p/.nightshift/.session-end" ]
}

@test "a session end with no reason is recorded as other, not left blank" {
  p="$(new_project codex-session-end-noreason)"
  punch_open "$p"
  printf 'sess-1\n' >"$p/.nightshift/.shift-session"
  run codex_hook session-end "$p" sess-1
  [ "$status" -eq 0 ]
  grep -qF 'clean session end (other)' "$p/.nightshift/.session-end"
}

@test "a finished shift records no session end, because there is nothing left to revive" {
  p="$(new_project codex-session-end-done)"
  printf '## Items\n- [x] **1. done.**\n' >"$p/.nightshift/punch-list.md"
  printf 'sess-1\n' >"$p/.nightshift/.shift-session"
  run codex_hook session-end "$p" sess-1 '{"reason":"completed"}'
  [ "$status" -eq 0 ]
  [ ! -e "$p/.nightshift/.session-end" ]
}

@test "a planted link is replaced rather than written through" {
  p="$(new_project codex-session-end-link)"
  punch_open "$p"
  printf 'sess-1\n' >"$p/.nightshift/.shift-session"
  outside="$BATS_TEST_TMPDIR/outside-session-end"
  printf 'untouched\n' >"$outside"
  ln -s "$outside" "$p/.nightshift/.session-end"
  run codex_hook session-end "$p" sess-1 '{"reason":"error"}'
  [ "$status" -eq 0 ]
  [ ! -L "$p/.nightshift/.session-end" ]
  grep -qF 'clean session end (error)' "$p/.nightshift/.session-end"
  [ "$(cat "$outside")" = untouched ]
}

# codex_stop <project> — a Codex stop payload.
codex_stop() {
  jq -nc --arg w "$1" '{session_id:"sess-1",cwd:$w,hook_event_name:"Stop"}' |
    env CODEX_PROJECT_DIR="$1" bash "$CODEX/clock-out-gate.sh"
}

@test "the Codex gate holds an ended shift once so the model can file it" {
  p="$(new_project codex-auto-file)"
  printf '## Items\n- [x] **1. done.**\n' >"$p/.nightshift/punch-list.md"
  jq '.archive.automatic = true' "$p/.nightshift/rules.json" >"$p/r.json"
  mv "$p/r.json" "$p/.nightshift/rules.json"

  run codex_stop "$p"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF 'file it before the session terminates' \
    || { echo "the shift ended without asking for its filing: $output"; return 1; }
  [ -f "$p/.nightshift/.ended" ]
  [ ! -f "$p/.nightshift/.shift-armed" ]
  [ -f "$p/.nightshift/.pending-filing" ]

  run codex_stop "$p"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qvF 'file it before the session terminates'
}

@test "the Codex gate records which shift ended and where it files" {
  p="$(new_project codex-ended-record)"
  printf '## Items\n- [x] **1. done.**\n' >"$p/.nightshift/punch-list.md"
  jq '.archive.root = "history" | .archive.layout = "shift"' "$p/.nightshift/rules.json" >"$p/r.json"
  mv "$p/r.json" "$p/.nightshift/rules.json"
  run codex_stop "$p"
  [ "$status" -eq 0 ]
  grep -qF 'archiveRoot=history' "$p/.nightshift/.ended"
  grep -qF 'archiveLayout=shift' "$p/.nightshift/.ended"
}
