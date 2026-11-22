#!/usr/bin/env bats

LOGIC="$BATS_TEST_DIRNAME/windows/logic-runner-logic.ps1"
RUN="$BATS_TEST_DIRNAME/windows/run.ps1"

@test "the Windows logic runner is registered with run.ps1" {
  [ -f "$LOGIC" ]
  [ -f "$BATS_TEST_DIRNAME/windows/logic-runner.ps1" ]
  grep -qF 'logic-runner.ps1' "$RUN"
  grep -qF 'logic-runner-logic.ps1' "$RUN"
  grep -qF 'NIGHTSHIFT_LOGIC_DEGREE' "$RUN"
}

@test "serial and overlapped logic suites agree, and a failure or timeout names the suite" {
  if ! command -v pwsh >/dev/null 2>&1; then
    skip 'pwsh not installed'
  fi
  run pwsh -NoProfile -NonInteractive -File "$LOGIC"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q 'logic-runner-logic passed'
  printf '%s\n' "$output" | grep -q 'logic fail.ps1 fail'
  printf '%s\n' "$output" | grep -q 'logic slow.ps1 timeout'
}

@test "Windows PowerShell runs the same logic-runner check when it is installed" {
  if ! command -v powershell >/dev/null 2>&1 && ! command -v powershell.exe >/dev/null 2>&1; then
    skip 'Windows PowerShell is not installed'
  fi
  bin="$(command -v powershell || command -v powershell.exe)"
  run "$bin" -NoProfile -NonInteractive -File "$LOGIC"
  [ "$status" -eq 0 ]
}
