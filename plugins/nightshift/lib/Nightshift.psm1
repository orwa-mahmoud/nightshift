Set-StrictMode -Version 2.0

$script:NSStateVersion = 1
$script:NSUtf8NoBom = New-Object System.Text.UTF8Encoding($false)
$script:NSRulesCacheStamp = ''
$script:NSRulesCache = $null

function Test-NSWindows {
    return [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
}

# Windows PowerShell 5.1's [Console]::In is the console host, not redirected
# stdin. With -File the host often parks the pipe on $input instead. Read both.
function Get-NSStdinText {
    param([AllowEmptyString()][string]$Piped = '')
    $text = $Piped
    if ([string]::IsNullOrWhiteSpace($text)) {
        $utf8 = New-Object Text.UTF8Encoding $false
        try {
            [Console]::InputEncoding = $utf8
        }
        catch {
        }
        try {
            $stream = [Console]::OpenStandardInput()
            if ($null -ne $stream) {
                $reader = New-Object IO.StreamReader($stream, $utf8, $true)
                try {
                    $text = $reader.ReadToEnd()
                }
                finally {
                    $reader.Dispose()
                }
            }
        }
        catch {
            $text = ''
        }
    }
    if (-not [string]::IsNullOrEmpty($text) -and [int][char]$text[0] -eq 0xFEFF) {
        $text = $text.Substring(1)
    }
    return $text
}

function Test-NSPathEntry {
    param([Parameter(Mandatory = $true)][string]$Path)
    try {
        $null = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        return $true
    }
    catch {
        return $false
    }
}

# rm -f: delete a file, succeed if it is already gone, never prompt. Remove-Item
# on a non-empty directory asks for confirmation; a headless host then throws
# NullReferenceException from ShouldContinue.
function Remove-NSFile {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return
    }
    try {
        [IO.File]::Delete($Path)
    }
    catch {
    }
}

function Test-NSReparsePoint {
    param([Parameter(Mandatory = $true)][string]$Path)
    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        return [bool]($item.Attributes -band [IO.FileAttributes]::ReparsePoint)
    }
    catch {
        return $false
    }
}

function Resolve-NSCanonicalPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    $resolved = Resolve-Path -LiteralPath $Path -ErrorAction Stop
    return [IO.Path]::GetFullPath($resolved.ProviderPath)
}

function Test-NSScratchPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    $normalized = $Path.TrimEnd('\', '/').Replace('\', '/')
    return [bool]($normalized -match '^/workspace/scratch(?:/|$)')
}

function Get-NSWorkMode {
    param([Parameter(Mandatory = $true)][string]$Workspace)
    $record = Join-Path $Workspace '.nightshift/work-mode'
    if (Test-NSReparsePoint $record) {
        throw 'work mode is malformed'
    }
    if (-not (Test-Path -LiteralPath $record -PathType Leaf)) {
        return 'repository'
    }
    $lines = [IO.File]::ReadAllLines($record)
    if ($lines.Count -lt 1) {
        throw 'work mode is unreadable'
    }
    $mode = $lines[0].Trim()
    if ($mode -notin @('repository', 'artifact')) {
        throw 'work mode is malformed'
    }
    return $mode
}

function Write-NSWorkMode {
    param(
        [Parameter(Mandatory = $true)][string]$Workspace,
        [Parameter(Mandatory = $true)][ValidateSet('repository', 'artifact')][string]$Mode
    )
    $ns = Join-Path $Workspace '.nightshift'
    $null = New-Item -ItemType Directory -Path $ns -Force
    $null = Write-NSAtomicLines -Path (Join-Path $ns 'work-mode') -Lines @($Mode)
}

function Get-NSProposedWorkMode {
    param([Parameter(Mandatory = $true)][string]$Workspace)
    $project = Resolve-NSCanonicalPath $Workspace
    if (Test-NSScratchPath $project) {
        throw 'disposable scratch workspaces are refused'
    }
    $top = Invoke-NSGit $project @('rev-parse', '--show-toplevel')
    if (-not [string]::IsNullOrWhiteSpace($top)) {
        return 'repository'
    }
    foreach ($child in Get-ChildItem -LiteralPath $project -Directory -Force -ErrorAction SilentlyContinue) {
        if ($child.Name.StartsWith('.')) {
            continue
        }
        if ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            continue
        }
        $candidate = Invoke-NSGit $child.FullName @('rev-parse', '--show-toplevel')
        if (-not [string]::IsNullOrWhiteSpace($candidate)) {
            return 'repository'
        }
    }
    return 'artifact'
}

function Resolve-NSWorkspaceRoot {
    param([Parameter(Mandatory = $true)][string]$HostRoot)

    $hostPath = Resolve-NSCanonicalPath $HostRoot
    $link = Join-Path $hostPath '.nightshift-link'
    if (-not (Test-NSPathEntry $link)) {
        return $hostPath
    }
    if ((Test-NSReparsePoint $link) -or -not (Test-Path -LiteralPath $link -PathType Leaf)) {
        throw 'invalid .nightshift-link'
    }

    $lines = [IO.File]::ReadAllLines($link)
    if ($lines.Count -ne 1 -or [string]::IsNullOrWhiteSpace($lines[0])) {
        throw 'invalid .nightshift-link'
    }
    $target = $lines[0]
    if (-not [IO.Path]::IsPathRooted($target)) {
        throw 'invalid .nightshift-link'
    }

    $workspace = Resolve-NSCanonicalPath $target
    if (-not (Test-Path -LiteralPath (Join-Path $workspace '.nightshift') -PathType Container)) {
        throw 'invalid .nightshift-link'
    }
    return $workspace
}

# Windows PowerShell 5.1 turns redirected native stderr into ErrorRecords. With
# $ErrorActionPreference=Stop, `git ... 2>$null` then aborts - including CRLF
# warnings and "unknown revision 'HEAD'" on an unborn branch.
function Invoke-NSGitCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Directory,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Arguments
    )
    $previous = $ErrorActionPreference
    $hadNative = Test-Path Variable:PSNativeCommandUseErrorActionPreference
    $previousNative = $false
    if ($hadNative) {
        $previousNative = $PSNativeCommandUseErrorActionPreference
        $PSNativeCommandUseErrorActionPreference = $false
    }
    $ErrorActionPreference = 'Continue'
    try {
        $output = & git -C $Directory @Arguments 2>&1
        $code = $LASTEXITCODE
        if ($null -eq $code) {
            $code = 1
        }
        $lines = [Collections.Generic.List[string]]::new()
        foreach ($item in @($output)) {
            if ($null -eq $item) {
                continue
            }
            $text = [string]$item
            if (-not [string]::IsNullOrEmpty($text)) {
                $lines.Add($text)
            }
        }
        return [pscustomobject]@{
            ExitCode = [int]$code
            Text     = ($lines -join "`n")
            Lines    = $lines.ToArray()
        }
    }
    catch {
        return [pscustomobject]@{
            ExitCode = 127
            Text     = [string]$_.Exception.Message
            Lines    = @()
        }
    }
    finally {
        $ErrorActionPreference = $previous
        if ($hadNative) {
            $PSNativeCommandUseErrorActionPreference = $previousNative
        }
    }
}

function Invoke-NSGit {
    param(
        [Parameter(Mandatory = $true)][string]$Directory,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )
    $result = Invoke-NSGitCommand $Directory $Arguments
    if ($result.ExitCode -ne 0) {
        return $null
    }
    return (($result.Lines | Select-Object -First 1) -as [string]).Trim()
}

function Get-NSGitDiffText {
    param(
        [Parameter(Mandatory = $true)][string]$Repository,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )
    $result = Invoke-NSGitCommand $Repository $Arguments
    if ($result.ExitCode -eq 0) {
        return [string]$result.Text
    }
    return $null
}

function Resolve-NSWorkTarget {
    param([Parameter(Mandatory = $true)][string]$Workspace)

    $project = Resolve-NSCanonicalPath $Workspace
    $mode = Get-NSWorkMode $project
    $record = Join-Path $project '.nightshift/work-target'
    if (Test-NSReparsePoint $record) {
        throw 'work target is unreadable'
    }
    if (Test-Path -LiteralPath $record -PathType Leaf) {
        $lines = [IO.File]::ReadAllLines($record)
        if ($lines.Count -lt 1 -or [string]::IsNullOrWhiteSpace($lines[0])) {
            throw 'work target is unreadable'
        }
        $target = $lines[0]
        if (-not [IO.Path]::IsPathRooted($target)) {
            $target = Join-Path $project $target
        }
        $folder = Resolve-NSCanonicalPath $target
        if (Test-NSScratchPath $folder) {
            throw 'work target is a disposable scratch workspace'
        }
        if ($mode -eq 'artifact') {
            if (-not (Test-Path -LiteralPath $folder -PathType Container)) {
                throw 'work target is not a directory'
            }
            return $folder
        }
        $top = Invoke-NSGit $target @('rev-parse', '--show-toplevel')
        if ([string]::IsNullOrWhiteSpace($top)) {
            throw 'work target is not a Git repository'
        }
        return (Resolve-NSCanonicalPath $top)
    }

    if ($mode -eq 'artifact') {
        if (Test-NSScratchPath $project) {
            throw 'work target is a disposable scratch workspace'
        }
        return $project
    }

    $top = Invoke-NSGit $project @('rev-parse', '--show-toplevel')
    if (-not [string]::IsNullOrWhiteSpace($top)) {
        return (Resolve-NSCanonicalPath $top)
    }

    $found = $null
    foreach ($child in Get-ChildItem -LiteralPath $project -Directory -Force -ErrorAction SilentlyContinue) {
        if ($child.Name.StartsWith('.')) {
            continue
        }
        if ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            continue
        }
        $candidate = Invoke-NSGit $child.FullName @('rev-parse', '--show-toplevel')
        if ([string]::IsNullOrWhiteSpace($candidate)) {
            continue
        }
        $candidate = Resolve-NSCanonicalPath $candidate
        if ($null -ne $found -and $found -ne $candidate) {
            throw 'several child repositories require an explicit work target'
        }
        $found = $candidate
    }
    if ($null -eq $found) {
        throw 'no Git work target found'
    }
    return $found
}

function Write-NSWorkTarget {
    param(
        [Parameter(Mandatory = $true)][string]$Workspace,
        [Parameter(Mandatory = $true)][string]$Repository,
        [ValidateSet('repository', 'artifact')][string]$Mode = 'repository'
    )
    $top = $null
    if ($Mode -eq 'artifact') {
        $top = Resolve-NSCanonicalPath $Repository
        if (-not (Test-Path -LiteralPath $top -PathType Container)) {
            throw 'work target is not a directory'
        }
        if (Test-NSScratchPath $top) {
            throw 'work target is a disposable scratch workspace'
        }
    }
    else {
        $gitTop = Invoke-NSGit $Repository @('rev-parse', '--show-toplevel')
        if ([string]::IsNullOrWhiteSpace($gitTop)) {
            throw 'work target is not a Git repository'
        }
        $top = Resolve-NSCanonicalPath $gitTop
        if (Test-NSScratchPath $top) {
            throw 'work target is a disposable scratch workspace'
        }
    }
    $ns = Join-Path $Workspace '.nightshift'
    $null = New-Item -ItemType Directory -Path $ns -Force
    Write-NSWorkMode $Workspace $Mode
    $null = Write-NSAtomicLines -Path (Join-Path $ns 'work-target') -Lines @($top)
}

function Get-NSReceiptsDir {
    param([Parameter(Mandatory = $true)][string]$Workspace)
    return (Join-Path $Workspace '.nightshift/receipts')
}

function Test-NSUsableReceiptsDir {
    param([Parameter(Mandatory = $true)][string]$Workspace)
    $dir = Get-NSReceiptsDir $Workspace
    return ((Test-Path -LiteralPath $dir -PathType Container) -and -not (Test-NSReparsePoint $dir))
}

function Get-NSFileSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-NSReceiptSlug {
    param([AllowEmptyString()][string]$Text)
    $s = ([string]$Text).ToLowerInvariant() -replace '[^a-z0-9]+', '-'
    $s = $s.Trim('-')
    if ($s.Length -gt 40) {
        $s = $s.Substring(0, 40).TrimEnd('-')
    }
    if ([string]::IsNullOrEmpty($s)) {
        $s = 'item'
    }
    return $s
}

function Get-NSReceiptsCount {
    param([Parameter(Mandatory = $true)][string]$Workspace)
    $dir = Get-NSReceiptsDir $Workspace
    if (-not (Test-NSUsableReceiptsDir $Workspace)) {
        return 0
    }
    return @(Get-ChildItem -LiteralPath $dir -File -Force -ErrorAction SilentlyContinue |
        Where-Object {
            -not $_.Name.StartsWith('.') -and
            -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint)
        }).Count
}

function Get-NSLatestReceipt {
    param([Parameter(Mandatory = $true)][string]$Workspace)
    $dir = Get-NSReceiptsDir $Workspace
    if (-not (Test-NSUsableReceiptsDir $Workspace)) {
        return $null
    }
    $files = @(Get-ChildItem -LiteralPath $dir -File -Force -ErrorAction SilentlyContinue |
        Where-Object {
            -not $_.Name.StartsWith('.') -and
            -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint)
        })
    if ($files.Count -eq 0) {
        return $null
    }
    # LastWriteTime first. Same-second uniqueness suffixes (`stamp-slug-n.md`)
    # sort before `stamp-slug.md` by name (`-` < `.`); map `.md` -> `-0.md` so
    # the unsuffixed sibling sorts first and `-n` wins the tie.
    $latest = @($files | Sort-Object @{
            Expression = { $_.LastWriteTimeUtc.Ticks }
        }, @{
            Expression = {
                if ($_.Name -like '*.md') {
                    $_.Name.Substring(0, $_.Name.Length - 3) + '-0.md'
                }
                else {
                    $_.Name
                }
            }
        })[-1]
    return $latest.FullName
}

function Get-NSReceiptsFingerprint {
    param([Parameter(Mandatory = $true)][string]$Workspace)
    $dir = Get-NSReceiptsDir $Workspace
    if (-not (Test-NSUsableReceiptsDir $Workspace)) {
        return 'none'
    }
    $files = @(Get-ChildItem -LiteralPath $dir -File -Force -ErrorAction SilentlyContinue |
        Where-Object {
            -not $_.Name.StartsWith('.') -and
            -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint)
        } |
        Sort-Object { $_.FullName })
    if ($files.Count -eq 0) {
        return 'none'
    }
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $utf8 = New-Object Text.UTF8Encoding $false
        foreach ($file in $files) {
            $line = '{0} {1}{2}' -f (Get-NSFileSha256 $file.FullName), $file.Name, "`n"
            $bytes = $utf8.GetBytes($line)
            [void]$sha.TransformBlock($bytes, 0, $bytes.Length, $null, 0)
        }
        [void]$sha.TransformFinalBlock([byte[]]@(), 0, 0)
        return (([BitConverter]::ToString($sha.Hash)) -replace '-', '').ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function Get-NSWorkTargetHead {
    param([Parameter(Mandatory = $true)][string]$Workspace)
    try {
        $target = Resolve-NSWorkTarget $Workspace
        $head = Invoke-NSGit $target @('rev-parse', 'HEAD')
        if (-not [string]::IsNullOrWhiteSpace($head)) {
            return $head
        }
    }
    catch {
    }
    return 'nohead'
}

function Get-NSProgressToken {
    param([Parameter(Mandatory = $true)][string]$Workspace)
    $mode = 'repository'
    try {
        $mode = Get-NSWorkMode $Workspace
    }
    catch {
        $mode = 'repository'
    }
    $token = if ($mode -eq 'artifact') {
        Get-NSReceiptsFingerprint $Workspace
    }
    else {
        Get-NSWorkTargetHead $Workspace
    }
    $checkpoint = Get-NSGateCheckpointToken $Workspace
    return ($token + ':' + $checkpoint)
}

function Get-NSGateCheckpointToken {
    param([Parameter(Mandatory = $true)][string]$Workspace)
    $last = ''
    foreach ($record in (Get-NSEvidenceLedgerRecords $Workspace)) {
        if ((Get-NSRecordText $record 'domain') -ceq 'checkpoint') {
            $id = Get-NSRecordText $record 'id'
            if ($id.Length -gt 0) { $last = $id }
        }
    }
    if ($last.Length -eq 0) { return 'none' }
    return $last
}

function Get-NSEvidenceCountSummary {
    param([Parameter(Mandatory = $true)][string]$Workspace)
    $findings = 0; $open = 0; $baseline = 0; $checkpoint = 0
    foreach ($record in (Get-NSEvidenceLedgerRecords $Workspace)) {
        $findings++
        switch (Get-NSRecordText $record 'domain') {
            'baseline' { $baseline++ }
            'checkpoint' { $checkpoint++ }
        }
        if ((Get-NSRecordText $record 'status') -ceq 'open') { $open++ }
    }
    return ('findings={0} open={1} baseline={2} checkpoint={3}' -f $findings, $open, $baseline, $checkpoint)
}

function Get-NSStatusLiveness {
    param(
        [Parameter(Mandatory = $true)][string]$Workspace,
        [int]$WatchMinutes = 0
    )
    $ns = Join-Path $Workspace '.nightshift'
    $pulse = Join-Path $ns '.shift-pulse'
    if (-not (Test-NSPathEntry $pulse)) { return 'absent' }
    if (Test-NSReparsePoint $pulse) { return 'absent' }
    try {
        $line = ([IO.File]::ReadAllText($pulse, $script:NSUtf8NoBom)).Trim()
        $epochText = ($line -split '\s+', 2)[0]
        if ($epochText -notmatch '^\d+$') { return 'absent' }
        $epoch = [long]$epochText
        $window = $WatchMinutes * 120
        if ($window -le 0) { $window = 1200 }
        if ((Get-NSUnixTime) - $epoch -lt $window) { return 'fresh' }
        return 'stale'
    }
    catch {
        return 'absent'
    }
}

function Get-NSStatusLastActivity {
    param([Parameter(Mandatory = $true)][string]$Workspace)
    $ns = Join-Path $Workspace '.nightshift'
    $pulse = Join-Path $ns '.shift-pulse'
    if (-not (Test-NSPathEntry $pulse) -or (Test-NSReparsePoint $pulse)) { return '' }
    try {
        $line = ([IO.File]::ReadAllText($pulse, $script:NSUtf8NoBom)).Trim()
        return ($line -split '\s+', 2)[0]
    }
    catch {
        return ''
    }
}

function Get-NSStatusStallAttempts {
    param([Parameter(Mandatory = $true)][string]$Workspace)
    $stall = Join-Path (Join-Path $Workspace '.nightshift') '.stall'
    if (-not (Test-NSPathEntry $stall) -or (Test-NSReparsePoint $stall)) { return 0 }
    try {
        $lines = [IO.File]::ReadAllLines($stall, $script:NSUtf8NoBom)
        if ($lines.Length -lt 2) { return 0 }
        $n = $lines[1].Trim()
        if ($n -match '^\d+$') { return [int]$n }
    }
    catch {
    }
    return 0
}

function Invoke-NSEvidenceArchive {
    param(
        [Parameter(Mandatory = $true)][string]$Workspace,
        [AllowEmptyString()][string]$ShiftId = ''
    )
    $paths = Get-NSEvidencePaths $Workspace
    $jsonl = $paths['jsonl']
    if (-not (Test-NSPathEntry $jsonl) -or (Test-NSReparsePoint $jsonl)) { return 0 }
    $info = Get-Item -LiteralPath $jsonl
    if ($info.Length -le 0) { return 0 }
    if ([string]::IsNullOrEmpty($ShiftId)) {
        $state = Get-NSShiftPolicyState $Workspace
        if ($state['state'] -ceq 'valid') { $ShiftId = [string]$state['policy']['shiftId'] }
    }
    if ([string]::IsNullOrEmpty($ShiftId)) { $ShiftId = 'unknown' }
    $date = (Get-Date -Format 'yyyy-MM-dd')
    $archiveRoot = Join-NSPath (Join-Path $Workspace '.nightshift') 'archive'
    $directory = Join-NSPath $archiveRoot $date
    foreach ($candidate in @($archiveRoot, $directory)) {
        if (Test-NSReparsePoint $candidate) { return 2 }
    }
    $null = [IO.Directory]::CreateDirectory($directory)
    $destination = Join-NSPath $directory ('findings-' + $ShiftId + '.jsonl')
    Copy-Item -LiteralPath $jsonl -Destination $destination -Force
    [IO.File]::WriteAllText($jsonl, '', $script:NSUtf8NoBom)
    Write-Output $destination
    return 0
}

function Write-NSStatusReport {
    param([Parameter(Mandatory = $true)][string]$Workspace)
    $ns = Join-Path $Workspace '.nightshift'
    if (-not (Test-Path -LiteralPath $ns -PathType Container)) {
        Write-Output 'Nightshift Status'
        Write-Output ('Nightshift: missing at ' + $Workspace)
        return 0
    }
    $punch = Join-Path $ns 'punch-list.md'
    $open = 0; $ticked = 0
    if (Test-NSPathEntry $punch) {
        $counts = Get-NSBoxCounts $punch
        $open = [int]$counts.Open
        $ticked = [int]$counts.Ticked
    }
    $armed = Test-NSPathEntry (Join-Path $ns '.shift-armed')
    $watch = 0
    try { $watch = [int](Get-NSRule $Workspace 'watchMinutes' '') } catch { $watch = 0 }
    Write-Output 'Nightshift Status'
    Write-Output ('Workspace:   ' + $Workspace)
    Write-Output ('Shift:       ' + ($(if ($armed) { 'armed' } else { 'not armed' })))
    Write-Output ('Items:       open=' + $open + ' ticked=' + $ticked)
    Write-Output ('evidence:    ' + (Get-NSEvidenceCountSummary $Workspace))
    Write-Output ('liveness:    ' + (Get-NSStatusLiveness $Workspace $watch))
    $activity = Get-NSStatusLastActivity $Workspace
    Write-Output ('last activity: ' + ($(if ($activity.Length -gt 0) { $activity } else { 'none' })))
    Write-Output ('last checkpoint: ' + (Get-NSGateCheckpointToken $Workspace))
    Write-Output ('stall attempts: ' + (Get-NSStatusStallAttempts $Workspace))
    Write-Output ''
    Write-Output 'resolved policy'
    $table = Resolve-NSPolicy -Workspace $Workspace -Table
    if ([string]::IsNullOrEmpty($table)) { Write-Output 'none' }
    else { Write-Output $table }
    Write-Output ''
    Write-Output 'preflight gaps'
    $preflight = Get-NSPreflightNeeds $Workspace
    if ([string]::IsNullOrEmpty($preflight)) { Write-Output 'none' }
    else { Write-Output $preflight }
    return 0
}

function Get-NSStateKind {
    param([Parameter(Mandatory = $true)][string]$Workspace)

    $ns = Join-Path $Workspace '.nightshift'
    if (-not (Test-Path -LiteralPath $ns -PathType Container)) {
        return 'absent'
    }
    $marker = Join-Path $ns 'state-version'
    if (-not (Test-NSPathEntry $marker)) {
        return 'legacy'
    }
    if ((Test-NSReparsePoint $marker) -or -not (Test-Path -LiteralPath $marker -PathType Leaf)) {
        return 'malformed'
    }
    try {
        $lines = [IO.File]::ReadAllLines($marker)
    }
    catch {
        return 'malformed'
    }
    if ($lines.Count -ne 1 -or $lines[0] -notmatch '^(0|[1-9][0-9]{0,7})$') {
        return 'malformed'
    }
    $version = [int]$lines[0]
    if ($version -gt $script:NSStateVersion) {
        return 'future'
    }
    if ($version -eq $script:NSStateVersion) {
        return 'current'
    }
    return 'legacy'
}

function Get-NSStateRefuseMessage {
    param([Parameter(Mandatory = $true)][string]$Kind)
    if ($Kind -eq 'future') {
        return "Nightshift state-version is newer than this plugin supports (supported: $script:NSStateVersion). Upgrade Nightshift; never rewrite or downgrade the marker."
    }
    if ($Kind -eq 'malformed') {
        return 'Nightshift state-version is malformed. Inspect it only while unarmed; never guess a version.'
    }
    return 'Nightshift state-version is unsupported.'
}

function Get-NSRulesObject {
    param([Parameter(Mandatory = $true)][string]$Workspace)
    $path = Join-Path $Workspace '.nightshift/rules.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        $script:NSRulesCacheStamp = ''
        $script:NSRulesCache = $null
        return $null
    }
    try {
        $item = Get-Item -LiteralPath $path -ErrorAction Stop
        $stamp = '{0}:{1}:{2}' -f $item.FullName, $item.Length, $item.LastWriteTimeUtc.Ticks
        if ($script:NSRulesCacheStamp -eq $stamp) {
            return $script:NSRulesCache
        }
        $parsed = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $script:NSRulesCacheStamp = $stamp
        $script:NSRulesCache = $parsed
        return $parsed
    }
    catch {
        $script:NSRulesCacheStamp = ''
        $script:NSRulesCache = $null
        return $null
    }
}

function Get-NSRule {
    param(
        [Parameter(Mandatory = $true)][string]$Workspace,
        [Parameter(Mandatory = $true)][string]$Key,
        [AllowEmptyString()][string]$Override = ''
    )
    if (-not [string]::IsNullOrEmpty($Override)) {
        return $Override
    }
    $rules = Get-NSRulesObject $Workspace
    if ($null -eq $rules) {
        return ''
    }
    $property = $rules.PSObject.Properties[$Key]
    if ($null -eq $property -or $null -eq $property.Value) {
        return ''
    }
    if ($property.Value -is [string] -or $property.Value -is [ValueType]) {
        return [string]$property.Value
    }
    return ($property.Value | ConvertTo-Json -Compress -Depth 20)
}

function Get-NSToolRules {
    param(
        [Parameter(Mandatory = $true)][string]$Workspace,
        [AllowEmptyString()][string]$Override = ''
    )
    try {
        if (-not [string]::IsNullOrEmpty($Override)) {
            $map = $Override | ConvertFrom-Json -ErrorAction Stop
        }
        else {
            $rules = Get-NSRulesObject $Workspace
            if ($null -eq $rules) {
                return $null
            }
            $property = $rules.PSObject.Properties['toolDeny']
            if ($null -eq $property) {
                return [pscustomobject]@{}
            }
            $map = $property.Value
        }
        if ($null -eq $map -or $map -is [Array] -or $map -is [string] -or $map -is [ValueType]) {
            throw 'invalid toolDeny'
        }
        foreach ($property in $map.PSObject.Properties) {
            if ($property.Value -isnot [string]) {
                throw 'invalid toolDeny'
            }
        }
        return $map
    }
    catch {
        throw 'toolDeny is not a JSON object of string values'
    }
}

function Get-NSBoxCounts {
    param([Parameter(Mandatory = $true)][string]$PunchList)
    $open = 0
    $ticked = 0
    $inItems = $false
    $readable = $true
    if (Test-Path -LiteralPath $PunchList -PathType Leaf) {
        try {
            foreach ($line in [IO.File]::ReadLines($PunchList)) {
                if (-not $inItems) {
                    if ($line -match '^## Items\s*$') {
                        $inItems = $true
                    }
                    continue
                }
                if ($line -match '^\s*-\s*\[\s\]') {
                    $open++
                }
                elseif ($line -match '^\s*-\s*\[[xX]\]') {
                    $ticked++
                }
            }
        }
        catch {
            $readable = $false
            $open = 0
            $ticked = 0
        }
    }
    return [pscustomobject]@{ Open = $open; Ticked = $ticked; Total = ($open + $ticked); Readable = $readable }
}

function Get-NSOpenBoxesInFile {
    param([Parameter(Mandatory = $true)][string]$Path)
    $open = 0
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        foreach ($line in [IO.File]::ReadLines($Path)) {
            if ($line -match '^\s*-\s*\[\s\]') {
                $open++
            }
        }
    }
    return $open
}

function Get-NSOpenDrafts {
    param([Parameter(Mandatory = $true)][string]$Path)
    $open = 0
    $seenRule = $false
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        foreach ($line in [IO.File]::ReadLines($Path)) {
            if (-not $seenRule) {
                if ($line -match '^---\s*$') {
                    $seenRule = $true
                }
                continue
            }
            if ($line -match '^\s*-\s*\[\s\]') {
                $open++
            }
        }
    }
    return $open
}

function Get-NSCodexIdentityKind {
    param([AllowEmptyString()][string]$SessionId)
    if ([string]::IsNullOrEmpty($SessionId)) {
        return 'missing'
    }
    if ($SessionId -match '[\s/\\$`;|&<>*]') {
        return 'malformed'
    }
    if ($SessionId -match '^(thread_|conv_|chatgpt-|rollout-|task_|scratch_)' `
        -or $SessionId -in @('local', 'unknown')) {
        return 'unsupported'
    }
    if ($SessionId -match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' `
        -or $SessionId -match '^[0-9a-fA-F]{32,}$') {
        return 'resumable'
    }
    return 'unsupported'
}

function New-NSPrivateFileSecurity {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $system = [Security.Principal.SecurityIdentifier]::new(
        [Security.Principal.WellKnownSidType]::LocalSystemSid,
        $null
    )
    $acl = New-Object Security.AccessControl.FileSecurity
    $acl.SetOwner($identity)
    $acl.SetAccessRuleProtection($true, $false)
    $allow = [Security.AccessControl.AccessControlType]::Allow
    $rights = [Security.AccessControl.FileSystemRights]::FullControl
    $null = $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($identity, $rights, $allow))
    $null = $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($system, $rights, $allow))
    return $acl
}

function Protect-NSPrivateFile {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-NSWindows)) {
        return
    }
    $acl = New-NSPrivateFileSecurity
    Set-Acl -LiteralPath $Path -AclObject $acl -ErrorAction Stop
}

function Write-NSAtomicLines {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Lines,
        [switch]$Private,
        [switch]$CreateOnly
    )
    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        throw 'destination directory does not exist'
    }
    $leaf = Split-Path -Leaf $Path
    $tempLeaf = if ($leaf.StartsWith('.')) {
        '{0}.tmp.{1}.{2}' -f $leaf, $PID, [guid]::NewGuid().ToString('N')
    }
    else {
        '.{0}.tmp.{1}.{2}' -f $leaf, $PID, [guid]::NewGuid().ToString('N')
    }
    $temp = $null
    if (-not $CreateOnly) {
        $temp = Join-Path $directory $tempLeaf
    }
    $writePath = if ($CreateOnly) { $Path } else { $temp }
    if ($CreateOnly -and (Test-NSPathEntry $Path)) {
        return $false
    }
    $encoding = New-Object System.Text.UTF8Encoding $false
    $createdHere = $false
    try {
        $stream = $null
        $writer = $null
        try {
            $stream = [IO.FileStream]::new(
                $writePath,
                [IO.FileMode]::CreateNew,
                [IO.FileAccess]::Write,
                [IO.FileShare]::None
            )
            $createdHere = $true
            $writer = [IO.StreamWriter]::new($stream, $encoding)
            $writer.NewLine = "`n"
            foreach ($line in $Lines) {
                $writer.WriteLine($line)
            }
            $writer.Flush()
        }
        catch [IO.IOException] {
            if ($CreateOnly -and -not $createdHere -and (Test-NSPathEntry $Path)) {
                return $false
            }
            throw
        }
        finally {
            if ($null -ne $writer) {
                $writer.Dispose()
            }
            elseif ($null -ne $stream) {
                $stream.Dispose()
            }
        }
        if ($Private) {
            try {
                Protect-NSPrivateFile $writePath
            }
            catch {
            }
        }
        if ($CreateOnly) {
            return $true
        }
        if (Test-NSPathEntry $Path) {
            if (Test-NSReparsePoint $Path) {
                throw 'refusing to replace a reparse point'
            }
            # .NET Core File.Replace rejects a null backup path; delete the spare after the swap.
            $backup = Join-Path $directory ('{0}.bak.{1}' -f $tempLeaf, [guid]::NewGuid().ToString('N'))
            [IO.File]::Replace($temp, $Path, $backup)
            Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue
        }
        else {
            [IO.File]::Move($temp, $Path)
        }
        $temp = $null
        return $true
    }
    catch {
        if ($CreateOnly -and $createdHere -and (Test-NSPathEntry $Path)) {
            Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
        }
        throw
    }
    finally {
        if ($null -ne $temp -and (Test-Path -LiteralPath $temp -PathType Leaf)) {
            Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-NSProcessStart {
    param([Parameter(Mandatory = $true)][int]$ProcessId)
    try {
        $process = Get-Process -Id $ProcessId -ErrorAction Stop
        return $process.StartTime.ToUniversalTime().ToString('o')
    }
    catch {
        return ''
    }
}

function Test-NSRecordedProcess {
    param(
        [AllowEmptyString()][string]$ProcessId,
        [AllowEmptyString()][string]$Start = ''
    )
    if ($ProcessId -notmatch '^[1-9][0-9]*$') {
        return 'Malformed'
    }
    try {
        $process = Get-Process -Id ([int]$ProcessId) -ErrorAction Stop
    }
    catch [Microsoft.PowerShell.Commands.ProcessCommandException] {
        return 'Dead'
    }
    catch {
        return 'Unavailable'
    }
    if (-not [string]::IsNullOrEmpty($Start)) {
        try {
            $current = $process.StartTime.ToUniversalTime().ToString('o')
        }
        catch {
            return 'Unavailable'
        }
        if ($current -ne $Start) {
            return 'Dead'
        }
    }
    return 'Alive'
}

function Get-NSHostProcess {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('claude', 'codex', 'cursor')][string]$HostName,
        [int]$StartingProcessId = $PID
    )
    try {
        $records = @(Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId, Name -ErrorAction Stop)
    }
    catch {
        return $null
    }
    $byId = @{}
    foreach ($record in $records) {
        $byId[[int]$record.ProcessId] = $record
    }
    $current = $StartingProcessId
    for ($i = 0; $i -lt 8; $i++) {
        if ($current -le 1) {
            break
        }
        $record = $byId[$current]
        if ($null -eq $record) {
            return $null
        }
        $name = [IO.Path]::GetFileNameWithoutExtension([string]$record.Name)
        if ($name -ieq $HostName) {
            return [pscustomobject]@{
                Id = [string]$record.ProcessId
                Start = Get-NSProcessStart ([int]$record.ProcessId)
            }
        }
        $current = [int]$record.ParentProcessId
    }
    return $null
}

function Protect-NSMutexScopeReceipt {
    param([Parameter(Mandatory = $true)][string]$NightshiftDir)

    $receiptGit = Join-Path $NightshiftDir '.git'
    if (-not (Test-Path -LiteralPath $receiptGit -PathType Container)) {
        return $true
    }
    $exclude = Join-Path $receiptGit 'info/exclude'
    if ((Test-NSPathEntry $exclude) -and
        ((Test-NSReparsePoint $exclude) -or -not (Test-Path -LiteralPath $exclude -PathType Leaf))) {
        return $false
    }
    try {
        $lines = [Collections.Generic.List[string]]::new()
        if (Test-Path -LiteralPath $exclude -PathType Leaf) {
            $lines.AddRange([string[]][IO.File]::ReadAllLines($exclude))
        }
        $changed = $false
        foreach ($entry in @('.mutex-scope', '.mutex-scope.tmp.*')) {
            if (-not $lines.Contains($entry)) {
                $lines.Add($entry)
                $changed = $true
            }
        }
        if ($changed) {
            $null = Write-NSAtomicLines -Path $exclude -Lines $lines.ToArray()
        }
        $removed = Invoke-NSGitCommand $NightshiftDir @(
            'rm', '-r', '--cached', '--quiet', '--force', '--ignore-unmatch', '--',
            '.mutex-scope', '.mutex-scope.tmp.*'
        )
        return $removed.ExitCode -eq 0
    }
    catch {
        return $false
    }
}

function Get-NSMutexScope {
    param([Parameter(Mandatory = $true)][string]$NightshiftDir)

    if (-not (Protect-NSMutexScopeReceipt $NightshiftDir)) {
        return ''
    }
    $path = Join-Path $NightshiftDir '.mutex-scope'
    if (-not (Test-NSPathEntry $path)) {
        $bytes = New-Object byte[] 16
        $rng = New-Object Security.Cryptography.RNGCryptoServiceProvider
        try {
            $rng.GetBytes($bytes)
        }
        finally {
            $rng.Dispose()
        }
        $candidate = ([BitConverter]::ToString($bytes)).Replace('-', '').ToLowerInvariant()
        try {
            $null = Write-NSAtomicLines -Path $path -Lines @($candidate) -Private -CreateOnly
        }
        catch {
            return ''
        }
    }
    if ((Test-NSReparsePoint $path) -or -not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return ''
    }
    try {
        try {
            Protect-NSPrivateFile $path
        }
        catch {
        }
        $lines = [IO.File]::ReadAllLines($path)
    }
    catch {
        return ''
    }
    if ($lines.Count -ne 1 -or $lines[0] -notmatch '^[a-f0-9]{32}$') {
        return ''
    }
    return $lines[0]
}

function New-NSMutexSecurity {
    $acl = New-Object Security.AccessControl.MutexSecurity
    $acl.SetAccessRuleProtection($true, $false)
    $allow = [Security.AccessControl.AccessControlType]::Allow
    $rights = [Security.AccessControl.MutexRights]::FullControl
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $system = [Security.Principal.SecurityIdentifier]::new(
        [Security.Principal.WellKnownSidType]::LocalSystemSid,
        $null
    )
    $null = $acl.AddAccessRule([Security.AccessControl.MutexAccessRule]::new($identity, $rights, $allow))
    $null = $acl.AddAccessRule([Security.AccessControl.MutexAccessRule]::new($system, $rights, $allow))
    return $acl
}

function Enter-NSMutex {
    param(
        [Parameter(Mandatory = $true)][string]$NightshiftDir,
        [Parameter(Mandatory = $true)][string]$Name,
        [ValidateRange(0, 30000)][int]$TimeoutMilliseconds = 2000
    )
    $workspaceScope = Get-NSMutexScope $NightshiftDir
    if ([string]::IsNullOrEmpty($workspaceScope)) {
        return $null
    }
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $scope = $workspaceScope + '|' + $Name
        $digest = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($scope))
        $suffix = ([BitConverter]::ToString($digest, 0, 16)).Replace('-', '')
    }
    finally {
        $sha.Dispose()
    }
    $mutexName = if (Test-NSWindows) { "Global\Nightshift-$suffix" } else { "Nightshift-$suffix" }
    $mutex = $null
    try {
        $created = $false
        if (Test-NSWindows) {
            $mutexSecurity = New-NSMutexSecurity
            if ($PSVersionTable.PSVersion.Major -lt 6) {
                $mutex = [Threading.Mutex]::new(
                    $false,
                    $mutexName,
                    [ref]$created,
                    $mutexSecurity
                )
            }
            else {
                $mutex = [Threading.MutexAcl]::Create(
                    $false,
                    $mutexName,
                    [ref]$created,
                    $mutexSecurity
                )
            }
        }
        else {
            $mutex = New-Object Threading.Mutex($false, $mutexName, [ref]$created)
        }
        try {
            $acquired = $mutex.WaitOne($TimeoutMilliseconds)
        }
        catch [Threading.AbandonedMutexException] {
            $acquired = $true
        }
        if (-not $acquired) {
            $mutex.Dispose()
            return $null
        }
        return $mutex
    }
    catch {
        if ($null -ne $mutex) {
            $mutex.Dispose()
        }
        return $null
    }
}

function Exit-NSMutex {
    param([AllowNull()][Threading.Mutex]$Mutex)
    if ($null -eq $Mutex) {
        return
    }
    try {
        $Mutex.ReleaseMutex()
    }
    finally {
        $Mutex.Dispose()
    }
}

function Test-NSSafeLine {
    param([AllowEmptyString()][string]$Value)
    return $Value.IndexOfAny([char[]]"`r`n") -lt 0
}

function Claim-NSSession {
    param(
        [Parameter(Mandatory = $true)][string]$NightshiftDir,
        [Parameter(Mandatory = $true)][string]$SessionId,
        [AllowEmptyString()][string]$Transcript = '',
        [AllowEmptyString()][string]$ProcessId = '',
        [AllowEmptyString()][string]$Start = '',
        [Parameter(Mandatory = $true)][ValidateSet('claude', 'codex', 'cursor')][string]$HostName
    )
    if ([string]::IsNullOrEmpty($SessionId)) {
        return $false
    }
    foreach ($value in @($SessionId, $Transcript, $ProcessId, $Start)) {
        if (-not (Test-NSSafeLine $value)) {
            return $false
        }
    }
    if ($ProcessId -notmatch '^[0-9]*$') {
        return $false
    }
    try {
        $path = Join-Path $NightshiftDir '.shift-session'
        if (Test-NSReparsePoint $path) {
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        }
        return Write-NSAtomicLines -Path $path `
            -Lines @($SessionId, $Transcript, $ProcessId, $Start, $HostName) -Private -CreateOnly
    }
    catch {
        return $false
    }
}

function Read-NSSession {
    param([Parameter(Mandatory = $true)][string]$NightshiftDir)
    $path = Join-Path $NightshiftDir '.shift-session'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or (Test-NSReparsePoint $path)) {
        return $null
    }
    try {
        $lines = [IO.File]::ReadAllLines($path)
    }
    catch {
        return $null
    }
    if ($lines.Count -lt 1 -or $lines.Count -gt 5 -or [string]::IsNullOrEmpty($lines[0])) {
        return $null
    }
    $values = @('', '', '', '', 'claude')
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $values[$i] = $lines[$i]
    }
    if ($values[2] -notmatch '^[0-9]*$' -or $values[4] -notin @('claude', 'codex', 'cursor')) {
        return $null
    }
    return [pscustomobject]@{
        SessionId = $values[0]
        Transcript = $values[1]
        ProcessId = $values[2]
        Start = $values[3]
        HostName = $values[4]
    }
}

function Test-NSClaudeForeignCursorSurface {
    param(
        [Parameter(Mandatory = $true)][string]$NightshiftDir,
        [AllowEmptyString()][string]$Transcript = ''
    )
    if ($Transcript -match '[/\\]\.cursor([/\\]|$)') {
        return $true
    }
    $session = Read-NSSession $NightshiftDir
    return ($null -ne $session -and $session.HostName -eq 'cursor')
}

function Write-NSSession {
    param(
        [Parameter(Mandatory = $true)][string]$NightshiftDir,
        [Parameter(Mandatory = $true)][string]$SessionId,
        [AllowEmptyString()][string]$Transcript = '',
        [AllowEmptyString()][string]$ProcessId = '',
        [AllowEmptyString()][string]$Start = '',
        [Parameter(Mandatory = $true)][ValidateSet('claude', 'codex', 'cursor')][string]$HostName
    )
    foreach ($value in @($SessionId, $Transcript, $ProcessId, $Start)) {
        if (-not (Test-NSSafeLine $value)) {
            return $false
        }
    }
    if ([string]::IsNullOrEmpty($SessionId) -or $ProcessId -notmatch '^[0-9]*$') {
        return $false
    }
    try {
        $path = Join-Path $NightshiftDir '.shift-session'
        if (Test-NSReparsePoint $path) {
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        }
        return Write-NSAtomicLines -Path $path `
            -Lines @($SessionId, $Transcript, $ProcessId, $Start, $HostName) -Private
    }
    catch {
        return $false
    }
}

function Read-NSLease {
    param([Parameter(Mandatory = $true)][string]$NightshiftDir)
    $path = Join-Path $NightshiftDir '.shift-lease'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or (Test-NSReparsePoint $path)) {
        return $null
    }
    try {
        $lines = [IO.File]::ReadAllLines($path)
    }
    catch {
        return $null
    }
    if ($lines.Count -ne 6) {
        return $null
    }
    foreach ($line in $lines) {
        if (-not (Test-NSSafeLine $line)) {
            return $null
        }
    }
    if ($lines[1] -notin @('claude', 'codex', 'cursor') -or $lines[2] -notmatch '^[1-9][0-9]*$' `
        -or $lines[3] -notmatch '^[A-Za-z0-9._-]*$' -or $lines[4] -notmatch '^[0-9]*$') {
        return $null
    }
    if ([string]::IsNullOrEmpty($lines[4]) -and -not [string]::IsNullOrEmpty($lines[5])) {
        return $null
    }
    if ([string]::IsNullOrEmpty($lines[0]) -and [string]::IsNullOrEmpty($lines[3])) {
        return $null
    }
    return [pscustomobject]@{
        SessionId = $lines[0]
        HostName = $lines[1]
        Generation = [int]$lines[2]
        Nonce = $lines[3]
        ProcessId = $lines[4]
        Start = $lines[5]
    }
}

function Write-NSLease {
    param(
        [Parameter(Mandatory = $true)][string]$NightshiftDir,
        [AllowEmptyString()][string]$SessionId,
        [Parameter(Mandatory = $true)][ValidateSet('claude', 'codex', 'cursor')][string]$HostName,
        [Parameter(Mandatory = $true)][int]$Generation,
        [AllowEmptyString()][string]$Nonce,
        [AllowEmptyString()][string]$ProcessId,
        [AllowEmptyString()][string]$Start
    )
    if ($Generation -lt 1 -or $Nonce -notmatch '^[A-Za-z0-9._-]*$' -or $ProcessId -notmatch '^[0-9]*$') {
        return $false
    }
    foreach ($value in @($SessionId, $Start)) {
        if (-not (Test-NSSafeLine $value)) {
            return $false
        }
    }
    if ([string]::IsNullOrEmpty($SessionId) -and [string]::IsNullOrEmpty($Nonce)) {
        return $false
    }
    if ([string]::IsNullOrEmpty($ProcessId) -and -not [string]::IsNullOrEmpty($Start)) {
        return $false
    }
    try {
        return Write-NSAtomicLines -Path (Join-Path $NightshiftDir '.shift-lease') `
            -Lines @($SessionId, $HostName, [string]$Generation, $Nonce, $ProcessId, $Start) -Private
    }
    catch {
        return $false
    }
}

function Claim-NSInitialLease {
    param(
        [Parameter(Mandatory = $true)][string]$NightshiftDir,
        [Parameter(Mandatory = $true)][string]$SessionId,
        [Parameter(Mandatory = $true)][ValidateSet('claude', 'codex', 'cursor')][string]$HostName,
        [AllowEmptyString()][string]$ProcessId = '',
        [AllowEmptyString()][string]$Start = ''
    )
    $mutex = Enter-NSMutex $NightshiftDir '.lease-lock.d'
    if ($null -eq $mutex) {
        return $false
    }
    try {
        $path = Join-Path $NightshiftDir '.shift-lease'
        if (Test-NSPathEntry $path) {
            return $null -ne (Read-NSLease $NightshiftDir)
        }
        return Write-NSLease $NightshiftDir $SessionId $HostName 1 '' $ProcessId $Start
    }
    finally {
        Exit-NSMutex $mutex
    }
}

function New-NSLeaseNonce {
    param(
        [Parameter(Mandatory = $true)][string]$HostName,
        [Parameter(Mandatory = $true)][int]$Generation
    )
    $bytes = New-Object byte[] 18
    $rng = New-Object Security.Cryptography.RNGCryptoServiceProvider
    try {
        $rng.GetBytes($bytes)
    }
    finally {
        $rng.Dispose()
    }
    $random = [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    return "$HostName.$Generation.$PID.$random"
}

function Takeover-NSLease {
    param(
        [Parameter(Mandatory = $true)][string]$NightshiftDir,
        [AllowEmptyString()][string]$SessionId = '',
        [Parameter(Mandatory = $true)][ValidateSet('claude', 'codex', 'cursor')][string]$HostName
    )
    $mutex = Enter-NSMutex $NightshiftDir '.lease-lock.d'
    if ($null -eq $mutex) {
        return $null
    }
    try {
        $generation = 0
        $path = Join-Path $NightshiftDir '.shift-lease'
        if (Test-NSPathEntry $path) {
            $lease = Read-NSLease $NightshiftDir
            if ($null -eq $lease) {
                return $null
            }
            if (-not [string]::IsNullOrEmpty($lease.SessionId)) {
                $SessionId = $lease.SessionId
            }
            $generation = $lease.Generation
        }
        $generation++
        $nonce = New-NSLeaseNonce $HostName $generation
        if (-not (Write-NSLease $NightshiftDir $SessionId $HostName $generation $nonce '' '')) {
            return $null
        }
        return [pscustomobject]@{ Generation = $generation; Nonce = $nonce }
    }
    finally {
        Exit-NSMutex $mutex
    }
}

function Test-NSLeaseNonce {
    param(
        [Parameter(Mandatory = $true)][string]$NightshiftDir,
        [Parameter(Mandatory = $true)][ValidateSet('claude', 'codex', 'cursor')][string]$HostName,
        [AllowEmptyString()][string]$Nonce,
        [AllowEmptyString()][string]$Generation
    )
    if ([string]::IsNullOrEmpty($Nonce) -or $Generation -notmatch '^[1-9][0-9]*$') {
        return $false
    }
    $lease = Read-NSLease $NightshiftDir
    return $null -ne $lease -and $lease.HostName -eq $HostName `
        -and $lease.Generation -eq [int]$Generation -and $lease.Nonce -eq $Nonce
}

function Bind-NSLeaseSession {
    param(
        [Parameter(Mandatory = $true)][string]$NightshiftDir,
        [Parameter(Mandatory = $true)][string]$SessionId,
        [Parameter(Mandatory = $true)][ValidateSet('claude', 'codex', 'cursor')][string]$HostName,
        [Parameter(Mandatory = $true)][string]$Nonce,
        [Parameter(Mandatory = $true)][string]$Generation
    )
    $mutex = Enter-NSMutex $NightshiftDir '.lease-lock.d'
    if ($null -eq $mutex) {
        return $false
    }
    try {
        if (-not (Test-NSLeaseNonce $NightshiftDir $HostName $Nonce $Generation)) {
            return $false
        }
        $lease = Read-NSLease $NightshiftDir
        $scope = $lease.SessionId
        if ([string]::IsNullOrEmpty($scope)) {
            $scope = $SessionId
        }
        return Write-NSLease $NightshiftDir $scope $HostName $lease.Generation $lease.Nonce $lease.ProcessId $lease.Start
    }
    finally {
        Exit-NSMutex $mutex
    }
}

function Attach-NSLeaseProcess {
    param(
        [Parameter(Mandatory = $true)][string]$NightshiftDir,
        [Parameter(Mandatory = $true)][ValidateSet('claude', 'codex', 'cursor')][string]$HostName,
        [Parameter(Mandatory = $true)][string]$Nonce,
        [Parameter(Mandatory = $true)][string]$Generation,
        [Parameter(Mandatory = $true)][string]$ProcessId,
        [AllowEmptyString()][string]$Start = ''
    )
    $mutex = Enter-NSMutex $NightshiftDir '.lease-lock.d'
    if ($null -eq $mutex) {
        return $false
    }
    try {
        if (-not (Test-NSLeaseNonce $NightshiftDir $HostName $Nonce $Generation)) {
            return $false
        }
        $lease = Read-NSLease $NightshiftDir
        return Write-NSLease $NightshiftDir $lease.SessionId $HostName $lease.Generation $lease.Nonce $ProcessId $Start
    }
    finally {
        Exit-NSMutex $mutex
    }
}

function Restore-NSLeaseInteractive {
    param([Parameter(Mandatory = $true)][string]$NightshiftDir)
    $mutex = Enter-NSMutex $NightshiftDir '.lease-lock.d'
    if ($null -eq $mutex) {
        return $false
    }
    try {
        $lease = Read-NSLease $NightshiftDir
        if ($null -eq $lease) {
            return $false
        }
        if ([string]::IsNullOrEmpty($lease.Nonce)) {
            return $true
        }
        if (-not [string]::IsNullOrEmpty($lease.ProcessId)) {
            if ((Test-NSRecordedProcess $lease.ProcessId $lease.Start) -ne 'Dead') {
                return $false
            }
        }
        if ([string]::IsNullOrEmpty($lease.SessionId)) {
            $path = Join-Path $NightshiftDir '.shift-lease'
            Remove-NSFile $path
            return -not (Test-NSPathEntry $path)
        }
        # Empty pid: the recorded session id may reclaim. Copying a still-live
        # recorded pid would fence that conversation's next tool process.
        return Write-NSLease $NightshiftDir $lease.SessionId $lease.HostName ($lease.Generation + 1) '' '' ''
    }
    finally {
        Exit-NSMutex $mutex
    }
}

function Test-NSLeaseAllows {
    param(
        [Parameter(Mandatory = $true)][string]$NightshiftDir,
        [AllowEmptyString()][string]$SessionId,
        [Parameter(Mandatory = $true)][ValidateSet('claude', 'codex', 'cursor')][string]$HostName,
        [AllowEmptyString()][string]$ProcessId = '',
        [AllowEmptyString()][string]$Start = '',
        [AllowEmptyString()][string]$Nonce = '',
        [AllowEmptyString()][string]$Generation = ''
    )
    $lease = Read-NSLease $NightshiftDir
    if ($null -eq $lease) {
        return 'Invalid'
    }
    if ($lease.HostName -ne $HostName) {
        return 'Deny'
    }
    if (-not [string]::IsNullOrEmpty($lease.Nonce)) {
        if ($lease.Nonce -eq $Nonce -and [string]$lease.Generation -eq $Generation) {
            return 'Allow'
        }
        return 'Deny'
    }
    if ($lease.SessionId -ne $SessionId -or -not [string]::IsNullOrEmpty($Nonce) `
        -or -not [string]::IsNullOrEmpty($Generation)) {
        return 'Deny'
    }
    if ([string]::IsNullOrEmpty($lease.ProcessId)) {
        return 'Allow'
    }
    if ($lease.ProcessId -eq $ProcessId -and (Test-NSRecordedProcess $lease.ProcessId $lease.Start) -eq 'Alive') {
        return 'Allow'
    }
    if ([string]::IsNullOrEmpty($ProcessId) -or (Test-NSRecordedProcess $lease.ProcessId $lease.Start) -ne 'Dead') {
        return 'Deny'
    }

    $mutex = Enter-NSMutex $NightshiftDir '.lease-lock.d'
    if ($null -eq $mutex) {
        return 'Deny'
    }
    try {
        $current = Read-NSLease $NightshiftDir
        if ($null -eq $current -or $current.SessionId -ne $SessionId -or $current.HostName -ne $HostName `
            -or $current.Generation -ne $lease.Generation -or -not [string]::IsNullOrEmpty($current.Nonce) `
            -or (Test-NSRecordedProcess $current.ProcessId $current.Start) -ne 'Dead') {
            return 'Deny'
        }
        if (Write-NSLease $NightshiftDir $SessionId $HostName ($current.Generation + 1) '' $ProcessId $Start) {
            return 'Allow'
        }
        return 'Deny'
    }
    finally {
        Exit-NSMutex $mutex
    }
}

# The recorded conversation reclaims a lease a dead revival attempt left behind. The
# generation and nonce it presented must still be the ones on disk and the recorded pid
# must still read dead, re-checked under the lock, or a second caller could steal a lease
# that changed underneath it. Returns the new generation, or $null when the reclaim lost
# a race.
function Reclaim-NSLeaseRecorded {
    param(
        [Parameter(Mandatory = $true)][string]$NightshiftDir,
        [Parameter(Mandatory = $true)][ValidateSet('claude', 'codex', 'cursor')][string]$HostName,
        [Parameter(Mandatory = $true)][string]$SessionId,
        [Parameter(Mandatory = $true)][int]$OldGeneration,
        [Parameter(Mandatory = $true)][string]$OldNonce,
        [AllowEmptyString()][string]$ProcessId = '',
        [AllowEmptyString()][string]$Start = ''
    )
    $mutex = Enter-NSMutex $NightshiftDir '.lease-lock.d'
    if ($null -eq $mutex) {
        return $null
    }
    try {
        $lease = Read-NSLease $NightshiftDir
        if ($null -eq $lease -or $lease.HostName -ne $HostName -or $lease.Generation -ne $OldGeneration `
            -or $lease.Nonce -ne $OldNonce -or [string]::IsNullOrEmpty($lease.Nonce) `
            -or [string]::IsNullOrEmpty($lease.ProcessId)) {
            return $null
        }
        if ((Test-NSRecordedProcess $lease.ProcessId $lease.Start) -ne 'Dead') {
            return $null
        }
        $newGeneration = $lease.Generation + 1
        if (-not (Write-NSLease $NightshiftDir $SessionId $HostName $newGeneration '' $ProcessId $Start)) {
            return $null
        }
        return $newGeneration
    }
    finally {
        Exit-NSMutex $mutex
    }
}

function Release-NSLease {
    param([Parameter(Mandatory = $true)][string]$NightshiftDir)
    $mutex = Enter-NSMutex $NightshiftDir '.lease-lock.d'
    if ($null -eq $mutex) {
        return $false
    }
    try {
        $path = Join-Path $NightshiftDir '.shift-lease'
        Remove-NSFile $path
        return -not (Test-NSPathEntry $path)
    }
    catch {
        return $false
    }
    finally {
        Exit-NSMutex $mutex
    }
}

function Reset-NSStaleLease {
    param([Parameter(Mandatory = $true)][string]$NightshiftDir)
    $mutex = Enter-NSMutex $NightshiftDir '.lease-lock.d'
    if ($null -eq $mutex) {
        return $false
    }
    try {
        Remove-NSFile (Join-Path $NightshiftDir '.shift-lease')
        Get-ChildItem -LiteralPath $NightshiftDir -Filter '.shift-lease.tmp.*' -Force -ErrorAction SilentlyContinue |
            Remove-Item -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath (Join-Path $NightshiftDir '.lease-lock.d') -Recurse -Force -ErrorAction SilentlyContinue
        return $true
    }
    finally {
        Exit-NSMutex $mutex
    }
}

function Remove-NSPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (Test-NSReparsePoint $Path) {
        Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
        return
    }
    if (Test-Path -LiteralPath $Path -PathType Container) {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
        return
    }
    Remove-NSFile $Path
}

function Resolve-NSControlWorkspace {
    param([Parameter(Mandatory = $true)][string]$Project)
    $hostPath = Resolve-NSCanonicalPath $Project
    $workspace = Resolve-NSWorkspaceRoot $hostPath
    $ns = Join-Path $workspace '.nightshift'
    return [pscustomobject]@{
        HostRoot = $hostPath
        Workspace = $workspace
        NightshiftDir = $ns
    }
}

function Test-NSBroadWorkspace {
    param([Parameter(Mandatory = $true)][string]$Workspace)
    $ws = $Workspace.TrimEnd('\', '/')
    if ([string]::IsNullOrEmpty($ws)) { return $true }
    if ($ws -in @('/', '\', 'C:', 'C:\')) { return $true }
    $root = ''
    try { $root = [IO.Path]::GetPathRoot($ws).TrimEnd('\', '/') } catch { $root = '' }
    if (-not [string]::IsNullOrEmpty($root) -and $ws.Equals($root, [StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }
    $home = ''
    if (-not [string]::IsNullOrEmpty($env:USERPROFILE)) {
        try { $home = Resolve-NSCanonicalPath $env:USERPROFILE } catch { $home = '' }
    }
    if ([string]::IsNullOrEmpty($home) -and -not [string]::IsNullOrEmpty($env:HOME)) {
        try { $home = Resolve-NSCanonicalPath $env:HOME } catch { $home = '' }
    }
    if (-not [string]::IsNullOrEmpty($home) -and $ws.Equals($home.TrimEnd('\', '/'), [StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }
    $forbidden = @()
    if (-not [string]::IsNullOrEmpty($root)) {
        $forbidden += (Join-Path $root 'Users')
        $forbidden += (Join-Path $root 'Windows')
        $forbidden += (Join-Path $root 'Program Files')
        $forbidden += (Join-Path $root 'Program Files (x86)')
    }
    foreach ($item in $forbidden) {
        $candidate = $item.TrimEnd('\', '/')
        if ($ws.Equals($candidate, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Read-NSControlLink {
    param([Parameter(Mandatory = $true)][string]$HostRoot)
    $link = Join-Path $HostRoot '.nightshift-link'
    if (-not (Test-NSPathEntry $link)) { return $null }
    if ((Test-NSReparsePoint $link) -or -not (Test-Path -LiteralPath $link -PathType Leaf)) {
        throw 'invalid .nightshift-link'
    }
    $lines = [IO.File]::ReadAllLines($link)
    if ($lines.Count -ne 1 -or [string]::IsNullOrWhiteSpace($lines[0])) {
        throw 'invalid .nightshift-link'
    }
    $target = $lines[0]
    if (-not [IO.Path]::IsPathRooted($target)) {
        throw 'invalid .nightshift-link'
    }
    try {
        return Resolve-NSCanonicalPath $target
    }
    catch {
        $parent = Split-Path -Parent $target
        return (Join-Path (Resolve-NSCanonicalPath $parent) (Split-Path -Leaf $target))
    }
}

function Get-NSControlStartRefuseReason {
    param([Parameter(Mandatory = $true)][string]$NightshiftDir)
    $stop = Join-Path $NightshiftDir 'STOP'
    $ended = Join-Path $NightshiftDir '.ended'
    if (-not (Test-Path -LiteralPath $stop -PathType Leaf)) { return '' }
    if ((Test-Path -LiteralPath $ended -PathType Leaf) -and -not (Test-NSReparsePoint $ended)) { return '' }
    $deadline = Join-Path $NightshiftDir 'deadline'
    if (-not (Test-Path -LiteralPath $deadline -PathType Leaf) -or (Test-NSReparsePoint $deadline)) {
        return ''
    }
    $raw = ([IO.File]::ReadAllText($deadline)).Trim()
    if ($raw -notmatch '^[0-9]+$') { return '' }
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    if ($now -lt [long]$raw) { return '' }
    return "paused shift deadline has expired - write a new UNIX epoch to $NightshiftDir/deadline, or run Reset then Start; refusing to invent a time budget"
}

function Stop-NSWatchman {
    param([Parameter(Mandatory = $true)][string]$NightshiftDir)
    $pidFile = Join-Path $NightshiftDir '.watchman'
    $tick = Join-Path $NightshiftDir '.watchman-tick'
    if (Test-NSReparsePoint $pidFile) {
        Remove-NSPath $pidFile
        Remove-NSPath $tick
        return 'stopped'
    }
    if (-not (Test-Path -LiteralPath $pidFile -PathType Leaf)) {
        Remove-NSPath $tick
        return 'absent'
    }
    $lines = @([IO.File]::ReadAllLines($pidFile))
    $pid = if ($lines.Count -gt 0) { $lines[0].Trim() } else { '' }
    $start = if ($lines.Count -gt 1) { [string]$lines[1] } else { '' }
    $state = Test-NSRecordedProcess $pid $start
    if ($state -in @('Dead', 'Malformed')) {
        Remove-NSPath $pidFile
        Remove-NSPath $tick
        return 'absent'
    }
    if ($state -ne 'Alive') {
        return 'unverified'
    }
    if ([string]::IsNullOrEmpty($start)) {
        $proc = Get-Process -Id ([int]$pid) -ErrorAction SilentlyContinue
        $blob = ''
        if ($null -ne $proc) {
            $blob = [string]$proc.ProcessName + ' ' + [string]$proc.Path
        }
        if ($blob -notmatch 'watchman\.ps1|watchman\.sh|start-watchman') {
            return 'unverified'
        }
    }
    Stop-Process -Id ([int]$pid) -Force -ErrorAction SilentlyContinue
    Remove-NSPath $pidFile
    Remove-NSPath $tick
    return 'stopped'
}

function Clear-NSRuntimeMarkers {
    param([Parameter(Mandatory = $true)][string]$NightshiftDir)
    foreach ($name in @('.shift-armed', '.ended', '.session-end', '.shift-pulse', '.mint-failed', '.shift-session', '.stall', '.notified', '.watchman-tick', '.mutex-scope')) {
        Remove-NSPath (Join-Path $NightshiftDir $name)
    }
    Get-ChildItem -LiteralPath $NightshiftDir -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like '.shift-session.tmp.*' -or $_.Name -like '.mutex-scope.tmp.*' } |
        ForEach-Object { Remove-NSPath $_.FullName }
    Remove-NSPath (Join-Path $NightshiftDir '.lock.d')
    $null = Reset-NSStaleLease $NightshiftDir
}

function Write-NSControlLog {
    param(
        [Parameter(Mandatory = $true)][string]$NightshiftDir,
        [Parameter(Mandatory = $true)][string]$Line
    )
    $log = Join-Path $NightshiftDir 'shift-log.md'
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content -LiteralPath $log -Value "$stamp · $Line" -Encoding utf8
}

function Stop-NSShift {
    param(
        [Parameter(Mandatory = $true)][string]$Project,
        [string]$Reason = 'stopped by owner'
    )
    $ctx = Resolve-NSControlWorkspace $Project
    $ns = $ctx.NightshiftDir
    if (Test-NSReparsePoint $ns) { throw 'stop-shift: .nightshift path is not a usable directory' }
    if (-not (Test-Path -LiteralPath $ns -PathType Container)) {
        throw "stop-shift: no .nightshift/ at $($ctx.Workspace)"
    }
    if ([string]::IsNullOrEmpty($Reason)) { $Reason = 'stopped by owner' }
    $ts = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    Remove-NSPath (Join-Path $ns 'STOP')
    [IO.File]::WriteAllText((Join-Path $ns 'STOP'), "$Reason · $ts`n")
    $watch = Stop-NSWatchman $ns
    $null = Write-NSReason $ns 'owner-stop'
    Write-NSControlLog $ns 'stopped by owner'
    $open = 0
    $punch = Join-Path $ns 'punch-list.md'
    if (Test-Path -LiteralPath $punch -PathType Leaf) {
        $open = (Get-NSBoxCounts $punch).Open
    }
    Write-Output "stopped $ns"
    Write-Output "workspace $($ctx.Workspace)"
    if ($ctx.HostRoot -ne $ctx.Workspace) { Write-Output "host $($ctx.HostRoot)" }
    Write-Output "watchman $watch"
    Write-Output "open-items $open"
    Write-Output 'deadline preserved'
}

function Reset-NSShift {
    param([Parameter(Mandatory = $true)][string]$Project)
    $ctx = Resolve-NSControlWorkspace $Project
    $tx = Join-NSPath $ctx.NightshiftDir 'provision-transaction.json'
    if (Test-NSPathEntry $tx) {
        Write-Error 'reset-shift: refuse while provision-transaction.json is open; run provision recover or rollback first'
        return 1
    }
    Stop-NSShift -Project $Project -Reason 'reset by owner'
    $ctx = Resolve-NSControlWorkspace $Project
    Clear-NSRuntimeMarkers $ctx.NightshiftDir
    Remove-NSPath (Join-Path $ctx.NightshiftDir 'STOP')
    Remove-NSPath (Join-Path $ctx.NightshiftDir 'deadline')
    Remove-NSPath (Join-Path $ctx.NightshiftDir '.watch-reason')
    # shift-defaults.json (remembered convenience) and rules.json (permanent boundaries) survive
    # a reset exactly like the punch list and parking lot do; only tonight's snapshot goes.
    Remove-NSPath (Join-Path $ctx.NightshiftDir 'shift-policy.json')
    Write-NSControlLog $ctx.NightshiftDir 'reset by owner - runtime markers, deadline, and shift policy cleared'
    Write-Output "reset $($ctx.NightshiftDir)"
    Write-Output 'deadline removed'
}

function Remove-NSNightshiftWorkspace {
    param(
        [Parameter(Mandatory = $true)][string]$Project,
        [Parameter(Mandatory = $true)][string]$ConfirmPath
    )
    $hostPath = Resolve-NSCanonicalPath $Project
    $workspace = $hostPath
    $link = Join-Path $hostPath '.nightshift-link'
    if (Test-NSPathEntry $link) {
        $workspace = Read-NSControlLink $hostPath
    }
    $nsCanon = Join-Path $workspace '.nightshift'
    if ((Test-Path -LiteralPath $nsCanon -PathType Container) -and -not (Test-NSReparsePoint $nsCanon)) {
        $nsCanon = Resolve-NSCanonicalPath $nsCanon
    }
    else {
        try { $nsCanon = Resolve-NSCanonicalPath $nsCanon } catch {
            $parent = Split-Path -Parent $nsCanon
            $nsCanon = Join-Path (Resolve-NSCanonicalPath $parent) (Split-Path -Leaf $nsCanon)
        }
    }
    $confirm = $ConfirmPath.TrimEnd('\', '/')
    try { $confirm = Resolve-NSCanonicalPath $ConfirmPath } catch {
        $parent = Split-Path -Parent $ConfirmPath
        $confirm = Join-Path (Resolve-NSCanonicalPath $parent) (Split-Path -Leaf $ConfirmPath)
    }
    $confirm = $confirm.TrimEnd('\', '/')
    $nsCanon = $nsCanon.TrimEnd('\', '/')
    if ($confirm -ne $nsCanon) {
        throw "purge-workspace: --confirm-path must be exactly $nsCanon"
    }
    if ((Test-NSBroadWorkspace $workspace) -or (Test-NSReparsePoint $nsCanon)) {
        throw "purge-workspace: refusing to delete $nsCanon"
    }
    if ((Test-Path -LiteralPath $nsCanon -PathType Container) -and -not (Test-NSReparsePoint $nsCanon)) {
        Reset-NSShift -Project $Project
    }
    if (Test-NSReparsePoint $nsCanon) {
        throw 'purge-workspace: .nightshift path is a symlink'
    }
    if (Test-Path -LiteralPath $nsCanon) {
        Remove-Item -LiteralPath $nsCanon -Recurse -Force
    }
    if (Test-NSPathEntry $link) {
        Remove-NSPath $link
    }
    Write-Output "purged $nsCanon"
    Write-Output 'plugin install was not touched'
}

function Test-NSTrustedShiftControl {
    param(
        [AllowEmptyString()][string]$Command,
        [Parameter(Mandatory = $true)][string]$PluginRoot,
        [Parameter(Mandatory = $true)][string]$Workspace
    )
    if ([string]::IsNullOrWhiteSpace($Command)) { return $false }
    if ($Command.Contains('$')) { return $false }
    if ($Command -match "[\r\n;|&``<>]") { return $false }
    $pluginRoot = Resolve-NSCanonicalPath $PluginRoot
    $workspace = Resolve-NSCanonicalPath $Workspace
    $normalized = $Command.Trim()
    foreach ($prefix in @('powershell.exe ', 'pwsh ', 'pwsh.exe ', '& ')) {
        if ($normalized.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
            $normalized = $normalized.Substring($prefix.Length).Trim()
        }
    }
    $normalized = $normalized -replace "^'", '' -replace "'$", '' -replace '^"', '' -replace '"$', ''
    # @() keeps a single regex hit as a one-element array; StrictMode rejects .Count on a bare string.
    $tokens = @([regex]::Matches($normalized, '(?:[^\s"]+|"[^"]*"|''[^'']*'')') | ForEach-Object { $_.Value.Trim("'`"") })
    if ($tokens.Count -lt 3) { return $false }
    $idx = 0
    if ($tokens[0] -in @('powershell', 'powershell.exe', 'pwsh', 'pwsh.exe', 'bash') -and $tokens.Count -ge 4) {
        if ($tokens[1] -in @('-File', '-Command', '--')) { $idx = 2 } else { $idx = 1 }
    }
    $script = $tokens[$idx]
    try { $script = Resolve-NSCanonicalPath $script } catch { return $false }
    $helpers = @(
        (Join-Path $pluginRoot 'runtime/windows/stop-shift.ps1'),
        (Join-Path $pluginRoot 'runtime/windows/reset-shift.ps1'),
        (Join-Path $pluginRoot 'runtime/windows/purge-workspace.ps1'),
        (Join-Path $pluginRoot 'runtime/stop-shift.sh'),
        (Join-Path $pluginRoot 'runtime/reset-shift.sh'),
        (Join-Path $pluginRoot 'runtime/purge-workspace.sh')
    )
    $ok = $false
    foreach ($h in $helpers) {
        try {
            if ((Resolve-NSCanonicalPath $h) -eq $script) { $ok = $true; break }
        }
        catch { }
    }
    if (-not $ok) { return $false }
    $project = ''
    $confirm = ''
    for ($i = $idx + 1; $i -lt $tokens.Count; $i++) {
        if ($tokens[$i] -in @('--project', '-Project') -and ($i + 1) -lt $tokens.Count) {
            $project = $tokens[$i + 1]
            $i++
            continue
        }
        if ($tokens[$i] -in @('--confirm-path', '-ConfirmPath') -and ($i + 1) -lt $tokens.Count) {
            $confirm = $tokens[$i + 1]
            $i++
            continue
        }
        if ($tokens[$i] -in @('--reason', '-Reason') -and ($i + 1) -lt $tokens.Count) {
            $i++
            continue
        }
        return $false
    }
    if ([string]::IsNullOrEmpty($project)) { return $false }
    if (-not [IO.Path]::IsPathRooted($project)) { return $false }
    try {
        $resolved = (Resolve-NSControlWorkspace $project).Workspace
    }
    catch { return $false }
    if ($resolved -ne $workspace) { return $false }
    $leaf = Split-Path -Leaf $script
    if ($leaf -like 'purge-workspace.*' -and [string]::IsNullOrEmpty($confirm)) { return $false }
    return $true
}

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
        [Parameter(Mandatory = $true)][ValidateSet('hardhat', 'gate')][string]$Mode
    )
    $session = Read-NSSession $NightshiftDir
    $lease = Read-NSLease $NightshiftDir
    if ($null -eq $session -and $null -ne $lease -and -not [string]::IsNullOrEmpty($lease.Nonce)) {
        if (-not $Revival -or -not (Test-NSLeaseNonce $NightshiftDir $HostName $Nonce $Generation)) {
            if ($Mode -eq 'hardhat') {
                return New-NSShiftDecision -Status Fail -Message 'BLOCKED: this shift is being recovered before its new conversation is bound. Reopen the recorded conversation and retry after recovery.'
            }
            return New-NSShiftDecision -Status Pass
        }
    }
    return New-NSShiftDecision -Status Continue -Session $session
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
    $leasePath = Join-Path $NightshiftDir '.shift-lease'
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
        'clock-out-failed', 'recovery-scope-unavailable'
    )
    if ($Code -notin $allowed) {
        $Code = 'stand-down'
    }
    $Detail = ($Detail -replace '[\x00-\x1f]', '').TrimEnd()
    $null = Write-NSAtomicLines -Path (Join-Path $NightshiftDir '.watch-reason') -Lines @($Code, $Detail)
}

function Get-NSUnixTime {
    return [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
}

function Get-NSPulseEpoch {
    param([Parameter(Mandatory = $true)][string]$NightshiftDir)
    $path = Join-Path $NightshiftDir '.shift-pulse'
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
    $armed = Join-Path $NightshiftDir '.shift-armed'
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

function Test-NSHardhatActive {
    param([Parameter(Mandatory = $true)][string]$NightshiftDir)
    $ended = Join-Path $NightshiftDir '.ended'
    if ((Test-Path -LiteralPath $ended -PathType Leaf) -and -not (Test-NSReparsePoint $ended)) {
        return $false
    }
    $armed = Join-Path $NightshiftDir '.shift-armed'
    if (-not (Test-Path -LiteralPath $armed -PathType Leaf)) {
        return $false
    }
    $punch = Join-Path $NightshiftDir 'punch-list.md'
    if (-not (Test-Path -LiteralPath $punch -PathType Leaf)) {
        return $false
    }
    $stop = Join-Path $NightshiftDir 'STOP'
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
    $sessionPath = Join-Path $ns '.shift-session'
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
        'legacy' { return '0' }
        'current' { return [string]$script:NSStateVersion }
        'future' {
            try {
                $raw = ([IO.File]::ReadAllLines((Join-Path $Workspace '.nightshift/state-version')) | Select-Object -First 1)
                return ([string]$raw).Trim()
            }
            catch {
                return ''
            }
        }
        default { return '' }
    }
}

function Invoke-NSMigrateState {
    param([Parameter(Mandatory = $true)][string]$Workspace)
    $kind = Get-NSStateKind $Workspace
    if ($kind -eq 'current') {
        return 0
    }
    if ($kind -ne 'legacy') {
        return 2
    }
    if (Test-Path -LiteralPath (Join-Path $Workspace '.nightshift/.shift-armed') -PathType Leaf) {
        return 1
    }
    try {
        $null = Write-NSAtomicLines -Path (Join-Path $Workspace '.nightshift/state-version') `
            -Lines @([string]$script:NSStateVersion)
        return 0
    }
    catch {
        return 3
    }
}

function Get-NSReasonCode {
    param([Parameter(Mandatory = $true)][string]$NightshiftDir)
    $path = Join-Path $NightshiftDir '.watch-reason'
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
        $logPath = Resolve-NSUnderNightshift $Workspace 'scheduled.log'
        if (-not [string]::IsNullOrEmpty($logPath) -and (Test-Path -LiteralPath $logPath -PathType Leaf)) {
            $age = [int](($now - (Get-Item -LiteralPath $logPath).LastWriteTimeUtc).TotalDays)
            if ($age -ge $logDays) {
                $null = $rows.Add([pscustomobject]@{ Kind = 'runtime-log'; Rel = 'scheduled.log'; Age = $age; Days = $logDays })
            }
        }
    }

    if ($archDays -le 0) {
        return @($rows)
    }
    $archiveRoot = Join-Path $ns 'archive'
    if (-not (Test-Path -LiteralPath $archiveRoot -PathType Container) -or (Test-NSReparsePoint $archiveRoot)) {
        return @($rows)
    }
    foreach ($dir in @(Get-ChildItem -LiteralPath $archiveRoot -Directory -ErrorAction SilentlyContinue)) {
        if ($dir.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            continue
        }
        if ($dir.Name -notmatch '^[0-9]{4}-[0-9]{2}-[0-9]{2}$') {
            continue
        }
        $rel = 'archive/' + $dir.Name
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
    if (Test-Path -LiteralPath (Join-Path $ns '.shift-armed') -PathType Leaf) {
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
        else {
            $null = $builder.Append('.nightshift')
            $i = $idx + 11
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

# --- paths, JSON and schema documents --------------------------------------

function Sort-NSOrdinal {
    param([AllowNull()][AllowEmptyCollection()][string[]]$Items)
    $sorted = New-Object Collections.Generic.List[string]
    if ($null -ne $Items) {
        foreach ($item in $Items) {
            $sorted.Add($item)
        }
    }
    $sorted.Sort([StringComparer]::Ordinal)
    return , $sorted.ToArray()
}

function Get-NSAbsolutePath {
    param([Parameter(Mandatory = $true)][string]$Path)
    $candidate = $Path
    if (-not [IO.Path]::IsPathRooted($candidate)) {
        $candidate = Join-Path (Get-Location).ProviderPath $candidate
    }
    $full = [IO.Path]::GetFullPath($candidate)
    $sep = [IO.Path]::DirectorySeparatorChar
    while ($full.Length -gt 1 -and $full[$full.Length - 1] -eq $sep -and -not $full.EndsWith(':' + $sep, [StringComparison]::Ordinal)) {
        $full = $full.Substring(0, $full.Length - 1)
    }
    return $full
}

function Test-NSEvidenceId {
    param([AllowEmptyString()][string]$Id)
    if ([string]::IsNullOrEmpty($Id)) { return $false }
    return [regex]::IsMatch($Id, '^[A-Za-z0-9][A-Za-z0-9_-]*$')
}

# Join a directory and a leaf name. Never treats Name as a path, even when
# it looks rooted - Join-NSPath's rooted-name rule is how an evidence id
# such as /tmp/nightshift-proof escaped .nightshift/.
function Join-NSLeaf {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Base,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Name
    )
    if ([string]::IsNullOrEmpty($Base)) { return $Name }
    $last = $Base[$Base.Length - 1]
    if ($last -eq [IO.Path]::DirectorySeparatorChar -or $last -eq [IO.Path]::AltDirectorySeparatorChar) {
        return ($Base + $Name)
    }
    return ($Base + [IO.Path]::DirectorySeparatorChar + $Name)
}

function Get-NSEvidenceRawDestination {
    param(
        [Parameter(Mandatory = $true)][string]$Ns,
        [AllowEmptyString()][string]$Id
    )
    if (-not (Test-NSEvidenceId $Id)) { return $null }
    $rawDir = Join-NSPath $Ns 'evidence'
    $rawDir = Join-NSPath $rawDir 'raw'
    if (-not (Test-Path -LiteralPath $rawDir -PathType Container)) {
        $null = New-Item -ItemType Directory -Path $rawDir -Force
    }
    $parent = Get-NSAbsolutePath $rawDir
    $nsRoot = Get-NSAbsolutePath $Ns
    $sep = [string][IO.Path]::DirectorySeparatorChar
    if ($parent -ne $nsRoot -and -not $parent.StartsWith($nsRoot + $sep, [StringComparison]::Ordinal)) {
        return $null
    }
    $dest = Join-NSLeaf $parent ($Id + '.txt')
    $destParent = Get-NSAbsolutePath ([IO.Path]::GetDirectoryName($dest))
    if ($destParent -ne $parent) { return $null }
    $result = New-NSOrdinalMap
    $result['rel'] = (Join-NSLeaf (Join-NSLeaf 'evidence' 'raw') ($Id + '.txt')) -replace '\\', '/'
    $result['abs'] = $dest
    return $result
}

function Join-NSPath {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Base,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Name
    )
    if ([string]::IsNullOrEmpty($Base) -or [IO.Path]::IsPathRooted($Name)) {
        return $Name
    }
    $last = $Base[$Base.Length - 1]
    if ($last -eq [IO.Path]::DirectorySeparatorChar -or $last -eq [IO.Path]::AltDirectorySeparatorChar) {
        return ($Base + $Name)
    }
    return ($Base + [IO.Path]::DirectorySeparatorChar + $Name)
}

# The canonical capability document: recursively sorted keys,
# two-space indent, "key": value, [] and {} for empties, \uXXXX for every
# character outside printable ASCII, no escaped slash, LF only. -Compact drops
# every newline and space, giving Python json.dumps(sort_keys=True,
# separators=(",", ":")) - the one-line form the evidence ledger stores.
function ConvertTo-NSJsonStringLiteral {
    param([AllowNull()][AllowEmptyString()][string]$Text)
    $builder = New-Object Text.StringBuilder
    $null = $builder.Append('"')
    if (-not [string]::IsNullOrEmpty($Text)) {
        foreach ($char in $Text.ToCharArray()) {
            $code = [int]$char
            if ($code -eq 34) { $null = $builder.Append('\"') }
            elseif ($code -eq 92) { $null = $builder.Append('\\') }
            elseif ($code -eq 8) { $null = $builder.Append('\b') }
            elseif ($code -eq 9) { $null = $builder.Append('\t') }
            elseif ($code -eq 10) { $null = $builder.Append('\n') }
            elseif ($code -eq 12) { $null = $builder.Append('\f') }
            elseif ($code -eq 13) { $null = $builder.Append('\r') }
            elseif ($code -lt 32 -or $code -gt 126) { $null = $builder.Append(('\u{0:x4}' -f $code)) }
            else { $null = $builder.Append($char) }
        }
    }
    $null = $builder.Append('"')
    return $builder.ToString()
}

function Test-NSJsonInteger {
    param($Value)
    return ($Value -is [int] -or $Value -is [long] -or $Value -is [int16] -or $Value -is [byte] -or $Value -is [uint16] -or $Value -is [uint32] -or $Value -is [uint64] -or $Value -is [sbyte])
}

function Test-NSJsonFloat {
    param($Value)
    return ($Value -is [double] -or $Value -is [single] -or $Value -is [decimal])
}

# repr() of a Python float: shortest round-trip, and always a fractional part so
# 1.0 never collapses to 1.
function Format-NSJsonFloat {
    param($Value)
    $text = ([double]$Value).ToString('R', [Globalization.CultureInfo]::InvariantCulture)
    if ($text.IndexOf('.') -lt 0 -and $text.IndexOf('E') -lt 0 -and $text.IndexOf('e') -lt 0 -and $text.IndexOf('N') -lt 0 -and $text.IndexOf('I') -lt 0) {
        $text = $text + '.0'
    }
    return $text
}

function Write-NSCanonicalJsonValue {
    param(
        [Parameter(Mandatory = $true)]$Builder,
        $Value,
        [int]$Level = 0,
        [switch]$Compact
    )
    if ($null -eq $Value) {
        $null = $Builder.Append('null')
        return
    }
    if ($Value -is [bool]) {
        if ($Value) { $null = $Builder.Append('true') } else { $null = $Builder.Append('false') }
        return
    }
    if ($Value -is [string]) {
        $null = $Builder.Append((ConvertTo-NSJsonStringLiteral $Value))
        return
    }
    if (Test-NSJsonInteger $Value) {
        $null = $Builder.Append(([long]$Value).ToString([Globalization.CultureInfo]::InvariantCulture))
        return
    }
    if (Test-NSJsonFloat $Value) {
        $null = $Builder.Append((Format-NSJsonFloat $Value))
        return
    }
    $pad = ' ' * (2 * ($Level + 1))
    $tail = ' ' * (2 * $Level)
    $break = "`n"
    $colon = ': '
    if ($Compact) {
        $pad = ''
        $tail = ''
        $break = ''
        $colon = ':'
    }
    if ($Value -is [Collections.IDictionary]) {
        $keys = Sort-NSOrdinal (@($Value.Keys))
        if ($keys.Count -eq 0) {
            $null = $Builder.Append('{}')
            return
        }
        $null = $Builder.Append('{')
        $index = 0
        foreach ($key in $keys) {
            if ($index -gt 0) { $null = $Builder.Append(',') }
            $null = $Builder.Append($break)
            $null = $Builder.Append($pad)
            $null = $Builder.Append((ConvertTo-NSJsonStringLiteral $key))
            $null = $Builder.Append($colon)
            Write-NSCanonicalJsonValue $Builder $Value[$key] ($Level + 1) -Compact:$Compact
            $index++
        }
        $null = $Builder.Append($break)
        $null = $Builder.Append($tail)
        $null = $Builder.Append('}')
        return
    }
    if ($Value -is [Collections.IEnumerable]) {
        $items = @($Value)
        if ($items.Count -eq 0) {
            $null = $Builder.Append('[]')
            return
        }
        $null = $Builder.Append('[')
        $index = 0
        foreach ($item in $items) {
            if ($index -gt 0) { $null = $Builder.Append(',') }
            $null = $Builder.Append($break)
            $null = $Builder.Append($pad)
            Write-NSCanonicalJsonValue $Builder $item ($Level + 1) -Compact:$Compact
            $index++
        }
        $null = $Builder.Append($break)
        $null = $Builder.Append($tail)
        $null = $Builder.Append(']')
        return
    }
    $null = $Builder.Append((ConvertTo-NSJsonStringLiteral ([string]$Value)))
}

function ConvertTo-NSCanonicalJson {
    param([AllowNull()]$InputObject, [switch]$Compact)
    $builder = New-Object Text.StringBuilder
    Write-NSCanonicalJsonValue $builder $InputObject 0 -Compact:$Compact
    return $builder.ToString()
}

function Get-NSSchemaDocument {
    param([Parameter(Mandatory = $true)][string]$Name)
    $dir = Join-Path (Split-Path -Parent $PSScriptRoot) 'skills/nightshift/references/schemas/v1'
    $raw = [IO.File]::ReadAllText((Join-Path $dir $Name))
    return ($raw | ConvertFrom-Json)
}

function Get-NSJsonProperty {
    param($Object, [Parameter(Mandatory = $true)][string]$Name)
    if ($null -eq $Object) {
        return $null
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }
    return $property.Value
}

# ---------------------------------------------------------------------------
# Evidence ledger - the native side of runtime/windows/evidence.ps1.
# Validates records. Does not verify a Nightshift tick or interpret domain
# meaning. Every byte it writes matches runtime/evidence.py for the same input.
# ---------------------------------------------------------------------------

$script:NSEvidenceLadderRank = New-Object Collections.Specialized.OrderedDictionary([StringComparer]::Ordinal)
$script:NSEvidenceLadderRank['declared'] = 0
$script:NSEvidenceLadderRank['observed'] = 1
$script:NSEvidenceLadderRank['reproduced'] = 2
$script:NSEvidenceLadderRank['measured'] = 3
$script:NSEvidenceLadderRank['verified-after-change'] = 4
$script:NSEvidenceLadderRank['human-accepted'] = 5

$script:NSEvidenceTsvColumns = @(
    'id', 'domain', 'sourceClass', 'source', 'scope', 'severity',
    'confidence', 'impact', 'status', 'ladder', 'locator', 'host'
)

# ConvertFrom-Json turns any string that looks like a timestamp into a DateTime,
# which would rewrite firstSeen/lastChecked on the way through. Prefixing every
# string literal with one guard character before the parse - and dropping it
# again after - keeps every value the text it was.
$script:NSJsonGuard = '~'

function Add-NSJsonStringGuard {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)
    $builder = New-Object Text.StringBuilder
    $inString = $false
    $i = 0
    while ($i -lt $Text.Length) {
        $ch = $Text[$i]
        if (-not $inString) {
            $null = $builder.Append($ch)
            if ($ch -eq '"') {
                $inString = $true
                $null = $builder.Append($script:NSJsonGuard)
            }
            $i++
            continue
        }
        if ($ch -eq '\') {
            $null = $builder.Append($ch)
            if ($i + 1 -lt $Text.Length) { $null = $builder.Append($Text[$i + 1]) }
            $i += 2
            continue
        }
        $null = $builder.Append($ch)
        if ($ch -eq '"') { $inString = $false }
        $i++
    }
    return $builder.ToString()
}

function Remove-NSJsonStringGuard {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)
    if ($Text.Length -eq 0) { return $Text }
    return $Text.Substring(1)
}

function New-NSOrdinalMap {
    return (New-Object Collections.Specialized.OrderedDictionary([StringComparer]::Ordinal))
}

function ConvertFrom-NSJsonNode {
    param($Node)
    if ($null -eq $Node) { return $null }
    if ($Node -is [string]) { return (Remove-NSJsonStringGuard $Node) }
    if ($Node -is [bool] -or (Test-NSJsonInteger $Node) -or (Test-NSJsonFloat $Node)) { return $Node }
    if ($Node -is [Collections.IDictionary]) {
        $map = New-NSOrdinalMap
        foreach ($key in @($Node.Keys)) {
            $map[(Remove-NSJsonStringGuard ([string]$key))] = ConvertFrom-NSJsonNode $Node[$key]
        }
        return $map
    }
    if ($Node -is [Collections.IEnumerable]) {
        $items = New-Object Collections.Generic.List[object]
        foreach ($item in $Node) { $items.Add((ConvertFrom-NSJsonNode $item)) }
        return , $items.ToArray()
    }
    $map = New-NSOrdinalMap
    foreach ($property in $Node.PSObject.Properties) {
        $name = Remove-NSJsonStringGuard $property.Name
        if ($null -eq $property.Value -and ($property.TypeNameOfValue -ceq 'System.Object[]')) {
            $map[$name] = @()
            continue
        }
        $map[$name] = ConvertFrom-NSJsonNode $property.Value
    }
    return $map
}

# json.loads: ordered dictionaries with ordinal keys, so "id" and "ID" stay two
# keys and the canonical serializer sees them the way Python does.
function ConvertFrom-NSJsonText {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)
    $parsed = ConvertFrom-Json (Add-NSJsonStringGuard $Text) -ErrorAction Stop
    return (ConvertFrom-NSJsonNode $parsed)
}

function Get-NSMapValue {
    param($Map, [Parameter(Mandatory = $true)][string]$Key)
    if (-not ($Map -is [Collections.IDictionary])) { return $null }
    if (-not $Map.Contains($Key)) { return $null }
    return , $Map[$Key]
}

function Copy-NSMap {
    param($Map)
    $copy = New-NSOrdinalMap
    if ($Map -is [Collections.IDictionary]) {
        foreach ($key in @($Map.Keys)) { $copy[$key] = $Map[$key] }
    }
    return $copy
}

# Python truth testing: empty string, zero, empty container and None are false.
function Test-NSPyTruthy {
    param($Value)
    if ($null -eq $Value) { return $false }
    if ($Value -is [bool]) { return [bool]$Value }
    if ($Value -is [string]) { return ($Value.Length -gt 0) }
    if (Test-NSJsonInteger $Value) { return ([long]$Value -ne 0) }
    if (Test-NSJsonFloat $Value) { return ([double]$Value -ne 0) }
    if ($Value -is [Collections.IDictionary]) { return ($Value.Count -gt 0) }
    if ($Value -is [Collections.ICollection]) { return ($Value.Count -gt 0) }
    return $true
}

# Python str(): None renders None, booleans render True/False.
function ConvertTo-NSPyText {
    param($Value)
    if ($null -eq $Value) { return 'None' }
    if ($Value -is [bool]) {
        if ($Value) { return 'True' }
        return 'False'
    }
    if (Test-NSJsonFloat $Value) { return (Format-NSJsonFloat $Value) }
    return [string]$Value
}

# Python ==: same type and same value, so 1 and "1" stay different.
function Test-NSPyEqual {
    param($Left, $Right)
    return ((ConvertTo-NSCanonicalJson $Left -Compact) -ceq (ConvertTo-NSCanonicalJson $Right -Compact))
}

function Write-NSEvidenceOut {
    param([AllowEmptyString()][string]$Text)
    [Console]::Out.Write($Text)
    [Console]::Out.Write("`n")
}

function Write-NSEvidenceError {
    param([AllowEmptyString()][string]$Text)
    [Console]::Error.WriteLine($Text)
}

function Write-NSEvidenceUsage {
    Write-NSEvidenceError 'usage: evidence.ps1 -Project DIR -Command {init|validate|append|disposition|render|export-tsv|migrate} ...'
    return 1
}

function Get-NSEvidenceNow {
    $fixed = $env:NIGHTSHIFT_EVIDENCE_NOW
    if (-not [string]::IsNullOrEmpty($fixed)) { return $fixed }
    return [DateTime]::UtcNow.ToString('yyyy-MM-dd\THH:mm:ss\Z', [Globalization.CultureInfo]::InvariantCulture)
}

function Get-NSTextSha256 {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash($script:NSUtf8NoBom.GetBytes($Text))
    }
    finally {
        $sha.Dispose()
    }
    $builder = New-Object Text.StringBuilder
    foreach ($byte in $hash) { $null = $builder.Append($byte.ToString('x2')) }
    return $builder.ToString()
}

function Get-NSEvidencePaths {
    param([Parameter(Mandatory = $true)][string]$Project)
    $ns = Join-NSPath (Get-NSAbsolutePath $Project) '.nightshift'
    $evidence = Join-NSPath $ns 'evidence'
    $paths = New-NSOrdinalMap
    $paths['ns'] = $ns
    $paths['dir'] = $evidence
    $paths['jsonl'] = Join-NSPath $evidence 'findings.jsonl'
    $paths['md'] = Join-NSPath $evidence 'findings.md'
    $paths['raw'] = Join-NSPath $evidence 'raw'
    $paths['version'] = Join-NSPath $evidence 'schema-version'
    return $paths
}

function Write-NSEvidenceFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text
    )
    [IO.File]::WriteAllText($Path, $Text, $script:NSUtf8NoBom)
}

function Write-NSEvidenceFileAtomic {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text
    )
    $tmp = $Path + '.tmp'
    Write-NSEvidenceFile -Path $tmp -Text $Text
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        # [NullString]::Value, not $null: PowerShell would bind $null to "" and
        # Replace rejects an empty backup path.
        [IO.File]::Replace($tmp, $Path, [NullString]::Value)
        return
    }
    [IO.File]::Move($tmp, $Path)
}

function Test-NSEvidenceSchemaOne {
    param($Value)
    if ($null -eq $Value) { return $false }
    if ($Value -is [bool]) { return [bool]$Value }
    if (Test-NSJsonInteger $Value) { return ([long]$Value -eq 1) }
    if (Test-NSJsonFloat $Value) { return ([double]$Value -eq 1) }
    return $false
}

# Python "value in list": exact, case-sensitive, and never true across types.
function Test-NSEvidenceEnum {
    param($Value, $Allowed)
    if (-not ($Value -is [string])) { return $false }
    foreach ($candidate in @($Allowed)) {
        if (($candidate -is [string]) -and ($candidate -ceq $Value)) { return $true }
    }
    return $false
}

function Get-NSEvidenceLadderRank {
    param($Ladder)
    if (-not ($Ladder -is [string])) { return -1 }
    if (-not $script:NSEvidenceLadderRank.Contains($Ladder)) { return -1 }
    return [int]$script:NSEvidenceLadderRank[$Ladder]
}

function Test-NSEvidenceRecord {
    param($Record, $Schema, $Previous)
    $errors = New-Object Collections.Generic.List[string]
    if (-not ($Record -is [Collections.IDictionary])) {
        $errors.Add('record is not an object')
        return , $errors
    }
    foreach ($key in $Schema.required) {
        if (-not $Record.Contains($key)) { $errors.Add('missing ' + $key) }
    }
    if (-not (Test-NSEvidenceSchemaOne (Get-NSMapValue $Record 'schemaVersion'))) { $errors.Add('unsupported schemaVersion') }
    if (-not (Test-NSEvidenceEnum (Get-NSMapValue $Record 'severity') $Schema.severity)) { $errors.Add('invalid severity') }
    if (-not (Test-NSEvidenceEnum (Get-NSMapValue $Record 'confidence') $Schema.confidence)) { $errors.Add('invalid confidence') }
    if (-not (Test-NSEvidenceEnum (Get-NSMapValue $Record 'impact') $Schema.impact)) { $errors.Add('invalid impact') }
    if (-not (Test-NSEvidenceEnum (Get-NSMapValue $Record 'status') $Schema.status)) { $errors.Add('invalid status') }
    if (-not (Test-NSEvidenceEnum (Get-NSMapValue $Record 'ladder') $Schema.ladder)) { $errors.Add('invalid ladder') }
    if ($Record.Contains('id') -and -not (Test-NSEvidenceId (Get-NSMapValue $Record 'id'))) { $errors.Add('invalid id') }
    $locator = Get-NSMapValue $Record 'locator'
    if (-not (Test-NSPyTruthy $locator)) { $locator = '' }
    if (([string]$locator).Contains('://') -and -not (Test-NSPyTruthy (Get-NSMapValue $Record 'untrusted'))) {
        $errors.Add('remote locator requires untrusted=true')
    }
    if ($null -ne $Previous) {
        $oldRank = Get-NSEvidenceLadderRank (Get-NSMapValue $Previous 'ladder')
        $newRank = Get-NSEvidenceLadderRank (Get-NSMapValue $Record 'ladder')
        $promoteBy = Get-NSMapValue $Record 'promoteBy'
        if ($oldRank -ge 0 -and $newRank -ge 0 -and $newRank -gt $oldRank -and ($promoteBy -is [string]) -and ($promoteBy -ceq 'prose')) {
            $errors.Add('ladder must not be promoted by prose')
        }
    }
    return , $errors
}

# SystemExit in the reference: the message goes to stderr and the process
# leaves with 1, whichever command was running.
function New-NSEvidenceHalt {
    param([Parameter(Mandatory = $true)][string]$Message)
    return (New-Object ApplicationException($Message))
}

function Read-NSEvidenceRecords {
    param([Parameter(Mandatory = $true)][string]$Path)
    $records = New-Object Collections.Generic.List[object]
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return , $records }
    $lines = [regex]::Split([IO.File]::ReadAllText($Path, $script:NSUtf8NoBom), "\r\n|\n|\r")
    for ($i = 0; $i -lt $lines.Length; $i++) {
        $line = $lines[$i].Trim()
        if ($line.Length -eq 0) { continue }
        $record = $null
        try {
            $record = ConvertFrom-NSJsonText $line
        }
        catch {
            throw (New-NSEvidenceHalt ('evidence: malformed JSON on line ' + ($i + 1)))
        }
        $records.Add($record)
    }
    return , $records
}

function Write-NSEvidenceRecords {
    param([Parameter(Mandatory = $true)][string]$Path, $Records)
    $builder = New-Object Text.StringBuilder
    foreach ($record in $Records) {
        $null = $builder.Append((ConvertTo-NSCanonicalJson $record -Compact))
        $null = $builder.Append("`n")
    }
    Write-NSEvidenceFileAtomic -Path $Path -Text $builder.ToString()
}

function Invoke-NSEvidenceInit {
    param([Parameter(Mandatory = $true)][string]$Project, [switch]$Quiet)
    $paths = Get-NSEvidencePaths $Project
    if (-not (Test-Path -LiteralPath $paths['ns'] -PathType Container)) {
        Write-NSEvidenceError ('evidence: no .nightshift/ at ' + $Project)
        return 1
    }
    $null = [IO.Directory]::CreateDirectory($paths['raw'])
    if (-not (Test-Path -LiteralPath $paths['jsonl'] -PathType Leaf)) {
        Write-NSEvidenceFile -Path $paths['jsonl'] -Text ''
    }
    if (-not (Test-Path -LiteralPath $paths['version'] -PathType Leaf)) {
        Write-NSEvidenceFile -Path $paths['version'] -Text "1`n"
    }
    if (-not $Quiet) { Write-NSEvidenceOut $paths['jsonl'] }
    return 0
}

function Invoke-NSEvidenceValidate {
    param([Parameter(Mandatory = $true)][string]$Project)
    $paths = Get-NSEvidencePaths $Project
    if (-not (Test-Path -LiteralPath $paths['jsonl'] -PathType Leaf)) {
        Write-NSEvidenceOut 'evidence: no ledger (valid empty workspace)'
        return 0
    }
    $schema = Get-NSSchemaDocument 'finding.json'
    $records = Read-NSEvidenceRecords $paths['jsonl']
    $seen = New-NSOrdinalMap
    $code = 0
    foreach ($record in $records) {
        $id = Get-NSMapValue $record 'id'
        $key = ConvertTo-NSCanonicalJson $id -Compact
        $previous = $null
        if ($seen.Contains($key)) { $previous = $seen[$key] }
        $errors = Test-NSEvidenceRecord $record $schema $previous
        if ($errors.Count -gt 0) {
            $code = 2
            $label = '?'
            if (Test-NSPyTruthy $id) { $label = ConvertTo-NSPyText $id }
            foreach ($error in $errors) { Write-NSEvidenceError ('evidence: ' + $label + ': ' + $error) }
        }
        if (Test-NSPyTruthy $id) { $seen[$key] = $record }
    }
    return $code
}

function Invoke-NSEvidenceAppend {
    param(
        [Parameter(Mandatory = $true)][string]$Project,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$RecordJson,
        [AllowEmptyString()][string]$RawText = ''
    )
    $paths = Get-NSEvidencePaths $Project
    $null = Invoke-NSEvidenceInit -Project $Project -Quiet
    $record = ConvertFrom-NSJsonText $RecordJson
    if ($record -is [Collections.IDictionary]) {
        if (-not $record.Contains('schemaVersion')) { $record['schemaVersion'] = 1 }
        if (-not $record.Contains('firstSeen')) { $record['firstSeen'] = Get-NSEvidenceNow }
        if (-not $record.Contains('lastChecked')) { $record['lastChecked'] = $record['firstSeen'] }
        if (-not $record.Contains('digest')) {
            $record['digest'] = Get-NSTextSha256 (ConvertTo-NSCanonicalJson $record -Compact)
        }
        foreach ($key in @('action', 'fix', 'verificationLocator', 'disposition', 'rollback')) {
            if (-not $record.Contains($key)) { $record[$key] = '' }
        }
        $source = Get-NSMapValue $record 'source'
        if (-not (Test-NSPyTruthy $source)) { $source = Get-NSMapValue $record 'sourceCommand' }
        if (-not (Test-NSPyTruthy $source)) { $source = '' }
        $record['source'] = $source
        $sourceClass = Get-NSMapValue $record 'sourceClass'
        if (-not (Test-NSPyTruthy $sourceClass)) { $sourceClass = Get-NSMapValue $record 'sourceTool' }
        if (-not (Test-NSPyTruthy $sourceClass)) { $sourceClass = 'unknown' }
        $record['sourceClass'] = $sourceClass
    }
    $schema = Get-NSSchemaDocument 'finding.json'
    $records = Read-NSEvidenceRecords $paths['jsonl']
    $previous = $null
    foreach ($existing in $records) {
        if (Test-NSPyEqual (Get-NSMapValue $existing 'id') (Get-NSMapValue $record 'id')) {
            $previous = $existing
            break
        }
    }
    $errors = Test-NSEvidenceRecord $record $schema $previous
    if ($errors.Count -gt 0) {
        foreach ($error in $errors) { Write-NSEvidenceError ('evidence: ' + $error) }
        return 2
    }
    if (Test-NSPyTruthy $RawText) {
        $contained = Get-NSEvidenceRawDestination -Ns $paths['ns'] -Id ([string](Get-NSMapValue $record 'id'))
        if ($null -eq $contained) {
            Write-NSEvidenceError 'evidence: invalid id'
            return 2
        }
        $record['rawPath'] = [string]$contained['rel']
        $onDisk = $RawText
        if (-not $RawText.EndsWith("`n")) { $onDisk = $RawText + "`n" }
        Write-NSEvidenceFile -Path ([string]$contained['abs']) -Text $onDisk
        $record['rawDigest'] = Get-NSTextSha256 $RawText
    }
    $records.Add($record)
    Write-NSEvidenceRecords -Path $paths['jsonl'] -Records $records
    Write-NSEvidenceOut (ConvertTo-NSPyText (Get-NSMapValue $record 'id'))
    return 0
}

function Invoke-NSEvidenceDisposition {
    param(
        [Parameter(Mandatory = $true)][string]$Project,
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Disposition,
        [AllowEmptyString()][string]$Ladder = ''
    )
    $paths = Get-NSEvidencePaths $Project
    $records = Read-NSEvidenceRecords $paths['jsonl']
    $schema = Get-NSSchemaDocument 'finding.json'
    $found = $false
    foreach ($record in $records) {
        $recordId = Get-NSMapValue $record 'id'
        if (-not (($recordId -is [string]) -and ($recordId -ceq $Id))) { continue }
        $found = $true
        $previous = Copy-NSMap $record
        $record['disposition'] = $Disposition
        $record['lastChecked'] = Get-NSEvidenceNow
        if (Test-NSPyTruthy $Ladder) { $record['ladder'] = $Ladder }
        $errors = Test-NSEvidenceRecord $record $schema $previous
        if ($errors.Count -gt 0) {
            foreach ($error in $errors) { Write-NSEvidenceError ('evidence: ' + $error) }
            return 2
        }
    }
    if (-not $found) {
        Write-NSEvidenceError ('evidence: unknown id ' + $Id)
        return 2
    }
    Write-NSEvidenceRecords -Path $paths['jsonl'] -Records $records
    return 0
}

function Get-NSEvidenceMarkdown {
    param($Records)
    $dash = [string][char]0x2014
    $lines = New-Object Collections.Generic.List[string]
    $lines.Add('# Evidence ledger')
    $lines.Add('')
    $lines.Add('Machine source: `evidence/findings.jsonl`. Helpers validate records; they do not')
    $lines.Add('verify a Nightshift tick or interpret domain meaning.')
    $lines.Add('')
    $lines.Add('| ID | Domain | Severity | Ladder | Status | Locator |')
    $lines.Add('| --- | --- | --- | --- | --- | --- |')
    $count = 0
    foreach ($record in $Records) {
        $cells = New-Object Collections.Generic.List[string]
        foreach ($column in @('id', 'domain', 'severity', 'ladder', 'status', 'locator')) {
            $cells.Add((ConvertTo-NSPyText (Get-NSMapValue $record $column)))
        }
        $lines.Add('| ' + ($cells -join ' | ') + ' |')
        $count++
    }
    if ($count -eq 0) {
        $empty = @($dash, $dash, $dash, $dash, $dash, 'empty')
        $lines.Add('| ' + ($empty -join ' | ') + ' |')
    }
    return (($lines -join "`n") + "`n")
}

function Invoke-NSEvidenceRender {
    param([Parameter(Mandatory = $true)][string]$Project)
    $paths = Get-NSEvidencePaths $Project
    $records = Read-NSEvidenceRecords $paths['jsonl']
    $text = Get-NSEvidenceMarkdown $records
    $null = [IO.Directory]::CreateDirectory($paths['dir'])
    Write-NSEvidenceFile -Path $paths['md'] -Text $text
    [Console]::Out.Write($text)
    return 0
}

function Invoke-NSEvidenceExportTsv {
    param([Parameter(Mandatory = $true)][string]$Project)
    $paths = Get-NSEvidencePaths $Project
    $records = Read-NSEvidenceRecords $paths['jsonl']
    Write-NSEvidenceOut ($script:NSEvidenceTsvColumns -join "`t")
    foreach ($record in $records) {
        $cells = New-Object Collections.Generic.List[string]
        foreach ($column in $script:NSEvidenceTsvColumns) {
            $value = ''
            if (($record -is [Collections.IDictionary]) -and $record.Contains($column)) {
                $value = ConvertTo-NSPyText $record[$column]
            }
            $cells.Add($value.Replace("`t", ' '))
        }
        Write-NSEvidenceOut ($cells -join "`t")
    }
    return 0
}

function Invoke-NSEvidenceMigrate {
    param([Parameter(Mandatory = $true)][string]$Project)
    $paths = Get-NSEvidencePaths $Project
    $hasDir = Test-Path -LiteralPath $paths['dir'] -PathType Container
    $hasLedger = Test-Path -LiteralPath $paths['jsonl'] -PathType Leaf
    if (-not $hasDir -and -not $hasLedger) {
        Write-NSEvidenceOut 'evidence: nothing to migrate'
        return 0
    }
    $version = '0'
    if (Test-Path -LiteralPath $paths['version'] -PathType Leaf) {
        $version = ([IO.File]::ReadAllText($paths['version'], $script:NSUtf8NoBom)).Trim()
        if ($version.Length -eq 0) { $version = '0' }
    }
    if (($version -ceq '0') -or ($version -ceq '1')) {
        $null = [IO.Directory]::CreateDirectory($paths['raw'])
        Write-NSEvidenceFile -Path $paths['version'] -Text "1`n"
        if (-not (Test-Path -LiteralPath $paths['jsonl'] -PathType Leaf)) {
            Write-NSEvidenceFile -Path $paths['jsonl'] -Text ''
        }
        Write-NSEvidenceOut 'evidence: schema-version 1'
        return 0
    }
    Write-NSEvidenceError ('evidence: unsupported evidence schema-version ' + $version)
    return 2
}

function Invoke-NSEvidenceCommand {
    param(
        [AllowEmptyString()][string]$Project = '',
        [AllowEmptyString()][string]$Command = '',
        [AllowEmptyString()][string]$Record = '',
        [AllowEmptyString()][string]$Raw = '',
        [AllowEmptyString()][string]$Id = '',
        [AllowEmptyString()][string]$Disposition = '',
        [AllowEmptyString()][string]$Ladder = ''
    )
    try {
        if ([string]::IsNullOrEmpty($Project) -or [string]::IsNullOrEmpty($Command)) { return (Write-NSEvidenceUsage) }
        switch ($Command) {
            'init' { return (Invoke-NSEvidenceInit -Project $Project) }
            'validate' { return (Invoke-NSEvidenceValidate -Project $Project) }
            'append' {
                if ([string]::IsNullOrEmpty($Record)) { return (Write-NSEvidenceUsage) }
                return (Invoke-NSEvidenceAppend -Project $Project -RecordJson $Record -RawText $Raw)
            }
            'disposition' {
                if ([string]::IsNullOrEmpty($Id) -or [string]::IsNullOrEmpty($Disposition)) { return (Write-NSEvidenceUsage) }
                return (Invoke-NSEvidenceDisposition -Project $Project -Id $Id -Disposition $Disposition -Ladder $Ladder)
            }
            'render' { return (Invoke-NSEvidenceRender -Project $Project) }
            'export-tsv' { return (Invoke-NSEvidenceExportTsv -Project $Project) }
            'migrate' { return (Invoke-NSEvidenceMigrate -Project $Project) }
        }
        return (Write-NSEvidenceUsage)
    }
    catch [ApplicationException] {
        Write-NSEvidenceError $_.Exception.Message
        return 1
    }
}

# ---------------------------------------------------------------------------
# Layered shift policy - the native side of runtime/windows/shift-policy.ps1,
# preflight-needs.ps1 and park-needs.ps1.
#
# rules.json carries the permanent boundaries, shift-defaults.json only prefills
# the next composition question, and shift-policy.json is tonight's snapshot.
# Get-NSPolicyResolution is the one resolver: hardhat, Start, Doctor, Status and
# the support bundle render what it returns and never re-derive precedence.
# ---------------------------------------------------------------------------

$script:NSPolicyCategories = @('sudo', 'containers', 'global-packages', 'daemons', 'external-services')
$script:NSPolicyVerificationLevels = @('none', 'final', 'per-item', 'custom')
$script:NSPolicyToolingPolicies = @('existing-tools', 'review-missing', 'auto-add')
$script:NSPolicyProfiles = @('fast', 'balanced', 'strict', 'custom')
$script:NSPolicyExecutions = @('review-first', 'run-direct')
$script:NSPolicySources = @('composition', 'start-defaults')
$script:NSPolicyScopes = @('category', 'exact-plan')
$script:NSPolicyProvenances = @('rules', 'one-shift')

$script:NSPolicyCompletionModes = @('clear-all', 'no-regression-plus-selected-debt')
$script:NSPolicyCompletionDefault = 'clear-all'

# Shipped elevation patterns (grep -E), used for any category rules.json does not
# carry. Preflight and the hardhat guard read them through Get-NSElevationPattern,
# so the signal that parks an item is the signal that blocks the command. The rules
# template and lib/policy.sh carry the same text, so a category answers alike on
# either engine and whether or not the owner's file names it.
$script:NSPolicyElevationPattern = New-Object Collections.Specialized.OrderedDictionary([StringComparer]::Ordinal)
$script:NSPolicyElevationPattern['sudo'] = '(^|[;&|(`]|[[:space:]]|''|")(/[A-Za-z0-9._-]+)*/*(sudo|d[o]as)([[:space:]]|[;&|)''"`]|$)'
$script:NSPolicyElevationPattern['containers'] = '(/var/run/docker\.sock|unix://[^ \t]*docker\.sock|DOCKER_HOST=)|(^|[;&|(`]|[[:space:]]|''|")(docker-compose)[[:space:]]+(up|run|start|build|down|create)|(^|[;&|(`]|[[:space:]]|''|")(docker|podman|nerdctl|colima)[[:space:]]+(run|create|start|build|compose[[:space:]]+(up|run|start|build|down|create))'
$script:NSPolicyElevationPattern['global-packages'] = '(^|[;&|(`]|[[:space:]]|''|")(brew|apt|apt-get|dnf|yum|pacman|choco|winget|scoop)[[:space:]]+(install|upgrade|uninstall|remove|reinstall)|npm[[:space:]]+(i|install)[[:space:]]+(-g|--global)|pnpm[[:space:]]+add[[:space:]]+-g|yarn[[:space:]]+global|(pip3?|cargo|go)[[:space:]]+install'
$script:NSPolicyElevationPattern['daemons'] = '(^|[;&|(`]|[[:space:]]|''|")(systemctl|launchctl|service|brew[[:space:]]+services|pg_ctl|redis-server|mongod|mysqld)([[:space:]]|$)'
$script:NSPolicyElevationPattern['external-services'] = '(^|[;&|(`]|[[:space:]]|''|")(gh[[:space:]]+auth[[:space:]]+login|npm[[:space:]]+login|docker[[:space:]]+login|az[[:space:]]+login|gcloud[[:space:]]+auth|aws[[:space:]]+configure)([[:space:]]|$)'

# Every setting the resolved view reports, in the order the table prints them.
# The owner preference blocks the resolved view carries, with the built-in each falls back to.
# The same list as NS_RULES_GROUP_KEYS in lib/rules-read.sh, and the same defaults as
# ns_policy_builtin in lib/policy.sh: both resolvers print one view.
$script:NSPolicyGroupDefaults = New-Object Collections.Specialized.OrderedDictionary([StringComparer]::Ordinal)
$script:NSPolicyGroupDefaults['archive.automatic'] = $false
$script:NSPolicyGroupDefaults['archive.layout'] = 'date'
$script:NSPolicyGroupDefaults['archive.root'] = 'archive'
$script:NSPolicyGroupDefaults['archive.templatePath'] = ''
$script:NSPolicyGroupDefaults['handoff.detail'] = 'concise'
$script:NSPolicyGroupDefaults['handoff.enabled'] = $true
$script:NSPolicyGroupDefaults['handoff.language'] = 'auto'
$script:NSPolicyGroupDefaults['handoff.sections'] = @()
$script:NSPolicyGroupDefaults['handoff.templatePath'] = ''
$script:NSPolicyGroupDefaults['handoff.view'] = 'owner'
$script:NSPolicyGroupDefaults['recovery.launchScope'] = 'inherit-recorded-scope'
$script:NSPolicyGroupDefaults['report.enabled'] = $true
$script:NSPolicyGroupDefaults['report.legacyItemReceipts'] = $false
$script:NSPolicyGroupDefaults['report.progressMinutes'] = 20
$script:NSPolicyGroupDefaults['report.progressMode'] = 'time'
$script:NSPolicyGroupDefaults['report.progressTokens'] = 100000
$script:NSPolicyGroupDefaults['report.templatePath'] = ''
$script:NSPolicyGroupDefaults['report.usage'] = 'when-available'
$script:NSPolicyGroupDefaults['shift.execution'] = 'review-first'
$script:NSPolicyGroupDefaults['shift.hours'] = $null
$script:NSPolicyGroupDefaults['shift.toolingPolicy'] = 'existing-tools'
$script:NSPolicyGroupDefaults['shift.verificationProfile'] = 'fast'

$script:NSPolicySettingNames = @(
    'archive.automatic',
    'archive.layout',
    'archive.root',
    'archive.templatePath',
    'deadlineEpoch',
    'elevation.containers',
    'elevation.daemons',
    'elevation.external-services',
    'elevation.global-packages',
    'elevation.sudo',
    'expectedEmail',
    'forbiddenCommands',
    'handoff.detail',
    'handoff.enabled',
    'handoff.language',
    'handoff.sections',
    'handoff.templatePath',
    'handoff.view',
    'neverCommitPatterns',
    'protectedDirs',
    'recovery.launchScope',
    'report.enabled',
    'report.legacyItemReceipts',
    'report.progressMinutes',
    'report.progressMode',
    'report.progressTokens',
    'report.templatePath',
    'report.usage',
    'shift.execution',
    'shift.hours',
    'shift.toolingPolicy',
    'shift.verificationProfile',
    'stallMax',
    'toolingPolicy',
    'verificationLevel',
    'watchMinutes'
)

function Write-NSPolicyOut {
    param([AllowEmptyString()][string]$Text)
    [Console]::Out.Write($Text)
    [Console]::Out.Write("`n")
}

function Write-NSPolicyError {
    param([AllowEmptyString()][string]$Text)
    [Console]::Error.WriteLine($Text)
}

function Get-NSPolicyNow {
    $fixed = $env:NIGHTSHIFT_POLICY_NOW
    if (-not [string]::IsNullOrEmpty($fixed)) { return $fixed }
    return [DateTime]::UtcNow.ToString('yyyy-MM-dd\THH:mm:ss\Z', [Globalization.CultureInfo]::InvariantCulture)
}

function Get-NSPolicyPaths {
    param([Parameter(Mandatory = $true)][string]$Workspace)
    $ns = Join-NSPath (Get-NSAbsolutePath $Workspace) '.nightshift'
    $paths = New-NSOrdinalMap
    $paths['ns'] = $ns
    $paths['policy'] = Join-NSPath $ns 'shift-policy.json'
    $paths['defaults'] = Join-NSPath $ns 'shift-defaults.json'
    $paths['deadline'] = Join-NSPath $ns 'deadline'
    $paths['armed'] = Join-NSPath $ns '.shift-armed'
    $paths['archive'] = Join-NSPath $ns 'archive'
    $paths['punch'] = Join-NSPath $ns 'punch-list.md'
    $paths['orders'] = Join-NSPath $ns 'work-orders.md'
    $paths['parking'] = Join-NSPath $ns 'parking-lot.md'
    $paths['rules'] = Join-NSPath $ns 'rules.json'
    return $paths
}

function Test-NSPolicyArmed {
    param([Parameter(Mandatory = $true)][string]$Workspace)
    return (Test-Path -LiteralPath (Get-NSPolicyPaths $Workspace)['armed'] -PathType Leaf)
}

# .NET has no POSIX character classes; the shipped patterns and any owner pattern
# in rules.elevation are grep -E. Same table as the hardhat hook's converter.
function Convert-NSPolicyErePattern {
    param([Parameter(Mandatory = $true)][string]$Pattern)
    $result = $Pattern.Replace('[[:space:]]', '\s')
    $result = $result.Replace('[[:blank:]]', '[ \t]')
    $result = $result.Replace('[[:digit:]]', '\d')
    $result = $result.Replace('[[:alnum:]]', '[A-Za-z0-9]')
    $result = $result.Replace('[[:alpha:]]', '[A-Za-z]')
    $result = $result.Replace('[[:lower:]]', '[a-z]')
    $result = $result.Replace('[[:upper:]]', '[A-Z]')
    $result = $result.Replace('[[:xdigit:]]', '[A-Fa-f0-9]')
    if ($result -match '\[:[a-z]+:\]') {
        throw 'unmapped POSIX character class'
    }
    return $result
}

function New-NSPolicyRegex {
    param([Parameter(Mandatory = $true)][string]$Pattern)
    return [Text.RegularExpressions.Regex]::new(
        (Convert-NSPolicyErePattern $Pattern),
        [Text.RegularExpressions.RegexOptions]::Multiline)
}

function Get-NSRulesElevationEntry {
    param(
        [Parameter(Mandatory = $true)][string]$Workspace,
        [Parameter(Mandatory = $true)][string]$Category
    )
    $rules = Get-NSRulesObject $Workspace
    if ($null -eq $rules) { return $null }
    $elevation = Get-NSJsonProperty $rules 'elevation'
    if ($null -eq $elevation) { return $null }
    return (Get-NSJsonProperty $elevation $Category)
}

function Get-NSElevationPattern {
    param(
        [Parameter(Mandatory = $true)][string]$Workspace,
        [Parameter(Mandatory = $true)][string]$Category
    )
    if (-not ($script:NSPolicyCategories -ccontains $Category)) { return '' }
    $entry = Get-NSRulesElevationEntry $Workspace $Category
    if ($null -ne $entry) {
        $pattern = Get-NSJsonProperty $entry 'pattern'
        if (($pattern -is [string]) -and $pattern.Length -gt 0) { return $pattern }
    }
    return [string]$script:NSPolicyElevationPattern[$Category]
}

function Get-NSElevationRulePolicy {
    param(
        [Parameter(Mandatory = $true)][string]$Workspace,
        [Parameter(Mandatory = $true)][string]$Category
    )
    $entry = Get-NSRulesElevationEntry $Workspace $Category
    if ($null -eq $entry) { return '' }
    $policy = Get-NSJsonProperty $entry 'policy'
    if (($policy -is [string]) -and (($policy -ceq 'allow') -or ($policy -ceq 'deny'))) { return $policy }
    return ''
}

# ---------------------------------------------------------------------------
# shift-policy.json
# ---------------------------------------------------------------------------

# A function that returns an array unrolls it, so a one-command plan would come
# back as a bare string. The comma keeps an array an array and a scalar a scalar.
function Get-NSPolicyField {
    param($Map, [Parameter(Mandatory = $true)][string]$Key)
    if (-not ($Map -is [Collections.IDictionary])) { return $null }
    if (-not $Map.Contains($Key)) { return $null }
    return , $Map[$Key]
}

function Test-NSPolicyShiftId {
    param($Value)
    if (-not ($Value -is [string])) { return $false }
    if ($Value -cmatch '^[0-9a-f]{16}$') { return $true }
    return ($Value -cmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
}

function Test-NSPolicyDigest {
    param($Value)
    return (($Value -is [string]) -and ($Value -cmatch '^[0-9a-f]{64}$'))
}

# The schema lives at references/schemas/v1/shift-policy.json; these are the same
# constraints, applied without a file read so a helper still validates on a host
# whose plugin tree is read-only or partially installed.
function Test-NSShiftPolicyDocument {
    param($Document)
    $errors = New-Object Collections.Generic.List[string]
    if (-not ($Document -is [Collections.IDictionary])) {
        $errors.Add('document: not a JSON object')
        return , $errors
    }
    $known = @('schemaVersion', 'shiftId', 'createdAt', 'source', 'deadlineEpoch',
        'verificationLevel', 'toolingPolicy', 'launchScope', 'launchProvenance', 'budgets',
        'allowances', 'gatesDigest', 'completionMode', 'selectedDebt',
        'shift', 'recovery', 'handoff', 'archive', 'report')
    foreach ($key in @($Document.Keys)) {
        if (-not ($known -ccontains [string]$key)) {
            $errors.Add(([string]$key) + ': unknown field')
        }
    }
    foreach ($key in @('schemaVersion', 'shiftId', 'createdAt', 'source', 'verificationLevel', 'toolingPolicy')) {
        if (-not $Document.Contains($key)) { $errors.Add($key + ': missing') }
    }
    if ($Document.Contains('schemaVersion') -and -not (Test-NSEvidenceSchemaOne $Document['schemaVersion'])) {
        $errors.Add('schemaVersion: must be 1')
    }
    if ($Document.Contains('shiftId') -and -not (Test-NSPolicyShiftId $Document['shiftId'])) {
        $errors.Add('shiftId: must be a uuid or 16 lowercase hex characters')
    }
    if ($Document.Contains('createdAt') -and -not (($Document['createdAt'] -is [string]) -and ($Document['createdAt'] -cmatch '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'))) {
        $errors.Add('createdAt: must be YYYY-MM-DDTHH:MM:SSZ')
    }
    if ($Document.Contains('source') -and -not (Test-NSEvidenceEnum $Document['source'] $script:NSPolicySources)) {
        $errors.Add('source: must be one of ' + ($script:NSPolicySources -join ', '))
    }
    if ($Document.Contains('verificationLevel') -and -not (Test-NSEvidenceEnum $Document['verificationLevel'] $script:NSPolicyVerificationLevels)) {
        $errors.Add('verificationLevel: must be one of ' + ($script:NSPolicyVerificationLevels -join ', '))
    }
    if ($Document.Contains('toolingPolicy') -and -not (Test-NSEvidenceEnum $Document['toolingPolicy'] $script:NSPolicyToolingPolicies)) {
        $errors.Add('toolingPolicy: must be one of ' + ($script:NSPolicyToolingPolicies -join ', '))
    }
    if ($Document.Contains('completionMode') -and -not (Test-NSEvidenceEnum $Document['completionMode'] $script:NSPolicyCompletionModes)) {
        $errors.Add('completionMode: must be one of ' + ($script:NSPolicyCompletionModes -join ', '))
    }
    if ($Document.Contains('selectedDebt')) {
        $debt = Get-NSPolicyField $Document 'selectedDebt'
        if (($debt -is [Collections.IDictionary]) -or ($debt -is [string]) -or -not ($debt -is [Collections.IEnumerable])) {
            $errors.Add('selectedDebt: must be an array of finding ids')
        }
        else {
            foreach ($id in @($debt)) {
                if (-not (($id -is [string]) -and $id.Trim().Length -gt 0)) {
                    $errors.Add('selectedDebt: must be an array of non-empty strings')
                    break
                }
            }
        }
    }
    if ($Document.Contains('deadlineEpoch')) {
        $deadline = $Document['deadlineEpoch']
        if ($null -ne $deadline -and -not (Test-NSJsonInteger $deadline)) {
            $errors.Add('deadlineEpoch: must be an integer or null')
        }
    }
    if ($Document.Contains('gatesDigest') -and -not (Test-NSPolicyDigest $Document['gatesDigest'])) {
        $errors.Add('gatesDigest: must be 64 lowercase hex characters')
    }
    if ($Document.Contains('budgets')) {
        $budgets = $Document['budgets']
        if (-not ($budgets -is [Collections.IDictionary])) {
            $errors.Add('budgets: must be an object of integers')
        }
        else {
            foreach ($key in @($budgets.Keys)) {
                if (-not (Test-NSJsonInteger $budgets[$key])) {
                    $errors.Add('budgets.' + ([string]$key) + ': must be an integer')
                }
            }
        }
    }
    if ($Document.Contains('allowances')) {
        $allowances = $Document['allowances']
        if (($allowances -is [Collections.IDictionary]) -or ($allowances -is [string]) -or -not ($allowances -is [Collections.IEnumerable])) {
            $errors.Add('allowances: must be an array')
        }
        else {
            $index = 0
            foreach ($allowance in @($allowances)) {
                $label = 'allowances[' + $index + ']'
                $index++
                if (-not ($allowance -is [Collections.IDictionary])) {
                    $errors.Add($label + ': not a JSON object')
                    continue
                }
                foreach ($key in @($allowance.Keys)) {
                    if (-not (@('category', 'scope', 'provenance', 'plan') -ccontains [string]$key)) {
                        $errors.Add($label + '.' + ([string]$key) + ': unknown field')
                    }
                }
                if (-not (Test-NSEvidenceEnum (Get-NSMapValue $allowance 'category') $script:NSPolicyCategories)) {
                    $errors.Add($label + '.category: must be one of ' + ($script:NSPolicyCategories -join ', '))
                }
                if (-not (Test-NSEvidenceEnum (Get-NSMapValue $allowance 'scope') $script:NSPolicyScopes)) {
                    $errors.Add($label + '.scope: must be one of ' + ($script:NSPolicyScopes -join ', '))
                }
                if (-not (Test-NSEvidenceEnum (Get-NSMapValue $allowance 'provenance') $script:NSPolicyProvenances)) {
                    $errors.Add($label + '.provenance: must be one of ' + ($script:NSPolicyProvenances -join ', '))
                }
                $scope = Get-NSMapValue $allowance 'scope'
                $plan = Get-NSMapValue $allowance 'plan'
                if (($scope -is [string]) -and ($scope -ceq 'exact-plan')) {
                    foreach ($planError in (Test-NSPolicyPlan $plan ($label + '.plan'))) { $errors.Add($planError) }
                }
                elseif ($null -ne $plan) {
                    $errors.Add($label + '.plan: only an exact-plan allowance carries a plan')
                }
            }
        }
    }
    return , $errors
}

function Test-NSPolicyPlan {
    param($Plan, [Parameter(Mandatory = $true)][string]$Label)
    $errors = New-Object Collections.Generic.List[string]
    if (-not ($Plan -is [Collections.IDictionary])) {
        $errors.Add($Label + ': an exact-plan allowance needs a plan object')
        return , $errors
    }
    foreach ($key in @($Plan.Keys)) {
        if (-not (@('commands', 'workTarget', 'digest', 'expiry') -ccontains [string]$key)) {
            $errors.Add($Label + '.' + ([string]$key) + ': unknown field')
        }
    }
    $commands = Get-NSPolicyField $Plan 'commands'
    if (($commands -is [Collections.IDictionary]) -or ($commands -is [string]) -or -not ($commands -is [Collections.IEnumerable])) {
        $errors.Add($Label + '.commands: must be an array of strings')
    }
    else {
        $items = @($commands)
        if ($items.Count -eq 0) {
            $errors.Add($Label + '.commands: must list at least one command')
        }
        foreach ($command in $items) {
            if (-not (($command -is [string]) -and $command.Trim().Length -gt 0)) {
                $errors.Add($Label + '.commands: must be an array of non-empty strings')
                break
            }
        }
    }
    $target = Get-NSMapValue $Plan 'workTarget'
    if (-not (($target -is [string]) -and $target.Length -gt 0 -and [IO.Path]::IsPathRooted($target))) {
        $errors.Add($Label + '.workTarget: must be an absolute path')
    }
    if ($Plan.Contains('expiry')) {
        $expiry = $Plan['expiry']
        if ($null -ne $expiry -and -not (Test-NSJsonInteger $expiry)) {
            $errors.Add($Label + '.expiry: must be a UNIX epoch integer or null')
        }
    }
    if (-not (Test-NSPolicyDigest (Get-NSMapValue $Plan 'digest'))) {
        $errors.Add($Label + '.digest: must be 64 lowercase hex characters')
    }
    return , $errors
}

# The digest an exact-plan allowance carries and hardhat recomputes: sha256 over
# the compact canonical JSON of {"commands":[...],"shiftId":...,"workTarget":...}.
# plan.expiry is checked before the digest, never inside it.
function Get-NSPolicyPlanDigest {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Commands,
        [Parameter(Mandatory = $true)][string]$WorkTarget,
        [Parameter(Mandatory = $true)][string]$ShiftId
    )
    $normalized = New-Object Collections.Generic.List[string]
    foreach ($command in $Commands) { $normalized.Add((Get-NSPolicyNormalizedCommand $command)) }
    $preimage = New-NSOrdinalMap
    $preimage['commands'] = $normalized.ToArray()
    $preimage['shiftId'] = $ShiftId
    $preimage['workTarget'] = $WorkTarget
    return (Get-NSTextSha256 (ConvertTo-NSCanonicalJson $preimage -Compact))
}

# Whitespace runs collapse to one space and the ends are trimmed, so a command
# approved as written matches the command as the host reports it.
function Get-NSPolicyNormalizedCommand {
    param([AllowEmptyString()][string]$Command)
    if ([string]::IsNullOrEmpty($Command)) { return '' }
    return ([regex]::Replace($Command, '\s+', ' ')).Trim()
}

function Get-NSShiftPolicyState {
    param([Parameter(Mandatory = $true)][string]$Workspace)
    $paths = Get-NSPolicyPaths $Workspace
    $state = New-NSOrdinalMap
    $state['state'] = 'absent'
    $state['error'] = ''
    $state['policy'] = $null
    $path = $paths['policy']
    if (Test-NSReparsePoint $path) {
        $state['state'] = 'malformed'
        $state['error'] = 'document: shift-policy.json is not a usable file'
        return $state
    }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $state }
    $document = $null
    try {
        $document = ConvertFrom-NSJsonText ([IO.File]::ReadAllText($path, $script:NSUtf8NoBom))
    }
    catch {
        $state['state'] = 'malformed'
        $state['error'] = 'document: not valid JSON'
        return $state
    }
    $errors = Test-NSShiftPolicyDocument $document
    if ($errors.Count -gt 0) {
        $state['state'] = 'malformed'
        $state['error'] = $errors[0]
        return $state
    }
    $state['state'] = 'valid'
    $state['policy'] = $document
    return $state
}

function Get-NSShiftPolicy {
    param([Parameter(Mandatory = $true)][string]$Workspace)
    $state = Get-NSShiftPolicyState $Workspace
    return $state['policy']
}

function Set-NSShiftPolicy {
    param(
        [Parameter(Mandatory = $true)][string]$Workspace,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Json
    )
    $paths = Get-NSPolicyPaths $Workspace
    if (-not (Test-Path -LiteralPath $paths['ns'] -PathType Container)) {
        Write-NSPolicyError ('shift-policy: no .nightshift/ at ' + $Workspace)
        return 2
    }
    if (Test-NSPolicyArmed $Workspace) {
        Write-NSPolicyError 'shift-policy: refuse to rewrite the shift policy while the shift is armed; park the need'
        return 4
    }
    $document = $null
    try {
        $document = ConvertFrom-NSJsonText $Json
    }
    catch {
        Write-NSPolicyError 'shift-policy: document: not valid JSON'
        return 2
    }
    $errors = Test-NSShiftPolicyDocument $document
    if ($errors.Count -gt 0) {
        foreach ($error in $errors) { Write-NSPolicyError ('shift-policy: ' + $error) }
        return 2
    }
    # Record what this session is actually running under, so a revival can reproduce it instead of
    # guessing. It grants nothing - it is a note of what the shift already had - and a candidate
    # that states it already is left exactly as the owner wrote it.
    # Freeze the owner's preference blocks into tonight's policy. From here the shift reads them
    # here, so an edit to rules.json lands on the next shift rather than moving the ground under
    # this one. A candidate that already states a block is left exactly as it was written.
    foreach ($block in @('shift', 'recovery', 'handoff', 'archive', 'report')) {
        if ($document.Contains($block)) { continue }
        $frozen = New-NSOrdinalMap
        foreach ($name in $script:NSPolicyGroupDefaults.Keys) {
            if (-not $name.StartsWith($block + '.', [StringComparison]::Ordinal)) { continue }
            $frozen[$name.Substring($block.Length + 1)] = (Get-NSPolicyGroupSetting $Workspace $name)['value']
        }
        if ($frozen.Count -gt 0) { $document[$block] = $frozen }
    }
    if (-not $document.Contains('launchScope')) {
        $observed = (Get-NSLaunchObserved (Get-NSPolicyHostName)) -split "`t", 2
        $document['launchScope'] = $observed[0]
        $document['launchProvenance'] = $observed[1]
    }
    Write-NSEvidenceFileAtomic -Path $paths['policy'] -Text ((ConvertTo-NSCanonicalJson $document) + "`n")
    return 0
}

# ---------------------------------------------------------------------------
# shift-defaults.json - prefill only. Nothing here is ever an effective value.
# ---------------------------------------------------------------------------

function New-NSShiftDefaultsDocument {
    $document = New-NSOrdinalMap
    $document['schemaVersion'] = 1
    $document['verificationProfile'] = 'fast'
    $document['hours'] = $null
    $document['toolingPolicy'] = 'existing-tools'
    $document['execution'] = 'review-first'
    $document['updatedAt'] = ''
    return $document
}

function Get-NSShiftDefaults {
    param([Parameter(Mandatory = $true)][string]$Workspace)
    $paths = Get-NSPolicyPaths $Workspace
    $defaults = New-NSShiftDefaultsDocument
    $path = $paths['defaults']
    # Every way out of the legacy file goes through the shift block, so a workspace that has
    # already migrated - and so has no legacy file at all - still reports what the owner chose.
    if ((Test-NSReparsePoint $path) -or -not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return (Merge-NSShiftBlockDefaults -Workspace $Workspace -Defaults $defaults)
    }
    $document = $null
    try {
        $document = ConvertFrom-NSJsonText ([IO.File]::ReadAllText($path, $script:NSUtf8NoBom))
    }
    catch {
        return (Merge-NSShiftBlockDefaults -Workspace $Workspace -Defaults $defaults)
    }
    if (-not ($document -is [Collections.IDictionary])) {
        return (Merge-NSShiftBlockDefaults -Workspace $Workspace -Defaults $defaults)
    }
    $storedProfile = Get-NSMapValue $document 'verificationProfile'
    if (Test-NSEvidenceEnum $storedProfile $script:NSPolicyProfiles) { $defaults['verificationProfile'] = $storedProfile }
    $tooling = Get-NSMapValue $document 'toolingPolicy'
    if (Test-NSEvidenceEnum $tooling $script:NSPolicyToolingPolicies) { $defaults['toolingPolicy'] = $tooling }
    $execution = Get-NSMapValue $document 'execution'
    if (Test-NSEvidenceEnum $execution $script:NSPolicyExecutions) { $defaults['execution'] = $execution }
    $hours = Get-NSMapValue $document 'hours'
    if ((Test-NSJsonInteger $hours) -and [long]$hours -ge 0) { $defaults['hours'] = [long]$hours }
    $updated = Get-NSMapValue $document 'updatedAt'
    if ($updated -is [string]) { $defaults['updatedAt'] = $updated }
    return (Merge-NSShiftBlockDefaults -Workspace $Workspace -Defaults $defaults)
}

# The shift block of the owner file is where these live now. A value stated there is the owner's
# answer and wins over the older file, which stays readable only so a workspace that has not
# migrated yet still reports the choice it remembers.
function Merge-NSShiftBlockDefaults {
    param(
        [Parameter(Mandatory = $true)][string]$Workspace,
        [Parameter(Mandatory = $true)]$Defaults
    )
    $block = Get-NSShiftBlock $Workspace
    if ($null -eq $block) { return $Defaults }
    $stored = Get-NSMapValue $block 'verificationProfile'
    if (Test-NSEvidenceEnum $stored $script:NSPolicyProfiles) { $Defaults['verificationProfile'] = $stored }
    $stored = Get-NSMapValue $block 'toolingPolicy'
    if (Test-NSEvidenceEnum $stored $script:NSPolicyToolingPolicies) { $Defaults['toolingPolicy'] = $stored }
    $stored = Get-NSMapValue $block 'execution'
    if (Test-NSEvidenceEnum $stored $script:NSPolicyExecutions) { $Defaults['execution'] = $stored }
    if ($block.Contains('hours')) {
        $stored = Get-NSMapValue $block 'hours'
        if ($null -eq $stored) { $Defaults['hours'] = $null }
        elseif ((Test-NSJsonInteger $stored) -and [long]$stored -ge 0) { $Defaults['hours'] = [long]$stored }
    }
    return $Defaults
}

# Get-NSShiftBlock <workspace> - the shift object of the owner rules file, or $null.
# Get-NSRecoveryLaunchScope <workspace> - the scope the owner chose, as written.
#
# host-grant is the documented broad grant for the host and only ever comes from the owner
# writing it. host-default adds no permission argument and takes whatever the host gives.
# Everything else - the shipped default, an absent key, an unreadable or malformed file - is
# inherit-recorded-scope, which resolves against what the shift actually recorded. Falling back
# to the broad grant because a file could not be read would hand out permissions on a parse
# error, so it never happens here.
function Get-NSRecoveryLaunchScope {
    param([Parameter(Mandatory = $true)][string]$Workspace)
    if (-not [string]::IsNullOrEmpty($env:NIGHTSHIFT_LAUNCH_SCOPE)) {
        if ($env:NIGHTSHIFT_LAUNCH_SCOPE -ceq 'host-default') { return 'host-default' }
        if ($env:NIGHTSHIFT_LAUNCH_SCOPE -ceq 'host-grant') { return 'host-grant' }
        return 'inherit-recorded-scope'
    }
    $path = (Get-NSPolicyPaths $Workspace)['rules']
    if ((Test-NSReparsePoint $path) -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { return 'inherit-recorded-scope' }
    $document = $null
    try {
        $document = ConvertFrom-NSJsonText ([IO.File]::ReadAllText($path, $script:NSUtf8NoBom))
    }
    catch {
        return 'inherit-recorded-scope'
    }
    if (-not ($document -is [Collections.IDictionary])) { return 'inherit-recorded-scope' }
    if (-not $document.Contains('recovery')) { return 'inherit-recorded-scope' }
    $block = $document['recovery']
    if (-not ($block -is [Collections.IDictionary])) { return 'inherit-recorded-scope' }
    $value = Get-NSMapValue $block 'launchScope'
    if ($value -ceq 'host-default') { return 'host-default' }
    if ($value -ceq 'host-grant') { return 'host-grant' }
    return 'inherit-recorded-scope'
}

# Get-NSStatePath <state-dir> <relative> - a nested path under the Nightshift state area, or
# $null. The whole chain is checked, not just its last component: a reparse point anywhere along
# it is what an escape actually looks like, because `linked\history` reaches outside while
# `history` is an ordinary directory nobody would question. The twin of ns_state_path.
function Get-NSStatePath {
    param(
        [Parameter(Mandatory = $true)][string]$StateDir,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Relative
    )
    if ([string]::IsNullOrEmpty($Relative) -or $Relative -ceq '.') { return $null }
    if ($Relative -cmatch '^[~/\\]' -or $Relative -cmatch '^[A-Za-z]:') { return $null }
    $path = $StateDir
    $deepest = $StateDir
    foreach ($component in ($Relative -split '[\\/]')) {
        if ([string]::IsNullOrEmpty($component) -or $component.StartsWith('.', [StringComparison]::Ordinal)) {
            return $null
        }
        $path = Join-Path $path $component
        if (Test-NSReparsePoint $path) { return $null }
        if (Test-Path -LiteralPath $path) {
            if (-not (Test-Path -LiteralPath $path -PathType Container)) { return $null }
            $deepest = $path
        }
    }
    # Compare the real paths rather than trusting that the text of one is a prefix of the other.
    $canonicalState = ''
    $canonicalDeepest = ''
    try {
        # -Force, because .nightshift is a hidden directory and Get-Item skips those without it.
        $canonicalState = (Get-Item -LiteralPath $StateDir -Force -ErrorAction Stop).FullName
        $canonicalDeepest = (Get-Item -LiteralPath $deepest -Force -ErrorAction Stop).FullName
    }
    catch {
        return $null
    }
    $canonicalState = $canonicalState.TrimEnd([IO.Path]::DirectorySeparatorChar)
    $canonicalDeepest = $canonicalDeepest.TrimEnd([IO.Path]::DirectorySeparatorChar)
    if ($canonicalDeepest -cne $canonicalState -and
        -not $canonicalDeepest.StartsWith($canonicalState + [IO.Path]::DirectorySeparatorChar, [StringComparison]::Ordinal)) {
        return $null
    }
    return $path
}

# Get-NSArchiveRoot <workspace> - the directory dated archives live in, or $null when the owner's
# name would leave the state area. The name is theirs; where it may sit is not.
function Get-NSArchiveRoot {
    param([Parameter(Mandatory = $true)][string]$Workspace)
    $name = [string](Get-NSPolicyGroupSetting $Workspace 'archive.root')['value']
    if ([string]::IsNullOrEmpty($name)) { $name = 'archive' }
    # The live records are not an archive destination: filing into them would file a shift on top
    # of the shift that is still running.
    if ($name -ceq 'receipts' -or $name -clike 'receipts/*' -or $name -clike 'receipts\*') { return $null }
    return (Get-NSStatePath (Join-Path $Workspace '.nightshift') $name)
}

# Get-NSArchiveDir <workspace> <date> <shift-id> - the directory one shift is filed into. The date
# layout groups a night together; the shift layout gives each shift its own directory. The shift
# id names the files inside either way, so two shifts on one day never collide.
function Get-NSArchiveDir {
    param(
        [Parameter(Mandatory = $true)][string]$Workspace,
        [Parameter(Mandatory = $true)][string]$Date,
        [AllowEmptyString()][string]$ShiftId = ''
    )
    $root = Get-NSArchiveRoot $Workspace
    if ($null -eq $root) { return $null }
    $layout = [string](Get-NSPolicyGroupSetting $Workspace 'archive.layout')['value']
    if ($layout -ceq 'shift' -and -not [string]::IsNullOrEmpty($ShiftId) -and $ShiftId -cne 'unknown') {
        return (Join-Path $root ('shift-' + $ShiftId))
    }
    return (Join-Path $root $Date)
}

# Test-NSArchiveDest <path> - true when one file may be written at that exact path. A directory
# containment check says nothing about the leaf: a reparse point left where a receipt is about to
# land would still carry its bytes somewhere else.
function Test-NSArchiveDest {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (Test-NSReparsePoint $Path) { return $false }
    if (-not (Test-Path -LiteralPath $Path)) { return $true }
    return (Test-Path -LiteralPath $Path -PathType Leaf)
}

# Test-NSArchiveAutomatic <workspace> - true when the owner asked for filing at clock-out.
# Filing is a copy; it never implies deleting anything.
function Test-NSArchiveAutomatic {
    param([Parameter(Mandatory = $true)][string]$Workspace)
    return ([string](Get-NSPolicyGroupSetting $Workspace 'archive.automatic')['value'] -ceq 'True')
}

# Convert-NSReportLinks <text> <archived> <back> - the report's own links, repointed for where it
# now sits. The twin of runtime/archive-links.awk, and it must answer identically: a record that
# travelled with the report is still a sibling, one that stayed live is reached back through the
# archive. A scheme, a leading slash, a bare fragment, anything already climbing with ../ and
# everything inside a fenced code block are left exactly as written.
function Convert-NSReportLinks {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Archived,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Back
    )
    $moved = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($entry in $Archived) {
        if (-not [string]::IsNullOrEmpty($entry)) { $null = $moved.Add($entry) }
    }
    $prefix = $Back
    if (-not [string]::IsNullOrEmpty($prefix) -and -not $prefix.EndsWith('/', [StringComparison]::Ordinal)) {
        $prefix = $prefix + '/'
    }

    $repoint = {
        param([string]$target)
        $hash = $target.IndexOf('#')
        $path = $target
        $fragment = ''
        if ($hash -ge 0) {
            $path = $target.Substring(0, $hash)
            $fragment = $target.Substring($hash)
        }
        if ([string]::IsNullOrEmpty($path)) { return $target }
        if ($path -cmatch '^[A-Za-z][A-Za-z0-9+.-]*:') { return $target }
        if ($path.StartsWith('/', [StringComparison]::Ordinal)) { return $target }
        if ($path.StartsWith('../', [StringComparison]::Ordinal)) { return $target }
        if ($moved.Contains($path)) { return $target }
        return ($prefix + $path + $fragment)
    }

    # No max-substrings argument: a negative one means "the last N", which would hand back the
    # whole document as a single line and let the scanner run straight through a fenced block.
    $lines = $Text -split "`n"
    $out = New-Object Collections.Generic.List[string]
    $fence = $false
    foreach ($line in $lines) {
        if ($line -cmatch '^[ \t]*(```|~~~)') {
            $fence = -not $fence
            $out.Add($line)
            continue
        }
        if ($fence) {
            $out.Add($line)
            continue
        }
        $definition = [Text.RegularExpressions.Regex]::Match($line, '^([ \t]*\[[^\]]*\]:[ \t]*)([^ \t]+)(.*)$')
        if ($definition.Success) {
            $out.Add($definition.Groups[1].Value + (& $repoint $definition.Groups[2].Value) + $definition.Groups[3].Value)
            continue
        }
        # Scanned character by character rather than substituted by pattern, so a code span or a
        # stray bracket cannot make it rewrite something that is not a link.
        $builder = New-Object Text.StringBuilder
        $i = 0
        while ($i -lt $line.Length) {
            $ch = $line[$i]
            if ($ch -ceq '`') {
                $tick = $i + 1
                while ($tick -lt $line.Length -and $line[$tick] -cne '`') { $tick++ }
                if ($tick -ge $line.Length) { $tick = $line.Length - 1 }
                $null = $builder.Append($line.Substring($i, $tick - $i + 1))
                $i = $tick + 1
                continue
            }
            if ($ch -ceq ']' -and ($i + 1) -lt $line.Length -and $line[$i + 1] -ceq '(') {
                $depth = 1
                $stop = $i + 2
                while ($stop -lt $line.Length -and $depth -gt 0) {
                    if ($line[$stop] -ceq '(') { $depth++ }
                    elseif ($line[$stop] -ceq ')') { $depth-- }
                    if ($depth -eq 0) { break }
                    $stop++
                }
                if ($depth -eq 0) {
                    $target = $line.Substring($i + 2, $stop - $i - 2)
                    $null = $builder.Append('](' + (& $repoint $target) + ')')
                    $i = $stop + 1
                    continue
                }
            }
            $null = $builder.Append($ch)
            $i++
        }
        $out.Add($builder.ToString())
    }
    return ($out -join "`n")
}

# Get-NSReportPath <workspace> - the shift's own report, the twin of ns_report_path.
function Get-NSReportPath {
    param([Parameter(Mandatory = $true)][string]$Workspace)
    return (Join-Path (Join-Path $Workspace '.nightshift') 'shift-report.md')
}

# Get-NSPolicyHostName - which host this session is, from what the host itself sets.
function Get-NSPolicyHostName {
    if (-not [string]::IsNullOrEmpty($env:CURSOR_PLUGIN_ROOT)) { return 'cursor' }
    if (-not [string]::IsNullOrEmpty($env:CODEX_PROJECT_DIR) -or
        -not [string]::IsNullOrEmpty($env:CODEX_SANDBOX) -or
        -not [string]::IsNullOrEmpty($env:CODEX_SANDBOX_MODE)) { return 'codex' }
    if (-not [string]::IsNullOrEmpty($env:CLAUDE_PLUGIN_ROOT) -or
        -not [string]::IsNullOrEmpty($env:CLAUDE_PROJECT_DIR)) { return 'claude' }
    return 'unknown'
}

# Test-NSLaunchScopeSupported <host> <scope> - true when the host can actually be asked to start
# a session at that scope. Nothing outside this vocabulary reaches a native flag.
function Test-NSLaunchScopeSupported {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$HostName,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Scope
    )
    if ($HostName -cne 'codex') { return $false }
    return @('read-only', 'workspace-write', 'danger-full-access') -ccontains $Scope
}

# Get-NSLaunchObserved <host> - the scope this session runs under in the host's own words, and
# whether the host actually said so, joined by a tab. Only Codex names a session's sandbox.
# Claude Code and Cursor expose no name for one anywhere a hook can read it, so there is nothing
# to observe and this reports that rather than inventing a label for it.
function Get-NSLaunchObserved {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$HostName)
    if ($HostName -ceq 'codex') {
        if (-not [string]::IsNullOrEmpty($env:CODEX_SANDBOX_MODE)) {
            return ($env:CODEX_SANDBOX_MODE + "`tobserved")
        }
        if (-not [string]::IsNullOrEmpty($env:CODEX_SANDBOX)) {
            return ($env:CODEX_SANDBOX + "`tobserved")
        }
    }
    return "unknown`tunavailable"
}

# Get-NSRecoveryEffectiveScope <workspace> <host> - what a revival may actually ask for. The same
# four answers as the POSIX resolver, decided the same way:
#
#   host-default      the owner asked for it, or no scope was ever recorded. No permission
#                     argument is passed. It is the baseline, not a claim of being narrower than
#                     the original session.
#   host-grant        the owner wrote it by name.
#   recorded:<scope>  a scope the host observed and can be asked for again.
#   unavailable:<s>   a recorded scope this host cannot request, so the caller refuses.
function Get-NSRecoveryEffectiveScope {
    param(
        [Parameter(Mandatory = $true)][string]$Workspace,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$HostName
    )
    $configured = Get-NSRecoveryLaunchScope $Workspace
    if ($configured -ceq 'host-default' -or $configured -ceq 'host-grant') { return $configured }
    $recorded = Get-NSPolicyLaunch -Workspace $Workspace -Field 'scope'
    $provenance = Get-NSPolicyLaunch -Workspace $Workspace -Field 'provenance'
    if ($provenance -ceq 'observed' -and -not [string]::IsNullOrEmpty($recorded) -and $recorded -cne 'unknown') {
        if (Test-NSLaunchScopeSupported $HostName $recorded) { return ('recorded:' + $recorded) }
        return ('unavailable:' + $recorded)
    }
    return 'host-default'
}

# Get-NSPolicyLaunch <workspace> <scope|provenance> - what the snapshot recorded about the scope
# the shift was started under. A field the snapshot never carried is empty, never a guess.
function Get-NSPolicyLaunch {
    param(
        [Parameter(Mandatory = $true)][string]$Workspace,
        [Parameter(Mandatory = $true)][ValidateSet('scope', 'provenance')][string]$Field
    )
    $path = (Get-NSPolicyPaths $Workspace)['policy']
    if ((Test-NSReparsePoint $path) -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { return '' }
    $document = $null
    try {
        $document = ConvertFrom-NSJsonText ([IO.File]::ReadAllText($path, $script:NSUtf8NoBom))
    }
    catch {
        return ''
    }
    if (-not ($document -is [Collections.IDictionary])) { return '' }
    $key = 'launchScope'
    if ($Field -ceq 'provenance') { $key = 'launchProvenance' }
    $value = Get-NSMapValue $document $key
    if ($value -is [string]) { return $value }
    return ''
}

function Get-NSShiftBlock {
    param([Parameter(Mandatory = $true)][string]$Workspace)
    $path = (Get-NSPolicyPaths $Workspace)['rules']
    if ((Test-NSReparsePoint $path) -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    $document = $null
    try {
        $document = ConvertFrom-NSJsonText ([IO.File]::ReadAllText($path, $script:NSUtf8NoBom))
    }
    catch {
        return $null
    }
    if (-not ($document -is [Collections.IDictionary])) { return $null }
    if (-not $document.Contains('shift')) { return $null }
    $block = $document['shift']
    if (-not ($block -is [Collections.IDictionary])) { return $null }
    return $block
}

# Set-NSShiftBlock <workspace> <block> — the owner file with its shift block replaced. Every other
# key survives, including one a later version added.
function Set-NSShiftBlock {
    param(
        [Parameter(Mandatory = $true)][string]$Workspace,
        [Parameter(Mandatory = $true)]$Block
    )
    $path = (Get-NSPolicyPaths $Workspace)['rules']
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        Write-NSPolicyError ('shift-policy: no owner rules file at ' + $path + ' - run setup first')
        return 2
    }
    $document = $null
    try {
        $document = ConvertFrom-NSJsonText ([IO.File]::ReadAllText($path, $script:NSUtf8NoBom))
    }
    catch {
        Write-NSPolicyError ('shift-policy: ' + $path + ' is not readable')
        return 2
    }
    if (-not ($document -is [Collections.IDictionary])) {
        Write-NSPolicyError ('shift-policy: ' + $path + ' is not a JSON object')
        return 2
    }
    $document['shift'] = $Block
    Write-NSEvidenceFileAtomic -Path $path -Text ((ConvertTo-NSCanonicalJson $document) + "`n")
    return 0
}

function Set-NSShiftDefaults {
    param(
        [Parameter(Mandatory = $true)][string]$Workspace,
        [AllowEmptyString()][string]$VerificationProfile = '',
        [AllowEmptyString()][string]$Hours = '',
        [AllowEmptyString()][string]$ToolingPolicy = '',
        [AllowEmptyString()][string]$Execution = ''
    )
    $paths = Get-NSPolicyPaths $Workspace
    if (-not (Test-Path -LiteralPath $paths['ns'] -PathType Container)) {
        Write-NSPolicyError ('shift-policy: no .nightshift/ at ' + $Workspace)
        return 2
    }
    if (Test-NSPolicyArmed $Workspace) {
        Write-NSPolicyError 'shift-policy: refuse to rewrite the shift defaults while the shift is armed; park the need'
        return 4
    }
    $document = Get-NSShiftDefaults $Workspace
    if (-not [string]::IsNullOrEmpty($VerificationProfile)) {
        if (-not (Test-NSEvidenceEnum $VerificationProfile $script:NSPolicyProfiles)) {
            Write-NSPolicyError ('shift-policy: verificationProfile: must be one of ' + ($script:NSPolicyProfiles -join ', '))
            return 2
        }
        $document['verificationProfile'] = $VerificationProfile
    }
    if (-not [string]::IsNullOrEmpty($ToolingPolicy)) {
        if (-not (Test-NSEvidenceEnum $ToolingPolicy $script:NSPolicyToolingPolicies)) {
            Write-NSPolicyError ('shift-policy: toolingPolicy: must be one of ' + ($script:NSPolicyToolingPolicies -join ', '))
            return 2
        }
        $document['toolingPolicy'] = $ToolingPolicy
    }
    if (-not [string]::IsNullOrEmpty($Execution)) {
        if (-not (Test-NSEvidenceEnum $Execution $script:NSPolicyExecutions)) {
            Write-NSPolicyError ('shift-policy: execution: must be one of ' + ($script:NSPolicyExecutions -join ', '))
            return 2
        }
        $document['execution'] = $Execution
    }
    if (-not [string]::IsNullOrEmpty($Hours)) {
        if ($Hours -ceq 'null') {
            $document['hours'] = $null
        }
        elseif ($Hours -cmatch '^[0-9]+$') {
            $document['hours'] = [long]$Hours
        }
        else {
            Write-NSPolicyError 'shift-policy: hours: must be a whole number of hours or null'
            return 2
        }
    }
    # These live in the shift block of the owner file, which is the one place a preference is
    # kept. Writing them anywhere else would leave the value that is read and the value that was
    # set in two files that can disagree.
    $block = New-NSOrdinalMap
    $block['verificationProfile'] = $document['verificationProfile']
    $block['hours'] = $document['hours']
    $block['execution'] = $document['execution']
    $block['toolingPolicy'] = $document['toolingPolicy']
    $rc = Set-NSShiftBlock -Workspace $Workspace -Block $block
    if ($rc -eq 0) { Write-NSPolicyOut (Get-NSPolicyPaths $Workspace)['rules'] }
    return $rc
}

# ---------------------------------------------------------------------------
# The resolver
# ---------------------------------------------------------------------------

function New-NSPolicySetting {
    param($Value, [Parameter(Mandatory = $true)][string]$Source, [Parameter(Mandatory = $true)][string]$Expiry)
    $entry = New-NSOrdinalMap
    $entry['value'] = $Value
    $entry['source'] = $Source
    $entry['expiry'] = $Expiry
    return $entry
}

# A key the owner wrote is an owner decision even when its value is empty, so
# presence - not emptiness - decides the source.
function Test-NSRuleKeyPresent {
    param(
        [Parameter(Mandatory = $true)][string]$Workspace,
        [Parameter(Mandatory = $true)][string]$Key
    )
    $rules = Get-NSRulesObject $Workspace
    if ($null -eq $rules) { return $false }
    return ($null -ne $rules.PSObject.Properties[$Key])
}

function Get-NSPolicyRuleSetting {
    param(
        [Parameter(Mandatory = $true)][string]$Workspace,
        [Parameter(Mandatory = $true)][string]$Key
    )
    $value = Get-NSRule $Workspace $Key ''
    if (Test-NSRuleKeyPresent $Workspace $Key) { return (New-NSPolicySetting $value 'rules' 'permanent') }
    return (New-NSPolicySetting $value 'built-in' '-')
}

# A dotted preference like report.progressMode: the owner's block if they wrote the key, the
# shipped default otherwise. Presence decides the source, so a key written as an empty string is
# still an owner decision.
function Get-NSPolicyGroupSetting {
    param(
        [Parameter(Mandatory = $true)][string]$Workspace,
        [Parameter(Mandatory = $true)][string]$Name
    )
    $fallback = $script:NSPolicyGroupDefaults[$Name]
    $block = $Name.Substring(0, $Name.IndexOf('.'))
    $key = $Name.Substring($Name.IndexOf('.') + 1)

    # A preference tonight's policy froze is what tonight uses, whatever the owner has since
    # written, and the view says so. A snapshot that cannot be read answers with the shipped
    # default rather than the mutable file it was supposed to fix; one written before this
    # feature carries no block, and then the owner's file is the source.
    $state = Get-NSShiftPolicyState $Workspace
    if ($state['state'] -ceq 'malformed') { return (New-NSPolicySetting $fallback 'built-in' '-') }
    if ($state['state'] -ceq 'valid') {
        $frozen = Get-NSMapValue $state['policy'] $block
        if ($frozen -is [Collections.IDictionary] -and $frozen.Contains($key)) {
            $value = $frozen[$key]
            if ($null -ne $value) {
                if ($value -is [Array]) { return (New-NSPolicySetting ([object[]]@($value)) 'one-shift' 'shift') }
                return (New-NSPolicySetting $value 'one-shift' 'shift')
            }
        }
    }

    $rules = Get-NSRulesObject $Workspace
    if ($null -eq $rules) { return (New-NSPolicySetting $fallback 'built-in' '-') }
    $property = $rules.PSObject.Properties[$block]
    if ($null -eq $property -or $null -eq $property.Value) { return (New-NSPolicySetting $fallback 'built-in' '-') }
    $inner = $property.Value.PSObject.Properties[$key]
    if ($null -eq $inner) { return (New-NSPolicySetting $fallback 'built-in' '-') }
    $value = $inner.Value
    if ($value -is [Array]) { return (New-NSPolicySetting ([object[]]@($value)) 'rules' 'permanent') }
    return (New-NSPolicySetting $value 'rules' 'permanent')
}

function Get-NSPolicyRuleInteger {
    param(
        [Parameter(Mandatory = $true)][string]$Workspace,
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][long]$Fallback
    )
    $value = Get-NSRule $Workspace $Key ''
    if ($value -cmatch '^-?[0-9]+$') { return (New-NSPolicySetting ([long]$value) 'rules' 'permanent') }
    return (New-NSPolicySetting $Fallback 'built-in' '-')
}

function Get-NSPolicyDeadlineFile {
    param([Parameter(Mandatory = $true)][string]$Workspace)
    $path = (Get-NSPolicyPaths $Workspace)['deadline']
    if ((Test-NSReparsePoint $path) -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    $raw = ''
    try {
        $raw = ([IO.File]::ReadAllText($path, $script:NSUtf8NoBom)).Trim()
    }
    catch {
        return $null
    }
    if ($raw -cmatch '^[0-9]+$') { return [long]$raw }
    return $null
}

# The one resolver. Precedence, top to bottom: an allowance in tonight's policy,
# then rules.json, then the built-in default. Protected paths, never-commit
# patterns and the expected email come from rules.json alone - no allowance lifts
# them - and shift-defaults.json never appears as the source of a value.
function Get-NSPolicyResolution {
    param([Parameter(Mandatory = $true)][string]$Workspace)
    $paths = Get-NSPolicyPaths $Workspace
    $state = Get-NSShiftPolicyState $Workspace
    $policy = $state['policy']
    $settings = New-NSOrdinalMap

    # The built-in shift is the shipped fast profile: no gate cadence, existing
    # tools, no deadline. Only tonight's policy moves any of the three.
    $settings['verificationLevel'] = New-NSPolicySetting 'none' 'built-in' '-'
    $settings['toolingPolicy'] = New-NSPolicySetting 'existing-tools' 'built-in' '-'
    $settings['deadlineEpoch'] = New-NSPolicySetting $null 'built-in' '-'
    if ($null -ne $policy) {
        $settings['verificationLevel'] = New-NSPolicySetting $policy['verificationLevel'] 'one-shift' 'shift'
        $settings['toolingPolicy'] = New-NSPolicySetting $policy['toolingPolicy'] 'one-shift' 'shift'
        # Once a policy exists, the deadline is tonight's either way: a number is the clock, and
        # null says this shift runs without one. Neither is the absence of a decision.
        $deadline = Get-NSMapValue $policy 'deadlineEpoch'
        if (Test-NSJsonInteger $deadline) {
            $settings['deadlineEpoch'] = New-NSPolicySetting ([long]$deadline) 'one-shift' 'shift'
        }
        else {
            $settings['deadlineEpoch'] = New-NSPolicySetting $null 'one-shift' 'shift'
        }
    }

    foreach ($category in $script:NSPolicyCategories) {
        $entry = New-NSPolicySetting 'deny' 'built-in' '-'
        $rulePolicy = Get-NSElevationRulePolicy $Workspace $category
        if (-not [string]::IsNullOrEmpty($rulePolicy)) {
            $entry = New-NSPolicySetting $rulePolicy 'rules' 'permanent'
        }
        $allowance = Get-NSPolicyCategoryAllowance $policy $category
        if ($null -ne $allowance) {
            $provenance = [string]$allowance['provenance']
            if ($provenance -ceq 'rules') {
                $entry = New-NSPolicySetting 'allow' 'rules' 'permanent'
            }
            else {
                $entry = New-NSPolicySetting 'allow' 'one-shift' 'shift'
            }
        }
        elseif ((Get-NSPolicyExactPlanAllowances $policy $category).Count -gt 0) {
            $entry = New-NSPolicySetting 'exact-plan' 'exact-plan' 'shift'
        }
        $settings['elevation.' + $category] = $entry
    }

    $settings['forbiddenCommands'] = Get-NSPolicyRuleSetting $Workspace 'forbiddenCommands'
    $settings['protectedDirs'] = Get-NSPolicyRuleSetting $Workspace 'protectedDirs'
    $settings['neverCommitPatterns'] = Get-NSPolicyRuleSetting $Workspace 'neverCommitPatterns'
    $settings['expectedEmail'] = Get-NSPolicyRuleSetting $Workspace 'expectedEmail'
    $settings['stallMax'] = Get-NSPolicyRuleInteger $Workspace 'stallMax' 0
    $settings['watchMinutes'] = Get-NSPolicyRuleInteger $Workspace 'watchMinutes' 10
    foreach ($name in $script:NSPolicyGroupDefaults.Keys) {
        $settings[$name] = Get-NSPolicyGroupSetting $Workspace $name
    }

    $resolution = New-NSOrdinalMap
    $resolution['settings'] = $settings
    $resolution['policy'] = $policy
    $resolution['policyState'] = $state['state']
    $resolution['policyError'] = $state['error']
    $resolution['deadlineFile'] = Get-NSPolicyDeadlineFile $Workspace
    $resolution['deadlinePolicy'] = $settings['deadlineEpoch']['value']
    return $resolution
}

function Get-NSPolicyAllowances {
    param($Policy, [Parameter(Mandatory = $true)][string]$Category)
    $found = New-Object Collections.Generic.List[object]
    if ($null -eq $Policy) { return , $found }
    $allowances = Get-NSPolicyField $Policy 'allowances'
    if ($null -eq $allowances) { return , $found }
    foreach ($allowance in @($allowances)) {
        if (-not ($allowance -is [Collections.IDictionary])) { continue }
        $candidate = Get-NSMapValue $allowance 'category'
        if (($candidate -is [string]) -and ($candidate -ceq $Category)) { $found.Add($allowance) }
    }
    return , $found
}

function Get-NSPolicyCategoryAllowance {
    param($Policy, [Parameter(Mandatory = $true)][string]$Category)
    foreach ($allowance in (Get-NSPolicyAllowances $Policy $Category)) {
        $scope = Get-NSMapValue $allowance 'scope'
        if (($scope -is [string]) -and ($scope -ceq 'category')) { return $allowance }
    }
    return $null
}

function Get-NSPolicyExactPlanAllowances {
    param($Policy, [Parameter(Mandatory = $true)][string]$Category)
    $plans = New-Object Collections.Generic.List[object]
    foreach ($allowance in (Get-NSPolicyAllowances $Policy $Category)) {
        $scope = Get-NSMapValue $allowance 'scope'
        if (($scope -is [string]) -and ($scope -ceq 'exact-plan')) { $plans.Add($allowance) }
    }
    return , $plans
}

# One rendering for both resolvers: the table is read by people and by the model, so a boolean,
# a null and a list have to look the same whichever half printed them.
function Format-NSPolicyValue {
    param($Value)
    if ($null -eq $Value) { return 'null' }
    if ($Value -is [bool]) { if ($Value) { return 'true' } else { return 'false' } }
    if (Test-NSJsonInteger $Value) { return ([long]$Value).ToString([Globalization.CultureInfo]::InvariantCulture) }
    if ($Value -is [Array]) { return (ConvertTo-NSCanonicalJson $Value -Compact) }
    return [string]$Value
}

function Format-NSPolicyTable {
    param($Resolution)
    $settings = $Resolution['settings']
    $lines = New-Object Collections.Generic.List[string]
    foreach ($name in (Sort-NSOrdinal $script:NSPolicySettingNames)) {
        $entry = $settings[$name]
        $lines.Add(('{0}={1} ({2}, {3})' -f $name, (Format-NSPolicyValue $entry['value']), $entry['source'], $entry['expiry']))
    }
    return , $lines.ToArray()
}

function Resolve-NSPolicy {
    param(
        [Parameter(Mandatory = $true)][string]$Workspace,
        [switch]$Json,
        [switch]$Table
    )
    if ($Table -and $Json) {
        throw 'choose one of -Json or -Table'
    }
    $resolution = Get-NSPolicyResolution $Workspace
    if ($Table) {
        return ((Format-NSPolicyTable $resolution) -join "`n")
    }
    $document = New-NSOrdinalMap
    $document['schemaVersion'] = 1
    $document['settings'] = $resolution['settings']
    return (ConvertTo-NSCanonicalJson $document -Compact)
}

# The gate honours the earlier of the two, so a deadline file that drifts from
# the policy shortens the night rather than extending it.
function Get-NSPolicyDeadlineEpoch {
    param([Parameter(Mandatory = $true)][string]$Workspace)
    $resolution = Get-NSPolicyResolution $Workspace
    $file = $resolution['deadlineFile']
    $fromPolicy = $resolution['deadlinePolicy']
    if ($null -eq $file) { return $fromPolicy }
    if ($null -eq $fromPolicy) { return $file }
    if ([long]$file -lt [long]$fromPolicy) { return [long]$file }
    return [long]$fromPolicy
}

# 0 allow - 1 deny - 2 the category is denied and no exact plan covers this
# command. The caller has already matched the command against the category
# pattern; this answers only whether the shift permits it.
function Test-NSPolicyAllowed {
    param(
        [Parameter(Mandatory = $true)][string]$Workspace,
        [Parameter(Mandatory = $true)][string]$Category,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Command
    )
    if (-not ($script:NSPolicyCategories -ccontains $Category)) { return 1 }
    $resolution = Get-NSPolicyResolution $Workspace
    $value = [string]$resolution['settings']['elevation.' + $Category]['value']
    if ($value -ceq 'allow') { return 0 }
    if ($value -cne 'exact-plan') { return 1 }
    if (Test-NSPolicyExactPlan -Workspace $Workspace -Resolution $resolution -Category $Category -Command $Command) { return 0 }
    return 2
}

# An exact plan binds the command, the resolved work target, the shift identity
# and the deadline. Any drift is a mismatch, never a fall-through to the category.
function Test-NSPolicyExactPlan {
    param(
        [Parameter(Mandatory = $true)][string]$Workspace,
        [Parameter(Mandatory = $true)]$Resolution,
        [Parameter(Mandatory = $true)][string]$Category,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Command
    )
    $policy = $Resolution['policy']
    if ($null -eq $policy) { return $false }
    $deadline = $Resolution['deadlinePolicy']
    if ($null -ne $deadline -and (Get-NSUnixTime) -gt [long]$deadline) { return $false }
    $target = $Workspace
    try {
        $target = Resolve-NSWorkTarget $Workspace
    }
    catch {
        $target = Get-NSAbsolutePath $Workspace
    }
    $shiftId = [string]$policy['shiftId']
    $normalized = Get-NSPolicyNormalizedCommand $Command
    foreach ($allowance in (Get-NSPolicyExactPlanAllowances $policy $Category)) {
        $plan = Get-NSMapValue $allowance 'plan'
        if ($null -eq $plan) { continue }
        # A plan may expire before the shift does; a plan with no expiry of its
        # own defers to the shift deadline checked above.
        $planExpiry = Get-NSMapValue $plan 'expiry'
        if ((Test-NSJsonInteger $planExpiry) -and (Get-NSUnixTime) -gt [long]$planExpiry) { continue }
        $planTarget = [string](Get-NSMapValue $plan 'workTarget')
        if (-not ($planTarget -ceq (Get-NSAbsolutePath $target))) { continue }
        $commands = New-Object Collections.Generic.List[string]
        foreach ($command in @(Get-NSPolicyField $plan 'commands')) { $commands.Add([string]$command) }
        $expected = Get-NSPolicyPlanDigest -Commands $commands.ToArray() -WorkTarget $planTarget -ShiftId $shiftId
        if (-not ($expected -ceq [string](Get-NSMapValue $plan 'digest'))) { continue }
        foreach ($command in $commands) {
            if ((Get-NSPolicyNormalizedCommand $command) -ceq $normalized) { return $true }
        }
    }
    return $false
}

# ---------------------------------------------------------------------------
# Permission preflight - a filter for surprises, never a guarantee. It reports
# and exits 0; only the owner lifts a category.
# ---------------------------------------------------------------------------

function Get-NSPreflightTitle {
    param([AllowEmptyString()][string]$Line)
    $title = $Line.Trim()
    $title = [regex]::Replace($title, '^-\s*\[[ xX]\]\s*', '')
    $title = [regex]::Replace($title, '^#+\s*', '')
    $title = $title.Replace('**', '')
    return $title.Trim()
}

function Get-NSPreflightSectionItems {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Lines,
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$FallbackTitle
    )
    $items = New-Object Collections.Generic.List[object]
    $current = $null
    $sawBox = $false
    $text = New-Object Text.StringBuilder
    foreach ($line in $Lines) {
        # A ticked box is finished work: it closes the item above it and starts
        # nothing, so no allowance is ever reported or parked for it.
        if ($line -match '^-\s*\[[xX]\]') {
            $sawBox = $true
            if ($null -ne $current) {
                $current['text'] = $text.ToString()
                $items.Add($current)
                $current = $null
            }
            continue
        }
        if ($line -match '^-\s*\[ \]') {
            $sawBox = $true
            if ($null -ne $current) {
                $current['text'] = $text.ToString()
                $items.Add($current)
            }
            $current = New-NSOrdinalMap
            $current['title'] = Get-NSPreflightTitle $line
            $current['source'] = $Source
            $text = New-Object Text.StringBuilder
        }
        if ($null -ne $current) {
            $null = $text.Append($line)
            $null = $text.Append("`n")
        }
    }
    if ($null -ne $current) {
        $current['text'] = $text.ToString()
        $items.Add($current)
    }
    # A section that carries no box at all is itself the unit; one whose boxes are
    # all ticked has nothing left to need.
    if ($items.Count -eq 0 -and -not $sawBox -and -not [string]::IsNullOrEmpty($FallbackTitle)) {
        $item = New-NSOrdinalMap
        $item['title'] = $FallbackTitle
        $item['source'] = $Source
        $item['text'] = ($Lines -join "`n")
        $items.Add($item)
    }
    return , $items
}

function Get-NSPreflightFileLines {
    param([Parameter(Mandatory = $true)][string]$Path)
    if ((Test-NSReparsePoint $Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return , @() }
    try {
        return , ([regex]::Split([IO.File]::ReadAllText($Path, $script:NSUtf8NoBom), "\r\n|\n|\r"))
    }
    catch {
        return , @()
    }
}

function Get-NSPreflightItems {
    param([Parameter(Mandatory = $true)][string]$Workspace)
    $paths = Get-NSPolicyPaths $Workspace
    $items = New-Object Collections.Generic.List[object]

    $section = New-Object Collections.Generic.List[string]
    $inItems = $false
    foreach ($line in (Get-NSPreflightFileLines $paths['punch'])) {
        if (-not $inItems) {
            if ($line -match '^##\s+Items\s*$') { $inItems = $true }
            continue
        }
        if ($line -match '^##\s') { break }
        $section.Add($line)
    }
    foreach ($item in (Get-NSPreflightSectionItems -Lines $section.ToArray() -Source 'punch-list' -FallbackTitle '')) {
        $items.Add($item)
    }

    $orderLines = New-Object Collections.Generic.List[string]
    $orderTitle = ''
    foreach ($line in (Get-NSPreflightFileLines $paths['orders'])) {
        if ($line -match '^##\s+Work order') {
            if (-not [string]::IsNullOrEmpty($orderTitle)) {
                foreach ($item in (Get-NSPreflightSectionItems -Lines $orderLines.ToArray() -Source 'work-order' -FallbackTitle $orderTitle)) {
                    $items.Add($item)
                }
            }
            $orderTitle = Get-NSPreflightTitle $line
            $orderLines = New-Object Collections.Generic.List[string]
            continue
        }
        if ($line -match '^##\s') {
            if (-not [string]::IsNullOrEmpty($orderTitle)) {
                foreach ($item in (Get-NSPreflightSectionItems -Lines $orderLines.ToArray() -Source 'work-order' -FallbackTitle $orderTitle)) {
                    $items.Add($item)
                }
            }
            $orderTitle = ''
            $orderLines = New-Object Collections.Generic.List[string]
            continue
        }
        if (-not [string]::IsNullOrEmpty($orderTitle)) { $orderLines.Add($line) }
    }
    if (-not [string]::IsNullOrEmpty($orderTitle)) {
        foreach ($item in (Get-NSPreflightSectionItems -Lines $orderLines.ToArray() -Source 'work-order' -FallbackTitle $orderTitle)) {
            $items.Add($item)
        }
    }
    return , $items
}

function Get-NSPreflightReport {
    param([Parameter(Mandatory = $true)][string]$Workspace)
    $resolution = Get-NSPolicyResolution $Workspace
    $patterns = New-NSOrdinalMap
    foreach ($category in $script:NSPolicyCategories) {
        $pattern = Get-NSElevationPattern $Workspace $category
        $regex = $null
        try {
            $regex = New-NSPolicyRegex $pattern
        }
        catch {
            # An unreadable pattern is one reported defect. The category stays
            # denied and the hardhat guard still fails closed on the command.
            $regex = $null
        }
        $patterns[$category] = $regex
    }
    $patternErrors = New-Object Collections.Generic.List[string]
    foreach ($category in $script:NSPolicyCategories) {
        if ($null -eq $patterns[$category]) { $patternErrors.Add($category) }
    }
    $items = New-Object Collections.Generic.List[object]
    $gaps = New-Object Collections.Generic.List[object]
    foreach ($item in (Get-NSPreflightItems $Workspace)) {
        # An item quotes its commands in markdown; the backticks become spaces so
        # the shared elevation patterns read prose the way the guard reads a command.
        $text = ([string]$item['text']).Replace('`', ' ')
        $needs = New-Object Collections.Generic.List[object]
        foreach ($category in $script:NSPolicyCategories) {
            $regex = $patterns[$category]
            if ($null -eq $regex) { continue }
            if (-not $regex.IsMatch($text)) { continue }
            $value = [string]$resolution['settings']['elevation.' + $category]['value']
            $need = New-NSOrdinalMap
            $need['category'] = $category
            $need['resolved'] = $value
            $need['allowed'] = ($value -ceq 'allow')
            $needs.Add($need)
            if (-not $need['allowed']) {
                $gap = New-NSOrdinalMap
                $gap['category'] = $category
                $gap['title'] = $item['title']
                $gaps.Add($gap)
            }
        }
        $entry = New-NSOrdinalMap
        $entry['title'] = $item['title']
        $entry['source'] = $item['source']
        $entry['needs'] = $needs.ToArray()
        $items.Add($entry)
    }
    $report = New-NSOrdinalMap
    $report['schemaVersion'] = 1
    $report['items'] = $items.ToArray()
    $report['gaps'] = $gaps.ToArray()
    $report['patternErrors'] = $patternErrors.ToArray()
    return $report
}

function Get-NSPreflightNeeds {
    param(
        [Parameter(Mandatory = $true)][string]$Workspace,
        [switch]$Json
    )
    $report = Get-NSPreflightReport $Workspace
    if ($Json) {
        return (ConvertTo-NSCanonicalJson $report -Compact)
    }
    $lines = New-Object Collections.Generic.List[string]
    $index = 0
    foreach ($item in $report['items']) {
        $index++
        $lines.Add(('item {0} ({1}): {2}' -f $index, $item['source'], $item['title']))
        if (@($item['needs']).Count -eq 0) {
            $lines.Add('  needs: none')
            continue
        }
        foreach ($need in $item['needs']) {
            $state = 'denied'
            if ($need['allowed']) { $state = 'allowed' }
            elseif ([string]$need['resolved'] -ceq 'exact-plan') { $state = 'exact-plan only' }
            $lines.Add(('  needs {0}: {1}' -f $need['category'], $state))
        }
    }
    if ($index -eq 0) {
        $lines.Add('items: none')
    }
    foreach ($category in $report['patternErrors']) {
        $lines.Add('pattern error: ' + $category + ' (rules.elevation pattern does not compile)')
    }
    $categories = New-Object Collections.Generic.List[string]
    foreach ($gap in $report['gaps']) {
        if (-not ($categories -ccontains [string]$gap['category'])) { $categories.Add([string]$gap['category']) }
    }
    if ($categories.Count -eq 0) {
        $lines.Add('gaps: none')
    }
    else {
        $lines.Add('gaps: ' + ((Sort-NSOrdinal $categories.ToArray()) -join ', '))
    }
    return ($lines -join "`n")
}

# One parking-lot entry per item and category, idempotent: Start may run twice
# over the same punch list and the owner still reads one entry per gap.
function Add-NSParkedNeeds {
    param([Parameter(Mandatory = $true)][string]$Workspace)
    $paths = Get-NSPolicyPaths $Workspace
    $report = Get-NSPreflightReport $Workspace
    $added = New-Object Collections.Generic.List[string]
    if (@($report['gaps']).Count -eq 0) { return , $added.ToArray() }
    $path = $paths['parking']
    if (Test-NSReparsePoint $path) {
        throw 'parking-lot.md is not a usable file'
    }
    $existing = ''
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        $existing = [IO.File]::ReadAllText($path, $script:NSUtf8NoBom)
    }
    else {
        $existing = "# Parking Lot`n"
    }
    $dash = [string][char]0x2014
    $builder = New-Object Text.StringBuilder
    $null = $builder.Append($existing)
    if (-not $existing.EndsWith("`n")) { $null = $builder.Append("`n") }
    foreach ($gap in $report['gaps']) {
        $category = [string]$gap['category']
        $title = [string]$gap['title']
        $marker = '**needs allowance: {0}** {1} item "{2}"' -f $category, $dash, $title
        if ($builder.ToString().Contains($marker)) { continue }
        $null = $builder.Append("`n")
        $null = $builder.Append($marker)
        $null = $builder.Append((' needs the {0} elevation category, which is denied for this shift. Default: parked, worked last if the owner allows it before then.' -f $category))
        $null = $builder.Append("`n")
        $added.Add(('{0}: {1}' -f $category, $title))
    }
    if ($added.Count -gt 0) {
        Write-NSEvidenceFileAtomic -Path $path -Text $builder.ToString()
    }
    return , $added.ToArray()
}

# ---------------------------------------------------------------------------
# Command surfaces for the thin runtime scripts
# ---------------------------------------------------------------------------

function Write-NSShiftPolicyUsage {
    Write-NSPolicyError 'usage: shift-policy.ps1 -Project DIR -Command {get|set|defaults-get|defaults-set|resolve|archive} ...'
    return 1
}

function Invoke-NSShiftPolicyArchive {
    param(
        [Parameter(Mandatory = $true)][string]$Workspace,
        [Parameter(Mandatory = $true)][string]$Date
    )
    $paths = Get-NSPolicyPaths $Workspace
    if (-not (Test-Path -LiteralPath $paths['policy'] -PathType Leaf)) {
        Write-NSPolicyError 'shift-policy: no shift policy to archive'
        return 3
    }
    $state = Get-NSShiftPolicyState $Workspace
    $shiftId = 'unknown'
    if ($state['state'] -ceq 'valid') {
        $shiftId = [string]$state['policy']['shiftId']
    }
    else {
        Write-NSPolicyError ('shift-policy: ' + $state['error'] + '; archiving as shift-policy-unknown.json')
    }
    $directory = Join-NSPath $paths['archive'] $Date
    foreach ($candidate in @($paths['archive'], $directory)) {
        if (Test-NSReparsePoint $candidate) {
            Write-NSPolicyError 'shift-policy: refuse to write through a symlink archive path'
            return 2
        }
    }
    $null = [IO.Directory]::CreateDirectory($directory)
    $destination = Join-NSPath $directory ('shift-policy-' + $shiftId + '.json')
    Write-NSEvidenceFileAtomic -Path $destination -Text ([IO.File]::ReadAllText($paths['policy'], $script:NSUtf8NoBom))
    Remove-Item -LiteralPath $paths['policy'] -Force
    Write-NSPolicyOut $destination
    return 0
}

# The migration onto the one-file shape. Same contract as the POSIX helper: refuse while armed,
# name an invalid value by its key, validate the destination before replacing one that loads,
# keep a lossless backup, do nothing the second time, and refuse a disagreeing pair by naming
# both sides rather than choosing one.
function Invoke-NSPolicyMigrate {
    param(
        [Parameter(Mandatory = $true)][string]$Workspace,
        [switch]$DryRun
    )
    $paths = Get-NSPolicyPaths $Workspace
    $rules = $paths['rules']
    $legacy = $paths['defaults']
    if (-not (Test-Path -LiteralPath $rules -PathType Leaf)) {
        Write-NSPolicyError ('shift-policy: no owner rules file at ' + $rules + ' - run setup first')
        return 3
    }
    if (Test-NSPolicyArmed $Workspace) {
        Write-NSPolicyError 'shift-policy: refuse to migrate while the shift is armed - stop the shift, migrate, then start again'
        return 4
    }
    $canonical = Get-NSShiftBlock $Workspace
    $stated = $null
    if (Test-Path -LiteralPath $legacy -PathType Leaf) {
        try {
            $stated = ConvertFrom-NSJsonText ([IO.File]::ReadAllText($legacy, $script:NSUtf8NoBom))
        }
        catch {
            $stated = $null
        }
        if (-not ($stated -is [Collections.IDictionary])) { $stated = $null }
    }

    $fields = @(
        @{ Name = 'verificationProfile'; Enum = $script:NSPolicyProfiles },
        @{ Name = 'hours'; Enum = $null },
        @{ Name = 'execution'; Enum = $script:NSPolicyExecutions },
        @{ Name = 'toolingPolicy'; Enum = $script:NSPolicyToolingPolicies })

    $block = New-NSOrdinalMap
    $conflicts = New-Object Collections.Generic.List[string]
    foreach ($field in $fields) {
        $name = [string]$field['Name']
        $here = $null
        $there = $null
        $haveHere = ($null -ne $canonical) -and $canonical.Contains($name)
        $haveThere = ($null -ne $stated) -and $stated.Contains($name)
        if ($haveHere) { $here = $canonical[$name] }
        if ($haveThere) { $there = $stated[$name] }
        foreach ($pair in @(@($haveHere, $here), @($haveThere, $there))) {
            if (-not $pair[0]) { continue }
            if (-not (Test-NSMigrateValue $name $pair[1] $field['Enum'])) { return 2 }
        }
        if ($haveHere -and $haveThere -and ((ConvertTo-NSCanonicalJson @{ v = $here }) -cne (ConvertTo-NSCanonicalJson @{ v = $there }))) {
            $conflicts.Add('  shift.' + $name + ': this file says ' + (ConvertTo-NSJsonScalar $here) +
                ', the legacy file says ' + (ConvertTo-NSJsonScalar $there))
            continue
        }
        if ($haveHere) { $block[$name] = $here }
        elseif ($haveThere) { $block[$name] = $there }
    }

    if ($conflicts.Count -gt 0) {
        Write-NSPolicyError 'shift-policy: refused: two explicit values disagree, and nothing here decides between them'
        foreach ($line in $conflicts) { Write-NSPolicyError $line }
        Write-NSPolicyError ('shift-policy: keep one value, delete the other from ' + $legacy + ', then run migrate again')
        return 2
    }

    if (-not (Test-Path -LiteralPath $legacy -PathType Leaf) -and $null -ne $canonical) {
        Write-NSPolicyOut ('no-op: every remembered choice already lives in ' + $rules)
        return 0
    }

    Write-NSPolicyOut ('migrating into ' + $rules + ':')
    Write-NSPolicyOut ('  shift = ' + (ConvertTo-NSCanonicalJson $block))
    if ($DryRun) {
        Write-NSPolicyOut 'dry run: nothing was written'
        return 0
    }
    if (Test-Path -LiteralPath $legacy -PathType Leaf) {
        Copy-Item -LiteralPath $legacy -Destination ($legacy + '.bak') -Force
    }
    $rc = Set-NSShiftBlock -Workspace $Workspace -Block $block
    if ($rc -ne 0) { return $rc }
    Remove-Item -LiteralPath $legacy -Force -ErrorAction SilentlyContinue
    Write-NSPolicyOut $rules
    return 0
}

# The bounded reader answers about shape; this answers about the value, which is what a migration
# must know before it carries one forward.
function Test-NSMigrateValue {
    param([string]$Name, $Value, $Enum)
    if ($Name -ceq 'hours') {
        if ($null -eq $Value) { return $true }
        if ((Test-NSJsonInteger $Value) -and [long]$Value -ge 0) { return $true }
        Write-NSPolicyError 'shift-policy: shift.hours: must be a whole number of hours or null'
        return $false
    }
    if (Test-NSEvidenceEnum $Value $Enum) { return $true }
    Write-NSPolicyError ('shift-policy: shift.' + $Name + ': must be ' + ($Enum -join ', '))
    return $false
}

function ConvertTo-NSJsonScalar {
    param($Value)
    if ($null -eq $Value) { return 'null' }
    if ($Value -is [string]) { return ('"' + $Value + '"') }
    return ([string]$Value)
}

function Invoke-NSShiftPolicyCommand {
    param(
        [AllowEmptyString()][string]$Project = '',
        [AllowEmptyString()][string]$Command = '',
        [AllowEmptyString()][string]$FromJson = '',
        [AllowEmptyString()][string]$VerificationProfile = '',
        [AllowEmptyString()][string]$Hours = '',
        [AllowEmptyString()][string]$ToolingPolicy = '',
        [AllowEmptyString()][string]$Execution = '',
        [AllowEmptyString()][string]$Date = '',
        [switch]$Json,
        [switch]$Table,
        [switch]$DryRun
    )
    if ([string]::IsNullOrEmpty($Project) -or [string]::IsNullOrEmpty($Command)) { return (Write-NSShiftPolicyUsage) }
    $workspace = Get-NSAbsolutePath $Project
    $paths = Get-NSPolicyPaths $workspace
    switch ($Command) {
        'get' {
            if (-not (Test-Path -LiteralPath $paths['policy'] -PathType Leaf)) {
                Write-NSPolicyOut '{}'
                return 3
            }
            $text = [IO.File]::ReadAllText($paths['policy'], $script:NSUtf8NoBom)
            [Console]::Out.Write($text)
            if (-not $text.EndsWith("`n")) { [Console]::Out.Write("`n") }
            return 0
        }
        'set' {
            if ([string]::IsNullOrEmpty($FromJson)) { return (Write-NSShiftPolicyUsage) }
            $documentText = ''
            if ($FromJson -ceq '-') {
                $documentText = Get-NSStdinText
            }
            elseif (Test-Path -LiteralPath $FromJson -PathType Leaf) {
                $documentText = [IO.File]::ReadAllText($FromJson, $script:NSUtf8NoBom)
            }
            else {
                Write-NSPolicyError ('shift-policy: cannot read ' + $FromJson)
                return 2
            }
            return (Set-NSShiftPolicy -Workspace $workspace -Json $documentText)
        }
        'defaults-get' {
            Write-NSPolicyOut (ConvertTo-NSCanonicalJson (Get-NSShiftDefaults $workspace))
            return 0
        }
        'defaults-set' {
            return (Set-NSShiftDefaults -Workspace $workspace -VerificationProfile $VerificationProfile `
                    -Hours $Hours -ToolingPolicy $ToolingPolicy -Execution $Execution)
        }
        'resolve' {
            if ($Table) {
                Write-NSPolicyOut (Resolve-NSPolicy -Workspace $workspace -Table)
                return 0
            }
            Write-NSPolicyOut (Resolve-NSPolicy -Workspace $workspace -Json)
            return 0
        }
        'migrate' {
            return (Invoke-NSPolicyMigrate -Workspace $workspace -DryRun:$DryRun)
        }
        'archive' {
            $day = $Date
            if ([string]::IsNullOrEmpty($day)) { $day = Get-Date -Format 'yyyy-MM-dd' }
            if ($day -cnotmatch '^[0-9]{4}-[0-9]{2}-[0-9]{2}$') {
                Write-NSPolicyError 'shift-policy: -Date must be YYYY-MM-DD'
                return 2
            }
            return (Invoke-NSShiftPolicyArchive -Workspace $workspace -Date $day)
        }
    }
    return (Write-NSShiftPolicyUsage)
}

function Invoke-NSPreflightNeedsCommand {
    param([AllowEmptyString()][string]$Project = '', [switch]$Json)
    if ([string]::IsNullOrEmpty($Project)) {
        Write-NSPolicyError 'usage: preflight-needs.ps1 -Project DIR [-Json]'
        return 1
    }
    Write-NSPolicyOut (Get-NSPreflightNeeds -Workspace (Get-NSAbsolutePath $Project) -Json:$Json)
    return 0
}

function Invoke-NSParkNeedsCommand {
    param([AllowEmptyString()][string]$Project = '')
    if ([string]::IsNullOrEmpty($Project)) {
        Write-NSPolicyError 'usage: park-needs.ps1 -Project DIR'
        return 1
    }
    $workspace = Get-NSAbsolutePath $Project
    if (-not (Test-Path -LiteralPath (Get-NSPolicyPaths $workspace)['ns'] -PathType Container)) {
        Write-NSPolicyError ('park-needs: no .nightshift/ at ' + $workspace)
        return 1
    }
    $added = Add-NSParkedNeeds -Workspace $workspace
    foreach ($entry in $added) { Write-NSPolicyOut ('parked ' + $entry) }
    Write-NSPolicyOut ('park-needs: added ' + $added.Count)
    return 0
}

# ---------------------------------------------------------------------------
# Provisioning - the transaction document, native rollback, and the late stages.
# The engine that installs a capability is not on this host. What lives here is
# the recovery every host owes an interrupted transaction, the read-only plan,
# and the honest refusal.
# ---------------------------------------------------------------------------

$script:NSProvisionStages = @('authorize', 'capture-baseline', 'apply', 'smoke', 'record', 'commit-tooling')
# Every stage but record and commit-tooling undoes rather than finishes.
$script:NSProvisionRollbackStages = @('authorize', 'capture-baseline', 'apply', 'smoke', 'rollback')
$script:NSProvisionSetupPrefix = 'chore(tooling):'
$script:NSProvisionBudgetDefault = 120
$script:NSProvisionRequiredFields = @(
    'capabilityId', 'ecosystems', 'versionConstraints', 'detect', 'probe',
    'packageManagerAdditions', 'allowedFiles', 'minimalConfig', 'smoke',
    'rollback', 'enabledShifts', 'safetyClass', 'permissionRequirements', 'recipeVersion')
$script:NSProvisionLockedNames = @(
    'punch-list.md', 'parking-lot.md', 'drafting-table.md', 'work-orders.md',
    'capability-policy.json', 'shift-policy.json', 'shift-defaults.json')
$script:NSProvisionStackSignals = New-Object Collections.Specialized.OrderedDictionary([StringComparer]::Ordinal)
$script:NSProvisionStackSignals['javascript-typescript'] = @('package.json')
$script:NSProvisionStackSignals['python'] = @('pyproject.toml', 'requirements.txt', 'setup.cfg', 'setup.py')
$script:NSProvisionStackSignals['go'] = @('go.mod')
$script:NSProvisionStackSignals['rust'] = @('Cargo.toml')
$script:NSProvisionStackSignals['shell-plugin'] = @('.claude-plugin', '.codex-plugin')
$script:NSProvisionStackSignals['make'] = @('Makefile')

function Write-NSProvisionOut {
    param([AllowEmptyString()][string]$Text)
    [Console]::Out.Write($Text)
    [Console]::Out.Write("`n")
}

function Write-NSProvisionError {
    param([AllowEmptyString()][string]$Text)
    [Console]::Error.WriteLine($Text)
}

# One line of sorted, compact JSON with a single trailing newline - the bytes the
# POSIX recovery helper prints, so every host answers on one wire format.
function Write-NSProvisionJson {
    param([Parameter(Mandatory = $true)]$Document)
    Write-NSProvisionOut (ConvertTo-NSCanonicalJson $Document -Compact)
}

function Write-NSProvisionUsage {
    Write-NSProvisionError ('usage: provision.ps1 -Project DIR plan|apply|recover|rollback ' +
        '[-Recipe PATH] [-Capability ID] [-BudgetSeconds N]')
    return 1
}

function Get-NSProvisionNow {
    $fixed = $env:NIGHTSHIFT_PROVISION_NOW
    if (-not [string]::IsNullOrEmpty($fixed)) { return $fixed }
    return [DateTime]::UtcNow.ToString('yyyy-MM-dd\THH:mm:ss\Z', [Globalization.CultureInfo]::InvariantCulture)
}

function Get-NSProvisionPaths {
    param([Parameter(Mandatory = $true)][string]$Project)
    $ns = Join-NSPath (Get-NSAbsolutePath $Project) '.nightshift'
    $paths = New-NSOrdinalMap
    $paths['ns'] = $ns
    $paths['transaction'] = Join-NSPath $ns 'provision-transaction.json'
    $paths['baseline'] = Join-NSPath $ns 'provision-baseline'
    $paths['inventory'] = Join-NSPath $ns 'capabilities.json'
    return $paths
}

function Get-NSProvisionRelPath {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Rel)
    return ($Rel.Replace('\', '/')).TrimStart('.', '/')
}

function Get-NSProvisionByteSha256 {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]]$Bytes)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash($Bytes)
    }
    finally {
        $sha.Dispose()
    }
    $builder = New-Object Text.StringBuilder
    foreach ($byte in $hash) { $null = $builder.Append($byte.ToString('x2')) }
    return $builder.ToString()
}

# The blob file name is the digest of the normalized relative path, so the store
# is addressable without reading the transaction.
function Get-NSProvisionBlobId {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Rel)
    return (Get-NSTextSha256 (Get-NSProvisionRelPath $Rel))
}

# Every path the engine touches is relative, inside the work target, and never an
# owner file. A baseline that breaks any of the three is malformed, not repairable.
function Resolve-NSProvisionPath {
    param(
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Rel
    )
    $relative = Get-NSProvisionRelPath $Rel
    if ([string]::IsNullOrEmpty($relative)) { throw ('path outside work target: ' + $Rel) }
    if ($relative.StartsWith('/', [StringComparison]::Ordinal)) { throw ('path outside work target: ' + $Rel) }
    foreach ($part in $relative.Split('/')) {
        if ($part -ceq '..') { throw ('path outside work target: ' + $Rel) }
    }
    if ($script:NSProvisionLockedNames -ccontains ([IO.Path]::GetFileName($relative))) {
        throw 'refuses to write Nightshift owner files'
    }
    $root = Get-NSAbsolutePath $Target
    $full = Get-NSAbsolutePath (Join-NSPath $root $relative)
    $head = $root + [string][IO.Path]::DirectorySeparatorChar
    if (($full -cne $root) -and -not $full.StartsWith($head, [StringComparison]::Ordinal)) {
        throw ('path outside work target: ' + $Rel)
    }
    return $full
}

function Read-NSProvisionTransaction {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    return (ConvertFrom-NSJsonText ([IO.File]::ReadAllText($Path, $script:NSUtf8NoBom)))
}

function Write-NSProvisionTransaction {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Document
    )
    Write-NSEvidenceFileAtomic -Path $Path -Text ((ConvertTo-NSCanonicalJson $Document) + "`n")
}

# The scalar gate on a transaction: every field recovery reads is present and of
# the right type, or recovery names the field and touches nothing.
function Test-NSProvisionTransaction {
    param($Document)
    if (-not ($Document -is [Collections.IDictionary])) { return 'document' }
    if (-not (Test-NSEvidenceEnum (Get-NSMapValue $Document 'stage') (@($script:NSProvisionStages) + @('rollback')))) {
        return 'stage'
    }
    $capability = Get-NSMapValue $Document 'capabilityId'
    if (-not ($capability -is [string]) -or $capability.Length -eq 0) { return 'capabilityId' }
    $failed = Get-NSMapValue $Document 'failed'
    if (($null -ne $failed) -and -not ($failed -is [bool])) { return 'failed' }
    $target = Get-NSMapValue $Document 'workTarget'
    if ($null -ne $target) {
        if (-not ($target -is [string]) -or $target.Length -eq 0) { return 'workTarget' }
    }
    $touched = Get-NSMapValue $Document 'touched'
    if ($null -ne $touched) {
        if (($touched -is [string]) -or ($touched -is [Collections.IDictionary]) -or -not ($touched -is [Collections.IEnumerable])) {
            return 'touched'
        }
        foreach ($entry in @($touched)) {
            if (-not ($entry -is [string])) { return 'touched' }
        }
    }
    $baseline = Get-NSMapValue $Document 'baseline'
    if ($null -ne $baseline) {
        if (-not ($baseline -is [Collections.IDictionary])) { return 'baseline' }
    }
    return ''
}

# The baseline gate needs the work target, so it runs once the target is known:
# each entry is an object, says whether the file existed, carries a digest when
# it did, names a blob the store can address, and stays inside the target. The
# digest itself is compared, never shape-checked.
function Test-NSProvisionBaseline {
    param($Baseline, [Parameter(Mandatory = $true)][string]$Target)
    if ($null -eq $Baseline) { return '' }
    if (-not ($Baseline -is [Collections.IDictionary])) { return 'baseline' }
    foreach ($rel in (Sort-NSOrdinal @($Baseline.Keys))) {
        $label = 'baseline["' + [string]$rel + '"]'
        $meta = $Baseline[$rel]
        if (-not ($meta -is [Collections.IDictionary])) { return $label }
        $existed = Get-NSMapValue $meta 'existed'
        if (-not ($existed -is [bool])) { return ($label + '.existed') }
        try {
            $null = Resolve-NSProvisionPath $Target ([string]$rel)
        }
        catch {
            return $label
        }
        $blob = Get-NSMapValue $meta 'blob'
        if (($null -ne $blob) -and -not (Test-NSPolicyDigest $blob)) { return ($label + '.blob') }
        if (-not [bool]$existed) { continue }
        $digest = Get-NSMapValue $meta 'digest'
        if (-not ($digest -is [string]) -or $digest.Length -eq 0) { return ($label + '.digest') }
    }
    return ''
}

function Get-NSProvisionTouched {
    param($Transaction)
    $touched = New-Object Collections.Generic.List[string]
    $recorded = Get-NSMapValue $Transaction 'touched'
    if ($null -ne $recorded) {
        foreach ($entry in @($recorded)) { $touched.Add([string]$entry) }
    }
    return , $touched.ToArray()
}

# The blob store holds the original bytes; the base64 copy in the transaction is
# the fallback when the store is gone. Neither one usable returns nothing, and a
# restore with nothing to restore from leaves the file alone for the proof to
# report - it never invents empty content.
function Get-NSProvisionRestoreBytes {
    param(
        [Parameter(Mandatory = $true)][string]$BaselineDir,
        [Parameter(Mandatory = $true)]$Meta
    )
    $blob = Get-NSMapValue $Meta 'blob'
    if (($blob -is [string]) -and $blob.Length -gt 0) {
        $blobPath = Join-NSPath $BaselineDir $blob
        if (Test-Path -LiteralPath $blobPath -PathType Leaf) {
            return , ([IO.File]::ReadAllBytes($blobPath))
        }
    }
    $content = Get-NSMapValue $Meta 'content'
    if (($content -is [string]) -and $content.Length -gt 0) {
        $decoded = $null
        try {
            $decoded = [Convert]::FromBase64String($content)
        }
        catch {
            return $null
        }
        return , $decoded
    }
    return $null
}

# A real directory where a file has to land is the owner's, not ours: the restore
# steps over it and the proof names it.
function Test-NSProvisionDirectoryBlock {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (Test-NSReparsePoint $Path) { return $false }
    return (Test-Path -LiteralPath $Path -PathType Container)
}

# The restore lands by rename, so a reader never sees half a file, and it
# replaces a symlink rather than writing through it.
function Write-NSProvisionRestoredFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]]$Bytes
    )
    $temp = $Path + '.nightshift-restore'
    Remove-NSFile $temp
    [IO.File]::WriteAllBytes($temp, $Bytes)
    if (Test-NSReparsePoint $Path) {
        try {
            [IO.File]::Delete($Path)
        }
        catch {
            [IO.Directory]::Delete($Path)
        }
    }
    elseif (Test-Path -LiteralPath $Path -PathType Leaf) {
        Remove-NSFile $Path
    }
    [IO.File]::Move($temp, $Path)
}

# rmdir up the tree: a directory the engine created and nothing else needs goes
# away, and the walk stops at the work target itself.
function Remove-NSProvisionEmptyParents {
    param(
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string]$Path
    )
    $head = (Get-NSAbsolutePath $Target) + [string][IO.Path]::DirectorySeparatorChar
    $parent = [IO.Path]::GetDirectoryName($Path)
    while ((-not [string]::IsNullOrEmpty($parent)) -and $parent.StartsWith($head, [StringComparison]::Ordinal)) {
        try {
            [IO.Directory]::Delete($parent)
        }
        catch {
            return
        }
        $parent = [IO.Path]::GetDirectoryName($parent)
    }
}

function Invoke-NSProvisionRestore {
    param(
        [Parameter(Mandatory = $true)][string]$BaselineDir,
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)]$Baseline
    )
    foreach ($rel in (Sort-NSOrdinal @($Baseline.Keys))) {
        $meta = $Baseline[$rel]
        $path = Resolve-NSProvisionPath $Target $rel
        if (Test-NSPyTruthy (Get-NSMapValue $meta 'existed')) {
            if (Test-NSProvisionDirectoryBlock $path) { continue }
            $bytes = Get-NSProvisionRestoreBytes -BaselineDir $BaselineDir -Meta $meta
            if ($null -eq $bytes) { continue }
            $parent = [IO.Path]::GetDirectoryName($path)
            if ((-not [string]::IsNullOrEmpty($parent)) -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
                $null = New-Item -ItemType Directory -Path $parent -Force
            }
            Write-NSProvisionRestoredFile -Path $path -Bytes ([byte[]]$bytes)
            continue
        }
        if (Test-NSReparsePoint $path) {
            try {
                [IO.File]::Delete($path)
            }
            catch {
                [IO.Directory]::Delete($path)
            }
        }
        elseif (Test-Path -LiteralPath $path -PathType Leaf) {
            Remove-NSFile $path
        }
        Remove-NSProvisionEmptyParents -Target $Target -Path $path
    }
}

# The proof, after the restore: every file that existed hashes to its recorded
# digest and every file the engine created is gone. The first failure is the one
# reported, and it leaves the transaction and the store where they are.
function Test-NSProvisionRestored {
    param(
        [Parameter(Mandatory = $true)][string]$Target,
        $Baseline
    )
    if ($null -eq $Baseline) { return '' }
    foreach ($rel in (Sort-NSOrdinal @($Baseline.Keys))) {
        $meta = $Baseline[$rel]
        $path = Resolve-NSProvisionPath $Target $rel
        if (Test-NSPyTruthy (Get-NSMapValue $meta 'existed')) {
            if (Test-NSProvisionDirectoryBlock $path) {
                return ('a directory blocks the baseline path: ' + [string]$rel)
            }
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                return ('baseline file missing after restore: ' + [string]$rel)
            }
            if ((Get-NSFileSha256 $path) -cne [string](Get-NSMapValue $meta 'digest')) {
                return ('restored bytes do not match baseline digest: ' + [string]$rel)
            }
            continue
        }
        if (Test-NSPathEntry $path) { return ('created path still present: ' + [string]$rel) }
    }
    return ''
}

# Read-only twin of the proof: the bytes the store and the transaction hold for
# every file that existed already hash to the recorded digest, so a rollback
# would prove. Doctor and diagnose report this and restore nothing.
function Test-NSProvisionProvable {
    param(
        [Parameter(Mandatory = $true)][string]$BaselineDir,
        $Baseline
    )
    if ($null -eq $Baseline) { return $true }
    foreach ($rel in (Sort-NSOrdinal @($Baseline.Keys))) {
        $meta = $Baseline[$rel]
        if (-not (Test-NSPyTruthy (Get-NSMapValue $meta 'existed'))) { continue }
        $bytes = Get-NSProvisionRestoreBytes -BaselineDir $BaselineDir -Meta $meta
        if ($null -eq $bytes) { return $false }
        if ((Get-NSProvisionByteSha256 ([byte[]]$bytes)) -cne [string](Get-NSMapValue $meta 'digest')) { return $false }
    }
    return $true
}

function Get-NSProvisionRequiredFields {
    $fields = $null
    try {
        $fields = Get-NSJsonProperty (Get-NSSchemaDocument 'capability-recipe.json') 'requiredRecipeFields'
    }
    catch {
        $fields = $null
    }
    $names = New-Object Collections.Generic.List[string]
    if (($null -ne $fields) -and -not ($fields -is [string])) {
        foreach ($field in @($fields)) {
            if ($field -is [string]) { $names.Add($field) }
        }
    }
    if ($names.Count -eq 0) { return , @($script:NSProvisionRequiredFields) }
    return , $names.ToArray()
}

function Get-NSJsonStringList {
    param(
        $Value,
        [Parameter(Mandatory = $true)][string]$FieldName
    )
    $message = $FieldName + ' must be a list of relative paths'
    if ($null -eq $Value) { return @() }
    if ($Value -is [Collections.IDictionary]) { throw $message }
    if ($Value -is [string]) {
        if ($Value.Length -eq 0) { throw $message }
        return @($Value)
    }
    if (-not ($Value -is [Collections.IEnumerable])) { throw $message }
    $items = New-Object Collections.Generic.List[string]
    foreach ($entry in @($Value)) {
        if (($entry -is [Collections.IEnumerable]) -and -not ($entry -is [string])) {
            foreach ($nested in @($entry)) {
                if (-not ($nested -is [string]) -or $nested.Length -eq 0) { throw $message }
                $items.Add($nested)
            }
            continue
        }
        if (-not ($entry -is [string]) -or $entry.Length -eq 0) { throw $message }
        $items.Add($entry)
    }
    return , $items.ToArray()
}

function Read-NSProvisionRecipe {
    param([Parameter(Mandatory = $true)][string]$Path)
    $recipe = ConvertFrom-NSJsonText ([IO.File]::ReadAllText($Path, $script:NSUtf8NoBom))
    if (-not ($recipe -is [Collections.IDictionary])) { throw 'recipe must be an object' }
    $missing = New-Object Collections.Generic.List[string]
    foreach ($field in (Get-NSProvisionRequiredFields)) {
        if (-not $recipe.Contains($field)) { $missing.Add($field) }
    }
    if ($missing.Count -gt 0) { throw ('missing fields: ' + ($missing -join ', ')) }
    $recipe['allowedFiles'] = Get-NSJsonStringList (Get-NSMapValue $recipe 'allowedFiles') 'allowedFiles'
    return $recipe
}

function Get-NSProvisionAllowedFiles {
    param($Recipe)
    $allowed = New-Object Collections.Generic.List[string]
    $declared = Get-NSMapValue $Recipe 'allowedFiles'
    if (($null -ne $declared) -and -not ($declared -is [string])) {
        foreach ($entry in @($declared)) { $allowed.Add((Get-NSProvisionRelPath ([string]$entry))) }
    }
    elseif ($declared -is [string]) {
        $allowed.Add((Get-NSProvisionRelPath $declared))
    }
    return , $allowed.ToArray()
}

function Test-NSProvisionUnderAllowed {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Rel,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Allowed
    )
    $candidate = Get-NSProvisionRelPath $Rel
    foreach ($entry in $Allowed) {
        $normalized = Get-NSProvisionRelPath $entry
        if ($candidate -ceq $normalized) { return $true }
        if ($candidate.StartsWith($normalized.TrimEnd('/') + '/', [StringComparison]::Ordinal)) { return $true }
    }
    return $false
}

function Get-NSProvisionCommandText {
    param($Step)
    if ($Step -is [Collections.IDictionary]) {
        foreach ($key in @('command', 'cmd')) {
            $value = Get-NSMapValue $Step $key
            if (($value -is [string]) -and $value.Length -gt 0) { return $value }
        }
        return ''
    }
    if ($Step -is [string]) { return $Step }
    return ''
}

function Test-NSProvisionGitTarget {
    param([Parameter(Mandatory = $true)][string]$Target)
    $result = Invoke-NSGitCommand $Target @('rev-parse', '--is-inside-work-tree')
    if ($result.ExitCode -ne 0) { return $false }
    return (([string]$result.Text).Trim() -ceq 'true')
}

function Get-NSProvisionPorcelain {
    param(
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Paths
    )
    $lines = New-Object Collections.Generic.List[string]
    if ($Paths.Count -eq 0) { return , $lines.ToArray() }
    if (-not (Test-NSProvisionGitTarget $Target)) { return , $lines.ToArray() }
    $result = Invoke-NSGitCommand $Target (@('status', '--porcelain', '--') + $Paths)
    if ($result.ExitCode -ne 0) { return , $lines.ToArray() }
    foreach ($line in @($result.Lines)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$line)) { $lines.Add([string]$line) }
    }
    return , $lines.ToArray()
}

function Get-NSProvisionInventory {
    param([Parameter(Mandatory = $true)][string]$Project)
    $path = (Get-NSProvisionPaths $Project)['inventory']
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        $document = New-NSOrdinalMap
        $document['schemaVersion'] = 1
        $document['source'] = 'default'
        $document['items'] = @()
        $document['updatedAt'] = $null
        $document['tickProof'] = $false
        return $document
    }
    $document = ConvertFrom-NSJsonText ([IO.File]::ReadAllText($path, $script:NSUtf8NoBom))
    if (-not ($document -is [Collections.IDictionary])) { throw 'inventory must be an object' }
    return $document
}

# One row per capability, replaced in place. schemaVersion, updatedAt and
# tickProof are the writer's, never the caller's.
function Write-NSProvisionInventory {
    param(
        [Parameter(Mandatory = $true)][string]$Project,
        [Parameter(Mandatory = $true)]$Recipe,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$SetupCommit
    )
    $paths = Get-NSProvisionPaths $Project
    $document = $null
    try {
        $document = Get-NSProvisionInventory $Project
    }
    catch {
        $document = New-NSOrdinalMap
        $document['items'] = @()
    }
    $capability = [string](Get-NSMapValue $Recipe 'capabilityId')
    $items = New-Object Collections.Generic.List[object]
    $recorded = Get-NSMapValue $document 'items'
    if (($null -ne $recorded) -and -not ($recorded -is [string])) {
        foreach ($item in @($recorded)) {
            if (-not ($item -is [Collections.IDictionary])) { continue }
            if ([string](Get-NSMapValue $item 'capability') -ceq $capability) { continue }
            $items.Add($item)
        }
    }
    $row = New-NSOrdinalMap
    $row['capability'] = $capability
    $row['command'] = Get-NSProvisionCommandText (Get-NSMapValue $Recipe 'smoke')
    $row['source'] = 'recipe'
    $row['verifiedAt'] = Get-NSProvisionNow
    $row['configFiles'] = Get-NSPolicyField $Recipe 'allowedFiles'
    $row['recipeVersion'] = Get-NSMapValue $Recipe 'recipeVersion'
    $row['setupCommit'] = $SetupCommit
    $items.Add($row)
    $document['items'] = $items.ToArray()
    $document['schemaVersion'] = 1
    $document['updatedAt'] = Get-NSProvisionNow
    $document['tickProof'] = $false
    Write-NSEvidenceFileAtomic -Path $paths['inventory'] -Text ((ConvertTo-NSCanonicalJson $document) + "`n")
}

# The setup commit: the allowed files the transaction actually touched, staged
# and committed under one subject. Nothing staged is not a failure.
function Invoke-NSProvisionCommitTooling {
    param(
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)]$Recipe,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Touched
    )
    if (-not (Test-NSProvisionGitTarget $Target)) { return '' }
    $allowed = [string[]](Get-NSProvisionAllowedFiles $Recipe)
    $paths = New-Object Collections.Generic.List[string]
    foreach ($rel in $Touched) {
        if (Test-NSProvisionUnderAllowed -Rel $rel -Allowed $allowed) { $paths.Add((Get-NSProvisionRelPath $rel)) }
    }
    if ($paths.Count -eq 0) { return '' }
    foreach ($rel in $paths) {
        $null = Invoke-NSGitCommand $Target @('add', '--', $rel)
    }
    $subject = $script:NSProvisionSetupPrefix + ' ' + [string](Get-NSMapValue $Recipe 'capabilityId')
    $commit = Invoke-NSGitCommand $Target (@('commit', '-m', $subject, '--') + $paths.ToArray())
    if ($commit.ExitCode -ne 0) {
        if ((Get-NSProvisionPorcelain -Target $Target -Paths $paths.ToArray()).Count -eq 0) { return '' }
        throw 'commit-tooling failed'
    }
    $head = Invoke-NSGit $Target @('rev-parse', 'HEAD')
    if ([string]::IsNullOrEmpty($head)) { return '' }
    return $head
}

function Resolve-NSProvisionTarget {
    param([Parameter(Mandatory = $true)][string]$Project)
    $workspace = Get-NSAbsolutePath $Project
    $record = Join-Path $workspace '.nightshift/work-target'
    if (Test-Path -LiteralPath $record -PathType Leaf) {
        $lines = [IO.File]::ReadAllLines($record)
        if ($lines.Count -ge 1 -and -not [string]::IsNullOrWhiteSpace($lines[0])) {
            $target = $lines[0].Trim()
            if (-not [IO.Path]::IsPathRooted($target)) {
                $target = Join-Path $workspace $target
            }
            if (Test-Path -LiteralPath $target -PathType Container) {
                return (Get-NSAbsolutePath $target)
            }
        }
    }
    return $workspace
}

function Invoke-NSProvisionRollback {
    param(
        [Parameter(Mandatory = $true)][string]$Project,
        [Parameter(Mandatory = $true)]$Transaction,
        [Parameter(Mandatory = $true)][string]$Target
    )
    $paths = Get-NSProvisionPaths $Project
    $baseline = Get-NSMapValue $Transaction 'baseline'
    $detail = ''
    try {
        if ($null -ne $baseline) {
            Invoke-NSProvisionRestore -BaselineDir $paths['baseline'] -Target $Target -Baseline $baseline
        }
        $detail = Test-NSProvisionRestored -Target $Target -Baseline $baseline
    }
    catch {
        $detail = [string]$_.Exception.Message
    }
    if ($detail.Length -gt 0) {
        $document = New-NSOrdinalMap
        $document['ok'] = $false
        $document['rolledBack'] = $false
        $document['proven'] = $false
        $document['detail'] = $detail
        Write-NSProvisionJson $document
        return 3
    }
    Remove-NSPath $paths['baseline']
    Remove-NSFile $paths['transaction']
    $document = New-NSOrdinalMap
    $document['ok'] = $true
    $document['rolledBack'] = $true
    $document['capabilityId'] = [string](Get-NSMapValue $Transaction 'capabilityId')
    $document['touched'] = Get-NSProvisionTouched $Transaction
    $document['proven'] = $true
    Write-NSProvisionJson $document
    return 0
}

# record and commit-tooling are the two stages that finish rather than undo: the
# inventory row lands, the allowed files are committed under one subject, and the
# transaction goes away.
function Invoke-NSProvisionFinish {
    param(
        [Parameter(Mandatory = $true)][string]$Project,
        [Parameter(Mandatory = $true)]$Transaction,
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)]$Recipe
    )
    $paths = Get-NSProvisionPaths $Project
    $touched = [string[]](Get-NSProvisionTouched $Transaction)
    if ([string](Get-NSMapValue $Transaction 'stage') -ceq 'record') {
        Write-NSProvisionInventory -Project $Project -Recipe $Recipe -SetupCommit ''
        $Transaction['stage'] = 'commit-tooling'
        $Transaction['updatedAt'] = Get-NSProvisionNow
        Write-NSProvisionTransaction -Path $paths['transaction'] -Document $Transaction
    }
    $setup = Invoke-NSProvisionCommitTooling -Target $Target -Recipe $Recipe -Touched $touched
    if ($setup.Length -gt 0) {
        Write-NSProvisionInventory -Project $Project -Recipe $Recipe -SetupCommit $setup
    }
    Remove-NSPath $paths['baseline']
    Remove-NSFile $paths['transaction']
    $document = New-NSOrdinalMap
    $document['ok'] = $true
    $document['recovered'] = $true
    $document['finished'] = $true
    $document['capabilityId'] = Get-NSMapValue $Recipe 'capabilityId'
    $document['setupCommit'] = $setup
    $document['touched'] = $touched
    Write-NSProvisionJson $document
    return 0
}

# The one recovery path, and Start runs it before any product work.
#   0 nothing to recover, rolled back and proven, or late stages finished
#   2 the transaction is malformed - the field is named and nothing is touched
#   3 the restore could not be proven - the transaction and the store stay put
# -Rollback forces the undo whatever the stage; -Diagnose only reports.
# -BudgetSeconds is the engine's argument contract; recovery is bounded by the
# work itself - the recorded files and at most two Git calls - and never
# abandons a restore half done.
function Invoke-NSProvisionRecover {
    param(
        [Parameter(Mandatory = $true)][string]$Project,
        [int]$BudgetSeconds = 0,
        [switch]$Rollback,
        [switch]$Diagnose
    )
    $project = Get-NSAbsolutePath $Project
    if ($Diagnose.IsPresent) { return (Invoke-NSProvisionDiagnose -Project $project) }
    $paths = Get-NSProvisionPaths $project
    if (-not (Test-Path -LiteralPath $paths['transaction'] -PathType Leaf)) {
        $document = New-NSOrdinalMap
        $document['ok'] = $true
        $document['recovered'] = $false
        $document['detail'] = 'no transaction'
        Write-NSProvisionJson $document
        return 0
    }
    $transaction = $null
    # State is a file, never a link: a transaction reached through a reparse
    # point is malformed, not followed.
    if (-not (Test-NSReparsePoint $paths['transaction'])) {
        try {
            $transaction = Read-NSProvisionTransaction $paths['transaction']
        }
        catch {
            $transaction = $null
        }
    }
    $field = 'document'
    if ($null -ne $transaction) { $field = Test-NSProvisionTransaction $transaction }
    $target = ''
    if ($field.Length -eq 0) {
        $target = [string](Get-NSMapValue $transaction 'workTarget')
        if ([string]::IsNullOrEmpty($target)) { $target = Resolve-NSProvisionTarget $project }
        $field = Test-NSProvisionBaseline -Baseline (Get-NSMapValue $transaction 'baseline') -Target $target
    }
    if ($field.Length -gt 0) {
        $document = New-NSOrdinalMap
        $document['ok'] = $false
        $document['recovered'] = $false
        $document['malformed'] = $true
        $document['detail'] = 'malformed transaction: ' + $field
        Write-NSProvisionJson $document
        return 2
    }
    $stage = [string](Get-NSMapValue $transaction 'stage')
    $failed = Test-NSPyTruthy (Get-NSMapValue $transaction 'failed')
    if ($Rollback.IsPresent -or $failed -or ($script:NSProvisionRollbackStages -ccontains $stage)) {
        return (Invoke-NSProvisionRollback -Project $project -Transaction $transaction -Target $target)
    }
    $recipePath = [string](Get-NSMapValue $transaction 'recipePath')
    $recipe = $null
    if ($recipePath.Length -gt 0) {
        try {
            $recipe = Read-NSProvisionRecipe $recipePath
        }
        catch {
            $recipe = $null
        }
    }
    if ($null -eq $recipe) {
        return (Invoke-NSProvisionRollback -Project $project -Transaction $transaction -Target $target)
    }
    try {
        return (Invoke-NSProvisionFinish -Project $project -Transaction $transaction -Target $target -Recipe $recipe)
    }
    catch {
        return (Invoke-NSProvisionRollback -Project $project -Transaction $transaction -Target $target)
    }
}

# What Doctor reads: whether a transaction is open, at which stage, for which
# capability, and whether its baseline would prove. Doctor never restores.
function Get-NSProvisionDiagnosis {
    param([Parameter(Mandatory = $true)][string]$Project)
    $paths = Get-NSProvisionPaths $Project
    $report = New-NSOrdinalMap
    $report['present'] = $false
    $report['malformed'] = ''
    $report['stage'] = ''
    $report['capabilityId'] = ''
    $report['provable'] = $false
    if (Test-NSReparsePoint $paths['transaction']) {
        $report['present'] = $true
        $report['malformed'] = 'document'
        return $report
    }
    if (-not (Test-Path -LiteralPath $paths['transaction'] -PathType Leaf)) { return $report }
    $report['present'] = $true
    $transaction = $null
    try {
        $transaction = Read-NSProvisionTransaction $paths['transaction']
    }
    catch {
        $transaction = $null
    }
    $field = 'document'
    if ($null -ne $transaction) { $field = Test-NSProvisionTransaction $transaction }
    if ($field.Length -gt 0) {
        $report['malformed'] = $field
        return $report
    }
    $report['stage'] = [string](Get-NSMapValue $transaction 'stage')
    $report['capabilityId'] = [string](Get-NSMapValue $transaction 'capabilityId')
    $target = [string](Get-NSMapValue $transaction 'workTarget')
    if ([string]::IsNullOrEmpty($target)) { $target = Resolve-NSProvisionTarget $Project }
    $baseline = Get-NSMapValue $transaction 'baseline'
    $field = Test-NSProvisionBaseline -Baseline $baseline -Target $target
    if ($field.Length -gt 0) {
        $report['malformed'] = $field
        return $report
    }
    $report['provable'] = (Test-NSProvisionProvable -BaselineDir $paths['baseline'] -Baseline $baseline)
    return $report
}

# The class, then the sentence - one tab-separated line, the same on every host.
function Get-NSProvisionDiagnosisClass {
    param([Parameter(Mandatory = $true)]$Report)
    if ([string]$Report['malformed'] -cne '') { return 'malformed' }
    if ($Report['provable']) { return 'provable' }
    return 'unprovable'
}

function Get-NSProvisionDiagnosisLine {
    param([Parameter(Mandatory = $true)]$Report)
    if ([string]$Report['malformed'] -cne '') {
        return ('provision-transaction.json is malformed (' + [string]$Report['malformed'] + ')')
    }
    $state = 'unprovable'
    if ($Report['provable']) { $state = 'provable' }
    return ('provision transaction stage=' + [string]$Report['stage'] + ' capability=' +
        [string]$Report['capabilityId'] + ' baseline=' + $state)
}

# Read-only: no transaction prints nothing at all.
function Invoke-NSProvisionDiagnose {
    param([Parameter(Mandatory = $true)][string]$Project)
    $report = Get-NSProvisionDiagnosis $Project
    if (-not $report['present']) { return 0 }
    Write-NSProvisionOut ((Get-NSProvisionDiagnosisClass $report) + "`t" + (Get-NSProvisionDiagnosisLine $report))
    return 0
}

function Invoke-NSProvisionCommand {
    param(
        [AllowEmptyString()][string]$Project = '',
        [AllowEmptyString()][string]$Command = '',
        [AllowEmptyString()][string]$BudgetSeconds = '',
        [switch]$Rollback,
        [switch]$Diagnose
    )
    if ([string]::IsNullOrEmpty($Project) -or [string]::IsNullOrEmpty($Command)) { return (Write-NSProvisionUsage) }
    $budget = $script:NSProvisionBudgetDefault
    if (-not [string]::IsNullOrEmpty($BudgetSeconds)) {
        if ($BudgetSeconds -cnotmatch '^[0-9]+$') { return (Write-NSProvisionUsage) }
        $budget = [int]$BudgetSeconds
    }
    $workspace = Get-NSAbsolutePath $Project
    if (-not (Test-Path -LiteralPath $workspace -PathType Container)) {
        Write-NSProvisionError ('provision: not a directory: ' + $workspace)
        return 1
    }
    switch ($Command) {
        'recover' {
            return (Invoke-NSProvisionRecover -Project $workspace -BudgetSeconds $budget `
                    -Rollback:$Rollback -Diagnose:$Diagnose)
        }
        'rollback' {
            return (Invoke-NSProvisionRecover -Project $workspace -BudgetSeconds $budget -Rollback)
        }
    }
    return (Write-NSProvisionUsage)
}

# Comparison and morning receipt - the native side of
# runtime/windows/evidence-compare.ps1 and morning-receipt.ps1.
#
# Nothing here reruns a tool or reads a work target for a finding. Every row a
# comparison prints and every line the receipt renders comes from a record
# already in the ledger, cited by id. A tool that failed, a source the ledger
# marked unavailable, and a moved environment digest are reported as
# unavailable - never as improvement.
# ---------------------------------------------------------------------------

$script:NSEvidenceBaselineDomain = 'baseline'
$script:NSEvidenceLifecycleDomains = @('baseline', 'checkpoint')

# The eight classes a comparison assigns, in report order.
$script:NSCompareClasses = @(
    'new', 'cleared', 'unchanged', 'regressed',
    'unavailable', 'rejected-duplicate', 'parked', 'human-only'
)

# Record state to class. First match wins, and the statuses that mean "could not
# be measured" come first so a tool that never ran is never read as a fix.
$script:NSCompareUnavailableStatuses = @('unavailable', 'unsupported', 'unmeasured')
$script:NSCompareHumanStatuses = @('human-only')
$script:NSCompareClearedStatuses = @('fixed')
$script:NSCompareParkedDispositions = @('parked')
$script:NSCompareDuplicateDispositions = @('rejected-duplicate')

# clear-all fails on any of these. no-regression-plus-selected-debt fails only on
# a regression, plus a selected id that did not clear.
$script:NSCompareOutstandingClasses = @('new', 'unchanged', 'regressed', 'unavailable')
$script:NSCompareRegressionClasses = @('regressed')

$script:NSCompareDigestLength = 12
$script:NSCompareTitle = '# Comparison'
$script:NSCompareTableHeader = '| ID | Class | Digest | Sources | Locator |'
$script:NSCompareTableRule = '| --- | --- | --- | --- | --- |'
$script:NSCompareRowFormat = '| {0} | {1} | {2} | {3} | {4} |'
$script:NSCompareEmptyLocator = 'empty'
$script:NSCompareBaselineFormat = 'Baseline: {0} {1} {2} {1} `{3}`'
$script:NSCompareModeFormat = 'Mode: {0}'
$script:NSCompareSourceFormat = 'Source: {0}'
$script:NSCompareResultFormat = 'Result: {0}'
$script:NSComparePassLabel = 'pass'
$script:NSCompareFailLabel = 'fail'
$script:NSCompareSummaryPrefix = 'Summary: '
$script:NSCompareSummaryCellFormat = '{0} {1}'
$script:NSCompareSummarySeparator = ', '
$script:NSCompareSelectedDebtPrefix = 'Selected debt outstanding: '
$script:NSMdPipeEscape = '\|'
$script:NSMdSourceSeparator = ', '

$script:NSReceiptTitle = '# Morning receipt'
$script:NSReceiptViewNames = @('owner', 'reviewer', 'release', 'artifact')
$script:NSReceiptNone = 'none'
$script:NSReceiptEndingUnknown = 'unknown'
$script:NSReceiptFileFormat = 'morning-{0}-{1}.md'
$script:NSReceiptDateFileFormat = 'morning-{0}.md'
$script:NSReceiptFieldFormat = '- {0}: {1}'
$script:NSReceiptNestedFormat = '  - {0}: {1}'
$script:NSReceiptPlainFormat = '- {0}'
$script:NSReceiptItemsFormat = '{0} ticked, {1} open'
$script:NSReceiptPolicyFormat = 'profile {0}, verification {1}, tooling {2}'
$script:NSReceiptAllowanceFormat = '{0} ({1}, {2})'
$script:NSReceiptBaselineFormat = '{0} `{1}` {2} env {3} raw {4} ({5})'
$script:NSReceiptVerifiedNoneFormat = 'none {0} verification level {1} (owner)'
$script:NSReceiptVerifiedNoPolicyFormat = 'none {0} no shift policy was written'
$script:NSReceiptGatesFormat = '{0} (punch list)'
$script:NSReceiptChosenSource = 'one-shift'
$script:NSReceiptNextFormat = '{0} {1} next: {2}'

# Section headings in receipt order, and the sections each view renders. Same
# data, same conclusions - a view only decides how much of it.

$script:NSReceiptSectionTitle = New-Object Collections.Specialized.OrderedDictionary([StringComparer]::Ordinal)
$script:NSReceiptSectionTitle['shift'] = '## Shift'
$script:NSReceiptSectionTitle['baseline'] = '## Baseline'
$script:NSReceiptSectionTitle['changed'] = '## What changed'
$script:NSReceiptSectionTitle['parked'] = '## Parked'
$script:NSReceiptSectionTitle['unsupported'] = '## Unsupported / unmeasured'
$script:NSReceiptSectionTitle['next'] = '## Next'

$script:NSReceiptViewSections = New-Object Collections.Specialized.OrderedDictionary([StringComparer]::Ordinal)
$script:NSReceiptViewSections['owner'] = @('shift', 'baseline', 'changed', 'parked', 'unsupported', 'next')
$script:NSReceiptViewSections['reviewer'] = @('baseline', 'changed')
$script:NSReceiptViewSections['release'] = @('shift', 'changed')
$script:NSReceiptViewSections['artifact'] = @('shift', 'parked', 'unsupported', 'next')

$script:NSReceiptLabels = New-Object Collections.Specialized.OrderedDictionary([StringComparer]::Ordinal)
$script:NSReceiptLabels['shift'] = 'Shift'
$script:NSReceiptLabels['host'] = 'Host'
$script:NSReceiptLabels['workTarget'] = 'Work target'
$script:NSReceiptLabels['started'] = 'Started'
$script:NSReceiptLabels['ended'] = 'Ended'
$script:NSReceiptLabels['ending'] = 'Ending'
$script:NSReceiptLabels['items'] = 'Items'
$script:NSReceiptLabels['commits'] = 'Commits'
$script:NSReceiptLabels['receipts'] = 'Receipts'
$script:NSReceiptLabels['policy'] = 'Policy'
$script:NSReceiptLabels['allowance'] = 'Allowance'
$script:NSReceiptLabels['gates'] = 'Gates'
$script:NSReceiptLabels['verified'] = 'Verified'
$script:NSReceiptLabels['disabled'] = 'Disabled by owner'
$script:NSReceiptLabels['unavailable'] = 'Unavailable'
$script:NSReceiptLabels['default'] = 'Default'
$script:NSReceiptLabels['rollback'] = 'Rollback'
$script:NSReceiptLabels['building'] = 'Building'

# Statuses section 5 owns: a surface nobody measured, and one only a human can.
$script:NSReceiptUnmeasuredStatuses = @('human-only', 'unsupported', 'unmeasured')
$script:NSReceiptVerifiedLadder = 'verified-after-change'

# ---------------------------------------------------------------------------
# Small readers over a parsed record
# ---------------------------------------------------------------------------

function Get-NSEvidenceDash {
    return ([string][char]0x2014)
}

function Get-NSEvidenceJoiner {
    return (' ' + (Get-NSEvidenceDash) + ' ')
}

function Get-NSEvidenceDay {
    $now = Get-NSEvidenceNow
    if ($now -cmatch '^[0-9]{4}-[0-9]{2}-[0-9]{2}') { return $now.Substring(0, 10) }
    return ([DateTime]::UtcNow.ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture))
}

function Get-NSEvidenceLedgerRecords {
    param([Parameter(Mandatory = $true)][string]$Workspace)
    $paths = Get-NSEvidencePaths $Workspace
    $records = Read-NSEvidenceRecords $paths['jsonl']
    if ($null -eq $records) { return , @() }
    if ($records -is [Collections.Generic.List[object]]) {
        return , $records.ToArray()
    }
    return , [object[]]@($records)
}

function Get-NSRecordText {
    param($Record, [Parameter(Mandatory = $true)][string]$Key)
    $value = Get-NSMapValue $Record $Key
    if ($null -eq $value) { return '' }
    if ($value -is [string]) { return $value }
    return (ConvertTo-NSPyText $value)
}

function Get-NSRecordDetails {
    param($Record)
    $details = Get-NSMapValue $Record 'details'
    if ($details -is [Collections.IDictionary]) { return $details }
    return (New-NSOrdinalMap)
}

# A JSON array of strings, a lone string, or nothing - always an array back.
function Get-NSRecordList {
    param($Record, [Parameter(Mandatory = $true)][string]$Key)
    $items = New-Object Collections.Generic.List[string]
    $value = Get-NSMapValue $Record $Key
    if ($null -eq $value) { return , $items.ToArray() }
    if ($value -is [string]) {
        if ($value.Length -gt 0) { $items.Add($value) }
        return , $items.ToArray()
    }
    if ($value -is [Collections.IEnumerable]) {
        foreach ($item in $value) {
            if ($null -eq $item) { continue }
            $text = ConvertTo-NSPyText $item
            if ($text.Length -gt 0) { $items.Add($text) }
        }
    }
    return , $items.ToArray()
}

function Get-NSUniqueSorted {
    param([AllowNull()][AllowEmptyCollection()][string[]]$Items)
    $map = New-NSOrdinalMap
    if ($null -ne $Items) {
        foreach ($item in $Items) {
            if ([string]::IsNullOrEmpty($item)) { continue }
            $map[$item] = $true
        }
    }
    return , (Sort-NSOrdinal ([string[]]@($map.Keys)))
}

function Get-NSCompareShortDigest {
    param([AllowEmptyString()][string]$Digest)
    if ([string]::IsNullOrEmpty($Digest)) { return '' }
    if ($Digest.Length -le $script:NSCompareDigestLength) { return $Digest }
    return $Digest.Substring(0, $script:NSCompareDigestLength)
}

# Reads either shape back: the {digest,id} array this module writes, or a plain
# array of ids from a hand-written record.
function Get-NSBaselineSeenMap {
    param($Baseline)
    $map = New-NSOrdinalMap
    $details = Get-NSRecordDetails $Baseline
    $seen = Get-NSMapValue $details 'seen'
    if ($null -eq $seen) { return $map }
    if ($seen -is [string]) {
        if ($seen.Length -gt 0) { $map[$seen] = '' }
        return $map
    }
    if (-not ($seen -is [Collections.IEnumerable])) { return $map }
    foreach ($entry in $seen) {
        if ($entry -is [Collections.IDictionary]) {
            $id = Get-NSRecordText $entry 'id'
            if ($id.Length -eq 0) { continue }
            $map[$id] = Get-NSRecordText $entry 'digest'
            continue
        }
        if ($null -eq $entry) { continue }
        $id = ConvertTo-NSPyText $entry
        if ($id.Length -gt 0) { $map[$id] = '' }
    }
    return $map
}

function Get-NSEvidenceWorkTarget {
    param([Parameter(Mandatory = $true)][string]$Workspace)
    try {
        return (Resolve-NSWorkTarget $Workspace)
    }
    catch {
        return (Get-NSAbsolutePath $Workspace)
    }
}

# ---------------------------------------------------------------------------
# The comparison
# ---------------------------------------------------------------------------

function Get-NSPolicyCompletionModeFrom {
    param($Policy)
    if ($null -eq $Policy) { return $script:NSPolicyCompletionDefault }
    $mode = Get-NSMapValue $Policy 'completionMode'
    if (Test-NSEvidenceEnum $mode $script:NSPolicyCompletionModes) { return [string]$mode }
    return $script:NSPolicyCompletionDefault
}

function Get-NSPolicyCompletionMode {
    param([Parameter(Mandatory = $true)][string]$Workspace)
    $policy = $null
    try {
        $policy = Get-NSShiftPolicy $Workspace
    }
    catch {
        $policy = $null
    }
    return (Get-NSPolicyCompletionModeFrom $policy)
}

function Get-NSPolicySelectedDebt {
    param([Parameter(Mandatory = $true)][string]$Workspace)
    $policy = $null
    try {
        $policy = Get-NSShiftPolicy $Workspace
    }
    catch {
        $policy = $null
    }
    if ($null -eq $policy) { return , @() }
    return (Get-NSUniqueSorted (Get-NSRecordList $policy 'selectedDebt'))
}

# Every originating tool a row stands on. A record that already carries sources
# keeps them; otherwise its own source is the one entry.
function Get-NSRowSources {
    param($Record)
    $sources = Get-NSRecordList $Record 'sources'
    if (@($sources).Count -gt 0) { return , @($sources) }
    $single = Get-NSRecordText $Record 'source'
    if ($single.Length -gt 0) { return , @($single) }
    return , @()
}

# One record, one class. Ordered so an unavailable source is never read as an
# improvement and a duplicate is never read as an outstanding finding.
function Get-NSCompareClass {
    param($Record, $SeenMap, [bool]$EnvironmentMoved)
    $status = Get-NSRecordText $Record 'status'
    $disposition = Get-NSRecordText $Record 'disposition'
    if ($script:NSCompareUnavailableStatuses -ccontains $status) { return 'unavailable' }
    if ($script:NSCompareHumanStatuses -ccontains $status) { return 'human-only' }
    if ($script:NSCompareDuplicateDispositions -ccontains $disposition) { return 'rejected-duplicate' }
    if ((Get-NSRecordText $Record 'duplicateOf').Length -gt 0) { return 'rejected-duplicate' }
    if ($script:NSCompareParkedDispositions -ccontains $disposition) { return 'parked' }
    if ($script:NSCompareClearedStatuses -ccontains $status) {
        if ($EnvironmentMoved) { return 'unavailable' }
        return 'cleared'
    }
    $id = Get-NSRecordText $Record 'id'
    if (-not $SeenMap.Contains($id)) { return 'new' }
    $before = [string]$SeenMap[$id]
    $now = Get-NSRecordText $Record 'digest'
    if ($before.Length -gt 0 -and $now.Length -gt 0 -and -not ($before -ceq $now)) { return 'regressed' }
    return 'unchanged'
}

function Get-NSCompareCounts {
    param($Rows)
    $counts = New-NSOrdinalMap
    foreach ($class in $script:NSCompareClasses) { $counts[$class] = [long]0 }
    foreach ($row in @($Rows)) {
        $class = [string]$row['class']
        if (-not $counts.Contains($class)) { $counts[$class] = [long]0 }
        $counts[$class] = [long]$counts[$class] + 1
    }
    return $counts
}

function Get-NSCompareBaselineRecords {
    param($Records)
    $found = New-Object Collections.Generic.List[object]
    foreach ($record in @($Records)) {
        if ((Get-NSRecordText $record 'domain') -ceq $script:NSEvidenceBaselineDomain) { $found.Add($record) }
    }
    return , $found.ToArray()
}

function Get-NSCompareBaselineSourceClass {
    param($Baseline)
    $sourceClass = Get-NSRecordText (Get-NSRecordDetails $Baseline) 'sourceClass'
    if ($sourceClass.Length -gt 0) { return $sourceClass }
    return (Get-NSRecordText $Baseline 'sourceClass')
}

# Reruns nothing. Reads the records sharing the baseline's source class, keeps
# the last state recorded for each id, and classifies by id and digest.
function Get-NSEvidenceComparison {
    param(
        [Parameter(Mandatory = $true)][string]$Workspace,
        [Parameter(Mandatory = $true)][string]$Baseline,
        $Records = $null,
        [AllowEmptyString()][string]$Mode = '',
        $SelectedDebt = $null
    )
    $all = $Records
    if ($null -eq $all) { $all = Get-NSEvidenceLedgerRecords $Workspace }
    $anchor = $null
    foreach ($record in (Get-NSCompareBaselineRecords $all)) {
        if ((Get-NSRecordText $record 'id') -ceq $Baseline) {
            $anchor = $record
            break
        }
    }
    if ($null -eq $anchor) {
        throw (New-NSEvidenceHalt ('evidence-compare: unknown baseline ' + $Baseline))
    }
    $details = Get-NSRecordDetails $anchor
    $sourceClass = Get-NSCompareBaselineSourceClass $anchor
    $environment = Get-NSRecordText $details 'environmentDigest'
    $seenMap = Get-NSBaselineSeenMap $anchor

    # A second baseline for the same source class taken in another environment
    # means the two measurements are not comparable. Nothing may clear against
    # this baseline until the environment matches again.
    $environmentMoved = $false
    foreach ($record in (Get-NSCompareBaselineRecords $all)) {
        if ((Get-NSRecordText $record 'id') -ceq $Baseline) { continue }
        if (-not ((Get-NSCompareBaselineSourceClass $record) -ceq $sourceClass)) { continue }
        $other = Get-NSRecordText (Get-NSRecordDetails $record) 'environmentDigest'
        if ($other.Length -eq 0 -or $environment.Length -eq 0) { continue }
        if (-not ($other -ceq $environment)) { $environmentMoved = $true }
    }

    # The source speaks for itself, above every row. A baseline of this source taken at or after
    # the chosen one that reports itself unavailable means the tool did not run: nothing it did
    # not say can be read as an improvement, and an empty answer is not a clean one.
    $sourceUnavailable = $false
    $reached = $false
    foreach ($record in (Get-NSCompareBaselineRecords $all)) {
        if ((Get-NSRecordText $record 'id') -ceq $Baseline) { $reached = $true }
        if (-not $reached) { continue }
        if (-not ((Get-NSCompareBaselineSourceClass $record) -ceq $sourceClass)) { continue }
        if ($script:NSCompareUnavailableStatuses -ccontains (Get-NSRecordText $record 'status')) {
            $sourceUnavailable = $true
        }
    }

    $current = New-NSOrdinalMap
    foreach ($record in @($all)) {
        if ($script:NSEvidenceLifecycleDomains -ccontains (Get-NSRecordText $record 'domain')) { continue }
        if (-not ((Get-NSRecordText $record 'sourceClass') -ceq $sourceClass)) { continue }
        $id = Get-NSRecordText $record 'id'
        if ($id.Length -eq 0) { continue }
        $current[$id] = $record
    }

    # A rejected duplicate never erases its tool: its source joins the surviving
    # finding's row and the duplicate keeps a row of its own.
    $extraSources = New-NSOrdinalMap
    foreach ($key in @($current.Keys)) {
        $record = $current[$key]
        $survivor = Get-NSRecordText $record 'duplicateOf'
        if ($survivor.Length -eq 0) { continue }
        if (-not $extraSources.Contains($survivor)) {
            $extraSources[$survivor] = New-Object Collections.Generic.List[string]
        }
        foreach ($source in (Get-NSRowSources $record)) { $extraSources[$survivor].Add([string]$source) }
    }

    $union = New-NSOrdinalMap
    foreach ($key in @($current.Keys)) { $union[[string]$key] = $true }
    foreach ($key in @($seenMap.Keys)) { $union[[string]$key] = $true }

    $command = Get-NSRecordText $details 'command'
    $rows = New-Object Collections.Generic.List[object]
    foreach ($id in (Sort-NSOrdinal ([string[]]@($union.Keys)))) {
        $row = New-NSOrdinalMap
        $row['id'] = [string]$id
        if ($current.Contains($id)) {
            $record = $current[$id]
            $row['class'] = Get-NSCompareClass $record $seenMap $environmentMoved
            $row['digest'] = Get-NSRecordText $record 'digest'
            $row['locator'] = Get-NSRecordText $record 'locator'
            $sources = New-Object Collections.Generic.List[string]
            foreach ($source in (Get-NSRowSources $record)) { $sources.Add([string]$source) }
            if ($extraSources.Contains($id)) {
                foreach ($source in $extraSources[$id]) { $sources.Add([string]$source) }
            }
            $row['sources'] = Get-NSUniqueSorted ([string[]]$sources.ToArray())
        }
        else {
            # An id the baseline saw and the ledger no longer carries is not a
            # fix: absence is not evidence. Environment-moved absence is never
            # cleared either - the two hosts agree.
            $row['class'] = 'unavailable'
            $row['digest'] = [string]$seenMap[$id]
            $row['locator'] = ''
            $row['sources'] = Get-NSUniqueSorted ([string[]]@($command))
        }
        if ($sourceUnavailable) { $row['class'] = 'unavailable' }
        $rows.Add($row)
    }

    $mode = $Mode
    if ([string]::IsNullOrEmpty($mode)) { $mode = Get-NSPolicyCompletionMode $Workspace }
    if (-not ($script:NSPolicyCompletionModes -ccontains $mode)) { $mode = $script:NSPolicyCompletionDefault }
    $selected = $SelectedDebt
    if ($null -eq $selected) { $selected = Get-NSPolicySelectedDebt $Workspace }

    $outstanding = New-Object Collections.Generic.List[string]
    foreach ($id in @($selected)) {
        $cleared = $false
        foreach ($row in $rows) {
            if ((([string]$row['id']) -ceq ([string]$id)) -and (([string]$row['class']) -ceq 'cleared')) {
                $cleared = $true
            }
        }
        if (-not $cleared) { $outstanding.Add([string]$id) }
    }

    $pass = $true
    if ($mode -ceq 'no-regression-plus-selected-debt') {
        foreach ($row in $rows) {
            if ($script:NSCompareRegressionClasses -ccontains ([string]$row['class'])) { $pass = $false }
        }
        if ($outstanding.Count -gt 0) { $pass = $false }
    }
    else {
        if ($sourceUnavailable -or $environmentMoved) { $pass = $false }
        foreach ($row in $rows) {
            if ($script:NSCompareOutstandingClasses -ccontains ([string]$row['class'])) { $pass = $false }
        }
    }

    $counts = Get-NSCompareCounts $rows.ToArray()
    $summary = New-NSOrdinalMap
    foreach ($class in $script:NSCompareClasses) { $summary[$class] = [long]$counts[$class] }
    $summary['selectedDebtOutstanding'] = Get-NSUniqueSorted ([string[]]$outstanding.ToArray())
    $summary['total'] = [long]$rows.Count

    $document = New-NSOrdinalMap
    $document['baseline'] = $Baseline
    $document['mode'] = $mode
    $document['pass'] = $pass
    $document['rows'] = $rows.ToArray()
    $document['schemaVersion'] = 1
    $document['sourceStatus'] = if ($sourceUnavailable -or $environmentMoved) { 'unavailable' } else { 'available' }
    $document['summary'] = $summary

    $result = New-NSOrdinalMap
    $result['document'] = $document
    $result['record'] = $anchor
    $result['sourceClass'] = $sourceClass
    $result['command'] = $command
    $result['environmentMoved'] = $environmentMoved
    return $result
}

function Get-NSMdCell {
    param([AllowEmptyString()][string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return (Get-NSEvidenceDash) }
    return ($Text.Replace('|', $script:NSMdPipeEscape))
}

function Get-NSCompareRowLine {
    param($Row)
    $id = Get-NSMdCell ([string]$Row['id'])
    $class = Get-NSMdCell ([string]$Row['class'])
    $digest = Get-NSMdCell (Get-NSCompareShortDigest ([string]$Row['digest']))
    $sources = Get-NSMdCell ((@($Row['sources']) -join $script:NSMdSourceSeparator))
    $locator = Get-NSMdCell ([string]$Row['locator'])
    return ($script:NSCompareRowFormat -f $id, $class, $digest, $sources, $locator)
}

function Get-NSCompareTableLines {
    param($Rows, [string]$SourceStatus = 'available')
    $lines = New-Object Collections.Generic.List[string]
    $lines.Add($script:NSCompareTableHeader)
    $lines.Add($script:NSCompareTableRule)
    $count = 0
    foreach ($row in @($Rows)) {
        $lines.Add((Get-NSCompareRowLine $row))
        $count++
    }
    if ($count -eq 0) {
        # An empty table says why it is empty: a source that ran and found nothing is not the
        # same answer as a source that never ran.
        $dash = Get-NSEvidenceDash
        $why = $script:NSCompareEmptyLocator
        if ($SourceStatus -ceq 'unavailable') { $why = 'unavailable' }
        $lines.Add(($script:NSCompareRowFormat -f $dash, $dash, $dash, $dash, $why))
    }
    return , $lines.ToArray()
}

function Get-NSCompareSummaryLines {
    param($Counts, $Outstanding)
    $cells = New-Object Collections.Generic.List[string]
    foreach ($class in $script:NSCompareClasses) {
        $value = [long]0
        if ($Counts.Contains($class)) { $value = [long]$Counts[$class] }
        $cells.Add(($script:NSCompareSummaryCellFormat -f $class, $value))
    }
    $lines = New-Object Collections.Generic.List[string]
    $lines.Add($script:NSCompareSummaryPrefix + (($cells -join $script:NSCompareSummarySeparator)))
    $ids = @($Outstanding)
    if ($ids.Count -gt 0) {
        $lines.Add($script:NSCompareSelectedDebtPrefix + (($ids -join $script:NSCompareSummarySeparator)))
    }
    return , $lines.ToArray()
}

function Get-NSCompareResultLabel {
    param($Pass)
    if ([bool]$Pass) { return $script:NSComparePassLabel }
    return $script:NSCompareFailLabel
}

function Get-NSCompareMarkdown {
    param($Comparison)
    $document = $Comparison['document']
    $dash = Get-NSEvidenceDash
    $lines = New-Object Collections.Generic.List[string]
    $lines.Add($script:NSCompareTitle)
    $lines.Add('')
    $lines.Add(($script:NSCompareBaselineFormat -f ([string]$document['baseline']), $dash, `
        ([string]$Comparison['sourceClass']), ([string]$Comparison['command'])))
    $lines.Add(($script:NSCompareModeFormat -f ([string]$document['mode'])))
    $lines.Add(($script:NSCompareSourceFormat -f ([string]$document['sourceStatus'])))
    $lines.Add(($script:NSCompareResultFormat -f (Get-NSCompareResultLabel $document['pass'])))
    $lines.Add('')
    foreach ($line in (Get-NSCompareTableLines $document['rows'] ([string]$document['sourceStatus']))) { $lines.Add($line) }
    $lines.Add('')
    $summary = $document['summary']
    foreach ($line in (Get-NSCompareSummaryLines $summary $summary['selectedDebtOutstanding'])) { $lines.Add($line) }
    return (($lines -join "`n") + "`n")
}

# ---------------------------------------------------------------------------
# The morning receipt
# ---------------------------------------------------------------------------

# The gate writes this path in end_shift and the archive helper moves the file
# from it. UTC, so a shift that crosses local midnight still files under the day
# the ledger stamped. A shift that wrote no policy has no id, and the date alone
# names its receipt.
function Get-NSMorningReceiptPath {
    param([Parameter(Mandatory = $true)][string]$Workspace)
    $shiftId = ''
    $policy = $null
    try {
        $policy = Get-NSShiftPolicy $Workspace
    }
    catch {
        $policy = $null
    }
    if ($null -ne $policy) {
        $candidate = Get-NSRecordText $policy 'shiftId'
        if ($candidate.Length -gt 0) { $shiftId = $candidate }
    }
    if ($shiftId.Length -gt 0) {
        $name = $script:NSReceiptFileFormat -f (Get-NSEvidenceDay), $shiftId
    }
    else {
        $name = $script:NSReceiptDateFileFormat -f (Get-NSEvidenceDay)
    }
    return (Join-NSPath (Get-NSReceiptsDir (Get-NSAbsolutePath $Workspace)) $name)
}

function Write-NSMorningReceiptFile {
    param([Parameter(Mandatory = $true)][string]$Workspace)
    $path = Get-NSMorningReceiptPath $Workspace
    # A page already standing for this shift is the one the owner asked for - a custom handoff
    # the model wrote, or the page a duplicate stop event already rendered. Neither is replaced.
    if (Test-Path -LiteralPath $path) { return $path }
    $view = Get-NSHandoffView $Workspace
    $null = Get-NSMorningReceipt -Workspace $Workspace -View $view -Out $path
    return $path
}

# Get-NSHandoffView <workspace> - the reader the owner configured, or owner.
function Get-NSHandoffView {
    param([Parameter(Mandatory = $true)][string]$Workspace)
    $block = Get-NSHandoffBlock $Workspace
    if ($null -ne $block) {
        $view = Get-NSMapValue $block 'view'
        if ($script:NSReceiptViewNames -ccontains $view) { return [string]$view }
    }
    return 'owner'
}

# Test-NSHandoffEnabled <workspace> - false only when the owner turned the page off. A shift that
# writes no page still keeps every factual record it made.
function Test-NSHandoffEnabled {
    param([Parameter(Mandatory = $true)][string]$Workspace)
    $block = Get-NSHandoffBlock $Workspace
    if ($null -eq $block) { return $true }
    if (-not $block.Contains('enabled')) { return $true }
    return ([bool]$block['enabled'])
}

function Get-NSHandoffBlock {
    param([Parameter(Mandatory = $true)][string]$Workspace)
    $path = (Get-NSPolicyPaths $Workspace)['rules']
    if ((Test-NSReparsePoint $path) -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    $document = $null
    try {
        $document = ConvertFrom-NSJsonText ([IO.File]::ReadAllText($path, $script:NSUtf8NoBom))
    }
    catch {
        return $null
    }
    if (-not ($document -is [Collections.IDictionary])) { return $null }
    if (-not $document.Contains('handoff')) { return $null }
    $block = $document['handoff']
    if (-not ($block -is [Collections.IDictionary])) { return $null }
    return $block
}

# The last stamp the shift log carries, as the log wrote it. The log is stamped
# in host local time, so it is reported as written rather than relabelled UTC.
function Get-NSReceiptLogEnd {
    param([Parameter(Mandatory = $true)][string]$Path)
    $stamp = ''
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $stamp }
    try {
        foreach ($line in [IO.File]::ReadLines($Path)) {
            $match = [regex]::Match([string]$line, '^([0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2})')
            if ($match.Success) { $stamp = $match.Groups[1].Value }
        }
    }
    catch {
        return $stamp
    }
    return $stamp
}

# done when every box is ticked, otherwise whatever STOP says. Stop writes
# "<reason> MIDDOT <timestamp>"; the gate writes the bare word.
function Get-NSReceiptEnding {
    param([Parameter(Mandatory = $true)][string]$NightshiftDir, [int]$Open, [bool]$Readable = $true)
    $stop = Join-NSPath $NightshiftDir 'STOP'
    if (Test-Path -LiteralPath $stop -PathType Leaf) {
        $first = ''
        try {
            $first = [string](([IO.File]::ReadLines($stop) | Select-Object -First 1) -as [string])
        }
        catch {
            $first = ''
        }
        if ($null -eq $first) { $first = '' }
        $at = $first.IndexOf([char]0x00b7)
        if ($at -ge 0) { $first = $first.Substring(0, $at) }
        $reason = $first.Trim()
        if ($reason -ceq 'deadline') { return 'deadline' }
        if ($reason -ceq 'stalled') { return 'stall' }
        return 'stop'
    }
    if (-not $Readable) { return $script:NSReceiptEndingUnknown }
    if ($Open -eq 0) { return 'done' }
    return $script:NSReceiptEndingUnknown
}

function Get-NSReceiptCommitCount {
    param(
        [Parameter(Mandatory = $true)][string]$Target,
        [AllowEmptyString()][string]$Since
    )
    if ([string]::IsNullOrEmpty($Since)) { return '' }
    $result = Invoke-NSGitCommand $Target @('rev-list', '--count', '--since', $Since, 'HEAD')
    if ($result.ExitCode -ne 0) { return '' }
    $text = ([string]$result.Text).Trim()
    if ($text -cmatch '^[0-9]+$') { return $text }
    return ''
}

# The commands in the punch list's Gates block, in byte order. These are the
# checks the level either ran or skipped; the block stays their only list.
function Get-NSReceiptGateCommands {
    param([Parameter(Mandatory = $true)][string]$PunchList)
    $commands = New-Object Collections.Generic.List[string]
    if (-not (Test-Path -LiteralPath $PunchList -PathType Leaf)) {
        return (Get-NSUniqueSorted ([string[]]$commands.ToArray()))
    }
    $inGates = $false
    try {
        foreach ($line in [IO.File]::ReadLines($PunchList)) {
            $text = [string]$line
            if ($text -cmatch '^##\s') {
                $inGates = ($text -cmatch '^##\s+Gates\s*$')
                continue
            }
            if (-not $inGates) { continue }
            foreach ($match in [regex]::Matches($text, '`([^`]+)`')) {
                $command = $match.Groups[1].Value.Trim()
                if ($command.Length -gt 0) { $commands.Add($command) }
            }
        }
    }
    catch {
        return (Get-NSUniqueSorted ([string[]]$commands.ToArray()))
    }
    return (Get-NSUniqueSorted ([string[]]$commands.ToArray()))
}

function Get-NSReceiptRecordSources {
    param($Records, $Statuses, [AllowEmptyString()][string]$Ladder)
    $sources = New-Object Collections.Generic.List[string]
    foreach ($record in @($Records)) {
        if ($script:NSEvidenceLifecycleDomains -ccontains (Get-NSRecordText $record 'domain')) { continue }
        $keep = $false
        if ($null -ne $Statuses -and ($Statuses -ccontains (Get-NSRecordText $record 'status'))) { $keep = $true }
        if (-not [string]::IsNullOrEmpty($Ladder) -and ((Get-NSRecordText $record 'ladder') -ceq $Ladder)) { $keep = $true }
        if (-not $keep) { continue }
        $source = Get-NSRecordText $record 'source'
        if ($source.Length -eq 0) { $source = Get-NSRecordText $record 'sourceClass' }
        if ($source.Length -gt 0) { $sources.Add($source) }
    }
    return (Get-NSUniqueSorted ([string[]]$sources.ToArray()))
}

# The last state the ledger recorded for each id, lifecycle records excluded.
function Get-NSReceiptFindingMap {
    param($Records)
    $map = New-NSOrdinalMap
    foreach ($record in @($Records)) {
        if ($script:NSEvidenceLifecycleDomains -ccontains (Get-NSRecordText $record 'domain')) { continue }
        $id = Get-NSRecordText $record 'id'
        if ($id.Length -eq 0) { continue }
        $map[$id] = $record
    }
    return $map
}

function Get-NSReceiptOpenItems {
    param([Parameter(Mandatory = $true)][string]$PunchList)
    $items = New-Object Collections.Generic.List[string]
    if (-not (Test-Path -LiteralPath $PunchList -PathType Leaf)) { return , $items.ToArray() }
    $inItems = $false
    try {
        foreach ($line in [IO.File]::ReadLines($PunchList)) {
            $text = [string]$line
            if (-not $inItems) {
                if ($text -cmatch '^##\s+Items\s*$') { $inItems = $true }
                continue
            }
            $match = [regex]::Match($text, '^-\s*\[\s\]\s*(.*)$')
            if (-not $match.Success) { continue }
            $body = $match.Groups[1].Value.Trim()
            if ($body.Length -gt 0) { $items.Add($body) }
        }
    }
    catch {
        return , $items.ToArray()
    }
    return , $items.ToArray()
}

# Entries below the parking lot's rule, each as the owner wrote it, with the
# default and the rollback kept as their own lines when the entry carries them.
function Get-NSReceiptParkedEntries {
    param([Parameter(Mandatory = $true)][string]$ParkingLot)
    $entries = New-Object Collections.Generic.List[object]
    if (-not (Test-Path -LiteralPath $ParkingLot -PathType Leaf)) { return , $entries.ToArray() }
    $afterRule = $false
    $entry = $null
    try {
        foreach ($line in [IO.File]::ReadLines($ParkingLot)) {
            $text = [string]$line
            if (-not $afterRule) {
                if ($text -cmatch '^---\s*$') { $afterRule = $true }
                continue
            }
            $head = [regex]::Match($text, '^(?:-\s+|###\s+)(.*)$')
            if ($head.Success) {
                $title = $head.Groups[1].Value.Trim()
                if ($title.Length -eq 0 -or $title -ceq '(empty)') {
                    $entry = $null
                    continue
                }
                $entry = New-NSOrdinalMap
                $entry['title'] = $title
                $entry['default'] = ''
                $entry['rollback'] = ''
                $entries.Add($entry)
                continue
            }
            if ($null -eq $entry) { continue }
            $field = [regex]::Match($text, '^\s*(?:-\s+)?(Default|Rollback):\s*(.*)$')
            if (-not $field.Success) { continue }
            $value = $field.Groups[2].Value.Trim()
            if ($field.Groups[1].Value -ceq 'Default') { $entry['default'] = $value }
            else { $entry['rollback'] = $value }
        }
    }
    catch {
        return , $entries.ToArray()
    }
    return , $entries.ToArray()
}

# The one building entry from the opportunity map, with the exact next action it
# carries. Nothing is inferred: no Next line, no line in the receipt.
function Get-NSReceiptBuilding {
    param([Parameter(Mandatory = $true)][string]$OpportunityMap)
    $result = New-NSOrdinalMap
    $result['title'] = ''
    $result['next'] = ''
    if (-not (Test-Path -LiteralPath $OpportunityMap -PathType Leaf)) { return $result }
    $title = ''
    $building = $false
    try {
        foreach ($line in [IO.File]::ReadLines($OpportunityMap)) {
            $text = [string]$line
            $head = [regex]::Match($text, '^###\s+(.*)$')
            if ($head.Success) {
                if ($building -and $result['title'].Length -gt 0) { break }
                $title = $head.Groups[1].Value.Trim()
                $building = $false
                continue
            }
            if ($text -cmatch '^Status:\s*building\s*$') {
                $building = $true
                if ($result['title'].Length -eq 0) { $result['title'] = $title }
                continue
            }
            if (-not $building) { continue }
            $next = [regex]::Match($text, '^Next:\s*(.*)$')
            if ($next.Success -and $result['next'].Length -eq 0) {
                $result['next'] = $next.Groups[1].Value.Trim()
            }
        }
    }
    catch {
        return $result
    }
    return $result
}

function Get-NSReceiptContext {
    param(
        [Parameter(Mandatory = $true)][string]$Workspace,
        [Parameter(Mandatory = $true)][string]$View
    )
    $workspacePath = Get-NSAbsolutePath $Workspace
    $paths = Get-NSPolicyPaths $workspacePath
    $ns = [string]$paths['ns']
    $context = New-NSOrdinalMap
    $context['view'] = $View
    $context['workspace'] = $workspacePath
    $context['ns'] = $ns
    $context['punch'] = [string]$paths['punch']
    $context['parking'] = [string]$paths['parking']

    $records = New-Object Collections.Generic.List[object]
    try {
        $records = Get-NSEvidenceLedgerRecords $workspacePath
    }
    catch {
        $records = New-Object Collections.Generic.List[object]
    }
    $context['records'] = $records
    $context['findings'] = Get-NSReceiptFindingMap $records
    $context['baselines'] = Get-NSCompareBaselineRecords $records

    $policy = $null
    try {
        $policy = Get-NSShiftPolicy $workspacePath
    }
    catch {
        $policy = $null
    }
    $context['policy'] = $policy

    $mode = 'repository'
    try {
        $mode = Get-NSWorkMode $workspacePath
    }
    catch {
        $mode = 'repository'
    }
    $context['workMode'] = $mode
    $context['workTarget'] = Get-NSEvidenceWorkTarget $workspacePath

    $shiftId = ''
    $started = ''
    if ($null -ne $policy) {
        $shiftId = Get-NSRecordText $policy 'shiftId'
        $started = Get-NSRecordText $policy 'createdAt'
    }
    $context['shiftId'] = $shiftId
    $context['started'] = $started

    $counts = Get-NSBoxCounts $context['punch']
    $context['ticked'] = [int]$counts.Ticked
    $context['open'] = [int]$counts.Open
    $context['punchReadable'] = [bool]$counts.Readable
    $context['ending'] = Get-NSReceiptEnding -NightshiftDir $ns -Open ([int]$counts.Open) -Readable ([bool]$counts.Readable)

    $ended = Get-NSReceiptLogEnd (Join-NSPath $ns 'shift-log.md')
    $context['ended'] = $ended

    $sessionHost = ''
    $session = $null
    try {
        $session = Read-NSSession $ns
    }
    catch {
        $session = $null
    }
    if ($null -ne $session) { $sessionHost = [string]$session.HostName }
    if ($sessionHost.Length -eq 0) {
        foreach ($record in @($records)) {
            $candidate = Get-NSRecordText $record 'host'
            if ($candidate.Length -gt 0) { $sessionHost = $candidate }
        }
    }
    $context['host'] = $sessionHost

    $resolution = $null
    try {
        $resolution = Get-NSPolicyResolution $workspacePath
    }
    catch {
        $resolution = $null
    }
    $verificationLevel = 'none'
    $verificationSource = 'built-in'
    $toolingPolicy = 'existing-tools'
    if ($null -ne $resolution) {
        $verificationLevel = [string]$resolution['settings']['verificationLevel']['value']
        $verificationSource = [string]$resolution['settings']['verificationLevel']['source']
        $toolingPolicy = [string]$resolution['settings']['toolingPolicy']['value']
    }
    $context['verificationLevel'] = $verificationLevel
    $context['verificationSource'] = $verificationSource
    $context['toolingPolicy'] = $toolingPolicy

    $profile = ''
    try {
        $defaults = Get-NSShiftDefaults $workspacePath
        $profile = [string]$defaults['verificationProfile']
    }
    catch {
        $profile = ''
    }
    $context['profile'] = $profile

    $allowances = New-Object Collections.Generic.List[string]
  if ($null -ne $policy) {
        $rawAllowances = Get-NSMapValue $policy 'allowances'
        if ($null -ne $rawAllowances) {
            foreach ($allowance in @($rawAllowances)) {
                if (-not ($allowance -is [Collections.IDictionary])) { continue }
                $category = Get-NSRecordText $allowance 'category'
                $scope = Get-NSRecordText $allowance 'scope'
                $provenance = Get-NSRecordText $allowance 'provenance'
                if ($category.Length -eq 0 -and $scope.Length -eq 0 -and $provenance.Length -eq 0) { continue }
                $allowances.Add(($script:NSReceiptAllowanceFormat -f $category, $scope, $provenance))
            }
        }
    }
    $context['allowances'] = Get-NSUniqueSorted ([string[]]$allowances.ToArray())

    $context['gates'] = Get-NSReceiptGateCommands $context['punch']
    $context['verified'] = Get-NSReceiptRecordSources $records $null $script:NSReceiptVerifiedLadder
    $context['unavailable'] = Get-NSReceiptRecordSources $records $script:NSCompareUnavailableStatuses ''
    $context['mode'] = Get-NSPolicyCompletionModeFrom $policy
    $context['selectedDebt'] = Get-NSPolicySelectedDebt $workspacePath
    return $context
}

function Add-NSReceiptField {
    param(
        [Parameter(Mandatory = $true)]$Lines,
        [Parameter(Mandatory = $true)][string]$Key,
        [AllowEmptyString()][string]$Value
    )
    if ([string]::IsNullOrEmpty($Value)) { return }
    $Lines.Add(($script:NSReceiptFieldFormat -f ([string]$script:NSReceiptLabels[$Key]), $Value))
}

# Section 1. The three closing lines always appear: what ran green by command,
# what the level skipped, and what could not be measured. A disabled check is
# never rendered as a check that passed.
function Get-NSReceiptShiftLines {
    param($Context)
    $lines = New-Object Collections.Generic.List[string]
    Add-NSReceiptField $lines 'shift' ([string]$Context['shiftId'])
    Add-NSReceiptField $lines 'host' ([string]$Context['host'])
    Add-NSReceiptField $lines 'workTarget' ([string]$Context['workTarget'])
    Add-NSReceiptField $lines 'started' ([string]$Context['started'])
    Add-NSReceiptField $lines 'ended' ([string]$Context['ended'])
    Add-NSReceiptField $lines 'ending' ([string]$Context['ending'])
    if ($Context.Contains('punchReadable') -and -not [bool]$Context['punchReadable']) {
        Add-NSReceiptField $lines 'items' 'unknown'
    }
    else {
        Add-NSReceiptField $lines 'items' ($script:NSReceiptItemsFormat -f ([int]$Context['ticked']), ([int]$Context['open']))
    }
    $artifactView = ([string]$Context['view']) -ceq 'artifact'
    if ($artifactView -or (([string]$Context['workMode']) -ceq 'artifact')) {
        Add-NSReceiptField $lines 'receipts' ([string](Get-NSReceiptsCount ([string]$Context['workspace'])))
    }
    else {
        Add-NSReceiptField $lines 'commits' (Get-NSReceiptCommitCount -Target ([string]$Context['workTarget']) -Since ([string]$Context['started']))
    }
    $profile = [string]$Context['profile']
    if ($profile.Length -eq 0) { $profile = $script:NSReceiptNone }
    Add-NSReceiptField $lines 'policy' ($script:NSReceiptPolicyFormat -f $profile, ([string]$Context['verificationLevel']), ([string]$Context['toolingPolicy']))
    foreach ($allowance in @($Context['allowances'])) {
        Add-NSReceiptField $lines 'allowance' ([string]$allowance)
    }

    $gates = @($Context['gates'])
    $chosen = ([string]$Context['verificationSource']) -ceq $script:NSReceiptChosenSource
    # A shift that wrote no policy runs on the built-in floor, and the punch list's own Gates
    # section is what it was told to run. Naming those commands as the shift's gate keeps the
    # receipt from crediting the owner with a decision they never made.
    if (-not $chosen -and $gates.Count -gt 0) {
        Add-NSReceiptField $lines 'gates' ($script:NSReceiptGatesFormat -f ($gates -join $script:NSMdSourceSeparator))
    }

    $verified = @($Context['verified'])
    if ($verified.Count -gt 0) {
        Add-NSReceiptField $lines 'verified' (($verified -join $script:NSMdSourceSeparator))
    }
    elseif ($chosen) {
        Add-NSReceiptField $lines 'verified' ($script:NSReceiptVerifiedNoneFormat -f (Get-NSEvidenceDash), ([string]$Context['verificationLevel']))
    }
    else {
        Add-NSReceiptField $lines 'verified' ($script:NSReceiptVerifiedNoPolicyFormat -f (Get-NSEvidenceDash))
    }

    $disabled = @()
    if ($chosen -and (([string]$Context['verificationLevel']) -ceq 'none')) { $disabled = $gates }
    if ($disabled.Count -gt 0) {
        Add-NSReceiptField $lines 'disabled' (($disabled -join $script:NSMdSourceSeparator))
    }
    else {
        Add-NSReceiptField $lines 'disabled' $script:NSReceiptNone
    }

    $unavailable = @($Context['unavailable'])
    if ($unavailable.Count -gt 0) {
        Add-NSReceiptField $lines 'unavailable' (($unavailable -join $script:NSMdSourceSeparator))
    }
    else {
        Add-NSReceiptField $lines 'unavailable' $script:NSReceiptNone
    }
    return , $lines.ToArray()
}

# Section 2. One line per baseline: its source class, the exact command, and the
# two digests the comparison is measured against.
function Get-NSReceiptBaselineLines {
    param($Context)
    $lines = New-Object Collections.Generic.List[string]
    $byId = New-NSOrdinalMap
    foreach ($record in @($Context['baselines'])) {
        $id = Get-NSRecordText $record 'id'
        if ($id.Length -eq 0) { continue }
        $byId[$id] = $record
    }
    foreach ($id in (Sort-NSOrdinal ([string[]]@($byId.Keys)))) {
        $record = $byId[$id]
        $details = Get-NSRecordDetails $record
        $environment = Get-NSCompareShortDigest (Get-NSRecordText $details 'environmentDigest')
        if ($environment.Length -eq 0) { $environment = $script:NSReceiptNone }
        $raw = Get-NSCompareShortDigest (Get-NSRecordText $details 'rawDigest')
        if ($raw.Length -eq 0) { $raw = $script:NSReceiptNone }
        $scope = Get-NSRecordText $details 'scope'
        if ($scope.Length -eq 0) { $scope = Get-NSRecordText $record 'scope' }
        if ($scope.Length -eq 0) { $scope = $script:NSReceiptNone }
        $body = $script:NSReceiptBaselineFormat -f (Get-NSCompareBaselineSourceClass $record), `
        (Get-NSRecordText $details 'command'), (Get-NSEvidenceDash), $environment, $raw, $scope
        $lines.Add(($script:NSReceiptFieldFormat -f ([string]$id), $body))
    }
    return , $lines.ToArray()
}

# Section 3. Every baseline's rows in one table, then one line per fix: the
# record, the commit or receipt it landed as, its verification locator, and the
# post-measurement digest from the same source.
function Get-NSReceiptChangedLines {
    param($Context)
    $lines = New-Object Collections.Generic.List[string]
    $rows = New-NSOrdinalMap
    $outstanding = New-Object Collections.Generic.List[string]
    foreach ($record in @($Context['baselines'])) {
        $id = Get-NSRecordText $record 'id'
        if ($id.Length -eq 0) { continue }
        $comparison = $null
        try {
            $comparison = Get-NSEvidenceComparison -Workspace ([string]$Context['workspace']) -Baseline $id `
                -Records $Context['records'] -Mode ([string]$Context['mode']) -SelectedDebt $Context['selectedDebt']
        }
        catch {
            $comparison = $null
        }
        if ($null -eq $comparison) { continue }
        $document = $comparison['document']
        foreach ($row in @($document['rows'])) {
            $rowId = [string]$row['id']
            if (-not $rows.Contains($rowId)) { $rows[$rowId] = $row }
        }
        foreach ($debt in @($document['summary']['selectedDebtOutstanding'])) { $outstanding.Add([string]$debt) }
    }
    $ordered = New-Object Collections.Generic.List[object]
    $release = ([string]$Context['view']) -ceq 'release'
    foreach ($rowId in (Sort-NSOrdinal ([string[]]@($rows.Keys)))) {
        $row = $rows[$rowId]
        if ($release -and -not ($script:NSCompareRegressionClasses -ccontains ([string]$row['class']))) { continue }
        $ordered.Add($row)
    }
    if ($ordered.Count -eq 0 -and @($Context['baselines']).Count -eq 0) { return , @() }
    foreach ($line in (Get-NSCompareTableLines $ordered.ToArray())) { $lines.Add($line) }
    $lines.Add('')
    foreach ($line in (Get-NSCompareSummaryLines (Get-NSCompareCounts $ordered.ToArray()) (Get-NSUniqueSorted ([string[]]$outstanding.ToArray())))) {
        $lines.Add($line)
    }

    $fixes = New-Object Collections.Generic.List[string]
    $findings = $Context['findings']
    $joiner = Get-NSEvidenceJoiner
    foreach ($id in (Sort-NSOrdinal ([string[]]@($findings.Keys)))) {
        $record = $findings[$id]
        if (-not ($script:NSCompareClearedStatuses -ccontains (Get-NSRecordText $record 'status'))) { continue }
        $fix = Get-NSRecordText $record 'fix'
        if ($fix.Length -eq 0) { $fix = $script:NSReceiptNone }
        $locator = Get-NSRecordText $record 'verificationLocator'
        if ($locator.Length -eq 0) { $locator = Get-NSRecordText $record 'locator' }
        if ($locator.Length -eq 0) { $locator = $script:NSReceiptNone }
        $digest = Get-NSCompareShortDigest (Get-NSRecordText $record 'digest')
        if ($digest.Length -eq 0) { $digest = $script:NSReceiptNone }
        $body = @($fix, $locator, $digest) -join $joiner
        $fixes.Add(($script:NSReceiptFieldFormat -f ([string]$id), $body))
    }
    if ($fixes.Count -gt 0) {
        $lines.Add('')
        foreach ($fix in $fixes) { $lines.Add($fix) }
    }
    return , $lines.ToArray()
}

# Section 4.
function Get-NSReceiptParkedLines {
    param($Context)
    $lines = New-Object Collections.Generic.List[string]
    foreach ($entry in (Get-NSReceiptParkedEntries ([string]$Context['parking']))) {
        $lines.Add(($script:NSReceiptPlainFormat -f ([string]$entry['title'])))
        $default = [string]$entry['default']
        if ($default.Length -gt 0) {
            $lines.Add(($script:NSReceiptNestedFormat -f ([string]$script:NSReceiptLabels['default']), $default))
        }
        $rollback = [string]$entry['rollback']
        if ($rollback.Length -gt 0) {
            $lines.Add(($script:NSReceiptNestedFormat -f ([string]$script:NSReceiptLabels['rollback']), $rollback))
        }
    }
    return , $lines.ToArray()
}

# Section 5.
function Get-NSReceiptUnsupportedLines {
    param($Context)
    $lines = New-Object Collections.Generic.List[string]
    $findings = $Context['findings']
    $joiner = Get-NSEvidenceJoiner
    foreach ($id in (Sort-NSOrdinal ([string[]]@($findings.Keys)))) {
        $record = $findings[$id]
        $status = Get-NSRecordText $record 'status'
        if (-not ($script:NSReceiptUnmeasuredStatuses -ccontains $status)) { continue }
        $locator = Get-NSRecordText $record 'locator'
        if ($locator.Length -eq 0) { $locator = $script:NSReceiptNone }
        $lines.Add(($script:NSReceiptFieldFormat -f ([string]$id), (@($status, $locator) -join $joiner)))
    }
    return , $lines.ToArray()
}

# Section 6.
function Get-NSReceiptNextLines {
    param($Context)
    $lines = New-Object Collections.Generic.List[string]
    foreach ($item in (Get-NSReceiptOpenItems ([string]$Context['punch']))) {
        $lines.Add(($script:NSReceiptPlainFormat -f ([string]$item)))
    }
    $building = Get-NSReceiptBuilding (Join-NSPath ([string]$Context['ns']) 'opportunity-map.md')
    $title = [string]$building['title']
    $next = [string]$building['next']
    if ($title.Length -gt 0 -and $next.Length -gt 0) {
        $body = $script:NSReceiptNextFormat -f $title, (Get-NSEvidenceDash), $next
        $lines.Add(($script:NSReceiptFieldFormat -f ([string]$script:NSReceiptLabels['building']), $body))
    }
    return , $lines.ToArray()
}

function Get-NSReceiptSectionLines {
    param([Parameter(Mandatory = $true)][string]$Key, $Context)
    switch ($Key) {
        'shift' { return (Get-NSReceiptShiftLines $Context) }
        'baseline' { return (Get-NSReceiptBaselineLines $Context) }
        'changed' { return (Get-NSReceiptChangedLines $Context) }
        'parked' { return (Get-NSReceiptParkedLines $Context) }
        'unsupported' { return (Get-NSReceiptUnsupportedLines $Context) }
        'next' { return (Get-NSReceiptNextLines $Context) }
    }
    return , @()
}

# Markdown from records only. It invents nothing, never upgrades a claim into
# proof, and omits a section it has no record for.
function Get-NSMorningReceipt {
    param(
        [Parameter(Mandatory = $true)][string]$Workspace,
        [ValidateSet('owner', 'reviewer', 'release', 'artifact')][string]$View = 'owner',
        [AllowEmptyString()][string]$Out = ''
    )
    $context = Get-NSReceiptContext -Workspace $Workspace -View $View
    $lines = New-Object Collections.Generic.List[string]
    $lines.Add($script:NSReceiptTitle)
    foreach ($key in @($script:NSReceiptViewSections[$View])) {
        $body = Get-NSReceiptSectionLines -Key ([string]$key) -Context $context
        if ($null -eq $body -or @($body).Count -eq 0) { continue }
        $lines.Add('')
        $lines.Add([string]$script:NSReceiptSectionTitle[[string]$key])
        $lines.Add('')
        foreach ($line in @($body)) { $lines.Add([string]$line) }
    }
    $text = ($lines -join "`n") + "`n"
    if (-not [string]::IsNullOrEmpty($Out)) {
        $directory = Split-Path -Parent $Out
        if (-not [string]::IsNullOrEmpty($directory)) { $null = [IO.Directory]::CreateDirectory($directory) }
        if (Test-NSReparsePoint $Out) { Remove-Item -LiteralPath $Out -Force -ErrorAction SilentlyContinue }
        Write-NSEvidenceFileAtomic -Path $Out -Text $text
    }
    return $text
}

# ---------------------------------------------------------------------------
# Command surfaces for the thin runtime scripts
# ---------------------------------------------------------------------------

function Write-NSEvidenceCompareUsage {
    Write-NSEvidenceError 'usage: evidence-compare.ps1 -Project DIR -Baseline ID [-Json|-Md]'
    return 1
}

# 0 the report renders and the mode is satisfied - 1 usage - 2 contract failure
# - 3 the report renders and the mode is not satisfied.
function Invoke-NSEvidenceCompareCommand {
    param(
        [AllowEmptyString()][string]$Project = '',
        [AllowEmptyString()][string]$Baseline = '',
        [switch]$Json,
        [switch]$Md
    )
    if ([string]::IsNullOrEmpty($Project) -or [string]::IsNullOrEmpty($Baseline)) { return (Write-NSEvidenceCompareUsage) }
    if ($Json -and $Md) { return (Write-NSEvidenceCompareUsage) }
    try {
        $comparison = Get-NSEvidenceComparison -Workspace $Project -Baseline $Baseline
        if ($Json) {
            [Console]::Out.Write((ConvertTo-NSCanonicalJson $comparison['document'] -Compact))
            [Console]::Out.Write("`n")
        }
        else {
            [Console]::Out.Write((Get-NSCompareMarkdown $comparison))
        }
        if ([bool]$comparison['document']['pass']) { return 0 }
        return 3
    }
    catch [ApplicationException] {
        Write-NSEvidenceError $_.Exception.Message
        return 2
    }
}

function Write-NSMorningReceiptUsage {
    Write-NSEvidenceError 'usage: morning-receipt.ps1 -Project DIR [-View owner|reviewer|release|artifact] [-Out PATH]'
    return 1
}

function Invoke-NSMorningReceiptCommand {
    param(
        [AllowEmptyString()][string]$Project = '',
        [AllowEmptyString()][string]$View = '',
        [AllowEmptyString()][string]$Out = ''
    )
    if ([string]::IsNullOrEmpty($Project)) { return (Write-NSMorningReceiptUsage) }
    $view = $View
    if ([string]::IsNullOrEmpty($view)) { $view = 'owner' }
    if (-not ($script:NSReceiptViewNames -ccontains $view)) { return (Write-NSMorningReceiptUsage) }
    try {
        $text = Get-NSMorningReceipt -Workspace $Project -View $view -Out $Out
        if ([string]::IsNullOrEmpty($Out)) {
            [Console]::Out.Write($text)
            return 0
        }
        Write-NSEvidenceOut (Get-NSAbsolutePath $Out)
        return 0
    }
    catch [ApplicationException] {
        Write-NSEvidenceError $_.Exception.Message
        return 2
    }
}


Export-ModuleMember -Function *
