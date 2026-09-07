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

$pluginRoot = Resolve-Path (Join-Path $PSScriptRoot '../..')
Import-Module (Join-Path $pluginRoot 'lib/Nightshift.psm1') -Force -DisableNameChecking

$raw = Get-NSStdinText -Piped (($input | ForEach-Object { $_ }) -join "`n")
if ([string]::IsNullOrWhiteSpace($raw) -and -not [string]::IsNullOrWhiteSpace($HookJson)) {
    $raw = $HookJson
}
try {
    $payload = $raw | ConvertFrom-Json -ErrorAction Stop
}
catch {
    exit 0
}

function Get-PropertyValue {
    param(
        [AllowNull()][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowEmptyString()][string]$Default = ''
    )
    if ($null -eq $Object) { return $Default }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return $Default }
    return [string]$property.Value
}

$sessionId = Get-PropertyValue $payload 'session_id'
if ($HostName -eq 'cursor') {
    $conversation = Get-PropertyValue $payload 'conversation_id'
    if (-not [string]::IsNullOrEmpty($conversation)) {
        $sessionId = $conversation
    }
}

$hostRoot = ''
if ($HostName -eq 'claude' -and -not [string]::IsNullOrEmpty($env:CLAUDE_PROJECT_DIR)) {
    $hostRoot = $env:CLAUDE_PROJECT_DIR
}
elseif ($HostName -eq 'codex' -and -not [string]::IsNullOrEmpty($env:CODEX_PROJECT_DIR)) {
    $hostRoot = $env:CODEX_PROJECT_DIR
}
elseif ($HostName -eq 'cursor' -and -not [string]::IsNullOrEmpty($env:CURSOR_PROJECT_DIR)) {
    $hostRoot = $env:CURSOR_PROJECT_DIR
}
elseif (-not [string]::IsNullOrEmpty((Get-PropertyValue $payload 'cwd'))) {
    $hostRoot = Get-PropertyValue $payload 'cwd'
}
else {
    $hostRoot = [Environment]::CurrentDirectory
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

if ([string]::IsNullOrEmpty($sessionId)) {
    exit 0
}

$session = Read-NSSession $ns
$workerPath = Join-Path $ns '.shift-worker'
$worker = ''
if ((Test-Path -LiteralPath $workerPath -PathType Leaf) -and -not (Test-NSReparsePoint $workerPath)) {
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
elseif ($null -eq $session -or [string]::IsNullOrEmpty($session.SessionId) -or $session.SessionId -ne $sessionId) {
    exit 0
}

$pulse = Join-Path $ns '.shift-pulse'
if (Test-NSReparsePoint $pulse) {
    Remove-Item -LiteralPath $pulse -Force -ErrorAction SilentlyContinue
}
$line = '{0} {1}{2}' -f (Get-NSUnixTime), $sessionId, [Environment]::NewLine
[IO.File]::WriteAllText($pulse, $line, (New-Object Text.UTF8Encoding($false)))

# The reading rides on the pulse: no daemon, no timer, no second session. Cursor carries its figures
# on the payload; the other two name a transcript. Never fatal - a host that reports nothing leaves
# no snapshot, and the report says `unavailable` rather than zero.
$source = $(if ($HostName -eq 'cursor') { $raw } else { Get-PropertyValue $payload 'transcript_path' })
try {
    $null = Invoke-NSPulseUsage $ns $HostName $sessionId $source
    $null = Invoke-NSPulseMarks $ns $workspace $source
}
catch {
    [Console]::Error.WriteLine('nightshift: usage accounting skipped - ' + $_.Exception.Message)
}
exit 0
