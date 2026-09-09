load helpers

PURGE_LOGIC="$BATS_TEST_DIRNAME/windows/purge-workspace-logic.ps1"
RESET_LOGIC="$BATS_TEST_DIRNAME/windows/reset-shift-logic.ps1"
RUN="$BATS_TEST_DIRNAME/windows/run.ps1"
PURGE="$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/windows/purge-workspace.ps1"
RESET="$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/windows/reset-shift.ps1"

@test "Windows CI runs the Purge and Reset entry-point suites" {
  [ -f "$PURGE_LOGIC" ]
  [ -f "$RESET_LOGIC" ]
  grep -qF 'purge-workspace-logic.ps1' "$RUN"
  grep -qF 'reset-shift-logic.ps1' "$RUN"
  grep -qF 'Remove-NSNightshiftWorkspace' "$PURGE"
  grep -qF 'Reset-NSShift' "$RESET"
  if grep -qE 'ConfirmPath' "$RESET"; then
    return 1
  fi
}

@test "Windows Purge and Reset entry-point logic passes when pwsh is present" {
  if ! command -v pwsh >/dev/null 2>&1; then
    return 0
  fi
  run pwsh -NoProfile -NonInteractive -File "$PURGE_LOGIC"
  [ "$status" -eq 0 ]
  run pwsh -NoProfile -NonInteractive -File "$RESET_LOGIC"
  [ "$status" -eq 0 ]
}
