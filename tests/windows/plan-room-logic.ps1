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
            "& `"$nsPs`" plan-enter --host claude", "& `"$nsPs`" shift-estimate --items 4")) {
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

    # The plan record: created on entry, read back on entry, written without asking, filed when closed.
    $r = Join-Path $root 'record'
    $rns = Join-Path $r '.nightshift'
    $null = New-Item -ItemType Directory -Path $rns -Force
    Copy-Item -LiteralPath $rulesTemplate -Destination (Join-Path $rns 'rules.json') -Force
    [IO.File]::WriteAllText((Join-Path $rns 'state-version'), "2`n", $utf8)
    & git -C $r init --quiet
    $enter = Join-Path $plugin 'runtime/windows/plan-enter.ps1'
    $first = @(& $hostExe -NoProfile -NonInteractive -File $enter -Project $r)
    $record = Get-NSLayoutPath $rns 'plan-record'
    Expect-True ((Test-Path -LiteralPath $record -PathType Leaf) -and ([IO.File]::ReadAllLines($record)[0] -ceq '# Plan Record')) 'entering creates the plan record'
    Expect-True ($first -ccontains 'plan record .nightshift/staging/plan-record.md' -and $first -ccontains 'open plan: none') "first entry: $($first -join ' | ')"
    $dot = [char]0x00B7
    $entries = @(
        "- **Retry budget** $dot open since 2026-10-09 09:12 (UTC+04:00)",
        '  - Where we are: choosing between a fixed and an adaptive budget',
        "- **Config loader** $dot open since 2026-10-08 18:40 (UTC+04:00) $dot captured: ## Plan: Config loader",
        '  - Decided: one TOML file',
        "- **Dark mode** $dot open since 2026-10-07 11:05 (UTC+04:00) $dot dropped: not this quarter")
    [IO.File]::AppendAllText($record, (($entries -join "`n") + "`n"), $utf8)
    $again = @(& $hostExe -NoProfile -NonInteractive -File $enter -Project $r)
    $openLines = @($again | Where-Object { $_.StartsWith('open plan: ') })
    Expect-True ($openLines.Count -eq 1 -and $openLines[0] -ceq ('open plan: ' + $entries[0])) "re-entry reads back the open plan: $($again -join ' | ')"
    $null = Invoke-Hardhat $r 'planner' (New-Shell "`$null = 'nightshift-plan-probe'")
    Expect-True ((Invoke-Hardhat $r 'planner' (New-Edit 'Edit' $record)) -ceq '') 'the planning conversation writes the record'
    $null = & $hostExe -NoProfile -NonInteractive -File (Join-Path $plugin 'runtime/windows/plan-exit.ps1') -Project $r
    [IO.File]::WriteAllText((Get-NSLayoutPath $rns 'ended'), "shiftId=aaaa1111bbbb2222`narchiveRoot=archive`narchiveLayout=date`n", $utf8)
    $null = & $hostExe -NoProfile -NonInteractive -File (Join-Path $plugin 'runtime/windows/archive-receipts.ps1') -Project $r -Date 2026-10-09
    $filedRecord = Join-Path $rns 'archive/2026-10-09/staging/plan-record.md'
    $filedText = if (Test-Path -LiteralPath $filedRecord) { [IO.File]::ReadAllText($filedRecord) } else { '' }
    Expect-True ($filedText.Contains('**Config loader**') -and $filedText.Contains('**Dark mode**') -and -not $filedText.Contains('Retry budget')) "filed record: $filedText"
    $liveText = [IO.File]::ReadAllText($record)
    Expect-True ($liveText.Contains('**Retry budget**') -and -not $liveText.Contains('Config loader') -and $liveText.Contains('Filed: [2026-10-09](../archive/2026-10-09/staging/plan-record.md)')) "live record: $liveText"
    $legacy = Join-Path $root 'record-legacy'
    $lns = Join-Path $legacy '.nightshift'
    $null = New-Item -ItemType Directory -Path $lns -Force
    Copy-Item -LiteralPath $rulesTemplate -Destination (Join-Path $lns 'rules.json') -Force
    & git -C $legacy init --quiet
    $null = & $hostExe -NoProfile -NonInteractive -File $enter -Project $legacy
    $null = Invoke-Hardhat $legacy 'planner' (New-Shell "`$null = 'nightshift-plan-probe'")
    Expect-True ((Invoke-Hardhat $legacy 'planner' (New-Edit 'Write' (Get-NSLayoutPath $lns 'plan-record'))) -ceq '') 'a legacy layout writes its record too'
    Expect-True ((Get-NSPlanRecordOpen $rns).Count -eq 1) 'Get-NSPlanRecordOpen reads the one open plan'

    # The morning review: entering after a finished shift lists what it left for the owner.
    $v = Join-Path $root 'review'
    $vns = Join-Path $v '.nightshift'
    $null = New-Item -ItemType Directory -Path (Join-Path $vns 'run'), (Join-Path $vns 'inbox'), (Join-Path $vns 'receipts') -Force
    Copy-Item -LiteralPath $rulesTemplate -Destination (Join-Path $vns 'rules.json') -Force
    [IO.File]::WriteAllText((Join-Path $vns 'state-version'), "2`n", $utf8)
    & git -C $v init --quiet
    [IO.File]::WriteAllText((Get-NSLayoutPath $vns 'armed'), '', $utf8)
    [IO.File]::WriteAllText((Get-NSLayoutPath $vns 'ended'), "shiftId=aaaa1111bbbb2222`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $vns 'punch-list.md'), ("## Items`n- [x] **1. Parse the config.** <!-- id: aa11 -->`n- [ ] **2. Cache the parse.** <!-- id: bb22 -->`n" +
        "- [-] **3. Rewrite the loader.** <!-- id: cc33 -->`n  - Stopped: hard 45m reached`n"), $utf8)
    [IO.File]::WriteAllText((Get-NSLayoutPath $vns 'parking-lot'), ("# Parking Lot`n`n---`n`n- Keep the old flag name? $dot default: keep it`n" +
        "- Bump the minimum Node? $dot answered: yes, to 22`n"), $utf8)
    [IO.File]::WriteAllText((Get-NSLayoutPath $vns 'snag-log'), ("# Snag Log`n`n---`n`n- The loader retries forever $dot tests/loader.bats $dot 2026-10-09`n" +
        "- A typo in the help text $dot cli.sh $dot fixed $dot 2026-10-09`n"), $utf8)
    [IO.File]::WriteAllText((Join-Path $vns 'receipts/morning-2026-10-08-1111aaaa2222bbbb.md'), "# Morning`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $vns 'receipts/morning-2026-10-09-aaaa1111bbbb2222.md'), "# Morning`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $vns 'receipts/README.md'), "# Receipts`n", $utf8)
    $wantReview = @('review morning .nightshift/receipts/morning-2026-10-09-aaaa1111bbbb2222.md', 'review receipts .nightshift/receipts/README.md',
        "review parked Keep the old flag name? $dot default: keep it", "review snag The loader retries forever $dot tests/loader.bats $dot 2026-10-09",
        'review open **2. Cache the parse.**', 'review stopped **3. Rewrite the loader.**')
    $gotReview = @(@(& $hostExe -NoProfile -NonInteractive -File $enter -Project $v) | Where-Object { $_.StartsWith('review ') })
    Expect-True (($gotReview -join "`n") -ceq ($wantReview -join "`n")) "review: $($gotReview -join ' | ')"
    $direct = Get-NSPlanReview $vns; Expect-True (($direct -join "`n") -ceq ($wantReview -join "`n")) "Get-NSPlanReview lists the same review: $($direct -join ' | ')"
    Remove-Item -LiteralPath (Get-NSLayoutPath $vns 'ended') -Force
    $runningReview = Get-NSPlanReview $vns
    Expect-True ($runningReview.Count -gt 0 -and @($runningReview | Where-Object { $_ -cmatch '^review (open|stopped) ' }).Count -eq 0) "a running shift's items are not put up for review"
    Remove-Item -LiteralPath (Get-NSLayoutPath $vns 'armed') -Force
    $null = Invoke-Hardhat $v 'planner' (New-Shell "`$null = 'nightshift-plan-probe'")
    foreach ($key in @('parking-lot', 'snag-log', 'drafting-table')) {
        Expect-True ((Invoke-Hardhat $v 'planner' (New-Edit 'Edit' (Get-NSLayoutPath $vns $key))) -ceq '') "the plan room records review decisions in $key"
    }
    Expect-True ((Invoke-Hardhat $v 'planner' (New-Edit 'Edit' (Join-Path $vns 'punch-list.md'))).Length -gt 0) 'the punch list stays fenced'

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
