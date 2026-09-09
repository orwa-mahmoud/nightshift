# Portable PowerShell coverage for the native Windows permission preflight.
# Run on macOS or Windows: pwsh -File tests/windows/preflight-needs-logic.ps1
#
# The preflight reads the punch list and the work orders, matches each item
# against the same rules.elevation patterns the guard uses, and reports the gap.
# It reports; it never refuses and never writes. park-needs is the only writer,
# and it appends one entry per item and category, idempotently.
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if (Test-Path Variable:PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $false
}

$repository = Resolve-Path (Join-Path $PSScriptRoot '../..')
$plugin = Join-Path $repository 'plugins/nightshift'
$preflight = Join-Path $plugin 'runtime/windows/preflight-needs.ps1'
$parkNeeds = Join-Path $plugin 'runtime/windows/park-needs.ps1'
$rulesTemplate = Join-Path $plugin 'skills/nightshift/references/nightshift-rules-template.json'
$hostExecutable = (Get-Process -Id $PID).Path
$failures = New-Object 'System.Collections.Generic.List[string]'
$utf8 = New-Object Text.UTF8Encoding($false)

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
    param(
        [Parameter(Mandatory = $true)][string]$FileName,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )
    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $FileName
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    Set-ProcessArguments -StartInfo $psi -Arguments $Arguments
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

function Invoke-Preflight {
    param([Parameter(Mandatory = $true)][string]$Project, [switch]$Json)
    $psArgs = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $preflight, '-Project', $Project)
    if ($Json) { $psArgs += '-Json' }
    return Invoke-ProcessBytes -FileName $hostExecutable -Arguments $psArgs
}

function Invoke-Park {
    param([Parameter(Mandatory = $true)][string]$Project)
    return Invoke-ProcessBytes -FileName $hostExecutable -Arguments @(
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $parkNeeds, '-Project', $Project)
}

function New-PreflightProject {
    param([Parameter(Mandatory = $true)][string]$Path, [AllowEmptyString()][string]$Orders = '')
    $ns = Join-Path $Path '.nightshift'
    $null = New-Item -ItemType Directory -Path $ns -Force
    Copy-Item -LiteralPath $rulesTemplate -Destination (Join-Path $ns 'rules.json')
    $punch = @(
        '# Punch List',
        '',
        '## Gates',
        '',
        '- [ ] this checkbox is above the Items heading and is not an item',
        '',
        '## Items',
        '',
        '- [ ] **Bring the review stack up.**',
        '  - Run `docker compose up -d sonarqube` and wait for it to answer.',
        '  - Verify: the dashboard loads.',
        '',
        '- [ ] **Install ripgrep on the runner.**',
        '  - `sudo apt-get install -y ripgrep`',
        '  - Verify: `rg --version` prints.',
        '',
        '- [ ] **Publish the package.**',
        '  - `npm install -g @scope/cli` then `npm login`.',
        '',
        '- [x] **Retire the old runner.**',
        '  - `brew uninstall runner` and `sudo rm -rf /opt/runner`.',
        '',
        '- [ ] **Start the database service.**',
        '  - `systemctl start postgresql`',
        '',
        '- [ ] **Green the unit suite.**',
        '  - Run `npm test` and fix what it reports.',
        ''
    ) -join "`n"
    [IO.File]::WriteAllText((Join-Path $ns 'punch-list.md'), $punch, $utf8)
    if (-not [string]::IsNullOrEmpty($Orders)) {
        [IO.File]::WriteAllText((Join-Path $ns 'work-orders.md'), $Orders, $utf8)
    }
    [IO.File]::WriteAllText((Join-Path $ns 'parking-lot.md'), "# Parking Lot`n`n---`n`n(empty)`n", $utf8)
    return $ns
}

function Get-ItemBlock {
    param([Parameter(Mandatory = $true)][string]$Text, [Parameter(Mandatory = $true)][string]$Title)
    $lines = $Text -split "`n"
    $block = New-Object Collections.Generic.List[string]
    $inside = $false
    foreach ($line in $lines) {
        if ($line.StartsWith('item ', [StringComparison]::Ordinal)) {
            $inside = $line.Contains($Title)
            continue
        }
        if ($inside -and $line.StartsWith('  ', [StringComparison]::Ordinal)) { $block.Add($line.Trim()) }
    }
    return , $block.ToArray()
}

$root = Join-Path ([IO.Path]::GetTempPath()) ('ns-preflight-logic-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $root -Force
try {
    # === 1. every shipped signal is detected in item text ===
    $project = Join-Path $root 'project'
    $ns = New-PreflightProject $project
    $run = Invoke-Preflight -Project $project
    Expect-Equal 0 $run.ExitCode "preflight exits 0 ($($run.StderrText))"
    $text = $run.StdoutText.TrimEnd("`n")
    Expect-True (-not $text.Contains('this checkbox is above the Items heading')) `
        'only the Items section is read'
    Expect-Equal 5 (($text -split "`n" | Where-Object { $_.StartsWith('item ', [StringComparison]::Ordinal) }).Count) `
        'every open checkbox in the Items section is one item'
    Expect-True (-not $text.Contains('Retire the old runner.')) `
        'a ticked item is finished work and is never reported'
    Expect-True $text.Contains('preflight: 5 open items, 4 with gaps') 'the open-item and gap summary leads'
    Expect-True $text.Contains('item 1 [punch-list] Bring the review stack up.') 'the item line carries the title and the source'
    Expect-True ((Get-ItemBlock $text 'Bring the review stack up.') -ccontains 'needs containers (denied)') `
        'docker compose is a containers signal'
    Expect-True ((Get-ItemBlock $text 'Install ripgrep on the runner.') -ccontains 'needs sudo (denied)') `
        'sudo is a sudo signal'
    Expect-True ((Get-ItemBlock $text 'Install ripgrep on the runner.') -ccontains 'needs global-packages (denied)') `
        'apt-get is a global-packages signal'
    Expect-True ((Get-ItemBlock $text 'Publish the package.') -ccontains 'needs global-packages (denied)') `
        'npm install -g is a global-packages signal'
    Expect-True ((Get-ItemBlock $text 'Publish the package.') -ccontains 'needs external-services (denied)') `
        'npm login is an external-services signal'
    Expect-True ((Get-ItemBlock $text 'Start the database service.') -ccontains 'needs daemons (denied)') `
        'systemctl is a daemons signal'
    Expect-True ((Get-ItemBlock $text 'Green the unit suite.') -ccontains 'needs nothing') `
        'npm test needs no elevation'
    Expect-True $text.Contains('gaps: containers (item 1), sudo (item 2), global-packages (item 2), global-packages (item 3), external-services (item 3), daemons (item 5)') `
        'the summary lists every gap with its item number'

    # === 2. the resolver decides allowed, not the grep ===
    $allowed = Join-Path $root 'allowed'
    $allowedNs = New-PreflightProject $allowed
    $policy = New-NSOrdinalMap
    $policy['schemaVersion'] = 1
    $policy['shiftId'] = '0123456789abcdef'
    $policy['createdAt'] = '2026-09-02T00:00:00Z'
    $policy['source'] = 'composition'
    $policy['deadlineEpoch'] = $null
    $policy['verificationLevel'] = 'final'
    $policy['toolingPolicy'] = 'existing-tools'
    $containers = New-NSOrdinalMap
    $containers['category'] = 'containers'
    $containers['scope'] = 'category'
    $containers['provenance'] = 'one-shift'
    $policy['allowances'] = @($containers)
    [IO.File]::WriteAllText((Join-Path $allowedNs 'shift-policy.json'), (ConvertTo-NSCanonicalJson $policy), $utf8)
    $allowedText = (Invoke-Preflight -Project $allowed).StdoutText.TrimEnd("`n")
    Expect-True ((Get-ItemBlock $allowedText 'Bring the review stack up.') -ccontains 'needs containers (allowed)') `
        'a one-shift allowance turns a need into an allowance'
    Expect-True (-not $allowedText.Contains('containers (item 1)')) 'an allowed category is no longer a gap'
    Expect-True $allowedText.Contains('gaps: sudo (item 2), global-packages (item 2), global-packages (item 3), external-services (item 3), daemons (item 5)') `
        'the remaining gaps stay listed'

    # === 3. work orders are read too ===
    $orders = @(
        '# Work Orders',
        '',
        '## Work order - 2026-09-02 22:00',
        'Hours: 6',
        '',
        '- [ ] **Coverage hunt.**',
        '  - Run `docker run --rm coverage` over the suite.',
        '',
        '## Work order - 2026-09-03 22:00',
        'Hours: 2',
        'Scope: the release checklist, no boxes yet.',
        '',
        '## Work order - 2026-09-04 22:00',
        'Hours: 1',
        '',
        '- [x] **Retired container hunt.**',
        '  - `docker compose down` once, already done.',
        ''
    ) -join "`n"
    $withOrders = Join-Path $root 'with-orders'
    $null = New-PreflightProject $withOrders -Orders $orders
    $ordersText = (Invoke-Preflight -Project $withOrders).StdoutText.TrimEnd("`n")
    Expect-True $ordersText.Contains('item 1 [work-orders] Coverage hunt.') 'a boxed work order reports its box as the item'
    Expect-True ((Get-ItemBlock $ordersText 'Coverage hunt.') -ccontains 'needs containers (denied)') `
        'a work order is matched against the same patterns'
    Expect-True (-not $ordersText.Contains('Work order - 2026-09-03 22:00')) `
        'a work order with no box is not an item'
    Expect-True (-not $ordersText.Contains('Retired container hunt.')) `
        'a fully ticked work order reports neither its box nor its heading'
    Expect-True (-not $ordersText.Contains('2026-09-04 22:00')) `
        'a fully ticked work order is finished work'

    # === 4. the JSON view ===
    $jsonRun = Invoke-Preflight -Project $project -Json
    Expect-Equal 0 $jsonRun.ExitCode 'the JSON view exits 0'
    $json = $jsonRun.StdoutText.TrimEnd("`n")
    Expect-True $json.StartsWith('{"gaps":[', [StringComparison]::Ordinal) "the JSON view sorts its keys (got $json)"
    Expect-True $json.Contains('"items":[') 'the JSON view carries the items'
    Expect-True $json.Contains('"patternErrors":[]') 'a readable pattern set reports no pattern errors'
    Expect-True $json.Contains('"schemaVersion":1') 'the JSON view is versioned'
    Expect-True $json.Contains('{"allowed":false,"category":"containers","resolved":"deny"}') `
        'each need carries its resolved value'
    foreach ($byte in $jsonRun.StdoutBytes) { if ($byte -eq 13) { Expect-True $false 'the JSON view is LF-only'; break } }

    # === 5. an unreadable owner pattern is one reported defect, not a gap everywhere ===
    $brokenPattern = Join-Path $root 'broken-pattern'
    $brokenNs = New-PreflightProject $brokenPattern
    $rules = ConvertFrom-NSJsonText ([IO.File]::ReadAllText((Join-Path $brokenNs 'rules.json'), $utf8))
    $elevation = New-NSOrdinalMap
    $daemons = New-NSOrdinalMap
    $daemons['policy'] = 'deny'
    $daemons['pattern'] = '(unclosed'
    $elevation['daemons'] = $daemons
    $rules['elevation'] = $elevation
    [IO.File]::WriteAllText((Join-Path $brokenNs 'rules.json'), (ConvertTo-NSCanonicalJson $rules), $utf8)
    $brokenRun = Invoke-Preflight -Project $brokenPattern
    Expect-Equal 0 $brokenRun.ExitCode 'a broken pattern never makes the preflight refuse'
    Expect-True $brokenRun.StdoutText.Contains('pattern error: elevation.daemons.pattern is not a valid grep -E pattern; the category counts as needed') `
        'the broken pattern is named once'
    Expect-True $brokenRun.StdoutText.Contains('needs daemons (denied)') `
        'an unreadable pattern fails closed and counts as needed'

    # === 6. an empty workspace reports nothing and still exits 0 ===
    $emptyProject = Join-Path $root 'empty'
    $null = New-Item -ItemType Directory -Path (Join-Path $emptyProject '.nightshift') -Force
    $emptyRun = Invoke-Preflight -Project $emptyProject
    Expect-Equal 0 $emptyRun.ExitCode 'an empty workspace exits 0'
    Expect-True $emptyRun.StdoutText.Contains('preflight: 0 open items, 0 with gaps') 'an empty workspace reports no items'
    Expect-True $emptyRun.StdoutText.Contains('gaps: none') 'an empty workspace reports no gaps'

    # === shared fixture: same punch list and policy as tests/preflight-needs.bats ===
    $sharedList = @(
        '## Items',
        '',
        '- [ ] **1. Bring up the database.**',
        '  - Add postgres to docker-compose.yml and run `docker compose up -d`',
        '  - Verify: `psql -c ''select 1''`',
        '- [ ] **2. Install jq system-wide.**',
        '  - `sudo apt-get install -y jq`',
        '- [ ] **3. Run the tests.**',
        '  - `npm test`',
        '- [x] **4. Pin the linter.**',
        '  - `brew install shellcheck`',
        ''
    ) -join "`n"
    function Write-SharedPolicy {
        param([string]$Ns, [object[]]$Allowances)
        $policy = New-NSOrdinalMap
        $policy['schemaVersion'] = 1
        $policy['shiftId'] = '9f2c40ab77e51d63'
        $policy['createdAt'] = '2026-09-02T02:30:00Z'
        $policy['source'] = 'composition'
        $policy['deadlineEpoch'] = $null
        $policy['verificationLevel'] = 'final'
        $policy['toolingPolicy'] = 'existing-tools'
        $policy['allowances'] = @($Allowances)
        [IO.File]::WriteAllText((Join-Path $Ns 'shift-policy.json'), (ConvertTo-NSCanonicalJson $policy), $utf8)
    }
    function New-SharedAllowance {
        param([string]$Category)
        $row = New-NSOrdinalMap
        $row['category'] = $Category
        $row['scope'] = 'category'
        $row['provenance'] = 'one-shift'
        return $row
    }

    $mixed = Join-Path $root 'shared-mixed'
    $mixedNs = Join-Path $mixed '.nightshift'
    $null = New-Item -ItemType Directory -Path $mixedNs -Force
    Copy-Item -LiteralPath $rulesTemplate -Destination (Join-Path $mixedNs 'rules.json')
    [IO.File]::WriteAllText((Join-Path $mixedNs 'punch-list.md'), $sharedList, $utf8)
    $mixedText = (Invoke-Preflight -Project $mixed).StdoutText
    Expect-True $mixedText.Contains('preflight: 3 open items, 2 with gaps') 'shared fixture mixed needs: open and gap counts'
    Expect-True $mixedText.Contains('item 1 [punch-list] 1. Bring up the database.') 'shared fixture mixed needs: item 1'
    Expect-True $mixedText.Contains('  needs containers (denied)') 'shared fixture mixed needs: containers denied'
    Expect-True $mixedText.Contains('  needs nothing') 'shared fixture mixed needs: tests need nothing'
    Expect-True $mixedText.Contains('gaps: containers (item 1), sudo (item 2), global-packages (item 2)') `
        'shared fixture mixed needs: gap summary'

    $oneGap = Join-Path $root 'shared-one-gap'
    $oneGapNs = Join-Path $oneGap '.nightshift'
    $null = New-Item -ItemType Directory -Path $oneGapNs -Force
    Copy-Item -LiteralPath $rulesTemplate -Destination (Join-Path $oneGapNs 'rules.json')
    [IO.File]::WriteAllText((Join-Path $oneGapNs 'punch-list.md'), $sharedList, $utf8)
    Write-SharedPolicy $oneGapNs @((New-SharedAllowance 'containers'))
    $oneGapText = (Invoke-Preflight -Project $oneGap).StdoutText
    Expect-True $oneGapText.Contains('preflight: 3 open items, 1 with gaps') 'shared fixture one missing allowance: counts'
    Expect-True $oneGapText.Contains('  needs containers (allowed)') 'shared fixture one missing allowance: containers allowed'
    Expect-True $oneGapText.Contains('gaps: sudo (item 2), global-packages (item 2)') `
        'shared fixture one missing allowance: remaining gaps'

    $noGaps = Join-Path $root 'shared-no-gaps'
    $noGapsNs = Join-Path $noGaps '.nightshift'
    $null = New-Item -ItemType Directory -Path $noGapsNs -Force
    Copy-Item -LiteralPath $rulesTemplate -Destination (Join-Path $noGapsNs 'rules.json')
    [IO.File]::WriteAllText((Join-Path $noGapsNs 'punch-list.md'), $sharedList, $utf8)
    Write-SharedPolicy $noGapsNs @(
        (New-SharedAllowance 'containers'),
        (New-SharedAllowance 'sudo'),
        (New-SharedAllowance 'global-packages')
    )
    $noGapsText = (Invoke-Preflight -Project $noGaps).StdoutText
    Expect-True $noGapsText.Contains('preflight: 3 open items, 0 with gaps') 'shared fixture: no gaps'
    Expect-True $noGapsText.Contains('gaps: none') 'shared fixture: no gaps summary'

    # === 7. park-needs writes one entry per gap and repeats none ===
    $parkRun = Invoke-Park -Project $project
    Expect-Equal 0 $parkRun.ExitCode "park-needs exits 0 ($($parkRun.StderrText))"
    Expect-True $parkRun.StdoutText.Contains('park-needs: added 6') "park-needs adds one entry per item gap (got $($parkRun.StdoutText))"
    Expect-True (-not $parkRun.StdoutText.Contains('Retire the old runner.')) 'a ticked item is never parked'
    $parkingPath = Join-Path $ns 'parking-lot.md'
    $parking = [IO.File]::ReadAllText($parkingPath, $utf8)
    Expect-True $parking.StartsWith('# Parking Lot', [StringComparison]::Ordinal) 'park-needs keeps the owner file it appends to'
    Expect-True $parking.Contains('**needs allowance: containers**') 'the entry carries the missing category'
    Expect-True $parking.Contains('item "Bring the review stack up."') 'the entry names the item'
    Expect-True $parking.Contains('worked last if the owner allows it before then') 'the entry states the default'
    $secondRun = Invoke-Park -Project $project
    Expect-True $secondRun.StdoutText.Contains('park-needs: added 0') 'a second run adds nothing'
    Expect-Equal $parking ([IO.File]::ReadAllText($parkingPath, $utf8)) 'a second run leaves the file byte-identical'
    Expect-Equal 6 ([regex]::Matches($parking, '\*\*needs allowance: ')).Count 'the file carries exactly one entry per gap'
    Expect-Equal 0 (Add-NSParkedNeeds -Workspace $project).Count 'the library call is idempotent too'

    # === 8. park-needs writes nothing when there is no gap ===
    $noGap = Join-Path $root 'no-gap'
    $noGapNs = New-Item -ItemType Directory -Path (Join-Path $noGap '.nightshift') -Force
    [IO.File]::WriteAllText((Join-Path $noGapNs 'punch-list.md'),
        "# Punch List`n`n## Items`n`n- [ ] **Green the unit suite.**`n  - Run the tests.`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $noGapNs 'parking-lot.md'), "# Parking Lot`n`n(empty)`n", $utf8)
    $noGapRun = Invoke-Park -Project $noGap
    Expect-Equal 0 $noGapRun.ExitCode 'park-needs on a clean list exits 0'
    Expect-True $noGapRun.StdoutText.Contains('park-needs: added 0') 'park-needs on a clean list adds nothing'
    Expect-Equal "# Parking Lot`n`n(empty)`n" ([IO.File]::ReadAllText((Join-Path $noGapNs 'parking-lot.md'), $utf8)) `
        'park-needs never touches a parking lot it has nothing to add to'
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures.Count -gt 0) {
    Write-Host "preflight-needs-logic failed ($($failures.Count)):"
    foreach ($failure in $failures) { Write-Host " - $failure" }
    exit 1
}
Write-Host 'preflight-needs-logic passed'
exit 0
