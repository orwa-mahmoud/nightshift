load helpers

LOGIC="$BATS_TEST_DIRNAME/windows/link-workspace-logic.ps1"
RUN="$BATS_TEST_DIRNAME/windows/run.ps1"
HELPER="$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/windows/link-workspace.ps1"

@test "Windows CI runs the portable link-workspace usage suite" {
  [ -f "$LOGIC" ]
  grep -qF 'link-workspace-logic.ps1' "$RUN"
  grep -qF 'unknown argument' "$HELPER"
}

@test "Windows link-workspace logic passes when pwsh is present" {
  if ! command -v pwsh >/dev/null 2>&1; then
    return 0
  fi
  run pwsh -NoProfile -NonInteractive -File "$LOGIC"
  [ "$status" -eq 0 ]
}
