<#
.SYNOPSIS
  Start one catalog entry from the template in force.

.DESCRIPTION
  Mirrors runtime/catalog-new.sh. Copies the template in force into the project folder
  (.nightshift\catalogs\<Catalog>\), or with -User into %APPDATA%\nightshift\catalogs\<Catalog>\,
  as <Key>.md, and prints the new file's path. Refuses a key that is not lowercase words joined by
  hyphens, and a file that already exists: nothing is overwritten.
  Exit: 0 written - 1 usage - 2 refused
#>
param(
    [string]$Catalog = '',
    [string]$Key = '',
    [switch]$User,
    [string]$Project = '',
    [Alias('plugin-root')][string]$PluginRoot = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrEmpty($PluginRoot)) {
    $PluginRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
}
if ([string]::IsNullOrEmpty($Catalog) -or [string]::IsNullOrEmpty($Key)) {
    [Console]::Error.WriteLine('catalog-new: --catalog and --key are required')
    exit 1
}

. (Join-Path $PSScriptRoot '../../lib/catalog-sources.ps1')
Import-Module (Join-Path $PluginRoot 'lib/Nightshift.psm1') -Force -DisableNameChecking

$row = Get-NSCatalogRow -Name $Catalog
if ($null -eq $row) {
    $names = (Get-NSCatalogRows | ForEach-Object { $_.Name }) -join ' '
    [Console]::Error.WriteLine("catalog-new: unknown catalog: $Catalog (one of: $names)")
    exit 1
}
if (-not (Test-NSCatalogKey $Key)) {
    [Console]::Error.WriteLine("catalog-new: $Key is not a key: use lowercase words joined by hyphens")
    exit 2
}

if ($User) {
    $dir = Join-Path (Join-Path (Get-NSCatalogUserRoot) 'catalogs') $Catalog
}
else {
    if ([string]::IsNullOrEmpty($Project)) {
        [Console]::Error.WriteLine('catalog-new: --project is required for a project entry; pass --user for every project')
        exit 1
    }
    $dir = Get-NSLayoutPath (Join-Path $Project '.nightshift') ('catalog-' + $Catalog)
}

$template = Get-NSCatalogTemplate -PluginRoot $PluginRoot -Workspace $Project -Row $row
if (-not (Test-Path -LiteralPath $template -PathType Leaf) -or (Test-NSReparsePoint $template)) {
    [Console]::Error.WriteLine("catalog-new: no template at $template")
    exit 2
}
$target = Join-Path $dir ($Key + '.md')
if (Test-Path -LiteralPath $target) {
    [Console]::Error.WriteLine("catalog-new: $target already exists")
    exit 2
}
$null = New-Item -ItemType Directory -Force -Path $dir
Copy-Item -LiteralPath $template -Destination $target
[Console]::Out.WriteLine($target)
exit 0
