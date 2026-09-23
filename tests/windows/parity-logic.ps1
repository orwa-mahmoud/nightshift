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

foreach ($row in (Get-FixtureRows 'punch.tsv')) {
    $list = Join-Path (Join-Path $fixtures 'punch') $row[0]
    $counts = Get-NSBoxCounts $list
    Expect-Equal $row[1] ([string]$counts.Open) "$($row[0]) open"
    Expect-Equal $row[2] ([string]$counts.Ticked) "$($row[0]) ticked"
    Expect-Equal $row[3] (Get-NSGateItemLabel $list 1) "$($row[0]) label 1"
    Expect-Equal $row[4] (Get-NSGateItemLabel $list 2) "$($row[0]) label 2"
    Expect-Equal $row[5] (Get-NSGateItemLabel $list 3) "$($row[0]) label 3"
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
