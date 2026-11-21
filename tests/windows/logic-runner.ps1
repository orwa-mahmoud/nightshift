# Bounded runner for the independent Windows logic suites.
# Each suite is its own process. A suite reads the repo and writes a private temp
# directory, so several may run at once. The parent environment is not shared:
# Nightshift variables are removed from the child before it starts.

Set-StrictMode -Version 2.0

function Start-NSLogicSuite {
    param(
        [Parameter(Mandatory = $true)][string]$Engine,
        [Parameter(Mandatory = $true)]$Item
    )
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $Engine
    $startInfo.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File ' + (Quote-NSLogicArgument $Item.Suite.Path)
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $drop = New-Object System.Collections.Generic.List[string]
    foreach ($key in @($startInfo.EnvironmentVariables.Keys)) {
        $name = [string]$key
        if ($name -like 'NIGHTSHIFT_*' -or $name -in @(
                'CLAUDE_PROJECT_DIR', 'CODEX_PROJECT_DIR', 'CLAUDE_PLUGIN_ROOT', 'PLUGIN_ROOT'
            )) {
            $drop.Add($name)
        }
    }
    foreach ($name in $drop) {
        [void]$startInfo.EnvironmentVariables.Remove($name)
    }
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    [void]$process.Start()
    return [pscustomobject]@{
        Item = $Item
        Process = $process
        Started = [DateTime]::UtcNow
        Stdout = $process.StandardOutput.ReadToEndAsync()
        Stderr = $process.StandardError.ReadToEndAsync()
        Peak = [int64]0
    }
}

function Quote-NSLogicArgument {
    param([AllowEmptyString()][string]$Value)
    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append('"')
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq '"') {
            [void]$builder.Append('\"')
        }
        else {
            [void]$builder.Append($character)
        }
    }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Complete-NSLogicSuite {
    param($Job, [bool]$TimedOut)
    $stdout = ''
    $stderr = ''
    try { $stdout = [string]$Job.Stdout.Result } catch { $stdout = '' }
    try { $stderr = [string]$Job.Stderr.Result } catch { $stderr = '' }
    $code = 124
    if (-not $TimedOut) {
        try { $code = [int]$Job.Process.ExitCode } catch { $code = 1 }
    }
    $status = 'fail'
    if ($TimedOut) { $status = 'timeout' }
    elseif ($code -eq 0) { $status = 'pass' }
    $ms = [int]([DateTime]::UtcNow - $Job.Started).TotalMilliseconds
    $name = [string]$Job.Item.Suite.Name
    Write-Host ("logic {0} {1} {2}ms" -f $name, $status, $ms)
    if ($status -ne 'pass') {
        if (-not [string]::IsNullOrEmpty($stdout)) { Write-Host $stdout }
        if (-not [string]::IsNullOrEmpty($stderr)) { Write-Host $stderr }
    }
    try { $Job.Process.Dispose() } catch { }
    return [pscustomobject]@{
        Name = $name
        Label = [string]$Job.Item.Suite.Label
        ExitCode = $code
        Stdout = $stdout
        Stderr = $stderr
        Milliseconds = $ms
        Status = $status
        PeakBytes = [int64]$Job.Peak
    }
}

function Invoke-NSLogicSuites {
    param(
        [Parameter(Mandatory = $true)][string]$Engine,
        [Parameter(Mandatory = $true)][object[]]$Suites,
        [int]$Degree = 2,
        [int]$TimeoutSeconds = 0
    )
    if ($Degree -lt 1) { $Degree = 1 }
    $pending = New-Object System.Collections.Generic.List[object]
    $index = 0
    foreach ($suite in $Suites) {
        $pending.Add([pscustomobject]@{ Index = $index; Suite = $suite })
        $index++
    }
    $running = New-Object System.Collections.Generic.List[object]
    $results = New-Object object[] $Suites.Count
    $wall = [Diagnostics.Stopwatch]::StartNew()
    $peak = [int64]0
    while ($pending.Count -gt 0 -or $running.Count -gt 0) {
        while ($pending.Count -gt 0 -and $running.Count -lt $Degree) {
            $next = $pending[0]
            $pending.RemoveAt(0)
            $running.Add((Start-NSLogicSuite -Engine $Engine -Item $next))
        }
        $still = New-Object System.Collections.Generic.List[object]
        foreach ($job in $running) {
            $timedOut = $false
            $done = $job.Process.HasExited
            if (-not $done -and $TimeoutSeconds -gt 0) {
                $elapsed = ([DateTime]::UtcNow - $job.Started).TotalSeconds
                if ($elapsed -ge $TimeoutSeconds) {
                    try { $job.Process.Kill() } catch { }
                    try { [void]$job.Process.WaitForExit(5000) } catch { }
                    $timedOut = $true
                    $done = $true
                }
            }
            if (-not $done) {
                try {
                    $job.Process.Refresh()
                    if ($job.Process.WorkingSet64 -gt $job.Peak) { $job.Peak = $job.Process.WorkingSet64 }
                    if ($job.Peak -gt $peak) { $peak = $job.Peak }
                }
                catch { }
                $still.Add($job)
                continue
            }
            $results[$job.Item.Index] = Complete-NSLogicSuite -Job $job -TimedOut $timedOut
            if ($job.Peak -gt $peak) { $peak = [int64]$job.Peak }
        }
        $running = $still
        if ($running.Count -ge $Degree -or ($pending.Count -eq 0 -and $running.Count -gt 0)) {
            Start-Sleep -Milliseconds 50
        }
    }
    $failed = 0
    foreach ($result in $results) {
        if ($null -eq $result -or $result.Status -ne 'pass') { $failed++ }
    }
    $wallMs = [int]$wall.Elapsed.TotalMilliseconds
    Write-Host ("logic suites: {0} run, {1} failed, degree {2}, wall {3}ms, peak {4} bytes" -f `
            $results.Count, $failed, $Degree, $wallMs, $peak)
    return [pscustomobject]@{
        Results = $results
        Failed = $failed
        Degree = $Degree
        WallMilliseconds = $wallMs
        PeakBytes = $peak
    }
}
