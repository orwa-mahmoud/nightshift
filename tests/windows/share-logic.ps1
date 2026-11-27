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
$threadHead = Join-Path $plugin 'skills/nightshift/references/templates/plan-record.md'
$hostExe = (Get-Process -Id $PID).Path
$failures = New-Object 'System.Collections.Generic.List[string]'
$utf8 = New-Object Text.UTF8Encoding($false)
$allRecords = @('plans', 'decisions', 'rules', 'receipts', 'summaries')

function Expect-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        $failures.Add($Message)
        Write-Host "FAIL: $Message"
    }
}

# Invoke-Quiet <directory> <git arguments> - git's stdout lines; stderr dropped, exit code kept.
function Invoke-Quiet {
    param([string]$Directory, [string[]]$Arguments)
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { return @(& git -C $Directory @Arguments 2>$null | ForEach-Object { [string]$_ }) }
    finally { $ErrorActionPreference = $previous }
}

function Write-Text { param([string]$Path, [string]$Text) [IO.File]::WriteAllText($Path, $Text, $utf8) }

# Invoke-Helper <script> <arguments> - a runtime helper's output and exit code.
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

function Set-Records {
    param([string]$Site, [string[]]$Records)
    $file = Join-Path $Site '.nightshift/rules.json'
    $data = Get-Content -Raw -LiteralPath $file | ConvertFrom-Json
    $data | Add-Member -NotePropertyName sharing -NotePropertyValue ([pscustomobject]@{ records = @($Records) }) -Force
    Write-Text $file ($data | ConvertTo-Json -Depth 20)
}

function Set-RunsLayout {
    param([string]$Site, [string]$Layout)
    $file = Join-Path $Site '.nightshift/rules.json'
    $data = Get-Content -Raw -LiteralPath $file | ConvertFrom-Json
    $data.runs.layout = $Layout
    Write-Text $file ($data | ConvertTo-Json -Depth 20)
}

function Save-All {
    param([string]$Repo, [string]$Message)
    $null = Invoke-Quiet $Repo @('add', '-A')
    $null = Invoke-Quiet $Repo @('commit', '-q', '-m', $Message)
}

# Set-LocalSite <repo> - what Setup writes on each runner's machine, which Git never carries.
function Set-LocalSite {
    param([string]$Repo)
    $run = Join-Path $Repo '.nightshift/run'
    $null = New-Item -ItemType Directory -Path $run -Force
    Write-Text (Join-Path $run 'work-target') ((Resolve-NSCanonicalPath $Repo) + "`n")
    Write-Text (Join-Path $run 'work-mode') "repository`n"
}

# New-Team <name> [records] - a bare remote and the first member's clone with the site inside the
# repository, sharing every record (or the given ones), pushed.
function New-Team {
    param([string]$Name, [string[]]$Records = $allRecords)
    $dir = Join-Path $root $Name
    $null = Invoke-Quiet $root @('init', '-q', '--bare', (Join-Path $dir 'remote.git'))
    $a = Join-Path $dir 'alice'
    $null = Invoke-Quiet $root @('clone', '-q', (Join-Path $dir 'remote.git'), $a)
    $null = Invoke-Quiet $a @('symbolic-ref', 'HEAD', 'refs/heads/main')
    $null = Invoke-Quiet $a @('config', 'user.email', 'alice@example.com')
    $null = Invoke-Quiet $a @('config', 'user.name', 'alice')
    Write-Text (Join-Path $a 'app.txt') "app`n"
    Write-Text (Join-Path $a '.gitignore') ".nightshift/`n"
    $null = New-Item -ItemType Directory -Path (Join-Path $a '.nightshift/staging/plans') -Force
    Write-Text (Join-Path $a '.nightshift/state-version') "3`n"
    Copy-Item -LiteralPath $rulesTemplate -Destination (Join-Path $a '.nightshift/rules.json')
    Set-Records $a $Records
    Write-Text (Join-Path $a '.nightshift/staging/plans/export-csv.md') ("# Punch List " + [char]0x2014 + " Export CSV`n`n## Contract`n`n- Work in the run; receipts go in ``" + '$NS' + "/receipts/``.`n`n## Gates`n`n## Items`n`n- [ ] **1. Export the table.**`n  - Verify: true`n  - Commit: ``feat: export```n")
    Set-LocalSite $a
    $null = Invoke-Helper 'share.ps1' @('-Project', $a, '-Apply')
    Save-All $a 'plan: export csv'
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

function Write-Thread {
    param([string]$Repo, [string]$File, [string]$Topic, [string]$Question)
    $dir = Join-Path $Repo '.nightshift/staging/decisions'
    $null = New-Item -ItemType Directory -Path $dir -Force
    $head = New-Object Collections.Generic.List[string]
    foreach ($line in [IO.File]::ReadAllLines($threadHead)) { $head.Add($line); if ($line -ceq '---') { break } }
    Write-Text (Join-Path $dir $File) (($head.ToArray() -join "`n") + "`n`n- **$Topic** " + [char]0x00B7 + " open since 2026-11-27 10:00 (UTC+04:00)`n  - Open: $Question`n")
}

function Write-Receipt {
    param([string]$Repo, [string]$Run, [string]$Text)
    $dir = Join-Path $Repo ".nightshift/runs/$Run/receipts"
    $null = New-Item -ItemType Directory -Path $dir -Force
    Write-Text (Join-Path $dir '01-export-the-table-ab12.md') ($Text + "`n")
}

# Invoke-StartRun <workspace> <plan> - a runner on a shared site reads what the run would execute and
# consents to exactly that, then starts it.
function Invoke-StartRun {
    param([string]$Site, [string]$Plan)
    $first = Invoke-Helper 'start-run.ps1' @('-Project', $Site, '-Plan', $Plan, '-HostName', 'claude')
    if ($first.ExitCode -eq 0) { return $first }
    $repair = @($first.Lines | Where-Object { $_ -clike 'repair read those inputs, then run this again with --consent *' })
    if ($repair.Count -eq 0) { return $first }
    $consent = $repair[0] -replace '^.* --consent ', ''
    return (Invoke-Helper 'start-run.ps1' @('-Project', $Site, '-Plan', $Plan, '-HostName', 'claude', '-Consent', $consent))
}

function Get-RunName { param($Result) return (@($Result.Lines | Where-Object { $_ -cmatch '^ok run ' }) | Select-Object -First 1) -replace '^ok run ', '' }

$dot = [string][char]0x00B7
$root = Join-Path ([IO.Path]::GetTempPath()) ('ns-share-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $root -Force
try {
    # Git sees the shared records and none of a runner's private files.
    $a = New-Team 'see'
    Expect-True ([IO.File]::ReadAllText((Join-Path $a '.gitignore')).Length -eq 0) 'see: the line Setup wrote is taken out'
    $runDir = '.nightshift/runs/export-csv-abc123'
    foreach ($d in @("$runDir/receipts/01-export-the-table-ab12", "$runDir/run", "$runDir/inbox", '.nightshift/worktrees/w1')) {
        $null = New-Item -ItemType Directory -Path (Join-Path $a $d) -Force
    }
    foreach ($f in @("$runDir/punch-list.md", "$runDir/receipts/01-export-the-table-ab12.md", "$runDir/receipts/01-export-the-table-ab12/screen.png",
            "$runDir/run/shift-log.md", "$runDir/inbox/parking-lot.md", "$runDir/inbox/messages.md", "$runDir/STOP", '.nightshift/STOP',
            '.nightshift/staging/plan-record.md', '.nightshift/worktrees/w1/file')) {
        Write-Text (Join-Path $a $f) "x`n"
    }
    Write-Text (Join-Path $a "$runDir/rules.json") "{}`n"
    $seen = @(Invoke-Quiet $a @('add', '-A', '--dry-run') | ForEach-Object { $_ -replace "^add '", '' -replace "'$", '' } | Sort-Object)
    $expected = @("$runDir/inbox/parking-lot.md", "$runDir/punch-list.md", "$runDir/receipts/01-export-the-table-ab12.md", "$runDir/rules.json")
    Expect-True (($seen -join '|') -ceq ($expected -join '|')) "see: git sees only the shared run records: $($seen -join ', ')"
    $tracked = @(Invoke-Quiet $a @('ls-files', '.nightshift') | Sort-Object)
    Expect-True (($tracked -join '|') -ceq '.nightshift/.gitattributes|.nightshift/.gitignore|.nightshift/rules.json|.nightshift/staging/plans/export-csv.md|.nightshift/state-version') "see: committed records: $($tracked -join ', ')"
    $again = Invoke-Helper 'share.ps1' @('-Project', $a)
    Expect-True ($again.ExitCode -eq 0 -and ($again.Lines -ccontains 'ok gitignore .nightshift/.gitignore already matches')) "see: a second look changes nothing: $($again.Text)"

    # An owner-selected folder inside the repository shares the same records.
    $r = Join-Path $root 'chosen/repo'
    $null = New-Item -ItemType Directory -Path (Join-Path $r 'planning/.nightshift/staging/plans') -Force
    $null = Invoke-Quiet $r @('init', '-q')
    $null = Invoke-Quiet $r @('config', 'user.email', 'dev@example.com')
    $null = Invoke-Quiet $r @('config', 'user.name', 'dev')
    Write-Text (Join-Path $r 'planning/.nightshift/state-version') "3`n"
    Copy-Item -LiteralPath $rulesTemplate -Destination (Join-Path $r 'planning/.nightshift/rules.json')
    Set-Records (Join-Path $r 'planning') @('plans', 'rules')
    Write-Text (Join-Path $r 'planning/.nightshift/staging/plans/p.md') "# Punch List - P`n`n## Items`n"
    Write-Text (Join-Path $r 'planning/.nightshift/STOP') "x`n"
    Write-Text (Join-Path $r '.gitignore') "planning/.nightshift/`n"
    $chosen = Invoke-Helper 'share.ps1' @('-Project', (Join-Path $r 'planning'), '-Apply')
    Expect-True ($chosen.ExitCode -eq 0 -and $chosen.Text.Contains('ok repository took the line planning/.nightshift/ out of')) "chosen: $($chosen.Text)"
    $seen = @(Invoke-Quiet $r @('add', '-A', '--dry-run') | ForEach-Object { $_ -replace "^add '", '' -replace "'$", '' } | Where-Object { $_ -like '*nightshift*' } | Sort-Object)
    Expect-True (($seen -join '|') -ceq 'planning/.nightshift/.gitattributes|planning/.nightshift/.gitignore|planning/.nightshift/rules.json|planning/.nightshift/staging/plans/p.md|planning/.nightshift/state-version') "chosen: $($seen -join ', ')"

    # A planning question is read in the other clone before approval; answer and change are traced.
    $a = New-Team 'trace'
    $b = New-Member 'trace' 'bob'
    Write-Thread $a 'export-csv-separator.md' 'CSV separator' 'comma or semicolon?'
    Save-All $a 'question: csv separator'
    $null = Invoke-Quiet $a @('push', '-q')
    $null = Invoke-Quiet $b @('pull', '-q')
    $enter = Invoke-Helper 'plan-enter.ps1' @('-Project', $b)
    Expect-True ($enter.Lines -ccontains 'decision threads go in .nightshift/staging/decisions, one file each') "trace: where threads go: $($enter.Text)"
    Expect-True ($enter.Lines -ccontains "open thread: export-csv-separator.md $dot - **CSV separator** $dot open since 2026-11-27 10:00 (UTC+04:00)") "trace: the open thread: $($enter.Text)"
    $null = Invoke-Helper 'plan-exit.ps1' @('-Project', $b)
    $threadFile = Join-Path $b '.nightshift/staging/decisions/export-csv-separator.md'
    Write-Text $threadFile ([IO.File]::ReadAllText($threadFile).Replace('  - Open: comma or semicolon?', ('  - Decided: semicolon ' + [char]0x2014 + ' the finance team opens it in a spreadsheet')))
    Save-All $b 'answer: semicolon'
    $null = Invoke-Quiet $b @('push', '-q')
    $null = Invoke-Quiet $a @('pull', '-q')
    [IO.File]::AppendAllText((Join-Path $a '.nightshift/staging/decisions/export-csv-separator.md'), ('  - Decided: comma ' + [char]0x2014 + " the importer reads RFC 4180 only`n"), $utf8)
    Save-All $a 'decision: comma'
    $started = Invoke-StartRun $a 'Export CSV'
    Expect-True ($started.ExitCode -eq 0) "trace: start-run: $($started.Text)"
    $traceRun = Get-RunName $started
    Write-Receipt $a $traceRun 'Comma separated.'
    Save-All $a 'receipt: export the table'
    $null = Invoke-Quiet $a @('push', '-q')
    $null = Invoke-Quiet $b @('pull', '-q')
    $log = @(Invoke-Quiet $b @('log', '--format=%an %s', '--', '.nightshift/staging/decisions/export-csv-separator.md'))
    Expect-True (($log -join '|') -ceq 'alice decision: comma|bob answer: semicolon|alice question: csv separator') "trace: thread history: $($log -join ', ')"
    $log = @(Invoke-Quiet $b @('log', '--format=%an %s', '--', ".nightshift/runs/$traceRun/receipts"))
    Expect-True (($log -join '|') -ceq 'alice receipt: export the table') "trace: receipt history: $($log -join ', ')"

    # The same plan run in two clones keeps both runs' receipts; the plan stays the team's record.
    $a = New-Team 'twin'
    $b = New-Member 'twin' 'bob'
    $first = Invoke-StartRun $a 'Export CSV'
    Expect-True ($first.ExitCode -eq 0 -and ($first.Lines -ccontains "ok plan Export CSV stays in .nightshift/staging/plans as the team's record; the run works from its own copy")) "twin: alice: $($first.Text)"
    $ra = Get-RunName $first
    $second = Invoke-StartRun $b 'Export CSV'
    Expect-True ($second.ExitCode -eq 0) "twin: bob: $($second.Text)"
    $rb = Get-RunName $second
    Expect-True ($ra -cmatch '^export-csv-[0-9a-f]{6}$' -and $rb -cmatch '^export-csv-[0-9a-f]{6}$' -and $ra -cne $rb) "twin: tagged run names $ra and $rb"
    $runList = [IO.File]::ReadAllText((Join-Path $a ".nightshift/runs/$ra/punch-list.md"))
    Expect-True ($runList.Contains('- Work in the run; receipts go in `./.nightshift/receipts/`.') -and -not $runList.Contains($a)) "twin: the run's copy names relative paths: $runList"
    Expect-True ((Test-Path -LiteralPath (Join-Path $a '.nightshift/staging/plans/export-csv.md')) -and (Test-Path -LiteralPath (Join-Path $b '.nightshift/staging/plans/export-csv.md'))) 'twin: the plan stays staged in both clones'
    Write-Receipt $a $ra 'alice ran it'
    Write-Receipt $b $rb 'bob ran it'
    Save-All $a 'alice: receipt'
    $null = Invoke-Quiet $a @('push', '-q')
    Save-All $b 'bob: receipt'
    $null = Invoke-Quiet $b @('pull', '-q', '--no-rebase', '--no-edit')
    Expect-True ([IO.File]::ReadAllText((Join-Path $b ".nightshift/runs/$ra/receipts/01-export-the-table-ab12.md")) -ceq "alice ran it`n") 'twin: alice receipt merged'
    Expect-True ([IO.File]::ReadAllText((Join-Path $b ".nightshift/runs/$rb/receipts/01-export-the-table-ab12.md")) -ceq "bob ran it`n") 'twin: bob receipt kept'
    $again = Invoke-StartRun $b 'Export CSV'
    Expect-True ($again.ExitCode -eq 0 -and ($again.Lines -ccontains "ok run $rb")) "twin: bob's restart keeps his run: $($again.Text)"

    # Decision threads from separate branches merge cleanly and both reopen.
    $a = New-Team 'branches'
    $null = Invoke-Quiet $a @('checkout', '-q', '-b', 'format')
    Write-Thread $a 'export-csv-separator.md' 'CSV separator' 'comma or semicolon?'
    Save-All $a 'question: separator'
    $null = Invoke-Quiet $a @('checkout', '-q', 'main')
    $null = Invoke-Quiet $a @('checkout', '-q', '-b', 'encoding')
    Write-Thread $a 'export-csv-encoding.md' 'CSV encoding' 'UTF-8 with or without BOM?'
    Save-All $a 'question: encoding'
    $null = Invoke-Quiet $a @('checkout', '-q', 'main')
    $null = Invoke-Quiet $a @('merge', '-q', '--no-edit', 'format', 'encoding')
    $enter = Invoke-Helper 'plan-enter.ps1' @('-Project', $a)
    $threads = @($enter.Lines | Where-Object { $_ -clike 'open thread: *' })
    Expect-True (($threads -join '|') -ceq ("open thread: export-csv-encoding.md $dot - **CSV encoding** $dot open since 2026-11-27 10:00 (UTC+04:00)|" +
            "open thread: export-csv-separator.md $dot - **CSV separator** $dot open since 2026-11-27 10:00 (UTC+04:00)")) "branches: $($threads -join ' / ')"

    # A conflicting edit to a shared rule is resolved through Git and the team's value is read.
    $a = New-Team 'rule'
    $b = New-Member 'rule' 'bob'
    Set-RunsLayout $a 'date'
    Save-All $a 'rules: date runs'
    $null = Invoke-Quiet $a @('push', '-q')
    Set-RunsLayout $b 'date-name'
    Save-All $b 'rules: date-name runs'
    $null = Invoke-Quiet $b @('pull', '-q', '--no-rebase', '--no-edit')
    Expect-True ((Get-NSRunsLayout $b) -ceq 'name') 'rule: an unresolved file reads as the shipped default'
    $null = Invoke-Quiet $b @('checkout', '-q', '--ours', '.nightshift/rules.json')
    $null = Invoke-Quiet $b @('add', '.nightshift/rules.json')
    $null = Invoke-Quiet $b @('commit', '-q', '--no-edit')
    Expect-True ((Get-NSRunsLayout $b) -ceq 'date-name') 'rule: the resolved value is read'

    # Filing tags the folder and leaves later edits to the shared plan and decisions alone.
    $a = New-Team 'filing'
    Write-Thread $a 'export-csv-separator.md' 'CSV separator' 'comma or semicolon?'
    $started = Invoke-StartRun $a 'Export CSV'
    $filingRun = Get-RunName $started
    $planFile = Join-Path $a '.nightshift/staging/plans/export-csv.md'
    $threadFile = Join-Path $a '.nightshift/staging/decisions/export-csv-separator.md'
    [IO.File]::AppendAllText($planFile, "- [ ] **2. Added after the run took its copy.**`n", $utf8)
    [IO.File]::AppendAllText($threadFile, "  - Decided: comma`n", $utf8)
    $plan = [IO.File]::ReadAllText($planFile)
    $decisions = [IO.File]::ReadAllText($threadFile)
    $null = Invoke-Helper 'archive-receipts.ps1' @('-Project', $a, '-Run', $filingRun)
    Expect-True ([IO.File]::ReadAllText($planFile) -ceq $plan) 'filing: the shared plan is untouched'
    Expect-True ([IO.File]::ReadAllText($threadFile) -ceq $decisions) 'filing: the decision thread is untouched'
    $folder = Get-NSArchiveDir -Workspace $a -Date '2026-11-27' -ShiftId '0123456789abcdef'
    Expect-True ((Split-Path -Leaf $folder) -ceq '2026-11-27-012345') "filing: tagged archive folder $folder"

    # A solo site keeps its run names, takes the plan out of staging and writes no sharing block.
    $solo = Join-Path $root 'solo'
    $null = New-Item -ItemType Directory -Path (Join-Path $solo '.nightshift/staging/plans'), (Join-Path $solo '.nightshift/runs') -Force
    $null = Invoke-Quiet $root @('init', '-q', (Join-Path $solo 'repo'))
    $null = Invoke-Quiet (Join-Path $solo 'repo') @('-c', 'user.email=d@example.com', '-c', 'user.name=d', 'commit', '-q', '--allow-empty', '-m', 'init')
    Write-Text (Join-Path $solo '.nightshift/state-version') "3`n"
    Copy-Item -LiteralPath $rulesTemplate -Destination (Join-Path $solo '.nightshift/rules.json')
    $null = New-Item -ItemType Directory -Path (Join-Path $solo '.nightshift/run') -Force
    Write-Text (Join-Path $solo '.nightshift/run/work-target') ((Resolve-NSCanonicalPath (Join-Path $solo 'repo')) + "`n")
    Write-Text (Join-Path $solo '.nightshift/run/work-mode') "repository`n"
    Write-Text (Join-Path $solo '.nightshift/staging/plans/export-csv.md') ("# Punch List " + [char]0x2014 + " Export CSV`n`n## Contract`n`n- Work in the run.`n`n## Gates`n`n## Items`n`n- [ ] **1. Export the table.**`n  - Verify: true`n  - Commit: ``feat: export```n")
    $preview = Invoke-Helper 'share.ps1' @('-Project', $solo)
    Expect-True ($preview.Lines -ccontains 'ok records none: the site stays private to its runner') "solo: $($preview.Text)"
    $started = Invoke-Helper 'start-run.ps1' @('-Project', $solo, '-Plan', 'Export CSV', '-HostName', 'claude')
    Expect-True ($started.ExitCode -eq 0 -and ($started.Lines -ccontains 'ok run export-csv') -and ($started.Lines -ccontains 'ok plan Export CSV left staging')) "solo: $($started.Text)"
    Expect-True (-not (Test-Path -LiteralPath (Join-Path $solo '.nightshift/.gitignore'))) 'solo: no sharing block'
    $soloFolder = Get-NSArchiveDir -Workspace (Resolve-NSCanonicalPath $solo) -Date '2026-11-27' -ShiftId '0123456789abcdef'
    Expect-True ((Split-Path -Leaf $soloFolder) -ceq '2026-11-27') "solo: untagged archive folder $soloFolder"

    # Sharing refuses a value it does not know, a receipts repo and a one-shift layout.
    $a = New-Team 'refusals'
    Set-Records $a @('plans', 'secrets')
    $refused = Invoke-Helper 'share.ps1' @('-Project', $a)
    Expect-True ($refused.ExitCode -eq 1 -and ($refused.Lines -ccontains 'refuse records sharing.records names secrets, which is no record')) "refusals: unknown: $($refused.Text)"
    Set-Records $a @('plans')
    $null = Invoke-Quiet $a @('init', '-q', '.nightshift')
    $refused = Invoke-Helper 'share.ps1' @('-Project', $a, '-Apply')
    Expect-True ($refused.ExitCode -eq 1 -and $refused.Text.Contains('refuse receipts-repo ')) "refusals: receipts repo: $($refused.Text)"
    Remove-Item -LiteralPath (Join-Path $a '.nightshift/.git') -Recurse -Force
    Write-Text (Join-Path $a '.nightshift/state-version') "2`n"
    $refused = Invoke-Helper 'share.ps1' @('-Project', $a, '-Apply')
    Expect-True ($refused.ExitCode -eq 1 -and $refused.Text.Contains('refuse layout ')) "refusals: layout: $($refused.Text)"
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
