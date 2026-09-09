# check-report.ps1 is a thin alias that names check-receipts and forwards to it.
# Run on macOS or Windows: pwsh -File tests/windows/check-report-logic.ps1
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if (Test-Path Variable:PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $false
}

$repository = Resolve-Path (Join-Path $PSScriptRoot '../..')
$helper = Join-Path $repository 'plugins/nightshift/runtime/windows/check-report.ps1'
$hostExecutable = (Get-Process -Id $PID).Path
$failures = New-Object 'System.Collections.Generic.List[string]'

function Expect-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        $failures.Add($Message)
        Write-Host "FAIL: $Message"
    }
}

$root = Join-Path ([IO.Path]::GetTempPath()) ("ns-check-report-alias-" + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path (Join-Path $root '.nightshift/receipts') -Force
try {
    $out = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N') + '.check-out')
    try {
        $previousEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            & $hostExecutable -NoProfile -NonInteractive -File $helper -Project $root > $out 2>&1
        }
        finally {
            $ErrorActionPreference = $previousEap
        }
        $code = $LASTEXITCODE
        $text = if (Test-Path -LiteralPath $out) { [IO.File]::ReadAllText($out) } else { '' }
        Expect-True ($code -eq 0) "alias exits 0 (got $code $text)"
        Expect-True ($text -like '*ns check-receipts*') "alias names check-receipts: $text"
    }
    finally {
        Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue
    }
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures.Count -gt 0) {
    Write-Host "check-report logic failed ($($failures.Count)):"
    foreach ($failure in $failures) {
        Write-Host " - $failure"
    }
    exit 1
}
Write-Host 'check-report logic passed'
exit 0
