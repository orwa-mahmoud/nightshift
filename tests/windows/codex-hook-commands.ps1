# Execute the manifest commands, rather than bypassing their launcher with -File.
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$repository = Resolve-Path (Join-Path $PSScriptRoot '../..')
$plugin = Join-Path $repository 'plugins/nightshift'
$manifest = Get-Content -LiteralPath (Join-Path $plugin 'hooks/codex/hooks.json') -Raw | ConvertFrom-Json
$hostExecutable = (Get-Process -Id $PID).Path
$failures = New-Object 'System.Collections.Generic.List[string]'
$assertions = 0

function Expect-True {
    param([bool]$Condition, [string]$Message)
    $script:assertions++
    if (-not $Condition) { $failures.Add($Message); Write-Host "FAIL: $Message" }
}

function Invoke-ManifestCommand {
    param([string]$Command, [string]$Shell, [AllowNull()][string]$PluginRoot, [string]$InputText = '{}')
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $Shell
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.WorkingDirectory = $root
    foreach ($key in @($info.EnvironmentVariables.Keys)) {
        if ($key -like 'NIGHTSHIFT_*' -or $key -in @('CODEX_PROJECT_DIR', 'CLAUDE_PROJECT_DIR', 'CLAUDE_PLUGIN_ROOT', 'PLUGIN_ROOT')) {
            $info.EnvironmentVariables.Remove($key)
        }
    }
    if (-not [string]::IsNullOrEmpty($PluginRoot)) { $info.EnvironmentVariables['PLUGIN_ROOT'] = $PluginRoot }
    if ($Shell -eq $env:ComSpec) {
        $info.Arguments = '/d /s /c "' + $Command + '"'
    }
    else {
        $info.Arguments = '-NoProfile -NonInteractive -Command "' + $Command.Replace('"', '\"') + '"'
    }
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $info
    try {
        $null = $process.Start()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $process.StandardInput.WriteLine($InputText)
        $process.StandardInput.Close()
        if (-not $process.WaitForExit(15000)) { $process.Kill(); throw 'Hook command timed out' }
        return [pscustomobject]@{ ExitCode = $process.ExitCode; Stdout = $stdout.Result; Stderr = $stderr.Result }
    }
    finally { $process.Dispose() }
}

$root = Join-Path ([IO.Path]::GetTempPath()) ('ns-codex-hook-commands-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $root
try {
    # Copy only the native hook runtime so its path includes spaces without changing an installation.
    $spacedPlugin = Join-Path $root 'plugin with spaces'
    $null = New-Item -ItemType Directory -Path $spacedPlugin
    Copy-Item -LiteralPath (Join-Path $plugin 'lib') -Destination $spacedPlugin -Recurse
    $null = New-Item -ItemType Directory -Path (Join-Path $spacedPlugin 'hooks')
    Copy-Item -LiteralPath (Join-Path $plugin 'hooks/windows') -Destination (Join-Path $spacedPlugin 'hooks') -Recurse
    $shells = @($hostExecutable)
    if ($env:OS -eq 'Windows_NT') { $shells += $env:ComSpec }
    foreach ($shell in $shells) {
        foreach ($event in $manifest.hooks.PSObject.Properties) {
            $command = [string]$event.Value[0].hooks[0].commandWindows
            $result = Invoke-ManifestCommand $command $shell $spacedPlugin
            Expect-True ($result.ExitCode -eq 0) "$($event.Name) is inert through $shell (exit=$($result.ExitCode), stderr=$($result.Stderr))"
            if ($event.Name -eq 'Stop') {
                $output = $result.Stdout | ConvertFrom-Json
                Expect-True ($output.continue -eq $true) "Stop permits idle completion through $shell"
            }
            else {
                Expect-True ([string]::IsNullOrWhiteSpace($result.Stdout)) "$($event.Name) has no idle output through $shell"
            }
            Expect-True ([string]::IsNullOrWhiteSpace($result.Stderr)) "$($event.Name) has no idle error through $shell : $($result.Stderr)"
        }
        $command = [string]$manifest.hooks.PreToolUse[0].hooks[0].commandWindows
        $missing = Invoke-ManifestCommand $command $shell $null
        Expect-True ($missing.ExitCode -ne 0) 'A missing plugin root must not silently permit a guard'

        # A tiny hook fixture proves payload binding and exit forwarding independently of idle guards.
        $fixture = Join-Path $root 'fixture plugin with spaces'
        $null = New-Item -ItemType Directory -Path (Join-Path $fixture 'hooks/windows') -Force
        $stub = @'
param([string]$HostName, [Parameter(ValueFromPipeline = $true)][string]$HookJson)
[Console]::Out.WriteLine("$HostName|$HookJson")
exit 2
'@
        [IO.File]::WriteAllText((Join-Path $fixture 'hooks/windows/hardhat.ps1'), $stub)
        $forwarded = Invoke-ManifestCommand $command $shell $fixture '{"session_id":"payload-probe"}'
        Expect-True ($forwarded.Stdout.Trim() -eq 'codex|{"session_id":"payload-probe"}') "stdin and host reach the hook through $shell"
        # PowerShell command hosts normalize native nonzero exits; CMD preserves the code.
        $expectedExit = if ($shell -eq $env:ComSpec) { 2 } else { 1 }
        Expect-True ($forwarded.ExitCode -eq $expectedExit) "hook failure stays nonzero through $shell"
    }
    if ($failures.Count -gt 0) { throw "$($failures.Count) manifest assertions failed" }
    Write-Host "Codex hook commands passed ($assertions assertions)."
    exit 0
}
finally {
    $resolved = [IO.Path]::GetFullPath($root)
    if (-not $resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()), [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Refusing cleanup outside the temporary directory'
    }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
