# The team's branch workflow on native Windows: the PowerShell half of tests/branches.bats.
# Run on macOS or Windows: pwsh -File tests/windows/branches-logic.ps1
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
function Invoke-Git { param([string]$Directory, [string[]]$Arguments) return (Invoke-NSGitCommand $Directory $Arguments) }

function Invoke-Start {
    param([string]$Site, [string]$Plan, [string[]]$Extra = @())
    $saved = $env:NIGHTSHIFT_RUN
    $env:NIGHTSHIFT_RUN = $null
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = @(& $hostExe -NoProfile -NonInteractive -File (Join-Path $plugin 'runtime/windows/start-run.ps1') -Project $Site -Plan $Plan -HostName claude @Extra 2>&1 | ForEach-Object { [string]$_ })
        return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Lines = $out; Text = ($out -join "`n") }
    }
    finally { $ErrorActionPreference = $previous; $env:NIGHTSHIFT_RUN = $saved }
}

function Get-RunTarget {
    param([string]$Site, [string]$Run)
    $saved = $env:NIGHTSHIFT_RUN
    $env:NIGHTSHIFT_RUN = $Run
    try { return (Resolve-NSWorkTarget $Site) } finally { $env:NIGHTSHIFT_RUN = $saved }
}

# Get-Top <path> - the folder Git names as the top of that checkout, spelled the same way every time.
function Get-Top { param([string]$Path) return [string](Invoke-NSGit $Path @('rev-parse', '--show-toplevel')) }

function Add-Plan {
    param([string]$Site, [string]$Name)
    $key = Get-NSReceiptSlug $Name
    Write-Text (Join-Path $Site ".nightshift/staging/plans/$key.md") ("# Punch List " + [char]0x2014 + " $Name`n`n## Contract`n`n- Work in the run.`n`n## Gates`n`n## Items`n`n- [ ] **1. Do $Name.**`n  - Verify: true`n  - Commit: ``feat: x```n")
}

# New-Site <path> <start> - a repository on develop holding a solo site whose runs start from develop.
function New-Site {
    param([string]$Path, [string]$Start)
    $ns = Join-Path $Path '.nightshift'
    foreach ($d in @('run', 'runs', 'staging/plans')) { $null = New-Item -ItemType Directory -Path (Join-Path $ns $d) -Force }
    $null = Invoke-Git $Path @('init', '-q', '-b', 'develop')
    $null = Invoke-Git $Path @('config', 'user.email', 'a@example.com')
    $null = Invoke-Git $Path @('config', 'user.name', 'Alice')
    Write-Text (Join-Path $Path 'app.txt') "app`n"
    Write-Text (Join-Path $Path '.gitignore') ".nightshift/`n"
    $null = Invoke-Git $Path @('add', '-A')
    $null = Invoke-Git $Path @('commit', '-q', '-m', 'app')
    Write-Text (Join-Path $ns 'state-version') "3`n"
    $rules = Get-Content -Raw -LiteralPath $rulesTemplate | ConvertFrom-Json
    $rules.branches.base = 'develop'
    $rules.branches.start = $Start
    Write-Text (Join-Path $ns 'rules.json') ($rules | ConvertTo-Json -Depth 20)
    Write-Text (Join-Path $ns 'run/work-target') ((Resolve-NSCanonicalPath $Path) + "`n")
    Write-Text (Join-Path $ns 'run/work-mode') "repository`n"
    return (Resolve-NSCanonicalPath $Path)
}

$root = Join-Path ([IO.Path]::GetTempPath()) ('ns-branches-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $root -Force
try {
    # choose: the choices are listed and nothing is placed; runs on one branch go one after another.
    $s = New-Site (Join-Path $root 'choose') 'choose'
    Add-Plan $s 'Export CSV'
    Add-Plan $s 'Dark mode'
    $asked = Invoke-Start $s 'Export CSV'
    Expect-True ($asked.ExitCode -eq 1 -and ($asked.Lines -ccontains 'branch current develop') -and ($asked.Lines -ccontains 'branch base develop')) "choose: $($asked.Text)"
    Expect-True (@(Get-ChildItem -LiteralPath (Join-Path $s '.nightshift/runs') -Force).Count -eq 0) 'choose: nothing placed'
    $first = Invoke-Start $s 'Export CSV' @('-Branch', 'alice/export')
    Expect-True ($first.ExitCode -eq 0 -and ($first.Lines -ccontains 'ok branch alice/export')) "choose: first: $($first.Text)"
    $wt = Get-RunTarget $s 'export-csv'
    Expect-True (([string](Invoke-NSGit $wt @('symbolic-ref', '--short', 'HEAD'))) -ceq 'alice/export') 'choose: the run works on alice/export'
    $busy = Invoke-Start $s 'Dark mode' @('-Branch', 'alice/export')
    Expect-True ($busy.ExitCode -eq 1 -and ($busy.Lines -ccontains 'refuse worktree alice/export is in use by run export-csv')) "choose: busy: $($busy.Text)"
    Write-Text (Join-Path $s '.nightshift/runs/export-csv/run/.ended') ''
    $second = Invoke-Start $s 'Dark mode' @('-Branch', 'alice/export')
    Expect-True ($second.ExitCode -eq 0 -and @($second.Lines | Where-Object { $_ -clike "ok worktree * branch alice/export - the run continues the branch's worktree" }).Count -eq 1) "choose: second: $($second.Text)"
    Expect-True ((Get-Top (Get-RunTarget $s 'dark-mode')) -ceq (Get-Top $wt)) 'choose: the second run works in the same worktree'

    # current: the run works on the member's branch in the checkout itself.
    $s = New-Site (Join-Path $root 'current') 'current'
    $null = Invoke-Git $s @('checkout', '-q', '-b', 'bob/feature')
    Add-Plan $s 'Export CSV'
    $started = Invoke-Start $s 'Export CSV'
    Expect-True ($started.ExitCode -eq 0 -and ($started.Lines -ccontains 'ok worktree none - the run works on bob/feature in the checkout itself')) "current: $($started.Text)"
    Expect-True ((Get-Top (Get-RunTarget $s 'export-csv')) -ceq (Get-Top $s)) 'current: the work target is the checkout'
}
finally {
    Set-Location ([IO.Path]::GetTempPath())
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures.Count -gt 0) {
    Write-Host "branches logic failed ($($failures.Count)):"
    foreach ($failure in $failures) { Write-Host " - $failure" }
    exit 1
}
Write-Host 'branches logic passed.'
