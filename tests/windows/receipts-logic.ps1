# Portable PowerShell coverage for receipt slugs, tick files, and the report→receipts migration.
# Run on macOS or Windows: pwsh -File tests/windows/receipts-logic.ps1
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$repository = Resolve-Path (Join-Path $PSScriptRoot '../..')
Import-Module (Join-Path $repository 'plugins/nightshift/lib/Nightshift.psm1') -Force -DisableNameChecking
$failures = New-Object 'System.Collections.Generic.List[string]'

function Expect-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        $failures.Add($Message)
        Write-Host "FAIL: $Message"
    }
}

$slugs = Join-Path $repository 'tests/fixtures/receipts/slugs.tsv'
foreach ($row in [IO.File]::ReadAllLines($slugs)) {
    if ([string]::IsNullOrWhiteSpace($row)) { continue }
    $parts = $row.Split("`t")
    $title = $parts[0]
    $want = $(if ($parts.Length -gt 1) { $parts[1] } else { '' })
    $got = Get-NSReceiptSlug $title
    Expect-True ($got -ceq $want) "slug '$title' -> '$got' want '$want'"
}

$root = Join-Path ([IO.Path]::GetTempPath()) ("ns-receipts-logic-" + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $root -Force
try {
    $w = Join-Path $root 'tick'
    $ns = Join-Path $w '.nightshift'
    $null = New-Item -ItemType Directory -Path $ns -Force
    [IO.File]::WriteAllText((Join-Path $ns 'punch-list.md'),
        "## Items`n- [x] **2. Make the packed Node-only build reproducible.**`n")
    [IO.File]::WriteAllText((Join-Path $ns '.shift-armed'), '')
    $label = '2. Make the packed Node-only build reproducible.'
    Expect-True ((Get-NSReceiptBasename $label) -ceq '2-make-the-packed-node-only-build-reproducible') `
        'basename is NN-slug'
    Expect-True ((Get-NSUsageScale 122) -ceq '122') 'below 1000 stays an integer'
    Expect-True ((Get-NSUsageScale 55458) -ceq '55.5k') 'thousands take one decimal k'
    Expect-True ((Get-NSUsageScale 47457543) -ceq '47.5M') 'millions take one decimal M'
    Expect-True ((Get-NSUsageScale 2049584461) -ceq '2.0B') 'billions take one decimal B'
    Expect-True ((Get-NSReceiptBasename '- [x] 1. Title without bold.') -ceq '1-title-without-bold') `
        'a leftover checkbox does not become an x- sidecar name'

    $line = Get-NSUsageLine 'input=122,cache_write=55458,cache_read=47457543,output=42091,reasoning=7332' `
        'claude claude-opus-5' '1' 'claude'
    Expect-True ($line.Contains('| input | 122 |')) 'the Tokens table scales input'
    Expect-True ($line.Contains('| cache write | 55.5k |')) 'thousands take one decimal k'
    Expect-True ($line.Contains('| cache read | 47.5M |')) 'millions take one decimal M'
    Expect-True ($line.Contains('| output | 42.1k |')) 'output is scaled'
    Expect-True ($line.Contains('| reasoning | 7.3k |')) 'reasoning is scaled'
    Expect-True ($line.Contains('<!-- tokens 122 55458 47457543 42091 7332 -->')) `
        'raw counts stay in the hidden comment'

    $duration = Get-NSUsageDurationLine '2663' '0' '' '' ''
    Add-NSGateUsageAppend (Get-NSReceiptPath $w $label) $label $line $duration
    $file = Get-NSReceiptPath $w $label
    $text = [IO.File]::ReadAllText($file)
    Expect-True ($text.StartsWith('# 2. Make the packed Node-only build reproducible.')) `
        'a missing file is created with the item heading'
    Expect-True ($text.Contains('| working | 44m 23s |')) 'working time is on the Time table'
    $usageAt = $text.IndexOf('| Tokens |')
    $durAt = $text.IndexOf('| Time |')
    $bodyAt = $text.IndexOf('## ')
    Expect-True ($usageAt -gt 0 -and $durAt -gt $usageAt) 'usage sits under the heading'
    Expect-True ($bodyAt -lt 0 -or $usageAt -lt $bodyAt) 'usage comes before later narrative'
    $missing = @(Get-NSReceiptsMissingNns $w)
    Expect-True ($missing.Count -eq 1) 'a usage-only receipt still needs model text'
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures.Count -gt 0) {
    Write-Host "receipts-logic failed ($($failures.Count)):"
    foreach ($failure in $failures) { Write-Host " - $failure" }
    exit 1
}
Write-Host 'receipts-logic passed'
exit 0
