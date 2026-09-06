LIB="$BATS_TEST_DIRNAME/../plugins/nightshift/lib/lib.sh"
STATUS="$BATS_TEST_DIRNAME/../plugins/nightshift/skills/status/SKILL.md"
DOCTOR="$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/doctor.sh"
DOCTOR_SKILL="$BATS_TEST_DIRNAME/../plugins/nightshift/skills/doctor/SKILL.md"

CODES="completed owner-stop owner-disarm stale-pid invalid-session exhausted-retry unknown-wedge revived stand-down wrong-host deadline clean-session-end esc-standby silent-standby non-resumable-session unreadable-rules fresh-fallback unsupported-state process-evidence-unavailable clock-out-failed recovery-scope-unavailable"

@test "every shipped reason code has a stable label" {
  for c in $CODES; do
    label="$(bash -c '. "$1"; ns_reason_label "$2"' _ "$LIB" "$c")"
    [ -n "$label" ] || { echo "empty label: $c"; return 1; }
    [ "$label" != "unknown watchman outcome" ] || { echo "unlisted code: $c"; return 1; }
  done
}

@test "status and Doctor render the same shared reason file" {
  grep -qF '.watch-reason' "$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/status.sh"
  grep -qF 'ns_reason_label' "$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/status.sh"
  grep -qF 'Get-NSReasonLabel' \
    "$BATS_TEST_DIRNAME/../plugins/nightshift/lib/Nightshift.psm1"
  grep -qF 'ns_reason_code' "$DOCTOR"
  grep -qF 'ns_reason_label' "$DOCTOR"
  grep -qF '.watch-reason' "$DOCTOR_SKILL" || grep -qF 'watchman reason' "$DOCTOR"
}

@test "status reads session and watchman liveness from Doctor" {
  grep -qF 'recorded pid' "$STATUS"
  grep -qF 'watchman pid' "$STATUS"
  grep -qF 'reimplement liveness' "$STATUS"
  grep -qF 'recorded pid' "$DOCTOR"
  grep -qF 'watchman pid' "$DOCTOR"
}

@test "Windows reason allow-list matches the shared codes" {
  psm1="$BATS_TEST_DIRNAME/../plugins/nightshift/lib/Nightshift.psm1"
  grep -qF 'function Write-NSReason' "$psm1"
  for c in $CODES; do
    grep -qF "'$c'" "$psm1" || { echo "missing in Write-NSReason: $c"; return 1; }
  done
}

@test "recording a reason strips controls and rejects unknown codes" {
  ns="$BATS_TEST_TMPDIR/ns"
  mkdir -p "$ns"
  bash -c '. "$1"; ns_record_reason "$2" revived "$(printf "ok\tdetail\nextra")"' _ "$LIB" "$ns"
  [ "$(sed -n 1p "$ns/.watch-reason")" = "revived" ]
  if grep -q $'\t' "$ns/.watch-reason"; then
    return 1
  fi
  bash -c '. "$1"; ns_record_reason "$2" not-a-real-code' _ "$LIB" "$ns"
  [ "$(sed -n 1p "$ns/.watch-reason")" = "stand-down" ]
}

LOGIC="$BATS_TEST_DIRNAME/windows/reason-label-logic.ps1"
RUN="$BATS_TEST_DIRNAME/windows/run.ps1"

@test "Windows CI runs the portable watchman reason-label suite" {
  [ -f "$LOGIC" ]
  grep -qF 'reason-label-logic.ps1' "$RUN"
  grep -qF 'Get-NSReasonLabel' "$LOGIC"
  grep -qF 'process-evidence-unavailable' "$LOGIC"
}

@test "Windows reason labels match POSIX when pwsh is present" {
  if ! command -v pwsh >/dev/null 2>&1; then
    return 0
  fi
  run pwsh -NoProfile -NonInteractive -File "$LOGIC"
  [ "$status" -eq 0 ]
  while IFS=$'\t' read -r code label; do
    [ -n "$code" ] || continue
    posix="$(bash -c '. "$1"; ns_reason_label "$2"' _ "$LIB" "$code")"
    [ "$posix" = "$label" ] || {
      echo "mismatch $code: posix='$posix' win='$label'" >&2
      return 1
    }
  done <<< "$output"
}
