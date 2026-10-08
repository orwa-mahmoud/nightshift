#!/usr/bin/env bats
# Leaving the plan room. Only something the owner typed removes the marker: the exit command the
# host's prompt hook sees, or plan-exit run in a terminal. The model reaches neither.

load helpers

PLUGIN="$BATS_TEST_DIRNAME/../plugins/nightshift"
LIB="$PLUGIN/lib/lib.sh"

lib() { bash -c '. "$1"; shift; "$@"' _ "$LIB" "$@"; }

# room <name> [host] — a version-2 workspace with no shift armed and the plan room open, bound to
# `planner`.
room() {
  local p
  p="$(new_project "$1")"
  rm -f "$p/.nightshift/.shift-armed"
  printf '2\n' >"$p/.nightshift/state-version"
  mkdir -p "$p/.nightshift/staging" "$p/.nightshift/run"
  printf '## Items\n' >"$p/.nightshift/punch-list.md"
  bash "$PLUGIN/runtime/plan-enter.sh" --project "$p" --host "${2:-claude}" >/dev/null
  lib ns_plan_room_bind "$p/.nightshift" planner "${2:-claude}"
  printf '%s' "$p"
}

marker() { printf '%s/.nightshift/run/plan-room' "$1"; }

# expansion <project> <command-name> — the owner typing that command in Claude Code, through the
# command hooks.json registers.
expansion() {
  local cmd
  cmd="$(jq -r '.hooks.UserPromptExpansion[0].hooks[0].command' "$PLUGIN/hooks/hooks.json")"
  jq -nc --arg n "$2" --arg p "$1" \
    '{session_id:"planner",cwd:$p,hook_event_name:"UserPromptExpansion",expansion_type:"slash_command",command_name:$n,command_args:"",command_source:"plugin",prompt:("/" + $n)}' |
    CLAUDE_PLUGIN_ROOT="$PLUGIN" CLAUDE_PROJECT_DIR="$1" sh -c "$cmd"
}

codex_prompt() {
  jq -nc --arg t "$2" --arg p "$1" '{session_id:"planner",turn_id:"t1",cwd:$p,hook_event_name:"UserPromptSubmit",prompt:$t}' |
    CODEX_PROJECT_DIR="$1" bash "$PLUGIN/hooks/codex/prompt-submit.sh"
}

cursor_prompt() {
  CURSOR_PROJECT_DIR="$1" bash "$PLUGIN/hooks/cursor/before-submit.sh" \
    "$(jq -nc --arg t "$2" --arg p "$1" '{conversation_id:"planner",cwd:$p,prompt:$t}')"
}

hardhat() {
  hook_payload "$(printf '%s' "$3" | jq -c --arg s "$2" '. + {session_id:$s}')" \
    env CLAUDE_PROJECT_DIR="$1" bash "$PLUGIN/hooks/hardhat.sh"
}

reason() { printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty'; }

@test "the exit word is the owner's command as the first word typed, and nothing else" {
  for prompt in '/nightshift:plan-exit' '  /nightshift:plan-exit please' '$nightshift:plan-exit' \
    "$(printf '\n/nightshift:plan-exit\r')"; do
    [ "$(lib ns_plan_room_exit_word "$prompt")" = plan-exit ] || { echo "missed: $prompt"; return 1; }
  done
  for prompt in '/nightshift:start' '$nightshift:start tonight'; do
    [ "$(lib ns_plan_room_exit_word "$prompt")" = start ] || { echo "missed: $prompt"; return 1; }
  done
  for prompt in '' 'leave the plan room' 'type /nightshift:plan-exit' '/nightshift:plan-exits' \
    '/plan-exit' 'nightshift:plan-exit' '/nightshift:status' '/other:plan-exit' '/nightshift:start-now'; do
    run lib ns_plan_room_exit_word "$prompt"
    [ "$status" -ne 0 ] && [ -z "$output" ] || { echo "matched: $prompt -> $output"; return 1; }
  done
}

@test "Claude Code: the owner's /nightshift:plan-exit or /nightshift:start closes the room, any other command does not" {
  p="$(room claude-exit)"
  for name in nightshift:status nightshift:plan nightshift:plan-exits other:plan-exit plan-exit; do
    run expansion "$p" "$name"
    [ "$status" -eq 0 ] && [ -z "$output" ] || { echo "$name: $output"; return 1; }
    [ -f "$(marker "$p")" ] || { echo "$name closed the room"; return 1; }
  done
  run expansion "$p" nightshift:plan-exit
  [ "$status" -eq 0 ]
  [ ! -e "$(marker "$p")" ]
  printf '%s' "$output" | jq -e '.hookSpecificOutput.hookEventName == "UserPromptExpansion"
    and (.hookSpecificOutput.additionalContext | startswith("nightshift: the owner left the plan room."))' >/dev/null
  grep -q 'plan room closed by the owner: typed the plan-exit command (conversation planner)$' "$p/.nightshift/run/shift-log.md"
  [ -z "$(jq -r '.decision // empty' <<<"$output")" ]

  q="$(room claude-start)"
  run expansion "$q" nightshift:start
  [ "$status" -eq 0 ]
  [ ! -e "$(marker "$q")" ]
  [[ "$output" == *'by starting the shift'* ]]
  # The hook is registered for exactly the two commands, and through the polyglot dispatcher.
  [ "$(jq -r '.hooks.UserPromptExpansion[0].matcher' "$PLUGIN/hooks/hooks.json")" = '^nightshift:(plan-exit|start)$' ]
}

@test "Codex: a prompt that starts with \$nightshift:plan-exit or \$nightshift:start closes the room" {
  p="$(room codex-exit codex)"
  for prompt in 'please $nightshift:plan-exit' 'plan-exit' 'we are done planning' '$nightshift:status'; do
    run codex_prompt "$p" "$prompt"
    [ "$status" -eq 0 ] && [ -z "$output" ] || { echo "$prompt: $output"; return 1; }
    [ -f "$(marker "$p")" ] || { echo "$prompt closed the room"; return 1; }
  done
  run codex_prompt "$p" '$nightshift:plan-exit'
  [ "$status" -eq 0 ]
  [ ! -e "$(marker "$p")" ]
  printf '%s' "$output" | jq -e '.hookSpecificOutput.hookEventName == "UserPromptSubmit"
    and (.hookSpecificOutput.additionalContext | length > 0)' >/dev/null

  q="$(room codex-start codex)"
  run codex_prompt "$q" '/nightshift:start'
  [ ! -e "$(marker "$q")" ]
  f="$PLUGIN/hooks/codex/hooks.json"
  jq -e '.hooks.UserPromptSubmit[0].hooks[0].command | test("codex/prompt-submit.sh")' "$f" >/dev/null
}

@test "Cursor: beforeSubmitPrompt closes the room on the owner's command and lets every prompt through" {
  p="$(room cursor-exit cursor)"
  run cursor_prompt "$p" 'can you /nightshift:plan-exit for me'
  [ "$status" -eq 0 ] && [ -z "$output" ]
  [ -f "$(marker "$p")" ]
  run cursor_prompt "$p" '/nightshift:plan-exit'
  [ "$status" -eq 0 ] && [ -z "$output" ]
  [ ! -e "$(marker "$p")" ]
  grep -q 'plan room closed by the owner: typed the plan-exit command' "$p/.nightshift/run/shift-log.md"
}

@test "no agent tool call can run plan-exit or invoke the exit, from any conversation" {
  p="$(room tools)"
  ns_cmd="$PLUGIN/runtime/ns"
  for who in planner builder; do
    for cmd in "\"$ns_cmd\" plan-exit" "bash $PLUGIN/runtime/plan-exit.sh --project ." \
      "cd $PLUGIN/runtime && ./plan-exit.sh --project $p" "pwsh -File runtime/windows/plan-exit.ps1 -Project ." \
      "ns 'plan-exit'"; do
      run hardhat "$p" "$who" "$(jq -nc --arg c "$cmd" '{tool_name:"Bash",tool_input:{command:$c}}')"
      [[ "$(reason "$output")" == "BLOCKED: the plan room marker is the owner's."* ]] || { echo "$who ran: $cmd -> $output"; return 1; }
    done
  done
  # Paths that only share the name are not the verb.
  run hardhat "$p" builder "$(jq -nc --arg f "$p/skills/plan-exit/SKILL.md" '{tool_name:"Write",tool_input:{file_path:$f}}')"
  [ -z "$(reason "$output")" ] || { echo "skill file: $output"; return 1; }
  [ -f "$(marker "$p")" ]
}

@test "ns plan-exit in a terminal closes the room, and says so when none is open" {
  p="$(room terminal)"
  run env -u CLAUDE_PROJECT_DIR -u CODEX_PROJECT_DIR -u CURSOR_PROJECT_DIR NIGHTSHIFT_HOST=claude \
    bash -c 'cd "$1" && "$2" plan-exit' _ "$p" "$PLUGIN/runtime/ns"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "workspace $(cd -P "$p" && pwd)" ]
  [ "${lines[1]}" = 'plan room closed: nothing is fenced any more' ]
  [ ! -e "$(marker "$p")" ]
  grep -q 'plan room closed by the owner: ran plan-exit in a terminal (conversation planner)$' "$p/.nightshift/run/shift-log.md"
  run bash "$PLUGIN/runtime/plan-exit.sh" --project "$p"
  [ "$status" -eq 0 ]
  [ "$output" = 'plan room was not open' ]
}

@test "Start refuses while the plan room is open and names both exits" {
  p="$(room preflight)"
  run bash "$PLUGIN/runtime/start-preflight.sh" --project "$p" --host claude
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -qxF 'refuse plan-room the plan room is open, bound to conversation planner, and a shift never arms over it'
  printf '%s\n' "$output" | grep -q '^explain plan-room A planning conversation implements nothing until the owner leaves the plan room'
  printf '%s\n' "$output" | grep -qF 'repair the owner leaves the plan room by typing /nightshift:plan-exit or /nightshift:start'
  printf '%s\n' "$output" | grep -qF 'or by running ns plan-exit in a terminal'
  bash "$PLUGIN/runtime/plan-exit.sh" --project "$p" >/dev/null
  run bash "$PLUGIN/runtime/start-preflight.sh" --project "$p" --host claude
  [[ "$output" != *'plan-room'* ]] || { echo "$output"; return 1; }
}

@test "the PowerShell half reads the same exits and runs in the Windows suite" {
  grep -qF 'plan-room-logic.ps1' "$BATS_TEST_DIRNAME/windows/run.ps1"
  grep -qF 'prompt-submit.ps1' "$BATS_TEST_DIRNAME/windows/plan-room-logic.ps1"
  grep -qF 'plan-exit.ps1' "$BATS_TEST_DIRNAME/windows/plan-room-logic.ps1"
  command -v pwsh >/dev/null 2>&1 || skip 'pwsh is not installed'
  for prompt in '/nightshift:plan-exit' '  $nightshift:start now' 'type /nightshift:plan-exit' '/nightshift:plan-exits' ''; do
    want="$(lib ns_plan_room_exit_word "$prompt" || true)"
    got="$(NS_MODULE="$PLUGIN/lib/Nightshift.psm1" NS_PROMPT="$prompt" pwsh -NoProfile -NonInteractive -Command \
      'Import-Module $env:NS_MODULE -Force -DisableNameChecking; Get-NSPlanRoomExitWord ([string]$env:NS_PROMPT)')"
    [ "$got" = "$want" ] || { echo "'$prompt': bash '$want', PowerShell '$got'"; return 1; }
  done
}
