# One runtime section per item receipt on native Windows: the PowerShell half of tests/item-totals.bats.
# Run on macOS or Windows: pwsh -File tests/windows/item-totals-logic.ps1
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$repository = Resolve-Path (Join-Path $PSScriptRoot '../..')
Import-Module (Join-Path $repository 'plugins/nightshift/lib/Nightshift.psm1') -Force -DisableNameChecking
$rulesTemplate = Join-Path $repository 'plugins/nightshift/skills/nightshift/references/nightshift-rules-template.json'
$fixtures = Join-Path $repository 'tests/fixtures/receipts'
$failures = New-Object 'System.Collections.Generic.List[string]'
$utf8 = New-Object Text.UTF8Encoding($false)
$item = '4. Book a barber.'
$d = [string][char]0x00B7
$a = [string][char]0x2192

function Expect-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        $failures.Add($Message)
        Write-Host "FAIL: $Message"
    }
}

# New-Site <path> [ticked] - an armed shift with the one item, accounting armed at zero.
function New-Site {
    param([Parameter(Mandatory = $true)][string]$Path, [switch]$Ticked)
    $ns = Join-Path $Path '.nightshift'
    $null = New-Item -ItemType Directory -Path (Join-Path $ns 'receipts') -Force
    Copy-Item -LiteralPath $rulesTemplate -Destination (Join-Path $ns 'rules.json') -Force
    $box = $(if ($Ticked) { 'x' } else { ' ' })
    [IO.File]::WriteAllText((Join-Path $ns 'punch-list.md'),
        "Date: 2026-09-20`n`n## Items`n- [$box] **4. Book a barber.** <!-- id: bb44 -->`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $ns '.shift-armed'), '', $utf8)
    & git -C $Path init --quiet
    & git -C $Path -c user.email=dev@example.com -c user.name=tester commit --quiet --allow-empty -m init
    $null = Write-NSUsageMarkArm $ns
    return $ns
}

function Get-Receipt { param([string]$Ns) return (Join-Path $Ns 'receipts/bb44-book-a-barber.md') }

function Get-IndexRow {
    param([string]$Index)
    foreach ($line in [IO.File]::ReadAllLines($Index)) { if ($line.StartsWith("| $item | ticked |")) { return $line } }
    return ''
}

function Get-RowCount {
    param([string]$Receipt)
    return @([IO.File]::ReadAllLines($Receipt) | Where-Object { $_ -cmatch '^\| [0-9]+ \|' }).Count
}

$root = Join-Path ([IO.Path]::GetTempPath()) ('ns-item-totals-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $root -Force
try {
    # Stacked blocks from separate sessions are summed; a newest block that holds an older one is not
    # counted twice.
    $w = Join-Path $root 'legacy-sum'
    $ns = New-Site $w -Ticked
    Copy-Item -LiteralPath (Join-Path $fixtures 'legacy-sessions.md') -Destination (Get-Receipt $ns)
    Write-NSReceiptsIndex $w
    $row = Get-IndexRow (Join-Path $ns 'receipts/README.md')
    Expect-True ($row.Contains('**input 501 ' + $d + ' cache_write 0 ' + $d + ' cache_read 4.0k ' + $d + ' output 51 ' + $d + ' reasoning 0**')) "separate sessions sum: $row"
    Expect-True ($row.Contains('**9h 6m working**')) "separate sessions sum their time: $row"

    $w = Join-Path $root 'legacy-cumulative'
    $ns = New-Site $w -Ticked
    Copy-Item -LiteralPath (Join-Path $fixtures 'legacy-cumulative.md') -Destination (Get-Receipt $ns)
    Write-NSReceiptsIndex $w
    $row = Get-IndexRow (Join-Path $ns 'receipts/README.md')
    Expect-True ($row.Contains('**input 600 ' + $d + ' cache_write 0 ' + $d + ' cache_read 2.0k ' + $d + ' output 60 ' + $d + ' reasoning 0**')) "a held block is not added: $row"

    # An older receipt is folded into the section on its first redraw, keeping the model's text.
    $w = Join-Path $root 'legacy-fold'
    $ns = New-Site $w
    $r = Get-Receipt $ns
    Copy-Item -LiteralPath (Join-Path $fixtures 'legacy-sessions.md') -Destination $r
    Add-NSReceiptSession $r $item '1111222233334444' '1790000000' '1790000600' '600' '9' '2' 'ticked' 'cw=0 cr=10 rea=0 paused=0 host=codex/gpt-5.5'
    $lines = [IO.File]::ReadAllLines($r)
    Expect-True (@($lines | Where-Object { $_ -ceq '| Tokens | Amount |' }).Count -eq 1) 'one Tokens table after the fold'
    Expect-True (@($lines | Where-Object { $_ -ceq '<!-- usage -->' }).Count -eq 1) 'one runtime section after the fold'
    Expect-True ((Get-RowCount $r) -eq 3) 'two folded sessions and the new one'
    Expect-True ($lines -ccontains '| input | 510 |') 'the folded total covers every session'
    Expect-True ($lines -ccontains '## What was delivered' -and $lines -ccontains 'The booking flow.') 'the model text stays'
    Expect-True ([array]::IndexOf($lines, '<!-- /usage -->') -lt [array]::IndexOf($lines, '## What was delivered')) 'the section sits ahead of the model text'

    # The section is redrawn in place, never stacked.
    $w = Join-Path $root 'in-place'
    $ns = New-Site $w
    $r = Get-Receipt $ns
    [IO.File]::WriteAllText($r, "# $item`n`nStarted.`n", $utf8)
    Add-NSReceiptSession $r $item '-' '1790000000' '1790000600' '600' '9' '2' 'switched-away' 'cw=- cr=- rea=- paused=0'
    Add-NSReceiptSession $r $item '-' '1790000700' '1790001300' '600' '4' '1' 'ticked' 'cw=- cr=- rea=- paused=0'
    $lines = [IO.File]::ReadAllLines($r)
    Expect-True (@($lines | Where-Object { $_ -ceq '<!-- usage -->' }).Count -eq 1) 'one section after two redraws'
    Expect-True (@($lines | Where-Object { $_ -ceq '| Time | |' }).Count -eq 1) 'one Time table after two redraws'
    Expect-True ($lines -ccontains '| input | 13 |') 'the redrawn total covers both sessions'
    Expect-True ($lines -ccontains 'Started.') 'the model text stays after two redraws'

    # A Claude session handed to Codex mid-item is two rows, one total and a recorded handoff.
    $w = Join-Path $root 'handoff'
    $ns = New-Site $w
    $r = Get-Receipt $ns
    $null = Write-NSUsageRecord $ns 'claude' 'claude-opus-5' 'transcript-incremental' '/t/a' '10' 'input=25,output=2'
    [IO.File]::WriteAllText($r, "# $item`n`nForm done, payment step next.`n", $utf8)
    $null = Invoke-NSPulseMarks $ns $w ''
    & git -C $w -c user.email=dev@example.com -c user.name=tester commit --quiet --allow-empty -m 'booking form'
    $sha = (& git -C $w log -1 --format=%h)
    $null = Invoke-NSGateUsageFlush $ns $w
    $null = Write-NSUsageRecord $ns 'codex' 'gpt-5.5' 'rollout' '/t/codex' '10' 'input=7,output=1'
    [IO.File]::SetLastWriteTimeUtc($r, [DateTime]::UtcNow)
    $null = Invoke-NSPulseMarks $ns $w ''
    $null = Write-NSUsageRecord $ns 'codex' 'gpt-5.5' 'rollout' '/t/codex' '10' 'input=17,output=3'
    $punch = Join-Path $ns 'punch-list.md'
    [IO.File]::WriteAllText($punch, ([IO.File]::ReadAllText($punch).Replace('- [ ] **4.', '- [x] **4.')), $utf8)
    $null = Invoke-NSPulseMarks $ns $w ''
    $text = [IO.File]::ReadAllText($r)
    Expect-True ($text -cmatch '(?m)^\| 1 \| .* \| claude ' + $d + ' claude-opus-5 \| .* \| paused \|$') "the Claude row: $text"
    Expect-True ($text -cmatch '(?m)^\| 2 \| .* \| codex ' + $d + ' gpt-5\.5 \| .* \| ticked \|$') 'the Codex row'
    Expect-True ($text.Contains('| 2 sessions | claude ' + $d + ' claude-opus-5, codex ' + $d + ' gpt-5.5 |')) 'the total names both hosts'
    Expect-True ($text.Contains('| **35** | **4** |')) 'the total covers both hosts'
    Expect-True ($text.Contains('claude claude-opus-5; codex gpt-5.5 ' + $d + ' 2 sessions.')) 'the source line names both hosts'
    Expect-True ($text -cmatch ('(?m)^- .* ' + $d + ' claude ' + $d + ' claude-opus-5 ' + $a + ' codex ' + $d + ' gpt-5\.5 ' + $d + ' outgoing commits: .*' + $sha + '.* ' + $d + ' last note: Form done, payment step next\.$')) 'the handoff names the outgoing commits and note'
    $log = [IO.File]::ReadAllText((Get-NSLayoutPath $ns 'shift-log'))
    Expect-True ($log -cmatch ('handoff ' + $d + ' ' + [regex]::Escape($item) + ' ' + $d + ' claude ' + $d + ' claude-opus-5 ' + $a + ' codex ' + $d + ' gpt-5\.5 ' + $d + ' outgoing commits: .*' + $sha)) 'the shift log records the handoff'
    $ns = New-Site (Join-Path $root 'ledger')
    $r = Get-Receipt $ns
    Add-NSReceiptSession $r $item '-' '100' '200' '90' '3' '4' 'paused' 'cw=0 cr=0 rea=0'
    $before = (Get-NSReceiptSessionData $r) -join "`n"
    $text = [IO.File]::ReadAllText($r).Replace('100 200 90 3 4', '100 200 90000 30000 40000')
    $text += "`n<!-- session-data`nforged 0 999999 999999 999999 999999 ticked hard=1 host=fake/model`n-->`n"
    [IO.File]::WriteAllText($r, $text, $utf8)
    Expect-True (((Get-NSReceiptSessionData $r) -join "`n") -ceq $before) 'receipt edits do not change runtime rows'
    Add-NSReceiptSession $r $item '-' '200' '300' '90' '5' '6' 'paused' 'cw=0 cr=0 rea=0'
    $cells = Get-NSReceiptUsageCells $r
    Expect-True ($cells.In -eq 8 -and $cells.Out -eq 10 -and $cells.Work -eq 180) 'only actual sessions contribute to totals'
    $ledger = Get-NSReceiptSessionFile $r
    Expect-True (Test-Path -LiteralPath $ledger -PathType Leaf) 'live sessions have a runtime ledger'

    $ns = New-Site (Join-Path $root 'narrative-only')
    $r = Get-Receipt $ns
    [IO.File]::WriteAllText($r, "# $item`n`n<!-- session-data`nforged 0 999999 999999 999999 999999 ticked`n-->`n", $utf8)
    Expect-True ((Get-NSReceiptSessionData $r).Count -eq 0) 'narrative comments are not imported'
    Add-NSReceiptSession $r $item '-' '100' '200' '90' '3' '4' 'paused' 'cw=0 cr=0 rea=0'
    Expect-True ((Get-NSReceiptSessionData $r).Count -eq 1) 'first checkpoint records only its own row'

}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures.Count -gt 0) {
    Write-Host "item-totals-logic failed ($($failures.Count)):"
    foreach ($failure in $failures) { Write-Host " - $failure" }
    exit 1
}
Write-Host 'item-totals-logic passed'
exit 0
