# Sizing a shift from past receipts on native Windows: the PowerShell half of
# tests/shift-estimate.bats. Run on macOS or Windows: pwsh -File tests/windows/shift-estimate-logic.ps1
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$repository = Resolve-Path (Join-Path $PSScriptRoot '../..')
$plugin = Join-Path $repository 'plugins/nightshift'
Import-Module (Join-Path $plugin 'lib/Nightshift.psm1') -Force -DisableNameChecking
$rulesTemplate = Join-Path $plugin 'skills/nightshift/references/nightshift-rules-template.json'
$estimate = Join-Path $plugin 'runtime/windows/shift-estimate.ps1'
$hostExe = (Get-Process -Id $PID).Path
$failures = New-Object 'System.Collections.Generic.List[string]'
$utf8 = New-Object Text.UTF8Encoding($false)
$dot = [string][char]0x00B7

function Expect-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        $failures.Add($Message)
        Write-Host "FAIL: $Message"
    }
}

# New-Receipt <file> <working> <input|-> <output> - an item receipt whose Time and Tokens section
# reads that working time and, unless the input is `-`, those tokens.
function New-Receipt {
    param([string]$Path, [string]$Working, [string]$In, [string]$Out, [string]$CacheRead = '0', [string]$Reasoning = '0')
    $null = New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force
    $text = "# An item.`n`n<!-- usage -->`n"
    if ($In -cne '-') {
        $text += "| Tokens | Amount |`n| --- | ---: |`n| input | $In |`n| output | $Out |`n`n<!-- tokens $In 0 $CacheRead $Out $Reasoning -->`n`n"
    }
    $text += "| Time | |`n| --- | --- |`n| working | $Working |`n| wall | $Working |`n<!-- /usage -->`n"
    [IO.File]::WriteAllText($Path, $text, $utf8)
}

function New-Workspace {
    param([string]$Path)
    $ns = Join-Path $Path '.nightshift'
    $null = New-Item -ItemType Directory -Path $ns -Force
    Copy-Item -LiteralPath $rulesTemplate -Destination (Join-Path $ns 'rules.json') -Force
    & git -C $Path init --quiet
    return $ns
}

function Invoke-Estimate {
    param([string]$Project, [string]$Items = '')
    $arguments = @('-NoProfile', '-NonInteractive', '-File', $estimate, '-Project', $Project)
    if ($Items.Length -gt 0) { $arguments += @('-Items', $Items) }
    $out = @(& $hostExe @arguments)
    return [pscustomobject]@{ Code = $LASTEXITCODE; Text = ($out -join "`n") }
}

$root = Join-Path ([IO.Path]::GetTempPath()) ('ns-shift-estimate-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $root -Force
try {
    $empty = Join-Path $root 'empty'
    $null = New-Workspace $empty
    $run = Invoke-Estimate $empty '4'
    Expect-True ($run.Code -eq 0 -and $run.Text -ceq 'estimate none: no ticked item has a receipt yet') "empty: $($run.Text)"

    $mixed = Join-Path $root 'mixed'
    $ns = New-Workspace $mixed
    [IO.File]::WriteAllText((Join-Path $ns 'punch-list.md'), ("## Items`n- [x] **1. One.** <!-- id: aa11 -->`n- [x] **2. Two.** <!-- id: bb22 -->`n" +
        "- [x] **3. Three.** <!-- id: cc33 -->`n- [ ] **4. Four.** <!-- id: dd44 -->`n"), $utf8)
    $ticked = @(Get-NSTickedReceiptNames $mixed)
    $receipts = Join-Path $ns 'receipts'
    New-Receipt (Join-Path $receipts $ticked[0]) '10m 0s' '400000' '600000'
    New-Receipt (Join-Path $receipts $ticked[1]) '20m 0s' '1500000' '500000'
    New-Receipt (Join-Path $receipts $ticked[2]) '30m 0s' '300000' '200000'
    New-Receipt (Join-Path $receipts 'open-item.md') '5h 0m' '9000000' '9000000'
    New-Receipt (Join-Path $ns 'archive/2026-10-01/receipts/1-codex-item.md') '40m 0s' '2000000' '1000000' '5000000' '300000'
    New-Receipt (Join-Path $ns 'archive/2026-10-01/receipts/2-cursor-item.md') '1h 0m' '-' '-'
    [IO.File]::WriteAllText((Join-Path $ns 'archive/2026-10-01/receipts/README.md'), "# Receipts`n", $utf8)
    $run = Invoke-Estimate $mixed
    $want = @('estimate from 5 ticked items: 3 live, 2 archived',
        "time per item: median 30m 0s $dot range 10m 0s to 1h 0m $dot from 5 items",
        "tokens per item: median 1.5M $dot range 500.0k to 3.0M $dot from 4 items, 1 without a reading") -join "`n"
    Expect-True ($run.Code -eq 0 -and $run.Text -ceq $want) "mixed: $($run.Text)"
    $run = Invoke-Estimate $mixed '4'
    $want = @("for 4 items: time 2h 0m to 4h 0m $dot tokens 6.0M to 12.0M", 'suggested deadline: 2h 30m from the start',
        'suggested budget: soft 30m / 1.5M tokens, hard 1h / 3M tokens') -join "`n"
    Expect-True ($run.Text.EndsWith($want)) "suggestions: $($run.Text)"
    $budget = ConvertFrom-NSBudget 'soft 30m / 1.5M tokens, hard 1h / 3M tokens'
    Expect-True ($null -ne $budget) 'the suggested budget parses as the punch list writes it'

    $few = Join-Path $root 'few'
    $fns = New-Workspace $few
    New-Receipt (Join-Path $fns 'archive/2026-10-01/receipts/1-a.md') '10m 0s' '100' '100'
    New-Receipt (Join-Path $fns 'archive/2026-10-01/receipts/2-b.md') '20m 0s' '-' '-'
    $run = Invoke-Estimate $few '2'
    $want = @('estimate from 2 ticked items: 0 live, 2 archived', 'time per item: too few readings (2 of at least 3)',
        'tokens per item: too few readings (1 of at least 3), 1 without a reading', 'for 2 items: no estimate') -join "`n"
    Expect-True ($run.Text -ceq $want) "few: $($run.Text)"
    Expect-True ((Invoke-Estimate $few '0').Code -eq 1) 'a malformed item count is refused'
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures.Count -gt 0) {
    Write-Host "shift-estimate-logic failed ($($failures.Count)):"
    foreach ($failure in $failures) { Write-Host " - $failure" }
    exit 1
}
Write-Host 'shift-estimate-logic passed'
exit 0
