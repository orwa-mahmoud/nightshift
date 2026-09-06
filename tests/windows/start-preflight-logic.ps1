# Portable PowerShell coverage for the native Start preflight verdicts.
# Run on macOS or Windows: pwsh -File tests/windows/start-preflight-logic.ps1
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if (Test-Path Variable:PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $false
}

$repository = Resolve-Path (Join-Path $PSScriptRoot '../..')
$helper = Join-Path $repository 'plugins/nightshift/runtime/windows/start-preflight.ps1'
$posix = Join-Path $repository 'plugins/nightshift/runtime/start-preflight.sh'
$rulesTemplate = Join-Path $repository 'plugins/nightshift/skills/nightshift/references/nightshift-rules-template.json'
$hostExecutable = (Get-Process -Id $PID).Path
$failures = New-Object 'System.Collections.Generic.List[string]'

function Expect-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        $failures.Add($Message)
        Write-Host "FAIL: $Message"
    }
}

function Invoke-Preflight {
    param(
        [Parameter(Mandatory = $true)][string]$Project,
        [string[]]$Extra = @()
    )
    $argList = @(
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', $helper, '-Project', $Project
    ) + $Extra
    $outFile = [IO.Path]::GetTempFileName()
    $errFile = [IO.Path]::GetTempFileName()
    try {
        $process = Start-Process -FilePath $hostExecutable -ArgumentList $argList -NoNewWindow -Wait -PassThru `
            -RedirectStandardOutput $outFile -RedirectStandardError $errFile
        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            Stdout = [IO.File]::ReadAllText($outFile)
            Stderr = [IO.File]::ReadAllText($errFile)
        }
    }
    finally {
        Remove-Item -LiteralPath $outFile, $errFile -Force -ErrorAction SilentlyContinue
    }
}

function New-Site {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$Punch = "## Items`n- [ ] **1. work.**`n"
    )
    $ns = Join-Path $Path '.nightshift'
    $null = New-Item -ItemType Directory -Force -Path $ns
    Copy-Item -LiteralPath $rulesTemplate -Destination (Join-Path $ns 'rules.json') -Force
    [IO.File]::WriteAllText((Join-Path $ns 'punch-list.md'), $Punch)
    & git -C $Path init --quiet
    return $Path
}

$root = Join-Path ([IO.Path]::GetTempPath()) ('ns-start-preflight-' + [Guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $root
try {
    # A clean site arms, and nothing it prints is anything but a verdict.
    $clean = New-Site (Join-Path $root 'clean')
    $cleanRun = Invoke-Preflight $clean @('-HostName', 'claude')
    Expect-True ($cleanRun.ExitCode -eq 0) "clean site arms: $($cleanRun.Stdout) $($cleanRun.Stderr)"
    $cleanLines = @($cleanRun.Stdout -split "`n" | Where-Object { $_ -ne '' })
    Expect-True ($cleanLines.Count -gt 0) 'clean site prints verdicts'
    foreach ($line in $cleanLines) {
        Expect-True ($line -match '^(ok|warn|explain|repair|refuse) ') "every line is a verdict: $line"
    }
    Expect-True ($cleanRun.Stdout.Contains('ok host claude')) 'clean site names the host'
    Expect-True ($cleanRun.Stdout.Contains('ok work-mode repository')) 'clean site resolves repository mode'
    Expect-True ($cleanRun.Stdout.Contains('ok rules readable')) 'clean site reads the rules file'
    Expect-True ($cleanRun.Stdout.Contains('ok punch-list open=1 ticked=0')) 'clean site counts the punch list'
    Expect-True ($cleanRun.Stdout.Contains('ok deadline none (finite list')) 'a finite list needs no clock'

    # Nothing scaffolded: refuse and name Setup.
    $bare = Join-Path $root 'bare'
    $null = New-Item -ItemType Directory -Path $bare
    $bareRun = Invoke-Preflight $bare
    Expect-True ($bareRun.ExitCode -eq 1) 'a missing site refuses'
    Expect-True ($bareRun.Stdout.Contains('refuse workspace no usable .nightshift/')) 'the missing site is named'
    Expect-True ($bareRun.Stdout.Contains('repair run Nightshift setup in this project')) 'the repair is Setup'

    # A paused shift with a spent deadline never gets a silent new budget, and STOP survives.
    $spent = New-Site (Join-Path $root 'spent')
    [IO.File]::WriteAllText((Join-Path $spent '.nightshift/STOP'), "stopped by owner`n")
    [IO.File]::WriteAllText((Join-Path $spent '.nightshift/deadline'), "100`n")
    $spentRun = Invoke-Preflight $spent
    Expect-True ($spentRun.ExitCode -eq 1) 'a spent paused deadline refuses'
    Expect-True ($spentRun.Stdout.Contains('refuse control a paused shift with an expired deadline does not get a silent new budget')) `
        'the expired-budget refusal is verbatim'
    Expect-True ($spentRun.Stdout.Contains('never clear STOP and never invent a time budget')) 'the repair keeps STOP'
    Expect-True (Test-Path -LiteralPath (Join-Path $spent '.nightshift/STOP') -PathType Leaf) 'STOP survives the refusal'

    # An open-ended item with no clock refuses instead of inventing hours.
    $walk = New-Site (Join-Path $root 'walkthrough') "## Items`n- [ ] **1. walkthrough.** Ending: open-ended`n"
    $walkRun = Invoke-Preflight $walk
    Expect-True ($walkRun.ExitCode -eq 1) 'an unclocked walkthrough refuses'
    Expect-True ($walkRun.Stdout.Contains('refuse deadline an open-ended item has no clock')) 'the clockless refusal is verbatim'
    Expect-True ($walkRun.Stdout.Contains('never invent a number')) 'the repair sends the owner to Hunt'

    # Stale markers go, and a spent deadline goes with them; a future one stays.
    $stale = New-Site (Join-Path $root 'stale')
    $staleNs = Join-Path $stale '.nightshift'
    foreach ($marker in @('STOP', '.stall', '.notified', '.ended', '.session-end', '.shift-pulse',
            '.mint-failed', '.shift-session', '.shift-armed', '.watchman-tick')) {
        [IO.File]::WriteAllText((Join-Path $staleNs $marker), '')
    }
    [IO.File]::WriteAllText((Join-Path $staleNs 'deadline'), "100`n")
    $null = New-Item -ItemType Directory -Force -Path (Join-Path $staleNs '.lock.d')
    $staleRun = Invoke-Preflight $stale
    Expect-True ($staleRun.ExitCode -eq 0) "stale leftovers do not refuse: $($staleRun.Stdout)"
    foreach ($marker in @('STOP', '.stall', '.notified', '.ended', '.session-end', '.shift-pulse',
            '.mint-failed', '.shift-session', '.shift-armed', '.watchman-tick', '.lock.d', 'deadline')) {
        Expect-True (-not (Test-Path -LiteralPath (Join-Path $staleNs $marker))) "stale $marker is cleared"
    }

    $future = New-Site (Join-Path $root 'future')
    $futureEpoch = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 7200
    [IO.File]::WriteAllText((Join-Path $future '.nightshift/deadline'), "$futureEpoch`n")
    $futureRun = Invoke-Preflight $future
    Expect-True ($futureRun.ExitCode -eq 0) 'a future deadline arms'
    Expect-True ($futureRun.Stdout.Contains("ok deadline $futureEpoch (file")) 'a future deadline is tonight''s plan'
    Expect-True (Test-Path -LiteralPath (Join-Path $future '.nightshift/deadline') -PathType Leaf) 'a future deadline survives'

    # A malformed lease is unowned state: refuse, and never delete it here.
    $lease = New-Site (Join-Path $root 'lease')
    [IO.File]::WriteAllText((Join-Path $lease '.nightshift/.shift-lease'), "sid`nclaude`n1`n")
    $leaseRun = Invoke-Preflight $lease
    Expect-True ($leaseRun.ExitCode -eq 1) 'a malformed lease refuses'
    Expect-True ($leaseRun.Stdout.Contains('refuse lease malformed')) 'the malformed lease is named'
    Expect-True (Test-Path -LiteralPath (Join-Path $lease '.nightshift/.shift-lease') -PathType Leaf) `
        'the refusal leaves the lease on disk'

    # Rules: missing, broken, and an empty watchman recovery key each refuse with their repair.
    $noRules = New-Site (Join-Path $root 'no-rules')
    Remove-Item -LiteralPath (Join-Path $noRules '.nightshift/rules.json') -Force
    $noRulesRun = Invoke-Preflight $noRules
    Expect-True ($noRulesRun.ExitCode -eq 1) 'missing rules refuse'
    Expect-True ($noRulesRun.Stdout.Contains('refuse rules rules.json is missing')) 'missing rules are named'

    $badRules = New-Site (Join-Path $root 'bad-rules')
    [IO.File]::WriteAllText((Join-Path $badRules '.nightshift/rules.json'), "{`n")
    $badRulesRun = Invoke-Preflight $badRules
    Expect-True ($badRulesRun.ExitCode -eq 1) 'broken rules refuse'
    Expect-True ($badRulesRun.Stdout.Contains('refuse rules rules.json is not the accepted shape:')) 'broken rules are named'

    $emptyPrompt = New-Site (Join-Path $root 'empty-prompt')
    $emptyRules = Get-Content -Raw -LiteralPath (Join-Path $emptyPrompt '.nightshift/rules.json') | ConvertFrom-Json
    $emptyRules.revivalPrompt = ''
    [IO.File]::WriteAllText((Join-Path $emptyPrompt '.nightshift/rules.json'), ($emptyRules | ConvertTo-Json -Depth 12))
    $emptyPromptRun = Invoke-Preflight $emptyPrompt
    Expect-True ($emptyPromptRun.ExitCode -eq 1) 'an empty revivalPrompt refuses'
    Expect-True ($emptyPromptRun.Stdout.Contains('refuse rules revivalPrompt is empty, so the watchman would refuse to arm')) `
        'the empty recovery key is named'

    $noWatch = New-Site (Join-Path $root 'no-watch')
    $noWatchRules = Get-Content -Raw -LiteralPath (Join-Path $noWatch '.nightshift/rules.json') | ConvertFrom-Json
    $noWatchRules.watchMinutes = 0
    $noWatchRules.revivalPrompt = ''
    [IO.File]::WriteAllText((Join-Path $noWatch '.nightshift/rules.json'), ($noWatchRules | ConvertTo-Json -Depth 12))
    $noWatchRun = Invoke-Preflight $noWatch
    Expect-True ($noWatchRun.ExitCode -eq 0) 'watchMinutes 0 needs no recovery keys'
    Expect-True ($noWatchRun.Stdout.Contains('ok watch-minutes 0 (watchman disarmed)')) 'a disarmed watchman is reported'

    # An interrupted install refuses until it is proven recovered.
    $provision = New-Site (Join-Path $root 'provision')
    [IO.File]::WriteAllText((Join-Path $provision '.nightshift/provision-transaction.json'), "{`n")
    $provisionRun = Invoke-Preflight $provision
    Expect-True ($provisionRun.ExitCode -eq 1) 'an unproven install refuses'
    Expect-True ($provisionRun.Stdout.Contains('refuse provision an interrupted install cannot be proven recovered')) `
        'the unproven install is named'
    Expect-True ($provisionRun.Stdout.Contains('ns provision rollback after fixing the target, then Start again')) `
        'the restore instruction survives'

    # A future state-version fails closed and the marker is never rewritten.
    $futureState = New-Site (Join-Path $root 'future-state')
    [IO.File]::WriteAllText((Join-Path $futureState '.nightshift/state-version'), "99`n")
    $futureStateRun = Invoke-Preflight $futureState
    Expect-True ($futureStateRun.ExitCode -eq 1) 'a future state-version refuses'
    Expect-True ($futureStateRun.Stdout.Contains('refuse state-version Nightshift state-version is newer than this plugin supports')) `
        'the newer marker is named'
    Expect-True (([IO.File]::ReadAllText((Join-Path $futureState '.nightshift/state-version'))).Trim() -eq '99') `
        'the newer marker is left alone'

    # Each host gets its own permission-mode note.
    $perms = New-Site (Join-Path $root 'perms')
    $permsClaude = Invoke-Preflight $perms @('-HostName', 'claude')
    Expect-True ($permsClaude.Stdout.Contains('warn permissions no frictionless grant in')) 'Claude with no grant is warned'
    $null = New-Item -ItemType Directory -Force -Path (Join-Path $perms '.claude')
    [IO.File]::WriteAllText((Join-Path $perms '.claude/settings.local.json'),
        '{"permissions":{"defaultMode":"bypassPermissions"}}')
    $permsGranted = Invoke-Preflight $perms @('-HostName', 'claude')
    Expect-True ($permsGranted.Stdout.Contains('ok permissions frictionless permissions are granted at')) 'a grant is reported'
    $permsCodex = Invoke-Preflight $perms @('-HostName', 'codex')
    Expect-True ($permsCodex.Stdout.Contains('codex -a never -s danger-full-access')) 'Codex gets the unattended spelling'
    $permsCursor = Invoke-Preflight $perms @('-HostName', 'cursor')
    Expect-True ($permsCursor.Stdout.Contains('never passes the IDE conversation id to agent --resume')) `
        'Cursor keeps the IDE id off agent --resume'

    # The bind phase classifies the recorded Codex identity, after the probe and before the watchman.
    $bind = New-Site (Join-Path $root 'bind')
    [IO.File]::WriteAllText((Join-Path $bind '.nightshift/.shift-session'),
        "019624f3-6a41-7a6f-9f1e-3a8f0b2c4d5e`n/tmp/r.jsonl`n`n`ncodex`n")
    $bindOk = Invoke-Preflight $bind @('-Phase', 'bind')
    Expect-True ($bindOk.ExitCode -eq 0) "a resumable Codex id continues: $($bindOk.Stdout)"
    Expect-True ($bindOk.Stdout.Contains('ok codex-identity resumable')) 'a resumable Codex id is named'
    [IO.File]::WriteAllText((Join-Path $bind '.nightshift/.shift-session'),
        "thread_abc123`n/tmp/r.jsonl`n`n`ncodex`n")
    $bindRefuse = Invoke-Preflight $bind @('-Phase', 'bind')
    Expect-True ($bindRefuse.ExitCode -eq 1) 'a ChatGPT thread handle refuses the unattended start'
    Expect-True ($bindRefuse.Stdout.Contains('refuse codex-identity unsupported')) 'the unsupported identity is named'
    Expect-True ($bindRefuse.Stdout.Contains('before the watchman or item work')) 'the stop point is named'

    # The dry run reports and touches nothing.
    $dry = New-Site (Join-Path $root 'dry')
    [IO.File]::WriteAllText((Join-Path $dry '.nightshift/STOP'), '')
    $beforeDry = @(Get-ChildItem -LiteralPath (Join-Path $dry '.nightshift') -Recurse -Force |
            ForEach-Object { $_.FullName } | Sort-Object)
    $dryRun = Invoke-Preflight $dry @('-DryRun')
    Expect-True ($dryRun.Stdout.Contains('ok markers dry-run')) 'the dry run says so'
    $afterDry = @(Get-ChildItem -LiteralPath (Join-Path $dry '.nightshift') -Recurse -Force |
            ForEach-Object { $_.FullName } | Sort-Object)
    Expect-True (($beforeDry -join '|') -eq ($afterDry -join '|')) 'the dry run leaves the site byte-identical'

    # The two helpers ship together and print the same ASCII sentences.
    Expect-True (Test-Path -LiteralPath $posix -PathType Leaf) 'the POSIX helper ships beside the Windows twin'
    $helperBytes = [IO.File]::ReadAllBytes($helper)
    Expect-True (-not ($helperBytes | Where-Object { $_ -gt 127 })) 'the Windows twin is ASCII only'
    $posixText = [IO.File]::ReadAllText($posix)
    $helperText = [IO.File]::ReadAllText($helper)
    foreach ($phrase in @(
            'workspace no usable .nightshift/ at',
            'control a paused shift with an expired deadline does not get a silent new budget',
            'deadline an open-ended item has no clock',
            'provision an interrupted install cannot be proven recovered',
            'watch-minutes 0 (watchman disarmed)',
            'codex-identity resumable')) {
        Expect-True ($posixText.Contains($phrase)) "the POSIX helper keeps: $phrase"
        Expect-True ($helperText.Contains($phrase)) "the Windows twin keeps: $phrase"
    }

    if ($failures.Count -gt 0) {
        Write-Host "start-preflight logic failed ($($failures.Count)):"
        foreach ($failure in $failures) {
            Write-Host " - $failure"
        }
        exit 1
    }
    Write-Host 'start-preflight logic passed.'
    exit 0
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
