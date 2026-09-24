param(
    [Parameter(Mandatory = $true)][string]$Project,
    [Parameter(Mandatory = $true)]
    [ValidateSet('claude', 'codex', 'cursor')]
    [string]$HostName
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$watchman = Join-Path $PSScriptRoot 'watchman.ps1'
$projectPath = (Resolve-Path -LiteralPath $Project -ErrorAction Stop).ProviderPath
$pluginRoot = Resolve-Path (Join-Path $PSScriptRoot '../..')
Import-Module (Join-Path $pluginRoot 'lib/Nightshift.psm1') -Force -DisableNameChecking
$workspace = Resolve-NSWorkspaceRoot $projectPath
$marker = Get-NSLayoutPath (Join-Path $workspace '.nightshift') 'watchman'

$quotedScript = $watchman.Replace("'", "''")
$quotedProject = $projectPath.Replace("'", "''")
$command = "& '$quotedScript' -Project '$quotedProject' -HostName '$HostName'"
$encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
$arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encoded"
$process = Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments `
    -WindowStyle Hidden -PassThru -ErrorAction Stop
$processStart = Get-NSProcessStart $process.Id
if ([string]::IsNullOrEmpty($processStart)) {
    Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
    throw 'watchman process identity was unavailable during startup'
}

$ready = $false
for ($attempt = 0; $attempt -lt 100; $attempt++) {
    $process.Refresh()
    if ($process.HasExited) {
        throw "watchman exited before startup (code $($process.ExitCode))"
    }
    if (Test-Path -LiteralPath $marker -PathType Leaf) {
        $owner = [IO.File]::ReadAllLines($marker)
        $ownerPid = if ($owner.Count -gt 0) { $owner[0] } else { '' }
        $ownerStart = if ($owner.Count -gt 1) { $owner[1] } else { '' }
        if ($ownerPid -eq [string]$process.Id -and $ownerStart -eq $processStart) {
            $ready = $true
            break
        }
    }
    Start-Sleep -Milliseconds 50
}
if (-not $ready) {
    Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
    throw 'watchman did not publish its ownership marker'
}
$process.Refresh()
if ($process.HasExited) {
    throw "watchman exited during startup (code $($process.ExitCode))"
}

"watchman started (pid $($process.Id))"
