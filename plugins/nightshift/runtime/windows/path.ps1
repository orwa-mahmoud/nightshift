<#
.SYNOPSIS
  Where a state file lives in this workspace's layout.

.DESCRIPTION
  Mirrors runtime/path.sh.

    path.ps1 [-Project DIR] <key>...    one absolute path per key, in the order named
    path.ps1 [-Project DIR] -List       every key with its path, tab separated

  The layout table beside the module is the one answer. A skill command names a
  key instead of spelling a path under .nightshift/, so the same command lands in
  the right place whichever layout the workspace keeps. Nothing is created or
  changed.

  Exit: 0 printed - 1 usage or a key this layout does not have
#>
param(
    [string]$Project = [Environment]::CurrentDirectory,
    [switch]$List,
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)][string[]]$Keys = @()
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$pluginRoot = Resolve-Path (Join-Path $PSScriptRoot '../..')
Import-Module (Join-Path $pluginRoot 'lib/Nightshift.psm1') -Force -DisableNameChecking

[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)

try {
    $workspace = Resolve-NSWorkspaceRoot $Project
}
catch {
    $workspace = ''
}
if ([string]::IsNullOrEmpty($workspace)) {
    [Console]::Error.WriteLine('path: invalid .nightshift-link - Nightshift will not guess a workspace')
    exit 1
}
$ns = Join-Path $workspace '.nightshift'

if ($List) {
    foreach ($key in (Get-NSMigrationKeys)) {
        if (-not (Test-NSLayoutKey $ns $key)) { continue }
        [Console]::Out.Write($key + "`t" + (Get-NSLayoutPath $ns $key '*') + "`n")
    }
    exit 0
}

if ($Keys.Count -eq 0) {
    [Console]::Error.WriteLine('path: name a state key, or -List')
    exit 1
}
foreach ($key in $Keys) {
    if ($key.StartsWith('-', [StringComparison]::Ordinal)) {
        [Console]::Error.WriteLine('path: unknown argument: ' + $key)
        exit 1
    }
    if (-not (Test-NSLayoutKey $ns $key)) {
        [Console]::Error.WriteLine('path: layout ' + (Get-NSLayoutVersion $ns) + ' has no ' + $key)
        exit 1
    }
    [Console]::Out.Write((Get-NSLayoutPath $ns $key) + "`n")
}
exit 0
