# Portable PowerShell coverage for the session-end hook's owner reasons and the Codex lease.
# Run on macOS or Windows: pwsh -File tests/windows/session-end-logic.ps1
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if (Test-Path Variable:PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $false
}

$repository = Resolve-Path (Join-Path $PSScriptRoot '../..')
$hook = Join-Path $repository 'plugins/nightshift/hooks/windows/session-end.ps1'
$template = Join-Path $repository 'plugins/nightshift/skills/nightshift/references/nightshift-rules-template.json'
$pwsh = (Get-Process -Id $PID).Path
$utf8 = New-Object Text.UTF8Encoding($false)
$root = Join-Path ([IO.Path]::GetTempPath()) ('ns-session-end-' + [guid]::NewGuid().ToString('N'))
$failures = New-Object 'System.Collections.Generic.List[string]'

function Expect-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        $failures.Add($Message)
        Write-Host "FAIL: $Message"
    }
}

function New-EndProject {
    param([Parameter(Mandatory = $true)][string]$Name)
    $path = Join-Path $root $Name
    $ns = Join-Path $path '.nightshift'
    $null = New-Item -ItemType Directory -Force -Path $ns
    Copy-Item -LiteralPath $template -Destination (Join-Path $ns 'rules.json')
    [IO.File]::WriteAllText((Join-Path $ns 'punch-list.md'), "## Items`n- [ ] **1.**`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $ns '.shift-armed'), '', $utf8)
    return $path
}

function Set-ProcessArguments {
    # Windows PowerShell 5.1 runs on .NET Framework, whose ProcessStartInfo has
    # no ArgumentList. Quote into Arguments there, the way CommandLineToArgvW
    # reads it back.
    param(
        [Parameter(Mandatory = $true)]$StartInfo,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )
    if ($null -ne $StartInfo.PSObject.Properties['ArgumentList']) {
        foreach ($argument in $Arguments) { $null = $StartInfo.ArgumentList.Add($argument) }
        return
    }
    $quoted = New-Object Collections.Generic.List[string]
    foreach ($argument in $Arguments) {
        $escaped = $argument -replace '(\\*)"', '$1$1\"'
        $escaped = $escaped -replace '(\\+)$', '$1$1'
        $quoted.Add('"' + $escaped + '"')
    }
    $StartInfo.Arguments = ($quoted -join ' ')
}

function Set-ProcessEnvironment {
    param(
        [Parameter(Mandatory = $true)]$StartInfo,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Value
    )
    foreach ($existing in @($StartInfo.EnvironmentVariables.Keys)) {
        if ($existing -ieq $Name) { $null = $StartInfo.EnvironmentVariables.Remove($existing) }
    }
    $StartInfo.EnvironmentVariables.Add($Name, $Value)
}

function Invoke-End {
    param(
        [Parameter(Mandatory = $true)][string]$ForHost,
        [Parameter(Mandatory = $true)][string]$Project,
        [Parameter(Mandatory = $true)][string]$Json,
        [hashtable]$Environment = @{}
    )
    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $pwsh
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    Set-ProcessArguments -StartInfo $psi -Arguments @(
        '-NoProfile', '-NonInteractive', '-File', $hook, '-HostName', $ForHost, '-HookJson', $Json
    )
    $dirName = switch ($ForHost) {
        'claude' { 'CLAUDE_PROJECT_DIR' }
        'codex' { 'CODEX_PROJECT_DIR' }
        'cursor' { 'CURSOR_PROJECT_DIR' }
    }
    Set-ProcessEnvironment -StartInfo $psi -Name $dirName -Value $Project
    foreach ($name in $Environment.Keys) {
        Set-ProcessEnvironment -StartInfo $psi -Name ([string]$name) -Value ([string]$Environment[$name])
    }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $psi
    $null = $process.Start()
    $null = $process.StandardOutput.ReadToEnd()
    $null = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    return $process.ExitCode
}

try {
    $null = New-Item -ItemType Directory -Force -Path $root
    $claude = New-EndProject 'claude'
    $claudeMarker = Join-Path $claude '.nightshift/.session-end'
    foreach ($reason in @('prompt_input_exit', 'logout', 'clear', 'resume')) {
        if (Test-Path -LiteralPath $claudeMarker) { Remove-Item -LiteralPath $claudeMarker -Force }
        $json = '{"session_id":"sid","cwd":"' + ($claude -replace '\\', '\\') + '","reason":"' + $reason + '"}'
        Expect-True ((Invoke-End 'claude' $claude $json) -eq 0) "claude $reason exits 0"
        Expect-True (Test-Path -LiteralPath $claudeMarker) "claude $reason writes the marker"
        Expect-True (([IO.File]::ReadAllText($claudeMarker)).Contains("clean session end ($reason)")) `
            "claude $reason names itself"
    }
    foreach ($reason in @('other', 'unknown', 'exit', 'bypass_permissions_disabled')) {
        if (Test-Path -LiteralPath $claudeMarker) { Remove-Item -LiteralPath $claudeMarker -Force }
        $json = '{"session_id":"sid","reason":"' + $reason + '"}'
        Expect-True ((Invoke-End 'claude' $claude $json) -eq 0) "claude $reason exits 0"
        Expect-True (-not (Test-Path -LiteralPath $claudeMarker)) "claude $reason writes nothing"
    }
    if (Test-Path -LiteralPath $claudeMarker) { Remove-Item -LiteralPath $claudeMarker -Force }
    Expect-True ((Invoke-End 'claude' $claude '{"session_id":"sid"}') -eq 0) 'a payload with no reason exits 0'
    Expect-True (-not (Test-Path -LiteralPath $claudeMarker)) 'a payload with no reason writes nothing'

    $cursor = New-EndProject 'cursor'
    [IO.File]::WriteAllText((Join-Path $cursor '.nightshift/.shift-session'), "sid`n`n`n`ncursor`n", $utf8)
    $cursorMarker = Join-Path $cursor '.nightshift/.session-end'
    Expect-True ((Invoke-End 'cursor' $cursor '{"conversation_id":"sid","reason":"user_close"}') -eq 0) `
        'cursor user_close exits 0'
    Expect-True (Test-Path -LiteralPath $cursorMarker) 'cursor user_close writes the marker'
    Remove-Item -LiteralPath $cursorMarker -Force
    Expect-True ((Invoke-End 'cursor' $cursor '{"conversation_id":"sid","reason":"completed"}') -eq 0) `
        'cursor completed exits 0'
    Expect-True (-not (Test-Path -LiteralPath $cursorMarker)) 'cursor completed writes nothing'

    $codex = New-EndProject 'codex'
    [IO.File]::WriteAllText((Join-Path $codex '.nightshift/.shift-session'), "right-id`n`n`n`ncodex`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $codex '.nightshift/.shift-lease'),
        "right-id`ncodex`n2`nrevival-nonce`n999999`nMon Jan  1 00:00:00 2026`n", $utf8)
    $codexMarker = Join-Path $codex '.nightshift/.session-end'
    $codexJson = '{"session_id":"right-id","reason":"other"}'
    Expect-True ((Invoke-End 'codex' $codex $codexJson) -eq 0) 'a codex end without the lease exits 0'
    Expect-True (-not (Test-Path -LiteralPath $codexMarker)) 'a codex end without the lease writes nothing'
    Expect-True ((Invoke-End 'codex' $codex $codexJson @{
                NIGHTSHIFT_LEASE_NONCE = 'revival-nonce'
                NIGHTSHIFT_LEASE_GENERATION = '2'
            }) -eq 0) 'the codex lease holder exits 0'
    Expect-True (Test-Path -LiteralPath $codexMarker) 'the codex lease holder writes the marker'
}
finally {
    if (Test-Path -LiteralPath $root) {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($failures.Count -gt 0) {
    Write-Host "session-end-logic failed ($($failures.Count)):"
    foreach ($failure in $failures) { Write-Host " - $failure" }
    exit 1
}
Write-Host 'session-end-logic passed'
exit 0
