load helpers

LOGIC="$BATS_TEST_DIRNAME/windows/schedule-empty-logic.ps1"
RUN="$BATS_TEST_DIRNAME/windows/run.ps1"
HELPER="$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/windows/schedule.ps1"

@test "Windows CI runs the portable Schedule empty-list parked-work suite" {
  [ -f "$LOGIC" ]
  grep -qF 'schedule-empty-logic.ps1' "$RUN"
  grep -qF 'NOTE 1 parked Hunt work order' "$LOGIC"
  grep -qF 'Parked Hunt work orders: 1' "$LOGIC"
  grep -qF 'Drafting-table items: 1' "$LOGIC"
  grep -qF 'Note: the punch list has no open items' "$HELPER"
  grep -qF 'a scheduled start will refuse to arm' "$HELPER"
  grep -qF 'a scheduled start will refuse to arm' "$LOGIC"
  grep -qF '/nightshift:setup on Claude Code; ask Nightshift to set up on Codex' "$HELPER"
}

@test "Windows Schedule empty-list parked-work logic passes wherever pwsh runs" {
  if ! command -v pwsh >/dev/null 2>&1; then
    skip "pwsh not installed"
  fi
  run pwsh -NoProfile -NonInteractive -File "$LOGIC"
  [ "$status" -eq 0 ]
}
