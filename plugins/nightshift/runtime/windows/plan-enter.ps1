param(
    [string]$Project = '',
    [string]$HostName = ''
)

# plan-enter.ps1  -  open the plan room. Nothing is implemented in the conversation that enters it
# until the owner leaves it. Mirrors plan-enter.sh.
#   plan-enter.ps1 -Project DIR [-HostName claude|codex|cursor]
# The room opens unbound; the caller's very next tool call is the probe that binds it to that
# conversation: `$null = 'nightshift-plan-probe'` in PowerShell. An open room is left as it is.

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if (Test-Path Variable:PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $false
}

if ([string]::IsNullOrWhiteSpace($Project)) {
    [Console]::Error.WriteLine('plan-enter: -Project is required')
    exit 1
}
if ([string]::IsNullOrEmpty($HostName)) { $HostName = $(if ($env:NIGHTSHIFT_HOST) { $env:NIGHTSHIFT_HOST } else { 'claude' }) }
if ($HostName -cnotin @('claude', 'codex', 'cursor')) {
    [Console]::Error.WriteLine("plan-enter: unknown host: $HostName")
    exit 1
}

$pluginRoot = Resolve-Path (Join-Path $PSScriptRoot '../..')
Import-Module (Join-Path $pluginRoot 'lib/Nightshift.psm1') -Force -DisableNameChecking

try { $workspace = Resolve-NSWorkspaceRoot $Project }
catch {
    [Console]::Error.WriteLine("plan-enter: no workspace at $Project")
    exit 1
}
$ns = Join-Path $workspace '.nightshift'
if (-not (Test-Path -LiteralPath $ns -PathType Container) -or (Test-NSReparsePoint $ns)) {
    [Console]::Error.WriteLine("plan-enter: no .nightshift/ at $workspace - run Setup first")
    exit 1
}

# Write-PlanRecord - the plan record, created on first entry, and every plan it holds open: entering
# resumes from it.
function Write-PlanRecord {
    try { $null = Invoke-NSScaffold -Workspace $workspace -Keys @('plan-record') }
    catch { [Console]::Error.WriteLine('plan-enter: could not create ' + (Get-NSLayoutName $ns 'plan-record')) }
    Write-Output ('plan record ' + (Get-NSLayoutName $ns 'plan-record'))
    $open = Get-NSPlanRecordOpen $ns
    if ($open.Count -eq 0) { Write-Output 'open plan: none' }
    foreach ($line in $open) { Write-Output ('open plan: ' + $line) }
}

if (Test-NSPlanRoomOpen $ns) {
    $bound = Get-NSPlanRoomLine $ns 1
    if ($bound.Length -gt 0) { Write-Output "plan room already open, bound to conversation $bound" }
    else { Write-Output "plan room already open, waiting for its conversation: run `$null = 'nightshift-plan-probe' next" }
    Write-PlanRecord
    exit 0
}
$null = Enter-NSPlanRoom $ns $HostName
Write-NSControlLog $ns "plan room opened ($HostName)"
Write-Output "plan room open: run `$null = 'nightshift-plan-probe' as the next tool call to bind it to this conversation"
Write-Output ('plan goes in ' + (Get-NSPlanRoomPlaceName $ns))
Write-PlanRecord
exit 0
