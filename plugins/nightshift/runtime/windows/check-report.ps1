param(
    [string]$Project = [Environment]::CurrentDirectory,
    [string]$Report = '',
    [string]$Manifest = '',
    [string[]]$Output = @()
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$pluginRoot = Resolve-Path (Join-Path $PSScriptRoot '../..')
Import-Module (Join-Path $pluginRoot 'lib/Nightshift.psm1') -Force -DisableNameChecking

function Write-NSCheckError {
    param([string]$Message)
    [Console]::Error.WriteLine($Message)
}

function Fail-NSCheck {
    param([string]$Message)
    Write-NSCheckError "check-report: $Message"
    exit 2
}

try {
    $hostPath = Resolve-NSCanonicalPath $Project
}
catch {
    Write-NSCheckError "check-report: cannot cd to $Project"
    exit 1
}

if ([string]::IsNullOrWhiteSpace($Report)) {
    Write-NSCheckError 'check-report: -Report is required'
    exit 1
}
if ([string]::IsNullOrWhiteSpace($Manifest)) {
    Write-NSCheckError 'check-report: -Manifest is required'
    exit 1
}

function Resolve-NSCheckFile {
    param([string]$Raw)
    if ([IO.Path]::IsPathRooted($Raw)) {
        return $Raw
    }
    return (Join-Path $hostPath $Raw)
}

function Assert-NSOutputFile {
    param([string]$Raw)
    $abs = Resolve-NSCheckFile $Raw
    if ((Test-NSReparsePoint $abs) -or -not (Test-Path -LiteralPath $abs -PathType Leaf)) {
        Fail-NSCheck "missing output: $Raw"
    }
    try {
        $abs = Resolve-NSCanonicalPath $abs
    }
    catch {
        Fail-NSCheck "missing output: $Raw"
    }
    if ((Test-NSReparsePoint $abs) -or -not (Test-Path -LiteralPath $abs -PathType Leaf)) {
        Fail-NSCheck "missing output: $Raw"
    }
    $item = Get-Item -LiteralPath $abs -Force
    if ($item.Length -eq 0) {
        Fail-NSCheck "empty output: $Raw"
    }
    return $abs
}

$reportAbs = Assert-NSOutputFile $Report
$manifestAbs = Assert-NSOutputFile $Manifest
$outputs = @($Output | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
if ($outputs.Count -eq 0) {
    $outputs = @($Report)
}
foreach ($raw in $outputs) {
    $null = Assert-NSOutputFile $raw
}

function Test-NSSecretFile {
    param([string]$Path)
    foreach ($line in [IO.File]::ReadAllLines($Path)) {
        if (Test-NSSecretLine $line) {
            Fail-NSCheck 'secret line in a report or manifest file'
        }
    }
}
Test-NSSecretFile $reportAbs
Test-NSSecretFile $manifestAbs

$reportText = [IO.File]::ReadAllText($reportAbs)
foreach ($heading in @('Executive summary', 'Sources', 'Observations', 'Inferences')) {
    if ($reportText -notmatch ("(?m)^##\s*" + [regex]::Escape($heading) + "(\s|$)")) {
        Fail-NSCheck "missing heading: ## $heading"
    }
}

$ids = New-Object System.Collections.Generic.List[string]
$okIds = New-Object System.Collections.Generic.List[string]
$unavIds = New-Object System.Collections.Generic.List[string]
foreach ($line in [IO.File]::ReadAllLines($manifestAbs)) {
    if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith('#')) {
        continue
    }
    $parts = $line.Split("`t")
    if ($parts.Count -lt 4) {
        Fail-NSCheck 'malformed manifest line'
    }
    $status = $parts[0]
    $sid = $parts[2]
    $locator = $parts[3]
    if ([string]::IsNullOrWhiteSpace($status) -or [string]::IsNullOrWhiteSpace($sid) -or [string]::IsNullOrWhiteSpace($locator)) {
        Fail-NSCheck 'malformed manifest line'
    }
    if ($sid -notmatch '^S[0-9]+$') {
        Fail-NSCheck "manifest id must look like S1: $sid"
    }
    if ($status -notin @('ok', 'unavailable')) {
        Fail-NSCheck "manifest status must be ok or unavailable: $status"
    }
    [void]$ids.Add($sid)
    if ($status -eq 'ok') {
        [void]$okIds.Add($sid)
    }
    else {
        [void]$unavIds.Add($sid)
    }
}
if ($ids.Count -eq 0) {
    Fail-NSCheck 'manifest has no source records'
}

$citationMatches = [regex]::Matches($reportText, '\[S[0-9]+\]')
foreach ($match in $citationMatches) {
    $cid = $match.Value.Trim('[', ']')
    if (-not $ids.Contains($cid)) {
        Fail-NSCheck "fabricated citation: [$cid]"
    }
}

foreach ($sid in $okIds) {
    if (-not $reportText.Contains("[$sid]")) {
        Fail-NSCheck "uncited ok source: $sid"
    }
}

$sourcesBlock = New-Object System.Collections.Generic.List[string]
$inSources = $false
foreach ($line in [IO.File]::ReadAllLines($reportAbs)) {
    if ($line -match '^##\s*Sources(\s|$)') {
        $inSources = $true
        continue
    }
    if ($line -match '^##\s') {
        $inSources = $false
    }
    if ($inSources) {
        [void]$sourcesBlock.Add($line)
    }
}
$sourcesText = ($sourcesBlock -join "`n")
if ([string]::IsNullOrWhiteSpace($sourcesText)) {
    Fail-NSCheck 'empty Sources section'
}
foreach ($sid in $unavIds) {
    if ($sourcesText -notlike "*$sid*") {
        Fail-NSCheck "unavailable source not recorded: $sid"
    }
}

exit 0
