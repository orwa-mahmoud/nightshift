# Portable PowerShell coverage for the native Windows comparison helper.
# Run on macOS or Windows: pwsh -File tests/windows/evidence-compare-logic.ps1
#
# Covers the frozen 03A interface: the baseline record the comparison reads,
# all eight comparison classes, tool-unavailable-is-not-improvement,
# a moved environment digest, dedupe that keeps every originating tool,
# clear-all against no-regression-plus-selected-debt, the validator's
# acceptance of completionMode and selectedDebt, exact byte formatting, and
# byte parity with the bash helper when it is on the branch.
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if (Test-Path Variable:PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $false
}

$repository = Resolve-Path (Join-Path $PSScriptRoot '../..')
$plugin = Join-Path $repository 'plugins/nightshift'
$ledger = Join-Path $plugin 'runtime/windows/evidence.ps1'
$compareHelper = Join-Path $plugin 'runtime/windows/evidence-compare.ps1'
$policyHelper = Join-Path $plugin 'runtime/windows/shift-policy.ps1'
$bashCompare = Join-Path $plugin 'runtime/evidence-compare.sh'
$hostExecutable = (Get-Process -Id $PID).Path
$failures = New-Object 'System.Collections.Generic.List[string]'
$utf8 = New-Object Text.UTF8Encoding($false)
$fixedNow = '2026-09-02T00:00:00Z'

Import-Module (Join-Path $plugin 'lib/Nightshift.psm1') -Force -DisableNameChecking

function Expect-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        $failures.Add($Message)
        Write-Host "FAIL: $Message"
    }
}

function Expect-Equal {
    param($Expected, $Actual, [string]$Message)
    Expect-True (([string]$Expected) -ceq ([string]$Actual)) "$Message (expected '$Expected', got '$Actual')"
}

function Set-ProcessArguments {
    # Windows PowerShell 5.1 runs on .NET Framework, whose ProcessStartInfo has
    # no ArgumentList. Quote into Arguments there, the way CommandLineToArgvW
    # reads it back.
    param(
        [Parameter(Mandatory = $true)]$StartInfo,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )
    if ($null -ne $StartInfo.PSObject.Properties['ArgumentList']) {
        foreach ($argument in $Arguments) { $null = $StartInfo.ArgumentList.Add($argument) }
        return
    }
    $quoted = New-Object Collections.Generic.List[string]
    foreach ($argument in $Arguments) {
        $escaped = $argument -replace '(\\*)"', '$1$1\"'
        $escaped = $escaped -replace '(\\+)$', '$1$1'
        $quoted.Add('"' + $escaped + '"')
    }
    $StartInfo.Arguments = ($quoted -join ' ')
}

function Invoke-ProcessBytes {
    # Raw bytes, never PowerShell's native-command pipeline: the LF-only,
    # BOM-free, single-trailing-newline guarantees are byte claims and must be
    # read as bytes.
    param(
        [Parameter(Mandatory = $true)][string]$FileName,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [hashtable]$EnvOverrides
    )
    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $FileName
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    Set-ProcessArguments -StartInfo $psi -Arguments $Arguments
    if ($PSBoundParameters.ContainsKey('EnvOverrides')) {
        foreach ($key in $EnvOverrides.Keys) {
            foreach ($existing in @($psi.EnvironmentVariables.Keys)) {
                if ($existing -ieq [string]$key) { $null = $psi.EnvironmentVariables.Remove($existing) }
            }
            $psi.EnvironmentVariables.Add([string]$key, [string]$EnvOverrides[$key])
        }
    }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $psi
    $null = $process.Start()
    $outStream = New-Object IO.MemoryStream
    $errStream = New-Object IO.MemoryStream
    $outTask = $process.StandardOutput.BaseStream.CopyToAsync($outStream)
    $errTask = $process.StandardError.BaseStream.CopyToAsync($errStream)
    $process.WaitForExit()
    $null = $outTask.GetAwaiter().GetResult()
    $null = $errTask.GetAwaiter().GetResult()
    $outBytes = $outStream.ToArray()
    return [pscustomobject]@{
        ExitCode    = $process.ExitCode
        StdoutBytes = $outBytes
        StdoutText  = [Text.Encoding]::UTF8.GetString($outBytes)
        StderrText  = [Text.Encoding]::UTF8.GetString($errStream.ToArray())
    }
}

function Invoke-Script {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )
    $psArgs = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $Path) + $Arguments
    return Invoke-ProcessBytes -FileName $hostExecutable -Arguments $psArgs `
        -EnvOverrides @{ NIGHTSHIFT_EVIDENCE_NOW = $fixedNow }
}

function Test-NSNoCarriageReturn {
    param([byte[]]$Bytes)
    foreach ($byte in $Bytes) { if ($byte -eq 13) { return $false } }
    return $true
}

function Test-NSSingleTrailingNewline {
    param([byte[]]$Bytes)
    if ($Bytes.Length -lt 2) { return $false }
    return ($Bytes[$Bytes.Length - 1] -eq 10 -and $Bytes[$Bytes.Length - 2] -ne 10)
}

function Test-NSAsciiOnly {
    param([byte[]]$Bytes)
    foreach ($byte in $Bytes) { if ($byte -gt 127) { return $false } }
    return $true
}

function Test-NSHasBom {
    param([byte[]]$Bytes)
    if ($Bytes.Length -lt 3) { return $false }
    return ($Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF)
}

function Test-NSBytesEqual {
    param([byte[]]$Left, [byte[]]$Right)
    if ($Left.Length -ne $Right.Length) { return $false }
    for ($i = 0; $i -lt $Left.Length; $i++) {
        if ($Left[$i] -ne $Right[$i]) { return $false }
    }
    return $true
}

function Test-NSKeysSorted {
    # Every JSON object in the parsed tree has its keys in ascending ordinal
    # order, matching Python's json.dumps(sort_keys=True).
    param($Node)
    if ($null -eq $Node) { return $true }
    if ($Node -is [Array]) {
        foreach ($item in $Node) {
            if (-not (Test-NSKeysSorted $item)) { return $false }
        }
        return $true
    }
    if ($Node -is [Management.Automation.PSCustomObject]) {
        $names = @($Node.PSObject.Properties.Name)
        for ($i = 1; $i -lt $names.Count; $i++) {
            if ([string]::CompareOrdinal($names[$i - 1], $names[$i]) -gt 0) { return $false }
        }
        foreach ($name in $names) {
            if (-not (Test-NSKeysSorted $Node.$name)) { return $false }
        }
        return $true
    }
    return $true
}

function Get-Sha256Hex {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))
    }
    finally {
        $sha.Dispose()
    }
    $hex = New-Object Text.StringBuilder
    foreach ($byte in $hash) { $null = $hex.Append($byte.ToString('x2')) }
    return $hex.ToString()
}

function New-EvidenceProject {
    param([Parameter(Mandatory = $true)][string]$Path)
    $ns = Join-Path $Path '.nightshift'
    $null = New-Item -ItemType Directory -Path $ns -Force
    [IO.File]::WriteAllText((Join-Path $ns 'state-version'), "1`n", $utf8)
    return $ns
}

function New-FindingJson {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$Digest,
        [string]$SourceClass = 'lint',
        [string]$Source = 'npm run lint',
        [string]$Status = 'open',
        [string]$Ladder = 'observed',
        [string]$Disposition = '',
        [string]$DuplicateOf = '',
        [string]$Locator = 'src/app.js',
        [string]$Fix = '',
        [string]$VerificationLocator = '',
        [string[]]$Sources = @()
    )
    $record = New-NSOrdinalMap
    $record['schemaVersion'] = 1
    $record['id'] = $Id
    $record['domain'] = 'quality'
    $record['sourceClass'] = $SourceClass
    $record['source'] = $Source
    $record['scope'] = 'repo'
    $record['severity'] = 'medium'
    $record['confidence'] = 'high'
    $record['impact'] = 'developer'
    $record['status'] = $Status
    $record['ladder'] = $Ladder
    $record['locator'] = $Locator
    $record['digest'] = $Digest
    $record['firstSeen'] = $fixedNow
    $record['lastChecked'] = $fixedNow
    $record['action'] = 'logged for review'
    $record['host'] = 'claude'
    $record['workTarget'] = 'test-target'
    $record['fix'] = $Fix
    $record['verificationLocator'] = $VerificationLocator
    $record['disposition'] = $Disposition
    $record['rollback'] = ''
    if (-not [string]::IsNullOrEmpty($DuplicateOf)) { $record['duplicateOf'] = $DuplicateOf }
    if (@($Sources).Count -gt 0) { $record['sources'] = @($Sources) }
    return (ConvertTo-NSCanonicalJson $record -Compact)
}

function New-BaselineJson {
    # A baseline record as the model writes one through the ledger: domain
    # "baseline", the exact command, the environment digest the comparison
    # measures against, and every finding that source already had.
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$Environment,
        [string]$Status = 'open',
        [string]$SourceClass = 'lint',
        [string]$Command = 'npm run lint',
        [string]$Scope = 'repo',
        [string[]]$Seen = @()
    )
    $entries = New-Object Collections.Generic.List[object]
    foreach ($pair in $Seen) {
        if ([string]::IsNullOrEmpty($pair)) { continue }
        $at = $pair.IndexOf('=')
        $entry = New-NSOrdinalMap
        if ($at -ge 0) {
            $entry['digest'] = $pair.Substring($at + 1)
            $entry['id'] = $pair.Substring(0, $at)
        }
        else {
            $entry['digest'] = ''
            $entry['id'] = $pair
        }
        $entries.Add($entry)
    }
    $details = New-NSOrdinalMap
    $details['command'] = $Command
    $details['environmentDigest'] = $Environment
    $details['rawDigest'] = 'raw-' + $Id
    $details['scope'] = $Scope
    $details['seen'] = @($entries.ToArray())
    $details['sourceClass'] = $SourceClass
    $record = New-NSOrdinalMap
    $record['schemaVersion'] = 1
    $record['id'] = $Id
    $record['domain'] = 'baseline'
    $record['sourceClass'] = $SourceClass
    $record['source'] = $Command
    $record['scope'] = $Scope
    $record['severity'] = 'info'
    $record['confidence'] = 'high'
    $record['impact'] = 'none'
    $record['status'] = $Status
    $record['ladder'] = 'measured'
    $record['locator'] = $Scope
    $record['digest'] = 'digest-' + $Id
    $record['firstSeen'] = $fixedNow
    $record['lastChecked'] = $fixedNow
    $record['action'] = 'baseline recorded'
    $record['host'] = 'claude'
    $record['workTarget'] = 'test-target'
    $record['details'] = $details
    return (ConvertTo-NSCanonicalJson $record -Compact)
}

function Add-Finding {
    param(
        [Parameter(Mandatory = $true)][string]$Project,
        [Parameter(Mandatory = $true)][string]$Json
    )
    return (Invoke-Script -Path $ledger -Arguments @('-Project', $Project, '-Command', 'append', '-Record', $Json))
}

function Get-RowClass {
    param($Document, [Parameter(Mandatory = $true)][string]$Id)
    foreach ($row in @($Document.rows)) {
        if ([string]$row.id -ceq $Id) { return [string]$row.class }
    }
    return '(absent)'
}

function Get-RowSources {
    param($Document, [Parameter(Mandatory = $true)][string]$Id)
    foreach ($row in @($Document.rows)) {
        if ([string]$row.id -ceq $Id) { return (@($row.sources) -join ',') }
    }
    return '(absent)'
}

function Write-PolicyFile {
    param(
        [Parameter(Mandatory = $true)][string]$NightshiftDir,
        [AllowEmptyString()][string]$CompletionMode = '',
        [AllowNull()][AllowEmptyCollection()][string[]]$SelectedDebt = @()
    )
    $policy = New-NSOrdinalMap
    $policy['schemaVersion'] = 1
    $policy['shiftId'] = '0123456789abcdef'
    $policy['createdAt'] = $fixedNow
    $policy['source'] = 'composition'
    $policy['verificationLevel'] = 'final'
    $policy['toolingPolicy'] = 'existing-tools'
    if (-not [string]::IsNullOrEmpty($CompletionMode)) { $policy['completionMode'] = $CompletionMode }
    if (@($SelectedDebt).Count -gt 0) { $policy['selectedDebt'] = @($SelectedDebt) }
    [IO.File]::WriteAllText((Join-Path $NightshiftDir 'shift-policy.json'),
        ((ConvertTo-NSCanonicalJson $policy) + "`n"), $utf8)
}

# ---------------------------------------------------------------------------
# Fixture digests. Explicit, so "unchanged" and "regressed" are decided by the
# digest the record carries rather than by anything the helper recomputes.
# ---------------------------------------------------------------------------
$digestCleared = 'c' * 64
$digestUnchanged = 'u' * 64
$digestBefore = 'b' * 64
$digestAfter = 'a' * 64
$digestGone = '9' * 64
$digestNew = 'e' * 64
$digestOther = '7' * 64

$root = Join-Path ([IO.Path]::GetTempPath()) ("ns-evidence-compare-" + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $root -Force
$bashCommand = Get-Command bash -ErrorAction SilentlyContinue

try {
    # === 1. All eight classes on one ledger ===
    $project = Join-Path $root 'classes'
    $ns = New-EvidenceProject $project

    $baselineRun = Add-Finding -Project $project -Json (New-BaselineJson -Id 'B1' -Environment 'env-1' `
            -Seen @("F-cleared=$digestCleared", "F-unchanged=$digestUnchanged",
                "F-regressed=$digestBefore", "F-gone=$digestGone"))
    Expect-Equal 0 $baselineRun.ExitCode "the ledger takes a baseline record ($($baselineRun.StderrText))"
    Expect-Equal 'B1' $baselineRun.StdoutText.Trim() 'the ledger prints the baseline record id'

    $findings = @(
        (New-FindingJson -Id 'F-cleared' -Digest $digestCleared -Status 'fixed' -Ladder 'verified-after-change' `
                -Fix 'fix(lint): quiet the rule' -VerificationLocator 'npm run lint'),
        (New-FindingJson -Id 'F-unchanged' -Digest $digestUnchanged),
        (New-FindingJson -Id 'F-regressed' -Digest $digestAfter),
        (New-FindingJson -Id 'F-new' -Digest $digestNew),
        (New-FindingJson -Id 'F-unavail' -Digest $digestOther -Status 'unavailable'),
        (New-FindingJson -Id 'F-human' -Digest $digestOther -Status 'human-only'),
        (New-FindingJson -Id 'F-parked' -Digest $digestOther -Disposition 'parked'),
        (New-FindingJson -Id 'F-dup' -Digest $digestOther -Status 'rejected' -Source 'npx eslint' -DuplicateOf 'F-new')
    )
    foreach ($json in $findings) {
        $appended = Add-Finding -Project $project -Json $json
        Expect-Equal 0 $appended.ExitCode "append exits 0 ($($appended.StderrText))"
    }

    $jsonRun = Invoke-Script -Path $compareHelper -Arguments @('-Project', $project, '-Baseline', 'B1', '-Json')
    Expect-Equal 3 $jsonRun.ExitCode 'clear-all with outstanding findings exits 3'
    Expect-True (Test-NSNoCarriageReturn $jsonRun.StdoutBytes) 'comparison JSON has no CR bytes (LF only)'
    Expect-True (Test-NSSingleTrailingNewline $jsonRun.StdoutBytes) 'comparison JSON ends with exactly one LF'
    Expect-True (Test-NSAsciiOnly $jsonRun.StdoutBytes) 'comparison JSON contains no non-ASCII bytes'
    Expect-True (-not (Test-NSHasBom $jsonRun.StdoutBytes)) 'comparison JSON has no BOM'
    Expect-True (-not $jsonRun.StdoutText.Contains(', ')) 'comparison JSON has no comma-space separator'
    Expect-True (-not $jsonRun.StdoutText.Contains(': ')) 'comparison JSON has no colon-space separator'

    $document = $null
    try { $document = $jsonRun.StdoutText | ConvertFrom-Json } catch { $document = $null }
    Expect-True ($null -ne $document) 'comparison JSON parses'
    if ($null -ne $document) {
        Expect-True (Test-NSKeysSorted $document) 'comparison JSON has keys sorted recursively'
        Expect-Equal 1 $document.schemaVersion 'the comparison carries schemaVersion 1'
        Expect-Equal 'B1' $document.baseline 'the comparison names its baseline'
        Expect-Equal 'clear-all' $document.mode 'an absent completionMode resolves to clear-all'
        Expect-Equal 'False' $document.pass 'clear-all does not pass while findings are outstanding'

        Expect-Equal 'new' (Get-RowClass $document 'F-new') 'a finding the baseline never saw is new'
        Expect-Equal 'cleared' (Get-RowClass $document 'F-cleared') 'a fixed finding is cleared'
        Expect-Equal 'unchanged' (Get-RowClass $document 'F-unchanged') 'the same digest is unchanged'
        Expect-Equal 'regressed' (Get-RowClass $document 'F-regressed') 'a moved digest on a known id is regressed'
        Expect-Equal 'unavailable' (Get-RowClass $document 'F-unavail') 'an unavailable source is unavailable'
        Expect-Equal 'unavailable' (Get-RowClass $document 'F-gone') 'a baseline id the ledger no longer carries is unavailable, never cleared'
        Expect-Equal 'rejected-duplicate' (Get-RowClass $document 'F-dup') 'a duplicate root cause is rejected-duplicate'
        Expect-Equal 'parked' (Get-RowClass $document 'F-parked') 'a parked disposition is parked'
        Expect-Equal 'human-only' (Get-RowClass $document 'F-human') 'a human-only status is human-only'

        Expect-Equal 'npm run lint,npx eslint' (Get-RowSources $document 'F-new') `
            'dedupe keeps every originating tool on the surviving row'
        Expect-Equal 'npx eslint' (Get-RowSources $document 'F-dup') 'the duplicate keeps its own tool'

        $ids = @(@($document.rows) | ForEach-Object { [string]$_.id })
        $sorted = $true
        for ($i = 1; $i -lt $ids.Count; $i++) {
            if ([string]::CompareOrdinal($ids[$i - 1], $ids[$i]) -ge 0) { $sorted = $false }
        }
        Expect-True $sorted 'rows are sorted by id in byte order'
        Expect-Equal 9 (@($document.rows).Count) 'every baseline id and every current finding gets a row'
        Expect-Equal 9 $document.summary.total 'the summary total counts every row'
        Expect-Equal 2 $document.summary.unavailable 'both unavailable rows are counted'
        Expect-Equal 1 $document.summary.cleared 'the cleared row is counted'
        Expect-Equal 1 $document.summary.regressed 'the regressed row is counted'
    }

    $mdRun = Invoke-Script -Path $compareHelper -Arguments @('-Project', $project, '-Baseline', 'B1', '-Md')
    Expect-Equal 3 $mdRun.ExitCode 'the Markdown view reports the same verdict as the JSON view'
    Expect-True (Test-NSNoCarriageReturn $mdRun.StdoutBytes) 'the comparison table has no CR bytes (LF only)'
    Expect-True (Test-NSSingleTrailingNewline $mdRun.StdoutBytes) 'the comparison table ends with exactly one LF'
    Expect-True (-not (Test-NSHasBom $mdRun.StdoutBytes)) 'the comparison table has no BOM'
    Expect-True $mdRun.StdoutText.Contains('| ID | Class | Digest | Sources | Locator |') 'the table names its columns'
    Expect-True $mdRun.StdoutText.Contains('Mode: clear-all') 'the table names the completion mode'
    Expect-True $mdRun.StdoutText.Contains('Result: fail') 'the table names the verdict'
    Expect-True $mdRun.StdoutText.Contains('| F-gone | unavailable |') 'the table cites the missing baseline id'
    Expect-True $mdRun.StdoutText.Contains('unavailable 2') 'the summary line carries the class counts'

    # The default view is the table, so a caller that names no format still gets
    # something a person can read.
    $defaultRun = Invoke-Script -Path $compareHelper -Arguments @('-Project', $project, '-Baseline', 'B1')
    Expect-True (Test-NSBytesEqual $mdRun.StdoutBytes $defaultRun.StdoutBytes) 'the table is the default view'

    $unknownRun = Invoke-Script -Path $compareHelper -Arguments @('-Project', $project, '-Baseline', 'B404', '-Json')
    Expect-Equal 2 $unknownRun.ExitCode 'an unknown baseline is a contract failure'
    Expect-Equal 'evidence-compare: unknown baseline B404' $unknownRun.StderrText.Trim() `
        'an unknown baseline names itself on stderr'
    $usageRun = Invoke-Script -Path $compareHelper -Arguments @('-Project', $project, '-Baseline', 'B1', '-Json', '-Md')
    Expect-Equal 1 $usageRun.ExitCode 'two output formats at once is a usage error'

    # === 2. The ledger keeps the baseline record the comparison reads ===
    $ledgerPath = Join-Path $ns 'evidence/findings.jsonl'
    $baselineRecord = $null
    foreach ($line in [IO.File]::ReadAllLines($ledgerPath)) {
        if ($line.Length -eq 0) { continue }
        $parsed = $line | ConvertFrom-Json
        if ([string]$parsed.id -ceq 'B1') { $baselineRecord = $parsed }
    }
    Expect-True ($null -ne $baselineRecord) 'the baseline record is in the ledger'
    if ($null -ne $baselineRecord) {
        Expect-Equal 'baseline' $baselineRecord.domain 'the baseline record carries the baseline domain'
        Expect-Equal 'npm run lint' $baselineRecord.source 'the exact command is the record source'
        Expect-Equal 'env-1' $baselineRecord.details.environmentDigest `
            'the comparison reads the environment digest off the record'
        Expect-Equal 4 (@($baselineRecord.details.seen).Count) 'every seen id is recorded'
        Expect-Equal 'F-cleared' (@($baselineRecord.details.seen)[0].id) 'seen ids are sorted in byte order'
    }


    # === 3. clear-all against no-regression-plus-selected-debt, same ledger ===
    $modeProject = Join-Path $root 'modes'
    $modeNs = New-EvidenceProject $modeProject
    $modeBaseline = Add-Finding -Project $modeProject -Json (New-BaselineJson -Id 'B1' -Environment 'env-1' `
            -Seen @("F-cleared=$digestCleared", "F-unchanged=$digestUnchanged"))
    Expect-Equal 0 $modeBaseline.ExitCode "the mode fixture baseline is written ($($modeBaseline.StderrText))"
    $null = Add-Finding -Project $modeProject -Json (New-FindingJson -Id 'F-cleared' -Digest $digestCleared -Status 'fixed')
    $null = Add-Finding -Project $modeProject -Json (New-FindingJson -Id 'F-unchanged' -Digest $digestUnchanged)

    Write-PolicyFile -NightshiftDir $modeNs -CompletionMode 'clear-all'
    $strict = Invoke-Script -Path $compareHelper -Arguments @('-Project', $modeProject, '-Baseline', 'B1', '-Json')
    Expect-Equal 3 $strict.ExitCode 'clear-all fails while one finding is only unchanged'

    Write-PolicyFile -NightshiftDir $modeNs -CompletionMode 'no-regression-plus-selected-debt' -SelectedDebt @('F-cleared')
    $relaxed = Invoke-Script -Path $compareHelper -Arguments @('-Project', $modeProject, '-Baseline', 'B1', '-Json')
    Expect-Equal 0 $relaxed.ExitCode 'no-regression passes when nothing regressed and the selected debt cleared'
    $relaxedDocument = $relaxed.StdoutText | ConvertFrom-Json
    Expect-Equal 'no-regression-plus-selected-debt' $relaxedDocument.mode 'the mode comes from the shift policy'
    Expect-Equal 'True' $relaxedDocument.pass 'the relaxed mode passes on the same ledger'
    Expect-Equal 0 (@($relaxedDocument.summary.selectedDebtOutstanding).Count) 'no selected debt is left outstanding'

    Write-PolicyFile -NightshiftDir $modeNs -CompletionMode 'no-regression-plus-selected-debt' -SelectedDebt @('F-unchanged')
    $unmet = Invoke-Script -Path $compareHelper -Arguments @('-Project', $modeProject, '-Baseline', 'B1', '-Json')
    Expect-Equal 3 $unmet.ExitCode 'selected debt that did not clear fails the relaxed mode'
    $unmetDocument = $unmet.StdoutText | ConvertFrom-Json
    Expect-Equal 'F-unchanged' ((@($unmetDocument.summary.selectedDebtOutstanding)) -join ',') `
        'the summary names the selected debt still outstanding'

    # === 4. A tool that could not run is never an improvement ===
    $toolProject = Join-Path $root 'tool-unavailable'
    $toolNs = New-EvidenceProject $toolProject
    $null = Add-Finding -Project $toolProject -Json (New-BaselineJson -Id 'B1' -Environment 'env-1' `
            -Seen @("F-cleared=$digestCleared"))
    $null = Add-Finding -Project $toolProject -Json (New-FindingJson -Id 'F-cleared' -Digest $digestCleared -Status 'unavailable')
    Write-PolicyFile -NightshiftDir $toolNs -CompletionMode 'clear-all'
    $toolRun = Invoke-Script -Path $compareHelper -Arguments @('-Project', $toolProject, '-Baseline', 'B1', '-Json')
    Expect-Equal 3 $toolRun.ExitCode 'a source the ledger marked unavailable never passes clear-all'
    $toolDocument = $toolRun.StdoutText | ConvertFrom-Json
    Expect-Equal 'unavailable' (Get-RowClass $toolDocument 'F-cleared') 'an unavailable tool is reported as unavailable'
    Expect-Equal 0 $toolDocument.summary.cleared 'an unavailable tool clears nothing'

    # A source that reported itself unavailable and saw nothing still answers unavailable:
    # the verdict follows the source, not the number of rows it happens to carry.
    $emptyProject = Join-Path $root 'tool-unavailable-empty'
    $emptyNs = New-EvidenceProject $emptyProject
    $null = Add-Finding -Project $emptyProject -Json (New-BaselineJson -Id 'B1' -Environment 'env-1' -Status 'unavailable')
    Write-PolicyFile -NightshiftDir $emptyNs -CompletionMode 'clear-all'
    $emptyRun = Invoke-Script -Path $compareHelper -Arguments @('-Project', $emptyProject, '-Baseline', 'B1', '-Json')
    Expect-Equal 3 $emptyRun.ExitCode 'an unavailable source with no rows never passes clear-all'
    $emptyDocument = $emptyRun.StdoutText | ConvertFrom-Json
    Expect-Equal 'unavailable' ([string]$emptyDocument.sourceStatus) 'the source reports its own status'
    Expect-Equal 0 $emptyDocument.summary.total 'no row is invented to carry the status'
    Expect-Equal $false ([bool]$emptyDocument.pass) 'the empty unavailable source does not pass'
    $emptyMd = Invoke-Script -Path $compareHelper -Arguments @('-Project', $emptyProject, '-Baseline', 'B1', '-Md')
    Expect-True $emptyMd.StdoutText.Contains('Source: unavailable') 'the Markdown carries the source status'
    Expect-True $emptyMd.StdoutText.Contains('| unavailable |') 'the empty table says why it is empty'

    # A source that did run and genuinely found nothing keeps its pass.
    $cleanProject = Join-Path $root 'tool-clean-empty'
    $cleanNs = New-EvidenceProject $cleanProject
    $null = Add-Finding -Project $cleanProject -Json (New-BaselineJson -Id 'B1' -Environment 'env-1')
    Write-PolicyFile -NightshiftDir $cleanNs -CompletionMode 'clear-all'
    $cleanRun = Invoke-Script -Path $compareHelper -Arguments @('-Project', $cleanProject, '-Baseline', 'B1', '-Json')
    Expect-Equal 0 $cleanRun.ExitCode 'a source that ran and found nothing still passes'
    $cleanDocument = $cleanRun.StdoutText | ConvertFrom-Json
    Expect-Equal 'available' ([string]$cleanDocument.sourceStatus) 'a source that ran reports available'

    # === 5. A moved environment digest is not a comparison ===
    $envProject = Join-Path $root 'environment'
    $null = New-EvidenceProject $envProject
    $null = Add-Finding -Project $envProject -Json (New-BaselineJson -Id 'B1' -Environment 'env-1' `
            -Seen @("F-cleared=$digestCleared"))
    $null = Add-Finding -Project $envProject -Json (New-BaselineJson -Id 'B2' -Environment 'env-2' `
            -Seen @("F-cleared=$digestCleared"))
    $null = Add-Finding -Project $envProject -Json (New-FindingJson -Id 'F-cleared' -Digest $digestCleared -Status 'fixed')
    $envRun = Invoke-Script -Path $compareHelper -Arguments @('-Project', $envProject, '-Baseline', 'B1', '-Json')
    Expect-Equal 3 $envRun.ExitCode 'a moved environment digest never passes clear-all'
    $envDocument = $envRun.StdoutText | ConvertFrom-Json
    Expect-Equal 'unavailable' (Get-RowClass $envDocument 'F-cleared') `
        'a changed environment digest is reported as unavailable, never as improvement'

    $envAbsenceProject = Join-Path $root 'environment-absence'
    $null = New-EvidenceProject $envAbsenceProject
    $null = Add-Finding -Project $envAbsenceProject -Json (New-BaselineJson -Id 'B1' -Environment 'env-1' `
            -Seen @("F-gone=$digestCleared"))
    $null = Add-Finding -Project $envAbsenceProject -Json (New-BaselineJson -Id 'B2' -Environment 'env-2')
    $envAbsenceRun = Invoke-Script -Path $compareHelper -Arguments @('-Project', $envAbsenceProject, '-Baseline', 'B1', '-Json')
    Expect-Equal 3 $envAbsenceRun.ExitCode 'environment-moved absence never passes clear-all'
    $envAbsenceDocument = $envAbsenceRun.StdoutText | ConvertFrom-Json
    Expect-Equal 'unavailable' (Get-RowClass $envAbsenceDocument 'F-gone') `
        'environment-moved absence is unavailable, never cleared'
    Expect-Equal 0 $envAbsenceDocument.summary.cleared 'environment-moved absence clears nothing'

    # === 6. The validator accepts the two new policy fields, and only these values ===
    $policyProject = Join-Path $root 'policy'
    $policyNs = New-EvidenceProject $policyProject
    $goodPolicy = Join-Path $root 'good-policy.json'
    Write-PolicyFile -NightshiftDir $policyNs -CompletionMode 'no-regression-plus-selected-debt' -SelectedDebt @('F-one', 'F-two')
    Copy-Item -LiteralPath (Join-Path $policyNs 'shift-policy.json') -Destination $goodPolicy -Force
    Remove-Item -LiteralPath (Join-Path $policyNs 'shift-policy.json') -Force
    $setGood = Invoke-Script -Path $policyHelper -Arguments @('-Project', $policyProject, 'set', '-FromJson', $goodPolicy)
    Expect-Equal 0 $setGood.ExitCode "the validator accepts completionMode and selectedDebt ($($setGood.StderrText))"

    $badMode = New-NSOrdinalMap
    $badMode['schemaVersion'] = 1
    $badMode['shiftId'] = '0123456789abcdef'
    $badMode['createdAt'] = $fixedNow
    $badMode['source'] = 'composition'
    $badMode['verificationLevel'] = 'final'
    $badMode['toolingPolicy'] = 'existing-tools'
    $badMode['completionMode'] = 'clear-most'
    $badModePath = Join-Path $root 'bad-mode.json'
    [IO.File]::WriteAllText($badModePath, ((ConvertTo-NSCanonicalJson $badMode) + "`n"), $utf8)
    Remove-Item -LiteralPath (Join-Path $policyNs 'shift-policy.json') -Force -ErrorAction SilentlyContinue
    $setBadMode = Invoke-Script -Path $policyHelper -Arguments @('-Project', $policyProject, 'set', '-FromJson', $badModePath)
    Expect-Equal 2 $setBadMode.ExitCode 'an unknown completionMode is a contract failure'
    Expect-True $setBadMode.StderrText.Contains('completionMode: must be one of clear-all, no-regression-plus-selected-debt') `
        'the validator names the accepted completion modes'

    $badDebt = Copy-NSMap $badMode
    $badDebt['completionMode'] = 'clear-all'
    $badDebt['selectedDebt'] = 'F-one'
    $badDebtPath = Join-Path $root 'bad-debt.json'
    [IO.File]::WriteAllText($badDebtPath, ((ConvertTo-NSCanonicalJson $badDebt) + "`n"), $utf8)
    $setBadDebt = Invoke-Script -Path $policyHelper -Arguments @('-Project', $policyProject, 'set', '-FromJson', $badDebtPath)
    Expect-Equal 2 $setBadDebt.ExitCode 'a selectedDebt that is not an array is a contract failure'
    Expect-True $setBadDebt.StderrText.Contains('selectedDebt: must be an array of finding ids') `
        'the validator names the selectedDebt shape'

    # resolve reports settings with precedence; the completion mode is not one of
    # them and must never appear in the resolved view.
    $resolveRun = Invoke-Script -Path $policyHelper -Arguments @('-Project', $policyProject, 'resolve', '-Json')
    Expect-Equal 0 $resolveRun.ExitCode "resolve still succeeds ($($resolveRun.StderrText))"
    Expect-True (-not $resolveRun.StdoutText.Contains('completionMode')) 'resolve does not report completionMode'
    Expect-True (-not $resolveRun.StdoutText.Contains('selectedDebt')) 'resolve does not report selectedDebt'

    # === 7. The runtime helpers stay native ===
    foreach ($script in @($ledger, $compareHelper)) {
        $text = [IO.File]::ReadAllText($script)
        Expect-True (-not $text.Contains('python')) "$([IO.Path]::GetFileName($script)) names no python interpreter"
        Expect-True (-not $text.Contains('jq ')) "$([IO.Path]::GetFileName($script)) names no jq"
    }

    # === 8. Byte parity with the bash helper ===
    if ((Test-Path -LiteralPath $bashCompare -PathType Leaf) -and $null -ne $bashCommand) {
        foreach ($format in @('--json', '--md')) {
            $bashRun = Invoke-ProcessBytes -FileName $bashCommand.Source `
                -Arguments @($bashCompare, '--project', $project, '--baseline', 'B1', $format) `
                -EnvOverrides @{ NIGHTSHIFT_EVIDENCE_NOW = $fixedNow }
            $nativeFormat = '-Md'
            if ($format -ceq '--json') { $nativeFormat = '-Json' }
            $native = Invoke-Script -Path $compareHelper `
                -Arguments @('-Project', $project, '-Baseline', 'B1', $nativeFormat)
            Expect-True (Test-NSBytesEqual $native.StdoutBytes $bashRun.StdoutBytes) `
                "the native comparison and the bash helper are byte-identical for $format"
            Expect-Equal $native.ExitCode $bashRun.ExitCode "the two helpers agree on the exit code for $format"
        }
    }
    else {
        Write-Host 'skip: runtime/evidence-compare.sh or bash not available; parity leg not run'
    }
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures.Count -gt 0) {
    Write-Host "evidence-compare-logic failed ($($failures.Count)):"
    foreach ($failure in $failures) { Write-Host " - $failure" }
    exit 1
}
Write-Host 'evidence-compare-logic passed'
exit 0
