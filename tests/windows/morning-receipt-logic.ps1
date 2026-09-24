# Portable PowerShell coverage for the native Windows morning receipt.
# Run on macOS or Windows: pwsh -File tests/windows/morning-receipt-logic.ps1
#
# Covers the receipt interface: every section in order, the four views,
# the three lines that always appear in section 1, the zero-gate render with no
# ledger, an artifact view free of repository terms, every table row citing a
# record id, a disabled check never rendered as a check that passed, the file
# the clock-out gate writes, the archive move, and byte parity with the bash
# renderer when it is on the branch.
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if (Test-Path Variable:PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $false
}

$repository = Resolve-Path (Join-Path $PSScriptRoot '../..')
$plugin = Join-Path $repository 'plugins/nightshift'
$ledger = Join-Path $plugin 'runtime/windows/evidence.ps1'
$receiptHelper = Join-Path $plugin 'runtime/windows/morning-receipt.ps1'
$archiveHelper = Join-Path $plugin 'runtime/windows/archive-receipts.ps1'
$gate = Join-Path $plugin 'hooks/windows/clock-out-gate.ps1'
$bashReceipt = Join-Path $plugin 'runtime/morning-receipt.sh'
$punchTemplate = Join-Path $plugin 'skills/nightshift/references/templates/punch-list.md'
$parkingTemplate = Join-Path $plugin 'skills/nightshift/references/templates/parking-lot.md'
$hostExecutable = (Get-Process -Id $PID).Path
$failures = New-Object 'System.Collections.Generic.List[string]'
$utf8 = New-Object Text.UTF8Encoding($false)
$fixedNow = '2026-09-02T00:00:00Z'
$shiftId = '0123456789abcdef'

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
    # Raw bytes, never PowerShell's native-command pipeline: LF-only and
    # single-trailing-newline are byte claims and must be read as bytes.
    param(
        [Parameter(Mandatory = $true)][string]$FileName,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [AllowEmptyString()][string]$InputText = '',
        [hashtable]$EnvOverrides
    )
    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $FileName
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
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
    if (-not [string]::IsNullOrEmpty($InputText)) { $process.StandardInput.Write($InputText) }
    $process.StandardInput.Close()
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
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [AllowEmptyString()][string]$InputText = '',
        [hashtable]$Environment = @{}
    )
    $psArgs = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $Path) + $Arguments
    $overrides = @{ NIGHTSHIFT_EVIDENCE_NOW = $fixedNow }
    foreach ($key in $Environment.Keys) { $overrides[[string]$key] = [string]$Environment[$key] }
    return Invoke-ProcessBytes -FileName $hostExecutable -Arguments $psArgs -InputText $InputText -EnvOverrides $overrides
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

function Get-NSReceiptWorkTargetLine {
    param([string]$Text)
    foreach ($line in ($Text -split "`n")) {
        if ($line.StartsWith('- Work target: ')) { return $line }
    }
    return ''
}

function Get-NSReceiptLinesOnlyIn {
    param([string]$Left, [string]$Right)
    $inRight = @{}
    foreach ($line in ($Right -split "`n")) { $inRight[$line] = $true }
    $only = New-Object Collections.Generic.List[string]
    foreach ($line in ($Left -split "`n")) {
        if (-not $inRight.ContainsKey($line)) { $only.Add($line) }
        if ($only.Count -ge 6) { break }
    }
    return ($only -join ' || ')
}

function Expect-NSRendererParity {
    param($Native, $Bash, [string]$Message)
    if ($Bash.ExitCode -ne 0) {
        Expect-True $false "$Message (bash exit=$($Bash.ExitCode) stderr=$($Bash.StderrText))"
        return
    }
    if (Test-NSBytesEqual $Native.StdoutBytes $Bash.StdoutBytes) { return }
    Expect-True $false ("$Message (nativeLen=$($Native.StdoutBytes.Length) bashLen=$($Bash.StdoutBytes.Length) " +
        "nativeWork='$(Get-NSReceiptWorkTargetLine $Native.StdoutText)' bashWork='$(Get-NSReceiptWorkTargetLine $Bash.StdoutText)' " +
        "nativeOnly='$(Get-NSReceiptLinesOnlyIn $Native.StdoutText $Bash.StdoutText)' " +
        "bashOnly='$(Get-NSReceiptLinesOnlyIn $Bash.StdoutText $Native.StdoutText)')")
}

function Get-SectionOrder {
    param([Parameter(Mandatory = $true)][string]$Text)
    $found = New-Object Collections.Generic.List[string]
    foreach ($line in ($Text -split "`n")) {
        if ($line.StartsWith('## ')) { $found.Add($line.Substring(3)) }
    }
    return (($found) -join '|')
}

function New-ReceiptProject {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$WorkMode = 'repository',
        [string]$VerificationLevel = 'final',
        [string]$Gates = '`npm run lint`',
        [string]$Items = "- [x] Quiet the lint rule`n- [ ] Rewrite the import map`n",
        [string]$Parking = "- Ship the import map rewrite behind a flag`n  - Default: flag off`n  - Rollback: revert the flag commit`n",
        [bool]$WithPolicy = $true
    )
    $ns = Join-Path $Path '.nightshift'
    $null = New-Item -ItemType Directory -Path $ns -Force
    [IO.File]::WriteAllText((Join-Path $ns 'state-version'), "1`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $ns 'work-mode'), ($WorkMode + "`n"), $utf8)
    [IO.File]::WriteAllText((Join-Path $ns 'work-target'), ($Path + "`n"), $utf8)
    $punch = "# Punch List`n`n## Gates`n`n- Item gate: $Gates`n`n## Items`n`n$Items"
    [IO.File]::WriteAllText((Join-Path $ns 'punch-list.md'), $punch, $utf8)
    [IO.File]::WriteAllText((Join-Path $ns 'parking-lot.md'), ("# Parking Lot`n`n---`n`n" + $Parking), $utf8)
    [IO.File]::WriteAllText((Join-Path $ns 'shift-log.md'), "2026-09-02 03:14:15 - shift done: 1/2`n", $utf8)
    $null = New-Item -ItemType Directory -Path (Join-Path $ns 'receipts') -Force
    if ($WithPolicy) {
        $policy = New-NSOrdinalMap
        $policy['schemaVersion'] = 1
        $policy['shiftId'] = $shiftId
        $policy['createdAt'] = '2020-01-01T00:00:00Z'
        $policy['source'] = 'composition'
        $policy['verificationLevel'] = $VerificationLevel
        $policy['toolingPolicy'] = 'existing-tools'
        $allowance = New-NSOrdinalMap
        $allowance['category'] = 'containers'
        $allowance['scope'] = 'category'
        $allowance['provenance'] = 'one-shift'
        $policy['allowances'] = @($allowance)
        [IO.File]::WriteAllText((Join-Path $ns 'shift-policy.json'),
            ((ConvertTo-NSCanonicalJson $policy) + "`n"), $utf8)
    }
    return $ns
}

function New-FindingJson {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$Digest,
        [string]$Status = 'open',
        [string]$Ladder = 'observed',
        [string]$Locator = 'src/app.js',
        [string]$Fix = '',
        [string]$VerificationLocator = '',
        [string]$Source = 'npm run lint'
    )
    $record = New-NSOrdinalMap
    $record['schemaVersion'] = 1
    $record['id'] = $Id
    $record['domain'] = 'quality'
    $record['sourceClass'] = 'lint'
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
    $record['disposition'] = ''
    $record['rollback'] = ''
    return (ConvertTo-NSCanonicalJson $record -Compact)
}

function New-BaselineJson {
    # A baseline record as the model writes one through the ledger.
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$Environment,
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
        $entry['digest'] = if ($at -ge 0) { $pair.Substring($at + 1) } else { '' }
        $entry['id'] = if ($at -ge 0) { $pair.Substring(0, $at) } else { $pair }
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
    $record['status'] = 'open'
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

$digestCleared = 'c' * 64
$digestUnchanged = 'u' * 64
$dash = [string][char]0x2014

$root = Join-Path ([IO.Path]::GetTempPath()) ("ns-morning-receipt-" + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $root -Force
$bashCommand = Get-Command bash -ErrorAction SilentlyContinue

try {
    # === 1. The owner view: every section in order, every row cited ===
    $project = Join-Path $root 'owner'
    $ns = New-ReceiptProject -Path $project
    & git -C $project init --quiet
    & git -C $project -c user.name=nightshift -c user.email=nightshift@localhost `
        -c commit.gpgsign=false commit -q --allow-empty -m 'chore: fixture commit'
    $opportunity = "# Opportunity map`n`n## Opportunities`n`n### Import map rewrite`nStatus: building`nNext: split the vendor chunk`n"
    [IO.File]::WriteAllText((Join-Path $ns 'opportunity-map.md'), $opportunity, $utf8)

    $baselineRun = Add-Finding -Project $project -Json (New-BaselineJson -Id 'B1' -Environment 'env-1' `
            -Seen @("F-cleared=$digestCleared", "F-unchanged=$digestUnchanged"))
    Expect-Equal 0 $baselineRun.ExitCode "the fixture baseline is written ($($baselineRun.StderrText))"
    $null = Add-Finding -Project $project -Json (New-FindingJson -Id 'F-cleared' -Digest $digestCleared `
            -Status 'fixed' -Ladder 'verified-after-change' -Fix 'fix(lint): quiet the rule' -VerificationLocator 'npm run lint')
    $null = Add-Finding -Project $project -Json (New-FindingJson -Id 'F-unchanged' -Digest $digestUnchanged)
    $null = Add-Finding -Project $project -Json (New-FindingJson -Id 'F-manual' -Digest ('d' * 64) `
            -Status 'human-only' -Locator 'docs/contrast.md')
    $null = Add-Finding -Project $project -Json (New-FindingJson -Id 'F-nogo' -Digest ('n' * 64) `
            -Status 'unavailable' -Source 'npm run audit')

    $ownerRun = Invoke-Script -Path $receiptHelper -Arguments @('-Project', $project)
    Expect-Equal 0 $ownerRun.ExitCode "the owner view renders ($($ownerRun.StderrText))"
    Expect-True (Test-NSNoCarriageReturn $ownerRun.StdoutBytes) 'the receipt has no CR bytes (LF only)'
    Expect-True (Test-NSSingleTrailingNewline $ownerRun.StdoutBytes) 'the receipt ends with exactly one LF'
    Expect-True (-not (Test-NSHasBom $ownerRun.StdoutBytes)) 'the receipt has no BOM'
    $owner = $ownerRun.StdoutText
    Expect-True $owner.StartsWith('# Morning receipt') 'the receipt names itself'
    Expect-Equal 'How it ended|Items|Review first|Decisions for you|Baseline|What changed|Unsupported / unmeasured|Next step' (Get-SectionOrder $owner) `
        'the owner view renders every section in interface order'

    Expect-True $owner.Contains("Receipts:`n- [index](./README.md)`n- Policy record: accepted") `
        'the page links the index'
    Expect-True $owner.Contains("## Items`n`n- Quiet the lint rule $dash ticked`n- Rewrite the import map $dash open`n") `
        'every item has its line with its state'
    Expect-True $owner.Contains('- Policy record: accepted') 'an accepted policy is named at the top'
    Expect-True $owner.Contains("- Shift: $shiftId") 'section 1 names the shift'
    Expect-True $owner.Contains('- Ending: unknown') 'an open punch list with no STOP is never reported as done'
    Expect-True $owner.Contains('- Items: 1 ticked, 1 open') 'section 1 counts ticked and open items'
    Expect-True $owner.Contains('- Started: 2020-01-01T00:00:00Z') 'section 1 takes the start from the policy that ran'
    Expect-True (-not $owner.Contains('- Ended:')) 'a shift that has not ended names no end'
    Expect-True $owner.Contains('- Policy: profile fast, verification final, tooling existing-tools') `
        'section 1 renders the policy that ran'
    Expect-True $owner.Contains('- Allowance: containers (category, one-shift)') 'every allowance carries its provenance'
    Expect-True $owner.Contains('- Commits: 1') 'repository mode counts the commits since the shift started'
    Expect-True $owner.Contains('- Verified: npm run lint') 'section 1 names what ran green by command'
    Expect-True $owner.Contains('- Disabled by owner: none') 'a shift with a live gate cadence disables nothing'
    Expect-True $owner.Contains('- Unavailable: npm run audit') 'section 1 names the unavailable source'

    Expect-True $owner.Contains('- B1: lint `npm run lint`') 'section 2 names the baseline source and command'
    Expect-True $owner.Contains('| ID | Class | Digest | Sources | Locator |') 'section 3 carries the comparison table'
    Expect-True $owner.Contains('| F-cleared | cleared |') 'section 3 classifies the cleared finding'
    Expect-True $owner.Contains('| F-unchanged | unchanged |') 'section 3 classifies the unchanged finding'
    Expect-True $owner.Contains('- F-cleared: fix(lint): quiet the rule') 'section 3 names the commit that landed the fix'
    Expect-True $owner.Contains('- Ship the import map rewrite behind a flag') 'section 4 lists the parked decision'
    Expect-True $owner.Contains('  - Default: flag off') 'a parked decision carries its default'
    Expect-True $owner.Contains('  - Rollback: revert the flag commit') 'a parked decision carries its rollback'
    Expect-True $owner.Contains('- F-manual: human-only') 'section 5 lists the human-only surface'
    Expect-True $owner.Contains('- Rewrite the import map') 'section 6 lists the open punch-list item'
    Expect-True $owner.Contains('- Building: Import map rewrite') 'section 6 names the building opportunity'
    Expect-True $owner.Contains('next: split the vendor chunk') 'section 6 carries the exact next action'

    # Every row in the table is a record id, so nothing in the receipt lacks a
    # source record.
    $tableRows = @()
    foreach ($line in ($owner -split "`n")) {
        if ($line.StartsWith('| ') -and -not $line.StartsWith('| ID ') -and -not $line.StartsWith('| --- ')) {
            $tableRows += , $line
        }
    }
    Expect-True ($tableRows.Count -gt 0) 'the comparison table has rows'
    $cited = $true
    foreach ($line in $tableRows) {
        $id = ($line -split '\|')[1].Trim()
        if (-not $id.StartsWith('F-')) { $cited = $false }
    }
    Expect-True $cited 'every comparison row cites a record id'

    # === 2. The views ===
    $reviewerRun = Invoke-Script -Path $receiptHelper -Arguments @('-Project', $project, '-View', 'reviewer')
    Expect-Equal 0 $reviewerRun.ExitCode "the reviewer view renders ($($reviewerRun.StderrText))"
    Expect-Equal 'Review first|Baseline|What changed' (Get-SectionOrder $reviewerRun.StdoutText) `
        'the reviewer view renders the baseline and the comparison'
    Expect-True $reviewerRun.StdoutText.Contains('| F-cleared | cleared |') 'the reviewer view keeps the locators'

    $releaseRun = Invoke-Script -Path $receiptHelper -Arguments @('-Project', $project, '-View', 'release')
    Expect-Equal 0 $releaseRun.ExitCode "the release view renders ($($releaseRun.StderrText))"
    Expect-Equal 'How it ended|What changed' (Get-SectionOrder $releaseRun.StdoutText) `
        'the release view renders the shift and the comparison'
    Expect-True (-not $releaseRun.StdoutText.Contains('| F-unchanged |')) 'the release view carries regressions only'

    $artifactProject = Join-Path $root 'artifact'
    $artifactNs = New-ReceiptProject -Path $artifactProject -WorkMode 'artifact' `
        -Parking "- Ship the import map rewrite behind a flag`n  - Default: flag off`n  - Rollback: restore the previous receipt`n"
    [IO.File]::WriteAllText((Join-Path $artifactNs 'receipts/2026-09-02-quiet-the-rule.md'), "# Receipt`n", $utf8)
    $artifactRun = Invoke-Script -Path $receiptHelper -Arguments @('-Project', $artifactProject, '-View', 'artifact')
    Expect-Equal 0 $artifactRun.ExitCode "the artifact view renders ($($artifactRun.StderrText))"
    Expect-Equal 'How it ended|Items|Review first|Decisions for you|Next step' (Get-SectionOrder $artifactRun.StdoutText) `
        'the artifact view omits the repository sections'
    Expect-True $artifactRun.StdoutText.Contains('- Receipts: 1') 'the artifact view counts receipts, never commits'
    foreach ($term in @('Commits:', 'commit', 'HEAD', 'git ', 'branch')) {
        Expect-True (-not $artifactRun.StdoutText.Contains($term)) "the artifact view names no repository term ($term)"
    }

    # === 3. A zero-gate fast shift with no ledger ===
    $fastProject = Join-Path $root 'fast'
    $null = New-ReceiptProject -Path $fastProject -VerificationLevel 'none' -Gates '`npm test`' `
        -Items "- [x] Tidy the changelog`n"
    $fastRun = Invoke-Script -Path $receiptHelper -Arguments @('-Project', $fastProject)
    Expect-Equal 0 $fastRun.ExitCode "a shift with no ledger still renders ($($fastRun.StderrText))"
    $fast = $fastRun.StdoutText
    Expect-True $fast.Contains("- Verified: none $dash verification level none (owner)") `
        'a zero-gate shift says nothing was verified and why'
    Expect-True $fast.Contains('- Disabled by owner: npm test') `
        'a check the level skipped is reported as disabled, never as passed'
    Expect-True (-not $fast.Contains('## Baseline')) 'a shift with no ledger omits the baseline section'
    Expect-True (-not $fast.Contains('## What changed')) 'a shift with no ledger omits the comparison section'
    Expect-True $fast.Contains('- Ending: done') 'a punch list with every box ticked ends done'
    Expect-True (-not $fast.Contains('- Verified: npm test')) 'a disabled check is never rendered as a check that passed'

    # === 3b. A shift that wrote no policy ===
    # The punch list's own Gates section is the shift's gate, and the owner
    # disabled nothing, so the receipt says so both ways round.
    $plainProject = Join-Path $root 'plain-start'
    $null = New-ReceiptProject -Path $plainProject -Gates '`npm test`' `
        -Items "- [x] Tidy the changelog`n" -WithPolicy $false
    & git -C $plainProject init --quiet
    & git -C $plainProject -c user.name=nightshift -c user.email=nightshift@localhost `
        commit --allow-empty --quiet -m 'init'
    $plainRun = Invoke-Script -Path $receiptHelper -Arguments @('-Project', $plainProject)
    Expect-Equal 0 $plainRun.ExitCode "a shift with no policy renders ($($plainRun.StderrText))"
    $plain = $plainRun.StdoutText
    Expect-True $plain.Contains("Receipts:`n- [index](./README.md)`n- Policy record: absent") `
        'a shift with no policy still links the index'
    Expect-True $plain.Contains("- Tidy the changelog $dash ticked") 'a shift with no policy still lists every item'
    Expect-True $plain.Contains("- Policy record: absent $dash the shift wrote no policy") `
        'a missing file is named as absent, not as malformed'
    Expect-True $plain.Contains('- Gates: npm test (punch list)') `
        'a shift with no policy names the punch-list gates as its gate'
    Expect-True $plain.Contains("- Verified: none $dash no shift policy was written") `
        'a shift with no policy says why nothing was verified'
    Expect-True $plain.Contains('- Disabled by owner: none') `
        'a shift with no policy credits the owner with disabling nothing'
    if ((Test-Path -LiteralPath $bashReceipt -PathType Leaf) -and $null -ne $bashCommand) {
        $plainBash = Invoke-ProcessBytes -FileName $bashCommand.Source `
            -Arguments @($bashReceipt, '--project', $plainProject, '--view', 'owner') `
            -EnvOverrides @{
                NIGHTSHIFT_EVIDENCE_NOW = $fixedNow
                LANG                    = 'C.UTF-8'
                LC_ALL                  = 'C.UTF-8'
                MSYS_NO_PATHCONV        = '1'
                MSYS2_ARG_CONV_EXCL     = '*'
            }
        Expect-NSRendererParity $plainRun $plainBash 'both renderers report a policy-free shift the same way'
    }

    # The gate names that receipt for the date alone: there is no shift id.
    $plainGateProject = Join-Path $root 'plain-gate'
    $plainGateNs = New-ReceiptProject -Path $plainGateProject -Items "- [x] Quiet the lint rule`n" `
        -WithPolicy $false
    [IO.File]::WriteAllText((Join-Path $plainGateNs '.shift-armed'), '', $utf8)
    [IO.File]::WriteAllText((Join-Path $plainGateNs 'STOP'), "owner`n", $utf8)
    $plainGateRun = Invoke-Script -Path $gate -Arguments @('-HostName', 'claude') `
        -InputText ('{"session_id":"11111111-2222-3333-4444-555555555555","cwd":"' + ($plainGateProject -replace '\\', '/') + '"}') `
        -Environment @{ CLAUDE_PROJECT_DIR = $plainGateProject }
    Expect-Equal 0 $plainGateRun.ExitCode "the gate answers without a policy ($($plainGateRun.StderrText))"
    Expect-True (Test-Path -LiteralPath (Join-Path $plainGateNs 'receipts/morning-2026-09-02.md') -PathType Leaf) `
        'a shift with no policy files receipts/morning-<date>.md'
    Expect-True (-not (Test-Path -LiteralPath (Join-Path $plainGateNs 'receipts/morning-2026-09-02-unknown.md') -PathType Leaf)) `
        'no receipt is filed under an invented shift id'

    # === 3c. Valid, absent, and malformed policy fixtures — same facts on both hosts ===
    $fixtureDir = Join-Path $repository 'tests/fixtures/morning-receipt'
    $receiptsLine = "Receipts:`n- [index](./README.md)`n- Policy record: "
    $itemLine = "- 2. Make the packed Node-only build reproducible. $dash ticked"
    $malformedReason = "the policy file is present but unreadable or fails the schema"
    foreach ($case in @(
            @{ Name = 'accepted'; File = 'shift-policy-valid.json' },
            @{ Name = 'absent'; File = '' },
            @{ Name = 'unreadable'; File = 'shift-policy-malformed.json' },
            @{ Name = 'schema-fail'; File = 'shift-policy-schema-fail.json' }
        )) {
        $fixProject = Join-Path $root ("policy-" + $case.Name)
        $fixNs = New-ReceiptProject -Path $fixProject -Items '' -WithPolicy $false
        [IO.File]::WriteAllText((Join-Path $fixNs 'punch-list.md'),
            ([IO.File]::ReadAllText((Join-Path $fixtureDir 'punch-list.md'))), $utf8)
        if (-not [string]::IsNullOrEmpty($case.File)) {
            [IO.File]::WriteAllText((Join-Path $fixNs 'shift-policy.json'),
                ([IO.File]::ReadAllText((Join-Path $fixtureDir $case.File))), $utf8)
        }
        $fixRun = Invoke-Script -Path $receiptHelper -Arguments @('-Project', $fixProject, '-View', 'owner')
        Expect-Equal 0 $fixRun.ExitCode "the $($case.Name) policy fixture renders ($($fixRun.StderrText))"
        Expect-True $fixRun.StdoutText.Contains($receiptsLine) `
            "the $($case.Name) fixture links the index"
        Expect-True $fixRun.StdoutText.Contains($itemLine) `
            "the $($case.Name) fixture lists the ticked item"
        switch ($case.Name) {
            'accepted' {
                Expect-True $fixRun.StdoutText.Contains('- Policy record: accepted') `
                    'a validating policy is named as accepted'
                Expect-True $fixRun.StdoutText.Contains('- Shift: 9f2c40ab77e51d63') `
                    'an accepted policy supplies the shift id'
            }
            'absent' {
                Expect-True $fixRun.StdoutText.Contains("- Policy record: absent $dash the shift wrote no policy") `
                    'a missing file is named as absent'
                Expect-True $fixRun.StdoutText.Contains("- Verified: none $dash no shift policy was written") `
                    'an absent policy keeps the historical verified line'
            }
            default {
                # the unreadable fixture is named as malformed
                Expect-True $fixRun.StdoutText.Contains("- Policy record: malformed $dash $malformedReason") `
                    "the $($case.Name) fixture is named as malformed"
                Expect-True $fixRun.StdoutText.Contains("- Verified: none $dash $malformedReason") `
                    "the $($case.Name) fixture does not read as if nothing was written"
                Expect-True (-not $fixRun.StdoutText.Contains('no shift policy was written')) `
                    "the $($case.Name) fixture is not described as absent"
                Expect-True $fixRun.StdoutText.Contains('- Items: 1 ticked, 1 open') `
                    "a malformed policy still counts punch-list boxes ($($case.Name))"
            }
        }
        if ((Test-Path -LiteralPath $bashReceipt -PathType Leaf) -and $null -ne $bashCommand) {
            $fixBash = Invoke-ProcessBytes -FileName $bashCommand.Source `
                -Arguments @($bashReceipt, '--project', $fixProject, '--view', 'owner') `
                -EnvOverrides @{
                    NIGHTSHIFT_EVIDENCE_NOW = $fixedNow
                    LANG                    = 'C.UTF-8'
                    LC_ALL                  = 'C.UTF-8'
                    MSYS_NO_PATHCONV        = '1'
                    MSYS2_ARG_CONV_EXCL     = '*'
                }
            Expect-NSRendererParity $fixRun $fixBash "both renderers report the $($case.Name) policy the same way"
        }
    }

    # === 4. The endings ===
    [IO.File]::WriteAllText((Join-Path $ns 'STOP'), "deadline`n", $utf8)
    $deadlineRun = Invoke-Script -Path $receiptHelper -Arguments @('-Project', $project)
    Expect-True $deadlineRun.StdoutText.Contains('- Ending: deadline') 'quitting time is reported as the deadline ending'
    [IO.File]::WriteAllText((Join-Path $ns 'STOP'), "stalled`n", $utf8)
    $stallRun = Invoke-Script -Path $receiptHelper -Arguments @('-Project', $project)
    Expect-True $stallRun.StdoutText.Contains('- Ending: stall') 'an auto-ended stall is reported as the stall ending'
    [IO.File]::WriteAllText((Join-Path $ns 'STOP'), "stopped by owner $dash 2026-09-02T04:00:00Z`n", $utf8)
    $stopRun = Invoke-Script -Path $receiptHelper -Arguments @('-Project', $project)
    Expect-True $stopRun.StdoutText.Contains('- Ending: stop') 'a stop-work order is reported as the stop ending'
    Remove-Item -LiteralPath (Join-Path $ns 'STOP') -Force

    # === 5. -Out writes the file and prints its path ===
    $outPath = Join-Path $root 'out/receipt.md'
    $outRun = Invoke-Script -Path $receiptHelper -Arguments @('-Project', $project, '-Out', $outPath)
    Expect-Equal 0 $outRun.ExitCode "-Out writes the receipt ($($outRun.StderrText))"
    Expect-Equal $outPath $outRun.StdoutText.Trim() '-Out prints the path it wrote'
    Expect-True (Test-Path -LiteralPath $outPath -PathType Leaf) '-Out creates the file'
    $outBytes = [IO.File]::ReadAllBytes($outPath)
    Expect-True (Test-NSNoCarriageReturn $outBytes) 'the written receipt is LF only'
    Expect-True (-not (Test-NSHasBom $outBytes)) 'the written receipt has no BOM'
    Expect-True (Test-NSBytesEqual $outBytes $ownerRun.StdoutBytes) 'the written receipt is the owner view byte for byte'

    # === 6. The clock-out gate writes the receipt and never blocks on a render ===
    $gateProject = Join-Path $root 'gate'
    $gateNs = New-ReceiptProject -Path $gateProject -Items "- [x] Quiet the lint rule`n"
    [IO.File]::WriteAllText((Join-Path $gateNs '.shift-armed'), '', $utf8)
    [IO.File]::WriteAllText((Join-Path $gateNs 'STOP'), "owner`n", $utf8)
    $gateRun = Invoke-Script -Path $gate -Arguments @('-HostName', 'claude') `
        -InputText ('{"session_id":"11111111-2222-3333-4444-555555555555","cwd":"' + ($gateProject -replace '\\', '/') + '"}') `
        -Environment @{ CLAUDE_PROJECT_DIR = $gateProject }
    Expect-Equal 0 $gateRun.ExitCode "the gate answers ($($gateRun.StderrText))"
    Expect-True (-not $gateRun.StdoutText.Contains('"decision":"block"')) 'a ticked punch list releases the shift'
    $expectedReceipt = Join-Path $gateNs ('receipts/morning-2026-09-02-' + $shiftId + '.md')
    Expect-True (Test-Path -LiteralPath $expectedReceipt -PathType Leaf) `
        'the gate writes receipts/morning-<date>-<shiftId>.md at the end of the shift'
    if (Test-Path -LiteralPath $expectedReceipt -PathType Leaf) {
        $written = [IO.File]::ReadAllText($expectedReceipt)
        Expect-True $written.Contains('# Morning receipt') 'the gate writes the owner view'
        Expect-True $written.Contains("- Shift: $shiftId") 'the receipt the gate writes still names the policy that ran'
    }

    # A render that cannot succeed leaves no receipt and still releases: the
    # receipts path is a file, so nothing can be written under it.
    $blockedProject = Join-Path $root 'gate-blocked'
    $blockedNs = New-ReceiptProject -Path $blockedProject -Items "- [x] Quiet the lint rule`n"
    Remove-Item -LiteralPath (Join-Path $blockedNs 'receipts') -Recurse -Force
    [IO.File]::WriteAllText((Join-Path $blockedNs 'receipts'), "not a directory`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $blockedNs '.shift-armed'), '', $utf8)
    [IO.File]::WriteAllText((Join-Path $blockedNs 'STOP'), "owner`n", $utf8)
    $blockedRun = Invoke-Script -Path $gate -Arguments @('-HostName', 'claude') `
        -InputText ('{"session_id":"11111111-2222-3333-4444-555555555555","cwd":"' + ($blockedProject -replace '\\', '/') + '"}') `
        -Environment @{ CLAUDE_PROJECT_DIR = $blockedProject }
    Expect-Equal 0 $blockedRun.ExitCode 'a receipt render failure never fails the gate'
    Expect-True (-not $blockedRun.StdoutText.Contains('"decision":"block"')) 'a receipt render failure never blocks the release'
    Expect-True (Test-Path -LiteralPath (Join-Path $blockedNs '.ended') -PathType Leaf) `
        'a receipt render failure still clocks the shift out'

    # === 6c. How the receipts and handoff switches combine ===
    # One stop finds the first item ticked and holds for the second; the next finds both ticked
    # and clocks the shift out.
    $rulesTemplate = Join-Path $plugin 'skills/nightshift/references/nightshift-rules-template.json'
    $page = 'morning-2026-09-02-' + $shiftId + '.md'
    foreach ($combo in @(
            @{ Name = 'receipts-off'; Receipts = $false; Handoff = $true },
            @{ Name = 'handoff-off'; Receipts = $true; Handoff = $false },
            @{ Name = 'both-off'; Receipts = $false; Handoff = $false })) {
        $comboProject = Join-Path $root ('switch-' + $combo.Name)
        $comboNs = New-ReceiptProject -Path $comboProject -Items "- [x] Quiet the lint rule`n- [ ] Rewrite the import map`n"
        # The shipped template with only the two switches changed, byte for byte otherwise.
        $comboRules = [IO.File]::ReadAllText($rulesTemplate)
        foreach ($switch in @(@('receipts', $combo.Receipts), @('handoff', $combo.Handoff))) {
            $comboRules = [regex]::Replace($comboRules, ('("' + $switch[0] + '"\s*:\s*\{\s*"enabled"\s*:\s*)true'),
                ('${1}' + ([string]$switch[1]).ToLowerInvariant()))
        }
        [IO.File]::WriteAllText((Join-Path $comboNs 'rules.json'), $comboRules, $utf8)
        [IO.File]::WriteAllText((Join-Path $comboNs '.shift-armed'), '', $utf8)
        # Windows PowerShell 5.1 -File does not read redirected stdin as pipeline input, so the payload
        # goes in as -HookJson, the way the Windows suite runner passes it.
        $payload = '{"session_id":"11111111-2222-3333-4444-555555555555","cwd":"' + ($comboProject -replace '\\', '/') + '"}'
        $held = Invoke-Script -Path $gate -Arguments @('-HostName', 'claude', '-HookJson', $payload) `
            -Environment @{ CLAUDE_PROJECT_DIR = $comboProject }
        Expect-True ($held.StdoutText.Contains('"decision":"block"') -and -not $held.StdoutText.Contains('payload is unreadable')) `
            "$($combo.Name): an open item holds the shift ($($held.StdoutText.Trim()))"
        [IO.File]::WriteAllText((Join-Path $comboNs 'punch-list.md'),
            "# Punch List`n`n## Gates`n`n- Item gate: ``npm run lint```n`n## Items`n`n- [x] Quiet the lint rule`n- [x] Rewrite the import map`n", $utf8)
        $released = Invoke-Script -Path $gate -Arguments @('-HostName', 'claude', '-HookJson', $payload) `
            -Environment @{ CLAUDE_PROJECT_DIR = $comboProject }
        Expect-True (-not $released.StdoutText.Contains('"decision":"block"')) `
            "$($combo.Name): every box ticked releases the shift ($($released.StdoutText.Trim()) $($released.StderrText.Trim()))"
        $receiptsDir = Join-Path $comboNs 'receipts'
        $names = @(Get-ChildItem -LiteralPath $receiptsDir -File -Force -ErrorAction SilentlyContinue |
                ForEach-Object { $_.Name } | Sort-Object)
        switch ($combo.Name) {
            'receipts-off' {
                Expect-Equal $page ($names -join ',') 'receipts off: the page is written, with no item receipt or index beside it'
                if ($names -ccontains $page) {
                    Expect-True ([IO.File]::ReadAllText((Join-Path $receiptsDir $page)).Contains("- Quiet the lint rule $dash ticked")) `
                        'receipts off: the page still lists every item'
                }
            }
            'handoff-off' {
                Expect-True (($names -ccontains 'quiet-the-lint-rule.md') -and ($names -ccontains 'rewrite-the-import-map.md') -and
                    ($names -ccontains 'README.md')) 'handoff off: the item receipts and their index stand'
                Expect-True (-not ($names -ccontains $page)) 'handoff off: no page is written'
            }
            'both-off' {
                Expect-Equal 0 $names.Count 'both off: nothing is written under receipts/'
                Expect-True (Test-Path -LiteralPath (Join-Path $comboNs '.ended') -PathType Leaf) 'both off: the shift still clocks out'
            }
        }
    }

    # === 6b. An unreadable punch list is never reported as done ===
    $onWindows = $env:OS -eq 'Windows_NT'
    if (-not $onWindows) {
        $unreadProject = Join-Path $root 'unreadable-punch'
        $unreadNs = New-ReceiptProject -Path $unreadProject
        $unreadPunch = Join-Path $unreadNs 'punch-list.md'
        & chmod 000 $unreadPunch
        try {
            $unreadRun = Invoke-Script -Path $receiptHelper -Arguments @('-Project', $unreadProject)
            Expect-Equal 0 $unreadRun.ExitCode "an unreadable punch list still renders ($($unreadRun.StderrText))"
            Expect-True $unreadRun.StdoutText.Contains('- Ending: unknown') `
                'an unreadable punch list reports Ending unknown, never done'
            Expect-True (-not $unreadRun.StdoutText.Contains('- Ending: done')) `
                'an unreadable punch list is not reported as done'
        }
        finally {
            & chmod 644 $unreadPunch
        }
    }

    # === 7. A record is retired because its shift closed, not because of its name ===
    # While a shift is still armed nothing leaves live storage, whatever the file is called.
    $archiveProject = Join-Path $root 'archive'
    $archiveNs = New-ReceiptProject -Path $archiveProject
    $morning = Join-Path $archiveNs ('receipts/morning-2026-09-02-' + $shiftId + '.md')
    [IO.File]::WriteAllText($morning, "# Morning receipt`n", $utf8)
    $artifactReceipt = Join-Path $archiveNs 'receipts/2026-09-02-quiet-the-rule.md'
    [IO.File]::WriteAllText($artifactReceipt, "# Receipt`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $archiveNs '.shift-armed'), '', $utf8)
    $archiveRun = Invoke-Script -Path $archiveHelper -Arguments @('-Project', $archiveProject, '-Date', '2026-09-02')
    Expect-Equal 0 $archiveRun.ExitCode "archive-receipts exits 0 ($($archiveRun.StderrText))"
    $archivedMorning = Join-Path $archiveNs ('archive/2026-09-02/receipts/morning-2026-09-02-' + $shiftId + '.md')
    Expect-True (Test-Path -LiteralPath $archivedMorning -PathType Leaf) 'the morning receipt lands in the dated archive'
    Expect-True (Test-Path -LiteralPath $morning -PathType Leaf) `
        'an armed shift keeps every live record, whatever it is called'
    Expect-True (Test-Path -LiteralPath $artifactReceipt -PathType Leaf) `
        'an armed shift keeps its artifact receipts live'

    # Once the shift has ended, the records the caller established as closed are retired. An
    # ended shift is not on its own evidence that any particular record is finished with, so the
    # names are what decide it.
    Remove-Item -LiteralPath (Join-Path $archiveNs '.shift-armed') -Force
    [IO.File]::WriteAllText((Join-Path $archiveNs '.ended'), '', $utf8)
    $untoldRun = Invoke-Script -Path $archiveHelper -Arguments @('-Project', $archiveProject, '-Date', '2026-09-02')
    Expect-Equal 0 $untoldRun.ExitCode "archive-receipts exits 0 when told nothing ($($untoldRun.StderrText))"
    Expect-True (Test-Path -LiteralPath $morning -PathType Leaf) `
        'told nothing, an ended shift still keeps every live record'
    $closeRun = Invoke-Script -Path $archiveHelper -Arguments @(
        '-Project', $archiveProject, '-Date', '2026-09-02',
        '-Retire', (('morning-2026-09-02-' + $shiftId + '.md') + ',2026-09-02-quiet-the-rule.md'))
    Expect-Equal 0 $closeRun.ExitCode "archive-receipts exits 0 on a closed shift ($($closeRun.StderrText))"
    Expect-True (-not (Test-Path -LiteralPath $morning -PathType Leaf)) `
        'a closed and verified record leaves live storage'
    Expect-True (-not (Test-Path -LiteralPath $artifactReceipt -PathType Leaf)) `
        'the artifact receipt is retired on the same terms, not by its name'
    Expect-True (Test-Path -LiteralPath $archivedMorning -PathType Leaf) 'the archived copy is still there'

    # A different record under a name already filed is never overwritten, and never removed.
    $clashProject = Join-Path $root 'archive-clash'
    $clashNs = New-ReceiptProject -Path $clashProject
    $clashLive = Join-Path $clashNs 'receipts/2026-09-02-same-name.md'
    [IO.File]::WriteAllText($clashLive, "live content`n", $utf8)
    $clashDest = Join-Path $clashNs 'archive/2026-09-02/receipts'
    $null = New-Item -ItemType Directory -Path $clashDest -Force
    [IO.File]::WriteAllText((Join-Path $clashDest '2026-09-02-same-name.md'), "filed content`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $clashNs '.ended'), '', $utf8)
    $clashRun = Invoke-Script -Path $archiveHelper -Arguments @('-Project', $clashProject, '-Date', '2026-09-02')
    Expect-Equal 0 $clashRun.ExitCode "archive-receipts exits 0 on a name clash ($($clashRun.StderrText))"
    Expect-True (Test-Path -LiteralPath $clashLive -PathType Leaf) `
        'a live record whose name is already filed with other content is kept'
    Expect-Equal "filed content`n" ([IO.File]::ReadAllText((Join-Path $clashDest '2026-09-02-same-name.md'))) `
        'the record already filed is never overwritten'
    Expect-True (Test-Path -LiteralPath (Join-Path $archiveNs 'archive/2026-09-02/receipts/2026-09-02-quiet-the-rule.md') -PathType Leaf) `
        'artifact receipts are archived beside the morning receipt'

    # === 8. The templates still carry the headings the receipt parses ===
    $punchText = [IO.File]::ReadAllText($punchTemplate)
    Expect-True $punchText.Contains('## Gates') 'the punch-list template still carries the Gates heading'
    Expect-True $punchText.Contains('## Items') 'the punch-list template still carries the Items heading'
    Expect-True ([IO.File]::ReadAllText($parkingTemplate)).Contains('---') `
        'the parking-lot template still carries the rule the receipt reads past'

    # === 9. The renderer stays native ===
    $receiptText = [IO.File]::ReadAllText($receiptHelper)
    Expect-True (-not $receiptText.Contains('python')) 'morning-receipt.ps1 names no python interpreter'
    Expect-True (-not $receiptText.Contains('jq ')) 'morning-receipt.ps1 names no jq'

    # === 10. Byte parity with the bash renderer ===
    if ((Test-Path -LiteralPath $bashReceipt -PathType Leaf) -and $null -ne $bashCommand) {
        foreach ($view in @('owner', 'reviewer', 'release', 'artifact')) {
            $bashRun = Invoke-ProcessBytes -FileName $bashCommand.Source `
                -Arguments @($bashReceipt, '--project', $project, '--view', $view) `
                -EnvOverrides @{
                    NIGHTSHIFT_EVIDENCE_NOW = $fixedNow
                    LANG                    = 'C.UTF-8'
                    LC_ALL                  = 'C.UTF-8'
                    MSYS_NO_PATHCONV        = '1'
                    MSYS2_ARG_CONV_EXCL     = '*'
                }
            $nativeRun = Invoke-Script -Path $receiptHelper -Arguments @('-Project', $project, '-View', $view)
            Expect-NSRendererParity $nativeRun $bashRun `
                "the native renderer and the bash renderer are byte-identical for the $view view"
        }
    }
    else {
        Write-Host 'skip: runtime/morning-receipt.sh or bash not available; parity leg not run'
    }

    # === 11. The verdict: time and tokens, items, review, interruptions, decisions, snags ===
    $verdictProject = Join-Path $root 'verdict'
    $verdictNs = New-ReceiptProject -Path $verdictProject -WithPolicy $false `
        -Items ("- [x] **1. Add the parser.** <!-- id: a1b2 -->`n" +
            "- [x] **2. Wire the parser into the CLI.** <!-- id: c3d4 -->`n" +
            "- [ ] **3. Document the flags.** <!-- id: e5f6 -->`n") `
        -Parking ("- Ship the parser behind a flag because the CLI cannot complete anywhere but a`n" +
            "  POSIX shell today, and Windows users would see a broken command.`n" +
            "  - Default: flag off until the Windows path lands`n" +
            "  - Rollback: delete the flag`n" +
            "- [notice] 2026-09-24 03:00 $dash the shift session died and the watchman revived it.`n" +
            "- An answered question $([char]0x00b7) answered 2026-09-24`n")
    $middot = [string][char]0x00b7
    [IO.File]::WriteAllText((Join-Path $verdictNs 'receipts/a1b2-add-the-parser.md'), "# 1. Add the parser.`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $verdictNs 'snag-log.md'), ("# Snag Log`n`n---`n`n" +
            "- Old finding $middot evidence $middot rejected-because noisy $middot 2020-01-01`n" +
            "- Parser drops a trailing comma $middot tests/parse.bats $middot fixed in abc123 $middot 2026-09-24`n" +
            "- CLI help is stale $middot docs/cli.md $middot accepted-tradeoff renamed in item 3 $middot 2026-09-24`n" +
            "- Windows path untested $middot no pwsh on the runner`n  still open $middot 2026-09-24`n"), $utf8)
    [IO.File]::WriteAllText((Join-Path $verdictNs 'shift-log.md'), ("# Shift Log`n" +
            "2026-09-21 10:00:00 $middot watchman: site dead quiet mid-shift $dash resume attempt 1 (resume)`n" +
            "2026-09-21T14:12:20Z shift started $dash 3 items`n" +
            "2026-09-21 18:01:00 $middot watchman: site dead quiet mid-shift $dash resume attempt 1 (resume)`n" +
            "2026-09-21T18:05:00Z $middot item 1 done $dash install the parser`n" +
            "2026-09-21T19:00:00Z $middot handover $dash item 3 half done; next: write the flags table`n" +
            "2026-09-21 19:10:00 $middot stopped by owner`n"), $utf8)
    $now = 1790000000
    $usage = Join-Path $verdictNs 'usage'
    $null = New-Item -ItemType Directory -Path $usage -Force
    [IO.File]::WriteAllText((Join-Path $usage 'marks.tsv'), (
            "$now`tarm`t`n" +
            "$($now + 600)`t1. Add the parser.`tinput=100,output=50`ttick`n" +
            "$($now + 1800)`t2. Wire the parser into the CLI.`tinput=300,output=90`ttick`n" +
            "$($now + 3000)`t3. Document the flags.`tinput=400,output=120`tpause`n"), $utf8)
    [IO.File]::WriteAllText((Join-Path $usage 'pauses.tsv'), (
            "$($now + 700)`towner pressed Esc`n" +
            "$($now + 1000)`tthe session ended and the shift was revived`n" +
            "$($now + 2000)`towner pressed Esc`n"), $utf8)
    [IO.File]::WriteAllText((Join-Path $usage 'segments.tsv'),
        "claude-t1`tclaude`tclaude-opus-5-5`ttranscript-incremental`t10`tinput=0,output=0`tinput=400,cache_read=12000,output=120`t`n", $utf8)
    $policy = New-NSOrdinalMap
    $policy['schemaVersion'] = 1
    $policy['shiftId'] = $shiftId
    $policy['createdAt'] = '2026-09-21T14:12:20Z'
    $policy['source'] = 'composition'
    $policy['verificationLevel'] = 'final'
    $policy['toolingPolicy'] = 'existing-tools'
    [IO.File]::WriteAllText((Join-Path $verdictNs 'shift-policy.json'), ((ConvertTo-NSCanonicalJson $policy) + "`n"), $utf8)
    $ended = Join-Path $verdictNs '.ended'
    [IO.File]::WriteAllText($ended, "shiftId=$shiftId`n", $utf8)
    [IO.File]::SetLastWriteTimeUtc($ended, (New-Object DateTime 2026, 9, 21, 15, 10, 5, ([DateTimeKind]::Utc)))
    & git -C $verdictProject init --quiet
    $history = @(
        @{ At = $now - 100000; File = 'base.txt'; Lines = 1; Subject = 'chore: base' },
        @{ At = $now + 100; File = 'parser.js'; Lines = 40; Subject = 'feat: add the parser' },
        @{ At = $now + 500; File = 'parser.test.js'; Lines = 30; Subject = 'test: cover the parser' },
        @{ At = $now + 1200; File = 'cli.js'; Lines = 5; Subject = 'feat: wire the parser' },
        @{ At = $now + 3500; File = 'notes.md'; Lines = 200; Subject = 'docs: late notes' })
    foreach ($commit in $history) {
        $body = (1..$commit.Lines | ForEach-Object { "line $_" }) -join "`n"
        [IO.File]::WriteAllText((Join-Path $verdictProject $commit.File), ($body + "`n"), $utf8)
        & git -C $verdictProject add $commit.File
        $env:GIT_AUTHOR_DATE = "@$($commit.At) +0000"
        $env:GIT_COMMITTER_DATE = "@$($commit.At) +0000"
        try {
            & git -C $verdictProject -c user.name=nightshift -c user.email=nightshift@localhost `
                -c commit.gpgsign=false commit --quiet -m $commit.Subject
        }
        finally {
            Remove-Item Env:GIT_AUTHOR_DATE, Env:GIT_COMMITTER_DATE -ErrorAction SilentlyContinue
        }
    }
    $first = ([string](& git -C $verdictProject log --format=%h -n1 HEAD~3)).Trim()
    $last = ([string](& git -C $verdictProject log --format=%h -n1)).Trim()

    $verdictRun = Invoke-Script -Path $receiptHelper -Arguments @('-Project', $verdictProject)
    Expect-Equal 0 $verdictRun.ExitCode "the verdict renders ($($verdictRun.StderrText))"
    $verdict = $verdictRun.StdoutText
    Expect-Equal 'How it ended|Time and tokens|Items|Review first|Interruptions|Decisions for you|Found but not fixed|Next step' `
        (Get-SectionOrder $verdict) 'the verdict orders every section it has records for'
    Expect-True ($verdict.Contains('- Started: 2026-09-21T14:13:20Z') -and $verdict.Contains('- Ended: 2026-09-21T15:10:05Z')) `
        'both ends of the shift carry the zone'
    Expect-True $verdict.Contains(("- Working: 8m 25s`n- Paused: 48m 20s`n  - owner pressed Esc: 35m 0s`n" +
            "  - the session ended and the shift was revived: 13m 20s`n- Wall: 56m 45s")) `
        'pause reasons sum to the paused total'
    Expect-True ($verdict.Contains('| cache write | unavailable |') -and $verdict.Contains('| cache read | 12.0k |')) `
        'a kind the host did not report reads unavailable'
    Expect-True $verdict.Contains("- [1. Add the parser.](./a1b2-add-the-parser.md) $dash ticked`n- 2. Wire the parser into the CLI. $dash ticked") `
        'an item links to its receipt only when the file exists'
    Expect-True $verdict.Contains(("- ``$last`` docs: late notes $dash 1 file, 200 lines (+200/-0), 1 commit`n" +
            "- [1. Add the parser.](./a1b2-add-the-parser.md) $dash 2 files, 70 lines (+70/-0), 2 commits`n" +
            "- 2. Wire the parser into the CLI. $dash 1 file, 5 lines (+5/-0), 1 commit`n" +
            "- Whole range: ``git log --stat $first^..$last``")) 'review first ranks by change size'
    Expect-True ($verdict.Contains('resume attempt 1') -and -not $verdict.Contains('2026-09-21 10:00:00') -and
        -not $verdict.Contains('install the parser') -and $verdict.Contains('stopped by owner')) `
        'interruptions come from the shift log since the shift started'
    Expect-True $verdict.Contains(("- Ship the parser behind a flag because the CLI cannot complete anywhere but a POSIX shell today, " +
            "and Windows users would see a broken command.`n  - Default: flag off until the Windows path lands`n  - Rollback: delete the flag")) `
        'a wrapped parked entry renders in full'
    Expect-True (-not $verdict.Contains('[notice]') -and -not $verdict.Contains('An answered question')) `
        'notices and answered entries are not decisions'
    Expect-True $verdict.Contains("## Found but not fixed`n`n- CLI help is stale $dash accepted-tradeoff renamed in item 3`n- Windows path untested $dash open`n") `
        'found but not fixed lists only this shift''s unfixed snags'
    Expect-True $verdict.Contains("- Handover: 2026-09-21T19:00:00Z $middot handover $dash item 3 half done; next: write the flags table") `
        'next step carries the handover line'

    $offRules = Join-Path $verdictNs 'rules.json'
    $rules = ConvertFrom-NSJsonText ([IO.File]::ReadAllText(
            (Join-Path $plugin 'skills/nightshift/references/nightshift-rules-template.json')))
    $rules['receipts']['usage'] = 'off'
    $rules['receipts']['duration'] = 'off'
    [IO.File]::WriteAllText($offRules, ((ConvertTo-NSCanonicalJson $rules) + "`n"), $utf8)
    $offRun = Invoke-Script -Path $receiptHelper -Arguments @('-Project', $verdictProject)
    Expect-True $offRun.StdoutText.Contains("## Time and tokens`n`n- Time: off`n- Tokens: off`n") `
        'a measurement the owner turned off reads off'
    if ((Test-Path -LiteralPath $bashReceipt -PathType Leaf) -and $null -ne $bashCommand) {
        $offBash = Invoke-ProcessBytes -FileName $bashCommand.Source `
            -Arguments @($bashReceipt, '--project', $verdictProject, '--view', 'owner') `
            -EnvOverrides @{ LANG = 'C.UTF-8'; LC_ALL = 'C.UTF-8'; MSYS_NO_PATHCONV = '1'; MSYS2_ARG_CONV_EXCL = '*' }
        Expect-NSRendererParity $offRun $offBash 'both renderers report a measurement turned off the same way'
    }
    Remove-Item -LiteralPath $offRules -Force

    [IO.File]::WriteAllText((Join-Path $verdictNs 'work-mode'), "artifact`n", $utf8)
    $artifactVerdict = Invoke-Script -Path $receiptHelper -Arguments @('-Project', $verdictProject, '-View', 'artifact')
    Expect-True $artifactVerdict.StdoutText.Contains("## Review first`n`n- Does not apply: an artifact shift is reviewed through its receipts.`n") `
        'review first does not apply in artifact mode'
    [IO.File]::WriteAllText((Join-Path $verdictNs 'work-mode'), "repository`n", $utf8)
    if ((Test-Path -LiteralPath $bashReceipt -PathType Leaf) -and $null -ne $bashCommand) {
        foreach ($view in @('owner', 'reviewer', 'release', 'artifact')) {
            $bashRun = Invoke-ProcessBytes -FileName $bashCommand.Source `
                -Arguments @($bashReceipt, '--project', $verdictProject, '--view', $view) `
                -EnvOverrides @{ LANG = 'C.UTF-8'; LC_ALL = 'C.UTF-8'; MSYS_NO_PATHCONV = '1'; MSYS2_ARG_CONV_EXCL = '*' }
            $nativeRun = Invoke-Script -Path $receiptHelper -Arguments @('-Project', $verdictProject, '-View', $view)
            Expect-NSRendererParity $nativeRun $bashRun "both renderers write the same verdict for the $view view"
        }
    }
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures.Count -gt 0) {
    Write-Host "morning-receipt-logic failed ($($failures.Count)):"
    foreach ($failure in $failures) { Write-Host " - $failure" }
    exit 1
}
Write-Host 'morning-receipt-logic passed'
exit 0
