load helpers

LOGIC="$BATS_TEST_DIRNAME/windows/morning-receipt-logic.ps1"
RUN="$BATS_TEST_DIRNAME/windows/run.ps1"
WIN="$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/windows"
HOOK="$BATS_TEST_DIRNAME/../plugins/nightshift/hooks/windows/clock-out-gate.ps1"
MODULE="$BATS_TEST_DIRNAME/../plugins/nightshift/lib/Nightshift.psm1"

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

@test "the receipt renders the six frozen sections and the four views" {
  grep -qF "\$script:NSReceiptSectionTitle['shift'] = '## Shift'" "$MODULE"
  grep -qF "\$script:NSReceiptSectionTitle['baseline'] = '## Baseline'" "$MODULE"
  grep -qF "\$script:NSReceiptSectionTitle['changed'] = '## What changed'" "$MODULE"
  grep -qF "\$script:NSReceiptSectionTitle['parked'] = '## Parked'" "$MODULE"
  grep -qF "\$script:NSReceiptSectionTitle['unsupported'] = '## Unsupported / unmeasured'" "$MODULE"
  grep -qF "\$script:NSReceiptSectionTitle['next'] = '## Next'" "$MODULE"
  grep -qF "\$script:NSReceiptViewSections['owner'] = @('shift', 'baseline', 'changed', 'parked', 'unsupported', 'next')" "$MODULE"
  grep -qF "\$script:NSReceiptViewSections['reviewer'] = @('baseline', 'changed')" "$MODULE"
  grep -qF "\$script:NSReceiptViewSections['release'] = @('shift', 'changed')" "$MODULE"
  grep -qF "\$script:NSReceiptViewSections['artifact'] = @('shift', 'parked', 'unsupported', 'next')" "$MODULE"
}

@test "section 1 always carries the three honesty lines" {
  grep -qF "\$script:NSReceiptLabels['verified'] = 'Verified'" "$MODULE"
  grep -qF "\$script:NSReceiptLabels['disabled'] = 'Disabled by owner'" "$MODULE"
  grep -qF "\$script:NSReceiptLabels['unavailable'] = 'Unavailable'" "$MODULE"
  grep -qF "\$script:NSReceiptVerifiedNoneFormat = 'none {0} verification level {1} (owner)'" "$MODULE"
  grep -qF "\$script:NSReceiptVerifiedMalformedFormat" "$MODULE"
  grep -qF 'Get-NSMorningReceiptsLine' "$MODULE"
  grep -qF '[index](./README.md)' "$MODULE"
}

@test "the clock-out gate writes the receipt at the end, best effort" {
  grep -qF 'Save-NSMorningReceipt' "$HOOK"
  grep -qF 'Write-NSMorningReceiptFile' "$HOOK"
  grep -qF 'never blocks the release' "$HOOK"
  grep -qF "\$script:NSReceiptFileFormat = 'morning-{0}-{1}.md'" "$MODULE"
  grep -qF 'Get-NSMorningReceiptPath' "$MODULE"
}

# A record leaves live storage because the shift is closed and its archived copy verified, never
# because of what it is called. Both hosts share that lifecycle now.
@test "the archive retires closed records by state, not by filename" {
  if grep -qF "morning-*.md" "$WIN/archive-receipts.ps1"; then
    echo "the Windows archive still decides by filename"
    return 1
  fi
  grep -qF 'Test-NSSameBytes' "$WIN/archive-receipts.ps1"
  grep -qF '$rotate = (-not $armed) -and $ended' "$WIN/archive-receipts.ps1"
  grep -qF 'a different record is already filed under that name' "$WIN/archive-receipts.ps1"
  # And the POSIX helper says the same thing.
  sh="$BATS_TEST_DIRNAME/../plugins/nightshift/runtime/archive-receipts.sh"
  grep -qF 'ROTATE=1' "$sh"
  grep -qF 'same_bytes' "$sh"
  grep -qF 'a different record is already filed under that name' "$sh"
}

@test "Windows morning-receipt logic covers every view and the zero-gate render" {
  grep -qF 'the owner view renders the six sections in interface order' "$LOGIC"
  grep -qF 'the reviewer view renders the baseline and the comparison' "$LOGIC"
  grep -qF 'the release view carries regressions only' "$LOGIC"
  grep -qF 'the artifact view omits the repository sections' "$LOGIC"
  grep -qF 'a zero-gate shift says nothing was verified and why' "$LOGIC"
  grep -qF 'a shift with no ledger omits the baseline section' "$LOGIC"
  grep -qF 'verification level none (owner)' "$LOGIC"
}

@test "Windows morning-receipt logic covers honesty and citation" {
  grep -qF 'every comparison row cites a record id' "$LOGIC"
  grep -qF 'a disabled check is never rendered as a check that passed' "$LOGIC"
  grep -qF 'a check the level skipped is reported as disabled, never as passed' "$LOGIC"
  grep -qF 'section 1 names the unavailable source' "$LOGIC"
  grep -qF 'the artifact view names no repository term' "$LOGIC"
  grep -qF 'every allowance carries its provenance' "$LOGIC"
  grep -qF 'an unreadable punch list reports Ending unknown, never done' "$LOGIC"
  grep -qF 'the page links the index and each ticked item' "$LOGIC"
  grep -qF 'an accepted policy is named at the top' "$LOGIC"
  grep -qF 'a missing file is named as absent, not as malformed' "$LOGIC"
  grep -qF 'the unreadable fixture is named as malformed' "$LOGIC"
}

@test "Windows morning-receipt logic covers the gate and the archive" {
  grep -qF 'the gate writes receipts/morning-<date>-<shiftId>.md at the end of the shift' "$LOGIC"
  grep -qF 'a receipt render failure never blocks the release' "$LOGIC"
  grep -qF 'a receipt render failure still clocks the shift out' "$LOGIC"
  grep -qF 'an armed shift keeps every live record, whatever it is called' "$LOGIC"
  grep -qF 'a closed and verified record leaves live storage' "$LOGIC"
  grep -qF 'the artifact receipt is retired on the same terms, not by its name' "$LOGIC"
  grep -qF 'the record already filed is never overwritten' "$LOGIC"
}

@test "Windows morning-receipt logic checks exact byte formatting and bash parity" {
  grep -qF 'Test-NSNoCarriageReturn' "$LOGIC"
  grep -qF 'Test-NSSingleTrailingNewline' "$LOGIC"
  grep -qF 'Test-NSHasBom' "$LOGIC"
  grep -qF 'byte-identical' "$LOGIC"
  grep -qF 'morning-receipt.sh' "$LOGIC"
  grep -qF 'parity leg not run' "$LOGIC"
}

@test "Windows morning-receipt logic passes when pwsh is present" {
  if ! command -v pwsh >/dev/null 2>&1; then
    skip 'pwsh not installed'
  fi
  run pwsh -NoProfile -NonInteractive -File "$LOGIC"
  [ "$status" -eq 0 ]
}
