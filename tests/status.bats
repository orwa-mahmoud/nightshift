#!/usr/bin/env bats
# Native status helper — evidence counts, policy view, and lifecycle lines.

bats_require_minimum_version 1.5.0

ROOT="$BATS_TEST_DIRNAME/.."
STATUS="$ROOT/plugins/nightshift/runtime/status.sh"
REF="$ROOT/plugins/nightshift/skills/nightshift/references"

load helpers

@test "status reports evidence counts and separate lifecycle lines" {
  p="$(new_project status-basic)"
  cp "$REF/nightshift-rules-template.json" "$p/.nightshift/rules.json"
  mkdir -p "$p/.nightshift/evidence"
  printf '{"schemaVersion":1,"id":"b1","domain":"baseline","severity":"low","confidence":"medium","impact":"local","status":"open","ladder":"declared","locator":"x","source":"fixture","sourceClass":"test","host":"local"}\n' \
    >"$p/.nightshift/evidence/findings.jsonl"
  printf '{"schemaVersion":1,"id":"c1","domain":"checkpoint","severity":"low","confidence":"medium","impact":"local","status":"open","ladder":"declared","locator":"x","source":"fixture","sourceClass":"test","host":"local"}\n' \
    >>"$p/.nightshift/evidence/findings.jsonl"
  printf '1735689600 test-session\n' >"$p/.nightshift/.shift-pulse"
  printf '1\n2\n' >"$p/.nightshift/.stall"
  printf '## Items\n- [ ] **1. work.**\n' >"$p/.nightshift/punch-list.md"
  : >"$p/.nightshift/.shift-armed"
  run bash "$STATUS" --project "$p"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qF 'evidence:    findings=2 open=2 baseline=1 checkpoint=1'
  printf '%s\n' "$output" | grep -qF 'liveness:'
  printf '%s\n' "$output" | grep -qF 'last activity:'
  printf '%s\n' "$output" | grep -qF 'last checkpoint: c1'
  printf '%s\n' "$output" | grep -qF 'stall attempts: 2'
  printf '%s\n' "$output" | grep -qF 'resolved policy'
}

@test "checkpoint changes the stall fingerprint and resets the counter" {
  p="$(new_project status-stall)"
  cp "$REF/nightshift-rules-template.json" "$p/.nightshift/rules.json"
  printf '## Items\n- [ ] **1. work.**\n' >"$p/.nightshift/punch-list.md"
  : >"$p/.nightshift/.shift-armed"
  git -C "$p" commit -q --allow-empty -m "progress"
  FP1="$(bash -c 'PROJECT_DIR="'"$p"'"; . "'"$ROOT"'/plugins/nightshift/lib/lib.sh"; . "'"$ROOT"'/plugins/nightshift/hooks/shared/gate-core.sh"; ns_gate_progress_token')"
  printf '%s\n' "$p" >"$p/.nightshift/work-target"
  bash "$ROOT/plugins/nightshift/runtime/evidence.sh" --project "$p" init >/dev/null
  bash "$ROOT/plugins/nightshift/runtime/evidence.sh" --project "$p" append --record "$(
    jq -nc --arg t "$p" '{
      schemaVersion: 1, id: "c1", domain: "checkpoint", sourceClass: "worktree",
      source: "manual", scope: "unit", severity: "info", confidence: "high",
      impact: "none", status: "open", ladder: "observed", locator: "nohead",
      digest: "digest-c1", firstSeen: "2026-09-02T00:00:00Z",
      lastChecked: "2026-09-02T00:00:00Z", action: "checkpoint recorded",
      host: "claude", workTarget: $t,
      details: { baseline: "b1", touched: ["README"], rollback: "manual", plan: "fixture" }
    }')" >/dev/null
  FP2="$(bash -c 'PROJECT_DIR="'"$p"'"; . "'"$ROOT"'/plugins/nightshift/lib/lib.sh"; . "'"$ROOT"'/plugins/nightshift/hooks/shared/gate-core.sh"; ns_gate_progress_token')"
  [ "$FP1" != "$FP2" ]
}

# The facts, derived by the helper rather than by hand in the skill.
#
# Counting boxes below a heading, counting drafting-table boxes only after the first rule,
# subtracting a deadline from the clock — every one of those is mechanics, and mechanics in prose
# is an instruction that can be followed loosely. These hold what the helper prints so the skill
# can render it.

PS_STATUS="$ROOT/plugins/nightshift/runtime/windows/status.ps1"

ps_ready() {
  command -v pwsh >/dev/null 2>&1 || skip "pwsh not installed"
}

facts() { # <project> — the fact block, one per line
  bash "$STATUS" --project "$1" 2>/dev/null | sed -n '/^facts$/,/^resolved policy$/p'
}

fact_of() { # <project> <label>
  facts "$1" | grep -E "^$2 " | head -1 | cut -d' ' -f"$(($(printf '%s' "$2" | wc -w) + 1))-"
}

@test "the current open item is named, and a ticked list says none" {
  p="$(new_project status-open-item)"
  printf '## Items\n\n- [x] **P01 - done.**\n\n- [ ] **P02 - the live one.**\n\n  Detail.\n' \
    >"$p/.nightshift/punch-list.md"
  [ "$(fact_of "$p" 'open item')" = 'P02 - the live one.' ]

  printf '## Items\n\n- [x] **P01 - done.**\n' >"$p/.nightshift/punch-list.md"
  [ "$(fact_of "$p" 'open item')" = 'none' ]
}

@test "an unarmed workspace with open boxes says the list is not a shift" {
  p="$(new_project status-todo-file)"
  rm -f "$p/.nightshift/.shift-armed"
  printf '## Items\n\n- [ ] **P01 - open.**\n' >"$p/.nightshift/punch-list.md"
  fact_of "$p" 'armed' | grep -qF 'to-do file, not a shift'

  : >"$p/.nightshift/.shift-armed"
  [ "$(fact_of "$p" 'armed')" = 'yes' ]
}

@test "parked entries are counted and titled, one line each" {
  p="$(new_project status-parked)"
  printf '# Parking lot\n\n- **First decision.** Body that should not appear.\n\n- **Second one.**\n' \
    >"$p/.nightshift/parking-lot.md"
  [ "$(fact_of "$p" 'parked')" = '2' ]
  facts "$p" | grep -qF 'parked entry First decision. Body that should not appear.'
  facts "$p" | grep -qF 'parked entry Second one.'
}

@test "drafting-table boxes are counted only after the first rule" {
  p="$(new_project status-drafts)"
  printf '# Drafting table\n\n```text\n- [ ] **Example shape, not a draft.**\n```\n\n---\n\n- [ ] **A real draft.**\n- [x] **Already promoted.**\n' \
    >"$p/.nightshift/drafting-table.md"
  printf '## Items\n' >"$p/.nightshift/punch-list.md"
  fact_of "$p" 'staged' | grep -qF 'drafts=1'
}

@test "staged work is marked informational only while items are open" {
  p="$(new_project status-staged)"
  printf '# Drafting table\n\n---\n\n- [ ] **A draft.**\n' >"$p/.nightshift/drafting-table.md"

  printf '## Items\n\n- [ ] **P01 - open.**\n' >"$p/.nightshift/punch-list.md"
  fact_of "$p" 'staged' | grep -qF 'informational while items are open'

  printf '## Items\n' >"$p/.nightshift/punch-list.md"
  ! fact_of "$p" 'staged' | grep -qF 'informational'
}

@test "the last three snag dispositions are reported, not the whole log" {
  p="$(new_project status-snags)"
  {
    printf '# Snag log\n\n'
    for n in 1 2 3 4 5; do printf -- '- **Snag %s.** Detail.\n\n' "$n"; done
  } >"$p/.nightshift/snag-log.md"
  [ "$(facts "$p" | grep -c '^snag ')" -eq 3 ]
  facts "$p" | grep -qF 'snag Snag 5. Detail.'
  ! facts "$p" | grep -qF 'snag Snag 1.'
}

@test "the shipped opportunity template counts as no opportunities at all" {
  p="$(new_project status-map-template)"
  cp "$REF/../assets/opportunity-map.md" "$p/.nightshift/opportunity-map.md" 2>/dev/null ||
    printf '# Opportunity map\n\n<!--\n### <title>\nStatus: building\nNext: <action>\n-->\n' \
      >"$p/.nightshift/opportunity-map.md"
  [ "$(fact_of "$p" 'opportunities')" = 'candidate=0 building=0 shipped=0 rejected=0 parked=0' ]
  ! facts "$p" | grep -q '^building '
}

@test "a building entry carries its phase, next action and remaining verification" {
  p="$(new_project status-building)"
  cat >"$p/.nightshift/opportunity-map.md" <<'MAP'
# Opportunity map

<!--
### <title>
Status: building
-->

### Faster cold start
Status: candidate

### Receipts index
Status: building
Phase: build
Next: write the index renderer
Verify remaining: the two fixtures and one native run

### Old idea
Status: rejected
MAP
  [ "$(fact_of "$p" 'opportunities')" = 'candidate=1 building=1 shipped=0 rejected=1 parked=0' ]
  facts "$p" | grep -qF 'building title Receipts index'
  facts "$p" | grep -qF 'building phase build'
  facts "$p" | grep -qF 'building next write the index renderer'
  facts "$p" | grep -qF 'building verify remaining the two fixtures and one native run'
}

@test "two building entries are visible as an inconsistency, and neither is changed" {
  p="$(new_project status-two-building)"
  before=""
  cat >"$p/.nightshift/opportunity-map.md" <<'MAP'
### One
Status: building
Next: first

### Two
Status: building
Next: second
MAP
  before="$(cksum <"$p/.nightshift/opportunity-map.md")"
  fact_of "$p" 'opportunities' | grep -qF 'building=2'
  # Only the first is detailed; the count is what says there is more than one.
  facts "$p" | grep -qF 'building title One'
  ! facts "$p" | grep -qF 'building title Two'
  [ "$(cksum <"$p/.nightshift/opportunity-map.md")" = "$before" ]
}

@test "the deadline is reported as time remaining, passed, or a finite list" {
  p="$(new_project status-deadline)"
  [ "$(fact_of "$p" 'deadline')" = 'none (finite list)' ]

  printf '%s\n' "$(($(date +%s) + 7500))" >"$p/.nightshift/deadline"
  fact_of "$p" 'deadline' | grep -qE '^2h0[0-9]m remaining$'

  printf '%s\n' "$(($(date +%s) - 60))" >"$p/.nightshift/deadline"
  [ "$(fact_of "$p" 'deadline')" = 'passed' ]
}

@test "a stop-work order is reported with its reason" {
  p="$(new_project status-stop)"
  [ "$(fact_of "$p" 'stop')" = 'absent' ]
  printf 'owner asked for the night to end\n' >"$p/.nightshift/STOP"
  [ "$(fact_of "$p" 'stop')" = 'present (owner asked for the night to end)' ]
}

@test "the watch reason carries its code and the label Doctor prints" {
  p="$(new_project status-watch-reason)"
  [ "$(fact_of "$p" 'watch reason')" = 'none' ]
  printf 'session-died\nnon-sensitive detail\n' >"$p/.nightshift/.watch-reason"
  fact_of "$p" 'watch reason' | grep -qE '^session-died \(.+\)$'
}

@test "a transition is a line whose subject is the shift changing hands" {
  p="$(new_project status-transitions)"
  cat >"$p/.nightshift/shift-log.md" <<'LOG'
- 2026-09-06T10:00:00Z P14 done. Seven commits. The shift ended cleanly after the handoff notes.
2026-09-06 11:00:00 · watchman armed · every 10m
2026-09-06 12:00:00 · watchman: the armed marker is gone — standing down
LOG
  facts "$p" | grep -qF 'transition watchman armed'
  facts "$p" | grep -qF 'transition watchman: the armed marker is gone'
  # An item summary that merely mentions a handoff is not a transition.
  ! facts "$p" | grep -qF 'P14 done'
}

@test "artifact ticks with no receipts are called out as unreviewable" {
  p="$(new_project status-artifact)"
  printf 'artifact\n' >"$p/.nightshift/work-mode"
  printf '## Items\n\n- [x] **P01 - done.**\n' >"$p/.nightshift/punch-list.md"
  facts "$p" | grep -qF 'receipts warning ticked items with no receipts are not reviewable completion'

  mkdir -p "$p/.nightshift/receipts"
  printf '# receipt\n' >"$p/.nightshift/receipts/p01.md"
  ! facts "$p" | grep -q '^receipts warning'
}

@test "nothing sensitive reaches the output" {
  p="$(new_project status-sensitive)"
  printf 'abc123-secret-session-id\nclaude\n' >"$p/.nightshift/.shift-session"
  printf 'session-died\n/Users/someone/.claude/projects/x/transcript.jsonl\n' \
    >"$p/.nightshift/.watch-reason"
  run bash "$STATUS" --project "$p"
  [ "$status" -eq 0 ]
  # The session is reported as bound, never by id, and no transcript path is echoed.
  printf '%s\n' "$output" | grep -qF 'session bound'
  ! printf '%s\n' "$output" | grep -qF 'abc123-secret-session-id'
  ! printf '%s\n' "$output" | grep -qF 'transcript.jsonl'
  ! printf '%s\n' "$output" | grep -qF '.claude/projects'
}

@test "status changes nothing it reads" {
  p="$(new_project status-readonly)"
  printf '## Items\n\n- [ ] **P01 - open.**\n' >"$p/.nightshift/punch-list.md"
  printf '# Parking lot\n\n- **A decision.**\n' >"$p/.nightshift/parking-lot.md"
  before="$(find "$p/.nightshift" -type f -exec cksum {} + | sort)"
  bash "$STATUS" --project "$p" >/dev/null 2>&1
  [ "$(find "$p/.nightshift" -type f -exec cksum {} + | sort)" = "$before" ]
}

@test "both hosts print the same facts for the same workspace" {
  ps_ready
  p="$(new_project status-twin)"
  printf '## Items\n\n- [x] **P01 - done.**\n\n- [ ] **P02 - live.**\n' \
    >"$p/.nightshift/punch-list.md"
  printf '# Parking lot\n\n- **A decision.**\n' >"$p/.nightshift/parking-lot.md"
  printf '# Snag log\n\n- **A snag.**\n' >"$p/.nightshift/snag-log.md"
  printf '### Thing\nStatus: building\nNext: do it\n' >"$p/.nightshift/opportunity-map.md"
  printf '%s\n' "$(($(date +%s) + 3600))" >"$p/.nightshift/deadline"

  bash "$STATUS" --project "$p" 2>/dev/null |
    sed -n '/^facts$/,/^resolved policy$/p' >"$p/posix.txt"
  pwsh -NoProfile -NonInteractive -File "$PS_STATUS" -Project "$p" 2>/dev/null |
    sed -n '/^facts$/,/^resolved policy$/p' >"$p/windows.txt"

  # The deadline is the one fact that moves while you look at it: the two runs are a second apart,
  # so it is held by shape here and by value in its own test.
  diff -u <(grep -v '^deadline ' "$p/posix.txt") <(grep -v '^deadline ' "$p/windows.txt")
  grep -qE '^deadline [0-9]+h[0-9]{2}m remaining$' "$p/posix.txt"
  grep -qE '^deadline [0-9]+h[0-9]{2}m remaining$' "$p/windows.txt"
}

@test "the Status skill renders and no longer teaches counting" {
  skill="$ROOT/plugins/nightshift/skills/status/SKILL.md"
  for phrase in 'counted **below the `## Items`' \
    'Count drafting-table boxes only after the first markdown' \
    'compare with `date +%s`' \
    'Count open `- [ ]` boxes in'; do
    if grep -qF "$phrase" "$skill"; then
      echo "Status still teaches counting: $phrase"
      return 1
    fi
  done
  grep -qF 'Render, never re-derive' "$skill"
  grep -qE 'ns"? status' "$skill"
  grep -qE 'ns"? doctor' "$skill"
  grep -qE 'ns"? inventory' "$skill"
  grep -qF 'read-only' "$skill"
  [ "$(wc -c <"$skill")" -lt 4096 ]
}

@test "a planted file where the receipts directory belongs is reported as itself" {
  p="$(new_project status-receipts-planted)"
  printf 'artifact\n' >"$p/.nightshift/work-mode"
  printf '## Items\n\n- [x] **P01 - done.**\n' >"$p/.nightshift/punch-list.md"
  # Not an empty night: something is there, and it is not a directory.
  printf 'not a directory\n' >"$p/.nightshift/receipts"
  facts "$p" | grep -qF 'receipts warning the artifact receipts path is not a usable directory'
  ! facts "$p" | grep -qF 'ticked items with no receipts'

  # An absent path is the empty case, not the planted one.
  rm -f "$p/.nightshift/receipts"
  facts "$p" | grep -qF 'receipts warning ticked items with no receipts are not reviewable completion'
  ! facts "$p" | grep -qF 'not a usable directory'
}
