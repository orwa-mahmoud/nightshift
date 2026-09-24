<#
.SYNOPSIS
  Thin auto-add seatbelt on native Windows. No recipe engine.

.DESCRIPTION
  Mirrors runtime/provision.sh. The skill tells the model to inspect the package
  manager, choose a compatible tool, install, smoke, and record. This helper
  only captures a write-surface baseline, prints the diff, and restores.
  Refuse symlink or reparse escape. Unknown flags do not mutate.
  recover of a leftover provision-transaction.json still settles that file.
  Exit: 0 ok - 1 usage/runtime - 2 refused - 3 unproven restore
#>
param(
    [string]$Project = [Environment]::CurrentDirectory,
    [Parameter(Position = 0)]
    [string]$Command = '',
    [string[]]$Surface = @(),
    [switch]$Rollback,
    [switch]$Diagnose
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$pluginRoot = Resolve-Path (Join-Path $PSScriptRoot '../..')
Import-Module (Join-Path $pluginRoot 'lib/Nightshift.psm1') -Force -DisableNameChecking
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)

function Write-NSLf {
    param([string]$Text)
    [Console]::Out.Write($Text + "`n")
}

function Write-NSSeatbeltUsage {
    Write-Error @'
provision.ps1 -Project DIR -Command baseline -Surface PATH[,PATH...]
provision.ps1 -Project DIR -Command diff
provision.ps1 -Project DIR -Command rollback
provision.ps1 -Project DIR -Command recover
'@
    return 1
}

if ([string]::IsNullOrEmpty($Command)) { exit (Write-NSSeatbeltUsage) }

$allowed = @('baseline', 'diff', 'rollback', 'recover')
if ($allowed -notcontains $Command) {
    # An unrecognized command prints the usage and mutates nothing.
    exit (Write-NSSeatbeltUsage)
}

$workspace = Get-NSAbsolutePath $Project
if (-not (Test-Path -LiteralPath $workspace -PathType Container)) {
    Write-Error ('provision: not a directory: ' + $workspace)
    exit 1
}

$ns = Join-NSPath $workspace '.nightshift'
$manifest = Get-NSLayoutPath $ns 'provision-surface'
$tx = Get-NSLayoutPath $ns 'provision-transaction'

# Leftover engine transaction: the native recover still settles it.
if (($Command -eq 'recover' -or $Command -eq 'rollback') -and
    (Test-Path -LiteralPath $tx) -and -not (Test-Path -LiteralPath $manifest)) {
    exit (Invoke-NSProvisionCommand -Project $Project -Command $Command `
            -Rollback:($Command -eq 'rollback' -or $Rollback) -Diagnose:$Diagnose)
}

# Thin seatbelt for the new surface format.
$target = $workspace
$wt = Get-NSLayoutPath $ns 'work-target'
if (Test-Path -LiteralPath $wt -PathType Leaf) {
    $line = (Get-Content -LiteralPath $wt -TotalCount 1)
    if (-not [string]::IsNullOrEmpty($line)) {
        if ($line -match '^[\\/]' -or $line -match '^[A-Za-z]:[\\/]') {
            $target = $line
        } else {
            $target = Join-NSPath $workspace $line
        }
    }
}

function Test-NSSurfaceEscape {
    param([string]$Rel, [string]$Root)
    if ([string]::IsNullOrEmpty($Rel)) { return $true }
    if ($Rel.Contains('..')) { return $true }
    if ($Rel.StartsWith('/') -or $Rel.StartsWith('\')) { return $true }
    $locked = @(
        'punch-list.md', 'parking-lot.md', 'drafting-table.md', 'work-orders.md',
        'capability-policy.json', 'shift-policy.json', 'shift-defaults.json', 'rules.json'
    )
    if ($locked -contains $Rel) { return $true }
    if ($Rel -eq '.nightshift' -or $Rel.StartsWith('.nightshift/') -or
        $Rel -eq '.git' -or $Rel.StartsWith('.git/')) { return $true }
    $full = Join-Path $Root $Rel
    if (Test-Path -LiteralPath $full) {
        $item = Get-Item -LiteralPath $full -Force
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { return $true }
        if ($item.LinkType) { return $true }
    }
    return $false
}

switch ($Command) {
    'baseline' {
        if ($Surface.Count -lt 1) { exit (Write-NSSeatbeltUsage) }
        New-Item -ItemType Directory -Force -Path $ns | Out-Null
        $base = Get-NSLayoutPath $ns 'provision-baseline'
        if (Test-Path -LiteralPath $base) { Remove-Item -LiteralPath $base -Recurse -Force }
        New-Item -ItemType Directory -Force -Path $base | Out-Null
        $rows = New-Object System.Collections.Generic.List[string]
        foreach ($rel in $Surface) {
            if (Test-NSSurfaceEscape -Rel $rel -Root $target) {
                if (Test-Path -LiteralPath $base) { Remove-Item -LiteralPath $base -Recurse -Force }
                Write-NSLf ('{"ok":false,"refused":true,"reason":"surface-escape:' + $rel + '"}')
                exit 2
            }
            $path = Join-Path $target $rel
            $existed = 0
            $digest = '-'
            if (Test-Path -LiteralPath $path -PathType Leaf) {
                $existed = 1
                $sha = Get-FileHash -LiteralPath $path -Algorithm SHA256
                $digest = $sha.Hash.ToLowerInvariant()
                Copy-Item -LiteralPath $path -Destination (Join-Path $base $digest) -Force
            } elseif (Test-Path -LiteralPath $path) {
                if (Test-Path -LiteralPath $base) { Remove-Item -LiteralPath $base -Recurse -Force }
                Write-NSLf ('{"ok":false,"refused":true,"reason":"surface-not-file:' + $rel + '"}')
                exit 2
            }
            $rows.Add(($rel + "`t" + $existed + "`t" + $digest))
        }
        Set-Content -LiteralPath $manifest -Value $rows -Encoding utf8
        Set-Content -LiteralPath $tx -Value '{"schemaVersion":1,"stage":"baseline"}' -Encoding utf8
        Write-NSLf '{"ok":true,"refused":false,"rolledBack":false,"command":"baseline"}'
        exit 0
    }
    'diff' {
        if (-not (Test-Path -LiteralPath $manifest)) {
            Write-Error 'provision: no provision-surface; run baseline first'
            exit 1
        }
        $touched = New-Object System.Collections.Generic.List[string]
        Get-Content -LiteralPath $manifest | ForEach-Object {
            if ([string]::IsNullOrEmpty($_)) { return }
            $parts = $_ -split "`t", 3
            $rel = $parts[0]
            $existed = $parts[1]
            $digest = $parts[2]
            $path = Join-Path $target $rel
            $now = 'absent'
            if (Test-Path -LiteralPath $path -PathType Leaf) {
                $item = Get-Item -LiteralPath $path -Force
                if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                    $now = 'symlink'
                } else {
                    $now = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
                }
            } elseif (Test-Path -LiteralPath $path) {
                $now = 'other'
            }
            $changed = $false
            if ($existed -eq '1') {
                if ($now -ne $digest) { $changed = $true }
            } else {
                if ($now -ne 'absent') { $changed = $true }
            }
            if ($changed) { $touched.Add($rel) }
        }
        $json = ($touched | ForEach-Object { '"' + $_ + '"' }) -join ','
        Write-NSLf ('{"ok":true,"touched":[' + $json + ']}')
        exit 0
    }
    { $_ -in @('rollback', 'recover') } {
        if (-not (Test-Path -LiteralPath $manifest)) {
            Write-NSLf '{"detail":"no transaction","ok":true,"recovered":false}'
            exit 0
        }
        $base = Get-NSLayoutPath $ns 'provision-baseline'
        Get-Content -LiteralPath $manifest | ForEach-Object {
            if ([string]::IsNullOrEmpty($_)) { return }
            $parts = $_ -split "`t", 3
            $rel = $parts[0]
            $existed = $parts[1]
            $digest = $parts[2]
            if (Test-NSSurfaceEscape -Rel $rel -Root $target) {
                Write-NSLf '{"ok":false,"proven":false,"rolledBack":false,"reason":"surface-escape"}'
                exit 3
            }
            $path = Join-Path $target $rel
            if (Test-Path -LiteralPath $path) {
                $item = Get-Item -LiteralPath $path -Force
                if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                    Remove-Item -LiteralPath $path -Force
                } elseif (-not $item.PSIsContainer) {
                    Remove-Item -LiteralPath $path -Force
                } else {
                    Write-NSLf '{"ok":false,"proven":false,"rolledBack":false,"reason":"restore-failed"}'
                    exit 3
                }
            }
            if ($existed -eq '1') {
                $blob = Join-Path $base $digest
                if (-not (Test-Path -LiteralPath $blob)) {
                    Write-NSLf '{"ok":false,"proven":false,"rolledBack":false,"reason":"restore-failed"}'
                    exit 3
                }
                $dir = Split-Path -Parent $path
                if (-not (Test-Path -LiteralPath $dir)) {
                    New-Item -ItemType Directory -Force -Path $dir | Out-Null
                }
                Copy-Item -LiteralPath $blob -Destination $path -Force
            }
        }
        Remove-Item -LiteralPath $manifest -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $tx -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $base) { Remove-Item -LiteralPath $base -Recurse -Force }
        Write-NSLf '{"ok":true,"rolledBack":true,"recovered":true}'
        exit 0
    }
}

exit (Write-NSSeatbeltUsage)
