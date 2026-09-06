# Portable PowerShell coverage for the Status fact readers.
# Run on macOS or Windows: pwsh -File tests/windows/status-facts-logic.ps1
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

$root = Join-Path ([IO.Path]::GetTempPath()) ("ns-status-facts-" + [guid]::NewGuid().ToString('N'))
$ns = Join-Path $root '.nightshift'
$null = New-Item -ItemType Directory -Path $ns -Force
try {
    $punch = Join-Path $ns 'punch-list.md'
    [IO.File]::WriteAllText($punch, "## Items`n`n- [x] **P01 - done.**`n`n- [ ] **P02 - the live one.**`n`n  Detail.`n")
    Expect-True ((Get-NSStatusOpenTitle $punch) -ceq 'P02 - the live one.') `
        "the current open item is named (got '$(Get-NSStatusOpenTitle $punch)')"

    [IO.File]::WriteAllText($punch, "## Items`n`n- [x] **P01 - done.**`n")
    Expect-True ([string]::IsNullOrEmpty((Get-NSStatusOpenTitle $punch))) 'a ticked list has no open item'

    $parking = Join-Path $ns 'parking-lot.md'
    [IO.File]::WriteAllText($parking, "# Parking lot`n`n- **First decision.** Body.`n`n- **Second one.**`n")
    Expect-True ((Get-NSStatusEntryCount $parking) -eq 2) 'parked entries are counted'
    $titles = @(Get-NSStatusEntryTitles $parking 0)
    Expect-True ($titles -ccontains 'First decision. Body.') 'the first parked title is taken'
    Expect-True ($titles -ccontains 'Second one.') 'the second parked title is taken'

    $snags = Join-Path $ns 'snag-log.md'
    $body = "# Snag log`n`n"
    foreach ($n in 1..5) { $body += "- **Snag $n.** Detail.`n`n" }
    [IO.File]::WriteAllText($snags, $body)
    $last = @(Get-NSStatusEntryTitles $snags 3)
    Expect-True ($last.Count -eq 3) "only the last three dispositions (got $($last.Count))"
    Expect-True ($last -ccontains 'Snag 5. Detail.') 'the most recent disposition is kept'
    Expect-True (-not ($last -ccontains 'Snag 1. Detail.')) 'the oldest is dropped'

    # The map ships commented out; a template heading is not an opportunity.
    $map = Join-Path $ns 'opportunity-map.md'
    [IO.File]::WriteAllText($map, "# Opportunity map`n`n<!--`n### <title>`nStatus: building`n-->`n")
    Expect-True ((Get-NSStatusOpportunityCounts $map) -ceq 'candidate=0 building=0 shipped=0 rejected=0 parked=0') `
        'the shipped template counts as nothing'
    Expect-True ((@(Get-NSStatusBuilding $map)).Count -eq 0) 'the template has no building entry'

    [IO.File]::WriteAllText($map, @'
<!--
### <title>
Status: building
-->

### Faster cold start
Status: candidate

### Receipts index
Status: building
Phase: build
Next: write the index renderer
Verify remaining: the two fixtures and one native run

### Old idea
Status: rejected
'@)
    Expect-True ((Get-NSStatusOpportunityCounts $map) -ceq 'candidate=1 building=1 shipped=0 rejected=1 parked=0') `
        "real entries are counted (got '$(Get-NSStatusOpportunityCounts $map)')"
    $building = @(Get-NSStatusBuilding $map)
    Expect-True ($building -ccontains ("title`tReceipts index")) 'the building title is reported'
    Expect-True ($building -ccontains ("phase`tbuild")) 'the building phase is reported'
    Expect-True ($building -ccontains ("next`twrite the index renderer")) 'the next action is reported'
    Expect-True ($building -ccontains ("verify remaining`tthe two fixtures and one native run")) `
        'the remaining verification is reported'

    $stop = Join-Path $ns 'STOP'
    Expect-True ([string]::IsNullOrEmpty((Get-NSStatusStopReason $ns))) 'no marker means no reason'
    [IO.File]::WriteAllText($stop, "owner asked for the night to end`n")
    Expect-True ((Get-NSStatusStopReason $ns) -ceq 'owner asked for the night to end') 'the reason is the first line'
    Remove-Item -LiteralPath $stop -Force

    $log = Join-Path $ns 'shift-log.md'
    [IO.File]::WriteAllText($log, @'
- 2026-09-06T10:00:00Z P14 done. Seven commits. The shift ended cleanly after the handoff notes.
2026-09-06 11:00:00 - watchman armed - every 10m
2026-09-06 12:00:00 - watchman: the armed marker is gone - standing down
'@)
    $transitions = @(Get-NSStatusTransitions $log 3)
    Expect-True ((@($transitions | Where-Object { $_ -clike 'watchman armed*' })).Count -eq 1) `
        'an arming is a transition'
    Expect-True ((@($transitions | Where-Object { $_ -clike 'watchman: the armed marker*' })).Count -eq 1) `
        'a stand-down is a transition'
    Expect-True ((@($transitions | Where-Object { $_ -clike '*P14 done*' })).Count -eq 0) `
        'an item summary that merely mentions a handoff is not a transition'

    $deadline = Join-Path $ns 'deadline'
    Expect-True ([string]::IsNullOrEmpty((Get-NSStatusDeadlineRemaining $ns))) 'no deadline reads as nothing'
    [IO.File]::WriteAllText($deadline, [string]((Get-NSUnixTime) + 7500) + "`n")
    Expect-True ((Get-NSStatusDeadlineRemaining $ns) -cmatch '^2h0[0-9]m remaining$') `
        "time remaining is formatted (got '$(Get-NSStatusDeadlineRemaining $ns)')"
    [IO.File]::WriteAllText($deadline, [string]((Get-NSUnixTime) - 60) + "`n")
    Expect-True ((Get-NSStatusDeadlineRemaining $ns) -ceq 'passed') 'a spent deadline reads as passed'
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures.Count -gt 0) {
    Write-Host "status-facts-logic failed ($($failures.Count)):"
    foreach ($failure in $failures) { Write-Host " - $failure" }
    exit 1
}
Write-Host 'status-facts-logic passed'
exit 0
