#!/usr/bin/env bats
# What a shift cost, read from the records each host already keeps.
#
# The model does none of this and is told not to: on no host can it see its own usage from inside
# the conversation, so an instruction to measure it could only ever produce `unavailable`. These
# hold the runtime to the numbers instead — deduplicated where the host repeats itself, segmented
# where the counter changes underneath, and sliced at the ticks.

load helpers

LIB="$BATS_TEST_DIRNAME/../plugins/nightshift/lib/lib.sh"
CORE="$BATS_TEST_DIRNAME/../plugins/nightshift/hooks/shared/gate-core.sh"
FIX="$BATS_TEST_DIRNAME/fixtures/usage"

lib() { bash -c '. "$1"; shift; "$@"' _ "$LIB" "$@"; }
core() { bash -c '. "$1"; . "$2"; shift 2; "$@"' _ "$LIB" "$CORE" "$@"; }

@test "one response written as several lines is counted once" {
  # Three lines for req_a, two for req_b: five usage-bearing lines, two responses. Summing lines
  # instead would report input 44 against the 17 actually spent, and cache reads 7,000 against
  # 3,000 — the whole reason this deduplicates rather than dividing by a constant.
  run lib ns_usage_read_claude "$FIX/claude-multiline.jsonl"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | cut -f1)" = 'input=17,cache_write=100,cache_read=3000,output=16,reasoning=6' ]
  [ "$(printf '%s' "$output" | cut -f3)" = claude-opus-5 ]
  [ "$(printf '%s' "$output" | cut -f4)" = 2 ]
}

@test "reading from an offset returns only what was appended" {
  cp "$FIX/claude-multiline.jsonl" "$BATS_TEST_TMPDIR/t.jsonl"
  run lib ns_usage_read_claude "$BATS_TEST_TMPDIR/t.jsonl"
  [ "$status" -eq 0 ]
  offset="$(printf '%s' "$output" | cut -f2)"
  cat "$FIX/claude-appended.jsonl" >>"$BATS_TEST_TMPDIR/t.jsonl"

  run lib ns_usage_read_claude "$BATS_TEST_TMPDIR/t.jsonl" "$offset"
  [ "$status" -eq 0 ]
  # Only the appended response, not the whole file again.
  [ "$(printf '%s' "$output" | cut -f1)" = 'input=3,cache_write=50,cache_read=500,output=2,reasoning=1' ]
  [ "$(printf '%s' "$output" | cut -f4)" = 1 ]
}

@test "a transcript that has not grown reads as nothing, not as itself again" {
  run lib ns_usage_read_claude "$FIX/claude-multiline.jsonl"
  offset="$(printf '%s' "$output" | cut -f2)"
  run lib ns_usage_read_claude "$FIX/claude-multiline.jsonl" "$offset"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | cut -f4)" = 0 ]
}

@test "a truncated line yields no number rather than a partial one" {
  run lib ns_usage_read_claude "$FIX/claude-truncated.jsonl"
  [ "$status" -eq 0 ]
  # The line never closed, so nothing is claimed from it: zero responses, and every dimension zero
  # rather than the 4 input tokens that were legible before the cut.
  [ "$(printf '%s' "$output" | cut -f4)" = 0 ]
  [ "$(printf '%s' "$output" | cut -f1)" = 'input=0,cache_write=0,cache_read=0,output=0,reasoning=0' ]
}

@test "Codex is read from its running total, with its own overlap kept" {
  run lib ns_usage_read_codex "$FIX/codex-rollout.jsonl"
  [ "$status" -eq 0 ]
  # The last token_count line, not the first, and not a sum of them.
  [ "$(printf '%s' "$output" | cut -f1)" = 'input=1300,cache_write=0,cache_read=900,output=80,reasoning=18' ]
  # Codex counts cache inside input and reasoning inside output; the report says so rather than
  # rearranging the numbers.
  run lib ns_usage_overlap codex
  printf '%s' "$output" | grep -qF 'already inside the input figure'
}

@test "a Codex line that is not the documented shape is refused, not guessed at" {
  run lib ns_usage_read_codex "$FIX/codex-noshape.jsonl"
  [ "$status" -ne 0 ]
}

@test "Cursor is read from the payload, and silence is not zero" {
  run lib ns_usage_read_cursor "$(cat "$FIX/cursor-stop.json")"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | cut -f1)" = 'input=120,cache_write=40,cache_read=900,output=30' ]
  # Cursor reports no reasoning at all, so no reasoning figure is invented for it.
  printf '%s' "$output" | grep -qv reasoning

  run lib ns_usage_read_cursor "$(cat "$FIX/cursor-stop-nofields.json")"
  [ "$status" -ne 0 ]
}

# A segment is one continuous counter. Its contribution is what it spent after Nightshift began
# watching it, so a counter that was already running does not bill the shift for its past, and one
# that changes underneath opens a new segment rather than producing a negative.

ns() { printf '%s/.nightshift' "$1"; }

@test "a counter that was already running bills only what advances" {
  p="$BATS_TEST_TMPDIR/codex-mid"; mkdir -p "$(ns "$p")"
  lib ns_usage_mark "$(ns "$p")" arm
  lib ns_usage_record "$(ns "$p")" codex gpt-x rollout /r/a 0 'input=1000,output=50'
  lib ns_usage_mark "$(ns "$p")" P01
  run lib ns_usage_last_item "$(ns "$p")"
  [ "$(printf '%s' "$output" | cut -f1)" = 'input=0,output=0' ]

  lib ns_usage_record "$(ns "$p")" codex gpt-x rollout /r/a 0 'input=1300,output=80'
  lib ns_usage_mark "$(ns "$p")" P02
  run lib ns_usage_last_item "$(ns "$p")"
  [ "$(printf '%s' "$output" | cut -f1)" = 'input=300,output=30' ]
}

@test "a counter that goes backwards opens a segment instead of a negative" {
  p="$BATS_TEST_TMPDIR/backwards"; mkdir -p "$(ns "$p")"
  lib ns_usage_mark "$(ns "$p")" arm
  lib ns_usage_record "$(ns "$p")" codex gpt-x rollout /r/a 0 'input=1000,output=50'
  lib ns_usage_record "$(ns "$p")" codex gpt-x rollout /r/a 0 'input=1200,output=60'
  # The session restarted: the same path, a counter that begins again.
  lib ns_usage_record "$(ns "$p")" codex gpt-x rollout /r/a 0 'input=40,output=2'
  lib ns_usage_mark "$(ns "$p")" P01
  run lib ns_usage_total "$(ns "$p")"
  [ "$output" = 'input=200,output=10' ]
  run lib ns_usage_segments "$(ns "$p")"
  [ "$output" = 2 ]
}

@test "a revival is a second segment, and the two add up" {
  p="$BATS_TEST_TMPDIR/revival"; mkdir -p "$(ns "$p")"
  lib ns_usage_mark "$(ns "$p")" arm
  lib ns_usage_record "$(ns "$p")" claude claude-opus-5 transcript-incremental /t/a 10 'input=10,output=5'
  lib ns_usage_mark "$(ns "$p")" P01
  # The session died and the watchman revived it into a different transcript.
  lib ns_usage_record "$(ns "$p")" claude claude-opus-5 transcript-incremental /t/b 40 'input=7,output=1'
  lib ns_usage_mark "$(ns "$p")" P02

  run lib ns_usage_last_item "$(ns "$p")"
  [ "$(printf '%s' "$output" | cut -f1)" = 'input=7,output=1' ]
  run lib ns_usage_total "$(ns "$p")"
  [ "$output" = 'input=17,output=6' ]
  run lib ns_usage_segments "$(ns "$p")"
  [ "$output" = 2 ]
}

@test "the tick is the boundary: three short items and one long one come out distinct" {
  p="$BATS_TEST_TMPDIR/four"; mkdir -p "$(ns "$p")"
  lib ns_usage_mark "$(ns "$p")" arm
  for pair in "P01 5" "P02 9" "P03 4"; do
    set -- $pair
    lib ns_usage_record "$(ns "$p")" claude claude-opus-5 transcript-incremental /t/a 1 "input=$2,output=1"
    lib ns_usage_mark "$(ns "$p")" "$1"
    run lib ns_usage_last_item "$(ns "$p")"
    [ "$(printf '%s' "$output" | cut -f1)" = "input=$2,output=1" ] || { echo "$1 -> $output"; return 1; }
  done
  # A long item: many readings between its start and its tick, one figure at the end.
  for n in 100 250 700; do
    lib ns_usage_record "$(ns "$p")" claude claude-opus-5 transcript-incremental /t/a 1 "input=$n,output=2"
  done
  lib ns_usage_mark "$(ns "$p")" P04
  run lib ns_usage_last_item "$(ns "$p")"
  [ "$(printf '%s' "$output" | cut -f1)" = 'input=1050,output=6' ]
}

# The gate writes the two runtime lines into the item's section as it releases. The model writes
# neither, and the measurement never waits on the narrative.

@test "the gate writes usage and duration under the item it just closed" {
  p="$(new_project usage-gate)"
  printf '## Items\n- [x] **P01 - first.**\n- [ ] **P02 - open.**\n' >"$p/.nightshift/punch-list.md"
  printf '# Shift report\n\n### P01\n\nWhat it delivered.\n' >"$p/.nightshift/shift-report.md"
  lib ns_usage_record "$p/.nightshift" claude claude-opus-5 transcript-incremental /t/a 10 \
    'input=10,cache_write=100,cache_read=1000,output=5,reasoning=2'
  core ns_gate_usage_sync "$p/.nightshift" "$p" "$p/.nightshift/punch-list.md" 1

  grep -qF 'Usage: input 10 - cache_write 100 - cache_read 1000 - output 5 - reasoning 2' \
    "$p/.nightshift/shift-report.md" ||
    grep -qF 'input 10' "$p/.nightshift/shift-report.md"
  grep -qF 'Duration:' "$p/.nightshift/shift-report.md"
  grep -qF 'segments 1' "$p/.nightshift/shift-report.md"
  # The host's own overlap, so nothing downstream adds the same tokens twice.
  grep -qF 'Cache reads and cache writes are separate from the input figure' \
    "$p/.nightshift/shift-report.md"
  # It landed under P01's heading, not at the end of the file.
  awk '/^### P01/{f=1} f&&/^Usage:/{print "found"; exit}' "$p/.nightshift/shift-report.md" | grep -q found
}

@test "the gate writes the line even when the model has written no section yet" {
  p="$(new_project usage-nosection)"
  printf '## Items\n- [x] **P01 - first.**\n- [ ] **P02 - open.**\n' >"$p/.nightshift/punch-list.md"
  lib ns_usage_record "$p/.nightshift" claude claude-opus-5 transcript-incremental /t/a 10 'input=4,output=2'
  core ns_gate_usage_sync "$p/.nightshift" "$p" "$p/.nightshift/punch-list.md" 1
  [ -f "$p/.nightshift/shift-report.md" ]
  grep -qF '### P01' "$p/.nightshift/shift-report.md"
  grep -qF 'input 4' "$p/.nightshift/shift-report.md"
}

@test "a second stop with nothing newly ticked writes nothing twice" {
  p="$(new_project usage-idempotent)"
  printf '## Items\n- [x] **P01 - first.**\n- [ ] **P02 - open.**\n' >"$p/.nightshift/punch-list.md"
  lib ns_usage_record "$p/.nightshift" claude claude-opus-5 transcript-incremental /t/a 10 'input=4,output=2'
  core ns_gate_usage_sync "$p/.nightshift" "$p" "$p/.nightshift/punch-list.md" 1
  core ns_gate_usage_sync "$p/.nightshift" "$p" "$p/.nightshift/punch-list.md" 1
  [ "$(grep -c '^Usage:' "$p/.nightshift/shift-report.md")" -eq 1 ]
}

@test "a dimension the host does not report reads unavailable, never zero" {
  p="$(new_project usage-partial)"
  printf '## Items\n- [x] **P01 - first.**\n- [ ] **P02 - open.**\n' >"$p/.nightshift/punch-list.md"
  # Cursor reports no reasoning at all.
  lib ns_usage_record "$p/.nightshift" cursor cursor-model stop-payload cursor:c1 0 \
    'input=120,cache_write=40,cache_read=900,output=30'
  lib ns_usage_record "$p/.nightshift" cursor cursor-model stop-payload cursor:c1 0 \
    'input=200,cache_write=60,cache_read=1500,output=44'
  core ns_gate_usage_sync "$p/.nightshift" "$p" "$p/.nightshift/punch-list.md" 1
  grep -qF 'reasoning unavailable' "$p/.nightshift/shift-report.md"
}

@test "usage off measures nothing and keeps no snapshot" {
  p="$(new_project usage-off)"
  printf '## Items\n- [x] **P01 - first.**\n- [ ] **P02 - open.**\n' >"$p/.nightshift/punch-list.md"
  # Set through the policy the shift was composed with, which is where the setting is fixed.
  jq -n '{schemaVersion:1,shiftId:"9f2c40ab77e51d63",createdAt:"2026-09-02T00:00:00Z",
    source:"composition",verificationLevel:"none",toolingPolicy:"existing-tools",
    report:{usage:"off"}}' >"$p/.nightshift/shift-policy.json"
  core ns_gate_usage_sync "$p/.nightshift" "$p" "$p/.nightshift/punch-list.md" 1
  [ ! -e "$p/.nightshift/usage/marks.tsv" ]
  [ ! -e "$p/.nightshift/shift-report.md" ]
}

# The cadence is the runtime's arithmetic against the same marks and the same counter. None of it
# waits: the marks are written directly, so a twenty-minute window is tested in milliseconds.

# mark_at <ns> <epoch> <label> <total> — a mark as if it had been written then.
mark_at() {
  mkdir -p "$1/usage"
  printf '%s\t%s\t%s\n' "$2" "$3" "$4" >>"$1/usage/marks.tsv"
}

@test "the time cadence fires when the clock has moved, and not before" {
  p="$(new_project cadence-time)"
  printf '## Items\n- [ ] **P01 - open.**\n' >"$p/.nightshift/punch-list.md"
  now="$(date +%s)"
  mark_at "$p/.nightshift" "$((now - 60))" arm ''
  run lib ns_usage_progress_due "$p" P01
  [ "$status" -ne 0 ]

  rm -f "$p/.nightshift/usage/marks.tsv"
  mark_at "$p/.nightshift" "$((now - 25 * 60))" arm ''
  run lib ns_usage_progress_due "$p" P01
  [ "$status" -eq 0 ]
}

@test "the token cadence fires on the counter, not on the clock" {
  p="$(new_project cadence-tokens)"
  printf '## Items\n- [ ] **P01 - open.**\n' >"$p/.nightshift/punch-list.md"
  jq -n '{schemaVersion:1,shiftId:"9f2c40ab77e51d63",createdAt:"2026-09-02T00:00:00Z",
    source:"composition",verificationLevel:"none",toolingPolicy:"existing-tools",
    report:{progressMode:"tokens",progressTokens:1000,progressMinutes:20}}' \
    >"$p/.nightshift/shift-policy.json"
  now="$(date +%s)"
  mark_at "$p/.nightshift" "$((now - 60))" arm ''
  lib ns_usage_record "$p/.nightshift" claude m transcript-incremental /t/a 1 'input=100,output=50'
  run lib ns_usage_progress_due "$p" P01
  [ "$status" -ne 0 ]

  lib ns_usage_record "$p/.nightshift" claude m transcript-incremental /t/a 2 'input=800,output=200'
  run lib ns_usage_progress_due "$p" P01
  [ "$status" -eq 0 ]
}

@test "completion-only never falls due" {
  p="$(new_project cadence-completion)"
  printf '## Items\n- [ ] **P01 - open.**\n' >"$p/.nightshift/punch-list.md"
  jq -n '{schemaVersion:1,shiftId:"9f2c40ab77e51d63",createdAt:"2026-09-02T00:00:00Z",
    source:"composition",verificationLevel:"none",toolingPolicy:"existing-tools",
    report:{progressMode:"completion-only"}}' >"$p/.nightshift/shift-policy.json"
  mark_at "$p/.nightshift" "$(( $(date +%s) - 90 * 60 ))" arm ''
  run lib ns_usage_progress_due "$p" P01
  [ "$status" -ne 0 ]
}

@test "a token cadence with no counter to read falls back to the clock" {
  p="$(new_project cadence-fallback)"
  printf '## Items\n- [ ] **P01 - open.**\n' >"$p/.nightshift/punch-list.md"
  jq -n '{schemaVersion:1,shiftId:"9f2c40ab77e51d63",createdAt:"2026-09-02T00:00:00Z",
    source:"composition",verificationLevel:"none",toolingPolicy:"existing-tools",
    report:{progressMode:"tokens",progressTokens:1000,progressMinutes:20}}' \
    >"$p/.nightshift/shift-policy.json"
  # No readings at all: the host reported nothing usable.
  mark_at "$p/.nightshift" "$(( $(date +%s) - 25 * 60 ))" arm ''
  run lib ns_usage_progress_due "$p" P01
  [ "$status" -eq 0 ]
}

@test "refreshing the item's section restarts the window" {
  p="$(new_project cadence-window)"
  printf '## Items\n- [ ] **P01 - open.**\n' >"$p/.nightshift/punch-list.md"
  printf '# Shift report\n\n### P01\n\nWhere it has got to.\n' >"$p/.nightshift/shift-report.md"
  mark_at "$p/.nightshift" "$(( $(date +%s) - 25 * 60 ))" arm ''
  run lib ns_usage_progress_due "$p" P01
  [ "$status" -eq 0 ]

  # The model refreshes the paragraph. The window starts again from that moment, and nothing had
  # to tell the runtime it happened.
  printf '# Shift report\n\n### P01\n\nWhere it has got to, updated.\n' >"$p/.nightshift/shift-report.md"
  run lib ns_usage_progress_due "$p" P01
  [ "$status" -ne 0 ]
}

@test "a long idle stretch is one overdue notice, not one per minute" {
  p="$(new_project cadence-once)"
  printf '## Items\n- [ ] **P01 - open.**\n' >"$p/.nightshift/punch-list.md"
  : >"$p/.nightshift/.shift-armed"
  mark_at "$p/.nightshift" "$(( $(date +%s) - 90 * 60 ))" arm ''

  run bash -c '. "$1"; . "$2"; ns_pulse_report_due "$3/.nightshift" "$3"' _ \
    "$LIB" "$BATS_TEST_DIRNAME/../plugins/nightshift/hooks/pulse.sh" "$p"
  [ "$status" -eq 0 ]
  [ "$output" = 'report: progress update due for P01' ]
  [ -f "$p/.nightshift/.report-due" ]

  # The same notice stands rather than being written afresh: the marker is what a revived session
  # or a dropped hook output finds at the next pulse.
  run bash -c '. "$1"; . "$2"; ns_pulse_report_due "$3/.nightshift" "$3"' _ \
    "$LIB" "$BATS_TEST_DIRNAME/../plugins/nightshift/hooks/pulse.sh" "$p"
  [ "$output" = 'report: progress update due for P01' ]
}

@test "the notice reaches the model in each host's own context field" {
  run bash -c '. "$1"; . "$2"; ns_pulse_context claude "report: progress update due for P01"' _ \
    "$LIB" "$BATS_TEST_DIRNAME/../plugins/nightshift/hooks/pulse.sh"
  printf '%s' "$output" | jq -e '.hookSpecificOutput.additionalContext == "report: progress update due for P01"' >/dev/null

  run bash -c '. "$1"; . "$2"; ns_pulse_context cursor "report: progress update due for P01"' _ \
    "$LIB" "$BATS_TEST_DIRNAME/../plugins/nightshift/hooks/pulse.sh"
  printf '%s' "$output" | jq -e '.additional_context == "report: progress update due for P01"' >/dev/null

  # An ordinary pulse says nothing at all.
  run bash -c '. "$1"; . "$2"; ns_pulse_context claude ""' _ \
    "$LIB" "$BATS_TEST_DIRNAME/../plugins/nightshift/hooks/pulse.sh"
  [ -z "$output" ]
}

@test "a gap the runtime knows was not work is listed beside the wall clock, never subtracted" {
  p="$(new_project paused-gap)"
  printf '## Items\n- [x] **P01 - first.**\n- [ ] **P02 - open.**\n' >"$p/.nightshift/punch-list.md"
  now="$(date +%s)"
  mark_at "$p/.nightshift" "$((now - 3600))" arm ''
  # The session died half an hour in and was revived twenty minutes later.
  mkdir -p "$p/.nightshift/usage"
  printf '%s\t%s\n' "$((now - 1800))" "the session ended and the shift was revived" \
    >"$p/.nightshift/usage/pauses.tsv"
  lib ns_usage_record "$p/.nightshift" claude m transcript-incremental /t/a 1 'input=5,output=1'
  core ns_gate_usage_sync "$p/.nightshift" "$p" "$p/.nightshift/punch-list.md" 1

  grep -qF 'paused' "$p/.nightshift/shift-report.md"
  grep -qF 'the session ended and the shift was revived' "$p/.nightshift/shift-report.md"
  # The wall clock still reads the full hour: the gap is listed next to it, not taken out of it.
  grep -qE 'Duration: 1h 0m \(paused' "$p/.nightshift/shift-report.md"
}

@test "Windows reads the same fixtures to the same bytes" {
  if ! command -v pwsh >/dev/null 2>&1; then
    return 0
  fi
  module="$BATS_TEST_DIRNAME/../plugins/nightshift/lib/Nightshift.psm1"
  for pair in "claude-multiline.jsonl Read-NSUsageClaude" "claude-truncated.jsonl Read-NSUsageClaude" \
    "codex-rollout.jsonl Read-NSUsageCodex" "codex-revived.jsonl Read-NSUsageCodex"; do
    set -- $pair
    case "$2" in
      Read-NSUsageClaude) posix="$(lib ns_usage_read_claude "$FIX/$1")" ;;
      *) posix="$(lib ns_usage_read_codex "$FIX/$1")" || posix="" ;;
    esac
    run pwsh -NoProfile -NonInteractive -Command \
      "Import-Module '$module' -Force -DisableNameChecking; \$r = $2 '$FIX/$1'; if (\$null -ne \$r) { Write-Output \$r }"
    [ "$status" -eq 0 ]
    [ "$output" = "$posix" ] || { echo "$1: posix [$posix] windows [$output]"; return 1; }
  done

  # And the overlap sentence, which the report carries verbatim on either half.
  for host in claude codex cursor; do
    run pwsh -NoProfile -NonInteractive -Command \
      "Import-Module '$module' -Force -DisableNameChecking; Get-NSUsageOverlap '$host'"
    [ "$output" = "$(lib ns_usage_overlap "$host")" ] || { echo "$host overlap differs"; return 1; }
  done
}

@test "a subagent's usage is its own segment, not the parent's" {
  # A Task-spawned agent writes beside the session file. Its tokens are real spend and belong to
  # the shift; counting them inside the parent's counter would make a revived child that replays
  # history look like new work.
  p="$BATS_TEST_TMPDIR/subagent"
  mkdir -p "$p/.nightshift" "$p/proj/sess/subagents"
  cp "$FIX/claude-multiline.jsonl" "$p/proj/sess.jsonl"
  cp "$FIX/claude-subagent.jsonl" "$p/proj/sess/subagents/agent-1.jsonl"

  run lib ns_usage_subagents "$p/proj/sess.jsonl"
  [ "$status" -eq 0 ]
  [ "$output" = "$p/proj/sess/subagents/agent-1.jsonl" ]

  run lib ns_usage_read_claude "$p/proj/sess/subagents/agent-1.jsonl"
  [ "$(printf '%s' "$output" | cut -f1)" = 'input=9,cache_write=0,cache_read=300,output=6,reasoning=3' ]

  # A session with no children says so rather than failing loudly.
  run lib ns_usage_subagents "$FIX/claude-multiline.jsonl"
  [ "$status" -ne 0 ]
}

@test "a transcript that is not JSON yields nothing, not a number" {
  run lib ns_usage_read_claude "$FIX/claude-malformed.jsonl"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | cut -f4)" = 0 ]
  [ "$(printf '%s' "$output" | cut -f1)" = 'input=0,cache_write=0,cache_read=0,output=0,reasoning=0' ]
}

@test "a revived Codex segment counts only what it spent, not the history it replays" {
  # The second rollout starts its own counter. Adding the two cumulative totals would bill the
  # shift for the parent's whole history a second time.
  p="$BATS_TEST_TMPDIR/codex-revived"; mkdir -p "$(ns "$p")"
  lib ns_usage_mark_arm "$(ns "$p")"
  first="$(lib ns_usage_read_codex "$FIX/codex-rollout.jsonl")"
  lib ns_usage_record "$(ns "$p")" codex gpt-x rollout /r/first 0 "$(printf '%s' "$first" | cut -f1)"
  second="$(lib ns_usage_read_codex "$FIX/codex-revived.jsonl")"
  lib ns_usage_record "$(ns "$p")" codex gpt-x rollout /r/second 0 "$(printf '%s' "$second" | cut -f1)"

  run lib ns_usage_total "$(ns "$p")"
  # Neither rollout advanced past its own first reading, so the shift is billed for nothing —
  # rather than for the 1,300 and 40 those counters happened to start at.
  [ "$output" = 'input=0,cache_write=0,cache_read=0,output=0,reasoning=0' ]
  run lib ns_usage_segments "$(ns "$p")"
  [ "$output" = 2 ]
}

@test "a disabled report with an enabled handoff, and the reverse" {
  p="$(new_project usage-report-off)"
  printf '## Items\n- [x] **P01 - first.**\n- [ ] **P02 - open.**\n' >"$p/.nightshift/punch-list.md"
  : >"$p/.nightshift/.shift-armed"
  jq -n '{schemaVersion:1,shiftId:"9f2c40ab77e51d63",createdAt:"2026-09-02T00:00:00Z",
    source:"composition",verificationLevel:"none",toolingPolicy:"existing-tools",
    report:{enabled:false},handoff:{enabled:true}}' >"$p/.nightshift/shift-policy.json"
  # Reporting is off, so no notice is ever due — the handoff is a separate page and unaffected.
  run bash -c '. "$1"; . "$2"; ns_pulse_report_due "$3/.nightshift" "$3"' _ \
    "$LIB" "$BATS_TEST_DIRNAME/../plugins/nightshift/hooks/pulse.sh" "$p"
  [ "$status" -ne 0 ]
  run lib ns_handoff_enabled "$p"
  [ "$status" -eq 0 ]

  # And the reverse: the report stands while the owner wants no morning page.
  q="$(new_project usage-handoff-off)"
  printf '## Items\n- [ ] **P01 - open.**\n' >"$q/.nightshift/punch-list.md"
  : >"$q/.nightshift/.shift-armed"
  jq -n '{schemaVersion:1,shiftId:"9f2c40ab77e51d63",createdAt:"2026-09-02T00:00:00Z",
    source:"composition",verificationLevel:"none",toolingPolicy:"existing-tools",
    report:{enabled:true},handoff:{enabled:false}}' >"$q/.nightshift/shift-policy.json"
  mark_at "$q/.nightshift" "$(( $(date +%s) - 25 * 60 ))" arm ''
  run bash -c '. "$1"; . "$2"; ns_pulse_report_due "$3/.nightshift" "$3"' _ \
    "$LIB" "$BATS_TEST_DIRNAME/../plugins/nightshift/hooks/pulse.sh" "$q"
  [ "$status" -eq 0 ]
  run lib ns_handoff_enabled "$q"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------------------------
# A mark is taken when the work finishes, not when the session tries to stop.
#
# The gate marks on a stop attempt, so two items ticked between stops both got the reading taken at
# the stop: the first was billed everything since the previous mark and the second nothing. The
# pulse fires on the PostToolUse of the edit that ticks the box, so a mark taken there carries the
# reading at that moment. These drive the hooks as processes, because that is the only way the
# ordering is real.

PULSE="$BATS_TEST_DIRNAME/../plugins/nightshift/hooks/pulse.sh"
GATE="$BATS_TEST_DIRNAME/../plugins/nightshift/hooks/clock-out-gate.sh"

# three_open <name> — an armed workspace with three open items and an empty transcript.
three_open() {
  local p
  p="$(new_project "$1")"
  printf '# Punch list\n\n## Items\n\n- [ ] **A1 — one.**\n- [ ] **A2 — two.**\n- [ ] **A3 — three.**\n' \
    >"$p/.nightshift/punch-list.md"
  : >"$p/.nightshift/.shift-armed"
  printf 'sess-marks\n' >"$p/.nightshift/.shift-session"
  : >"$p/transcript.jsonl"
  printf '%s' "$p"
}

tick() { sed -i.bak "s/- \[ \] \*\*$2/- [x] **$2/" "$1/.nightshift/punch-list.md"; rm -f "$1/.nightshift/punch-list.md.bak"; }
grow() { cat "$FIX/claude-multiline.jsonl" >>"$1/transcript.jsonl"; }
fire() {
  run env CLAUDE_PROJECT_DIR="$1" bash "$PULSE" <<<"$(printf '{"session_id":"sess-marks","transcript_path":"%s/transcript.jsonl","cwd":"%s","tool_name":"Edit","tool_input":{}}' "$1" "$1")"
  [ "$status" -eq 0 ]
}
marks() { cat "$1/.nightshift/usage/marks.tsv"; }

@test "an item ticked in its own turn is marked with the reading from that turn" {
  p="$(three_open marks-at-tick)"
  grow "$p"; fire "$p"                     # arm, and a first reading
  tick "$p" A1; grow "$p"; fire "$p"       # A1 finishes here
  tick "$p" A2; tick "$p" A3; grow "$p"; fire "$p"

  [ "$(marks "$p" | wc -l | tr -d ' ')" -eq 4 ]
  [ "$(marks "$p" | sed -n '2p' | cut -f2)" = A1 ]
  # The point of the change: A1 does not carry the total that A2 does.
  a1="$(marks "$p" | sed -n '2p' | cut -f3)"
  a2="$(marks "$p" | sed -n '3p' | cut -f3)"
  [ -n "$a1" ] && [ "$a1" != "$a2" ] || { echo "A1=$a1 A2=$a2"; return 1; }
}

@test "two items ticked in one turn share that turn's reading, and the report says so" {
  # Not a defect and not hidden: one pulse, one reading. The alternative would be inventing a split.
  p="$(three_open marks-same-turn)"
  grow "$p"; fire "$p"
  tick "$p" A1; tick "$p" A2; grow "$p"; fire "$p"
  [ "$(marks "$p" | sed -n '2p' | cut -f3)" = "$(marks "$p" | sed -n '3p' | cut -f3)" ]
}

@test "the gate still catches up when no pulse ever fired" {
  p="$(three_open marks-catchup)"
  tick "$p" A1; tick "$p" A2; tick "$p" A3
  cp "$FIX/claude-multiline.jsonl" "$p/transcript.jsonl"
  run env CLAUDE_PROJECT_DIR="$p" bash "$GATE" <<<"$(printf '{"session_id":"sess-marks","transcript_path":"%s/transcript.jsonl","cwd":"%s","hook_event_name":"Stop"}' "$p" "$p")"
  [ "$(marks "$p" | wc -l | tr -d ' ')" -eq 4 ]
}

# ---------------------------------------------------------------------------------------------
# The shift starts where the transcript already stood.
#
# A conversation sets the night up before Start ever arms, and it writes to the same transcript the
# incremental reader is about to open. That reader begins at byte 0 for a file it has not seen, so
# every response spent planning the shift was billed to item one. The arm mark now stamps the
# transcript at its current size, and reading begins there.

@test "spend from before the shift armed is not billed to the first item" {
  p="$(three_open preshift-baseline)"
  cat "$FIX/claude-preshift.jsonl" >"$p/transcript.jsonl"
  before="$(wc -c <"$p/transcript.jsonl" | tr -d ' ')"
  fire "$p"

  # Arming records where the file already stood, and charges nothing for it.
  seg="$p/.nightshift/usage/segments.tsv"
  [ "$(cut -f5 "$seg")" = "$before" ]
  [ -z "$(cut -f7 "$seg")" ]

  # Only what arrives afterwards is the shift's.
  cat "$FIX/claude-multiline.jsonl" >>"$p/transcript.jsonl"
  fire "$p"
  [ "$(cut -f7 "$seg")" = 'input=17,cache_write=100,cache_read=3000,output=16,reasoning=6' ]
}

@test "a transcript first seen mid-shift is read from its beginning" {
  # Nothing in it predates the shift, so there is no baseline to skip.
  p="$(three_open preshift-latecomer)"
  : >"$p/transcript.jsonl"
  fire "$p"
  cat "$FIX/claude-multiline.jsonl" >>"$p/transcript.jsonl"
  fire "$p"
  [ "$(cut -f7 "$p/.nightshift/usage/segments.tsv")" = 'input=17,cache_write=100,cache_read=3000,output=16,reasoning=6' ]
}

# ---------------------------------------------------------------------------------------------
# Deduplication has to survive the read boundary as well as the read.
#
# One response is written as several lines carrying the same identity. A read that ends between
# them leaves the rest for next time, still carrying that identity, and counting it again bills the
# response twice. The reader hands back the last identity it counted and takes it on the next call.

@test "a response split across two reads is counted once" {
  p="$(new_project usage-carry)"
  cp "$FIX/claude-multiline.jsonl" "$p/whole.jsonl"
  head -3 "$FIX/claude-multiline.jsonl" >"$p/part.jsonl"

  # Cut inside req_a, which spans three lines.
  first="$(lib ns_usage_read_claude "$p/part.jsonl" 0 '')"
  [ "$(printf '%s' "$first" | cut -f5)" = req_a ]

  offset="$(printf '%s' "$first" | cut -f2)"
  carry="$(printf '%s' "$first" | cut -f5)"
  second="$(lib ns_usage_read_claude "$p/whole.jsonl" "$offset" "$carry")"

  # The two reads together must equal one read of the whole file, exactly.
  whole="$(lib ns_usage_read_claude "$p/whole.jsonl" 0 '')"
  sum="$(lib ns_usage_add "$(printf '%s' "$first" | cut -f1)" "$(printf '%s' "$second" | cut -f1)")"
  [ "$sum" = "$(printf '%s' "$whole" | cut -f1)" ] \
    || { echo "split=$sum whole=$(printf '%s' "$whole" | cut -f1)"; return 1; }
}

@test "without the carried identity the straddling response is billed twice" {
  # The defect this closes, stated as a measurement rather than a description.
  p="$(new_project usage-carry-absent)"
  cp "$FIX/claude-multiline.jsonl" "$p/whole.jsonl"
  head -3 "$FIX/claude-multiline.jsonl" >"$p/part.jsonl"
  first="$(lib ns_usage_read_claude "$p/part.jsonl" 0 '')"
  offset="$(printf '%s' "$first" | cut -f2)"
  naive="$(lib ns_usage_read_claude "$p/whole.jsonl" "$offset" '')"
  carried="$(lib ns_usage_read_claude "$p/whole.jsonl" "$offset" req_a)"
  [ "$(printf '%s' "$naive" | cut -f1)" != "$(printf '%s' "$carried" | cut -f1)" ]
}

@test "a transcript that shrank drops its carried identity with its offset" {
  # The identity describes a file that is no longer there, so keeping it could skip a real response.
  p="$(new_project usage-carry-shrank)"
  cp "$FIX/claude-multiline.jsonl" "$p/t.jsonl"
  size="$(wc -c <"$p/t.jsonl" | tr -d ' ')"
  head -1 "$FIX/claude-multiline.jsonl" >"$p/t.jsonl"
  run lib ns_usage_read_claude "$p/t.jsonl" "$size" req_a
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------------------------
# One shift's accounting does not become the next shift's.
#
# `usage/` holds the offsets a shift reached, the marks it took and the totals it accumulated. Left
# in place it made the next shift open transcripts where the last one stopped and add to its totals,
# so two nights became one number nobody could separate. The Start preflight renames it aside when
# it clears the other leftovers, and Archive files what it renamed.

@test "a finished shift's accounting is retired, not carried into the next one" {
  p="$(three_open usage-retire)"
  cp "$FIX/claude-multiline.jsonl" "$p/transcript.jsonl"
  fire "$p"
  cat "$FIX/claude-multiline.jsonl" >>"$p/transcript.jsonl"
  fire "$p"
  first="$(cut -f7 "$p/.nightshift/usage/segments.tsv")"
  [ -n "$first" ]

  # The shift ends and the next one clears the leftovers.
  printf 'shiftId=aaaa1111bbbb2222\n' >"$p/.nightshift/.ended"
  run lib ns_usage_retire "$p/.nightshift" aaaa1111bbbb2222
  [ "$status" -eq 0 ]
  [ -d "$p/.nightshift/usage-aaaa1111bbbb2222" ]
  [ ! -d "$p/.nightshift/usage" ]

  # The second shift starts clean and bills only what it spends. Its first pulse re-arms and
  # stamps the baseline where the transcript now stands, so what came before is not its spend.
  rm -f "$p/.nightshift/.ended"
  fire "$p"
  cat "$FIX/claude-multiline.jsonl" >>"$p/transcript.jsonl"
  fire "$p"
  second="$(cut -f7 "$p/.nightshift/usage/segments.tsv")"
  [ "$second" = 'input=17,cache_write=100,cache_read=3000,output=16,reasoning=6' ] \
    || { echo "second shift billed $second"; return 1; }
  # And the first shift's record still says what it said.
  [ "$(cut -f7 "$p/.nightshift/usage-aaaa1111bbbb2222/segments.tsv")" = "$first" ]
}

@test "retiring twice under one id keeps both records" {
  p="$(three_open usage-retire-twice)"
  cp "$FIX/claude-multiline.jsonl" "$p/transcript.jsonl"
  fire "$p"
  run lib ns_usage_retire "$p/.nightshift" dup
  [ "$status" -eq 0 ]
  fire "$p"
  run lib ns_usage_retire "$p/.nightshift" dup
  [ "$status" -eq 0 ]
  # Neither night's readings were written over the other's.
  [ "$(find "$p/.nightshift" -maxdepth 1 -name 'usage-dup*' -type d | wc -l | tr -d ' ')" -eq 2 ]
}

@test "retiring is silent when there is nothing to retire" {
  p="$(three_open usage-retire-none)"
  run lib ns_usage_retire "$p/.nightshift" someid
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
