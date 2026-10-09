# Read-NSUsageCodex <rollout> - the running total from the rollout's last token_count line. Codex
# counts cached input inside input and reasoning inside output; that arrangement is carried
# through rather than corrected, and the report states it.
function Read-NSUsageCodex {
    param([Parameter(Mandatory = $true)][string]$Path)
    if ((Test-NSReparsePoint $Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $last = ''
    foreach ($line in [IO.File]::ReadLines($Path)) {
        if ($line.IndexOf('"token_count"', [StringComparison]::Ordinal) -ge 0) { $last = $line }
    }
    if ([string]::IsNullOrEmpty($last)) { return $null }
    $at = $last.IndexOf('"total_token_usage"', [StringComparison]::Ordinal)
    if ($at -lt 0) { return $null }
    $block = $last.Substring($at)
    $input = Get-NSUsageNumber $block 'input_tokens'
    $output = Get-NSUsageNumber $block 'output_tokens'
    if ($input -lt 0 -or $output -lt 0) { return $null }
    $fields = "input=$input"
    $cachew = Get-NSUsageNumber $block 'cache_write_input_tokens'
    if ($cachew -ge 0) { $fields += ",cache_write=$cachew" }
    $cacher = Get-NSUsageNumber $block 'cached_input_tokens'
    if ($cacher -ge 0) { $fields += ",cache_read=$cacher" }
    # Codex counts cached input inside input_tokens; every other host reports input without it.
    # Taking it out makes `input` fresh input on every host. Mirrors usage-codex.awk.
    if ($cacher -ge 0 -and $cacher -le $input) { $fields = $fields -replace '^input=[0-9]+', ('input=' + ($input - $cacher)) }
    $fields += ",output=$output"
    $reason = Get-NSUsageNumber $block 'reasoning_output_tokens'
    if ($reason -ge 0) { $fields += ",reasoning=$reason" }
    return ($fields + "`t0`t" + (Get-NSUsageString $last 'model') + "`t0")
}

# Get-NSUsageOverlap <host> - the one sentence saying what is already counted inside what.
# Byte-identical to ns_usage_overlap.
function Get-NSUsageOverlap {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$HostName)
    switch ($HostName) {
        'claude' { return 'Cache reads and cache writes are separate from the input figure; reasoning is inside output.' }
        'codex' { return 'Cache reads and cache writes are separate from the input figure; reasoning is inside output.' }
        'cursor' { return 'The input figure overlaps the cache figures; Cursor reports no reasoning or subagent tokens.' }
    }
    return 'Overlap between the dimensions is unknown for this host.'
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
    $ns = Join-Path $Workspace '.nightshift'
    $name = [string](Get-NSPolicyGroupSetting $Workspace 'archive.root')['value']
    if ([string]::IsNullOrEmpty($name)) { $name = Get-NSLayoutRelativePath $ns 'archive' }
    # The live records are not an archive destination: filing into them would file a shift on top
    # of the shift that is still running.
    foreach ($key in @('receipts', 'inbox', 'staging', 'product', 'run')) {
        $live = Get-NSLayoutRelativePath $ns $key
        if ($live.Length -eq 0) { continue }
        if ($name -ceq $live -or $name -clike ($live + '/*') -or $name -clike ($live + '\*')) { return $null }
    }
    return (Get-NSStatePath $ns $name)
}

# Get-NSArchiveDir <workspace> <date> <shift-id> [<shift-name>] - the directory one shift is filed
# into.
#
# The shift layout gives each shift `shift-<id>/`. The date layout gives the first shift of a day
# `<date>/` and each later one `<date>-shift-2/`, `<date>-shift-3/` and so on, so two shifts never
# share a punch list, a log or a receipt name. The name layout uses the shift's name instead of the
# date, and date-name both, as in `2026-09-25-archive-follow-ups/`; a shift with no name falls back
# to the date. A second shift under the same name takes `-shift-2` the same way. A folder records the shift it belongs to in
# `.shift-id`, `unknown` for a shift that ended without an id, and a shift filed again that day
# comes back to its own folder. An empty folder without that record is claimed; one that already
# holds records without it belongs to nobody we can name and is never claimed. A candidate that is
# a reparse point or not a directory is returned as it is, for the caller to refuse.
function Get-NSArchiveDir {
    param(
        [Parameter(Mandatory = $true)][string]$Workspace,
        [Parameter(Mandatory = $true)][string]$Date,
        [AllowEmptyString()][string]$ShiftId = '',
        [AllowEmptyString()][string]$Name = ''
    )
    $root = Get-NSArchiveRoot $Workspace
    if ($null -eq $root) { return $null }
    $layout = [string](Get-NSPolicyGroupSetting $Workspace 'archive.layout')['value']
    if ([string]::IsNullOrEmpty($ShiftId)) { $ShiftId = 'unknown' }
    if ($layout -ceq 'shift' -and $ShiftId -cne 'unknown') {
        return (Join-Path $root ('shift-' + $ShiftId))
    }
    $slug = ''
    if (-not [string]::IsNullOrEmpty($Name)) { $slug = Get-NSReceiptSlug $Name }
    $base = Join-Path $root $Date
    if ($slug -cne '') {
        if ($layout -ceq 'name') { $base = Join-Path $root $slug }
        elseif ($layout -ceq 'date-name') { $base = Join-Path $root ($Date + '-' + $slug) }
    }
    $dir = $base
    $n = 1
    while ($true) {
        if ((Test-NSReparsePoint $dir) -or ((Test-Path -LiteralPath $dir) -and -not (Test-Path -LiteralPath $dir -PathType Container))) {
            return $dir
        }
        if (-not (Test-Path -LiteralPath $dir)) {
            try {
                $null = New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop
                [IO.File]::WriteAllText((Join-Path $dir '.shift-id'), $ShiftId + "`n", (New-Object Text.UTF8Encoding($false)))
            }
            catch {
                return $null
            }
            return $dir
        }
        $owner = ''
        $record = Join-Path $dir '.shift-id'
        if ((Test-Path -LiteralPath $record -PathType Leaf) -and -not (Test-NSReparsePoint $record)) {
            $lines = @([IO.File]::ReadAllLines($record))
            if ($lines.Count -gt 0) { $owner = $lines[0] }
        }
        elseif (-not (Test-Path -LiteralPath $record) -and
            @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue).Count -eq 0) {
            try {
                [IO.File]::WriteAllText($record, $ShiftId + "`n", (New-Object Text.UTF8Encoding($false)))
            }
            catch {
                return $null
            }
            $owner = $ShiftId
        }
        if ($owner -ceq $ShiftId) { return $dir }
        $n++
        $dir = $base + '-shift-' + $n
    }
}

# Get-NSArchiveGroup <workspace> <date> <shift-id> - the folder one shift files into. Once clock-out
# has claimed it, the ending marker names it and every later filing of that shift returns there,
# whatever day it runs; before that, or when the named folder is gone or is another shift's, it is
# resolved from the date, the id and the shift's name. Mirrors ns_archive_group.
function Get-NSArchiveGroup {
    param(
        [Parameter(Mandatory = $true)][string]$Workspace,
        [Parameter(Mandatory = $true)][string]$Date,
        [AllowEmptyString()][string]$ShiftId = ''
    )
    if ([string]::IsNullOrEmpty($ShiftId)) { $ShiftId = 'unknown' }
    $claimed = Get-NSArchiveGroupIfClaimed $Workspace $ShiftId
    if ($claimed -cne '') { return $claimed }
    $name = ''
    if ((Get-NSEndedField $Workspace 'shiftId') -ceq $ShiftId) { $name = Get-NSEndedField $Workspace 'shiftName' }
    if ([string]::IsNullOrEmpty($name)) {
        $name = Get-NSShiftName (Get-NSLayoutPath (Join-Path $Workspace '.nightshift') 'punch-list')
    }
    return (Get-NSArchiveDir -Workspace $Workspace -Date $Date -ShiftId $ShiftId -Name $name)
}

# Get-NSArchiveGroupIfClaimed <workspace> <shift-id> - the folder the ending marker names for that
# shift, only when it exists and that shift still owns it. '' otherwise.
function Get-NSArchiveGroupIfClaimed {
    param([Parameter(Mandatory = $true)][string]$Workspace, [AllowEmptyString()][string]$ShiftId = '')
    if ((Get-NSEndedField $Workspace 'shiftId') -cne $ShiftId) { return '' }
    $folder = [string](Get-NSEndedField $Workspace 'archiveFolder')
    if ($folder -ceq '' -or $folder -cmatch '[\\/]' -or $folder.StartsWith('.', [StringComparison]::Ordinal)) { return '' }
    $root = Get-NSArchiveRoot $Workspace
    if ($null -eq $root) { return '' }
    $dir = Join-Path $root $folder
    if ((Get-NSArchiveFolderOwner $dir) -ceq $ShiftId) { return $dir }
    return ''
}

# Get-NSArchiveFolderOwner <dir> - the shift a folder records in its .shift-id, or '' for a folder
# that is a reparse point or records none.
function Get-NSArchiveFolderOwner {
    param([Parameter(Mandatory = $true)][string]$Directory)
    if (-not (Test-Path -LiteralPath $Directory -PathType Container) -or (Test-NSReparsePoint $Directory)) { return '' }
    $record = Join-Path $Directory '.shift-id'
    if (-not (Test-Path -LiteralPath $record -PathType Leaf) -or (Test-NSReparsePoint $record)) { return '' }
    $lines = @([IO.File]::ReadAllLines($record))
    if ($lines.Count -eq 0) { return '' }
    return [string]$lines[0]
}

# Get-NSArchiveFolderOf <workspace> <shift-id> - the archive folder a shift with that id claimed, or
# ''. A shift without an id owns no folder anyone can find by it. Mirrors ns_archive_folder_of.
function Get-NSArchiveFolderOf {
    param([Parameter(Mandatory = $true)][string]$Workspace, [AllowEmptyString()][string]$ShiftId = '')
    if ([string]::IsNullOrEmpty($ShiftId) -or $ShiftId -ceq 'unknown' -or $ShiftId -cmatch '[^A-Za-z0-9-]') { return '' }
    $root = Get-NSArchiveRoot $Workspace
    if ($null -eq $root -or -not (Test-Path -LiteralPath $root -PathType Container)) { return '' }
    $names = @(Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
    foreach ($name in (Sort-NSOrdinal $names)) {
        $dir = Join-Path $root $name
        if ((Get-NSArchiveFolderOwner $dir) -ceq $ShiftId) { return $dir }
    }
    return ''
}

# Find-NSArchivedShiftPolicy <workspace> <shift-id> - the shift policy filed for that shift: in the
# folder the ending marker names, then in any folder the shift claimed, at the path the policy has
# live, then under the shift-policy-<id>.json name earlier versions filed it by, anywhere under the
# archive root. '' when none is filed. Mirrors ns_archived_policy.
function Find-NSArchivedShiftPolicy {
    param([Parameter(Mandatory = $true)][string]$Workspace, [AllowEmptyString()][string]$ShiftId = '')
    if ([string]::IsNullOrEmpty($ShiftId) -or $ShiftId -ceq 'unknown' -or $ShiftId -cnotmatch '^[0-9a-f-]+$') { return '' }
    $root = $null
    try { $root = Get-NSArchiveRoot $Workspace } catch { return '' }
    if ([string]::IsNullOrEmpty($root) -or -not (Test-NSMigrationDirectory $root)) { return '' }
    foreach ($folder in @((Get-NSArchiveGroupIfClaimed $Workspace $ShiftId), (Get-NSArchiveFolderOf $Workspace $ShiftId))) {
        if ([string]::IsNullOrEmpty($folder)) { continue }
        foreach ($rel in @('run/shift-policy.json', 'shift-policy.json', ('shift-policy-' + $ShiftId + '.json'))) {
            $candidate = Join-NSPath $folder ($rel.Replace('/', [IO.Path]::DirectorySeparatorChar))
            if (Test-NSMigrationFile $candidate) { return $candidate }
        }
    }
    $name = 'shift-policy-' + $ShiftId + '.json'
    $found = New-Object Collections.Generic.List[string]
    $pending = New-Object Collections.Generic.Queue[string]
    $pending.Enqueue($root)
    while ($pending.Count -gt 0) {
        $dir = $pending.Dequeue()
        foreach ($entry in (Get-NSMigrationChildren $dir)) {
            $path = Join-NSPath $dir $entry
            if (Test-NSMigrationDirectory $path) { $pending.Enqueue($path); continue }
            if ($entry -ceq $name -and (Test-NSMigrationFile $path)) { $found.Add($path) }
        }
    }
    if ($found.Count -eq 0) { return '' }
    return (Sort-NSOrdinal $found.ToArray())[0]
}

# Split-NSArchiveRecords <text> - the text as awk reads it: one record per line, a CR it carries
# kept, and a final line with no newline still a record.
function Split-NSArchiveRecords {
    param([AllowEmptyString()][string]$Text)
    if ($Text.Length -eq 0) { return , @() }
    $parts = $Text.Split([char]"`n")
    if ($Text.EndsWith("`n", [StringComparison]::Ordinal)) { $parts = $parts[0..($parts.Length - 2)] }
    return , $parts
}

# Get-NSArchiveRelocated <text> <filed> <group> <ns> - the text with its relative links repointed
# for where <filed> sits inside the archive folder <group>: a link to a record filed in <group>
# stays a sibling link, one to a record that stayed live climbs back to it. Mirrors
# ns_archive_relocate.
function Get-NSArchiveRelocated {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory = $true)][string]$Filed,
        [Parameter(Mandatory = $true)][string]$Group,
        [Parameter(Mandatory = $true)][string]$Ns
    )
    $seps = [char[]]@('/', '\')
    $groupPath = $Group.TrimEnd($seps)
    $nsPath = $Ns.TrimEnd($seps)
    if (-not ($Filed.StartsWith($groupPath + '/', [StringComparison]::Ordinal) -or
            $Filed.StartsWith($groupPath + '\', [StringComparison]::Ordinal))) {
        throw 'the filed path is outside its archive folder'
    }
    $rel = $Filed.Substring($groupPath.Length).TrimStart($seps).Replace('\', '/')
    $from = ''
    if ($rel.Contains('/')) { $from = $rel.Substring(0, $rel.LastIndexOf('/')) }
    $relative = ([IO.Path]::GetDirectoryName($Filed)).Substring($nsPath.Length).Trim($seps)
    $back = ''
    foreach ($component in ($relative -split '[\\/]')) {
        if (-not [string]::IsNullOrEmpty($component)) { $back = $back + '../' }
    }
    $archived = New-Object Collections.Generic.List[string]
    if (Test-Path -LiteralPath $groupPath -PathType Container) {
        $groupFull = (Get-Item -LiteralPath $groupPath -Force).FullName.TrimEnd($seps)
        foreach ($file in @(Get-ChildItem -LiteralPath $groupPath -File -Recurse -Force -ErrorAction SilentlyContinue)) {
            if ($file.Name.StartsWith('.', [StringComparison]::Ordinal)) { continue }
            if ($file.Name.EndsWith('.original.md', [StringComparison]::Ordinal)) { continue }
            $archived.Add($file.FullName.Substring($groupFull.Length).TrimStart($seps).Replace('\', '/'))
        }
    }
    return (Convert-NSReportLinks -Text $Text -Archived $archived.ToArray() -Back $back -Dir $from)
}

# Get-NSArchiveMissingBlocks <filed> <chunk> - each entry of <chunk> that <filed> does not already
# hold, as whole lines, each followed by a newline. An entry is a top-level `- ` line with the lines
# under it, its `Default:` and `Rollback:` lines included; trailing blank lines are not part of it.
# '' when every entry is already filed; given '', every entry. Mirrors _ns_archive_missing_blocks.
function Get-NSArchiveMissingBlocks {
    param([AllowEmptyString()][string]$Filed, [AllowEmptyString()][string]$Chunk)
    $have = New-Object Text.StringBuilder
    $null = $have.Append("`n")
    foreach ($line in (Split-NSArchiveRecords $Filed)) { $null = $have.Append($line.TrimEnd([char]"`r")).Append("`n") }
    $haveText = $have.ToString()
    $out = New-Object Text.StringBuilder
    $buf = ''
    $flush = {
        if ($buf -ne '') {
            $block = $buf.TrimEnd([char]"`n")
            if (-not $haveText.Contains("`n" + $block + "`n")) { $null = $out.Append($block).Append("`n") }
        }
    }
    foreach ($raw in (Split-NSArchiveRecords $Chunk)) {
        $line = $raw.TrimEnd([char]"`r")
        if ($buf -ne '' -and $line -cmatch '^ *(- )?(\*\*)?(Default|Rollback):') { $buf = $buf + $line + "`n"; continue }
        if ($line.StartsWith('- ', [StringComparison]::Ordinal)) { . $flush; $buf = $line + "`n"; continue }
        if ($buf -ne '') { $buf = $buf + $line + "`n" }
    }
    . $flush
    return $out.ToString()
}

# Get-NSArchivePunchItems <closed|ticked> <text> - the punch list read by item: `closed` is the list
# less its open items, `ticked` only the ticked items, each with the lines under it. Mirrors
# _ns_archive_items.
function Get-NSArchivePunchItems {
    param([Parameter(Mandatory = $true)][string]$Mode, [AllowEmptyString()][string]$Text)
    $closed = ($Mode -ceq 'closed')
    $out = New-Object Text.StringBuilder
    $items = $false; $done = $false; $take = $false; $blanks = ''
    foreach ($raw in (Split-NSArchiveRecords $Text)) {
        $line = $raw.TrimEnd([char]"`r")
        $record = $raw + "`n"
        if (-not $items) {
            if ($closed) { $null = $out.Append($record) }
            if ($line -cmatch '^## Items\s*$') { $items = $true }
            continue
        }
        if ($done) { if ($closed) { $null = $out.Append($record) }; continue }
        if ($line -cmatch '^## ') {
            if ($closed) { $null = $out.Append($blanks).Append($record) }
            $blanks = ''; $done = $true; continue
        }
        if ($line -ceq '') { $blanks = $blanks + $record; continue }
        if ($line -cmatch '^- \[[ xX-]\]') {
            $take = ($line -cmatch '^- \[[xX]\]')
            if ($take) { if ($closed) { $null = $out.Append($blanks) }; $null = $out.Append($record) }
            $blanks = ''; continue
        }
        if ($line -cmatch '^\s') {
            if ($take) { $null = $out.Append($blanks).Append($record) }
            $blanks = ''; continue
        }
        $take = $false
        if ($closed) { $null = $out.Append($blanks).Append($record) }
        $blanks = ''
    }
    if ($closed) { $null = $out.Append($blanks) }
    return $out.ToString()
}

# Add-NSArchivePunchItems <filed> <items> - <filed> with <items> added at the end of its `## Items`
# section. Mirrors _ns_archive_insert_items.
function Add-NSArchivePunchItems {
    param([AllowEmptyString()][string]$Filed, [AllowEmptyString()][string]$Items)
    $out = New-Object Text.StringBuilder
    $inItems = $false; $added = $false; $blanks = ''
    foreach ($raw in (Split-NSArchiveRecords $Filed)) {
        $line = $raw.TrimEnd([char]"`r")
        $record = $raw + "`n"
        if (-not $inItems) {
            $null = $out.Append($record)
            if ($line -cmatch '^## Items\s*$') { $inItems = $true }
            continue
        }
        if ($added) { $null = $out.Append($record); continue }
        if ($line -cmatch '^## ') {
            $null = $out.Append($Items); $added = $true
            $null = $out.Append($blanks).Append($record); $blanks = ''; continue
        }
        if ($line -ceq '') { $blanks = $blanks + $record; continue }
        $null = $out.Append($blanks).Append($record); $blanks = ''
    }
    if (-not $added) { $null = $out.Append($Items) }
    $null = $out.Append($blanks)
    return $out.ToString()
}

# Get-NSArchiveContract <text> - the text down to and including its `## Items` heading.
function Get-NSArchiveContract {
    param([AllowEmptyString()][string]$Text)
    $lines = New-Object Collections.Generic.List[string]
    foreach ($raw in (Split-NSArchiveRecords $Text)) {
        $lines.Add($raw)
        if ($raw -cmatch '^## Items\s*\r?$') { break }
    }
    return (($lines.ToArray() -join "`n").TrimEnd([char]"`n"))
}

# Get-NSArchiveReviewHeading <text> - a review file's heading, down to its `---` rule, or down to its
# first entry when it has none, without the blank lines that follow it.
function Get-NSArchiveReviewHeading {
    param([AllowEmptyString()][string]$Text)
    $head = ''; $blanks = ''
    foreach ($raw in (Split-NSArchiveRecords $Text)) {
        $line = $raw.TrimEnd([char]"`r")
        if ($line -cmatch '^--- *$') { return ($head + $blanks + $raw + "`n") }
        if ($line.StartsWith('- ', [StringComparison]::Ordinal)) { break }
        if ($line -ceq '') { $blanks = $blanks + $raw + "`n"; continue }
        $head = $head + $blanks + $raw + "`n"; $blanks = ''
    }
    return $head
}

# Test-NSArchiveSame <source> <filed> [<group> <ns>] - true when the filed copy is this record: the
# same bytes, or, given its archive folder, the source with its links repointed for the archive.
function Test-NSArchiveSame {
    param(
        [Parameter(Mandatory = $true)][string]$Source, [Parameter(Mandatory = $true)][string]$Filed,
        [string]$Group = '', [string]$Ns = ''
    )
    if (-not (Test-Path -LiteralPath $Source -PathType Leaf) -or -not (Test-Path -LiteralPath $Filed -PathType Leaf)) { return $false }
    if (Test-NSSameFileBytes $Source $Filed) { return $true }
    if ([string]::IsNullOrEmpty($Group) -or [string]::IsNullOrEmpty($Ns)) { return $false }
    try {
        $view = Get-NSArchiveRelocated ([IO.File]::ReadAllText($Source)) $Filed $Group $Ns
    }
    catch { return $false }
    return ($view -ceq [IO.File]::ReadAllText($Filed))
}

# Test-NSSameFileBytes <a> <b> - true when both files hold exactly the same bytes.
function Test-NSSameFileBytes {
    param([Parameter(Mandatory = $true)][string]$A, [Parameter(Mandatory = $true)][string]$B)
    $left = [IO.File]::ReadAllBytes($A)
    $right = [IO.File]::ReadAllBytes($B)
    if ($left.Length -ne $right.Length) { return $false }
    for ($i = 0; $i -lt $left.Length; $i++) {
        if ($left[$i] -ne $right[$i]) { return $false }
    }
    return $true
}

# Save-NSArchivePunchList <workspace> <folder> <shift-id> <date> - file the ended shift's ticked
# items into its folder, at the path the list has live, then take them out of the live list. The
# filed list is the contract and the ticked items; open items stay live, and only there. A later
# filing of the same shift adds the items ticked since. Returns Status 0 (Path '' when no item is
# ticked), 2 when it could not write (Reason says why), or 3 when a list with a different contract
# is already filed there; the live list is then left as it is. Mirrors ns_archive_punch_list.
function Save-NSArchivePunchList {
    param(
        [Parameter(Mandatory = $true)][string]$Workspace, [Parameter(Mandatory = $true)][string]$Folder,
        [AllowEmptyString()][string]$ShiftId = '', [Parameter(Mandatory = $true)][string]$Date
    )
    $ns = Join-Path $Workspace '.nightshift'
    $live = Get-NSLayoutPath $ns 'punch-list'
    $none = [pscustomobject]@{ Status = 0; Path = ''; Reason = '' }
    if (-not (Test-Path -LiteralPath $live -PathType Leaf) -or (Test-NSReparsePoint $live)) { return $none }
    $section = @(Get-NSPunchItemsSection $live)
    $ticked = @($section | Where-Object { $_ -cmatch '^- \[[xX]\]' }).Count
    if ($ticked -eq 0) { return $none }
    $dest = Join-NSPath $Folder ((Get-NSLayoutRelativePath $ns 'punch-list').Replace('/', [IO.Path]::DirectorySeparatorChar))
    if (-not (Test-NSArchiveDest $dest)) { return [pscustomobject]@{ Status = 2; Path = ''; Reason = 'a link or a directory is in the way' } }
    try {
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $dest) -Force -ErrorAction Stop
        $utf8 = New-Object Text.UTF8Encoding($false)
        $liveText = [IO.File]::ReadAllText($live)
        # The ticked items as they read from where they are filed: the check that they all landed.
        $chunk = Get-NSArchiveRelocated (Get-NSArchivePunchItems 'ticked' $liveText) $dest $Folder $ns
        $view = Get-NSArchiveRelocated (Get-NSArchivePunchItems 'closed' $liveText) $dest $Folder $ns
        if (Test-Path -LiteralPath $dest -PathType Leaf) {
            $filedText = [IO.File]::ReadAllText($dest)
            # Only this shift's list takes more items: the contract filed there must be the live one.
            if ((Get-NSArchiveContract $view) -cne (Get-NSArchiveContract $filedText)) {
                return [pscustomobject]@{ Status = 3; Path = ''; Reason = '' }
            }
            $missing = Get-NSArchiveMissingBlocks $filedText $chunk
            if ($missing -ne '') { [IO.File]::WriteAllText($dest, (Add-NSArchivePunchItems $filedText $missing), $utf8) }
        }
        else {
            [IO.File]::WriteAllText($dest, $view, $utf8)
        }
        # Nothing leaves the live list until every ticked item reads back from the filed one.
        if ((Get-NSArchiveMissingBlocks ([IO.File]::ReadAllText($dest)) $chunk) -ne '') {
            return [pscustomobject]@{ Status = 2; Path = ''; Reason = 'the filed list does not hold every ticked item' }
        }
        if ($ticked -gt 0) {
            $text = [IO.File]::ReadAllText($live)
            # Each line as awk reads it: its text, with a CR it carries, and always written back with LF.
            $lines = New-Object Collections.Generic.List[string]
            foreach ($piece in [regex]::Split($text, '(?<=\n)')) {
                if ($piece.Length -eq 0) { continue }
                $lines.Add($piece.TrimEnd([char]"`n"))
            }
            $rest = New-Object Text.StringBuilder
            $items = $false; $done = $false; $drop = $false
            $restBlanks = New-Object Text.StringBuilder
            foreach ($raw in $lines) {
                $line = $raw.TrimEnd([char]"`r")
                $out = $raw + "`n"
                if (-not $items) {
                    $null = $rest.Append($out)
                    if ($line -cmatch '^## Items[ \t]*$') { $items = $true }
                    continue
                }
                if ($done) { $null = $rest.Append($out); continue }
                if ($line -cmatch '^## ') {
                    $done = $true
                    $null = $rest.Append($restBlanks.ToString()).Append($out)
                    $null = $restBlanks.Clear()
                    continue
                }
                if ($line.Length -eq 0) { $null = $restBlanks.Append($out); continue }
                if ($line -cmatch '^- \[[xX]\]') {
                    $drop = $true
                    $null = $restBlanks.Clear()
                    continue
                }
                if ($line -cmatch '^[ \t]') {
                    if (-not $drop) { $null = $rest.Append($restBlanks.ToString()).Append($out) }
                    $null = $restBlanks.Clear()
                    continue
                }
                $drop = $false
                $null = $rest.Append($restBlanks.ToString()).Append($out)
                $null = $restBlanks.Clear()
            }
            if (-not $drop) { $null = $rest.Append($restBlanks.ToString()) }
            $tmpLive = $live + '.tmp.' + [guid]::NewGuid().ToString('N')
            [IO.File]::WriteAllText($tmpLive, $rest.ToString(), $utf8)
            Move-Item -LiteralPath $tmpLive -Destination $live -Force
        }
    }
    catch {
        return [pscustomobject]@{ Status = 2; Path = ''; Reason = $_.Exception.Message }
    }
    return [pscustomobject]@{ Status = 0; Path = $dest; Reason = '' }
}

# Save-NSArchiveJournal <workspace> <folder> - move the shift log into the folder at the path it has
# live and start the live one again under the same heading. A journal already filed there keeps
# every line and gains the ones written since, so a shift filed twice loses nothing. Returns the
# filed path, or '' when the log holds no line past its heading. Throws when it cannot write.
# Mirrors ns_archive_file_journal.
function Save-NSArchiveJournal {
    param([Parameter(Mandatory = $true)][string]$Workspace, [Parameter(Mandatory = $true)][string]$Folder)
    $ns = Join-Path $Workspace '.nightshift'
    $live = Get-NSLayoutPath $ns 'shift-log'
    if (-not (Test-Path -LiteralPath $live -PathType Leaf) -or (Test-NSReparsePoint $live)) { return '' }
    $lines = @([IO.File]::ReadAllLines($live))
    $head = '# Shift Log'
    if ($lines.Count -gt 0 -and $lines[0].TrimEnd([char]"`r").StartsWith('# ', [StringComparison]::Ordinal)) {
        $head = $lines[0].TrimEnd([char]"`r")
    }
    $body = New-Object Collections.Generic.List[string]
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($i -eq 0 -and $lines[0] -ceq $head) { continue }
        $body.Add($lines[$i])
    }
    if (@($body | Where-Object { $_ -cmatch '[^ \t]' }).Count -eq 0) { return '' }
    $dest = Join-NSPath $Folder ((Get-NSLayoutRelativePath $ns 'shift-log').Replace('/', [IO.Path]::DirectorySeparatorChar))
    if (-not (Test-NSArchiveDest $dest)) { throw "refuse to write through $dest" }
    $null = New-Item -ItemType Directory -Path (Split-Path -Parent $dest) -Force -ErrorAction Stop
    $utf8 = New-Object Text.UTF8Encoding($false)
    if (Test-Path -LiteralPath $dest -PathType Leaf) {
        [IO.File]::AppendAllText($dest, (($body -join "`n") + "`n"), $utf8)
    }
    else {
        Copy-Item -LiteralPath $live -Destination $dest -Force -ErrorAction Stop
    }
    [IO.File]::WriteAllText($live, $head + "`n", $utf8)
    return $dest
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

# The dispositions Archive files. An inbox entry that carries one after a middle-dot separator
# is closed; one without is open and waits for the owner. The morning receipt reads the
# same list, the parking-lot and snag-log templates name it, and lib/state.sh
# NS_REVIEW_DISPOSITIONS is the POSIX copy.
$script:NSReviewDispositions = 'fixed|ignored|answered|rejected-because|accepted-tradeoff'

# The words that close a plan-record entry. Mirrors NS_PLAN_RECORD_CLOSED in lib/plan-room.sh.
$script:NSPlanRecordClosed = 'captured|dropped'

function Test-NSReviewHandled {
    param([AllowEmptyString()][string]$Text, [string]$Dispositions = $script:NSReviewDispositions)
    if ([string]::IsNullOrEmpty($Text)) { return $false }
    return [bool]($Text -imatch (' \u00B7 (' + $Dispositions + ')'))
}

# Get-NSInboxBlocks <lines> - a parking lot or snag log read entry by entry, the way
# lib/inbox-entries.awk reads it. An entry is a top-level `- ` bullet with its wrapped lines, its
# indented lines and any Default: or Rollback: line, blank lines between them included; an
# unindented line after a blank line ends it, and so does a heading, a `---` rule, a Filed:
# pointer or the (empty) placeholder. Any other text is a paragraph, which Archive never files.
# Each block is Kind entry, paragraph or line, the 1-based number of its first line, and its
# lines as written.
function Get-NSInboxBlocks {
    param([AllowEmptyCollection()][string[]]$Lines)
    $blocks = New-Object Collections.Generic.List[object]
    $entry = $null
    $paragraph = $null
    $blank = $false
    for ($i = 0; $i -lt $Lines.Length; $i++) {
        $line = $Lines[$i]
        $text = ($line -creplace '[\x00-\x1f\x7f]', ' ').TrimEnd(' ')
        if ($text.Length -eq 0) {
            $paragraph = $null
            if ($null -ne $entry) { $entry.Lines.Add($line); $blank = $true; continue }
        }
        elseif ($text -cmatch '^--- *$' -or $text -cmatch '^#' -or $text -cmatch '^(- )?Filed:' -or
            $text -cmatch '^\(empty') {
            $entry = $null
            $paragraph = $null
        }
        elseif ($null -ne $entry -and $text -cmatch '^ *(- )?(\*\*)?(Default|Rollback):') {
            $entry.Lines.Add($line)
            $blank = $false
            continue
        }
        elseif ($text.StartsWith('- ', [StringComparison]::Ordinal)) {
            $entry = [pscustomobject]@{ Kind = 'entry'; Line = $i + 1; Lines = (New-Object Collections.Generic.List[string]) }
            $entry.Lines.Add($line)
            $blocks.Add($entry)
            $paragraph = $null
            $blank = $false
            continue
        }
        elseif ($null -ne $entry -and (-not $blank -or $text.StartsWith(' ', [StringComparison]::Ordinal))) {
            $entry.Lines.Add($line)
            $blank = $false
            continue
        }
        else {
            $entry = $null
            $blank = $false
            if ($null -eq $paragraph) {
                $paragraph = [pscustomobject]@{ Kind = 'paragraph'; Line = $i + 1; Lines = (New-Object Collections.Generic.List[string]) }
                $blocks.Add($paragraph)
            }
            $paragraph.Lines.Add($line)
            continue
        }
        $single = [pscustomobject]@{ Kind = 'line'; Line = $i + 1; Lines = (New-Object Collections.Generic.List[string]) }
        $single.Lines.Add($line)
        $blocks.Add($single)
    }
    return , $blocks.ToArray()
}

# Get-NSInboxStrays <path> - the first line of each paragraph below the first `---` rule of a
# parking lot or snag log, or anywhere in a file that has none: text that is not a `- ` bullet,
# which Archive never files. Each is Line and Text.
function Get-NSInboxStrays {
    param([Parameter(Mandatory = $true)][string]$Path)
    $strays = New-Object Collections.Generic.List[object]
    if ((Test-NSReparsePoint $Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return , $strays.ToArray() }
    $lines = [IO.File]::ReadAllLines($Path, $script:NSUtf8NoBom)
    $rule = 0
    for ($i = 0; $i -lt $lines.Length; $i++) {
        if ((($lines[$i] -creplace '[\x00-\x1f\x7f]', ' ').TrimEnd(' ')) -cmatch '^--- *$') { $rule = $i + 1; break }
    }
    foreach ($block in (Get-NSInboxBlocks $lines)) {
        if ($block.Kind -cne 'paragraph' -or $block.Line -le $rule) { continue }
        $text = ($block.Lines[0] -creplace '[\x00-\x1f\x7f]', ' ').TrimEnd(' ')
        $strays.Add([pscustomobject]@{ Line = $block.Line; Text = $text })
    }
    return , $strays.ToArray()
}

# Get-NSArchiveReviewLabel <folder-name> <shift-id> <layout> - what a Filed pointer is labelled: the
# shift id in the shift layout, the folder's own name otherwise (`2026-09-09`, `2026-09-09-shift-2`,
# `2026-09-09-archive-follow-ups`), so two shifts on one day are told apart.
function Get-NSArchiveReviewLabel {
    param([string]$Date, [AllowEmptyString()][string]$ShiftId, [AllowEmptyString()][string]$Layout)
    if ($Layout -ceq 'shift' -and -not [string]::IsNullOrEmpty($ShiftId) -and $ShiftId -cne 'unknown') {
        return $ShiftId
    }
    return $Date
}

function Get-NSArchivePointerLine {
    param([Parameter(Mandatory = $true)][string]$Label, [Parameter(Mandatory = $true)][string]$RelPath)
    return ('Filed: [' + $Label + '](' + $RelPath + ')')
}

# Save-NSArchiveReviewSource <workspace> <parking-lot|snag-log|plan-record> <folder> <label> - file the handled
# entries of the live review file into the shift's folder, at the path it has live, then take them
# out of the live file and leave one pointer to the filed copy, written relative to the live file.
# Entries still open stay live, and only there: they wait for the owner. A file with no handled
# entry files nothing. A later filing of the same shift adds the entries handled since. Returns 0;
# throws when filing fails. Mirrors ns_archive_file_review_source.
function Save-NSArchiveReviewSource {
    param(
        [Parameter(Mandatory = $true)][string]$Workspace,
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][string]$Folder,
        [Parameter(Mandatory = $true)][string]$Label
    )
    $ns = Join-Path $Workspace '.nightshift'
    $live = Get-NSLayoutPath $ns $Key
    if (-not (Test-Path -LiteralPath $live -PathType Leaf) -or (Test-NSReparsePoint $live)) { return 0 }
    $lines = [IO.File]::ReadAllLines($live)
    if (@($lines | Where-Object { $_.StartsWith('- ', [StringComparison]::Ordinal) -and -not $_.StartsWith('- Filed:', [StringComparison]::Ordinal) }).Count -eq 0) { return 0 }
    $dest = Join-NSPath $Folder ((Get-NSLayoutRelativePath $ns $Key).Replace('/', [IO.Path]::DirectorySeparatorChar))
    if (-not $dest.StartsWith($ns.TrimEnd('\', '/'), [StringComparison]::OrdinalIgnoreCase)) {
        throw 'archive dest is outside .nightshift/'
    }
    if (-not (Test-NSArchiveDest $dest)) { throw 'refuse to write through a symlink archive path' }
    $dispositions = if ($Key -ceq 'plan-record') { $script:NSPlanRecordClosed } else { $script:NSReviewDispositions }
    $keep = New-Object Collections.Generic.List[string]
    $filed = New-Object Collections.Generic.List[string]
    foreach ($block in (Get-NSInboxBlocks $lines)) {
        if ($block.Kind -ceq 'entry' -and (Test-NSReviewHandled ($block.Lines -join "`n") $dispositions)) {
            $filed.AddRange($block.Lines)
        }
        else {
            $keep.AddRange($block.Lines)
        }
    }
    if ($filed.Count -eq 0) { return 0 }
    $utf8 = $script:NSUtf8NoBom
    if ($null -eq $utf8) { $utf8 = New-Object System.Text.UTF8Encoding $false }
    $filedText = ($filed.ToArray() -join "`n") + "`n"
    $null = New-Item -ItemType Directory -Path (Split-Path -Parent $dest) -Force
    # The handled entries as they read from where they are filed: the check that they all landed.
    $chunk = Get-NSArchiveRelocated $filedText $dest $Folder $ns
    if (Test-Path -LiteralPath $dest -PathType Leaf) {
        $destText = [IO.File]::ReadAllText($dest)
        $missing = Get-NSArchiveMissingBlocks $destText $chunk
        if ($missing -ne '') {
            if ($destText.Length -gt 0 -and -not $destText.EndsWith("`n", [StringComparison]::Ordinal)) { $destText = $destText + "`n" }
            [IO.File]::WriteAllText($dest, $destText + $missing, $utf8)
        }
    }
    else {
        # A first filing carries the file's heading, down to its `---` rule, above the entries.
        $first = (Get-NSArchiveReviewHeading ([IO.File]::ReadAllText($live))) + "`n" + (Get-NSArchiveMissingBlocks '' $filedText)
        [IO.File]::WriteAllText($dest, (Get-NSArchiveRelocated $first $dest $Folder $ns), $utf8)
    }
    # Nothing leaves the live file until every handled entry reads back from the filed one.
    if ((Get-NSArchiveMissingBlocks ([IO.File]::ReadAllText($dest)) $chunk) -ne '') {
        throw 'the filed copy does not hold every handled entry'
    }
    # The pointer is written relative to the file that carries it.
    $rel = ConvertTo-NSRelativeLink (Split-Path -Parent $live) $dest
    $ptr = Get-NSArchivePointerLine $Label $rel
    if (-not ($keep -contains $ptr)) {
        if ($keep.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($keep[$keep.Count - 1])) {
            $keep.Add('')
        }
        $keep.Add($ptr)
    }
    [IO.File]::WriteAllLines($live, $keep.ToArray(), $utf8)
    return 0
}

function Add-NSArchiveBrokenPointers {
    param([Parameter(Mandatory = $true)][string]$Workspace)
    $ns = Join-Path $Workspace '.nightshift'
    $snag = Get-NSLayoutPath $ns 'snag-log'
    $utf8 = $script:NSUtf8NoBom
    if ($null -eq $utf8) { $utf8 = New-Object System.Text.UTF8Encoding $false }
    foreach ($key in @('snag-log', 'parking-lot', 'plan-record')) {
        $live = Get-NSLayoutPath $ns $key
        if (-not (Test-Path -LiteralPath $live -PathType Leaf) -or (Test-NSReparsePoint $live)) { continue }
        foreach ($line in [IO.File]::ReadAllLines($live)) {
            if ($line -cnotmatch '^Filed: \[[^]]+\]\(([^)]+)\)$') { continue }
            $rel = $Matches[1]
            # A pointer is read relative to the file that carries it and must stay inside .nightshift/.
            $target = ''
            if (-not [string]::IsNullOrEmpty($rel) -and -not $rel.StartsWith('/')) {
                $target = ConvertTo-NSNormalPath ((Split-Path -Parent $live) + '/' + $rel)
                if (-not $target.StartsWith((ConvertTo-NSNormalPath $ns) + '/', [StringComparison]::OrdinalIgnoreCase)) {
                    $target = ''
                }
            }
            if ([string]::IsNullOrEmpty($target)) {
                $ok = $false
            }
            else {
                $target = $target -replace '/', [IO.Path]::DirectorySeparatorChar
                $ok = (Test-Path -LiteralPath $target -PathType Leaf) -and -not (Test-NSReparsePoint $target)
            }
            if ($ok) { continue }
            $already = $false
            if (Test-Path -LiteralPath $snag -PathType Leaf) {
                $already = [IO.File]::ReadAllText($snag).Contains(
                    ('broken archive pointer ' + $script:NSDot + ' ') + $rel + ' ')
            }
            if ($already) { continue }
            if (-not (Test-Path -LiteralPath $snag -PathType Leaf)) {
                New-NSLayoutParent $ns 'snag-log'
                [IO.File]::WriteAllText($snag, "# Snag Log$([Environment]::NewLine)$([Environment]::NewLine)", $utf8)
            }
            [IO.File]::AppendAllText($snag, (('- broken archive pointer ' + $script:NSDot + ' ') + $rel + ' is not a readable file' + [Environment]::NewLine), $utf8)
        }
    }
}

# Save-NSArchiveReviewRecords <workspace> <folder> <label> - the review files and the plan record, then
# a check of every pointer they carry. Returns 3 when either kept its handled entries live, 0 otherwise.
function Save-NSArchiveReviewRecords {
    param(
        [Parameter(Mandatory = $true)][string]$Workspace,
        [Parameter(Mandatory = $true)][string]$Folder,
        [Parameter(Mandatory = $true)][string]$Label
    )
    $status = 0
    foreach ($key in @('snag-log', 'parking-lot', 'plan-record')) {
        if ((Save-NSArchiveReviewSource $Workspace $key $Folder $Label) -eq 3) { $status = 3 }
    }
    Add-NSArchiveBrokenPointers $Workspace
    return $status
}

# Convert-NSReportLinks <text> <archived> <back> [dir] - one archived record's own links, repointed
# for where it now sits. The twin of runtime/archive-links.awk, and it must answer identically: a
# record that travelled with it is still a sibling, one that stayed live is reached back through the
# archive. A scheme, a leading slash, a bare fragment and everything inside a fenced code block
# are left exactly as written. Dir is the record's own directory before the move, relative to the
# state directory, and every relative link resolves against it: a bare `name` or `./name` names a
# file that sat right beside the record, and a link that climbs with ../ climbed from there.
function Convert-NSReportLinks {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Archived,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Back,
        [AllowEmptyString()][string]$Dir = ''
    )
    $moved = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($entry in $Archived) {
        if (-not [string]::IsNullOrEmpty($entry)) { $null = $moved.Add($entry) }
    }
    $prefix = $Back
    if (-not [string]::IsNullOrEmpty($prefix) -and -not $prefix.EndsWith('/', [StringComparison]::Ordinal)) {
        $prefix = $prefix + '/'
    }
    $from = $Dir
    if (-not [string]::IsNullOrEmpty($from) -and $from.EndsWith('/', [StringComparison]::Ordinal)) {
        $from = $from.Substring(0, $from.Length - 1)
    }

    # Where a relative link points, as a path relative to the state directory. ../ that climbs out
    # of the state area is kept: back/ lands at the top of it before the climb starts.
    $resolve = {
        param([string]$path)
        $joined = if ([string]::IsNullOrEmpty($from)) { $path } else { $from + '/' + $path }
        $out = New-Object Collections.Generic.List[string]
        foreach ($segment in ($joined -split '/')) {
            if ($segment -ceq '' -or $segment -ceq '.') { continue }
            if ($segment -ceq '..' -and $out.Count -gt 0 -and $out[$out.Count - 1] -cne '..') {
                $out.RemoveAt($out.Count - 1)
                continue
            }
            $out.Add($segment)
        }
        return ($out -join '/')
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
        if ($moved.Contains($path)) { return $target }
        $rel = & $resolve $path
        if ([string]::IsNullOrEmpty($rel)) { return $target }
        # The file it names travelled here too: still a sibling, still reached exactly as written.
        if ($moved.Contains($rel)) { return $target }
        return ($prefix + $rel + $fragment)
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

# Item identity. An item's number keeps its place in the list and its id keeps its identity: a
# trailing `<!-- id: k7q2 -->` on the item's own line, given the first time the shift policy is
# recorded. The owner may renumber, reorder or retitle items between shifts; the receipt and its
# history follow the id. Every reader of an item's label goes through Get-NSItemLabel, so the
# comment is never part of a label.
$script:NSItemIdPattern = '[ \t]*<!--[ \t]*id:[ \t]*([a-z0-9]+)[ \t]*-->[ \t]*$'

function Get-NSItemId {
    param([AllowEmptyString()][string]$Line)
    $match = [regex]::Match(($Line -creplace '\r$', ''), $script:NSItemIdPattern)
    if ($match.Success) { return $match.Groups[1].Value }
    return ''
}

function Get-NSItemLabel {
    param([AllowEmptyString()][string]$Line)
    $t = $Line -creplace '\r$', ''
    $t = $t -creplace $script:NSItemIdPattern, ''
    $t = $t -creplace '^- \[[ xX-]\][ \t]*\*\*', ''
    $t = $t -creplace '^- \[[ xX-]\][ \t]*', ''
    # A dash right after a bare number numbers the item, as in "1 - Fix it": a number alone is no
    # label, so only a later dash ends the title. A code such as P03 before a dash is the label.
    $lead = ''
    $dashes = [string][char]0x2014 + [char]0x2013
    if ($t -cmatch ('^[0-9]+[ \t]*[' + $dashes + '][ \t]*') -or $t -cmatch '^[0-9]+[ \t]+-[ \t]+') {
        $lead = $Matches[0]
        $t = $t.Substring($lead.Length)
    }
    $t = $t -creplace ('[ \t]+(' + [char]0x2014 + '|-[ \t]).*$'), ''
    $t = $t -creplace '\*\*.*$', ''
    return ($lead + $t).TrimEnd()
}

# Get-NSItemRows <punch-list> [open|ticked|stopped|all] - Label, Id, Open and State for each top-level
# item under `## Items` that has a label, list order. Id is '' for an item that has none. A ticked item
# is `[x]`; a stopped one, closed at its hard budget without being done, is `[-]`. Mirrors ns_item_rows.
function Get-NSItemRows {
    param(
        [Parameter(Mandatory = $true)][string]$PunchList,
        [ValidateSet('open', 'ticked', 'stopped', 'all')][string]$State = 'all'
    )
    $rows = New-Object Collections.Generic.List[object]
    if (-not (Test-Path -LiteralPath $PunchList -PathType Leaf) -or (Test-NSReparsePoint $PunchList)) {
        return , $rows.ToArray()
    }
    foreach ($line in (Get-NSPunchItemsSection $PunchList)) {
        if ($line -cnotmatch '^- \[[ xX-]\]') { continue }
        $open = $line -cmatch '^- \[ \]'
        $rowState = $(if ($open) { 'open' } elseif ($line -cmatch '^- \[-\]') { 'stopped' } else { 'ticked' })
        if ($State -cne 'all' -and $State -cne $rowState) { continue }
        $label = Get-NSItemLabel $line
        if ([string]::IsNullOrEmpty($label)) { continue }
        $rows.Add([pscustomobject]@{ Label = $label; Id = (Get-NSItemId $line); Open = $open; State = $rowState })
    }
    return , $rows.ToArray()
}

# Get-NSItemTitleFor <punch-list> <id> - the whole title of the item carrying that id: its bold
# text, or the line after its checkbox, without the id comment. '' when no item carries it.
function Get-NSItemTitleFor {
    param([Parameter(Mandatory = $true)][string]$PunchList, [Parameter(Mandatory = $true)][string]$Id)
    if (-not (Test-Path -LiteralPath $PunchList -PathType Leaf) -or (Test-NSReparsePoint $PunchList)) { return '' }
    foreach ($line in (Get-NSPunchItemsSection $PunchList)) {
        if ($line -cnotmatch '^- \[[ xX-]\]' -or (Get-NSItemId $line) -cne $Id) { continue }
        $t = $line -creplace '\r$', ''
        $t = $t -creplace $script:NSItemIdPattern, ''
        if ($t -cmatch '^- \[[ xX-]\][ \t]*\*\*') {
            $t = $t -creplace '^- \[[ xX-]\][ \t]*\*\*', ''
            $t = $t -creplace '\*\*.*$', ''
        }
        else {
            $t = $t -creplace '^- \[[ xX-]\][ \t]*', ''
        }
        return $t.TrimEnd()
    }
    return ''
}

# Get-NSItemIdFor <punch-list> <label> - the id of the first item with that label, or ''.
function Get-NSItemIdFor {
    param([Parameter(Mandatory = $true)][string]$PunchList, [AllowEmptyString()][string]$Label)
    foreach ($row in (Get-NSItemRows $PunchList)) {
        if ($row.Label -ceq $Label) { return $row.Id }
    }
    return ''
}

# Test-NSItemIdUsed <nightshift-dir> <id> [taken] - true when the id is in taken, is carried by an
# archived list or receipt, or already names a receipt file, so an id means one item for as long
# as the history is kept.
function Test-NSItemIdUsed {
    param([Parameter(Mandatory = $true)][string]$NightshiftDir, [Parameter(Mandatory = $true)][string]$Id,
          [string[]]$Taken = @())
    if ($Taken -ccontains $Id) { return $true }
    foreach ($dir in @((Get-NSLayoutPath $NightshiftDir 'receipts'), (Get-NSLayoutPath $NightshiftDir 'archive'))) {
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) { continue }
        foreach ($file in (Get-ChildItem -LiteralPath $dir -File -Recurse -Force -ErrorAction SilentlyContinue)) {
            if ($file.Name -ceq ($Id + '.md') -or
                $file.Name.EndsWith('-' + $Id + '.md', [StringComparison]::Ordinal) -or
                ($file.Name.StartsWith($Id + '-', [StringComparison]::Ordinal) -and
                    $file.Name.EndsWith('.md', [StringComparison]::Ordinal))) { return $true }
            if ([IO.File]::ReadAllText($file.FullName).Contains('id: ' + $Id + ' ')) { return $true }
        }
    }
    return $false
}

# New-NSItemId <nightshift-dir> [taken] - a fresh id: a letter, then three letters or digits, that
# Test-NSItemIdUsed does not know.
function New-NSItemId {
    param([Parameter(Mandatory = $true)][string]$NightshiftDir, [string[]]$Taken = @())
    $letters = 'abcdefghijklmnopqrstuvwxyz'
    $alphabet = $letters + '0123456789'
    $bytes = New-Object byte[] 4
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        for ($try = 0; $try -lt 64; $try++) {
            $rng.GetBytes($bytes)
            $id = [string]$letters[$bytes[0] % 26] + $alphabet[$bytes[1] % 36] + $alphabet[$bytes[2] % 36] + $alphabet[$bytes[3] % 36]
            if (-not (Test-NSItemIdUsed $NightshiftDir $id $Taken)) { return $id }
        }
    }
    finally {
        $rng.Dispose()
    }
    return ''
}

# Add-NSPunchItemIds <punch-list> <nightshift-dir> - give every item under `## Items` that has no
# id a new one, keeping each line's own ending. Items that carry one keep it, so running this again
# changes nothing. Returns $false when the list could not be rewritten.
function Add-NSPunchItemIds {
    param([Parameter(Mandatory = $true)][string]$PunchList, [Parameter(Mandatory = $true)][string]$NightshiftDir)
    if (-not (Test-Path -LiteralPath $PunchList -PathType Leaf) -or (Test-NSReparsePoint $PunchList)) { return $true }
    $text = [IO.File]::ReadAllText($PunchList)
    $pieces = [regex]::Split($text, '(?<=\n)')
    $taken = New-Object Collections.Generic.List[string]
    foreach ($row in (Get-NSItemRows $PunchList)) { if ($row.Id) { $taken.Add($row.Id) } }
    $out = New-Object Text.StringBuilder
    $on = $false
    $done = $false
    $changed = $false
    foreach ($piece in $pieces) {
        $ending = ''
        $line = $piece
        if ($line.EndsWith("`r`n", [StringComparison]::Ordinal)) { $ending = "`r`n"; $line = $line.Substring(0, $line.Length - 2) }
        elseif ($line.EndsWith("`n", [StringComparison]::Ordinal)) { $ending = "`n"; $line = $line.Substring(0, $line.Length - 1) }
        if (-not $on) {
            if ($line -cmatch '^##[ \t]*Items[ \t]*$') { $on = $true }
        }
        elseif (-not $done -and $line -cmatch '^## ') { $done = $true }
        elseif (-not $done -and $line -cmatch '^- \[[ xX-]\]' -and [string]::IsNullOrEmpty((Get-NSItemId $line))) {
            $id = New-NSItemId $NightshiftDir $taken.ToArray()
            if ([string]::IsNullOrEmpty($id)) { return $false }
            $taken.Add($id)
            $line = $line + ' <!-- id: ' + $id + ' -->'
            $changed = $true
        }
        $null = $out.Append($line).Append($ending)
    }
    if (-not $changed) { return $true }
    $tmp = $PunchList + '.ids.' + [guid]::NewGuid().ToString('N')
    try {
        [IO.File]::WriteAllText($tmp, $out.ToString(), (New-Object Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $tmp -Destination $PunchList -Force
    }
    catch {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        return $false
    }
    return $true
}

function Get-NSReceiptNn {
    param([AllowEmptyString()][string]$Label)
    if ($Label -cmatch '^([0-9]+)') { return $Matches[1] }
    if ($Label -cmatch '^([A-Za-z]+[0-9]+)') { return $Matches[1] }
    return ''
}

# Get-NSReceiptTitle <label> - the words after the written number, for the slug. The number may be
# followed by `.`, `)`, `:`, an em or en dash, or a hyphen with space around it.
function Get-NSReceiptTitle {
    param([AllowEmptyString()][string]$Label)
    $t = $Label
    if ($t -cmatch '^[0-9]+[.):]') {
        $t = $t -creplace '^[0-9]+[.):][ \t]*', ''
    }
    elseif ($t -cmatch ('^[0-9]+[ \t]*[' + [char]0x2014 + [char]0x2013 + ']')) {
        $t = $t -creplace ('^[0-9]+[ \t]*[' + [char]0x2014 + [char]0x2013 + '][ \t]*'), ''
    }
    else {
        $t = $t -creplace '^[0-9]+[ \t]+-[ \t]+', ''
    }
    $t = $t -creplace '^[A-Za-z]+[0-9]+[ \t]+', ''
    return $t
}

function Get-NSReceiptBasename {
    param([AllowEmptyString()][string]$Label)
    $Label = $Label -creplace '^- \[[xX -]\][ \t]*', ''
    $Label = $Label -creplace '^\*\*', ''
    $Label = $Label -creplace '\*\*$', ''
    $nn = Get-NSReceiptNn $Label
    $title = Get-NSReceiptTitle $Label
    if ([string]::IsNullOrEmpty($title)) { $title = $Label }
    if (-not [string]::IsNullOrEmpty($nn) -and $title -ceq $Label) { return $nn }
    $slug = Get-NSReceiptSlug $title
    if (-not [string]::IsNullOrEmpty($nn) -and -not [string]::IsNullOrEmpty($slug)) {
        return ($nn + '-' + $slug)
    }
    if (-not [string]::IsNullOrEmpty($slug)) { return $slug }
    return (Get-NSReceiptSlug $Label)
}

# Get-NSReceiptWant <workspace> <label> <id> - the name an item's receipt carries: its number, two
# digits at least, or its place in the list when the title has none; then its title; then its id.
# `03-fix-the-resolver-k7q2`. A label that is only a code, such as P03, takes the words of the
# item's whole title.
function Get-NSReceiptWant {
    param(
        [Parameter(Mandatory = $true)][string]$Workspace,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Label,
        [Parameter(Mandatory = $true)][string]$Id
    )
    $punch = Get-NSLayoutPath (Join-Path $Workspace '.nightshift') 'punch-list'
    $nn = Get-NSReceiptNn $Label
    $title = Get-NSReceiptTitle $Label
    if (-not [string]::IsNullOrEmpty($nn) -and $title -ceq $Label) {
        $full = Get-NSItemTitleFor $punch $Id
        $title = Get-NSReceiptTitle $full
        if ($title -ceq $full) { $title = '' }
    }
    if ([string]::IsNullOrEmpty($nn)) {
        $position = 0
        foreach ($row in (Get-NSItemRows $punch)) {
            $position++
            if ($row.Label -ceq $Label) { $nn = [string]$position; break }
        }
    }
    if ($nn -cmatch '^[0-9]+$') { $nn = ([decimal]::Parse($nn, [Globalization.CultureInfo]::InvariantCulture)).ToString('00', [Globalization.CultureInfo]::InvariantCulture) }
    $parts = New-Object Collections.Generic.List[string]
    if (-not [string]::IsNullOrEmpty($nn)) { $parts.Add($nn) }
    $slug = Get-NSReceiptSlug $title
    if (-not [string]::IsNullOrEmpty($slug)) { $parts.Add($slug) }
    $parts.Add($Id)
    return ($parts -join '-')
}

# Find-NSReceiptName <names> <id> - of the receipt file names given, the one an id already names:
# `<NN>-<slug>-<id>.md`, or the `<id>.md` and `<id>-<slug>.md` names earlier versions gave it, in
# that order and ordinal within each. '' when there is none.
function Find-NSReceiptName {
    param([AllowEmptyCollection()][string[]]$Names = @(), [Parameter(Mandatory = $true)][string]$Id)
    $sorted = [string[]]@($Names)
    [Array]::Sort($sorted, [StringComparer]::Ordinal)
    foreach ($name in $sorted) {
        if ($name.EndsWith('-' + $Id + '.md', [StringComparison]::Ordinal)) { return $name }
    }
    if ($sorted -ccontains ($Id + '.md')) { return ($Id + '.md') }
    foreach ($name in $sorted) {
        if ($name.StartsWith($Id + '-', [StringComparison]::Ordinal) -and
            $name.EndsWith('.md', [StringComparison]::Ordinal)) { return $name }
    }
    return ''
}

# Get-NSReceiptFileNames <dir> - the regular .md files in a receipts folder, reparse points left out.
function Get-NSReceiptFileNames {
    param([Parameter(Mandatory = $true)][string]$Dir)
    if (-not (Test-Path -LiteralPath $Dir -PathType Container)) { return , [string[]]@() }
    return , [string[]]@(Get-ChildItem -LiteralPath $Dir -File -Force -ErrorAction SilentlyContinue |
        Where-Object {
            -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -and
            $_.Name.EndsWith('.md', [StringComparison]::Ordinal)
        } | ForEach-Object { $_.Name })
}

# Get-NSReceiptLegacyName <dir> <label> - a receipt named by label before items had ids:
# `NN-slug.md`, or the bare `NN.md` a dash-numbered title was once cut down to. '' when neither is
# there.
function Get-NSReceiptLegacyName {
    param([Parameter(Mandatory = $true)][string]$Dir, [AllowEmptyString()][string]$Label)
    foreach ($name in @(((Get-NSReceiptBasename $Label) + '.md'), ((Get-NSReceiptNn $Label) + '.md'))) {
        if ($name -ceq '.md') { continue }
        $path = Join-Path $Dir $name
        if ((Test-Path -LiteralPath $path -PathType Leaf) -and -not (Test-NSReparsePoint $path)) { return $name }
    }
    return ''
}

# Get-NSReceiptBase <workspace> <label> [id] - the item's receipt file stem under receipts/. An item
# with an id keeps the file that id already names, else an earlier shift's receipt found by its
# label, else a new `<NN>-<slug>-<id>`; an item without one is its label's `NN-slug`. With no -Id
# the id is looked up in the punch list by label. Reading a name never renames anything:
# Rename-NSReceipts moves a receipt to the name its item carries now.
function Get-NSReceiptBase {
    param(
        [Parameter(Mandatory = $true)][string]$Workspace,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Label,
        [AllowEmptyString()][string]$Id = ''
    )
    if (-not $PSBoundParameters.ContainsKey('Id')) {
        $Id = Get-NSItemIdFor (Get-NSLayoutPath (Join-Path $Workspace '.nightshift') 'punch-list') $Label
    }
    $legacy = Get-NSReceiptBasename $Label
    $dir = Get-NSReceiptsDir $Workspace
    if (Test-Path -LiteralPath $dir -PathType Container) {
        $named = ''
        if (-not [string]::IsNullOrEmpty($Id)) { $named = Find-NSReceiptName (Get-NSReceiptFileNames $dir) $Id }
        if (-not $named) { $named = Get-NSReceiptLegacyName $dir $Label }
        if ($named) { return $named.Substring(0, $named.Length - 3) }
    }
    if ([string]::IsNullOrEmpty($Id)) { return $legacy }
    return (Get-NSReceiptWant $Workspace $Label $Id)
}

# Rename-NSReceipts <workspace> - move each live receipt of an item with an id to the name the item
# carries now, so a reordered, renumbered or retitled item's receipt follows it and the folder reads
# in item order. A name another file already holds is never overwritten, a receipt keeps its
# modification time, and archived receipts keep the names they were filed under. Returns $false
# when a move failed.
function Rename-NSReceipts {
    param([Parameter(Mandatory = $true)][string]$Workspace)
    $punch = Get-NSLayoutPath (Join-Path $Workspace '.nightshift') 'punch-list'
    $dir = Get-NSReceiptsDir $Workspace
    if (-not (Test-Path -LiteralPath $punch -PathType Leaf) -or -not (Test-Path -LiteralPath $dir -PathType Container) -or
        (Test-NSReparsePoint $dir)) { return $true }
    $ok = $true
    foreach ($row in (Get-NSItemRows $punch)) {
        if ([string]::IsNullOrEmpty($row.Id)) { continue }
        $name = Find-NSReceiptName (Get-NSReceiptFileNames $dir) $row.Id
        if (-not $name) { $name = Get-NSReceiptLegacyName $dir $row.Label }
        if (-not $name) { continue }
        $want = (Get-NSReceiptWant $Workspace $row.Label $row.Id) + '.md'
        if ($name -ceq $want) { continue }
        if (Test-Path -LiteralPath (Join-Path $dir $want)) { continue }
        try {
            $old = Join-Path $dir $name
            $new = Join-Path $dir $want
            if (Test-Path -LiteralPath (Get-NSReceiptSessionFile $old) -PathType Leaf) { Set-NSReceiptSessions $new (Get-NSReceiptSessionData $old) }
            [IO.File]::Move($old, $new)
            Remove-NSReceiptSessions $old
        }
        catch {
            Write-Warning ('receipts: ' + $name + ' could not take its item''s name ' + $want + ': ' + $_.Exception.Message)
            $ok = $false
        }
    }
    return $ok
}

function Get-NSReceiptPath {
    param(
        [Parameter(Mandatory = $true)][string]$Workspace,
        [Parameter(Mandatory = $true)][string]$Label,
        [AllowEmptyString()][string]$Id = ''
    )
    if ($PSBoundParameters.ContainsKey('Id')) {
        return (Join-Path (Get-NSReceiptsDir $Workspace) ((Get-NSReceiptBase $Workspace $Label $Id) + '.md'))
    }
    return (Join-Path (Get-NSReceiptsDir $Workspace) ((Get-NSReceiptBase $Workspace $Label) + '.md'))
}

# Update-NSReceiptLabel <receipt> <label> - note in the receipt which label it belongs to, and
# record a renumber or retitle once the item's label has moved since. The heading follows when it
# was the old label, and one dated line under it names what the item was called before.
#
# The runtime's writes to a receipt keep its modification time: the time says when the model last
# wrote it, which is how the pulse tells which item is being worked.
function Update-NSReceiptLabel {
    param([Parameter(Mandatory = $true)][string]$Receipt, [Parameter(Mandatory = $true)][string]$Label)
    if (-not (Test-Path -LiteralPath $Receipt -PathType Leaf) -or (Test-NSReparsePoint $Receipt)) { return }
    $utf8 = New-Object Text.UTF8Encoding($false)
    $lines = @([IO.File]::ReadAllLines($Receipt))
    $was = ''
    foreach ($line in $lines) {
        if ($line -cmatch '^<!-- item: (.*) -->[ \t]*$') { $was = $Matches[1] }
    }
    if ($was -ceq $Label) { return }
    $stamp = [IO.File]::GetLastWriteTimeUtc($Receipt)
    if ([string]::IsNullOrEmpty($was)) {
        [IO.File]::AppendAllText($Receipt, "`n<!-- item: $Label -->`n", $utf8)
        [IO.File]::SetLastWriteTimeUtc($Receipt, $stamp)
        return
    }
    $out = New-Object Collections.Generic.List[string]
    $headed = $false
    foreach ($line in $lines) {
        if (-not $headed -and $line -cmatch '^# ') {
            $headed = $true
            $out.Add($(if ($line -ceq ('# ' + $was)) { '# ' + $Label } else { $line }))
            $out.Add('')
            $out.Add(('Renamed from {0} on {1}.' -f $was, (Get-Date -Format 'yyyy-MM-dd')))
            continue
        }
        if ($line -cmatch '^<!-- item: .* -->[ \t]*$') { $out.Add('<!-- item: ' + $Label + ' -->'); continue }
        $out.Add($line)
    }
    [IO.File]::WriteAllText($Receipt, (($out -join "`n") + "`n"), $utf8)
    [IO.File]::SetLastWriteTimeUtc($Receipt, $stamp)
}

# ConvertTo-NSReceiptEncoded / ConvertFrom-NSReceiptEncoded <text> - a value that rides in one
# session-data field: no spaces or tabs, reversible. Mirrors ns_receipt_encode / ns_receipt_decode.
function ConvertTo-NSReceiptEncoded {
    param([AllowEmptyString()][string]$Text)
    return $Text.Replace('%', '%25').Replace(' ', '%20').Replace("`t", '%09')
}
function ConvertFrom-NSReceiptEncoded {
    param([AllowEmptyString()][string]$Text)
    return $Text.Replace('%20', ' ').Replace('%09', "`t").Replace('%25', '%')
}

# Get-NSSessionExtra <session-line> <key> - one named field after the seven positional ones, or ''.
function Get-NSSessionExtra {
    param([AllowEmptyString()][string]$Line, [Parameter(Mandatory = $true)][string]$Key)
    $f = @($Line -split '\s+' | Where-Object { $_.Length -gt 0 })
    for ($i = 7; $i -lt $f.Count; $i++) {
        if ($f[$i].StartsWith($Key + '=', [StringComparison]::Ordinal)) { return $f[$i].Substring($Key.Length + 1) }
    }
    return ''
}

# Get-NSSessionHostWords <host/model+host/model> - each host and its model joined by the middle dot,
# the hosts joined by ` + `. Mirrors ns_session_host_words.
function Get-NSSessionHostWords {
    param([AllowEmptyString()][string]$Hosts)
    $words = New-Object Collections.Generic.List[string]
    foreach ($entry in $Hosts.Split('+')) {
        if ($entry.Length -eq 0) { continue }
        $i = $entry.IndexOf('/')
        $h = $(if ($i -ge 0) { $entry.Substring(0, $i) } else { $entry })
        $m = $(if ($i -ge 0) { $entry.Substring($i + 1) } else { '' })
        $words.Add($h + $(if ($m.Length -gt 0 -and $m -cne '-') { ' ' + $script:NSDot + ' ' + $m } else { '' }))
    }
    return ($words -join ' + ')
}

function Get-NSReceiptSessionFile {
    param([Parameter(Mandatory = $true)][string]$Receipt)
    $ns = Split-Path -Parent (Split-Path -Parent $Receipt)
    if ((Split-Path -Leaf $ns) -cne '.nightshift') { return '' }
    return (Join-Path (Get-NSLayoutPath $ns 'item-sessions') ((Split-Path -Leaf $Receipt) + '.tsv'))
}

# Get-NSReceiptSessionData <receipt> - ledger rows, or an older receipt's first runtime section.
function Get-NSReceiptSessionData {
    param([AllowEmptyString()][string]$Receipt)
    $data = New-Object Collections.Generic.List[string]
    if ([string]::IsNullOrEmpty($Receipt)) { return , $data.ToArray() }
    $file = Get-NSReceiptSessionFile $Receipt
    if ($file.Length -gt 0) {
        $dir = Split-Path -Parent $file
        if ((Test-NSReparsePoint $file) -or (Test-NSReparsePoint $dir) -or (Test-NSReparsePoint (Split-Path -Parent $dir))) { throw 'receipt session ledger is a link' }
        if (Test-Path -LiteralPath $file -PathType Leaf) { return , [IO.File]::ReadAllLines($file) }
    }
    if (-not (Test-Path -LiteralPath $Receipt -PathType Leaf) -or (Test-NSReparsePoint $Receipt)) { return , $data.ToArray() }
    $on = $false; $usage = $false; $seen = $false
    foreach ($line in [IO.File]::ReadAllLines($Receipt)) {
        if ($line -ceq '<!-- usage -->') {
            if ($seen) { break }
            $usage = $true; $seen = $true; continue
        }
        if ($usage -and $line -ceq '<!-- /usage -->') { break }
        if ($usage -and $line -ceq '<!-- session-data') { $on = $true; continue }
        if ($on -and $line -ceq '-->') { break }
        if ($on -and $line.Trim().Length -gt 0) { $data.Add($line) }
    }
    return , $data.ToArray()
}

function Set-NSReceiptSessions {
    param([string]$Receipt, [string[]]$Rows)
    $file = Get-NSReceiptSessionFile $Receipt
    if ($file.Length -eq 0) { return }
    $dir = Split-Path -Parent $file
    if ((Test-NSReparsePoint $file) -or (Test-NSReparsePoint $dir) -or (Test-NSReparsePoint (Split-Path -Parent $dir))) { throw 'receipt session ledger is a link' }
    $null = New-Item -ItemType Directory -Path $dir -Force
    $tmp = Join-Path $dir ('.sessions.' + [guid]::NewGuid().ToString('N'))
    try {
        [IO.File]::WriteAllText($tmp, (($Rows -join "`n") + "`n"), (New-Object Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $tmp -Destination $file -Force
    }
    finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
}

function Remove-NSReceiptSessions {
    param([string]$Receipt)
    $file = Get-NSReceiptSessionFile $Receipt
    if ($file.Length -eq 0) { return }
    $dir = Split-Path -Parent $file
    if ((Test-NSReparsePoint $dir) -or (Test-NSReparsePoint (Split-Path -Parent $dir))) { throw 'receipt session ledger is a link' }
    Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
}

# Get-NSReceiptProgressNote <receipt> - the first line of the model's own text, cut to 160 characters.
function Get-NSReceiptProgressNote {
    param([AllowEmptyString()][string]$Receipt)
    foreach ($line in (Get-NSReceiptModelLines $Receipt)) {
        if ($line.StartsWith('#') -or $line.Trim().Length -eq 0) { continue }
        return $line.Substring(0, [math]::Min(160, $line.Length))
    }
    return ''
}

# ConvertFrom-NSIsoMinute <YYYY-MM-DDTHH:MMZ> - that UTC minute as epoch seconds, or ''.
function ConvertFrom-NSIsoMinute {
    param([AllowEmptyString()][string]$Text)
    if ($Text -cnotmatch '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}Z$') { return '' }
    $at = [DateTime]::ParseExact($Text, 'yyyy-MM-ddTHH:mmZ', [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal)
    $utc = New-Object DateTime 1970, 1, 1, 0, 0, 0, ([DateTimeKind]::Utc)
    return [string][long]($at - $utc).TotalSeconds
}

# Get-NSReceiptLegacyBlocks <receipt> - the stacked usage blocks an older receipt carries, the ones
# that count, oldest first: a newer block whose span holds an older one already counts it, and a
# block with no span counts only when it is the newest. Each is a hashtable of the fields
# receipt-legacy.awk prints. Mirrors ns_receipt_legacy_blocks.
function Get-NSReceiptLegacyBlocks {
    param([AllowEmptyString()][string]$Receipt)
    $blocks = New-Object Collections.Generic.List[object]
    if ([string]::IsNullOrEmpty($Receipt) -or -not (Test-Path -LiteralPath $Receipt -PathType Leaf) -or
        (Test-NSReparsePoint $Receipt)) { return , @() }
    $inside = $false
    $cur = $null
    foreach ($raw in [IO.File]::ReadAllLines($Receipt)) {
        $line = $raw.TrimEnd("`r")
        if ($line.StartsWith('<!-- usage -->') -or $line.StartsWith('<!-- sessions -->')) { $inside = $true; continue }
        if ($line.StartsWith('<!-- /usage -->') -or $line.StartsWith('<!-- /sessions -->')) { $inside = $false; continue }
        if ($inside) { continue }
        if ($line -ceq '| Tokens | Amount |' -or $line -ceq '**Tokens:** off') {
            $cur = @{ From = ''; To = ''; Work = ''; Pause = ''; Tok = $(if ($line -ceq '**Tokens:** off') { 'off' } else { '' })
                TimeOff = $false; Host = '' }
            $blocks.Add($cur)
            continue
        }
        if ($null -eq $cur) { continue }
        if ($line -cmatch '^<!-- tokens ([0-9 ]+?) *-->$') { $cur.Tok = $Matches[1]; continue }
        if ($line -cmatch ('^(.*) ' + [regex]::Escape($script:NSDot) + ' [0-9]+ segments?\.')) { $cur.Host = $Matches[1]; continue }
        if ($line -ceq '**Time:** off') { $cur.TimeOff = $true; continue }
        if ($line -cmatch '^\| working \| *(.*?) *\|$') { $cur.Work = $Matches[1]; continue }
        if ($line -cmatch '^\| paused \| *([^|(]*?) *(\(.*)?\|$') { $cur.Pause = $Matches[1].Trim(); continue }
        if ($line -cmatch ('^\| span \| *(.*?) ' + [char]0x2192 + ' (.*?) *\|$')) { $cur.From = $Matches[1]; $cur.To = $Matches[2]; continue }
    }
    $counted = New-Object Collections.Generic.List[object]
    for ($i = $blocks.Count - 1; $i -ge 0; $i--) {
        $b = $blocks[$i]
        if ($b.Tok.Length -eq 0 -and -not $b.TimeOff -and $b.Work.Length -eq 0) { continue }
        $keep = $true
        if ($b.From.Length -eq 0) {
            $keep = ($i -eq 0)
        }
        else {
            for ($j = 0; $j -lt $i; $j++) {
                $n = $blocks[$j]
                if ($n.From.Length -gt 0 -and [string]::CompareOrdinal($n.From, $b.From) -le 0 -and
                    [string]::CompareOrdinal($n.To, $b.To) -ge 0) { $keep = $false; break }
            }
        }
        if ($keep) { $counted.Add($b) }
    }
    return , $counted.ToArray()
}

# Get-NSReceiptLegacySessions <receipt> - those blocks as session lines. Mirrors
# ns_receipt_legacy_sessions.
function Get-NSReceiptLegacySessions {
    param([AllowEmptyString()][string]$Receipt)
    $rows = New-Object Collections.Generic.List[string]
    foreach ($b in (Get-NSReceiptLegacyBlocks $Receipt)) {
        $start = ConvertFrom-NSIsoMinute $b.From
        $end = ConvertFrom-NSIsoMinute $b.To
        if ($b.TimeOff) { $work = 'off'; $paused = 'off' }
        else {
            $work = $(if ($b.Work.Length -gt 0) { [string](Get-NSUsageParseSeconds $b.Work) } else { '-' })
            $paused = [string](Get-NSUsageParseSeconds $b.Pause)
        }
        if ($b.Tok -ceq 'off') { $t = @('off', 'off', 'off', 'off', 'off') }
        elseif ($b.Tok.Length -eq 0) { $t = @('-', '-', '-', '-', '-') }
        else { $t = @($b.Tok.Trim() -split '\s+') }
        $extras = 'cw={0} cr={1} rea={2} paused={3}' -f $t[1], $t[2], $t[4], $paused
        if ($b.Host.Length -gt 0) { $extras += ' host=' + $b.Host.Replace('; ', '+').Replace(' ', '/') }
        $rows.Add(('- {0} {1} {2} {3} {4} ticked {5}' -f $(if ($start) { $start } else { '-' }),
                $(if ($end) { $end } else { '-' }), $work, $t[0], $t[3], $extras))
    }
    return , $rows.ToArray()
}

# Get-NSReceiptUsageSection <session-lines> - the receipt's runtime section, drawn from every session
# the item was worked in. Mirrors ns_receipt_usage_section line for line.
function Get-NSReceiptUsageSection {
    param([AllowEmptyCollection()][string[]]$Data = @())
    $dash = [string][char]0x2014
    $arrow = [string][char]0x2192
    $tot = @([long]0, [long]0, [long]0, [long]0, [long]0)
    $have = @($false, $false, $false, $false, $false)
    $off = @($false, $false, $false, $false, $false)
    $miss = @($false, $false, $false, $false, $false)
    $twork = [long]0; $tpause = [long]0; $twall = [long]0
    $havework = $false; $offwork = $false; $havepause = $false; $offpause = $false
    $first = $null; $last = $null; $lastWhy = ''
    $hostsSeen = New-Object Collections.Generic.List[string]
    $rows = New-Object Collections.Generic.List[string]
    $handoffs = New-Object Collections.Generic.List[string]
    $prevHost = ''; $prevEnd = ''; $prevCommits = ''; $prevNote = ''
    $budget = ''
    $budgetEvents = New-Object Collections.Generic.List[string]
    $n = 0
    $scale = { param([long]$v) Get-NSUsageScale ([string]$v) }
    foreach ($line in $Data) {
        if ($line.Trim().Length -eq 0) { continue }
        $f = @($line -split '\s+' | Where-Object { $_.Length -gt 0 })
        if ($f.Count -lt 7) { continue }
        $n++
        $sid = $f[0]; $start = $f[1]; $end = $f[2]; $work = $f[3]; $ended = $f[6]
        $vals = @($f[4], $f[5], (Get-NSSessionExtra $line 'cw'), (Get-NSSessionExtra $line 'cr'), (Get-NSSessionExtra $line 'rea'))
        $paused = Get-NSSessionExtra $line 'paused'
        $why = ConvertFrom-NSReceiptEncoded (Get-NSSessionExtra $line 'why')
        $hostKey = Get-NSSessionExtra $line 'host'
        $commits = Get-NSSessionExtra $line 'commits'
        $note = ConvertFrom-NSReceiptEncoded (Get-NSSessionExtra $line 'note')
        $limitText = Get-NSSessionExtra $line 'limit'
        if ($limitText.Length -gt 0) { $budget = ConvertFrom-NSReceiptEncoded $limitText }
        foreach ($lv in @('soft', 'hard')) {
            $atLimit = Get-NSSessionExtra $line $lv
            if ($atLimit.Length -eq 0) { continue }
            $whenLimit = Get-NSLocalTime $atLimit
            $budgetLine = '- ' + $lv + ' limit reached ' + $(if ($whenLimit) { $whenLimit } else { $dash })
            if ($lv -ceq 'hard' -and $ended -ceq 'stopped') { $budgetLine += '; closed as stopped' }
            $budgetEvents.Add($budgetLine)
        }
        $cells = ''
        for ($i = 0; $i -lt 5; $i++) {
            $v = $vals[$i]; $num = [long]0
            if ($v -ceq 'off') { $off[$i] = $true; $cells += ' | off' }
            elseif ($v.Length -eq 0) { $miss[$i] = $true; $cells += ' | ' + $dash }
            elseif ($v -cnotmatch '^[0-9]+$' -or -not [long]::TryParse($v, [ref]$num)) { $miss[$i] = $true; $cells += ' | unavailable' }
            else { $tot[$i] += $num; $have[$i] = $true; $cells += ' | ' + (& $scale $num) }
        }
        $w = [long]0
        if ($work -ceq 'off') { $offwork = $true; $wcell = 'off' }
        elseif ($work -cnotmatch '^[0-9]+$') { $wcell = 'unavailable' }
        else { $w = [long]$work; $twork += $w; $havework = $true; $wcell = Get-NSUsageDuration $work }
        if ($paused -ceq 'off') { $offpause = $true; $pcell = 'off' }
        elseif ($paused.Length -eq 0) { $pcell = $dash }
        elseif ($paused -cnotmatch '^[0-9]+$') { $pcell = 'unavailable' }
        elseif ($paused -ceq '0') { $havepause = $true; $pcell = $dash }
        else {
            $tpause += [long]$paused; $havepause = $true; $pcell = Get-NSUsageDuration $paused
            if ($why.Length -gt 0) { $lastWhy = $why }
        }
        if ($start -cmatch '^[0-9]+$') { if ($null -eq $first -or [long]$start -lt $first) { $first = [long]$start } }
        if ($end -cmatch '^[0-9]+$') {
            if ($null -eq $last -or [long]$end -gt $last) { $last = [long]$end }
            if ($start -cmatch '^[0-9]+$') { $twall += [long]$end - [long]$start }
        }
        if ($hostKey.Length -gt 0 -and -not $hostsSeen.Contains($hostKey)) { $hostsSeen.Add($hostKey) }
        $sidCell = $(if ($sid -ceq '-') { $dash } else { $sid.Substring(0, [math]::Min(8, $sid.Length)) })
        $from = Get-NSLocalTime $start; $to = Get-NSLocalTime $end
        $rows.Add(('| {0} | {1} | {2} | {3} | {4} | {5} | {6}{7} | {8} |' -f $n, $sidCell,
                $(if ($hostKey.Length -gt 0) { Get-NSSessionHostWords $hostKey } else { $dash }),
                $(if ($from) { $from } else { $dash }), $(if ($to) { $to } else { $dash }),
                $wcell, $pcell, $cells, $ended.Replace('-', ' ')))
        if ($prevHost.Length -gt 0 -and $hostKey.Length -gt 0 -and $prevHost -cne $hostKey) {
            $at = Get-NSLocalTime $prevEnd
            $h = ('- {0} {1} {2} {3} {4} {1} outgoing commits: {5}' -f $(if ($at) { $at } else { $dash }), $script:NSDot,
                (Get-NSSessionHostWords $prevHost), $arrow, (Get-NSSessionHostWords $hostKey),
                $(if ($prevCommits.Length -gt 0) { $prevCommits.Replace(',', ', ') } else { 'none' }))
            if ($prevNote.Length -gt 0) { $h += ' ' + $script:NSDot + ' last note: ' + $prevNote }
            $handoffs.Add($h)
        }
        if ($hostKey.Length -gt 0) { $prevHost = $hostKey }
        $prevEnd = $end; $prevCommits = $commits; $prevNote = $note
    }
    $total = {
        param([int]$i)
        if ($have[$i]) {
            $s = Get-NSUsageScale ([string]$tot[$i])
            if ($miss[$i]) { return $s + ' (partial)' }
            return $s
        }
        if ($off[$i]) { return 'off' }
        return 'unavailable'
    }
    $out = New-Object Collections.Generic.List[string]
    $out.Add('<!-- usage -->')
    if (-not ($have -contains $true) -and $off[0]) {
        $out.Add('**Tokens:** off')
    }
    else {
        $out.Add('| Tokens | Amount |')
        $out.Add('| --- | ---: |')
        $comment = @()
        foreach ($d in @(@('input', 0), @('cache_write', 2), @('cache_read', 3), @('output', 1), @('reasoning', 4))) {
            $out.Add(('| {0} | {1} |' -f (Get-NSUsageDimLabel $d[0]), (& $total $d[1])))
            $comment += [string]$tot[$d[1]]
        }
        $hostline = (@($hostsSeen | ForEach-Object {
                    $i = $_.IndexOf('/'); $h = $_.Substring(0, $i); $m = $_.Substring($i + 1)
                    $(if ($m -ceq '-') { $h } else { $h + ' ' + $m })
                }) -join '; ')
        if ($hostline.Length -eq 0) { $hostline = 'unknown' }
        $word = $(if ($n -eq 1) { 'session' } else { 'sessions' })
        $out.Add('')
        $out.Add('<!-- tokens ' + ($comment -join ' ') + ' -->')
        $out.Add(('{0} {1} {2} {3}. {4}' -f $hostline, $script:NSDot, $n, $word, (Get-NSUsageOverlap $hostline.Split(' ')[0])))
    }
    $out.Add('')
    if (-not $havework -and $offwork) {
        $out.Add('**Time:** off')
    }
    else {
        $out.Add('| Time | |')
        $out.Add('| --- | --- |')
        $out.Add('| working | ' + (Get-NSUsageDuration ([string]$twork)) + ' |')
        if ($tpause -gt 0) {
            $out.Add('| paused | ' + (Get-NSUsageDuration ([string]$tpause)) + $(if ($lastWhy.Length -gt 0) { ' (' + $lastWhy + ')' } else { '' }) + ' |')
        }
        $out.Add('| wall | ' + (Get-NSUsageDuration ([string]$twall)) + ' |')
        if ($null -ne $first -and $null -ne $last) {
            $out.Add('| span | ' + (Get-NSLocalTime ([string]$first)) + ' ' + $arrow + ' ' + (Get-NSLocalTime ([string]$last)) + ' |')
        }
    }
    $word = $(if ($n -eq 1) { 'session' } else { 'sessions' })
    $out.Add('')
    $out.Add('**Sessions**')
    $out.Add('')
    $out.Add('| # | Shift | Host ' + $script:NSDot + ' model | Start | End | Working | Paused | Input | Output | Cache write | Cache read | Reasoning | Ended |')
    $out.Add('| --- | --- | --- | --- | --- | --- | --- | ---: | ---: | ---: | ---: | ---: | --- |')
    foreach ($r in $rows) { $out.Add($r) }
    $hostCell = (@($hostsSeen | ForEach-Object { Get-NSSessionHostWords $_ }) -join ', ')
    if ($hostCell.Length -eq 0) { $hostCell = $dash }
    $workTotal = $(if ($havework) { Get-NSUsageDuration ([string]$twork) } elseif ($offwork) { 'off' } else { 'unavailable' })
    $pauseTotal = $(if ($tpause -gt 0) { Get-NSUsageDuration ([string]$tpause) } elseif ($havepause) { $dash } elseif ($offpause) { 'off' } else { 'unavailable' })
    $totalRow = ('| **Total** | {0} {1} | {2} |  |  | **{3}** | **{4}**' -f $n, $word, $hostCell, $workTotal, $pauseTotal)
    for ($i = 0; $i -lt 5; $i++) { $totalRow += ' | **' + (& $total $i) + '**' }
    $out.Add($totalRow + ' |  |')
    if ($handoffs.Count -gt 0) {
        $out.Add('')
        $out.Add('**Handoffs**')
        $out.Add('')
        foreach ($h in $handoffs) { $out.Add($h) }
    }
    if ($budgetEvents.Count -gt 0) {
        $out.Add('')
        $out.Add('**Budget** `' + $budget + '`')
        $out.Add('')
        foreach ($e in $budgetEvents) { $out.Add($e) }
    }
    $out.Add('')
    $out.Add('<!-- session-data')
    foreach ($line in $Data) { if ($line.Trim().Length -gt 0) { $out.Add($line) } }
    $out.Add('-->')
    $out.Add('<!-- /usage -->')
    return , $out.ToArray()
}

# Test-NSReceiptRuntimeLine <line> - a line one of the stacked usage blocks of an older receipt wrote.
function Test-NSReceiptRuntimeLine {
    param([AllowEmptyString()][string]$Line)
    return ($Line.StartsWith('**Usage:**') -or $Line.StartsWith('**Duration:**') -or $Line -ceq '**Tokens:** off' -or
        $Line -ceq '**Time:** off' -or $Line -cmatch '^  (Source:|Cache reads|The input figure|Cached input|Overlap between)' -or
        $Line -cmatch '^\| (Tokens|Time) \|' -or $Line.StartsWith('| ---') -or
        $Line -cmatch '^\| (input|cache [a-z]+|output|reasoning|working|paused|wall|span) \|' -or
        $Line.StartsWith('<!-- tokens ') -or $Line -match (' ' + [regex]::Escape($script:NSDot) + ' [0-9]+ segments?\.'))
}

# Add-NSReceiptSession <receipt> <label> <shift-id> <start> <end> <working-sec> <input> <output>
# <ended> [extras] - add one session to the item's receipt and redraw its runtime section, under the
# heading, in place. An older receipt is folded in on its first redraw. Mirrors ns_receipt_add_session.
function Add-NSReceiptSession {
    param(
        [Parameter(Mandatory = $true)][string]$Receipt, [Parameter(Mandatory = $true)][string]$Label,
        [string]$Shift = '-', [string]$Start = '', [string]$End = '', [string]$Work = '0',
        [string]$In = '-', [string]$Out = '-', [string]$Ended = 'ticked', [string]$Extras = ''
    )
    if (Test-NSReparsePoint $Receipt) { return }
    $utf8 = New-Object Text.UTF8Encoding($false)
    $dir = Split-Path -Parent $Receipt
    $null = New-Item -ItemType Directory -Path $dir -Force
    $fresh = -not (Test-Path -LiteralPath $Receipt -PathType Leaf)
    if ($fresh) { [IO.File]::WriteAllText($Receipt, "# $Label`n", $utf8) }
    $stamp = [IO.File]::GetLastWriteTimeUtc($Receipt)
    $data = New-Object Collections.Generic.List[string]
    foreach ($row in (Get-NSReceiptSessionData $Receipt)) { $data.Add($row) }
    if ($data.Count -eq 0) { foreach ($row in (Get-NSReceiptLegacySessions $Receipt)) { $data.Add($row) } }
    $row = ('{0} {1} {2} {3} {4} {5} {6}' -f $Shift, $Start, $End, $Work, $In, $Out, $Ended)
    if ($Extras.Length -gt 0) { $row += ' ' + $Extras }
    $data.Add($row)
    Set-NSReceiptSessions $Receipt $data.ToArray()
    $block = Get-NSReceiptUsageSection $data.ToArray()
    $result = New-Object Collections.Generic.List[string]
    $skip = $false; $headed = $false; $top = $false; $done = $false; $pend = 0
    foreach ($raw in [IO.File]::ReadAllLines($Receipt)) {
        $line = $raw.TrimEnd("`r")
        if ($raw.StartsWith('<!-- usage -->') -or $raw.StartsWith('<!-- sessions -->')) { $skip = $true; continue }
        if ($skip -and ($raw.StartsWith('<!-- /usage -->') -or $raw.StartsWith('<!-- /sessions -->'))) { $skip = $false; continue }
        if ($skip) { continue }
        if (-not $headed -and $line.StartsWith('# ')) {
            $headed = $true; $top = $true
            $result.Add($raw); $result.Add('')
            foreach ($b in $block) { $result.Add($b) }
            $done = $true; $pend = 0
            continue
        }
        if ($top -and ($line.Trim().Length -eq 0 -or (Test-NSReceiptRuntimeLine $line))) { continue }
        if ($top -and $line -cmatch '^Renamed from .* on [0-9]{4}-[0-9]{2}-[0-9]{2}\.$') { $result.Add(''); $result.Add($raw); continue }
        if ($top) { $top = $false; $pend = 1 }
        if ($raw.Trim().Length -eq 0) { $pend++; continue }
        while ($pend -gt 0) { $result.Add(''); $pend-- }
        $result.Add($raw)
    }
    if (-not $done) {
        $result.Add('')
        foreach ($b in $block) { $result.Add($b) }
    }
    [IO.File]::WriteAllText($Receipt, (($result -join "`n") + "`n"), $utf8)
    if (-not $fresh) { [IO.File]::SetLastWriteTimeUtc($Receipt, $stamp) }
}

function Get-NSReceiptsShiftDate {
    param([Parameter(Mandatory = $true)][string]$Workspace)
    $punch = Get-NSLayoutPath (Join-Path $Workspace '.nightshift') 'punch-list'
    if ((Test-Path -LiteralPath $punch -PathType Leaf) -and -not (Test-NSReparsePoint $punch)) {
        foreach ($line in [IO.File]::ReadAllLines($punch)) {
            if ($line -cmatch '^Date:[ \t]*(.+)$') { return $Matches[1].Trim() }
        }
    }
    $policy = Get-NSLayoutPath (Join-Path $Workspace '.nightshift') 'shift-policy'
    if ((Test-Path -LiteralPath $policy -PathType Leaf) -and -not (Test-NSReparsePoint $policy)) {
        $text = [IO.File]::ReadAllText($policy)
        if ($text -cmatch '"createdAt"\s*:\s*"([0-9]{4}-[0-9]{2}-[0-9]{2})') { return $Matches[1] }
    }
    return [DateTime]::UtcNow.ToString('yyyy-MM-dd')
}

# Get-NSReceiptLegacyCells <counted-blocks> - Get-NSReceiptUsageCells for an older receipt's stacked
# blocks: the counted blocks summed, each measurement off only when every block says so. Mirrors
# _ns_receipt_legacy_cells.
function Get-NSReceiptLegacyCells {
    param([AllowEmptyCollection()][object[]]$Blocks = @())
    $dash = [string][char]0x2014
    $cells = @{
        In = [long]0; CacheWrite = [long]0; CacheRead = [long]0; Out = [long]0; Reasoning = [long]0
        Work = [long]0; Pause = [long]0; Sum = [long]0; Tokens = $dash; Time = $dash
    }
    $tokens = 0; $tokoff = 0; $times = 0; $timeoff = 0
    foreach ($b in $Blocks) {
        if ($b.Tok -ceq 'off') { $tokoff++ }
        elseif ($b.Tok.Length -gt 0) {
            $t = @($b.Tok.Trim() -split '\s+')
            $cells['In'] += [long]$t[0]; $cells['CacheWrite'] += [long]$t[1]; $cells['CacheRead'] += [long]$t[2]
            $cells['Out'] += [long]$t[3]; $cells['Reasoning'] += [long]$t[4]
            $tokens++
        }
        if ($b.TimeOff) { $timeoff++ }
        elseif ($b.Work.Length -gt 0) {
            $cells['Work'] += Get-NSUsageParseSeconds $b.Work
            $cells['Pause'] += Get-NSUsageParseSeconds $b.Pause
            $times++
        }
    }
    $cells['Sum'] = $cells['In'] + $cells['Out']
    if ($tokens -gt 0) {
        $cells['Tokens'] = ($script:NSUsageTokensFormat -f
            (Get-NSUsageScale ([string]$cells['In'])), (Get-NSUsageScale ([string]$cells['CacheWrite'])),
            (Get-NSUsageScale ([string]$cells['CacheRead'])), (Get-NSUsageScale ([string]$cells['Out'])),
            (Get-NSUsageScale ([string]$cells['Reasoning'])))
    }
    elseif ($tokoff -gt 0) { $cells['Tokens'] = 'off' }
    if ($times -gt 0) { $cells['Time'] = Get-NSReceiptsTimeCell ([long]$cells['Work']) ([long]$cells['Pause']) }
    elseif ($timeoff -gt 0) { $cells['Time'] = 'off' }
    return $cells
}

function Get-NSReceiptUsageCells {
    param([Parameter(Mandatory = $true)][string]$Path)
    $dash = [string][char]0x2014
    $cells = @{
        In = [long]0; CacheWrite = [long]0; CacheRead = [long]0; Out = [long]0; Reasoning = [long]0
        Work = [long]0; Pause = [long]0; Sum = [long]0; Tokens = $dash; Time = $dash
    }
    $file = $Path
    if ((Test-Path -LiteralPath $file -PathType Leaf) -and -not (Test-NSReparsePoint $file)) {
        $probe = [IO.File]::ReadAllText($file)
        if ($probe -notmatch 'exact:' -and $probe -notmatch '<!-- tokens ') {
            $sidecar = Join-Path (Split-Path -Parent $file) ('x-' + (Split-Path -Leaf $file))
            if ((Test-Path -LiteralPath $sidecar -PathType Leaf) -and -not (Test-NSReparsePoint $sidecar)) {
                $file = $sidecar
            }
        }
    }
    if ((Test-Path -LiteralPath $file -PathType Leaf) -and -not (Test-NSReparsePoint $file)) {
        $text = [IO.File]::ReadAllText($file)
        # The runtime section already totals every session; an older receipt with several stacked
        # blocks is read block by block, summing the sessions and skipping what a newer block holds.
        if ($text -cmatch '(?ms)^<!-- usage -->\r?\n(.*?)^<!-- \/usage -->') {
            $text = $Matches[1]
        }
        else {
            $legacy = Get-NSReceiptLegacyBlocks $file
            if ($legacy.Count -gt 1) { return (Get-NSReceiptLegacyCells $legacy) }
        }
        $parsed = $false
        if ($text -cmatch '(?m)^<!--\s*tokens\s+(.+?)-->') {
            $parts = @($Matches[1].Trim() -split '\s+')
            if ($parts.Count -ge 5) {
                $nums = @()
                foreach ($p in $parts[0..4]) {
                    $n = 0L
                    if (-not [long]::TryParse($p, [ref]$n)) { $n = 0 }
                    $nums += $n
                }
                $cells['In'] = $nums[0]
                $cells['CacheWrite'] = $nums[1]
                $cells['CacheRead'] = $nums[2]
                $cells['Out'] = $nums[3]
                $cells['Reasoning'] = $nums[4]
                $cells['Sum'] = $nums[0] + $nums[3]
                $cells['Tokens'] = ($script:NSUsageTokensFormat -f
                    (Get-NSUsageScale ([string]$nums[0])), (Get-NSUsageScale ([string]$nums[1])),
                    (Get-NSUsageScale ([string]$nums[2])), (Get-NSUsageScale ([string]$nums[3])),
                    (Get-NSUsageScale ([string]$nums[4])))
                $parsed = $true
            }
        }
        if (-not $parsed -and $text -cmatch 'exact:\s*([0-9]+)\s*/\s*([0-9]+)\s*/\s*([0-9]+)\s*/\s*([0-9]+)\s*/\s*([0-9]+)') {
            $cells['In'] = [long]$Matches[1]
            $cells['CacheWrite'] = [long]$Matches[2]
            $cells['CacheRead'] = [long]$Matches[3]
            $cells['Out'] = [long]$Matches[4]
            $cells['Reasoning'] = [long]$Matches[5]
            $cells['Sum'] = [long]$Matches[1] + [long]$Matches[4]
            $cells['Tokens'] = ($script:NSUsageTokensFormat -f
                (Get-NSUsageScale $Matches[1]), (Get-NSUsageScale $Matches[2]),
                (Get-NSUsageScale $Matches[3]), (Get-NSUsageScale $Matches[4]),
                (Get-NSUsageScale $Matches[5]))
        }
        if ($text -cmatch '(?m)^\|\s*working\s*\|\s*([^|]+)\|') {
            $cells['Work'] = Get-NSUsageParseSeconds $Matches[1].Trim()
            if ($text -cmatch '(?m)^\|\s*paused\s*\|\s*([^|(]+)') {
                $cells['Pause'] = Get-NSUsageParseSeconds $Matches[1].Trim()
            }
            $cells['Time'] = Get-NSReceiptsTimeCell ([long]$cells['Work']) ([long]$cells['Pause'])
        }
        elseif ($text -cmatch '(?m)^\*\*Duration:\*\*\s*(.+)$') {
            $raw = $Matches[1].Trim()
            $workText = $raw
            if ($raw -match '^(.*) working') { $workText = $Matches[1].Trim() }
            elseif ($raw -match '^(.*) \(') { $workText = $Matches[1].Trim() }
            $cells['Work'] = Get-NSUsageParseSeconds $workText
            if ($raw -match 'paused ([^,)]+)') {
                $cells['Pause'] = Get-NSUsageParseSeconds $Matches[1].Trim()
            }
            $cells['Time'] = Get-NSReceiptsTimeCell ([long]$cells['Work']) ([long]$cells['Pause'])
        }
        if ($text -cmatch '(?m)^\| (input|output) \| unavailable \|') { $cells['Tokens'] = $dash }
        # A measurement the owner turned off says so, rather than reading as one nobody reported.
        if ($text -cmatch '(?m)^\*\*Tokens:\*\* off\r?$') { $cells['Tokens'] = 'off' }
        if ($text -cmatch '(?m)^\*\*Time:\*\* off\r?$') { $cells['Time'] = 'off' }
    }
    return $cells
}

function Get-NSUsageParseSeconds {
    param([AllowEmptyString()][string]$Text)
    $h = 0; $m = 0; $s = 0
    if ($Text -cmatch '([0-9]+)h') { $h = [int]$Matches[1] }
    if ($Text -cmatch '([0-9]+)m') { $m = [int]$Matches[1] }
    if ($Text -cmatch '([0-9]+)s') { $s = [int]$Matches[1] }
    return [long]($h * 3600 + $m * 60 + $s)
}

# Get-NSReceiptsMorningNames <directory> - the shift summaries filed there, ordinal order.
function Get-NSReceiptsMorningNames {
    param([Parameter(Mandatory = $true)][string]$Directory)
    $names = New-Object Collections.Generic.List[string]
    if ((Test-NSReparsePoint $Directory) -or -not (Test-Path -LiteralPath $Directory -PathType Container)) {
        return , $names.ToArray()
    }
    foreach ($file in @(Get-ChildItem -LiteralPath $Directory -File -Force -ErrorAction SilentlyContinue)) {
        if ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
        $name = $file.Name
        if (-not $name.StartsWith('morning-', [StringComparison]::Ordinal)) { continue }
        if (-not $name.EndsWith('.md', [StringComparison]::Ordinal)) { continue }
        if ($name.EndsWith('.original.md', [StringComparison]::Ordinal)) { continue }
        $names.Add($name)
    }
    $sorted = $names.ToArray()
    [Array]::Sort($sorted, [StringComparer]::Ordinal)
    return , $sorted
}

function Get-NSReceiptsIndexPage {
    param(
        [Parameter(Mandatory = $true)][string]$Date,
        [AllowEmptyCollection()][string[]]$Rows = @(),
        [string]$UsageTotal = '',
        [string]$TimeTotal = '',
        [long]$TokenTotal = 0,
        [AllowEmptyCollection()][string[]]$Morning = @()
    )
    $dash = [string][char]0x2014
    $tokCell = $(if (-not [string]::IsNullOrEmpty($UsageTotal)) { $UsageTotal }
        elseif ($TokenTotal -gt 0) { Get-NSUsageScale $TokenTotal } else { $dash })
    $timeCell = $(if (-not [string]::IsNullOrEmpty($TimeTotal)) { $TimeTotal } else { $dash })
    # LF on every platform, as the POSIX writer ends its lines.
    $lines = New-Object Collections.Generic.List[string]
    $lines.Add('# Receipts ' + $dash + ' ' + $Date)
    $lines.Add('')
    foreach ($name in $Morning) {
        $lines.Add(('Shift summary: [{0}](./{0})' -f $name))
        $lines.Add('')
    }
    $lines.Add('| Item | State | **Usage** | **Time** | Receipt |')
    $lines.Add('| --- | --- | --- | --- | --- |')
    foreach ($row in $Rows) { $lines.Add($row) }
    $lines.Add(('| **Totals** |  | **{0}** | **{1}** |  |' -f $tokCell, $timeCell))
    return (($lines -join "`n") + "`n")
}

# The receipts of items nobody finished. A receipt travels into the archive when its item is
# ticked; one whose box is still open stays live, exactly as the box stays in the punch list, so
# the next shift extends the same file rather than a copy of it.
function Get-NSReceiptNamesByState {
    param(
        [Parameter(Mandatory = $true)][string]$Workspace,
        [ValidateSet('open', 'ticked')][string]$State = 'open'
    )
    $names = New-Object Collections.Generic.List[string]
    $punch = Get-NSLayoutPath (Join-Path $Workspace '.nightshift') 'punch-list'
    if ((Test-Path -LiteralPath $punch -PathType Leaf) -and -not (Test-NSReparsePoint $punch)) {
        foreach ($row in (Get-NSItemRows $punch $State)) {
            $names.Add((Get-NSReceiptBase $Workspace $row.Label $row.Id) + '.md')
        }
        # A stopped item is not done, so for its receipt it counts as open.
        if ($State -ceq 'open') {
            foreach ($row in (Get-NSItemRows $punch 'stopped')) {
                $names.Add((Get-NSReceiptBase $Workspace $row.Label $row.Id) + '.md')
            }
        }
    }
    return $names.ToArray()
}

function Get-NSOpenReceiptNames {
    param([Parameter(Mandatory = $true)][string]$Workspace)
    return Get-NSReceiptNamesByState $Workspace 'open'
}

function Get-NSTickedReceiptNames {
    param([Parameter(Mandatory = $true)][string]$Workspace)
    return Get-NSReceiptNamesByState $Workspace 'ticked'
}

# Write-NSArchiveReceiptsIndex <directory> <date> [-OpenNames] - the index of the item receipts
# filed in that directory, written only when at least one landed there. A receipt named in
# -OpenNames belongs to an item still open and is listed as open. Links stay siblings, because the
# receipts it lists are in that directory too.
# Get-NSReceiptItemOrderKey <name> - the ordinal sort key that puts receipts in item order: numbered
# items by value (1, 2, 10), then letter-and-number ids by letters and value (A1, A2, A10, B1), then
# the rest by name. Keys are tab-separated, so tab ends a shorter field first.
function Get-NSReceiptItemOrderKey {
    param([Parameter(Mandatory = $true)][string]$Name)
    $class = 2
    $prefix = ''
    $number = ''
    if ($Name -cmatch '^([0-9]+)') {
        $class = 0
        $number = $Matches[1]
    }
    elseif ($Name -cmatch '^([A-Za-z]+)([0-9]+)') {
        $class = 1
        $prefix = $Matches[1].ToLowerInvariant()
        $number = $Matches[2]
    }
    $number = $number.TrimStart([char]'0')
    if ($class -lt 2 -and $number.Length -eq 0) { $number = '0' }
    return ("{0}`t{1}`t{2:D4}{3}`t{4}" -f $class, $prefix, $number.Length, $number, $Name)
}

function Write-NSArchiveReceiptsIndex {
    param(
        [Parameter(Mandatory = $true)][string]$Directory,
        [Parameter(Mandatory = $true)][string]$Date,
        [string[]]$OpenNames = @()
    )
    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) { return }
    if (Test-NSReparsePoint $Directory) { return }
    $index = Join-Path $Directory 'README.md'
    if (Test-NSReparsePoint $index) { return }
    # Each receipt is listed under its heading, in the heading's item order, so a receipt named for
    # its item's id sorts by the number and title it shows.
    $names = New-Object Collections.Generic.List[string]
    $labels = New-Object Collections.Generic.List[string]
    foreach ($file in @(Get-ChildItem -LiteralPath $Directory -File -Force -ErrorAction SilentlyContinue)) {
        if ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
        $name = $file.Name
        if (-not $name.EndsWith('.md', [StringComparison]::Ordinal)) { continue }
        if ($name -ceq 'README.md' -or
            $name.StartsWith('morning-', [StringComparison]::Ordinal) -or
            $name.StartsWith('x-', [StringComparison]::Ordinal) -or
            $name.EndsWith('.original.md', [StringComparison]::Ordinal)) { continue }
        $label = ''
        foreach ($line in [IO.File]::ReadAllLines($file.FullName)) {
            if ($line -cmatch '^# (.+)$') { $label = $Matches[1]; break }
        }
        if ([string]::IsNullOrEmpty($label)) { continue }
        $names.Add($name)
        $labels.Add($label)
    }
    $order = $names.ToArray()
    $headings = $labels.ToArray()
    if ($order.Length -gt 1) {
        $keys = [string[]]@(for ($i = 0; $i -lt $order.Length; $i++) {
                (Get-NSReceiptItemOrderKey $headings[$i]) + "`t" + $order[$i]
            })
        $index2 = [int[]](0..($order.Length - 1))
        [Array]::Sort($keys, $index2, [StringComparer]::Ordinal)
        $order = [string[]]@($index2 | ForEach-Object { $names[$_] })
        $headings = [string[]]@($index2 | ForEach-Object { $labels[$_] })
    }
    $rows = New-Object Collections.Generic.List[string]
    $tin = [long]0; $tcw = [long]0; $tcr = [long]0; $tout = [long]0; $trea = [long]0
    $twork = [long]0; $tpause = [long]0
    $offUsage = $false; $offTime = $false
    for ($i = 0; $i -lt $order.Length; $i++) {
        $name = $order[$i]
        $label = $headings[$i]
        $path = Join-Path $Directory $name
        $cells = Get-NSReceiptUsageCells $path
        $tin += [long]$cells['In']; $tcw += [long]$cells['CacheWrite']; $tcr += [long]$cells['CacheRead']
        $tout += [long]$cells['Out']; $trea += [long]$cells['Reasoning']
        $twork += [long]$cells['Work']; $tpause += [long]$cells['Pause']
        if ($cells['Tokens'] -ceq 'off') { $offUsage = $true }
        if ($cells['Time'] -ceq 'off') { $offTime = $true }
        $state = $(if ($OpenNames -ccontains $name) { 'open' } else { 'ticked' })
        $rows.Add(('| {0} | {1} | **{2}** | **{3}** | [./{4}](./{4}) |' -f
            $label, $state, $cells['Tokens'], $cells['Time'], $name))
    }
    if ($rows.Count -eq 0) { return }
    $utf8 = New-Object Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($index,
        (Get-NSReceiptsIndexPage -Date $Date -Rows $rows.ToArray() `
            -UsageTotal (Get-NSIndexTotal (Get-NSReceiptsUsageTotalCell $tin $tcw $tcr $tout $trea) $offUsage) `
            -TimeTotal (Get-NSIndexTotal (Get-NSReceiptsTimeTotalCell $twork $tpause) $offTime) `
            -Morning (Get-NSReceiptsMorningNames $Directory)), $utf8)
}

