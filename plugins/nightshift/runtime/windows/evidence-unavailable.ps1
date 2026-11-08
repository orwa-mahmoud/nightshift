param(
    [string]$Project = '',
    [string]$Item = '',
    [string]$Reason = ''
)

# evidence-unavailable.ps1 - apply the item's unavailable setting.
#   evidence-unavailable.ps1 -Project DIR -Item LABEL -Reason TEXT
# hold closes the item as stopped. park writes one parking-lot entry. note ticks it.
# -Project and -Item are required. Does not use the current working directory.

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if (Test-Path Variable:PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $false
}

if ([string]::IsNullOrWhiteSpace($Project) -or [string]::IsNullOrWhiteSpace($Item)) {
    [Console]::Error.WriteLine('evidence-unavailable: -Project and -Item are required')
    exit 1
}

$pluginRoot = Resolve-Path (Join-Path $PSScriptRoot '../..')
Import-Module (Join-Path $pluginRoot 'lib/Nightshift.psm1') -Force -DisableNameChecking

$applied = Invoke-NSEvidenceUnavailable -Workspace $Project -Label $Item -Reason $Reason
if ([string]::IsNullOrEmpty($applied)) {
    [Console]::Error.WriteLine('evidence-unavailable: no such item: ' + $Item)
    exit 1
}
Write-Output $applied
exit 0
