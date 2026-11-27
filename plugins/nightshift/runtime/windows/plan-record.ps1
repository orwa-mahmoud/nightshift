<#
.SYNOPSIS
  Who did what to a plan, and whether the revision that would run is approved. Mirrors
  runtime/plan-record.sh.

.DESCRIPTION
    plan-record.ps1 -Project DIR -Plan NAME
    plan-record.ps1 -Project DIR -Plan NAME -Action proposed|approved|reviewed [-By NAME] [-Run RUN] [-Note TEXT]

  With no action, prints the plan's revision, whether the team needs an approval, its state, and
  every line of its record with the name on it (unknown for a line written without one). With an
  action, appends one attributed line to staging/records/<key>.md at the plan's current revision. The
  name is -By, or the Git user name of the work target. An approval is refused when the team's rules
  do not let that name's role approve this plan; nothing is written then.

  Prints one verdict per line: ok, or refuse followed by its repair.
  Exit: 0 printed or recorded - 1 refused - 2 usage
#>
param(
    [string]$Project = [Environment]::CurrentDirectory,
    [string]$Plan = '',
    [string]$Action = '',
    [string]$By = '',
    [string]$Run = '',
    [string]$Note = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if (Test-Path Variable:PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $false
}

$pluginRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).ProviderPath
Import-Module (Join-Path $pluginRoot 'lib/Nightshift.psm1') -Force -DisableNameChecking
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)

function Write-Verdict { param([string]$Kind, [string]$Text) [Console]::Out.Write($Kind + ' ' + $Text + "`n") }
function Stop-Refused {
    param([string]$Text, [string]$Repair = '')
    Write-Verdict 'refuse' $Text
    if ($Repair.Length -gt 0) { Write-Verdict 'repair' $Repair }
    exit 1
}

if ([string]::IsNullOrWhiteSpace($Plan)) { [Console]::Error.WriteLine('plan-record: -Plan is required'); exit 2 }
if (@('', 'proposed', 'approved', 'reviewed') -cnotcontains $Action) {
    [Console]::Error.WriteLine('plan-record: -Action must be proposed, approved or reviewed'); exit 2
}

try { $workspace = Resolve-NSWorkspaceRoot $Project }
catch { Stop-Refused "workspace no workspace at $Project" 'run Setup in the project first' }
$ns = Join-Path $workspace '.nightshift'
$key = Get-NSReceiptSlug $Plan
if ($key.Length -eq 0) { Stop-Refused "plan $Plan has no letters or digits to name it by" }
$recordFile = Get-NSPlanRecordFile $ns $key
if ($recordFile.Length -eq 0) {
    Stop-Refused 'layout this workspace keeps no plan records' 'preview the move to run folders with ns migrate-state, make it with -Apply'
}
$state = Get-NSPlanState $workspace $key
if ($null -eq $state) {
    Stop-Refused ("plan no plan named $Plan in " + (Get-NSLayoutName $ns 'plans')) 'list the waiting plans with ns plan-enter'
}

if ($Action.Length -eq 0) {
    foreach ($line in $state) { [Console]::Out.Write($line + "`n") }
    foreach ($entry in (Get-NSPlanRecordLines $recordFile)) {
        $at = $(if ($entry.Revision.Length -gt 0) { $entry.Revision } else { 'unknown' })
        [Console]::Out.Write("record $($entry.Action) by $($entry.Name) at $at`n")
    }
    exit 0
}

if ($By.Length -eq 0) {
    $target = $workspace
    try { $target = Resolve-NSWorkTarget $workspace } catch { $target = $workspace }
    $By = [string](& git -C $target config user.name 2>$null)
}
$By = $By.Replace("`r", '').Replace("`n", '')
if ([string]::IsNullOrWhiteSpace($By)) { Stop-Refused 'name no -By and no Git user name to record' 'pass -By with the name to put on the record' }
if ($By.Contains(' ' + [char]0x00B7 + ' ')) { Stop-Refused "name $By holds the record's separator" "pass a name without ' $([char]0x00B7) '" }

if ($Action -ceq 'approved') {
    $proposer = ''
    foreach ($entry in (Get-NSPlanRecordLines $recordFile)) { if ($entry.Action -ceq 'proposed') { $proposer = $entry.Name } }
    if (-not (Test-NSPlanMayApprove $workspace $By $proposer)) {
        $role = Get-NSTeamRole $workspace $By
        if ($role.Length -eq 0) { $role = 'no role' }
        Stop-Refused ("approve $By ($role) may not approve this plan; the team's approvers are " + ((Get-NSTeamList $workspace 'approvers') -join ',')) 'ask one of them to approve it'
    }
}

$extra = New-Object Collections.Generic.List[string]
if ($Run.Length -gt 0) { $extra.Add('run ' + $Run) }
if ($Note.Length -gt 0) { $extra.Add('note ' + $Note.Replace("`r", '').Replace("`n", '')) }
try { Add-NSPlanRecord -Workspace $workspace -Key $key -Action $Action -Name $By -Extra $extra.ToArray() }
catch { Stop-Refused ('record could not write ' + (Get-NSLayoutName $ns 'plan-records') + "/$key.md") 'check that .nightshift/ is writable, then run this again' }
$revision = (@($state | Where-Object { $_.StartsWith('revision ', [StringComparison]::Ordinal) })[0]).Substring(9)
Write-Verdict 'ok' "record $Action by $By at revision $revision"
exit 0
