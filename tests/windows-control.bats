load helpers

LOGIC="$BATS_TEST_DIRNAME/windows/control-logic.ps1"
RUN="$BATS_TEST_DIRNAME/windows/run.ps1"
PSM1="$BATS_TEST_DIRNAME/../plugins/nightshift/lib/Nightshift.psm1"

@test "Windows CI runs the portable Stop/Reset/Purge suite" {
  [ -f "$LOGIC" ]
  grep -qF 'control-logic.ps1' "$RUN"
  windows_module_source | grep -qF 'function Stop-NSShift'
  windows_module_source | grep -qF 'function Reset-NSShift'
  windows_module_source | grep -qF 'function Remove-NSNightshiftWorkspace'
  windows_module_source | grep -qF 'function Test-NSTrustedShiftControl'
  windows_module_source | grep -qF 'function Get-NSControlStartRefuseReason'
}

@test "Windows control logic passes when pwsh is present" {
  if ! command -v pwsh >/dev/null 2>&1; then
    return 0
  fi
  run pwsh -NoProfile -NonInteractive -File "$LOGIC"
  [ "$status" -eq 0 ]
}
