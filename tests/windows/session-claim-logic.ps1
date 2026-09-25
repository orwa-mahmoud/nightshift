# Portable PowerShell coverage for who may record a shift's conversation on Windows.
# Run on macOS or Windows: pwsh -File tests/windows/session-claim-logic.ps1
# Start's binding probe records the conversation it armed from. A site armed without that record
# belongs to no one: a Stop or a tool call from another conversation must leave it unbound.
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if (Test-Path Variable:PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $false
}

$repository = Resolve-Path (Join-Path $PSScriptRoot '../..')
$plugin = Join-Path $repository 'plugins/nightshift'
$hardhat = Join-Path $plugin 'hooks/windows/hardhat.ps1'
$gate = Join-Path $plugin 'hooks/windows/clock-out-gate.ps1'
$setup = Join-Path $plugin 'runtime/windows/setup.ps1'
$stopShift = Join-Path $plugin 'runtime/windows/stop-shift.ps1'
Import-Module (Join-Path $plugin 'lib/Nightshift.psm1') -Force -DisableNameChecking
$hostExecutable = (Get-Process -Id $PID).Path
$failures = New-Object 'System.Collections.Generic.List[string]'

function Expect-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        $failures.Add($Message)
        Write-Host "FAIL: $Message"
    }
}

# Invoke-Hook <script> <payload> <workspace> [arguments] — one hook run as the host runs it, with
# the payload piped in and only CLAUDE_PROJECT_DIR set.
function Invoke-Hook {
    param(
        [Parameter(Mandatory = $true)][string]$Script,
        [AllowEmptyString()][string]$Payload,
        [Parameter(Mandatory = $true)][string]$Workspace,
        [string[]]$Arguments = @('-HostName', 'claude')
    )
    $saved = @{}
    foreach ($item in @(Get-ChildItem Env: | Where-Object {
                $_.Name -like 'NIGHTSHIFT_*' -or $_.Name -in @('CLAUDE_PROJECT_DIR', 'CODEX_PROJECT_DIR')
            })) {
        $saved[$item.Name] = $item.Value
        [Environment]::SetEnvironmentVariable($item.Name, $null, 'Process')
    }
    $env:CLAUDE_PROJECT_DIR = $Workspace
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $argList = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $Script) + $Arguments
        $output = if ([string]::IsNullOrEmpty($Payload)) {
            & $hostExecutable @argList 2>&1
        }
        else {
            $Payload | & $hostExecutable @argList 2>&1
        }
        return [pscustomobject]@{
            ExitCode = [int]$LASTEXITCODE
            Stdout = (@($output | Where-Object { $_ -isnot [Management.Automation.ErrorRecord] }) -join "`n")
        }
    }
    finally {
        $ErrorActionPreference = $previous
        [Environment]::SetEnvironmentVariable('CLAUDE_PROJECT_DIR', $null, 'Process')
        foreach ($key in $saved.Keys) {
            [Environment]::SetEnvironmentVariable($key, $saved[$key], 'Process')
        }
    }
}

function Invoke-Stop {
    param([string]$Workspace, [string]$SessionId)
    $payload = @{ hook_event_name = 'Stop'; session_id = $SessionId; transcript_path = '' } | ConvertTo-Json -Compress
    return Invoke-Hook $gate $payload $Workspace
}

function Invoke-Bash {
    param([string]$Workspace, [string]$SessionId, [string]$Command)
    $payload = @{
        session_id = $SessionId
        transcript_path = ''
        cwd = $Workspace
        tool_name = 'Bash'
        tool_input = @{ command = $Command }
    } | ConvertTo-Json -Compress
    return Invoke-Hook $hardhat $payload $Workspace
}

function New-ArmedWorkspace {
    param([Parameter(Mandatory = $true)][string]$Path)
    $repo = Join-Path $Path 'repo'
    $null = New-Item -ItemType Directory -Path $repo -Force
    $null = & git -C $repo init --quiet
    $null = & git -C $repo config user.email dev@example.com
    $null = & git -C $repo config user.name tester
    $null = & git -C $repo commit --quiet --allow-empty -m init
    $made = Invoke-Hook $setup '' $Path @('-Project', $Path, '-WorkTarget', $repo)
    if ($made.ExitCode -ne 0) { throw "setup failed: $($made.Stdout)" }
    [IO.File]::WriteAllText((Join-Path $Path '.nightshift/punch-list.md'),
        "# Contract`n`n## Items`n- [ ] **1. first.**`n", (New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText((Get-NSLayoutPath (Join-Path $Path '.nightshift') 'armed'), '')
    return (Join-Path $Path '.nightshift')
}

$root = Join-Path ([IO.Path]::GetTempPath()) ('ns-session-claim-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $root
try {
    $blockPattern = '"decision"\s*:\s*"block"'

    # Start armed and was interrupted before its probe; another conversation stops and works.
    $workspace = Join-Path $root 'never bound'
    $ns = New-ArmedWorkspace $workspace
    $stop = Invoke-Stop $workspace 'helper-session'
    Expect-True ($stop.ExitCode -eq 0 -and $stop.Stdout -notmatch $blockPattern) `
        "a foreign Stop on a shift armed but never bound is released: $($stop.Stdout)"
    $bash = Invoke-Bash $workspace 'helper-session' 'git status'
    Expect-True ($bash.ExitCode -eq 0 -and [string]::IsNullOrWhiteSpace($bash.Stdout)) `
        "a foreign tool call on a shift armed but never bound is allowed: $($bash.Stdout)"
    Expect-True ($null -eq (Read-NSSession $ns)) 'another conversation does not record itself on an unbound shift'
    Expect-True ($null -eq (Read-NSLease $ns)) 'another conversation does not lease an unbound shift'

    $probe = Invoke-Bash $workspace 'shift-session' ": nightshift-binding-probe"
    Expect-True ($probe.ExitCode -eq 0 -and [string]::IsNullOrWhiteSpace($probe.Stdout)) `
        "the binding probe still binds the shift: $($probe.Stdout)"
    $session = Read-NSSession $ns
    Expect-True ($null -ne $session -and $session.SessionId -eq 'shift-session') 'the probe records its own conversation'
    $helperStop = Invoke-Stop $workspace 'helper-session'
    Expect-True ($helperStop.Stdout -notmatch $blockPattern) "a helper Stop beside a bound shift is released: $($helperStop.Stdout)"
    $ownerStop = Invoke-Stop $workspace 'shift-session'
    Expect-True ($ownerStop.Stdout -match $blockPattern) "the bound conversation is held: $($ownerStop.Stdout)"

    # A stop-work order drops the record and keeps the lease until clock-out.
    $stopped = Invoke-Hook $stopShift '' $workspace @('-Project', $workspace)
    Expect-True ($stopped.ExitCode -eq 0) "stop-shift succeeds: $($stopped.Stdout)"
    Expect-True ($null -eq (Read-NSSession $ns)) 'stop-shift drops the session record'
    Expect-True ($null -ne (Read-NSLease $ns)) 'stop-shift keeps the lease'
    $helperBash = Invoke-Bash $workspace 'investigating-session' 'git status'
    Expect-True ($helperBash.ExitCode -eq 0 -and [string]::IsNullOrWhiteSpace($helperBash.Stdout)) `
        "another conversation is neither claimed nor fenced after a stop-work order: $($helperBash.Stdout)"
    Expect-True ($null -eq (Read-NSSession $ns)) 'another conversation does not take the dropped record'
    $ownerBash = Invoke-Bash $workspace 'shift-session' "Remove-Item -Force .nightshift\run\.shift-armed"
    Expect-True ($ownerBash.Stdout -match 'control files') "the leased conversation stays under the site rules: $($ownerBash.Stdout)"
    $session = Read-NSSession $ns
    Expect-True ($null -ne $session -and $session.SessionId -eq 'shift-session') 'the leased conversation records itself again'
}
finally {
    Set-Location ([IO.Path]::GetTempPath())
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures.Count -gt 0) {
    Write-Host "session claim logic failed ($($failures.Count)):"
    foreach ($failure in $failures) { Write-Host " - $failure" }
    exit 1
}
Write-Host 'session claim logic passed.'
exit 0
