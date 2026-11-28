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

function Expect-Equal {
    param($Expected, $Actual, [string]$Message)
    Expect-True (([string]$Expected) -ceq ([string]$Actual)) "$Message (expected '$Expected', got '$Actual')"
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

    # A list that moves during a shift is recorded in the shift log, never refused.
    $ns = Join-Path $root '.nightshift'
    $null = New-Item -ItemType Directory -Path $ns -Force
    $armedPunch = Join-Path $ns 'punch-list.md'
    $shiftLog = Get-NSLayoutPath $ns 'shift-log'
    [IO.File]::WriteAllText($armedPunch, $text)
    Expect-True (-not (Invoke-NSPunchListNote $ns $armedPunch)) 'the first reading records the list and logs nothing'
    Expect-True (-not (Invoke-NSPunchListNote $ns $armedPunch)) 'an untouched list logs nothing'
    [IO.File]::WriteAllText($armedPunch, ($text -creplace '- \[ \] \*\*P02', '- [x] **P02'))
    Expect-True (-not (Invoke-NSPunchListNote $ns $armedPunch)) 'ticking a box is no change'
    [IO.File]::WriteAllText($armedPunch, ($text -creplace 'Nobody edits this while a shift runs\.', 'Anyone may.'))
    Expect-True (Invoke-NSPunchListNote $ns $armedPunch) 'an edited contract is a change'
    $added = ($text -creplace '(?m)^## Notes', "- [ ] **P09 - a late addition.**`n`n## Notes") -creplace 'P03 - the one after', 'P03 - the one before'
    [IO.File]::WriteAllText($armedPunch, ($added -creplace 'Nobody edits this while a shift runs\.', 'Anyone may.'))
    Expect-True (Invoke-NSPunchListNote $ns $armedPunch) 'added and reworded items are a change'
    Remove-Item -LiteralPath $armedPunch -Force
    Expect-True (Invoke-NSPunchListNote $ns $armedPunch) 'a deleted punch list is a change'
    $logged = @([IO.File]::ReadAllLines($shiftLog) | Where-Object { $_.Contains('punch list changed: ') } |
            ForEach-Object { $_.Substring($_.IndexOf('punch list changed: ') + 'punch list changed: '.Length) })
    Expect-Equal 3 $logged.Count 'one shift-log line per reading that found a change'
    Expect-Equal 'the contract above ## Items changed' $logged[0] 'the contract change is named'
    Expect-Equal 'reworded "P03"; added "P09"' $logged[1] 'each item is named by its label, in list order'
    Expect-Equal 'the punch list is gone' $logged[2] 'a deleted list is named'
    [IO.File]::WriteAllText($armedPunch, $text)

    # Both runtimes record the same view of the same list, byte for byte, so a shift that moves
    # between hosts keeps one history.
    # Git's own bash, not another one earlier on PATH; Windows paths go in with forward slashes and
    # MSYS path conversion off.
    $bash = Get-Command bash -ErrorAction SilentlyContinue
    $git = Get-Command git -ErrorAction SilentlyContinue
    if ($null -ne $git) {
        $gitBash = Join-Path (Split-Path -Parent (Split-Path -Parent $git.Source)) 'bin/bash.exe'
        if (Test-Path -LiteralPath $gitBash -PathType Leaf) { $bash = $gitBash }
    }
    if ($null -ne $bash) {
        $savedNoConv = [Environment]::GetEnvironmentVariable('MSYS_NO_PATHCONV', 'Process')
        [Environment]::SetEnvironmentVariable('MSYS_NO_PATHCONV', '1', 'Process')
        try {
            $libPath = (Join-Path $repository 'plugins/nightshift/lib/lib.sh').Replace('\', '/')
            $posix = (& $bash --noprofile --norc -c '. "$1"; ns_punch_list_view "$2"' _ $libPath $armedPunch.Replace('\', '/')) -join "`n"
        }
        finally {
            [Environment]::SetEnvironmentVariable('MSYS_NO_PATHCONV', $savedNoConv, 'Process')
        }
        Expect-Equal $posix ((Get-NSPunchListView $armedPunch) -join "`n") 'the Windows list view matches the POSIX one'
    }

    # A hyphen inside a word is part of the title. A spaced dash introduces a suffix.
    $hyphen = (@'
# Punch list

## Items

- [x] **2. Make the packed Node-only build reproducible.**

- [ ] **3. Ship it {dash} already reviewed**

- [ ] **4. Re-index {dash} later**
'@).Replace('{dash}', [string][char]0x2014)
    [IO.File]::WriteAllText($punch, $hyphen)
    Expect-True (((Get-NSGateTickedLabels $punch) -join '|') -ceq '2. Make the packed Node-only build reproducible.') `
        'a hyphenated ticked title stays whole'
    $namedHyphen = @(Get-NSPunchItem -PunchList $punch -Id '2. Make the packed Node-only build reproducible.')
    Expect-True ($namedHyphen[0] -ceq '- [x] **2. Make the packed Node-only build reproducible.**') `
        'lookup by the whole hyphenated title finds the item'
    $reindex = @(Get-NSPunchItem -PunchList $punch -Id '4. Re-index')
    Expect-True ($reindex[0] -ceq ('- [ ] **4. Re-index ' + [char]0x2014 + ' later**')) `
        'an em-dash suffix is stripped and a hyphen inside the word stays'
    Expect-True ((@(Get-NSPunchItem -PunchList $punch -Id '2. Make the packed Node')).Count -eq 0) `
        'a truncated hyphenated id finds nothing'
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
