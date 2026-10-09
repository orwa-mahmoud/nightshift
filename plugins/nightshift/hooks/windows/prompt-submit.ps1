param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('claude', 'codex')]
    [string]$HostName,
    [Parameter(ValueFromPipeline = $true)]
    [AllowEmptyString()]
    [string]$HookJson = ''
)

# prompt-submit.ps1 - the owner's own command closes the plan room. Mirrors hooks/prompt-expansion.sh
# (Claude Code UserPromptExpansion: the typed command's name in command_name) and
# hooks/codex/prompt-submit.sh (Codex UserPromptSubmit: the typed text in prompt). A command or skill
# the model invokes never reaches either event. The prompt always goes through: this hook never
# blocks one.

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if (Test-Path Variable:PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $false
}

$pluginRoot = Resolve-Path (Join-Path $PSScriptRoot '../..')
Import-Module (Join-Path $pluginRoot 'lib/Nightshift.psm1') -Force -DisableNameChecking

if (Test-NSHookIdle) { exit 0 }

# Same stdin shape as the other hooks: piped JSON binds to -HookJson under the Windows test host;
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

$typed = ''
if ($HostName -eq 'claude') {
    if ($null -ne $payload.PSObject.Properties['command_name']) { $typed = '/' + [string]$payload.command_name }
}
elseif ($null -ne $payload.PSObject.Properties['prompt']) {
    $typed = [string]$payload.prompt
}
$word = Get-NSPlanRoomExitWord $typed
if ($word.Length -eq 0) { exit 0 }

$hostEnv = if ($HostName -eq 'claude') { [string]$env:CLAUDE_PROJECT_DIR } else { [string]$env:CODEX_PROJECT_DIR }
$hostRoot = if (-not [string]::IsNullOrEmpty($hostEnv)) {
    $hostEnv
}
elseif ($null -ne $payload.PSObject.Properties['cwd'] -and -not [string]::IsNullOrEmpty([string]$payload.cwd)) {
    [string]$payload.cwd
}
else {
    exit 0
}
try {
    $workspace = Resolve-NSWorkspaceRoot $hostRoot
}
catch {
    exit 0
}
$ns = Join-Path $workspace '.nightshift'
if (-not (Exit-NSPlanRoom $ns "typed the $word command")) { exit 0 }

$eventName = if ($HostName -eq 'claude') { 'UserPromptExpansion' } else { 'UserPromptSubmit' }
$out = [ordered]@{
    hookSpecificOutput = [ordered]@{
        hookEventName = $eventName
        additionalContext = (Get-NSPlanRoomLeftContext $word)
    }
}
[Console]::Out.WriteLine(($out | ConvertTo-Json -Compress -Depth 3))
exit 0
