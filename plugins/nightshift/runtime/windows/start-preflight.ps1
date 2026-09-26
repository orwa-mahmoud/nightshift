<#
.SYNOPSIS
  The Start skill's one preflight on native Windows.

.DESCRIPTION
  Mirrors runtime/start-preflight.sh. Prints one verdict per line:

    ok <topic> <detail>      a resolved fact the skill may report
    warn <topic> <detail>    arm anyway, but say this to the owner
    refuse <topic> <detail>  do not arm
    repair <text>            the exact repair for the refusal above it

  The verdict sentence is byte-identical to the POSIX helper; only interpolated
  paths and a parser's own diagnostic tail differ. Phase preflight covers
  everything before .shift-armed; phase snapshot records the plain Start's shift
  policy right before arming; phase bind is the Codex identity checkpoint that
  runs after the binding probe and before the watchman.

  Exit: 0 may arm - 1 refused - 2 usage
#>
param(
    [string]$Project = [Environment]::CurrentDirectory,
    [ValidateSet('claude', 'codex', 'cursor', 'unknown', '')]
    [string]$HostName = '',
    [ValidateSet('preflight', 'snapshot', 'bind')]
    [string]$Phase = 'preflight',
    [switch]$DryRun
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$pluginRoot = Resolve-Path (Join-Path $PSScriptRoot '../..')
Import-Module (Join-Path $pluginRoot 'lib/Nightshift.psm1') -Force -DisableNameChecking

$script:Refused = $false
function Write-Verdict {
    param([string]$Text)
    [Console]::Out.Write($Text + "`n")
}
function Write-Ok { param([string]$Text) Write-Verdict "ok $Text" }
function Write-Repair { param([string]$Text) Write-Verdict "repair $Text" }

$script:ExplainFile = Join-Path $pluginRoot 'lib/preflight-explain.txt'

# A warn or a refuse carries its own explanation, so no verdict site has to remember to print one.
# `ok` lines get none: a resolved fact explains itself.
function Write-Explain {
    param([string]$Text)
    $topic = Get-NSExplainTopic $Text
    foreach ($line in (Get-NSExplainLines $script:ExplainFile 'explain' $topic)) {
        Write-Verdict "explain $topic $line"
    }
    foreach ($line in (Get-NSExplainLines $script:ExplainFile 'repair' $topic)) {
        Write-Verdict "repair $line"
    }
}
function Write-Warn {
    param([string]$Text)
    Write-Verdict "warn $Text"
    Write-Explain $Text
}
function Write-Refuse {
    param([string]$Text)
    $script:Refused = $true
    Write-Verdict "refuse $Text"
    Write-Explain $Text
}

if ([string]::IsNullOrEmpty($HostName)) {
    if (-not [string]::IsNullOrEmpty([string]$env:CURSOR_PLUGIN_ROOT)) { $HostName = 'cursor' }
    elseif (-not [string]::IsNullOrEmpty([string]$env:CODEX_PROJECT_DIR + [string]$env:CODEX_SANDBOX + [string]$env:CODEX_SANDBOX_MODE)) { $HostName = 'codex' }
    elseif (-not [string]::IsNullOrEmpty([string]$env:CLAUDE_PLUGIN_ROOT + [string]$env:CLAUDE_PROJECT_DIR)) { $HostName = 'claude' }
    else { $HostName = 'unknown' }
}

try {
    $hostRoot = Resolve-NSCanonicalPath $Project
}
catch {
    Write-Refuse "workspace cannot resolve the project path $Project"
    Write-Repair 'invoke Start from the host-opened project folder'
    exit 1
}

$workspace = $hostRoot
$linkPath = Join-Path $hostRoot '.nightshift-link'
if (Test-NSPathEntry $linkPath) {
    try {
        $workspace = Resolve-NSWorkspaceRoot $hostRoot
        Write-Ok "link $hostRoot -> $workspace"
    }
    catch {
        Write-Refuse 'link .nightshift-link does not name one existing Nightshift workspace'
        Write-Repair 'rewrite .nightshift-link with one absolute path to a directory that already holds .nightshift/, or run link-workspace with an owner-provided path'
        exit 1
    }
}

$ns = Join-Path $workspace '.nightshift'
Write-Ok "host $HostName"
Write-Ok "workspace $workspace"

if (-not (Test-Path -LiteralPath $ns -PathType Container) -or (Test-NSReparsePoint $ns)) {
    Write-Refuse "workspace no usable .nightshift/ at $workspace"
    Write-Repair 'run Nightshift setup in this project before starting a shift'
    exit 1
}

# ------------------------------------------------------------- phase bind
# Codex exposes task identity through hook payloads, so the recorded id can only
# be classified after the binding probe has written .shift-session.
if ($Phase -eq 'bind') {
    $session = Read-NSSession $ns
    $recordedHost = if ($null -eq $session) { 'claude' } else { [string]$session.HostName }
    Write-Ok "session-host $recordedHost"
    if ($recordedHost -ne 'codex') {
        Write-Ok 'codex-identity not-applicable'
        exit 0
    }
    $sid = if ($null -eq $session) { '' } else { [string]$session.SessionId }
    $kind = Get-NSCodexIdentityKind $sid
    if ($kind -eq 'resumable') {
        Write-Ok 'codex-identity resumable'
    }
    elseif ($kind -eq 'missing') {
        Write-Warn 'codex-identity missing - same-thread recovery is unavailable until an identity is recorded, so revival falls back to a fresh session whose handover is the punch list'
    }
    else {
        Write-Refuse "codex-identity $kind - the watchman must not claim it resumed that thread"
        Write-Repair 'remove the markers this start created (.shift-armed and its new .shift-session) and reset the lease in the same call, append one failed-preflight line to shift-log.md, and stop before the watchman or item work'
    }
    if ($script:Refused) { exit 1 }
    exit 0
}

# --------------------------------------------------------- phase snapshot
# Start runs this right before it arms, after any draft or order was cut into the list, so the gate
# holds the shift to the contract and items it actually starts with. A composed shift already has
# its snapshot and keeps it.
if ($Phase -eq 'snapshot') {
    if (Test-Path -LiteralPath (Get-NSLayoutPath $ns 'shift-policy')) {
        Write-Ok 'snapshot composed - this shift keeps the policy it was composed with'
        exit 0
    }
    if ((Get-NSBoxCounts (Get-NSLayoutPath $ns 'punch-list')).Open -eq 0) {
        Write-Warn 'snapshot none recorded - the punch list has no open item to hold a shift to'
        exit 0
    }
    if ($DryRun) {
        Write-Ok 'snapshot dry-run - nothing recorded'
        exit 0
    }
    $snapshotId = New-NSStartSnapshot $workspace
    if (-not [string]::IsNullOrEmpty($snapshotId)) {
        Write-Ok "snapshot start-defaults recorded for shift $snapshotId"
    }
    else {
        Write-Warn 'snapshot none recorded - the gate cannot hold this shift to the list it armed with; Start again, or compose it through Hunt'
    }
    exit 0
}

# --------------------------------------------------------- state version
$stateKind = Get-NSStateKind $workspace
if ($stateKind -eq 'current') {
    Write-Ok ('state-version ' + (Get-NSStateVersion $workspace) + " ($stateKind)")
}
elseif ($stateKind -eq 'legacy') {
    $stateVersion = Get-NSStateVersion $workspace
    Write-Ok ('state-version ' + $stateVersion + " ($stateKind)")
    Write-Warn ('state-version ' + $stateVersion + ' keeps every state file at the top of .nightshift/ - Doctor offers the move to version ' + (Get-NSCurrentStateVersion) + ', previewed by ns migrate-state and made only with --apply')
}
else {
    Write-Refuse ('state-version ' + (Get-NSStateRefuseMessage $stateKind))
    Write-Repair 'Setup or Doctor repairs the marker with migrate-state; Start never writes it'
}

# ------------------------------------------------------ work mode/target
$workMode = ''
try {
    $workMode = Get-NSWorkMode $workspace
    Write-Ok "work-mode $workMode"
    $modeRecord = Get-NSLayoutPath $ns 'work-mode'
    $modeRecorded = (Test-Path -LiteralPath $modeRecord -PathType Leaf) -and ((Get-Item -LiteralPath $modeRecord).Length -gt 0)
    if (-not $modeRecorded) {
        $proposed = ''
        try { $proposed = Get-NSProposedWorkMode $workspace } catch { $proposed = '' }
        if ($proposed -eq 'artifact') {
            Write-Refuse 'work-mode unset and Setup would propose artifact'
            Write-Repair 'run Setup to record artifact mode; never git init a notes folder to make it a repository'
        }
    }
    if ($workMode -eq 'artifact') {
        $receipts = Get-NSReceiptsDir $workspace
        if ((Test-NSPathEntry $receipts) -and -not (Test-NSUsableReceiptsDir $workspace)) {
            Write-Refuse 'receipts artifact receipts path exists but is not a usable directory'
            Write-Repair "replace $receipts with a real directory so receipts can land"
        }
    }
}
catch {
    $workMode = ''
    Write-Refuse 'work-mode malformed - the site is unusable until Setup rewrites it'
    Write-Repair 'run Setup to record repository or artifact as one word'
}

try {
    $workTarget = Resolve-NSWorkTarget $workspace
    Write-Ok "work-target $workTarget"
    if (-not $DryRun) {
        $null = Confirm-NSWorkTargetLink $workspace
    }
}
catch {
    if ([string]$_.Exception.Message -match 'scratch') {
        Write-Refuse 'work-target resolves to a disposable scratch path'
        Write-Repair 'open the project from a persistent folder or Git repository, then run Setup there'
    }
    else {
        Write-Refuse "work-target cannot be resolved from $workspace"
        Write-Repair 'run Setup to record one work target; several child repositories make the choice ambiguous and Nightshift never guesses'
    }
}

# ------------------------------------------------- one shift, one agent
$lease = Read-NSLease $ns
$leaseState = 'absent'
if (Test-NSPathEntry (Get-NSLayoutPath $ns 'lease')) {
    if ($null -ne $lease) {
        $leaseState = 'valid'
    }
    else {
        $leaseState = 'malformed'
        Write-Refuse 'lease malformed - ownership cannot be proven, so this is unowned state'
        Write-Repair "issue STOP, then run ns stop-shift in a terminal and start again; never edit or delete .shift-lease by hand"
        # The owner runs this themselves, in a terminal, after STOP. Never from the blocked session.
        Write-Repair "if the lease is still unowned after that, reset it yourself with: Reset-NSStaleLease `"`$NS`" from the imported module - a false result is a refusal, not permission to delete the lease directly"
    }
}

$sitePaused = Test-NSSitePaused $ns
$session = Read-NSSession $ns
if ($null -ne $session) {
    $sessionState = Test-NSRecordedProcess ([string]$session.ProcessId) ([string]$session.Start)
    if (-not $sitePaused -and $sessionState -eq 'Alive') {
        Write-Refuse ('session an agent is already working this punch list on ' + [string]$session.HostName)
        Write-Repair "ask Nightshift for status, or pause it with ns stop-shift before starting a second shift"
        Write-Repair 'if that shift is already stopped, clear the leftover session with ns reset-shift'
    }
    elseif (-not $sitePaused -and $sessionState -eq 'Unavailable') {
        Write-Refuse 'session process-evidence-unavailable - a pid this host cannot classify is not a dead session'
        Write-Repair "run Start from a shell that can see the recorded process, or pause the shift with ns stop-shift"
        Write-Repair 'if that shift is already stopped, clear the leftover session with ns reset-shift'
    }
}

if (-not $sitePaused -and $leaseState -eq 'valid' -and (Test-NSLeasePidLive $ns)) {
    Write-Refuse ('lease a live process holds generation ' + [string]$lease.Generation + ' of this shift')
    Write-Repair "wait for that worker to exit, or pause the shift with ns stop-shift"
    Write-Repair 'if that shift is already stopped, clear the leftover session with ns reset-shift'
}

if ((Get-NSReasonCode $ns) -eq 'clock-out-failed' -and $leaseState -eq 'valid' -and
    [string]::IsNullOrEmpty([string]$lease.Nonce)) {
    Write-Warn 'lease terminal clock-out failed without releasing the shift - reopen the recorded conversation rather than resetting the lease'
}

$punch = Get-NSLayoutPath $ns 'punch-list'
$counts = Get-NSBoxCounts $punch
$open = [int]$counts.Open
$ticked = [int]$counts.Ticked

$watchmanLive = $false
$watchmanPath = Get-NSLayoutPath $ns 'watchman'
if ((Test-Path -LiteralPath $watchmanPath -PathType Leaf) -and -not (Test-NSReparsePoint $watchmanPath)) {
    $watchLines = @([IO.File]::ReadAllLines($watchmanPath))
    $watchPid = if ($watchLines.Count -gt 0) { $watchLines[0].Trim() } else { '' }
    $watchStart = if ($watchLines.Count -gt 1) { $watchLines[1] } else { '' }
    if ((Test-NSRecordedProcess $watchPid $watchStart) -eq 'Alive') { $watchmanLive = $true }
}
if ($watchmanLive -and (Test-Path -LiteralPath (Get-NSLayoutPath $ns 'armed') -PathType Leaf) -and $open -gt 0) {
    Write-Refuse 'watchman a live watchman is recovering this shift, including between recovery attempts'
    Write-Repair "ask Nightshift for status, or pause it with ns stop-shift; never kill that watchman as stale"
    # The panic form when the helper cannot be run: it only writes the marker, so the watchman
    # stands down at its next Stop event rather than immediately.
    Write-Repair ("if you cannot run that, write the marker yourself with: New-Item -ItemType File -Force `"" + (Get-NSLayoutPath $ns 'stop') + "`" - the watchman then stands down at its next Stop event")
}

if ($script:Refused) { exit 1 }

# ---------------------------------------- cross-host handoff, then reset
if ($leaseState -eq 'valid') {
    $fence = Test-NSHandoffFence -NightshiftDir $ns
    if ([int]$fence.ExitCode -eq 0) {
        Write-Ok 'fence takeover allowed - the prior worker is fenced and no duplicate is live'
    }
    elseif ([int]$fence.ExitCode -eq 1) {
        Write-Refuse 'fence the on-disk fence does not permit takeover'
        Write-Repair "pause the shift with ns stop-shift, then start again"
    }
    else {
        Write-Refuse 'fence the on-disk fence is missing or unreadable'
        Write-Repair "pause the shift with ns stop-shift, then start again"
    }
}
else {
    Write-Ok 'fence no prior worker to fence'
}

if ($script:Refused) { exit 1 }

# A paused shift with a spent deadline never gets a silent new budget.
if (-not [string]::IsNullOrEmpty((Get-NSControlStartRefuseReason $ns))) {
    Write-Refuse 'control a paused shift with an expired deadline does not get a silent new budget'
    Write-Repair 'run Reset then Start, or write the new UNIX epoch yourself; never clear STOP and never invent a time budget'
    exit 1
}

$endedGroup = ''
if (-not $DryRun) {
    if ((Stop-NSWatchman $ns) -eq 'unverified') {
        Write-Refuse 'watchman a recorded watchman pid could not be verified, so it was left running'
        Write-Repair "pause the shift with ns stop-shift, then start again"
        exit 1
    }
    # The folder the last shift filed into, read before its ending marker is cleared: an oversized
    # journal joins it below.
    $endedGroup = Get-NSArchiveGroupIfClaimed $workspace (Get-NSEndedField $workspace 'shiftId')
    # The last sign of work, read before its marker is cleared: where an interrupted shift's gap began.
    $lastActivity = Get-NSPulseEpoch $ns
    $wasArmed = Test-Path -LiteralPath (Get-NSLayoutPath $ns 'armed') -PathType Leaf
    $cleared = New-Object 'System.Collections.Generic.List[string]'
    foreach ($key in @('stop', 'stall', 'notified', 'ended', 'session-end', 'pulse',
            'mint-failed', 'session', 'armed', 'watchman-tick', 'lock')) {
        $marker = Get-NSLayoutPath $ns $key
        if (Test-NSPathEntry $marker) { $null = $cleared.Add((Split-Path -Leaf $marker)) }
    }
    $endedPath = Get-NSLayoutPath $ns 'ended'
    $stopPath = Get-NSLayoutPath $ns 'stop'
    $ended = ((Test-Path -LiteralPath $endedPath -PathType Leaf) -and -not (Test-NSReparsePoint $endedPath))
    $stopped = ((Test-Path -LiteralPath $stopPath -PathType Leaf) -and -not (Test-NSReparsePoint $stopPath))
    # Accounting follows the work. A shift that finished its list has its readings set aside, so the
    # next list starts clean. One that stopped, reached quitting time or died with items still open
    # is continued, and an open item keeps the time and tokens already spent on it: the readings
    # stay live, and an ended shift gets its own copy for its archive. The gap since its last work
    # is recorded as a pause unless one already covers it. Mirrors start-preflight.sh.
    $openNow = Get-NSOpenBoxesInFile (Get-NSLayoutPath $ns 'punch-list')
    $continued = $false
    if ($ended) {
        if ($openNow -gt 0) {
            $continued = $true
            $keptUsage = Copy-NSUsageSnapshot $ns (Get-NSEndedField $workspace 'shiftId')
            if (-not [string]::IsNullOrEmpty($keptUsage)) { $null = $cleared.Add('usage=>' + (Split-Path -Leaf $keptUsage)) }
        }
        else {
            $retiredUsage = Move-NSUsageRetire $ns (Get-NSEndedField $workspace 'shiftId')
            if (-not [string]::IsNullOrEmpty($retiredUsage)) { $null = $cleared.Add('usage->' + (Split-Path -Leaf $retiredUsage)) }
        }
    }
    elseif ($stopped -or $wasArmed) {
        $continued = $true
    }
    else {
        $retiredUsage = Move-NSUsageRetire $ns (Get-NSEndedField $workspace 'shiftId')
        if (-not [string]::IsNullOrEmpty($retiredUsage)) { $null = $cleared.Add('usage->' + (Split-Path -Leaf $retiredUsage)) }
    }
    if ($continued -and $null -ne $lastActivity -and (Test-Path -LiteralPath (Get-NSUsageDir $ns) -PathType Container) -and
        [long]$lastActivity -gt (Get-NSUsageLastPause $ns)) {
        $null = Write-NSUsagePause $ns 'the shift broke off here and Start resumed it' ([long]$lastActivity)
    }
    Remove-NSPath (Get-NSLayoutPath $ns 'stop')
    $deadlinePath = Get-NSLayoutPath $ns 'deadline'
    $deadlineSpent = $false
    if ((Test-Path -LiteralPath $deadlinePath -PathType Leaf) -and -not (Test-NSReparsePoint $deadlinePath)) {
        $rawDeadline = ([IO.File]::ReadAllText($deadlinePath)).Trim()
        if ($rawDeadline -match '^[0-9]+$' -and (Get-NSUnixTime) -ge [long]$rawDeadline) { $deadlineSpent = $true }
    }
    Clear-NSRuntimeMarkers $ns
    if ($deadlineSpent) {
        Remove-NSPath $deadlinePath
        $null = $cleared.Add('deadline')
    }
    # The markers Start writes next land where the layout keeps them.
    New-NSLayoutParent $ns 'armed'
    if ($cleared.Count -eq 0) { Write-Ok 'markers none' } else { Write-Ok ('markers ' + ($cleared -join ' ')) }
    Write-Ok 'lease reset'
}
else {
    Write-Ok 'markers dry-run'
    Write-Ok 'lease dry-run'
}

# ---------------------------------------------------------------- rules
$rulesPath = Get-NSLayoutPath $ns 'rules'
$rules = $null
if (-not (Test-Path -LiteralPath $rulesPath -PathType Leaf)) {
    Write-Refuse 'rules rules.json is missing'
    Write-Repair 'run Setup and accept the shipped rules template'
}
else {
    $rules = Get-NSRulesObject $workspace
    if ($null -eq $rules) {
        Write-Refuse 'rules rules.json is not the accepted shape: unreadable or not a JSON object'
        Write-Repair ('fix that named reason in ' + (Get-NSLayoutPath $ns 'rules') + ' or re-run Setup; never half-apply a broken file')
    }
    else {
        Write-Ok 'rules readable'
    }
}

if ($null -ne $rules) {
    $watchMinutes = Get-NSRule $workspace 'watchMinutes' ([string]$env:NIGHTSHIFT_WATCH)
    if ($watchMinutes -notmatch '^[0-9]+$') { $watchMinutes = '0' }
    if ([int]$watchMinutes -gt 0) {
        Write-Ok "watch-minutes $watchMinutes"
        $retry = Get-NSRule $workspace 'watchRetrySeconds' ([string]$env:NIGHTSHIFT_WATCH_RETRY)
        $resume = Expand-NSInjectedPaths $workspace (Get-NSRule $workspace 'revivalPrompt' ([string]$env:NIGHTSHIFT_REVIVAL_PROMPT))
        $fresh = Expand-NSInjectedPaths $workspace (Get-NSRule $workspace 'freshRevivalPrompt' ([string]$env:NIGHTSHIFT_FRESH_PROMPT))
        foreach ($pair in @(@('watchRetrySeconds', $retry), @('revivalPrompt', $resume), @('freshRevivalPrompt', $fresh))) {
            if ([string]::IsNullOrEmpty([string]$pair[1])) {
                Write-Refuse ('rules ' + $pair[0] + ' is empty, so the watchman would refuse to arm')
                Write-Repair ('restore ' + $pair[0] + ' from the shipped rules template with Setup')
            }
        }
    }
    else {
        Write-Ok 'watch-minutes 0 (watchman disarmed)'
    }

    # New knobs: the shipped template's top-level keys and its three native
    # question-tool entries. A key the template has and the file lacks means a
    # plugin update brought a knob nobody has reviewed. Start names it once and
    # never adds it.
    $newKeys = New-Object 'System.Collections.Generic.List[string]'
    $templatePath = Join-Path $pluginRoot 'skills/nightshift/references/nightshift-rules-template.json'
    if (Test-Path -LiteralPath $templatePath -PathType Leaf) {
        try {
            $template = Get-Content -Raw -LiteralPath $templatePath | ConvertFrom-Json
            $present = @($rules.PSObject.Properties.Name)
            foreach ($name in @($template.PSObject.Properties.Name)) {
                if ($present -notcontains $name) { $null = $newKeys.Add($name) }
            }
        }
        catch {
        }
    }
    $denyMap = $null
    $denyProperty = $rules.PSObject.Properties['toolDeny']
    if ($null -ne $denyProperty) { $denyMap = $denyProperty.Value }
    foreach ($tool in @('AskUserQuestion', 'request_user_input', 'AskQuestion')) {
        $known = $false
        if ($null -ne $denyMap -and $null -ne $denyMap.PSObject.Properties[$tool]) {
            $value = $denyMap.PSObject.Properties[$tool].Value
            if ($value -is [string]) { $known = $true }
        }
        if (-not $known) {
            Write-Warn "rules toolDeny.$tool has no explicit policy and must be repaired with Setup before that ask tool can run; a non-empty value denies, an empty value allows"
        }
    }
    if ($newKeys.Count -gt 0) {
        Write-Warn ('rules a plugin update brought knobs this file lacks: ' + ($newKeys -join ' ') +
            ' - review them with Setup; Start never adds them')
    }
}

# --------------------------------------------------------- provisioning
if (Test-NSPathEntry (Get-NSLayoutPath $ns 'provision-transaction')) {
    $provable = $false
    try {
        $report = Get-NSProvisionDiagnosis $workspace
        $provable = [bool]$report['provable']
    }
    catch {
        $provable = $false
    }
    if ($provable) {
        Write-Ok 'provision an interrupted install is proven recovered'
    }
    else {
        Write-Refuse 'provision an interrupted install cannot be proven recovered'
        Write-Repair "$(Get-NSLayoutName $ns 'provision-transaction') and provision-baseline/, restore by hand or run ns provision rollback after fixing the target, then Start again"
    }
}
else {
    Write-Ok 'provision none pending'
}

# ----------------------------------------------------- tonight's policy
$policyState = Get-NSShiftPolicyState $workspace
if ([string]$policyState['state'] -eq 'malformed') {
    Write-Refuse ('policy shift-policy.json is malformed: ' + [string]$policyState['error'])
    Write-Repair ('repair the named field in ' + (Get-NSLayoutPath $ns 'shift-policy') + ', or delete the file so the next Start writes safe defaults')
}
elseif ([string]$policyState['state'] -eq 'absent') {
    Write-Ok 'policy none - arming from rules.json'
}
else {
    Write-Ok 'policy resolved'
    # A snapshot is one night's approval. One the archive has already filed would run that
    # approval again, one-shift allowances included; Start's own snapshot draws a fresh id.
    $replayed = Find-NSReplayedShiftPolicy $workspace
    if (-not [string]::IsNullOrEmpty($replayed)) {
        Write-Refuse ('replay shift-policy.json is shift ' + (Get-NSRecordText $policyState['policy'] 'shiftId') +
            ', which has already run and is filed as ' + $replayed)
        Write-Repair ('remove ' + (Get-NSLayoutPath $ns 'shift-policy') + ' so the next Start writes a fresh snapshot, or compose the shift again with Hunt or Quality')
    }
}

# --------------------------------------------------- work and deadline
Write-Ok "punch-list open=$open ticked=$ticked"
$orders = Get-NSOpenBoxesInFile (Get-NSLayoutPath $ns 'work-orders')
$drafts = Get-NSOpenDrafts (Get-NSLayoutPath $ns 'drafting-table')
Write-Ok "staged orders=$orders drafts=$drafts"
if ($open -eq 0) {
    if ($orders -gt 0 -or $drafts -gt 0) {
        Write-Warn 'punch-list empty - offer the staged orders and drafts, and cut the owner''s choice'
    }
    else {
        Write-Warn 'punch-list empty and nothing is staged - Setup, Hunt, or a hand-written item is the next step'
    }
}

# A shift that asked for filing at clock-out and ended before it could. The next explicit Archive
# is where it gets picked up; Start neither files nor clears it.
$pendingFiling = Get-NSLayoutPath $ns 'pending-filing'
if ((Test-Path -LiteralPath $pendingFiling -PathType Leaf) -and -not (Test-NSReparsePoint $pendingFiling)) {
    Write-Warn "pending-filing the last shift asked for filing at clock-out and ended before it could - the next explicit Archive picks it up from $(Get-NSLayoutName $ns 'pending-filing')"
}

$openEnded = $false
if ((Test-Path -LiteralPath $punch -PathType Leaf) -and -not (Test-NSReparsePoint $punch)) {
    $inItems = $false
    foreach ($line in [IO.File]::ReadLines($punch)) {
        if (-not $inItems) {
            if ($line -match '^## Items\s*$') { $inItems = $true }
            continue
        }
        if ($line.Contains('Ending: open-ended')) { $openEnded = $true; break }
    }
}

$deadlineFile = ''
$deadlinePath = Get-NSLayoutPath $ns 'deadline'
if ((Test-Path -LiteralPath $deadlinePath -PathType Leaf) -and -not (Test-NSReparsePoint $deadlinePath)) {
    $raw = ([IO.File]::ReadAllText($deadlinePath)).Trim()
    if ($raw -match '^[0-9]+$') { $deadlineFile = $raw }
}
$policyDeadline = ''
if ([string]$policyState['state'] -eq 'ok' -and $null -ne $policyState['policy']) {
    $candidate = Get-NSMapValue $policyState['policy'] 'deadlineEpoch'
    if (Test-NSJsonInteger $candidate) { $policyDeadline = [string][long]$candidate }
}

if (-not [string]::IsNullOrEmpty($policyDeadline)) {
    Write-Ok ("deadline $policyDeadline (policy - write it to " + (Get-NSLayoutPath $ns 'deadline') + ')')
}
elseif (-not [string]::IsNullOrEmpty($deadlineFile)) {
    Write-Ok "deadline $deadlineFile (file - keep it and adopt it as the policy deadlineEpoch)"
}
elseif ($openEnded) {
    Write-Refuse 'deadline an open-ended item has no clock, and a walkthrough with no clock never ends'
    Write-Repair 'compose the shift through Hunt, which asks for hours; never invent a number'
}
else {
    Write-Ok 'deadline none (finite list - the last tick is the natural end)'
}

# -------------------------------------------------------------- journal
$logPath = Get-NSLayoutPath $ns 'shift-log'
if (-not $DryRun -and (Test-Path -LiteralPath $logPath -PathType Leaf) -and -not (Test-NSReparsePoint $logPath)) {
    if ((Get-Item -LiteralPath $logPath).Length -gt 512000) {
        # The journal joins the folder of the shift that ended last, beside anything Archive filed
        # there already, or a folder claimed for today when no shift is on record.
        try {
            $rotateGroup = $endedGroup
            if ([string]::IsNullOrEmpty($rotateGroup)) {
                $rotateGroup = Get-NSArchiveDir -Workspace $workspace -Date (Get-Date -Format 'yyyy-MM-dd') -ShiftId 'unknown'
            }
            $rotated = ''
            if (-not [string]::IsNullOrEmpty($rotateGroup)) { $rotated = Save-NSArchiveJournal $workspace $rotateGroup }
            if (-not [string]::IsNullOrEmpty($rotated)) {
                Write-Ok ('journal rotated to ' + $rotated.Substring($ns.Length).TrimStart([char]'/', [char]'\').Replace('\', '/'))
            }
        }
        catch {
            Write-Warn ('journal could not be rotated: ' + $_.Exception.Message)
        }
    }
}

# ------------------------------------------------ host permission mode
if ($HostName -eq 'claude') {
    $grant = $false
    foreach ($settingsFile in @((Join-Path $hostRoot '.claude/settings.local.json'), (Join-Path $hostRoot '.claude/settings.json'))) {
        if (-not (Test-Path -LiteralPath $settingsFile -PathType Leaf)) { continue }
        if ([IO.File]::ReadAllText($settingsFile) -match 'bypassPermissions|"allow"') { $grant = $true; break }
    }
    if ($grant) {
        Write-Ok "permissions frictionless permissions are granted at $hostRoot"
    }
    else {
        Write-Warn "permissions no frictionless grant in $hostRoot/.claude - a permission prompt mid-shift freezes the night and a headless revival is denied outright; Setup offers the fix"
    }
}
elseif ($HostName -eq 'codex') {
    Write-Warn 'permissions approvals are per launch - an unattended shift is started codex -a never -s danger-full-access, and the workspace-write sandbox blocks git commit; a contract that only ticks needs only workspace-write'
}
elseif ($HostName -eq 'cursor') {
    Write-Warn 'permissions arm the Cursor watchman only; revival mints or resumes a CLI worker in .shift-worker and never passes the IDE conversation id to agent --resume'
}
else {
    Write-Ok 'permissions host unknown - no permission-mode note'
}

if ($script:Refused) { exit 1 }
exit 0
