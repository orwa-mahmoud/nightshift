# Portable PowerShell coverage for Windows punch-list, draft, and order counts.
# Run on macOS or Windows: pwsh -File tests/windows/box-counts-logic.ps1
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

$root = Join-Path ([IO.Path]::GetTempPath()) ("ns-box-counts-logic-" + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $root -Force
try {
    $punch = Join-Path $root 'punch-list.md'
    [IO.File]::WriteAllText($punch, @'
# Punch List

- [ ] this is prose, not work

## Items
- [ ] **1. real.**
- [x] **2. done.**
'@)
    $boxes = Get-NSBoxCounts $punch
    Expect-True ($boxes.Open -eq 1) "Items-scoped open count (got $($boxes.Open))"
    Expect-True ($boxes.Ticked -eq 1) "Items-scoped ticked count (got $($boxes.Ticked))"
    Expect-True ($boxes.Total -eq 2) "Items-scoped total (got $($boxes.Total))"

    $missing = Get-NSBoxCounts (Join-Path $root 'missing-punch.md')
    Expect-True ($missing.Open -eq 0 -and $missing.Ticked -eq 0 -and $missing.Total -eq 0) `
        'a missing punch list counts as zero'
    Expect-True $missing.Readable 'a missing punch list is readable-as-absent, not unreadable'

    $onWindows = $env:OS -eq 'Windows_NT'
    if (-not $onWindows) {
        $locked = Join-Path $root 'locked-punch.md'
        [IO.File]::WriteAllText($locked, "## Items`n- [ ] **1. real.**`n")
        & chmod 000 $locked
        try {
            $lockedCounts = Get-NSBoxCounts $locked
            Expect-True (-not $lockedCounts.Readable) `
                'an unreadable punch list is not counted as zero open'
        }
        finally {
            & chmod 644 $locked
        }
    }

    $orders = Join-Path $root 'work-orders.md'
    [IO.File]::WriteAllText($orders, "# Work Orders`n`n- [ ] **one.**`n- [x] **done.**`n- [ ] **two.**`n")
    Expect-True ((Get-NSOpenBoxesInFile $orders) -eq 2) 'whole-file order count includes every open box'
    Expect-True ((Get-NSOpenBoxesInFile (Join-Path $root 'missing-orders.md')) -eq 0) `
        'a missing work-order file counts as zero'

    $drafts = Join-Path $root 'drafting-table.md'
    [IO.File]::WriteAllText($drafts, @'
```text
- [ ] **1. example only.**
```

---

- [ ] **Real draft.**
- [x] **Already promoted.**
'@)
    Expect-True ((Get-NSOpenDrafts $drafts) -eq 1) 'drafts after the first rule are counted'
    Expect-True ((Get-NSOpenDrafts (Join-Path $root 'missing-drafts.md')) -eq 0) `
        'a missing drafting table counts as zero'

    $hyphen = Join-Path $root 'hyphen-punch.md'
    [IO.File]::WriteAllText($hyphen, @'
# Punch List

## Items
- [x] **2. Make the packed Node-only build reproducible.**
- [ ] **3. Ship it — already reviewed**
- [ ] **4. Re-index — later**
'@)
    Expect-True ((Get-NSGateItemLabel $hyphen 1) -ceq '2. Make the packed Node-only build reproducible.') `
        'box-count lists still expose a hyphenated title whole'
    $openHyphen = @(Get-NSPunchItem -PunchList $hyphen -Id '')
    Expect-True ($openHyphen[0] -ceq '- [ ] **3. Ship it — already reviewed**') `
        'the first open item is chosen by the spaced-dash suffix rule'
    $reindex = @(Get-NSPunchItem -PunchList $hyphen -Id '4. Re-index')
    Expect-True ($reindex[0] -ceq '- [ ] **4. Re-index — later**') `
        'Re-index keeps its hyphen after the suffix is stripped'
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures.Count -gt 0) {
    Write-Host "box-counts-logic failed ($($failures.Count)):"
    foreach ($failure in $failures) { Write-Host " - $failure" }
    exit 1
}
Write-Host 'box-counts-logic passed'
exit 0
