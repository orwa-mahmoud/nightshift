load helpers

HELPER="$BATS_TEST_DIRNAME/../plugins/nightshift/hooks/windows/clock-out-gate.ps1"
CORE="$BATS_TEST_DIRNAME/../plugins/nightshift/hooks/clock-out-gate.sh"
CODEX="$BATS_TEST_DIRNAME/../plugins/nightshift/hooks/codex/clock-out-gate.sh"
CURSOR="$BATS_TEST_DIRNAME/../plugins/nightshift/hooks/cursor/clock-out-gate.sh"

@test "Windows unreadable-rules clock-out names Setup like POSIX" {
  grep -qF '/nightshift:setup' "$CORE"
  grep -qF 'ask Nightshift to set up on Codex' "$CORE"
  grep -qF '$(ns_layout_name "$NS" rules) clockOutMessage' "$CORE"
  grep -qF 'stallMax/stallWarnEvery unreadable ($(ns_layout_name "$NS" rules) absent or incomplete)' "$CORE"
  grep -qF '/nightshift:setup' "$HELPER"
  grep -qF 'ask Nightshift to set up on Codex' "$HELPER"
  grep -qF "\$(Get-NSLayoutName \$ns 'rules') clockOutMessage" "$HELPER"
  grep -qF "stallMax/stallWarnEvery unreadable (\$(Get-NSLayoutName \$ns 'rules') absent or incomplete)" "$HELPER"
}

@test "Windows clock-out receipts commits match POSIX headless identity" {
  shared="$BATS_TEST_DIRNAME/../plugins/nightshift/hooks/shared/gate-core.sh"
  ps="$BATS_TEST_DIRNAME/../plugins/nightshift/lib/Nightshift.07.ps1"
  grep -qF 'ns_shift_end' "$CORE"
  grep -qF 'ns_shift_end' "$CODEX"
  grep -qF 'ns_shift_end' "$CURSOR"
  grep -qF 'Invoke-NSShiftEnd' "$HELPER"
  grep -qF 'user.email=nightshift@localhost' "$shared"
  grep -qF 'commit.gpgsign=false' "$shared"
  grep -qF 'receiptsAutoCommit' "$shared"
  grep -qF 'user.email=nightshift@localhost' "$ps"
  grep -qF 'commit.gpgsign=false' "$ps"
  grep -qF 'receiptsAutoCommit' "$ps"
}

@test "Windows unreadable punch list does not clock out as 0 open" {
  grep -qF '$counts.Readable' "$HELPER"
  grep -qF 'PUNCH_UNREADABLE' "$CORE"
  grep -qF 'PUNCH_UNREADABLE' "$CODEX"
  grep -qF 'PUNCH_UNREADABLE' "$CURSOR"
}

@test "Windows stall skip matches POSIX symlink fail-closed" {
  grep -qF '[ -L "$STALL" ]' "$CORE"
  grep -qF '[ -L "$STALL" ]' "$CODEX"
  grep -qF 'Test-NSReparsePoint $stall' "$HELPER"
  grep -qF '[ ! -L "$STALL" ]' "$CORE"
  grep -qF '[ ! -L "$STALL" ]' "$CODEX"
}

@test "Windows notified skip matches POSIX symlink fail-closed" {
  shared="$BATS_TEST_DIRNAME/../plugins/nightshift/hooks/shared/gate-core.sh"
  ps="$BATS_TEST_DIRNAME/../plugins/nightshift/lib/Nightshift.07.ps1"
  grep -qF '[ -L "$notified" ]' "$shared"
  grep -qF 'Test-NSReparsePoint $notified' "$ps"
}

# order_of <file> <pattern> — the line number a call sits on, so an ordering claim is checked
# against the file rather than asserted in prose.
order_of() { grep -n "$2" "$1" | head -n1 | cut -d: -f1; }

@test "every clock-out renders the receipt before the archives truncate what it reads" {
  # The findings ledger is the receipt's only source for its evidence sections, and the archive
  # empties it. Every host renders first.
  shared="$BATS_TEST_DIRNAME/../plugins/nightshift/hooks/shared/gate-core.sh"
  ps="$BATS_TEST_DIRNAME/../plugins/nightshift/lib/Nightshift.07.ps1"
  r="$(order_of "$shared" '^ *render_morning_receipt ')"
  a="$(order_of "$shared" '^ *archive_findings_ledger ')"
  [ -n "$r" ] && [ -n "$a" ]
  [ "$r" -lt "$a" ]
  r="$(order_of "$ps" 'Write-NSMorningReceiptFile')"
  e="$(order_of "$ps" 'Invoke-NSEvidenceArchive')"
  p="$(order_of "$ps" 'Invoke-NSShiftPolicyArchive')"
  [ -n "$r" ] && [ -n "$e" ] && [ -n "$p" ]
  [ "$r" -lt "$e" ]
  [ "$r" -lt "$p" ]
}
