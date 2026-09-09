# link-workspace.ps1  -  connect this task root to an existing Nightshift workspace.
#   link-workspace.ps1 -HostRoot DIR -Workspace DIR
# Native flags are -HostRoot and -Workspace. POSIX --host-root / --workspace are
# accepted so ns.ps1 can pass them through. An unknown flag is a usage refusal.

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if (Test-Path Variable:PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $false
}

$hostRoot = ''
$workspace = ''
$i = 0
while ($i -lt $args.Count) {
    $token = [string]$args[$i]
    if ($token -ieq '--host-root' -or $token -ieq '-HostRoot') {
        if ($i + 1 -ge $args.Count) {
            [Console]::Error.WriteLine("link-workspace: $token needs a value")
            exit 2
        }
        $hostRoot = [string]$args[$i + 1]
        $i += 2
        continue
    }
    if ($token -ieq '--workspace' -or $token -ieq '-Workspace') {
        if ($i + 1 -ge $args.Count) {
            [Console]::Error.WriteLine("link-workspace: $token needs a value")
            exit 2
        }
        $workspace = [string]$args[$i + 1]
        $i += 2
        continue
    }
    [Console]::Error.WriteLine("link-workspace: unknown argument: $token")
    exit 2
}

if ([string]::IsNullOrWhiteSpace($workspace)) {
    [Console]::Error.WriteLine('link-workspace: -Workspace is required')
    exit 2
}
if ([string]::IsNullOrWhiteSpace($hostRoot)) {
    [Console]::Error.WriteLine('link-workspace: -HostRoot is required')
    exit 2
}

$pluginRoot = Resolve-Path (Join-Path $PSScriptRoot '../..')
Import-Module (Join-Path $pluginRoot 'lib/Nightshift.psm1') -Force -DisableNameChecking

$hostPath = Resolve-NSCanonicalPath $hostRoot
$workspacePath = Resolve-NSCanonicalPath $workspace
if (-not (Test-Path -LiteralPath (Join-Path $workspacePath '.nightshift') -PathType Container)) {
    throw 'workspace does not contain .nightshift'
}

$link = Join-Path $hostPath '.nightshift-link'
if (Test-NSReparsePoint $link) {
    throw 'refusing to replace a reparse-point .nightshift-link'
}
$null = Write-NSAtomicLines -Path $link -Lines @($workspacePath)

$gitDirectory = Invoke-NSGit $hostPath @('rev-parse', '--git-dir')
if (-not [string]::IsNullOrWhiteSpace($gitDirectory)) {
    if (-not [IO.Path]::IsPathRooted($gitDirectory)) {
        $gitDirectory = Join-Path $hostPath $gitDirectory
    }
    $info = Join-Path $gitDirectory 'info'
    $null = New-Item -ItemType Directory -Path $info -Force
    $exclude = Join-Path $info 'exclude'
    $lines = if (Test-Path -LiteralPath $exclude -PathType Leaf) {
        @([IO.File]::ReadAllLines($exclude))
    }
    else {
        @()
    }
    if ($lines -notcontains '.nightshift-link') {
        $null = Write-NSAtomicLines -Path $exclude -Lines @($lines + '.nightshift-link')
    }
}

"linked $hostPath -> $workspacePath"
