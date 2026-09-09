load helpers

LOGIC="$BATS_TEST_DIRNAME/windows/pulse-logic.ps1"
RUN="$BATS_TEST_DIRNAME/windows/run.ps1"

@test "Windows pulse logic suite is registered with run.ps1" {
  [ -f "$LOGIC" ]
  grep -qF 'pulse-logic.ps1' "$RUN"
}

@test "Windows pulse logic covers start, cadence, tick, and clock-out reminders" {
  grep -qF 'item-start injection fires once' "$LOGIC"
  grep -qF 'tick injection names the newly ticked item and file' "$LOGIC"
  grep -qF 'no injection when receipts.enabled is false' "$LOGIC"
  grep -qF 'clock-out lists receipts missing model text' "$LOGIC"
  grep -qF 'a stale marker naming 37 with 38 active produces a message naming 38' "$LOGIC"
}

@test "Windows pulse logic passes when pwsh is present" {
  if ! command -v pwsh >/dev/null 2>&1; then
    skip 'pwsh not installed'
  fi
  run pwsh -NoProfile -NonInteractive -File "$LOGIC"
  [ "$status" -eq 0 ]
}
