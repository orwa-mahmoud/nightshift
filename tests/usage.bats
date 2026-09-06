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
