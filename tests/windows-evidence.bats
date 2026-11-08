load helpers

LOGIC="$BATS_TEST_DIRNAME/windows/evidence-logic.ps1"
RUN="$BATS_TEST_DIRNAME/windows/run.ps1"

@test "Windows evidence logic suite is registered with run.ps1" {
  [ -f "$LOGIC" ]
  grep -qF 'evidence-logic.ps1' "$RUN"
}

@test "Windows evidence logic passes when pwsh is present" {
  if ! command -v pwsh >/dev/null 2>&1; then
    skip 'pwsh not installed'
  fi
  run pwsh -NoProfile -NonInteractive -File "$LOGIC"
  [ "$status" -eq 0 ]
}
