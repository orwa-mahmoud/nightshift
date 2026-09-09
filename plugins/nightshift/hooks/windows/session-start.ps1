param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('claude', 'codex', 'cursor')]
    [string]$HostName,
    [Parameter(ValueFromPipeline = $true)]
    [AllowEmptyString()]
    [string]$HookJson = ''
)

# session-start.ps1 - the native Windows twin of hooks/session-start.sh.
#
# Claude Code's SessionStart, for the two sources that mean the conversation no longer holds what it
# was told: `compact` and `resume`. Two things happen, and only in the session that owns the shift:
# the .context-reset marker the next clock-out block consumes, so that block carries the whole
# contract again; and one line back, so the model reloads the skill, the contract that binds it, and
# the section it was working.
#
# Codex and Cursor expose no equivalent event, so this refuses to act for them.

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if (Test-Path Variable:PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $false
}

$pluginRoot = Resolve-Path (Join-Path $PSScriptRoot '../..')
Import-Module (Join-Path $pluginRoot 'lib/Nightshift.psm1') -Force -DisableNameChecking

[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)

# Same stdin shape as the other Windows hooks: piped JSON binds to -HookJson under the test host;
# nested -File launches still read Console stdin when HookJson is empty.
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

function Get-PayloadValue {
    param([AllowNull()][object]$Object, [Parameter(Mandatory = $true)][string]$Name)
    if ($null -eq $Object) { return '' }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return '' }
    return [string]$property.Value
}

$hostEnv = switch ($HostName) {
    'claude' { [string]$env:CLAUDE_PROJECT_DIR }
    'codex' { [string]$env:CODEX_PROJECT_DIR }
    'cursor' { [string]$env:CURSOR_PROJECT_DIR }
}
$hostRoot = if (-not [string]::IsNullOrEmpty($hostEnv)) { $hostEnv }
elseif (-not [string]::IsNullOrEmpty((Get-PayloadValue $payload 'cwd'))) { Get-PayloadValue $payload 'cwd' }
else { [Environment]::CurrentDirectory }

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
if (-not (Test-Path -LiteralPath (Join-Path $ns '.shift-armed') -PathType Leaf)) {
    exit 0
}

# Only the two sources that mean context was lost. A fresh start or a cleared conversation is not a
# reset of anything this shift said.
if ((Get-PayloadValue $payload 'source') -notin @('compact', 'resume')) {
    exit 0
}

# The session that owns the shift, and no other.
$session = Read-NSSession $ns
if ($null -eq $session -or [string]::IsNullOrEmpty($session.SessionId)) { exit 0 }
$sessionId = Get-PayloadValue $payload 'session_id'
if ([string]::IsNullOrEmpty($sessionId) -or $session.SessionId -cne $sessionId) { exit 0 }

$marker = Join-Path $ns '.context-reset'
if (Test-NSReparsePoint $marker) {
    Remove-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue
}
try { [IO.File]::WriteAllText($marker, '', (New-Object Text.UTF8Encoding($false))) }
catch {
    # Best-effort, exactly as the POSIX twin: the reminder still goes out, and the next clock-out
    # falls back to the short block rather than carrying the whole contract again.
    Write-Verbose ('nightshift: could not write the context-reset marker - ' + $_.Exception.Message)
}

$line = 'nightshift: context was compacted — reload the nightshift skill, the contract in ' +
    'punch-list.md, and the active receipt under receipts/ before continuing.'
$active = ''
$punch = Join-Path $ns 'punch-list.md'
if (Test-Path -LiteralPath $punch -PathType Leaf) {
    foreach ($row in (Get-NSPunchItemsSection $punch)) {
        if ($row -cnotmatch '^- \[ \]') { continue }
        $t = $row -creplace '^- \[ \][ \t]*\*\*', ''
        $t = $t -creplace '[ \t]+(—|-[ \t]).*$', ''
        $t = $t -creplace '\*\*.*$', ''
        $active = $t.TrimEnd()
        break
    }
}
if (-not [string]::IsNullOrEmpty($active)) {
    $line = $line + ' Receipts: one file per item under .nightshift/receipts/; the current item is ' +
        $active + ' → ' + (Get-NSReceiptBasename $active) + '.md.'
}
$out = [pscustomobject]@{
    hookSpecificOutput = [pscustomobject]@{
        hookEventName    = 'SessionStart'
        additionalContext = $line
    }
}
[Console]::Out.WriteLine(($out | ConvertTo-Json -Compress -Depth 4))
exit 0
