# Shift worktrees on native Windows: the PowerShell half of tests/shift-worktree.bats.
# Run on macOS or Windows: pwsh -File tests/windows/shift-worktree-logic.ps1
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$repository = Resolve-Path (Join-Path $PSScriptRoot '../..')
$plugin = Join-Path $repository 'plugins/nightshift'
Import-Module (Join-Path $plugin 'lib/Nightshift.psm1') -Force -DisableNameChecking
$rulesTemplate = Join-Path $plugin 'skills/nightshift/references/nightshift-rules-template.json'
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
