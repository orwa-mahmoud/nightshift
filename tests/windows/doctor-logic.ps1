# Portable PowerShell coverage for Windows Doctor leftover-contract and staged-work counts.
# Run on macOS or Windows: pwsh -File tests/windows/doctor-logic.ps1
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if (Test-Path Variable:PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $false
}

$repository = Resolve-Path (Join-Path $PSScriptRoot '../..')
$helper = Join-Path $repository 'plugins/nightshift/runtime/windows/doctor.ps1'
$rulesTemplate = Join-Path $repository 'plugins/nightshift/skills/nightshift/references/nightshift-rules-template.json'
$draftTemplate = Join-Path $repository 'plugins/nightshift/skills/nightshift/references/templates/drafting-table.md'
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

function Get-TreeStamp {
    param([Parameter(Mandatory = $true)][string]$Path)
    $lines = New-Object 'System.Collections.Generic.List[string]'
    Get-ChildItem -LiteralPath $Path -Recurse -File -Force | Sort-Object FullName | ForEach-Object {
        $rel = $_.FullName.Substring($Path.Length).TrimStart('\', '/')
        $hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
        $null = $lines.Add("$hash $rel")
    }
    return ($lines -join "`n")
}

function Invoke-Doctor {
    param([Parameter(Mandatory = $true)][string]$Project)
    $argList = @(
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', $helper, '-Project', $Project
    )
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
    return [pscustomobject]@{
        ExitCode = [int]$LASTEXITCODE
        Stdout = ($stdout -join "`n")
        Stderr = ($stderr -join "`n")
    }
}

$root = Join-Path ([IO.Path]::GetTempPath()) ("ns-doctor-logic-" + [guid]::NewGuid().ToString('N'))
$notes = $null
$clockout = $null
$receiptsSite = $null
$linkNotes = $null
$targetLink = $null
$otherTarget = $null
$null = New-Item -ItemType Directory -Path (Join-Path $root '.nightshift') -Force
try {
    $ns = Join-Path $root '.nightshift'
    Copy-Item -LiteralPath $rulesTemplate -Destination (Join-Path $ns 'rules.json')
    & git -C $root init --quiet
    if ($LASTEXITCODE -ne 0) { throw "git init failed in $root" }
    & git -C $root -c user.name=t -c user.email=t@example.com commit --allow-empty -q -m init
    if ($LASTEXITCODE -ne 0) { throw "git commit failed in $root" }

    $punch = Join-Path $ns 'punch-list.md'
    [IO.File]::WriteAllText($punch,
        "## Shift contract`n- leftover campaign`n`n## Gates`n- none`n`n## Items`n`n")
    $before = Get-TreeStamp $root
    $leftover = Invoke-Doctor $root
    Expect-True ($leftover.ExitCode -eq 0) "leftover contract exits 0 (got $($leftover.ExitCode) $($leftover.Stderr))"
    Expect-True ($leftover.Stdout -match 'leftover Shift contract and Gates') `
        'empty punch list names leftover contract'
    Expect-True ($leftover.Stdout -notmatch 'work mode is unset; Setup would propose artifact') `
        'a git workspace does not warn that Setup would propose artifact'
    Expect-True ($leftover.Stdout -notmatch 'persist the proposed artifact mode with Setup; Doctor does not write work-mode') `
        'a git workspace does not offer to persist artifact mode'
    Expect-True ($leftover.Stdout -match 'empty punch list will inherit the current contract') `
        'unarmed empty list warns that the contract is inherited'
    Expect-True ($leftover.Stdout -match '\[confirm\].*review punch-list.md contract') `
        'leftover contract is a confirm action'
    Expect-True ((Get-TreeStamp $root) -eq $before) 'Doctor leaves leftover-contract state untouched'
    Expect-True ([IO.File]::ReadAllText($punch) -match 'leftover campaign') `
        'leftover campaign text stays in the punch list'

    Copy-Item -LiteralPath $draftTemplate -Destination (Join-Path $ns 'drafting-table.md')
    $example = Invoke-Doctor $root
    Expect-True ($example.ExitCode -eq 0) "drafting example exits 0 (got $($example.ExitCode) $($example.Stderr))"
    Expect-True ($example.Stdout -notmatch 'staged drafting-table items=') `
        'fenced item-shape example is not a staged draft'

    $draft = Join-Path $ns 'drafting-table.md'
    [IO.File]::WriteAllText($draft, @'
# Drafting Table

```text
- [ ] **1. example only.**
```

---

- [ ] **Real draft.**
  - Verify: true
  - Commit: `fix: x`
'@)
    $counted = Invoke-Doctor $root
    Expect-True ($counted.ExitCode -eq 0) "real draft exits 0 (got $($counted.ExitCode) $($counted.Stderr))"
    Expect-True ($counted.Stdout -match 'staged drafting-table items=1') `
        'drafts after the rule are counted'
    Expect-True ($counted.Stdout -match '\[confirm\].*drafting-table items') `
        'staged drafts are a confirm action'

    [IO.File]::WriteAllText((Join-Path $ns 'work-orders.md'),
        "# Work Orders`n`n## Work order  -  test`nHours: 2`n`n- [ ] **Coverage hunt.**`n")
    $orders = Invoke-Doctor $root
    Expect-True ($orders.ExitCode -eq 0) "work orders exit 0 (got $($orders.ExitCode) $($orders.Stderr))"
    Expect-True ($orders.Stdout -match 'pending Hunt work orders=1') `
        'open work-order boxes are counted'
    Expect-True ($orders.Stdout -match '\[confirm\].*promote a parked Hunt order') `
        'parked Hunt orders are a confirm action'

    $null = New-Item -ItemType File -Force (Join-Path $ns 'STOP')
    $stop = Invoke-Doctor $root
    Expect-True ($stop.ExitCode -eq 0) "unarmed STOP exits 0 (got $($stop.ExitCode) $($stop.Stderr))"
    Expect-True ($stop.Stdout -match 'STOP leftover') 'unarmed STOP is reported as leftover'
    Expect-True ($stop.Stdout -match '\[confirm\].*stale STOP') 'unarmed STOP is a confirm action'

    $rulesPath = Join-Path $ns 'rules.json'
    $rules = Get-Content -LiteralPath $rulesPath -Raw | ConvertFrom-Json
    $rules.revivalPrompt = ''
    $rules | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $rulesPath -Encoding utf8
    $emptyPrompt = Invoke-Doctor $root
    Expect-True ($emptyPrompt.ExitCode -eq 0) "empty revivalPrompt exits 0 (got $($emptyPrompt.ExitCode) $($emptyPrompt.Stderr))"
    Expect-True ($emptyPrompt.Stdout -match 'revivalPrompt is empty') `
        'empty revivalPrompt is a warning'
    Expect-True ($emptyPrompt.Stdout -match 'watchman will refuse to arm') `
        'empty revivalPrompt names the watchman refuse'

    $receiptsSite = $root + '-receipts'
    $receiptsNs = Join-Path $receiptsSite '.nightshift'
    $null = New-Item -ItemType Directory -Path $receiptsNs -Force
    Copy-Item -LiteralPath $rulesTemplate -Destination (Join-Path $receiptsNs 'rules.json')
    [IO.File]::WriteAllText((Join-Path $receiptsNs 'punch-list.md'),
        "## Items`n- [x] **2. done.**`n")
    $missingReceipt = Invoke-Doctor $receiptsSite
    Expect-True ($missingReceipt.ExitCode -eq 0) `
        "missing receipt doctor exits 0 (got $($missingReceipt.ExitCode) $($missingReceipt.Stderr))"
    Expect-True ($missingReceipt.Stdout -match 'completion record per-item receipt') `
        'Doctor names the per-item completion record'
    Expect-True ($missingReceipt.Stdout -match 'ticked items have no receipt text') `
        'Doctor warns when ticked items have no receipt text'
    Expect-True ($missingReceipt.Stdout -match 'write the missing receipts under .nightshift/receipts/') `
        'Doctor offers to write missing receipts'
    $null = New-Item -ItemType Directory -Path (Join-Path $receiptsNs 'receipts') -Force
    $doneLabel = @(Get-NSPulseTickedLabels $receiptsSite)[0]
    [IO.File]::WriteAllText((Join-Path (Join-Path $receiptsNs 'receipts') ((Get-NSReceiptBasename $doneLabel) + '.md')),
        "# 2. done.`n`nThe work is done.`n")
    $haveReceipt = Invoke-Doctor $receiptsSite
    Expect-True ($haveReceipt.Stdout -notmatch 'ticked items have no receipt text') `
        'Doctor stops warning after the item receipt has model text'
    $offRules = Get-Content -LiteralPath (Join-Path $receiptsNs 'rules.json') -Raw | ConvertFrom-Json
    $offRules.receipts.enabled = $false
    $offRules | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $receiptsNs 'rules.json') -Encoding utf8
    $offReceipts = Invoke-Doctor $receiptsSite
    Expect-True ($offReceipts.Stdout -match 'completion record none; the owner disabled receipts') `
        'disabled receipts stay a fact'
    Expect-True ($offReceipts.Stdout -notmatch 'ticked items have no receipt text') `
        'disabled receipts never warn about missing text'

    $clockout = $root + '-clockout'
    $clockNs = Join-Path $clockout '.nightshift'
    $null = New-Item -ItemType Directory -Path $clockNs -Force
    Copy-Item -LiteralPath $rulesTemplate -Destination (Join-Path $clockNs 'rules.json')
    [IO.File]::WriteAllText((Join-Path $clockNs 'punch-list.md'),
        "## Items`n- [ ] **1.**`n")
    [IO.File]::WriteAllText((Join-Path $clockNs '.shift-armed'), '')
    [IO.File]::WriteAllText((Join-Path $clockNs '.watch-reason'), "clock-out-failed`n`n")
    [IO.File]::WriteAllText((Join-Path $clockNs '.shift-lease'), "shift-session`ncodex`n2`n`n`n`n")
    $clockDoctor = Invoke-Doctor $clockout
    Expect-True ($clockDoctor.ExitCode -eq 0) `
        "clock-out-failed doctor exits 0 (got $($clockDoctor.ExitCode) $($clockDoctor.Stderr))"
    Expect-True ($clockDoctor.Stdout -match 'terminal clock-out failed without releasing the shift') `
        'Doctor names a failed terminal clock-out'
    Expect-True ($clockDoctor.Stdout -match 'process lease restored to the interactive shift; the recorded conversation can operate') `
        'Doctor says the recorded conversation can operate after restore'

    $deadHolder = $root + '-dead-holder'
    $deadHolderNs = Join-Path $deadHolder '.nightshift'
    $null = New-Item -ItemType Directory -Path $deadHolderNs -Force
    Copy-Item -LiteralPath $rulesTemplate -Destination (Join-Path $deadHolderNs 'rules.json')
    [IO.File]::WriteAllText((Join-Path $deadHolderNs 'punch-list.md'),
        "## Items`n- [ ] **1.**`n")
    [IO.File]::WriteAllText((Join-Path $deadHolderNs '.shift-armed'), '')
    # A real, live pid ($PID, this test process) whose birthday can never match the bogus
    # one on the lease - the same fixture technique run.ps1 uses to prove death.
    [IO.File]::WriteAllText((Join-Path $deadHolderNs '.shift-session'), "dead-recorded`n`n$PID`n`ncodex`n")
    [IO.File]::WriteAllText((Join-Path $deadHolderNs '.shift-lease'), "dead-recorded`ncodex`n2`nnonce1`n$PID`n2000-01-01`n")
    $deadHolderDoctor = Invoke-Doctor $deadHolder
    Expect-True ($deadHolderDoctor.ExitCode -eq 0) `
        "dead-holder doctor exits 0 (got $($deadHolderDoctor.ExitCode) $($deadHolderDoctor.Stderr))"
    Expect-True ($deadHolderDoctor.Stdout -match [regex]::Escape("lease held by a dead recovery attempt (generation 2, pid $PID); the recorded conversation reclaims it on its next tool call")) `
        "Doctor names a dead recovery attempt as reclaimable ($($deadHolderDoctor.Stdout))"
    Expect-True ($deadHolderDoctor.Stdout -notmatch 'recovery worker is alive') `
        'Doctor does not claim a dead recovery worker is alive'

    $notes = $root + '-notes'
    $null = New-Item -ItemType Directory -Path (Join-Path $notes '.nightshift') -Force
    Copy-Item -LiteralPath $rulesTemplate -Destination (Join-Path $notes '.nightshift/rules.json')
    $null = New-Item -ItemType Directory -Path (Join-Path $notes 'research') -Force
    [IO.File]::WriteAllText((Join-Path $notes 'research/topic.md'), "notes`n")
    $unset = Invoke-Doctor $notes
    Expect-True ($unset.ExitCode -eq 0) "unset notes doctor exits 0 (got $($unset.ExitCode) $($unset.Stderr))"
    Expect-True ($unset.Stdout -match 'work mode is unset; Setup would propose artifact') `
        'an unset notes folder warns that Setup would propose artifact'
    Expect-True ($unset.Stdout -match 'persist the proposed artifact mode with Setup; Doctor does not write work-mode') `
        'an unset notes folder offers Setup as a confirm action'

    $linkNotes = $root + '-mode-link'
    $linkNs = Join-Path $linkNotes '.nightshift'
    $null = New-Item -ItemType Directory -Path $linkNs, (Join-Path $linkNotes 'research') -Force
    Copy-Item -LiteralPath $rulesTemplate -Destination (Join-Path $linkNs 'rules.json')
    [IO.File]::WriteAllText((Join-Path $linkNotes 'research/topic.md'), "notes`n")
    $plant = Join-Path $linkNs 'mode-plant'
    [IO.File]::WriteAllText($plant, "artifact`n")
    $modeLink = Join-Path $linkNs 'work-mode'
    try {
        $null = New-Item -ItemType SymbolicLink -Path $modeLink -Target $plant -ErrorAction Stop
    }
    catch {
        if ($onWin32) {
            Write-Host 'skip symlink work-mode (cannot create)'
        }
        else {
            throw
        }
    }
    if (Test-Path -LiteralPath $modeLink) {
        $malformed = Invoke-Doctor $linkNotes
        Expect-True ($malformed.ExitCode -eq 0) `
            "symlink work-mode doctor exits 0 (got $($malformed.ExitCode) $($malformed.Stderr))"
        Expect-True ($malformed.Stdout -match 'work mode is malformed; treating the site as unusable until Setup rewrites it') `
            'a symlink work-mode is reported as malformed'
        Expect-True ($malformed.Stdout -notmatch 'work mode is unset; Setup would propose artifact') `
            'a symlink work-mode is not reported as unset'
        Expect-True ($malformed.Stdout -notmatch 'work mode artifact') `
            'a symlink work-mode does not report artifact'
    }

    $targetLink = $root + '-target-link'
    $otherTarget = $root + '-other-target'
    $null = New-Item -ItemType Directory -Path $targetLink, $otherTarget -Force
    foreach ($repo in @($targetLink, $otherTarget)) {
        & git -C $repo init --quiet
        if ($LASTEXITCODE -ne 0) { throw "git init failed in $repo" }
        & git -C $repo -c user.name=t -c user.email=t@example.com commit --allow-empty -q -m init
        if ($LASTEXITCODE -ne 0) { throw "git commit failed in $repo" }
    }
    $targetNs = Join-Path $targetLink '.nightshift'
    $null = New-Item -ItemType Directory -Path $targetNs -Force
    Copy-Item -LiteralPath $rulesTemplate -Destination (Join-Path $targetNs 'rules.json')
    $otherTop = (& git -C $otherTarget rev-parse --show-toplevel).Trim()
    $targetPlant = Join-Path $targetNs 'target-plant'
    [IO.File]::WriteAllText($targetPlant, "$otherTop`n")
    $workTargetLink = Join-Path $targetNs 'work-target'
    try {
        $null = New-Item -ItemType SymbolicLink -Path $workTargetLink -Target $targetPlant -ErrorAction Stop
    }
    catch {
        if ($onWin32) {
            Write-Host 'skip symlink work-target (cannot create)'
        }
        else {
            throw
        }
    }
    if (Test-Path -LiteralPath $workTargetLink) {
        $unreadable = Invoke-Doctor $targetLink
        Expect-True ($unreadable.ExitCode -eq 0) `
            "symlink work-target doctor exits 0 (got $($unreadable.ExitCode) $($unreadable.Stderr))"
        Expect-True ($unreadable.Stdout -match 'work target could not be resolved; treating workspace as the code root') `
            'a symlink work-target is reported as unresolved'
        Expect-True ($unreadable.Stdout -notmatch [regex]::Escape("work target $otherTop")) `
            'a symlink work-target does not report the planted path'
    }
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    if ($null -ne $notes) {
        Remove-Item -LiteralPath $notes -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($null -ne $clockout) {
        Remove-Item -LiteralPath $clockout -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($null -ne $receiptsSite) {
        Remove-Item -LiteralPath $receiptsSite -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($null -ne $linkNotes) {
        Remove-Item -LiteralPath $linkNotes -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($null -ne $targetLink) {
        Remove-Item -LiteralPath $targetLink -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($null -ne $otherTarget) {
        Remove-Item -LiteralPath $otherTarget -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($failures.Count -gt 0) {
    Write-Host "doctor-logic failed ($($failures.Count)):"
    foreach ($failure in $failures) { Write-Host " - $failure" }
    exit 1
}
Write-Host 'doctor-logic passed'
exit 0
