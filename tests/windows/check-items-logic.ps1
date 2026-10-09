# Checking drafted items on native Windows: the PowerShell half of tests/check-items.bats, over the
# same fixtures. Run on macOS or Windows: pwsh -File tests/windows/check-items-logic.ps1
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$repository = Resolve-Path (Join-Path $PSScriptRoot '../..')
$plugin = Join-Path $repository 'plugins/nightshift'
$check = Join-Path $plugin 'runtime/windows/check-items.ps1'
$fixtures = Join-Path $repository 'tests/fixtures/check-items'
$hostExe = (Get-Process -Id $PID).Path
$failures = New-Object 'System.Collections.Generic.List[string]'

function Expect-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        $failures.Add($Message)
        Write-Host "FAIL: $Message"
    }
}

function Invoke-Check {
    param([string]$File)
    $out = @(& $hostExe -NoProfile -NonInteractive -File $check -Project ([IO.Path]::GetTempPath()) -File $File)
    return [pscustomobject]@{ Code = $LASTEXITCODE; Text = ($out -join "`n") }
}

$expected = @{
    'well-formed' = @('**1. Load one TOML file.**: ok', '**2. Drop the environment overrides.**: ok', 'checked 2 items: 0 with findings')
    'defects' = @('**1. No verify line.**: no Verify: line',
        '**2. A verify line that checks nothing.**: Verify: names no command and no WHEN/THEN scenario',
        '**3. No commit line.**: no Commit: line',
        '**4. A budget that does not parse.**: Budget: does not parse (about an hour)',
        '**5. A nested checkbox.**: line 23: a nested checkbox; only the item line may be a box',
        'line 26: a checkbox outside an item line counts as an open item',
        'line 29: a checkbox outside an item line counts as an open item',
        'checked 5 items: 5 with findings, 2 stray checkboxes')
    'mixed' = @('**1. Ship the site.**: ok', '**2. Write the about page.**: no Commit: line', 'checked 2 items: 1 with findings')
}
foreach ($name in @('well-formed', 'defects', 'mixed')) {
    $run = Invoke-Check (Join-Path $fixtures ($name + '.md'))
    Expect-True ($run.Code -eq 0 -and $run.Text -ceq ($expected[$name] -join "`n")) "${name}: $($run.Text)"
}
$missing = Invoke-Check (Join-Path $fixtures 'not-there.md')
Expect-True ($missing.Code -eq 0 -and $missing.Text.StartsWith('no items to check')) "missing file: $($missing.Text)"

if ($failures.Count -gt 0) {
    Write-Host "check-items-logic failed ($($failures.Count)):"
    foreach ($failure in $failures) { Write-Host " - $failure" }
    exit 1
}
Write-Host 'check-items-logic passed'
exit 0
