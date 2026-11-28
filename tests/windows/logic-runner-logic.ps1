# The logic runner keeps suite identity under overlap, failure, and timeout.
# Run: pwsh -File tests/windows/logic-runner-logic.ps1
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'logic-runner.ps1')

$root = Join-Path ([IO.Path]::GetTempPath()) ('ns-logic-runner-' + [guid]::NewGuid().ToString('N'))
$failures = New-Object System.Collections.Generic.List[string]
function Expect-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        $failures.Add($Message)
        Write-Host "FAIL: $Message"
    }
}

try {
    $null = New-Item -ItemType Directory -Path $root -Force
    $passA = Join-Path $root 'pass-a.ps1'
    $passB = Join-Path $root 'pass-b.ps1'
    $fail = Join-Path $root 'fail.ps1'
    $slow = Join-Path $root 'slow.ps1'
    [IO.File]::WriteAllText($passA, "Write-Host 'suite-a'`nexit 0`n")
    [IO.File]::WriteAllText($passB, "Write-Host 'suite-b'`nexit 0`n")
    [IO.File]::WriteAllText($fail, "Write-Host 'suite-fail'`nexit 3`n")
    [IO.File]::WriteAllText($slow, "Start-Sleep -Seconds 30`nexit 0`n")
    $engine = (Get-Process -Id $PID).Path

    $pair = @(
        @{ Name = 'pass-a.ps1'; Path = $passA; Label = 'suite a' }
        @{ Name = 'pass-b.ps1'; Path = $passB; Label = 'suite b' }
    )
    $serial = Invoke-NSLogicSuites -Engine $engine -Suites $pair -Degree 1
    $parallel = Invoke-NSLogicSuites -Engine $engine -Suites $pair -Degree 2
    $serialRows = @($serial.Results)
    $parallelRows = @($parallel.Results)
    Expect-True ($serialRows.Count -eq 2) 'serial returns both suites'
    Expect-True ($parallelRows.Count -eq 2) 'parallel returns both suites'
    Expect-True ($serialRows[0].Name -eq 'pass-a.ps1' -and $serialRows[1].Name -eq 'pass-b.ps1') 'serial keeps suite order'
    Expect-True ($parallelRows[0].Name -eq 'pass-a.ps1' -and $parallelRows[1].Name -eq 'pass-b.ps1') 'parallel keeps suite order'
    Expect-True ($serialRows[0].Status -eq 'pass' -and $serialRows[1].Status -eq 'pass') 'serial suites pass'
    Expect-True ($parallelRows[0].Status -eq 'pass' -and $parallelRows[1].Status -eq 'pass') 'parallel suites pass'
    Expect-True ($serialRows[0].Stdout.Contains('suite-a') -and $parallelRows[0].Stdout.Contains('suite-a')) 'suite a keeps its output'
    Expect-True ($serialRows[1].Stdout.Contains('suite-b') -and $parallelRows[1].Stdout.Contains('suite-b')) 'suite b keeps its output'

    # Each suite marks that it started, then waits for the other's mark: both pass only
    # when the runner had them running at the same time.
    $meet = @(
        @{ Name = 'meet-a.ps1'; Path = (Join-Path $root 'meet-a.ps1'); Label = 'meet a' }
        @{ Name = 'meet-b.ps1'; Path = (Join-Path $root 'meet-b.ps1'); Label = 'meet b' }
    )
    foreach ($pairing in @(@('a', 'b'), @('b', 'a'))) {
        $own = Join-Path $root ('started-' + $pairing[0])
        $other = Join-Path $root ('started-' + $pairing[1])
        $body = "[IO.File]::WriteAllText('$own', '')`n" +
            "`$until = [DateTime]::UtcNow.AddSeconds(60)`n" +
            "while (-not (Test-Path -LiteralPath '$other')) {`n" +
            "    if ([DateTime]::UtcNow -gt `$until) { Write-Host 'alone-$($pairing[0])'; exit 1 }`n" +
            "    Start-Sleep -Milliseconds 50`n" +
            "}`nWrite-Host 'met-$($pairing[0])'`nexit 0`n"
        [IO.File]::WriteAllText((Join-Path $root ('meet-' + $pairing[0] + '.ps1')), $body)
    }
    $meetRows = @((Invoke-NSLogicSuites -Engine $engine -Suites $meet -Degree 2 -TimeoutSeconds 120).Results)
    Expect-True ($meetRows[0].Status -eq 'pass' -and $meetRows[1].Status -eq 'pass') `
        "degree 2 runs the two suites at the same time (got $($meetRows[0].Status) $($meetRows[1].Status))"

    $broken = @(
        @{ Name = 'pass-a.ps1'; Path = $passA; Label = 'suite a' }
        @{ Name = 'fail.ps1'; Path = $fail; Label = 'the failing helper' }
    )
    $failedRun = Invoke-NSLogicSuites -Engine $engine -Suites $broken -Degree 2
    $failed = @($failedRun.Results)
    Expect-True ($failed[0].Status -eq 'pass') 'a passing suite still passes beside a failure'
    Expect-True ($failed[1].Name -eq 'fail.ps1' -and $failed[1].Status -eq 'fail' -and $failed[1].ExitCode -eq 3) `
        "the failing suite keeps its name and exit code (got $($failed[1].Name) $($failed[1].Status) $($failed[1].ExitCode))"
    Expect-True ($failed[1].Stdout.Contains('suite-fail')) 'the failing suite keeps its output'

    $hung = @(@{ Name = 'slow.ps1'; Path = $slow; Label = 'the timed-out helper' })
    $timedRun = Invoke-NSLogicSuites -Engine $engine -Suites $hung -Degree 1 -TimeoutSeconds 1
    $timed = @($timedRun.Results)
    Expect-True ($timed[0].Name -eq 'slow.ps1' -and $timed[0].Status -eq 'timeout' -and $timed[0].ExitCode -eq 124) `
        "a timed-out suite is named (got $($timed[0].Name) $($timed[0].Status) $($timed[0].ExitCode))"
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures.Count -gt 0) {
    Write-Host "logic-runner-logic failed ($($failures.Count)):"
    foreach ($failure in $failures) { Write-Host " - $failure" }
    exit 1
}
Write-Host 'logic-runner-logic passed'
exit 0
