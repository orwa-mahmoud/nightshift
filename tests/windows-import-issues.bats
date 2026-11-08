load helpers

LOGIC="$BATS_TEST_DIRNAME/windows/import-issues-logic.ps1"
RUN="$BATS_TEST_DIRNAME/windows/run.ps1"
HELPER="$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/windows/import-issues.ps1"

@test "Windows CI runs the portable import-issues list/promote suite" {
  [ -f "$LOGIC" ]
  grep -qF 'import-issues-logic.ps1' "$RUN"
  grep -qF -- '-ListProposed' "$LOGIC"
  grep -qF -- '-Promote' "$LOGIC"
  grep -qF 'Review flags: destructive' "$LOGIC"
  grep -qF 'PositionalBinding = $false' "$HELPER"
  grep -qF '[IO.FileAttributes]::ReparsePoint' "$HELPER"
  if grep -qF -- '-Recurse' "$HELPER"; then
    return 1
  fi
}

@test "Windows import-issues list/promote logic passes when pwsh is present" {
  if ! command -v pwsh >/dev/null 2>&1; then
    return 0
  fi
  run pwsh -NoProfile -NonInteractive -File "$LOGIC"
  [ "$status" -eq 0 ]
}
