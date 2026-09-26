param(
    [Parameter(Mandatory = $true)][string]$Project,
    [Parameter(Mandatory = $true)]
    [ValidateSet('claude', 'codex', 'cursor')]
    [string]$HostName
)

# start-watchman.ps1 - launch this host's watchman hidden and confirm it armed. The native twin of
# runtime/start-watchman.sh: the watchman's own output is appended to run/watchman.log, and success
# means its ownership marker names the launched process and the shift log gained its `armed` line.
# Anything short of that is reported with the watchman's own words, and a launched process that
# did not arm is stopped.

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$watchman = Join-Path $PSScriptRoot 'watchman.ps1'
$pluginRoot = Resolve-Path (Join-Path $PSScriptRoot '../..')
Import-Module (Join-Path $pluginRoot 'lib/Nightshift.psm1') -Force -DisableNameChecking
$projectPath = Get-NSStateDirOwner (Resolve-Path -LiteralPath $Project -ErrorAction Stop).ProviderPath
$workspace = Resolve-NSWorkspaceRoot $projectPath
$ns = Join-Path $workspace '.nightshift'
$marker = Get-NSLayoutPath $ns 'watchman'
$log = Get-NSLayoutPath $ns 'shift-log'
$output = Get-NSLayoutPath $ns 'watchman-log'
$utf8 = New-Object Text.UTF8Encoding($false)

function Read-NSWatchmanOwner {
    if (-not (Test-Path -LiteralPath $marker -PathType Leaf) -or (Test-NSReparsePoint $marker)) { return @('', '') }
    $owner = [IO.File]::ReadAllLines($marker)
    return @($(if ($owner.Count -gt 0) { $owner[0] } else { '' }), $(if ($owner.Count -gt 1) { $owner[1] } else { '' }))
}

# One watchman per site. A live one is already doing this job, and a second would refuse anyway.
$held = Read-NSWatchmanOwner
if ((Test-NSRecordedProcess $held[0] $held[1]) -eq 'Alive') {
    "watchman already watching (pid $($held[0]))"
    exit 0
}

foreach ($dir in @((Split-Path -Parent $output), (Split-Path -Parent $log))) {
    $null = New-Item -ItemType Directory -Path $dir -Force
}
$logFrom = [long]0
if (Test-Path -LiteralPath $log -PathType Leaf) { $logFrom = (Get-Item -LiteralPath $log).Length }
[IO.File]::AppendAllText($output, ('{0} - start-watchman: launching the {1} watchman for {2}' -f
        (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $HostName, $workspace) + [Environment]::NewLine, $utf8)
$outputFrom = @([IO.File]::ReadAllLines($output)).Count

# Every record the watchman writes, and the message of the error that ends it, is appended to the
# output file as UTF-8 text.
$quotedScript = $watchman.Replace("'", "''")
$quotedProject = $projectPath.Replace("'", "''")
$quotedOutput = $output.Replace("'", "''")
$command = "`$utf8 = New-Object Text.UTF8Encoding(`$false); " +
"try { & '$quotedScript' -Project '$quotedProject' -HostName '$HostName' *>&1 | " +
"ForEach-Object { [IO.File]::AppendAllText('$quotedOutput', [string]`$_ + [Environment]::NewLine, `$utf8) } } " +
"catch { [IO.File]::AppendAllText('$quotedOutput', `$_.Exception.Message + [Environment]::NewLine, `$utf8); exit 1 }; " +
"exit `$LASTEXITCODE"
$encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
$arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encoded"
$process = Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments `
    -WindowStyle Hidden -PassThru -ErrorAction Stop

function Stop-NSUnarmedWatchman {
    param([Parameter(Mandatory = $true)][string]$Reason)
    Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
    $said = @([IO.File]::ReadAllLines($output) | Select-Object -Skip $outputFrom)
    throw (@("start-watchman: $Reason") + $said + @("start-watchman: the full output is in $output")) -join [Environment]::NewLine
}

function Test-NSArmedLine {
    if (-not (Test-Path -LiteralPath $log -PathType Leaf)) { return $false }
    $bytes = [IO.File]::ReadAllBytes($log)
    if ($bytes.Length -le $logFrom) { return $false }
    $text = $utf8.GetString($bytes, [int]$logFrom, $bytes.Length - [int]$logFrom)
    return ($text -cmatch 'watchman \([^)]*\) armed')
}

$processStart = Get-NSProcessStart $process.Id
if ([string]::IsNullOrEmpty($processStart)) {
    Stop-NSUnarmedWatchman 'watchman process identity was unavailable during startup'
}

$ready = $false
for ($attempt = 0; $attempt -lt 300; $attempt++) {
    $process.Refresh()
    if ($process.HasExited) {
        Stop-NSUnarmedWatchman "the watchman exited before it armed (code $($process.ExitCode))"
    }
    $owner = Read-NSWatchmanOwner
    if ($owner[0] -eq [string]$process.Id -and $owner[1] -eq $processStart -and (Test-NSArmedLine)) {
        $ready = $true
        break
    }
    Start-Sleep -Milliseconds 50
}
if (-not $ready) {
    Stop-NSUnarmedWatchman 'the watchman did not arm within 15 seconds and was stopped'
}

"watchman started (pid $($process.Id))"
