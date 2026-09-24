# migrate-state.ps1 - move a workspace's state files into the current layout.
#
#   migrate-state.ps1 [-Project DIR] [-Apply]
#
# Previews by default: every move, every settings block renamed, every link written again so it
# still resolves, every conflict, and everything left in place because no Nightshift file has its
# name. Nothing changes until it runs with -Apply, which performs exactly what the preview lists.
# It refuses while the shift is armed, while a watchman is alive and while a lock is held, and it
# never deletes or overwrites: a destination that already holds different content refuses the whole
# run by name. The state-version marker is written last, so a run that stops part way is finished by
# running it again, and a second run changes nothing.
#
# Explicit owner action only. Hooks, Start, Status, Archive and recovery never invoke this.
#
# Exit: 0 previewed, applied, or nothing to do - 1 refused (armed, watchman, lock) - 2 unsupported
#       state - 3 a move or write failed - 4 usage - 5 conflict
param(
    [string]$Project = [Environment]::CurrentDirectory,
    [switch]$Apply
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$pluginRoot = Resolve-Path (Join-Path $PSScriptRoot '../..')
Import-Module (Join-Path $pluginRoot 'lib/Nightshift.psm1') -Force -DisableNameChecking

try {
    $hostPath = Resolve-NSCanonicalPath $Project
}
catch {
    [Console]::Error.WriteLine("migrate-state: cannot cd to $Project")
    exit 4
}

try {
    $workspace = Resolve-NSWorkspaceRoot $hostPath
}
catch {
    [Console]::Error.WriteLine('migrate-state: invalid .nightshift-link - Nightshift will not guess a workspace')
    exit 2
}

function Write-NSPlanLines {
    param([Parameter(Mandatory = $true)][string]$Mode, [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Records)
    foreach ($line in (Format-NSMigrationPlan -Mode $Mode -Records $Records)) { Write-Output $line }
}

$plan = Get-NSMigrationPlan $workspace
if ($plan.Code -ne 0) {
    foreach ($record in $plan.Records) {
        if ($record.StartsWith("refuse`t", [StringComparison]::Ordinal)) {
            [Console]::Error.WriteLine('migrate-state: ' + $record.Substring(7))
        }
    }
    exit 2
}
$records = $plan.Records
$from = ''
foreach ($record in $records) {
    if ($record.StartsWith("state`t", [StringComparison]::Ordinal)) { $from = $record.Substring(6) }
}
Write-Output ('migrate-state: ' + (Join-Path $workspace '.nightshift') + ' is state-version ' + $from + '; version ' +
    (Get-NSCurrentStateVersion) + ' groups it by purpose')

$refused = @($records | Where-Object { $_.StartsWith("refuse`t", [StringComparison]::Ordinal) }).Count -gt 0
$conflicted = @($records | Where-Object { $_.StartsWith("conflict`t", [StringComparison]::Ordinal) }).Count -gt 0
if ($refused) {
    Write-NSPlanLines 'preview' $records
    exit 1
}
if ($conflicted) {
    Write-NSPlanLines 'preview' $records
    exit 5
}
if (-not $Apply) {
    Write-NSPlanLines 'preview' $records
    exit 0
}
if ((Invoke-NSMigrationApply $workspace $records) -ne 0) {
    Write-NSPlanLines 'preview' @($records | Where-Object { -not $_.StartsWith("marker`t", [StringComparison]::Ordinal) })
    [Console]::Error.WriteLine('migrate-state: stopped part way - what finished stands and state-version is unchanged; run it again to finish')
    exit 3
}
Write-NSPlanLines 'apply' $records
exit 0
