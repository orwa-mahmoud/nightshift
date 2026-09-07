# Portable PowerShell coverage for the punch-list reader and the two contract digests.
# Run on macOS or Windows: pwsh -File tests/windows/punch-list-logic.ps1
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$repository = Resolve-Path (Join-Path $PSScriptRoot '../..')
Import-Module (Join-Path $repository 'plugins/nightshift/lib/Nightshift.psm1') -Force -DisableNameChecking
$failures = New-Object 'System.Collections.Generic.List[string]'

function Expect-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        $failures.Add($Message)
        Write-Host "FAIL: $Message"
    }
}

$root = Join-Path ([IO.Path]::GetTempPath()) ("ns-punch-list-logic-" + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $root -Force
try {
    $punch = Join-Path $root 'punch-list.md'
    $text = @'
# Punch list

## Shift

The contract the owner wrote. Nobody edits this while a shift runs.

## Gates

- Run the item's own checks before its commit.

## Items

- [x] **P01 - already done.**

  Its own sub-bullet.

- [ ] **P02 - the open one.**

  ```bash
  echo "fenced code inside an item"
  ```

  - a nested bullet
    - and a deeper one

- [ ] **P03 - the one after.**

## Notes

Trailing prose that belongs to no item.
'@
    [IO.File]::WriteAllText($punch, $text)

    $gates = @(Get-NSPunchGates $punch)
    Expect-True ($gates[0] -ceq '## Gates') 'the gates block starts at its own heading'
    Expect-True ($gates -ccontains "- Run the item's own checks before its commit.") `
        'the gates block carries its bullets'
    Expect-True (-not ($gates -ccontains '## Items')) 'the gates block stops at the next heading'

    $next = @(Get-NSPunchItem -PunchList $punch -Id '')
    Expect-True ($next[0] -ceq '- [ ] **P02 - the open one.**') 'next is the first still-open item'
    Expect-True ($next -ccontains '  - a nested bullet') 'a nested bullet comes through'
    Expect-True ($next -ccontains '    - and a deeper one') 'so does a deeper one'
    Expect-True ($next -ccontains '  echo "fenced code inside an item"') 'so does fenced code'
    Expect-True (-not ($next -ccontains '- [ ] **P03 - the one after.**')) 'and the next item does not'
    Expect-True ($next[$next.Count - 1].Trim() -cne '') 'an item does not end on a blank line'

    $named = @(Get-NSPunchItem -PunchList $punch -Id 'P01')
    Expect-True ($named[0] -ceq '- [x] **P01 - already done.**') 'a named item may already be ticked'
    Expect-True ((@(Get-NSPunchItem -PunchList $punch -Id 'P99')).Count -eq 0) 'an unknown id prints nothing'

    # The digests. A tick is invisible to them; anything else about an item is not.
    $contract = Get-NSPunchContractDigest $punch
    $items = Get-NSPunchItemsDigest $punch
    Expect-True ($contract -cmatch '^[0-9a-f]{64}$') 'the contract digest is 64 lowercase hex'
    Expect-True ($items -cmatch '^[0-9a-f]{64}$') 'the items digest is 64 lowercase hex'
    Expect-True ($contract -cne $items) 'the two digests are of different things'

    [IO.File]::WriteAllText($punch, ($text -creplace '- \[ \] \*\*P02', '- [x] **P02'))
    Expect-True ((Get-NSPunchContractDigest $punch) -ceq $contract) 'a tick leaves the contract alone'
    Expect-True ((Get-NSPunchItemsDigest $punch) -ceq $items) 'a tick is invisible to the items digest'

    # A Windows checkout converts line endings; a contract nobody touched has not moved.
    [IO.File]::WriteAllText($punch, (($text -creplace "`r`n", "`n") -creplace "`n", "`r`n"))
    Expect-True ((Get-NSPunchContractDigest $punch) -ceq $contract) 'CRLF is not a changed contract'
    Expect-True ((Get-NSPunchItemsDigest $punch) -ceq $items) 'CRLF is not a changed item'

    [IO.File]::WriteAllText($punch, ($text -creplace 'Nobody edits this while a shift runs\.', 'Anyone may.'))
    Expect-True ((Get-NSPunchContractDigest $punch) -cne $contract) 'an edited contract moves its digest'
    Expect-True ((Get-NSPunchItemsDigest $punch) -ceq $items) 'and leaves the items alone'

    [IO.File]::WriteAllText($punch, ($text -creplace 'P03 - the one after', 'P03 - something else'))
    Expect-True ((Get-NSPunchItemsDigest $punch) -cne $items) 'a reworded item moves the items digest'

    # The owner may change the gates mid-shift by design, so neither digest holds them still.
    [IO.File]::WriteAllText($punch, ($text -creplace "- Run the item's own checks before its commit\.", '- Run everything.'))
    Expect-True ((Get-NSPunchContractDigest $punch) -ceq $contract) 'the gates are outside the contract digest'
    Expect-True ((Get-NSPunchItemsDigest $punch) -ceq $items) 'and outside the items digest'

    # A snapshot that predates these fields compares nothing, which is not a mismatch.
    $ns = Join-Path $root '.nightshift'
    $null = New-Item -ItemType Directory -Path $ns -Force
    $armedPunch = Join-Path $ns 'punch-list.md'
    [IO.File]::WriteAllText($armedPunch, $text)
    [IO.File]::WriteAllText((Join-Path $ns 'shift-policy.json'), (@'
{"schemaVersion":1,"shiftId":"9f2c40ab77e51d63","createdAt":"2026-09-02T02:30:00Z",
 "source":"composition","verificationLevel":"final","toolingPolicy":"existing-tools"}
'@))
    [IO.File]::WriteAllText($armedPunch, ($text -creplace 'Nobody edits this while a shift runs\.', 'Anyone may.'))
    Expect-True ([string]::IsNullOrEmpty((Get-NSGateContractMismatch $root $armedPunch))) `
        'a policy without the fields compares nothing'

    # And with them recorded, a moved contract is named.
    [IO.File]::WriteAllText($armedPunch, $text)
    [IO.File]::WriteAllText((Join-Path $ns 'shift-policy.json'), (
            '{"schemaVersion":1,"shiftId":"9f2c40ab77e51d63","createdAt":"2026-09-02T02:30:00Z",' +
            '"source":"composition","verificationLevel":"final","toolingPolicy":"existing-tools",' +
            '"contractDigest":"' + (Get-NSPunchContractDigest $armedPunch) + '",' +
            '"itemsDigest":"' + (Get-NSPunchItemsDigest $armedPunch) + '"}'))
    Expect-True ([string]::IsNullOrEmpty((Get-NSGateContractMismatch $root $armedPunch))) `
        'an untouched list is no mismatch'

    [IO.File]::WriteAllText($armedPunch, ($text -creplace '- \[ \] \*\*P02', '- [x] **P02'))
    Expect-True ([string]::IsNullOrEmpty((Get-NSGateContractMismatch $root $armedPunch))) `
        'ticking a box is no mismatch'

    [IO.File]::WriteAllText($armedPunch, ($text -creplace 'Nobody edits this while a shift runs\.', 'Anyone may.'))
    $moved = Get-NSGateContractMismatch $root $armedPunch
    Expect-True ($moved -clike '*shift contract above the Items heading*') 'an edited contract is named'
    Expect-True ($moved -clike '*your ticks stand*') 'and the ticks are said to stand'

    [IO.File]::WriteAllText($armedPunch, ($text -creplace 'P03 - the one after', 'P03 - something else'))
    $moved = Get-NSGateContractMismatch $root $armedPunch
    Expect-True ($moved -clike '*reworded, removed or inserted*') 'a changed item is named'
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures.Count -gt 0) {
    Write-Host "punch-list-logic failed ($($failures.Count)):"
    foreach ($failure in $failures) { Write-Host " - $failure" }
    exit 1
}
Write-Host 'punch-list-logic passed'
exit 0
