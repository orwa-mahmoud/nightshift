# Portable PowerShell coverage for the shared alive-but-idle rule.
# Run on macOS or Windows: pwsh -File tests/windows/idle-logic.ps1
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

function Expect-Equal {
    param($Expected, $Actual, [string]$Message)
    if ($Expected -cne $Actual) {
        $failures.Add("$Message (expected '$Expected', got '$Actual')")
        Write-Host "FAIL: $Message (expected '$Expected', got '$Actual')"
    }
}

function New-Workspace {
    $path = Join-Path ([IO.Path]::GetTempPath()) ('ns-idle-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path (Join-Path $path '.nightshift') | Out-Null
    Copy-Item $template (Join-Path $path '.nightshift/rules.json')
    return $path
}

Expect-Equal 'pending' (Get-NSIdleVerdict -Pulse stale -Known 1 -Since '' -Now 2000 -Window 1) 'empty since is inside the window'
Expect-Equal 'pending' (Get-NSIdleVerdict -Pulse stale -Known 1 -Since '1000' -Now 1030 -Window 1) 'short quiet stretch stays pending'
Expect-Equal 'due' (Get-NSIdleVerdict -Pulse stale -Known 1 -Since '1000' -Now 1060 -Window 1) 'a full window is due'
Expect-Equal 'busy' (Get-NSIdleVerdict -Pulse fresh -Known 1 -Since '1000' -Now 9999 -Window 1) 'a fresh pulse is busy'
Expect-Equal 'busy' (Get-NSIdleVerdict -Pulse stale -Changed 1 -Known 1 -Since '1000' -Now 9999 -Window 1) 'a growing transcript is busy'
Expect-Equal 'busy' (Get-NSIdleVerdict -Pulse stale -Known 1 -Busy 1 -Since '1000' -Now 9999 -Window 1) 'a busy child is busy'
Expect-Equal 'busy' (Get-NSIdleVerdict -Pulse stale -Known 1 -Delta 100 -Since '1000' -Now 9999 -Window 1) 'a second of CPU is busy'
Expect-Equal 'unavailable' (Get-NSIdleVerdict -Pulse stale -Known 0 -Since '1000' -Now 9999 -Window 1) 'unknown CPU stands by'
Expect-Equal 'stuck' (Get-NSIdleVerdict -Pulse stale -Known 1 -Since '1000' -Now 9999 -Window 1 -Stuck 1) 'two failures stay stuck'
Expect-Equal '+1.05s' (Format-NSIdleCpu 105) 'cpu label'
Expect-Equal '-0.20s' (Format-NSIdleCpu -20) 'negative cpu label'

$parent = @{ 2 = 1; 3 = 2 }
Expect-True (Test-NSIdleDescendant -Parent $parent -Root 1 -Candidate 3) 'a grandchild is in the tree'
Expect-True (-not (Test-NSIdleDescendant -Parent $parent -Root 1 -Candidate 9)) 'an unrelated pid is outside the tree'

$workspace = New-Workspace
$ns = Join-Path $workspace '.nightshift'
try {
    $env:NIGHTSHIFT_IDLE_WINDOW = '1'
    Expect-Equal 1 (Get-NSIdleWindowMinutes $workspace) 'the session window overrides the file'
    Remove-Item Env:\NIGHTSHIFT_IDLE_WINDOW
    Expect-Equal 30 (Get-NSIdleWindowMinutes $workspace) 'a missing session window is 30'

    $state = Read-NSIdleState $ns
    $state.Since = [string]((Get-NSUnixTime) - 120)
    $state.Pids = [string]$PID
    $state.Evidence = 'pulse stale, transcript unchanged, cpu +0.00s, no busy child'
    Write-NSIdleState $ns $state
    $line = Get-NSIdleStatusSentence $ns
    Expect-True ($line -eq 'worker alive but idle for 2 min — pulse stale, transcript unchanged, cpu +0.00s, no busy child') "status sentence was '$line'"

    $state = Read-NSIdleState $ns
    $state.Episode = 1
    $state.Since = '1'
    $state.Fails = 0
    $state.Stuck = 0
    $state.Noticed = 0
    Write-NSIdleState $ns $state
    Expect-Equal 'counted' (Update-NSIdleAfterRevival -NightshiftDir $ns -Result 'failed') 'the first failure is counted'
    Expect-Equal 'stuck' (Update-NSIdleAfterRevival -NightshiftDir $ns -Result 'failed') 'the second failure sticks'
    $lot = Get-NSLayoutPath $ns 'parking-lot'
    $notices = @(Select-String -LiteralPath $lot -Pattern 'revival failed twice' -ErrorAction SilentlyContinue)
    Expect-Equal 1 $notices.Count 'one parking-lot notice'
    Expect-Equal 'stuck' (Update-NSIdleAfterRevival -NightshiftDir $ns -Result 'failed') 'a later failure does not retry'
    $notices = @(Select-String -LiteralPath $lot -Pattern 'revival failed twice')
    Expect-Equal 1 $notices.Count 'the notice is not written again'
}
finally {
    Remove-Item Env:\NIGHTSHIFT_IDLE_WINDOW -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $workspace -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures.Count -gt 0) {
    Write-Host ("{0} failure(s)" -f $failures.Count)
    exit 1
}
Write-Host 'idle-logic ok'
exit 0
