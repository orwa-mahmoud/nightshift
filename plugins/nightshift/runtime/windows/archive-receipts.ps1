param(
    [string]$Project = [Environment]::CurrentDirectory,
    [string]$Date = '',
    [string[]]$Retire = @()
)

# archive-receipts.ps1 - file a shift into its archive folder, laid out the way it was live. The
# native twin of runtime/archive-receipts.sh, with the same records, the same paths and the same
# rules: each record is filed as it stands, then the live side keeps only what is still open.

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

# A closed record leaves live storage only when a shift has actually ended and the archived copy
# has been read back and matches. While a shift is armed nothing is removed at all.
$armed = Test-Path -LiteralPath (Get-NSLayoutPath $ns 'armed')
$endedMarker = Get-NSLayoutPath $ns 'ended'
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

function Get-NSArchiveRel {
    param([string]$Key, [string]$Instance = '')
    return (Get-NSLayoutRelativePath $ns $Key $Instance)
}

function Join-NSArchiveRel {
    param([string]$Base, [string]$Rel)
    return (Join-NSPath $Base ($Rel.Replace('/', [IO.Path]::DirectorySeparatorChar)))
}

$src = Get-NSReceiptsDir $workspace
# Whose records these are. Once the shift has ended, the ending marker says which shift that was,
# even when a policy for the next one is already live; before then the live policy answers.
$policyId = ''
$policyState = Get-NSShiftPolicyState $workspace
if ($policyState['state'] -ceq 'valid') { $policyId = [string]$policyState['policy']['shiftId'] }
$endedId = [string](Get-NSEndedField $workspace 'shiftId')
$shiftId = $policyId
if ($rotate -and -not [string]::IsNullOrEmpty($endedId)) {
    $shiftId = $endedId
}
elseif ([string]::IsNullOrEmpty($shiftId) -or $shiftId -ceq 'unknown') {
    if (-not [string]::IsNullOrEmpty($endedId)) { $shiftId = $endedId }
}
$group = $null
try { $group = Get-NSArchiveGroup -Workspace $workspace -Date $Date -ShiftId $shiftId } catch { $group = $null }
if ([string]::IsNullOrEmpty($group)) {
    Write-NSArchiveReceiptsError 'archive-receipts: archive.root must name a directory inside .nightshift/ - an absolute path, a path with .., or a symlink is not supported'
    exit 2
}
$receiptsRel = Get-NSArchiveRel 'receipts'
$dest = Join-NSArchiveRel $group $receiptsRel
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

$utf8 = New-Object Text.UTF8Encoding($false)
$script:copied = 0
$script:removed = 0
$kept = New-Object Collections.Generic.List[string]
$filed = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
$filedLines = New-Object Collections.Generic.List[string]
$script:tickedNames = @(Get-NSTickedReceiptNames $workspace)

# New-NSArchiveFolder <dir> - create a folder inside the shift's folder, refusing one reached
# through a reparse point.
function New-NSArchiveFolder {
    param([string]$Directory)
    $null = New-Item -ItemType Directory -Path $Directory -Force
    if ((Get-Item -LiteralPath $Directory -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
        Write-NSArchiveReceiptsError 'archive-receipts: refuse to write through a symlink archive path'
        exit 2
    }
}

# Copy-NSArchiveRecord <source> <directory> <keep|closed|own> - file one record, verify it, and
# retire the source when the shift has ended: closed when it was named or its item is ticked, own
# always, keep never. True when the record now has a verified archived copy.
function Copy-NSArchiveRecord {
    param([string]$Source, [string]$Directory, [string]$Rule)
    $base = [IO.Path]::GetFileName($Source)
    if ($base.StartsWith('.', [StringComparison]::Ordinal) -or $base -ceq '') { return $false }
    New-NSArchiveFolder $Directory
    $target = Join-Path $Directory $base
    # The leaf is checked too. A reparse point left where this record is about to land would carry
    # its bytes somewhere else and then read back as a faithful copy, so the source stays put.
    if (-not (Test-NSArchiveDest $target)) {
        $kept.Add($base + ' (a link or a directory is in the way of its archived copy)')
        return $false
    }
    if (Test-Path -LiteralPath $target) {
        if (-not (Test-NSArchiveSame $Source $target)) {
            # Two different records under one name. Neither is worth losing, so the one already
            # filed stands and the live one stays where it is.
            $kept.Add($base + ' (a different record is already filed under that name)')
            return $false
        }
    }
    else {
        Copy-Item -LiteralPath $Source -Destination $target -Force
        $script:copied++
        if (-not (Test-NSSameFileBytes $Source $target)) {
            $kept.Add($base + ' (the archived copy does not match the source)')
            return $false
        }
    }
    $null = $filed.Add($base)
    if (-not $rotate) { return $true }
    if ($Rule -ceq 'keep') { return $true }
    if ($Rule -ceq 'closed' -and -not (($Retire -ccontains $base) -or ($script:tickedNames -ccontains $base))) { return $true }
    Remove-Item -LiteralPath $Source -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $Source) {
        $kept.Add($base + ' (could not be removed from live storage)')
        return $true
    }
    $script:removed++
    return $true
}

# Copy-NSArchiveFolder <live-dir> <archived-dir> <name> - one folder of readings, filed as one
# record: under its own name, only when every record in it was, and removed from live storage only
# then.
function Copy-NSArchiveFolder {
    param([string]$Live, [string]$To, [string]$Name)
    $whole = $true
    foreach ($entry in @(Get-ChildItem -LiteralPath $Live -Force -ErrorAction SilentlyContinue |
            Where-Object { -not $_.Name.StartsWith('.') })) {
        if ($entry.PSIsContainer -or ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            $whole = $false
            continue
        }
        if (-not (Copy-NSArchiveRecord $entry.FullName $To 'keep')) { $whole = $false }
    }
    if (-not $whole) {
        $kept.Add($Name + ' (not every record in it could be filed)')
        return
    }
    $null = $filed.Add($Name)
    if (-not $rotate) { return }
    Remove-Item -LiteralPath $Live -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $Live) { $kept.Add($Name + ' (could not be removed from live storage)') }
    else { $script:removed++ }
}

# The receipts of items nobody finished. They are filed as they stand and stay live, exactly as the
# box stays in the punch list, so the next shift extends the same file rather than a copy of it.
$openNames = @(Get-NSOpenReceiptNames $workspace)
if (Test-Path -LiteralPath $src -PathType Container) {
    # The index is a view of a set of receipts, so each side of the move gets its own, written
    # below from what is actually there. The live one is never filed as a record of its own.
    $files = @(Get-ChildItem -LiteralPath $src -File -Force -ErrorAction SilentlyContinue |
        Where-Object {
            -not $_.Name.StartsWith('.') -and
            -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -and
            $_.Name -cne 'README.md'
        })
    foreach ($file in (Sort-NSOrdinal @($files | ForEach-Object { $_.Name }))) {
        $rule = $(if ($openNames -ccontains $file) { 'keep' } else { 'closed' })
        $null = Copy-NSArchiveRecord (Join-Path $src $file) $dest $rule
    }
}

# Once the shift has ended, its own records follow it: the usage readings, the policy when no
# clock-out filed it, and the shift log.
if ($rotate) {
    $usageDir = Get-NSLayoutPath $ns 'usage'
    if ((Test-Path -LiteralPath $usageDir -PathType Container) -and -not (Test-NSReparsePoint $usageDir)) {
        Copy-NSArchiveFolder $usageDir (Join-NSArchiveRel $group (Get-NSArchiveRel 'usage')) (Split-Path -Leaf $usageDir)
    }
    $policyFile = Get-NSLayoutPath $ns 'shift-policy'
    if ((Test-Path -LiteralPath $policyFile -PathType Leaf) -and -not (Test-NSReparsePoint $policyFile) -and
        -not [string]::IsNullOrEmpty($policyId) -and $policyId -ceq $shiftId) {
        $policyRel = Get-NSArchiveRel 'shift-policy'
        $policyDir = $group
        if ($policyRel.Contains('/')) { $policyDir = Join-NSArchiveRel $group $policyRel.Substring(0, $policyRel.LastIndexOf('/')) }
        if (Copy-NSArchiveRecord $policyFile $policyDir 'own') {
            $filedLines.Add('archive-receipts: filed the shift policy as ' + (Join-NSArchiveRel $group $policyRel))
        }
    }
    try {
        $journal = Save-NSArchiveJournal $workspace $group
        if (-not [string]::IsNullOrEmpty($journal)) { $filedLines.Add('archive-receipts: filed the shift log as ' + $journal) }
    }
    catch {
        $kept.Add((Split-Path -Leaf (Get-NSLayoutPath $ns 'shift-log')) + ' (the shift log could not be filed)')
    }
}

# A usage-<id>/ folder is a closed shift's readings, set aside by the Start preflight. It goes to the
# folder that shift claimed, at the path the readings have live, or into this shift's folder under
# its own name when no folder is that shift's or its readings are already there.
$usagePrefix = Get-NSLayoutPath $ns 'usage-shift' ''
$usageParent = Split-Path -Parent $usagePrefix
$usageLead = Split-Path -Leaf $usagePrefix
if ((Test-Path -LiteralPath $usageParent -PathType Container) -and -not (Test-NSReparsePoint $usageParent)) {
    $usageFolders = @(Get-ChildItem -LiteralPath $usageParent -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name.StartsWith($usageLead, [StringComparison]::Ordinal) -and $_.Name.Length -gt $usageLead.Length -and
            -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint)
        })
    foreach ($name in (Sort-NSOrdinal @($usageFolders | ForEach-Object { $_.Name }))) {
        $instance = $name.Substring($usageLead.Length)
        $ownerDir = Get-NSArchiveFolderOf $workspace $instance
        $usageRel = Get-NSArchiveRel 'usage'
        if (-not [string]::IsNullOrEmpty($ownerDir) -and -not (Test-Path -LiteralPath (Join-NSArchiveRel $ownerDir $usageRel))) {
            $to = Join-NSArchiveRel $ownerDir $usageRel
        }
        else {
            $to = Join-NSArchiveRel $group (Get-NSArchiveRel 'usage-shift' $instance)
        }
        Copy-NSArchiveFolder (Join-Path $usageParent $name) $to $name
    }
}

# A leftover shift-report.md (not yet migrated into receipts/) still travels.
$report = Join-NSPath $ns (Get-NSLayoutRelativePathAt 0 'previous-report')
if ((Test-Path -LiteralPath $report -PathType Leaf) -and -not (Test-NSReparsePoint $report)) {
    $null = Copy-NSArchiveRecord $report $group 'closed'
}

# The parking lot and the snag log, whole, then only their open entries live.
$label = Get-NSArchiveReviewLabel (Split-Path -Leaf $group) $shiftId ([string](Get-NSPolicyGroupSetting $workspace 'archive.layout')['value'])
foreach ($key in @('snag-log', 'parking-lot')) {
    try {
        $status = Save-NSArchiveReviewSource $workspace $key $group $label
    }
    catch {
        Write-NSArchiveReceiptsError 'archive-receipts: could not file snag or parking records'
        exit 2
    }
    if ($status -eq 3) {
        $kept.Add((Get-NSArchiveRel $key) + " (this shift's copy is already filed; its handled entries stay live for the next filing)")
    }
}
try {
    Add-NSArchiveBrokenPointers $workspace
}
catch {
    Write-NSArchiveReceiptsError 'archive-receipts: could not check the filed pointers'
    exit 2
}

# The punch list, once the shift has ended: filed whole, then only the contract and the open items
# live. While it is armed the list is its contract and nothing here touches it.
if ($rotate) {
    $punch = Save-NSArchivePunchList -Workspace $workspace -Folder $group -ShiftId $shiftId -Date $Date
    if ($punch.Status -eq 0) {
        if ($punch.Path -cne '') { $filedLines.Add('archive-receipts: filed the punch list as ' + $punch.Path) }
    }
    elseif ($punch.Status -eq 3) {
        Write-NSArchiveReceiptsError ('archive-receipts: a different punch list is already filed at ' + (Join-NSArchiveRel $group (Get-NSArchiveRel 'punch-list')) + '; the live list is unchanged')
    }
    else {
        Write-NSArchiveReceiptsError ('archive-receipts: could not file the punch list into ' + $group)
    }
}

# The archive gets the index of what landed in it, written before the link pass so a receipt that
# links to its index has one to link to.
if (Test-Path -LiteralPath $dest -PathType Container) {
    Write-NSArchiveReceiptsIndex -Directory $dest -Date (Get-NSReceiptsShiftDate $workspace) -OpenNames $openNames
}

# Every filed page keeps working from where it now sits. A record filed beside it is reached
# exactly as written; one that stayed live is further away and its link says so. Rewriting changes
# bytes, so the untouched original is kept beside the repointed page, and a page repointed on an
# earlier filing is left alone. The shift log is raw evidence and stays as written.
$archivedPaths = New-Object Collections.Generic.List[string]
$groupFull = (Get-Item -LiteralPath $group -Force).FullName.TrimEnd([char]'/', [char]'\')
foreach ($file in @(Get-ChildItem -LiteralPath $group -File -Recurse -Force -ErrorAction SilentlyContinue)) {
    if ($file.Name.StartsWith('.', [StringComparison]::Ordinal)) { continue }
    if ($file.Name.EndsWith('.original.md', [StringComparison]::Ordinal)) { continue }
    $archivedPaths.Add($file.FullName.Substring($groupFull.Length).TrimStart([char]'/', [char]'\').Replace('\', '/'))
}
$journalRel = Get-NSArchiveRel 'shift-log'
foreach ($rel in (Sort-NSOrdinal $archivedPaths.ToArray())) {
    if (-not $rel.EndsWith('.md', [StringComparison]::Ordinal)) { continue }
    if ($rel -ceq $journalRel) { continue }
    # The index is written into the folder it describes: its links are already siblings there.
    if ($rel -ceq ($receiptsRel + '/README.md')) { continue }
    $page = Join-NSArchiveRel $group $rel
    if (Test-NSReparsePoint $page) { continue }
    $original = $page.Substring(0, $page.Length - 3) + '.original.md'
    if (Test-Path -LiteralPath $original) { continue }
    $from = ''
    if ($rel.Contains('/')) { $from = $rel.Substring(0, $rel.LastIndexOf('/')) }
    $relative = ([IO.Path]::GetDirectoryName($page)).Substring($ns.Length).Trim([char]'/', [char]'\')
    $back = ''
    foreach ($component in ($relative -split '[\\/]')) {
        if (-not [string]::IsNullOrEmpty($component)) { $back = $back + '../' }
    }
    $source = [IO.File]::ReadAllText($page, $utf8)
    $relocated = Convert-NSReportLinks -Text $source -Archived $archivedPaths.ToArray() -Back $back -Dir $from
    if ($relocated -ceq $source) { continue }
    if (Test-NSArchiveDest $original) {
        [IO.File]::WriteAllText($original, $source, $utf8)
        [IO.File]::WriteAllText($page, $relocated, $utf8)
    }
    else {
        $kept.Add([IO.Path]::GetFileName($page) + ' (its links were left as written: the original could not be preserved beside a relocated view)')
    }
}

# The live folder lists the work still in hand - losing its index when there is nothing left
# to list.
Write-NSReceiptsIndex -Workspace $workspace -Remaining

$unmatched = @($Retire | Where-Object { -not $filed.Contains($_) })
if ($unmatched.Count -gt 0) {
    Write-NSArchiveReceiptsError 'archive-receipts: refused to retire - this run filed no such record:'
    foreach ($name in $unmatched) { Write-NSArchiveReceiptsError ('  ' + $name) }
}

if ($kept.Count -gt 0) {
    Write-NSArchiveReceiptsError 'archive-receipts: kept in live storage:'
    foreach ($line in $kept) { Write-NSArchiveReceiptsError $line }
}

if ($script:copied -ne 0 -or $script:removed -ne 0 -or $filedLines.Count -gt 0) {
    Write-Output $group
    if ($script:removed -gt 0) {
        Write-NSArchiveReceiptsError ("archive-receipts: retired {0} closed record(s) from live storage" -f $script:removed)
    }
}
foreach ($line in $filedLines) { Write-Output $line }
exit 0
