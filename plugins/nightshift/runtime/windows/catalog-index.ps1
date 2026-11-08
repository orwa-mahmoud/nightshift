<#
.SYNOPSIS
  What a catalog holds, one line per entry.

.DESCRIPTION
  Mirrors runtime/catalog-index.sh. shifts, the default, reads references/compose/shifts and prints
  slug, ending, title and summary. -Project is accepted and ignored for shifts, so a caller that
  passes the workspace does not change that listing. evidence reads every evidence kind and prints
  key, title, description, source and the sources a same key replaced. -Template prints the kind
  template in force. -CheckDraft FILE checks one draft and names each required section it lacks.

  Every entry opens with an H1, and that header is the metadata, so there is no second registry:
  a file added today is listed today, and one that is deleted stops being listed. A symlink is
  skipped. Reads the catalog and nothing else, writes nothing, ranks nothing.
  Exit: 0 listed - 1 usage, or a draft that fails its check - 2 no catalog to read, or a template
  path that is not a file
#>
param(
    [Alias('plugin-root')][string]$PluginRoot = '',
    [string]$Catalog = 'shifts',
    [string]$Project = '',
    [switch]$Template,
    [Alias('check-draft')][string]$CheckDraft = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrEmpty($PluginRoot)) {
    $PluginRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
}

if ($Catalog -eq 'shifts') {
    if ($Template -or -not [string]::IsNullOrEmpty($CheckDraft)) {
        [Console]::Error.WriteLine('catalog-index: shifts does not take that argument')
        exit 1
    }
    $dir = Join-Path $PluginRoot 'skills/nightshift/references/compose/shifts'
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
        [Console]::Error.WriteLine('catalog-index: no catalog at ' + $dir)
        exit 2
    }
    $dash = [string][char]0x2014
    $sep = ' ' + $dash + ' '
    $files = @(Get-ChildItem -LiteralPath $dir -Filter '*.md' -File -ErrorAction SilentlyContinue |
        Where-Object { -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) } |
        Sort-Object Name)
    if ($files.Count -eq 0) {
        [Console]::Error.WriteLine('catalog-index: the catalog holds no entries')
        exit 2
    }
    foreach ($file in $files) {
        $title = ''
        $ending = ''
        $summary = ''
        $seen = $false
        foreach ($line in [IO.File]::ReadAllLines($file.FullName)) {
            if (-not $seen) {
                if ($line.StartsWith('# ')) {
                    $seen = $true
                    $parts = $line.Substring(2) -split [regex]::Escape($sep)
                    $title = $parts[0]
                    if ($parts.Count -ge 2) { $ending = $parts[1] }
                    if ($parts.Count -ge 3) { $summary = ($parts[2..($parts.Count - 1)] -join ' - ') }
                }
                continue
            }
            if ([string]::IsNullOrEmpty($summary) -and $line.Length -gt 0 -and
                -not $line.StartsWith('#') -and -not [char]::IsWhiteSpace($line[0])) {
                $summary = $line
            }
        }
        $slug = [IO.Path]::GetFileNameWithoutExtension($file.Name)
        $cells = @($slug, $ending, $title, $summary)
        $cells = $cells | ForEach-Object { $_ -replace "`t", ' ' }
        [Console]::Out.WriteLine($cells -join "`t")
    }
    exit 0
}

if ($Catalog -ne 'evidence') {
    [Console]::Error.WriteLine('catalog-index: unknown catalog: ' + $Catalog)
    exit 1
}

. (Join-Path $PSScriptRoot '../../lib/catalog-sources.ps1')
Import-Module (Join-Path $PluginRoot 'lib/Nightshift.psm1') -Force -DisableNameChecking

$headings = @('When it applies', 'Evidence lines', 'How to generate', 'How to verify', 'Never')
$bullet = 'Evidence lines'
$fence = 'evidence-check'
$fenceKeys = @('files', 'min', 'type')
$fenceTypes = @('image', 'text', 'json', 'any')
$shipped = Join-Path $PluginRoot 'skills/nightshift/references/templates/evidence-kind.md'
$templateSetting = ''
$pathValues = @()
if (-not [string]::IsNullOrEmpty($Project)) {
    $templateGot = Get-NSPolicyGroupSetting $Project 'receipts.evidence.kindTemplatePath'
    if ($null -ne $templateGot['value']) { $templateSetting = [string]$templateGot['value'] }
    $pathsGot = Get-NSPolicyGroupSetting $Project 'receipts.evidence.kindsPaths'
    $rawPaths = $pathsGot['value']
    if ($null -eq $rawPaths -or ($rawPaths -is [string] -and [string]::IsNullOrEmpty($rawPaths))) {
        $pathValues = @()
    }
    elseif ($rawPaths -is [string]) {
        [Console]::Error.WriteLine('catalog-index: kindsPaths could not be read')
    }
    else {
        $pathValues = @($rawPaths)
    }
}

if ($Template) {
    $resolved = $shipped
    if (-not [string]::IsNullOrEmpty($templateSetting)) {
        $resolved = Resolve-NSCatalogPath $Project $templateSetting
    }
    [Console]::Out.WriteLine($resolved)
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) { exit 2 }
    $item = Get-Item -LiteralPath $resolved -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { exit 2 }
    exit 0
}

if (-not [string]::IsNullOrEmpty($CheckDraft)) {
    $problems = @(Get-NSCatalogEntryProblems -Path $CheckDraft -Headings $headings -BulletHeading $bullet `
            -Fence $fence -FenceKeys $fenceKeys -FenceTypes $fenceTypes)
    if ($problems.Count -gt 0) {
        foreach ($problem in $problems) {
            if (-not [string]::IsNullOrEmpty([string]$problem)) {
                [Console]::Error.WriteLine("catalog-index: ${CheckDraft}: $problem")
            }
        }
        exit 1
    }
    exit 0
}

$pluginDir = Join-Path $PluginRoot 'skills/nightshift/references/evidence/kinds'
if (-not (Test-Path -LiteralPath $pluginDir -PathType Container)) {
    [Console]::Error.WriteLine('catalog-index: no catalog at ' + $pluginDir)
    exit 2
}

$projectDir = ''
if (-not [string]::IsNullOrEmpty($Project)) {
    $ns = Join-Path $Project '.nightshift'
    if (Test-NSLayoutKey $ns 'evidence-kinds') {
        $projectDir = Get-NSLayoutPath $ns 'evidence-kinds'
    }
}
$userDir = Get-NSCatalogUserDir 'evidence' 'kinds'
$labels = New-Object System.Collections.Generic.List[string]
$dirs = New-Object System.Collections.Generic.List[string]
foreach ($raw in $pathValues) {
    if ($raw -isnot [string]) {
        [Console]::Error.WriteLine('catalog-index: kindsPaths could not be read')
        continue
    }
    if ([string]::IsNullOrEmpty($raw)) { continue }
    $labels.Add($raw)
    $dirs.Add((Resolve-NSCatalogPath $Project $raw))
}

$lines = @(Get-NSCatalogIndex -Prefix 'catalog-index' -PluginDir $pluginDir -ProjectDir $projectDir `
        -UserDir $userDir -ConfiguredLabels $labels.ToArray() -ConfiguredDirs $dirs.ToArray() `
        -Headings $headings -BulletHeading $bullet -Fence $fence -FenceKeys $fenceKeys -FenceTypes $fenceTypes)
if ($lines.Count -eq 0 -or ($lines.Count -eq 1 -and [string]::IsNullOrEmpty([string]$lines[0]))) {
    [Console]::Error.WriteLine('catalog-index: the catalog holds no entries')
    exit 2
}
foreach ($line in $lines) {
    if (-not [string]::IsNullOrEmpty([string]$line)) { [Console]::Out.WriteLine($line) }
}
exit 0
