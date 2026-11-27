# Team rules and member settings on native Windows: the PowerShell half of tests/team-settings.bats.
# Run on macOS or Windows: pwsh -File tests/windows/team-settings-logic.ps1
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if (Test-Path Variable:PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $false
}

$repository = Resolve-Path (Join-Path $PSScriptRoot '../..')
$plugin = Join-Path $repository 'plugins/nightshift'
Import-Module (Join-Path $plugin 'lib/Nightshift.psm1') -Force -DisableNameChecking
$rulesTemplate = Join-Path $plugin 'config/nightshift-rules-template.json'
$hostExe = (Get-Process -Id $PID).Path
$failures = New-Object 'System.Collections.Generic.List[string]'
$utf8 = New-Object Text.UTF8Encoding($false)

function Expect-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        $failures.Add($Message)
        Write-Host "FAIL: $Message"
    }
}

function Write-Text { param([string]$Path, [string]$Text) [IO.File]::WriteAllText($Path, $Text, $utf8) }

# Invoke-Helper <script> <arguments> [run] - a runtime helper's output and exit code.
function Invoke-Helper {
    param([string]$Script, [string[]]$Arguments, [string]$Run = '')
    $saved = $env:NIGHTSHIFT_RUN
    $env:NIGHTSHIFT_RUN = $(if ($Run.Length -gt 0) { $Run } else { $null })
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = @(& $hostExe -NoProfile -NonInteractive -File (Join-Path $plugin "runtime/windows/$Script") @Arguments 2>&1 | ForEach-Object { [string]$_ })
        return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Lines = $out; Text = ($out -join "`n") }
    }
    finally { $ErrorActionPreference = $previous; $env:NIGHTSHIFT_RUN = $saved }
}

# Get-RunRules <workspace> <run> - the effective rules one run reads, or $null.
function Get-RunRules {
    param([string]$Workspace, [string]$Run)
    $saved = $env:NIGHTSHIFT_RUN
    $env:NIGHTSHIFT_RUN = $Run
    try { return (Get-NSRulesObject $Workspace) } finally { $env:NIGHTSHIFT_RUN = $saved }
}

# New-TeamSite <path> - a run-folder site whose team lets a member change shift.hours and
# receipts.progressMinutes and needs a lead's approval, with two members' settings files.
function New-TeamSite {
    param([string]$Path)
    $ns = Join-Path $Path '.nightshift'
    foreach ($d in @('run', 'runs', 'staging/plans', 'settings')) { $null = New-Item -ItemType Directory -Path (Join-Path $ns $d) -Force }
    $repo = Join-Path $Path 'repo'
    $null = New-Item -ItemType Directory -Path $repo -Force
    $null = & git -C $repo init -q
    $null = & git -C $repo -c user.email=d@example.com -c user.name=d commit -q --allow-empty -m init
    Write-Text (Join-Path $ns 'state-version') "3`n"
    $rules = Get-Content -Raw -LiteralPath $rulesTemplate | ConvertFrom-Json
    $rules.team.roles = [pscustomobject]@{ Alice = 'lead'; Bob = 'developer' }
    $rules.team.approvers = @('lead')
    $rules.team.memberSettings = @('shift.hours', 'receipts.progressMinutes')
    $rules.shift.hours = 2
    $rules.receipts.progressMinutes = 20
    Write-Text (Join-Path $ns 'rules.json') ($rules | ConvertTo-Json -Depth 20)
    Write-Text (Join-Path $ns 'run/work-target') ((Resolve-NSCanonicalPath $repo) + "`n")
    Write-Text (Join-Path $ns 'run/work-mode') "repository`n"
    foreach ($plan in @('Export CSV', 'Dark mode')) {
        $key = Get-NSReceiptSlug $plan
        Write-Text (Join-Path $ns "staging/plans/$key.md") ("# Punch List " + [char]0x2014 + " $plan`n`n## Contract`n`n- Work in the run.`n`n## Gates`n`n## Items`n`n- [ ] **1. Do $plan.**`n  - Verify: true`n  - Commit: ``feat: x```n")
    }
    Write-Text (Join-Path $ns 'settings/alice.json') "{`n  `"shift`": {`n    `"hours`": 3`n  },`n  `"receipts`": {`n    `"progressMinutes`": 5`n  }`n}`n"
    Write-Text (Join-Path $ns 'settings/bob.json') "{`n  `"shift`": {`n    `"hours`": 6`n  }`n}`n"
    # The lead has approved both plans, as this team requires before a run.
    foreach ($plan in @('Export CSV', 'Dark mode')) {
        $null = Invoke-Helper 'plan-record.ps1' @('-Project', $Path, '-Plan', $plan, '-Action', 'approved', '-By', 'Alice')
    }
    return (Resolve-NSCanonicalPath $Path)
}

$root = Join-Path ([IO.Path]::GetTempPath()) ('ns-team-settings-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $root -Force
try {
    # A selected file sets the run's values; a run with none uses the team's.
    $w = New-TeamSite (Join-Path $root 'select')
    $first = Invoke-Helper 'start-run.ps1' @('-Project', $w, '-Plan', 'Export CSV', '-HostName', 'claude', '-Settings', 'alice')
    Expect-True ($first.ExitCode -eq 0 -and ($first.Lines -ccontains "ok settings settings/alice.json over the team's rules.json, for this run")) "select: $($first.Text)"
    $second = Invoke-Helper 'start-run.ps1' @('-Project', $w, '-Plan', 'Dark mode', '-HostName', 'claude')
    Expect-True ($second.ExitCode -eq 0 -and -not ($second.Text.Contains('ok settings '))) "select: no settings: $($second.Text)"
    $a = Get-RunRules $w 'export-csv'
    $b = Get-RunRules $w 'dark-mode'
    Expect-True ([int]$a.shift.hours -eq 3 -and [int]$a.receipts.progressMinutes -eq 5) 'select: the selected values reach the run'
    Expect-True ([int]$b.shift.hours -eq 2 -and [int]$b.receipts.progressMinutes -eq 20) 'select: the other run reads the team defaults'
    $record = Join-Path $w '.nightshift/runs/export-csv/run/member-settings'
    Expect-True ([IO.File]::Exists($record) -and [IO.File]::ReadAllText($record) -ceq "alice`n") 'select: the selection sits with the run'

    # Neither a run's file nor a member's changes the team's own rules; an edited file is refused
    # at the next Start.
    Write-Text (Join-Path $w '.nightshift/runs/export-csv/rules.json') "{`n  `"shift`": {`n    `"isolation`": `"worktree`"`n  },`n  `"team`": {`n    `"approvers`": []`n  }`n}`n"
    Write-Text (Join-Path $w '.nightshift/settings/alice.json') "{`n  `"shift`": {`n    `"hours`": 3`n  },`n  `"team`": {`n    `"approvers`": []`n  }`n}`n"
    $a = Get-RunRules $w 'export-csv'
    Expect-True ((@($a.team.approvers) -join ',') -ceq 'lead' -and [int]$a.shift.hours -eq 3) 'owned: team.approvers stays the team''s'
    $preflight = Invoke-Helper 'start-preflight.ps1' @('-Project', $w, '-HostName', 'claude') 'export-csv'
    Expect-True ($preflight.ExitCode -ne 0 -and ($preflight.Lines -ccontains 'refuse settings alice cannot be used for this run') -and
        ($preflight.Lines -ccontains "explain settings/alice.json changes team.approvers, which only the team's rules.json sets")) "owned: preflight: $($preflight.Text)"

    # A second selection is refused; a selection whose file is gone fails closed.
    $again = Invoke-Helper 'start-run.ps1' @('-Project', $w, '-Plan', 'Export CSV', '-HostName', 'claude', '-Settings', 'bob')
    Expect-True ($again.ExitCode -eq 1 -and ($again.Lines -ccontains 'refuse settings run export-csv already uses settings/alice.json')) "gone: second selection: $($again.Text)"
    Remove-Item -LiteralPath (Join-Path $w '.nightshift/settings/alice.json') -Force
    Expect-True ($null -eq (Get-RunRules $w 'export-csv')) 'gone: a missing selected file fails closed'

    # A file that relaxes a required approval is refused before anything is placed.
    $r = New-TeamSite (Join-Path $root 'refuse')
    Write-Text (Join-Path $r '.nightshift/settings/eve.json') "{`n  `"team`": {`n    `"approvers`": []`n  },`n  `"watchMinutes`": 0`n}`n"
    $refused = Invoke-Helper 'start-run.ps1' @('-Project', $r, '-Plan', 'Export CSV', '-HostName', 'claude', '-Settings', 'eve')
    $expected = @('refuse settings eve cannot be selected for this run',
        "explain settings/eve.json changes team.approvers, which only the team's rules.json sets",
        'explain settings/eve.json changes watchMinutes, which the team does not let a member change',
        'repair take those settings out of the file, or ask the team to allow them in team.memberSettings, then run this again')
    Expect-True ($refused.ExitCode -eq 1 -and ($refused.Lines -join '|') -ceq ($expected -join '|')) "refuse: $($refused.Text)"
    Expect-True (@(Get-ChildItem -LiteralPath (Join-Path $r '.nightshift/runs') -Force).Count -eq 0) 'refuse: no run folder was placed'
}
finally {
    Set-Location ([IO.Path]::GetTempPath())
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures.Count -gt 0) {
    Write-Host "team settings logic failed ($($failures.Count)):"
    foreach ($failure in $failures) { Write-Host " - $failure" }
    exit 1
}
Write-Host 'team settings logic passed.'
