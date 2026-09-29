function New-NSShiftDecision {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Continue', 'Pass', 'Fail')][string]$Status,
        [AllowEmptyString()][string]$Message = '',
        $Session = $null
    )
    return [pscustomobject]@{
        Status  = $Status
        Message = $Message
        Session = $Session
    }
}

function Resolve-NSShiftUnbound {
    param(
        [Parameter(Mandatory = $true)][string]$NightshiftDir,
        [Parameter(Mandatory = $true)][ValidateSet('claude', 'codex', 'cursor')][string]$HostName,
        [AllowEmptyString()][string]$Nonce = '',
        [AllowEmptyString()][string]$Generation = '',
        [bool]$Revival = $false,
        [Parameter(Mandatory = $true)][ValidateSet('hardhat', 'gate')][string]$Mode,
        [AllowEmptyString()][string]$SessionId = '',
        [bool]$BindingProbe = $false
    )
    $session = Read-NSSession $NightshiftDir
    if ($null -ne $session) {
        return New-NSShiftDecision -Status Continue -Session $session
    }
    $lease = Read-NSLease $NightshiftDir
    if ($null -ne $lease -and -not [string]::IsNullOrEmpty($lease.Nonce)) {
        if (-not $Revival -or -not (Test-NSLeaseNonce $NightshiftDir $HostName $Nonce $Generation)) {
            if ($Mode -eq 'hardhat') {
                return New-NSShiftDecision -Status Fail -Message 'BLOCKED: this shift is being recovered before its new conversation is bound. Reopen the recorded conversation and retry after recovery.'
            }
            return New-NSShiftDecision -Status Pass
        }
        return New-NSShiftDecision -Status Continue -Session $session
    }
    # No conversation is recorded. Start's binding probe writes that record right after arming, so a
    # Stop or a tool call from any other conversation is not the shift's: a Start interrupted before
    # its probe, or a stop-work order that dropped the record, leaves the site to no one. The
    # conversation the lease still names may record itself again, and rebind judges a revival child.
    # A payload that names no conversation cannot be told apart, so rebind and authorize judge it.
    if ([string]::IsNullOrEmpty($SessionId) -or $BindingProbe -or $Revival) {
        return New-NSShiftDecision -Status Continue -Session $session
    }
    if ($null -ne $lease -and -not [string]::IsNullOrEmpty($lease.SessionId) -and $lease.SessionId -eq $SessionId) {
        return New-NSShiftDecision -Status Continue -Session $session
    }
    return New-NSShiftDecision -Status Pass
}

function Resolve-NSShiftRebind {
    param(
        [Parameter(Mandatory = $true)][string]$NightshiftDir,
        [Parameter(Mandatory = $true)][ValidateSet('claude', 'codex', 'cursor')][string]$HostName,
        [AllowEmptyString()][string]$SessionId = '',
        [AllowEmptyString()][string]$Transcript = '',
        [AllowEmptyString()][string]$ProcessId = '',
        [AllowEmptyString()][string]$ProcessStart = '',
        [AllowEmptyString()][string]$Nonce = '',
        [AllowEmptyString()][string]$Generation = '',
        [bool]$Revival = $false,
        [Parameter(Mandatory = $true)][ValidateSet('hardhat', 'gate')][string]$Mode
    )
    $session = Read-NSSession $NightshiftDir
    if (-not $Revival) {
        return New-NSShiftDecision -Status Continue -Session $session
    }
    if (-not (Test-NSLeaseNonce $NightshiftDir $HostName $Nonce $Generation)) {
        if ($Mode -eq 'hardhat') {
            return New-NSShiftDecision -Status Fail -Message 'BLOCKED: this recovered worker no longer owns the shift. Reopen the recorded conversation instead of continuing an older process.'
        }
        return New-NSShiftDecision -Status Pass
    }
    if ([string]::IsNullOrEmpty($SessionId)) {
        return New-NSShiftDecision -Status Continue -Session $session
    }
    $lease = Read-NSLease $NightshiftDir
    if ($null -ne $lease -and [string]::IsNullOrEmpty($lease.SessionId) `
        -and -not (Bind-NSLeaseSession $NightshiftDir $SessionId $HostName $Nonce $Generation)) {
        if ($Mode -eq 'hardhat') {
            return New-NSShiftDecision -Status Fail -Message 'BLOCKED: the shift process lease could not bind the recovered conversation. Issue STOP from another session, then run Start again.'
        }
        return New-NSShiftDecision -Status Pass
    }
    if ($null -eq $session -or $session.SessionId -ne $SessionId -or $session.ProcessId -ne $ProcessId) {
        $oldTranscript = if ([string]::IsNullOrEmpty($Transcript) -and $null -ne $session) { $session.Transcript } else { $Transcript }
        if (-not (Write-NSSession $NightshiftDir $SessionId $oldTranscript $ProcessId $ProcessStart $HostName)) {
            if ($Mode -eq 'hardhat') {
                return New-NSShiftDecision -Status Fail -Message 'BLOCKED: the recovered conversation could not update .shift-session. Issue STOP from another session, then run Start again.'
            }
            return New-NSShiftDecision -Status Pass
        }
    }
    $lease = Read-NSLease $NightshiftDir
    if ($null -ne $lease -and -not [string]::IsNullOrEmpty($ProcessId) -and $lease.ProcessId -ne $ProcessId `
        -and -not (Attach-NSLeaseProcess $NightshiftDir $HostName $Nonce $Generation $ProcessId $ProcessStart)) {
        if ($Mode -eq 'hardhat') {
            return New-NSShiftDecision -Status Fail -Message 'BLOCKED: the recovered process could not refresh its shift lease. Reopen the recorded conversation.'
        }
        return New-NSShiftDecision -Status Pass
    }
    return New-NSShiftDecision -Status Continue -Session (Read-NSSession $NightshiftDir)
}

function Resolve-NSShiftAuthorize {
    param(
        [Parameter(Mandatory = $true)][string]$NightshiftDir,
        [Parameter(Mandatory = $true)][ValidateSet('claude', 'codex', 'cursor')][string]$HostName,
        [AllowEmptyString()][string]$SessionId = '',
        [AllowEmptyString()][string]$ProcessId = '',
        [AllowEmptyString()][string]$ProcessStart = '',
        [AllowEmptyString()][string]$Nonce = '',
        [AllowEmptyString()][string]$Generation = '',
        [bool]$Revival = $false,
        [Parameter(Mandatory = $true)][ValidateSet('hardhat', 'gate')][string]$Mode,
        $Session = $null
    )
    if ($null -eq $Session) {
        $Session = Read-NSSession $NightshiftDir
    }
    $lease = Read-NSLease $NightshiftDir
    $leaseScope = if ($null -eq $lease) { '' } else { $lease.SessionId }
    if ($null -ne $Session -and -not [string]::IsNullOrEmpty($SessionId) `
        -and $SessionId -ne $Session.SessionId -and $SessionId -ne $leaseScope -and -not $Revival) {
        return New-NSShiftDecision -Status Pass -Session $Session
    }
    if ($null -eq $Session) {
        return New-NSShiftDecision -Status Continue
    }
    $leasePath = Get-NSLayoutPath $NightshiftDir 'lease'
    if (-not (Test-NSPathEntry $leasePath) `
        -and -not (Claim-NSInitialLease $NightshiftDir $Session.SessionId $HostName $ProcessId $ProcessStart)) {
        if ($Mode -eq 'hardhat') {
            return New-NSShiftDecision -Status Fail -Session $Session -Message 'BLOCKED: the shift process lease could not be created. Issue STOP from another session, then run Start again.'
        }
        return New-NSShiftDecision -Status Fail -Session $Session -Message 'DO NOT STOP - the shift process lease is unreadable. Issue STOP from another session, then run Start again.'
    }
    elseif ($HostName -eq 'cursor') {
        $contaminated = Read-NSLease $NightshiftDir
        if ($null -ne $contaminated `
            -and $contaminated.HostName -eq 'claude' `
            -and $contaminated.SessionId -eq $Session.SessionId `
            -and [string]::IsNullOrEmpty($contaminated.Nonce) `
            -and [string]::IsNullOrEmpty($Nonce)) {
            if (-not (Write-NSLease $NightshiftDir $Session.SessionId 'cursor' 1 '' $ProcessId $ProcessStart)) {
                if ($Mode -eq 'hardhat') {
                    return New-NSShiftDecision -Status Fail -Session $Session -Message 'BLOCKED: the shift process lease could not be reclaimed for Cursor. Issue STOP from another session, then run Start again.'
                }
                return New-NSShiftDecision -Status Fail -Session $Session -Message 'DO NOT STOP - the shift process lease could not be reclaimed for Cursor. Issue STOP from another session, then run Start again.'
            }
        }
    }
    $checkSession = if ([string]::IsNullOrEmpty($SessionId)) { $Session.SessionId } else { $SessionId }
    $allow = Test-NSLeaseAllows $NightshiftDir $checkSession $HostName $ProcessId $ProcessStart $Nonce $Generation
    if ($allow -eq 'Deny') {
        if ($Mode -eq 'hardhat') {
            $held = Read-NSLease $NightshiftDir
            if ($null -ne $held -and -not [string]::IsNullOrEmpty($held.Nonce) `
                -and -not [string]::IsNullOrEmpty($held.ProcessId)) {
                $liveness = Test-NSRecordedProcess $held.ProcessId $held.Start
                if ($liveness -eq 'Alive') {
                    return New-NSShiftDecision -Status Fail -Session $Session -Message 'BLOCKED: this shift is being recovered in another process. Wait or issue STOP from a separate session; reopening the recorded conversation stays blocked while that worker holds the lease.'
                }
                if ($liveness -eq 'Dead' -and -not [string]::IsNullOrEmpty($checkSession) `
                    -and $checkSession -eq $Session.SessionId) {
                    $reclaimed = Reclaim-NSLeaseRecorded -NightshiftDir $NightshiftDir -HostName $HostName `
                        -SessionId $Session.SessionId -OldGeneration $held.Generation -OldNonce $held.Nonce `
                        -ProcessId $ProcessId -Start $ProcessStart
                    if ($null -ne $reclaimed) {
                        Write-NSControlLog -NightshiftDir $NightshiftDir -Line `
                            "lease reclaimed by the recorded conversation after a dead recovery attempt (generation $($held.Generation) $([char]0x2192) $reclaimed)"
                        $allow = 'Allow'
                    }
                }
            }
            if ($allow -ne 'Allow') {
                return New-NSShiftDecision -Status Fail -Session $Session -Message 'BLOCKED: this shift continued in a recovered process. Reopen the recorded conversation before using tools here.'
            }
        }
        else {
            return New-NSShiftDecision -Status Pass -Session $Session
        }
    }
    if ($allow -ne 'Allow') {
        if ($Mode -eq 'hardhat') {
            return New-NSShiftDecision -Status Fail -Session $Session -Message 'BLOCKED: this shift continued in a recovered process. Reopen the recorded conversation before using tools here.'
        }
        return New-NSShiftDecision -Status Fail -Session $Session -Message 'DO NOT STOP - the shift process lease is unreadable. Issue STOP from another session, then run Start again.'
    }
    if (-not $Revival -and -not [string]::IsNullOrEmpty($ProcessId)) {
        $lease = Read-NSLease $NightshiftDir
        if ($null -ne $lease -and $lease.ProcessId -eq $ProcessId -and $Session.ProcessId -ne $ProcessId) {
            if (-not (Write-NSSession $NightshiftDir $Session.SessionId $Session.Transcript $ProcessId $ProcessStart $HostName)) {
                if ($Mode -eq 'hardhat') {
                    return New-NSShiftDecision -Status Fail -Session $Session -Message 'BLOCKED: the reclaimed interactive process could not refresh .shift-session. Issue STOP from another session, then run Start again.'
                }
                return New-NSShiftDecision -Status Fail -Session $Session -Message 'DO NOT STOP - the reclaimed process could not refresh .shift-session. Issue STOP from another session, then run Start again.'
            }
            $Session = Read-NSSession $NightshiftDir
        }
    }
    return New-NSShiftDecision -Status Continue -Session $Session
}

function Resolve-NSShiftOwnership {
    param(
        [Parameter(Mandatory = $true)][string]$NightshiftDir,
        [Parameter(Mandatory = $true)][ValidateSet('claude', 'codex', 'cursor')][string]$HostName,
        [AllowEmptyString()][string]$SessionId = '',
        [AllowEmptyString()][string]$Transcript = '',
        [AllowEmptyString()][string]$ProcessId = '',
        [AllowEmptyString()][string]$ProcessStart = '',
        [AllowEmptyString()][string]$Nonce = '',
        [AllowEmptyString()][string]$Generation = '',
        [bool]$Revival = $false,
        [Parameter(Mandatory = $true)][ValidateSet('hardhat', 'gate')][string]$Mode
    )
    $rebind = Resolve-NSShiftRebind -NightshiftDir $NightshiftDir -HostName $HostName `
        -SessionId $SessionId -Transcript $Transcript -ProcessId $ProcessId `
        -ProcessStart $ProcessStart -Nonce $Nonce -Generation $Generation `
        -Revival $Revival -Mode $Mode
    if ($rebind.Status -ne 'Continue') {
        return $rebind
    }
    return Resolve-NSShiftAuthorize -NightshiftDir $NightshiftDir -HostName $HostName `
        -SessionId $SessionId -ProcessId $ProcessId -ProcessStart $ProcessStart `
        -Nonce $Nonce -Generation $Generation -Revival $Revival -Mode $Mode `
        -Session $rebind.Session
}

function Write-NSReason {
    param(
        [Parameter(Mandatory = $true)][string]$NightshiftDir,
        [Parameter(Mandatory = $true)][string]$Code,
        [AllowEmptyString()][string]$Detail = ''
    )
    $allowed = @(
        'completed', 'owner-stop', 'owner-disarm', 'stale-pid', 'invalid-session', 'exhausted-retry',
        'unknown-wedge', 'revived', 'stand-down', 'wrong-host', 'deadline',
        'clean-session-end', 'esc-standby', 'silent-standby', 'non-resumable-session',
        'unreadable-rules', 'fresh-fallback', 'unsupported-state', 'process-evidence-unavailable',
        'clock-out-failed', 'recovery-scope-unavailable', 'api-error', 'usage-limit'
    )
    if ($Code -notin $allowed) {
        $Code = 'stand-down'
    }
    $Detail = ($Detail -replace '[\x00-\x1f]', '').TrimEnd()
    $null = Write-NSAtomicLines -Path (Get-NSLayoutPath $NightshiftDir 'watch-reason') -Lines @($Code, $Detail)
}

function Get-NSUnixTime {
    return [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
}

function Get-NSPulseEpoch {
    param([Parameter(Mandatory = $true)][string]$NightshiftDir)
    $path = Get-NSLayoutPath $NightshiftDir 'pulse'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or (Test-NSReparsePoint $path)) {
        return $null
    }
    try {
        $line = ([IO.File]::ReadAllLines($path) | Select-Object -First 1)
    }
    catch {
        return $null
    }
    if ([string]::IsNullOrWhiteSpace($line)) {
        return $null
    }
    $epoch = ($line -split ' ', 2)[0]
    if ($epoch -notmatch '^[0-9]+$') {
        return $null
    }
    return [long]$epoch
}

function Test-NSPulseFresh {
    param(
        [Parameter(Mandatory = $true)][string]$NightshiftDir,
        [Parameter(Mandatory = $true)][int]$IntervalMinutes
    )
    $epoch = Get-NSPulseEpoch $NightshiftDir
    if ($null -eq $epoch) {
        return $false
    }
    $window = [long]$IntervalMinutes * 120
    return ((Get-NSUnixTime) - $epoch) -lt $window
}

function Test-NSPulseStale {
    param(
        [Parameter(Mandatory = $true)][string]$NightshiftDir,
        [Parameter(Mandatory = $true)][int]$IntervalMinutes,
        [long]$Clock = 0
    )
    $window = [long]$IntervalMinutes * 120
    $now = Get-NSUnixTime
    $epoch = Get-NSPulseEpoch $NightshiftDir
    if ($null -ne $epoch) {
        return ($now - $epoch) -ge $window
    }
    $armed = Get-NSLayoutPath $NightshiftDir 'armed'
    if ((Test-Path -LiteralPath $armed -PathType Leaf) -and -not (Test-NSReparsePoint $armed)) {
        try {
            $Clock = [DateTimeOffset]::new((Get-Item -LiteralPath $armed).LastWriteTimeUtc).ToUnixTimeSeconds()
        }
        catch {
        }
    }
    if ($Clock -le 0) {
        $Clock = $now
    }
    return ($now - $Clock) -ge $window
}

function Test-NSLeasePidLive {
    param([Parameter(Mandatory = $true)][string]$NightshiftDir)
    $lease = Read-NSLease $NightshiftDir
    if ($null -eq $lease -or [string]::IsNullOrEmpty([string]$lease.ProcessId)) {
        return $false
    }
    return (Test-NSRecordedProcess $lease.ProcessId $lease.Start) -eq 'Alive'
}

function Test-NSWatchmanRevivalProved {
    param(
        [Parameter(Mandatory = $true)][string]$NightshiftDir,
        [string]$Sentinel = '',
        [int]$IntervalMinutes = 0,
        [AllowEmptyString()]$OpenBefore = ''
    )
    $ended = Get-NSLayoutPath $NightshiftDir 'ended'
    if ((Test-Path -LiteralPath $ended -PathType Leaf) -and -not (Test-NSReparsePoint $ended)) {
        return $true
    }
    $punch = Get-NSLayoutPath $NightshiftDir 'punch-list'
    $nowOpen = $null
    try { $nowOpen = [int](Get-NSBoxCounts $punch).Open } catch { $nowOpen = $null }
    if ($OpenBefore -match '^[0-9]+$' -and $null -ne $nowOpen -and $nowOpen -lt [int]$OpenBefore) {
        return $true
    }
    if (Test-NSPulseFresh $NightshiftDir $IntervalMinutes) { return $true }
    return (Test-NSLeasePidLive $NightshiftDir)
}

function Test-NSHardhatActive {
    param([Parameter(Mandatory = $true)][string]$NightshiftDir)
    $ended = Get-NSLayoutPath $NightshiftDir 'ended'
    if ((Test-Path -LiteralPath $ended -PathType Leaf) -and -not (Test-NSReparsePoint $ended)) {
        return $false
    }
    $armed = Get-NSLayoutPath $NightshiftDir 'armed'
    if (-not (Test-Path -LiteralPath $armed -PathType Leaf)) {
        return $false
    }
    $punch = Get-NSLayoutPath $NightshiftDir 'punch-list'
    if (-not (Test-Path -LiteralPath $punch -PathType Leaf)) {
        return $false
    }
    $stop = Get-NSLayoutPath $NightshiftDir 'stop'
    if ((Test-Path -LiteralPath $stop -PathType Leaf) -and -not (Test-NSReparsePoint $stop)) {
        return $true
    }
    # A punch list that exists but will not count keeps the site armed: only a readable
    # list with every box ticked takes the hardhat off.
    $counts = Get-NSBoxCounts $punch
    if (-not $counts.Readable) {
        return $true
    }
    return [int]$counts.Open -gt 0
}

function New-NSHandoffFenceResult {
    param(
        [string]$Action = 'refuse',
        [bool]$Duplicate = $false,
        [bool]$Fenced = $false,
        [bool]$Active = $false,
        [bool]$Takeover = $false,
        [int]$ExitCode = 2
    )
    return [pscustomobject]@{
        schemaVersion = 1
        kind = 'handoff-fence'
        priorOwnerFenced = $Fenced
        priorWorkerActive = $Active
        duplicateWorkerRejected = $Duplicate
        takeoverAllowed = $Takeover
        action = $Action
        twoActiveWorkersAllowed = $false
        ExitCode = $ExitCode
    }
}

function Test-NSHandoffFence {
    param(
        [string]$Project = '',
        [string]$NightshiftDir = ''
    )
    $ns = $NightshiftDir
    if ([string]::IsNullOrWhiteSpace($ns) -and -not [string]::IsNullOrWhiteSpace($Project)) {
        try {
            $ctx = Resolve-NSControlWorkspace $Project
            $ns = $ctx.NightshiftDir
        }
        catch {
            return (New-NSHandoffFenceResult -ExitCode 2)
        }
    }
    if ([string]::IsNullOrWhiteSpace($ns) -or -not (Test-Path -LiteralPath $ns -PathType Container) `
        -or (Test-NSReparsePoint $ns)) {
        return (New-NSHandoffFenceResult -ExitCode 2)
    }

    $lease = Read-NSLease $ns
    if ($null -eq $lease) {
        return (New-NSHandoffFenceResult -ExitCode 2)
    }

    $priorFenced = $false
    $priorActive = $false
    $duplicate = $false
    $sessionPath = Get-NSLayoutPath $ns 'session'
    $session = $null
    if ((Test-NSPathEntry $sessionPath)) {
        if (Test-NSReparsePoint $sessionPath) {
            return (New-NSHandoffFenceResult -ExitCode 2)
        }
        $session = Read-NSSession $ns
        if ($null -eq $session) {
            return (New-NSHandoffFenceResult -ExitCode 2)
        }
    }

    if ([string]::IsNullOrEmpty([string]$lease.ProcessId)) {
        $priorFenced = $true
    }
    else {
        $leaseState = Test-NSRecordedProcess $lease.ProcessId $lease.Start
        switch ($leaseState) {
            'Alive' { $priorActive = $true }
            'Dead' { $priorFenced = $true }
            default { return (New-NSHandoffFenceResult -ExitCode 2) }
        }
    }

    if ($null -ne $session -and -not [string]::IsNullOrEmpty([string]$session.ProcessId)) {
        $sessionState = Test-NSRecordedProcess $session.ProcessId $session.Start
        switch ($sessionState) {
            'Alive' {
                if (-not [string]::IsNullOrEmpty([string]$lease.ProcessId) `
                    -and [string]$session.ProcessId -ne [string]$lease.ProcessId) {
                    $duplicate = $true
                }
                $priorActive = $true
                $priorFenced = $false
            }
            'Dead' { }
            default { return (New-NSHandoffFenceResult -ExitCode 2) }
        }
    }

    if ((-not $priorActive) -and (-not $duplicate) -and $priorFenced) {
        return (New-NSHandoffFenceResult -Action proceed -Duplicate $duplicate -Fenced $priorFenced `
            -Active $priorActive -Takeover $true -ExitCode 0)
    }
    return (New-NSHandoffFenceResult -Action refuse -Duplicate $duplicate -Fenced $priorFenced `
        -Active $priorActive -Takeover $false -ExitCode 1)
}


function Get-NSStateVersion {
    param([Parameter(Mandatory = $true)][string]$Workspace)
    $kind = Get-NSStateKind $Workspace
    switch ($kind) {
        'absent' { return '' }
        'legacy' {
            $marker = Get-NSLayoutPath (Join-Path $Workspace '.nightshift') 'state-version'
            if (-not (Test-Path -LiteralPath $marker -PathType Leaf)) { return '0' }
            return ([string]([IO.File]::ReadAllLines($marker) | Select-Object -First 1)).Trim()
        }
        'current' { return [string]$script:NSStateVersion }
        'future' {
            try {
                $raw = ([IO.File]::ReadAllLines((Get-NSLayoutPath (Join-Path $Workspace '.nightshift') 'state-version')) | Select-Object -First 1)
                return ([string]$raw).Trim()
            }
            catch {
                return ''
            }
        }
        default { return '' }
    }
}

# ---------------------------------------------------------------------------
# Moving a workspace's state into the current layout. Mirrors lib/migrate.sh, record for record.
#
# The layout table is the whole plan. Every file found at an earlier path of a key moves to that
# key's current path, whichever layout the workspace started in, so one routine serves a legacy
# workspace, a version-1 one, a move that was cut short and a folder somebody tidied by hand; a
# second run finds nothing to do. A later layout change adds rows to the table, never a step here.
#
# Get-NSMigrationPlan computes the plan and changes nothing; Invoke-NSMigrationApply performs it.
# Nothing is deleted or overwritten: a file moves only onto a path that is empty, a copy already
# there with the same bytes is left where it is, and a destination that holds anything else
# refuses the whole run by name. The state-version marker is written last, so a run that stops part
# way is finished by running it again.
#
# Callers: migrate-state, and Doctor and Setup to describe the move. Never a hook, Start, Status,
# Archive or recovery.
# ---------------------------------------------------------------------------

# Get-NSMigrationKeys - every key that names a file or directory, table order.
function Get-NSMigrationKeys {
    $keys = New-Object Collections.Generic.List[string]
    $seen = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($row in $script:NSLayoutRows) {
        if ($row.Kind -ceq 'field' -or $row.Kind -ceq 'retired' -or $row.Kind -ceq 'stray') { continue }
        if ($seen.Add($row.Key)) { $keys.Add($row.Key) }
    }
    return , $keys.ToArray()
}

# Get-NSMigrationRows <key> - every path <key> has had, oldest first.
function Get-NSMigrationRows {
    param([Parameter(Mandatory = $true)][string]$Key)
    $paths = New-Object Collections.Generic.List[string]
    foreach ($row in $script:NSLayoutRows) {
        if ($row.Key -ceq $Key) { $paths.Add($row.Path) }
    }
    return , $paths.ToArray()
}

# Get-NSMigrationFieldKeys <kind> - the field or retired keys, table order.
function Get-NSMigrationFieldKeys {
    param([Parameter(Mandatory = $true)][string]$Kind)
    $keys = New-Object Collections.Generic.List[string]
    $seen = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($row in $script:NSLayoutRows) {
        if ($row.Kind -cne $Kind) { continue }
        if ($seen.Add($row.Key)) { $keys.Add($row.Key) }
    }
    return , $keys.ToArray()
}

# Get-NSMigrationNative <state-dir> <rel> - the absolute path of a /-separated relative path.
function Get-NSMigrationNative {
    param(
        [Parameter(Mandatory = $true)][string]$NightshiftDir,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Relative
    )
    if ($Relative.Length -eq 0) { return $NightshiftDir }
    return (Join-NSPath $NightshiftDir ($Relative.Replace('/', [IO.Path]::DirectorySeparatorChar)))
}

# Test-NSMigrationFile <path> - a regular file, not a link.
function Test-NSMigrationFile {
    param([Parameter(Mandatory = $true)][string]$Path)
    return ((Test-Path -LiteralPath $Path -PathType Leaf) -and -not (Test-NSReparsePoint $Path))
}

# Get-NSMigrationParent <rel> - the directory part of a relative path, empty at the top.
function Get-NSMigrationParent {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Relative)
    $cut = $Relative.LastIndexOf('/')
    if ($cut -lt 0) { return '' }
    return $Relative.Substring(0, $cut)
}

# Get-NSMigrationChildren <path> - the names in a directory, ordinal order; none when unreadable.
function Get-NSMigrationChildren {
    param([Parameter(Mandatory = $true)][string]$Path)
    $names = New-Object Collections.Generic.List[string]
    try {
        foreach ($entry in [IO.Directory]::GetFileSystemEntries($Path)) {
            $names.Add([IO.Path]::GetFileName($entry))
        }
    }
    catch {
        return , @()
    }
    return , (Sort-NSOrdinal $names.ToArray())
}

# Test-NSMigrationDirectory <path> - a directory that is not a link, the kind a walk descends into.
function Test-NSMigrationDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)
    return ((Test-Path -LiteralPath $Path -PathType Container) -and -not (Test-NSReparsePoint $Path))
}

# Get-NSMigrationCarryMap - every earlier path of every key, mapped to its current one: where a
# link written against any layout lands once each file is in its current place.
function Get-NSMigrationCarryMap {
    $carry = New-NSMigrationMap
    foreach ($key in (Get-NSMigrationKeys)) {
        $cur = Get-NSLayoutRelativePathAt $script:NSLayoutVersion $key
        if ($cur.Length -eq 0 -or $cur.Contains('*')) { continue }
        foreach ($p in (Get-NSMigrationRows $key)) {
            if ($p.Length -gt 0 -and $p -cne $cur) { $carry[$p] = $cur }
        }
    }
    return , $carry
}

# Get-NSMigrationCanonical <state-dir> <rel> <carry> - a Markdown file with every relative link
# written as the state path it names, so a copy written from another directory reads the same.
function Get-NSMigrationCanonical {
    param(
        [Parameter(Mandatory = $true)][string]$NightshiftDir,
        [Parameter(Mandatory = $true)][string]$Relative,
        [Parameter(Mandatory = $true)]$Carry
    )
    $context = [pscustomobject]@{
        Mode = 'canon'
        Dir = Get-NSMigrationParent $Relative
        OldDirs = @()
        Present = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
        Carry = $Carry
        Root = $NightshiftDir
        Changes = New-Object Collections.Generic.List[string]
    }
    return ((Convert-NSMigrationLinks $context (Read-NSMigrationLines (Get-NSMigrationNative $NightshiftDir $Relative))) -join "`n")
}

# Get-NSMigrationVerdict <state-dir> <from> <to> <carry> - how one earlier path meets its current
# path: move, same (its content is already there, a Markdown file's links read from where each copy
# sits), empty (an empty directory is left behind), or conflict.
function Get-NSMigrationVerdict {
    param(
        [Parameter(Mandatory = $true)][string]$NightshiftDir,
        [Parameter(Mandatory = $true)][string]$From,
        [Parameter(Mandatory = $true)][string]$To,
        [Parameter(Mandatory = $true)]$Carry
    )
    $parent = Get-NSMigrationParent $To
    while ($parent.Length -gt 0) {
        $native = Get-NSMigrationNative $NightshiftDir $parent
        if ((Test-NSPathEntry $native) -and -not (Test-NSMigrationDirectory $native)) { return 'conflict' }
        $parent = Get-NSMigrationParent $parent
    }
    $src = Get-NSMigrationNative $NightshiftDir $From
    $dst = Get-NSMigrationNative $NightshiftDir $To
    if (-not (Test-NSPathEntry $dst)) { return 'move' }
    if ((Test-NSMigrationFile $src) -and (Test-NSMigrationFile $dst)) {
        $a = [IO.File]::ReadAllBytes($src)
        $b = [IO.File]::ReadAllBytes($dst)
        if ($a.Length -eq $b.Length) {
            $same = $true
            for ($j = 0; $j -lt $a.Length; $j++) {
                if ($a[$j] -ne $b[$j]) { $same = $false; break }
            }
            if ($same) { return 'same' }
        }
        if ($From.EndsWith('.md', [StringComparison]::Ordinal) -and $To.EndsWith('.md', [StringComparison]::Ordinal) -and
            (Get-NSMigrationCanonical $NightshiftDir $From $Carry) -ceq (Get-NSMigrationCanonical $NightshiftDir $To $Carry)) {
            return 'same'
        }
        return 'conflict'
    }
    if ((Test-NSMigrationDirectory $src) -and (Test-Path -LiteralPath $dst -PathType Container)) {
        try {
            if (@([IO.Directory]::GetFileSystemEntries($src)).Count -eq 0) { return 'empty' }
        }
        catch {
            return 'conflict'
        }
    }
    return 'conflict'
}

# Get-NSMigrationLiveFile <state-dir> <key> - where a file key sits right now, relative: its current
# path when that exists, else the first earlier one that does. Empty when neither does.
function Get-NSMigrationLiveFile {
    param(
        [Parameter(Mandatory = $true)][string]$NightshiftDir,
        [Parameter(Mandatory = $true)][string]$Key
    )
    $cur = Get-NSLayoutRelativePathAt $script:NSLayoutVersion $Key
    if ($cur.Length -gt 0 -and (Test-NSPathEntry (Get-NSMigrationNative $NightshiftDir $cur))) { return $cur }
    foreach ($p in (Get-NSMigrationRows $Key)) {
        if ($p.Length -eq 0 -or $p -ceq $cur) { continue }
        if (Test-NSPathEntry (Get-NSMigrationNative $NightshiftDir $p)) { return $p }
    }
    return ''
}

# Read-NSMigrationJson <path> - the document as ordered maps; Readable is false when it is not JSON.
function Read-NSMigrationJson {
    param([Parameter(Mandatory = $true)][string]$Path)
    try {
        $text = $script:NSUtf8NoBom.GetString([IO.File]::ReadAllBytes($Path))
        if ($text.Trim().Length -eq 0) { return [pscustomobject]@{ Readable = $false; Doc = $null } }
        $doc = ConvertFrom-NSJsonText $text
    }
    catch {
        return [pscustomobject]@{ Readable = $false; Doc = $null }
    }
    return [pscustomobject]@{ Readable = $true; Doc = $doc }
}

# Get-NSMigrationJsonAt <doc> <dotted-path> - the compact canonical JSON of the value there, or empty
# when nothing is there.
function Get-NSMigrationJsonAt {
    param($Doc, [Parameter(Mandatory = $true)][string]$Path)
    $node = $Doc
    foreach ($part in $Path.Split('.')) {
        if (-not ($node -is [Collections.IDictionary]) -or -not $node.Contains($part)) { return '' }
        $node = $node[$part]
    }
    return (ConvertTo-NSCanonicalJson $node -Compact)
}

# Rename-NSMigrationJsonKey <doc> <from> <to> - a top-level key under a new name, with everything it
# held. An absent key changes nothing.
function Rename-NSMigrationJsonKey {
    param($Doc, [Parameter(Mandatory = $true)][string]$From, [Parameter(Mandatory = $true)][string]$To)
    if (-not ($Doc -is [Collections.IDictionary]) -or -not $Doc.Contains($From)) { return }
    $value = $Doc[$From]
    $Doc.Remove($From)
    $Doc[$To] = $value
}

# Remove-NSMigrationJsonKey <doc> <dotted-path> - the value there, and its name, are gone. An absent
# path changes nothing.
function Remove-NSMigrationJsonKey {
    param($Doc, [Parameter(Mandatory = $true)][string]$Path)
    $parts = $Path.Split('.')
    $node = $Doc
    for ($j = 0; $j -lt $parts.Count - 1; $j++) {
        if (-not ($node -is [Collections.IDictionary]) -or -not $node.Contains($parts[$j])) { return }
        $node = $node[$parts[$j]]
    }
    $leaf = $parts[$parts.Count - 1]
    if (($node -is [Collections.IDictionary]) -and $node.Contains($leaf)) { $node.Remove($leaf) }
}

# Write-NSMigrationJson <path> <doc> - the document sorted and indented, the way the owner reads it.
function Write-NSMigrationJson {
    param([Parameter(Mandatory = $true)][string]$Path, $Doc)
    $text = ConvertTo-NSCanonicalJson $Doc -Readable
    $null = Write-NSAtomicLines -Path $Path -Lines ($text.Split("`n"))
}

# Get-NSMigrationCarried <path> <moves> - where a path is once the moves are made: itself, or the new
# home of it or of the nearest directory above it.
function Get-NSMigrationCarried {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Path, [Parameter(Mandatory = $true)]$Moves)
    if ($Moves.ContainsKey($Path)) { return $Moves[$Path] }
    $q = $Path
    while (($cut = $q.LastIndexOf('/')) -ge 0) {
        $q = $q.Substring(0, $cut)
        if ($Moves.ContainsKey($q)) { return ($Moves[$q] + $Path.Substring($q.Length)) }
    }
    return $Path
}

function New-NSMigrationMap {
    return (New-Object 'Collections.Generic.Dictionary[string,string]' ([StringComparer]::Ordinal))
}

# Resolve-NSMigrationLink <base> <path> - a path relative to the state directory, from a link written
# against <base>. A `..` above the top is kept.
function Resolve-NSMigrationLink {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Base, [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Path)
    $joined = if ($Base.Length -eq 0) { $Path } else { $Base + '/' + $Path }
    $out = New-Object Collections.Generic.List[string]
    foreach ($segment in $joined.Split('/')) {
        if ($segment.Length -eq 0 -or $segment -ceq '.') { continue }
        if ($segment -ceq '..' -and $out.Count -gt 0 -and $out[$out.Count - 1] -cne '..') {
            $out.RemoveAt($out.Count - 1)
            continue
        }
        $out.Add($segment)
    }
    return ($out -join '/')
}

# Get-NSMigrationRelative <from> <to> - <to> relative to the directory <from>, both relative to the
# state directory; <to> may climb out of it.
function Get-NSMigrationRelative {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$From, [Parameter(Mandatory = $true)][AllowEmptyString()][string]$To)
    $fp = @()
    if ($From.Length -gt 0) { $fp = $From.Split('/') }
    $tp = @()
    if ($To.Length -gt 0) { $tp = $To.Split('/') }
    $common = 0
    while ($common -lt $fp.Count -and $common -lt $tp.Count -and $fp[$common] -ceq $tp[$common] -and $tp[$common] -cne '..') {
        $common++
    }
    $out = New-Object Text.StringBuilder
    for ($j = $common; $j -lt $fp.Count; $j++) { $null = $out.Append('../') }
    for ($j = $common; $j -lt $tp.Count; $j++) {
        $null = $out.Append($tp[$j])
        if ($j -lt $tp.Count - 1) { $null = $out.Append('/') }
    }
    return $out.ToString()
}

function Test-NSMigrationPresent {
    param([Parameter(Mandatory = $true)]$Context, [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Path)
    if ($Path.Length -eq 0) { return $true }
    # Nothing outside the state directory moves, so a link that climbs out of it is checked on disk.
    if ($Path -ceq '..' -or $Path.StartsWith('../', [StringComparison]::Ordinal)) {
        return (Test-Path -LiteralPath (Get-NSMigrationNative $Context.Root $Path))
    }
    return $Context.Present.Contains($Path)
}

# Get-NSMigrationRepoint <context> <target> - a link target as it must read once the moves are made.
# One that still resolves is left exactly as written; one that does not is read against each
# directory the file may have been written in, carried through the moves, and written again
# relative to where the file sits now.
function Get-NSMigrationRepoint {
    param([Parameter(Mandatory = $true)]$Context, [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Target)
    $hash = $Target.IndexOf('#')
    $path = $Target
    $frag = ''
    if ($hash -ge 0) {
        $path = $Target.Substring(0, $hash)
        $frag = $Target.Substring($hash)
    }
    if ($path.Length -eq 0) { return $Target }
    if ($path -cmatch '^[A-Za-z][A-Za-z0-9+.-]*:') { return $Target }
    if ($path.StartsWith('/', [StringComparison]::Ordinal)) { return $Target }
    $slash = ''
    if ($path.EndsWith('/', [StringComparison]::Ordinal)) {
        $slash = '/'
        $path = $path.Substring(0, $path.Length - 1)
    }
    if ($Context.Mode -ceq 'canon') { return ((Get-NSMigrationCarried (Resolve-NSMigrationLink $Context.Dir $path) $Context.Carry) + $slash + $frag) }
    if (Test-NSMigrationPresent $Context (Resolve-NSMigrationLink $Context.Dir $path)) { return $Target }
    foreach ($old in $Context.OldDirs) {
        $now = Get-NSMigrationCarried (Resolve-NSMigrationLink $old $path) $Context.Carry
        if (Test-NSMigrationPresent $Context $now) {
            $new = (Get-NSMigrationRelative $Context.Dir $now) + $slash + $frag
            $Context.Changes.Add($Target + "`t" + $new)
            return $new
        }
    }
    return $Target
}

# Convert-NSMigrationLinkLine <context> <line> - one line with every eligible inline link repointed.
# Scanned character by character, so a code span or a stray bracket cannot make it rewrite something
# that is not a link.
function Convert-NSMigrationLinkLine {
    param([Parameter(Mandatory = $true)]$Context, [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Line)
    $out = New-Object Text.StringBuilder
    $len = $Line.Length
    $i = 0
    while ($i -lt $len) {
        $ch = $Line[$i]
        if ($ch -ceq '`') {
            $tick = $i + 1
            while ($tick -lt $len -and $Line[$tick] -cne '`') { $tick++ }
            $end = [Math]::Min($tick, $len - 1)
            $null = $out.Append($Line.Substring($i, $end - $i + 1))
            $i = $tick + 1
            continue
        }
        if ($ch -ceq ']' -and $i + 1 -lt $len -and $Line[$i + 1] -ceq '(') {
            $depth = 1
            $stop = $i + 2
            while ($stop -lt $len -and $depth -gt 0) {
                if ($Line[$stop] -ceq '(') { $depth++ }
                elseif ($Line[$stop] -ceq ')') { $depth-- }
                if ($depth -eq 0) { break }
                $stop++
            }
            if ($depth -eq 0) {
                $target = $Line.Substring($i + 2, $stop - $i - 2)
                $null = $out.Append('](').Append((Get-NSMigrationRepoint $Context $target)).Append(')')
                $i = $stop + 1
                continue
            }
        }
        $null = $out.Append($ch)
        $i++
    }
    return $out.ToString()
}

# Convert-NSMigrationLinks <context> <lines> - the lines of one Markdown file with its relative links
# repointed; the changes land in the context. Only inline links and reference definitions with a
# relative target are read. A scheme, a leading slash and a bare fragment are left as written, as is
# everything inside a fenced code block. Mirrors lib/migrate-links.awk.
function Convert-NSMigrationLinks {
    param([Parameter(Mandatory = $true)]$Context, [Parameter(Mandatory = $true)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Lines)
    $result = New-Object Collections.Generic.List[string]
    $fence = $false
    foreach ($line in $Lines) {
        if ($line -cmatch '^[ \t\n\r\f\v]*(```|~~~)') {
            $fence = -not $fence
            $result.Add($line)
            continue
        }
        if ($fence) {
            $result.Add($line)
            continue
        }
        # A reference definition: [label]: target "optional title"
        $definition = [regex]::Match($line, '^[ \t]*\[[^\]]*\]:[ \t]*')
        if ($definition.Success -and $definition.Length -lt $line.Length) {
            $head = $line.Substring(0, $definition.Length)
            $rest = $line.Substring($definition.Length)
            $tail = ''
            $space = [regex]::Match($rest, '[ \t\n\r\f\v]')
            if ($space.Success) {
                $tail = $rest.Substring($space.Index)
                $rest = $rest.Substring(0, $space.Index)
            }
            $result.Add($head + (Get-NSMigrationRepoint $Context $rest) + $tail)
            continue
        }
        $result.Add((Convert-NSMigrationLinkLine $Context $line))
    }
    return , $result.ToArray()
}

# Get-NSMigrationTree <state-dir> - every path under the state directory, relative, leaving out the
# receipts repository and never descending into a link.
function Get-NSMigrationTree {
    param([Parameter(Mandatory = $true)][string]$NightshiftDir)
    $out = New-Object Collections.Generic.List[string]
    $pending = New-Object Collections.Generic.Queue[string]
    $pending.Enqueue('')
    while ($pending.Count -gt 0) {
        $rel = $pending.Dequeue()
        foreach ($name in (Get-NSMigrationChildren (Get-NSMigrationNative $NightshiftDir $rel))) {
            if ($name -ceq '.git') { continue }
            $child = if ($rel.Length -eq 0) { $name } else { $rel + '/' + $name }
            $out.Add($child)
            if (Test-NSMigrationDirectory (Get-NSMigrationNative $NightshiftDir $child)) { $pending.Enqueue($child) }
        }
    }
    return , $out.ToArray()
}

# Read-NSMigrationLines <path> - a file's lines as awk reads them: split at each newline, a last line
# without one still a line, every other byte kept.
function Read-NSMigrationLines {
    param([Parameter(Mandatory = $true)][string]$Path)
    $text = $script:NSUtf8NoBom.GetString([IO.File]::ReadAllBytes($Path))
    if ($text.Length -eq 0) { return , @() }
    $lines = $text.Split("`n")
    if ($text.EndsWith("`n", [StringComparison]::Ordinal)) { $lines = $lines[0..($lines.Count - 2)] }
    return , [string[]]$lines
}

# Get-NSMigrationArchiveName <workspace> - the archive root, relative to the state directory.
function Get-NSMigrationArchiveName {
    param([Parameter(Mandatory = $true)][string]$Workspace)
    $name = ''
    try {
        $name = [string](Get-NSPolicyGroupSetting $Workspace 'archive.root')['value']
    }
    catch {
        $name = ''
    }
    if ([string]::IsNullOrEmpty($name)) { $name = Get-NSLayoutRelativePathAt $script:NSLayoutVersion 'archive' }
    return $name
}

# Invoke-NSMigrationLinks <workspace> <moves> <plan|apply> - the Markdown files under the state
# directory with a link that would not resolve once the moves are made. `plan` returns link
# records; `apply` rewrites each file in place, and throws when a write fails.
function Invoke-NSMigrationLinks {
    param(
        [Parameter(Mandatory = $true)][string]$Workspace,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Moves,
        [Parameter(Mandatory = $true)][ValidateSet('plan', 'apply')][string]$Mode
    )
    $ns = Join-Path $Workspace '.nightshift'
    $records = New-Object Collections.Generic.List[string]
    $keys = Get-NSMigrationKeys
    # A link is carried by the table, not by this run's moves: every earlier path of a key reaches
    # its current one, so a run that finishes an interrupted one repoints what the first one moved.
    $carry = Get-NSMigrationCarryMap
    $moved = New-NSMigrationMap
    foreach ($pair in $Moves) {
        $fields = $pair.Split("`t")
        $moved[$fields[0]] = $fields[1]
    }
    # What exists once the moves are made: every path now, carried through the moves.
    $present = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $tree = Get-NSMigrationTree $ns
    foreach ($rel in $tree) {
        $now = Get-NSMigrationCarried $rel $moved
        $null = $present.Add($now)
        while ($now.Contains('/')) {
            $now = Get-NSMigrationParent $now
            $null = $present.Add($now)
        }
    }
    $files = New-Object Collections.Generic.List[string]
    foreach ($rel in $tree) {
        if (-not $rel.EndsWith('.md', [StringComparison]::Ordinal)) { continue }
        if ($rel.EndsWith('.original.md', [StringComparison]::Ordinal)) { continue }
        if (-not (Test-NSMigrationFile (Get-NSMigrationNative $ns $rel))) { continue }
        $files.Add($rel)
    }
    foreach ($rel in (Sort-NSOrdinal $files.ToArray())) {
        $native = Get-NSMigrationNative $ns $rel
        $now = $rel
        if ($Mode -ceq 'plan') { $now = Get-NSMigrationCarried $rel $moved }
        $dir = Get-NSMigrationParent $now
        $olddirs = New-Object Collections.Generic.List[string]
        $olddirs.Add($dir)
        $was = Get-NSMigrationParent $rel
        if ($was -cne $dir) { $olddirs.Add($was) }
        # A file with a key may have been written in any directory an earlier layout gave it.
        foreach ($key in $keys) {
            if ((Get-NSLayoutRelativePathAt $script:NSLayoutVersion $key) -cne $now) { continue }
            foreach ($p in (Get-NSMigrationRows $key)) {
                $pdir = Get-NSMigrationParent $p
                if (-not $olddirs.Contains($pdir)) { $olddirs.Add($pdir) }
            }
        }
        $context = [pscustomobject]@{
            Mode = 'rewrite'
            Dir = $dir
            OldDirs = $olddirs.ToArray()
            Present = $present
            Carry = $carry
            Root = $ns
            Changes = New-Object Collections.Generic.List[string]
        }
        $rewritten = Convert-NSMigrationLinks $context (Read-NSMigrationLines $native)
        if ($context.Changes.Count -eq 0) { continue }
        if ($Mode -ceq 'plan') {
            foreach ($change in $context.Changes) { $records.Add("link`t$now`t$change") }
            continue
        }
        $null = Write-NSAtomicLines -Path $native -Lines $rewritten
    }
    return , $records.ToArray()
}

# Test-NSMigrationKnown <rel> <known-paths> - whether <rel> is a path some layout gives a key, or an
# instance of a family such as usage-*.
function Test-NSMigrationKnown {
    param([Parameter(Mandatory = $true)][string]$Relative, [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Known)
    foreach ($p in $Known) {
        if ($p.Contains('*')) {
            $star = $p.IndexOf('*')
            $prefix = $p.Substring(0, $star)
            $suffix = $p.Substring($star + 1)
            if ($Relative.Length -ge $prefix.Length + $suffix.Length -and
                $Relative.StartsWith($prefix, [StringComparison]::Ordinal) -and
                $Relative.EndsWith($suffix, [StringComparison]::Ordinal)) { return $true }
            continue
        }
        if ($Relative -ceq $p) { return $true }
    }
    return $false
}

# Get-NSMigrationPlan <workspace> - the plan as the records ns_migrate_plan prints, one string each,
# tab separated:
#   state <version>                  where the workspace starts
#   refuse <reason>                  the run cannot apply until this is resolved
#   move <from> <to>                 a rename onto an empty path
#   leave <from> <to> same|empty     already done: the same content, or an empty directory, stay put
#   conflict <from> <to> [why]       a destination that holds something else
#   rename <file> <from> <to>        a settings block that moves to its current name
#   drop <file> <from> <to>          an earlier block whose value is already under its current name
#   retire <file> <path>             a setting no version reads any more
#   link <file> <old> <new>          a relative link written again so it resolves
#   ignore <file> <line>             a line the receipts repository needs to leave run/ out
#   unknown <path>                   something that is not a Nightshift file, left in place
#   stray <path>                     a file an earlier plugin wrote by mistake, left in place
#   note <text>                      what the owner should know about a move
#   marker <from> <to>               the state-version written last
# Code 0 planned - 2 no usable state directory.
function Get-NSMigrationPlan {
    param([Parameter(Mandatory = $true)][string]$Workspace)
    $records = New-Object Collections.Generic.List[string]
    $ns = Join-Path $Workspace '.nightshift'
    $kind = Get-NSStateKind $Workspace
    if ($kind -ceq 'absent') {
        $records.Add("refuse`tno .nightshift/ at $Workspace - run Setup first")
        return [pscustomobject]@{ Code = 2; Records = $records.ToArray() }
    }
    if ($kind -ceq 'future' -or $kind -ceq 'malformed') {
        $records.Add("refuse`t" + (Get-NSStateRefuseMessage $kind))
        return [pscustomobject]@{ Code = 2; Records = $records.ToArray() }
    }
    $records.Add("state`t" + (Get-NSStateVersion $Workspace))

    # Nothing moves under a running shift, a live watchman or a held lock: each of them may be
    # writing to a path this is about to take away.
    foreach ($p in (Get-NSMigrationRows 'armed')) {
        if (Test-Path -LiteralPath (Get-NSMigrationNative $ns $p) -PathType Leaf) {
            $records.Add("refuse`tthe shift is armed ($p) - clock out, or run Reset, first")
            break
        }
    }
    foreach ($p in (Get-NSMigrationRows 'watchman')) {
        $native = Get-NSMigrationNative $ns $p
        if (-not (Test-NSMigrationFile $native)) { continue }
        $lines = @()
        try { $lines = @([IO.File]::ReadAllLines($native)) } catch { $lines = @() }
        $recorded = if ($lines.Count -gt 0) { ([string]$lines[0]) -replace '\s', '' } else { '' }
        $start = if ($lines.Count -gt 1) { [string]$lines[1] } else { '' }
        if ($recorded -cnotmatch '^[0-9]+$') { continue }
        # A process that cannot be looked at is treated as the watchman it may be.
        if ((Test-NSRecordedProcess $recorded $start) -in @('Alive', 'Unavailable')) {
            $records.Add("refuse`ta watchman is running (pid $recorded, $p) - stop it with Stop or Reset first")
        }
    }
    foreach ($key in @('lock', 'lease-lock')) {
        foreach ($p in (Get-NSMigrationRows $key)) {
            if (Test-NSPathEntry (Get-NSMigrationNative $ns $p)) {
                $records.Add("refuse`ta lock is held ($p) - let the operation finish, or run Reset if nothing is running")
            }
        }
    }

    # Every file found at an earlier path of its key, bound for its current one.
    $carry = Get-NSMigrationCarryMap
    $moves = New-Object Collections.Generic.List[string]
    foreach ($key in (Get-NSMigrationKeys)) {
        $cur = Get-NSLayoutRelativePathAt $script:NSLayoutVersion $key
        if ($cur.Length -eq 0) { continue }
        foreach ($p in (Get-NSMigrationRows $key)) {
            if ($p.Length -eq 0 -or $p -ceq $cur) { continue }
            $pairs = New-Object Collections.Generic.List[object]
            $star = $p.IndexOf('*')
            if ($star -ge 0) {
                $prefix = $p.Substring(0, $star)
                $suffix = $p.Substring($star + 1)
                $parent = Get-NSMigrationParent $prefix
                $lead = $prefix.Substring($prefix.LastIndexOf('/') + 1)
                $curStar = $cur.IndexOf('*')
                foreach ($name in (Get-NSMigrationChildren (Get-NSMigrationNative $ns $parent))) {
                    if ($name.Length -le $lead.Length + $suffix.Length) { continue }
                    if (-not $name.StartsWith($lead, [StringComparison]::Ordinal)) { continue }
                    if (-not $name.EndsWith($suffix, [StringComparison]::Ordinal)) { continue }
                    # A family's * never matches a leading dot, as a shell pattern would not.
                    if ($lead.Length -eq 0 -and $name.StartsWith('.', [StringComparison]::Ordinal)) { continue }
                    $inst = $name.Substring($lead.Length, $name.Length - $lead.Length - $suffix.Length)
                    $rel = if ($parent.Length -eq 0) { $name } else { $parent + '/' + $name }
                    $pairs.Add(@($rel, ($cur.Substring(0, $curStar) + $inst + $cur.Substring($curStar + 1))))
                }
            }
            elseif (Test-NSPathEntry (Get-NSMigrationNative $ns $p)) {
                $pairs.Add(@($p, $cur))
            }
            foreach ($pair in $pairs) {
                $from = $pair[0]
                $to = $pair[1]
                $verdict = Get-NSMigrationVerdict $ns $from $to $carry
                switch -CaseSensitive ($verdict) {
                    'move' {
                        $records.Add("move`t$from`t$to")
                        $moves.Add("$from`t$to")
                    }
                    { $_ -ceq 'same' -or $_ -ceq 'empty' } { $records.Add("leave`t$from`t$to`t$verdict") }
                    default { $records.Add("conflict`t$from`t$to") }
                }
            }
        }
    }

    # Settings blocks under their current names, then settings no version reads. The document is
    # read wherever it sits now and judged as it will be once the renames are made.
    $docs = @{}
    foreach ($fkey in (Get-NSMigrationFieldKeys 'field')) {
        $rows = Get-NSMigrationRows $fkey
        $fcur = $rows[$rows.Count - 1]
        $file = $fcur.Substring(0, $fcur.IndexOf('#'))
        $newv = $fcur.Substring($fcur.IndexOf('#') + 1)
        $rel = Get-NSMigrationLiveFile $ns $file
        if ($rel.Length -eq 0 -or -not (Test-NSMigrationFile (Get-NSMigrationNative $ns $rel))) { continue }
        $to = Get-NSLayoutRelativePathAt $script:NSLayoutVersion $file
        if (-not $docs.ContainsKey($file)) { $docs[$file] = Read-NSMigrationJson (Get-NSMigrationNative $ns $rel) }
        $state = $docs[$file]
        if (-not $state.Readable) {
            $records.Add("conflict`t$rel`t$to`tis not readable JSON, so its settings cannot be checked")
            continue
        }
        for ($j = 0; $j -lt $rows.Count - 1; $j++) {
            $oldv = $rows[$j].Substring($rows[$j].IndexOf('#') + 1)
            $oldValue = Get-NSMigrationJsonAt $state.Doc $oldv
            if ($oldValue.Length -eq 0) { continue }
            $newValue = Get-NSMigrationJsonAt $state.Doc $newv
            if ($newValue.Length -eq 0) {
                $records.Add("rename`t$to`t$oldv`t$newv")
                Rename-NSMigrationJsonKey $state.Doc $oldv $newv
            }
            elseif ($oldValue -ceq $newValue) {
                $records.Add("drop`t$to`t$oldv`t$newv")
                Remove-NSMigrationJsonKey $state.Doc $oldv
            }
            else {
                $records.Add("conflict`t$rel`t$to`tholds both $oldv and $newv with different values")
            }
        }
    }
    foreach ($rkey in (Get-NSMigrationFieldKeys 'retired')) {
        foreach ($line in (Get-NSMigrationRows $rkey)) {
            $file = $line.Substring(0, $line.IndexOf('#'))
            $path = $line.Substring($line.IndexOf('#') + 1)
            if (-not $docs.ContainsKey($file)) {
                $rel = Get-NSMigrationLiveFile $ns $file
                if ($rel.Length -eq 0 -or -not (Test-NSMigrationFile (Get-NSMigrationNative $ns $rel))) { continue }
                $docs[$file] = Read-NSMigrationJson (Get-NSMigrationNative $ns $rel)
            }
            $state = $docs[$file]
            if (-not $state.Readable) { continue }
            if ((Get-NSMigrationJsonAt $state.Doc $path).Length -eq 0) { continue }
            $records.Add("retire`t" + (Get-NSLayoutRelativePathAt $script:NSLayoutVersion $file) + "`t$path")
        }
    }

    # Links that would stop resolving once the moves are made, written again so they do.
    foreach ($record in (Invoke-NSMigrationLinks $Workspace $moves.ToArray() 'plan')) { $records.Add($record) }

    # The receipts repository leaves the runtime's directory out, as Setup writes it.
    $run = Get-NSLayoutRelativePathAt $script:NSLayoutVersion 'run'
    $ignoreRel = Get-NSLayoutRelativePathAt $script:NSLayoutVersion 'gitignore'
    $ignore = Get-NSMigrationNative $ns $ignoreRel
    if ($run.Length -gt 0 -and (Test-NSMigrationFile $ignore) -and
        -not ((Read-NSMigrationLines $ignore) -ccontains ($run + '/'))) {
        $records.Add("ignore`t$ignoreRel`t$run/")
    }

    # Anything this layout has no name for stays where it is, and is named so nothing is a surprise.
    $archiveRoot = Get-NSMigrationArchiveName $Workspace
    $known = New-Object Collections.Generic.List[string]
    $groups = New-Object Collections.Generic.List[string]
    $strays = New-Object Collections.Generic.List[string]
    foreach ($row in $script:NSLayoutRows) {
        if ($row.Kind -ceq 'field' -or $row.Kind -ceq 'retired') { continue }
        if ($row.Kind -ceq 'stray') { $strays.Add($row.Path); continue }
        $known.Add($row.Path)
        if ($row.Kind -ceq 'group') { $groups.Add($row.Path) }
    }
    foreach ($name in (Get-NSMigrationChildren $ns)) {
        if ($name -ceq $archiveRoot) { continue }
        if (Test-NSMigrationKnown $name $strays.ToArray()) {
            $records.Add("stray`t$name")
            continue
        }
        if (-not (Test-NSMigrationKnown $name $known.ToArray())) {
            $records.Add("unknown`t$name")
            continue
        }
        # A folder that holds only other keys: anything else inside it is named too.
        if ((Test-NSMigrationDirectory (Get-NSMigrationNative $ns $name)) -and $groups.Contains($name)) {
            foreach ($child in (Get-NSMigrationChildren (Get-NSMigrationNative $ns $name))) {
                if (-not (Test-NSMigrationKnown "$name/$child" $known.ToArray())) { $records.Add("unknown`t$name/$child") }
            }
        }
    }

    $scheduled = Get-NSLayoutRelativePathAt $script:NSLayoutVersion 'scheduled-log'
    foreach ($pair in $moves) {
        if ($pair.Split("`t")[1] -ceq $scheduled) {
            $records.Add("note`ta schedule registered before this move still appends to scheduled.log; print it again with Schedule")
            break
        }
    }
    $repo = Get-NSMigrationNative $ns (Get-NSLayoutRelativePathAt $script:NSLayoutVersion 'receipts-repo')
    if ((Test-Path -LiteralPath $repo -PathType Container) -and $moves.Count -gt 0) {
        $records.Add("note`tthe receipts repository shows each move once you commit; run/ is left out of it from now on")
    }
    if ($kind -ceq 'legacy') {
        $records.Add("marker`t" + (Get-NSStateVersion $Workspace) + "`t$script:NSStateVersion")
    }
    return [pscustomobject]@{ Code = 0; Records = $records.ToArray() }
}

# Get-NSMigrationField <fields> <index> - one field of a record, empty past its end.
function Get-NSMigrationField {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Fields, [Parameter(Mandatory = $true)][int]$Index)
    if ($Index -lt $Fields.Count) { return $Fields[$Index] }
    return ''
}

# Format-NSMigrationPlan <preview|apply> <records> - the plan as lines an owner reads, the same
# lines ns_migrate_render prints.
function Format-NSMigrationPlan {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('preview', 'apply')][string]$Mode,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Records
    )
    $lines = New-Object Collections.Generic.List[string]
    $refused = $false
    $conflict = $false
    $n = 0
    foreach ($record in $Records) {
        $f = $record.Split("`t")
        $a = Get-NSMigrationField $f 1
        $b = Get-NSMigrationField $f 2
        $c = Get-NSMigrationField $f 3
        switch -CaseSensitive ($f[0]) {
            'refuse' { $lines.Add("  refuse    $a"); $refused = $true }
            'move' { $lines.Add("  move      $a -> $b"); $n++ }
            'leave' {
                if ($c -ceq 'same') { $lines.Add("  leave     $a (the same content is already at $b)") }
                else { $lines.Add("  leave     $a/ (empty; $b/ is already there)") }
            }
            'conflict' {
                if ($c.Length -gt 0) { $lines.Add("  conflict  $a $c") }
                else { $lines.Add("  conflict  $a and $b are both there and differ - keep one by hand") }
                $conflict = $true
            }
            'rename' { $lines.Add("  rename    ${a}: $b -> $c"); $n++ }
            'drop' { $lines.Add("  drop      ${a}: $b (the same value is already under $c)"); $n++ }
            'retire' { $lines.Add("  retire    ${a}: $b (no version reads it)"); $n++ }
            'link' { $lines.Add("  link      ${a}: $b -> $c"); $n++ }
            'ignore' { $lines.Add("  ignore    ${a}: add $b"); $n++ }
            'unknown' { $lines.Add("  unknown   $a (no Nightshift file has this name; left in place)") }
            'stray' { $lines.Add("  stray     $a (an earlier Setup copied a template here and nothing reads it; left in place, safe to delete)") }
            'note' { $lines.Add("  note      $a") }
            'marker' { $lines.Add("  marker    state-version $a -> $b"); $n++ }
        }
    }
    if ($refused -or $conflict) {
        $lines.Add('Refused - nothing was changed.')
    }
    elseif ($Mode -ceq 'apply') {
        $lines.Add('Applied. Nothing was deleted or overwritten.')
    }
    elseif ($n -eq 0) {
        $lines.Add('Every file is where the current layout keeps it; nothing to do.')
    }
    else {
        $lines.Add('Preview only - nothing was changed. Run it again with -Apply to make these changes; nothing is deleted or overwritten.')
    }
    return , $lines.ToArray()
}

# Get-NSMigrationOffer <records> <preview-command> - the move a plan makes, in one line for Doctor
# and Setup: each file with its old and new path, what else it changes, and the command that
# previews it. Empty when the plan changes nothing.
function Get-NSMigrationOffer {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Records,
        [Parameter(Mandatory = $true)][string]$Command
    )
    $moves = New-Object Collections.Generic.List[string]
    $other = ''
    $settings = 0
    $links = 0
    $marker = ''
    $n = 0
    foreach ($record in $Records) {
        $f = $record.Split("`t")
        $a = Get-NSMigrationField $f 1
        $b = Get-NSMigrationField $f 2
        $c = Get-NSMigrationField $f 3
        switch -CaseSensitive ($f[0]) {
            'move' { $moves.Add("$a -> $b"); $n++ }
            'rename' { $other += "; $a $b -> $c"; $n++ }
            'drop' { $settings++; $n++ }
            'retire' { $settings++; $n++ }
            'link' { $links++; $n++ }
            'ignore' { $other += "; $a leaves $b out"; $n++ }
            'marker' { $marker = "; state-version $a -> $b"; $n++ }
        }
    }
    if ($n -eq 0) { return '' }
    $out = "move the state files into layout $script:NSStateVersion"
    if ($moves.Count -gt 0) { $out += ': ' + ($moves -join ', ') }
    $out += $other
    if ($settings -gt 0) { $out += "; $settings retired setting" + $(if ($settings -eq 1) { '' } else { 's' }) + ' removed' }
    if ($links -gt 0) { $out += "; $links link" + $(if ($links -eq 1) { '' } else { 's' }) + ' written again so they still resolve' }
    $out += $marker + "; nothing is deleted or overwritten. Preview it with $Command, then run it again with -Apply"
    return $out
}

# Invoke-NSMigrationApply <workspace> <records> - perform a plan Get-NSMigrationPlan returned. The
# caller has checked it holds no refuse or conflict record.
# Return: 0 done - 3 a move or write failed (whatever finished stands; running it again completes it)
function Invoke-NSMigrationApply {
    param(
        [Parameter(Mandatory = $true)][string]$Workspace,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Records
    )
    $ns = Join-Path $Workspace '.nightshift'
    try {
        foreach ($record in $Records) {
            $f = $record.Split("`t")
            if ($f[0] -cne 'move') { continue }
            $src = Get-NSMigrationNative $ns $f[1]
            $dst = Get-NSMigrationNative $ns $f[2]
            if (Test-NSPathEntry $dst) { return 3 }
            $parent = Get-NSMigrationParent $f[2]
            if ($parent.Length -gt 0) { $null = [IO.Directory]::CreateDirectory((Get-NSMigrationNative $ns $parent)) }
            # A rename, file or directory alike, so nothing is ever half copied.
            if (([IO.File]::GetAttributes($src) -band [IO.FileAttributes]::Directory) -ne 0) {
                [IO.Directory]::Move($src, $dst)
            }
            else {
                [IO.File]::Move($src, $dst)
            }
        }
        foreach ($record in $Records) {
            $f = $record.Split("`t")
            if ($f[0] -cne 'rename' -and $f[0] -cne 'drop' -and $f[0] -cne 'retire') { continue }
            $path = Get-NSMigrationNative $ns $f[1]
            $state = Read-NSMigrationJson $path
            if (-not $state.Readable) { return 3 }
            if ($f[0] -ceq 'rename') { Rename-NSMigrationJsonKey $state.Doc $f[2] $f[3] }
            else { Remove-NSMigrationJsonKey $state.Doc $f[2] }
            Write-NSMigrationJson $path $state.Doc
        }
        if (@($Records | Where-Object { $_.StartsWith("link`t", [StringComparison]::Ordinal) }).Count -gt 0) {
            $null = Invoke-NSMigrationLinks $Workspace @() 'apply'
        }
        foreach ($record in $Records) {
            $f = $record.Split("`t")
            if ($f[0] -cne 'ignore') { continue }
            $path = Get-NSMigrationNative $ns $f[1]
            $bytes = [IO.File]::ReadAllBytes($path)
            $text = $f[2] + "`n"
            # A last line without its newline would otherwise run into the one added.
            if ($bytes.Length -gt 0 -and $bytes[$bytes.Length - 1] -ne 10) { $text = "`n" + $text }
            [IO.File]::AppendAllText($path, $text, $script:NSUtf8NoBom)
        }
        foreach ($record in $Records) {
            $f = $record.Split("`t")
            if ($f[0] -cne 'marker') { continue }
            $null = Write-NSAtomicLines -Path (Get-NSMigrationNative $ns (Get-NSLayoutRelativePathAt $script:NSLayoutVersion 'state-version')) -Lines @($f[2])
        }
    }
    catch {
        return 3
    }
    return 0
}

function Get-NSReasonCode {
    param([Parameter(Mandatory = $true)][string]$NightshiftDir)
    $path = Get-NSLayoutPath $NightshiftDir 'watch-reason'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return ''
    }
    try {
        $line = ([IO.File]::ReadAllLines($path) | Select-Object -First 1)
        return (([string]$line) -replace '\s', '')
    }
    catch {
        return ''
    }
}

function Get-NSReasonLabel {
    param([AllowEmptyString()][string]$Code)
    switch ($Code) {
        'completed' { return 'shift completed' }
        'owner-stop' { return 'owner stop-work order' }
        'owner-disarm' { return 'shift disarmed - the armed marker is gone' }
        'stale-pid' { return 'recorded process is stale' }
        'invalid-session' { return 'session identity is missing or unreadable' }
        'exhausted-retry' { return 'revival retries exhausted this wake' }
        'unknown-wedge' { return 'session looks wedged without a verified error signature' }
        'revived' { return 'session revived into its own conversation' }
        'stand-down' { return 'watchman stood down' }
        'wrong-host' { return 'watchman stood down - shift belongs to another host' }
        'deadline' { return 'quitting time passed' }
        'clean-session-end' { return 'owner closed the session' }
        'esc-standby' { return 'standing by - owner interrupt in the transcript' }
        'silent-standby' { return 'standing by - session alive and quiet' }
        'api-error' { return 'session stopped on an API error - reviving' }
        'usage-limit' { return 'waiting for the usage limit to reset' }
        'non-resumable-session' { return 'recorded Codex identity cannot be resumed' }
        'unreadable-rules' { return 'rules file missing or incomplete' }
        'fresh-fallback' { return 'fresh session - punch list is the handover' }
        'unsupported-state' { return 'workspace state-version is unsupported' }
        'recovery-scope-unavailable' { return 'recorded launch scope cannot be requested on this host' }
        'process-evidence-unavailable' { return 'process evidence is unavailable' }
        'clock-out-failed' { return 'terminal clock-out failed without releasing the shift' }
        default { return 'unknown watchman outcome' }
    }
}

function Get-NSRetentionDays {
    param(
        [Parameter(Mandatory = $true)][string]$Workspace,
        [Parameter(Mandatory = $true)][ValidateSet('runtimeLogDays', 'archiveDays')][string]$Key
    )
    $envName = if ($Key -eq 'runtimeLogDays') {
        'NIGHTSHIFT_RETENTION_RUNTIME_LOG_DAYS'
    }
    else {
        'NIGHTSHIFT_RETENTION_ARCHIVE_DAYS'
    }
    $override = [Environment]::GetEnvironmentVariable($envName)
    if ($override -match '^[0-9]+$') {
        return [int]$override
    }
    $rules = Get-NSRulesObject $Workspace
    if ($null -eq $rules) {
        return 0
    }
    $retention = $rules.PSObject.Properties['retention']
    if ($null -eq $retention -or $null -eq $retention.Value) {
        return 0
    }
    $property = $retention.Value.PSObject.Properties[$Key]
    if ($null -eq $property -or $null -eq $property.Value) {
        return 0
    }
    $raw = [string]$property.Value
    if ($raw -notmatch '^[0-9]+$') {
        return 0
    }
    return [int]$raw
}

function Resolve-NSUnderNightshift {
    param(
        [Parameter(Mandatory = $true)][string]$Workspace,
        [Parameter(Mandatory = $true)][string]$Relative
    )
    if ([string]::IsNullOrEmpty($Relative) -or $Relative.Contains('..') `
        -or [IO.Path]::IsPathRooted($Relative)) {
        return $null
    }
    $ns = Join-Path $Workspace '.nightshift'
    try {
        $root = Resolve-NSCanonicalPath $ns
    }
    catch {
        return $null
    }
    $candidate = Join-Path $ns ($Relative -replace '/', [string][IO.Path]::DirectorySeparatorChar)
    if (-not (Test-NSPathEntry $candidate) -or (Test-NSReparsePoint $candidate)) {
        return $null
    }
    try {
        $canon = Resolve-NSCanonicalPath $candidate
    }
    catch {
        return $null
    }
    $prefix = $root.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if ($canon.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        return $canon
    }
    return $null
}

function Test-NSArchiveHasOpenWork {
    param([Parameter(Mandatory = $true)][string]$Directory)
    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) {
        return $false
    }
    $armed = Join-Path $Directory '.shift-armed'
    if ((Test-NSPathEntry $armed)) {
        return $true
    }
    # A folder a shift claimed holds a copy of its list as it ended, whose open items stayed live;
    # only a page filed by an older version, without that claim, can hold work nothing else has.
    if ((Get-NSArchiveFolderOwner $Directory) -cne '') { return $false }
    foreach ($file in @(Get-ChildItem -LiteralPath $Directory -File -Force -ErrorAction SilentlyContinue)) {
        if ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            continue
        }
        if ($file.Name -in @('punch-list.md', 'shipped.md')) {
            $counts = Get-NSBoxCounts $file.FullName
            if ($counts.Open -gt 0) {
                return $true
            }
        }
    }
    return $false
}

function Get-NSRetentionEligible {
    param([Parameter(Mandatory = $true)][string]$Workspace)
    $ns = Join-Path $Workspace '.nightshift'
    $rows = [Collections.Generic.List[psobject]]::new()
    if (-not (Test-Path -LiteralPath $ns -PathType Container)) {
        return @($rows)
    }
    $now = [DateTime]::UtcNow
    $logDays = Get-NSRetentionDays $Workspace 'runtimeLogDays'
    $archDays = Get-NSRetentionDays $Workspace 'archiveDays'

    if ($logDays -gt 0) {
        $logRel = Get-NSLayoutRelativePath $ns 'scheduled-log'
        $logPath = Resolve-NSUnderNightshift $Workspace $logRel
        if (-not [string]::IsNullOrEmpty($logPath) -and (Test-Path -LiteralPath $logPath -PathType Leaf)) {
            $age = [int](($now - (Get-Item -LiteralPath $logPath).LastWriteTimeUtc).TotalDays)
            if ($age -ge $logDays) {
                $null = $rows.Add([pscustomobject]@{ Kind = 'runtime-log'; Rel = $logRel; Age = $age; Days = $logDays })
            }
        }
    }

    if ($archDays -le 0) {
        return @($rows)
    }
    $archiveRoot = Get-NSLayoutPath $ns 'archive'
    if (-not (Test-Path -LiteralPath $archiveRoot -PathType Container) -or (Test-NSReparsePoint $archiveRoot)) {
        return @($rows)
    }
    foreach ($dir in @(Get-ChildItem -LiteralPath $archiveRoot -Directory -ErrorAction SilentlyContinue)) {
        if ($dir.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            continue
        }
        # A dated folder, the same with a shift number or a name after the date, or any folder a
        # shift claimed, as the name layout files one.
        if ($dir.Name -cnotmatch '^[0-9]{4}-[0-9]{2}-[0-9]{2}(-shift-[1-9][0-9]*)?$' -and
            (Get-NSArchiveFolderOwner $dir.FullName) -ceq '') {
            continue
        }
        $rel = (Get-NSLayoutRelativePath $ns 'archive') + '/' + $dir.Name
        $path = Resolve-NSUnderNightshift $Workspace $rel
        if ([string]::IsNullOrEmpty($path)) {
            continue
        }
        if (Test-NSArchiveHasOpenWork $path) {
            continue
        }
        $age = [int](($now - (Get-Item -LiteralPath $path).LastWriteTimeUtc).TotalDays)
        if ($age -ge $archDays) {
            $null = $rows.Add([pscustomobject]@{ Kind = 'archive'; Rel = $rel; Age = $age; Days = $archDays })
        }
    }
    return @($rows)
}

function Invoke-NSRetentionApply {
    param([Parameter(Mandatory = $true)][string]$Workspace)
    $ns = Join-Path $Workspace '.nightshift'
    if (-not (Test-Path -LiteralPath $ns -PathType Container)) {
        return 2
    }
    if (Test-Path -LiteralPath (Get-NSLayoutPath $ns 'armed') -PathType Leaf) {
        return 1
    }
    foreach ($row in @(Get-NSRetentionEligible $Workspace)) {
        $path = Resolve-NSUnderNightshift $Workspace $row.Rel
        if ([string]::IsNullOrEmpty($path)) {
            return 2
        }
        if ($row.Kind -eq 'runtime-log') {
            if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or (Test-NSReparsePoint $path)) {
                return 2
            }
            Remove-NSFile $path
        }
        elseif ($row.Kind -eq 'archive') {
            if (-not (Test-Path -LiteralPath $path -PathType Container) -or (Test-NSReparsePoint $path)) {
                return 2
            }
            if (Test-NSArchiveHasOpenWork $path) {
                return 2
            }
            try {
                Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop
            }
            catch {
                return 2
            }
        }
        else {
            return 2
        }
    }
    return 0
}

function Test-NSSecretLine {
    param([AllowEmptyString()][string]$Text)
    if ($Text -match '(?i)(password|passwd|secret|token|api[_-]?key|authorization|bearer|credential)\s*[=:]') {
        return $true
    }
    if ($Text -match '://[^/@\s]+:[^/@\s]+@') {
        return $true
    }
    if ($Text -match '(?i)[?&](token|key|secret|password|auth|access_token)=') {
        return $true
    }
    return $false
}

function Convert-NSTokenizedText {
    param(
        [AllowEmptyString()][string]$Text,
        [AllowEmptyString()][string]$HomeRoot = '',
        [AllowEmptyString()][string]$Workspace = '',
        [AllowEmptyString()][string]$Target = ''
    )
    $out = $Text
    foreach ($pair in @(
            @{ From = $Target; To = '$WORK_TARGET' },
            @{ From = $Workspace; To = '$WORKSPACE' },
            @{ From = $HomeRoot; To = '$HOME' }
        )) {
        if ([string]::IsNullOrEmpty($pair.From)) {
            continue
        }
        $out = $out.Replace($pair.From, $pair.To)
        $slash = $pair.From.Replace('\', '/')
        if ($slash -ne $pair.From) {
            $out = $out.Replace($slash, $pair.To)
        }
    }
    if ($out -match '(^|[\s=])(/|file://|[A-Za-z]:[\\/])') {
        return $null
    }
    return $out
}

function Convert-NSSanitizedLine {
    param(
        [AllowEmptyString()][string]$Text,
        [AllowEmptyString()][string]$HomeRoot = '',
        [AllowEmptyString()][string]$Workspace = '',
        [AllowEmptyString()][string]$Target = ''
    )
    if (Test-NSSecretLine $Text) {
        return $null
    }
    return Convert-NSTokenizedText $Text $HomeRoot $Workspace $Target
}

function Expand-NSInjectedPaths {
    param(
        [Parameter(Mandatory = $true)][string]$Workspace,
        [AllowEmptyString()][string]$Text
    )
    if ([string]::IsNullOrEmpty($Text)) {
        return $Text
    }
    $text = $Text.Replace('$NIGHTSHIFT_WORKSPACE', $Workspace)
    $nsRoot = $Workspace.TrimEnd('\', '/') + '/.nightshift'
    $text = $text.Replace('$NS', $nsRoot)
    $root = $Workspace.TrimEnd('\', '/')
    # Each state file is named where this workspace's layout keeps it: text written for one layout
    # still sends the agent to the right file in another. The longest name goes first, so a file is
    # never read as the folder it sits in.
    $version = Get-NSLayoutVersion (Join-Path $Workspace '.nightshift')
    $current = $script:NSLayoutPaths[$version]
    $map = New-Object 'System.Collections.Generic.List[object]'
    foreach ($row in $script:NSLayoutRows) {
        if ($row.Kind -ceq 'field' -or $row.Kind -ceq 'retired' -or $row.Kind -ceq 'stray' -or $row.Path.Contains('*')) { continue }
        if (-not $current.ContainsKey($row.Key) -or $row.Path -ceq $current[$row.Key]) { continue }
        $map.Add([pscustomobject]@{ From = $row.Path; To = [string]$current[$row.Key] })
    }
    $map = @($map | Sort-Object -Property @{ Expression = { $_.From.Length }; Descending = $true })
    $builder = New-Object Text.StringBuilder
    $i = 0
    while ($i -lt $text.Length) {
        $idx = $text.IndexOf('.nightshift', $i, [StringComparison]::Ordinal)
        if ($idx -lt 0) {
            $null = $builder.Append($text.Substring($i))
            break
        }
        $after = if (($idx + 11) -lt $text.Length) { $text[$idx + 11] } else { [char]0 }
        $sepOk = ($after -eq [char]'/' -or $after -eq [char]'\')
        $prev = if ($idx -gt 0) { $text[$idx - 1] } else { [char]0 }
        $already = ($prev -eq [char]'/' -or $prev -eq [char]'\')
        $null = $builder.Append($text.Substring($i, $idx - $i))
        if ($sepOk -and -not $already) {
            $null = $builder.Append($root)
            $null = $builder.Append('/')
            $null = $builder.Append('.nightshift')
            $null = $builder.Append($after)
            $i = $idx + 12
        }
        elseif ($sepOk) {
            $null = $builder.Append('.nightshift')
            $null = $builder.Append($after)
            $i = $idx + 12
        }
        else {
            $null = $builder.Append('.nightshift')
            $i = $idx + 11
            continue
        }
        foreach ($pair in $map) {
            $end = $i + $pair.From.Length
            if ($end -gt $text.Length -or -not $text.Substring($i).StartsWith($pair.From, [StringComparison]::Ordinal)) { continue }
            if ($end -lt $text.Length -and $text[$end] -match '[A-Za-z0-9._-]') { continue }
            $null = $builder.Append($pair.To)
            $i = $end
            break
        }
    }
    return $builder.ToString()
}

function Copy-NSOwnerTemplate {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][string]$Workspace
    )
    $text = [IO.File]::ReadAllText($Source)
    $text = $text.Replace('$NIGHTSHIFT_WORKSPACE', $Workspace)
    $ns = Join-Path $Workspace.TrimEnd('\', '/') '.nightshift'
    $text = $text.Replace('$NS', $ns)
    [IO.File]::WriteAllText($Destination, $text, $script:NSUtf8NoBom)
}

# What Setup scaffolds, and what waits until something needs it: the order Hunt stages, or the
# product-evolution notebook a product item is cut into. Mirrors runtime/scaffold.sh.
$script:NSScaffoldDefault = @('punch-list', 'parking-lot', 'snag-log', 'drafting-table')
$script:NSScaffoldOnRequest = @('work-orders', 'opportunity-map', 'product-research')

# Get-NSScaffoldKeys <names> - the state keys a scaffold call names: every default file for none,
# `product` for both product files. Throws for a name scaffold does not write on request.
function Get-NSScaffoldKeys {
    param([AllowEmptyCollection()][string[]]$Names = @())
    if ($null -eq $Names -or $Names.Count -eq 0) { return , $script:NSScaffoldDefault }
    $keys = New-Object Collections.Generic.List[string]
    foreach ($name in $Names) {
        if ($name -ceq 'product') {
            $keys.Add('opportunity-map')
            $keys.Add('product-research')
        }
        elseif ($script:NSScaffoldOnRequest -ccontains $name) {
            $keys.Add($name)
        }
        else {
            throw "$name is not a file scaffold writes on request (work-orders, product)"
        }
    }
    return , $keys.ToArray()
}

# Write-NSScaffoldFile <workspace> <key> - one state file, copied from its template or holding one
# line, unless the name is taken. Returns `wrote <path>` or `kept <path>`, relative to .nightshift/.
function Write-NSScaffoldFile {
    param(
        [Parameter(Mandatory = $true)][string]$Workspace,
        [Parameter(Mandatory = $true)][string]$Key,
        [string]$Template = '',
        [string]$Line = ''
    )
    $ns = Join-Path $Workspace '.nightshift'
    $rel = Get-NSLayoutRelativePath $ns $Key
    if ($rel.Length -eq 0) { return '' }
    $dest = Get-NSLayoutPath $ns $Key
    # A name that is already taken is the owner's, whatever it holds and whatever kind of file it is.
    if (Test-NSPathEntry $dest) { return "kept $rel" }
    New-NSLayoutParent $ns $Key
    try {
        # The owner's copy carries resolved paths: a person pasting a command out of their own
        # punch list has no `$NS`. The shipped template is never changed.
        if ($Template.Length -gt 0) { Copy-NSOwnerTemplate -Source $Template -Destination $dest -Workspace $Workspace }
        else { [IO.File]::WriteAllText($dest, $Line + "`n", $script:NSUtf8NoBom) }
    }
    catch {
        Remove-NSFile $dest
        throw "cannot write $dest"
    }
    return "wrote $rel"
}

