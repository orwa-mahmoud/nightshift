#!/usr/bin/env bats
# Every time a person reads is written in the machine's own time zone, with its UTC offset; a field
# a program reads back keeps UTC. Pinned under a positive, a negative and a half-hour offset, on
# both runtimes.

load helpers

PLUGIN="$BATS_TEST_DIRNAME/../plugins/nightshift"
LIB="$PLUGIN/lib/lib.sh"
MODULE="$PLUGIN/lib/Nightshift.psm1"

lib() { bash -c '. "$1"; shift; "$@"' _ "$LIB" "$@"; }

ZONES='Asia/Dubai|2026-09-21 18:13 (UTC+04:00)
America/Sao_Paulo|2026-09-21 11:13 (UTC-03:00)
Asia/Kolkata|2026-09-21 19:43 (UTC+05:30)'

@test "a local time carries the machine's own offset, in any zone" {
  while IFS='|' read -r tz want; do
    [ "$(TZ="$tz" lib ns_local_time 1790000000)" = "$want" ] || { echo "$tz: $(TZ="$tz" lib ns_local_time 1790000000)"; return 1; }
  done <<<"$ZONES"
  [ "$(TZ=Asia/Kolkata lib ns_local_time 1790000000 second)" = '2026-09-21 19:43:20 (UTC+05:30)' ]
  run lib ns_local_time 'not-a-time'
  [ "$status" -ne 0 ]
}

@test "PowerShell writes the same local time in the same zone" {
  command -v pwsh >/dev/null 2>&1 || skip 'pwsh is not installed'
  while IFS='|' read -r tz want; do
    run env TZ="$tz" NS_MODULE="$MODULE" pwsh -NoProfile -NonInteractive -Command '
      Import-Module $env:NS_MODULE -Force -DisableNameChecking
      (Get-NSLocalTime "1790000000") + "|" + (Get-NSLocalTime "1790000000" -Seconds)'
    [ "$output" = "$want|$(TZ="$tz" lib ns_local_time 1790000000 second)" ] || { echo "$tz: $output"; return 1; }
  done <<<"$ZONES"
}

@test "a receipt's sessions, span and handoff are in local time" {
  data='- 1790000000 1790000600 600 9 2 paused cw=- cr=- rea=- paused=0 host=claude/claude-opus-5
- 1790003600 1790004200 600 4 1 ticked cw=- cr=- rea=- paused=0 host=codex/gpt-5.5'
  run env TZ=America/Sao_Paulo bash -c '. "$1"; ns_receipt_usage_section "$2"' _ "$LIB" "$data"
  [ "$status" -eq 0 ]
  [[ "$output" == *'| span | 2026-09-21 11:13 (UTC-03:00) → 2026-09-21 12:23 (UTC-03:00) |'* ]] || false
  [[ "$output" == *'| claude · claude-opus-5 | 2026-09-21 11:13 (UTC-03:00) | 2026-09-21 11:23 (UTC-03:00) |'* ]] || false
  [[ "$output" == *$'\n- 2026-09-21 11:23 (UTC-03:00) · claude · claude-opus-5 → codex · gpt-5.5 ·'* ]] || false
}

@test "shift-log lines and the stop-work order are stamped in local time" {
  p="$(new_project local-log)"
  TZ=Asia/Kolkata lib ns_shift_log "$p/.nightshift" 'a line'
  grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} \(UTC\+05:30\) · a line$' "$p/.nightshift/shift-log.md"
  TZ=America/Sao_Paulo bash "$PLUGIN/runtime/stop-shift.sh" --project "$p" >/dev/null
  head -n1 "$p/.nightshift/STOP" | grep -qE '^stopped by owner · [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} \(UTC-03:00\)$'
}

@test "Status still reads the shift changing hands from local-time lines, in either runtime's form" {
  p="$(new_project local-transitions)"
  printf '%s\n' \
    '2026-10-08 07:12:33 (UTC+04:00) - watchman armed for a claude shift' \
    '2026-10-08 07:13:00 (UTC+04:00) · shift started' \
    '2026-10-08 07:14:00 (UTC+04:00) · item 1 ticked' \
    '2026-10-08 07:15:00 · revived the shift' >"$p/.nightshift/shift-log.md"
  [ "$(lib ns_status_transitions "$p/.nightshift/shift-log.md" 5 | paste -sd'|' -)" = \
    'watchman armed for a claude shift|shift started|revived the shift' ]
  command -v pwsh >/dev/null 2>&1 || return 0
  run env NS_MODULE="$MODULE" NS_LOG="$p/.nightshift/shift-log.md" pwsh -NoProfile -NonInteractive -Command '
    Import-Module $env:NS_MODULE -Force -DisableNameChecking
    (Get-NSStatusTransitions $env:NS_LOG 5) -join "|"'
  [ "$output" = 'watchman armed for a claude shift|shift started|revived the shift' ]
}

@test "fields a program reads back keep UTC and epochs in any zone" {
  p="$(new_project local-machine)"
  printf '## Items\n- [ ] **1. work.**\n' >"$p/.nightshift/punch-list.md"
  rm -f "$p/.nightshift/.shift-armed"
  run env TZ=Asia/Kolkata bash "$PLUGIN/runtime/start-preflight.sh" --project "$p" --host claude --phase snapshot
  [ "$status" -eq 0 ]
  grep -qE '"createdAt": *"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z"' "$p/.nightshift/shift-policy.json"
  TZ=Asia/Kolkata lib ns_usage_mark "$p/.nightshift" arm
  cut -f1 "$p/.nightshift/usage/marks.tsv" | grep -qxE '[0-9]+'
}
