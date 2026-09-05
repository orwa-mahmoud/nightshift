load helpers

HELPER="$BATS_TEST_DIRNAME/../plugins/nightshift/hooks/windows/clock-out-gate.ps1"
CORE="$BATS_TEST_DIRNAME/../plugins/nightshift/hooks/clock-out-gate.sh"
CODEX="$BATS_TEST_DIRNAME/../plugins/nightshift/hooks/codex/clock-out-gate.sh"
CURSOR="$BATS_TEST_DIRNAME/../plugins/nightshift/hooks/cursor/clock-out-gate.sh"

@test "Windows unreadable-rules clock-out names Setup like POSIX" {
  grep -qF '/nightshift:setup' "$CORE"
  grep -qF 'ask Nightshift to set up on Codex' "$CORE"
  grep -qF '.nightshift/rules.json' "$CORE"
  grep -qF '/nightshift:setup' "$HELPER"
  grep -qF 'ask Nightshift to set up on Codex' "$HELPER"
  grep -qF '.nightshift/rules.json clockOutMessage' "$HELPER"
  grep -qF 'stallMax/stallWarnEvery unreadable (.nightshift/rules.json absent or incomplete)' "$HELPER"
}

@test "Windows clock-out receipts commits match POSIX headless identity" {
  grep -qF 'user.email=nightshift@localhost' "$CORE"
  grep -qF 'commit.gpgsign=false' "$CORE"
  grep -qF 'receiptsAutoCommit' "$CORE"
  grep -qF 'user.email=nightshift@localhost' "$CODEX"
  grep -qF 'commit.gpgsign=false' "$CODEX"
  grep -qF 'receiptsAutoCommit' "$CODEX"
  grep -qF 'user.email=nightshift@localhost' "$HELPER"
  grep -qF 'commit.gpgsign=false' "$HELPER"
  grep -qF 'receiptsAutoCommit' "$HELPER"
}

@test "Windows stall progress token pairs POSIX artifact receipts" {
  grep -qF 'ns_gate_progress_token' "$CORE"
  grep -qF 'ns_gate_progress_token' "$CODEX"
  grep -qF 'Get-NSProgressToken' "$HELPER"
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
  grep -qF '[ -L "$NOTIFIED" ]' "$CORE"
  grep -qF '[ -L "$NOTIFIED" ]' "$CODEX"
  grep -qF 'Test-NSReparsePoint $notified' "$HELPER"
}

# order_of <file> <pattern> — the line number a call sits on, so an ordering claim is checked
# against the file rather than asserted in prose.
order_of() { grep -n "$2" "$1" | head -n1 | cut -d: -f1; }

@test "every clock-out renders the receipt before the archives truncate what it reads" {
  # The findings ledger is the receipt's only source for its evidence sections, and the archive
  # empties it. Every host renders first.
  for f in "$CORE" "$CODEX" "$CURSOR"; do
    r="$(order_of "$f" '^  render_morning_receipt ')"
    a="$(order_of "$f" '^  archive_findings_ledger ')"
    [ -n "$r" ] && [ -n "$a" ]
    [ "$r" -lt "$a" ]
  done
  r="$(order_of "$HELPER" '^    Save-NSMorningReceipt$')"
  e="$(order_of "$HELPER" '^    Save-NSEvidenceArchive$')"
  p="$(order_of "$HELPER" '^    Save-NSPolicyArchive$')"
  [ -n "$r" ] && [ -n "$e" ] && [ -n "$p" ]
  [ "$r" -lt "$e" ]
  [ "$r" -lt "$p" ]
}
