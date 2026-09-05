param(
    [string]$Project = [Environment]::CurrentDirectory
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$pluginRoot = Resolve-Path (Join-Path $PSScriptRoot '../..')
Import-Module (Join-Path $pluginRoot 'lib/Nightshift.psm1') -Force -DisableNameChecking

$here = $PSScriptRoot
$facts = New-Object Collections.Generic.List[string]
$warns = New-Object Collections.Generic.List[string]
$actions = New-Object Collections.Generic.List[string]
$policyLines = New-Object Collections.Generic.List[string]

function Add-NSFact { param([string]$Message) $null = $script:facts.Add($Message) }
function Add-NSWarn { param([string]$Message) $null = $script:warns.Add($Message) }
function Add-NSAct {
    param([ValidateSet('safe', 'confirm', 'blocked')][string]$Kind, [string]$Message)
    $null = $script:actions.Add("[$Kind] $Message")
}

try {
    $hostPath = Resolve-NSCanonicalPath $Project
}
catch {
    [Console]::Error.WriteLine("doctor: cannot cd to $Project")
    exit 1
}

$linkState = 'absent'
$workspace = $hostPath
$link = Join-Path $hostPath '.nightshift-link'
if (Test-NSPathEntry $link) {
    try {
        $workspace = Resolve-NSWorkspaceRoot $hostPath
        $linkState = 'valid'
        Add-NSFact "task root $hostPath links to workspace $workspace"
    }
    catch {
        $linkState = 'invalid'
        $workspace = $hostPath
        Add-NSWarn 'invalid .nightshift-link - Nightshift will not guess a workspace'
        Add-NSAct confirm "replace .nightshift-link with an absolute path to a directory that already contains .nightshift/, using $(Join-Path $here 'link-workspace.ps1')"
    }
}
else {
    Add-NSFact "task root is the workspace: $hostPath"
}

$ns = Join-Path $workspace '.nightshift'
$stateKind = Get-NSStateKind $workspace
$stateVer = Get-NSStateVersion $workspace

function Write-NSDoctorReport {
    param(
        [string]$NightshiftLabel,
        [string]$Target = '',
        [string]$HostRec = 'none',
        [string]$LeaseState = 'absent',
        [string]$LeaseGeneration = '',
        [int]$Armed = 0,
        [int]$Open = 0,
        [int]$Ticked = 0,
        [int]$Stop = 0,
        [int]$Ended = 0
    )
    Write-Output 'Nightshift Doctor'
    Write-Output "Host:        $hostPath"
    Write-Output "Workspace:   $workspace"
    Write-Output "Link:        $linkState"
    if (-not [string]::IsNullOrEmpty($Target)) {
        Write-Output "Work target: $Target"
        Write-Output "Recorded:    $HostRec"
        $leaseLine = $LeaseState
        if (-not [string]::IsNullOrEmpty($LeaseGeneration)) {
            $leaseLine = "$LeaseState (generation $LeaseGeneration)"
        }
        Write-Output "Lease:       $leaseLine"
        $ver = if ([string]::IsNullOrEmpty($stateVer)) { '-' } else { $stateVer }
        Write-Output "State:       $ver ($stateKind)"
        Write-Output "Armed:       $Armed  Open: $Open  Ticked: $Ticked  STOP: $Stop  Ended: $Ended"
    }
    else {
        Write-Output "Nightshift:  $NightshiftLabel"
    }
    Write-Output ''
    Write-Output 'Facts'
    if ($facts.Count -eq 0) { Write-Output 'none' } else { $facts | ForEach-Object { Write-Output $_ } }
    Write-Output ''
    Write-Output 'resolved policy'
    if ($policyLines.Count -eq 0) { Write-Output 'none' } else { $policyLines | ForEach-Object { Write-Output $_ } }
    Write-Output ''
    Write-Output 'Warnings'
    if ($warns.Count -eq 0) { Write-Output 'none' } else { $warns | ForEach-Object { Write-Output $_ } }
    Write-Output ''
    Write-Output 'Actions (Doctor does not perform these)'
    if ($actions.Count -eq 0) { Write-Output 'none' } else { $actions | ForEach-Object { Write-Output $_ } }
}

if (-not (Test-Path -LiteralPath $ns -PathType Container)) {
    Add-NSWarn "no .nightshift/ at $workspace"
    Add-NSAct confirm 'run Nightshift setup from the project you want to change (not a ChatGPT scratch workspace)'
    Write-NSDoctorReport -NightshiftLabel 'missing'
    exit 0
}

$unusableRecv = $false
$reportedMode = ''
try {
    $reportedMode = Get-NSWorkMode $workspace
    Add-NSFact "work mode $reportedMode"
    $modeRecord = Join-Path $ns 'work-mode'
    if (-not (Test-Path -LiteralPath $modeRecord -PathType Leaf)) {
        try {
            if ((Get-NSProposedWorkMode $workspace) -eq 'artifact') {
                Add-NSWarn 'work mode is unset; Setup would propose artifact'
                Add-NSAct confirm 'persist the proposed artifact mode with Setup; Doctor does not write work-mode'
            }
        }
        catch {
        }
    }
    if ($reportedMode -eq 'artifact') {
        Add-NSFact "artifact receipts $(Get-NSReceiptsCount $workspace)"
        $latest = Get-NSLatestReceipt $workspace
        if (-not [string]::IsNullOrEmpty($latest)) {
            Add-NSFact "latest artifact receipt $([IO.Path]::GetFileName($latest))"
        }
        $recv = Get-NSReceiptsDir $workspace
        if ((Test-NSPathEntry $recv) -and -not (Test-NSUsableReceiptsDir $workspace)) {
            $unusableRecv = $true
            Add-NSWarn 'artifact receipts path is not a usable directory'
            Add-NSAct confirm 'replace the unusable receipts path with a real directory so write-receipt can land; Doctor does not rewrite it'
        }
    }
}
catch {
    Add-NSWarn 'work mode is malformed; treating the site as unusable until Setup rewrites it'
}

$target = $workspace
try {
    $target = Resolve-NSWorkTarget $workspace
    Add-NSFact "work target $target"
}
catch {
    $target = $workspace
    if ($_.Exception.Message -match 'scratch') {
        Add-NSWarn 'work target is a disposable scratch workspace'
    }
    else {
        Add-NSWarn 'work target could not be resolved; treating workspace as the code root'
    }
}

# The one resolver renders the one view: every effective setting, where it came
# from, and when it expires. Doctor reads it and never re-derives precedence.
$resolution = $null
try {
    $resolution = Get-NSPolicyResolution $workspace
}
catch {
    Add-NSWarn 'the shift policy could not be resolved; treat the shift as built-in defaults plus rules'
}
if ($null -ne $resolution) {
    foreach ($policyLine in (Format-NSPolicyTable $resolution)) { $null = $policyLines.Add($policyLine) }
    if ($resolution['policyState'] -ceq 'malformed') {
        Add-NSWarn "shift-policy.json is malformed ($($resolution['policyError'])); the shift resolves to built-in defaults and rules only"
        Add-NSAct confirm 'repair the named field in shift-policy.json, or delete the file so the next Start writes safe defaults'
    }
    $deadlineFileEpoch = $resolution['deadlineFile']
    $deadlinePolicyEpoch = $resolution['deadlinePolicy']
    if ($null -ne $deadlineFileEpoch -and $null -ne $deadlinePolicyEpoch -and [long]$deadlineFileEpoch -ne [long]$deadlinePolicyEpoch) {
        Add-NSWarn "deadline file $deadlineFileEpoch does not match shift-policy deadlineEpoch $deadlinePolicyEpoch; the gate honours the earlier value"
        Add-NSAct confirm 'synchronize the deadline projection with the policy before the next arm; Doctor rewrites neither'
    }
}

# An interrupted provisioning transaction is the one piece of state that can
# leave a half-installed tool behind. Doctor reads the same diagnosis the
# recovery helper prints, and restores nothing.
$provisionRepair = 'inspect .nightshift/provision-transaction.json and provision-baseline/, restore by hand or run provision.ps1 rollback after fixing the target, then Start again'
$provision = $null
try {
    $provision = Get-NSProvisionDiagnosis $workspace
}
catch {
    Add-NSWarn 'provision-transaction.json cannot be read; Start will refuse to arm'
    Add-NSAct confirm $provisionRepair
}
if (($null -ne $provision) -and $provision['present']) {
    $provisionLine = Get-NSProvisionDiagnosisLine $provision
    if ((Get-NSProvisionDiagnosisClass $provision) -ceq 'provable') {
        Add-NSFact $provisionLine
        Add-NSAct confirm "run $(Join-Path $here 'provision.ps1') -Project $hostPath recover before the next Start; Doctor never recovers"
    }
    else {
        Add-NSWarn ($provisionLine + '; Start will refuse to arm')
        Add-NSAct confirm $provisionRepair
    }
}

$punch = Join-Path $ns 'punch-list.md'
$open = 0
$ticked = 0
if (Test-Path -LiteralPath $punch -PathType Leaf) {
    $counts = Get-NSBoxCounts $punch
    $open = [int]$counts.Open
    $ticked = [int]$counts.Ticked
    Add-NSFact "punch list open=$open ticked=$ticked"
}
else {
    Add-NSWarn 'punch-list.md is missing'
}

try {
    if ((Get-NSWorkMode $workspace) -eq 'artifact' -and $ticked -gt 0 -and (Get-NSReceiptsCount $workspace) -eq 0 -and -not $unusableRecv) {
        Add-NSWarn 'artifact mode has ticked items but no receipts'
        Add-NSAct confirm "complete ticked items with $(Join-Path $here 'write-receipt.ps1') or untick them; Doctor does not rewrite the punch list"
    }
}
catch {
}

$orders = Get-NSOpenBoxesInFile (Join-Path $ns 'work-orders.md')
if ($orders -gt 0) {
    Add-NSFact "pending Hunt work orders=$orders"
}
$drafts = Get-NSOpenDrafts (Join-Path $ns 'drafting-table.md')
if ($drafts -gt 0) {
    Add-NSFact "staged drafting-table items=$drafts"
}

$armed = [int](Test-Path -LiteralPath (Join-Path $ns '.shift-armed') -PathType Leaf)
$endedPath = Join-Path $ns '.ended'
$ended = 0
if (Test-NSReparsePoint $endedPath) {
    Add-NSWarn 'ended path is not a usable file'
}
elseif (Test-Path -LiteralPath $endedPath -PathType Leaf) {
    $ended = 1
}
$stop = [int](Test-Path -LiteralPath (Join-Path $ns 'STOP') -PathType Leaf)
$sessionEndPath = Join-Path $ns '.session-end'
$sessionEnd = 0
if (Test-NSReparsePoint $sessionEndPath) {
    Add-NSWarn 'session-end path is not a usable file'
}
elseif (Test-Path -LiteralPath $sessionEndPath -PathType Leaf) {
    $sessionEnd = 1
}
$pulsePath = Join-Path $ns '.shift-pulse'
$pulse = 0
if (Test-NSReparsePoint $pulsePath) {
    Add-NSWarn 'shift-pulse path is not a usable file'
}
elseif (Test-Path -LiteralPath $pulsePath -PathType Leaf) {
    $pulse = 1
}
$stall = ''
$stallPath = Join-Path $ns '.stall'
if (Test-NSReparsePoint $stallPath) {
    Add-NSWarn 'stall path is not a usable file'
}
elseif (Test-Path -LiteralPath $stallPath -PathType Leaf) {
    try {
        $stall = (([IO.File]::ReadAllText($stallPath)) -replace '\s', '')
    }
    catch {
        $stall = ''
    }
}

if ($armed -eq 1) { Add-NSFact 'shift is armed' } else { Add-NSFact 'shift is not armed' }
switch ($stateKind) {
    'current' {
        $ver = if ([string]::IsNullOrEmpty($stateVer)) { '1' } else { $stateVer }
        Add-NSFact "state version $ver (current)"
    }
    'legacy' {
        Add-NSFact 'state version 0 (legacy - no state-version marker)'
        $migrator = Join-Path $here 'migrate-state.ps1'
        if ($armed -eq 1) {
            Add-NSWarn 'legacy workspace cannot be migrated while a shift is armed'
            Add-NSAct blocked "wait until the shift is unarmed, then write version 1 with $migrator"
        }
        else {
            Add-NSAct confirm "write $(Join-Path $ns 'state-version') as 1 with $migrator - only the marker is added"
        }
    }
    'future' {
        $ver = if ([string]::IsNullOrEmpty($stateVer)) { 'unknown' } else { $stateVer }
        Add-NSWarn "state version $ver is newer than this plugin supports (1)"
        Add-NSAct blocked 'upgrade Nightshift; never rewrite or downgrade a newer state-version'
    }
    'malformed' {
        Add-NSWarn 'state-version is malformed'
        Add-NSAct confirm "inspect $(Join-Path $ns 'state-version') and replace it with a single integer while unarmed - never guess"
    }
}
if ($ended -eq 1) { Add-NSFact 'gate has clocked the shift out (.ended)' }
if ($stop -eq 1) { Add-NSFact 'STOP is present' }
if ($sessionEnd -eq 1) { Add-NSFact 'clean session-end marker is present' }
if ($pulse -eq 1) { Add-NSFact 'shift-pulse marker is present' }
if (-not [string]::IsNullOrEmpty($stall)) { Add-NSFact "stall count $stall" }

$deadlinePath = Join-Path $ns 'deadline'
if (Test-NSReparsePoint $deadlinePath) {
    Add-NSWarn 'deadline path is not a usable file'
}
elseif (-not (Test-Path -LiteralPath $deadlinePath -PathType Leaf)) {
    Add-NSFact 'deadline=none'
}
else {
    $dlRaw = ''
    try {
        $dlRaw = ([IO.File]::ReadAllText($deadlinePath)).Trim()
    }
    catch {
        $dlRaw = ''
    }
    if ($dlRaw -match '^[0-9]+$') {
        $now = Get-NSUnixTime
        $dl = [long]$dlRaw
        if ($now -ge $dl) {
            Add-NSFact "deadline=$dlRaw remaining=0s (elapsed)"
        }
        else {
            $rem = $dl - $now
            Add-NSFact "deadline=$dlRaw remaining=${rem}s"
        }
    }
    else {
        Add-NSWarn 'deadline is not a UNIX epoch - watchmen compare integer seconds'
    }
}

if ($armed -eq 1 -and $open -eq 0 -and $ended -eq 0) {
    Add-NSWarn 'armed with no open boxes and no .ended - clock-out may still be due'
    Add-NSAct confirm 'ask Nightshift for status, or start so the watchman can spawn the clock-out'
}
if ($stop -eq 1 -and $armed -eq 1) {
    Add-NSWarn 'stop-work order is pending until the next stop attempt'
    Add-NSAct confirm "run $(Join-Path $here 'stop-shift.ps1') -Project $hostPath to disarm immediately; a bare STOP file waits for the next Stop event; do not delete STOP by hand"
}
if ($stop -eq 1 -and $armed -eq 0) {
    Add-NSWarn 'STOP leftover while no shift is armed - start will clear it'
    Add-NSAct confirm 'run start when you want a new shift, which clears stale STOP'
}
if ((Test-Path -LiteralPath $punch -PathType Leaf) -and $open -eq 0) {
    Add-NSFact 'punch list has no open items - leftover Shift contract and Gates still bind the next Hunt or Start cut'
    if ($armed -eq 0) {
        Add-NSWarn 'empty punch list will inherit the current contract'
        Add-NSAct confirm 'review punch-list.md contract and Gates before composing a new campaign; Archive files ticked items but never resets them'
    }
}
# Staged work is only an offer when there is nothing already approved to do. An open checkbox
# under ## Items is the shift, so Doctor reports what is staged and stops there - the same
# precedence Start applies, said the same way.
if ($orders -gt 0 -and $armed -eq 0 -and $open -eq 0) {
    Add-NSAct confirm 'start to promote a parked Hunt order, or hunt to compose a new one'
}
if ($drafts -gt 0 -and $armed -eq 0 -and $open -eq 0) {
    Add-NSAct confirm 'promote agreed drafting-table items into punch-list.md, or start to be offered them'
}
if ($open -gt 0 -and ($orders -gt 0 -or $drafts -gt 0)) {
    Add-NSFact "staged work is informational while $open punch-list items are open - start works the current list, and drafts and Hunt orders stay staged for a later shift"
}

$rulesPath = Join-Path $ns 'rules.json'
if (-not (Test-Path -LiteralPath $rulesPath -PathType Leaf)) {
    Add-NSWarn 'rules.json is missing - watchman will refuse to arm'
    Add-NSAct confirm 're-run setup and accept the shipped rules template'
}
else {
    $rules = Get-NSRulesObject $workspace
    if ($null -eq $rules) {
        Add-NSWarn 'rules.json is unreadable or not a JSON object'
        Add-NSAct confirm "fix $rulesPath or re-run setup - never half-apply a broken file"
    }
    else {
        Add-NSFact 'rules.json is a JSON object'
        $wm = Get-NSRule $workspace 'watchMinutes' ''
        if ($wm -notmatch '^[0-9]+$') {
            Add-NSWarn 'watchMinutes missing or not a whole number'
            Add-NSAct confirm 'restore watchMinutes from the shipped template (10, or 0 to disarm)'
        }
        else {
            Add-NSFact "watchMinutes $wm"
        }
        $retrySpacing = Get-NSRule $workspace 'watchRetrySeconds' ([string]$env:NIGHTSHIFT_WATCH_RETRY)
        $revivalPrompt = Expand-NSInjectedPaths $workspace (Get-NSRule $workspace 'revivalPrompt' ([string]$env:NIGHTSHIFT_REVIVAL_PROMPT))
        $freshPrompt = Expand-NSInjectedPaths $workspace (Get-NSRule $workspace 'freshRevivalPrompt' ([string]$env:NIGHTSHIFT_FRESH_PROMPT))
        if ([string]::IsNullOrEmpty($retrySpacing)) {
            Add-NSWarn 'watchRetrySeconds is empty - watchman will refuse to arm'
            Add-NSAct confirm 'restore watchRetrySeconds from the shipped template'
        }
        if ([string]::IsNullOrEmpty($revivalPrompt)) {
            Add-NSWarn 'revivalPrompt is empty - watchman will refuse to arm'
            Add-NSAct confirm 'restore revivalPrompt from the shipped template'
        }
        if ([string]::IsNullOrEmpty($freshPrompt)) {
            Add-NSWarn 'freshRevivalPrompt is empty - watchman will refuse to arm'
            Add-NSAct confirm 'restore freshRevivalPrompt from the shipped template'
        }
        $toolDeny = $null
        if ($null -ne $rules.PSObject.Properties['toolDeny']) {
            $toolDeny = $rules.toolDeny
        }
        foreach ($tool in @('AskUserQuestion', 'request_user_input', 'AskQuestion')) {
            $toolState = 'invalid'
            if ($null -eq $toolDeny -or $toolDeny -is [Array] -or $toolDeny -is [string] -or $toolDeny -is [ValueType]) {
                $toolState = 'invalid'
            }
            elseif ($null -eq $toolDeny.PSObject.Properties[$tool]) {
                $toolState = 'missing'
            }
            elseif ($toolDeny.PSObject.Properties[$tool].Value -isnot [string]) {
                $toolState = 'invalid'
            }
            elseif ([string]$toolDeny.PSObject.Properties[$tool].Value -eq '') {
                $toolState = 'allow'
            }
            else {
                $toolState = 'deny'
            }
            switch ($toolState) {
                'allow' { Add-NSFact "toolDeny.$tool explicitly allows the question tool" }
                'deny' { Add-NSFact "toolDeny.$tool explicitly denies the question tool" }
                default {
                    Add-NSWarn "toolDeny.$tool is $toolState - question behavior has no explicit policy"
                    Add-NSAct confirm "re-run setup and review the shipped $tool entry (non-empty denies; empty allows)"
                }
            }
        }
    }
}

$hostRec = 'none'
$sid = ''
$tpath = ''
$spid = ''
$sstart = ''
$sessionPath = Join-Path $ns '.shift-session'
if (Test-NSReparsePoint $sessionPath) {
    Add-NSWarn 'shift-session path is not a usable file'
}
elseif (Test-Path -LiteralPath $sessionPath -PathType Leaf) {
    try {
        $sessionLines = [IO.File]::ReadAllLines($sessionPath)
        if ($sessionLines.Count -gt 0) { $sid = [string]$sessionLines[0] }
        if ($sessionLines.Count -gt 1) { $tpath = [string]$sessionLines[1] }
        if ($sessionLines.Count -gt 2) { $spid = ([string]$sessionLines[2] -replace '\s', '') }
        if ($sessionLines.Count -gt 3) { $sstart = [string]$sessionLines[3] }
        if ($sessionLines.Count -gt 4 -and -not [string]::IsNullOrEmpty(([string]$sessionLines[4]).Trim())) {
            $hostRec = ([string]$sessionLines[4]).Trim()
        }
        else {
            $hostRec = 'claude'
        }
    }
    catch {
        $hostRec = 'claude'
    }
    Add-NSFact "recorded host $hostRec"
    if (-not [string]::IsNullOrEmpty($sid)) {
        Add-NSFact 'session id is present (not printed)'
        if ($hostRec -eq 'codex') {
            $kind = Get-NSCodexIdentityKind $sid
            Add-NSFact "Codex identity kind $kind"
            if ($kind -ne 'resumable') {
                Add-NSWarn "recorded Codex identity is $kind - watchman must not claim it resumed that thread"
                Add-NSAct blocked 'capture a resumable Codex session id before relying on overnight revival'
            }
        }
    }
    else {
        Add-NSWarn 'session id line is empty'
        Add-NSAct confirm 'let the next tool call record identity, or accept a fresh-session fallback'
    }
    if ($spid -match '^[0-9]+$') {
        $liveness = Test-NSRecordedProcess $spid $sstart
        if ($liveness -eq 'Alive') {
            Add-NSFact "recorded pid $spid is alive"
        }
        elseif ($liveness -eq 'Dead') {
            Add-NSFact "recorded pid $spid is dead"
        }
    }
}
else {
    Add-NSFact 'no .shift-session yet'
    if ($armed -eq 1 -and $open -gt 0) {
        Add-NSWarn 'armed shift has no session record - a 500 can land before first work'
    }
}

$leaseState = 'absent'
$leaseGeneration = ''
$leasePath = Join-Path $ns '.shift-lease'
if (Test-NSPathEntry $leasePath) {
    $lease = Read-NSLease $ns
    if ($null -ne $lease) {
        $leaseState = 'valid'
        $leaseGeneration = [string]$lease.Generation
        Add-NSFact "process lease host $($lease.HostName) generation $leaseGeneration"
        if (-not [string]::IsNullOrEmpty([string]$lease.Nonce)) {
            Add-NSFact 'process lease belongs to a watchman recovery (capability not printed)'
        }
        else {
            Add-NSFact 'process lease belongs to the interactive shift process'
        }
        if ($hostRec -ne 'none' -and [string]$lease.HostName -ne $hostRec) {
            Add-NSWarn "process lease host $($lease.HostName) disagrees with recorded session host $hostRec"
            Add-NSAct blocked "run $(Join-Path $here 'stop-shift.ps1') -Project $hostPath, then Start again; do not rewrite the lease by hand"
        }
        if (-not [string]::IsNullOrEmpty([string]$lease.ProcessId)) {
            $holder = Test-NSRecordedProcess ([string]$lease.ProcessId) ([string]$lease.Start)
            if ($holder -eq 'Alive') {
                Add-NSFact "lease holder pid $($lease.ProcessId) is alive"
            }
            else {
                Add-NSFact "lease holder pid $($lease.ProcessId) is not confirmed alive"
            }
        }
        $rcodeEarly = Get-NSReasonCode $ns
        $noncePresent = -not [string]::IsNullOrEmpty([string]$lease.Nonce)
        $holderAlive = -not [string]::IsNullOrEmpty([string]$lease.ProcessId) `
            -and ((Test-NSRecordedProcess ([string]$lease.ProcessId) ([string]$lease.Start)) -eq 'Alive')
        $holderDead = -not [string]::IsNullOrEmpty([string]$lease.ProcessId) `
            -and ((Test-NSRecordedProcess ([string]$lease.ProcessId) ([string]$lease.Start)) -eq 'Dead')
        if ($rcodeEarly -eq 'clock-out-failed') {
            Add-NSWarn 'terminal clock-out failed without releasing the shift'
            if ($noncePresent) {
                if ($holderAlive) {
                    Add-NSFact 'recovery worker is alive; the recorded conversation cannot reclaim yet'
                    Add-NSAct confirm "wait until the recovery worker exits, or run $(Join-Path $here 'stop-shift.ps1') -Project $hostPath; reopening the recorded conversation stays blocked while that worker holds the lease"
                }
                else {
                    Add-NSFact "recovery worker is not confirmed alive after a failed clock-out; run $(Join-Path $here 'stop-shift.ps1') -Project $hostPath, then Start"
                }
            }
            else {
                Add-NSFact 'process lease restored to the interactive shift; the recorded conversation can operate'
                Add-NSAct confirm "reopen the recorded conversation to continue or run $(Join-Path $here 'stop-shift.ps1') -Project $hostPath; Start re-arms after Stop"
            }
        }
        elseif ($noncePresent -and $holderAlive) {
            Add-NSFact 'recovery worker is alive; the recorded conversation cannot reclaim yet'
            Add-NSAct confirm "wait until the recovery worker exits, or run $(Join-Path $here 'stop-shift.ps1') -Project $hostPath; reopening the recorded conversation stays blocked while that worker holds the lease"
        }
        elseif ($noncePresent -and $holderDead -and -not [string]::IsNullOrEmpty($sid)) {
            Add-NSFact "lease held by a dead recovery attempt (generation $leaseGeneration, pid $($lease.ProcessId)); the recorded conversation reclaims it on its next tool call"
        }
    }
    else {
        $leaseState = 'malformed'
        Add-NSWarn 'process lease is malformed - ownership cannot be proven'
        Add-NSAct blocked "run $(Join-Path $here 'stop-shift.ps1') -Project $hostPath, then Start again; never guess or edit .shift-lease"
    }
}
elseif ($armed -eq 1 -and -not [string]::IsNullOrEmpty($sid)) {
    Add-NSWarn "armed shift has no process lease - the bound session's next tool call must bootstrap it"
}

$wpid = ''
$wstart = ''
$watchmanUnusable = $false
$watchmanPath = Join-Path $ns '.watchman'
if (Test-NSReparsePoint $watchmanPath) {
    Add-NSWarn 'watchman pidfile path is not a usable file'
    $watchmanUnusable = $true
}
elseif (Test-Path -LiteralPath $watchmanPath -PathType Leaf) {
    try {
        $watchLines = [IO.File]::ReadAllLines($watchmanPath)
        $wpid = if ($watchLines.Count -gt 0) { ([string]$watchLines[0] -replace '\s', '') } else { '' }
        $wstart = if ($watchLines.Count -gt 1) { [string]$watchLines[1] } else { '' }
    }
    catch {
        $wpid = ''
        $wstart = ''
    }
}
if ($wpid -match '^[0-9]+$') {
    $watchLive = Test-NSRecordedProcess $wpid $wstart
    if ($watchLive -eq 'Alive') {
        Add-NSFact "watchman pid $wpid is alive"
    }
    else {
        Add-NSFact "watchman pid $wpid is stale"
        if ($armed -eq 0) {
            Add-NSAct safe 'remove leftover .watchman - the recorded process is gone and no shift is armed'
        }
        else {
            Add-NSAct confirm 're-run start so the host watchman is armed; do not launch a second copy by hand beside a living one'
        }
    }
}
else {
    if (-not $watchmanUnusable) {
        Add-NSFact 'no live watchman pid file'
    }
}

$rcode = Get-NSReasonCode $ns
if (-not [string]::IsNullOrEmpty($rcode)) {
    Add-NSFact "watchman reason $rcode ($(Get-NSReasonLabel $rcode))"
}

if ($armed -eq 1 -and $open -gt 0 -and [string]::IsNullOrEmpty($wpid) -and -not $watchmanUnusable) {
    Add-NSWarn 'shift is armed with open boxes and no watchman'
    Add-NSAct confirm 're-run start so the host watchman is armed, or work the list in the live session'
}

if (-not [string]::IsNullOrEmpty($tpath) -and -not (Test-Path -LiteralPath $tpath -PathType Leaf)) {
    Add-NSWarn 'recorded transcript/rollout path is not a readable file'
}

Add-NSAct confirm "export a local support bundle with $(Join-Path $here 'export-support.ps1') - written under $(Join-Path $ns 'support'), never uploaded"
Add-NSAct blocked 'Doctor never repairs, arms, stops, revives, or deletes'

Write-NSDoctorReport -NightshiftLabel 'present' -Target $target -HostRec $hostRec `
    -LeaseState $leaseState -LeaseGeneration $leaseGeneration `
    -Armed $armed -Open $open -Ticked $ticked -Stop $stop -Ended $ended
exit 0
