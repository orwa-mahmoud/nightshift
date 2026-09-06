#!/usr/bin/env bats
# Continuity handoff — native fence; leftover commands folded into skills.

load helpers

ROOT="$BATS_TEST_DIRNAME/.."
CH="$ROOT/plugins/nightshift/runtime/continuity-handoff.sh"
FIX="$ROOT/tests/fixtures/continuity"
START="$ROOT/plugins/nightshift/skills/start/SKILL.md"
STATUS="$ROOT/plugins/nightshift/skills/status/SKILL.md"
DOCTOR="$ROOT/plugins/nightshift/skills/doctor/SKILL.md"
LIB="$ROOT/plugins/nightshift/lib/lib.sh"

@test "continuity-handoff script is executable" {
  [ -x "$CH" ]
}

@test "leftover python commands are unused" {
  run bash "$CH" handoff-package --input "$FIX/handoff-complete.json"
  [ "$status" -eq 2 ]
  printf '%s\n' "$output" | grep -qi 'unused'
  run bash "$CH" campaign-sequence --input "$FIX/campaign-valid.json"
  [ "$status" -eq 2 ]
  run bash "$CH" transition-history --input "$FIX/transition-history.json"
  [ "$status" -eq 2 ]
}

@test "fence-check without a lease refuses and ignores model JSON flags" {
  run bash "$CH" fence-check --input "$FIX/fence-ok.json"
  [ "$status" -ne 0 ]
  printf '%s' "$output" | jq -e '.takeoverAllowed == false and .action == "refuse"' >/dev/null
  run bash "$CH" fence-check --input "$FIX/fence-refused.json"
  [ "$status" -ne 0 ]
  printf '%s' "$output" | jq -e '.takeoverAllowed == false' >/dev/null

  p="$(new_project)"
  punch_open "$p"
  run bash "$CH" fence-check --project "$p"
  [ "$status" -eq 2 ]
  printf '%s' "$output" | jq -e '.takeoverAllowed == false and .action == "refuse"' >/dev/null
}

@test "fence-check allows takeover only when the on-disk lease is fenced" {
  p="$(new_project)"
  punch_open "$p"
  bash -c '. "$1"; ns_lease_takeover "$2/.nightshift" shift-session claude' \
    nightshift "$LIB" "$p" >/dev/null
  run bash "$CH" fence-check --project "$p"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.takeoverAllowed == true and .priorOwnerFenced == true and .twoActiveWorkersAllowed == false' >/dev/null

  start="$(ps -o lstart= -p $$ | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  printf 'shift-session\nclaude\n1\n\n%s\n%s\n' "$$" "$start" >"$p/.nightshift/.shift-lease"
  run bash "$CH" fence-check --project "$p" --input "$FIX/fence-ok.json"
  [ "$status" -eq 1 ]
  printf '%s' "$output" | jq -e '.takeoverAllowed == false and .priorWorkerActive == true' >/dev/null
}

@test "fence-check accepts a CRLF empty-pid lease" {
  p="$(new_project)"
  punch_open "$p"
  printf 'shift-session\r\nclaude\r\n1\r\nfence.1\r\n\r\n\r\n' >"$p/.nightshift/.shift-lease"
  run bash "$CH" fence-check --project "$p"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.takeoverAllowed == true and .priorOwnerFenced == true' >/dev/null
}

@test "start status and doctor keep native fence and drop leftover python commands" {
  grep -qF 'ns continuity-handoff fence-check' \
    "$BATS_TEST_DIRNAME/../plugins/nightshift/lib/preflight-explain.txt"
  if grep -qF 'handoff-package' "$START"; then
    return 1
  fi
  if grep -qF 'transition-history' "$STATUS"; then
    return 1
  fi
  if grep -qF 'transition-history' "$DOCTOR"; then
    return 1
  fi
  grep -qF 'shift-log.md' "$STATUS"
}
