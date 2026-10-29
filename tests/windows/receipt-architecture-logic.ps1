# The architecture diagram on native Windows: the PowerShell half of tests/receipt-architecture.bats.
# Run on macOS or Windows: pwsh -File tests/windows/receipt-architecture-logic.ps1
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$repository = Resolve-Path (Join-Path $PSScriptRoot '../..')
$plugin = Join-Path $repository 'plugins/nightshift'
Import-Module (Join-Path $plugin 'lib/Nightshift.psm1') -Force -DisableNameChecking
$rulesTemplate = Join-Path $plugin 'skills/nightshift/references/nightshift-rules-template.json'
$check = Join-Path $plugin 'runtime/windows/check-receipts.ps1'
$hostExe = (Get-Process -Id $PID).Path
$failures = New-Object 'System.Collections.Generic.List[string]'
$utf8 = New-Object Text.UTF8Encoding($false)
$dash = [string][char]0x2014

function Expect-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        $failures.Add($Message)
        Write-Host "FAIL: $Message"
    }
}

function New-Workspace {
    param([string]$Path, [string]$Diagram)
    $ns = Join-Path $Path '.nightshift'
    $null = New-Item -ItemType Directory -Path (Join-Path $ns 'receipts') -Force
    $rules = [IO.File]::ReadAllText($rulesTemplate).Replace('"architecture": "off"', ('"architecture": "' + $Diagram + '"'))
    [IO.File]::WriteAllText((Join-Path $ns 'rules.json'), $rules, $utf8)
    [IO.File]::WriteAllText((Join-Path $ns 'punch-list.md'),
        "## Items`n- [x] **1. Add the parser.** <!-- id: aa11 -->`n- [x] **2. Tune the parser.** <!-- id: bb22 -->`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $ns 'receipts/architecture.md'),
        "# Architecture`n`n``````mermaid`nflowchart LR`n  cli --> parser`n```````n`nLegend: a box is a component.`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $ns 'receipts/01-add-the-parser-aa11.md'),
        "# 1. Add the parser.`n`nDone.`n`n- Diagram: updated $dash added the parser`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $ns 'receipts/02-tune-the-parser-bb22.md'), "# 2. Tune the parser.`n`nDone.`n", $utf8)
    return $ns
}

$root = Join-Path ([IO.Path]::GetTempPath()) ('ns-architecture-' + [guid]::NewGuid().ToString('N'))
try {
    $on = Join-Path $root 'on'
    $onNs = New-Workspace $on 'on'
    $receipts = Join-Path $onNs 'receipts'
    Invoke-NSArchitectureTick $onNs $on '1. Add the parser.'
    Invoke-NSArchitectureTick $onNs $on '2. Tune the parser.'
    Expect-True (Test-NSSameFileBytes (Join-Path $receipts 'architecture.md') (Join-Path $receipts '01-add-the-parser-aa11/architecture.md')) `
        'the changed diagram is copied into its item''s folder'
    Expect-True (-not (Test-Path -LiteralPath (Join-Path $receipts '02-tune-the-parser-bb22'))) 'an unchanged diagram is not copied again'
    $second = [IO.File]::ReadAllText((Join-Path $receipts '02-tune-the-parser-bb22.md'))
    Expect-True ($second.Contains("<!-- nightshift:architecture -->`n**Architecture after this item:** [architecture.md](./01-add-the-parser-aa11/architecture.md)`n<!-- /nightshift:architecture -->")) `
        "the second receipt links the copy before it: $second"
    $section = Get-NSReceiptArchitectureLines @{ workspace = $on; ns = $onNs }
    $want = @('[architecture.md](./architecture.md), as the shift left it:', '', '```mermaid', 'flowchart LR', '  cli --> parser', '```', '',
        'Legend: a box is a component.', '', 'Changed by:', "- 1. Add the parser. $dash added the parser")
    Expect-True (($section -join "`n") -ceq ($want -join "`n")) ("the morning section: " + ($section -join ' | '))
    $run = (& $hostExe -NoProfile -NonInteractive -File $check -Project $on -Diagrams) -join "`n"
    Expect-True ($run -ceq "2. Tune the parser.: no Diagram: line`nchecked 2 ticked items: 1 with findings") "check-receipts names the gap: $run"

    $off = Join-Path $root 'off'
    $offNs = New-Workspace $off 'off'
    Invoke-NSArchitectureTick $offNs $off '1. Add the parser.'
    Expect-True (-not (Test-Path -LiteralPath (Join-Path $offNs 'receipts/01-add-the-parser-aa11'))) 'off: nothing is copied'
    Expect-True (-not ([IO.File]::ReadAllText((Join-Path $offNs 'receipts/01-add-the-parser-aa11.md'))).Contains('nightshift:architecture')) 'off: no link'
    Expect-True ((Get-NSArchitectureNotice $off).Length -eq 0) 'off: no step in the notice'
    $offSection = Get-NSReceiptArchitectureLines @{ workspace = $off; ns = $offNs }
    Expect-True ($null -eq $offSection -or $offSection.Count -eq 0) 'off: no morning section'
    $offRun = (& $hostExe -NoProfile -NonInteractive -File $check -Project $off -Diagrams) -join "`n"
    Expect-True ($offRun -ceq 'checked 2 ticked items: 0 with findings') "off: nothing to check: $offRun"
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures.Count -gt 0) {
    Write-Host "receipt-architecture-logic failed ($($failures.Count)):"
    foreach ($failure in $failures) { Write-Host " - $failure" }
    exit 1
}
Write-Host 'receipt-architecture-logic passed'
exit 0
