# Portable PowerShell coverage for receipt-duty injection.
# Run: pwsh -File tests/windows/pulse-logic.ps1
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if (Test-Path Variable:PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $false
}

$repository = Resolve-Path (Join-Path $PSScriptRoot '../..')
Import-Module (Join-Path $repository 'plugins/nightshift/lib/Nightshift.psm1') -Force -DisableNameChecking
$failures = New-Object 'System.Collections.Generic.List[string]'
$utf8 = New-Object Text.UTF8Encoding($false)
$dash = [string][char]0x2014

function Expect-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        $failures.Add($Message)
        Write-Host "FAIL: $Message"
    }
}

$root = Join-Path ([IO.Path]::GetTempPath()) ("ns-pulse-logic-" + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $root -Force
try {
    $w = Join-Path $root 'start'
    $ns = Join-Path $w '.nightshift'
    $null = New-Item -ItemType Directory -Path $ns -Force
    [IO.File]::WriteAllText((Join-Path $ns 'punch-list.md'), "## Items`n- [ ] **36. First of the replay.**`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $ns '.shift-armed'), '', $utf8)
    $first = Get-NSPulseReceiptsNotice $ns $w
    Expect-True ($first.Contains("receipts: item 36. First of the replay. started $dash open .nightshift/receipts/36-first-of-the-replay.md")) `
        'item-start injection fires once'
    $again = Get-NSPulseReceiptsNotice $ns $w
    Expect-True (-not $again.Contains('started ')) 'a second pulse on the same item does not restart it'

    $tickWs = Join-Path $root 'tick'
    $tickNs = Join-Path $tickWs '.nightshift'
    $null = New-Item -ItemType Directory -Path $tickNs -Force
    [IO.File]::WriteAllText((Join-Path $tickNs 'punch-list.md'), "## Items`n- [ ] **36. First of the replay.**`n- [ ] **37. Second of the replay.**`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $tickNs '.shift-armed'), '', $utf8)
    $null = Get-NSPulseReceiptsNotice $tickNs $tickWs
    [IO.File]::WriteAllText((Join-Path $tickNs 'punch-list.md'), "## Items`n- [x] **36. First of the replay.**`n- [ ] **37. Second of the replay.**`n", $utf8)
    $ticked = Get-NSPulseReceiptsNotice $tickNs $tickWs
    Expect-True ($ticked.Contains("receipts: item 36. First of the replay. is ticked $dash write its closing paragraph in .nightshift/receipts/36-first-of-the-replay.md now, before starting the next item.")) `
        'tick injection names the newly ticked item and file'

    $off = Join-Path $root 'off'
    $offNs = Join-Path $off '.nightshift'
    $null = New-Item -ItemType Directory -Path $offNs -Force
    [IO.File]::WriteAllText((Join-Path $offNs 'punch-list.md'), "## Items`n- [ ] **36. First of the replay.**`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $offNs '.shift-armed'), '', $utf8)
    [IO.File]::WriteAllText((Join-Path $offNs 'rules.json'), '{"receipts":{"enabled":false}}', $utf8)
    Expect-True ([string]::IsNullOrEmpty((Get-NSPulseReceiptsNotice $offNs $off))) `
        'no injection when receipts.enabled is false'

    $miss = Join-Path $root 'missing'
    $missNs = Join-Path $miss '.nightshift'
    $null = New-Item -ItemType Directory -Path (Join-Path $missNs 'receipts') -Force
    [IO.File]::WriteAllText((Join-Path $missNs 'punch-list.md'), "## Items`n- [x] **36. First of the replay.**`n- [x] **37. Second of the replay.**`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $missNs 'receipts/36-first-of-the-replay.md'), "# 36.`n`n**Usage:** input 1`n**Duration:** 1m`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $missNs 'receipts/37-second-of-the-replay.md'), "# 37.`n`nWrote the closing paragraph.`n", $utf8)
    Expect-True ((Get-NSGateReceiptsMissingNote $miss) -ceq 'Receipts missing model text: 36') `
        'clock-out lists receipts missing model text'

    $stale = Join-Path $root 'stale'
    $staleNs = Join-Path $stale '.nightshift'
    $null = New-Item -ItemType Directory -Path (Join-Path $staleNs 'usage') -Force
    [IO.File]::WriteAllText((Join-Path $staleNs 'punch-list.md'), "## Items`n- [x] **37. Second of the replay.**`n- [ ] **38. Third of the replay.**`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $staleNs '.shift-armed'), '', $utf8)
    $old = (Get-NSUnixTime) - (25 * 60)
    [IO.File]::WriteAllText((Join-Path $staleNs 'usage/marks.tsv'), "$old`tarm`t`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $staleNs '.receipt-due'),
        "receipts: progress update due for 37. Second of the replay. $dash refresh the progress paragraph in .nightshift/receipts/37-second-of-the-replay.md: where it stands, what is left.",
        $utf8)
    $cadence = Get-NSPulseReportDue $staleNs $stale
    Expect-True ($cadence.Contains('progress update due for 38. Third of the replay.')) `
        'a stale marker naming 37 with 38 active produces a message naming 38'
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures.Count -gt 0) {
    Write-Host "pulse-logic failed ($($failures.Count)):"
    foreach ($f in $failures) { Write-Host "  $f" }
    exit 1
}
Write-Host 'pulse-logic passed'
exit 0
