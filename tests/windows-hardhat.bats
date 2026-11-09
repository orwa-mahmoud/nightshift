load helpers

LOGIC="$BATS_TEST_DIRNAME/windows/hardhat-logic.ps1"
RUN="$BATS_TEST_DIRNAME/windows/run.ps1"
HELPER="$BATS_TEST_DIRNAME/../plugins/nightshift/hooks/windows/hardhat.ps1"
CORE="$BATS_TEST_DIRNAME/../plugins/nightshift/hooks/shared/hardhat-core.sh"
PSM1="$BATS_TEST_DIRNAME/../plugins/nightshift/lib/Nightshift.psm1"

WRAPPER="$BATS_TEST_DIRNAME/../plugins/nightshift/hooks/hardhat.sh"

@test "Windows CI runs the portable hardhat expected-email suite" {
  [ -f "$LOGIC" ]
  grep -qF 'hardhat-logic.ps1' "$RUN"
  grep -qF 'NIGHTSHIFT_EXPECTED_EMAIL' "$RUN"
  grep -qF 'committer identity' "$LOGIC"
  grep -qF "repository's configured identity" "$LOGIC"
}

@test "Windows hardhat expected-email logic passes when pwsh is present" {
  if ! command -v pwsh >/dev/null 2>&1; then
    return 0
  fi
  run pwsh -NoProfile -NonInteractive -File "$LOGIC"
  if [ "$status" -ne 0 ]; then
    printf '%s\n' "$output"
  fi
  [ "$status" -eq 0 ]
}

@test "Windows toolDeny repairs name Setup like POSIX" {
  grep -qF '/nightshift:setup on Claude Code; ask Nightshift to set up on Codex' "$WRAPPER"
  grep -qF '/nightshift:setup on Claude Code; ask Nightshift to set up on Codex' "$CORE"
  grep -qF "Fix \$(Get-NSLayoutName \$script:ns 'rules') or run Setup again (/nightshift:setup on Claude Code; ask Nightshift to set up on Codex)." "$HELPER"
  grep -qF 'run Setup again (/nightshift:setup on Claude Code; ask Nightshift to set up on Codex) to review the current template.' "$HELPER"
}

@test "Windows forbidden-command denials match POSIX wording" {
  grep -qF "the command matches the owner's forbidden list" "$CORE"
  grep -qF "the command matches the owner's forbidden list" "$HELPER"
  grep -qF '$(ns_hardhat_state_name parking-lot) and keep working' "$CORE"
  grep -qF "\$(Get-NSLayoutName \$script:ns 'parking-lot') and keep working" "$HELPER"
  grep -qF 'forbidden list' "$RUN"
  grep -qF 'forbidden list' "$LOGIC"
}

@test "Windows fence wording is unchanged and the dead-holder reclaim is wired" {
  windows_module_source | grep -qF 'BLOCKED: this shift is being recovered in another process. Wait or issue STOP from a separate session; reopening the recorded conversation stays blocked while that worker holds the lease.'
  windows_module_source | grep -qF 'BLOCKED: this shift continued in a recovered process. Reopen the recorded conversation before using tools here.'
  windows_module_source | grep -qF 'function Reclaim-NSLeaseRecorded'
  windows_module_source | grep -qF 'lease reclaimed by the recorded conversation after a dead recovery attempt'
  grep -qF 'Test-NSTrustedShiftControl' "$HELPER"
  grep -qF 'lease reclaimed by the recorded conversation after a dead recovery attempt' "$LOGIC"
  grep -qF 'a live recovery worker still fences the recorded conversation' "$LOGIC"
  grep -qF 'the Stop helper is allowed through a live foreign lease' "$LOGIC"
  grep -qF 'a disarmed site holds nobody' "$LOGIC"
}

@test "Windows hardhat lease-reclaim logic passes when pwsh is present" {
  if ! command -v pwsh >/dev/null 2>&1; then
    return 0
  fi
  run pwsh -NoProfile -NonInteractive -File "$LOGIC"
  if [ "$status" -ne 0 ]; then
    printf '%s\n' "$output"
  fi
  [ "$status" -eq 0 ]
}
