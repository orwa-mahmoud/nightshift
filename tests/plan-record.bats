#!/usr/bin/env bats
# The plan record: the plan room's notebook. Entering the room creates it and reads back every plan
# still open, the planning conversation may write it without asking, and Archive files a plan once
# it is captured or dropped.

load helpers

PLUGIN="$BATS_TEST_DIRNAME/../plugins/nightshift"
LIB="$PLUGIN/lib/lib.sh"

lib() { bash -c '. "$1"; shift; "$@"' _ "$LIB" "$@"; }

# workspace <name> [legacy] — no shift armed; version 2 unless `legacy`.
workspace() {
  local p
  p="$(new_project "$1")"
  rm -f "$p/.nightshift/.shift-armed"
  [ "${2:-}" = legacy ] || printf '2\n' >"$p/.nightshift/state-version"
  printf '%s' "$p"
}

claude() {
  hook_payload "$(printf '%s' "$3" | jq -c --arg s "$2" '. + {session_id:$s}')" \
    env CLAUDE_PROJECT_DIR="$1" bash "$PLUGIN/hooks/hardhat.sh"
}

reason() { printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty'; }

entries() {
  cat <<'EOF'
- **Retry budget** · open since 2026-10-09 09:12 (UTC+04:00)
  - Where we are: choosing between a fixed and an adaptive budget; next, the failure cases
  - Rejected: unbounded retries — a dead dependency would hold the shift forever
- **Config loader** · open since 2026-10-08 18:40 (UTC+04:00) · captured: ## Plan: Config loader
  - Decided: one TOML file, no environment overrides — fewer places to look
- **Dark mode** · open since 2026-10-07 11:05 (UTC+04:00) · dropped: not this quarter
EOF
}

@test "the plan record has its own path, under staging in version 2 and at the top before it" {
  p="$(workspace path)"
  [ "$(lib ns_layout_name "$p/.nightshift" plan-record)" = .nightshift/staging/plan-record.md ]
  run env -u CLAUDE_PROJECT_DIR NIGHTSHIFT_HOST=claude bash -c 'cd "$1" && "$2" path plan-record' _ "$p" "$PLUGIN/runtime/ns"
  [ "$status" -eq 0 ]
  [ "$output" = "$(cd -P "$p" && pwd)/.nightshift/staging/plan-record.md" ]
  q="$(workspace path-legacy legacy)"
  [ "$(lib ns_layout_name "$q/.nightshift" plan-record)" = .nightshift/plan-record.md ]
}

@test "entering the room creates the record, and entering again reads back only the plans still open" {
  p="$(workspace resume)"
  run bash "$PLUGIN/runtime/plan-enter.sh" --project "$p"
  [ "$status" -eq 0 ]
  record="$p/.nightshift/staging/plan-record.md"
  [ -f "$record" ]
  head -n1 "$record" | grep -qxF '# Plan Record'
  printf '%s\n' "$output" | grep -qxF 'plan record .nightshift/staging/plan-record.md'
  printf '%s\n' "$output" | grep -qxF 'open plan: none'

  entries >>"$record"
  run bash "$PLUGIN/runtime/plan-enter.sh" --project "$p"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c '^open plan: ')" -eq 1 ]
  printf '%s\n' "$output" | grep -qxF 'open plan: - **Retry budget** · open since 2026-10-09 09:12 (UTC+04:00)'
  # An existing record is the owner's notebook: entering never rewrites it.
  [ "$(grep -c '^- \*\*' "$record")" -eq 3 ]
}

@test "the planning conversation writes the record without asking, in either layout" {
  for layout in 2 legacy; do
    p="$(workspace "write-$layout" "$([ "$layout" = legacy ] && printf legacy)")"
    bash "$PLUGIN/runtime/plan-enter.sh" --project "$p" >/dev/null
    claude "$p" planner '{"tool_name":"Bash","tool_input":{"command":": nightshift-plan-probe"}}' >/dev/null
    record="$(lib ns_layout_path "$p/.nightshift" plan-record)"
    run claude "$p" planner "$(jq -nc --arg f "$record" '{tool_name:"Edit",tool_input:{file_path:$f}}')"
    [ -z "$(reason "$output")" ] || { echo "$layout record: $output"; return 1; }
    run claude "$p" planner "$(jq -nc --arg f "$p/src.js" '{tool_name:"Write",tool_input:{file_path:$f}}')"
    [[ "$(reason "$output")" == 'BLOCKED: the plan room is open'* ]] || { echo "$layout outside: $output"; return 1; }
  done
}

@test "archive files captured and dropped plans with their shift and keeps open ones live" {
  p="$(workspace archive)"
  bash "$PLUGIN/runtime/plan-enter.sh" --project "$p" >/dev/null
  bash "$PLUGIN/runtime/plan-exit.sh" --project "$p" >/dev/null
  record="$p/.nightshift/staging/plan-record.md"
  entries >>"$record"
  printf 'shiftId=aaaa1111bbbb2222\narchiveRoot=archive\narchiveLayout=date\n' >"$(lib ns_layout_path "$p/.nightshift" ended)"
  run bash "$PLUGIN/runtime/archive-receipts.sh" --project "$p" --date 2026-10-09
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  filed="$p/.nightshift/archive/2026-10-09/staging/plan-record.md"
  [ -f "$filed" ]
  head -n1 "$filed" | grep -qxF '# Plan Record'
  grep -qF -- '- **Config loader**' "$filed"
  grep -qF -- '  - Decided: one TOML file, no environment overrides' "$filed"
  grep -qF -- '- **Dark mode**' "$filed"
  ! grep -qF 'Retry budget' "$filed" || false
  grep -qF -- '- **Retry budget**' "$record"
  grep -qF -- '  - Rejected: unbounded retries' "$record"
  ! grep -qF 'Config loader' "$record" || false
  ! grep -qF 'Dark mode' "$record" || false
  grep -qxF 'Filed: [2026-10-09](../archive/2026-10-09/staging/plan-record.md)' "$record"
  # Entering again still resumes the plan that stayed open.
  run bash "$PLUGIN/runtime/plan-enter.sh" --project "$p"
  printf '%s\n' "$output" | grep -qF 'open plan: - **Retry budget**'
}

@test "the PowerShell half reads the same record and runs in the Windows suite" {
  grep -qF 'Get-NSPlanRecordOpen' "$BATS_TEST_DIRNAME/windows/plan-room-logic.ps1"
  command -v pwsh >/dev/null 2>&1 || skip 'pwsh is not installed'
  p="$(workspace parity)"
  bash "$PLUGIN/runtime/plan-enter.sh" --project "$p" >/dev/null
  entries >>"$p/.nightshift/staging/plan-record.md"
  want="$(lib ns_plan_record_open "$p/.nightshift")"
  got="$(NS_MODULE="$PLUGIN/lib/Nightshift.psm1" NS_NS="$p/.nightshift" pwsh -NoProfile -NonInteractive -Command \
    'Import-Module $env:NS_MODULE -Force -DisableNameChecking; Get-NSPlanRecordOpen $env:NS_NS')"
  [ -n "$want" ]
  [ "$got" = "$want" ] || { echo "bash: $want"; echo "PowerShell: $got"; return 1; }
}
