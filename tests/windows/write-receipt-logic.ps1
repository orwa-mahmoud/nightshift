# Portable PowerShell coverage for artifact-mode write-receipt.
# Run on macOS or Windows: pwsh -File tests/windows/write-receipt-logic.ps1
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if (Test-Path Variable:PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $false
}

$repository = Resolve-Path (Join-Path $PSScriptRoot '../..')
$helper = Join-Path $repository 'plugins/nightshift/runtime/windows/write-receipt.ps1'
$doctor = Join-Path $repository 'plugins/nightshift/runtime/windows/doctor.ps1'
$module = Join-Path $repository 'plugins/nightshift/lib/Nightshift.psm1'
$hostExecutable = (Get-Process -Id $PID).Path
$failures = New-Object 'System.Collections.Generic.List[string]'
$onWin32 = [Environment]::OSVersion.Platform -eq 'Win32NT'

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

function Expect-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        $failures.Add($Message)
        Write-Host "FAIL: $Message"
    }
}

function Invoke-WriteReceipt {
    param(
        [Parameter(Mandatory = $true)][string]$Project,
        [string[]]$Extra = @()
    )
    $argList = @(
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', $helper, '-Project', $Project
    ) + $Extra
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

function Invoke-Doctor {
    param([Parameter(Mandatory = $true)][string]$Project)
    $argList = @(
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', $doctor, '-Project', $Project
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

$root = Join-Path ([IO.Path]::GetTempPath()) ("ns-write-receipt-logic-" + [guid]::NewGuid().ToString('N'))
try {
    $artifact = Join-Path $root 'notes'
    $outDir = Join-Path $artifact 'out'
    $ns = Join-Path $artifact '.nightshift'
    $null = New-Item -ItemType Directory -Path $ns, $outDir -Force
    [IO.File]::WriteAllText((Join-Path $ns 'work-mode'), "artifact`n")
    [IO.File]::WriteAllText((Join-Path $ns 'work-target'), "$artifact`n")
    Import-Module $module -Force -DisableNameChecking
    Expect-True ($null -eq (Get-NSLatestReceipt $artifact)) 'no latest receipt before any write'
    [IO.File]::WriteAllText((Join-Path $ns 'punch-list.md'), "## Items`n- [x] **done.**`n")
    $before = Invoke-Doctor $artifact
    Expect-True ($before.ExitCode -eq 0) "Doctor before receipts exits 0 (got $($before.ExitCode) $($before.Stderr))"
    Expect-True ($before.Stdout -match 'ticked items have no receipt text') `
        'Doctor warns when ticks exist without receipts'

    $note = Join-Path $outDir 'topic.md'
    [IO.File]::WriteAllText($note, "research notes`n")

    $ok = Invoke-WriteReceipt $artifact @(
        '-Item', 'Write the brief',
        '-Verify', 'file exists',
        '-Source', 'https://example.com/doc',
        '-Output', $note
    )
    Expect-True ($ok.ExitCode -eq 0) "artifact success exits 0 (got $($ok.ExitCode) $($ok.Stderr))"
    Expect-True (Test-Path -LiteralPath $ok.Stdout.Trim() -PathType Leaf) 'prints a receipt path'
    Expect-True ($ok.Stdout -match [regex]::Escape((Join-Path $ns 'receipts'))) 'receipt lands under .nightshift/receipts'
    $body = [IO.File]::ReadAllText($ok.Stdout.Trim())
    Expect-True ($body -match 'mode: artifact') 'receipt records artifact mode'
    Expect-True ($body -match 'sha256:') 'receipt records file identity'
    $firstName = [IO.Path]::GetFileName($ok.Stdout.Trim())
    Expect-True (([IO.Path]::GetFileName((Get-NSLatestReceipt $artifact))) -eq $firstName) `
        'Get-NSLatestReceipt names the first receipt'
    Start-Sleep -Seconds 1

    $secret = Invoke-WriteReceipt $artifact @(
        '-Item', 'x',
        '-Verify', 'ok',
        '-Decision', 'password=supersecret',
        '-Output', $note
    )
    Expect-True ($secret.ExitCode -eq 0) "secret decision still writes (got $($secret.ExitCode))"
    $secretBody = [IO.File]::ReadAllText($secret.Stdout.Trim())
    Expect-True ($secretBody -notmatch 'supersecret') 'secret value is omitted'
    Expect-True ($secretBody -match 'decision: \(redacted\)') 'secret decision is redacted'
    $secondName = [IO.Path]::GetFileName($secret.Stdout.Trim())
    Expect-True (([IO.Path]::GetFileName((Get-NSLatestReceipt $artifact))) -eq $secondName) `
        'Get-NSLatestReceipt names the newest receipt'
    $report = Invoke-Doctor $artifact
    Expect-True ($report.ExitCode -eq 0) "Doctor exits 0 (got $($report.ExitCode) $($report.Stderr))"
    Expect-True ($report.Stdout -match 'artifact receipts 2') 'Doctor counts both receipts'
    Expect-True ($report.Stdout -match [regex]::Escape("latest artifact receipt $secondName")) `
        'Doctor names the newest receipt filename'
    Expect-True ($report.Stdout -notmatch [regex]::Escape("latest artifact receipt $firstName")) `
        'Doctor does not name the older receipt as latest'
    Expect-True ($report.Stdout -match 'ticked items have no receipt text') `
        'timestamp receipts do not complete a named punch-list item'

    $empty = Join-Path $outDir 'blank.md'
    [IO.File]::WriteAllText($empty, '')
    $blank = Invoke-WriteReceipt $artifact @(
        '-Item', 'x', '-Verify', 'ok', '-Output', $empty
    )
    Expect-True ($blank.ExitCode -eq 2) "empty output exits 2 (got $($blank.ExitCode))"

    $missing = Invoke-WriteReceipt $artifact @(
        '-Item', 'x', '-Verify', 'ok', '-Output', (Join-Path $outDir 'nope.md')
    )
    Expect-True ($missing.ExitCode -eq 2) "missing output exits 2 (got $($missing.ExitCode))"

    $linkOutCase = Join-Path $root 'link-output-notes'
    $linkOutNs = Join-Path $linkOutCase '.nightshift'
    $null = New-Item -ItemType Directory -Path $linkOutNs -Force
    [IO.File]::WriteAllText((Join-Path $linkOutNs 'work-mode'), "artifact`n")
    [IO.File]::WriteAllText((Join-Path $linkOutNs 'work-target'), "$linkOutCase`n")
    $realOut = Join-Path $linkOutCase 'real.md'
    $aliasOut = Join-Path $linkOutCase 'alias.md'
    [IO.File]::WriteAllText($realOut, "ok`n")
    $outLinkCreated = $true
    try {
        $null = New-Item -ItemType SymbolicLink -Path $aliasOut -Target $realOut -ErrorAction Stop
    }
    catch {
        if ($onWin32) {
            $outLinkCreated = $false
        }
        else {
            throw
        }
    }
    if ($outLinkCreated) {
        $linkedOut = Invoke-WriteReceipt $linkOutCase @(
            '-Item', 'x', '-Verify', 'ok', '-Output', $aliasOut
        )
        Expect-True ($linkedOut.ExitCode -eq 2) "symlink output exits 2 (got $($linkedOut.ExitCode) $($linkedOut.Stderr))"
        Expect-True ($linkedOut.Stderr -match 'missing output') 'symlink output is missing'
        Expect-True (-not (Test-Path -LiteralPath (Join-Path $linkOutNs 'receipts'))) `
            'does not create receipts for a symlink output'
    }

    $repo = Join-Path $root 'repo'
    $null = New-Item -ItemType Directory -Path (Join-Path $repo '.nightshift') -Force
    [IO.File]::WriteAllText((Join-Path $repo '.nightshift/work-mode'), "repository`n")
    $repoOut = Join-Path $repo 'out.md'
    [IO.File]::WriteAllText($repoOut, "ok`n")
    $refused = Invoke-WriteReceipt $repo @(
        '-Item', 'x', '-Verify', 'ok', '-Output', $repoOut
    )
    Expect-True ($refused.ExitCode -eq 3) "repository mode exits 3 (got $($refused.ExitCode) $($refused.Stderr))"
    Expect-True (-not (Test-Path -LiteralPath (Join-Path $repo '.nightshift/receipts'))) `
        'repository refuse writes no receipts directory'

    $mtimeCase = Join-Path $root 'mtime-notes'
    $mtimeNs = Join-Path $mtimeCase '.nightshift'
    $mtimeRecv = Join-Path $mtimeNs 'receipts'
    $null = New-Item -ItemType Directory -Path $mtimeRecv -Force
    [IO.File]::WriteAllText((Join-Path $mtimeNs 'work-mode'), "artifact`n")
    $first = Join-Path $mtimeRecv '20260101T000000Z-item.md'
    $second = Join-Path $mtimeRecv '20260101T000000Z-item-1.md'
    [IO.File]::WriteAllText($first, "first`n")
    [IO.File]::WriteAllText($second, "second`n")
    $same = (Get-Item -LiteralPath $first).LastWriteTimeUtc
    (Get-Item -LiteralPath $second).LastWriteTimeUtc = $same
    Expect-True (([IO.Path]::GetFileName((Get-NSLatestReceipt $mtimeCase))) -eq '20260101T000000Z-item-1.md') `
        'same-mtime uniqueness suffix is latest, not C-locale last'

    $staleName = Join-Path $mtimeRecv '20261231T235959Z-new.md'
    $laterWrite = Join-Path $mtimeRecv '20260101T000000Z-old.md'
    [IO.File]::WriteAllText($staleName, "stale name`n")
    [IO.File]::WriteAllText($laterWrite, "written later`n")
    $now = [DateTime]::UtcNow
    (Get-Item -LiteralPath $staleName).LastWriteTimeUtc = $now.AddHours(-1)
    (Get-Item -LiteralPath $laterWrite).LastWriteTimeUtc = $now
    (Get-Item -LiteralPath $first).LastWriteTimeUtc = $now.AddHours(-2)
    (Get-Item -LiteralPath $second).LastWriteTimeUtc = $now.AddHours(-2)
    Expect-True (([IO.Path]::GetFileName((Get-NSLatestReceipt $mtimeCase))) -eq '20260101T000000Z-old.md') `
        'mtime beats a later-looking stamp'

    $hiddenCase = Join-Path $root 'hidden-notes'
    $hiddenNs = Join-Path $hiddenCase '.nightshift'
    $hiddenRecv = Join-Path $hiddenNs 'receipts'
    $null = New-Item -ItemType Directory -Path $hiddenRecv -Force
    [IO.File]::WriteAllText((Join-Path $hiddenNs 'work-mode'), "artifact`n")
    [IO.File]::WriteAllText((Join-Path $hiddenRecv '.not-a-receipt'), "dot`n")
    Expect-True ($null -eq (Get-NSLatestReceipt $hiddenCase)) 'hidden-only receipts are not latest'
    Expect-True ((Get-NSReceiptsCount $hiddenCase) -eq 0) 'hidden-only receipts count as zero'
    [IO.File]::WriteAllText((Join-Path $hiddenRecv '20260101T000000Z-real.md'), "ok`n")
    Expect-True ((Get-NSReceiptsCount $hiddenCase) -eq 1) 'a real receipt counts beside a hidden file'
    Expect-True (([IO.Path]::GetFileName((Get-NSLatestReceipt $hiddenCase))) -eq '20260101T000000Z-real.md') `
        'latest ignores a hidden sibling'

    $nestedCase = Join-Path $root 'nested-notes'
    $nestedNs = Join-Path $nestedCase '.nightshift'
    $nestedRecv = Join-Path $nestedNs 'receipts'
    $nestedSub = Join-Path $nestedRecv 'nested'
    $null = New-Item -ItemType Directory -Path $nestedSub -Force
    [IO.File]::WriteAllText((Join-Path $nestedNs 'work-mode'), "artifact`n")
    [IO.File]::WriteAllText((Join-Path $nestedRecv '20260101T000000Z-real.md'), "ok`n")
    $fpFlat = Get-NSReceiptsFingerprint $nestedCase
    [IO.File]::WriteAllText((Join-Path $nestedSub '20260101T000000Z-nested.md'), "nested`n")
    Expect-True ((Get-NSReceiptsCount $nestedCase) -eq 1) 'nested receipt is not counted'
    Expect-True (([IO.Path]::GetFileName((Get-NSLatestReceipt $nestedCase))) -eq '20260101T000000Z-real.md') `
        'nested receipt is not latest'
    Expect-True ((Get-NSReceiptsFingerprint $nestedCase) -eq $fpFlat) 'nested receipt is not in the stall fingerprint'

    Remove-Item -LiteralPath (Join-Path $nestedRecv '20260101T000000Z-real.md') -Force
    Expect-True ((Get-NSReceiptsCount $nestedCase) -eq 0) 'nested-only receipts count as zero'
    Expect-True ($null -eq (Get-NSLatestReceipt $nestedCase)) 'nested-only receipts are not latest'
    Expect-True ((Get-NSReceiptsFingerprint $nestedCase) -eq 'none') 'nested-only receipts have no stall fingerprint'

    $symlinkCase = Join-Path $root 'symlink-notes'
    $symlinkNs = Join-Path $symlinkCase '.nightshift'
    $symlinkRecv = Join-Path $symlinkNs 'receipts'
    $null = New-Item -ItemType Directory -Path $symlinkRecv -Force
    [IO.File]::WriteAllText((Join-Path $symlinkNs 'work-mode'), "artifact`n")
    $realReceipt = Join-Path $symlinkRecv '20260101T000000Z-real.md'
    [IO.File]::WriteAllText($realReceipt, "ok`n")
    $fpBefore = Get-NSReceiptsFingerprint $symlinkCase
    $receiptLink = Join-Path $symlinkRecv '20260101T000000Z-link.md'
    $fileLinkCreated = $true
    try {
        $null = New-Item -ItemType SymbolicLink -Path $receiptLink -Target $realReceipt -ErrorAction Stop
    }
    catch {
        if ($onWin32) {
            $fileLinkCreated = $false
        }
        else {
            throw
        }
    }
    if ($fileLinkCreated) {
        Expect-True ((Get-NSReceiptsCount $symlinkCase) -eq 1) 'symlink receipt is not counted'
        Expect-True (([IO.Path]::GetFileName((Get-NSLatestReceipt $symlinkCase))) -eq '20260101T000000Z-real.md') `
            'symlink receipt is not latest'
        Expect-True ((Get-NSReceiptsFingerprint $symlinkCase) -eq $fpBefore) `
            'symlink receipt is not in the stall fingerprint'
    }

    $linkWrite = Join-Path $root 'link-write-notes'
    $linkWriteNs = Join-Path $linkWrite '.nightshift'
    $outsideRecv = Join-Path $root 'outside-recv'
    $null = New-Item -ItemType Directory -Path $linkWriteNs, $outsideRecv -Force
    [IO.File]::WriteAllText((Join-Path $linkWriteNs 'work-mode'), "artifact`n")
    New-ReparseDirectory (Join-Path $linkWriteNs 'receipts') $outsideRecv
    $linkOut = Join-Path $linkWrite 'out.md'
    [IO.File]::WriteAllText($linkOut, "ok`n")
    $blocked = Invoke-WriteReceipt $linkWrite @(
        '-Item', 'x', '-Verify', 'ok', '-Output', $linkOut
    )
    Expect-True ($blocked.ExitCode -eq 2) "symlink receipts dir exits 2 (got $($blocked.ExitCode) $($blocked.Stderr))"
    Expect-True (@(Get-ChildItem -LiteralPath $outsideRecv -File -Force -ErrorAction SilentlyContinue).Count -eq 0) `
        'does not write through a reparse receipts path'
    Expect-True ((Get-NSReceiptsCount $linkWrite) -eq 0) 'symlink receipts dir is not counted'
    Expect-True ($null -eq (Get-NSLatestReceipt $linkWrite)) 'symlink receipts dir is not latest'
    Expect-True ((Get-NSReceiptsFingerprint $linkWrite) -eq 'none') 'symlink receipts dir has no stall fingerprint'

    $fileWrite = Join-Path $root 'file-write-notes'
    $fileWriteNs = Join-Path $fileWrite '.nightshift'
    $null = New-Item -ItemType Directory -Path $fileWriteNs -Force
    [IO.File]::WriteAllText((Join-Path $fileWriteNs 'work-mode'), "artifact`n")
    [IO.File]::WriteAllText((Join-Path $fileWriteNs 'receipts'), "not-a-dir`n")
    $fileOut = Join-Path $fileWrite 'out.md'
    [IO.File]::WriteAllText($fileOut, "ok`n")
    $fileBlocked = Invoke-WriteReceipt $fileWrite @(
        '-Item', 'x', '-Verify', 'ok', '-Output', $fileOut
    )
    Expect-True ($fileBlocked.ExitCode -eq 2) "file receipts path exits 2 (got $($fileBlocked.ExitCode) $($fileBlocked.Stderr))"
    Expect-True ((Get-Content -LiteralPath (Join-Path $fileWriteNs 'receipts') -Raw) -match 'not-a-dir') `
        'does not replace a file receipts path'
    $fileDoctor = Invoke-Doctor $fileWrite
    Expect-True ($fileDoctor.ExitCode -eq 0) "Doctor on file receipts path exits 0 (got $($fileDoctor.ExitCode))"
    Expect-True ($fileDoctor.Stdout -match 'artifact receipts path is not a usable directory') `
        'Doctor warns when receipts path is not a usable directory'
    Expect-True ($fileDoctor.Stdout -match 'so write-receipt can land') `
        'Doctor offers a replace-path action when receipts path is unusable'
    Expect-True ($fileDoctor.Stdout -notmatch 'complete ticked items with') `
        'Doctor does not offer write-receipt on an unusable receipts path'

    [IO.File]::WriteAllText((Join-Path $fileWriteNs 'punch-list.md'), "## Items`n- [x] **done.**`n")
    $tickedUnusable = Invoke-Doctor $fileWrite
    Expect-True ($tickedUnusable.ExitCode -eq 0) "Doctor on ticked unusable receipts path exits 0 (got $($tickedUnusable.ExitCode))"
    Expect-True ($tickedUnusable.Stdout -match 'artifact receipts path is not a usable directory') `
        'Doctor still warns unusable path when ticks exist'
    Expect-True ($tickedUnusable.Stdout -match 'so write-receipt can land') `
        'Doctor still offers replace-path when ticks sit on an unusable receipts path'
    Expect-True ($tickedUnusable.Stdout -notmatch 'ticked items have no receipt text') `
        'Doctor does not warn empty ticks when receipts path is unusable'
        Expect-True ($tickedUnusable.Stdout -notmatch 'complete ticked items with') `
            'Doctor does not offer write-receipt when ticks sit on an unusable receipts path'

    $modeLinkCase = Join-Path $root 'mode-link-notes'
    $modeLinkNs = Join-Path $modeLinkCase '.nightshift'
    $modeLinkOut = Join-Path $modeLinkCase 'out.md'
    $null = New-Item -ItemType Directory -Path $modeLinkNs -Force
    $modePlant = Join-Path $modeLinkNs 'mode-plant'
    [IO.File]::WriteAllText($modePlant, "artifact`n")
    [IO.File]::WriteAllText($modeLinkOut, "ok`n")
    $modeLink = Join-Path $modeLinkNs 'work-mode'
    try {
        $null = New-Item -ItemType SymbolicLink -Path $modeLink -Target $modePlant -ErrorAction Stop
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
        $modeBlocked = Invoke-WriteReceipt $modeLinkCase @(
            '-Item', 'x', '-Verify', 'ok', '-Output', $modeLinkOut
        )
        Expect-True ($modeBlocked.ExitCode -eq 3) `
            "symlink work-mode exits 3 (got $($modeBlocked.ExitCode) $($modeBlocked.Stderr))"
        Expect-True (($modeBlocked.Stderr + $modeBlocked.Stdout) -match 'work-mode is malformed') `
            'symlink work-mode is malformed'
        Expect-True (-not (Test-Path -LiteralPath (Join-Path $modeLinkNs 'receipts'))) `
            'does not create receipts for a symlink work-mode'
    }
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures.Count -gt 0) {
    Write-Host "write-receipt logic failed ($($failures.Count)):"
    foreach ($failure in $failures) {
        Write-Host " - $failure"
    }
    exit 1
}
Write-Host 'write-receipt logic passed'
exit 0
