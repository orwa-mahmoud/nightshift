#!/usr/bin/env bats
# What a block says when nothing has changed.
#
# The push is not in question here and never changes: a turn that ends with open boxes is blocked,
# with a reason the host feeds back into the conversation. What these hold is the repetition. A
# model ends turns to narrate many times per item, and each block was re-injecting a message it
# had read a few calls earlier. The gate may say so in one line — but only when it positively
# knows nothing moved, and every path still produces a block with a non-empty reason.

load helpers

LIB="$BATS_TEST_DIRNAME/../plugins/nightshift/lib/lib.sh"
CORE="$BATS_TEST_DIRNAME/../plugins/nightshift/hooks/shared/gate-core.sh"
GATE="$BATS_TEST_DIRNAME/../plugins/nightshift/hooks/clock-out-gate.sh"

# reminder <project> <mode> — a workspace whose owner chose that mode.
reminder() {
  jq --arg m "$2" '.clockOutReminderMode = $m' "$1/.nightshift/rules.json" >"$1/r.json"
  mv "$1/r.json" "$1/.nightshift/rules.json"
}

# block <project> — one Stop event through the real Claude gate, printing its reason.
block() {
  jq -nc '{hook_event_name:"Stop",session_id:"test-shift-session",transcript_path:""}' |
    env CLAUDE_PROJECT_DIR="$1" bash "$GATE"
}

reason() { printf '%s' "$1" | jq -r '.reason // empty'; }

# two_open <project> — a shift with work left, so every stop is blocked.
two_open() {
  printf '## Items\n- [ ] **P01 - first.**\n- [ ] **P02 - second.**\n' >"$1/.nightshift/punch-list.md"
}

@test "the first block of a shift carries the whole contract" {
  p="$(new_project rem-first)"
  two_open "$p"
  reminder "$p" changed-only
  run block "$p"
  [ "$status" -eq 0 ]
  [ -n "$(reason "$output")" ]
  reason "$output" | grep -qF 'DO NOT STOP'
}

@test "a second block with nothing moved carries the short line, and still blocks" {
  p="$(new_project rem-short)"
  two_open "$p"
  reminder "$p" changed-only
  run block "$p"
  first="$(reason "$output")"
  run block "$p"
  second="$(reason "$output")"

  printf '%s' "$output" | jq -e '.decision == "block"' >/dev/null
  [ -n "$second" ]
  [ "$second" != "$first" ]
  printf '%s' "$second" | grep -qF 'P01 still open'
  printf '%s' "$second" | grep -qF 'still binds'
}

@test "a tick brings the whole contract back" {
  p="$(new_project rem-tick)"
  two_open "$p"
  reminder "$p" changed-only
  run block "$p"
  run block "$p"
  reason "$output" | grep -qF 'P01 still open'

  printf '## Items\n- [x] **P01 - first.**\n- [ ] **P02 - second.**\n' >"$p/.nightshift/punch-list.md"
  run block "$p"
  reason "$output" | grep -qF 'DO NOT STOP'
}

@test "a stop-work order brings the whole contract back" {
  p="$(new_project rem-stop)"
  two_open "$p"
  reminder "$p" changed-only
  run block "$p"
  run block "$p"
  reason "$output" | grep -qF 'P01 still open'
  # The order is honoured on the next event, so this asserts the fingerprint moved, not the block.
  run bash -c '. "$1"; . "$2"; ns_gate_reminder_fingerprint 2 0 P01 yes pending quiet' _ "$LIB" "$CORE"
  before="$output"
  run bash -c '. "$1"; . "$2"; ns_gate_reminder_fingerprint 2 0 P01 no pending quiet' _ "$LIB" "$CORE"
  [ "$before" != "$output" ]
}

@test "the stall guard starting to warn brings the whole contract back" {
  # The guard's state, not its per-block tally. That tally rises on every stop attempt without
  # progress — which is exactly the repetition this shortens — so a fingerprint carrying it could
  # never compare equal twice and the short line would never be sent at all.
  run bash -c '. "$1"; . "$2"; ns_gate_reminder_fingerprint 2 0 P01 no pending quiet' _ "$LIB" "$CORE"
  quiet="$output"
  run bash -c '. "$1"; . "$2"; ns_gate_reminder_fingerprint 2 0 P01 no pending warned' _ "$LIB" "$CORE"
  [ "$quiet" != "$output" ]
}

@test "the stall state is quiet until the guard's own threshold, then warned" {
  f="$BATS_TEST_TMPDIR/stall"
  printf 'fingerprint\n2\n' >"$f"
  run bash -c '. "$1"; . "$2"; ns_gate_stall_state "$3" 3' _ "$LIB" "$CORE" "$f"
  [ "$output" = quiet ]
  printf 'fingerprint\n3\n' >"$f"
  run bash -c '. "$1"; . "$2"; ns_gate_stall_state "$3" 3' _ "$LIB" "$CORE" "$f"
  [ "$output" = warned ]
  # No file, an unreadable count, or a threshold of zero all read quiet rather than guessing.
  run bash -c '. "$1"; . "$2"; ns_gate_stall_state "$3/nope" 3' _ "$LIB" "$CORE" "$BATS_TEST_TMPDIR"
  [ "$output" = quiet ]
  printf 'fingerprint\nnot-a-number\n' >"$f"
  run bash -c '. "$1"; . "$2"; ns_gate_stall_state "$3" 3' _ "$LIB" "$CORE" "$f"
  [ "$output" = quiet ]
}

@test "a deadline passing brings the whole contract back" {
  run bash -c '. "$1"; . "$2"; ns_gate_reminder_fingerprint 2 0 P01 no pending quiet' _ "$LIB" "$CORE"
  pending="$output"
  run bash -c '. "$1"; . "$2"; ns_gate_reminder_fingerprint 2 0 P01 no passed quiet' _ "$LIB" "$CORE"
  [ "$pending" != "$output" ]
}

@test "a missing, empty or malformed comparison file means the whole contract" {
  p="$(new_project rem-unreadable)"
  two_open "$p"
  reminder "$p" changed-only
  fp="$(bash -c '. "$1"; . "$2"; ns_gate_reminder_fingerprint 2 0 P01 no pending quiet' _ "$LIB" "$CORE")"

  for state in missing empty malformed; do
    case "$state" in
      missing) rm -f "$p/.nightshift/.clock-out-reminder" ;;
      empty) : >"$p/.nightshift/.clock-out-reminder" ;;
      malformed) printf 'not-a-fingerprint\n' >"$p/.nightshift/.clock-out-reminder" ;;
    esac
    run bash -c '. "$1"; . "$2"; ns_gate_reminder_text "$3" "FULL TEXT" 2 0 P01 "$4"' \
      _ "$LIB" "$CORE" "$p" "$fp"
    [ "$output" = 'FULL TEXT' ] || { echo "$state gave: $output"; return 1; }
  done
}

@test "N short lines in a row, then the whole contract again" {
  p="$(new_project rem-limit)"
  two_open "$p"
  reminder "$p" changed-only
  jq '.clockOutReminderLimit = 3' "$p/.nightshift/rules.json" >"$p/r.json"
  mv "$p/r.json" "$p/.nightshift/rules.json"
  fp="$(bash -c '. "$1"; . "$2"; ns_gate_reminder_fingerprint 2 0 P01 no pending quiet' _ "$LIB" "$CORE")"

  # First call establishes the fingerprint and sends the full text.
  run bash -c '. "$1"; . "$2"; ns_gate_reminder_text "$3" "FULL TEXT" 2 0 P01 "$4"' _ "$LIB" "$CORE" "$p" "$fp"
  [ "$output" = 'FULL TEXT' ]
  # Then three short lines.
  for _ in 1 2 3; do
    run bash -c '. "$1"; . "$2"; ns_gate_reminder_text "$3" "FULL TEXT" 2 0 P01 "$4"' _ "$LIB" "$CORE" "$p" "$fp"
    [ "$output" != 'FULL TEXT' ] || { echo "went full too early"; return 1; }
    [ -n "$output" ]
  done
  # The limit is reached: the whole contract regardless.
  run bash -c '. "$1"; . "$2"; ns_gate_reminder_text "$3" "FULL TEXT" 2 0 P01 "$4"' _ "$LIB" "$CORE" "$p" "$fp"
  [ "$output" = 'FULL TEXT' ]
}

@test "a context reset means the whole contract, and the marker is consumed" {
  p="$(new_project rem-reset)"
  two_open "$p"
  reminder "$p" changed-only
  fp="$(bash -c '. "$1"; . "$2"; ns_gate_reminder_fingerprint 2 0 P01 no pending quiet' _ "$LIB" "$CORE")"
  run bash -c '. "$1"; . "$2"; ns_gate_reminder_text "$3" "FULL TEXT" 2 0 P01 "$4"' _ "$LIB" "$CORE" "$p" "$fp"
  run bash -c '. "$1"; . "$2"; ns_gate_reminder_text "$3" "FULL TEXT" 2 0 P01 "$4"' _ "$LIB" "$CORE" "$p" "$fp"
  [ "$output" != 'FULL TEXT' ]

  : >"$p/.nightshift/.context-reset"
  run bash -c '. "$1"; . "$2"; ns_gate_reminder_text "$3" "FULL TEXT" 2 0 P01 "$4"' _ "$LIB" "$CORE" "$p" "$fp"
  [ "$output" = 'FULL TEXT' ]
  [ ! -e "$p/.nightshift/.context-reset" ]
}

@test "full mode sends the whole contract every time, and so does a mode nobody can parse" {
  p="$(new_project rem-full)"
  two_open "$p"
  fp="$(bash -c '. "$1"; . "$2"; ns_gate_reminder_fingerprint 2 0 P01 no pending quiet' _ "$LIB" "$CORE")"
  for _ in 1 2 3; do
    run bash -c '. "$1"; . "$2"; ns_gate_reminder_text "$3" "FULL TEXT" 2 0 P01 "$4"' _ "$LIB" "$CORE" "$p" "$fp"
    [ "$output" = 'FULL TEXT' ]
  done

  reminder "$p" nonsense-mode
  for _ in 1 2; do
    run bash -c '. "$1"; . "$2"; ns_gate_reminder_text "$3" "FULL TEXT" 2 0 P01 "$4"' _ "$LIB" "$CORE" "$p" "$fp"
    [ "$output" = 'FULL TEXT' ]
  done
}

@test "an owner who empties their short line gets the whole contract, never an empty block" {
  p="$(new_project rem-empty-short)"
  two_open "$p"
  reminder "$p" changed-only
  jq '.clockOutReminder = ""' "$p/.nightshift/rules.json" >"$p/r.json"
  mv "$p/r.json" "$p/.nightshift/rules.json"
  fp="$(bash -c '. "$1"; . "$2"; ns_gate_reminder_fingerprint 2 0 P01 no pending quiet' _ "$LIB" "$CORE")"
  run bash -c '. "$1"; . "$2"; ns_gate_reminder_text "$3" "FULL TEXT" 2 0 P01 "$4"' _ "$LIB" "$CORE" "$p" "$fp"
  run bash -c '. "$1"; . "$2"; ns_gate_reminder_text "$3" "FULL TEXT" 2 0 P01 "$4"' _ "$LIB" "$CORE" "$p" "$fp"
  [ "$output" = 'FULL TEXT' ]
}

@test "every host makes the same decision on the same facts" {
  # The decision lives in the shared core, so the three POSIX gates cannot disagree about it —
  # and each one hands the result to its own host's block shape.
  for host in clock-out-gate.sh codex/clock-out-gate.sh cursor/clock-out-gate.sh; do
    f="$BATS_TEST_DIRNAME/../plugins/nightshift/hooks/$host"
    grep -qF 'ns_gate_reminder_text' "$f" || { echo "$host does not use the shared decision"; return 1; }
    grep -qF 'ns_gate_reminder_fingerprint' "$f" || { echo "$host builds no fingerprint"; return 1; }
  done
  win="$BATS_TEST_DIRNAME/../plugins/nightshift/hooks/windows/clock-out-gate.ps1"
  grep -qF 'Get-NSGateReminderText' "$win" || { echo "the Windows gate does not use it"; return 1; }
}

@test "Windows decides the same way on the same facts" {
  if ! command -v pwsh >/dev/null 2>&1; then
    return 0
  fi
  module="$BATS_TEST_DIRNAME/../plugins/nightshift/lib/Nightshift.psm1"
  run pwsh -NoProfile -NonInteractive -Command \
    "Import-Module '$module' -Force -DisableNameChecking; Get-NSGateReminderFingerprint 2 0 'P01' 'no' 'pending' 'quiet'"
  [ "$status" -eq 0 ]
  [ "$output" = "$(bash -c '. "$1"; . "$2"; ns_gate_reminder_fingerprint 2 0 P01 no pending quiet' _ "$LIB" "$CORE")" ]

  run pwsh -NoProfile -NonInteractive -Command \
    "Import-Module '$module' -Force -DisableNameChecking; Format-NSGateReminder 'P{item} {open} of {ticked}' 'P01' 2 5"
  [ "$output" = "$(bash -c '. "$1"; . "$2"; ns_gate_reminder_fill "P{item} {open} of {ticked}" P01 2 5' _ "$LIB" "$CORE")" ]
}
