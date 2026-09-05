<#
.SYNOPSIS
  The layered shift policy for native Windows.

.DESCRIPTION
  Mirrors runtime/shift-policy.sh. rules.json holds the permanent boundaries and,
  in its shift block, the remembered composition choices; shift-policy.json is
  tonight's snapshot. `resolve` prints the one resolved view every other surface
  renders, and `migrate` moves a workspace that still carries the older
  shift-defaults.json onto the one-file shape.
  Exit: 0 ok - 1 usage - 2 contract failure - 3 absent - 4 refused while armed
#>
param(
    [string]$Project = [Environment]::CurrentDirectory,
    [Parameter(Position = 0)]
    [ValidateSet('', 'get', 'set', 'defaults-get', 'defaults-set', 'resolve', 'migrate', 'archive')]
    [string]$Command = '',
    [string]$FromJson = '',
    [ValidateSet('', 'fast', 'balanced', 'strict', 'custom')]
    [string]$VerificationProfile = '',
    [string]$Hours = '',
    [ValidateSet('', 'existing-tools', 'review-missing', 'auto-add')]
    [string]$ToolingPolicy = '',
    [ValidateSet('', 'review-first', 'run-direct')]
    [string]$Execution = '',
    [string]$Date = '',
    [switch]$Json,
    [switch]$Table,
    [switch]$DryRun
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$pluginRoot = Resolve-Path (Join-Path $PSScriptRoot '../..')
Import-Module (Join-Path $pluginRoot 'lib/Nightshift.psm1') -Force -DisableNameChecking

exit (Invoke-NSShiftPolicyCommand -Project $Project -Command $Command -FromJson $FromJson `
        -VerificationProfile $VerificationProfile -Hours $Hours -ToolingPolicy $ToolingPolicy `
        -Execution $Execution -Date $Date -Json:$Json -Table:$Table -DryRun:$DryRun)
