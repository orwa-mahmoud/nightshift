# Portable PowerShell probe for link-workspace usage refusals.
# Run on macOS or Windows: pwsh -File tests/windows/link-workspace-logic.ps1
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if (Test-Path Variable:PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $false
}

$repository = Resolve-Path (Join-Path $PSScriptRoot '../..')
$plugin = Join-Path $repository 'plugins/nightshift'
$helper = Join-Path $plugin 'runtime/windows/link-workspace.ps1'
$failures = New-Object 'System.Collections.Generic.List[string]'

function Expect-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        $failures.Add($Message)
        Write-Host "FAIL: $Message"
    }
}

function Invoke-Linker {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)
    $out = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N') + '.link-out')
    try {
        $previousEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            & (Get-Process -Id $PID).Path -NoProfile -NonInteractive -File $helper @Arguments `
                > $out 2>&1
        }
        finally {
            $ErrorActionPreference = $previousEap
        }
        $code = $LASTEXITCODE
        $text = ''
        if (Test-Path -LiteralPath $out) { $text = [IO.File]::ReadAllText($out) }
        return [pscustomobject]@{ ExitCode = $code; Text = $text }
    }
    finally {
        Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue
    }
}

$root = Join-Path ([IO.Path]::GetTempPath()) ("ns-link-logic-" + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $root -Force
$hostRoot = Join-Path $root 'host'
$workspace = Join-Path $root 'workspace'
$null = New-Item -ItemType Directory -Path $hostRoot -Force
$null = New-Item -ItemType Directory -Path (Join-Path $workspace '.nightshift') -Force

try {
    $unknown = Invoke-Linker @('-HostRoot', $hostRoot, '-Bogus', 'x', '-Workspace', $workspace)
    Expect-True ($unknown.ExitCode -eq 2) "unknown flag exits 2: $($unknown.Text)"
    Expect-True ($unknown.Text -like '*link-workspace: unknown argument: -Bogus*') `
        "unknown flag is a usage refusal: $($unknown.Text)"
    Expect-True (-not ($unknown.Text -like '*ParameterBinding*')) `
        "unknown flag is not a binding exception: $($unknown.Text)"
    Expect-True (-not (Test-Path -LiteralPath (Join-Path $hostRoot '.nightshift-link'))) `
        'unknown flag writes no link'

    $posixUnknown = Invoke-Linker @('--host-root', $hostRoot, '--bogus', 'x', '--workspace', $workspace)
    Expect-True ($posixUnknown.ExitCode -eq 2) "POSIX unknown flag exits 2: $($posixUnknown.Text)"
    Expect-True ($posixUnknown.Text -like '*link-workspace: unknown argument: --bogus*') `
        "POSIX unknown flag is a usage refusal: $($posixUnknown.Text)"
}
finally {
    if (Test-Path -LiteralPath $root) {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($failures.Count -gt 0) {
    Write-Host ("{0} link-workspace-logic failures" -f $failures.Count)
    exit 1
}
Write-Host 'link-workspace-logic ok'
exit 0
