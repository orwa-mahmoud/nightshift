#!/usr/bin/env bats
# The one event that means the conversation no longer holds what it was told.
#
# Claude Code fires SessionStart with a source of `compact` or `resume` when context was lost.
# The hook marks that, so the next clock-out block carries the whole contract again instead of a
# short line that only makes sense to a conversation which still remembers the long one.
#
# It has to be invisible to everyone else: an ordinary conversation, a second tab on the same
# project, and a project with no shift never see the line and never pay for the hook.

load helpers

HOOK="$BATS_TEST_DIRNAME/../plugins/nightshift/hooks/session-start.sh"

# start <project> <source> <session-id> — one SessionStart event as Claude Code sends it.
start() {
  jq -nc --arg s "$2" --arg id "$3" '{hook_event_name:"SessionStart",source:$s,session_id:$id}' |
    env CLAUDE_PROJECT_DIR="$1" bash "$HOOK"
}

# bound <project> — a shift armed and owned by session `sess-1`.
bound() {
  printf '## Items\n- [ ] **P01 - open.**\n' >"$1/.nightshift/punch-list.md"
  printf 'sess-1\n' >"$1/.nightshift/.shift-session"
  : >"$1/.nightshift/.shift-armed"
}

@test "a compacted conversation is marked, and told to reload" {
  p="$(new_project ss-compact)"
  bound "$p"
  run start "$p" compact sess-1
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.hookSpecificOutput.hookEventName == "SessionStart"' >/dev/null
  printf '%s' "$output" | jq -r '.hookSpecificOutput.additionalContext' | grep -qF 'context was compacted'
  printf '%s' "$output" | jq -r '.hookSpecificOutput.additionalContext' | grep -qF 'receipts/'
  printf '%s' "$output" | jq -r '.hookSpecificOutput.additionalContext' \
    | grep -qF 'Receipts: one file per item under .nightshift/receipts/'
  # A compacted conversation has lost the contract as surely as the report section, and the helper
  # in step 1 hands back an item, never the contract above it.
  printf '%s' "$output" | jq -r '.hookSpecificOutput.additionalContext' \
    | grep -qF 'the contract in punch-list.md'
  [ -f "$p/.nightshift/.context-reset" ]
}

@test "a resumed conversation is treated the same way" {
  p="$(new_project ss-resume)"
  bound "$p"
  run start "$p" resume sess-1
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  [ -f "$p/.nightshift/.context-reset" ]
}

@test "an ordinary start or a cleared conversation says nothing" {
  p="$(new_project ss-other)"
  bound "$p"
  for source in startup clear ''; do
    run start "$p" "$source" sess-1
    [ "$status" -eq 0 ]
    [ -z "$output" ] || { echo "$source said: $output"; return 1; }
    [ ! -e "$p/.nightshift/.context-reset" ] || { echo "$source marked a reset"; return 1; }
  done
}

@test "a project with no armed shift never pays for the hook" {
  p="$(new_project ss-unarmed)"
  bound "$p"
  rm -f "$p/.nightshift/.shift-armed"
  run start "$p" compact sess-1
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -e "$p/.nightshift/.context-reset" ]
}

@test "a second tab on the same project is not the session that owns the shift" {
  p="$(new_project ss-foreign)"
  bound "$p"
  run start "$p" compact sess-9
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -e "$p/.nightshift/.context-reset" ]
}

@test "the marker a compaction leaves is what the next block consumes" {
  p="$(new_project ss-consumed)"
  bound "$p"
  jq '.clockOutReminderMode = "changed-only"' "$p/.nightshift/rules.json" >"$p/r.json"
  mv "$p/r.json" "$p/.nightshift/rules.json"
  lib="$BATS_TEST_DIRNAME/../plugins/nightshift/lib/lib.sh"
  core="$BATS_TEST_DIRNAME/../plugins/nightshift/hooks/shared/gate-core.sh"
  fp="$(bash -c '. "$1"; . "$2"; ns_gate_reminder_fingerprint 1 0 P01 no pending quiet' _ "$lib" "$core")"

  # Settle into the short line.
  bash -c '. "$1"; . "$2"; ns_gate_reminder_text "$3" "FULL TEXT" 1 0 P01 "$4"' _ "$lib" "$core" "$p" "$fp" >/dev/null
  run bash -c '. "$1"; . "$2"; ns_gate_reminder_text "$3" "FULL TEXT" 1 0 P01 "$4"' _ "$lib" "$core" "$p" "$fp"
  [ "$output" != 'FULL TEXT' ]

  # Then the conversation is compacted.
  run start "$p" compact sess-1
  [ -f "$p/.nightshift/.context-reset" ]
  run bash -c '. "$1"; . "$2"; ns_gate_reminder_text "$3" "FULL TEXT" 1 0 P01 "$4"' _ "$lib" "$core" "$p" "$fp"
  [ "$output" = 'FULL TEXT' ]
  [ ! -e "$p/.nightshift/.context-reset" ]
}

@test "the hook is registered for those two sources only" {
  hooks="$BATS_TEST_DIRNAME/../plugins/nightshift/hooks/hooks.json"
  jq -e '.hooks.SessionStart | length == 1' "$hooks" >/dev/null
  jq -e '.hooks.SessionStart[0].matcher == "compact|resume"' "$hooks" >/dev/null
  jq -e '.hooks.SessionStart[0].hooks[0].command | contains("claude-session-start")' "$hooks" >/dev/null
  [ -x "$BATS_TEST_DIRNAME/../plugins/nightshift/hooks/dispatch/claude-session-start.ps1" ]
}

@test "every dispatch file names two hooks that exist" {
  # SessionStart shipped pointing at a Windows hook that was never written, so a native session got
  # a failing hook on every compaction and resume. The class is the check, not the instance: each
  # dispatch file names a POSIX target and a Windows one, and both must be there.
  P="$BATS_TEST_DIRNAME/../plugins/nightshift"
  for d in "$P"/hooks/dispatch/*; do
    named=0
    for target in $(grep -oE 'hooks[/\\][A-Za-z0-9_/\\.-]+\.(ps1|sh)' "$d" | tr '\\' '/' | sort -u); do
      named=$((named + 1))
      [ -f "$P/$target" ] || { echo "$d names $target, which does not exist"; return 1; }
    done
    [ "$named" -ge 2 ] || { echo "$d names fewer than two hooks"; return 1; }
  done
}

@test "the Windows SessionStart twin exists and its logic suite is registered" {
  W="$BATS_TEST_DIRNAME/../plugins/nightshift/hooks/windows/session-start.ps1"
  [ -f "$W" ]
  # The two things the POSIX hook does, and the two hosts that have no such event.
  grep -qF '.context-reset' "$W"
  grep -qF 'SessionStart' "$W"
  grep -qF 'compact' "$W"
  grep -qF 'resume' "$W"
  [ -f "$BATS_TEST_DIRNAME/windows/session-start-logic.ps1" ]
  grep -qF 'session-start-logic.ps1' "$BATS_TEST_DIRNAME/windows/run.ps1"
  command -v pwsh >/dev/null 2>&1 || skip 'pwsh is not installed'
  run pwsh -NoProfile -NonInteractive -File "$BATS_TEST_DIRNAME/windows/session-start-logic.ps1"
  [ "$status" -eq 0 ]
}
