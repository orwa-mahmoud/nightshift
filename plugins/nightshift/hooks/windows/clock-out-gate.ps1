param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('claude', 'codex')]
    [string]$HostName,
    [Parameter(ValueFromPipeline = $true)]
    [AllowEmptyString()]
    [string]$HookJson = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if (Test-Path Variable:PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $false
}
$utf8 = New-Object Text.UTF8Encoding($false)

$pluginRoot = Resolve-Path (Join-Path $PSScriptRoot '../..')
Import-Module (Join-Path $pluginRoot 'lib/Nightshift.psm1') -Force -DisableNameChecking

# The reason a block carries: the whole contract, or one line when the gate positively knows
# nothing has moved. The decision is the shared one; only the shape around it is this host's.
function Get-NSGateBlockReason {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Full)
    # A contract that moved is answered in full, before any question of shortening arises: the
    # whole point of the short line is that the model already holds the contract, and here it
    # may not.
    $moved = ''
    try { $moved = Get-NSGateContractMismatch $workspace $punch } catch { $moved = '' }
    if (-not [string]::IsNullOrEmpty($moved)) { return $moved }
    $item = ''
    try { $item = Get-NSGateOpenItem $punch } catch { $item = '' }
    $stopped = if (Test-Path -LiteralPath $stop) { 'yes' } else { 'no' }
    $deadline = if (Test-NSDeadlinePassed) { 'passed' } else { 'pending' }
    $fp = Get-NSGateReminderFingerprint $counts.Open $counts.Ticked $item $stopped $deadline `
        (Get-NSGateStallState $stall $stallWarn)
    return (Get-NSGateReminderText -Workspace $workspace -Full $Full -Open $counts.Open `
            -Ticked $counts.Ticked -Item $item -Fingerprint $fp)
}

# Get-NSGateOpenItem <punch-list> - the id of the first still-open item, for the short line.
function Get-NSGateOpenItem {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    $inItems = $false
    foreach ($line in [IO.File]::ReadLines($Path)) {
        if ($line -cmatch '^##[ \t]*Items[ \t]*$') { $inItems = $true; continue }
        if (-not $inItems) { continue }
        if ($line -cmatch '^- \[ \][ \t]*\*\*(.+?)[ \t]*[\u2014-]') { return $Matches[1].Trim() }
    }
    return ''
}

function Write-Block {
    param([Parameter(Mandatory = $true)][string]$Reason)
    if ((Test-Path Variable:workspace) -and -not [string]::IsNullOrEmpty($workspace)) {
        $Reason = Expand-NSInjectedPaths $workspace $Reason
    }
    [Console]::Out.WriteLine((@{ decision = 'block'; reason = $Reason } | ConvertTo-Json -Compress))
    exit 0
}

function Write-Release {
    if ($HostName -eq 'codex') {
        [Console]::Out.WriteLine('{"continue":true}')
    }
    exit 0
}

function Get-PropertyValue {
    param(
        [AllowNull()][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowNull()][object]$Default = ''
    )
    if ($null -eq $Object) {
        return $Default
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) {
        return $Default
    }
    return $property.Value
}

function Write-NSLogLine {
    param([Parameter(Mandatory = $true)][string]$Message)
    if (Test-Path -LiteralPath $ns -PathType Container) {
        $line = '{0} - {1}{2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message, [Environment]::NewLine
        [IO.File]::AppendAllText($log, $line, $utf8)
    }
}

function Release-NSLeaseWithRetry {
    if (Release-NSLease $ns) {
        return
    }
    Start-Sleep -Milliseconds 200
    if (-not (Release-NSLease $ns)) {
        Write-NSLogLine 'process lease release deferred: lease mutex remained busy'
    }
}

function Save-NSPolicyArchive {
    # Best effort, never blocks the release: file tonight's shift-policy.json under
    # archive/<YYYY-MM-DD>/shift-policy-<shiftId>.json via the same helper the owner runs by
    # hand. A shift that armed with safe defaults and never wrote a policy leaves nothing to
    # archive. Invoke-NSShiftPolicyArchive writes its result straight to the console, which this
    # hook's stdout must carry nothing but the release/block JSON, so the console is swapped for
    # a throwaway writer for the length of the call.
    $policyPath = Join-Path $ns 'shift-policy.json'
    if (-not (Test-Path -LiteralPath $policyPath -PathType Leaf) -or (Test-NSReparsePoint $policyPath)) {
        return
    }
    $originalOut = [Console]::Out
    $originalErr = [Console]::Error
    $swallow = New-Object IO.StringWriter
    try {
        [Console]::SetOut($swallow)
        [Console]::SetError($swallow)
        $null = Invoke-NSShiftPolicyArchive -Workspace $workspace -Date (Get-Date -Format 'yyyy-MM-dd')
    }
    catch {
    }
    finally {
        [Console]::SetOut($originalOut)
        [Console]::SetError($originalErr)
    }
}

function Save-NSEvidenceArchive {
    $originalOut = [Console]::Out
    $originalErr = [Console]::Error
    $swallow = New-Object IO.StringWriter
    try {
        [Console]::SetOut($swallow)
        [Console]::SetError($swallow)
        $shiftId = 'unknown'
        $state = Get-NSShiftPolicyState $workspace
        if ($state['state'] -ceq 'valid') { $shiftId = [string]$state['policy']['shiftId'] }
        $null = Invoke-NSEvidenceArchive -Workspace $workspace -ShiftId $shiftId
    }
    catch {
    }
    finally {
        [Console]::SetOut($originalOut)
        [Console]::SetError($originalErr)
    }
}

function Save-NSMorningReceipt {
    # Best effort, never blocks the release: render the owner view to
    # receipts/morning-<YYYY-MM-DD>-<shiftId>.md. Runs before both archives, so the policy that
    # ran is still in place for section 1 and the findings ledger still holds the night's
    # evidence, and before the receipts commit so a workspace with a receipts git carries the
    # receipt in the same commit. A render failure leaves no file, no message on this hook's
    # stdout, and no effect on the clock-out; both archives still run.
    $originalOut = [Console]::Out
    $originalErr = [Console]::Error
    $swallow = New-Object IO.StringWriter
    try {
        [Console]::SetOut($swallow)
        [Console]::SetError($swallow)
        if (Test-NSHandoffEnabled $workspace) {
            $null = Write-NSMorningReceiptFile -Workspace $workspace
        }
    }
    catch {
    }
    finally {
        [Console]::SetOut($originalOut)
        [Console]::SetError($originalErr)
    }
}

function Save-NSReceipt {
    param([Parameter(Mandatory = $true)][string]$Summary)
    if (-not (Test-Path -LiteralPath (Join-Path $ns '.git') -PathType Container)) {
        return
    }
    # Owner opt-in. Default off — a receipts git alone does not authorize headless commits.
    $auto = Get-NSRule $workspace 'receiptsAutoCommit' ([string]$env:NIGHTSHIFT_RECEIPTS_AUTO_COMMIT)
    switch -Regex ($auto) {
        '^(?i:true|1|yes)$' { }
        default { return }
    }
    try {
        $null = Invoke-NSGitCommand $ns @('add', '-A')
        $committed = Invoke-NSGitCommand $ns @(
            '-c', 'user.name=nightshift',
            '-c', 'user.email=nightshift@localhost',
            '-c', 'commit.gpgsign=false',
            'commit', '-q', '-m', $Summary
        )
        if ($committed.ExitCode -ne 0 -and $committed.Text -notmatch 'nothing to commit|nothing added') {
            Write-NSLogLine ('receipts commit failed: ' + (($committed.Text -split "`r?`n")[0]))
        }
    }
    catch {
        Write-NSLogLine ('receipts commit failed: ' + $_.Exception.Message)
    }
}

function Invoke-NSWhistle {
    param([Parameter(Mandatory = $true)][string]$Summary)
    if ([string]::IsNullOrEmpty($notify)) {
        return
    }
    if (Test-NSReparsePoint $notified) {
        Remove-Item -LiteralPath $notified -Force -ErrorAction SilentlyContinue
    }
    $stream = $null
    try {
        $stream = [IO.File]::Open($notified, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $stream.Dispose()
        $stream = $null
    }
    catch {
        if ($null -ne $stream) {
            $stream.Dispose()
        }
        return
    }
    $oldSummary = $env:NIGHTSHIFT_SUMMARY
    try {
        $env:NIGHTSHIFT_SUMMARY = $Summary
        $null = Invoke-Expression $notify 2>$null
    }
    catch {
    }
    finally {
        $env:NIGHTSHIFT_SUMMARY = $oldSummary
    }
}

# Every ending runs through here. The shift is over by now, so asking the model to file is a
# request it can carry out, and that request is the one hold left in a finished shift. Asking is
# recorded, so the next stop releases either way.
function Complete-NSShiftAndStop {
    param([Parameter(Mandatory = $true)][string]$Summary)
    Complete-NSShift $Summary
    Complete-NSShiftHold
    Write-Release
}

# The one hold left in a finished shift: the owner asked for filing, so the model is given its
# turn before the session terminates. Asking is recorded, so the next stop releases either way.
function Complete-NSShiftHold {
    $pending = Join-Path $ns '.pending-filing'
    if ((Test-Path -LiteralPath (Join-Path $ns '.ended') -PathType Leaf) -and
        -not (Test-Path -LiteralPath $armed) -and
        (Test-Path -LiteralPath $pending -PathType Leaf) -and
        -not (Test-NSReparsePoint $pending) -and
        -not (@([IO.File]::ReadAllLines($pending)) -ccontains 'asked=1')) {
        [IO.File]::AppendAllText($pending, "asked=1`n", $utf8)
        Write-NSLogLine 'archive.automatic is on - holding once so this shift can be filed before the session ends'
        Write-Block 'DO NOT STOP YET - this shift has ended and archive.automatic is on, so file it before the session terminates. Run Archive now: decide from the punch list and the records which belong to work that is finished with, file those, and delete .nightshift/.pending-filing when it is done. Stopping again releases the session whether or not filing succeeded, and an unfiled marker is picked up by the next explicit Archive.'
    }
}

function Complete-NSShift {
    param([Parameter(Mandatory = $true)][string]$Summary)
    if (Test-Path -LiteralPath $ns -PathType Container) {
        if (Test-NSReparsePoint $ended) {
            Remove-Item -LiteralPath $ended -Force -ErrorAction SilentlyContinue
        }
        [IO.File]::WriteAllText($ended, '', $utf8)
    }
    Remove-Item -LiteralPath $armed -Force -ErrorAction SilentlyContinue
    Release-NSLeaseWithRetry
    Save-NSMorningReceipt
    # The marker that says this shift ended also says which shift, and where it files. Archiving
    # the policy below takes both away from any later Archive, and one shift's records must not
    # end up half under its own name and half under a date.
    $endedId = 'unknown'
    $endedState = Get-NSShiftPolicyState $workspace
    if ($endedState['state'] -ceq 'valid') { $endedId = [string]$endedState['policy']['shiftId'] }
    Write-NSEndedRecord -StateDir $ns -ShiftId $endedId `
        -ArchiveRoot ([string](Get-NSPolicyGroupSetting $workspace 'archive.root')['value']) `
        -ArchiveLayout ([string](Get-NSPolicyGroupSetting $workspace 'archive.layout')['value'])
    if (Test-NSArchiveAutomatic $workspace) {
        $pending = Join-Path $ns '.pending-filing'
        if (Test-NSReparsePoint $pending) { Remove-Item -LiteralPath $pending -Force -ErrorAction SilentlyContinue }
        [IO.File]::WriteAllText($pending,
            ('date=' + (Get-Date -Format 'yyyy-MM-dd') + "`nshiftId=$endedId`n"), $utf8)
        Write-NSLogLine 'archive.automatic is on - filing is due for this shift'
    }
    Save-NSPolicyArchive
    Save-NSEvidenceArchive
    Save-NSReceipt $Summary
    # An owner who asked for filing at clock-out gets a note that filing is due, not a hook that
    # files. Deciding which records are closed reads the punch list and the work; a stop hook is
    # the wrong place for that judgement and no session is spawned to make it.
    Invoke-NSWhistle $Summary
}

# shift-policy.json is authoritative for the deadline; the deadline file is a derived
# projection. Honours the earlier of the two when both are readable and disagree, logging one
# line naming both - a malformed or absent side just falls back to the other.
function Test-NSDeadlinePassed {
    $fileTarget = $null
    if ((Test-Path -LiteralPath $deadline -PathType Leaf) -and -not (Test-NSReparsePoint $deadline)) {
        try {
            $rawDeadline = ([IO.File]::ReadAllText($deadline)).Trim()
            if ($rawDeadline -match '^[0-9]+$') {
                $fileTarget = [long]$rawDeadline
            }
            else {
                $parsed = [DateTimeOffset]::Parse(
                    $rawDeadline,
                    [Globalization.CultureInfo]::InvariantCulture,
                    [Globalization.DateTimeStyles]::AssumeLocal
                )
                $fileTarget = $parsed.ToUnixTimeSeconds()
            }
        }
        catch {
            $fileTarget = $null
        }
    }
    $policyTarget = $null
    try {
        $resolution = Get-NSPolicyResolution $workspace
        if ($null -ne $resolution['deadlinePolicy']) {
            $policyTarget = [long]$resolution['deadlinePolicy']
        }
    }
    catch {
        $policyTarget = $null
    }
    $target = $fileTarget
    if ($null -ne $policyTarget) {
        if ($null -eq $target) {
            $target = $policyTarget
        }
        elseif ($policyTarget -ne $target) {
            Write-NSLogLine "deadline mismatch - deadline file $target does not match shift-policy deadlineEpoch $policyTarget; honoring the earlier value"
            if ($policyTarget -lt $target) {
                $target = $policyTarget
            }
        }
    }
    if ($null -eq $target) {
        return $false
    }
    return (Get-NSUnixTime) -ge $target
}

$raw = Get-NSStdinText -Piped $HookJson
if ([string]::IsNullOrWhiteSpace($raw)) {
    $raw = Get-NSStdinText -Piped (($input | ForEach-Object { $_ }) -join "`n")
}
$payload = $null
if (-not [string]::IsNullOrWhiteSpace($raw)) {
    try {
        $payload = $raw | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        $payload = $null
    }
}
$sessionId = [string](Get-PropertyValue $payload 'session_id')
$transcript = [string](Get-PropertyValue $payload 'transcript_path')
$payloadCwd = [string](Get-PropertyValue $payload 'cwd' ([Environment]::CurrentDirectory))

if ($HostName -eq 'claude') {
    $hostRoot = if (-not [string]::IsNullOrEmpty($env:CLAUDE_PROJECT_DIR)) { $env:CLAUDE_PROJECT_DIR } else { $payloadCwd }
}
else {
    $hostRoot = if (-not [string]::IsNullOrEmpty($env:CODEX_PROJECT_DIR)) { $env:CODEX_PROJECT_DIR } else { $payloadCwd }
}
if ([string]::IsNullOrEmpty($hostRoot)) {
    $hostRoot = [Environment]::CurrentDirectory
}

try {
    $workspace = Resolve-NSWorkspaceRoot $hostRoot
}
catch {
    Write-Block 'DO NOT STOP - .nightshift-link is invalid. Open the correct project task or repair the explicit link to an absolute workspace containing .nightshift/.'
}

$stateKind = Get-NSStateKind $workspace
if ($stateKind -in @('malformed', 'future')) {
    Write-Block ('DO NOT STOP - ' + (Get-NSStateRefuseMessage $stateKind))
}

$ns = Join-Path $workspace '.nightshift'
$punch = Join-Path $ns 'punch-list.md'
$stop = Join-Path $ns 'STOP'
$deadline = Join-Path $ns 'deadline'
$stall = Join-Path $ns '.stall'
$notified = Join-Path $ns '.notified'
$ended = Join-Path $ns '.ended'
$armed = Join-Path $ns '.shift-armed'
$log = Join-Path $ns 'shift-log.md'

if (-not (Test-Path -LiteralPath $armed -PathType Leaf)) {
    Write-Release
}

$counts = Get-NSBoxCounts $punch
$stallMaxRaw = Get-NSRule $workspace 'stallMax' ([string]$env:NIGHTSHIFT_STALL_MAX)
$stallWarnRaw = Get-NSRule $workspace 'stallWarnEvery' ([string]$env:NIGHTSHIFT_STALL_WARN)
$stallReady = $stallMaxRaw -match '^[0-9]+$' -and $stallWarnRaw -match '^[1-9][0-9]*$'
$stallMax = if ($stallReady) { [int]$stallMaxRaw } else { 0 }
$stallWarn = if ($stallReady) { [int]$stallWarnRaw } else { 0 }
$notify = Get-NSRule $workspace 'notifyCommand' ([string]$env:NIGHTSHIFT_NOTIFY_CMD)
$gateMessage = Get-NSRule $workspace 'clockOutMessage' ([string]$env:NIGHTSHIFT_GATE_MESSAGE)

# STOP is an owner capability. Process ownership must never make emergency stop unusable.
if (Test-Path -LiteralPath $stop -PathType Leaf) {
    $mutex = Enter-NSMutex $ns '.lock.d'
    try {
        $reason = ''
        try {
            $reason = (([IO.File]::ReadLines($stop) | Select-Object -First 1) -as [string]).Trim()
        }
        catch {
        }
        $suffix = if ([string]::IsNullOrEmpty($reason)) { '' } else { " ($reason)" }
        Complete-NSShift ("shift ended${suffix}: $($counts.Ticked)/$($counts.Total) done")
    }
    finally {
        if ($null -ne $mutex) {
            Exit-NSMutex $mutex
        }
    }
    # The mutex is released first: the hold below may end the session, and holding a site mutex
    # across that would leave the next stop waiting on a process that is gone.
    Complete-NSShiftHold
    Write-Release
}

# Cursor IDE also runs this Claude gate; leave Cursor's gate as the only clock-out owner.
if ($HostName -eq 'claude' -and (Test-NSClaudeForeignCursorSurface -NightshiftDir $ns -Transcript $transcript)) {
    Write-Release
}

if ($null -eq $payload) {
    Write-Block 'DO NOT STOP - the hook payload is unreadable while a shift is active. Retry after the host can provide valid hook JSON.'
}

$nonce = [string]$env:NIGHTSHIFT_LEASE_NONCE
$generation = [string]$env:NIGHTSHIFT_LEASE_GENERATION
$revival = $env:NIGHTSHIFT_REVIVAL -eq '1'

$unbound = Resolve-NSShiftUnbound -NightshiftDir $ns -HostName $HostName `
    -Nonce $nonce -Generation $generation -Revival $revival -Mode gate
if ($unbound.Status -eq 'Pass') { Write-Release }
if ($unbound.Status -eq 'Fail') { Write-Block $unbound.Message }

$hostProcess = Get-NSHostProcess $HostName
$processId = if ($null -eq $hostProcess) { '' } else { [string]$hostProcess.Id }
$processStart = if ($null -eq $hostProcess) { '' } else { [string]$hostProcess.Start }

$session = Read-NSSession $ns
if ($null -eq $session -and -not [string]::IsNullOrEmpty($sessionId)) {
    $null = Claim-NSSession $ns $sessionId $transcript $processId $processStart $HostName
}

$owned = Resolve-NSShiftOwnership -NightshiftDir $ns -HostName $HostName `
    -SessionId $sessionId -Transcript $transcript -ProcessId $processId `
    -ProcessStart $processStart -Nonce $nonce -Generation $generation `
    -Revival $revival -Mode gate
if ($owned.Status -eq 'Pass') { Write-Release }
if ($owned.Status -eq 'Fail') { Write-Block $owned.Message }
$session = $owned.Session

$mutex = Enter-NSMutex $ns '.lock.d'
# An unlockable site is decided unlocked: the gate must answer, never queue.
try {
    # What the shift has cost so far, closed off item by item. The gate sees ticked boxes rather
    # than ticks, so it catches the marks up to them. It runs here, once this session has been shown
    # to own the shift and holds the site's lock: a stop from a second conversation on the same
    # workspace must leave the ledger exactly as it found it.
    if ($counts.Readable) {
        try { $null = Invoke-NSGateUsageSync $ns $workspace $punch $counts.Ticked }
        catch { Write-NSLogLine "usage accounting skipped - $($_.Exception.Message)" }
    }
    if (Test-Path -LiteralPath $stop -PathType Leaf) {
        $reason = ''
        try {
            $reason = (([IO.File]::ReadLines($stop) | Select-Object -First 1) -as [string]).Trim()
        }
        catch {
        }
        $suffix = if ([string]::IsNullOrEmpty($reason)) { '' } else { " ($reason)" }
        Complete-NSShiftAndStop ("shift ended${suffix}: $($counts.Ticked)/$($counts.Total) done")
    }

    if ($counts.Readable) {
        if (-not (Test-Path -LiteralPath $punch -PathType Leaf)) {
            Complete-NSShiftAndStop "shift done: $($counts.Ticked)/$($counts.Total)"
        }
        if ($counts.Open -eq 0) {
            Complete-NSShiftAndStop "shift done: $($counts.Ticked)/$($counts.Total)"
        }
    }
    if (Test-NSDeadlinePassed) {
        Write-NSLogLine "quitting time - shift ended, $($counts.Ticked)/$($counts.Total) done, items left open"
        [IO.File]::WriteAllText($stop, "deadline$([Environment]::NewLine)", $utf8)
        Complete-NSShiftAndStop "quitting time: $($counts.Ticked)/$($counts.Total) done, items left open"
    }

    if ($stallReady) {
        $fingerprint = "$($counts.Ticked):$(Get-NSProgressToken $workspace)"
        $previousFingerprint = ''
        $previousAttempts = 0
        if ((Test-Path -LiteralPath $stall -PathType Leaf) -and -not (Test-NSReparsePoint $stall)) {
            try {
                $lines = [IO.File]::ReadAllLines($stall)
                if ($lines.Count -gt 0) {
                    $previousFingerprint = $lines[0]
                }
                if ($lines.Count -gt 1 -and $lines[1] -match '^[0-9]+$') {
                    $previousAttempts = [int]$lines[1]
                }
            }
            catch {
            }
        }
        $attempts = if ($previousFingerprint -eq $fingerprint) { $previousAttempts + 1 } else { 1 }
        if ($stallMax -gt 0 -and $attempts -ge $stallMax) {
            Write-NSLogLine "stalled - auto-ended, $attempts attempts no progress, $($counts.Ticked)/$($counts.Total) done, items left open"
            [IO.File]::WriteAllText($stop, "stalled$([Environment]::NewLine)", $utf8)
            Complete-NSShiftAndStop "stalled: $($counts.Ticked)/$($counts.Total) done, $attempts attempts no progress"
        }
        if ($stallMax -eq 0 -and $attempts -ge $stallWarn) {
            Write-NSLogLine "stall warning - $attempts attempts no progress, $($counts.Ticked)/$($counts.Total) done; keeping shift open"
            $attempts = 0
        }
        if (Test-NSReparsePoint $stall) {
            Remove-Item -LiteralPath $stall -Force -ErrorAction SilentlyContinue
        }
        $null = Write-NSAtomicLines -Path $stall -Lines @($fingerprint, [string]$attempts)
    }
    else {
        Write-NSLogLine 'stall guard down - stallMax/stallWarnEvery unreadable (.nightshift/rules.json absent or incomplete); run Setup again (/nightshift:setup on Claude Code; ask Nightshift to set up on Codex)'
    }
}
finally {
    if ($null -ne $mutex) {
        Exit-NSMutex $mutex
    }
}

if (-not [string]::IsNullOrEmpty($gateMessage)) {
    Write-Block (Get-NSGateBlockReason $gateMessage)
}
Write-Block (Get-NSGateBlockReason 'DO NOT STOP - the punch list (.nightshift/punch-list.md) still has open items. Work them one at a time per its contract, run each item''s gate, and tick only after completion; park owner decisions in .nightshift/parking-lot.md and keep working. (nightshift: the full contract reinjection lives in .nightshift/rules.json clockOutMessage - unreadable here; run Setup again: /nightshift:setup on Claude Code, or ask Nightshift to set up on Codex.)')
