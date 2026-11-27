# Shared project records on native Windows: the PowerShell half of tests/share.bats.
# Run on macOS or Windows: pwsh -File tests/windows/share-logic.ps1
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

function Invoke-Quiet {
    param([string]$Directory, [string[]]$Arguments)
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { return @(& git -C $Directory @Arguments 2>$null | ForEach-Object { [string]$_ }) }
    finally { $ErrorActionPreference = $previous }
}

function Invoke-Start {
    param([string]$Site)
    $saved = $env:NIGHTSHIFT_RUN
    $env:NIGHTSHIFT_RUN = $null
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = @(& $hostExe -NoProfile -NonInteractive -File (Join-Path $plugin 'runtime/windows/start-run.ps1') -Project $Site -Plan 'Export CSV' -HostName claude 2>&1 | ForEach-Object { [string]$_ })
        return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Lines = $out; Text = ($out -join "`n") }
    }
    finally { $ErrorActionPreference = $previous; $env:NIGHTSHIFT_RUN = $saved }
}

function Get-RunName { param($Result) return (@($Result.Lines | Where-Object { $_ -cmatch '^ok run ' }) | Select-Object -First 1) -replace '^ok run ', '' }

# Set-LocalSite <repo> - what Setup writes on each runner's machine, which Git never carries.
function Set-LocalSite {
    param([string]$Repo)
    $run = Join-Path $Repo '.nightshift/run'
    $null = New-Item -ItemType Directory -Path $run -Force
    Write-Text (Join-Path $run 'work-target') ((Resolve-NSCanonicalPath $Repo) + "`n")
    Write-Text (Join-Path $run 'work-mode') "repository`n"
}

# New-Team <name> - a bare remote and the first member's clone, sharing through the shipped ignore files.
function New-Team {
    param([string]$Name)
    $dir = Join-Path $root $Name
    $null = Invoke-Quiet $root @('init', '-q', '--bare', (Join-Path $dir 'remote.git'))
    $a = Join-Path $dir 'alice'
    $null = Invoke-Quiet $root @('clone', '-q', (Join-Path $dir 'remote.git'), $a)
    $null = Invoke-Quiet $a @('symbolic-ref', 'HEAD', 'refs/heads/main')
    $null = Invoke-Quiet $a @('config', 'user.email', 'alice@example.com')
    $null = Invoke-Quiet $a @('config', 'user.name', 'alice')
    Write-Text (Join-Path $a 'app.txt') "app`n"
    $null = New-Item -ItemType Directory -Path (Join-Path $a '.nightshift/staging/plans') -Force
    Write-Text (Join-Path $a '.nightshift/state-version') "3`n"
    Copy-Item -LiteralPath $rulesTemplate -Destination (Join-Path $a '.nightshift/rules.json')
    $null = Invoke-NSScaffold -Workspace $a -Keys (Get-NSScaffoldKeys @('shared'))
    Write-Text (Join-Path $a '.nightshift/staging/plans/export-csv.md') ("# Punch List " + [char]0x2014 + " Export CSV`n`n## Contract`n`n- Work in the run; receipts go in ``" + '$NS' + "/receipts/``.`n`n## Gates`n`n## Items`n`n- [ ] **1. Export the table.**`n  - Verify: true`n  - Commit: ``feat: export```n")
    Set-LocalSite $a
    $null = Invoke-Quiet $a @('add', '-A')
    $null = Invoke-Quiet $a @('commit', '-q', '-m', 'plan: export csv')
    $null = Invoke-Quiet $a @('push', '-q', '-u', 'origin', 'main')
    return (Resolve-NSCanonicalPath $a)
}

function New-Member {
    param([string]$Team, [string]$Name)
    $m = Join-Path (Join-Path $root $Team) $Name
    $null = Invoke-Quiet $root @('clone', '-q', '-b', 'main', (Join-Path (Join-Path $root $Team) 'remote.git'), $m)
    $null = Invoke-Quiet $m @('config', 'user.email', "$Name@example.com")
    $null = Invoke-Quiet $m @('config', 'user.name', $Name)
    Set-LocalSite $m
    return (Resolve-NSCanonicalPath $m)
}

$root = Join-Path ([IO.Path]::GetTempPath()) ('ns-share-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $root -Force
try {
    # The shipped ignore file shares every record; an edit to it changes what is shared.
    $a = New-Team 'edited'
    foreach ($record in @('plans', 'decisions', 'rules', 'receipts', 'summaries')) {
        Expect-True (Test-NSSiteShares $a $record) "edited: $record is shared under the shipped file"
    }
    [IO.File]::AppendAllText((Join-Path $a '.nightshift/.gitignore'), "/runs/`n", $utf8)
    Expect-True (-not (Test-NSSiteShares $a 'receipts')) 'edited: ignoring runs/ keeps receipts private'
    Expect-True (Test-NSSiteShares $a 'plans') 'edited: plans stay shared'
    $solo = Invoke-Start $a
    Expect-True ($solo.ExitCode -eq 0 -and ($solo.Lines -ccontains 'ok run export-csv')) "edited: an untagged run: $($solo.Text)"
    Write-Text (Join-Path $a '.gitignore') ".nightshift/`n"
    Expect-True (-not (Test-NSSiteShares $a 'plans')) 'edited: ignoring the whole site shares nothing'

    # The same plan run in two clones keeps both runs' receipts and both starts in its record.
    $a = New-Team 'twin'
    $b = New-Member 'twin' 'bob'
    $first = Invoke-Start $a
    Expect-True ($first.ExitCode -eq 0 -and ($first.Lines -ccontains "ok plan Export CSV stays in .nightshift/staging/plans as the team's record; the run works from its own copy")) "twin: alice: $($first.Text)"
    $ra = Get-RunName $first
    $second = Invoke-Start $b
    $rb = Get-RunName $second
    Expect-True ($ra -cmatch '^export-csv-[0-9a-f]{6}$' -and $rb -cmatch '^export-csv-[0-9a-f]{6}$' -and $ra -cne $rb) "twin: tagged run names $ra and $rb"
    $runList = [IO.File]::ReadAllText((Join-Path $a ".nightshift/runs/$ra/punch-list.md"))
    Expect-True ($runList.Contains('- Work in the run; receipts go in `./.nightshift/receipts/`.') -and -not $runList.Contains($a)) "twin: the run's copy names relative paths"
    foreach ($pair in @(@($a, $ra, 'alice ran it'), @($b, $rb, 'bob ran it'))) {
        $dir = Join-Path $pair[0] ".nightshift/runs/$($pair[1])/receipts"
        $null = New-Item -ItemType Directory -Path $dir -Force
        Write-Text (Join-Path $dir '01-export-the-table-ab12.md') ($pair[2] + "`n")
    }
    $null = Invoke-Quiet $a @('add', '-A'); $null = Invoke-Quiet $a @('commit', '-q', '-m', 'alice: receipt'); $null = Invoke-Quiet $a @('push', '-q')
    $null = Invoke-Quiet $b @('add', '-A'); $null = Invoke-Quiet $b @('commit', '-q', '-m', 'bob: receipt')
    $null = Invoke-Quiet $b @('pull', '-q', '--no-rebase', '--no-edit')
    Expect-True ([IO.File]::ReadAllText((Join-Path $b ".nightshift/runs/$ra/receipts/01-export-the-table-ab12.md")) -ceq "alice ran it`n") 'twin: alice receipt merged'
    $record = [IO.File]::ReadAllText((Join-Path $b '.nightshift/staging/records/export-csv.md'))
    Expect-True ($record.Contains("run $ra") -and $record.Contains("run $rb")) "twin: both starts are in the record: $record"
    Expect-True (@(Invoke-Quiet $b @('diff', '--name-only', '--diff-filter=U')).Count -eq 0) 'twin: no conflict'
}
finally {
    Set-Location ([IO.Path]::GetTempPath())
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures.Count -gt 0) {
    Write-Host "share logic failed ($($failures.Count)):"
    foreach ($failure in $failures) { Write-Host " - $failure" }
    exit 1
}
Write-Host 'share logic passed.'
