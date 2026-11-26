<#
.SYNOPSIS
  Read-only shift status for native Windows.
#>
param(
    [string]$Project = [Environment]::CurrentDirectory,
    [string]$Run = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$pluginRoot = Resolve-Path (Join-Path $PSScriptRoot '../..')
Import-Module (Join-Path $pluginRoot 'lib/Nightshift.psm1') -Force -DisableNameChecking
$workspace = Resolve-NSWorkspaceRoot $Project
exit (Write-NSStatusReport -Workspace $workspace -Run $Run)
