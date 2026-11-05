# A plugin copy answers only the host that installed it.
# Run on macOS or Windows: pwsh -File tests/windows/ownership-host-logic.ps1
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if (Test-Path Variable:PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $false
}

$repository = Resolve-Path (Join-Path $PSScriptRoot '../..')
$plugin = Join-Path $repository 'plugins/nightshift'
Import-Module (Join-Path $plugin 'lib/Nightshift.psm1') -Force -DisableNameChecking
$failures = New-Object 'System.Collections.Generic.List[string]'

function Expect-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        $failures.Add($Message)
        Write-Host "FAIL: $Message"
    }
}

function Expect-Equal {
    param($Expected, $Actual, [string]$Message)
    if ([string]$Expected -ne [string]$Actual) {
        $failures.Add("$Message (expected '$Expected', got '$Actual')")
        Write-Host "FAIL: $Message (expected '$Expected', got '$Actual')"
    }
}

$saved = @{}
foreach ($name in @(
        'USERPROFILE', 'HOME', 'NIGHTSHIFT_HOST',
        'CLAUDE_PROJECT_DIR', 'CLAUDECODE', 'CLAUDE_PLUGIN_ROOT',
        'CODEX_PROJECT_DIR', 'CODEX_HOME', 'CODEX_SANDBOX',
        'CURSOR_PROJECT_DIR', 'CURSOR_PLUGIN_ROOT', 'CURSOR_TRACE_ID',
        'CURSOR_AGENT', 'CURSOR_VERSION')) {
    $saved[$name] = [Environment]::GetEnvironmentVariable($name)
    Remove-Item "Env:$name" -ErrorAction SilentlyContinue
}

try {
    $root = Join-Path ([IO.Path]::GetTempPath()) ("ns-own-" + [guid]::NewGuid().ToString('n'))
    $profileRoot = Join-Path $root 'profile'
    $claude = Join-Path $profileRoot '.claude/plugins/nightshift'
    $cursor = Join-Path $profileRoot '.cursor/plugins/nightshift'
    $codex = Join-Path $profileRoot '.codex/plugins/cache/m/nightshift/1'
    $checkout = Join-Path $root 'checkout'
    New-Item -ItemType Directory -Force -Path $claude, $cursor, $codex, $checkout | Out-Null
    $env:USERPROFILE = $profileRoot
    $env:HOME = $profileRoot

    Expect-Equal 'claude' (Get-NSInstallingHost $claude) 'claude plugins directory'
    Expect-Equal 'cursor' (Get-NSInstallingHost $cursor) 'cursor plugins directory'
    Expect-Equal 'codex' (Get-NSInstallingHost $codex) 'codex plugins directory'
    Expect-Equal 'any' (Get-NSInstallingHost $checkout) 'a checkout serves every host'
    Expect-Equal 'any' (Get-NSInstallingHost (Join-Path $profileRoot '.claude/plugins-extra/ns')) 'a sibling directory is not an install'
    Expect-True (Test-NSCopyServesHost $cursor 'cursor') 'a cursor copy serves cursor'
    Expect-True (-not (Test-NSCopyServesHost $cursor 'claude')) 'a cursor copy does not serve claude'
    Expect-True (Test-NSCopyServesHost $checkout 'codex') 'a checkout serves codex'

    $project = Join-Path $root 'project'
    New-Item -ItemType Directory -Force -Path (Join-Path $project '.nightshift') | Out-Null
    $env:CURSOR_AGENT = '1'
    $env:CLAUDE_PROJECT_DIR = $project
    $env:CLAUDECODE = '1'
    $pwsh = (Get-Process -Id $PID).Path
    function Invoke-Captured {
        param([Parameter(Mandatory = $true)][string]$File, [string[]]$Arguments = @())
        $text = & $pwsh -NoProfile -NonInteractive -File $File @Arguments 2>&1 | Out-String
        return @{ Code = $LASTEXITCODE; Text = [string]$text }
    }
    $ns = Join-Path $plugin 'runtime/windows/ns.ps1'
    $bind = Invoke-Captured $ns @('bind')
    Expect-True ($bind.Text -match '(?m)^HOST\tcursor\s*$') "a Cursor environment that also carries CLAUDE_* binds as cursor: $($bind.Text)"

    Remove-Item -LiteralPath $claude -Recurse -Force
    Copy-Item -LiteralPath $plugin -Destination $claude -Recurse
    $foreign = Join-Path $claude 'runtime/windows/ns.ps1'
    $refused = Invoke-Captured $foreign @('start-preflight', '--project', $project, '--host', 'cursor')
    Expect-True ($refused.Code -eq 2) "a claude copy refuses a cursor session ($($refused.Code)): $($refused.Text)"
    Expect-True ($refused.Text.Contains('refuse ownership this copy was installed for claude')) "the refusal names the installing host: $($refused.Text)"
    Expect-True ($refused.Text.Contains("under the user profile's .cursor/plugins directory.")) "the refusal names the cursor copy: $($refused.Text)"

    $helped = Invoke-Captured $foreign @('help')
    Expect-True ($helped.Code -eq 0) "help still answers from the foreign copy: $($helped.Text)"
    Expect-True (-not $helped.Text.Contains('refuse ownership')) 'help is not an ownership refusal'

    $hardhat = Join-Path $claude 'hooks/windows/hardhat.ps1'
    $hook = Invoke-Captured $hardhat @('-HostName', 'codex', '-HookJson', '{"session_id":"sess-own","tool_name":"Bash","tool_input":{"command":"true"}}')
    Expect-True ($hook.Code -eq 0) "a claude copy's codex hardhat exits 0 ($($hook.Code))"
    Expect-True ([string]::IsNullOrWhiteSpace($hook.Text)) "a foreign hook prints nothing: $($hook.Text)"
    Expect-True (-not (Test-Path (Join-Path $project '.nightshift/.hook-copies'))) 'a foreign hook records no copy'
    Expect-True (-not (Test-Path (Join-Path $project '.nightshift/run/hook-copies'))) 'a foreign hook records no copy in the current layout'
}
finally {
    foreach ($name in $saved.Keys) {
        if ([string]::IsNullOrEmpty($saved[$name])) {
            Remove-Item "Env:$name" -ErrorAction SilentlyContinue
        }
        else {
            Set-Item "Env:$name" $saved[$name]
        }
    }
    if (Test-Path -LiteralPath $root) {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($failures.Count -gt 0) {
    Write-Host "ownership-host-logic failed ($($failures.Count)):"
    foreach ($failure in $failures) { Write-Host " - $failure" }
    exit 1
}
Write-Host 'ownership-host-logic passed'
exit 0
