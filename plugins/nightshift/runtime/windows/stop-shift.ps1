param(
    [string]$Project = '',
    [string]$Reason = 'stopped by owner',
    [string]$Run = ''
)

# stop-shift.ps1  -  issue a stop-work order. Hardhat stays until clock-out writes ENDED.
#   stop-shift.ps1 -Project DIR [-Reason TEXT] [-Run NAME]
# -Project is required. Does not use the current working directory.

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if (Test-Path Variable:PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $false
}

if ([string]::IsNullOrWhiteSpace($Project)) {
    [Console]::Error.WriteLine('stop-shift: -Project is required')
    exit 1
}

$pluginRoot = Resolve-Path (Join-Path $PSScriptRoot '../..')
Import-Module (Join-Path $pluginRoot 'lib/Nightshift.psm1') -Force -DisableNameChecking

try {
    $lines = @(Stop-NSShift -Project $Project -Reason $Reason -Run $Run)
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
$lines | ForEach-Object { Write-Output $_ }
if ($lines -contains 'watchman unverified') { exit 2 }
exit 0
