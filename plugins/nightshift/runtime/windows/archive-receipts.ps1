param(
    [string]$Project = [Environment]::CurrentDirectory,
    [string]$Date = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$pluginRoot = Resolve-Path (Join-Path $PSScriptRoot '../..')
Import-Module (Join-Path $pluginRoot 'lib/Nightshift.psm1') -Force -DisableNameChecking

function Write-NSArchiveReceiptsError {
    param([string]$Message)
    [Console]::Error.WriteLine($Message)
}

try {
    $hostPath = Resolve-NSCanonicalPath $Project
}
catch {
    Write-NSArchiveReceiptsError "archive-receipts: cannot cd to $Project"
    exit 1
}

try {
    $workspace = Resolve-NSWorkspaceRoot $hostPath
}
catch {
    Write-NSArchiveReceiptsError 'archive-receipts: invalid .nightshift-link - Nightshift will not guess a workspace'
    exit 2
}

$kind = Get-NSStateKind $workspace
if ($kind -in @('malformed', 'future')) {
    Write-NSArchiveReceiptsError ("archive-receipts: {0}" -f (Get-NSStateRefuseMessage $kind))
    exit 2
}
if ($kind -eq 'absent') {
    Write-NSArchiveReceiptsError "archive-receipts: no .nightshift/ at $workspace"
    exit 2
}

$ns = Join-Path $workspace '.nightshift'
if ([string]::IsNullOrWhiteSpace($Date)) {
    $Date = Get-Date -Format 'yyyy-MM-dd'
}
if ($Date -notmatch '^\d{4}-\d{2}-\d{2}$') {
    Write-NSArchiveReceiptsError 'archive-receipts: -Date must be YYYY-MM-DD'
    exit 1
}

$src = Get-NSReceiptsDir $workspace
$dest = Join-Path $ns "archive/$Date/receipts"
if ((Test-Path -LiteralPath $src) -and (Test-NSReparsePoint $src)) {
    Write-NSArchiveReceiptsError 'archive-receipts: refuse to write through a symlink receipts path'
    exit 2
}
if ((Test-Path -LiteralPath $src) -and -not (Test-Path -LiteralPath $src -PathType Container)) {
    Write-NSArchiveReceiptsError 'archive-receipts: receipts path is not a directory'
    exit 2
}
foreach ($p in @((Join-Path $ns 'archive'), (Join-Path $ns "archive/$Date"), $dest)) {
    if (Test-Path -LiteralPath $p) {
        $item = Get-Item -LiteralPath $p -Force
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            Write-NSArchiveReceiptsError 'archive-receipts: refuse to write through a symlink archive path'
            exit 2
        }
        if (-not (Test-Path -LiteralPath $p -PathType Container)) {
            Write-NSArchiveReceiptsError 'archive-receipts: refuse to write through a non-directory archive path'
            exit 2
        }
    }
}

# The archived copy is read back and compared, so a copy that silently truncated or landed on
# another filesystem is never mistaken for a safe one.
function Test-NSSameBytes {
    param([string]$A, [string]$B)
    if (-not (Test-Path -LiteralPath $A -PathType Leaf)) { return $false }
    if (-not (Test-Path -LiteralPath $B -PathType Leaf)) { return $false }
    $left = [IO.File]::ReadAllBytes($A)
    $right = [IO.File]::ReadAllBytes($B)
    if ($left.Length -ne $right.Length) { return $false }
    for ($i = 0; $i -lt $left.Length; $i++) {
        if ($left[$i] -ne $right[$i]) { return $false }
    }
    return $true
}

$copied = 0
if (Test-Path -LiteralPath $src -PathType Container) {
    $files = @(Get-ChildItem -LiteralPath $src -File -Force -ErrorAction SilentlyContinue |
        Where-Object {
            -not $_.Name.StartsWith('.') -and
            -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint)
        })
    if ($files.Count -gt 0) {
        $null = New-Item -ItemType Directory -Path $dest -Force
        $destItem = Get-Item -LiteralPath $dest -Force
        if ($destItem.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            Write-NSArchiveReceiptsError 'archive-receipts: refuse to write through a symlink archive path'
            exit 2
        }
        # A closed record leaves live storage only when the shift has ended and the archived
        # copy has been read back and matches. While a shift is armed nothing is removed: its
        # receipts are what its own progress checks read. Which file it is never decides this -
        # a name is not evidence that a record is finished with.
        $armed = Test-Path -LiteralPath (Join-Path $ns '.shift-armed')
        $endedMarker = Join-Path $ns '.ended'
        $ended = (Test-Path -LiteralPath $endedMarker -PathType Leaf) -and
            -not ((Get-Item -LiteralPath $endedMarker -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)
        $rotate = (-not $armed) -and $ended
        $kept = New-Object Collections.Generic.List[string]
        foreach ($file in $files) {
            $target = Join-Path $dest $file.Name
            if (Test-Path -LiteralPath $target) {
                if (-not (Test-NSSameBytes $file.FullName $target)) {
                    # Two different records under one name. Neither is worth losing, so the one
                    # already filed stands and the live one stays where it is.
                    $kept.Add($file.Name + ' (a different record is already filed under that name)')
                    continue
                }
            }
            else {
                Copy-Item -LiteralPath $file.FullName -Destination $target -Force
                $copied++
            }
            if (-not (Test-NSSameBytes $file.FullName $target)) {
                $kept.Add($file.Name + ' (the archived copy does not match the source)')
                continue
            }
            if ($rotate) {
                Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue
                if (Test-Path -LiteralPath $file.FullName) {
                    $kept.Add($file.Name + ' (could not be removed from live storage)')
                }
            }
        }
        if ($kept.Count -gt 0) {
            Write-NSArchiveReceiptsError 'archive-receipts: kept in live storage:'
            foreach ($line in $kept) { Write-NSArchiveReceiptsError $line }
        }
    }
}

if ($copied -eq 0) {
    exit 0
}
Write-Output $dest
exit 0
