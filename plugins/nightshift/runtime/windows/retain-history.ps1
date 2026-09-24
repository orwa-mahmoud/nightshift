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
    [Console]::Error.WriteLine("retain-history: cannot cd to $Project")
    exit 1
}

try {
    $workspace = Resolve-NSWorkspaceRoot $hostPath
}
catch {
    [Console]::Error.WriteLine('retain-history: invalid .nightshift-link - Nightshift will not guess a workspace')
    exit 2
}

$kind = Get-NSStateKind $workspace
if ($kind -in @('malformed', 'future')) {
    [Console]::Error.WriteLine("retain-history: $(Get-NSStateRefuseMessage $kind)")
    exit 2
}
if ($kind -eq 'absent') {
    [Console]::Error.WriteLine("retain-history: no .nightshift/ at $workspace")
    exit 2
}

$ns = Join-Path $workspace '.nightshift'
$logDays = Get-NSRetentionDays $workspace 'runtimeLogDays'
$archDays = Get-NSRetentionDays $workspace 'archiveDays'
$armed = Test-Path -LiteralPath (Get-NSLayoutPath $ns 'armed') -PathType Leaf

Write-Output 'Nightshift retention preview'
Write-Output "Workspace:      $workspace"
Write-Output "runtimeLogDays: $logDays"
Write-Output "archiveDays:    $archDays"
if ($armed) {
    Write-Output 'Armed:          yes - deletion is refused until the shift is unarmed'
}
else {
    Write-Output 'Armed:          no'
}
Write-Output ''

$eligible = @(Get-NSRetentionEligible $workspace)
if ($eligible.Count -eq 0) {
    Write-Output 'Eligible: none'
    if ($logDays -eq 0 -and $archDays -eq 0) {
        Write-Output 'Both rules are 0 (keep forever). Upgrading changes nothing until the owner opts in.'
    }
    exit 0
}

Write-Output 'Eligible'
foreach ($row in $eligible) {
    Write-Output ("  {0}  age={1}d  rule={2}:{3}" -f $row.Rel, $row.Age, $row.Kind, $row.Days)
}

if (-not $Apply) {
    Write-Output ''
    Write-Output 'Dry run. Re-run with -Apply after explicit confirmation to delete only the listed paths.'
    exit 0
}

if ($armed) {
    [Console]::Error.WriteLine('retain-history: refuse to delete while the shift is armed')
    exit 2
}

$code = Invoke-NSRetentionApply $workspace
switch ($code) {
    0 {
        Write-Output ''
        Write-Output 'Deleted the eligible allowlisted paths.'
        exit 0
    }
    1 {
        [Console]::Error.WriteLine('retain-history: refuse to delete while the shift is armed')
        exit 2
    }
    default {
        [Console]::Error.WriteLine('retain-history: refused or failed to delete a target')
        exit 3
    }
}
