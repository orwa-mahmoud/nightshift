# Portable PowerShell coverage for native provisioning recovery on Windows.
# Run on macOS or Windows: pwsh -File tests/windows/provision-recover-logic.ps1
#
# Covers the frozen 02B interface: the transaction document, rollback from the
# blob store and from the recorded base64, created files removed and empty
# parents pruned, the proof that leaves an unproven tree alone, the late stages
# finishing natively with a real setup commit, the malformed transaction that
# names its field, the forced rollback, the read-only diagnosis, and the Doctor
# diagnosis line.
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if (Test-Path Variable:PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $false
}

$repository = Resolve-Path (Join-Path $PSScriptRoot '../..')
$plugin = Join-Path $repository 'plugins/nightshift'
$helper = Join-Path $plugin 'runtime/windows/provision.ps1'
$doctor = Join-Path $plugin 'runtime/windows/doctor.ps1'
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
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [hashtable]$Environment = @{}
    )
    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $FileName
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    Set-ProcessArguments -StartInfo $psi -Arguments $Arguments
    foreach ($name in @($psi.EnvironmentVariables.Keys)) {
        if ([string]$name -like 'NIGHTSHIFT_*') { $psi.EnvironmentVariables.Remove([string]$name) }
    }
    foreach ($name in @($Environment.Keys)) {
        $psi.EnvironmentVariables[[string]$name] = [string]$Environment[$name]
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
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [hashtable]$Environment = @{}
    )
    $psArgs = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $Path) + $Arguments
    return Invoke-ProcessBytes -FileName $hostExecutable -Arguments $psArgs -Environment $Environment
}

function Invoke-Provision {
    param(
        [Parameter(Mandatory = $true)][string]$Workspace,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )
    return Invoke-Script -Path $helper -Arguments (@('-Project', $Workspace) + $Arguments)
}

function Get-JsonLine {
    param([Parameter(Mandatory = $true)]$Result)
    return ([string]$Result.StdoutText).TrimEnd("`n")
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

function Expect-WireFormat {
    param([Parameter(Mandatory = $true)]$Result, [Parameter(Mandatory = $true)][string]$Label)
    Expect-True (Test-NSNoCarriageReturn $Result.StdoutBytes) "$Label is LF-only"
    Expect-True (Test-NSSingleTrailingNewline $Result.StdoutBytes) "$Label ends with one newline"
    Expect-True (-not (Test-NSHasBom $Result.StdoutBytes)) "$Label has no BOM"
    Expect-True (Test-NSAsciiOnly $Result.StdoutBytes) "$Label is ASCII only"
}

function Write-TestJson {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)]$Document)
    [IO.File]::WriteAllText($Path, ((ConvertTo-NSCanonicalJson $Document) + "`n"), $utf8)
}

function Write-TestText {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        $null = New-Item -ItemType Directory -Path $parent -Force
    }
    [IO.File]::WriteAllText($Path, $Text, $utf8)
}

# A scaffolded workspace beside a real Git work target: the shipped rules, one
# commit, and the recorded work-target the resolver reads.
function New-TestProject {
    param([Parameter(Mandatory = $true)][string]$Path)
    $ns = Join-Path $Path '.nightshift'
    $null = New-Item -ItemType Directory -Path $ns -Force
    Copy-Item -LiteralPath $rulesTemplate -Destination (Join-Path $ns 'rules.json')
    $repo = Join-Path $Path 'code repo'
    $null = New-Item -ItemType Directory -Path $repo -Force
    $init = Invoke-NSGitCommand $repo @('init', '--quiet')
    if ($init.ExitCode -ne 0) { throw ('git init failed: ' + $init.Text) }
    $null = Invoke-NSGitCommand $repo @('config', 'core.autocrlf', 'false')
    $null = Invoke-NSGitCommand $repo @('config', 'commit.gpgsign', 'false')
    $null = Invoke-NSGitCommand $repo @('config', 'user.email', 'dev@example.com')
    $null = Invoke-NSGitCommand $repo @('config', 'user.name', 'Nightshift Test')
    Write-TestText (Join-Path $repo 'package.json') "{}`n"
    $null = Invoke-NSGitCommand $repo @('add', '--', 'package.json')
    $seed = Invoke-NSGitCommand $repo @('commit', '--quiet', '-m', 'init')
    if ($seed.ExitCode -ne 0) { throw ('initial commit failed: ' + $seed.Text) }
    Write-NSWorkTarget -Workspace $Path -Repository $repo -Mode 'repository'
    $project = New-NSOrdinalMap
    $project['workspace'] = Get-NSAbsolutePath $Path
    $project['ns'] = Join-NSPath (Get-NSAbsolutePath $Path) '.nightshift'
    $project['transaction'] = Join-NSPath $project['ns'] 'provision-transaction.json'
    $project['store'] = Join-NSPath $project['ns'] 'provision-baseline'
    $project['inventory'] = Join-NSPath $project['ns'] 'capabilities.json'
    # The recorded target is the resolver's answer, not the string we joined:
    # a temporary directory can reach the same repository by two paths.
    $project['target'] = Resolve-NSWorkTarget $Path
    return $project
}

function New-TestPolicy {
    param(
        [string]$ToolingPolicy = 'existing-tools',
        $Allowances = @()
    )
    $policy = New-NSOrdinalMap
    $policy['schemaVersion'] = 1
    $policy['shiftId'] = '0123456789abcdef'
    $policy['createdAt'] = '2026-09-02T00:00:00Z'
    $policy['source'] = 'composition'
    $policy['deadlineEpoch'] = $null
    $policy['verificationLevel'] = 'none'
    $policy['toolingPolicy'] = $ToolingPolicy
    $policy['allowances'] = $Allowances
    return $policy
}

function New-TestAllowance {
    param([Parameter(Mandatory = $true)][string]$Category)
    $allowance = New-NSOrdinalMap
    $allowance['category'] = $Category
    $allowance['scope'] = 'category'
    $allowance['provenance'] = 'one-shift'
    return $allowance
}

function New-TestCommandStep {
    param([Parameter(Mandatory = $true)][string]$Command)
    $step = New-NSOrdinalMap
    $step['command'] = $Command
    return $step
}

function New-TestRecipe {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$Capability = 'fixture-lint',
        [string[]]$Ecosystems = @('javascript-typescript'),
        [string[]]$AllowedFiles = @('nightshift-fake.txt'),
        [string]$SafetyClass = 'local-dev-free',
        [string]$Smoke = 'true',
        [AllowEmptyCollection()][string[]]$ElevationCategories = @()
    )
    $recipe = New-NSOrdinalMap
    $recipe['capabilityId'] = $Capability
    $recipe['ecosystems'] = $Ecosystems
    $constraints = New-NSOrdinalMap
    $constraints['node'] = '>=18'
    $recipe['versionConstraints'] = $constraints
    $recipe['detect'] = New-TestCommandStep 'true'
    $recipe['probe'] = New-TestCommandStep 'true'
    $recipe['packageManagerAdditions'] = @()
    $recipe['allowedFiles'] = $AllowedFiles
    $config = New-NSOrdinalMap
    foreach ($rel in $AllowedFiles) { $config[$rel] = "ok`n" }
    $recipe['minimalConfig'] = $config
    $recipe['smoke'] = New-TestCommandStep $Smoke
    $recipe['rollback'] = New-TestCommandStep 'true'
    $recipe['enabledShifts'] = @('quality')
    $recipe['safetyClass'] = $SafetyClass
    $recipe['permissionRequirements'] = @()
    $recipe['recipeVersion'] = '1'
    if ($ElevationCategories.Count -gt 0) { $recipe['elevationCategories'] = $ElevationCategories }
    Write-TestJson $Path $recipe
    return $Path
}

function New-TestTransaction {
    param(
        [Parameter(Mandatory = $true)][string]$Stage,
        [Parameter(Mandatory = $true)][string]$Target,
        [string]$Capability = 'fixture-lint',
        [AllowEmptyString()][string]$RecipePath = '',
        [AllowEmptyCollection()][string[]]$Touched = @(),
        $Baseline = $null,
        [bool]$Failed = $false
    )
    $transaction = New-NSOrdinalMap
    $transaction['schemaVersion'] = 1
    $transaction['stage'] = $Stage
    $transaction['capabilityId'] = $Capability
    $transaction['recipePath'] = $RecipePath
    $transaction['recipeVersion'] = '1'
    $transaction['workTarget'] = $Target
    $transaction['allowedFiles'] = @()
    if ($null -eq $Baseline) { $transaction['baseline'] = New-NSOrdinalMap } else { $transaction['baseline'] = $Baseline }
    $transaction['gitPorcelain'] = @()
    $transaction['touched'] = $Touched
    $transaction['failed'] = $Failed
    $transaction['lastError'] = $null
    $transaction['setupCommit'] = ''
    $transaction['startedAt'] = '2026-09-02T00:00:00Z'
    $transaction['updatedAt'] = '2026-09-02T00:00:00Z'
    return $transaction
}

function New-TestBaselineExisted {
    param(
        [Parameter(Mandatory = $true)][string]$Rel,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text,
        [switch]$NoBlob,
        [switch]$NoContent,
        [AllowEmptyString()][string]$Digest = ''
    )
    $meta = New-NSOrdinalMap
    $meta['existed'] = $true
    if ([string]::IsNullOrEmpty($Digest)) {
        $meta['digest'] = Get-NSTextSha256 $Text
    }
    else {
        $meta['digest'] = $Digest
    }
    if ($NoBlob.IsPresent) {
        $meta['blob'] = $null
    }
    else {
        $meta['blob'] = (Get-NSTextSha256 (Get-NSProvisionRelPath $Rel))
    }
    if ($NoContent.IsPresent) {
        $meta['content'] = $null
    }
    else {
        $meta['content'] = [Convert]::ToBase64String($utf8.GetBytes($Text))
    }
    return $meta
}

function New-TestBaselineCreated {
    $meta = New-NSOrdinalMap
    $meta['existed'] = $false
    $meta['digest'] = $null
    $meta['blob'] = $null
    $meta['content'] = $null
    return $meta
}

function Write-TestBlob {
    param(
        [Parameter(Mandatory = $true)][string]$Store,
        [Parameter(Mandatory = $true)][string]$Rel,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text
    )
    $null = New-Item -ItemType Directory -Path $Store -Force
    [IO.File]::WriteAllBytes((Join-Path $Store ((Get-NSTextSha256 (Get-NSProvisionRelPath $Rel)))), $utf8.GetBytes($Text))
}

function Get-TestFileText {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    return [IO.File]::ReadAllText($Path, $utf8)
}

$root = Join-Path ([IO.Path]::GetTempPath()) ('ns-provision-recover-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $root -Force
try {
    # === 1. no transaction ===
    $empty = New-TestProject (Join-Path $root 'no transaction')
    $emptyRecover = Invoke-Provision $empty['workspace'] @('recover')
    Expect-Equal 0 $emptyRecover.ExitCode "recover with no transaction exits 0 ($($emptyRecover.StderrText))"
    Expect-Equal '{"detail":"no transaction","ok":true,"recovered":false}' (Get-JsonLine $emptyRecover) `
        'recover with no transaction reports the frozen object'
    Expect-WireFormat $emptyRecover 'the recovery JSON'
    $emptyRollback = Invoke-Provision $empty['workspace'] @('rollback')
    Expect-Equal 0 $emptyRollback.ExitCode 'rollback with no transaction exits 0'
    Expect-Equal '{"detail":"no transaction","ok":true,"recovered":false}' (Get-JsonLine $emptyRollback) `
        'both verbs answer from the one recovery helper'

    # === 2. rollback restores bytes from the blob store ===
    $blobProject = New-TestProject (Join-Path $root 'rollback from blob')
    $blobTarget = $blobProject['target']
    $blobRel = 'tools/keep.txt'
    $blobPath = Join-Path $blobTarget $blobRel
    Write-TestText $blobPath "owner bytes`n"
    $null = Invoke-NSGitCommand $blobTarget @('add', '--', $blobRel)
    $null = Invoke-NSGitCommand $blobTarget @('commit', '--quiet', '-m', 'owner file')
    Write-TestBlob -Store $blobProject['store'] -Rel $blobRel -Text "owner bytes`n"
    Write-TestText $blobPath "engine bytes`n"
    $blobBaseline = New-NSOrdinalMap
    $blobBaseline[$blobRel] = New-TestBaselineExisted -Rel $blobRel -Text "owner bytes`n" -NoContent
    Write-TestJson $blobProject['transaction'] (New-TestTransaction -Stage 'apply' -Target $blobTarget `
            -Touched @($blobRel) -Baseline $blobBaseline)
    $blobRun = Invoke-Provision $blobProject['workspace'] @('recover')
    Expect-Equal 0 $blobRun.ExitCode "a proven rollback exits 0 ($($blobRun.StderrText))"
    Expect-Equal '{"capabilityId":"fixture-lint","ok":true,"proven":true,"rolledBack":true,"touched":["tools/keep.txt"]}' `
    (Get-JsonLine $blobRun) 'a proven rollback reports the frozen object'
    Expect-Equal "owner bytes`n" (Get-TestFileText $blobPath) 'rollback restores the owner bytes from the blob store'
    Expect-True (-not (Test-Path -LiteralPath $blobProject['transaction'])) 'a proven rollback clears the transaction'
    Expect-True (-not (Test-Path -LiteralPath $blobProject['store'])) 'a proven rollback clears the blob store'

    # === 3. rollback restores bytes from the recorded base64 ===
    $contentProject = New-TestProject (Join-Path $root 'rollback from content')
    $contentTarget = $contentProject['target']
    $storeless = 'config/keep.json'
    $stalePath = 'config/stale.json'
    Write-TestText (Join-Path $contentTarget $storeless) "owner config`n"
    Write-TestText (Join-Path $contentTarget $stalePath) "owner stale`n"
    $null = Invoke-NSGitCommand $contentTarget @('add', '--', 'config')
    $null = Invoke-NSGitCommand $contentTarget @('commit', '--quiet', '-m', 'owner config')
    Write-TestText (Join-Path $contentTarget $storeless) "engine wrote this`n"
    Write-TestText (Join-Path $contentTarget $stalePath) "engine wrote this too`n"
    $contentBaseline = New-NSOrdinalMap
    # No blob recorded at all.
    $contentBaseline[$storeless] = New-TestBaselineExisted -Rel $storeless -Text "owner config`n" -NoBlob
    # A blob recorded but missing from the store: the base64 copy is the fallback.
    $contentBaseline[$stalePath] = New-TestBaselineExisted -Rel $stalePath -Text "owner stale`n"
    Write-TestJson $contentProject['transaction'] (New-TestTransaction -Stage 'smoke' -Target $contentTarget `
            -Touched @($storeless, $stalePath) -Baseline $contentBaseline)
    $contentRun = Invoke-Provision $contentProject['workspace'] @('recover')
    Expect-Equal 0 $contentRun.ExitCode "a rollback from recorded bytes exits 0 ($($contentRun.StderrText))"
    Expect-Equal "owner config`n" (Get-TestFileText (Join-Path $contentTarget $storeless)) `
        'rollback restores from the recorded base64 when no blob is named'
    Expect-Equal "owner stale`n" (Get-TestFileText (Join-Path $contentTarget $stalePath)) `
        'rollback falls back to the recorded base64 when the blob file is gone'

    # === 4. created files are removed and empty parents pruned ===
    $createdProject = New-TestProject (Join-Path $root 'created removed')
    $createdTarget = $createdProject['target']
    $createdRel = 'deep/nested/new.txt'
    $sharedRel = 'keep/generated.txt'
    Write-TestText (Join-Path $createdTarget $createdRel) "engine`n"
    Write-TestText (Join-Path $createdTarget $sharedRel) "engine`n"
    Write-TestText (Join-Path $createdTarget 'keep/owner.txt') "owner`n"
    $createdBaseline = New-NSOrdinalMap
    $createdBaseline[$createdRel] = New-TestBaselineCreated
    $createdBaseline[$sharedRel] = New-TestBaselineCreated
    Write-TestJson $createdProject['transaction'] (New-TestTransaction -Stage 'apply' -Target $createdTarget `
            -Touched @($createdRel, $sharedRel) -Baseline $createdBaseline)
    $createdRun = Invoke-Provision $createdProject['workspace'] @('recover')
    Expect-Equal 0 $createdRun.ExitCode "removing created files exits 0 ($($createdRun.StderrText))"
    Expect-True (-not (Test-Path -LiteralPath (Join-Path $createdTarget $createdRel))) 'a created file is removed'
    Expect-True (-not (Test-Path -LiteralPath (Join-Path $createdTarget 'deep/nested'))) 'an emptied parent is pruned'
    Expect-True (-not (Test-Path -LiteralPath (Join-Path $createdTarget 'deep'))) 'pruning walks up while parents stay empty'
    Expect-True (Test-Path -LiteralPath (Join-Path $createdTarget 'keep') -PathType Container) `
        'a parent that still holds owner work survives'
    Expect-Equal "owner`n" (Get-TestFileText (Join-Path $createdTarget 'keep/owner.txt')) 'owner work is untouched'
    Expect-True (Test-Path -LiteralPath $createdTarget -PathType Container) 'pruning stops at the work target'

    # === 5. an unproven restore leaves everything in place and exits 3 ===
    $unprovenProject = New-TestProject (Join-Path $root 'unproven digest')
    $unprovenTarget = $unprovenProject['target']
    $unprovenRel = 'tools/lost.txt'
    Write-TestText (Join-Path $unprovenTarget $unprovenRel) "engine bytes`n"
    $unprovenBaseline = New-NSOrdinalMap
    # Neither the store nor the transaction can produce the recorded bytes.
    $unprovenBaseline[$unprovenRel] = New-TestBaselineExisted -Rel $unprovenRel -Text "owner bytes`n" -NoBlob -NoContent
    Write-TestJson $unprovenProject['transaction'] (New-TestTransaction -Stage 'apply' -Target $unprovenTarget `
            -Touched @($unprovenRel) -Baseline $unprovenBaseline)
    Write-TestBlob -Store $unprovenProject['store'] -Rel 'unrelated.txt' -Text "keep`n"
    $unprovenRun = Invoke-Provision $unprovenProject['workspace'] @('recover')
    Expect-Equal 3 $unprovenRun.ExitCode "an unproven restore exits 3 ($($unprovenRun.StderrText))"
    Expect-Equal '{"detail":"restored bytes do not match baseline digest: tools/lost.txt","ok":false,"proven":false,"rolledBack":false}' `
    (Get-JsonLine $unprovenRun) 'an unproven restore names the first mismatch'
    Expect-Equal "engine bytes`n" (Get-TestFileText (Join-Path $unprovenTarget $unprovenRel)) `
        'nothing to restore from leaves the file alone'
    Expect-True (Test-Path -LiteralPath $unprovenProject['transaction'] -PathType Leaf) `
        'an unproven restore leaves the transaction in place'
    Expect-True (Test-Path -LiteralPath $unprovenProject['store'] -PathType Container) `
        'an unproven restore leaves the blob store in place'

    $missingProject = New-TestProject (Join-Path $root 'unproven missing')
    $missingTarget = $missingProject['target']
    $missingBaseline = New-NSOrdinalMap
    $missingBaseline['tools/gone.txt'] = New-TestBaselineExisted -Rel 'tools/gone.txt' -Text "owner bytes`n" -NoBlob -NoContent
    Write-TestJson $missingProject['transaction'] (New-TestTransaction -Stage 'apply' -Target $missingTarget `
            -Baseline $missingBaseline)
    $missingRun = Invoke-Provision $missingProject['workspace'] @('recover')
    Expect-Equal 3 $missingRun.ExitCode 'a baseline file that cannot be put back exits 3'
    Expect-Equal '{"detail":"baseline file missing after restore: tools/gone.txt","ok":false,"proven":false,"rolledBack":false}' `
    (Get-JsonLine $missingRun) 'the proof reports a baseline file that never came back'

    $directoryProject = New-TestProject (Join-Path $root 'unproven directory')
    $directoryTarget = $directoryProject['target']
    $null = New-Item -ItemType Directory -Path (Join-Path $directoryTarget 'tools/held.txt') -Force
    Write-TestBlob -Store $directoryProject['store'] -Rel 'tools/held.txt' -Text "owner bytes`n"
    $directoryBaseline = New-NSOrdinalMap
    $directoryBaseline['tools/held.txt'] = New-TestBaselineExisted -Rel 'tools/held.txt' -Text "owner bytes`n" -NoContent
    Write-TestJson $directoryProject['transaction'] (New-TestTransaction -Stage 'apply' -Target $directoryTarget `
            -Baseline $directoryBaseline)
    $directoryRun = Invoke-Provision $directoryProject['workspace'] @('recover')
    Expect-Equal 3 $directoryRun.ExitCode 'a directory where a baseline file belongs exits 3'
    Expect-Equal '{"detail":"a directory blocks the baseline path: tools/held.txt","ok":false,"proven":false,"rolledBack":false}' `
    (Get-JsonLine $directoryRun) 'the proof reports a directory blocking the baseline path'
    Expect-True (Test-Path -LiteralPath (Join-Path $directoryTarget 'tools/held.txt') -PathType Container) `
        'a blocking directory is never deleted'

    $blockedProject = New-TestProject (Join-Path $root 'unproven leftover')
    $blockedTarget = $blockedProject['target']
    $null = New-Item -ItemType Directory -Path (Join-Path $blockedTarget 'blocked') -Force
    Write-TestText (Join-Path $blockedTarget 'blocked/owner.txt') "owner`n"
    $blockedBaseline = New-NSOrdinalMap
    $blockedBaseline['blocked'] = New-TestBaselineCreated
    Write-TestJson $blockedProject['transaction'] (New-TestTransaction -Stage 'apply' -Target $blockedTarget `
            -Baseline $blockedBaseline)
    $blockedRun = Invoke-Provision $blockedProject['workspace'] @('recover')
    Expect-Equal 3 $blockedRun.ExitCode 'a path that could not be removed exits 3'
    Expect-Equal '{"detail":"created path still present: blocked","ok":false,"proven":false,"rolledBack":false}' `
    (Get-JsonLine $blockedRun) 'the proof reports a created path that is still there'
    Expect-Equal "owner`n" (Get-TestFileText (Join-Path $blockedTarget 'blocked/owner.txt')) `
        'an unproven rollback never deletes owner work'

    # === 6. the late stages finish natively with a real setup commit ===
    $finishProject = New-TestProject (Join-Path $root 'finish record')
    $finishTarget = $finishProject['target']
    $finishRecipe = New-TestRecipe (Join-Path $root 'finish-recipe.json')
    Write-TestText (Join-Path $finishTarget 'nightshift-fake.txt') "ok`n"
    Write-TestBlob -Store $finishProject['store'] -Rel 'nightshift-fake.txt' -Text "ok`n"
    $finishBaseline = New-NSOrdinalMap
    $finishBaseline['nightshift-fake.txt'] = New-TestBaselineCreated
    Write-TestJson $finishProject['transaction'] (New-TestTransaction -Stage 'record' -Target $finishTarget `
            -RecipePath $finishRecipe -Touched @('nightshift-fake.txt') -Baseline $finishBaseline)
    $finishRun = Invoke-Provision $finishProject['workspace'] @('recover')
    Expect-Equal 0 $finishRun.ExitCode "finishing the late stages exits 0 ($($finishRun.StderrText))"
    $finishHead = Invoke-NSGit $finishTarget @('rev-parse', 'HEAD')
    Expect-Equal ('{"capabilityId":"fixture-lint","finished":true,"ok":true,"recovered":true,"setupCommit":"' +
        $finishHead + '","touched":["nightshift-fake.txt"]}') (Get-JsonLine $finishRun) `
        'a finished recovery reports the frozen object with the setup commit'
    Expect-Equal 'chore(tooling): fixture-lint' (Invoke-NSGit $finishTarget @('log', '-1', '--format=%s')) `
        'the late stages commit the tooling under one subject'
    $finishPorcelain = Invoke-NSGitCommand $finishTarget @('status', '--porcelain', '--', 'nightshift-fake.txt')
    Expect-Equal '' $finishPorcelain.Text 'the allowed file is committed, not left dirty'
    Expect-True (-not (Test-Path -LiteralPath $finishProject['transaction'])) 'finishing clears the transaction'
    Expect-True (-not (Test-Path -LiteralPath $finishProject['store'])) 'finishing clears the blob store too'
    Expect-True (Test-Path -LiteralPath $finishProject['inventory'] -PathType Leaf) 'record writes the inventory'
    $inventoryBytes = [IO.File]::ReadAllBytes($finishProject['inventory'])
    Expect-True (Test-NSNoCarriageReturn $inventoryBytes) 'the inventory is LF-only'
    Expect-True (Test-NSSingleTrailingNewline $inventoryBytes) 'the inventory ends with one newline'
    Expect-True (-not (Test-NSHasBom $inventoryBytes)) 'the inventory has no BOM'
    $inventory = ConvertFrom-NSJsonText ([IO.File]::ReadAllText($finishProject['inventory'], $utf8))
    Expect-Equal 1 $inventory['schemaVersion'] 'the inventory carries schemaVersion 1'
    Expect-Equal 'default' $inventory['source'] 'a fresh inventory keeps the default source'
    Expect-Equal 'False' $inventory['tickProof'] 'the inventory never claims tick proof'
    Expect-True ([string]$inventory['updatedAt'] -cmatch '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$') `
        'the inventory stamps updatedAt in UTC'
    Expect-Equal 1 @($inventory['items']).Count 'the inventory holds one row per capability'
    $row = @($inventory['items'])[0]
    Expect-Equal 'fixture-lint' $row['capability'] 'the row names the capability'
    Expect-Equal 'true' $row['command'] 'the row records the smoke command'
    Expect-Equal 'recipe' $row['source'] 'the row is sourced to the recipe'
    Expect-Equal '1' $row['recipeVersion'] 'the row records the recipe version'
    Expect-Equal $finishHead $row['setupCommit'] 'the row records the setup commit'
    Expect-Equal 'nightshift-fake.txt' (@($row['configFiles'])[0]) 'the row lists the config files'
    $inventoryText = [IO.File]::ReadAllText($finishProject['inventory'], $utf8)
    Expect-True $inventoryText.Contains('  "capability": "fixture-lint"') 'the inventory is pretty-printed with two spaces'
    Expect-True ($inventoryText.IndexOf('"capability"', [StringComparison]::Ordinal) -lt
        $inventoryText.IndexOf('"command"', [StringComparison]::Ordinal)) 'the inventory sorts its keys'

    # === 7. commit-tooling with nothing allowed to commit ===
    $nothingProject = New-TestProject (Join-Path $root 'finish nothing')
    $nothingTarget = $nothingProject['target']
    $nothingRecipe = New-TestRecipe (Join-Path $root 'nothing-recipe.json')
    $nothingHeadBefore = Invoke-NSGit $nothingTarget @('rev-parse', 'HEAD')
    Write-TestJson $nothingProject['transaction'] (New-TestTransaction -Stage 'commit-tooling' -Target $nothingTarget `
            -RecipePath $nothingRecipe)
    $nothingRun = Invoke-Provision $nothingProject['workspace'] @('recover')
    Expect-Equal 0 $nothingRun.ExitCode "finishing with nothing staged exits 0 ($($nothingRun.StderrText))"
    Expect-Equal '{"capabilityId":"fixture-lint","finished":true,"ok":true,"recovered":true,"setupCommit":"","touched":[]}' `
    (Get-JsonLine $nothingRun) 'nothing staged is not a failure and not a commit'
    Expect-Equal $nothingHeadBefore (Invoke-NSGit $nothingTarget @('rev-parse', 'HEAD')) `
        'nothing staged leaves the history alone'

    # === 8. the rollback verb undoes a late stage; a failed transaction always rolls back ===
    $forcedProject = New-TestProject (Join-Path $root 'forced rollback')
    $forcedTarget = $forcedProject['target']
    $forcedRecipe = New-TestRecipe (Join-Path $root 'forced-recipe.json')
    Write-TestText (Join-Path $forcedTarget 'nightshift-fake.txt') "ok`n"
    $forcedBaseline = New-NSOrdinalMap
    $forcedBaseline['nightshift-fake.txt'] = New-TestBaselineCreated
    Write-TestJson $forcedProject['transaction'] (New-TestTransaction -Stage 'commit-tooling' -Target $forcedTarget `
            -RecipePath $forcedRecipe -Touched @('nightshift-fake.txt') -Baseline $forcedBaseline)
    $forcedHeadBefore = Invoke-NSGit $forcedTarget @('rev-parse', 'HEAD')
    $forcedRun = Invoke-Provision $forcedProject['workspace'] @('rollback')
    Expect-Equal 0 $forcedRun.ExitCode "the rollback verb exits 0 ($($forcedRun.StderrText))"
    Expect-Equal '{"capabilityId":"fixture-lint","ok":true,"proven":true,"rolledBack":true,"touched":["nightshift-fake.txt"]}' `
    (Get-JsonLine $forcedRun) 'the rollback verb undoes a late stage instead of finishing it'
    Expect-True (-not (Test-Path -LiteralPath (Join-Path $forcedTarget 'nightshift-fake.txt'))) `
        'the rollback verb removes what the engine created'
    Expect-Equal $forcedHeadBefore (Invoke-NSGit $forcedTarget @('rev-parse', 'HEAD')) `
        'the rollback verb writes no setup commit'

    $flagProject = New-TestProject (Join-Path $root 'rollback flag')
    $flagTarget = $flagProject['target']
    $flagRecipe = New-TestRecipe (Join-Path $root 'flag-recipe.json')
    Write-TestText (Join-Path $flagTarget 'nightshift-fake.txt') "ok`n"
    $flagBaseline = New-NSOrdinalMap
    $flagBaseline['nightshift-fake.txt'] = New-TestBaselineCreated
    Write-TestJson $flagProject['transaction'] (New-TestTransaction -Stage 'record' -Target $flagTarget `
            -RecipePath $flagRecipe -Touched @('nightshift-fake.txt') -Baseline $flagBaseline)
    $flagRun = Invoke-Provision $flagProject['workspace'] @('recover', '-Rollback')
    Expect-Equal 0 $flagRun.ExitCode "recover -Rollback exits 0 ($($flagRun.StderrText))"
    Expect-True ((Get-JsonLine $flagRun).Contains('"rolledBack":true')) `
        'recover -Rollback forces the undo whatever the stage'
    Expect-True (-not (Test-Path -LiteralPath $flagProject['inventory'])) 'a forced rollback records no capability'

    $failedProject = New-TestProject (Join-Path $root 'failed late stage')
    $failedTarget = $failedProject['target']
    $failedRecipe = New-TestRecipe (Join-Path $root 'failed-recipe.json')
    Write-TestText (Join-Path $failedTarget 'nightshift-fake.txt') "ok`n"
    $failedBaseline = New-NSOrdinalMap
    $failedBaseline['nightshift-fake.txt'] = New-TestBaselineCreated
    Write-TestJson $failedProject['transaction'] (New-TestTransaction -Stage 'record' -Target $failedTarget `
            -RecipePath $failedRecipe -Touched @('nightshift-fake.txt') -Baseline $failedBaseline -Failed $true)
    $failedRun = Invoke-Provision $failedProject['workspace'] @('recover')
    Expect-Equal 0 $failedRun.ExitCode "a failed late stage rolls back and exits 0 ($($failedRun.StderrText))"
    Expect-True ((Get-JsonLine $failedRun).Contains('"rolledBack":true')) 'a failed transaction rolls back rather than finishes'
    Expect-True (-not (Test-Path -LiteralPath $failedProject['inventory'])) 'a rolled-back transaction records no capability'

    $orphanProject = New-TestProject (Join-Path $root 'missing recipe')
    $orphanTarget = $orphanProject['target']
    Write-TestText (Join-Path $orphanTarget 'nightshift-fake.txt') "ok`n"
    $orphanBaseline = New-NSOrdinalMap
    $orphanBaseline['nightshift-fake.txt'] = New-TestBaselineCreated
    Write-TestJson $orphanProject['transaction'] (New-TestTransaction -Stage 'record' -Target $orphanTarget `
            -RecipePath (Join-Path $root 'absent-recipe.json') -Touched @('nightshift-fake.txt') -Baseline $orphanBaseline)
    $orphanRun = Invoke-Provision $orphanProject['workspace'] @('recover')
    Expect-Equal 0 $orphanRun.ExitCode 'a late stage with no readable recipe rolls back'
    Expect-True ((Get-JsonLine $orphanRun).Contains('"rolledBack":true')) 'a late stage cannot finish without its recipe'

    # === 9. a malformed transaction names its field and touches nothing ===
    $malformed = New-TestProject (Join-Path $root 'malformed')
    $malformedTarget = $malformed['target']
    $guardRel = 'tools/guard.txt'
    Write-TestText (Join-Path $malformedTarget $guardRel) "owner bytes`n"
    Write-TestBlob -Store $malformed['store'] -Rel $guardRel -Text "owner bytes`n"

    [IO.File]::WriteAllText($malformed['transaction'], '{"stage":', $utf8)
    $brokenRun = Invoke-Provision $malformed['workspace'] @('recover')
    Expect-Equal 2 $brokenRun.ExitCode 'a transaction that is not JSON exits 2'
    Expect-Equal '{"detail":"malformed transaction: document","malformed":true,"ok":false,"recovered":false}' `
    (Get-JsonLine $brokenRun) 'a transaction that is not JSON names the document'
    Expect-Equal "owner bytes`n" (Get-TestFileText (Join-Path $malformedTarget $guardRel)) `
        'a malformed transaction touches no file'
    Expect-True (Test-Path -LiteralPath $malformed['transaction'] -PathType Leaf) 'a malformed transaction is left for the owner'
    Expect-True (Test-Path -LiteralPath $malformed['store'] -PathType Container) 'a malformed transaction keeps its blob store'

    Write-TestJson $malformed['transaction'] (New-TestTransaction -Stage 'nonsense' -Target $malformedTarget)
    $stageRun = Invoke-Provision $malformed['workspace'] @('recover')
    Expect-Equal 2 $stageRun.ExitCode 'an unknown stage exits 2'
    Expect-Equal '{"detail":"malformed transaction: stage","malformed":true,"ok":false,"recovered":false}' `
    (Get-JsonLine $stageRun) 'an unknown stage is named'

    $noCapability = New-TestTransaction -Stage 'apply' -Target $malformedTarget
    $noCapability['capabilityId'] = ''
    Write-TestJson $malformed['transaction'] $noCapability
    $capabilityRun = Invoke-Provision $malformed['workspace'] @('recover')
    Expect-Equal 2 $capabilityRun.ExitCode 'an empty capabilityId exits 2'
    Expect-Equal '{"detail":"malformed transaction: capabilityId","malformed":true,"ok":false,"recovered":false}' `
    (Get-JsonLine $capabilityRun) 'an empty capabilityId is named'

    $badTarget = New-TestTransaction -Stage 'apply' -Target $malformedTarget
    $badTarget['workTarget'] = 4
    Write-TestJson $malformed['transaction'] $badTarget
    $targetRun = Invoke-Provision $malformed['workspace'] @('recover')
    Expect-Equal 2 $targetRun.ExitCode 'a workTarget that is not a path exits 2'
    Expect-Equal '{"detail":"malformed transaction: workTarget","malformed":true,"ok":false,"recovered":false}' `
    (Get-JsonLine $targetRun) 'a malformed workTarget is named'

    $badFailed = New-TestTransaction -Stage 'apply' -Target $malformedTarget
    $badFailed['failed'] = 'yes'
    Write-TestJson $malformed['transaction'] $badFailed
    $failedFieldRun = Invoke-Provision $malformed['workspace'] @('recover')
    Expect-Equal 2 $failedFieldRun.ExitCode 'a failed flag that is not a boolean exits 2'
    Expect-Equal '{"detail":"malformed transaction: failed","malformed":true,"ok":false,"recovered":false}' `
    (Get-JsonLine $failedFieldRun) 'a malformed failed flag is named'

    $badTouched = New-TestTransaction -Stage 'apply' -Target $malformedTarget
    $badTouched['touched'] = @(1, 2)
    Write-TestJson $malformed['transaction'] $badTouched
    $touchedRun = Invoke-Provision $malformed['workspace'] @('recover')
    Expect-Equal 2 $touchedRun.ExitCode 'a touched list that is not strings exits 2'
    Expect-Equal '{"detail":"malformed transaction: touched","malformed":true,"ok":false,"recovered":false}' `
    (Get-JsonLine $touchedRun) 'a malformed touched list is named'

    $badBaseline = New-TestTransaction -Stage 'apply' -Target $malformedTarget
    $badBaseline['baseline'] = 'nothing here'
    Write-TestJson $malformed['transaction'] $badBaseline
    $baselineRun = Invoke-Provision $malformed['workspace'] @('recover')
    Expect-Equal 2 $baselineRun.ExitCode 'a baseline that is not an object exits 2'
    Expect-Equal '{"detail":"malformed transaction: baseline","malformed":true,"ok":false,"recovered":false}' `
    (Get-JsonLine $baselineRun) 'a malformed baseline is named'

    $noExisted = New-NSOrdinalMap
    $noExisted[$guardRel] = New-NSOrdinalMap
    $noExisted[$guardRel]['digest'] = Get-NSTextSha256 "owner bytes`n"
    Write-TestJson $malformed['transaction'] (New-TestTransaction -Stage 'apply' -Target $malformedTarget -Baseline $noExisted)
    $existedRun = Invoke-Provision $malformed['workspace'] @('recover')
    Expect-Equal 2 $existedRun.ExitCode 'a baseline entry with no existed flag exits 2'
    Expect-Equal '{"detail":"malformed transaction: baseline[\"tools/guard.txt\"].existed","malformed":true,"ok":false,"recovered":false}' `
    (Get-JsonLine $existedRun) 'a baseline entry with no existed flag is named down to the field'

    $noDigest = New-NSOrdinalMap
    $noDigest[$guardRel] = New-TestBaselineExisted -Rel $guardRel -Text "owner bytes`n" -NoContent
    $noDigest[$guardRel]['digest'] = $null
    Write-TestJson $malformed['transaction'] (New-TestTransaction -Stage 'apply' -Target $malformedTarget -Baseline $noDigest)
    $digestRun = Invoke-Provision $malformed['workspace'] @('recover')
    Expect-Equal 2 $digestRun.ExitCode 'a file that existed with no recorded digest exits 2'
    Expect-Equal '{"detail":"malformed transaction: baseline[\"tools/guard.txt\"].digest","malformed":true,"ok":false,"recovered":false}' `
    (Get-JsonLine $digestRun) 'a missing digest is named down to the field'

    $badBlob = New-NSOrdinalMap
    $badBlob[$guardRel] = New-TestBaselineExisted -Rel $guardRel -Text "owner bytes`n"
    $badBlob[$guardRel]['blob'] = 'NOT-A-BLOB'
    Write-TestJson $malformed['transaction'] (New-TestTransaction -Stage 'apply' -Target $malformedTarget -Baseline $badBlob)
    $blobRunField = Invoke-Provision $malformed['workspace'] @('recover')
    Expect-Equal 2 $blobRunField.ExitCode 'a blob that is not a store address exits 2'
    Expect-Equal '{"detail":"malformed transaction: baseline[\"tools/guard.txt\"].blob","malformed":true,"ok":false,"recovered":false}' `
    (Get-JsonLine $blobRunField) 'a malformed blob address is named down to the field'

    $escaping = New-NSOrdinalMap
    $escaping['tools/../../outside.txt'] = New-TestBaselineCreated
    Write-TestJson $malformed['transaction'] (New-TestTransaction -Stage 'apply' -Target $malformedTarget -Baseline $escaping)
    $escapeRun = Invoke-Provision $malformed['workspace'] @('recover')
    Expect-Equal 2 $escapeRun.ExitCode 'a baseline path outside the work target exits 2'
    Expect-True ((Get-JsonLine $escapeRun).Contains('baseline[\"tools/../../outside.txt\"]')) `
        'a path outside the work target is named as the entry'
    Expect-True (Test-Path -LiteralPath (Join-Path $malformedTarget $guardRel) -PathType Leaf) `
        'a baseline path outside the work target restores nothing'

    $ownerFile = New-NSOrdinalMap
    $ownerFile['.nightshift/punch-list.md'] = New-TestBaselineCreated
    Write-TestJson $malformed['transaction'] (New-TestTransaction -Stage 'apply' -Target $malformedTarget -Baseline $ownerFile)
    $ownerRun = Invoke-Provision $malformed['workspace'] @('recover')
    Expect-Equal 2 $ownerRun.ExitCode 'a baseline naming an owner file exits 2'

    # The digest is compared, never shape-checked, so a wrong one is an unproven
    # restore rather than a malformed document.
    $wrongDigest = New-NSOrdinalMap
    $wrongDigest[$guardRel] = New-TestBaselineExisted -Rel $guardRel -Text "owner bytes`n" -Digest 'not-a-digest'
    Write-TestJson $malformed['transaction'] (New-TestTransaction -Stage 'apply' -Target $malformedTarget -Baseline $wrongDigest)
    $wrongDigestRun = Invoke-Provision $malformed['workspace'] @('recover')
    Expect-Equal 3 $wrongDigestRun.ExitCode 'a digest that no bytes can match is unproven, not malformed'
    Expect-Equal '{"detail":"restored bytes do not match baseline digest: tools/guard.txt","ok":false,"proven":false,"rolledBack":false}' `
    (Get-JsonLine $wrongDigestRun) 'the digest is compared, never shape-checked'

    Write-TestText (Join-Path $malformedTarget $guardRel) "engine bytes`n"
    $badContent = New-NSOrdinalMap
    $badContent[$guardRel] = New-TestBaselineExisted -Rel $guardRel -Text "owner bytes`n" -NoBlob
    $badContent[$guardRel]['content'] = 'not base64 at all'
    Write-TestJson $malformed['transaction'] (New-TestTransaction -Stage 'apply' -Target $malformedTarget -Baseline $badContent)
    $contentFieldRun = Invoke-Provision $malformed['workspace'] @('recover')
    Expect-Equal 3 $contentFieldRun.ExitCode 'baseline bytes that do not decode leave an unproven tree'
    Expect-Equal "engine bytes`n" (Get-TestFileText (Join-Path $malformedTarget $guardRel)) `
        'undecodable baseline bytes never overwrite the tree'

    # === 10. the seatbelt takes four verbs and nothing else ===
    $planProject = New-TestProject (Join-Path $root 'refused verbs')
    $planTarget = $planProject['target']
    Write-TestJson (Join-Path $planProject['ns'] 'shift-policy.json') (New-TestPolicy -ToolingPolicy 'auto-add')
    foreach ($verb in @('plan', 'apply', 'install')) {
        $refused = Invoke-Provision $planProject['workspace'] @($verb)
        Expect-Equal 1 $refused.ExitCode ($verb + ' is not a seatbelt verb')
        Expect-True $refused.StderrText.Contains('provision.ps1 -Project DIR -Command diff') `
        ($verb + ' prints the seatbelt usage')
        Expect-True (-not (Test-Path -LiteralPath $planProject['transaction'])) `
        ($verb + ' opens no transaction')
        Expect-True (-not (Test-Path -LiteralPath (Join-Path $planTarget 'nightshift-fake.txt'))) `
        ($verb + ' writes nothing into the work target')
    }


    # === 13. the Doctor diagnosis ===
    $doctorProject = New-TestProject (Join-Path $root 'doctor')
    $doctorTarget = $doctorProject['target']
    $doctorRel = 'tools/doctor.txt'
    Write-TestText (Join-Path $doctorTarget $doctorRel) "owner bytes`n"
    Write-TestBlob -Store $doctorProject['store'] -Rel $doctorRel -Text "owner bytes`n"
    $doctorClean = Invoke-Script -Path $doctor -Arguments @('-Project', $doctorProject['workspace'])
    Expect-Equal 0 $doctorClean.ExitCode "Doctor reports and exits 0 ($($doctorClean.StderrText))"
    Expect-True (-not $doctorClean.StdoutText.Contains('provision transaction')) `
        'Doctor says nothing about provisioning when no transaction is open'
    $diagnoseClean = Invoke-Provision $doctorProject['workspace'] @('recover', '-Diagnose')
    Expect-Equal 0 $diagnoseClean.ExitCode 'diagnose exits 0 with no transaction'
    Expect-Equal '{"detail":"no transaction","ok":true,"recovered":false}' (Get-JsonLine $diagnoseClean) `
        'with no engine transaction the seatbelt recover answers'

    $doctorBaseline = New-NSOrdinalMap
    $doctorBaseline[$doctorRel] = New-TestBaselineExisted -Rel $doctorRel -Text "owner bytes`n" -NoContent
    Write-TestJson $doctorProject['transaction'] (New-TestTransaction -Stage 'apply' -Target $doctorTarget `
            -Touched @($doctorRel) -Baseline $doctorBaseline)
    $doctorProvable = Invoke-Script -Path $doctor -Arguments @('-Project', $doctorProject['workspace'])
    Expect-Equal 0 $doctorProvable.ExitCode 'Doctor reads an open transaction and still exits 0'
    Expect-True $doctorProvable.StdoutText.Contains('provision transaction stage=apply capability=fixture-lint baseline=provable') `
        'Doctor names the stage, the capability and a provable baseline'
    Expect-True $doctorProvable.StdoutText.Contains('Doctor never recovers') `
        'Doctor points at recovery without performing it'
    $diagnoseProvable = Invoke-Provision $doctorProject['workspace'] @('recover', '-Diagnose')
    Expect-Equal 0 $diagnoseProvable.ExitCode 'diagnose reports and exits 0'
    Expect-Equal "provable`tprovision transaction stage=apply capability=fixture-lint baseline=provable" `
    (Get-JsonLine $diagnoseProvable) 'diagnose prints the class and the sentence on one tab-separated line'
    Expect-WireFormat $diagnoseProvable 'the diagnosis line'
    Expect-True (Test-Path -LiteralPath $doctorProject['transaction'] -PathType Leaf) 'diagnose changes nothing'

    $doctorUnprovable = New-NSOrdinalMap
    $doctorUnprovable[$doctorRel] = New-TestBaselineExisted -Rel $doctorRel -Text "owner bytes`n" -NoBlob -NoContent
    Write-TestJson $doctorProject['transaction'] (New-TestTransaction -Stage 'smoke' -Target $doctorTarget `
            -Touched @($doctorRel) -Baseline $doctorUnprovable)
    $doctorNot = Invoke-Script -Path $doctor -Arguments @('-Project', $doctorProject['workspace'])
    Expect-True $doctorNot.StdoutText.Contains('capability=fixture-lint baseline=unprovable') `
        'Doctor names a baseline that would not prove'
    Expect-True $doctorNot.StdoutText.Contains('Start will refuse to arm') `
        'Doctor says the shift will not arm over an unproven baseline'
    Expect-True $doctorNot.StdoutText.Contains('restore by hand or run provision.ps1 rollback after fixing the target') `
        'Doctor prints the one repair for an unproven baseline'
    $diagnoseNot = Invoke-Provision $doctorProject['workspace'] @('recover', '-Diagnose')
    Expect-Equal "unprovable`tprovision transaction stage=smoke capability=fixture-lint baseline=unprovable" `
    (Get-JsonLine $diagnoseNot) 'diagnose classes an unprovable baseline'

    Write-TestJson $doctorProject['transaction'] (New-TestTransaction -Stage 'nonsense' -Target $doctorTarget)
    $doctorMalformed = Invoke-Script -Path $doctor -Arguments @('-Project', $doctorProject['workspace'])
    Expect-True $doctorMalformed.StdoutText.Contains('provision-transaction.json is malformed (stage)') `
        'Doctor names the malformed field'
    $diagnoseMalformed = Invoke-Provision $doctorProject['workspace'] @('recover', '-Diagnose')
    Expect-Equal "malformed`tprovision-transaction.json is malformed (stage)" `
    (Get-JsonLine $diagnoseMalformed) 'diagnose classes a malformed transaction'

    # === 14. usage ===
    $usageRun = Invoke-Script -Path $helper -Arguments @('-Project', $planProject['workspace'])
    Expect-Equal 1 $usageRun.ExitCode 'an empty command is a usage error'
    foreach ($verb in @('baseline', 'diff', 'rollback', 'recover')) {
        Expect-True $usageRun.StderrText.Contains($verb) ('the usage names ' + $verb)
    }
    Expect-True $usageRun.StderrText.Contains('-Surface') 'the usage names the surface flag'
    $surfaceRun = Invoke-Provision $planProject['workspace'] @('baseline')
    Expect-Equal 1 $surfaceRun.ExitCode 'baseline without a surface is a usage error'
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures.Count -gt 0) {
    Write-Host "provision-recover-logic failed ($($failures.Count)):"
    foreach ($failure in $failures) { Write-Host " - $failure" }
    exit 1
}
Write-Host 'provision-recover-logic passed'
exit 0
