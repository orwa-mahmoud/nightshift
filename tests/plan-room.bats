#!/usr/bin/env bats
# The plan room: a planning conversation that implements nothing until the owner leaves it. The
# fence is hardhat's, so it holds however the conversation is worded, and only for the conversation
# the room is bound to; the marker itself is out of every conversation's reach.

load helpers

PLUGIN="$BATS_TEST_DIRNAME/../plugins/nightshift"
LIB="$PLUGIN/lib/lib.sh"

lib() { bash -c '. "$1"; shift; "$@"' _ "$LIB" "$@"; }

# room <name> — a version-2 workspace with no shift armed and the plan room open, bound to
# `planner` by the probe.
room() {
  local p
  p="$(new_project "$1")"
  rm -f "$p/.nightshift/.shift-armed"
  printf '2\n' >"$p/.nightshift/state-version"
  mkdir -p "$p/.nightshift/staging" "$p/.nightshift/run" "$p/src"
  printf '## Items\n' >"$p/.nightshift/punch-list.md"
  bash "$PLUGIN/runtime/plan-enter.sh" --project "$p" >/dev/null
  claude "$p" planner '{"tool_name":"Bash","tool_input":{"command":": nightshift-plan-probe"}}' >/dev/null
  printf '%s' "$p"
}

# claude <project> <session> <payload-json> — one PreToolUse call from that conversation.
claude() {
  hook_payload "$(printf '%s' "$3" | jq -c --arg s "$2" '. + {session_id:$s}')" \
    env CLAUDE_PROJECT_DIR="$1" bash "$PLUGIN/hooks/hardhat.sh"
}

edit() { jq -nc --arg t "$1" --arg f "$2" '{tool_name:$t,tool_input:{file_path:$f}}'; }
bash_call() { jq -nc --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}'; }

reason() { printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty'; }

# message <project> <place> — the denial, with the place named the way hardhat names every path it
# mentions: absolute, under the workspace.
message() {
  printf 'BLOCKED: the plan room is open, so nothing is implemented in this conversation. Tell the owner they are in the plan room and that this change was not made. Here you read, explore and write the plan into %s/%s. To build, the owner leaves the plan room: they type /nightshift:plan-exit, or approve the plan and type /nightshift:start.' \
    "$(cd -P "$1" && pwd)" "$2"
}

@test "entering opens the room unbound and the probe binds it to the conversation that made it" {
  p="$(new_project bind)"
  rm -f "$p/.nightshift/.shift-armed"
  run bash "$PLUGIN/runtime/plan-enter.sh" --project "$p"
  [ "$status" -eq 0 ]
  [[ "$output" == *': nightshift-plan-probe'* ]]
  [ -z "$(lib ns_plan_room_line "$p/.nightshift" 1)" ]
  run claude "$p" planner "$(bash_call ': nightshift-plan-probe')"
  [ -z "$(reason "$output")" ]
  [ "$(lib ns_plan_room_line "$p/.nightshift" 1)" = planner ]
  run claude "$p" someone-else "$(bash_call ': nightshift-plan-probe')"
  [[ "$(reason "$output")" == 'BLOCKED: the plan room is bound to another conversation.'* ]]
}

@test "the shift's own conversation cannot enter the plan room, and another conversation can" {
  p="$(new_project on-shift)"
  punch_open "$p"
  printf 'shifter\n\n\n\nclaude\n' >"$p/.nightshift/.shift-session"
  bash "$PLUGIN/runtime/plan-enter.sh" --project "$p" >/dev/null
  run claude "$p" shifter "$(bash_call ': nightshift-plan-probe')"
  [ "$(reason "$output")" = 'BLOCKED: this conversation is working the shift, so it cannot enter the plan room, and the plan room was not opened. Plan in another conversation, or stop the shift first.' ]
  ! lib ns_plan_room_open "$p/.nightshift"
  grep -q 'plan room not opened: conversation shifter is working the shift$' "$p/.nightshift/shift-log.md"
  # The shift's work is not fenced.
  run claude "$p" shifter "$(edit Edit "$p/src/app.js")"
  [[ "$(reason "$output")" != *'plan room'* ]] || { echo "$output"; return 1; }
  # Planning tomorrow's work in another conversation while the shift runs is allowed.
  bash "$PLUGIN/runtime/plan-enter.sh" --project "$p" >/dev/null
  run claude "$p" planner "$(bash_call ': nightshift-plan-probe')"
  [ -z "$(reason "$output")" ]
  [ "$(lib ns_plan_room_line "$p/.nightshift" 1)" = planner ]
}

@test "the planning conversation is denied every write outside the staging folder, with the exact message" {
  p="$(room fence)"
  for payload in \
    "$(edit Edit "$p/src/app.js")" "$(edit Write "$p/README.md")" "$(edit MultiEdit "$p/src/a.js")" \
    "$(edit NotebookEdit "$p/nb.ipynb")" "$(bash_call 'git commit -m MSG')" "$(bash_call 'rm -rf src')" \
    "$(bash_call 'mv a b')" "$(bash_call 'echo hi > notes.txt')" "$(bash_call 'npm install')" \
    '{"tool_name":"mcp__db__write","tool_input":{}}'; do
    run claude "$p" planner "$payload"
    [ "$(reason "$output")" = "$(message "$p" .nightshift/staging/)" ] || { echo "not denied as planned: $payload -> $(reason "$output")"; return 1; }
  done
}

@test "reading, read-only commands and writing the plan into staging stay free" {
  p="$(room free)"
  for payload in \
    "$(edit Read "$p/src/app.js")" '{"tool_name":"Grep","tool_input":{"pattern":"x"}}' \
    "$(bash_call 'git log --oneline -5 && git diff')" "$(bash_call 'grep -rn TODO src | head -20')" \
    "$(edit Write "$p/.nightshift/staging/drafting-table.md")" "$(edit Edit "$p/.nightshift/staging/plan.md")"; do
    run claude "$p" planner "$payload"
    [ -z "$(reason "$output")" ] || { echo "denied: $payload -> $(reason "$output")"; return 1; }
  done
}

@test "the read-only ns verbs run in the plan room as the skills write them" {
  p="$(room ns-verbs)"
  for cmd in "\"$PLUGIN/runtime/ns\" status" "'$PLUGIN/runtime/ns' doctor" \
    "\"\$NIGHTSHIFT_PLUGIN_ROOT/runtime/ns\" path drafting-table" "\"$PLUGIN/runtime/ns\" plan-enter --host claude" \
    "ns bind"; do
    run claude "$p" planner "$(bash_call "$cmd")"
    [ -z "$(reason "$output")" ] || { echo "denied: $cmd -> $output"; return 1; }
  done
  for cmd in "\"$PLUGIN/runtime/ns\" scaffold product" "\"$PLUGIN/runtime/ns\" stop-shift" \
    "\"/tmp/evil/rm\" -rf src" "'git' commit -m x"; do
    run claude "$p" planner "$(bash_call "$cmd")"
    [[ "$(reason "$output")" == 'BLOCKED: the plan room is open'* ]] || { echo "allowed: $cmd -> $output"; return 1; }
  done
  # Wrap-up shares the classifier but has no room to enter.
  run bash -c '. "$1"; . "$2"; ns_hardhat_command_allowed "\"/x/runtime/ns\" plan-enter" wrapup' _ \
    "$LIB" "$PLUGIN/hooks/shared/hardhat-core.sh"
  [ "$status" -ne 0 ]
  run bash -c '. "$1"; . "$2"; ns_hardhat_command_allowed "\"/x/runtime/ns\" status" wrapup' _ \
    "$LIB" "$PLUGIN/hooks/shared/hardhat-core.sh"
  [ "$status" -eq 0 ]
}

@test "another conversation in the same project is not fenced" {
  p="$(room others)"
  run claude "$p" builder "$(edit Edit "$p/src/app.js")"
  [ -z "$(reason "$output")" ]
  run claude "$p" builder "$(bash_call 'npm install')"
  [ -z "$(reason "$output")" ]
}

@test "no conversation may touch the marker" {
  p="$(room marker)"
  marker="$p/.nightshift/run/plan-room"
  for who in planner builder; do
    for payload in \
      "$(bash_call "rm $marker")" "$(bash_call 'rm .nightshift/run/plan-room')" "$(bash_call 'mv .nightshift/run/* /tmp')" \
      "$(edit Write "$marker")" "$(edit Edit "$marker")"; do
      run claude "$p" "$who" "$payload"
      [[ "$(reason "$output")" == "BLOCKED: the plan room marker is the owner's."* ]] || { echo "$who: $payload -> $(reason "$output")"; return 1; }
    done
  done
  [ -f "$marker" ]
}

@test "the fence holds on Codex and Cursor too" {
  p="$(new_project other-hosts)"
  rm -f "$p/.nightshift/.shift-armed"
  printf '2\n' >"$p/.nightshift/state-version"
  mkdir -p "$p/.nightshift/staging" "$p/src"
  bash "$PLUGIN/runtime/plan-enter.sh" --project "$p" --host codex >/dev/null
  hook_payload '{"tool_name":"Bash","session_id":"codex-plan","tool_input":{"command":": nightshift-plan-probe"}}' \
    env CODEX_PROJECT_DIR="$p" bash "$PLUGIN/hooks/codex/hardhat.sh" >/dev/null
  run hook_payload "$(jq -nc --arg c '*** Begin Patch
*** Update File: src/app.js
*** End Patch' '{tool_name:"apply_patch",session_id:"codex-plan",tool_input:{command:$c}}')" \
    env CODEX_PROJECT_DIR="$p" bash "$PLUGIN/hooks/codex/hardhat.sh"
  [[ "$output" == *'the plan room is open'* ]] || { echo "codex: $output"; return 1; }
  run hook_payload "$(jq -nc --arg c '*** Begin Patch
*** Add File: .nightshift/staging/plan.md
*** End Patch' '{tool_name:"apply_patch",session_id:"codex-plan",tool_input:{command:$c}}')" \
    env CODEX_PROJECT_DIR="$p" bash "$PLUGIN/hooks/codex/hardhat.sh"
  [[ "$output" != *'plan room'* ]] || { echo "codex staging: $output"; return 1; }

  q="$(new_project other-hosts-cursor)"
  rm -f "$q/.nightshift/.shift-armed"
  mkdir -p "$q/src"
  bash "$PLUGIN/runtime/plan-enter.sh" --project "$q" --host cursor >/dev/null
  jq -nc --arg p "$q" '{tool_name:"Shell",conversation_id:"cursor-plan",transcript_path:"",cwd:$p,tool_input:{command:": nightshift-plan-probe"}}' |
    env CURSOR_PROJECT_DIR="$q" bash "$PLUGIN/hooks/cursor/hardhat.sh" >/dev/null
  run bash -c 'jq -nc --arg p "$1" '\''{tool_name:"Shell",conversation_id:"cursor-plan",transcript_path:"",cwd:$p,tool_input:{command:"npm install"}}'\'' |
    env CURSOR_PROJECT_DIR="$1" bash "$2"' _ "$q" "$PLUGIN/hooks/cursor/hardhat.sh"
  [[ "$output" == *'the plan room is open'* ]] || { echo "cursor: $output"; return 1; }
}

@test "Status and Doctor report an open plan room and the conversation it binds" {
  p="$(room report)"
  run bash "$PLUGIN/runtime/status.sh" --project "$p"
  [[ "$output" == *'Plan room:   open, bound to conversation planner'* ]] || { echo "$output"; return 1; }
  run bash "$PLUGIN/runtime/doctor.sh" --project "$p"
  [[ "$output" == *'plan room open, bound to conversation planner'* ]] || { echo "$output"; return 1; }
}

@test "a workspace laid out before the staging folder plans into its drafting table" {
  p="$(new_project legacy-place)"
  rm -f "$p/.nightshift/.shift-armed"
  bash "$PLUGIN/runtime/plan-enter.sh" --project "$p" >/dev/null
  claude "$p" planner "$(bash_call ': nightshift-plan-probe')" >/dev/null
  run claude "$p" planner "$(edit Write "$p/.nightshift/drafting-table.md")"
  [ -z "$(reason "$output")" ]
  run claude "$p" planner "$(edit Write "$p/.nightshift/punch-list.md")"
  [ "$(reason "$output")" = "$(message "$p" .nightshift/drafting-table.md)" ]
}

@test "the PowerShell half words the plan room the same and runs in the Windows suite" {
  grep -qF 'plan-room-logic.ps1' "$BATS_TEST_DIRNAME/windows/run.ps1"
  command -v pwsh >/dev/null 2>&1 || skip 'pwsh is not installed'
  for layout in 2 legacy; do
    p="$BATS_TEST_TMPDIR/words-$layout"
    mkdir -p "$p/.nightshift"
    [ "$layout" = legacy ] || printf '2\n' >"$p/.nightshift/state-version"
    run env NS_MODULE="$PLUGIN/lib/Nightshift.psm1" NS_NS="$p/.nightshift" pwsh -NoProfile -NonInteractive -Command '
      Import-Module $env:NS_MODULE -Force -DisableNameChecking
      (Get-NSPlanRoomMessage $env:NS_NS) + "|" + (Get-NSPlanRoomMarkerMessage)'
    [ "$output" = "$(lib ns_plan_room_message "$p/.nightshift")|$(lib ns_plan_room_marker_message)" ] ||
      { echo "$layout: $output"; return 1; }
  done
}
