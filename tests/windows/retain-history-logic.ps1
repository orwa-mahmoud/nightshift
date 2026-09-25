# Portable PowerShell coverage for Windows retain-history apply.
# Run on macOS or Windows: pwsh -File tests/windows/retain-history-logic.ps1
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if (Test-Path Variable:PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $false
}

$repository = Resolve-Path (Join-Path $PSScriptRoot '../..')
$helper = Join-Path $repository 'plugins/nightshift/runtime/windows/retain-history.ps1'
$template = Join-Path $repository 'plugins/nightshift/skills/nightshift/references/nightshift-rules-template.json'
$hostExecutable = (Get-Process -Id $PID).Path
$failures = New-Object 'System.Collections.Generic.List[string]'
$onWin32 = [Environment]::OSVersion.Platform -eq 'Win32NT'

function Expect-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        $failures.Add($Message)
        Write-Host "FAIL: $Message"
    }
}

function Invoke-RetainHistory {
    param(
        [Parameter(Mandatory = $true)][string]$Project,
        [switch]$Apply
    )
    $argList = @(
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', $helper, '-Project', $Project
    )
    if ($Apply) {
        $argList += '-Apply'
    }
    $stdout = [Collections.Generic.List[string]]::new()
    $stderr = [Collections.Generic.List[string]]::new()
    $previousEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        foreach ($item in @(& $hostExecutable @argList 2>&1)) {
            if ($item -is [Management.Automation.ErrorRecord]) {
                $stderr.Add([string]$item)
            }
            else {
                $stdout.Add([string]$item)
            }
        }
    }
    finally {
        $ErrorActionPreference = $previousEap
    }
    $code = $LASTEXITCODE
    if ($null -eq $code) {
        $code = 1
    }
    return [pscustomobject]@{
        ExitCode = [int]$code
        Stdout = ($stdout -join "`n")
        Stderr = ($stderr -join "`n")
    }
}

function Set-RetentionRules {
    param([Parameter(Mandatory = $true)][string]$NightshiftDir, [int]$LogDays, [int]$ArchiveDays)
    $path = Join-Path $NightshiftDir 'rules.json'
    $raw = [IO.File]::ReadAllText($path)
    $raw = $raw.Replace('"runtimeLogDays": 0', '"runtimeLogDays": ' + $LogDays)
    $raw = $raw.Replace('"archiveDays": 0', '"archiveDays": ' + $ArchiveDays)
    [IO.File]::WriteAllText($path, $raw)
}

function Age-Path {
    param([Parameter(Mandatory = $true)][string]$Path)
    $item = Get-Item -LiteralPath $Path -Force
    $item.LastWriteTimeUtc = [DateTime]::UtcNow.AddDays(-400)
}

function New-ReparseDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Target
    )
    if ($onWin32) {
        $null = New-Item -ItemType Junction -Path $Path -Target $Target
    }
    else {
        $null = New-Item -ItemType SymbolicLink -Path $Path -Target $Target
    }
}

$root = Join-Path ([IO.Path]::GetTempPath()) ("ns-retain-history-logic-" + [guid]::NewGuid().ToString('N'))
try {
    $applyRoot = Join-Path $root 'apply'
    $null = New-Item -ItemType Directory -Path (Join-Path $applyRoot '.nightshift') -Force
    $ns = Join-Path $applyRoot '.nightshift'
    Copy-Item -LiteralPath $template -Destination (Join-Path $ns 'rules.json')
    Set-RetentionRules $ns 7 30
    [IO.File]::WriteAllText((Join-Path $ns 'scheduled.log'), "old log`n")
    $oldArchive = Join-Path $ns 'archive/2020-01-01'
    $newArchive = Join-Path $ns 'archive/2026-08-01'
    $null = New-Item -ItemType Directory -Path $oldArchive -Force
    $null = New-Item -ItemType Directory -Path $newArchive -Force
    [IO.File]::WriteAllText((Join-Path $oldArchive 'shipped.md'), "- [x] done`n")
    [IO.File]::WriteAllText((Join-Path $newArchive 'shipped.md'), "- [x] recent`n")
    [IO.File]::WriteAllText((Join-Path $ns 'punch-list.md'), "live`n")
    [IO.File]::WriteAllText((Join-Path $ns 'notes-from-owner.md'), "owner`n")
    Age-Path (Join-Path $ns 'scheduled.log')
    Age-Path $oldArchive

    $preview = Invoke-RetainHistory $applyRoot
    Expect-True ($preview.ExitCode -eq 0) "preview exits 0 (got $($preview.ExitCode) $($preview.Stderr))"
    Expect-True ($preview.Stdout -match 'scheduled.log') 'preview lists the old runtime log'
    Expect-True ($preview.Stdout -match 'archive/2020-01-01') 'preview lists the old archive'
    Expect-True ($preview.Stdout -notmatch 'archive/2026-08-01') 'preview omits the recent archive'
    Expect-True ($preview.Stdout -notmatch 'punch-list.md') 'preview omits the live punch list'
    Expect-True ($preview.Stdout -notmatch 'notes-from-owner') 'preview omits owner notes'
    Expect-True ($preview.Stdout -match 'Dry run') 'preview is a dry run'
    Expect-True (Test-Path -LiteralPath (Join-Path $ns 'scheduled.log')) 'preview does not delete the log'
    Expect-True (Test-Path -LiteralPath $oldArchive) 'preview does not delete the old archive'

    $applied = Invoke-RetainHistory $applyRoot -Apply
    Expect-True ($applied.ExitCode -eq 0) "apply exits 0 (got $($applied.ExitCode) $($applied.Stderr))"
    Expect-True ($applied.Stdout -match 'Deleted the eligible allowlisted paths') 'apply reports deletion'
    Expect-True (-not (Test-Path -LiteralPath (Join-Path $ns 'scheduled.log'))) 'apply deletes the old log'
    Expect-True (-not (Test-Path -LiteralPath $oldArchive)) 'apply deletes the old archive'
    Expect-True (Test-Path -LiteralPath $newArchive) 'apply keeps the recent archive'
    Expect-True (Test-Path -LiteralPath (Join-Path $ns 'punch-list.md')) 'apply keeps the live punch list'
    Expect-True (Test-Path -LiteralPath (Join-Path $ns 'notes-from-owner.md')) 'apply keeps owner notes'
    Expect-True (Test-Path -LiteralPath (Join-Path $ns 'rules.json')) 'apply keeps rules.json'

    $armedRoot = Join-Path $root 'armed'
    $null = New-Item -ItemType Directory -Path (Join-Path $armedRoot '.nightshift') -Force
    $ans = Join-Path $armedRoot '.nightshift'
    Copy-Item -LiteralPath $template -Destination (Join-Path $ans 'rules.json')
    Set-RetentionRules $ans 1 1
    [IO.File]::WriteAllText((Join-Path $ans '.shift-armed'), '')
    [IO.File]::WriteAllText((Join-Path $ans 'scheduled.log'), "old log`n")
    Age-Path (Join-Path $ans 'scheduled.log')
    $armedPreview = Invoke-RetainHistory $armedRoot
    Expect-True ($armedPreview.ExitCode -eq 0) "armed preview exits 0 (got $($armedPreview.ExitCode) $($armedPreview.Stderr))"
    Expect-True ($armedPreview.Stdout -match 'Armed:\s+yes') 'armed preview reports the armed marker'
    Expect-True ($armedPreview.Stdout -match 'scheduled.log') 'armed preview still lists eligible paths'
    $armedApply = Invoke-RetainHistory $armedRoot -Apply
    Expect-True ($armedApply.ExitCode -eq 2) "armed apply exits 2 (got $($armedApply.ExitCode) $($armedApply.Stderr))"
    Expect-True ($armedApply.Stderr -match 'refuse to delete while the shift is armed') `
        "armed refuse names the armed marker: $($armedApply.Stderr)"
    Expect-True (Test-Path -LiteralPath (Join-Path $ans 'scheduled.log')) 'armed apply does not delete'

    $hostile = Join-Path $root 'hostile'
    $null = New-Item -ItemType Directory -Path (Join-Path $hostile '.nightshift/archive') -Force
    $hns = Join-Path $hostile '.nightshift'
    Copy-Item -LiteralPath $template -Destination (Join-Path $hns 'rules.json')
    Set-RetentionRules $hns 1 1
    $outside = Join-Path $root 'outside.log'
    [IO.File]::WriteAllText($outside, "secret`n")
    $logLink = Join-Path $hns 'scheduled.log'
    $fileLinkCreated = $true
    try {
        $null = New-Item -ItemType SymbolicLink -Path $logLink -Target $outside -ErrorAction Stop
    }
    catch {
        if ($onWin32) {
            $fileLinkCreated = $false
        }
        else {
            throw
        }
    }
    $openArchive = Join-Path $hns 'archive/2020-01-01'
    $null = New-Item -ItemType Directory -Path $openArchive -Force
    [IO.File]::WriteAllText((Join-Path $openArchive 'punch-list.md'), "## Items`n- [ ] still open`n")
    Age-Path $openArchive
    $doneArchive = Join-Path $hns 'archive/2019-01-01'
    $null = New-Item -ItemType Directory -Path $doneArchive -Force
    [IO.File]::WriteAllText((Join-Path $doneArchive 'shipped.md'), "- [x] done`n")
    Age-Path $doneArchive
    $outsideDir = Join-Path $root 'outside-dir'
    $null = New-Item -ItemType Directory -Path $outsideDir -Force
    [IO.File]::WriteAllText((Join-Path $outsideDir 'secret.md'), "outside`n")
    $archiveLink = Join-Path $hns 'archive/2018-01-01'
    New-ReparseDirectory $archiveLink $outsideDir

    [IO.File]::WriteAllText((Join-Path $hns 'punch-list.md'), "## Items`n- [ ] live open`n")
    $linkArchive = Join-Path $hns 'archive/2017-01-01'
    $null = New-Item -ItemType Directory -Path $linkArchive -Force
    [IO.File]::WriteAllText((Join-Path $linkArchive 'shipped.md'), "- [x] done`n")
    $punchLink = Join-Path $linkArchive 'punch-list.md'
    $punchLinkCreated = $true
    try {
        $null = New-Item -ItemType SymbolicLink -Path $punchLink -Target (Join-Path $hns 'punch-list.md') -ErrorAction Stop
    }
    catch {
        if ($onWin32) {
            $punchLinkCreated = $false
        }
        else {
            throw
        }
    }
    Age-Path $linkArchive

    $hostilePreview = Invoke-RetainHistory $hostile
    Expect-True ($hostilePreview.ExitCode -eq 0) "hostile preview exits 0 (got $($hostilePreview.ExitCode) $($hostilePreview.Stderr))"
    if ($fileLinkCreated) {
        Expect-True ($hostilePreview.Stdout -notmatch 'scheduled.log') 'symlink runtime log is not eligible'
    }
    Expect-True ($hostilePreview.Stdout -notmatch 'archive/2020-01-01') 'open-work archive is not eligible'
    Expect-True ($hostilePreview.Stdout -notmatch 'archive/2018-01-01') 'reparse archive directory is not eligible'
    Expect-True ($hostilePreview.Stdout -match 'archive/2019-01-01') 'closed old archive is eligible'
    if ($punchLinkCreated) {
        Expect-True ($hostilePreview.Stdout -match 'archive/2017-01-01') 'symlink punch-list is not open work'
    }

    $hostileApply = Invoke-RetainHistory $hostile -Apply
    Expect-True ($hostileApply.ExitCode -eq 0) "hostile apply exits 0 (got $($hostileApply.ExitCode) $($hostileApply.Stderr))"
    if ($fileLinkCreated) {
        Expect-True (Test-Path -LiteralPath $logLink) 'apply leaves the symlink log'
        Expect-True (Test-Path -LiteralPath $outside) 'apply does not follow the symlink outside .nightshift'
    }
    Expect-True (Test-Path -LiteralPath (Join-Path $openArchive 'punch-list.md')) 'apply leaves the open-work archive'
    Expect-True (Test-Path -LiteralPath $archiveLink) 'apply leaves the reparse archive directory'
    Expect-True (Test-Path -LiteralPath (Join-Path $outsideDir 'secret.md')) 'apply does not follow the archive reparse point'
    Expect-True (-not (Test-Path -LiteralPath $doneArchive)) 'apply deletes the closed old archive'
    if ($punchLinkCreated) {
        Expect-True (-not (Test-Path -LiteralPath $linkArchive)) 'apply deletes the archive whose punch-list is a symlink'
        Expect-True (Test-Path -LiteralPath (Join-Path $hns 'punch-list.md')) 'apply leaves the live punch list'
    }

    # A later shift's dated folder is previewed and pruned by age like its day's first.
    $laterRoot = Join-Path $root 'later-shift'
    $lns = Join-Path $laterRoot '.nightshift'
    $null = New-Item -ItemType Directory -Path $lns -Force
    Copy-Item -LiteralPath $template -Destination (Join-Path $lns 'rules.json')
    Set-RetentionRules $lns 0 30
    $second = Join-Path $lns 'archive/2020-01-01-shift-2'
    $notOurs = Join-Path $lns 'archive/2020-01-01-shift-x'
    $recentSecond = Join-Path $lns 'archive/2026-08-01-shift-2'
    foreach ($dir in @($second, $notOurs, $recentSecond)) { $null = New-Item -ItemType Directory -Path $dir -Force }
    [IO.File]::WriteAllText((Join-Path $second 'punch-list.md'), "- [x] done`n")
    Age-Path $second
    Age-Path $notOurs
    $laterPreview = Invoke-RetainHistory $laterRoot
    Expect-True ($laterPreview.Stdout -match 'archive/2020-01-01-shift-2') 'preview lists an old later-shift folder'
    Expect-True ($laterPreview.Stdout -notmatch 'archive/2020-01-01-shift-x') 'preview omits a folder that is not a later shift'
    Expect-True ($laterPreview.Stdout -notmatch 'archive/2026-08-01-shift-2') 'preview omits a recent later-shift folder'
    $laterApply = Invoke-RetainHistory $laterRoot -Apply
    Expect-True ($laterApply.ExitCode -eq 0) "later-shift apply exits 0 (got $($laterApply.ExitCode) $($laterApply.Stderr))"
    Expect-True (-not (Test-Path -LiteralPath $second)) 'apply deletes the old later-shift folder'
    Expect-True (Test-Path -LiteralPath $notOurs) 'apply keeps a folder that is not a later shift'
    Expect-True (Test-Path -LiteralPath $recentSecond) 'apply keeps a recent later-shift folder'

    # An old folder holding an archived punch list is pruned; its contract's boxes are not open work.
    $punchRoot = Join-Path $root 'archived-punch'
    $pns = Join-Path $punchRoot '.nightshift'
    $null = New-Item -ItemType Directory -Path $pns -Force
    Copy-Item -LiteralPath $template -Destination (Join-Path $pns 'rules.json')
    Set-RetentionRules $pns 0 30
    $filedPunch = Join-Path $pns 'archive/2020-01-01'
    $null = New-Item -ItemType Directory -Path $filedPunch -Force
    [IO.File]::WriteAllText((Join-Path $filedPunch 'punch-list.md'),
        "> Archived record of shift 1111222233334444, filed 2020-01-01.`n`n# Punch list`n`n- [ ] a box in the contract prose`n`n## Items`n`n- [x] **1. done.**`n")
    Age-Path $filedPunch
    $punchApply = Invoke-RetainHistory $punchRoot -Apply
    Expect-True ($punchApply.ExitCode -eq 0) "archived punch apply exits 0 (got $($punchApply.ExitCode) $($punchApply.Stderr))"
    Expect-True (-not (Test-Path -LiteralPath $filedPunch)) 'apply prunes a folder holding an archived punch list'

    # A folder a shift claimed is pruned by age whatever its name, and its open boxes are the live
    # list's.
    $claimRoot = Join-Path $root 'claimed'
    $cns = Join-Path $claimRoot '.nightshift'
    $null = New-Item -ItemType Directory -Path $cns -Force
    Copy-Item -LiteralPath $template -Destination (Join-Path $cns 'rules.json')
    Set-RetentionRules $cns 0 30
    $named = Join-Path $cns 'archive/archive-follow-ups'
    $dated = Join-Path $cns 'archive/2020-01-01-archive-follow-ups'
    $notes = Join-Path $cns 'archive/notes'
    foreach ($dir in @($named, $dated, $notes)) { $null = New-Item -ItemType Directory -Path $dir -Force }
    [IO.File]::WriteAllText((Join-Path $named '.shift-id'), "1111222233334444`n")
    [IO.File]::WriteAllText((Join-Path $dated '.shift-id'), "5555666677778888`n")
    [IO.File]::WriteAllText((Join-Path $named 'punch-list.md'), "## Items`n`n- [ ] **1. still open.**`n")
    foreach ($dir in @($named, $dated, $notes)) { Age-Path $dir }
    $claimPreview = Invoke-RetainHistory $claimRoot
    Expect-True ($claimPreview.Stdout -match 'archive/archive-follow-ups' -and $claimPreview.Stdout -match 'archive/2020-01-01-archive-follow-ups') `
        "preview lists old claimed folders whatever their names: $($claimPreview.Stdout)"
    Expect-True ($claimPreview.Stdout -notmatch 'archive/notes') 'preview omits a folder no shift claimed'
    $claimApply = Invoke-RetainHistory $claimRoot -Apply
    Expect-True ($claimApply.ExitCode -eq 0) "claimed apply exits 0 (got $($claimApply.ExitCode) $($claimApply.Stderr))"
    Expect-True (-not (Test-Path -LiteralPath $named) -and -not (Test-Path -LiteralPath $dated) -and (Test-Path -LiteralPath $notes)) `
        'apply prunes the claimed folders and keeps the rest'
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures.Count -gt 0) {
    Write-Host "retain-history-logic failed ($($failures.Count)):"
    foreach ($failure in $failures) { Write-Host " - $failure" }
    exit 1
}
Write-Host 'retain-history-logic ok'
exit 0
