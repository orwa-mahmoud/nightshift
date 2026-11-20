# Portable PowerShell coverage for Windows Schedule empty-list parked-work notes.
# Run on macOS or Windows: pwsh -File tests/windows/schedule-empty-logic.ps1
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if (Test-Path Variable:PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $false
}

$repository = Resolve-Path (Join-Path $PSScriptRoot '../..')
$helper = Join-Path $repository 'plugins/nightshift/runtime/windows/schedule.ps1'
$rulesTemplate = Join-Path $repository 'plugins/nightshift/config/nightshift-rules-template.json'
$hostExecutable = (Get-Process -Id $PID).Path
$failures = New-Object 'System.Collections.Generic.List[string]'

function Expect-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        $failures.Add($Message)
        Write-Host "FAIL: $Message"
    }
}

function Invoke-Schedule {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)
    $argList = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $helper) + $Arguments
    $stdout = [Collections.Generic.List[string]]::new()
    $stderr = [Collections.Generic.List[string]]::new()
    $previousEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        foreach ($item in @(& $hostExecutable @argList 2>&1)) {
            if ($item -is [Management.Automation.ErrorRecord]) {
                $stderr.Add([string]$item)
            }
            else {
                $stdout.Add([string]$item)
            }
        }
    }
    finally {
        $ErrorActionPreference = $previousEap
    }
    return [pscustomobject]@{
        ExitCode = [int]$LASTEXITCODE
        Stdout = ($stdout -join "`n")
        Stderr = ($stderr -join "`n")
    }
}

$root = Join-Path ([IO.Path]::GetTempPath()) ("ns-schedule-empty-logic-" + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path (Join-Path $root '.nightshift') -Force
try {
    $ns = Join-Path $root '.nightshift'
    Copy-Item -LiteralPath $rulesTemplate -Destination (Join-Path $ns 'rules.json')
    & git -C $root init --quiet
    if ($LASTEXITCODE -ne 0) { throw "git init failed in $root" }
    & git -C $root -c user.name=t -c user.email=t@example.com commit --allow-empty -q -m init
    if ($LASTEXITCODE -ne 0) { throw "git commit failed in $root" }

    [IO.File]::WriteAllText((Join-Path $ns 'punch-list.md'), "## Items`n`n")
    [IO.File]::WriteAllText((Join-Path $ns 'work-orders.md'),
        "# Work Orders`n`n## Work order  -  test`nHours: 2`n`n- [ ] **Coverage hunt.**`n")
    [IO.File]::WriteAllText((Join-Path $ns 'drafting-table.md'), @'
# Drafting Table

```text
- [ ] **1. example only.**
```

---

- [ ] **Real draft.**
'@)

    $preflight = Invoke-Schedule @('-Project', $root, '-Preflight')
    Expect-True ($preflight.ExitCode -eq 1) "empty-list preflight exits 1 (got $($preflight.ExitCode) $($preflight.Stderr))"
    Expect-True ($preflight.Stdout -match 'no open items') 'preflight fails closed on an empty punch list'
    Expect-True ($preflight.Stdout -match 'NOTE 1 parked Hunt work order') `
        'preflight names parked Hunt orders'
    Expect-True ($preflight.Stdout -match 'NOTE 1 drafting-table item') `
        'preflight names drafting-table items after the rule'

    $generate = Invoke-Schedule @('-Project', $root, '-At', '04:05')
    Expect-True ($generate.ExitCode -eq 0) "empty-list generate exits 0 (got $($generate.ExitCode) $($generate.Stderr))"
    Expect-True ($generate.Stdout -match 'Note: the punch list has no open items') `
        'generate warns that a scheduled start promotes nothing'
    Expect-True ($generate.Stdout -match 'Parked Hunt work orders: 1') `
        'generate names parked Hunt orders'
    Expect-True ($generate.Stdout -match 'Drafting-table items: 1') `
        'generate names drafting-table items after the rule'
    Expect-True ($generate.Stdout -match 'Scheduled start for') `
        'generate still prints the registration command after the empty-list note'

    $artifact = Join-Path $root 'notes'
    $artifactNs = Join-Path $artifact '.nightshift'
    $null = New-Item -ItemType Directory -Path $artifactNs -Force
    Copy-Item -LiteralPath $rulesTemplate -Destination (Join-Path $artifactNs 'rules.json')
    [IO.File]::WriteAllText((Join-Path $artifactNs 'work-mode'), "artifact`n")
    [IO.File]::WriteAllText((Join-Path $artifactNs 'work-target'), "$artifact`n")
    [IO.File]::WriteAllText((Join-Path $artifactNs 'punch-list.md'), "## Items`n- [ ] **work.**`n")
    [IO.File]::WriteAllText((Join-Path $artifactNs 'receipts'), "not-a-dir`n")
    $unusable = Invoke-Schedule @('-Project', $artifact, '-Preflight')
    Expect-True ($unusable.ExitCode -eq 1) "unusable receipts preflight exits 1 (got $($unusable.ExitCode) $($unusable.Stderr))"
    Expect-True ($unusable.Stdout -match 'artifact receipts path is not a usable directory') `
        'preflight fails when receipts path is unusable'
    Expect-True ($unusable.Stdout -match 'a scheduled start will refuse to arm') `
        'preflight names the scheduled-start refuse'
    $unusableGen = Invoke-Schedule @('-Project', $artifact, '-At', '04:05')
    Expect-True ($unusableGen.ExitCode -eq 1) "unusable receipts generate exits 1 (got $($unusableGen.ExitCode) $($unusableGen.Stderr))"
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures.Count -gt 0) {
    Write-Host "schedule-empty-logic failed ($($failures.Count)):"
    foreach ($failure in $failures) { Write-Host " - $failure" }
    exit 1
}
Write-Host 'schedule-empty-logic passed'
exit 0
