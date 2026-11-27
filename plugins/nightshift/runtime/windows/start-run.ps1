<#
.SYNOPSIS
  Start a named plan as a run of its own. Mirrors runtime/start-run.sh.

.DESCRIPTION
    start-run.ps1 -Project DIR -Plan NAME -HostName claude|codex|cursor [-Background] [-Settings NAME]
                  [-Consent DIGEST]

  A team whose rules name approvers runs only an approved revision of a plan: one whose contract,
  gates or items, as team.reviewChanges names them, have not changed since an approver approved it. On
  a site that shares its plans, the runner consents to exactly what the run would execute before
  anything of it runs: without -Consent, or with one for other inputs, this prints those inputs and
  the consent that covers them, and places nothing. A started run is written to the plan's record
  with the runner's Git user name.

  -Settings selects a member's settings file, settings/<NAME>.json, for this run alone: its values are
  laid over the team's rules.json, beneath the run's own rules file, and reach every helper the run
  starts. A file that changes anything the team does not let a member change is refused before
  anything is placed.

  In a workspace that keeps runs, a plan waiting in staging/plans/ becomes a run. Its folder under
  runs/ is claimed first, named by runs.layout from the plan's title; the plan's punch list is written
  into it with the run's own paths; in repository mode the run is set to work in a git worktree of its
  own (a run rules file holding shift.isolation, unless the run already has one), and the Start
  preflight, snapshot and worktree phases run for it. Only when every step has succeeded does the plan
  leave staging, so a failed step leaves the plan staged and the owner's checkout and index as they
  were, and running this again finishes the run instead of making a second one. On a site that shares
  its plans through Git the plan stays staged as the team's record and the run works from its own
  copy; a teammate's run of the same plan, pulled through Git, is never taken over.

  Without -Background, Start continues in the conversation that asked, with NIGHTSHIFT_RUN set to the
  run printed here. With -Background, this arms the run, takes its lease for a hidden headless worker
  started the way the watchman starts a fresh one, and starts the run's watchman. A run whose lease
  names a live worker is never started twice.

  Prints one verdict per line: `ok run <name>`, then `ok`, `warn` or `refuse` lines, each refusal
  followed by its `repair`.
  Exit: 0 placed (and started, with -Background) - 1 refused - 2 usage
#>
param(
    [string]$Project = [Environment]::CurrentDirectory,
    [string]$Plan = '',
    [string]$HostName = '',
    [switch]$Background,
    [string]$Settings = '',
    [string]$Consent = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if (Test-Path Variable:PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $false
}

$pluginRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).ProviderPath
Import-Module (Join-Path $pluginRoot 'lib/Nightshift.psm1') -Force -DisableNameChecking
$utf8 = New-Object Text.UTF8Encoding($false)

function Write-Verdict { param([string]$Kind, [string]$Text) [Console]::Out.Write($Kind + ' ' + $Text + "`n") }
function Stop-Refused {
    param([string]$Text, [string]$Repair = '')
    Write-Verdict 'refuse' $Text
    if ($Repair.Length -gt 0) { Write-Verdict 'repair' $Repair }
    exit 1
}

# Invoke-NSRunPhase <name> - one Start preflight phase for this run, its verdicts relayed; $false on
# refusal.
function Invoke-NSRunPhase {
    param([Parameter(Mandatory = $true)][string]$Name)
    $script = Join-Path $PSScriptRoot 'start-preflight.ps1'
    $shell = (Get-Process -Id $PID).Path
    if ($Name -eq 'preflight') {
        $out = @(& $shell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $script -Project $workspace -HostName $HostName 2>&1)
    }
    else {
        $out = @(& $shell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $script -Project $workspace -Phase $Name 2>&1)
    }
    $code = $LASTEXITCODE
    foreach ($line in $out) {
        $text = [string]$line
        if ($text -cmatch '^(warn|refuse|explain|repair) ' -or ($Name -eq 'worktree' -and $text -cmatch '^ok worktree ')) {
            [Console]::Out.Write($text + "`n")
        }
    }
    return ($code -eq 0)
}

$Plan = $Plan.Replace("`r", '').Replace("`n", '')
if ([string]::IsNullOrWhiteSpace($Plan)) { [Console]::Error.WriteLine('start-run: -Plan is required'); exit 2 }
if (@('claude', 'codex', 'cursor') -notcontains $HostName) {
    [Console]::Error.WriteLine('start-run: -HostName must be claude, codex or cursor'); exit 2
}

try { $workspace = Resolve-NSWorkspaceRoot $Project }
catch { Stop-Refused "workspace no workspace at $Project" 'run Setup in the project first' }
$ns = Join-Path $workspace '.nightshift'
if (-not (Test-Path -LiteralPath $ns -PathType Container) -or (Test-NSReparsePoint $ns)) {
    Stop-Refused "workspace no .nightshift/ at $workspace" 'run Setup in the project first'
}
if (-not (Test-NSLayoutPerRun $ns 'punch-list')) {
    Stop-Refused 'layout this workspace keeps one shift at a time' 'preview the move to run folders with ns migrate-state, make it with -Apply, then run this again'
}

# A member's settings are checked before anything is placed, so a refused file leaves no run behind.
if ($Settings.Length -gt 0) {
    $problems = Get-NSMemberSettingsProblems $workspace $Settings
    if ($problems.Count -gt 0) {
        Write-Verdict 'refuse' "settings $Settings cannot be selected for this run"
        foreach ($problem in $problems) { Write-Verdict 'explain' $problem }
        Write-Verdict 'repair' 'take those settings out of the file, or ask the team to allow them in team.memberSettings, then run this again'
        exit 1
    }
}

$key = Get-NSReceiptSlug $Plan
if ($key.Length -eq 0) { Stop-Refused "plan $Plan has no letters or digits to name it by" }
$planFile = Join-Path (Get-NSLayoutPath $ns 'plans') ($key + '.md')
$staged = (Test-Path -LiteralPath $planFile -PathType Leaf) -and -not (Test-NSReparsePoint $planFile)

# ---------------------------------------------------------------- approval and consent
# Both are settled before anything is placed or run, so a refusal leaves no side effect.
$inputsDigest = ''
if ($staged -and (Get-NSPlanRecordFile $ns $key).Length -gt 0) {
    $state = Get-NSPlanState $workspace $key
    if ($null -eq $state) { Stop-Refused "plan the revision of $Plan cannot be read" 'run ns doctor, then run this again' }
    if (($state -ccontains 'approval required') -and -not ($state -ccontains 'state approved')) {
        $field = { param($Name) $hit = @($state | Where-Object { $_.StartsWith($Name + ' ', [StringComparison]::Ordinal) }); if ($hit.Count -gt 0) { $hit[0].Substring($Name.Length + 1) } else { '' } }
        $revision = & $field 'revision'
        $changed = & $field 'changed'
        $lastApproval = & $field 'approved-by'
        if ($changed.Length -gt 0) {
            $by = $lastApproval.Substring(0, $lastApproval.LastIndexOf(' '))
            $was = $lastApproval.Substring($lastApproval.LastIndexOf(' ') + 1)
            Stop-Refused "approval $Plan changed its $changed since $by approved revision $was, so revision $revision is proposed" `
                "an approver reviews the change and records it with ns plan-record --plan `"$Plan`" --action approved"
        }
        Stop-Refused "approval $Plan revision $revision is proposed: no approver has approved it" `
            "an approver reviews it and records it with ns plan-record --plan `"$Plan`" --action approved"
    }
    if (Test-NSSiteShares $workspace 'plans') {
        $inputs = Get-NSRunInputs $workspace $planFile $Settings
        $inputsDigest = Get-NSRunConsent $inputs
        if ($Consent -cne $inputsDigest) {
            if ($Consent.Length -gt 0) { Write-Verdict 'refuse' "consent what this run would execute changed since consent $Consent was given" }
            else { Write-Verdict 'refuse' 'consent read what this run would execute before it starts' }
            foreach ($line in $inputs) { Write-Verdict 'input' $line }
            Write-Verdict 'repair' "read those inputs, then run this again with --consent $inputsDigest"
            exit 1
        }
        Write-Verdict 'ok' "consent $inputsDigest covers what this run executes"
    }
}

# The run a plan already went into in this clone is reused: its punch list carries the plan's title.
# Otherwise the folder is claimed now, before anything is written, so a second start of the same plan
# finds it.
$sharedReceipts = Test-NSSiteShares $workspace 'receipts'
$run = ''
foreach ($candidate in (Get-NSLayoutRuns $ns)) {
    $list = [IO.Path]::Combine($ns, 'runs', $candidate, 'punch-list.md')
    if (-not [IO.File]::Exists($list) -or (Test-NSReparsePoint $list)) { continue }
    if ($sharedReceipts -and -not (Test-NSRunIsLocal $ns $candidate)) { continue }
    if ((Get-NSReceiptSlug (Get-NSShiftName $list)) -ceq $key) { $run = $candidate; break }
}
if ($run.Length -eq 0) {
    if (-not $staged) {
        Stop-Refused ("plan no plan named $Plan in " + (Get-NSLayoutName $ns 'plans')) 'list the waiting plans with ns plan-enter, or open the plan room to write one'
    }
    $dir = Get-NSRunDir -Workspace $workspace -Date (Get-Date -Format 'yyyy-MM-dd') -ShiftId 'unknown' -Name (Get-NSShiftName $planFile)
    if ($null -eq $dir) { Stop-Refused ('run could not claim a run folder under ' + (Join-Path $ns 'runs')) 'check that .nightshift/ is writable, then run this again' }
    $run = Split-Path -Leaf $dir
}
$env:NIGHTSHIFT_RUN = $run
Write-Verdict 'ok' "run $run"

# The member settings this run uses, kept with the run's own runtime files: the choice is the
# runner's, and every helper of the run reads it from there.
$selection = Get-NSLayoutPath $ns 'member-settings'
$selected = ''
if ([IO.File]::Exists($selection)) {
    $lines = @([IO.File]::ReadAllLines($selection))
    if ($lines.Count -gt 0) { $selected = $lines[0].TrimEnd("`r") }
}
if ($Settings.Length -gt 0) {
    if ($selected.Length -gt 0 -and $selected -cne $Settings) {
        Stop-Refused "settings run $run already uses settings/$selected.json" 'start it again without -Settings, or file that run with Archive first'
    }
    if ($selected.Length -eq 0) {
        try {
            $null = New-Item -ItemType Directory -Path (Split-Path -Parent $selection) -Force
            [IO.File]::WriteAllText($selection, $Settings + "`n", $utf8)
        }
        catch { Stop-Refused "settings could not write $selection" 'check that .nightshift/ is writable, then run this again' }
    }
    $selected = $Settings
}
if ($selected.Length -gt 0) {
    Write-Verdict 'ok' "settings settings/$selected.json over the team's rules.json, for this run"
}

# A run already worked by a live process is not started twice, and nothing of it is redone.
if ($Background) {
    $held = Read-NSLease $ns
    if ($null -ne $held -and -not [string]::IsNullOrEmpty($held.Pid) -and (Test-NSRecordedProcess $held.Pid $held.Start) -eq 'Alive') {
        Write-Verdict 'ok' "worker already running for $run (pid $($held.Pid))"
        exit 0
    }
}

$punch = Get-NSLayoutPath $ns 'punch-list'
if (Test-Path -LiteralPath $punch) {
    if ((Test-NSReparsePoint $punch) -or (Get-NSReceiptSlug (Get-NSShiftName $punch)) -cne $key) {
        Stop-Refused "run $run already holds another punch list" 'pick another plan name, or file that run with Archive first'
    }
    Write-Verdict 'ok' ('punch-list ' + (Get-NSLayoutName $ns 'punch-list') + ' holds the plan')
}
else {
    $tmp = $punch + '.tmp.' + $PID
    try {
        # A run the team shares names its paths from the workspace root, so its punch list reads the
        # same in every clone and carries no runner's own folders into Git.
        $text = $(if ($sharedReceipts) { Get-NSOwnerTemplateText -Source $planFile -Workspace '.' -RunDir ('./.nightshift/runs/' + $run) -Relative }
            else { Get-NSOwnerTemplateText -Source $planFile -Workspace $workspace -RunDir ([IO.Path]::Combine($ns, 'runs', $run)) })
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $punch) -Force
        [IO.File]::WriteAllText($tmp, $text, $utf8)
        Move-Item -LiteralPath $tmp -Destination $punch -Force
    }
    catch {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
        Stop-Refused ('punch-list could not write ' + (Get-NSLayoutName $ns 'punch-list')) 'check that .nightshift/ is writable, then run this again'
    }
    Write-Verdict 'ok' ('punch-list the plan is written to ' + (Get-NSLayoutName $ns 'punch-list'))
}
try { $null = Invoke-NSScaffold -Workspace $workspace -Keys (Get-NSScaffoldKeys @()) }
catch { Stop-Refused ('scaffold ' + $_.Exception.Message) 'check that .nightshift/ is writable, then run this again' }

# Runs share the owner's checkout only through git: each one that writes code works in a worktree of
# its own. The run's own rules file says so, where the owner can read and change it.
if ((Get-NSWorkMode $workspace) -ne 'artifact') {
    $runRules = [IO.Path]::Combine($ns, 'runs', $run, (Get-NSLayoutRelativePathAt (Get-NSLayoutVersion $ns) 'rules'))
    if (-not (Test-Path -LiteralPath $runRules)) {
        try { [IO.File]::WriteAllText($runRules, "{`n  `"shift`": {`n    `"isolation`": `"worktree`"`n  }`n}`n", $utf8) }
        catch { Stop-Refused "rules could not write $runRules" 'check that .nightshift/ is writable, then run this again' }
    }
}
if (-not (Invoke-NSRunPhase 'preflight')) { Stop-Refused 'preflight the run was not started' 'fix what the preflight named, then run this again' }
if (-not (Invoke-NSRunPhase 'snapshot')) { Stop-Refused "snapshot the run's shift policy could not be recorded" 'run ns doctor, then run this again' }
if (-not (Invoke-NSRunPhase 'worktree')) { Stop-Refused 'worktree the run has no worktree' 'fix what the worktree step named, then run this again' }

# The plan leaves staging once the run holds everything it needs. A plan the team shares stays where
# teammates read and edit it.
function Remove-NSStagedPlan {
    if (-not $staged) { return }
    if (Test-NSSiteShares $workspace 'plans') {
        Write-Verdict 'ok' ("plan $Plan stays in " + (Get-NSLayoutName $ns 'plans') + " as the team's record; the run works from its own copy")
        return
    }
    try { Remove-Item -LiteralPath $planFile -Force }
    catch { Stop-Refused "plan could not take $planFile out of staging" 'remove it by hand; the run already holds it' }
    Write-Verdict 'ok' "plan $Plan left staging"
}

# The plan's record names who started this run, from which revision, with which consent.
function Add-NSRunStartRecord {
    if (-not $staged -or (Get-NSPlanRecordFile $ns $key).Length -eq 0) { return }
    $target = $workspace
    try { $target = Resolve-NSWorkTarget $workspace } catch { $target = $workspace }
    $who = ([string](& git -C $target config user.name 2>$null)).Replace("`r", '').Replace("`n", '')
    if ($who.Length -eq 0) { $who = 'unknown' }
    $extra = @("run $run")
    if ($inputsDigest.Length -gt 0) { $extra += "inputs $inputsDigest" }
    try {
        Add-NSPlanRecord -Workspace $workspace -Key $key -Action 'started' -Name $who -Extra $extra
        Write-Verdict 'ok' "record started by $who"
    }
    catch { Write-Verdict 'warn' ('record the start could not be written to ' + (Get-NSLayoutName $ns 'plan-records') + "/$key.md") }
}

if (-not $Background) {
    Add-NSRunStartRecord
    Remove-NSStagedPlan
    Write-Verdict 'ok' "next run Start in this conversation with NIGHTSHIFT_RUN=$run"
    exit 0
}

$prompt = Expand-NSInjectedPaths $workspace (Get-NSRule $workspace 'freshRevivalPrompt' ([string]$env:NIGHTSHIFT_FRESH_PROMPT))
if ([string]::IsNullOrEmpty($prompt)) {
    Stop-Refused ('rules freshRevivalPrompt is missing from ' + (Get-NSLayoutName $ns 'rules')) 'run Setup again, then run this again'
}
$scope = Get-NSRecoveryEffectiveScope $workspace $HostName
$worker = Get-NSBackgroundWorkerCommand -Workspace $workspace -HostName $HostName -Scope $scope -Prompt $prompt
if ($worker.Error.Length -gt 0) { Stop-Refused ('worker ' + $worker.Error) (Get-NSRecoveryRepair $workspace $scope) }
if ($null -eq (Get-Command $worker.Name -ErrorAction SilentlyContinue)) {
    Stop-Refused ('worker ' + $worker.Name + ' is not installed or not on PATH') "install and sign in to the $HostName CLI, then run this again"
}
$workTarget = Resolve-NSWorkTarget $workspace
$armed = Get-NSLayoutPath $ns 'armed'
try { [IO.File]::WriteAllText($armed, '', $utf8) }
catch { Stop-Refused "armed could not write $armed" 'check that .nightshift/ is writable, then run this again' }
$workerPid = Start-NSBackgroundWorker -NightshiftDir $ns -HostName $HostName -WorkTarget $workTarget -Workspace $workspace `
    -CommandName $worker.Name -CommandArguments $worker.Arguments
if ($workerPid -le 0) {
    Remove-Item -LiteralPath $armed -Force -ErrorAction SilentlyContinue
    Stop-Refused "worker the $HostName CLI could not be started headless" ('check that ' + $worker.Name + ' is installed and signed in, then run this again')
}
[IO.File]::AppendAllText((Get-NSLayoutPath $ns 'shift-log'), ('{0} - shift started in the background (run {1}, pid {2})' -f (Get-NSLocalNow -Seconds), $run, $workerPid) + [Environment]::NewLine, $utf8)
Write-Verdict 'ok' "worker started for $run (pid $workerPid)"
Add-NSRunStartRecord
Remove-NSStagedPlan
$shell = (Get-Process -Id $PID).Path
$watch = @(& $shell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'start-watchman.ps1') -Project $workspace -HostName $HostName 2>&1)
if ($LASTEXITCODE -eq 0) {
    Write-Verdict 'ok' ([string]($watch | Select-Object -Last 1))
}
else {
    Write-Verdict 'warn' ("watchman did not arm for $run, so nothing revives its worker if it dies: " + [string]($watch | Select-Object -Last 1))
    Write-Verdict 'repair' "set NIGHTSHIFT_RUN=$run and run ns start-watchman -HostName $HostName"
}
exit 0
