Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$repo = Resolve-Path (Join-Path $PSScriptRoot '../..')
$plugin = Join-Path $repo 'plugins/nightshift'
$watchman = Join-Path $plugin 'runtime/windows/watchman.ps1'
$fixtures = Join-Path $repo 'tests/fixtures/codex-limits'
Import-Module (Join-Path $plugin 'lib/Nightshift.psm1') -Force -DisableNameChecking

function Assert-Equal($Expected, $Actual, [string]$Message) {
    if ($Expected -cne $Actual) { throw "$Message (expected '$Expected', got '$Actual')" }
}

$expectedResets = @{ primary = 2000001921; weekly = 2000540730; both = 2000540730; explicit = 2000000600; missing = 0; stale = 0; partial = 0 }
foreach ($name in $expectedResets.Keys) {
    $rollout = Join-Path $fixtures "$name.jsonl"
    Assert-Equal $expectedResets[$name] (Get-NSCodexLimitReset $rollout) "reset for $name"
    Assert-Equal 'usage_limit_exceeded' (Get-NSCodexTurnError $rollout) "turn error for $name"
    Assert-Equal 2000000000 (Get-NSCodexTurnErrorAt $rollout) "failure time for $name"
}

# Replace the clock and OS process launch. Run the full watchman, including the default
# Codex command construction, lease takeover and bounded retry loop.
function Get-TestUnixTime { return $global:CodexLimitTest.Clock }
Set-Alias -Name Get-NSUnixTime -Value Get-TestUnixTime

function Start-Sleep {
    param([int]$Seconds, [int]$Milliseconds)
    $test = $global:CodexLimitTest
    if ($Seconds -ne 123 -or $test.Poll -ge $test.Polls.Count) { throw 'unexpected watchman sleep' }
    $test.Clock = $test.Polls[$test.Poll]
    $test.Poll++
}

function Start-Process {
    param($FilePath, $ArgumentList, $WorkingDirectory, $WindowStyle, [switch]$PassThru, $ErrorAction)
    Assert-Equal 'powershell.exe' $FilePath 'watchman child launcher'
    $test = $global:CodexLimitTest
    $lease = Read-NSLease $test.Nightshift
    Assert-Equal $test.SessionId $lease.SessionId 'lease belongs to the recorded chat at launch'
    Assert-Equal ([string]$lease.Generation) $env:NIGHTSHIFT_LEASE_GENERATION 'child inherits the lease generation'
    Assert-Equal $lease.Nonce $env:NIGHTSHIFT_LEASE_NONCE 'child inherits the lease nonce'
    if ([string]::IsNullOrEmpty($lease.Nonce)) { throw 'launch requires a fenced lease' }
    $test.Launches.Add(@{ Clock = $test.Clock; Command = $ArgumentList })
    if (-not $test.FailLaunch) {
        [IO.File]::WriteAllText((Get-NSLayoutPath $test.Nightshift 'punch-list'), "## Items`n- [x] Item`n")
    }
    $child = [pscustomobject]@{ Id = [int]::MaxValue }
    $child | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value {}
    return $child
}

function Invoke-QuotaWatch {
    param([string]$Fixture, [long[]]$Polls, [switch]$OptOut, [switch]$FailLaunch, [switch]$OwnerStop)
    $workspace = Join-Path ([IO.Path]::GetTempPath()) ('ns-codex-quota-' + [guid]::NewGuid().ToString('N'))
    $nightshift = Join-Path $workspace '.nightshift'
    $test = @{
        Nightshift = $nightshift
        SessionId = 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee'
        Clock = $Polls[0] - 1
        Polls = $Polls
        Poll = 0
        Launches = New-Object 'System.Collections.Generic.List[object]'
        FailLaunch = $FailLaunch.IsPresent
    }
    $global:CodexLimitTest = $test
    $null = New-Item -ItemType Directory -Path $nightshift -Force
    try {
        $rules = Get-Content -LiteralPath (Join-Path $plugin 'config/nightshift-rules-template.json') -Raw | ConvertFrom-Json
        $rules.recovery.launchScope = 'host-default'
        $rules.watchAfterUsageLimit = -not $OptOut.IsPresent
        [IO.File]::WriteAllText((Get-NSLayoutPath $nightshift 'rules'), ($rules | ConvertTo-Json -Depth 20))
        [IO.File]::WriteAllText((Get-NSLayoutPath $nightshift 'punch-list'), "## Items`n- [ ] Item`n")
        [IO.File]::WriteAllText((Get-NSLayoutPath $nightshift 'armed'), '')
        if ($OwnerStop) { [IO.File]::WriteAllText((Get-NSLayoutPath $nightshift 'stop'), '') }
        # A pulse from the failed turn can still be fresh on the reset poll.
        if (-not $FailLaunch) {
            $pulse = $test.Clock.ToString() + ' ' + $test.SessionId
            [IO.File]::WriteAllText((Get-NSLayoutPath $nightshift 'pulse'), $pulse)
            Assert-Equal $true (Test-NSPulseFresh $nightshift 1) 'fixture has a fresh pulse at watchman start'
        }
        $null = Write-NSSession $nightshift $test.SessionId (Join-Path $fixtures "$Fixture.jsonl") '' '' 'codex'
        $env:NIGHTSHIFT_WATCH_SLEEP = '123'
        $env:NIGHTSHIFT_WATCH_RETRY = '0 0'
        & $watchman -Project $workspace -HostName codex -IntervalMinutes 1 -MaxWakes $Polls.Count
        if ($LASTEXITCODE -notin @(0, 7)) { throw "watchman exited with code $LASTEXITCODE" }
        $reasonFile = Get-NSLayoutPath $nightshift 'watch-reason'
        return @{
            SessionId = $test.SessionId
            Launches = $test.Launches.ToArray()
            Reason = [IO.File]::ReadAllLines($reasonFile)
            Log = [IO.File]::ReadAllText((Get-NSLayoutPath $nightshift 'shift-log'))
        }
    }
    finally {
        Remove-Variable CodexLimitTest -Scope Global
        Remove-Item -LiteralPath $workspace -Recurse -Force
    }
}

$env:NIGHTSHIFT_WATCH_IMMEDIATE = ''
$env:NIGHTSHIFT_WATCH_AGENT = ''
$env:NIGHTSHIFT_WATCH_AFTER_USAGE_LIMIT = ''

$before = Invoke-QuotaWatch primary @(2000001920)
Assert-Equal 0 $before.Launches.Count 'known limit prevents early revival'
Assert-Equal 'usage-limit' $before.Reason[0] 'waiting verdict'
Assert-Equal '2000001921' $before.Reason[1] 'waiting for the exhausted primary reset'

$atReset = Invoke-QuotaWatch primary @(2000001920, 2000001921)
Assert-Equal 1 $atReset.Launches.Count 'one launch across both polls'
Assert-Equal 2000001921 $atReset.Launches[0].Clock 'launch is on the first eligible poll'
if ($atReset.Launches[0].Command -cnotmatch "& 'codex' 'exec' 'resume' '$($atReset.SessionId)'") {
    throw "watchman must resume the recorded chat: $($atReset.Launches[0].Command)"
}
Assert-Equal 'revived' $atReset.Reason[0] 'same-chat recovery succeeds'

$unknown = Invoke-QuotaWatch stale @(2000000001) -FailLaunch
Assert-Equal 3 $unknown.Launches.Count 'unknown reset uses one bounded retry ladder'
Assert-Equal 'exhausted-retry' $unknown.Reason[0] 'failed retries report exhaustion'
if (-not $unknown.Log.Contains('Codex usage limit reset time is unknown')) { throw 'missing unknown-reset report' }

$off = Invoke-QuotaWatch primary @(2000001920, 2000001921) -OptOut
Assert-Equal 0 $off.Launches.Count 'owner opt-out prevents revival after reset'
Assert-Equal 'usage-limit' $off.Reason[0] 'owner opt-out keeps the usage-limit verdict'

$stopped = Invoke-QuotaWatch primary @(2000001921) -OwnerStop
Assert-Equal 0 $stopped.Launches.Count 'STOP prevents revival at reset'
Assert-Equal 'owner-stop' $stopped.Reason[0] 'STOP takes precedence over quota recovery'

Write-Host 'codex-limit-logic ok'
