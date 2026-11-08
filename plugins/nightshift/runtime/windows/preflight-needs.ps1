<#
.SYNOPSIS
  Permission preflight for native Windows.

.DESCRIPTION
  Mirrors runtime/preflight-needs.sh. Reads the `## Items` section of
  punch-list.md and every open item in work-orders.md, matches each item
  against the same rules.elevation patterns the hardhat guard uses, and reports
  the categories each item needs against the resolved policy. Reports only:
  it never writes and never refuses.
  Exit: 0 always (1 on usage)
#>
param(
    [string]$Project = [Environment]::CurrentDirectory,
    [switch]$Json
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$pluginRoot = Resolve-Path (Join-Path $PSScriptRoot '../..')
Import-Module (Join-Path $pluginRoot 'lib/Nightshift.psm1') -Force -DisableNameChecking

exit (Invoke-NSPreflightNeedsCommand -Project $Project -Json:$Json)
