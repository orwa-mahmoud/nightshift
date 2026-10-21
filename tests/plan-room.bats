#!/usr/bin/env bats
# The plan room: a planning conversation reminded on every owner message that it plans and does not
# build. Hardhat keeps its edit tools to the plan's places and applies the owner's planRoom block
# lists, only for the conversation the room is bound to; every other tool runs. The marker itself
# is out of every conversation's reach.

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
  [[ "$output" == *': nightshift-plan-probe'* ]] || false
  [ -z "$(lib ns_plan_room_line "$p/.nightshift" 1)" ]
  run claude "$p" planner "$(bash_call ': nightshift-plan-probe')"
  [ -z "$(reason "$output")" ]
  [ "$(lib ns_plan_room_line "$p/.nightshift" 1)" = planner ]
  run claude "$p" someone-else "$(bash_call ': nightshift-plan-probe')"
  [[ "$(reason "$output")" == 'BLOCKED: the plan room is bound to another conversation.'* ]] || false
}

@test "the shift's own conversation cannot enter the plan room, and another conversation can" {
  p="$(new_project on-shift)"
  punch_open "$p"
  printf 'shifter\n\n\n\nclaude\n' >"$p/.nightshift/.shift-session"
  bash "$PLUGIN/runtime/plan-enter.sh" --project "$p" >/dev/null
  run claude "$p" shifter "$(bash_call ': nightshift-plan-probe')"
  [ "$(reason "$output")" = 'BLOCKED: this conversation is working the shift, so it cannot enter the plan room, and the plan room was not opened. Plan in another conversation, or stop the shift first.' ]
  ! lib ns_plan_room_open "$p/.nightshift" || false
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

@test "the planning conversation's edit tools are denied every write outside the plan's places" {
  p="$(room fence)"
  for payload in \
    "$(edit Edit "$p/src/app.js")" "$(edit Write "$p/README.md")" "$(edit MultiEdit "$p/src/a.js")" \
    "$(edit NotebookEdit "$p/nb.ipynb")" "$(edit Write "$p/.nightshift/rules.json")"; do
    run claude "$p" planner "$payload"
    [ "$(reason "$output")" = "$(message "$p" .nightshift/staging/)" ] || { echo "not denied as planned: $payload -> $(reason "$output")"; return 1; }
  done
}

@test "every tool that is not an edit runs: questions, research, connectors, agents and new tools" {
  p="$(room free)"
  for payload in \
    "$(edit Read "$p/src/app.js")" '{"tool_name":"Grep","tool_input":{"pattern":"x"}}' \
    '{"tool_name":"AskUserQuestion","tool_input":{"questions":[]}}' '{"tool_name":"Agent","tool_input":{"prompt":"x"}}' \
    '{"tool_name":"mcp__db__write","tool_input":{}}' '{"tool_name":"mcp__ccd_turn__update_plan","tool_input":{"advance":true}}' \
    '{"tool_name":"SomeToolNoHostHasYet","tool_input":{"x":1}}' \
    "$(bash_call 'git log --oneline -5 && git diff')" "$(bash_call 'grep -rn TODO src | head -20')" \
    "$(bash_call "grep 'a\\|b' src/app.js")" "$(bash_call 'sed -n 1p src/app.js')" "$(bash_call 'gh issue view 21')" \
    "$(bash_call 'npm install')" \
    "$(edit Write "$p/.nightshift/staging/drafting-table.md")" "$(edit Edit "$p/.nightshift/staging/plan.md")"; do
    run claude "$p" planner "$payload"
    [ -z "$(reason "$output")" ] || { echo "denied: $payload -> $(reason "$output")"; return 1; }
  done
}

# expanded <project> <text> — a message as hardhat prints it: the rules file named absolute, under the
# workspace.
expanded() {
  local root
  root="$(cd -P "$1" && pwd)"
  printf '%s' "${2//.nightshift\/rules.json/$root/.nightshift/rules.json}"
}

# set_lists <project> <jq-filter> — rewrite the workspace's planRoom block.
set_lists() {
  local f="$1/.nightshift/rules.json"
  jq "$2" "$f" >"$f.tmp" && mv "$f.tmp" "$f"
}

@test "the owner's block lists stop what they name, read fresh on every call" {
  p="$(room lists)"
  # No planRoom block: the room's own default keeps commits, pushes and tags out.
  set_lists "$p" 'del(.planRoom)'
  for cmd in 'git commit -m "push me"' 'git push origin main' 'git tag v1'; do
    run claude "$p" planner "$(bash_call "$cmd")"
    [ "$(reason "$output")" = "$(expanded "$p" "$(lib ns_plan_room_block_message blockedCommands 'git (commit|push|tag)')")" ] ||
      { echo "$cmd: $(reason "$output")"; return 1; }
  done
  run claude "$p" planner "$(bash_call 'git log --oneline')"
  [ -z "$(reason "$output")" ]
  set_lists "$p" '.planRoom = {blockedTools: ["mcp__slack__*"], blockedCommands: "npm install"}'
  run claude "$p" planner '{"tool_name":"mcp__slack__post_message","tool_input":{}}'
  [ "$(reason "$output")" = "$(expanded "$p" "$(lib ns_plan_room_block_message blockedTools 'mcp__slack__*')")" ] || { echo "$output"; return 1; }
  run claude "$p" planner '{"tool_name":"mcp__github__get_issue","tool_input":{}}'
  [ -z "$(reason "$output")" ]
  run claude "$p" planner "$(bash_call 'npm install')"
  [ "$(reason "$output")" = "$(expanded "$p" "$(lib ns_plan_room_block_message blockedCommands 'npm install')")" ]
  run claude "$p" planner "$(bash_call 'git commit -m x')"
  [ -z "$(reason "$output")" ]
  # Empty lists block nothing.
  set_lists "$p" '.planRoom = {blockedTools: [], blockedCommands: ""}'
  run claude "$p" planner "$(bash_call 'git push')"
  [ -z "$(reason "$output")" ]
  # A list the room cannot read denies, naming the key.
  set_lists "$p" '.planRoom = {blockedTools: "mcp__slack__*"}'
  run claude "$p" planner '{"tool_name":"mcp__slack__post_message","tool_input":{}}'
  [[ "$(reason "$output")" == *'planRoom.blockedTools is not a list of tool names'* ]] || { echo "$output"; return 1; }
  set_lists "$p" '.planRoom = {blockedCommands: "(unclosed"}'
  run claude "$p" planner "$(bash_call 'ls')"
  [[ "$(reason "$output")" == *'planRoom.blockedCommands is not a valid pattern'* ]] || { echo "$output"; return 1; }
}

@test "a command reaching the rules file is denied in the room; reading it with Read is not" {
  p="$(room rules-guard)"
  for cmd in "sed -i '' 's/x/y/' .nightshift/rules.json" "jq . .nightshift/rules.json"; do
    run claude "$p" planner "$(bash_call "$cmd")"
    [ "$(reason "$output")" = "$(expanded "$p" "$(lib ns_plan_room_rules_message)")" ] || { echo "$cmd: $(reason "$output")"; return 1; }
  done
  run claude "$p" planner "$(edit Read "$p/.nightshift/rules.json")"
  [ -z "$(reason "$output")" ]
}

# submit <project> <session> <prompt> — one Claude Code UserPromptSubmit from that conversation.
submit() {
  jq -nc --arg s "$2" --arg q "$3" --arg c "$1" '{session_id:$s,prompt:$q,cwd:$c,hook_event_name:"UserPromptSubmit"}' |
    env CLAUDE_PROJECT_DIR="$1" bash "$PLUGIN/hooks/prompt-submit.sh"
}

@test "each owner message in the bound conversation carries the reminder, and no other prompt does" {
  p="$(room reminder)"
  run submit "$p" planner 'what does the gate do?'
  [ "$(printf '%s' "$output" | jq -r '.hookSpecificOutput.hookEventName')" = UserPromptSubmit ]
  [ "$(printf '%s' "$output" | jq -r '.hookSpecificOutput.additionalContext')" = "$(lib ns_plan_room_reminder "$p/.nightshift")" ]
  run submit "$p" builder 'ship it'
  [ -z "$output" ]
  run submit "$p" planner '/nightshift:plan-exit'
  [ -z "$output" ]
  lib ns_plan_room_leave "$p/.nightshift" test
  run submit "$p" planner 'and now?'
  [ -z "$output" ]
  jq -e '.hooks.UserPromptSubmit[0].hooks[0].command | test("claude-prompt-submit.ps1")' "$PLUGIN/hooks/hooks.json" >/dev/null
}

@test "Codex carries the reminder the same way, and its exit command still closes the room" {
  p="$(new_project codex-reminder)"
  rm -f "$p/.nightshift/.shift-armed"
  printf '2\n' >"$p/.nightshift/state-version"
  mkdir -p "$p/.nightshift/staging"
  bash "$PLUGIN/runtime/plan-enter.sh" --project "$p" --host codex >/dev/null
  hook_payload '{"tool_name":"Bash","session_id":"codex-plan","tool_input":{"command":": nightshift-plan-probe"}}' \
    env CODEX_PROJECT_DIR="$p" bash "$PLUGIN/hooks/codex/hardhat.sh" >/dev/null
  run hook_payload '{"session_id":"codex-plan","prompt":"how should the budget work?"}' \
    env CODEX_PROJECT_DIR="$p" bash "$PLUGIN/hooks/codex/prompt-submit.sh"
  [ "$(printf '%s' "$output" | jq -r '.hookSpecificOutput.additionalContext')" = "$(lib ns_plan_room_reminder "$p/.nightshift")" ]
  run hook_payload '{"session_id":"codex-plan","prompt":"$nightshift:plan-exit"}' \
    env CODEX_PROJECT_DIR="$p" bash "$PLUGIN/hooks/codex/prompt-submit.sh"
  [[ "$(printf '%s' "$output" | jq -r '.hookSpecificOutput.additionalContext')" == 'nightshift: the owner left the plan room.'* ]] || { echo "$output"; return 1; }
  ! lib ns_plan_room_open "$p/.nightshift" || false
}

@test "the read-only ns verbs run in the plan room as the skills write them" {
  p="$(room ns-verbs)"
  for cmd in "\"$PLUGIN/runtime/ns\" status" "'$PLUGIN/runtime/ns' doctor" \
    "\"\$NIGHTSHIFT_PLUGIN_ROOT/runtime/ns\" path drafting-table" "\"$PLUGIN/runtime/ns\" plan-enter --host claude" \
    "\"$PLUGIN/runtime/ns\" shift-estimate --items 4" "ns bind"; do
    run claude "$p" planner "$(bash_call "$cmd")"
    [ -z "$(reason "$output")" ] || { echo "denied: $cmd -> $output"; return 1; }
  done
  # Wrap-up keeps the read-only classifier and has no room to enter.
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

@test "the edit check and the block lists hold on Codex and Cursor too" {
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
  run bash -c 'jq -nc --arg p "$1" '\''{tool_name:"Shell",conversation_id:"cursor-plan",transcript_path:"",cwd:$p,tool_input:{command:"git push"}}'\'' |
    env CURSOR_PROJECT_DIR="$1" bash "$2"' _ "$q" "$PLUGIN/hooks/cursor/hardhat.sh"
  [[ "$output" == *'planRoom.blockedCommands'* ]] || { echo "cursor push: $output"; return 1; }
  run bash -c 'jq -nc --arg p "$1" '\''{tool_name:"Shell",conversation_id:"cursor-plan",transcript_path:"",cwd:$p,tool_input:{command:"npm install"}}'\'' |
    env CURSOR_PROJECT_DIR="$1" bash "$2"' _ "$q" "$PLUGIN/hooks/cursor/hardhat.sh"
  [[ "$output" != *'plan room'* ]] || { echo "cursor install: $output"; return 1; }
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
      (Get-NSPlanRoomMessage $env:NS_NS) + "|" + (Get-NSPlanRoomMarkerMessage) + "|" + (Get-NSPlanRoomReminder $env:NS_NS) + "|" +
        (Get-NSPlanRoomBlockMessage blockedTools "mcp__x__*") + "|" + (Get-NSPlanRoomRulesMessage)'
    [ "$output" = "$(lib ns_plan_room_message "$p/.nightshift")|$(lib ns_plan_room_marker_message)|$(lib ns_plan_room_reminder "$p/.nightshift")|$(lib ns_plan_room_block_message blockedTools 'mcp__x__*')|$(lib ns_plan_room_rules_message)" ] ||
      { echo "$layout: $output"; return 1; }
  done
}

@test "another conversation cannot delete or move the plan room's parent directories" {
  p="$(room directory-guard)"
  for cmd in 'rm -rf .nightshift/run' 'mv .nightshift/run saved' 'rm -rf .nightshift'; do
    run claude "$p" helper "$(bash_call "$cmd")"
    [ "$(reason "$output")" = "$(lib ns_plan_room_marker_message)" ] || { echo "$cmd: $output"; return 1; }
  done
  run claude "$p" helper "$(bash_call 'rm -rf src/run')"
  [ -z "$(reason "$output")" ]
}

@test "the plan's places reject a symlink leaf that reaches the project" {
  p="$(room write-escapes)"
  printf 'unchanged\n' >"$p/src/app.js"
  ln -s "$p/src/app.js" "$p/.nightshift/staging/plan.md"
  run claude "$p" planner "$(edit Edit "$p/.nightshift/staging/plan.md")"
  [ -n "$(reason "$output")" ]
  [ "$(cat "$p/src/app.js")" = unchanged ]
}

@test "concurrent first probes admit only the winner" {
  p="$(room atomic-bind)"
  lib ns_plan_room_leave "$p/.nightshift" test
  lib ns_plan_room_enter "$p/.nightshift" claude
  cat >"$BATS_TEST_TMPDIR/bind.sh" <<'EOF'
. "$1"
eval "$(declare -f ns_plan_room_line | sed '1s/ns_plan_room_line/ns_original_plan_line/')"
ns_plan_room_line() {
  local out
  out="$(ns_original_plan_line "$@")" || return 1
  [ "$2" != 1 ] || sleep 0.3
  printf '%s' "$out"
}
while [ ! -f "$4/start" ]; do sleep 0.02; done
ns_plan_room_bind "$2" "$3" claude
printf '%s' "$?" >"$4/$3.result"
EOF
  bash "$BATS_TEST_TMPDIR/bind.sh" "$LIB" "$p/.nightshift" first "$BATS_TEST_TMPDIR" & first=$!
  bash "$BATS_TEST_TMPDIR/bind.sh" "$LIB" "$p/.nightshift" second "$BATS_TEST_TMPDIR" & second=$!
  touch "$BATS_TEST_TMPDIR/start"
  wait "$first"
  wait "$second"
  [ "$(( $(cat "$BATS_TEST_TMPDIR/first.result") + $(cat "$BATS_TEST_TMPDIR/second.result") ))" -eq 1 ]
  winner="$(lib ns_plan_room_line "$p/.nightshift" 1)"
  [ "$(cat "$BATS_TEST_TMPDIR/$winner.result")" -eq 0 ]
}

@test "wrap-up refuses interpreters, command wrappers and write-capable read options" {
  for cmd in "awk 'BEGIN { system(\"touch src/new\") }'" "sed -n 'w src/new' input" \
    'command touch src/new' 'sort -o src/new input' 'rg --pre writer text src' 'uniq input src/new' \
    'git diff --output=src/app.js' 'git -c diff.external=writer diff'; do
    run bash -c '. "$1"; . "$2"; ns_hardhat_command_allowed "$3" wrapup' _ "$LIB" "$PLUGIN/hooks/shared/hardhat-core.sh" "$cmd"
    [ "$status" -ne 0 ] || { echo "allowed: $cmd"; return 1; }
  done
}

@test "entering refuses a marker symlink without touching its target on either runtime" {
  p="$(new_project marker-link)"
  rm -f "$p/.nightshift/.shift-armed"
  victim="$p/src.txt"
  printf 'unchanged\n' >"$victim"
  ln -s "$victim" "$(lib ns_plan_room_file "$p/.nightshift")"
  run bash "$PLUGIN/runtime/plan-enter.sh" --project "$p"
  [ "$status" -eq 1 ]
  [ "$(cat "$victim")" = unchanged ]
  command -v pwsh >/dev/null 2>&1 || return 0
  run pwsh -NoProfile -NonInteractive -File "$PLUGIN/runtime/windows/plan-enter.ps1" -Project "$p"
  [ "$status" -eq 1 ]
  [ "$(cat "$victim")" = unchanged ]
}
