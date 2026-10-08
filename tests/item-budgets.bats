#!/usr/bin/env bats
# Item budgets: a soft limit tells the agent once to start finishing, a hard limit allows only
# wrap-up until the item is closed as stopped, and a stopped item is never ticked. The runtime
# measures the spend; the agent never measures itself.

load helpers

ROOT="$BATS_TEST_DIRNAME/.."
PLUGIN="$ROOT/plugins/nightshift"
LIB="$PLUGIN/lib/lib.sh"
CORE="$PLUGIN/hooks/shared/gate-core.sh"
PULSE="$PLUGIN/hooks/pulse.sh"

lib() { bash -c '. "$1"; shift; "$@"' _ "$LIB" "$@"; }
core() { bash -c '. "$1"; . "$2"; shift 2; "$@"' _ "$LIB" "$CORE" "$@"; }
pulse() { bash -c '. "$1"; . "$2"; . "$3"; shift 3; "$@"' _ "$LIB" "$CORE" "$PULSE" "$@"; }

ITEM='2. Build the importer.'

# site <name> <budget-line> — an armed shift working item 2, whose receipt is the newest.
site() {
  local p
  p="$(new_project "$1")"
  {
    printf '## Items\n- [x] **1. Done already.** <!-- id: aa11 -->\n'
    printf -- '- [ ] **2. Build the importer.** <!-- id: bb22 -->\n'
    [ -z "$2" ] || printf '  - Budget: %s\n' "$2"
    printf '  - Verify: the importer test passes.\n'
    printf -- '- [ ] **3. Later.** <!-- id: cc33 -->\n'
  } >"$p/.nightshift/punch-list.md"
  printf 'test-shift-session\n' >"$p/.nightshift/.shift-session"
  mkdir -p "$p/.nightshift/receipts" "$p/src"
  lib ns_usage_mark_arm "$p/.nightshift"
  printf '# %s\n\nWriting the parser.\n' "$ITEM" >"$p/.nightshift/receipts/bb22-build-the-importer.md"
  pulse ns_pulse_marks "$p/.nightshift" "$p" test-shift-session ""
  printf '%s' "$p"
}

spend() { lib ns_usage_record "$1/.nightshift" claude claude-opus-5 transcript-incremental /t/a 10 "input=$2,output=$3"; }

# notices <project> — the budget lines this pulse has for the agent.
notices() { pulse ns_pulse_notices "$1/.nightshift" "$1" | grep '^budget:' || :; }

deny_reason() { printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecisionReason'; }

hardhat_tool() { # <project> <payload-json>
  hook_payload "$2" env CLAUDE_PROJECT_DIR="$1" bash "$PLUGIN/hooks/hardhat.sh"
}

denied() { printf '%s' "$1" | grep -q '"permissionDecision":"deny"'; }

@test "a budget reads soft and hard limits in time, tokens or both" {
  [ "$(lib ns_budget_parse 'soft 30m / 1M tokens, hard 45m / 2M tokens')" = '1800 1000000 2700 2000000' ]
  [ "$(lib ns_budget_parse 'hard 1h 30m')" = '- - 5400 -' ]
  [ "$(lib ns_budget_parse 'soft 500k tokens')" = '- 500000 - -' ]
  [ "$(lib ns_budget_parse 'hard 2.5M tokens / 90s')" = '- - 90 2500000' ]
  run lib ns_budget_parse ''
  [ "$status" -eq 1 ]
  for bad in 'soft 30x' 'medium 3m' 'soft 3m, soft 4m' 'soft 3m / 4m' 'hard -5m'; do
    run lib ns_budget_parse "$bad"
    [ "$status" -eq 2 ] || { echo "accepted: $bad"; return 1; }
  done
}

@test "an item's own budget wins; the shift block's itemBudget covers an item that names none" {
  p="$(site own-and-default 'hard 45m')"
  jq '.shift.itemBudget = "soft 10m"' "$p/.nightshift/rules.json" >"$p/r" && mv "$p/r" "$p/.nightshift/rules.json"
  [ "$(lib ns_budget_text "$p" "$ITEM")" = 'hard 45m' ]
  [ "$(lib ns_budget_text "$p" '3. Later.')" = 'soft 10m' ]
  run lib ns_policy_settings
  printf '%s\n' "$output" | grep -qx 'shift.itemBudget'
}

@test "a soft limit tells the agent once to start finishing" {
  p="$(site soft 'soft 100 tokens')"
  spend "$p" 60 10
  [ -z "$(notices "$p")" ]
  spend "$p" 30 10
  out="$(notices "$p")"
  [[ "$out" == *"budget: $ITEM has reached its soft budget (100 tokens; spent "*'110 tokens). Start finishing it now'* ]] || { echo "$out"; return 1; }
  spend "$p" 30 10
  [ -z "$(notices "$p")" ]
  grep -qF "budget · $ITEM · soft limit reached (100 tokens; spent" "$p/.nightshift/shift-log.md"
}

@test "a hard limit allows only wrap-up until the item is closed" {
  p="$(site hard 'soft 50 tokens, hard 100 tokens')"
  spend "$p" 90 20
  out="$(notices "$p")"
  [[ "$out" == *"budget: $ITEM has reached its hard budget (100 tokens; spent "*'From the next tool call only wrap-up is allowed'* ]] || { echo "$out"; return 1; }
  [ "$(lib ns_budget_hard_open "$p/.nightshift")" = "$ITEM" ]

  r="$(hardhat_tool "$p" "$(jq -nc --arg f "$p/src/importer.js" '{tool_name:"Edit",session_id:"test-shift-session",tool_input:{file_path:$f}}')")"
  denied "$r"
  [[ "$(deny_reason "$r")" == "BLOCKED: $ITEM reached its hard budget. From the next tool call only wrap-up is allowed: commit the work in progress"* ]] || { deny_reason "$r"; return 1; }
  r="$(hardhat_tool "$p" '{"tool_name":"Bash","session_id":"test-shift-session","tool_input":{"command":"npm test"}}')"
  denied "$r"
  for allowed in \
    "$(jq -nc --arg f "$p/.nightshift/receipts/bb22-build-the-importer.md" '{tool_name:"Write",session_id:"test-shift-session",tool_input:{file_path:$f}}')" \
    "$(jq -nc --arg f "$p/.nightshift/punch-list.md" '{tool_name:"Edit",session_id:"test-shift-session",tool_input:{file_path:$f}}')" \
    '{"tool_name":"Bash","session_id":"test-shift-session","tool_input":{"command":"git add -A && git commit -m \"wip: importer parser\""}}' \
    '{"tool_name":"Bash","session_id":"test-shift-session","tool_input":{"command":"git status"}}' \
    "$(jq -nc --arg f "$p/src/importer.js" '{tool_name:"Read",session_id:"test-shift-session",tool_input:{file_path:$f}}')"; do
    r="$(hardhat_tool "$p" "$allowed")"
    ! denied "$r" || { echo "denied: $allowed -> $(deny_reason "$r")"; return 1; }
  done
}

@test "a stopped item closes as stopped, never ticked, and its budget is forgotten" {
  p="$(site stopped 'hard 100 tokens')"
  spend "$p" 90 20
  notices "$p" >/dev/null
  git -C "$p" commit -q --allow-empty -m 'wip: importer parser'
  sed -i.bak 's/^- \[ \] \*\*2\./- [-] **2./' "$p/.nightshift/punch-list.md"
  pulse ns_pulse_marks "$p/.nightshift" "$p" test-shift-session ""

  [ "$(lib ns_item_states "$p/.nightshift/punch-list.md" | cut -f1 | paste -sd' ' -)" = 'ticked stopped open' ]
  [ "$(lib ns_open_boxes "$p/.nightshift/punch-list.md")" = 1 ]
  [ "$(lib ns_ticked_boxes "$p/.nightshift/punch-list.md")" = 1 ]
  [ "$(lib ns_stopped_boxes "$p/.nightshift/punch-list.md")" = 1 ]
  r="$p/.nightshift/receipts/bb22-build-the-importer.md"
  grep -qE '\| stopped \|$' "$r"
  grep -qF '**Budget** `hard 100 tokens`' "$r"
  grep -qE '^- hard limit reached .*; closed as stopped$' "$r"
  run lib ns_budget_hard_open "$p/.nightshift"
  [ "$status" -ne 0 ]
  grep -qF "| $ITEM | stopped |" "$p/.nightshift/receipts/README.md"
}

@test "Status, Doctor's count, the preflight and the morning receipt name a stopped item" {
  p="$(new_project stopped-readers)"
  printf '## Items\n- [x] **1. Done.**\n- [-] **2. Build the importer.**\n  - Stopped: hard 45m spent; wip in abc1234.\n- [ ] **3. Later.**\n' \
    >"$p/.nightshift/punch-list.md"
  run bash "$PLUGIN/runtime/status.sh" --project "$p"
  [[ "$output" == *'Items:       open=1 ticked=1 stopped=1'* ]] || { echo "$output"; return 1; }
  rm -f "$p/.nightshift/.shift-armed"
  run bash "$PLUGIN/runtime/start-preflight.sh" --project "$p" --host claude
  printf '%s\n' "$output" | grep -qx 'ok punch-list open=1 ticked=1 stopped=1'
  run bash "$PLUGIN/runtime/morning-receipt.sh" --project "$p" --view owner
  [[ "$output" == *'- Items: 1 ticked, 1 open, 1 stopped at their hard budget'* ]] || { echo "$output"; return 1; }
  [[ "$output" == *$'## Decisions for you\n\n- 2. Build the importer. stopped at its hard budget without being done'* ]] || { echo "$output"; return 1; }
}

@test "the clock-out gate releases a list whose only unfinished item is stopped" {
  p="$(new_project stopped-gate)"
  printf '## Items\n- [x] **1. Done.**\n- [-] **2. Build the importer.**\n' >"$p/.nightshift/punch-list.md"
  run gate "$p"
  [ "$status" -eq 0 ]
  ! printf '%s' "$output" | grep -q '"decision":"block"'
}

@test "Archive files a ticked item and keeps a stopped one live" {
  p="$(new_project stopped-archive)"
  printf 'Date: 2026-09-20\n\n## Items\n- [x] **1. Done.**\n- [-] **2. Build the importer.**\n' >"$p/.nightshift/punch-list.md"
  rm -f "$p/.nightshift/.shift-armed"
  : >"$p/.nightshift/.ended"
  run bash "$PLUGIN/runtime/archive-receipts.sh" --project "$p" --date 2026-09-20
  [ "$status" -eq 0 ]
  grep -qF -- '- [-] **2. Build the importer.**' "$p/.nightshift/punch-list.md"
}

@test "the Codex and Cursor hardhats hold a spent hard budget to wrap-up too" {
  p="$(site other-hosts 'hard 100 tokens')"
  spend "$p" 90 20
  notices "$p" >/dev/null
  for c in 'npm test' 'git status'; do
    r="$(hook_payload "$(jq -nc --arg c "$c" '{tool_name:"Bash",session_id:"test-shift-session",tool_input:{command:$c}}')" \
      env CODEX_PROJECT_DIR="$p" bash "$PLUGIN/hooks/codex/hardhat.sh")"
    case "$c" in
      'npm test') [[ "$r" == *"$ITEM reached its hard budget"* ]] || { echo "codex: $r"; return 1; } ;;
      *) [[ "$r" != *'hard budget'* ]] || { echo "codex denied $c: $r"; return 1; } ;;
    esac
  done
  # Cursor binds its own conversation, by its conversation id, on a site of its own.
  p="$(site other-hosts-cursor 'hard 100 tokens')"
  spend "$p" 90 20
  notices "$p" >/dev/null
  rm -f "$p/.nightshift/.shift-session"
  bind_session "$p" cursor-tab cursor
  for c in 'npm test' 'git status'; do
    r="$(jq -nc --arg p "$p" --arg c "$c" '{tool_name:"Shell",conversation_id:"cursor-tab",transcript_path:"",cwd:$p,tool_input:{command:$c}}' |
      env CURSOR_PROJECT_DIR="$p" bash "$PLUGIN/hooks/cursor/hardhat.sh")"
    case "$c" in
      'npm test') [[ "$r" == *"$ITEM reached its hard budget"* ]] || { echo "cursor: $r"; return 1; } ;;
      *) [[ "$r" != *'hard budget'* ]] || { echo "cursor denied $c: $r"; return 1; } ;;
    esac
  done
}

@test "closing an item as stopped leaves the items digest as it was" {
  p="$(site digest 'hard 100 tokens')"
  before="$(lib ns_punch_items_digest "$p/.nightshift/punch-list.md")"
  sed -i.bak -e 's/^- \[ \] \*\*2\./- [-] **2./' -e 's/^  - Verify:/  - Stopped: hard 100 tokens spent; wip committed.\n  - Verify:/' \
    "$p/.nightshift/punch-list.md"
  grep -qF '  - Stopped: hard 100 tokens spent' "$p/.nightshift/punch-list.md"
  [ "$(lib ns_punch_items_digest "$p/.nightshift/punch-list.md")" = "$before" ]
}

@test "a time budget counts the working time the receipt already records" {
  p="$(site time 'soft 1m')"
  r="$p/.nightshift/receipts/bb22-build-the-importer.md"
  lib ns_receipt_add_session "$r" "$ITEM" - 1790000000 1790000090 90 1 1 paused 'cw=- cr=- rea=- paused=0'
  out="$(notices "$p")"
  [[ "$out" == "budget: $ITEM has reached its soft budget (1m 0s; spent 1m "* ]] || { echo "$out"; return 1; }
}

@test "the PowerShell half reads, measures and words a budget the same and runs in the Windows suite" {
  grep -qF 'item-budgets-logic.ps1' "$BATS_TEST_DIRNAME/windows/run.ps1"
  command -v pwsh >/dev/null 2>&1 || skip 'pwsh is not installed'
  for t in 'soft 30m / 1M tokens, hard 45m / 2M tokens' 'hard 1h 30m' 'soft 500k tokens' 'hard 2.5M tokens / 90s'; do
    run env NS_MODULE="$PLUGIN/lib/Nightshift.psm1" NS_T="$t" pwsh -NoProfile -NonInteractive -Command '
      Import-Module $env:NS_MODULE -Force -DisableNameChecking; ConvertFrom-NSBudget $env:NS_T'
    [ "$output" = "$(lib ns_budget_parse "$t")" ] || { echo "$t: $output"; return 1; }
  done
  run env NS_MODULE="$PLUGIN/lib/Nightshift.psm1" NS_ITEM="$ITEM" pwsh -NoProfile -NonInteractive -Command '
    Import-Module $env:NS_MODULE -Force -DisableNameChecking
    (Get-NSBudgetNotice "soft" $env:NS_ITEM "30m 0s" "31m 2s / 1.2M tokens") + "|" + (Get-NSBudgetNotice "hard" $env:NS_ITEM "45m 0s" "46m 0s")'
  [ "$output" = "$(lib ns_budget_notice soft "$ITEM" '30m 0s' '31m 2s / 1.2M tokens')|$(lib ns_budget_notice hard "$ITEM" '45m 0s' '46m 0s')" ]
  for c in 'git status' 'git -C repo add -A' 'git push origin x' 'cat a | grep b 2>/dev/null' 'ls > out.txt' \
    'sed -i s/a/b/ f' 'echo $(rm x)' 'npm test' 'find . -name x -delete'; do
    for m in wrapup plan; do
      b=allow
      bash -c '. "$1"; . "$2"; ns_hardhat_command_allowed "$3" "$4"' _ "$LIB" "$PLUGIN/hooks/shared/hardhat-core.sh" "$c" "$m" || b=deny
      run env NS_MODULE="$PLUGIN/lib/Nightshift.psm1" NS_C="$c" NS_M="$m" pwsh -NoProfile -NonInteractive -Command '
        Import-Module $env:NS_MODULE -Force -DisableNameChecking
        if (Test-NSRestrictedCommand $env:NS_C $env:NS_M) { "allow" } else { "deny" }'
      [ "$output" = "$b" ] || { echo "$c ($m): bash $b, pwsh $output"; return 1; }
    done
  done
}
