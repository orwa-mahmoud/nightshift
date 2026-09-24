#!/usr/bin/env bats
# Windows PowerShell 5.1 reads a script saved without a byte-order mark in the ANSI code page, so
# one character outside ASCII in a shipped script reaches the runtime as two others: a separator in
# a record, a pattern that matches the POSIX runtime's lines, a message. Every PowerShell file the
# plugin ships stays ASCII and spells such a character by its code.

PLUGIN="$BATS_TEST_DIRNAME/../plugins/nightshift"
MODULE="$PLUGIN/lib/Nightshift.psm1"

@test "every shipped PowerShell file is ASCII" {
  cd "$PLUGIN"
  hits="$(git ls-files '*.ps1' '*.psm1' | xargs perl -ne 'print "$ARGV:$.: $_" if /[^\x00-\x7f]/; close ARGV if eof')"
  [ -z "$hits" ] || { echo "$hits"; return 1; }
}

@test "the separators the POSIX runtime writes come out byte for byte" {
  command -v pwsh >/dev/null 2>&1 || skip 'pwsh is not installed'
  run pwsh -NoProfile -NonInteractive -Command "
    Import-Module '$MODULE' -Force -DisableNameChecking
    \$m = Get-Module Nightshift
    \$bytes = [Text.Encoding]::UTF8.GetBytes((& \$m { \$script:NSDot }))
    [Console]::Out.Write(([BitConverter]::ToString(\$bytes)) + \"\`n\")
    [Console]::Out.Write((Test-NSReviewHandled ('- a snag ' + [char]0x00B7 + ' fixed')).ToString() + \"\`n\")"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ "$(printf '%s\n' "$output" | sed -n 1p)" = 'C2-B7' ]
  [ "$(printf '%s\n' "$output" | sed -n 2p)" = 'True' ]
}
