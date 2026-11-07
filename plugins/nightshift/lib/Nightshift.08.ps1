# Alive-but-idle. The same rule as lib/idle.sh: a live worker is stopped and revived
# only after idleWindowMinutes of a stale pulse, an unchanged transcript, under a
# second of CPU across its process tree, and no build, test, or browser child.
# Two failed recoveries write one notice and stop retrying.

$script:NSIdleWork = '^(make|gmake|ninja|cmake|xcodebuild|gradle|mvn|mvnw|tsc|webpack|esbuild|rollup|vite|cargo|go|docker|podman|npm|pnpm|yarn|bun|bats|pytest|py\.test|jest|vitest|mocha|phpunit|rspec|ctest|playwright|chrome|chromium|firefox|safari|msedge|google-chrome|chromium-browser)$'
$script:NSIdleCpuMin = 100

function Get-NSIdleWindowMinutes {
    param([Parameter(Mandatory = $true)][string]$Workspace)
    $raw = ''
    if (-not [string]::IsNullOrEmpty($env:NIGHTSHIFT_IDLE_WINDOW)) {
        $raw = [string]$env:NIGHTSHIFT_IDLE_WINDOW
    }
    else {
        try { $raw = [string](Get-NSRule $Workspace 'idleWindowMinutes' '') } catch { $raw = '' }
    }
    if ($raw -notmatch '^[1-9][0-9]*$') { return 30 }
    return [int]$raw
}

function Format-NSIdleCpu {
    param([long]$Centi)
    $sign = '+'
    if ($Centi -lt 0) {
        $sign = '-'
        $Centi = -$Centi
    }
    $whole = [long][Math]::Floor($Centi / 100)
    $frac = [long]($Centi % 100)
    return ('{0}{1}.{2}s' -f $sign, $whole, $frac.ToString('00'))
}

function Test-NSIdleDescendant {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Parent,
        [int]$Root,
        [int]$Candidate
    )
    $current = $Candidate
    for ($hop = 0; $hop -lt 64; $hop++) {
        if ($current -eq $Root) { return $true }
        if (-not $Parent.ContainsKey($current)) { return $false }
        $next = [int]$Parent[$current]
        if ($next -eq $current -or $next -le 0) { return $false }
        $current = $next
    }
    return $false
}

function Get-NSIdleVerdict {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('stale', 'fresh')][string]$Pulse,
        [int]$Changed = 0,
        [int]$Known = 0,
        [long]$Delta = 0,
        [int]$Busy = 0,
        [AllowEmptyString()][string]$Since = '',
        [long]$Now = 0,
        [int]$Window = 30,
        [int]$Stuck = 0
    )
    if ($Stuck -eq 1) { return 'stuck' }
    if ($Pulse -eq 'fresh') { return 'busy' }
    if ($Changed -eq 1) { return 'busy' }
    if ($Known -ne 1) { return 'unavailable' }
    if ($Busy -eq 1) { return 'busy' }
    if ($Since -notmatch '^[0-9]+$') { return 'pending' }
    if ($Delta -lt 0 -or $Delta -ge $script:NSIdleCpuMin) { return 'busy' }
    if ($Window -le 0) { $Window = 30 }
    if (($Now - [long]$Since) -ge ([long]$Window * 60)) { return 'due' }
    return 'pending'
}

function Test-NSIdleWorkName {
    param([AllowEmptyString()][string]$Name)
    if ([string]::IsNullOrEmpty($Name)) { return $false }
    $base = $Name
    if ($base.Contains('\') -or $base.Contains('/')) { $base = Split-Path -Leaf $base }
    if ($base.EndsWith('.exe', [StringComparison]::OrdinalIgnoreCase)) {
        $base = $base.Substring(0, $base.Length - 4)
    }
    return $base -match $script:NSIdleWork
}

function Get-NSIdlePath {
    param([Parameter(Mandatory = $true)][string]$NightshiftDir)
    return (Get-NSLayoutPath $NightshiftDir 'idle-watch')
}

function Read-NSIdleState {
    param([Parameter(Mandatory = $true)][string]$NightshiftDir)
    $state = [ordered]@{
        Since = ''; Cpu = ''; Bytes = ''; Pids = ''; Fails = 0; Episode = 0
        Stuck = 0; Noticed = 0; Evidence = ''
    }
    $path = Get-NSIdlePath $NightshiftDir
    if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or (Test-NSReparsePoint $path)) {
        return [pscustomobject]$state
    }
    foreach ($line in [IO.File]::ReadAllLines($path)) {
        $cut = $line.IndexOf('=')
        if ($cut -lt 1) { continue }
        $key = $line.Substring(0, $cut)
        $val = $line.Substring($cut + 1)
        switch ($key) {
            'since' { $state.Since = $val }
            'cpu' { $state.Cpu = $val }
            'bytes' { $state.Bytes = $val }
            'pids' { $state.Pids = $val }
            'fails' { if ($val -match '^[0-9]+$') { $state.Fails = [int]$val } }
            'episode' { if ($val -eq '1') { $state.Episode = 1 } }
            'stuck' { if ($val -eq '1') { $state.Stuck = 1 } }
            'noticed' { if ($val -eq '1') { $state.Noticed = 1 } }
            'evidence' { $state.Evidence = $val }
        }
    }
    return [pscustomobject]$state
}

function Write-NSIdleState {
    param(
        [Parameter(Mandatory = $true)][string]$NightshiftDir,
        [Parameter(Mandatory = $true)]$State
    )
    $path = Get-NSIdlePath $NightshiftDir
    $dir = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $lines = @(
        ('since=' + $State.Since),
        ('cpu=' + $State.Cpu),
        ('bytes=' + $State.Bytes),
        ('pids=' + $State.Pids),
        ('fails=' + $State.Fails),
        ('episode=' + $State.Episode),
        ('stuck=' + $State.Stuck),
        ('noticed=' + $State.Noticed),
        ('evidence=' + $State.Evidence)
    )
    [IO.File]::WriteAllLines($path, $lines, $script:NSUtf8NoBom)
}

function Clear-NSIdleWatch {
    param([Parameter(Mandatory = $true)][string]$NightshiftDir)
    $path = Get-NSIdlePath $NightshiftDir
    if ((Test-Path -LiteralPath $path) -and -not (Test-NSReparsePoint $path)) {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }
}

function Test-NSIdleRevivalBlocked {
    param([Parameter(Mandatory = $true)][string]$NightshiftDir)
    return ((Read-NSIdleState $NightshiftDir).Stuck -eq 1)
}

function Update-NSIdleAfterRevival {
    param(
        [Parameter(Mandatory = $true)][string]$NightshiftDir,
        [Parameter(Mandatory = $true)][ValidateSet('revived', 'failed')][string]$Result
    )
    $state = Read-NSIdleState $NightshiftDir
    if ($Result -eq 'revived') {
        Clear-NSIdleWatch $NightshiftDir
        return 'clear'
    }
    if ($state.Episode -ne 1) { return 'ignore' }
    if ($state.Stuck -eq 1) { return 'stuck' }
    $state.Fails = [int]$state.Fails + 1
    if ($state.Fails -ge 2) {
        $state.Stuck = 1
        $state.Noticed = 1
        Write-NSIdleState $NightshiftDir $state
        Write-NSReason -NightshiftDir $NightshiftDir -Code 'idle-stuck' -Detail 'two recoveries failed'
        Write-NSControlLog $NightshiftDir ('watchman: idle recovery failed twice ' + [char]0x2014 + ' one notice, no further retries')
        Add-NSWatchmanNotice $NightshiftDir 'an idle worker was stopped and revival failed twice. The watchman will not try again until that worker is busy again or the shift is started again.'
        return 'stuck'
    }
    Write-NSIdleState $NightshiftDir $state
    return 'counted'
}

function Get-NSIdleStatusSentence {
    param([Parameter(Mandatory = $true)][string]$NightshiftDir)
    $state = Read-NSIdleState $NightshiftDir
    if ($state.Stuck -eq 1 -or $state.Since -notmatch '^[0-9]+$' -or [string]::IsNullOrEmpty($state.Evidence)) {
        return ''
    }
    $alive = $false
    foreach ($pidText in ($state.Pids -split '\s+')) {
        if ($pidText -match '^[1-9][0-9]*$') {
            try {
                $null = Get-Process -Id ([int]$pidText) -ErrorAction Stop
                $alive = $true
            }
            catch { }
        }
    }
    if (-not $alive) { return '' }
    $mins = [int](([Math]::Floor(((Get-NSUnixTime) - [long]$state.Since) / 60)))
    if ($mins -lt 0) { return '' }
    return ('worker alive but idle for {0} min {1} {2}' -f $mins, [char]0x2014, $state.Evidence)
}

function Get-NSIdleProtected {
    param([int]$ProcessId)
    if ($ProcessId -le 4) { return $true }
    if ($ProcessId -eq $PID) { return $true }
    $current = $PID
    for ($i = 0; $i -lt 16; $i++) {
        if ($current -eq $ProcessId) { return $true }
        if ($current -le 4) { return $false }
        try {
            $parent = (Get-CimInstance Win32_Process -Filter "ProcessId=$current" -ErrorAction Stop).ParentProcessId
        }
        catch { return $false }
        if ($null -eq $parent) { return $false }
        $current = [int]$parent
    }
    return $false
}

function Get-NSIdleTreeSample {
    param([Parameter(Mandatory = $true)][int[]]$ProcessIds)
    $known = 1
    $busy = 0
    $cpu = [long]0
    try {
        $rows = @(Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId, Name -ErrorAction Stop)
    }
    catch {
        return [pscustomobject]@{ Cpu = 0; Known = 0; Busy = 0 }
    }
    $parent = @{}
    $name = @{}
    foreach ($row in $rows) {
        $parent[[int]$row.ProcessId] = [int]$row.ParentProcessId
        $name[[int]$row.ProcessId] = [string]$row.Name
    }
    $walk = @{}
    $queue = New-Object System.Collections.Generic.Queue[int]
    foreach ($root in $ProcessIds) {
        if (-not $parent.ContainsKey($root)) { $known = 0; continue }
        if ($walk.ContainsKey($root)) { continue }
        $walk[$root] = $true
        $queue.Enqueue($root)
    }
    if ($queue.Count -eq 0) {
        return [pscustomobject]@{ Cpu = 0; Known = 0; Busy = 0 }
    }
    while ($queue.Count -gt 0) {
        $id = $queue.Dequeue()
        try {
            $proc = Get-Process -Id $id -ErrorAction Stop
            $cpu += [long][Math]::Round($proc.TotalProcessorTime.TotalSeconds * 100)
        }
        catch { $known = 0 }
        if ((Test-NSIdleWorkName $name[$id])) { $busy = 1 }
        foreach ($child in @($parent.Keys)) {
            if ($parent[$child] -eq $id -and -not $walk.ContainsKey($child)) {
                $walk[$child] = $true
                $queue.Enqueue([int]$child)
            }
        }
    }
    return [pscustomobject]@{ Cpu = $cpu; Known = $known; Busy = $busy }
}

function Stop-NSIdleTree {
    param([Parameter(Mandatory = $true)][int[]]$ProcessIds)
    $grace = 5
    if ($env:NIGHTSHIFT_IDLE_GRACE -match '^[0-9]+$') { $grace = [int]$env:NIGHTSHIFT_IDLE_GRACE }
    $targets = New-Object System.Collections.Generic.List[int]
    foreach ($root in $ProcessIds) {
        if (Get-NSIdleProtected $root) { return $false }
        try {
            $rows = @(Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId -ErrorAction Stop)
        }
        catch { return $false }
        $parent = @{}
        foreach ($row in $rows) { $parent[[int]$row.ProcessId] = [int]$row.ParentProcessId }
        $queue = New-Object System.Collections.Generic.Queue[int]
        $seen = @{}
        if (-not $parent.ContainsKey($root)) { return $false }
        $queue.Enqueue($root)
        $seen[$root] = $true
        while ($queue.Count -gt 0) {
            $id = $queue.Dequeue()
            if (Get-NSIdleProtected $id) { return $false }
            if (-not $targets.Contains($id)) { $targets.Add($id) }
            foreach ($child in @($parent.Keys)) {
                if ($parent[$child] -eq $id -and -not $seen.ContainsKey($child)) {
                    $seen[$child] = $true
                    $queue.Enqueue([int]$child)
                }
            }
        }
    }
    if ($targets.Count -eq 0) { return $false }
    for ($i = $targets.Count - 1; $i -ge 0; $i--) {
        Stop-Process -Id $targets[$i] -ErrorAction SilentlyContinue
    }
    if ($grace -gt 0) { Start-Sleep -Seconds $grace }
    $alive = @()
    foreach ($id in $targets) {
        if (Get-Process -Id $id -ErrorAction SilentlyContinue) { $alive += $id }
    }
    foreach ($id in $alive) {
        Stop-Process -Id $id -Force -ErrorAction SilentlyContinue
    }
    for ($n = 0; $n -lt 10; $n++) {
        $left = $false
        foreach ($id in $targets) {
            if (Get-Process -Id $id -ErrorAction SilentlyContinue) { $left = $true }
        }
        if (-not $left) { return $true }
        Start-Sleep -Milliseconds 100
    }
    return $false
}

# standby, revive, hold, unavailable, stuck
function Invoke-NSIdleTake {
    param(
        [Parameter(Mandatory = $true)][string]$NightshiftDir,
        [Parameter(Mandatory = $true)][string]$Workspace,
        [AllowEmptyString()][string]$TranscriptPath = '',
        [bool]$PulseStale = $false,
        [Parameter(Mandatory = $true)][ValidateSet('claude', 'codex', 'cursor')][string]$HostName
    )
    $state = Read-NSIdleState $NightshiftDir
    if ($state.Stuck -eq 1) { return 'stuck' }
    $pulse = 'fresh'
    if ($PulseStale) { $pulse = 'stale' }
    $bytes = 0
    if (-not [string]::IsNullOrEmpty($TranscriptPath) -and (Test-Path -LiteralPath $TranscriptPath -PathType Leaf)) {
        try { $bytes = ([IO.File]::ReadAllBytes($TranscriptPath)).Length } catch { $bytes = 0 }
    }
    $changed = 0
    if ($state.Since -match '^[0-9]+$' -and ([string]$state.Bytes) -ne ([string]$bytes)) { $changed = 1 }
    $ids = New-Object System.Collections.Generic.List[int]
    $session = Read-NSSession $NightshiftDir
    if ($null -ne $session -and $session.ProcessId -match '^[1-9][0-9]*$' -and (Test-NSRecordedProcess $session.ProcessId $session.Start) -eq 'Alive') {
        $ids.Add([int]$session.ProcessId)
    }
    $lease = Read-NSLease $NightshiftDir
    if ($null -ne $lease -and $lease.ProcessId -match '^[1-9][0-9]*$' -and (Test-NSRecordedProcess $lease.ProcessId $lease.Start) -eq 'Alive') {
        if (-not $ids.Contains([int]$lease.ProcessId)) { $ids.Add([int]$lease.ProcessId) }
    }
    $now = Get-NSUnixTime
    $window = Get-NSIdleWindowMinutes $Workspace
    if ($ids.Count -eq 0) {
        $verdict = Get-NSIdleVerdict -Pulse $pulse -Changed $changed -Known 1 -Delta 0 -Busy 0 -Since $state.Since -Now $now -Window $window -Stuck 0
    }
    else {
        # A host process outside the worker tree means stand by. Windows has no
        # portable cwd, so any other process of that name counts; POSIX also
        # requires the working directory to be this project.
        if ($HostName -in @('claude', 'codex')) {
            $outside = $false
            try {
                $hostRows = @(Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId -ErrorAction Stop)
            }
            catch { $hostRows = @() }
            if ($hostRows.Count -gt 0) {
                $hostParent = @{}
                foreach ($row in $hostRows) { $hostParent[[int]$row.ProcessId] = [int]$row.ParentProcessId }
                foreach ($proc in @(Get-Process -Name $HostName -ErrorAction SilentlyContinue)) {
                    $inTree = $false
                    foreach ($id in $ids) {
                        if (Test-NSIdleDescendant -Parent $hostParent -Root $id -Candidate $proc.Id) {
                            $inTree = $true
                        }
                    }
                    if (-not $inTree) { $outside = $true }
                }
            }
            if ($outside) { return 'standby' }
        }
        $sample = Get-NSIdleTreeSample -ProcessIds @($ids.ToArray())
        $delta = [long]0
        if ($state.Cpu -match '^-?[0-9]+$' -and $sample.Known -eq 1) {
            $delta = [long]$sample.Cpu - [long]$state.Cpu
        }
        $verdict = Get-NSIdleVerdict -Pulse $pulse -Changed $changed -Known $sample.Known -Delta $delta -Busy $sample.Busy -Since $state.Since -Now $now -Window $window -Stuck 0
        if ($verdict -in @('pending', 'due') -and [string]::IsNullOrEmpty($state.Cpu)) { $state.Cpu = [string]$sample.Cpu }
        $state.Pids = ($ids -join ' ')
    }
    switch ($verdict) {
        'busy' { Clear-NSIdleWatch $NightshiftDir; return 'standby' }
        'unavailable' { return 'unavailable' }
        'stuck' { return 'stuck' }
        'pending' {
            if ($state.Since -notmatch '^[0-9]+$') { $state.Since = [string]$now }
            if ([string]::IsNullOrEmpty([string]$state.Bytes)) { $state.Bytes = [string]$bytes }
            if ($ids.Count -eq 0) {
                $state.Evidence = 'pulse stale, transcript unchanged, no recorded process'
            }
            else {
                $state.Evidence = "pulse stale, transcript unchanged, cpu $(Format-NSIdleCpu $delta), no busy child"
            }
            Write-NSIdleState $NightshiftDir $state
            return 'standby'
        }
        'due' {
            if ($state.Since -notmatch '^[0-9]+$') { $state.Since = [string]$now }
            $mins = [int]([Math]::Floor(($now - [long]$state.Since) / 60))
            if ($mins -lt 1) { $mins = 1 }
            if ($ids.Count -eq 0) {
                $state.Evidence = 'pulse stale, transcript unchanged, no recorded process'
                $state.Episode = 1
                Write-NSIdleState $NightshiftDir $state
                Write-NSControlLog $NightshiftDir ("watchman: worker quiet for $mins min $([char]0x2014) $($state.Evidence) $([char]0x2014) reviving")
                return 'revive'
            }
            $state.Evidence = "pulse stale, transcript unchanged, cpu $(Format-NSIdleCpu $delta), no busy child"
            Write-NSControlLog $NightshiftDir ("watchman: worker alive but idle for $mins min $([char]0x2014) $($state.Evidence) $([char]0x2014) stopping it and reviving")
            if (Stop-NSIdleTree -ProcessIds @($ids.ToArray())) {
                $state.Episode = 1
                Write-NSIdleState $NightshiftDir $state
                return 'revive'
            }
            Write-NSControlLog $NightshiftDir ('watchman: idle worker could not be stopped ' + [char]0x2014 + ' not reviving beside it')
            return 'hold'
        }
    }
    return 'standby'
}
