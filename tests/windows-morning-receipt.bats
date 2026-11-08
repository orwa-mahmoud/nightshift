load helpers

LOGIC="$BATS_TEST_DIRNAME/windows/morning-receipt-logic.ps1"
RUN="$BATS_TEST_DIRNAME/windows/run.ps1"
WIN="$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/windows"
HOOK="$BATS_TEST_DIRNAME/../plugins/nightshift/hooks/windows/clock-out-gate.ps1"

@test "Windows morning-receipt logic suite is registered with run.ps1" {
  [ -f "$LOGIC" ]
  grep -qF 'morning-receipt-logic.ps1' "$RUN"
}

@test "the Windows morning-receipt helper is native and thin" {
  [ -f "$WIN/morning-receipt.ps1" ]
  grep -qF 'Invoke-NSMorningReceiptCommand' "$WIN/morning-receipt.ps1"
  if grep -RE 'brew |npm install|pip install|python3|jq is required' "$WIN/morning-receipt.ps1"; then
    return 1
  fi
}

@test "the receipt renders the eleven sections and the four views" {
  windows_module_source | grep -qF "\$script:NSReceiptSectionTitle['shift'] = '## How it ended'"
  windows_module_source | grep -qF "\$script:NSReceiptSectionTitle['usage'] = '## Time and tokens'"
  windows_module_source | grep -qF "\$script:NSReceiptSectionTitle['items'] = '## Items'"
  windows_module_source | grep -qF "\$script:NSReceiptSectionTitle['review'] = '## Review first'"
  windows_module_source | grep -qF "\$script:NSReceiptSectionTitle['interruptions'] = '## Interruptions'"
  windows_module_source | grep -qF "\$script:NSReceiptSectionTitle['parked'] = '## Decisions for you'"
  windows_module_source | grep -qF "\$script:NSReceiptSectionTitle['snags'] = '## Found but not fixed'"
  windows_module_source | grep -qF "\$script:NSReceiptSectionTitle['baseline'] = '## Baseline'"
  windows_module_source | grep -qF "\$script:NSReceiptSectionTitle['changed'] = '## What changed'"
  windows_module_source | grep -qF "\$script:NSReceiptSectionTitle['architecture'] = '## Architecture'"
  windows_module_source | grep -qF "\$script:NSReceiptSectionTitle['unsupported'] = '## Unsupported / unmeasured'"
  windows_module_source | grep -qF "\$script:NSReceiptSectionTitle['next'] = '## Next step'"
  windows_module_source | grep -qF "\$script:NSReceiptViewSections['owner'] = @('shift', 'usage', 'items', 'review', 'interruptions', 'parked', 'snags', 'baseline', 'changed', 'architecture', 'unsupported', 'next')"
  windows_module_source | grep -qF "\$script:NSReceiptViewSections['reviewer'] = @('review', 'baseline', 'changed', 'architecture')"
  windows_module_source | grep -qF "\$script:NSReceiptViewSections['release'] = @('shift', 'changed')"
  windows_module_source | grep -qF "\$script:NSReceiptViewSections['artifact'] = @('shift', 'usage', 'items', 'review', 'interruptions', 'parked', 'snags', 'unsupported', 'next')"
}

@test "section 1 always carries the three honesty lines" {
  windows_module_source | grep -qF "\$script:NSReceiptLabels['verified'] = 'Verified'"
  windows_module_source | grep -qF "\$script:NSReceiptLabels['disabled'] = 'Disabled by owner'"
  windows_module_source | grep -qF "\$script:NSReceiptLabels['unavailable'] = 'Unavailable'"
  windows_module_source | grep -qF "\$script:NSReceiptVerifiedNoneFormat = 'none {0} verification level {1} (owner)'"
  windows_module_source | grep -qF "\$script:NSReceiptVerifiedMalformedFormat"
  windows_module_source | grep -qF 'Get-NSMorningReceiptsLine'
  windows_module_source | grep -qF '[index](./README.md)'
}

@test "the clock-out gate writes the receipt at the end, best effort" {
  local end="$BATS_TEST_DIRNAME/../plugins/nightshift/lib/Nightshift.07.ps1"
  grep -qF 'Invoke-NSShiftEnd' "$HOOK"
  grep -qF 'Write-NSMorningReceiptFile' "$end"
  grep -qF 'never blocks the release' "$end"
  windows_module_source | grep -qF "\$script:NSReceiptFileFormat = 'morning-{0}-{1}.md'"
  windows_module_source | grep -qF 'Get-NSMorningReceiptPath'
}

# A record leaves live storage because the shift is closed and its archived copy verified, never
# because of what it is called. Both hosts share that lifecycle now.
@test "the archive retires closed records by state, not by filename" {
  if grep -qF "morning-*.md" "$WIN/archive-receipts.ps1"; then
    echo "the Windows archive still decides by filename"
    return 1
  fi
  grep -qF 'Test-NSArchiveSame' "$WIN/archive-receipts.ps1"
  grep -qF '$rotate = (-not $armed) -and $ended' "$WIN/archive-receipts.ps1"
  grep -qF 'a different record is already filed under that name' "$WIN/archive-receipts.ps1"
  # And the POSIX helper says the same thing.
  sh="$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/archive-receipts.sh"
  grep -qF 'ROTATE=1' "$sh"
  grep -qF 'ns_archive_same' "$sh"
  grep -qF 'a different record is already filed under that name' "$sh"
}

@test "Windows morning-receipt logic passes when pwsh is present" {
  if ! command -v pwsh >/dev/null 2>&1; then
    skip 'pwsh not installed'
  fi
  run pwsh -NoProfile -NonInteractive -File "$LOGIC"
  [ "$status" -eq 0 ]
}
