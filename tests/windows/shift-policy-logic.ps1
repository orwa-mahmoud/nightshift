# Portable PowerShell coverage for the layered shift policy on native Windows.
# Run on macOS or Windows: pwsh -File tests/windows/shift-policy-logic.ps1
#
# Covers the frozen 02A interface: the three files, the one resolver and every
# precedence row, exact-plan binding, the armed refusal, the archive, the legacy
# the state-version migration, and the Doctor and support-bundle views.
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if (Test-Path Variable:PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $false
}

$repository = Resolve-Path (Join-Path $PSScriptRoot '../..')
$plugin = Join-Path $repository 'plugins/nightshift'
$helper = Join-Path $plugin 'runtime/windows/shift-policy.ps1'
$doctor = Join-Path $plugin 'runtime/windows/doctor.ps1'
$exportSupport = Join-Path $plugin 'runtime/windows/export-support.ps1'
$migrateState = Join-Path $plugin 'runtime/windows/migrate-state.ps1'
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
    # Raw bytes, never PowerShell's native-command pipeline: the LF-only,
    # BOM-free, ASCII-only guarantees are byte claims and must be read as bytes.
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

function Invoke-Helper {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)
    $psArgs = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $helper) + $Arguments
    return Invoke-ProcessBytes -FileName $hostExecutable -Arguments $psArgs
}

function Invoke-Script {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string[]]$Arguments)
    $psArgs = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $Path) + $Arguments
    return Invoke-ProcessBytes -FileName $hostExecutable -Arguments $psArgs
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

function Test-NSKeysSorted {
    param([string]$Json)
    $names = [regex]::Matches($Json, '"([^"]+)":') | ForEach-Object { $_.Groups[1].Value }
    $settingsAt = $Json.IndexOf('"settings":{', [StringComparison]::Ordinal)
    if ($settingsAt -lt 0) { return $false }
    $sorted = $true
    $previous = ''
    foreach ($name in $names) {
        if ($name -ceq 'schemaVersion' -or $name -ceq 'settings') { continue }
        if ($name -ceq 'value' -or $name -ceq 'source' -or $name -ceq 'expiry') { continue }
        if ($previous.Length -gt 0 -and [string]::CompareOrdinal($previous, $name) -ge 0) { $sorted = $false }
        $previous = $name
    }
    return $sorted
}

function New-PolicyProject {
    param([Parameter(Mandatory = $true)][string]$Path)
    $ns = Join-Path $Path '.nightshift'
    $null = New-Item -ItemType Directory -Path $ns -Force
    Copy-Item -LiteralPath $rulesTemplate -Destination (Join-Path $ns 'rules.json')
    return $ns
}

function Write-JsonFile {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)]$Document)
    [IO.File]::WriteAllText($Path, (ConvertTo-NSCanonicalJson $Document), $utf8)
}

function New-Policy {
    param(
        [string]$ShiftId = '0123456789abcdef',
        [string]$VerificationLevel = 'final',
        [string]$ToolingPolicy = 'existing-tools',
        $DeadlineEpoch = $null,
        $Allowances = @()
    )
    $policy = New-NSOrdinalMap
    $policy['schemaVersion'] = 1
    $policy['shiftId'] = $ShiftId
    $policy['createdAt'] = '2026-09-02T00:00:00Z'
    $policy['source'] = 'composition'
    $policy['deadlineEpoch'] = $DeadlineEpoch
    $policy['verificationLevel'] = $VerificationLevel
    $policy['toolingPolicy'] = $ToolingPolicy
    $policy['allowances'] = $Allowances
    return $policy
}

function New-Allowance {
    param(
        [Parameter(Mandatory = $true)][string]$Category,
        [Parameter(Mandatory = $true)][string]$Scope,
        [Parameter(Mandatory = $true)][string]$Provenance,
        $Plan = $null
    )
    $allowance = New-NSOrdinalMap
    $allowance['category'] = $Category
    $allowance['scope'] = $Scope
    $allowance['provenance'] = $Provenance
    if ($null -ne $Plan) { $allowance['plan'] = $Plan }
    return $allowance
}

function New-Plan {
    param(
        [Parameter(Mandatory = $true)][string[]]$Commands,
        [Parameter(Mandatory = $true)][string]$WorkTarget,
        [Parameter(Mandatory = $true)][string]$ShiftId,
        [AllowEmptyString()][string]$Digest = '',
        [AllowEmptyString()][string]$Expiry = ''
    )
    $plan = New-NSOrdinalMap
    $plan['commands'] = $Commands
    $plan['workTarget'] = $WorkTarget
    if ($Expiry -ceq 'none') {
        $plan['expiry'] = $null
    }
    elseif (-not [string]::IsNullOrEmpty($Expiry)) {
        $plan['expiry'] = [long]$Expiry
    }
    if ([string]::IsNullOrEmpty($Digest)) {
        $plan['digest'] = Get-NSPolicyPlanDigest -Commands $Commands -WorkTarget $WorkTarget -ShiftId $ShiftId
    }
    else {
        $plan['digest'] = $Digest
    }
    return $plan
}

function Get-SettingLine {
    param([Parameter(Mandatory = $true)][string]$Table, [Parameter(Mandatory = $true)][string]$Name)
    foreach ($line in ($Table -split "`n")) {
        if ($line.StartsWith($Name + '=', [StringComparison]::Ordinal)) { return $line }
    }
    return ''
}

$root = Join-Path ([IO.Path]::GetTempPath()) ('ns-shift-policy-logic-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $root -Force
try {
    # === 1. the resolved view on a scaffolded project ===
    $base = Join-Path $root 'base'
    $baseNs = New-PolicyProject $base
    $resolveRun = Invoke-Helper @('-Project', $base, '-Command', 'resolve')
    Expect-Equal 0 $resolveRun.ExitCode "resolve exits 0 ($($resolveRun.StderrText))"
    Expect-True (Test-NSNoCarriageReturn $resolveRun.StdoutBytes) 'the resolved JSON is LF-only'
    Expect-True (Test-NSSingleTrailingNewline $resolveRun.StdoutBytes) 'the resolved JSON ends with one newline'
    Expect-True (-not (Test-NSHasBom $resolveRun.StdoutBytes)) 'the resolved JSON has no BOM'
    Expect-True (Test-NSAsciiOnly $resolveRun.StdoutBytes) 'the resolved JSON is ASCII only'
    $resolveJson = $resolveRun.StdoutText.TrimEnd("`n")
    Expect-True (Test-NSKeysSorted $resolveJson) 'the resolved JSON sorts its keys ordinally'
    Expect-True $resolveJson.StartsWith('{"schemaVersion":1,"settings":{', [StringComparison]::Ordinal) `
        "the resolved JSON is the frozen shape (got $resolveJson)"
    foreach ($name in @('deadlineEpoch', 'elevation.containers', 'elevation.daemons',
            'elevation.external-services', 'elevation.global-packages', 'elevation.sudo',
            'expectedEmail', 'forbiddenCommands', 'neverCommitPatterns', 'protectedDirs',
            'stallMax', 'toolingPolicy', 'verificationLevel', 'watchMinutes')) {
        Expect-True $resolveJson.Contains('"' + $name + '":{') "the resolved view reports $name"
    }

    $tableRun = Invoke-Helper @('-Project', $base, '-Command', 'resolve', '-Table')
    Expect-Equal 0 $tableRun.ExitCode 'resolve -Table exits 0'
    $table = $tableRun.StdoutText.TrimEnd("`n")
    Expect-Equal 14 ($table -split "`n").Count 'the table prints one line per setting'
    Expect-Equal 'deadlineEpoch=none (built-in, -)' (Get-SettingLine $table 'deadlineEpoch') `
        'an absent deadline reports none'
    Expect-Equal 'verificationLevel=none (built-in, -)' (Get-SettingLine $table 'verificationLevel') `
        'without a policy the verification level is the built-in default'
    Expect-Equal 'toolingPolicy=existing-tools (built-in, -)' (Get-SettingLine $table 'toolingPolicy') `
        'without a policy the tooling policy is existing-tools'

    # Row: a key the owner wrote is sourced to rules even when its value is empty.
    Expect-Equal 'expectedEmail= (rules, permanent)' (Get-SettingLine $table 'expectedEmail') `
        'a present rules key is sourced to rules'
    Expect-Equal 'watchMinutes=10 (rules, permanent)' (Get-SettingLine $table 'watchMinutes') `
        'watchMinutes comes from rules.json'

    # === 2. precedence row 2: built-in deny, rules deny, rules allow, one-shift allow ===
    foreach ($category in @('sudo', 'containers', 'global-packages', 'daemons', 'external-services')) {
        Expect-Equal "elevation.$category=deny (rules, permanent)" (Get-SettingLine $table "elevation.$category") `
            "the shipped template denies $category and says so as an owner decision"
        Expect-True ((Get-NSElevationPattern $base $category).Length -gt 0) `
            "the shipped template carries a $category pattern"
    }

    # A workspace whose rules.json names no elevation at all falls to the built-in.
    $noElevation = Join-Path $root 'no-elevation'
    $noElevationNs = New-PolicyProject $noElevation
    $strippedRules = ConvertFrom-NSJsonText ([IO.File]::ReadAllText((Join-Path $noElevationNs 'rules.json'), $utf8))
    $strippedRules.Remove('elevation')
    Write-JsonFile (Join-Path $noElevationNs 'rules.json') $strippedRules
    $noElevationTable = (Invoke-Helper @('-Project', $noElevation, '-Command', 'resolve', '-Table')).StdoutText.TrimEnd("`n")
    foreach ($category in @('sudo', 'containers', 'global-packages', 'daemons', 'external-services')) {
        Expect-Equal "elevation.$category=deny (built-in, -)" (Get-SettingLine $noElevationTable "elevation.$category") `
            "$category is denied by default when rules.json names no elevation"
    }
    Expect-True ((Get-NSElevationPattern $noElevation 'sudo').Contains('sudo|d[o]as')) `
        'a workspace with no elevation object still gets the shipped patterns'
    $templateElevation = (ConvertFrom-NSJsonText ([IO.File]::ReadAllText($rulesTemplate, $utf8)))['elevation']
    foreach ($category in @('sudo', 'containers', 'global-packages', 'daemons', 'external-services')) {
        Expect-Equal $templateElevation[$category]['pattern'] (Get-NSElevationPattern $noElevation $category) `
            "the built-in $category pattern is the template's, character for character"
    }

    $rulesAllow = Join-Path $root 'rules-allow'
    $rulesAllowNs = New-PolicyProject $rulesAllow
    $rules = ConvertFrom-NSJsonText ([IO.File]::ReadAllText((Join-Path $rulesAllowNs 'rules.json'), $utf8))
    $elevation = New-NSOrdinalMap
    $containers = New-NSOrdinalMap
    $containers['policy'] = 'allow'
    $containers['pattern'] = '(^|[;&|(]|[[:space:]])(docker|podman)([[:space:]]|$)'
    $elevation['containers'] = $containers
    $rules['elevation'] = $elevation
    Write-JsonFile (Join-Path $rulesAllowNs 'rules.json') $rules
    $rulesTable = (Invoke-Helper @('-Project', $rulesAllow, '-Command', 'resolve', '-Table')).StdoutText.TrimEnd("`n")
    Expect-Equal 'elevation.containers=allow (rules, permanent)' (Get-SettingLine $rulesTable 'elevation.containers') `
        'a rules.elevation allow lifts the built-in deny permanently'
    Expect-Equal 'elevation.sudo=deny (built-in, -)' (Get-SettingLine $rulesTable 'elevation.sudo') `
        'a category dropped from rules.elevation falls back to the built-in deny'
    Expect-Equal '(^|[;&|(]|[[:space:]])(docker|podman)([[:space:]]|$)' (Get-NSElevationPattern $rulesAllow 'containers') `
        'the owner pattern replaces the shipped one'
    Expect-True ((Get-NSElevationPattern $rulesAllow 'sudo').Contains('sudo|d[o]as')) `
        'a missing category falls back to the shipped pattern'

    $oneShift = Join-Path $root 'one-shift'
    $oneShiftNs = New-PolicyProject $oneShift
    Write-JsonFile (Join-Path $oneShiftNs 'shift-policy.json') `
    (New-Policy -VerificationLevel 'per-item' -ToolingPolicy 'auto-add' -DeadlineEpoch 1788000000 `
            -Allowances @((New-Allowance -Category 'containers' -Scope 'category' -Provenance 'one-shift')))
    $oneShiftTable = (Invoke-Helper @('-Project', $oneShift, '-Command', 'resolve', '-Table')).StdoutText.TrimEnd("`n")
    Expect-Equal 'elevation.containers=allow (one-shift, shift)' (Get-SettingLine $oneShiftTable 'elevation.containers') `
        'a one-shift allowance alone lifts the deny for tonight'
    Expect-Equal 'verificationLevel=per-item (one-shift, shift)' (Get-SettingLine $oneShiftTable 'verificationLevel') `
        'the policy owns the verification level'
    Expect-Equal 'toolingPolicy=auto-add (one-shift, shift)' (Get-SettingLine $oneShiftTable 'toolingPolicy') `
        'the policy owns the tooling policy'
    Expect-Equal 'deadlineEpoch=1788000000 (one-shift, shift)' (Get-SettingLine $oneShiftTable 'deadlineEpoch') `
        'the policy owns the deadline'

    $rulesProvenance = Join-Path $root 'rules-provenance'
    $rulesProvenanceNs = New-PolicyProject $rulesProvenance
    Write-JsonFile (Join-Path $rulesProvenanceNs 'shift-policy.json') `
    (New-Policy -Allowances @((New-Allowance -Category 'daemons' -Scope 'category' -Provenance 'rules')))
    $provenanceTable = (Invoke-Helper @('-Project', $rulesProvenance, '-Command', 'resolve', '-Table')).StdoutText.TrimEnd("`n")
    Expect-Equal 'elevation.daemons=allow (rules, permanent)' (Get-SettingLine $provenanceTable 'elevation.daemons') `
        'an allowance carrying rules provenance reports rules and permanent'

    # === 3. precedence row 1: no allowance lifts a protected boundary ===
    $protectedProject = Join-Path $root 'protected'
    $protectedNs = New-PolicyProject $protectedProject
    $protectedRules = ConvertFrom-NSJsonText ([IO.File]::ReadAllText((Join-Path $protectedNs 'rules.json'), $utf8))
    $protectedRules['protectedDirs'] = '.github infra'
    $protectedRules['neverCommitPatterns'] = 'BEGIN OPENSSH PRIVATE KEY'
    $protectedRules['expectedEmail'] = 'owner@example.invalid'
    Write-JsonFile (Join-Path $protectedNs 'rules.json') $protectedRules
    Write-JsonFile (Join-Path $protectedNs 'shift-policy.json') `
    (New-Policy -Allowances @(
            (New-Allowance -Category 'sudo' -Scope 'category' -Provenance 'one-shift'),
            (New-Allowance -Category 'containers' -Scope 'category' -Provenance 'one-shift')))
    $protectedTable = (Invoke-Helper @('-Project', $protectedProject, '-Command', 'resolve', '-Table')).StdoutText.TrimEnd("`n")
    Expect-Equal 'protectedDirs=.github infra (rules, permanent)' (Get-SettingLine $protectedTable 'protectedDirs') `
        'protected paths stay rules-only under a category allowance'
    Expect-Equal 'neverCommitPatterns=BEGIN OPENSSH PRIVATE KEY (rules, permanent)' (Get-SettingLine $protectedTable 'neverCommitPatterns') `
        'never-commit patterns stay rules-only under a category allowance'
    Expect-Equal 'expectedEmail=owner@example.invalid (rules, permanent)' (Get-SettingLine $protectedTable 'expectedEmail') `
        'the expected email stays rules-only under a category allowance'

    # === 4. precedence row 3: exact plan, and category wins when both are present ===
    $planProject = Join-Path $root 'exact-plan'
    $planNs = New-PolicyProject $planProject
    $planTarget = Get-NSAbsolutePath $planProject
    $planCommand = 'sudo apt-get install -y ripgrep'
    Write-JsonFile (Join-Path $planNs 'shift-policy.json') `
    (New-Policy -DeadlineEpoch ((Get-NSUnixTime) + 3600) -Allowances @(
            (New-Allowance -Category 'sudo' -Scope 'exact-plan' -Provenance 'one-shift' `
                    -Plan (New-Plan -Commands @($planCommand) -WorkTarget $planTarget -ShiftId '0123456789abcdef'))))
    $planTable = (Invoke-Helper @('-Project', $planProject, '-Command', 'resolve', '-Table')).StdoutText.TrimEnd("`n")
    Expect-Equal 'elevation.sudo=exact-plan (exact-plan, shift)' (Get-SettingLine $planTable 'elevation.sudo') `
        'an exact plan reports itself as the source'
    Expect-Equal 0 (Test-NSPolicyAllowed -Workspace $planProject -Category 'sudo' -Command $planCommand) `
        'the approved command is allowed'
    Expect-Equal 0 (Test-NSPolicyAllowed -Workspace $planProject -Category 'sudo' -Command "sudo   apt-get install -y   ripgrep") `
        'whitespace collapses before the exact match'
    Expect-Equal 2 (Test-NSPolicyAllowed -Workspace $planProject -Category 'sudo' -Command 'sudo apt-get install -y curl') `
        'a neighbouring command is an exact-plan mismatch, not a deny'
    Expect-Equal 1 (Test-NSPolicyAllowed -Workspace $planProject -Category 'daemons' -Command 'systemctl start postgresql') `
        'an untouched category is still denied'

    $bothProject = Join-Path $root 'plan-and-category'
    $bothNs = New-PolicyProject $bothProject
    Write-JsonFile (Join-Path $bothNs 'shift-policy.json') `
    (New-Policy -Allowances @(
            (New-Allowance -Category 'sudo' -Scope 'exact-plan' -Provenance 'one-shift' `
                    -Plan (New-Plan -Commands @($planCommand) -WorkTarget (Get-NSAbsolutePath $bothProject) -ShiftId '0123456789abcdef')),
            (New-Allowance -Category 'sudo' -Scope 'category' -Provenance 'one-shift')))
    $bothTable = (Invoke-Helper @('-Project', $bothProject, '-Command', 'resolve', '-Table')).StdoutText.TrimEnd("`n")
    Expect-Equal 'elevation.sudo=allow (one-shift, shift)' (Get-SettingLine $bothTable 'elevation.sudo') `
        'a category allowance beside an exact plan wins'
    Expect-Equal 0 (Test-NSPolicyAllowed -Workspace $bothProject -Category 'sudo' -Command 'sudo anything else') `
        'the category allowance covers commands the plan never listed'

    # === 5. exact-plan binding: target, digest and expiry each deny on drift ===
    $driftTarget = Join-Path $root 'drift-target'
    $driftTargetNs = New-PolicyProject $driftTarget
    Write-JsonFile (Join-Path $driftTargetNs 'shift-policy.json') `
    (New-Policy -Allowances @(
            (New-Allowance -Category 'sudo' -Scope 'exact-plan' -Provenance 'one-shift' `
                    -Plan (New-Plan -Commands @($planCommand) -WorkTarget (Join-Path $root 'somewhere-else') -ShiftId '0123456789abcdef'))))
    Expect-Equal 2 (Test-NSPolicyAllowed -Workspace $driftTarget -Category 'sudo' -Command $planCommand) `
        'a plan approved for another work target is a mismatch'

    $driftDigest = Join-Path $root 'drift-digest'
    $driftDigestNs = New-PolicyProject $driftDigest
    Write-JsonFile (Join-Path $driftDigestNs 'shift-policy.json') `
    (New-Policy -Allowances @(
            (New-Allowance -Category 'sudo' -Scope 'exact-plan' -Provenance 'one-shift' `
                    -Plan (New-Plan -Commands @($planCommand) -WorkTarget (Get-NSAbsolutePath $driftDigest) -ShiftId '0123456789abcdef' `
                        -Digest ('0' * 64)))))
    Expect-Equal 2 (Test-NSPolicyAllowed -Workspace $driftDigest -Category 'sudo' -Command $planCommand) `
        'a plan whose digest does not recompute is a mismatch'

    $driftShift = Join-Path $root 'drift-shift'
    $driftShiftNs = New-PolicyProject $driftShift
    Write-JsonFile (Join-Path $driftShiftNs 'shift-policy.json') `
    (New-Policy -ShiftId 'fedcba9876543210' -Allowances @(
            (New-Allowance -Category 'sudo' -Scope 'exact-plan' -Provenance 'one-shift' `
                    -Plan (New-Plan -Commands @($planCommand) -WorkTarget (Get-NSAbsolutePath $driftShift) -ShiftId '0123456789abcdef'))))
    Expect-Equal 2 (Test-NSPolicyAllowed -Workspace $driftShift -Category 'sudo' -Command $planCommand) `
        'a plan digested under another shift identity is a replay and denies'

    $expired = Join-Path $root 'expired'
    $expiredNs = New-PolicyProject $expired
    Write-JsonFile (Join-Path $expiredNs 'shift-policy.json') `
    (New-Policy -DeadlineEpoch 1000000000 -Allowances @(
            (New-Allowance -Category 'sudo' -Scope 'exact-plan' -Provenance 'one-shift' `
                    -Plan (New-Plan -Commands @($planCommand) -WorkTarget (Get-NSAbsolutePath $expired) -ShiftId '0123456789abcdef'))))
    Expect-Equal 2 (Test-NSPolicyAllowed -Workspace $expired -Category 'sudo' -Command $planCommand) `
        'an expired plan is a mismatch'

    # === 5b. plan.expiry binds on its own, outside the digest ===
    $now = Get-NSUnixTime
    $planAhead = Join-Path $root 'expiry-ahead'
    $planAheadNs = New-PolicyProject $planAhead
    Write-JsonFile (Join-Path $planAheadNs 'shift-policy.json') `
    (New-Policy -Allowances @(
            (New-Allowance -Category 'sudo' -Scope 'exact-plan' -Provenance 'one-shift' `
                    -Plan (New-Plan -Commands @($planCommand) -WorkTarget (Get-NSAbsolutePath $planAhead) `
                        -ShiftId '0123456789abcdef' -Expiry ([string]($now + 3600))))))
    Expect-Equal 0 (Test-NSPolicyAllowed -Workspace $planAhead -Category 'sudo' -Command $planCommand) `
        'a plan whose expiry is still ahead binds'

    $planPassed = Join-Path $root 'expiry-passed'
    $planPassedNs = New-PolicyProject $planPassed
    Write-JsonFile (Join-Path $planPassedNs 'shift-policy.json') `
    (New-Policy -Allowances @(
            (New-Allowance -Category 'sudo' -Scope 'exact-plan' -Provenance 'one-shift' `
                    -Plan (New-Plan -Commands @($planCommand) -WorkTarget (Get-NSAbsolutePath $planPassed) `
                        -ShiftId '0123456789abcdef' -Expiry ([string]($now - 60))))))
    Expect-Equal 2 (Test-NSPolicyAllowed -Workspace $planPassed -Category 'sudo' -Command $planCommand) `
        'a plan whose expiry has passed does not bind, even with no shift deadline'

    $planNullExpiry = Join-Path $root 'expiry-null'
    $planNullExpiryNs = New-PolicyProject $planNullExpiry
    Write-JsonFile (Join-Path $planNullExpiryNs 'shift-policy.json') `
    (New-Policy -Allowances @(
            (New-Allowance -Category 'sudo' -Scope 'exact-plan' -Provenance 'one-shift' `
                    -Plan (New-Plan -Commands @($planCommand) -WorkTarget (Get-NSAbsolutePath $planNullExpiry) `
                        -ShiftId '0123456789abcdef' -Expiry 'none'))))
    Expect-Equal 0 (Test-NSPolicyAllowed -Workspace $planNullExpiry -Category 'sudo' -Command $planCommand) `
        'a null expiry defers to the shift deadline and binds'
    $nullExpiryPolicy = Get-NSShiftPolicy $planNullExpiry
    Expect-True $nullExpiryPolicy['allowances'][0]['plan'].Contains('expiry') `
        'a null expiry survives the schema as a present field'

    # The digest covers commands, shiftId and workTarget - never the expiry, so a
    # plan that only sets one still recomputes.
    $withExpiry = New-Plan -Commands @($planCommand) -WorkTarget '/tmp/target' -ShiftId '0123456789abcdef' -Expiry '1788000000'
    $withoutExpiry = New-Plan -Commands @($planCommand) -WorkTarget '/tmp/target' -ShiftId '0123456789abcdef'
    Expect-Equal $withoutExpiry['digest'] $withExpiry['digest'] 'plan.expiry is outside the digest preimage'
    Expect-Equal 0 (Set-NSShiftPolicy -Workspace $planAhead -Json (ConvertTo-NSCanonicalJson (New-Policy -Allowances @(
                    (New-Allowance -Category 'sudo' -Scope 'exact-plan' -Provenance 'one-shift' `
                            -Plan (New-Plan -Commands @($planCommand) -WorkTarget (Get-NSAbsolutePath $planAhead) `
                                -ShiftId '0123456789abcdef' -Expiry '1788000000')))))) `
        'the schema accepts a plan expiry'

    # === 6. precedence row 4: shift-defaults never decides ===
    $defaultsProject = Join-Path $root 'defaults'
    $null = New-PolicyProject $defaultsProject
    $defaultsSet = Invoke-Helper @('-Project', $defaultsProject, '-Command', 'defaults-set',
        '-VerificationProfile', 'strict', '-Hours', '10', '-ToolingPolicy', 'auto-add', '-Execution', 'run-direct')
    Expect-Equal 0 $defaultsSet.ExitCode "defaults-set exits 0 ($($defaultsSet.StderrText))"
    $defaultsGet = Invoke-Helper @('-Project', $defaultsProject, '-Command', 'defaults-get')
    Expect-True $defaultsGet.StdoutText.Contains('"verificationProfile": "strict"') 'defaults-get reports the remembered profile'
    Expect-True $defaultsGet.StdoutText.Contains('"hours": 10') 'defaults-get reports the remembered hours'
    $defaultsTable = (Invoke-Helper @('-Project', $defaultsProject, '-Command', 'resolve', '-Table')).StdoutText.TrimEnd("`n")
    Expect-Equal 'verificationLevel=none (built-in, -)' (Get-SettingLine $defaultsTable 'verificationLevel') `
        'a remembered strict profile never becomes an effective verification level'
    Expect-Equal 'toolingPolicy=existing-tools (built-in, -)' (Get-SettingLine $defaultsTable 'toolingPolicy') `
        'a remembered tooling policy never becomes an effective value'
    $defaultsBad = Invoke-Helper @('-Project', $defaultsProject, '-Command', 'defaults-set', '-Hours', 'ten')
    Expect-Equal 2 $defaultsBad.ExitCode 'defaults-set rejects a non-numeric hours'
    Expect-True $defaultsBad.StderrText.Contains('hours:') 'the defaults-set refusal names the field'

    # === 7. set: schema validation, armed refusal, get and archive ===
    $setProject = Join-Path $root 'set'
    $setNs = New-PolicyProject $setProject
    $absentGet = Invoke-Helper @('-Project', $setProject, '-Command', 'get')
    Expect-Equal 3 $absentGet.ExitCode 'get on an absent policy exits 3'
    Expect-Equal '{}' $absentGet.StdoutText.TrimEnd("`n") 'get on an absent policy prints {}'

    $good = Join-Path $root 'good-policy.json'
    Write-JsonFile $good (New-Policy -VerificationLevel 'final')
    $setRun = Invoke-Helper @('-Project', $setProject, '-Command', 'set', '-FromJson', $good)
    Expect-Equal 0 $setRun.ExitCode "set writes a valid policy ($($setRun.StderrText))"
    $afterGet = Invoke-Helper @('-Project', $setProject, '-Command', 'get')
    Expect-Equal 0 $afterGet.ExitCode 'get on a written policy exits 0'
    Expect-True $afterGet.StdoutText.Contains('"shiftId": "0123456789abcdef"') 'get prints the written policy'

    $unknownField = Join-Path $root 'unknown-field.json'
    $unknown = New-Policy
    $unknown['bonusAuthority'] = 'yes'
    Write-JsonFile $unknownField $unknown
    $unknownRun = Invoke-Helper @('-Project', $setProject, '-Command', 'set', '-FromJson', $unknownField)
    Expect-Equal 2 $unknownRun.ExitCode 'set refuses an unknown field'
    Expect-True $unknownRun.StderrText.Contains('bonusAuthority: unknown field') 'the refusal names the exact field'

    $badLevel = Join-Path $root 'bad-level.json'
    Write-JsonFile $badLevel (New-Policy -VerificationLevel 'thorough')
    $badLevelRun = Invoke-Helper @('-Project', $setProject, '-Command', 'set', '-FromJson', $badLevel)
    Expect-Equal 2 $badLevelRun.ExitCode 'set refuses an unknown verification level'
    Expect-True $badLevelRun.StderrText.Contains('verificationLevel: must be one of') 'the refusal names verificationLevel'

    $badPlan = Join-Path $root 'bad-plan.json'
    Write-JsonFile $badPlan (New-Policy -Allowances @(
            (New-Allowance -Category 'sudo' -Scope 'exact-plan' -Provenance 'one-shift')))
    $badPlanRun = Invoke-Helper @('-Project', $setProject, '-Command', 'set', '-FromJson', $badPlan)
    Expect-Equal 2 $badPlanRun.ExitCode 'set refuses an exact-plan allowance with no plan'
    Expect-True $badPlanRun.StderrText.Contains('allowances[0].plan:') 'the refusal names the allowance and the plan'

    $notJson = Join-Path $root 'not-json.json'
    [IO.File]::WriteAllText($notJson, '{ "schemaVersion": 1,', $utf8)
    $notJsonRun = Invoke-Helper @('-Project', $setProject, '-Command', 'set', '-FromJson', $notJson)
    Expect-Equal 2 $notJsonRun.ExitCode 'set refuses text that is not JSON'
    Expect-True $notJsonRun.StderrText.Contains('document: not valid JSON') 'the refusal names the document'

    [IO.File]::WriteAllText((Join-Path $setNs '.shift-armed'), '', $utf8)
    $armedRun = Invoke-Helper @('-Project', $setProject, '-Command', 'set', '-FromJson', $good)
    Expect-Equal 4 $armedRun.ExitCode 'set is refused while the shift is armed'
    Expect-True $armedRun.StderrText.Contains('while the shift is armed') 'the armed refusal says so'
    $armedDefaults = Invoke-Helper @('-Project', $setProject, '-Command', 'defaults-set', '-ToolingPolicy', 'auto-add')
    Expect-Equal 4 $armedDefaults.ExitCode 'defaults-set is refused while the shift is armed'
    Remove-Item -LiteralPath (Join-Path $setNs '.shift-armed') -Force

    $archiveRun = Invoke-Helper @('-Project', $setProject, '-Command', 'archive', '-Date', '2026-09-02')
    Expect-Equal 0 $archiveRun.ExitCode "archive exits 0 ($($archiveRun.StderrText))"
    $archived = Join-Path $setNs 'archive/2026-09-02/shift-policy-0123456789abcdef.json'
    Expect-True (Test-Path -LiteralPath $archived -PathType Leaf) 'archive names the file after the shift identity'
    Expect-True (-not (Test-Path -LiteralPath (Join-Path $setNs 'shift-policy.json') -PathType Leaf)) `
        'archive removes the live policy'
    Expect-Equal 3 (Invoke-Helper @('-Project', $setProject, '-Command', 'archive', '-Date', '2026-09-02')).ExitCode `
        'archiving nothing exits 3'

    # === 8. precedence row 6: a malformed policy grants no authority ===
    $malformed = Join-Path $root 'malformed'
    $malformedNs = New-PolicyProject $malformed
    $malformedDocument = New-Policy -VerificationLevel 'per-item' -Allowances @(
        (New-Allowance -Category 'sudo' -Scope 'category' -Provenance 'one-shift'))
    $malformedDocument['toolingPolicy'] = 'install-whatever'
    Write-JsonFile (Join-Path $malformedNs 'shift-policy.json') $malformedDocument
    $malformedTable = (Invoke-Helper @('-Project', $malformed, '-Command', 'resolve', '-Table')).StdoutText.TrimEnd("`n")
    Expect-Equal 'elevation.sudo=deny (rules, permanent)' (Get-SettingLine $malformedTable 'elevation.sudo') `
        'a malformed policy grants no allowance'
    Expect-Equal 'verificationLevel=none (built-in, -)' (Get-SettingLine $malformedTable 'verificationLevel') `
        'a malformed policy decides no verification level'
    Expect-Equal 1 (Test-NSPolicyAllowed -Workspace $malformed -Category 'sudo' -Command 'sudo rm -rf /') `
        'a malformed policy allows nothing'
    $malformedResolution = Get-NSPolicyResolution $malformed
    Expect-Equal 'malformed' $malformedResolution['policyState'] 'the resolver reports the malformed state'
    Expect-True ([string]$malformedResolution['policyError']).StartsWith('toolingPolicy:', [StringComparison]::Ordinal) `
        "the resolver names the exact field (got $($malformedResolution['policyError']))"

    # === 9. the deadline projection honours the earlier value ===
    $deadlineProject = Join-Path $root 'deadline'
    $deadlineNs = New-PolicyProject $deadlineProject
    Write-JsonFile (Join-Path $deadlineNs 'shift-policy.json') (New-Policy -DeadlineEpoch 1788000000)
    [IO.File]::WriteAllText((Join-Path $deadlineNs 'deadline'), "1787000000`n", $utf8)
    Expect-Equal 1787000000 (Get-NSPolicyDeadlineEpoch $deadlineProject) 'the earlier of file and policy wins'
    [IO.File]::WriteAllText((Join-Path $deadlineNs 'deadline'), "1789000000`n", $utf8)
    Expect-Equal 1788000000 (Get-NSPolicyDeadlineEpoch $deadlineProject) 'a later deadline file never extends the night'

    # === 10. Doctor renders the one view and names every defect ===
    $doctorRun = Invoke-Script -Path $doctor -Arguments @('-Project', $deadlineProject)
    Expect-Equal 0 $doctorRun.ExitCode "Doctor exits 0 ($($doctorRun.StderrText))"
    Expect-True $doctorRun.StdoutText.Contains('resolved policy') 'Doctor prints one resolved policy block'
    $doctorTable = (Invoke-Helper @('-Project', $deadlineProject, '-Command', 'resolve', '-Table')).StdoutText.TrimEnd("`n")
    foreach ($doctorLine in ($doctorTable -split "`n")) {
        Expect-True $doctorRun.StdoutText.Contains($doctorLine) "Doctor prints the resolver's line $doctorLine"
    }
    Expect-True $doctorRun.StdoutText.Contains('deadline file 1789000000 does not match shift-policy deadlineEpoch 1788000000') `
        'Doctor names both deadline values on a mismatch'
    $doctorMalformed = Invoke-Script -Path $doctor -Arguments @('-Project', $malformed)
    Expect-True $doctorMalformed.StdoutText.Contains('shift-policy.json is malformed (toolingPolicy:') `
        'Doctor names the malformed field'

    # === 11. the support bundle ships the view, never the files ===
    $supportProject = Join-Path $root 'support'
    $supportNs = New-PolicyProject $supportProject
    $longPattern = 'secret-' + ('x' * 120)
    $supportRules = ConvertFrom-NSJsonText ([IO.File]::ReadAllText((Join-Path $supportNs 'rules.json'), $utf8))
    $supportRules['forbiddenCommands'] = $longPattern
    $supportRules['expectedEmail'] = 'owner@example.invalid'
    Write-JsonFile (Join-Path $supportNs 'rules.json') $supportRules
    Write-JsonFile (Join-Path $supportNs 'shift-policy.json') (New-Policy -VerificationLevel 'final')
    $supportRun = Invoke-Script -Path $exportSupport -Arguments @('-Project', $supportProject)
    Expect-Equal 0 $supportRun.ExitCode "export-support exits 0 ($($supportRun.StderrText))"
    $bundlePath = ($supportRun.StdoutText -split "`n" | Where-Object { $_.StartsWith('Support bundle: ', [StringComparison]::Ordinal) })
    $bundle = ([string]$bundlePath).Substring('Support bundle: '.Length).Trim()
    $bundleText = [IO.File]::ReadAllText($bundle, $utf8)
    Expect-True $bundleText.Contains('== resolved policy ==') 'the bundle carries the resolved policy section'
    Expect-True $bundleText.Contains('shift_policy: valid') 'the bundle reports the policy state'
    Expect-True $bundleText.Contains('verificationLevel=final (one-shift, shift)') 'the bundle carries the effective values'
    Expect-True (-not $bundleText.Contains($longPattern)) 'the bundle never carries a long owner pattern'
    Expect-True $bundleText.Contains('forbiddenCommands=<redacted 127 chars> (rules, permanent)') `
        'a value over 80 characters ships as its length'
    Expect-True (-not $bundleText.Contains('owner@example.invalid')) 'the bundle never carries a rule value'
    Expect-True $bundleText.Contains('expectedEmail=<redacted 21 chars> (rules, permanent)') `
        'owner free-form text ships as its length however short it is'
    Expect-True $bundleText.Contains('protectedDirs= (rules, permanent)') `
        'an empty owner value has nothing to redact'

    # === 12. migrate-state writes the state marker only ===
    $legacyProject = Join-Path $root 'legacy'
    $legacyNs = New-PolicyProject $legacyProject
    [IO.File]::WriteAllText((Join-Path $legacyNs 'state-version'), "1`n", $utf8)
    $migrateRun = Invoke-Script -Path $migrateState -Arguments @('-Project', $legacyProject)
    Expect-Equal 0 $migrateRun.ExitCode "migrate-state exits 0 ($($migrateRun.StderrText))"
    Expect-True (-not $migrateRun.StdoutText.Contains('is retired')) `
        'migrate-state retires nothing but the state marker'

    # === 13. The migration onto the one-file shape, against the frozen cases ===
    # The same fixtures the POSIX suite runs, so both hosts are held to one contract.
    $fixtures = Join-Path $PSScriptRoot '../fixtures/policy-contract'
    $ownerName = 'rules' + '.json'
    $legacyName = 'shift-defaults' + '.json'
    foreach ($case in @('fresh', 'legacy', 'conflict', 'identical', 'repeat', 'malformed', 'armed',
                        'new-settings-absent')) {
        $caseDir = Join-Path $fixtures $case
        $casePath = Join-Path $root ('migrate-' + $case)
        $caseNs = Join-Path $casePath '.nightshift'
        $null = New-Item -ItemType Directory -Force -Path $caseNs
        Copy-Item (Join-Path $caseDir $ownerName) (Join-Path $caseNs $ownerName)
        $legacySource = Join-Path $caseDir $legacyName
        if (Test-Path -LiteralPath $legacySource) {
            Copy-Item $legacySource (Join-Path $caseNs $legacyName)
        }
        $expected = Get-Content (Join-Path $caseDir 'expected.json') -Raw | ConvertFrom-Json
        if ($expected.PSObject.Properties['armed'] -and $expected.armed) {
            [IO.File]::WriteAllText((Join-Path $caseNs '.shift-armed'), '', $utf8)
        }
        $migrateRun = Invoke-Script -Path $helper -Arguments @('-Project', $casePath, '-Command', 'migrate')
        Expect-Equal ([int]$expected.exit) $migrateRun.ExitCode `
            "migrate $case exits the way the contract says ($($migrateRun.StderrText))"
    }

    # The value lands, the owner's own keys survive, and the legacy file is retired behind a backup.
    $movedPath = Join-Path $root 'migrate-legacy'
    $movedNs = Join-Path $movedPath '.nightshift'
    $moved = Get-Content (Join-Path $movedNs $ownerName) -Raw | ConvertFrom-Json
    Expect-Equal 'review-missing' ([string]$moved.shift.toolingPolicy) 'the explicit legacy value survives the move'
    Expect-Equal 10 ([int]$moved.watchMinutes) 'an owner value the migration never touched is unchanged'
    Expect-True (Test-Path -LiteralPath (Join-Path $movedNs ($legacyName + '.bak'))) 'a lossless backup is kept'
    Expect-True (-not (Test-Path -LiteralPath (Join-Path $movedNs $legacyName))) 'the legacy file is retired'

    # A second run changes nothing, and a dry run writes nothing.
    $againRun = Invoke-Script -Path $helper -Arguments @('-Project', $movedPath, '-Command', 'migrate')
    Expect-Equal 0 $againRun.ExitCode 'a migration that already ran is a no-op'
    Expect-True $againRun.StdoutText.Contains('no-op') 'the second run says it did nothing'

    # What defaults-set writes is what defaults-get reads, because there is one place for it.
    $setRun = Invoke-Script -Path $helper -Arguments @('-Project', $movedPath, '-Command', 'defaults-set',
        '-ToolingPolicy', 'auto-add')
    Expect-Equal 0 $setRun.ExitCode 'defaults-set writes the shift block'
    $getRun = Invoke-Script -Path $helper -Arguments @('-Project', $movedPath, '-Command', 'defaults-get')
    Expect-True $getRun.StdoutText.Contains('"toolingPolicy": "auto-add"') `
        'defaults-get reads the block defaults-set wrote'
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures.Count -gt 0) {
    Write-Host "shift-policy-logic failed ($($failures.Count)):"
    foreach ($failure in $failures) { Write-Host " - $failure" }
    exit 1
}
Write-Host 'shift-policy-logic passed'
exit 0
