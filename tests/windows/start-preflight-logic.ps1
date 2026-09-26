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

    # An oversized journal joins the last ended shift's folder, after the log Archive filed there.
    $rotate = New-Site (Join-Path $root 'rotate')
    $filedDir = Join-Path $rotate '.nightshift/archive/2026-09-20'
    $null = New-Item -ItemType Directory -Force -Path $filedDir
    [IO.File]::WriteAllText((Join-Path $filedDir '.shift-id'), "1111222233334444`n")
    [IO.File]::WriteAllText((Join-Path $filedDir 'shift-log.md'), "# Shift Log`na filed line`n")
    [IO.File]::WriteAllText((Join-Path $rotate '.nightshift/.ended'),
        "shiftId=1111222233334444`narchiveRoot=archive`narchiveLayout=date`nshiftName=`narchiveFolder=2026-09-20`n")
    [IO.File]::WriteAllText((Join-Path $rotate '.nightshift/shift-log.md'), "# Shift Log`n" + ('x' * 600000) + "`n")
    $rotateRun = Invoke-Preflight $rotate @('-HostName', 'claude')
    Expect-True ($rotateRun.Stdout.Contains('ok journal rotated to archive/2026-09-20/shift-log.md')) "the journal joins the ended shift's folder: $($rotateRun.Stdout)"
    $filedLines = @([IO.File]::ReadAllLines((Join-Path $filedDir 'shift-log.md')))
    Expect-True ($filedLines.Count -eq 3 -and $filedLines[1] -ceq 'a filed line' -and $filedLines[2].Length -eq 600000) 'the filed log keeps its lines and gains the journal'
    Expect-True ([IO.File]::ReadAllText((Join-Path $rotate '.nightshift/shift-log.md')) -ceq "# Shift Log`n") 'the live journal starts again under its heading'

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

    # Stop-work keeps the live usage folder; a finished shift retires it.
    $keepUsage = New-Site (Join-Path $root 'keep-usage')
    [IO.File]::WriteAllText((Join-Path $keepUsage '.nightshift/STOP'), '')
    $null = New-Item -ItemType Directory -Force -Path (Join-Path $keepUsage '.nightshift/usage')
    [IO.File]::WriteAllText((Join-Path $keepUsage '.nightshift/usage/marks.tsv'), "arm`n")
    $keepRun = Invoke-Preflight $keepUsage
    Expect-True ($keepRun.ExitCode -eq 0) "stop-work resume keeps going: $($keepRun.Stdout)"
    Expect-True (Test-Path -LiteralPath (Join-Path $keepUsage '.nightshift/usage/marks.tsv') -PathType Leaf) `
        'stop-work resume keeps the live usage folder'
    $retireUsage = New-Site (Join-Path $root 'retire-usage') "## Items`n- [x] **1. work.**`n"
    [IO.File]::WriteAllText((Join-Path $retireUsage '.nightshift/.ended'), '')
    $null = New-Item -ItemType Directory -Force -Path (Join-Path $retireUsage '.nightshift/usage')
    [IO.File]::WriteAllText((Join-Path $retireUsage '.nightshift/usage/marks.tsv'), "arm`n")
    $retireRun = Invoke-Preflight $retireUsage
    Expect-True ($retireRun.ExitCode -eq 0) "a finished shift still starts: $($retireRun.Stdout)"
    Expect-True (-not (Test-Path -LiteralPath (Join-Path $retireUsage '.nightshift/usage'))) `
        'a finished shift retires usage'

    # A shift that ended with items open is continued: its readings stay live and the ended shift
    # gets its own copy. A shift that died armed keeps them too, and the gap from its last work is
    # recorded once.
    $continueEnded = New-Site (Join-Path $root 'continue-ended')
    [IO.File]::WriteAllText((Join-Path $continueEnded '.nightshift/.ended'), "shiftId=1111222233334444`n")
    $null = New-Item -ItemType Directory -Force -Path (Join-Path $continueEnded '.nightshift/usage')
    [IO.File]::WriteAllText((Join-Path $continueEnded '.nightshift/usage/marks.tsv'), "arm`n")
    $null = Invoke-Preflight $continueEnded
    Expect-True ((Test-Path -LiteralPath (Join-Path $continueEnded '.nightshift/usage/marks.tsv') -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $continueEnded '.nightshift/usage-1111222233334444/marks.tsv') -PathType Leaf)) `
        'a shift that ended with items open keeps its readings and copies them for its archive'
    $interrupted = New-Site (Join-Path $root 'interrupted')
    [IO.File]::WriteAllText((Join-Path $interrupted '.nightshift/.shift-armed'), '')
    $null = New-Item -ItemType Directory -Force -Path (Join-Path $interrupted '.nightshift/usage')
    [IO.File]::WriteAllText((Join-Path $interrupted '.nightshift/usage/marks.tsv'), "arm`n")
    [IO.File]::WriteAllText((Join-Path $interrupted '.nightshift/.shift-pulse'), "1790380000 sid`n")
    $null = Invoke-Preflight $interrupted
    $pauses = Join-Path $interrupted '.nightshift/usage/pauses.tsv'
    Expect-True ((Test-Path -LiteralPath $pauses -PathType Leaf) -and
        ([IO.File]::ReadAllText($pauses) -ceq "1790380000`tthe shift broke off here and Start resumed it`n")) `
        'an interrupted shift keeps its readings and records the gap from its last work once'

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
            'codex-identity resumable',
            'snapshot start-defaults recorded for shift',
            'snapshot none recorded - the gate cannot hold this shift to the list it armed with',
            'snapshot composed - this shift keeps the policy it was composed with',
            'snapshot none recorded - the punch list has no open item to hold a shift to',
            'snapshot dry-run - nothing recorded')) {
        Expect-True ($posixText.Contains($phrase)) "the POSIX helper keeps: $phrase"
        Expect-True ($helperText.Contains($phrase)) "the Windows twin keeps: $phrase"
    }

    # A plain Start records tonight's snapshot itself, in its own phase right before arming, with the
    # digests of the list it arms with. The preflight phase records none.
    Import-Module (Join-Path $repository 'plugins/nightshift/lib/Nightshift.psm1') -Force -DisableNameChecking
    $snap = New-Site (Join-Path $root 'snapshot')
    $preRun = Invoke-Preflight $snap @('-HostName', 'claude')
    Expect-True ($preRun.ExitCode -eq 0 -and -not $preRun.Stdout.Contains('ok snapshot')) 'the preflight itself records no snapshot'
    Expect-True (-not (Test-Path -LiteralPath (Join-Path (Join-Path $snap '.nightshift') 'shift-policy.json'))) `
        'the preflight leaves no policy behind'
    $snapRun = Invoke-Preflight $snap @('-Phase', 'snapshot')
    Expect-True ($snapRun.ExitCode -eq 0) "snapshot site arms: $($snapRun.Stdout) $($snapRun.Stderr)"
    Expect-True ($snapRun.Stdout -match 'ok snapshot start-defaults recorded for shift [0-9a-f]{16}') `
        "a plain Start records a snapshot: $($snapRun.Stdout)"
    $snapNs = Join-Path $snap '.nightshift'
    $snapPolicy = Join-Path $snapNs 'shift-policy.json'
    Expect-True (Test-Path -LiteralPath $snapPolicy -PathType Leaf) 'the snapshot file exists'
    if (Test-Path -LiteralPath $snapPolicy -PathType Leaf) {
        $doc = [IO.File]::ReadAllText($snapPolicy) | ConvertFrom-Json
        Expect-True ($doc.source -ceq 'start-defaults') 'the snapshot says who wrote it'
        Expect-True ($doc.verificationLevel -ceq 'none' -and $doc.toolingPolicy -ceq 'existing-tools') `
            'the snapshot keeps the values the resolved view showed'
        Expect-True ($null -eq $doc.deadlineEpoch) 'a finite list records no deadline'
        $snapPunch = Join-Path $snapNs 'punch-list.md'
        Expect-True ($doc.contractDigest -ceq (Get-NSPunchContractDigest $snapPunch)) 'the contract digest is the list armed with'
        Expect-True ($doc.itemsDigest -ceq (Get-NSPunchItemsDigest $snapPunch)) 'the items digest is the list armed with'
    }

    # A policy is one night's approval: once a night has run under it and been filed, arming it
    # again would replay that approval. Start's own snapshot draws an id the archive has never seen.
    $replay = New-Site (Join-Path $root 'replay')
    $replayNs = Join-Path $replay '.nightshift'
    $replayPolicy = Join-Path $replayNs 'shift-policy.json'
    $replayText = '{"schemaVersion":1,"shiftId":"9f2c40ab77e51d63","createdAt":"2026-09-02T00:00:00Z","source":"composition","deadlineEpoch":null,"verificationLevel":"final","toolingPolicy":"existing-tools"}' + "`n"
    [IO.File]::WriteAllText($replayPolicy, $replayText)
    $freshRun = Invoke-Preflight $replay @('-HostName', 'claude')
    Expect-True ($freshRun.ExitCode -eq 0 -and $freshRun.Stdout.Contains('ok policy resolved')) `
        "a policy that has not run arms: $($freshRun.Stdout) $($freshRun.Stderr)"
    Expect-True (-not $freshRun.Stdout.Contains('refuse replay')) 'a policy that has not run is no replay'
    $filed = Join-Path $replayNs 'archive/2026-09-02/older'
    $null = New-Item -ItemType Directory -Force -Path $filed
    Copy-Item -LiteralPath $replayPolicy -Destination (Join-Path $filed 'shift-policy-9f2c40ab77e51d63.json')
    $replayRun = Invoke-Preflight $replay @('-HostName', 'claude')
    Expect-True ($replayRun.ExitCode -eq 1) "a policy that has already run refuses: $($replayRun.Stdout)"
    Expect-True ($replayRun.Stdout -match '(?m)^refuse replay shift-policy\.json is shift 9f2c40ab77e51d63, which has already run and is filed as .*[\\/]archive[\\/]2026-09-02[\\/]older[\\/]shift-policy-9f2c40ab77e51d63\.json$') `
        "the refusal names the filed copy: $($replayRun.Stdout)"
    Expect-True ($replayRun.Stdout.Contains("explain replay A shift policy is one night's approval, and the verdict names the copy the archive filed")) `
        'the refusal explains itself from the shared table'
    Expect-True ($replayRun.Stdout -match '(?m)^repair remove .*shift-policy\.json so the next Start writes a fresh snapshot, or compose the shift again with Hunt or Quality$') `
        'the repair removes the live file or composes again'
    Expect-True ([IO.File]::ReadAllText($replayPolicy) -ceq $replayText) 'the refusal changes nothing'
    Remove-Item -LiteralPath $replayPolicy -Force
    $null = Invoke-Preflight $replay @('-Phase', 'snapshot')
    $freshDoc = [IO.File]::ReadAllText($replayPolicy) | ConvertFrom-Json
    Expect-True ($freshDoc.shiftId -cne '9f2c40ab77e51d63') "Start's own snapshot draws a fresh id"
    $afterRun = Invoke-Preflight $replay @('-HostName', 'claude')
    Expect-True ($afterRun.ExitCode -eq 0 -and -not $afterRun.Stdout.Contains('refuse replay')) `
        "a fresh snapshot arms: $($afterRun.Stdout)"

    $snapDeadline = New-Site (Join-Path $root 'snapshot-deadline')
    $epoch = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 7200
    [IO.File]::WriteAllText((Join-Path (Join-Path $snapDeadline '.nightshift') 'deadline'), "$epoch`n")
    $null = Invoke-Preflight $snapDeadline @('-Phase', 'snapshot')
    $deadlineDoc = [IO.File]::ReadAllText((Join-Path (Join-Path $snapDeadline '.nightshift') 'shift-policy.json')) | ConvertFrom-Json
    Expect-True ([long]$deadlineDoc.deadlineEpoch -eq $epoch) 'the snapshot adopts a deadline the owner already wrote'

    $snapDry = New-Site (Join-Path $root 'snapshot-dry')
    $dryRunSnap = Invoke-Preflight $snapDry @('-Phase', 'snapshot', '-DryRun')
    Expect-True ($dryRunSnap.Stdout.Contains('ok snapshot dry-run - nothing recorded')) 'a dry run says it recorded nothing'
    Expect-True (-not (Test-Path -LiteralPath (Join-Path (Join-Path $snapDry '.nightshift') 'shift-policy.json'))) `
        'a dry run records no snapshot'

    # An empty list gets no snapshot; an item cut into it after the preflight is what the snapshot holds.
    $snapCut = New-Site (Join-Path $root 'snapshot-cut') "## Items`n"
    $emptyRun = Invoke-Preflight $snapCut @('-Phase', 'snapshot')
    Expect-True ($emptyRun.Stdout.Contains('warn snapshot none recorded - the punch list has no open item to hold a shift to')) `
        "an empty list gets no snapshot: $($emptyRun.Stdout)"
    $cutPunch = Join-Path (Join-Path $snapCut '.nightshift') 'punch-list.md'
    [IO.File]::WriteAllText($cutPunch, "## Items`n- [ ] **1. cut from the drafts.**`n")
    $null = Invoke-Preflight $snapCut @('-Phase', 'snapshot')
    $cutDoc = [IO.File]::ReadAllText((Join-Path (Join-Path $snapCut '.nightshift') 'shift-policy.json')) | ConvertFrom-Json
    Expect-True ($cutDoc.itemsDigest -ceq (Get-NSPunchItemsDigest $cutPunch)) 'the snapshot holds the item cut after the preflight'

    $composedRun = Invoke-Preflight $snapCut @('-Phase', 'snapshot')
    Expect-True ($composedRun.Stdout.Contains('ok snapshot composed - this shift keeps the policy it was composed with')) `
        'a recorded policy is kept'

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
