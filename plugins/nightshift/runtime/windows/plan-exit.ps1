param(
    [string]$Project = ''
)

# plan-exit.ps1  -  the owner leaves the plan room from a terminal. Mirrors plan-exit.sh.
#   plan-exit.ps1 -Project DIR
# The terminal exit on every host, and the only one on a host whose prompt hook did not see the
# owner's command. Hardhat refuses this command to every agent tool call while the room is open, so
# running it is the owner's own act.

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if (Test-Path Variable:PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $false
}

if ([string]::IsNullOrWhiteSpace($Project)) {
    [Console]::Error.WriteLine('plan-exit: -Project is required')
    exit 1
}

$pluginRoot = Resolve-Path (Join-Path $PSScriptRoot '../..')
Import-Module (Join-Path $pluginRoot 'lib/Nightshift.psm1') -Force -DisableNameChecking

try { $workspace = Resolve-NSWorkspaceRoot $Project }
catch {
    [Console]::Error.WriteLine("plan-exit: no workspace at $Project")
    exit 1
}
$ns = Join-Path $workspace '.nightshift'
if (-not (Test-Path -LiteralPath $ns -PathType Container) -or (Test-NSReparsePoint $ns)) {
    [Console]::Error.WriteLine("plan-exit: no .nightshift/ at $workspace")
    exit 1
}

if (-not (Test-NSPlanRoomOpen $ns)) {
    Write-Output 'plan room was not open'
    exit 0
}
if (-not (Exit-NSPlanRoom $ns 'ran plan-exit in a terminal')) {
    [Console]::Error.WriteLine('plan-exit: could not remove ' + (Get-NSLayoutName $ns 'plan-room'))
    exit 1
}
Write-Output 'plan room closed: nothing is fenced any more'
exit 0
