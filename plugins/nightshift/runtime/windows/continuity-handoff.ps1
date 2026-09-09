param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('fence-check')]
    [string]$Command,
    [string]$Project = '',
    [string]$Manifest = ''
)

# continuity-handoff.ps1  -  native worker fence. Reads lease / session / pid on disk.
#   continuity-handoff.ps1 -Command fence-check -Project DIR
# -Input JSON flags are ignored and cannot grant takeover.

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if (Test-Path Variable:PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $false
}

$pluginRoot = Resolve-Path (Join-Path $PSScriptRoot '../..')
Import-Module (Join-Path $pluginRoot 'lib/Nightshift.psm1') -Force -DisableNameChecking

# $Manifest is accepted so old call sites fail closed; its flags never grant takeover.
$null = $Manifest
$result = Test-NSHandoffFence -Project $Project
$payload = [ordered]@{
    action = $result.action
    duplicateWorkerRejected = $result.duplicateWorkerRejected
    kind = $result.kind
    priorOwnerFenced = $result.priorOwnerFenced
    priorWorkerActive = $result.priorWorkerActive
    schemaVersion = $result.schemaVersion
    takeoverAllowed = $result.takeoverAllowed
    twoActiveWorkersAllowed = $false
}
Write-Output ($payload | ConvertTo-Json -Depth 4)
exit $result.ExitCode
