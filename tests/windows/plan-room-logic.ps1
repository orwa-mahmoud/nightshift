# The plan room on native Windows: the PowerShell half of tests/plan-room.bats.
# Run on macOS or Windows: pwsh -File tests/windows/plan-room-logic.ps1
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$repository = Resolve-Path (Join-Path $PSScriptRoot '../..')
$plugin = Join-Path $repository 'plugins/nightshift'
Import-Module (Join-Path $plugin 'lib/Nightshift.psm1') -Force -DisableNameChecking
$rulesTemplate = Join-Path $plugin 'skills/nightshift/references/nightshift-rules-template.json'
$hardhat = Join-Path $plugin 'hooks/windows/hardhat.ps1'
$hostExe = (Get-Process -Id $PID).Path
$failures = New-Object 'System.Collections.Generic.List[string]'
$utf8 = New-Object Text.UTF8Encoding($false)

function Expect-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        $failures.Add($Message)
        Write-Host "FAIL: $Message"
    }
}

# New-Room <path> - a version-2 workspace with no shift armed and the plan room open, bound to `planner`.
function New-Room {
    param([Parameter(Mandatory = $true)][string]$Path)
    $ns = Join-Path $Path '.nightshift'
    $null = New-Item -ItemType Directory -Path (Join-Path $ns 'staging'), (Join-Path $ns 'run'), (Join-Path $Path 'src') -Force
    Copy-Item -LiteralPath $rulesTemplate -Destination (Join-Path $ns 'rules.json') -Force
    [IO.File]::WriteAllText((Join-Path $ns 'state-version'), "2`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $ns 'punch-list.md'), "## Items`n", $utf8)
    & git -C $Path init --quiet
    $null = & $hostExe -NoProfile -NonInteractive -File (Join-Path $plugin 'runtime/windows/plan-enter.ps1') -Project $Path
    $null = Invoke-Hardhat $Path 'planner' @{ tool_name = 'PowerShell'; tool_input = @{ command = "`$null = 'nightshift-plan-probe'" } }
    return $ns
}

# Invoke-Hardhat <project> <session> <payload> - one PreToolUse call; the deny reason, or ''.
function Invoke-Hardhat {
    param([string]$Project, [string]$Session, [hashtable]$Payload)
    $Payload['session_id'] = $Session
    $json = $Payload | ConvertTo-Json -Compress -Depth 5
    $previous = $env:CLAUDE_PROJECT_DIR
    $env:CLAUDE_PROJECT_DIR = $Project
    try { $out = @($json | & $hostExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $hardhat -HostName claude 2>&1) -join "`n" }
    finally { $env:CLAUDE_PROJECT_DIR = $previous }
    if ($out.Trim().Length -eq 0) { return '' }
    try { return [string]($out | ConvertFrom-Json).hookSpecificOutput.permissionDecisionReason } catch { return "unreadable: $out" }
}

function New-Edit { param([string]$Tool, [string]$Path) return @{ tool_name = $Tool; tool_input = @{ file_path = $Path } } }
function New-Shell { param([string]$Command) return @{ tool_name = 'PowerShell'; tool_input = @{ command = $Command } } }

$root = Join-Path ([IO.Path]::GetTempPath()) ('ns-plan-room-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $root -Force
try {
    $w = Join-Path $root 'room'
    $ns = New-Room $w
    Expect-True ((Get-NSPlanRoomLine $ns 1) -ceq 'planner') 'the probe binds the room to the conversation that made it'
    Expect-True ((Invoke-Hardhat $w 'someone-else' (New-Shell "`$null = 'nightshift-plan-probe'")).StartsWith('BLOCKED: the plan room is bound to another conversation.')) 'a second probe is refused'

    $canonical = Resolve-NSWorkspaceRoot $w
    $expected = 'BLOCKED: the plan room is open, so nothing is implemented in this conversation. Tell the owner they are in the plan room and that this change was not made. Here you read, explore and write the plan into ' +
        (Join-Path $canonical '.nightshift/staging/').Replace('\', '/') + '. To build, the owner leaves the plan room: they type /nightshift:plan-exit, or approve the plan and type /nightshift:start.'
    foreach ($payload in @((New-Edit 'Edit' (Join-Path $w 'src/app.js')), (New-Edit 'Write' (Join-Path $w 'README.md')),
            (New-Shell 'Set-Content -Path notes.txt -Value hi'), (New-Shell 'git commit -m wip'), (New-Shell 'Remove-Item src -Recurse'),
            @{ tool_name = 'mcp__db__write'; tool_input = @{} })) {
        $reason = Invoke-Hardhat $w 'planner' $payload
        Expect-True ($reason.Replace('\', '/') -ceq $expected) "fenced: $($payload | ConvertTo-Json -Compress) -> $reason"
    }
    foreach ($payload in @((New-Edit 'Read' (Join-Path $w 'src/app.js')), (New-Shell 'git log --oneline -5'),
            (New-Shell 'Get-ChildItem src | Select-String TODO'), (New-Edit 'Write' (Join-Path $ns 'staging/plan.md')))) {
        $reason = Invoke-Hardhat $w 'planner' $payload
        Expect-True ($reason -ceq '') "free: $($payload | ConvertTo-Json -Compress) -> $reason"
    }
    Expect-True ((Invoke-Hardhat $w 'builder' (New-Edit 'Edit' (Join-Path $w 'src/app.js'))) -ceq '') 'another conversation is not fenced'
    $marker = Get-NSPlanRoomFile $ns
    foreach ($who in @('planner', 'builder')) {
        foreach ($payload in @((New-Shell "Remove-Item '$marker'"), (New-Edit 'Write' $marker), (New-Shell 'Remove-Item .nightshift/run/*'))) {
            $reason = Invoke-Hardhat $w $who $payload
            Expect-True ($reason.StartsWith("BLOCKED: the plan room marker is the owner's.")) "$who may not touch the marker: $reason"
        }
    }
    Expect-True (Test-Path -LiteralPath $marker -PathType Leaf) 'the marker survives'

    $status = (& $hostExe -NoProfile -NonInteractive -File (Join-Path $plugin 'runtime/windows/status.ps1') -Project $w) -join "`n"
    Expect-True ($status.Contains('Plan room:   open, bound to conversation planner')) "status: $status"
    $doctor = (& $hostExe -NoProfile -NonInteractive -File (Join-Path $plugin 'runtime/windows/doctor.ps1') -Project $w) -join "`n"
    Expect-True ($doctor.Contains('plan room open, bound to conversation planner')) "doctor: $doctor"
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures.Count -gt 0) {
    Write-Host "plan-room-logic failed ($($failures.Count)):"
    foreach ($failure in $failures) { Write-Host " - $failure" }
    exit 1
}
Write-Host 'plan-room-logic passed'
exit 0
