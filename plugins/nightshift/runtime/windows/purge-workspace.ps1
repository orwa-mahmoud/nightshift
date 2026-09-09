param(
    [string]$Project = '',
    [string]$ConfirmPath = ''
)

# purge-workspace.ps1  -  delete this project's Nightshift state. Does not uninstall the plugin.
#   purge-workspace.ps1 -Project DIR -ConfirmPath C:\canonical\.nightshift
# -Project and -ConfirmPath are required. Does not use the current working directory.

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if (Test-Path Variable:PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $false
}

if ([string]::IsNullOrWhiteSpace($Project)) {
    [Console]::Error.WriteLine('purge-workspace: -Project is required')
    exit 1
}

$pluginRoot = Resolve-Path (Join-Path $PSScriptRoot '../..')
Import-Module (Join-Path $pluginRoot 'lib/Nightshift.psm1') -Force -DisableNameChecking

if ([string]::IsNullOrWhiteSpace($ConfirmPath)) {
    try {
        $ctx = Resolve-NSControlWorkspace $Project
        $expected = Join-Path $ctx.Workspace '.nightshift'
        [Console]::Error.WriteLine("purge-workspace: refusing without --confirm-path $expected")
    }
    catch {
        [Console]::Error.WriteLine('purge-workspace: --confirm-path is required')
    }
    exit 1
}

try {
    $lines = @(Remove-NSNightshiftWorkspace -Project $Project -ConfirmPath $ConfirmPath)
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
$lines | ForEach-Object { Write-Output $_ }
exit 0
