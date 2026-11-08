<#
.SYNOPSIS
  What a catalog holds, one line per entry.

.DESCRIPTION
  Mirrors runtime/catalog-index.sh. -Catalog names a row of lib/catalogs.tsv: shifts (the default),
  evidence, gates, or edge-cases. Every catalog reads the shipped entries, the project folder, the
  user folder, and the folders the rules file names, with the precedence lib/catalog-sources.ps1
  describes.

  shifts prints slug, ending, title and summary. The others print key, title, description, source,
  and the sources a same key replaced; gates prints them in match order. -Template prints the
  template in force. -CheckDraft FILE checks what code reads in one draft and names each problem. -Path KEY
  prints the file in force for one key.

  Every entry opens with an H1, and that header is the metadata, so there is no second registry of
  entries: a file added today is listed today. A symlink is skipped. Reads the catalog and nothing
  else, writes nothing, ranks nothing by judgement.
  Exit: 0 listed - 1 usage, or a draft that fails its check - 2 no catalog to read, no such key, or
  a template path that is not a file
#>
param(
    [Alias('plugin-root')][string]$PluginRoot = '',
    [string]$Catalog = 'shifts',
    [string]$Project = '',
    [switch]$Template,
    [Alias('check-draft')][string]$CheckDraft = '',
    [Alias('path')][string]$EntryKey = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrEmpty($PluginRoot)) {
    $PluginRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
}

. (Join-Path $PSScriptRoot '../../lib/catalog-sources.ps1')
Import-Module (Join-Path $PluginRoot 'lib/Nightshift.psm1') -Force -DisableNameChecking

$row = Get-NSCatalogRow -Name $Catalog
if ($null -eq $row) {
    [Console]::Error.WriteLine('catalog-index: unknown catalog: ' + $Catalog)
    exit 1
}

if ($Template) {
    $resolved = Get-NSCatalogTemplate -PluginRoot $PluginRoot -Workspace $Project -Row $row
    [Console]::Out.WriteLine($resolved)
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) { exit 2 }
    $item = Get-Item -LiteralPath $resolved -Force
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { exit 2 }
    exit 0
}

if (-not [string]::IsNullOrEmpty($CheckDraft)) {
    $found = @(Get-NSCatalogEntryProblems -Path $CheckDraft -Rule $row.Rule -Notes)
    # A note says what the draft leaves to the owner; it never fails the check.
    foreach ($note in @($found | Where-Object { $_.StartsWith('note: ') })) { Write-Output ("catalog-index: ${CheckDraft}: " + $note.Substring(6)) }
    $problems = @($found | Where-Object { -not $_.StartsWith('note: ') })
    if ($problems.Count -gt 0) {
        foreach ($problem in $problems) { [Console]::Error.WriteLine("catalog-index: ${CheckDraft}: $problem") }
        exit 1
    }
    exit 0
}

$shippedDir = Join-Path $PluginRoot $row.Shipped
if (-not (Test-Path -LiteralPath $shippedDir -PathType Container)) {
    [Console]::Error.WriteLine('catalog-index: no catalog at ' + $shippedDir)
    exit 2
}

if (-not [string]::IsNullOrEmpty($EntryKey)) {
    $file = Get-NSCatalogFile -Prefix 'catalog-index' -PluginRoot $PluginRoot -Row $row -Workspace $Project -Key $EntryKey
    if ([string]::IsNullOrEmpty($file)) {
        [Console]::Error.WriteLine("catalog-index: $Catalog holds no entry $EntryKey")
        exit 2
    }
    [Console]::Out.WriteLine($file)
    exit 0
}

$entries = @(Get-NSCatalogEntries -Prefix 'catalog-index' -PluginRoot $PluginRoot -Row $row -Workspace $Project)
if ($entries.Count -eq 0) {
    [Console]::Error.WriteLine('catalog-index: the catalog holds no entries')
    exit 2
}

# Get-NSShiftLine - slug, ending, title and summary. The summary is the H1's third part onward, or
# the first line of prose when the H1 has none.
function Get-NSShiftLine {
    param([string]$Slug, [string]$Path)
    $sep = ' ' + [string][char]0x2014 + ' '
    $title = ''
    $ending = ''
    $summary = ''
    $seen = $false
    foreach ($line in [IO.File]::ReadAllLines($Path)) {
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
    return (@($Slug, $ending, $title, $summary) | ForEach-Object { $_ -replace "`t", ' ' }) -join "`t"
}

foreach ($entry in $entries) {
    if ($Catalog -ceq 'shifts') {
        [Console]::Out.WriteLine((Get-NSShiftLine -Slug $entry.Key -Path $entry.File))
    }
    else {
        [Console]::Out.WriteLine("$($entry.Key)`t$($entry.Title)`t$($entry.Description)`t$($entry.Source)`t$($entry.Replaced)")
    }
}
exit 0
