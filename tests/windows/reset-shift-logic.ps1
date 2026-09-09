# Drive runtime/windows/reset-shift.ps1 in a scratch tree.
# Run on macOS or Windows: pwsh -File tests/windows/reset-shift-logic.ps1
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if (Test-Path Variable:PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $false
}

$repository = Resolve-Path (Join-Path $PSScriptRoot '../..')
$plugin = Join-Path $repository 'plugins/nightshift'
$helper = Join-Path $plugin 'runtime/windows/reset-shift.ps1'
Import-Module (Join-Path $plugin 'lib/Nightshift.psm1') -Force -DisableNameChecking

$failures = New-Object 'System.Collections.Generic.List[string]'

function Expect-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        $failures.Add($Message)
        Write-Host "FAIL: $Message"
    }
}

function Invoke-Reset {
    param([string[]]$Arguments = @())
    $out = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N') + '.reset-ep')
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

$helperText = [IO.File]::ReadAllText($helper)
Expect-True ($helperText -notmatch 'ConfirmPath') 'reset invents no confirmation flag'
Expect-True ($helperText -match '-Project DIR') 'reset documents -Project'

$root = Join-Path ([IO.Path]::GetTempPath()) ("ns-reset-ep-" + [guid]::NewGuid().ToString('N'))
$ns = Join-Path $root '.nightshift'
$null = New-Item -ItemType Directory -Path $ns -Force
[IO.File]::WriteAllText((Join-Path $ns 'punch-list.md'), "## Items`n- [ ] **1. first.**`n")
[IO.File]::WriteAllText((Join-Path $ns 'rules.json'), "{ }`n")
[IO.File]::WriteAllText((Join-Path $ns 'shift-policy.json'), "{ }`n")
[IO.File]::WriteAllText((Join-Path $ns 'shift-defaults.json'), "{ }`n")
[IO.File]::WriteAllText((Join-Path $ns 'parking-lot.md'), "parked`n")
[IO.File]::WriteAllText((Join-Path $ns 'snag-log.md'), "snag`n")
[IO.File]::WriteAllText((Join-Path $ns 'shift-log.md'), "log`n")
$deadline = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 3600
[IO.File]::WriteAllText((Join-Path $ns 'deadline'), "$deadline`n")
$null = New-Item -ItemType File -Path (Join-Path $ns '.shift-armed') -Force
$null = New-Item -ItemType File -Path (Join-Path $ns '.shift-session') -Force
$null = New-Item -ItemType Directory -Path (Join-Path $ns 'archive') -Force
[IO.File]::WriteAllText((Join-Path $ns 'archive/keep.md'), "history`n")

$sleeper = $null
try {
    $missing = Invoke-Reset @()
    Expect-True ($missing.ExitCode -eq 1) "missing Project exits 1: $($missing.Text)"
    Expect-True ($missing.Text -like '*reset-shift: -Project is required*') `
        "missing Project is a usage refusal: $($missing.Text)"
    Expect-True (Test-Path -LiteralPath (Join-Path $ns '.shift-armed')) 'missing Project leaves markers'

    $pwsh = (Get-Process -Id $PID).Path
    $sleeper = Start-Process -FilePath $pwsh `
        -ArgumentList @('-NoProfile', '-NonInteractive', '-Command', 'Start-Sleep -Seconds 300') `
        -PassThru
    [IO.File]::WriteAllText((Join-Path $ns '.watchman'), "$($sleeper.Id)`n")
    $unverified = Invoke-Reset @('-Project', $root)
    Expect-True ($unverified.ExitCode -eq 2) "unverified watchman exits 2: $($unverified.Text)"
    Expect-True ($unverified.Text -like '*watchman unverified*') `
        "unverified watchman is named: $($unverified.Text)"
    $sleeper.Refresh()
    Expect-True (-not $sleeper.HasExited) 'unverified watchman is left running'
    Expect-True (Test-Path -LiteralPath (Join-Path $ns '.watchman') -PathType Leaf) `
        'unverified watchman pidfile remains'
    Expect-True (-not (Test-Path -LiteralPath (Join-Path $ns '.shift-armed'))) 'reset clears .shift-armed'
    Expect-True (-not (Test-Path -LiteralPath (Join-Path $ns '.shift-session'))) 'reset clears .shift-session'
    Expect-True (-not (Test-Path -LiteralPath (Join-Path $ns 'STOP'))) 'reset removes STOP'
    Expect-True (-not (Test-Path -LiteralPath (Join-Path $ns 'deadline'))) 'reset removes the deadline'
    Expect-True (-not (Test-Path -LiteralPath (Join-Path $ns 'shift-policy.json'))) 'reset removes tonight policy'
    Expect-True (Test-Path -LiteralPath (Join-Path $ns 'punch-list.md') -PathType Leaf) 'reset keeps the punch list'
    Expect-True (Test-Path -LiteralPath (Join-Path $ns 'rules.json') -PathType Leaf) 'reset keeps rules'
    Expect-True (Test-Path -LiteralPath (Join-Path $ns 'shift-defaults.json') -PathType Leaf) 'reset keeps defaults'
    Expect-True (Test-Path -LiteralPath (Join-Path $ns 'parking-lot.md') -PathType Leaf) 'reset keeps the parking lot'
    Expect-True (Test-Path -LiteralPath (Join-Path $ns 'snag-log.md') -PathType Leaf) 'reset keeps the snag log'
    Expect-True (Test-Path -LiteralPath (Join-Path $ns 'archive/keep.md') -PathType Leaf) 'reset keeps history'
    Expect-True (Test-Path -LiteralPath $ns -PathType Container) 'reset keeps .nightshift'

    $again = Invoke-Reset @('-Project', $root)
    Expect-True ($again.ExitCode -eq 2) "second reset still reports the live unverified pid: $($again.Text)"
    $sleeper.Refresh()
    Expect-True (-not $sleeper.HasExited) 'second reset still leaves the process'
}
finally {
    if ($null -ne $sleeper -and -not $sleeper.HasExited) {
        Stop-Process -Id $sleeper.Id -Force -ErrorAction SilentlyContinue
        try { $null = $sleeper.WaitForExit(5000) } catch { }
    }
    if (Test-Path -LiteralPath $root) {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($failures.Count -gt 0) {
    Write-Host ("{0} reset-shift-logic failures" -f $failures.Count)
    exit 1
}
Write-Host 'reset-shift-logic ok'
exit 0
