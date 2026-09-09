param(
    [string]$Project = [Environment]::CurrentDirectory,
    [string]$Date = '',
    [string[]]$Retire = @()
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$pluginRoot = Resolve-Path (Join-Path $PSScriptRoot '../..')
Import-Module (Join-Path $pluginRoot 'lib/Nightshift.psm1') -Force -DisableNameChecking

function Write-NSArchiveReceiptsError {
    param([string]$Message)
    [Console]::Error.WriteLine($Message)
}

try {
    $hostPath = Resolve-NSCanonicalPath $Project
}
catch {
    Write-NSArchiveReceiptsError "archive-receipts: cannot cd to $Project"
    exit 1
}

try {
    $workspace = Resolve-NSWorkspaceRoot $hostPath
}
catch {
    Write-NSArchiveReceiptsError 'archive-receipts: invalid .nightshift-link - Nightshift will not guess a workspace'
    exit 2
}

$kind = Get-NSStateKind $workspace
if ($kind -in @('malformed', 'future')) {
    Write-NSArchiveReceiptsError ("archive-receipts: {0}" -f (Get-NSStateRefuseMessage $kind))
    exit 2
}
if ($kind -eq 'absent') {
    Write-NSArchiveReceiptsError "archive-receipts: no .nightshift/ at $workspace"
    exit 2
}

$ns = Join-Path $workspace '.nightshift'
if ([string]::IsNullOrWhiteSpace($Date)) {
    $Date = Get-Date -Format 'yyyy-MM-dd'
}
if ($Date -notmatch '^\d{4}-\d{2}-\d{2}$') {
    Write-NSArchiveReceiptsError 'archive-receipts: -Date must be YYYY-MM-DD'
    exit 1
}

# Invoked with -File, PowerShell hands an array parameter through as one string, so the list is
# split here and both invocation styles name the same records.
$Retire = @($Retire | ForEach-Object { $_ -split ',' } | Where-Object { $_ -cne '' })
foreach ($name in $Retire) {
    if ([string]::IsNullOrEmpty($name) -or $name -cmatch '[\\/]' -or $name.StartsWith('.', [StringComparison]::Ordinal)) {
        Write-NSArchiveReceiptsError "archive-receipts: -Retire takes a record name, not a path: $name"
        exit 1
    }
}

$src = Get-NSReceiptsDir $workspace
# The owner's archive.root and archive.layout decide where this lands, the same as on POSIX, and
# the same containment refuses a root that would leave the state area.
# Whose records these are. The live policy answers while it is still live; once clock-out has
# archived it, the ending marker is what remembers, so a shift filed later lands under its own
# name rather than a date bucket that could hold somebody else's night too.
$shiftId = ''
$policyState = Get-NSShiftPolicyState $workspace
if ($policyState['state'] -ceq 'valid') { $shiftId = [string]$policyState['policy']['shiftId'] }
if ([string]::IsNullOrEmpty($shiftId) -or $shiftId -ceq 'unknown') {
    $endedId = Get-NSEndedField $workspace 'shiftId'
    if (-not [string]::IsNullOrEmpty($endedId)) { $shiftId = $endedId }
}
$group = Get-NSArchiveDir -Workspace $workspace -Date $Date -ShiftId $shiftId
if ($null -eq $group) {
    Write-NSArchiveReceiptsError 'archive-receipts: archive.root must name a directory inside .nightshift/ - an absolute path, a path with .., or a symlink is not supported'
    exit 2
}
$dest = Join-Path $group 'receipts'
if ((Test-Path -LiteralPath $src) -and (Test-NSReparsePoint $src)) {
    Write-NSArchiveReceiptsError 'archive-receipts: refuse to write through a symlink receipts path'
    exit 2
}
if ((Test-Path -LiteralPath $src) -and -not (Test-Path -LiteralPath $src -PathType Container)) {
    Write-NSArchiveReceiptsError 'archive-receipts: receipts path is not a directory'
    exit 2
}
foreach ($p in @((Get-NSArchiveRoot $workspace), $group, $dest)) {
    if (Test-Path -LiteralPath $p) {
        $item = Get-Item -LiteralPath $p -Force
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            Write-NSArchiveReceiptsError 'archive-receipts: refuse to write through a symlink archive path'
            exit 2
        }
        if (-not (Test-Path -LiteralPath $p -PathType Container)) {
            Write-NSArchiveReceiptsError 'archive-receipts: refuse to write through a non-directory archive path'
            exit 2
        }
    }
}

# The archived copy is read back and compared, so a copy that silently truncated or landed on
# another filesystem is never mistaken for a safe one.
function Test-NSSameBytes {
    param([string]$A, [string]$B)
    if (-not (Test-Path -LiteralPath $A -PathType Leaf)) { return $false }
    if (-not (Test-Path -LiteralPath $B -PathType Leaf)) { return $false }
    $left = [IO.File]::ReadAllBytes($A)
    $right = [IO.File]::ReadAllBytes($B)
    if ($left.Length -ne $right.Length) { return $false }
    for ($i = 0; $i -lt $left.Length; $i++) {
        if ($left[$i] -ne $right[$i]) { return $false }
    }
    return $true
}

# Nothing leaves live storage unless the caller named it and the shift has ended. While a shift is
# armed nothing is removed at all: its receipts are what its own progress checks read. Which file
# it is never decides this - a name is not evidence that a record is finished with.
$armed = Test-Path -LiteralPath (Join-Path $ns '.shift-armed')
$endedMarker = Join-Path $ns '.ended'
$ended = (Test-Path -LiteralPath $endedMarker -PathType Leaf) -and
    -not ((Get-Item -LiteralPath $endedMarker -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)
$rotate = (-not $armed) -and $ended
if (-not $rotate -and $Retire.Count -gt 0) {
    if ($armed) {
        Write-NSArchiveReceiptsError 'archive-receipts: refuse to retire anything while the shift is armed'
    }
    else {
        Write-NSArchiveReceiptsError 'archive-receipts: refuse to retire anything before the shift has ended'
    }
    exit 2
}

$utf8 = New-Object Text.UTF8Encoding($false)
$copied = 0
$removed = 0
$kept = New-Object Collections.Generic.List[string]
$filed = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
$archivedPaths = New-Object Collections.Generic.List[string]

# Copy-NSArchiveRecord <source> <directory> - file one record, verify it, and retire the source
# when the caller established it as closed.
function Copy-NSArchiveRecord {
    param([string]$Source, [string]$Directory)
    $base = [IO.Path]::GetFileName($Source)
    $target = Join-Path $Directory $base
    # The leaf is checked too. A reparse point left where this record is about to land would carry
    # its bytes somewhere else and then read back as a faithful copy, so the source stays put.
    if (-not (Test-NSArchiveDest $target)) {
        $kept.Add($base + ' (a link or a directory is in the way of its archived copy)')
        return
    }
    if (Test-Path -LiteralPath $target) {
        if (-not (Test-NSSameBytes $Source $target)) {
            # Two different records under one name. Neither is worth losing, so the one already
            # filed stands and the live one stays where it is.
            $kept.Add($base + ' (a different record is already filed under that name)')
            return
        }
    }
    else {
        Copy-Item -LiteralPath $Source -Destination $target -Force
        $script:copied++
    }
    if (-not (Test-NSSameBytes $Source $target)) {
        $kept.Add($base + ' (the archived copy does not match the source)')
        return
    }
    $null = $filed.Add($base)
    $archivedPaths.Add($Source.Substring($ns.Length).TrimStart([char]'/', [char]'\').Replace('\', '/'))
    if ($rotate -and ($Retire -ccontains $base)) {
        Remove-Item -LiteralPath $Source -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $Source) {
            $kept.Add($base + ' (could not be removed from live storage)')
            return
        }
        $script:removed++
    }
}

if (Test-Path -LiteralPath $src -PathType Container) {
    # The index is a view of a set of receipts, so each side of the move gets its own, written
    # below from what is actually there. The live one is never filed as a record of its own, and
    # the receipt of an item that is still open stays live with the box it belongs to.
    $openNames = @(Get-NSOpenReceiptNames $workspace)
    $files = @(Get-ChildItem -LiteralPath $src -File -Force -ErrorAction SilentlyContinue |
        Where-Object {
            -not $_.Name.StartsWith('.') -and
            -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -and
            $_.Name -cne 'README.md' -and
            -not ($openNames -ccontains $_.Name)
        })
    if ($files.Count -gt 0) {
        $null = New-Item -ItemType Directory -Path $dest -Force
        $destItem = Get-Item -LiteralPath $dest -Force
        if ($destItem.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            Write-NSArchiveReceiptsError 'archive-receipts: refuse to write through a symlink archive path'
            exit 2
        }
        foreach ($file in $files) {
            $null = Copy-NSArchiveRecord $file.FullName $dest
        }
    }
}

# The shift report travels with the receipts it describes, and keeps working from where it lands.
$report = Join-Path $ns 'shift-report.md'
$reportBase = ''
$reportRelocated = $false
if ((Test-Path -LiteralPath $report -PathType Leaf) -and -not (Test-NSReparsePoint $report)) {
    $reportBase = [IO.Path]::GetFileName($report)
    $reportOriginal = Join-Path $group ([IO.Path]::GetFileNameWithoutExtension($reportBase) + '.original.md')
    if ((Test-Path -LiteralPath $reportOriginal -PathType Leaf) -and
        -not (Test-NSReparsePoint $reportOriginal) -and
        (Test-NSSameBytes $report $reportOriginal)) {
        # Filed already, on a run that relocated its links. The archived page differs from the
        # source by design, so the preserved original is what says whether this is the same report.
        $null = $filed.Add($reportBase)
        $reportRelocated = $true
        if ($rotate -and ($Retire -ccontains $reportBase)) {
            Remove-Item -LiteralPath $report -Force -ErrorAction SilentlyContinue
            if (Test-Path -LiteralPath $report) {
                $kept.Add($reportBase + ' (could not be removed from live storage)')
            }
            else { $removed++ }
        }
    }
    else {
        $null = New-Item -ItemType Directory -Path $group -Force
        $null = Copy-NSArchiveRecord $report $group
    }
}

# A record that travelled with this one is still a sibling; one that stayed live is now further
# away and its link has to say so. Rewriting changes bytes, so the untouched original is kept
# beside the relocated view rather than replaced by it.
# Convert-NSArchivedPageLinks <page> <its directory before the move, relative to the state area>
function Convert-NSArchivedPageLinks {
    param([string]$Page, [AllowEmptyString()][string]$From)
    if (-not (Test-Path -LiteralPath $Page -PathType Leaf)) { return }
    if (Test-NSReparsePoint $Page) { return }
    $base = [IO.Path]::GetFileName($Page)
    if ($base.EndsWith('.original.md', [StringComparison]::Ordinal)) { return }
    $relative = ([IO.Path]::GetDirectoryName($Page)).Substring($ns.Length).Trim([char]'/', [char]'\')
    $back = ''
    foreach ($component in ($relative -split '[\\/]')) {
        if (-not [string]::IsNullOrEmpty($component)) { $back = $back + '../' }
    }
    $source = [IO.File]::ReadAllText($Page, $utf8)
    $relocated = Convert-NSReportLinks -Text $source -Archived $archivedPaths.ToArray() -Back $back -Dir $From
    if ($relocated -ceq $source) { return }
    $original = Join-Path ([IO.Path]::GetDirectoryName($Page)) `
        ([IO.Path]::GetFileNameWithoutExtension($base) + '.original.md')
    if (Test-NSArchiveDest $original) {
        [IO.File]::WriteAllText($original, $source, $utf8)
        [IO.File]::WriteAllText($Page, $relocated, $utf8)
    }
    else {
        $kept.Add($base + ' (its links were left as written: the original could not be preserved beside a relocated view)')
    }
}

# The archive gets the index of what landed in it. Written before the relocation pass, so a receipt
# that links to its index has an index to link to: the archived folder holds one of its own, and
# that is the sibling the link still names.
$receiptsRel = $src.Substring($ns.Length).Trim([char]'/', [char]'\').Replace('\', '/')
Write-NSArchiveReceiptsIndex -Directory $dest -Date (Get-NSReceiptsShiftDate $workspace)
if (Test-Path -LiteralPath (Join-Path $dest 'README.md') -PathType Leaf) {
    $archivedPaths.Add($receiptsRel + '/README.md')
}
if (Test-Path -LiteralPath $dest -PathType Container) {
    foreach ($page in @(Get-ChildItem -LiteralPath $dest -File -Force -Filter '*.md' -ErrorAction SilentlyContinue)) {
        # The index is written into the folder it describes: its links are already siblings there.
        if ($page.Name -ceq 'README.md') { continue }
        Convert-NSArchivedPageLinks $page.FullName $receiptsRel
    }
}
if ($reportBase -cne '' -and -not $reportRelocated) {
    Convert-NSArchivedPageLinks (Join-Path $group $reportBase) ''
}

# The live folder lists the work still in hand - losing its index when there is nothing left
# to list.
Write-NSReceiptsIndex -Workspace $workspace -Remaining

try {
    Save-NSArchiveReviewRecords $workspace $Date $shiftId
}
catch {
    Write-NSArchiveReceiptsError 'archive-receipts: could not file snag or parking records'
    exit 2
}

$unmatched = @($Retire | Where-Object { -not $filed.Contains($_) })
if ($unmatched.Count -gt 0) {
    Write-NSArchiveReceiptsError 'archive-receipts: refused to retire - this run filed no such record:'
    foreach ($name in $unmatched) { Write-NSArchiveReceiptsError ('  ' + $name) }
}

if ($kept.Count -gt 0) {
    Write-NSArchiveReceiptsError 'archive-receipts: kept in live storage:'
    foreach ($line in $kept) { Write-NSArchiveReceiptsError $line }
}

if ($copied -eq 0 -and $removed -eq 0) {
    exit 0
}
Write-Output $dest
if ($removed -gt 0) {
    Write-NSArchiveReceiptsError ("archive-receipts: retired {0} closed record(s) from live storage" -f $removed)
}
exit 0
