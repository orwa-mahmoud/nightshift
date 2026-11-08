# catalog-sources.ps1 - every catalog through one model. Mirrors catalog-sources.sh in this directory.
#
# lib/catalogs.tsv names each catalog: where its shipped entries live, its template, its order, and
# the one rule its template cannot express. An owner adds entries in .nightshift\catalogs\<name>\
# (this project), in %APPDATA%\nightshift\catalogs\<name>\ (every project on the machine), or in
# the folders catalogs.<name>.paths names; the template in force is catalogs.<name>.template, else
# the shipped one. The folders and keys an earlier version read stay honoured.
#
# Precedence, highest first: the project folder, the configured folders in the order given, the
# user folder, the shipped directory. A later source replaces an earlier one and the index names
# what it replaced. An owner entry that fails its check is reported and left out. A symlink is
# skipped. The template is the schema: its H2 headings are the sections every entry needs, and a
# section whose template text shows a bullet needs one in the entry.

$script:NSCatalogsTable = Join-Path $PSScriptRoot 'catalogs.tsv'

function Get-NSCatalogRows {
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($line in [IO.File]::ReadAllLines($script:NSCatalogsTable)) {
        if ($line.StartsWith('#') -or [string]::IsNullOrWhiteSpace($line)) { continue }
        $cells = $line.Split([char]9)
        if ($cells.Count -lt 9) { continue }
        $clean = @($cells | ForEach-Object { if ($_ -ceq '-') { '' } else { $_ } })
        $rows.Add([pscustomobject]@{
                Name           = $clean[0]
                Shipped        = $clean[1]
                Template       = $clean[2]
                Order          = $clean[3]
                Rule           = $clean[4]
                LegacyProject  = $clean[5]
                LegacyUser     = $clean[6]
                LegacyPaths    = $clean[7]
                LegacyTemplate = $clean[8]
            })
    }
    return $rows.ToArray()
}

# Get-NSCatalogRow <name> - the registry row, or $null for a name the registry does not hold.
function Get-NSCatalogRow {
    param([Parameter(Mandatory = $true)][string]$Name)
    foreach ($row in (Get-NSCatalogRows)) {
        if ($row.Name -ceq $Name) { return $row }
    }
    return $null
}

# Get-NSCatalogUserRoot - the per-user Nightshift folder: Application Data, then nightshift.
function Get-NSCatalogUserRoot {
    $base = $env:APPDATA
    if ([string]::IsNullOrEmpty($base)) {
        $base = [Environment]::GetFolderPath('ApplicationData')
    }
    return (Join-Path $base 'nightshift')
}

# Resolve-NSCatalogPath <workspace> <path> - a tilde, an absolute path, or a workspace-relative path.
function Resolve-NSCatalogPath {
    param(
        [AllowEmptyString()][string]$Workspace,
        [AllowEmptyString()][string]$Path
    )
    if ([string]::IsNullOrEmpty($Path)) { return '' }
    $homeDir = $env:HOME
    if ([string]::IsNullOrEmpty($homeDir)) { $homeDir = '' }
    if ($Path -ceq '~') { return $homeDir }
    if ($Path.StartsWith('~/')) { return (Join-Path $homeDir $Path.Substring(2)) }
    if ([IO.Path]::IsPathRooted($Path)) { return $Path }
    if (-not [string]::IsNullOrEmpty($Workspace)) {
        return (Join-Path $Workspace.TrimEnd([IO.Path]::DirectorySeparatorChar, '/') $Path)
    }
    return $Path
}

# Get-NSCatalogSetting - the owner's value for one catalog and the key that holds it:
# catalogs.<name>.<field>, else the legacy key the registry names. Value is $null when neither is set.
function Get-NSCatalogSetting {
    param(
        [AllowEmptyString()][string]$Workspace,
        [Parameter(Mandatory = $true)]$Row,
        [Parameter(Mandatory = $true)][ValidateSet('paths', 'template')][string]$Field
    )
    $result = @{ Key = "catalogs.$($Row.Name).$Field"; Value = $null }
    if ([string]::IsNullOrEmpty($Workspace)) { return $result }
    $value = (Get-NSPolicyGroupSetting $Workspace $result['Key'])['value']
    if (Test-NSCatalogSettingEmpty $value) {
        $legacy = $Row.LegacyTemplate
        if ($Field -ceq 'paths') { $legacy = $Row.LegacyPaths }
        $value = $null
        if (-not [string]::IsNullOrEmpty($legacy)) {
            $result['Key'] = $legacy
            $value = (Get-NSPolicyGroupSetting $Workspace $legacy)['value']
            if (Test-NSCatalogSettingEmpty $value) { $value = $null }
        }
    }
    $result['Value'] = $value
    return $result
}

function Test-NSCatalogSettingEmpty {
    param($Value)
    if ($null -eq $Value) { return $true }
    if ($Value -is [string]) { return [string]::IsNullOrEmpty($Value) }
    if ($Value -is [Collections.IEnumerable]) { return (@($Value).Count -eq 0) }
    return $false
}

# Get-NSCatalogTemplate - the template in force.
function Get-NSCatalogTemplate {
    param(
        [Parameter(Mandatory = $true)][string]$PluginRoot,
        [AllowEmptyString()][string]$Workspace,
        [Parameter(Mandatory = $true)]$Row
    )
    $setting = Get-NSCatalogSetting -Workspace $Workspace -Row $Row -Field template
    if ($setting['Value'] -is [string] -and -not [string]::IsNullOrEmpty($setting['Value'])) {
        return (Resolve-NSCatalogPath $Workspace $setting['Value'])
    }
    return (Join-Path $PluginRoot $Row.Template)
}

# Get-NSCatalogShape <template> - the required H2 names and the names of the sections that need a
# bullet. Comments and fenced blocks are not part of the shape.
function Get-NSCatalogShape {
    param([Parameter(Mandatory = $true)][string]$Template)
    $heads = New-Object System.Collections.Generic.List[string]
    $bullets = New-Object System.Collections.Generic.List[string]
    $inComment = $false
    $inFence = $false
    $current = ''
    $lines = @()
    if (Test-Path -LiteralPath $Template -PathType Leaf) { $lines = [IO.File]::ReadAllLines($Template) }
    foreach ($raw in $lines) {
        $line = $raw.TrimEnd("`r")
        if ($inComment) {
            if ($line.Contains('-->')) { $inComment = $false }
            continue
        }
        if ($line.StartsWith('<!--')) {
            if (-not $line.Contains('-->')) { $inComment = $true }
            continue
        }
        if ($line.StartsWith('```')) { $inFence = -not $inFence; continue }
        if ($inFence) { continue }
        if ($line.StartsWith('## ')) {
            $current = $line.Substring(3).Trim()
            $heads.Add($current)
            continue
        }
        if ($current.Length -gt 0 -and $line.StartsWith('- ') -and -not $bullets.Contains($current)) {
            $bullets.Add($current)
        }
    }
    return [pscustomobject]@{ Headings = $heads.ToArray(); Bullets = $bullets.ToArray() }
}

function Get-NSCatalogHeading {
    param([Parameter(Mandatory = $true)][string]$Path)
    $dash = ' ' + [string][char]0x2014 + ' '
    foreach ($raw in [IO.File]::ReadAllLines($Path)) {
        $line = $raw.TrimEnd("`r")
        if ($line.StartsWith('# ') -and -not $line.StartsWith('## ')) {
            $text = $line.Substring(2)
            $parts = $text -split [regex]::Escape($dash), 2
            $title = $parts[0] -replace "`t", ' '
            $description = ''
            if ($parts.Count -ge 2) { $description = ($parts[1] -replace "`t", ' ') }
            return @($title, $description)
        }
    }
    return @('', '')
}

# Get-NSCatalogEntryProblems - one reason per entry, the same words as catalog-sources.sh. Rule is
# the registry's rule: shift, fence:<lang>, match, or empty. HTML comments are not part of the check.
function Get-NSCatalogEntryProblems {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Shape,
        [AllowEmptyString()][string]$Rule = ''
    )
    $problems = New-Object System.Collections.Generic.List[string]
    $fenceKeys = @('files', 'min', 'type')
    $fenceTypes = @('image', 'text', 'json', 'any')
    $inComment = $false
    $inCheck = $false
    $inBlock = $false
    $inItem = $false
    $itemBox = $false
    $itemVerify = $false
    $seenH1 = $false
    $matchSeen = $false
    $current = ''
    $found = @{}
    $hasBullet = @{}
    $seenKeys = @{}
    $dash = ' ' + [string][char]0x2014 + ' '
    $lines = @()
    if (Test-Path -LiteralPath $Path -PathType Leaf) { $lines = [IO.File]::ReadAllLines($Path) }
    foreach ($raw in $lines) {
        $rest = $raw.TrimEnd("`r")
        $line = ''
        while ($rest.Length -gt 0) {
            if ($inComment) {
                $i = $rest.IndexOf('-->')
                if ($i -lt 0) { $rest = ''; break }
                $rest = $rest.Substring($i + 3)
                $inComment = $false
                continue
            }
            $i = $rest.IndexOf('<!--')
            if ($i -lt 0) { $line += $rest; $rest = ''; break }
            $line += $rest.Substring(0, $i)
            $rest = $rest.Substring($i + 4)
            $inComment = $true
        }
        if ($inComment) { continue }
        if (-not $seenH1 -and $line.StartsWith('# ') -and -not $line.StartsWith('## ')) {
            $seenH1 = $true
            $parts = $line.Substring(2) -split [regex]::Escape($dash)
            if ($parts.Count -lt 2 -or [string]::IsNullOrEmpty($parts[0]) -or [string]::IsNullOrEmpty($parts[1])) {
                $problems.Add('missing H1')
            }
            if ($Rule -ceq 'shift' -and ($parts.Count -lt 3 -or ($parts[1] -cne 'finite' -and $parts[1] -cne 'open-ended'))) {
                $problems.Add('H1 must name the ending: finite or open-ended')
            }
            continue
        }
        if ($line.StartsWith('```') -and -not $inCheck) {
            if ($Rule.StartsWith('fence:') -and $line -cmatch ('^```' + [regex]::Escape($Rule.Substring(6)) + '\s*$')) {
                $inCheck = $true
                $seenKeys = @{}
                continue
            }
            $inBlock = -not $inBlock
            if ($inBlock -and $current -ceq 'Item' -and $line -cmatch '^```text\s*$') { $inItem = $true }
            if (-not $inBlock) { $inItem = $false }
            continue
        }
        if ($inCheck -and $line -cmatch '^```\s*$') {
            foreach ($required in $fenceKeys) {
                if (-not $seenKeys.ContainsKey($required)) { $problems.Add('missing key') }
            }
            $inCheck = $false
            continue
        }
        if ($inCheck) {
            if ($line -cnotmatch '^[a-z]+:\s*\S.*$') { $problems.Add('unknown key'); continue }
            $key = ($line -split ':', 2)[0]
            if ($fenceKeys -cnotcontains $key) { $problems.Add('unknown key'); continue }
            if ($seenKeys.ContainsKey($key)) { $problems.Add('duplicate key'); continue }
            $val = ($line -split ':', 2)[1].Trim()
            if ($key -ceq 'min' -and $val -cnotmatch '^[1-9][0-9]*$') { $problems.Add('invalid min') }
            if ($key -ceq 'type' -and $fenceTypes -cnotcontains $val) { $problems.Add('invalid type') }
            $seenKeys[$key] = $val
            continue
        }
        if ($inItem) {
            if ($line -cmatch '^- \[ \] \*\*') { $itemBox = $true }
            if ($line.Contains('Verify:')) { $itemVerify = $true }
            continue
        }
        if ($inBlock) { continue }
        if ($line.StartsWith('## ')) {
            $current = $line.Substring(3).Trim()
            $found[$current] = $true
            continue
        }
        if ($Shape.Bullets -ccontains $current -and $line.StartsWith('- ')) { $hasBullet[$current] = $true }
        if ($Rule -ceq 'match' -and $line -cmatch '^Match:\s*') {
            $matchVal = ($line -replace '^Match:\s*', '').Trim()
            if ($matchVal -cne 'stack' -and $matchVal -cne 'plugin' -and $matchVal -cne 'fallback') {
                $problems.Add('invalid match')
            }
            if ($matchSeen) { $problems.Add('duplicate match') }
            $matchSeen = $true
        }
    }
    if (-not $seenH1) { $problems.Add('missing H1') }
    foreach ($heading in $Shape.Headings) {
        if (-not [string]::IsNullOrEmpty($heading) -and -not $found.ContainsKey($heading)) {
            $problems.Add('missing section ' + $heading)
        }
    }
    foreach ($heading in $Shape.Bullets) {
        if ($found.ContainsKey($heading) -and -not $hasBullet.ContainsKey($heading)) {
            $problems.Add('no bullet in ' + $heading)
        }
    }
    if ($Rule -ceq 'match' -and -not $matchSeen) { $problems.Add('missing match') }
    if ($Rule -ceq 'shift' -and -not $itemBox) { $problems.Add('the Item section has no pasteable box') }
    if ($Rule -ceq 'shift' -and -not $itemVerify) { $problems.Add('the Item section has no Verify line') }
    if ($inCheck -or $inBlock) { $problems.Add('unclosed fence') }
    return $problems.ToArray()
}

function Write-NSCatalogProblem {
    param([hashtable]$State, [string]$Text)
    if (-not $State['Quiet']) { [Console]::Error.WriteLine($Text) }
}

function Add-NSCatalogDirectory {
    param(
        [AllowEmptyString()][string]$Dir,
        [Parameter(Mandatory = $true)][string]$Label,
        [bool]$Check,
        [bool]$ReportMissing,
        [hashtable]$State
    )
    if ([string]::IsNullOrEmpty($Dir)) { return }
    $prefix = $State['Prefix']
    if (-not (Test-Path -LiteralPath $Dir)) {
        if ($ReportMissing) { Write-NSCatalogProblem $State ("${prefix}: configured folder missing: $Label") }
        return
    }
    $item = Get-Item -LiteralPath $Dir -Force
    if (-not $item.PSIsContainer) {
        if ($ReportMissing) { Write-NSCatalogProblem $State ("${prefix}: configured folder unreadable: $Label") }
        return
    }
    $files = @()
    try {
        $files = @(Get-ChildItem -LiteralPath $Dir -Filter '*.md' -File -ErrorAction Stop)
    }
    catch {
        if ($ReportMissing) { Write-NSCatalogProblem $State ("${prefix}: configured folder unreadable: $Label") }
        return
    }
    foreach ($file in $files) {
        if ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
        $key = [IO.Path]::GetFileNameWithoutExtension($file.Name)
        if ($Check -and $key -cnotmatch '^[a-z0-9]+(-[a-z0-9]+)*$') {
            Write-NSCatalogProblem $State ("${prefix}: $($file.FullName): malformed file name")
            continue
        }
        if ($Check) {
            $problems = @(Get-NSCatalogEntryProblems -Path $file.FullName -Shape $State['Shape'] -Rule $State['Rule'])
            if ($problems.Count -gt 0) {
                foreach ($problem in $problems) {
                    Write-NSCatalogProblem $State ("${prefix}: $($file.FullName): $problem")
                }
                continue
            }
        }
        $heading = @(Get-NSCatalogHeading -Path $file.FullName)
        if ($State['SourceOf'].ContainsKey($key)) {
            $old = [string]$State['SourceOf'][$key]
            $prev = [string]$State['ReplacedOf'][$key]
            if (-not [string]::IsNullOrEmpty($prev)) { $State['ReplacedOf'][$key] = "$old, $prev" }
            else { $State['ReplacedOf'][$key] = $old }
        }
        else {
            $State['Order'].Add($key)
            $State['ReplacedOf'][$key] = ''
        }
        $State['SourceOf'][$key] = $Label
        $State['MetaOf'][$key] = "$([string]$heading[0])`t$([string]$heading[1])"
        $State['FileOf'][$key] = $file.FullName
    }
}

function Get-NSCatalogRank {
    param([Parameter(Mandatory = $true)][string]$Path)
    foreach ($row in [IO.File]::ReadAllLines($Path)) {
        if ($row -cmatch '^Match:\s*(.*)$') {
            $match = $Matches[1].Trim()
            if ($match -ceq 'plugin') { return 1 }
            if ($match -ceq 'fallback') { return 2 }
            return 0
        }
    }
    return 0
}

# Get-NSCatalogEntries - every entry once, in the catalog's order, as objects with Key, Title,
# Description, Source, Replaced and File. Problems go to stderr under Prefix.
function Get-NSCatalogEntries {
    param(
        [Parameter(Mandatory = $true)][string]$Prefix,
        [Parameter(Mandatory = $true)][string]$PluginRoot,
        [Parameter(Mandatory = $true)]$Row,
        [AllowEmptyString()][string]$Workspace = '',
        [switch]$Quiet
    )
    $template = Get-NSCatalogTemplate -PluginRoot $PluginRoot -Workspace $Workspace -Row $Row
    $state = @{
        Prefix     = $Prefix
        Quiet      = [bool]$Quiet
        Shape      = (Get-NSCatalogShape -Template $template)
        Rule       = $Row.Rule
        Order      = (New-Object System.Collections.Generic.List[string])
        SourceOf   = @{}
        ReplacedOf = @{}
        MetaOf     = @{}
        FileOf     = @{}
    }
    $projectDir = ''
    $legacyProjectDir = ''
    if (-not [string]::IsNullOrEmpty($Workspace)) {
        $ns = Join-Path $Workspace '.nightshift'
        if (Test-NSLayoutKey $ns ('catalog-' + $Row.Name)) { $projectDir = Get-NSLayoutPath $ns ('catalog-' + $Row.Name) }
        if (-not [string]::IsNullOrEmpty($Row.LegacyProject) -and (Test-NSLayoutKey $ns $Row.LegacyProject)) {
            $legacyProjectDir = Get-NSLayoutPath $ns $Row.LegacyProject
        }
    }
    $userRoot = Get-NSCatalogUserRoot
    $userDir = Join-Path (Join-Path $userRoot 'catalogs') $Row.Name
    $legacyUserDir = ''
    if (-not [string]::IsNullOrEmpty($Row.LegacyUser)) { $legacyUserDir = Join-Path $userRoot $Row.LegacyUser }

    Add-NSCatalogDirectory -Dir (Join-Path $PluginRoot $Row.Shipped) -Label 'plugin' -Check $false -ReportMissing $false -State $state
    Add-NSCatalogDirectory -Dir $legacyUserDir -Label 'user' -Check $true -ReportMissing $false -State $state
    Add-NSCatalogDirectory -Dir $userDir -Label 'user' -Check $true -ReportMissing $false -State $state
    $setting = Get-NSCatalogSetting -Workspace $Workspace -Row $Row -Field paths
    $configured = @()
    if ($null -ne $setting['Value']) {
        $readable = ($setting['Value'] -isnot [string]) -and ($setting['Value'] -is [Collections.IEnumerable])
        if ($readable) {
            foreach ($one in @($setting['Value'])) { if ($one -isnot [string]) { $readable = $false } }
        }
        if ($readable) { $configured = @($setting['Value'] | Where-Object { -not [string]::IsNullOrEmpty($_) }) }
        else { Write-NSCatalogProblem $state "${Prefix}: $($setting['Key']) could not be read" }
    }
    for ($i = $configured.Count - 1; $i -ge 0; $i--) {
        Add-NSCatalogDirectory -Dir (Resolve-NSCatalogPath $Workspace $configured[$i]) -Label $configured[$i] `
            -Check $true -ReportMissing $true -State $state
    }
    Add-NSCatalogDirectory -Dir $legacyProjectDir -Label 'project' -Check $true -ReportMissing $false -State $state
    Add-NSCatalogDirectory -Dir $projectDir -Label 'project' -Check $true -ReportMissing $false -State $state

    $keys = @($state['Order'] | Select-Object -Unique)
    [Array]::Sort($keys, [StringComparer]::Ordinal)
    $entries = New-Object System.Collections.Generic.List[object]
    foreach ($key in $keys) {
        if ([string]::IsNullOrEmpty($key)) { continue }
        $meta = ([string]$state['MetaOf'][$key]).Split([char]9, 2)
        $rank = 0
        if ($Row.Order -ceq 'match') { $rank = Get-NSCatalogRank -Path $state['FileOf'][$key] }
        $entries.Add([pscustomobject]@{
                Rank        = $rank
                Key         = $key
                Title       = $meta[0]
                Description = $(if ($meta.Count -ge 2) { $meta[1] } else { '' })
                Source      = [string]$state['SourceOf'][$key]
                Replaced    = [string]$state['ReplacedOf'][$key]
                File        = [string]$state['FileOf'][$key]
            })
    }
    if ($Row.Order -ceq 'match') {
        $sorted = [Linq.Enumerable]::ToArray([Linq.Enumerable]::ThenBy(
                [Linq.Enumerable]::OrderBy($entries, [Func[object, int]] { param($e) $e.Rank }),
                [Func[object, string]] { param($e) $e.Key }, [StringComparer]::Ordinal))
        return $sorted
    }
    return $entries.ToArray()
}

# Get-NSCatalogFile - the file in force for one key, or an empty string when no source holds it.
function Get-NSCatalogFile {
    param(
        [Parameter(Mandatory = $true)][string]$Prefix,
        [Parameter(Mandatory = $true)][string]$PluginRoot,
        [Parameter(Mandatory = $true)]$Row,
        [AllowEmptyString()][string]$Workspace = '',
        [Parameter(Mandatory = $true)][string]$Key
    )
    $entries = Get-NSCatalogEntries -Prefix $Prefix -PluginRoot $PluginRoot -Row $Row -Workspace $Workspace -Quiet
    foreach ($entry in $entries) {
        if ($entry.Key -ceq $Key) { return $entry.File }
    }
    return ''
}
