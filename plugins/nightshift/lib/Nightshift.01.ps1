
# The state-version this plugin writes, which names the layout its files sit in. Version 1 and
# legacy workspaces stay operable in the paths they have; only migrate-state moves them.
$script:NSStateVersion = 2
$script:NSUtf8NoBom = New-Object System.Text.UTF8Encoding($false)
# The separator the records and receipts share with the POSIX runtime, spelled by its code so this
# file stays ASCII: Windows PowerShell 5.1 reads a script saved without a BOM as ANSI.
$script:NSDot = [string][char]0x00B7
$script:NSUsageTokensFormat = "input {0} $script:NSDot cache_write {1} $script:NSDot cache_read {2} $script:NSDot output {3} $script:NSDot reasoning {4}"
$script:NSRulesCacheStamp = ''
$script:NSRulesCache = $null

# Get-NSLocalTime <epoch> [-Seconds] - the moment as the person at this machine reads it: local
# date and time with the machine's own UTC offset, `2026-10-08 07:12 (UTC+04:00)`; with -Seconds, to
# the second. '' for an unreadable epoch. Mirrors ns_local_time.
function Get-NSLocalTime {
    param([AllowEmptyString()][string]$Epoch, [switch]$Seconds)
    $e = 0L
    if ([string]::IsNullOrEmpty($Epoch) -or $Epoch -cnotmatch '^[0-9]+$' -or -not [long]::TryParse($Epoch, [ref]$e)) { return '' }
    $at = [DateTimeOffset]::FromUnixTimeSeconds($e).ToLocalTime()
    $fmt = $(if ($Seconds) { 'yyyy-MM-dd HH:mm:ss' } else { 'yyyy-MM-dd HH:mm' })
    $offset = $at.Offset
    $sign = $(if ($offset -lt [TimeSpan]::Zero) { '-' } else { '+' })
    $offset = $offset.Duration()
    return ('{0} (UTC{1}{2:00}:{3:00})' -f $at.ToString($fmt, [Globalization.CultureInfo]::InvariantCulture),
        $sign, $offset.Hours, $offset.Minutes)
}

# Get-NSLocalNow [-Seconds] - now, as Get-NSLocalTime writes it.
function Get-NSLocalNow {
    param([switch]$Seconds)
    return (Get-NSLocalTime ([string][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) -Seconds:$Seconds)
}

function Test-NSWindows {
    return [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
}

# State layout. Every path under .nightshift/ comes from state-layout.tsv beside this module, read
# once at import: a key resolves to the path its workspace's layout gives it. Layout 2 is the one
# this plugin writes; a version-1 or legacy workspace keeps the paths it has, so an upgraded plugin
# goes on guarding it, a shift armed before the upgrade included. Mirrors lib/layout.sh.
$script:NSLayoutVersion = $script:NSStateVersion
$script:NSLayoutRows = New-Object 'System.Collections.Generic.List[object]'
$script:NSLayoutPaths = @{}

# Get-NSCurrentStateVersion - the state-version this plugin writes.
function Get-NSCurrentStateVersion {
    return $script:NSStateVersion
}

function Import-NSLayoutTable {
    param([Parameter(Mandatory = $true)][string]$Path)
    for ($v = 0; $v -le $script:NSLayoutVersion; $v++) {
        $script:NSLayoutPaths[$v] = @{}
    }
    foreach ($line in [IO.File]::ReadAllLines($Path)) {
        if ($line.Length -eq 0 -or $line.StartsWith('#')) { continue }
        $fields = $line.Split("`t")
        if ($fields.Count -ne 4) { throw "state-layout.tsv: malformed row: $line" }
        $row = [pscustomobject]@{
            Key = $fields[0]
            Since = [int]$fields[1]
            Path = $fields[2]
            Kind = $fields[3]
        }
        $script:NSLayoutRows.Add($row)
        if ($row.Kind -ceq 'field' -or $row.Kind -ceq 'retired' -or $row.Kind -ceq 'stray') { continue }
        for ($v = $row.Since; $v -le $script:NSLayoutVersion; $v++) {
            $script:NSLayoutPaths[$v][$row.Key] = $row.Path
        }
    }
}

# Get-NSLayoutRelativePathAt <version> <key> - the path <key> had in layout <version>, for code
# that must still find a file an older layout left behind. Empty when that layout had no such key.
function Get-NSLayoutRelativePathAt {
    param(
        [Parameter(Mandatory = $true)][int]$Version,
        [Parameter(Mandatory = $true)][string]$Key
    )
    if (-not $script:NSLayoutPaths.ContainsKey($Version)) { return '' }
    $paths = $script:NSLayoutPaths[$Version]
    if (-not $paths.ContainsKey($Key)) { return '' }
    return [string]$paths[$Key]
}

# Get-NSLayoutVersion <state-dir> - the layout this state directory uses: its state-version when
# that is a layout this plugin knows, 1 for version 1, legacy and a marker that cannot be read. A
# newer marker reads as the newest layout; the state-version check refuses it.
function Get-NSLayoutVersion {
    param([Parameter(Mandatory = $true)][string]$NightshiftDir)
    # The marker every layout keeps at the top: read directly, since it decides the layout.
    $marker = [IO.Path]::Combine($NightshiftDir, 'state-version')
    $raw = ''
    try {
        if ([IO.File]::Exists($marker) -and
            -not (([IO.File]::GetAttributes($marker) -band [IO.FileAttributes]::ReparsePoint))) {
            $lines = [IO.File]::ReadAllLines($marker)
            if ($lines.Count -gt 0) { $raw = [string]$lines[0] }
        }
    }
    catch {
        $raw = ''
    }
    $raw = $raw.TrimEnd("`r")
    if ($raw -cnotmatch '^(0|[1-9][0-9]{0,7})$') { return 1 }
    $version = [int]$raw
    if ($version -lt 1) { return 1 }
    if ($version -gt $script:NSLayoutVersion) { return $script:NSLayoutVersion }
    return $version
}

# Get-NSLayoutRelativePath <state-dir> <key> [instance] - the path of <key> relative to the state
# directory, with / separators, in that directory's layout; <instance> fills the * of a family such
# as usage-*. Empty for a key this layout does not have.
function Get-NSLayoutRelativePath {
    param(
        [Parameter(Mandatory = $true)][string]$NightshiftDir,
        [Parameter(Mandatory = $true)][string]$Key,
        [AllowEmptyString()][string]$Instance = ''
    )
    $paths = $script:NSLayoutPaths[(Get-NSLayoutVersion $NightshiftDir)]
    if (-not $paths.ContainsKey($Key)) { return '' }
    $rel = [string]$paths[$Key]
    $star = $rel.IndexOf('*')
    if ($star -ge 0) { $rel = $rel.Substring(0, $star) + $Instance + $rel.Substring($star + 1) }
    return $rel
}

# Get-NSLayoutPath <state-dir> <key> [instance] - the absolute path of <key>, with native
# separators. Throws for a key this layout does not have.
function Get-NSLayoutPath {
    param(
        [Parameter(Mandatory = $true)][string]$NightshiftDir,
        [Parameter(Mandatory = $true)][string]$Key,
        [AllowEmptyString()][string]$Instance = ''
    )
    $rel = Get-NSLayoutRelativePath $NightshiftDir $Key $Instance
    if ($rel.Length -eq 0) { throw "state layout $(Get-NSLayoutVersion $NightshiftDir) has no $Key" }
    return (Join-NSPath $NightshiftDir ($rel.Replace('/', [IO.Path]::DirectorySeparatorChar)))
}

# Test-NSLayoutKey <state-dir> <key> - whether this directory's layout has <key>.
function Test-NSLayoutKey {
    param(
        [Parameter(Mandatory = $true)][string]$NightshiftDir,
        [Parameter(Mandatory = $true)][string]$Key
    )
    return $script:NSLayoutPaths[(Get-NSLayoutVersion $NightshiftDir)].ContainsKey($Key)
}

# Get-NSLayoutName <state-dir> <key> - a state file as a message names it, `.nightshift/<path>` in
# that directory's layout.
function Get-NSLayoutName {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$NightshiftDir,
        [Parameter(Mandatory = $true)][string]$Key
    )
    $rel = ''
    if (-not [string]::IsNullOrEmpty($NightshiftDir)) { $rel = Get-NSLayoutRelativePath $NightshiftDir $Key }
    if ($rel.Length -eq 0) { $rel = $Key }
    return ('.nightshift/' + $rel)
}

# ConvertTo-NSNormalPath <path> - the path with its `.` and `..` segments resolved as text, with /
# separators, the way a relative link is read. A `..` above the start is kept.
function ConvertTo-NSNormalPath {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Path)
    $lead = ''
    if ($Path.StartsWith('/')) { $lead = '/' }
    $out = New-Object Collections.Generic.List[string]
    foreach ($segment in $Path.Split([char[]]@('/', '\'))) {
        if ($segment.Length -eq 0 -or $segment -ceq '.') { continue }
        if ($segment -ceq '..' -and $out.Count -gt 0 -and $out[$out.Count - 1] -cne '..') {
            $out.RemoveAt($out.Count - 1)
            continue
        }
        $out.Add($segment)
    }
    return ($lead + ($out -join '/'))
}

# ConvertTo-NSRelativeLink <from-dir> <to-path> - <to-path> relative to <from-dir>, with /
# separators. Both are absolute and spelled alike up to where they part, as two paths built from one
# state directory are.
function ConvertTo-NSRelativeLink {
    param(
        [Parameter(Mandatory = $true)][string]$From,
        [Parameter(Mandatory = $true)][string]$To
    )
    $fromParts = @((ConvertTo-NSNormalPath $From).Split('/') | Where-Object { $_.Length -gt 0 })
    $toParts = @((ConvertTo-NSNormalPath $To).Split('/') | Where-Object { $_.Length -gt 0 })
    $common = 0
    while ($common -lt $fromParts.Count -and $common -lt $toParts.Count -and $fromParts[$common] -ceq $toParts[$common]) { $common++ }
    $parts = New-Object Collections.Generic.List[string]
    for ($j = $common; $j -lt $fromParts.Count; $j++) { $parts.Add('..') }
    for ($j = $common; $j -lt $toParts.Count; $j++) { $parts.Add($toParts[$j]) }
    return ($parts -join '/')
}

# New-NSLayoutParent <state-dir> <key> - create the directory <key> lives in, for a writer that may
# be the first to use it.
function New-NSLayoutParent {
    param(
        [Parameter(Mandatory = $true)][string]$NightshiftDir,
        [Parameter(Mandatory = $true)][string]$Key
    )
    $parent = Split-Path -Parent (Get-NSLayoutPath $NightshiftDir $Key)
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        $null = New-Item -ItemType Directory -Path $parent -Force
    }
}

# Initialize-NSStateDir <workspace> - create <workspace>/.nightshift/ when it does not exist yet. A
# state directory is born in the current layout, so a new one gets its state-version before any
# file lands in it; an existing one is left exactly as it is.
function Initialize-NSStateDir {
    param([Parameter(Mandatory = $true)][string]$Workspace)
    $ns = Join-Path $Workspace '.nightshift'
    if (Test-Path -LiteralPath $ns -PathType Container) { return }
    $null = New-Item -ItemType Directory -Path $ns -Force
    $null = Write-NSAtomicLines -Path ([IO.Path]::Combine($ns, 'state-version')) -Lines @([string]$script:NSLayoutVersion)
}

Import-NSLayoutTable (Join-Path $PSScriptRoot 'state-layout.tsv')

# Hosts fire every registered hook on every event. An install with no armed
# shift must not read stdin. Revival workers stay in so they can refuse to
# continue after clock-out. A .nightshift-link is resolved after this returns.
function Test-NSHookIdle {
    if ($env:NIGHTSHIFT_REVIVAL -eq '1') {
        return $false
    }
    $hostDir = $env:CURSOR_PROJECT_DIR
    if ([string]::IsNullOrEmpty($hostDir)) { $hostDir = $env:CLAUDE_PROJECT_DIR }
    if ([string]::IsNullOrEmpty($hostDir)) { $hostDir = $env:CODEX_PROJECT_DIR }
    if ([string]::IsNullOrEmpty($hostDir)) {
        return $false
    }
    $link = Join-Path $hostDir '.nightshift-link'
    if (Test-Path -LiteralPath $link) {
        return $false
    }
    $ns = Join-Path $hostDir '.nightshift'
    $armed = Get-NSLayoutPath $ns 'armed'
    $ended = Get-NSLayoutPath $ns 'ended'
    if (-not (Test-Path -LiteralPath $armed -PathType Leaf)) {
        return $true
    }
    if (-not (Test-Path -LiteralPath $ended -PathType Leaf)) {
        return $false
    }
    try {
        $item = Get-Item -LiteralPath $ended -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            return $false
        }
    }
    catch {
        return $true
    }
    return $true
}

# Windows PowerShell 5.1's [Console]::In is the console host, not redirected
# stdin. With -File the host often parks the pipe on $input instead. Read both.
function Get-NSStdinText {
    param(
        [AllowEmptyString()][string]$Piped = '',
        [int]$TimeoutSeconds = 2
    )
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
                # ReadToEnd waits for EOF. A host that keeps the pipe open and trickles
                # bytes never reaches it, so the wait is a wall-clock deadline instead.
                if ($TimeoutSeconds -lt 0) { $TimeoutSeconds = 0 }
                $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
                $chunks = New-Object Text.StringBuilder
                $buf = New-Object byte[] 8192
                while ([DateTime]::UtcNow -lt $deadline) {
                    $left = [int][Math]::Ceiling(($deadline - [DateTime]::UtcNow).TotalMilliseconds)
                    if ($left -le 0) { break }
                    $ar = $stream.BeginRead($buf, 0, $buf.Length, $null, $null)
                    if (-not $ar.AsyncWaitHandle.WaitOne($left)) { break }
                    $n = $stream.EndRead($ar)
                    if ($n -le 0) { break }
                    [void]$chunks.Append($utf8.GetString($buf, 0, $n))
                }
                $text = $chunks.ToString()
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
    $record = Get-NSLayoutPath (Join-Path $Workspace '.nightshift') 'work-mode'
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
    Initialize-NSStateDir $Workspace
    New-NSLayoutParent $ns 'work-mode'
    $null = Write-NSAtomicLines -Path (Get-NSLayoutPath $ns 'work-mode') -Lines @($Mode)
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

# Get-NSStateDirOwner <dir> - the folder a working directory stands for. A directory inside a
# `.nightshift/` state folder is that folder's owner, the directory above it: a shell left in
# `.nightshift/` or `.nightshift/run/` still means the workspace, never a nested
# `.nightshift/.nightshift`. A `.nightshift` folder that holds its own `.nightshift/` is a
# workspace in its own right and is kept. Anything else, and a path that does not resolve, is
# returned as given. Mirrors ns_state_dir_owner.
function Get-NSStateDirOwner {
    param([Parameter(Mandatory = $true)][string]$Directory)
    try { $dir = (Resolve-Path -LiteralPath $Directory -ErrorAction Stop).ProviderPath }
    catch { return $Directory }
    $probe = $dir.TrimEnd([char]'/', [char]'\')
    while (-not [string]::IsNullOrEmpty($probe)) {
        $parent = [IO.Path]::GetDirectoryName($probe)
        if ([IO.Path]::GetFileName($probe) -ceq '.nightshift' -and
            -not (Test-Path -LiteralPath (Join-Path $probe '.nightshift') -PathType Container)) {
            if ([string]::IsNullOrEmpty($parent)) { return $probe }
            return $parent
        }
        if ([string]::IsNullOrEmpty($parent) -or $parent -ceq $probe) { break }
        $probe = $parent
    }
    return $dir
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

function Confirm-NSWorkTargetLink {
    param([Parameter(Mandatory = $true)][string]$Workspace)
    try {
        $ws = Resolve-NSCanonicalPath $Workspace
        $target = Resolve-NSWorkTarget $ws
        if ([string]::IsNullOrEmpty($target) -or $target -eq $ws) { return $true }
        if (-not (Test-Path -LiteralPath $target -PathType Container)) { return $false }
        try {
            if ((Resolve-NSWorkspaceRoot $target) -eq $ws) { return $true }
        }
        catch {
        }
        $link = Join-Path $target '.nightshift-link'
        if (Test-NSReparsePoint $link) { return $false }
        $null = Write-NSAtomicLines -Path $link -Lines @($ws)
        $gitDirectory = Invoke-NSGit $target @('rev-parse', '--git-dir')
        if (-not [string]::IsNullOrWhiteSpace($gitDirectory)) {
            if (-not [IO.Path]::IsPathRooted($gitDirectory)) {
                $gitDirectory = Join-Path $target $gitDirectory
            }
            $info = Join-Path $gitDirectory 'info'
            $null = New-Item -ItemType Directory -Path $info -Force
            $exclude = Join-Path $info 'exclude'
            $lines = if (Test-Path -LiteralPath $exclude -PathType Leaf) {
                @([IO.File]::ReadAllLines($exclude))
            }
            else {
                @()
            }
            if ($lines -notcontains '.nightshift-link') {
                $null = Write-NSAtomicLines -Path $exclude -Lines @($lines + '.nightshift-link')
            }
        }
        return $true
    }
    catch {
        return $false
    }
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
    $record = Get-NSLayoutPath (Join-Path $project '.nightshift') 'work-target'
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
    Write-NSWorkMode $Workspace $Mode
    New-NSLayoutParent $ns 'work-target'
    $null = Write-NSAtomicLines -Path (Get-NSLayoutPath $ns 'work-target') -Lines @($top)
    if (-not (Confirm-NSWorkTargetLink $Workspace)) {
        throw 'could not record the work-target link'
    }
}

function Get-NSReceiptsDir {
    param([Parameter(Mandatory = $true)][string]$Workspace)
    return (Get-NSLayoutPath (Join-Path $Workspace '.nightshift') 'receipts')
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
    if ($s.Length -gt 60) {
        $s = $s.Substring(0, 60).TrimEnd('-')
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
    $pulse = Get-NSLayoutPath $ns 'pulse'
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
    $pulse = Get-NSLayoutPath $ns 'pulse'
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
    $stall = Get-NSLayoutPath (Join-Path $Workspace '.nightshift') 'stall'
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
    # The shift's own folder, at the path the ledger has live. A ledger already filed for the shift
    # keeps every record and gains the new ones.
    $directory = Get-NSArchiveGroup -Workspace $Workspace -Date (Get-Date -Format 'yyyy-MM-dd') -ShiftId $ShiftId
    if ($null -eq $directory -or (Test-NSReparsePoint $directory)) { return 2 }
    $ns = Join-Path $Workspace '.nightshift'
    $destination = Join-NSPath $directory (((Get-NSLayoutRelativePath $ns 'evidence') + '/findings.jsonl').Replace('/', [IO.Path]::DirectorySeparatorChar))
    if (-not (Test-NSArchiveDest $destination)) { return 2 }
    $null = [IO.Directory]::CreateDirectory((Split-Path -Parent $destination))
    [IO.File]::AppendAllText($destination, [IO.File]::ReadAllText($jsonl, $script:NSUtf8NoBom), $script:NSUtf8NoBom)
    [IO.File]::WriteAllText($jsonl, '', $script:NSUtf8NoBom)
    # The console, not the pipeline: the caller writes `exit (Invoke-NSEvidenceArchive ...)`, which
    # would consume this path as part of the expression's value and print nothing, and the archived
    # copy is the one thing the owner needs to be told about.
    [Console]::Out.Write($destination + "`n")
    return 0
}



function Get-NSStateKind {
    param([Parameter(Mandatory = $true)][string]$Workspace)

    $ns = Join-Path $Workspace '.nightshift'
    if (-not (Test-Path -LiteralPath $ns -PathType Container)) {
        return 'absent'
    }
    $marker = Get-NSLayoutPath $ns 'state-version'
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
    $path = Get-NSLayoutPath (Join-Path $Workspace '.nightshift') 'rules'
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
    $stopped = 0
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
                elseif ($line -match '^\s*-\s*\[-\]') {
                    $stopped++
                }
            }
        }
        catch {
            $readable = $false
            $open = 0
            $ticked = 0
            $stopped = 0
        }
    }
    return [pscustomobject]@{ Open = $open; Ticked = $ticked; Stopped = $stopped; Total = ($open + $ticked); Readable = $readable }
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

# Get-NSCodexTail <rollout> - the last megabyte of a rollout as text; one event can be large, and a
# rollout can run to hundreds of megabytes. Empty when the file cannot be read.
function Get-NSCodexTail {
    param([AllowEmptyString()][string]$Rollout)
    if ([string]::IsNullOrEmpty($Rollout) -or -not (Test-Path -LiteralPath $Rollout -PathType Leaf) -or (Test-NSReparsePoint $Rollout)) { return '' }
    try {
        $stream = [IO.File]::Open($Rollout, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        try {
            $take = [long][Math]::Min($stream.Length, 1048576)
            $null = $stream.Seek(-$take, [IO.SeekOrigin]::End)
            $buffer = New-Object byte[] $take
            $read = $stream.Read($buffer, 0, [int]$take)
            $text = (New-Object Text.UTF8Encoding($false)).GetString($buffer, 0, $read)
        }
        finally { $stream.Dispose() }
    }
    catch { return '' }
    return $text
}

# Get-NSCodexTurnLine <rollout> - the rollout's last turn boundary (task_started or task_complete).
function Get-NSCodexTurnLine {
    param([AllowEmptyString()][string]$Rollout)
    $last = ''
    foreach ($line in ((Get-NSCodexTail $Rollout) -split "`n")) {
        if ($line -cmatch '"payload":\{"type":"task_(started|complete)"') { $last = $line }
    }
    return $last
}

# Get-NSCodexTurnError <rollout> - how the thread's last turn ended, when it ended on an error.
# Codex records a failed model request on the turn's closing event: task_complete carries an error
# object with a codex_error_info kind (usage_limit_exceeded, other, ...) and the session stays open
# and quiet. Returns that kind, 'error' when the object names none, and '' otherwise.
# Mirrors ns_codex_turn_error.
function Get-NSCodexTurnError {
    param([AllowEmptyString()][string]$Rollout)
    $last = Get-NSCodexTurnLine $Rollout
    if (-not $last.Contains('"payload":{"type":"task_complete"')) { return '' }
    if ($last -notmatch '[^\\]"error":\{') { return '' }
    $kind = [regex]::Matches($last, '"codex_error_info":"([a-z_]+)"')
    if ($kind.Count -gt 0) { return $kind[$kind.Count - 1].Groups[1].Value }
    return 'error'
}

# Get-NSCodexTurnErrorAt <rollout> - the epoch that errored turn completed, or 0.
function Get-NSCodexTurnErrorAt {
    param([AllowEmptyString()][string]$Rollout)
    if ([string]::IsNullOrEmpty((Get-NSCodexTurnError $Rollout))) { return [long]0 }
    $at = [regex]::Match((Get-NSCodexTurnLine $Rollout), '"completed_at":([0-9]+)')
    if ($at.Success) { return [long]$at.Groups[1].Value }
    return [long]0
}

# Get-NSCodexLimitReset <rollout> - the epoch Codex last reported the usage window resets, or 0.
function Get-NSCodexLimitReset {
    param([AllowEmptyString()][string]$Rollout)
    $reset = [long]0
    foreach ($m in [regex]::Matches((Get-NSCodexTail $Rollout), '"resets_at":([0-9]+)')) { $reset = [long]$m.Groups[1].Value }
    return $reset
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

    $receiptGit = Get-NSLayoutPath $NightshiftDir 'receipts-repo'
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
        $scope = Get-NSLayoutRelativePath $NightshiftDir 'mutex-scope'
        foreach ($entry in @($scope, ($scope + '.tmp.*'))) {
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
            $scope, ($scope + '.tmp.*')
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
    $path = Get-NSLayoutPath $NightshiftDir 'mutex-scope'
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
        $path = Get-NSLayoutPath $NightshiftDir 'session'
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
    $path = Get-NSLayoutPath $NightshiftDir 'session'
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
        $path = Get-NSLayoutPath $NightshiftDir 'session'
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
    $path = Get-NSLayoutPath $NightshiftDir 'lease'
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
        return Write-NSAtomicLines -Path (Get-NSLayoutPath $NightshiftDir 'lease') `
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
        $path = Get-NSLayoutPath $NightshiftDir 'lease'
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
        $path = Get-NSLayoutPath $NightshiftDir 'lease'
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
            $path = Get-NSLayoutPath $NightshiftDir 'lease'
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
        $path = Get-NSLayoutPath $NightshiftDir 'lease'
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
        Remove-NSFile (Get-NSLayoutPath $NightshiftDir 'lease')
        Get-ChildItem -LiteralPath $NightshiftDir -Filter '.shift-lease.tmp.*' -Force -ErrorAction SilentlyContinue |
            Remove-Item -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath (Get-NSLayoutPath $NightshiftDir 'lease-lock') -Recurse -Force -ErrorAction SilentlyContinue
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
    $stop = Get-NSLayoutPath $NightshiftDir 'stop'
    $ended = Get-NSLayoutPath $NightshiftDir 'ended'
    if (-not (Test-Path -LiteralPath $stop -PathType Leaf)) { return '' }
    if ((Test-Path -LiteralPath $ended -PathType Leaf) -and -not (Test-NSReparsePoint $ended)) { return '' }
    $deadline = Get-NSLayoutPath $NightshiftDir 'deadline'
    if (-not (Test-Path -LiteralPath $deadline -PathType Leaf) -or (Test-NSReparsePoint $deadline)) {
        return ''
    }
    $raw = ([IO.File]::ReadAllText($deadline)).Trim()
    if ($raw -notmatch '^[0-9]+$') { return '' }
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    if ($now -lt [long]$raw) { return '' }
    return "paused shift deadline has expired - write a new UNIX epoch to $NightshiftDir/deadline, or run Reset then Start; refusing to invent a time budget"
}

function Test-NSSitePaused {
    param([Parameter(Mandatory = $true)][string]$NightshiftDir)
    $stop = Get-NSLayoutPath $NightshiftDir 'stop'
    $ended = Get-NSLayoutPath $NightshiftDir 'ended'
    if ((Test-Path -LiteralPath $stop -PathType Leaf) -and -not (Test-NSReparsePoint $stop)) { return $true }
    if ((Test-Path -LiteralPath $ended -PathType Leaf) -and -not (Test-NSReparsePoint $ended)) { return $true }
    return $false
}

function Stop-NSWatchman {
    param([Parameter(Mandatory = $true)][string]$NightshiftDir)
    $pidFile = Get-NSLayoutPath $NightshiftDir 'watchman'
    $tick = Get-NSLayoutPath $NightshiftDir 'watchman-tick'
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
    foreach ($key in @('armed', 'ended', 'session-end', 'pulse', 'mint-failed', 'session', 'stall', 'notified', 'watchman-tick', 'mutex-scope')) {
        Remove-NSPath (Get-NSLayoutPath $NightshiftDir $key)
    }
    foreach ($key in @('session', 'mutex-scope')) {
        $record = Get-NSLayoutPath $NightshiftDir $key
        $pattern = (Split-Path -Leaf $record) + '.tmp.*'
        Get-ChildItem -LiteralPath (Split-Path -Parent $record) -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like $pattern } |
            ForEach-Object { Remove-NSPath $_.FullName }
    }
    Remove-NSPath (Get-NSLayoutPath $NightshiftDir 'lock')
    $null = Reset-NSStaleLease $NightshiftDir
}

function Write-NSControlLog {
    param(
        [Parameter(Mandatory = $true)][string]$NightshiftDir,
        [Parameter(Mandatory = $true)][string]$Line
    )
    $log = Get-NSLayoutPath $NightshiftDir 'shift-log'
    $stamp = Get-NSLocalNow -Seconds
    Add-Content -LiteralPath $log -Value "$stamp $script:NSDot $Line" -Encoding utf8
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
    $ts = Get-NSLocalNow -Seconds
    Remove-NSPath (Get-NSLayoutPath $ns 'stop')
    [IO.File]::WriteAllText((Get-NSLayoutPath $ns 'stop'), "$Reason $script:NSDot $ts`n")
    Remove-NSPath (Get-NSLayoutPath $ns 'session')
    $null = Write-NSUsagePause $ns 'owner stop-work'
    $watch = Stop-NSWatchman $ns
    $null = Write-NSReason $ns 'owner-stop'
    Write-NSControlLog $ns 'stopped by owner'
    $open = 0
    $punch = Get-NSLayoutPath $ns 'punch-list'
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
    $tx = Get-NSLayoutPath $ctx.NightshiftDir 'provision-transaction'
    if (Test-NSPathEntry $tx) {
        Write-Error 'reset-shift: refuse while provision-transaction.json is open; run provision recover or rollback first'
        return 1
    }
    Stop-NSShift -Project $Project -Reason 'reset by owner'
    $ctx = Resolve-NSControlWorkspace $Project
    Clear-NSRuntimeMarkers $ctx.NightshiftDir
    Remove-NSPath (Get-NSLayoutPath $ctx.NightshiftDir 'stop')
    Remove-NSPath (Get-NSLayoutPath $ctx.NightshiftDir 'deadline')
    Remove-NSPath (Get-NSLayoutPath $ctx.NightshiftDir 'watch-reason')
    # shift-defaults.json (remembered convenience) and rules.json (permanent boundaries) survive
    # a reset exactly like the punch list and parking lot do; only tonight's snapshot goes.
    Remove-NSPath (Get-NSLayoutPath $ctx.NightshiftDir 'shift-policy')
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

