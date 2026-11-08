# catalog-sources.ps1 - where a catalog's entries live, and one index of them.
# Mirrors catalog-sources.sh in this directory. The catalog name and the entry-folder name are arguments.
# Project wins over the configured folders, those win in the order given, then the user folder,
# then the shipped directory. A file that fails the structural check is reported and left out.
# A symlink is skipped. Nothing here names a catalog.

# Get-NSCatalogUserDir <catalog> <entries> - the per-user folder.
# One formula: Application Data, then nightshift, then the catalog and its entry folder.
function Get-NSCatalogUserDir {
    param(
        [Parameter(Mandatory = $true)][string]$Catalog,
        [Parameter(Mandatory = $true)][string]$Entries
    )
    $base = $env:APPDATA
    if ([string]::IsNullOrEmpty($base)) {
        $base = [Environment]::GetFolderPath('ApplicationData')
    }
    return (Join-Path (Join-Path (Join-Path $base 'nightshift') $Catalog) $Entries)
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

# Get-NSCatalogEntryProblems - one reason per line. HTML comments are not part of the check.
function Get-NSCatalogEntryProblems {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string[]]$Headings,
        [AllowEmptyString()][string]$BulletHeading,
        [AllowEmptyString()][string]$Fence,
        [string[]]$FenceKeys,
        [string[]]$FenceTypes,
        [switch]$RequireMatch
    )
    $problems = New-Object System.Collections.Generic.List[string]
    $inComment = $false
    $inFence = $false
    $seenH1 = $false
    $bulletOn = $false
    $bulletFound = $false
    $matchSeen = $false
    $found = @{}
    $seenKeys = @{}
    $dash = ' ' + [string][char]0x2014 + ' '
    $lines = @()
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $lines = [IO.File]::ReadAllLines($Path)
    }
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
            $text = $line.Substring(2)
            $parts = $text -split [regex]::Escape($dash), 2
            if ($parts.Count -lt 2 -or [string]::IsNullOrEmpty($parts[0]) -or [string]::IsNullOrEmpty($parts[1])) {
                $problems.Add('missing H1')
            }
            continue
        }
        if ($line.StartsWith('## ')) {
            $name = $line.Substring(3).Trim()
            $found[$name] = $true
            $bulletOn = (-not [string]::IsNullOrEmpty($BulletHeading) -and $name -ceq $BulletHeading)
            continue
        }
        if ($bulletOn -and $line.StartsWith('- ')) { $bulletFound = $true }
        if ($RequireMatch -and $line -cmatch '^Match:\s*') {
            $matchVal = ($line -replace '^Match:\s*', '').Trim()
            if ($matchVal -cne 'stack' -and $matchVal -cne 'plugin' -and $matchVal -cne 'fallback') {
                $problems.Add('invalid match')
            }
            if ($matchSeen) { $problems.Add('duplicate match') }
            $matchSeen = $true
            continue
        }
        if (-not [string]::IsNullOrEmpty($Fence) -and $line -cmatch ('^```' + [regex]::Escape($Fence) + '\s*$')) {
            if ($inFence) { $problems.Add('nested fence') }
            $inFence = $true
            $seenKeys = @{}
            continue
        }
        if ($inFence -and $line -cmatch '^```\s*$') {
            foreach ($required in $FenceKeys) {
                if (-not [string]::IsNullOrEmpty($required) -and -not $seenKeys.ContainsKey($required)) {
                    $problems.Add('missing key')
                }
            }
            $inFence = $false
            continue
        }
        if ($inFence) {
            if ($line -cnotmatch '^[a-z]+:\s*\S.*$') { $problems.Add('unknown key'); continue }
            $key = ($line -split ':', 2)[0]
            $allowed = $false
            foreach ($candidate in $FenceKeys) {
                if ($candidate -ceq $key) { $allowed = $true }
            }
            if (-not $allowed) { $problems.Add('unknown key'); continue }
            if ($seenKeys.ContainsKey($key)) { $problems.Add('duplicate key'); continue }
            $val = ($line -split ':', 2)[1].Trim()
            if ($key -ceq 'min' -and $val -cnotmatch '^[1-9][0-9]*$') { $problems.Add('invalid min') }
            if ($key -ceq 'type') {
                $typeOk = $false
                foreach ($candidate in $FenceTypes) {
                    if ($candidate -ceq $val) { $typeOk = $true }
                }
                if (-not $typeOk) { $problems.Add('invalid type') }
            }
            $seenKeys[$key] = $val
            continue
        }
    }
    if (-not $seenH1) { $problems.Add('missing H1') }
    foreach ($heading in $Headings) {
        if (-not [string]::IsNullOrEmpty($heading) -and -not $found.ContainsKey($heading)) {
            $problems.Add('missing section ' + $heading)
        }
    }
    if (-not [string]::IsNullOrEmpty($BulletHeading) -and $found.ContainsKey($BulletHeading) -and -not $bulletFound) {
        $problems.Add('no bullet')
    }
    if ($RequireMatch -and -not $matchSeen) { $problems.Add('missing match') }
    if ($inFence) { $problems.Add('unclosed fence') }
    return $problems.ToArray()
}

function Add-NSCatalogDirectory {
    param(
        [AllowEmptyString()][string]$Dir,
        [Parameter(Mandatory = $true)][string]$Label,
        [bool]$Check,
        [bool]$ReportMissing,
        [string]$Prefix,
        [System.Collections.Generic.List[string]]$Order,
        [hashtable]$SourceOf,
        [hashtable]$ReplacedOf,
        [hashtable]$MetaOf,
        [string[]]$Headings,
        [AllowEmptyString()][string]$BulletHeading,
        [AllowEmptyString()][string]$Fence,
        [string[]]$FenceKeys,
        [string[]]$FenceTypes,
        [switch]$RequireMatch
    )
    if ([string]::IsNullOrEmpty($Dir)) { return }
    if (-not (Test-Path -LiteralPath $Dir)) {
        if ($ReportMissing) {
            [Console]::Error.WriteLine("${Prefix}: configured folder missing: $Label")
        }
        return
    }
    $item = Get-Item -LiteralPath $Dir -Force
    if (-not $item.PSIsContainer) {
        if ($ReportMissing) {
            [Console]::Error.WriteLine("${Prefix}: configured folder unreadable: $Label")
        }
        return
    }
    $files = @()
    try {
        $files = @(Get-ChildItem -LiteralPath $Dir -Filter '*.md' -File -ErrorAction Stop)
    }
    catch {
        if ($ReportMissing) {
            [Console]::Error.WriteLine("${Prefix}: configured folder unreadable: $Label")
        }
        return
    }
    foreach ($file in $files) {
        if ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
        $key = [IO.Path]::GetFileNameWithoutExtension($file.Name)
        if ($key -cnotmatch '^[a-z0-9]+(-[a-z0-9]+)*$') {
            if ($Check) {
                [Console]::Error.WriteLine("${Prefix}: $($file.FullName): malformed file name")
                continue
            }
        }
        if ($Check) {
            $problems = @(Get-NSCatalogEntryProblems -Path $file.FullName -Headings $Headings `
                    -BulletHeading $BulletHeading -Fence $Fence -FenceKeys $FenceKeys -FenceTypes $FenceTypes `
                    -RequireMatch:$RequireMatch)
            if ($problems.Count -gt 0) {
                foreach ($problem in $problems) {
                    if (-not [string]::IsNullOrEmpty($problem)) {
                        [Console]::Error.WriteLine("${Prefix}: $($file.FullName): $problem")
                    }
                }
                continue
            }
        }
        $heading = @(Get-NSCatalogHeading -Path $file.FullName)
        $title = [string]$heading[0]
        $description = ''
        if ($heading.Count -ge 2) { $description = [string]$heading[1] }
        if ($SourceOf.ContainsKey($key)) {
            $old = [string]$SourceOf[$key]
            $prev = [string]$ReplacedOf[$key]
            if (-not [string]::IsNullOrEmpty($prev)) {
                $ReplacedOf[$key] = "$old, $prev"
            }
            else {
                $ReplacedOf[$key] = $old
            }
        }
        else {
            $Order.Add($key)
            $ReplacedOf[$key] = ''
        }
        $SourceOf[$key] = $Label
        $MetaOf[$key] = "$title`t$description"
    }
}

# Get-NSCatalogIndex - one line per entry: key, title, description, source, replaced.
# ConfiguredLabels and ConfiguredDirs are parallel. The first label wins.
function Get-NSCatalogIndex {
    param(
        [Parameter(Mandatory = $true)][string]$Prefix,
        [AllowEmptyString()][string]$PluginDir,
        [AllowEmptyString()][string]$ProjectDir,
        [AllowEmptyString()][string]$UserDir,
        [string[]]$ConfiguredLabels = @(),
        [string[]]$ConfiguredDirs = @(),
        [string[]]$Headings = @(),
        [AllowEmptyString()][string]$BulletHeading = '',
        [AllowEmptyString()][string]$Fence = '',
        [string[]]$FenceKeys = @(),
        [string[]]$FenceTypes = @(),
        [switch]$RequireMatch
    )
    $order = New-Object System.Collections.Generic.List[string]
    $sourceOf = @{}
    $replacedOf = @{}
    $metaOf = @{}
    $common = @{
        Prefix        = $Prefix
        Order         = $order
        SourceOf      = $sourceOf
        ReplacedOf    = $replacedOf
        MetaOf        = $metaOf
        Headings      = $Headings
        BulletHeading = $BulletHeading
        Fence         = $Fence
        FenceKeys     = $FenceKeys
        FenceTypes    = $FenceTypes
        RequireMatch  = [bool]$RequireMatch
    }
    Add-NSCatalogDirectory -Dir $PluginDir -Label 'plugin' -Check $false -ReportMissing $false @common
    Add-NSCatalogDirectory -Dir $UserDir -Label 'user' -Check $true -ReportMissing $false @common
    for ($i = $ConfiguredLabels.Count - 1; $i -ge 0; $i--) {
        $dir = ''
        if ($i -lt $ConfiguredDirs.Count) { $dir = $ConfiguredDirs[$i] }
        Add-NSCatalogDirectory -Dir $dir -Label $ConfiguredLabels[$i] -Check $true -ReportMissing $true @common
    }
    Add-NSCatalogDirectory -Dir $ProjectDir -Label 'project' -Check $true -ReportMissing $false @common
    $keys = @($order | Select-Object -Unique)
    [Array]::Sort($keys, [StringComparer]::Ordinal)
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($key in $keys) {
        if ([string]::IsNullOrEmpty($key)) { continue }
        $lines.Add("$key`t$($metaOf[$key])`t$($sourceOf[$key])`t$($replacedOf[$key])")
    }
    return $lines.ToArray()
}
