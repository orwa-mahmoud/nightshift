# Attribution and approval on native Windows: the PowerShell half of tests/approvals.bats.
# Run on macOS or Windows: pwsh -File tests/windows/approvals-logic.ps1
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
$dot = [string][char]0x00B7

function Expect-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        $failures.Add($Message)
        Write-Host "FAIL: $Message"
    }
}

function Write-Text { param([string]$Path, [string]$Text) [IO.File]::WriteAllText($Path, $Text, $utf8) }

function Invoke-Helper {
    param([string]$Script, [string[]]$Arguments)
    $saved = $env:NIGHTSHIFT_RUN
    $env:NIGHTSHIFT_RUN = $null
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = @(& $hostExe -NoProfile -NonInteractive -File (Join-Path $plugin "runtime/windows/$Script") @Arguments 2>&1 | ForEach-Object { [string]$_ })
        return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Lines = $out; Text = ($out -join "`n") }
    }
    finally { $ErrorActionPreference = $previous; $env:NIGHTSHIFT_RUN = $saved }
}

function Invoke-Record { param([string]$Site, [string[]]$Arguments) return (Invoke-Helper 'plan-record.ps1' (@('-Project', $Site, '-Plan', 'Export CSV') + $Arguments)) }
function Invoke-Start { param([string]$Site, [string[]]$Arguments) return (Invoke-Helper 'start-run.ps1' (@('-Project', $Site, '-Plan', 'Export CSV', '-HostName', 'claude') + $Arguments)) }

# New-Site <path> <records> <team> - a site inside its repository with one plan; the hashtable sets
# team keys. The runner's Git name is Carol.
function New-Site {
    param([string]$Path, [string[]]$Records, [hashtable]$Team, [hashtable]$Top = @{})
    $ns = Join-Path $Path '.nightshift'
    foreach ($d in @('run', 'runs', 'staging/plans')) { $null = New-Item -ItemType Directory -Path (Join-Path $ns $d) -Force }
    $null = & git -C $Path init -q
    $null = & git -C $Path config user.email c@example.com
    $null = & git -C $Path config user.name Carol
    $null = & git -C $Path commit -q --allow-empty -m init
    Write-Text (Join-Path $ns 'state-version') "3`n"
    $rules = Get-Content -Raw -LiteralPath $rulesTemplate | ConvertFrom-Json
    $rules.sharing.records = @($Records)
    foreach ($k in $Team.Keys) { $rules.team.$k = $Team[$k] }
    foreach ($k in $Top.Keys) { $rules | Add-Member -NotePropertyName $k -NotePropertyValue $Top[$k] -Force }
    Write-Text (Join-Path $ns 'rules.json') ($rules | ConvertTo-Json -Depth 20)
    Write-Text (Join-Path $ns 'run/work-target') ((Resolve-NSCanonicalPath $Path) + "`n")
    Write-Text (Join-Path $ns 'run/work-mode') "repository`n"
    Write-Text (Join-Path $ns 'staging/plans/export-csv.md') ("# Punch List " + [char]0x2014 + " Export CSV`n`n## Contract`n`n- Work in the run.`n`n## Gates`n`n- ``true```n`n## Items`n`n- [ ] **1. Export the table.**`n  - Verify: true`n  - Commit: ``feat: export```n")
    return (Resolve-NSCanonicalPath $Path)
}

$root = Join-Path ([IO.Path]::GetTempPath()) ('ns-approvals-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $root -Force
try {
    # Solo: the owner proposes and approves under their own name; an older line reads as unknown.
    $w = New-Site (Join-Path $root 'solo') @() @{}
    $proposed = Invoke-Record $w @('-Action', 'proposed')
    $revision = Get-NSPlanRevision (Join-Path $w '.nightshift/staging/plans/export-csv.md')
    Expect-True ($proposed.ExitCode -eq 0 -and $proposed.Text -ceq "ok record proposed by Carol at revision $revision") "solo: $($proposed.Text)"
    $null = Invoke-Record $w @('-Action', 'approved')
    [IO.File]::AppendAllText((Join-Path $w '.nightshift/staging/records/export-csv.md'), "- approved $dot 2026-11-01 09:00 (UTC+04:00) $dot revision aaaaaaaaaaaa.bbbbbbbbbbbb.cccccccccccc`n", $utf8)
    $status = Invoke-Record $w @()
    $expected = @("revision $revision", 'approval not-required', 'state approved', "approved-by Carol $revision",
        "record proposed by Carol at $revision", "record approved by Carol at $revision", 'record approved by unknown at aaaaaaaaaaaa.bbbbbbbbbbbb.cccccccccccc')
    Expect-True (($status.Lines -join '|') -ceq ($expected -join '|')) "solo: status: $($status.Text)"
    $started = Invoke-Start $w @()
    Expect-True ($started.ExitCode -eq 0 -and ($started.Lines -ccontains 'ok record started by Carol')) "solo: start: $($started.Text)"

    # Developer and lead: only the lead's approval runs; a gate change returns the plan to proposed.
    $w = New-Site (Join-Path $root 'leads') @('plans', 'rules') @{ roles = [pscustomobject]@{ Alice = 'lead'; Bob = 'developer' }; approvers = @('lead'); reviewChanges = @('contract', 'gates') }
    $null = Invoke-Record $w @('-Action', 'proposed', '-By', 'Bob')
    $revision = Get-NSPlanRevision (Join-Path $w '.nightshift/staging/plans/export-csv.md')
    $refused = Invoke-Start $w @()
    Expect-True ($refused.ExitCode -eq 1 -and ($refused.Lines -ccontains "refuse approval Export CSV revision $revision is proposed: no approver has approved it")) "leads: unapproved: $($refused.Text)"
    $bob = Invoke-Record $w @('-Action', 'approved', '-By', 'Bob')
    Expect-True ($bob.ExitCode -eq 1 -and ($bob.Lines -ccontains "refuse approve Bob (developer) may not approve this plan; the team's approvers are lead")) "leads: bob: $($bob.Text)"
    $null = Invoke-Record $w @('-Action', 'approved', '-By', 'Alice')
    $plan = Join-Path $w '.nightshift/staging/plans/export-csv.md'
    Write-Text $plan ([IO.File]::ReadAllText($plan).Replace('- `true`', '- `make test`'))
    $stale = Invoke-Start $w @()
    Expect-True ($stale.ExitCode -eq 1 -and $stale.Text.Contains("refuse approval Export CSV changed its gates since Alice approved revision $revision, so revision ")) "leads: stale: $($stale.Text)"

    # Consent: nothing of the run executes before the runner consents to exactly its inputs.
    $marker = Join-Path $root 'gate-ran'
    $w = New-Site (Join-Path $root 'consent') @('plans') @{} @{ baselineGates = $true }
    $plan = Join-Path $w '.nightshift/staging/plans/export-csv.md'
    Write-Text $plan ([IO.File]::ReadAllText($plan).Replace('- `true`', ('- `pwsh -NoProfile -Command New-Item -ItemType File -Force ' + $marker + '`')))
    $asked = Invoke-Start $w @()
    Expect-True ($asked.ExitCode -eq 1 -and ($asked.Lines -ccontains 'refuse consent read what this run would execute before it starts') -and ($asked.Lines -ccontains 'input baseline-gates true')) "consent: asked: $($asked.Text)"
    Expect-True (-not (Test-Path -LiteralPath $marker)) 'consent: no gate ran before consent'
    $consent = (@($asked.Lines | Where-Object { $_ -clike 'repair read those inputs*' })[0]) -replace '^.* --consent ', ''
    $given = Invoke-Start $w @('-Consent', $consent)
    Expect-True ($given.ExitCode -eq 0 -and ($given.Lines -ccontains "ok consent $consent covers what this run executes")) "consent: given: $($given.Text)"
    Expect-True (Test-Path -LiteralPath $marker) 'consent: the gate ran once consent was given'
}
finally {
    Set-Location ([IO.Path]::GetTempPath())
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures.Count -gt 0) {
    Write-Host "approvals logic failed ($($failures.Count)):"
    foreach ($failure in $failures) { Write-Host " - $failure" }
    exit 1
}
Write-Host 'approvals logic passed.'
