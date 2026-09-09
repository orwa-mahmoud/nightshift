load helpers

LOGIC="$BATS_TEST_DIRNAME/windows/doctor-logic.ps1"
RUN="$BATS_TEST_DIRNAME/windows/run.ps1"
HELPER="$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/windows/doctor.ps1"

@test "Windows CI runs the portable Doctor leftover and staged-work suite" {
  [ -f "$LOGIC" ]
  grep -qF 'doctor-logic.ps1' "$RUN"
  grep -qF 'leftover Shift contract and Gates' "$LOGIC"
  grep -qF 'staged drafting-table items=' "$LOGIC"
  grep -qF 'pending Hunt work orders=1' "$LOGIC"
  grep -qF 'STOP leftover' "$LOGIC"
  grep -qF 'leftover Shift contract and Gates still bind the next Hunt or Start cut' "$HELPER"
  grep -qF 'deadline=none' "$HELPER"
  grep -qF 'Get-NSUnixTime' "$HELPER"
  grep -qF 'artifact receipts' "$HELPER"
  grep -qF 'Get-NSReceiptsCount' "$HELPER"
  grep -qF 'Get-NSLatestReceipt' "$HELPER"
  grep -qF 'latest artifact receipt' "$HELPER"
  grep -qF 'ticked items have no receipt text' "$HELPER"
  grep -qF 'write the missing receipts under .nightshift/receipts/' "$HELPER"
  grep -qF 'artifact receipts path is not a usable directory' "$HELPER"
  grep -qF 'so write-receipt can land' "$HELPER"
  grep -qF 'unusableRecv' "$HELPER"
  grep -qF 'deadline is not a UNIX epoch' "$HELPER"
  grep -qF 'deadline path is not a usable file' "$HELPER"
  grep -qF 'Test-NSReparsePoint $deadlinePath' "$HELPER"
  grep -qF 'ended path is not a usable file' "$HELPER"
  grep -qF 'stall path is not a usable file' "$HELPER"
  grep -qF 'Test-NSReparsePoint $stallPath' "$HELPER"
  grep -qF 'session-end path is not a usable file' "$HELPER"
  grep -qF 'Test-NSReparsePoint $sessionEndPath' "$HELPER"
  grep -qF 'shift-pulse path is not a usable file' "$HELPER"
  grep -qF 'Test-NSReparsePoint $pulsePath' "$HELPER"
  grep -qF 'shift-session path is not a usable file' "$HELPER"
  grep -qF 'Test-NSReparsePoint $sessionPath' "$HELPER"
  grep -qF 'Test-NSRecordedProcess $spid $sstart' "$HELPER"
  grep -qF 'Test-NSRecordedProcess $wpid $wstart' "$HELPER"
  grep -qF 'watchRetrySeconds is empty' "$HELPER"
  grep -qF 'revivalPrompt is empty' "$HELPER"
  grep -qF 'freshRevivalPrompt is empty' "$HELPER"
  grep -qF 'revivalPrompt is empty' "$LOGIC"
  grep -qF 'work mode is malformed; treating the site as unusable until Setup rewrites it' "$HELPER"
  grep -qF 'a symlink work-mode is reported as malformed' "$LOGIC"
  grep -qF 'a symlink work-target is reported as unresolved' "$LOGIC"
  grep -qF 'work target could not be resolved; treating workspace as the code root' "$HELPER"
  grep -qF 'watchman pidfile path is not a usable file' "$HELPER"
  grep -qF 'Test-NSReparsePoint $watchmanPath' "$HELPER"
  grep -qF 'terminal clock-out failed without releasing the shift' "$HELPER"
  grep -qF 'lease held by a dead recovery attempt' "$HELPER"
  grep -qF 'the recorded conversation reclaims it on its next tool call' "$HELPER"
  grep -qF 'lease held by a dead recovery attempt' "$LOGIC"
}

@test "Windows Doctor leftover and staged-work logic passes when pwsh is present" {
  if ! command -v pwsh >/dev/null 2>&1; then
    return 0
  fi
  run pwsh -NoProfile -NonInteractive -File "$LOGIC"
  [ "$status" -eq 0 ]
}
