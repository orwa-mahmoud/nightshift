# One fixture set, two runtimes: the PowerShell half of tests/parity.bats. Every row in
# tests/fixtures/parity/ is an input and the output both implementations must produce.
# Run on macOS or Windows: pwsh -File tests/windows/parity-logic.ps1
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$repository = Resolve-Path (Join-Path $PSScriptRoot '../..')
Import-Module (Join-Path $repository 'plugins/nightshift/lib/Nightshift.psm1') -Force -DisableNameChecking
$fixtures = Join-Path $repository 'tests/fixtures/parity'
$failures = New-Object 'System.Collections.Generic.List[string]'

function Expect-Equal {
    param([string]$Want, [string]$Got, [string]$Message)
    if ($Want -cne $Got) {
        $failures.Add("${Message}: got '$Got', want '$Want'")
        Write-Host "FAIL: ${Message}: got '$Got', want '$Want'"
    }
}

# Get-FixtureRows <file> - the fixture's cases as field arrays, without comments or blank lines.
function Get-FixtureRows {
    param([Parameter(Mandatory = $true)][string]$Name)
    $rows = New-Object 'System.Collections.Generic.List[object]'
    foreach ($line in [IO.File]::ReadAllLines((Join-Path $fixtures $Name))) {
        if ($line.Length -eq 0 -or $line.StartsWith('#')) { continue }
        $rows.Add([string[]]($line -split "`t"))
    }
    return , $rows
}

foreach ($row in (Get-FixtureRows 'usage-scale.tsv')) {
    Expect-Equal $row[1] (Get-NSUsageScale $row[0]) "usage scale $($row[0])"
}

foreach ($row in (Get-FixtureRows 'receipt-basenames.tsv')) {
    Expect-Equal $row[1] (Get-NSReceiptBasename -Label $row[0]) "receipt basename '$($row[0])'"
}

foreach ($row in (Get-FixtureRows 'receipt-order.tsv')) {
    $names = [string[]]($row[0] -split ' ')
    $keys = [string[]]@($names | ForEach-Object { Get-NSReceiptItemOrderKey $_ })
    [Array]::Sort($keys, $names, [StringComparer]::Ordinal)
    Expect-Equal $row[1] ($names -join ' ') 'receipt order'
}

$scratch = Join-Path ([IO.Path]::GetTempPath()) ('ns-parity-' + [guid]::NewGuid().ToString('N') + '.md')
try {
    foreach ($row in (Get-FixtureRows 'receipt-hash.tsv')) {
        $text = $row[0].Replace('\r', "`r").Replace('\n', "`n")
        [IO.File]::WriteAllText($scratch, $text, (New-Object Text.UTF8Encoding($false)))
        Expect-Equal $row[1] (Get-NSUsageReceiptHash $scratch) "receipt digest '$($row[0])'"
    }
}
finally {
    Remove-Item -LiteralPath $scratch -Force -ErrorAction SilentlyContinue
}

$sessionsReceipt = Join-Path ([IO.Path]::GetTempPath()) ('ns-parity-sessions-' + [guid]::NewGuid().ToString('N') + '.md')
try {
    foreach ($row in (Get-FixtureRows 'sessions.tsv')) {
        Add-NSReceiptSession $sessionsReceipt '6. Runtime only.' $row[0] $row[1] $row[2] $row[3] $row[4] $row[5] $row[6]
    }
    # A Windows checkout may end the fixture's lines with CRLF; the runtime writes LF.
    $want = [IO.File]::ReadAllText((Join-Path $fixtures 'sessions-expected.md')).Replace("`r`n", "`n")
    Expect-Equal $want ([IO.File]::ReadAllText($sessionsReceipt)) 'sessions table'
}
finally {
    Remove-Item -LiteralPath $sessionsReceipt -Force -ErrorAction SilentlyContinue
}

$dueRoot = Join-Path ([IO.Path]::GetTempPath()) ('ns-parity-due-' + [guid]::NewGuid().ToString('N'))
try {
    $n = 0
    $utf8 = New-Object Text.UTF8Encoding($false)
    foreach ($row in (Get-FixtureRows 'progress-due.tsv')) {
        $n++
        $site = Join-Path $dueRoot ('due-' + $n)
        $siteNs = Join-Path $site '.nightshift'
        $null = New-Item -ItemType Directory -Path (Join-Path $siteNs 'usage') -Force
        [IO.File]::WriteAllText((Join-Path $siteNs 'punch-list.md'), "## Items`n- [ ] **P01 - open.**`n", $utf8)
        [IO.File]::WriteAllText((Join-Path $siteNs 'shift-policy.json'),
            ('{"schemaVersion":1,"shiftId":"9f2c40ab77e51d63","createdAt":"2026-09-02T00:00:00Z",' +
                '"source":"composition","verificationLevel":"none","toolingPolicy":"existing-tools",' +
                '"receipts":{"progressMode":"' + $row[0] + '","usage":"' + $row[1] + '","progressMinutes":20,"progressTokens":1000}}'), $utf8)
        [IO.File]::WriteAllText((Get-NSUsageMarksPath $siteNs), ([string]((Get-NSUnixTime) - [long]$row[2] * 60) + "`tarm`t`n"), $utf8)
        if ($row[3] -cne '-') {
            $null = Write-NSUsageRecord $siteNs 'claude' 'm' 'transcript-incremental' '/t/a' '1' ('input=' + $row[3] + ',output=0')
        }
        $got = $(if (Test-NSUsageProgressDue $site 'P01') { 'yes' } else { 'no' })
        Expect-Equal $row[4] $got "progress due $($row[0]) $($row[1]) $($row[2]) $($row[3])"
    }
}
finally {
    Remove-Item -LiteralPath $dueRoot -Recurse -Force -ErrorAction SilentlyContinue
}

foreach ($row in (Get-FixtureRows 'item-labels.tsv')) {
    $want = if ($row.Count -gt 2) { $row[2] } else { '' }
    Expect-Equal $row[1] (Get-NSItemLabel $row[0]) "item label '$($row[0])'"
    Expect-Equal $want (Get-NSItemId $row[0]) "item id '$($row[0])'"
}

foreach ($row in (Get-FixtureRows 'punch.tsv')) {
    $list = Join-Path (Join-Path $fixtures 'punch') $row[0]
    $counts = Get-NSBoxCounts $list
    Expect-Equal $row[1] ([string]$counts.Open) "$($row[0]) open"
    Expect-Equal $row[2] ([string]$counts.Ticked) "$($row[0]) ticked"
    Expect-Equal (@($row[3], $row[4], $row[5]) -join '|') ((Get-NSGateTickedLabels $list) -join '|') "$($row[0]) labels"
    Expect-Equal $row[6] (Get-NSPunchContractDigest $list) "$($row[0]) contract digest"
    Expect-Equal $row[7] (Get-NSPunchItemsDigest $list) "$($row[0]) items digest"
}

if ($failures.Count -gt 0) {
    Write-Host "parity-logic failed ($($failures.Count)):"
    foreach ($failure in $failures) { Write-Host " - $failure" }
    exit 1
}
Write-Host 'parity logic passed'
exit 0
