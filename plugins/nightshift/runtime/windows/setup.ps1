param(
    [string]$Project = [Environment]::CurrentDirectory,
    [string]$WorkTarget = '',
    [ValidateSet('repository', 'artifact')][string]$Mode = 'repository',
    [switch]$Receipts,
    [switch]$MigrateLegacy
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
    -and -not (Test-Path -LiteralPath (Join-Path $ns 'work-target') -PathType Leaf)) {
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

if (-not $newSite) {
    $kind = Get-NSStateKind $workspace
    if ($kind -in @('malformed', 'future')) {
        throw (Get-NSStateRefuseMessage $kind)
    }
    if ($kind -eq 'legacy') {
        if (-not $MigrateLegacy) {
            throw 'Nightshift state is legacy version 0. Re-run with -MigrateLegacy only after the owner approves migration.'
        }
        if (Test-Path -LiteralPath (Join-Path $ns '.shift-armed') -PathType Leaf) {
            throw 'An armed workspace cannot be migrated.'
        }
    }
}

$null = New-Item -ItemType Directory -Path $ns -Force

$templates = [ordered]@{
    'skills/nightshift/references/templates/punch-list.md' = 'punch-list.md'
    'skills/nightshift/references/templates/drafting-table.md' = 'drafting-table.md'
    'skills/nightshift/references/templates/parking-lot.md' = 'parking-lot.md'
    'skills/nightshift/references/templates/snag-log.md' = 'snag-log.md'
    'skills/nightshift/references/templates/product-research.md' = 'product-research.md'
    'skills/nightshift/references/templates/opportunity-map.md' = 'opportunity-map.md'
    'skills/nightshift/references/templates/work-orders.md' = 'work-orders.md'
    'skills/nightshift/references/nightshift-rules-template.json' = 'rules.json'
}

$created = New-Object Collections.Generic.List[string]
foreach ($entry in $templates.GetEnumerator()) {
    $source = Join-Path $pluginRoot $entry.Key
    $destination = Join-Path $ns $entry.Value
    if (-not (Test-NSPathEntry $destination)) {
        Copy-NSOwnerTemplate -Source $source -Destination $destination -Workspace $workspace
        $created.Add($entry.Value)
    }
}

$shiftLog = Join-Path $ns 'shift-log.md'
if (-not (Test-NSPathEntry $shiftLog)) {
    $null = Write-NSAtomicLines -Path $shiftLog -Lines @('# Nightshift log')
    $created.Add('shift-log.md')
}

if ($newSite -or $MigrateLegacy) {
    $null = Write-NSAtomicLines -Path (Join-Path $ns 'state-version') -Lines @('1')
}

try {
    $rules = Get-Content -LiteralPath (Join-Path $ns 'rules.json') -Raw | ConvertFrom-Json -ErrorAction Stop
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
elseif (Test-Path -LiteralPath (Join-Path $ns 'work-target') -PathType Leaf) {
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
$receiptRepo = Join-Path $ns '.git'
if ($Receipts -or (Test-Path -LiteralPath $receiptRepo -PathType Container)) {
    if (-not (Test-Path -LiteralPath $receiptRepo -PathType Container)) {
        $initialized = Invoke-NSGitCommand $ns @('init', '--quiet')
        if ($initialized.ExitCode -ne 0) {
            throw 'the local receipts repository could not be initialized'
        }
        $receiptsCreated = $true
    }
    $receiptIgnore = @(
        'STOP',
        '.stall',
        '.notified',
        'deadline',
        '.session-end',
        '.shift-pulse',
        '.mint-failed',
        '.shift-session',
        '.shift-session.tmp.*',
        '.shift-worker',
        '.shift-lease',
        '.shift-lease.tmp.*',
        '.mutex-scope',
        '.mutex-scope.tmp.*',
        '.watchman',
        '.watchman-tick',
        '.lock.d/',
        '.lease-lock.d/'
    )
    $receiptIgnorePath = Join-Path $ns '.gitignore'
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
            'commit', '--quiet', '-m', 'Initialize Nightshift receipts'
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
} | ConvertTo-Json -Depth 5
