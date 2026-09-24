param(
    [string]$Project = [Environment]::CurrentDirectory,
    [string]$WorkTarget = '',
    [ValidateSet('repository', 'artifact')][string]$Mode = 'repository',
    [switch]$Receipts
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if (Test-Path Variable:PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $false
}

$pluginRoot = Resolve-Path (Join-Path $PSScriptRoot '../..')
Import-Module (Join-Path $pluginRoot 'lib/Nightshift.psm1') -Force -DisableNameChecking

$taskRoot = Resolve-NSCanonicalPath $Project
$normalizedTaskRoot = $taskRoot.Replace('\', '/')
if ($normalizedTaskRoot -match '^/workspace/scratch(?:/|$)') {
    throw 'Nightshift needs a persistent software project workspace; disposable scratch workspaces are refused.'
}

$workspace = Resolve-NSWorkspaceRoot $taskRoot
$ns = Join-Path $workspace '.nightshift'
$newSite = -not (Test-Path -LiteralPath $ns -PathType Container)

if ($Mode -eq 'repository' -and [string]::IsNullOrEmpty($WorkTarget) `
    -and -not (Test-Path -LiteralPath (Get-NSLayoutPath $ns 'work-target') -PathType Leaf)) {
    $proposed = $null
    try {
        $proposed = Get-NSProposedWorkMode $workspace
    }
    catch {
    }
    if ($proposed -eq 'artifact') {
        throw 'setup: pass -Mode artifact for a notes folder that is not a Git repository'
    }
}

# An older layout stays operable where it is; Setup describes the move into the current one and
# leaves making it to migrate-state on the owner's word.
$migration = ''
if (-not $newSite) {
    $kind = Get-NSStateKind $workspace
    if ($kind -in @('malformed', 'future')) {
        throw (Get-NSStateRefuseMessage $kind)
    }
    $plan = Get-NSMigrationPlan $workspace
    if ($plan.Code -eq 0) {
        $migration = Get-NSMigrationOffer -Records $plan.Records -Command (Join-Path $PSScriptRoot 'migrate-state.ps1')
    }
}

# A new site is born in the current layout; the scaffold writes what every shift uses, and the
# work orders and the product notebook wait until something needs them.
$created = New-Object Collections.Generic.List[string]
foreach ($line in (Invoke-NSScaffold -Workspace $workspace -Keys (Get-NSScaffoldKeys @()))) {
    if ($line.StartsWith('wrote ', [StringComparison]::Ordinal)) { $created.Add($line.Substring(6)) }
}
$rulesPath = Get-NSLayoutPath $ns 'rules'
if (-not (Test-NSPathEntry $rulesPath)) {
    Copy-NSOwnerTemplate -Source (Join-Path $pluginRoot 'skills/nightshift/references/nightshift-rules-template.json') `
        -Destination $rulesPath -Workspace $workspace
    $created.Add((Get-NSLayoutRelativePath $ns 'rules'))
}

try {
    $rules = Get-Content -LiteralPath (Get-NSLayoutPath $ns 'rules') -Raw | ConvertFrom-Json -ErrorAction Stop
    if ($null -eq $rules -or $rules -is [Array] -or $rules -is [string] -or $rules -is [ValueType]) {
        throw 'rules.json must contain one JSON object'
    }
}
catch {
    throw 'rules.json is unreadable or is not a JSON object'
}

$resolvedTarget = ''
if (-not [string]::IsNullOrEmpty($WorkTarget)) {
    $resolvedTarget = Resolve-NSCanonicalPath $WorkTarget
    $null = Write-NSWorkTarget $workspace $resolvedTarget -Mode $Mode
}
elseif (Test-Path -LiteralPath (Get-NSLayoutPath $ns 'work-target') -PathType Leaf) {
    $resolvedTarget = Resolve-NSWorkTarget $workspace
}
elseif ($Mode -eq 'artifact') {
    $resolvedTarget = $workspace
    $null = Write-NSWorkTarget $workspace $resolvedTarget -Mode artifact
}
else {
    try {
        $resolvedTarget = Resolve-NSWorkTarget $workspace
        $null = Write-NSWorkTarget $workspace $resolvedTarget -Mode repository
    }
    catch {
        if ($_.Exception.Message -match 'several child repositories') {
            throw
        }
        $proposed = $null
        try {
            $proposed = Get-NSProposedWorkMode $workspace
        }
        catch {
        }
        if ($proposed -eq 'artifact') {
            throw 'setup: pass -Mode artifact for a notes folder that is not a Git repository'
        }
    }
}

$workspaceTop = Invoke-NSGit $workspace @('rev-parse', '--show-toplevel')
if (-not [string]::IsNullOrWhiteSpace($workspaceTop) `
    -and (Resolve-NSCanonicalPath $workspaceTop) -eq $workspace) {
    $gitignore = Join-Path $workspace '.gitignore'
    $lines = if (Test-Path -LiteralPath $gitignore -PathType Leaf) {
        [Collections.Generic.List[string]]::new([string[]][IO.File]::ReadAllLines($gitignore))
    }
    else {
        [Collections.Generic.List[string]]::new()
    }
    if (-not $lines.Contains('.nightshift/')) {
        $lines.Add('.nightshift/')
        $null = Write-NSAtomicLines -Path $gitignore -Lines $lines.ToArray()
    }
}

$receiptsCreated = $false
$receiptRepo = Get-NSLayoutPath $ns 'receipts-repo'
if ($Receipts -or (Test-Path -LiteralPath $receiptRepo -PathType Container)) {
    if (-not (Test-Path -LiteralPath $receiptRepo -PathType Container)) {
        $initialized = Invoke-NSGitCommand $ns @('init', '--quiet')
        if ($initialized.ExitCode -ne 0) {
            throw 'the local receipts repository could not be initialized'
        }
        $receiptsCreated = $true
    }
    $receiptIgnore = Get-NSReceiptIgnoreLines $ns
    $receiptIgnorePath = Get-NSLayoutPath $ns 'gitignore'
    $receiptIgnoreLines = [Collections.Generic.List[string]]::new()
    if (Test-Path -LiteralPath $receiptIgnorePath -PathType Leaf) {
        $receiptIgnoreLines.AddRange([string[]][IO.File]::ReadAllLines($receiptIgnorePath))
    }
    $receiptIgnoreChanged = $false
    foreach ($entry in $receiptIgnore) {
        if (-not $receiptIgnoreLines.Contains($entry)) {
            $receiptIgnoreLines.Add($entry)
            $receiptIgnoreChanged = $true
        }
    }
    if ($receiptIgnoreChanged) {
        $null = Write-NSAtomicLines -Path $receiptIgnorePath -Lines $receiptIgnoreLines.ToArray()
    }
    if ($receiptsCreated) {
        $null = Invoke-NSGitCommand $ns @('add', '-A')
        $committed = Invoke-NSGitCommand $ns @(
            '-c', 'user.name=nightshift',
            '-c', 'user.email=nightshift@localhost',
            '-c', 'commit.gpgsign=false',
            'commit', '--quiet', '-m', 'Initialize the receipts store'
        )
        if ($committed.ExitCode -ne 0) {
            throw 'the initial local receipt could not be committed'
        }
    }
}

[pscustomobject]@{
    taskRoot = $taskRoot
    workspace = $workspace
    workTarget = $resolvedTarget
    workMode = $Mode
    created = $created.ToArray()
    receiptsCreated = $receiptsCreated
    migration = $migration
} | ConvertTo-Json -Depth 5
