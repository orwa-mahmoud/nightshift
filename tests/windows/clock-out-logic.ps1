# Portable coverage for the Cursor watchman's direct clock-out.
# Run on macOS or Windows: pwsh -File tests/windows/clock-out-logic.ps1
# Windows CI also runs it via tests/windows/run.ps1.
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$repository = Resolve-Path (Join-Path $PSScriptRoot '../..')
Import-Module (Join-Path $repository 'plugins/nightshift/lib/Nightshift.psm1') -Force -DisableNameChecking
$template = Join-Path $repository 'plugins/nightshift/skills/nightshift/references/nightshift-rules-template.json'
$failures = New-Object 'System.Collections.Generic.List[string]'

function Expect-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        $failures.Add($Message)
        Write-Host "FAIL: $Message"
    }
}

function New-Workspace {
    param([string]$Punch)
    $path = Join-Path ([IO.Path]::GetTempPath()) ('ns-clock-' + [guid]::NewGuid().ToString('N'))
    $ns = Join-Path $path '.nightshift'
    New-Item -ItemType Directory -Force -Path $ns | Out-Null
    Copy-Item $template (Join-Path $ns 'rules.json')
    [IO.File]::WriteAllText((Join-Path $ns 'punch-list.md'), $Punch)
    [IO.File]::WriteAllText((Join-Path $ns '.shift-armed'), '')
    $stale = [string]((Get-NSUnixTime) - 100000)
    [IO.File]::WriteAllText((Join-Path $ns '.shift-pulse'), "$stale origin-ide`n")
    [IO.File]::WriteAllText((Join-Path $ns '.shift-session'), "origin-ide`n`n`n`ncursor`n")
    return $path
}

function Read-Log {
    param([string]$Workspace)
    $log = Join-Path $Workspace '.nightshift/shift-log.md'
    if (-not (Test-Path -LiteralPath $log)) { return '' }
    return [IO.File]::ReadAllText($log)
}

$ticked = New-Workspace "## Items`n- [x] **1.**`n"
$done = Invoke-NSWatchmanDirectClockOut -Workspace $ticked -HostName cursor -IntervalMinutes 20
Expect-True $done.Released 'a ticked shift with a stale pulse clocks out'
Expect-True (Test-Path -LiteralPath (Join-Path $ticked '.nightshift/.ended') -PathType Leaf) '.ended is written'
Expect-True (-not (Test-Path -LiteralPath (Join-Path $ticked '.nightshift/.shift-armed'))) 'the armed marker is gone'
$morning = @(Get-ChildItem -LiteralPath (Join-Path $ticked '.nightshift/receipts') -Filter 'morning-*.md' -File -ErrorAction SilentlyContinue)
Expect-True ($morning.Count -ge 1) 'the morning receipt is written'
Expect-True ((Read-Log $ticked).Contains('watchman: clocking out')) 'the shift log names the clock-out'
Remove-Item -LiteralPath $ticked -Recurse -Force

$stopped = New-Workspace "## Items`n- [ ] **1.**`n"
[IO.File]::WriteAllText((Join-Path $stopped '.nightshift/STOP'), "owner stop`n")
$stopResult = Invoke-NSWatchmanDirectClockOut -Workspace $stopped -HostName cursor -IntervalMinutes 20
Expect-True $stopResult.Released 'STOP clocks out when the session is gone'
Expect-True (Test-Path -LiteralPath (Join-Path $stopped '.nightshift/.ended') -PathType Leaf) 'STOP writes .ended'
Expect-True ((Read-Log $stopped).Contains('watchman: clocking out')) 'STOP names the clock-out'
Remove-Item -LiteralPath $stopped -Recurse -Force

$open = New-Workspace "## Items`n- [ ] **1.**`n"
$openResult = Invoke-NSWatchmanDirectClockOut -Workspace $open -HostName cursor -IntervalMinutes 20
Expect-True (-not $openResult.Released) 'an open shift is not clocked out'
Expect-True (-not (Test-Path -LiteralPath (Join-Path $open '.nightshift/.ended'))) 'an open shift leaves .ended unwritten'
Expect-True ((Read-Log $open) -notmatch 'clocking out') 'an open shift does not log a clock-out'
Remove-Item -LiteralPath $open -Recurse -Force

$other = New-Workspace "## Items`n- [x] **1.**`n"
[IO.File]::WriteAllText((Join-Path $other '.nightshift/.shift-session'), "origin-ide`n`n`n`nclaude`n")
$otherResult = Invoke-NSWatchmanDirectClockOut -Workspace $other -HostName cursor -IntervalMinutes 20
Expect-True (-not $otherResult.Released) 'another host is not clocked out'
Expect-True ($otherResult.Reason.Contains('ownership')) 'the refusal names ownership'
Expect-True (-not (Test-Path -LiteralPath (Join-Path $other '.nightshift/.ended'))) 'ownership refusal writes no .ended'
Remove-Item -LiteralPath $other -Recurse -Force

$blockedPunch = @"
## Items
- [x] **Shot.** <!-- id: ab12 -->
  - Evidence: the screen ``shot.png`` check: block
"@
$blocked = New-Workspace $blockedPunch
$blockedResult = Invoke-NSWatchmanDirectClockOut -Workspace $blocked -HostName cursor -IntervalMinutes 20
Expect-True (-not $blockedResult.Released) 'missing evidence keeps a ticked shift from clocking out'
Expect-True (-not (Test-Path -LiteralPath (Join-Path $blocked '.nightshift/.ended'))) 'missing evidence writes no .ended'
$shot = Get-NSReceiptPath $blocked 'Shot.' 'ab12'
$shotDir = $shot.Substring(0, $shot.Length - 3)
New-Item -ItemType Directory -Force -Path $shotDir | Out-Null
[IO.File]::WriteAllBytes((Join-Path $shotDir 'shot.png'), [byte[]](0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x78))
$present = Invoke-NSWatchmanDirectClockOut -Workspace $blocked -HostName cursor -IntervalMinutes 20
Expect-True $present.Released 'a present image lets the ticked shift clock out'
Remove-Item -LiteralPath $blocked -Recurse -Force

if ($failures.Count -gt 0) {
    Write-Host ($failures -join [Environment]::NewLine)
    exit 1
}
Write-Host 'clock-out logic ok'
exit 0
