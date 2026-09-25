# Portable PowerShell coverage for migrate-state: the move into the current layout, its preview,
# its refusals, its rerun, and the hooks on either side of it.
# Run on macOS or Windows: pwsh -File tests/windows/migrate-state-logic.ps1
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if (Test-Path Variable:PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $false
}

$repository = Resolve-Path (Join-Path $PSScriptRoot '../..')
$plugin = Join-Path $repository 'plugins/nightshift'
$helper = Join-Path $plugin 'runtime/windows/migrate-state.ps1'
$doctor = Join-Path $plugin 'runtime/windows/doctor.ps1'
$preflight = Join-Path $plugin 'runtime/windows/start-preflight.ps1'
$scaffold = Join-Path $plugin 'runtime/windows/scaffold.ps1'
$pathHelper = Join-Path $plugin 'runtime/windows/path.ps1'
$hardhat = Join-Path $plugin 'hooks/windows/hardhat.ps1'
$gate = Join-Path $plugin 'hooks/windows/clock-out-gate.ps1'
$rulesTemplate = Join-Path $plugin 'skills/nightshift/references/nightshift-rules-template.json'
$hostExecutable = (Get-Process -Id $PID).Path
$utf8 = New-Object Text.UTF8Encoding($false)
Import-Module (Join-Path $plugin 'lib/Nightshift.psm1') -Force -DisableNameChecking
$failures = New-Object 'System.Collections.Generic.List[string]'

function Expect-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        $failures.Add($Message)
        Write-Host "FAIL: $Message"
    }
}

function Invoke-Script {
    param(
        [Parameter(Mandatory = $true)][string]$Script,
        [string[]]$Arguments = @(),
        [AllowEmptyString()][string]$InputText = '',
        [hashtable]$Environment = @{}
    )
    $saved = @{}
    foreach ($key in @('CLAUDE_PROJECT_DIR', 'CODEX_PROJECT_DIR', 'CURSOR_PROJECT_DIR') + @($Environment.Keys)) {
        $saved[$key] = [Environment]::GetEnvironmentVariable($key, 'Process')
        [Environment]::SetEnvironmentVariable($key, $null, 'Process')
    }
    foreach ($key in $Environment.Keys) {
        [Environment]::SetEnvironmentVariable($key, [string]$Environment[$key], 'Process')
    }
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $argList = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $Script) + @($Arguments)
        $output = if ([string]::IsNullOrEmpty($InputText)) { & $hostExecutable @argList 2>&1 } else { $InputText | & $hostExecutable @argList 2>&1 }
        $stdout = New-Object Collections.Generic.List[string]
        $stderr = New-Object Collections.Generic.List[string]
        foreach ($item in @($output)) {
            if ($item -is [Management.Automation.ErrorRecord]) { $stderr.Add([string]$item) } else { $stdout.Add([string]$item) }
        }
        $code = $LASTEXITCODE
        if ($null -eq $code) { $code = 1 }
        return [pscustomobject]@{ ExitCode = [int]$code; Stdout = ($stdout -join "`n"); Stderr = ($stderr -join "`n") }
    }
    finally {
        $ErrorActionPreference = $previous
        foreach ($key in $saved.Keys) { [Environment]::SetEnvironmentVariable($key, $saved[$key], 'Process') }
    }
}

function Invoke-Migrate {
    param([Parameter(Mandatory = $true)][string]$Workspace, [switch]$Apply)
    $arguments = @('-Project', $Workspace)
    if ($Apply) { $arguments += '-Apply' }
    return Invoke-Script $helper $arguments
}

function Write-Text {
    param([Parameter(Mandatory = $true)][string]$Path, [AllowEmptyString()][string]$Text)
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { $null = New-Item -ItemType Directory -Path $parent -Force }
    [IO.File]::WriteAllText($Path, $Text, $utf8)
}

function Read-Text {
    param([Parameter(Mandatory = $true)][string]$Path)
    return [IO.File]::ReadAllText($Path, $utf8)
}

# Every file under a directory with its hash, the receipts repository left out.
function Get-Fingerprint {
    param([Parameter(Mandatory = $true)][string]$Directory)
    $rows = New-Object Collections.Generic.List[string]
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        foreach ($file in @(Get-ChildItem -LiteralPath $Directory -Recurse -Force -File)) {
            $rel = $file.FullName.Substring($Directory.Length).Replace('\', '/')
            if ($rel -match '(^|/)\.git(/|$)') { continue }
            $rows.Add($rel + "`t" + [BitConverter]::ToString($sha.ComputeHash([IO.File]::ReadAllBytes($file.FullName))))
        }
    }
    finally {
        $sha.Dispose()
    }
    $rows.Sort([StringComparer]::Ordinal)
    return ($rows -join "`n")
}

# The relative links, outside code, of every live Markdown file that do not resolve.
function Get-UnresolvedLinks {
    param([Parameter(Mandatory = $true)][string]$NightshiftDir)
    $bad = New-Object Collections.Generic.List[string]
    foreach ($file in @(Get-ChildItem -LiteralPath $NightshiftDir -Recurse -Force -File -Filter '*.md')) {
        if ($file.FullName -match '[\\/]\.git[\\/]' -or $file.Name.EndsWith('.original.md')) { continue }
        $fence = $false
        foreach ($line in [IO.File]::ReadAllLines($file.FullName)) {
            if ($line -match '^\s*(```|~~~)') { $fence = -not $fence; continue }
            if ($fence) { continue }
            $text = [regex]::Replace($line, '`[^`]*`', '')
            $targets = New-Object Collections.Generic.List[string]
            foreach ($m in [regex]::Matches($text, '\]\(([^)]*)\)')) { $targets.Add($m.Groups[1].Value) }
            $definition = [regex]::Match($text, '^\[[^\]]*\]:\s*(\S+)')
            if ($definition.Success) { $targets.Add($definition.Groups[1].Value) }
            foreach ($target in $targets) {
                $path = $target
                $hash = $path.IndexOf('#')
                if ($hash -ge 0) { $path = $path.Substring(0, $hash) }
                if ($path.Length -eq 0 -or $path.Contains(':') -or $path.StartsWith('/')) { continue }
                if (-not (Test-Path -LiteralPath (Join-Path $file.DirectoryName $path))) {
                    $bad.Add($file.FullName.Substring($NightshiftDir.Length) + ' -> ' + $target)
                }
            }
        }
    }
    return , $bad.ToArray()
}

# A version-1 workspace with one of everything the move has to handle, as the POSIX suite builds it.
function New-V1Site {
    param([Parameter(Mandatory = $true)][string]$Path)
    $ns = Join-Path $Path '.nightshift'
    foreach ($dir in @('archive/2026-09-24', 'receipts', 'usage', 'usage-abc123', 'evidence')) {
        $null = New-Item -ItemType Directory -Path (Join-Path $ns $dir) -Force
    }
    Write-Text (Join-Path $ns 'state-version') "1`n"
    Write-Text (Join-Path $ns 'rules.json') "{`n  `"report`": {`n    `"enabled`": true,`n    `"legacyItemReceipts`": true`n  },`n  `"watchMinutes`": 10`n}`n"
    Write-Text (Join-Path $ns 'punch-list.md') "# Punch List`n`n## Items`n`n- [x] **1. done.** Decided in [the lot](parking-lot.md#top).`n"
    Write-Text (Join-Path $ns 'parking-lot.md') "# Parking Lot`n`n- a decision - answered: yes`n`nFiled: [2026-09-24](archive/2026-09-24/parking-lot.md)`n"
    Write-Text (Join-Path $ns 'snag-log.md') "# Snag Log`n`n- a snag - fixed`n`nFiled: [2026-09-24](archive/2026-09-24/snag-log.md)`n"
    Write-Text (Join-Path $ns 'drafting-table.md') ("# Drafting Table`n`nSee [the parked one](parking-lot.md) and [last night](archive/2026-09-24/punch-list.md).`n`n" +
        "[log]: shift-log.md `"The log`"`n`n``````n[not a link](parking-lot.md)`n``````n`nAnd ``[code](snag-log.md)`` stays.`n")
    Write-Text (Join-Path $ns 'work-orders.md') "# Work Orders`n"
    Write-Text (Join-Path $ns 'opportunity-map.md') "# Opportunity Map`n"
    Write-Text (Join-Path $ns 'product-research.md') "# Product Research`n"
    Write-Text (Join-Path $ns 'shift-log.md') "# Shift Log`n- line`n"
    Write-Text (Join-Path $ns 'scheduled.log') "scheduled run`n"
    Write-Text (Join-Path $ns 'capabilities.json') "{}`n"
    Write-Text (Join-Path $ns 'work-mode') "repository`n"
    Write-Text (Join-Path $ns 'work-target') "fixed`n"
    Write-Text (Join-Path $ns 'usage/segments.tsv') "a`tb`n"
    Write-Text (Join-Path $ns 'usage-abc123/segments.tsv') "a`tb`n"
    Write-Text (Join-Path $ns 'evidence/findings.jsonl') ''
    Write-Text (Join-Path $ns 'shift-report.md') "# Previous report`n"
    Write-Text (Join-Path $ns 'receipts/a1b2-done.md') "# 1. done.`n`nSee [snags](../snag-log.md) and [the report](../shift-report.md).`n"
    Write-Text (Join-Path $ns 'archive/2026-09-24/parking-lot.md') "# Parking Lot`n`n- a decision - answered: yes`n"
    Write-Text (Join-Path $ns 'archive/2026-09-24/snag-log.md') "# Snag Log`n`n- a snag - fixed`n"
    Write-Text (Join-Path $ns 'archive/2026-09-24/punch-list.md') "# Punch List`n"
    Write-Text (Join-Path $ns 'archive/2026-09-24/drafting-table.md') "# Drafting Table`n`nStill open: [the parked one](../../parking-lot.md).`n"
    Write-Text (Join-Path $ns 'receipt-item.md') "stray`n"
    Write-Text (Join-Path $ns 'owner-notes.txt') "mine`n"
    Write-Text (Join-Path $ns '.ended') "shiftId=abc`n"
    return $ns
}

$root = Join-Path ([IO.Path]::GetTempPath()) ("ns-migrate-state-logic-" + [guid]::NewGuid().ToString('N'))
try {
    # --- the preview names everything and changes nothing
    $site = Join-Path $root 'preview'
    $ns = New-V1Site $site
    $before = Get-Fingerprint $site
    $preview = Invoke-Migrate $site
    Expect-True ($preview.ExitCode -eq 0) "the preview exits 0 (got $($preview.ExitCode) $($preview.Stderr))"
    foreach ($line in @(
            'move      parking-lot.md -> inbox/parking-lot.md',
            'move      drafting-table.md -> staging/drafting-table.md',
            'move      opportunity-map.md -> product/opportunity-map.md',
            'move      shift-report.md -> receipts/previous-report.md',
            'move      shift-log.md -> run/shift-log.md',
            'move      usage-abc123 -> run/usage-abc123',
            'move      .ended -> run/.ended',
            'rename    rules.json: report -> receipts',
            'retire    rules.json: receipts.legacyItemReceipts (no version reads it)',
            'link      punch-list.md: parking-lot.md#top -> inbox/parking-lot.md#top',
            'link      staging/drafting-table.md: shift-log.md -> ../run/shift-log.md',
            'link      receipts/a1b2-done.md: ../shift-report.md -> previous-report.md',
            'original  archive/2026-09-24/drafting-table.original.md keeps the archived file as it was',
            'unknown   owner-notes.txt (no Nightshift file has this name; left in place)',
            'stray     receipt-item.md',
            'marker    state-version 1 -> 2',
            'Preview only - nothing was changed. Run it again with -Apply')) {
        Expect-True ($preview.Stdout.Contains($line)) "the preview lists: $line"
    }
    Expect-True (-not ($preview.Stdout -match 'not a link|code\]')) 'a fence and a code span are not links'
    Expect-True ((Get-Fingerprint $site) -ceq $before) 'the preview changes no byte'

    # --- -Apply performs exactly what the preview listed
    $records = (Get-NSMigrationPlan $site).Records
    $archived = Read-Text (Join-Path $ns 'archive/2026-09-24/drafting-table.md')
    $applied = Invoke-Migrate $site -Apply
    Expect-True ($applied.ExitCode -eq 0) "-Apply exits 0 (got $($applied.ExitCode) $($applied.Stdout) $($applied.Stderr))"
    Expect-True ($applied.Stdout.Contains('Applied. Nothing was deleted or overwritten.')) 'the apply says nothing was deleted'
    foreach ($record in $records) {
        $f = $record.Split("`t")
        if ($f[0] -ceq 'move') {
            Expect-True (-not (Test-NSPathEntry (Join-Path $ns $f[1]))) "moved away from $($f[1])"
            Expect-True (Test-NSPathEntry (Join-Path $ns $f[2])) "moved onto $($f[2])"
        }
        elseif ($f[0] -ceq 'link') {
            Expect-True ((Read-Text (Join-Path $ns $f[1])).Contains($f[3])) "repointed $($f[1]) to $($f[3])"
        }
    }
    Expect-True ((Read-Text (Join-Path $ns 'state-version')) -ceq "2`n") 'the marker is written last, as 2'
    $rules = Read-Text (Join-Path $ns 'rules.json')
    Expect-True ($rules.Contains('"receipts"') -and -not $rules.Contains('"report"') -and -not $rules.Contains('legacyItemReceipts')) `
        'the settings block has its current name and no retired setting'
    Expect-True ((Read-Text (Join-Path $ns 'archive/2026-09-24/drafting-table.original.md')) -ceq $archived) 'the archived original is kept as it was'
    Expect-True ((Read-Text (Join-Path $ns 'staging/drafting-table.md')).Contains('[not a link](parking-lot.md)')) 'fenced text is left as written'
    Expect-True ((Test-Path -LiteralPath (Join-Path $ns 'owner-notes.txt')) -and (Test-Path -LiteralPath (Join-Path $ns 'receipt-item.md'))) `
        'what no layout names stays where it was'
    $unresolved = Get-UnresolvedLinks $ns
    Expect-True ($unresolved.Count -eq 0) "every link still resolves ($($unresolved -join '; '))"

    # --- a second run finds nothing to do
    $settled = Get-Fingerprint $site
    $again = Invoke-Migrate $site -Apply
    Expect-True ($again.ExitCode -eq 0) "a second run exits 0 (got $($again.ExitCode))"
    $rerun = Invoke-Migrate $site
    Expect-True ($rerun.Stdout.Contains('Every file is where the current layout keeps it; nothing to do.')) 'a second run has nothing to do'
    Expect-True ((Get-Fingerprint $site) -ceq $settled) 'a second run changes nothing'

    # --- a rerun after an interrupted move finishes it
    $cut = Join-Path $root 'interrupted'
    $ns = New-V1Site $cut
    $null = New-Item -ItemType Directory -Path (Join-Path $ns 'inbox'), (Join-Path $ns 'run') -Force
    Move-Item -LiteralPath (Join-Path $ns 'parking-lot.md') -Destination (Join-Path $ns 'inbox/parking-lot.md')
    Move-Item -LiteralPath (Join-Path $ns 'shift-log.md') -Destination (Join-Path $ns 'run/shift-log.md')
    $resumed = Invoke-Migrate $cut
    Expect-True ($resumed.Stdout.Contains('link      punch-list.md: parking-lot.md#top -> inbox/parking-lot.md#top')) `
        'the rerun repoints a link to a file the first run moved'
    Expect-True (-not $resumed.Stdout.Contains('move      parking-lot.md')) 'the rerun does not move it twice'
    $finished = Invoke-Migrate $cut -Apply
    Expect-True ($finished.ExitCode -eq 0) "the rerun finishes (got $($finished.ExitCode) $($finished.Stderr))"
    Expect-True ((Read-Text (Join-Path $ns 'state-version')) -ceq "2`n") 'the finished rerun writes the marker'
    $unresolved = Get-UnresolvedLinks $ns
    Expect-True ($unresolved.Count -eq 0) "every link resolves after the rerun ($($unresolved -join '; '))"

    # --- an armed shift, a live watchman and a held lock each refuse by name
    $armed = Join-Path $root 'armed'
    $ns = New-V1Site $armed
    Write-Text (Join-Path $ns '.shift-armed') ''
    $before = Get-Fingerprint $armed
    $refused = Invoke-Migrate $armed -Apply
    Expect-True ($refused.ExitCode -eq 1) "an armed shift exits 1 (got $($refused.ExitCode))"
    Expect-True ($refused.Stdout.Contains('refuse    the shift is armed (.shift-armed) - clock out, or run Reset, first')) 'the armed marker is named'
    Expect-True ((Get-Fingerprint $armed) -ceq $before) 'an armed refusal changes nothing'
    Remove-Item -LiteralPath (Join-Path $ns '.shift-armed') -Force
    Write-Text (Join-Path $ns '.watchman') "$PID`n"
    $watched = Invoke-Migrate $armed -Apply
    Expect-True ($watched.ExitCode -eq 1) "a live watchman exits 1 (got $($watched.ExitCode))"
    Expect-True ($watched.Stdout.Contains("refuse    a watchman is running (pid $PID, .watchman)")) 'the live watchman is named'
    Remove-Item -LiteralPath (Join-Path $ns '.watchman') -Force
    $null = New-Item -ItemType Directory -Path (Join-Path $ns '.lock.d') -Force
    $locked = Invoke-Migrate $armed -Apply
    Expect-True ($locked.ExitCode -eq 1) "a held lock exits 1 (got $($locked.ExitCode))"
    Expect-True ($locked.Stdout.Contains('refuse    a lock is held (.lock.d)')) 'the held lock is named'
    Expect-True ((Read-Text (Join-Path $ns 'state-version')) -ceq "1`n") 'no refusal writes the marker'

    # --- a file at both paths: refused when it differs, left when it is the same
    $both = Join-Path $root 'both'
    $ns = New-V1Site $both
    Write-Text (Join-Path $ns 'inbox/parking-lot.md') "a different parking lot`n"
    $before = Get-Fingerprint $both
    $conflict = Invoke-Migrate $both -Apply
    Expect-True ($conflict.ExitCode -eq 5) "a conflict exits 5 (got $($conflict.ExitCode))"
    Expect-True ($conflict.Stdout.Contains('conflict  parking-lot.md and inbox/parking-lot.md are both there and differ - keep one by hand')) `
        'the conflict names both paths'
    Expect-True ((Get-Fingerprint $both) -ceq $before) 'a conflict changes nothing'
    Copy-Item -LiteralPath (Join-Path $ns 'parking-lot.md') -Destination (Join-Path $ns 'inbox/parking-lot.md') -Force
    $left = Read-Text (Join-Path $ns 'parking-lot.md')
    $same = Invoke-Migrate $both -Apply
    Expect-True ($same.ExitCode -eq 0) "the same content applies (got $($same.ExitCode) $($same.Stdout))"
    Expect-True ($same.Stdout.Contains('leave     parking-lot.md (the same content is already at inbox/parking-lot.md)')) 'the same content is left'
    Expect-True ((Read-Text (Join-Path $ns 'parking-lot.md')) -ceq $left) 'the copy left behind is untouched'
    $settled = Get-Fingerprint $both
    $sameAgain = Invoke-Migrate $both -Apply
    Expect-True ($sameAgain.ExitCode -eq 0 -and $sameAgain.Stdout.Contains('leave     parking-lot.md')) 'a rerun leaves the two copies as they are'
    Expect-True ((Get-Fingerprint $both) -ceq $settled) 'a rerun over two copies changes nothing'

    # --- the older report page and settings: onto an existing page, and a clash of values
    $report = Join-Path $root 'report'
    $ns = New-V1Site $report
    Write-Text (Join-Path $ns 'receipts/previous-report.md') "# A different previous report`n"
    $clash = Invoke-Migrate $report -Apply
    Expect-True ($clash.ExitCode -eq 5) "a different previous report exits 5 (got $($clash.ExitCode))"
    Expect-True ($clash.Stdout.Contains('conflict  shift-report.md and receipts/previous-report.md are both there and differ')) `
        'the previous report conflict is named'
    Copy-Item -LiteralPath (Join-Path $ns 'shift-report.md') -Destination (Join-Path $ns 'receipts/previous-report.md') -Force
    Write-Text (Join-Path $ns 'shift-policy.json') "{`n  `"report`": {`n    `"enabled`": false`n  },`n  `"receipts`": {`n    `"enabled`": false`n  }`n}`n"
    $reportApplied = Invoke-Migrate $report -Apply
    Expect-True ($reportApplied.ExitCode -eq 0) "the report rows apply (got $($reportApplied.ExitCode) $($reportApplied.Stdout))"
    Expect-True ($reportApplied.Stdout.Contains('drop      run/shift-policy.json: report (the same value is already under receipts)')) `
        'an old block with the same value is dropped'
    Expect-True (-not (Read-Text (Join-Path $ns 'run/shift-policy.json')).Contains('"report"')) 'the policy keeps only its current block'
    $values = Join-Path $root 'values'
    $ns = New-V1Site $values
    Write-Text (Join-Path $ns 'rules.json') "{`n  `"report`": {`n    `"enabled`": true`n  },`n  `"receipts`": {`n    `"enabled`": false`n  }`n}`n"
    $differ = Invoke-Migrate $values -Apply
    Expect-True ($differ.ExitCode -eq 5) "two blocks with different values exit 5 (got $($differ.ExitCode))"
    Expect-True ($differ.Stdout.Contains('conflict  rules.json holds both report and receipts with different values')) 'the settings clash is named'

    # --- no marker at all moves too; a new site is born in the current layout
    $legacy = Join-Path $root 'legacy'
    $ns = New-V1Site $legacy
    Remove-Item -LiteralPath (Join-Path $ns 'state-version') -Force
    $zero = Invoke-Migrate $legacy -Apply
    Expect-True ($zero.ExitCode -eq 0 -and $zero.Stdout.Contains('marker    state-version 0 -> 2')) 'a legacy site moves and gets its marker'
    $fresh = Join-Path $root 'fresh'
    $null = New-Item -ItemType Directory -Path $fresh -Force
    $scaffolded = Invoke-Script $scaffold @('-Project', $fresh)
    Expect-True ($scaffolded.ExitCode -eq 0) "the scaffold writes a new site (got $($scaffolded.ExitCode) $($scaffolded.Stderr))"
    Expect-True ((Read-Text (Join-Path $fresh '.nightshift/state-version')) -ceq "2`n") 'a new site is born at version 2'
    Expect-True (Test-Path -LiteralPath (Join-Path $fresh '.nightshift/inbox/parking-lot.md')) 'a new site keeps the parking lot in inbox/'
    Expect-True (-not (Test-Path -LiteralPath (Join-Path $fresh '.nightshift/staging/work-orders.md'))) 'the work orders wait until Hunt needs them'
    Expect-True ((Invoke-Migrate $fresh).Stdout.Contains('nothing to do')) 'a new site has nothing to move'

    # --- the receipts repository leaves run/ out
    $repo = Join-Path $root 'repo'
    $ns = New-V1Site $repo
    Write-Text (Join-Path $ns '.gitignore') "STOP`n.stall"
    $null = & git init --quiet $ns
    $ignored = Invoke-Migrate $repo -Apply
    Expect-True ($ignored.Stdout.Contains('ignore    .gitignore: add run/')) 'the receipts repository gets run/ left out'
    Expect-True ((Read-Text (Join-Path $ns '.gitignore')) -ceq "STOP`n.stall`nrun/`n") 'run/ lands on its own line'
    Expect-True (-not (Invoke-Migrate $repo).Stdout.Contains('ignore')) 'run/ is added once'

    # --- Doctor names each move and changes nothing
    $described = Join-Path $root 'doctor'
    $ns = New-V1Site $described
    $before = Get-Fingerprint $described
    $report = Invoke-Script $doctor @('-Project', $described)
    Expect-True ($report.Stdout.Contains('state version 1 (every state file sits at the top of .nightshift/)')) 'Doctor names the old layout'
    Expect-True ($report.Stdout.Contains('[confirm] move the state files into layout 2: shift-report.md -> receipts/previous-report.md, parking-lot.md -> inbox/parking-lot.md')) `
        "Doctor names each file's old and new path ($($report.Stdout))"
    Expect-True ($report.Stdout.Contains('nothing is deleted or overwritten. Preview it with')) 'Doctor says nothing is deleted'
    Expect-True ((Get-Fingerprint $described) -ceq $before) 'Doctor changes nothing'
    Write-Text (Join-Path $ns '.shift-armed') ''
    $waiting = Invoke-Script $doctor @('-Project', $described)
    Expect-True ($waiting.Stdout.Contains('the move into layout 2 waits: the shift is armed (.shift-armed)')) 'Doctor says the move waits while armed'
    Expect-True ($waiting.Stdout.Contains('[blocked] move the state files into layout 2:')) 'the move is blocked while armed'

    # --- Start warns once on version 1 and arms as usual
    $start = Join-Path $root 'start'
    $ns = New-V1Site $start
    Remove-Item -LiteralPath (Join-Path $ns '.ended') -Force
    $code = Join-Path $start 'code'
    $null = New-Item -ItemType Directory -Path $code -Force
    $null = & git -C $code init --quiet
    $null = & git -C $code -c user.name=t -c user.email=t@example.com commit --quiet --allow-empty -m init
    Write-Text (Join-Path $ns 'work-target') ((Resolve-NSCanonicalPath $code) + "`n")
    Write-Text (Join-Path $ns 'punch-list.md') "## Items`n- [ ] **1. work.**`n"
    Copy-Item -LiteralPath $rulesTemplate -Destination (Join-Path $ns 'rules.json') -Force
    $verdicts = Invoke-Script $preflight @('-Project', $start, '-HostName', 'claude')
    Expect-True ($verdicts.ExitCode -eq 0) "Start arms a version-1 site (got $($verdicts.ExitCode) $($verdicts.Stdout))"
    $warnings = @($verdicts.Stdout.Split("`n") | Where-Object { $_ -like 'warn state-version*' })
    Expect-True ($warnings.Count -eq 1) "Start warns once ($($warnings.Count))"
    Expect-True ($verdicts.Stdout.Contains('warn state-version 1 keeps every state file at the top of .nightshift/ - Doctor offers the move to version 2')) `
        'the warning points at the move'
    Expect-True (Test-Path -LiteralPath (Join-Path $ns 'parking-lot.md')) 'Start moves nothing'

    # --- the hooks guard an armed version-1 site where it is, and a version-2 site in run/
    $old = Join-Path $root 'guard-v1'
    $ns = New-V1Site $old
    Remove-Item -LiteralPath (Join-Path $ns '.ended') -Force
    Write-Text (Join-Path $ns 'punch-list.md') "## Items`n- [ ] **1. work.**`n"
    Write-Text (Join-Path $ns '.shift-armed') ''
    $probe = '{"session_id":"sess-1","transcript_path":"","cwd":"' + $old.Replace('\', '\\') + '","tool_name":"Bash","tool_input":{"command":": nightshift-binding-probe"}}'
    $bound = Invoke-Script $hardhat @('-HostName', 'codex') $probe @{ CODEX_PROJECT_DIR = $old }
    Expect-True ([string]::IsNullOrWhiteSpace($bound.Stdout)) "Start binds an armed version-1 site ($($bound.Stdout) $($bound.Stderr))"
    $payload = '{"session_id":"sess-1","transcript_path":"","cwd":"' + $old.Replace('\', '\\') + '","tool_name":"Bash","tool_input":{"command":"Remove-Item -Force .nightshift\\.shift-armed"}}'
    $deny = Invoke-Script $hardhat @('-HostName', 'codex') $payload @{ CODEX_PROJECT_DIR = $old }
    Expect-True ($deny.Stdout -match 'control files') "an armed version-1 site keeps its armed marker guarded ($($deny.Stdout) $($deny.Stderr))"
    $stop = '{"session_id":"sess-1","transcript_path":"","cwd":"' + $old.Replace('\', '\\') + '","stop_hook_active":true}'
    $held = Invoke-Script $gate @('-HostName', 'codex') $stop @{ CODEX_PROJECT_DIR = $old }
    Expect-True ($held.Stdout -match '"decision":"block"') "an armed version-1 site holds the session ($($held.Stdout) $($held.Stderr))"
    Expect-True (-not (Test-Path -LiteralPath (Join-Path $ns 'run'))) 'a version-1 site gets no run/ folder'

    $new = Join-Path $root 'guard-v2'
    $ns = Join-Path $new '.nightshift'
    Write-Text (Join-Path $ns 'state-version') "2`n"
    Copy-Item -LiteralPath $rulesTemplate -Destination (Join-Path $ns 'rules.json') -Force
    Write-Text (Join-Path $ns 'punch-list.md') "## Items`n- [ ] **1. work.**`n"
    Write-Text (Join-Path $ns 'run/.shift-armed') ''
    $probe = '{"session_id":"sess-2","transcript_path":"","cwd":"' + $new.Replace('\', '\\') + '","tool_name":"Bash","tool_input":{"command":": nightshift-binding-probe"}}'
    $bound = Invoke-Script $hardhat @('-HostName', 'codex') $probe @{ CODEX_PROJECT_DIR = $new }
    Expect-True ([string]::IsNullOrWhiteSpace($bound.Stdout)) "Start binds an armed version-2 site ($($bound.Stdout) $($bound.Stderr))"
    $payload = '{"session_id":"sess-2","transcript_path":"","cwd":"' + $new.Replace('\', '\\') + '","tool_name":"Bash","tool_input":{"command":"Remove-Item -Force .nightshift\\run\\.shift-armed"}}'
    $deny = Invoke-Script $hardhat @('-HostName', 'codex') $payload @{ CODEX_PROJECT_DIR = $new }
    Expect-True ($deny.Stdout -match 'control files') "a version-2 site keeps run/.shift-armed guarded ($($deny.Stdout) $($deny.Stderr))"
    $stop = '{"session_id":"sess-2","transcript_path":"","cwd":"' + $new.Replace('\', '\\') + '","stop_hook_active":true}'
    $held = Invoke-Script $gate @('-HostName', 'codex') $stop @{ CODEX_PROJECT_DIR = $new }
    Expect-True ($held.Stdout -match '"decision":"block"') "a version-2 site holds the session ($($held.Stdout) $($held.Stderr))"
    Expect-True (Test-Path -LiteralPath (Join-Path $ns 'run/.shift-session')) 'the session is bound in run/'
    Expect-True (-not (Test-Path -LiteralPath (Join-Path $ns '.shift-session'))) 'nothing binds at the top of a version-2 site'
    Expect-True (Test-Path -LiteralPath (Join-Path $ns 'run/.shift-armed')) 'the armed marker survives'

    # --- path answers from the site's own layout
    $answer = Invoke-Script $pathHelper @('-Project', $old, 'parking-lot', 'armed')
    $expected = (Get-NSLayoutPath (Join-Path (Resolve-NSCanonicalPath $old) '.nightshift') 'parking-lot') + "`n" +
        (Get-NSLayoutPath (Join-Path (Resolve-NSCanonicalPath $old) '.nightshift') 'armed')
    Expect-True ($answer.Stdout -ceq $expected) "path answers in a version-1 site's layout ($($answer.Stdout))"
    Expect-True ($answer.Stdout.EndsWith([IO.Path]::DirectorySeparatorChar + '.shift-armed')) 'a version-1 site keeps the armed marker at the top'
    $none = Invoke-Script $pathHelper @('-Project', $old, 'inbox')
    Expect-True ($none.ExitCode -eq 1 -and $none.Stderr.Contains('path: layout 1 has no inbox')) 'path refuses a key the layout does not have'

    # --- a future marker is never rewritten
    $future = Join-Path $root 'future'
    Write-Text (Join-Path $future '.nightshift/state-version') "9`n"
    $blocked = Invoke-Migrate $future -Apply
    Expect-True ($blocked.ExitCode -eq 2) "a future marker exits 2 (got $($blocked.ExitCode))"
    Expect-True ((Read-Text (Join-Path $future '.nightshift/state-version')) -ceq "9`n") 'a future marker is left untouched'
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures.Count -gt 0) {
    Write-Host "migrate-state logic failed ($($failures.Count)):"
    foreach ($failure in $failures) {
        Write-Host " - $failure"
    }
    exit 1
}
Write-Host 'migrate-state logic passed'
exit 0
