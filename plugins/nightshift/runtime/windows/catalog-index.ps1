<#
.SYNOPSIS
  What a catalog holds, one line per entry.

.DESCRIPTION
  Mirrors runtime/catalog-index.sh. shifts, the default, reads references/compose/shifts and prints
  slug, ending, title and summary. evidence reads references/evidence/kinds and prints key, title
  and description. Callers that pass no catalog keep the shift listing, unchanged.

  Every entry opens with an H1, and that header is the metadata, so there is no second registry:
  a file added today is listed today, and one that is deleted stops being listed. A symlink is
  skipped. Reads the catalog and nothing else, writes nothing, ranks nothing.
  Exit: 0 listed - 1 usage - 2 no catalog to read
#>
param(
    [string]$PluginRoot = '',
    [string]$Catalog = 'shifts'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrEmpty($PluginRoot)) {
    $PluginRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
}

if ($Catalog -eq 'shifts') {
    $dir = Join-Path $PluginRoot 'skills/nightshift/references/compose/shifts'
    $mode = 'shift'
} elseif ($Catalog -eq 'evidence') {
    $dir = Join-Path $PluginRoot 'skills/nightshift/references/evidence/kinds'
    $mode = 'kind'
} else {
    [Console]::Error.WriteLine('catalog-index: unknown catalog: ' + $Catalog)
    exit 1
}

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
    $description = ''
    $seen = $false
    foreach ($line in [IO.File]::ReadAllLines($file.FullName)) {
        if (-not $seen) {
            if ($line.StartsWith('# ')) {
                $seen = $true
                $parts = $line.Substring(2) -split [regex]::Escape($sep)
                $title = $parts[0]
                if ($mode -eq 'kind') {
                    if ($parts.Count -ge 2) {
                        $description = ($parts[1..($parts.Count - 1)] -join $sep)
                    }
                } else {
                    if ($parts.Count -ge 2) { $ending = $parts[1] }
                    if ($parts.Count -ge 3) { $summary = ($parts[2..($parts.Count - 1)] -join ' - ') }
                }
            }
            continue
        }
        if ($mode -eq 'shift' -and [string]::IsNullOrEmpty($summary) -and $line.Length -gt 0 -and
            -not $line.StartsWith('#') -and -not [char]::IsWhiteSpace($line[0])) {
            $summary = $line
        }
    }
    $slug = [IO.Path]::GetFileNameWithoutExtension($file.Name)
    if ($mode -eq 'kind') {
        $cells = @($slug, $title, $description)
    } else {
        $cells = @($slug, $ending, $title, $summary)
    }
    $cells = $cells | ForEach-Object { $_ -replace "`t", ' ' }
    [Console]::Out.WriteLine($cells -join "`t")
}
exit 0
