#!/usr/bin/env bats
# Native status helper — evidence counts, policy view, and lifecycle lines.

bats_require_minimum_version 1.5.0

ROOT="$BATS_TEST_DIRNAME/.."
STATUS="$ROOT/plugins/nightshift/runtime/status.sh"
REF="$ROOT/plugins/nightshift/skills/nightshift/references"
CONFIG="$ROOT/plugins/nightshift/config"

load helpers

@test "status reports evidence counts and separate lifecycle lines" {
  p="$(new_project status-basic)"
  cp "$CONFIG/nightshift-rules-template.json" "$p/.nightshift/rules.json"
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
  cp "$CONFIG/nightshift-rules-template.json" "$p/.nightshift/rules.json"
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

# fact_from <report> <label> — a field of a status report the caller already captured.
fact_from() {
  printf '%s\n' "$1" | sed -n '/^facts$/,/^resolved policy$/p' | grep -E "^$2 " | head -1 | cut -d' ' -f"$(($(printf '%s' "$2" | wc -w) + 1))-"
}

# One report of a freshly set-up site, read by every case that starts from one.
setup_file() {
  local BATS_TEST_TMPDIR="$BATS_FILE_TMPDIR" p
  p="$(new_project fresh)"
  bash "$STATUS" --project "$p" >"$BATS_FILE_TMPDIR/fresh.out" 2>/dev/null
}

fresh_fact() { # <label> — a field of the fresh site's report
  fact_from "$(cat "$BATS_FILE_TMPDIR/fresh.out")" "$1"
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

@test "Filed pointers are not parked or snag entries" {
  p="$(new_project status-filed)"
  printf '# Parking lot\n\n- **First decision.**\n\nFiled: [2026-09-09](archive/2026-09-09/parking-lot.md)\n' \
    >"$p/.nightshift/parking-lot.md"
  printf '# Snag log\n\n- **A snag.**\n\nFiled: [2026-09-09](archive/2026-09-09/snag-log.md)\n' \
    >"$p/.nightshift/snag-log.md"
  run bash "$STATUS" --project "$p"
  [ "$status" -eq 0 ]
  [ "$(fact_from "$output" 'parked')" = '1' ]
  printf '%s\n' "$output" | grep -qF 'parked entry First decision.'
  ! printf '%s\n' "$output" | grep -qF 'Filed:' || false
  printf '%s\n' "$output" | grep -qF 'snag A snag.'
  ! printf '%s\n' "$output" | grep -qF 'snag Filed' || false
}

@test "parked entries are counted and titled, one line each" {
  p="$(new_project status-parked)"
  printf '# Parking lot\n\n- **First decision.** Body that should not appear.\n\n- **Second one.**\n' \
    >"$p/.nightshift/parking-lot.md"
  run bash "$STATUS" --project "$p"
  [ "$status" -eq 0 ]
  [ "$(fact_from "$output" 'parked')" = '2' ]
  printf '%s\n' "$output" | grep -qF 'parked entry First decision. Body that should not appear.'
  printf '%s\n' "$output" | grep -qF 'parked entry Second one.'
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
  ! fact_of "$p" 'staged' | grep -qF 'informational' || false
}

@test "the last three snag dispositions are reported, not the whole log" {
  p="$(new_project status-snags)"
  {
    printf '# Snag log\n\n'
    for n in 1 2 3 4 5; do printf -- '- **Snag %s.** Detail.\n\n' "$n"; done
  } >"$p/.nightshift/snag-log.md"
  run bash "$STATUS" --project "$p"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c '^snag ')" -eq 3 ]
  printf '%s\n' "$output" | grep -qF 'snag Snag 5. Detail.'
  ! printf '%s\n' "$output" | grep -qF 'snag Snag 1.' || false
}

@test "the shipped opportunity template counts as no opportunities at all" {
  p="$(new_project status-map-template)"
  cp "$REF/../assets/opportunity-map.md" "$p/.nightshift/opportunity-map.md" 2>/dev/null ||
    printf '# Opportunity map\n\n<!--\n### <title>\nStatus: building\nNext: <action>\n-->\n' \
      >"$p/.nightshift/opportunity-map.md"
  run bash "$STATUS" --project "$p"
  [ "$status" -eq 0 ]
  [ "$(fact_from "$output" 'opportunities')" = 'candidate=0 building=0 shipped=0 rejected=0 parked=0' ]
  ! printf '%s\n' "$output" | grep -q '^building ' || false
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
  run bash "$STATUS" --project "$p"
  [ "$status" -eq 0 ]
  [ "$(fact_from "$output" 'opportunities')" = 'candidate=1 building=1 shipped=0 rejected=1 parked=0' ]
  printf '%s\n' "$output" | grep -qF 'building title Receipts index'
  printf '%s\n' "$output" | grep -qF 'building phase build'
  printf '%s\n' "$output" | grep -qF 'building next write the index renderer'
  printf '%s\n' "$output" | grep -qF 'building verify remaining the two fixtures and one native run'
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
  run bash "$STATUS" --project "$p"
  [ "$status" -eq 0 ]
  fact_from "$output" 'opportunities' | grep -qF 'building=2'
  # Only the first is detailed; the count is what says there is more than one.
  printf '%s\n' "$output" | grep -qF 'building title One'
  ! printf '%s\n' "$output" | grep -qF 'building title Two' || false
  [ "$(cksum <"$p/.nightshift/opportunity-map.md")" = "$before" ]
}

@test "the deadline is reported as time remaining, passed, or a finite list" {
  [ "$(fresh_fact 'deadline')" = 'none (finite list)' ]
  p="$(new_project status-deadline)"

  printf '%s\n' "$(($(date +%s) + 7500))" >"$p/.nightshift/deadline"
  fact_of "$p" 'deadline' | grep -qE '^2h0[0-9]m remaining$'

  printf '%s\n' "$(($(date +%s) - 60))" >"$p/.nightshift/deadline"
  [ "$(fact_of "$p" 'deadline')" = 'passed' ]
}

@test "a stop-work order is reported with its reason" {
  [ "$(fresh_fact 'stop')" = 'absent' ]
  p="$(new_project status-stop)"
  printf 'owner asked for the night to end\n' >"$p/.nightshift/STOP"
  [ "$(fact_of "$p" 'stop')" = 'present (owner asked for the night to end)' ]
}

@test "status says whether a watchman is alive, and warns when an armed shift with work has none" {
  p="$(new_project status-watchman)"
  printf '## Items\n- [ ] **1. open.**\n' >"$p/.nightshift/punch-list.md"
  run bash "$STATUS" --project "$p"
  [ "$status" -eq 0 ]
  [ "$(fact_from "$output" 'watchman')" = 'none' ]
  fact_from "$output" 'watchman warning' | grep -qF 'nothing is watching it'
  printf '99999\n' >"$p/.nightshift/.watchman"
  run bash "$STATUS" --project "$p"
  [ "$status" -eq 0 ]
  [ "$(fact_from "$output" 'watchman')" = 'stale (pid 99999)' ]
  fact_from "$output" 'watchman warning' | grep -qF 'nothing is watching it'
  printf '%s\n' "$$" >"$p/.nightshift/.watchman"
  run bash "$STATUS" --project "$p"
  [ "$status" -eq 0 ]
  [ "$(fact_from "$output" 'watchman')" = "alive (pid $$)" ]
  [ -z "$(fact_from "$output" 'watchman warning')" ]
  # watchMinutes 0 is the owner saying no watchman, and a shift with nothing open needs none.
  rm "$p/.nightshift/.watchman"
  jq '.watchMinutes = 0' "$p/.nightshift/rules.json" >"$p/.nightshift/r.json"
  mv "$p/.nightshift/r.json" "$p/.nightshift/rules.json"
  run bash "$STATUS" --project "$p"
  [ "$status" -eq 0 ]
  [ -z "$(fact_from "$output" 'watchman warning')" ]
}

@test "the watch reason carries its code and the label Doctor prints" {
  [ "$(fresh_fact 'watch reason')" = 'none' ]
  p="$(new_project status-watch-reason)"
  printf 'session-died\nnon-sensitive detail\n' >"$p/.nightshift/.watch-reason"
  run bash "$STATUS" --project "$p"
  [ "$status" -eq 0 ]
  fact_from "$output" 'watch reason' | grep -qE '^session-died \(.+\)$'
  # With no watchman running, the reason is what the last one said, and reads that way.
  fact_from "$output" 'watch reason' | grep -qF 'the watchman that recorded it is not running'
}

@test "a stuck revival is a warning, not a watchman that is merely alive" {
  p="$(new_project status-recovery-stuck)"
  printf 'recovery-stuck\nunavailable:unrecorded\n' >"$p/.nightshift/.watch-reason"
  run bash "$STATUS" --project "$p"
  [ "$status" -eq 0 ]
  fact_from "$output" 'watch reason' | grep -qF 'recovery-stuck'
  fact_from "$output" 'watch reason' | grep -qF 'unattended revival is stuck'
  fact_from "$output" 'watchman warning' | grep -qF 'unattended revival and watchman clock-out are stuck'
  fact_from "$output" 'watchman warning' | grep -qF 'nothing to inherit'
}

@test "a transition is a line whose subject is the shift changing hands" {
  p="$(new_project status-transitions)"
  cat >"$p/.nightshift/shift-log.md" <<'LOG'
- 2026-09-06T10:00:00Z P14 done. Seven commits. The shift ended cleanly after the handoff notes.
2026-09-06 11:00:00 · watchman armed · every 10m
2026-09-06 12:00:00 · watchman: the armed marker is gone — standing down
LOG
  run bash "$STATUS" --project "$p"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qF 'transition watchman armed'
  printf '%s\n' "$output" | grep -qF 'transition watchman: the armed marker is gone'
  # An item summary that merely mentions a handoff is not a transition.
  ! printf '%s\n' "$output" | grep -qF 'P14 done' || false
}

@test "artifact ticks with no receipts are called out as unreviewable" {
  p="$(new_project status-artifact)"
  printf 'artifact\n' >"$p/.nightshift/work-mode"
  printf '## Items\n\n- [x] **P01 - done.**\n' >"$p/.nightshift/punch-list.md"
  run bash "$STATUS" --project "$p"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qF 'completion record per-item receipt'
  printf '%s\n' "$output" | grep -qF 'receipts missing model text 1'

  mkdir -p "$p/.nightshift/receipts"
  printf '# P01\n\nThe work is done.\n' >"$p/.nightshift/receipts/P01.md"
  run bash "$STATUS" --project "$p"
  [ "$status" -eq 0 ]
  ! printf '%s\n' "$output" | grep -q 'receipts missing model text' || false
}

@test "disabled receipts are a fact, never a missing-text warning" {
  p="$(new_project status-receipts-off)"
  jq '.receipts.enabled = false' "$p/.nightshift/rules.json" >"$p/.nightshift/rules.next"
  mv "$p/.nightshift/rules.next" "$p/.nightshift/rules.json"
  printf '## Items\n\n- [x] **P01 - done.**\n' >"$p/.nightshift/punch-list.md"
  run bash "$STATUS" --project "$p"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qF 'completion record none; the owner disabled receipts'
  ! printf '%s\n' "$output" | grep -q 'receipts missing model text' || false
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
  ! printf '%s\n' "$output" | grep -qF 'abc123-secret-session-id' || false
  ! printf '%s\n' "$output" | grep -qF 'transcript.jsonl' || false
  ! printf '%s\n' "$output" | grep -qF '.claude/projects' || false
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

@test "the Status skill renders and teaches no counting" {
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
  run bash "$STATUS" --project "$p"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qF 'receipts warning the artifact receipts path is not a usable directory'
  ! printf '%s\n' "$output" | grep -qF 'receipts missing model text' || false

  # An absent path is the empty case, not the planted one.
  rm -f "$p/.nightshift/receipts"
  run bash "$STATUS" --project "$p"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qF 'receipts missing model text 1'
  ! printf '%s\n' "$output" | grep -qF 'not a usable directory' || false
}

@test "status names a worker that is alive but idle" {
  p="$(new_project status-idle)"
  printf '## Items\n- [ ] **1. work.**\n' >"$p/.nightshift/punch-list.md"
  bash -c 'sleep 30' &
  worker=$!
  now="$(date +%s)"
  printf 'since=%s\ncpu=0\nbytes=0\npids=%s\nfails=0\nepisode=0\nstuck=0\nnoticed=0\nevidence=pulse stale, transcript unchanged, cpu +0.00s, no busy child\n' \
    "$((now - 120))" "$worker" >"$p/.nightshift/.idle-watch"
  run bash "$STATUS" --project "$p"
  kill "$worker" 2>/dev/null || true
  wait "$worker" 2>/dev/null || true
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qF 'worker alive but idle for 2 min — pulse stale, transcript unchanged, cpu +0.00s, no busy child'
}

@test "status from a conversation of one of two runs reports that conversation's run" {
  p="$(two_runs status-two-runs)"
  NS_CMD="$ROOT/plugins/nightshift/runtime/ns"
  out="$(env -u NIGHTSHIFT_RUN CLAUDE_PROJECT_DIR="$p" CLAUDE_CODE_SESSION_ID=sid-b "$NS_CMD" status 2>/dev/null)"
  [ "$(fact_from "$out" 'open item')" = '1. b first.' ]
  out="$(env -u NIGHTSHIFT_RUN CLAUDE_PROJECT_DIR="$p" CLAUDE_CODE_SESSION_ID=sid-a "$NS_CMD" status 2>/dev/null)"
  [ "$(fact_from "$out" 'open item')" = '1. a first.' ]
  # A run the caller names wins over the conversation's own.
  out="$(env CLAUDE_PROJECT_DIR="$p" CLAUDE_CODE_SESSION_ID=sid-a NIGHTSHIFT_RUN=b "$NS_CMD" status 2>/dev/null)"
  [ "$(fact_from "$out" 'open item')" = '1. b first.' ]
}

@test "native Windows status from a conversation of one of two runs reports that run" {
  ps_ready
  p="$(two_runs ps-status-two-runs)"
  NS_PS="$ROOT/plugins/nightshift/runtime/windows/ns.ps1"
  out="$(env -u NIGHTSHIFT_RUN CLAUDE_PROJECT_DIR="$p" CLAUDE_CODE_SESSION_ID=sid-b \
    pwsh -NoProfile -NonInteractive -File "$NS_PS" status 2>/dev/null)"
  [ "$(fact_from "$out" 'open item')" = '1. b first.' ]
  out="$(env -u NIGHTSHIFT_RUN CLAUDE_PROJECT_DIR="$p" CLAUDE_CODE_SESSION_ID=sid-a \
    pwsh -NoProfile -NonInteractive -File "$NS_PS" status 2>/dev/null)"
  [ "$(fact_from "$out" 'open item')" = '1. a first.' ]
}

@test "status lists every run with its state, open item and deadline, on both hosts" {
  p="$(two_runs status-every-run)"
  : >"$p/.nightshift/runs/a/STOP"
  printf '%s\n' "$(($(date +%s) + 7200))" >"$p/.nightshift/runs/b/run/deadline"
  out="$(env -u NIGHTSHIFT_RUN -u CLAUDE_CODE_SESSION_ID bash "$STATUS" --project "$p")"
  [ "$(fact_from "$out" 'run a')" = 'stopped, open item 1. a first., deadline none (finite list)' ]
  fact_from "$out" 'run b' | grep -qE '^armed, open item 1\. b first\., deadline [0-9]+h[0-9]{2}m remaining$'
  printf '%s\n' "$out" | grep -qx 'run none named (name one with --run for its facts)'
  # Named, the run's own facts follow the run lines.
  out="$(env -u NIGHTSHIFT_RUN -u CLAUDE_CODE_SESSION_ID bash "$STATUS" --project "$p" --run b)"
  printf '%s\n' "$out" | grep -qx 'run b'
  [ "$(fact_from "$out" 'open item')" = '1. b first.' ]
  run env -u NIGHTSHIFT_RUN -u CLAUDE_CODE_SESSION_ID bash "$STATUS" --project "$p" --run c
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -qF 'no run named c; runs: a b'
  ps_ready
  for args in "" b; do
    env -u NIGHTSHIFT_RUN -u CLAUDE_CODE_SESSION_ID bash "$STATUS" --project "$p" ${args:+--run "$args"} |
      sed -n '/^facts$/,/^resolved policy$/p' | grep -v '^run b armed' >"$p/posix.txt"
    env -u NIGHTSHIFT_RUN -u CLAUDE_CODE_SESSION_ID pwsh -NoProfile -NonInteractive -File "$PS_STATUS" -Project "$p" ${args:+-Run "$args"} |
      sed -n '/^facts$/,/^resolved policy$/p' | grep -v '^run b armed' >"$p/windows.txt"
    diff -u <(grep -v '^deadline ' "$p/posix.txt") <(grep -v '^deadline ' "$p/windows.txt")
  done
}

@test "with one run, status prints no run lines" {
  p="$(two_runs status-one-run)"
  rm -rf "$p/.nightshift/runs/b"
  out="$(env -u NIGHTSHIFT_RUN -u CLAUDE_CODE_SESSION_ID bash "$STATUS" --project "$p")"
  [ "$(fact_from "$out" 'open item')" = '1. a first.' ]
  if printf '%s\n' "$out" | grep -q '^run '; then return 1; fi
}
