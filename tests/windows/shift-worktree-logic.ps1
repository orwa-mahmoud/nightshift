# Shift worktrees on native Windows: the PowerShell half of tests/shift-worktree.bats.
# Run on macOS or Windows: pwsh -File tests/windows/shift-worktree-logic.ps1
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$repository = Resolve-Path (Join-Path $PSScriptRoot '../..')
$plugin = Join-Path $repository 'plugins/nightshift'
Import-Module (Join-Path $plugin 'lib/Nightshift.psm1') -Force -DisableNameChecking
$rulesTemplate = Join-Path $plugin 'config/nightshift-rules-template.json'
$preflight = Join-Path $plugin 'runtime/windows/start-preflight.ps1'
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

function Invoke-Git { param([string]$Directory, [string[]]$Arguments) $null = Invoke-NSGitCommand $Directory $Arguments }

# Invoke-Archive <script> <site> - Archive's output, stdout and stderr together. Windows PowerShell
# turns a native command's stderr into an error record, which 'Stop' would make terminating.
function Invoke-Archive {
    param([string]$Script, [string]$Site)
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { return ((& $hostExe -NoProfile -NonInteractive -File $Script -Project $Site 2>&1 | ForEach-Object { [string]$_ }) -join "`n") }
    finally { $ErrorActionPreference = $previous }
}

# New-Site <path> <shift-block> - a version-2 workspace beside its code repo, no shift armed, one open
# item, the owner's shift block merged from the hashtable. The repo ignores .env files and the owner
# has uncommitted work in it. The snapshot is recorded.
function New-Site {
    param([Parameter(Mandatory = $true)][string]$Path, [hashtable]$Shift = @{})
    $ns = Join-Path $Path '.nightshift'
    $repo = Join-Path $Path 'repo'
    $null = New-Item -ItemType Directory -Path (Join-Path $ns 'run'), $repo -Force
    $rules = [IO.File]::ReadAllText($rulesTemplate) | ConvertFrom-Json
    foreach ($key in $Shift.Keys) { $rules.shift | Add-Member -NotePropertyName $key -NotePropertyValue $Shift[$key] -Force }
    [IO.File]::WriteAllText((Join-Path $ns 'rules.json'), ($rules | ConvertTo-Json -Depth 8), $utf8)
    [IO.File]::WriteAllText((Join-Path $ns 'state-version'), "2`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $ns 'punch-list.md'), ("# Punch List " + [char]0x2014 + " Worktree trial`n`n## Items`n`n- [ ] **1. Change the app.**`n  - Verify: x`n  - Commit: ``feat: x```n"), $utf8)
    Invoke-Git $repo @('init', '-q')
    Invoke-Git $repo @('config', 'user.email', 'dev@example.com')
    Invoke-Git $repo @('config', 'user.name', 'tester')
    [IO.File]::WriteAllText((Join-Path $repo 'app.txt'), "app`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $repo '.gitignore'), ".env*`n", $utf8)
    Invoke-Git $repo @('add', 'app.txt', '.gitignore')
    Invoke-Git $repo @('commit', '-q', '-m', 'app')
    [IO.File]::WriteAllText((Join-Path $repo '.env'), "SECRET=real`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $repo '.env.test'), "SECRET=test`n", $utf8)
    [IO.File]::AppendAllText((Join-Path $repo 'app.txt'), "owner work in progress`n", $utf8)
    $null = & $hostExe -NoProfile -NonInteractive -File $preflight -Project $Path -Phase snapshot
    return (Resolve-NSCanonicalPath $Path)
}

function Invoke-Worktree {
    param([string]$Path)
    $out = @(& $hostExe -NoProfile -NonInteractive -File $preflight -Project $Path -Phase worktree)
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Lines = $out; Text = ($out -join "`n") }
}

# New-RunsSite <path> - a version-3 workspace with no run yet, its code repo beside it holding a commit
# and the owner's uncommitted work, and two plans waiting in staging: "Export CSV" and "Dark mode".
function New-RunsSite {
    param([Parameter(Mandatory = $true)][string]$Path)
    $ns = Join-Path $Path '.nightshift'
    $repo = Join-Path $Path 'repo'
    $null = New-Item -ItemType Directory -Path (Join-Path $ns 'run'), (Join-Path $ns 'runs'), (Join-Path $ns 'staging/plans'), $repo -Force
    Copy-Item -LiteralPath $rulesTemplate -Destination (Join-Path $ns 'rules.json')
    [IO.File]::WriteAllText((Join-Path $ns 'state-version'), "3`n", $utf8)
    Invoke-Git $repo @('init', '-q')
    Invoke-Git $repo @('config', 'user.email', 'dev@example.com')
    Invoke-Git $repo @('config', 'user.name', 'tester')
    [IO.File]::WriteAllText((Join-Path $repo 'app.txt'), "app`n", $utf8)
    Invoke-Git $repo @('add', 'app.txt')
    Invoke-Git $repo @('commit', '-q', '-m', 'app')
    [IO.File]::AppendAllText((Join-Path $repo 'app.txt'), "owner work in progress`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $repo 'notes.txt'), "notes`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $ns 'run/work-target'), (Resolve-NSCanonicalPath $repo) + "`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $ns 'run/work-mode'), "repository`n", $utf8)
    foreach ($name in @('Export CSV', 'Dark mode')) {
        $file = Join-Path $ns ('staging/plans/' + $name.ToLowerInvariant().Replace(' ', '-') + '.md')
        [IO.File]::WriteAllText($file, ("# Punch List " + [char]0x2014 + " $name`n`n## Contract`n`n- Work in the run.`n`n## Gates`n`n## Items`n`n- [ ] **1. Do $name.**`n  - Verify: true`n  - Commit: ``feat: x```n"), $utf8)
    }
    return (Resolve-NSCanonicalPath $Path)
}

# Get-OwnerState <repo> - HEAD, index, edits and files of the owner's checkout, as one string.
function Get-OwnerState {
    param([string]$Repo)
    return ((@(& git -C $Repo rev-parse HEAD) + @(& git -C $Repo status --porcelain) + @(& git -C $Repo diff) +
            @(& git -C $Repo diff --cached) + [IO.File]::ReadAllText((Join-Path $Repo 'app.txt')) +
            [IO.File]::ReadAllText((Join-Path $Repo 'notes.txt'))) -join "`n")
}

# Invoke-StartRun <workspace> <plan> [-Background] - start-run.ps1's verdicts and exit code.
function Invoke-StartRun {
    param([string]$Path, [string]$Plan, [switch]$Background)
    $saved = $env:NIGHTSHIFT_RUN
    $env:NIGHTSHIFT_RUN = $null
    try {
        $arguments = @('-NoProfile', '-NonInteractive', '-File', (Join-Path $plugin 'runtime/windows/start-run.ps1'), '-Project', $Path, '-Plan', $Plan, '-HostName', 'claude')
        if ($Background) { $arguments += '-Background' }
        $out = @(& $hostExe @arguments 2>&1 | ForEach-Object { [string]$_ })
        return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Text = ($out -join "`n") }
    }
    finally { $env:NIGHTSHIFT_RUN = $saved }
}

$root = Join-Path ([IO.Path]::GetTempPath()) ('ns-shift-worktree-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $root -Force
try {
    # isolation none leaves the shift in the work target.
    $plain = New-Site (Join-Path $root 'plain')
    $run = Invoke-Worktree $plain
    Expect-True ($run.ExitCode -eq 0 -and $run.Text.Contains('ok worktree none - the shift works in the work target itself')) "none: $($run.Text)"
    Expect-True ((Resolve-NSWorkTarget $plain) -eq (Resolve-NSCanonicalPath (& git -C (Join-Path $plain 'repo') rev-parse --show-toplevel))) 'none keeps the checkout as the work target'

    # isolation worktree: its own prepared worktree and branch; the checkout stays as it was.
    $site = New-Site (Join-Path $root 'isolated') @{ isolation = 'worktree'; copyIn = @('.env.test'); prepare = "Set-Content -Path .env.prepared -Value yes" }
    $repo = Join-Path $site 'repo'
    $headBefore = (& git -C $repo rev-parse HEAD)
    $statusBefore = (& git -C $repo status --porcelain) -join "`n"
    $run = Invoke-Worktree $site
    $branch = 'shift/' + (Get-Date -Format 'yyyy-MM-dd') + '-worktree-trial'
    Expect-True ($run.ExitCode -eq 0 -and $run.Text.Contains("branch $branch from " + $headBefore.Substring(0, 7) + ' - work there')) "worktree: $($run.Text)"
    $worktree = Get-NSShiftWorktreeField $site 'path'
    Expect-True ((& git -C $worktree rev-parse --abbrev-ref HEAD) -ceq $branch) 'the worktree is on the shift branch'
    Expect-True (Test-Path -LiteralPath (Join-Path $worktree '.env.prepared')) 'prepare ran in the worktree'
    Expect-True (Test-Path -LiteralPath (Join-Path $worktree '.env.test')) 'copyIn copied the listed file'
    Expect-True (-not (Test-Path -LiteralPath (Join-Path $worktree '.env'))) 'an unlisted ignored file stays out'
    Expect-True ((Resolve-NSWorkTarget $site) -eq (Resolve-NSCanonicalPath $worktree)) 'the worktree is the work target'
    Expect-True ((Resolve-NSOwnerWorkTarget $site) -eq (Resolve-NSCanonicalPath (& git -C $repo rev-parse --show-toplevel))) 'the owner work target is still the checkout'
    [IO.File]::WriteAllText((Join-Path $worktree 'feature.txt'), "feature`n", $utf8)
    Invoke-Git $worktree @('add', 'feature.txt')
    Invoke-Git $worktree @('-c', 'user.name=t', '-c', 'user.email=t@example.com', 'commit', '-q', '-m', 'feat: feature')
    Expect-True ((& git -C $repo rev-parse HEAD) -ceq $headBefore) 'the checkout keeps its HEAD'
    Expect-True (((& git -C $repo status --porcelain) -join "`n") -ceq $statusBefore) 'the checkout keeps its index and edits'
    $run = Invoke-Worktree $site
    Expect-True ($run.Text.Contains("this shift's worktree, kept")) "a second run keeps the worktree: $($run.Text)"

    # Status and the morning page follow the worktree.
    $status = (& $hostExe -NoProfile -NonInteractive -File (Join-Path $plugin 'runtime/windows/status.ps1') -Project $site) -join "`n"
    Expect-True ($status.Contains("isolation worktree, branch $branch")) "status: $status"
    $morning = (& $hostExe -NoProfile -NonInteractive -File (Join-Path $plugin 'runtime/windows/morning-receipt.ps1') -Project $site) -join "`n"
    Expect-True ($morning.Contains("- Isolation: worktree, branch $branch from " + $headBefore.Substring(0, 7))) "morning isolation: $morning"
    Expect-True ($morning.Contains('- Branch: 1 file changed, 1 insertion(+)')) "morning branch: $morning"
    Expect-True ($morning.Contains("merge --ff-only $branch")) "morning merge: $morning"

    # Archive: unmerged keeps the worktree; merged removes it and keeps the branch.
    $id = Get-NSShiftWorktreeField $site 'shift'
    [IO.File]::WriteAllText((Get-NSLayoutPath (Join-Path $site '.nightshift') 'ended'), "shiftId=$id`narchiveRoot=archive`narchiveLayout=date`n", $utf8)
    $archive = Join-Path $plugin 'runtime/windows/archive-receipts.ps1'
    $out = Invoke-Archive $archive $site
    Expect-True ($out.Contains("kept the shift worktree ${worktree}: branch $branch is not merged") -and (Test-Path -LiteralPath $worktree)) "unmerged archive: $out"
    Invoke-Git $repo @('stash', '-q')
    Invoke-Git $repo @('merge', '-q', '--ff-only', $branch)
    Invoke-Git $repo @('stash', 'pop', '-q')
    $out = Invoke-Archive $archive $site
    Expect-True ($out.Contains("removed the shift worktree $worktree; branch $branch is merged and kept")) "merged archive: $out"
    Expect-True (-not (Test-Path -LiteralPath $worktree)) 'the merged worktree folder is gone'
    Expect-True (@(& git -C $repo branch --list $branch).Count -eq 1) 'the branch is never deleted'

    # A prepare that fails refuses and leaves nothing behind.
    $failing = New-Site (Join-Path $root 'failing') @{ isolation = 'worktree'; prepare = "Write-Error 'missing tool'; exit 3" }
    $run = Invoke-Worktree $failing
    Expect-True ($run.ExitCode -eq 1 -and $run.Text.Contains('refuse worktree prepare exited 3 in ')) "failing prepare: $($run.Text)"
    Expect-True (@(& git -C (Join-Path $failing 'repo') branch --list 'shift/*').Count -eq 0) 'the failed branch is removed'
    Expect-True ((Get-NSShiftWorktreeField $failing 'path').Length -eq 0) 'no record is written'

    # A session already in a linked worktree gets no second one.
    $hosted = New-Site (Join-Path $root 'hosted') @{ isolation = 'worktree' }
    $hostWorktree = Join-Path $hosted 'host-wt'
    Invoke-Git (Join-Path $hosted 'repo') @('worktree', 'add', '-q', '-b', 'host-made', $hostWorktree)
    [IO.File]::WriteAllText((Get-NSLayoutPath (Join-Path $hosted '.nightshift') 'work-target'), ((Resolve-NSCanonicalPath $hostWorktree) + "`n"), $utf8)
    $run = Invoke-Worktree $hosted
    Expect-True ($run.Text.Contains('ok worktree host ') -and $run.Text.Contains('already works in its own worktree')) "host worktree: $($run.Text)"

    # Artifact mode ignores the setting, and Status says so.
    $artifact = New-Site (Join-Path $root 'artifact') @{ isolation = 'worktree' }
    [IO.File]::WriteAllText((Get-NSLayoutPath (Join-Path $artifact '.nightshift') 'work-mode'), "artifact`n", $utf8)
    $run = Invoke-Worktree $artifact
    Expect-True ($run.Text.Contains('ok worktree not-applicable - artifact mode works in its folder')) "artifact: $($run.Text)"
    $status = (& $hostExe -NoProfile -NonInteractive -File (Join-Path $plugin 'runtime/windows/status.ps1') -Project $artifact) -join "`n"
    Expect-True ($status.Contains('isolation not-applicable (artifact mode)')) "artifact status: $status"

    # Two named plans from a dirty owner checkout: two run folders, two worktrees, the owner's files
    # exactly as they were. The path holds a space.
    $runs = New-RunsSite (Join-Path $root 'named runs')
    $runsRepo = Join-Path $runs 'repo'
    $before = Get-OwnerState $runsRepo
    $first = Invoke-StartRun $runs 'Export CSV'
    Expect-True ($first.ExitCode -eq 0 -and $first.Text.Contains('ok run export-csv')) "first run: $($first.Text)"
    $second = Invoke-StartRun $runs 'Dark mode'
    Expect-True ($second.ExitCode -eq 0 -and $second.Text.Contains('ok run dark-mode')) "second run: $($second.Text)"
    Expect-True (Test-Path -LiteralPath (Join-Path $runs '.nightshift/runs/export-csv/punch-list.md')) 'the first run holds its punch list'
    Expect-True (Test-Path -LiteralPath (Join-Path $runs '.nightshift/runs/dark-mode/punch-list.md')) 'the second run holds its punch list'
    Expect-True (-not (Test-Path -LiteralPath (Join-Path $runs '.nightshift/staging/plans/export-csv.md'))) 'the first plan left staging'
    Expect-True (@(& git -C $runsRepo worktree list).Count -eq 3) 'each run has its own worktree'
    Expect-True ((Get-OwnerState $runsRepo) -ceq $before) "the owner's checkout is unchanged"
    $runRules = [IO.File]::ReadAllText((Join-Path $runs '.nightshift/runs/export-csv/rules.json')) | ConvertFrom-Json
    Expect-True ($runRules.shift.isolation -ceq 'worktree') 'the run rules give the run its worktree'

    # A failed worktree step leaves the plan staged and the checkout as it was.
    $blocked = New-RunsSite (Join-Path $root 'blocked run')
    $blockedRepo = Join-Path $blocked 'repo'
    Invoke-Git $blockedRepo @('branch', ('shift/' + (Get-Date -Format 'yyyy-MM-dd') + '-export-csv'))
    $before = Get-OwnerState $blockedRepo
    $refused = Invoke-StartRun $blocked 'Export CSV'
    Expect-True ($refused.ExitCode -eq 1 -and $refused.Text -cmatch '(?m)^refuse worktree ') "failed worktree: $($refused.Text)"
    Expect-True (Test-Path -LiteralPath (Join-Path $blocked '.nightshift/staging/plans/export-csv.md')) 'the plan stays staged'
    Expect-True (@(& git -C $blockedRepo worktree list).Count -eq 1) 'no worktree is left'
    Expect-True ((Get-OwnerState $blockedRepo) -ceq $before) "the owner's checkout is unchanged after the refusal"

    # A background start whose worker cannot start arms nothing and leaves the plan staged.
    $background = New-RunsSite (Join-Path $root 'background run')
    $env:NIGHTSHIFT_WATCH_AGENT = Join-Path $root 'missing-agent'
    try { $noWorker = Invoke-StartRun $background 'Dark mode' -Background } finally { $env:NIGHTSHIFT_WATCH_AGENT = $null }
    Expect-True ($noWorker.ExitCode -eq 1 -and $noWorker.Text.Contains('missing-agent is not installed')) "missing worker: $($noWorker.Text)"
    Expect-True (Test-Path -LiteralPath (Join-Path $background '.nightshift/staging/plans/dark-mode.md')) 'the background plan stays staged'
    Expect-True (-not (Test-Path -LiteralPath (Join-Path $background '.nightshift/runs/dark-mode/run/.shift-armed'))) 'nothing is armed'

    # Each host's headless launch, at the watchman's launch scope.
    $claude = Get-NSBackgroundWorkerCommand -Workspace $runs -HostName claude -Scope 'host-default' -Prompt 'go'
    Expect-True ($claude.Name -ceq 'claude' -and ($claude.Arguments -join ' ') -ceq '-p go') "claude launch: $($claude.Arguments -join ' ')"
    $codex = Get-NSBackgroundWorkerCommand -Workspace $runs -HostName codex -Scope 'recorded:workspace-write' -Prompt 'go'
    Expect-True ($codex.Name -ceq 'codex' -and ($codex.Arguments -join ' ') -ceq 'exec -s workspace-write go') "codex launch: $($codex.Arguments -join ' ')"
    $refusedScope = Get-NSBackgroundWorkerCommand -Workspace $runs -HostName claude -Scope 'unavailable:host-grant' -Prompt 'go'
    Expect-True ($refusedScope.Error.Length -gt 0 -and $refusedScope.Name -ceq '') 'an unavailable scope starts nothing'
    $env:NIGHTSHIFT_WATCH_AGENT = 'my-agent --flag'
    try { $owned = Get-NSBackgroundWorkerCommand -Workspace $runs -HostName claude -Scope 'host-default' -Prompt 'go' }
    finally { $env:NIGHTSHIFT_WATCH_AGENT = $null }
    Expect-True ($owned.Name -ceq 'my-agent' -and ($owned.Arguments -join ' ') -ceq '--flag go') "owner agent: $($owned.Arguments -join ' ')"

    # Each run's watchman is told apart by its run.
    Expect-True (Test-NSWatchmanCommandForProject "bash /tmp/watchman.sh --project $runs --run a" $runs 'a') 'a run matches its own watchman'
    Expect-True (-not (Test-NSWatchmanCommandForProject "bash /tmp/watchman.sh --project $runs --run a" $runs 'b')) "another run's watchman does not match"
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures.Count -gt 0) {
    Write-Host "shift-worktree-logic failed ($($failures.Count)):"
    foreach ($failure in $failures) { Write-Host " - $failure" }
    exit 1
}
Write-Host 'shift-worktree-logic passed'
exit 0
