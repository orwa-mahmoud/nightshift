<#
.SYNOPSIS
  What the shift catalog holds, one line per entry.

.DESCRIPTION
  Mirrors runtime/catalog-index.sh. Every entry opens with
  `# <title> - <ending> - <what it is for>`, so that header is the metadata and there is no second
  registry to keep in step: an entry added today is discovered today. Prints slug, ending, title
  and summary, tab-separated. Reads the catalog and nothing else, writes nothing, ranks nothing.
  Exit: 0 listed - 1 usage - 2 no catalog to read
#>
param(
    [string]$PluginRoot = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrEmpty($PluginRoot)) {
    $PluginRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
}

$dir = Join-Path $PluginRoot 'skills/nightshift/references/compose/shifts'
if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
    [Console]::Error.WriteLine('catalog-index: no catalog at ' + $dir)
    exit 2
}

$dash = [string][char]0x2014
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
                $parts = $line.Substring(2) -split [regex]::Escape(' ' + $dash + ' ')
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
    $cells = @($slug, $ending, $title, $summary) | ForEach-Object { $_ -replace "`t", ' ' }
    [Console]::Out.WriteLine($cells -join "`t")
}
exit 0
