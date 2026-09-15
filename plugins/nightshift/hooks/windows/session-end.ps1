param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('claude', 'codex', 'cursor')]
    [string]$HostName,
    [Parameter(ValueFromPipeline = $true)]
    [AllowEmptyString()]
    [string]$HookJson = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if (Test-Path Variable:PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $false
}

if ($env:NIGHTSHIFT_REVIVAL -eq '1') {
    exit 0
}

$pluginRoot = Resolve-Path (Join-Path $PSScriptRoot '../..')
Import-Module (Join-Path $pluginRoot 'lib/Nightshift.psm1') -Force -DisableNameChecking

if (Test-NSHookIdle) { exit 0 }

# Same stdin shape as hardhat/pulse: piped JSON binds to -HookJson under the Windows
# test host; nested -File launches still read Console stdin when HookJson is empty.
$raw = Get-NSStdinText -Piped $HookJson
if ([string]::IsNullOrWhiteSpace($raw)) {
    $raw = Get-NSStdinText -Piped (($input | ForEach-Object { $_ }) -join "`n")
}
try {
    $payload = $raw | ConvertFrom-Json -ErrorAction Stop
}
catch {
    exit 0
}

$hostEnv = switch ($HostName) {
    'claude' { [string]$env:CLAUDE_PROJECT_DIR }
    'codex' { [string]$env:CODEX_PROJECT_DIR }
    'cursor' { [string]$env:CURSOR_PROJECT_DIR }
}
$hostRoot = if (-not [string]::IsNullOrEmpty($hostEnv)) {
    $hostEnv
}
elseif ($null -ne $payload.PSObject.Properties['cwd'] -and -not [string]::IsNullOrEmpty([string]$payload.cwd)) {
    [string]$payload.cwd
}
else {
    [Environment]::CurrentDirectory
}

try {
    $workspace = Resolve-NSWorkspaceRoot $hostRoot
}
catch {
    exit 0
}
if ((Get-NSStateKind $workspace) -in @('malformed', 'future')) {
    exit 0
}

$ns = Join-Path $workspace '.nightshift'
$punch = Join-Path $ns 'punch-list.md'
$counts = Get-NSBoxCounts $punch
if (-not (Test-Path -LiteralPath (Join-Path $ns '.shift-armed') -PathType Leaf) `
    -or -not (Test-Path -LiteralPath $punch -PathType Leaf) `
    -or ((Test-Path -LiteralPath (Join-Path $ns '.ended') -PathType Leaf) `
        -and -not (Test-NSReparsePoint (Join-Path $ns '.ended'))) `
    -or $counts.Open -eq 0) {
    exit 0
}

$sessionId = if ($null -eq $payload.PSObject.Properties['session_id']) { '' } else { [string]$payload.session_id }
if ($HostName -eq 'cursor' -and $null -ne $payload.PSObject.Properties['conversation_id'] `
    -and -not [string]::IsNullOrEmpty([string]$payload.conversation_id)) {
    $sessionId = [string]$payload.conversation_id
}
$session = Read-NSSession $ns
$workerPath = Join-Path $ns '.shift-worker'
$worker = ''
if ($HostName -eq 'cursor' -and (Test-Path -LiteralPath $workerPath -PathType Leaf) `
    -and -not (Test-NSReparsePoint $workerPath)) {
    try {
        $worker = (([IO.File]::ReadAllLines($workerPath) | Select-Object -First 1) + '').Trim()
    }
    catch {
        $worker = ''
    }
}
if (-not [string]::IsNullOrEmpty($worker)) {
    if ($sessionId -ne $worker) { exit 0 }
}
elseif ($null -ne $session -and -not [string]::IsNullOrEmpty($session.SessionId) -and $session.SessionId -ne $sessionId) {
    exit 0
}

$leasePath = Join-Path $ns '.shift-lease'
if ($HostName -ne 'codex' -and (Test-NSPathEntry $leasePath)) {
    $hostProcess = Get-NSHostProcess $HostName
    $processId = if ($null -eq $hostProcess) { '' } else { [string]$hostProcess.Id }
    $processStart = if ($null -eq $hostProcess) { '' } else { [string]$hostProcess.Start }
    $allow = Test-NSLeaseAllows $ns $sessionId $HostName $processId $processStart `
        ([string]$env:NIGHTSHIFT_LEASE_NONCE) ([string]$env:NIGHTSHIFT_LEASE_GENERATION)
    if ($allow -ne 'Allow') {
        exit 0
    }
}

$reason = if ($null -eq $payload.PSObject.Properties['reason']) {
    if ($HostName -eq 'codex') { 'other' } else { 'unknown' }
} else {
    [string]$payload.reason
}
$reason = ($reason -replace '[\x00-\x1f]', '').Trim()
if ($HostName -eq 'cursor') {
    if ($reason -notin @('aborted', 'user_close')) {
        exit 0
    }
}

$line = '{0} · clean session end ({1}){2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $reason, [Environment]::NewLine
$sessionEnd = Join-Path $ns '.session-end'
if (Test-NSReparsePoint $sessionEnd) {
    Remove-Item -LiteralPath $sessionEnd -Force -ErrorAction SilentlyContinue
}
[IO.File]::WriteAllText($sessionEnd, $line, (New-Object Text.UTF8Encoding($false)))
exit 0
