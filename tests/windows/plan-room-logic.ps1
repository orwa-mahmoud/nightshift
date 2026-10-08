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

    # The read-only ns verbs run as the skills write them.
    $nsPs = Join-Path $plugin 'runtime/windows/ns.ps1'
    foreach ($command in @("& `"$nsPs`" status", "& '$nsPs' doctor", '& "$NIGHTSHIFT_PLUGIN_ROOT\runtime\windows\ns.ps1" path drafting-table',
            "& `"$nsPs`" plan-enter -HostName claude")) {
        $reason = Invoke-Hardhat $w 'planner' (New-Shell $command)
        Expect-True ($reason -ceq '') "free: $command -> $reason"
    }
    foreach ($command in @("& `"$nsPs`" scaffold product", "& `"$nsPs`" stop-shift", "& 'C:\evil\rm.exe' -rf src")) {
        $reason = Invoke-Hardhat $w 'planner' (New-Shell $command)
        Expect-True ($reason -ceq $expected -or $reason.Replace('\', '/') -ceq $expected) "fenced: $command -> $reason"
    }
    Expect-True (-not (Test-NSRestrictedCommand "& `"$nsPs`" plan-enter" 'wrapup')) 'wrap-up has no room to enter'
    Expect-True (Test-NSRestrictedCommand "& `"$nsPs`" status" 'wrapup') 'wrap-up reads status through the dispatcher'
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

    # Leaving. No agent tool call runs plan-exit, from any conversation.
    foreach ($who in @('planner', 'builder')) {
        foreach ($command in @('& $ns plan-exit', "& '$plugin/runtime/windows/plan-exit.ps1' -Project .", 'bash runtime/plan-exit.sh --project .')) {
            $reason = Invoke-Hardhat $w $who (New-Shell $command)
            Expect-True ($reason.StartsWith("BLOCKED: the plan room marker is the owner's.")) "$who may not run: $command -> $reason"
        }
    }
    Expect-True ((Invoke-Hardhat $w 'builder' (New-Edit 'Write' (Join-Path $w 'skills/plan-exit/SKILL.md'))) -ceq '') 'a path that only shares the name is not the verb'

    # Start refuses while the room is open and names both exits.
    $preflight = @(& $hostExe -NoProfile -NonInteractive -File (Join-Path $plugin 'runtime/windows/start-preflight.ps1') -Project $w -HostName claude)
    Expect-True ($LASTEXITCODE -ne 0) 'start-preflight refuses while the plan room is open'
    Expect-True ($preflight -ccontains 'refuse plan-room the plan room is open, bound to conversation planner, and a shift never arms over it') "preflight: $($preflight -join ' | ')"
    Expect-True (@($preflight | Where-Object { $_.StartsWith('repair the owner leaves the plan room by typing /nightshift:plan-exit or /nightshift:start') }).Count -eq 1) 'preflight repair names the exits'

    # The prompt hook: the owner's command closes the room, anything else does not.
    $promptHook = Join-Path $plugin 'hooks/windows/prompt-submit.ps1'
    function Invoke-PromptHook {
        param([string]$Project, [string]$HostName, [hashtable]$Payload)
        $Payload['session_id'] = 'planner'
        $Payload['cwd'] = $Project
        $json = $Payload | ConvertTo-Json -Compress
        $name = if ($HostName -eq 'claude') { 'CLAUDE_PROJECT_DIR' } else { 'CODEX_PROJECT_DIR' }
        $previous = [Environment]::GetEnvironmentVariable($name)
        [Environment]::SetEnvironmentVariable($name, $Project)
        try { return (@($json | & $hostExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $promptHook -HostName $HostName 2>&1) -join "`n") }
        finally { [Environment]::SetEnvironmentVariable($name, $previous) }
    }
    foreach ($name in @('nightshift:status', 'nightshift:plan-exits', 'other:plan-exit', 'plan-exit')) {
        $out = Invoke-PromptHook $w 'claude' @{ hook_event_name = 'UserPromptExpansion'; command_name = $name; prompt = "/$name" }
        Expect-True ($out.Trim().Length -eq 0 -and (Test-NSPlanRoomOpen $ns)) "claude $name leaves the room open: $out"
    }
    $out = Invoke-PromptHook $w 'claude' @{ hook_event_name = 'UserPromptExpansion'; command_name = 'nightshift:plan-exit'; prompt = '/nightshift:plan-exit' }
    Expect-True (-not (Test-NSPlanRoomOpen $ns)) 'claude /nightshift:plan-exit closes the room'
    $context = ($out | ConvertFrom-Json).hookSpecificOutput
    Expect-True ($context.hookEventName -ceq 'UserPromptExpansion' -and $context.additionalContext.StartsWith('nightshift: the owner left the plan room.')) "claude context: $out"
    $log = [IO.File]::ReadAllText((Get-NSLayoutPath $ns 'shift-log'))
    Expect-True ($log.Contains('plan room closed by the owner: typed the plan-exit command (conversation planner)')) "shift log: $log"

    $c = Join-Path $root 'codex'
    $cns = New-Room $c
    foreach ($prompt in @('please $nightshift:plan-exit', 'plan-exit', '$nightshift:status')) {
        $out = Invoke-PromptHook $c 'codex' @{ hook_event_name = 'UserPromptSubmit'; prompt = $prompt }
        Expect-True ($out.Trim().Length -eq 0 -and (Test-NSPlanRoomOpen $cns)) "codex '$prompt' leaves the room open: $out"
    }
    $out = Invoke-PromptHook $c 'codex' @{ hook_event_name = 'UserPromptSubmit'; prompt = '$nightshift:start' }
    Expect-True (-not (Test-NSPlanRoomOpen $cns)) 'codex $nightshift:start closes the room'
    Expect-True (($out | ConvertFrom-Json).hookSpecificOutput.additionalContext.Contains('by starting the shift')) "codex context: $out"

    # The shift's own conversation cannot enter the plan room; another conversation can.
    $s = Join-Path $root 'on-shift'
    $sns = Join-Path $s '.nightshift'
    $null = New-Item -ItemType Directory -Path (Join-Path $sns 'run'), (Join-Path $sns 'staging'), (Join-Path $s 'src') -Force
    Copy-Item -LiteralPath $rulesTemplate -Destination (Join-Path $sns 'rules.json') -Force
    [IO.File]::WriteAllText((Join-Path $sns 'state-version'), "2`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $sns 'punch-list.md'), "## Items`n- [ ] **1. first.**`n", $utf8)
    [IO.File]::WriteAllText((Get-NSLayoutPath $sns 'armed'), '', $utf8)
    [IO.File]::WriteAllText((Get-NSLayoutPath $sns 'session'), "shifter`n`n`n`nclaude`n", $utf8)
    & git -C $s init --quiet
    $null = & $hostExe -NoProfile -NonInteractive -File (Join-Path $plugin 'runtime/windows/plan-enter.ps1') -Project $s
    $reason = Invoke-Hardhat $s 'shifter' (New-Shell "`$null = 'nightshift-plan-probe'")
    Expect-True ($reason -ceq 'BLOCKED: this conversation is working the shift, so it cannot enter the plan room, and the plan room was not opened. Plan in another conversation, or stop the shift first.') "on-shift probe: $reason"
    Expect-True (-not (Test-NSPlanRoomOpen $sns)) 'the room the shift conversation asked for is not opened'
    $null = & $hostExe -NoProfile -NonInteractive -File (Join-Path $plugin 'runtime/windows/plan-enter.ps1') -Project $s
    Expect-True ((Invoke-Hardhat $s 'planner' (New-Shell "`$null = 'nightshift-plan-probe'")) -ceq '') 'another conversation plans while the shift runs'
    Expect-True ((Get-NSPlanRoomLine $sns 1) -ceq 'planner') 'and the room binds to it'

    # The terminal verb.
    $t = Join-Path $root 'terminal'
    $tns = New-Room $t
    $exit = @(& $hostExe -NoProfile -NonInteractive -File (Join-Path $plugin 'runtime/windows/plan-exit.ps1') -Project $t)
    Expect-True ($LASTEXITCODE -eq 0 -and ($exit -join "`n") -ceq 'plan room closed: nothing is fenced any more') "plan-exit: $($exit -join ' | ')"
    Expect-True (-not (Test-NSPlanRoomOpen $tns)) 'plan-exit closes the room'
    $again = @(& $hostExe -NoProfile -NonInteractive -File (Join-Path $plugin 'runtime/windows/plan-exit.ps1') -Project $t)
    Expect-True ($LASTEXITCODE -eq 0 -and ($again -join "`n") -ceq 'plan room was not open') "plan-exit again: $($again -join ' | ')"
    $log = [IO.File]::ReadAllText((Get-NSLayoutPath $tns 'shift-log'))
    Expect-True ($log.Contains('plan room closed by the owner: ran plan-exit in a terminal (conversation planner)')) "terminal shift log: $log"
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
