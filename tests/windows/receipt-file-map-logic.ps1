# File maps on native Windows: the PowerShell half of tests/receipt-file-map.bats.
# Run on macOS or Windows: pwsh -File tests/windows/receipt-file-map-logic.ps1
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$repository = Resolve-Path (Join-Path $PSScriptRoot '../..')
$plugin = Join-Path $repository 'plugins/nightshift'
Import-Module (Join-Path $plugin 'lib/Nightshift.psm1') -Force -DisableNameChecking
$rulesTemplate = Join-Path $plugin 'skills/nightshift/references/nightshift-rules-template.json'
$morning = Join-Path $plugin 'runtime/windows/morning-receipt.ps1'
$hostExe = (Get-Process -Id $PID).Path
$failures = New-Object 'System.Collections.Generic.List[string]'
$utf8 = New-Object Text.UTF8Encoding($false)
$dash = [string][char]0x2014
$fence = '```'

function Expect-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        $failures.Add($Message)
        Write-Host "FAIL: $Message"
    }
}

function Invoke-Git {
    param([string]$Directory, [string[]]$Arguments)
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $out = & git -C $Directory @Arguments 2>&1 } finally { $ErrorActionPreference = $previous }
    if ($LASTEXITCODE -ne 0) { throw ('git ' + ($Arguments -join ' ') + ': ' + ($out -join ' ')) }
    return (@($out) -join "`n")
}

# New-Project <path> <punch> <fileMap> - a repository with its workspace, as Setup leaves one.
function New-Project {
    param([string]$Path, [string]$Punch, [string]$FileMap)
    $ns = Join-Path $Path '.nightshift'
    $null = New-Item -ItemType Directory -Path (Join-Path $ns 'receipts') -Force
    $rules = [IO.File]::ReadAllText($rulesTemplate).Replace('"fileMap": "off"', ('"fileMap": "' + $FileMap + '"'))
    [IO.File]::WriteAllText((Join-Path $ns 'rules.json'), $rules, $utf8)
    [IO.File]::WriteAllText((Join-Path $ns 'punch-list.md'), $Punch, $utf8)
    $null = Invoke-Git $Path @('init', '-q')
    $null = Invoke-Git $Path @('config', 'user.email', 'dev@example.com')
    $null = Invoke-Git $Path @('config', 'user.name', 'tester')
    $null = Invoke-Git $Path @('config', 'core.autocrlf', 'false')
    $null = Invoke-Git $Path @('commit', '-q', '--allow-empty', '-m', 'init')
    return $ns
}

function Write-Lines {
    param([string]$Root, [string]$Relative, [int]$Count)
    $path = Join-Path $Root $Relative
    $null = New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force
    $text = ((1..$Count | ForEach-Object { "line $_" }) -join "`n") + "`n"
    [IO.File]::WriteAllText($path, $text, $utf8)
}

function Save-Commit {
    param([string]$Root, [string]$Message)
    $null = Invoke-Git $Root @('add', '-A', '--', '.', ':!.nightshift')
    $null = Invoke-Git $Root @('commit', '-q', '-m', $Message)
}

function Get-Block {
    param([string]$Receipt)
    $text = [IO.File]::ReadAllText($Receipt)
    $start = $text.IndexOf('<!-- nightshift:file-map -->')
    if ($start -lt 0) { return '' }
    $end = $text.IndexOf('<!-- /nightshift:file-map -->')
    return $text.Substring($start, $end - $start + '<!-- /nightshift:file-map -->'.Length)
}

$root = Join-Path ([IO.Path]::GetTempPath()) ('ns-file-map-' + [guid]::NewGuid().ToString('N'))
try {
    # An item's commit that adds three files and changes one is drawn as those four paths.
    $item = Join-Path $root 'item'
    $itemNs = New-Project $item "## Items`n- [ ] **1. Add the parser.** <!-- id: aa11 -->`n" 'on'
    Write-Lines $item 'README.md' 2
    Save-Commit $item 'readme'
    Start-NSFileMap $item
    $base = Invoke-Git $item @('rev-parse', 'HEAD')
    Write-Lines $item 'src/a.sh' 2
    Write-Lines $item 'src/b.sh' 1
    Write-Lines $item 'docs/c.md' 3
    [IO.File]::WriteAllText((Join-Path $item 'README.md'), "line 1`nchanged`n", $utf8)
    Save-Commit $item 'parser'
    $head = Invoke-Git $item @('rev-parse', 'HEAD')
    $receipt = Join-Path $itemNs 'receipts/01-add-the-parser-aa11.md'
    [IO.File]::WriteAllText($receipt, "# 1. Add the parser.`n`nDone.`n", $utf8)
    $stamp = [DateTime]::new(2026, 9, 24, 1, 1, 0, [DateTimeKind]::Utc)
    [IO.File]::SetLastWriteTimeUtc($receipt, $stamp)
    Invoke-NSFileMapTick $itemNs $item '1. Add the parser.'
    $want = "<!-- nightshift:file-map -->`n## File map`n`n4 files changed, +7 -1`n`n${fence}text`n./`n  M README.md  +1 -1`ndocs/`n  A c.md  +3 -0`nsrc/`n  A a.sh  +2 -0`n  A b.sh  +1 -0`n$fence`n<!-- /nightshift:file-map -->"
    $got = Get-Block $receipt
    Expect-True ($got -ceq $want) "the item map names the four paths: $got"
    Expect-True ([IO.File]::GetLastWriteTimeUtc($receipt) -eq $stamp) 'the receipt keeps its time'
    Expect-True (-not ((Get-NSReceiptModelLines $receipt) -join "`n").Contains('File map')) 'the block is not the model''s text'
    Invoke-NSFileMapTick $itemNs $item '1. Add the parser.'
    Expect-True (([regex]::Matches([IO.File]::ReadAllText($receipt), '<!-- nightshift:file-map -->')).Count -eq 1) 'a refresh draws the block once'
    $page = Join-Path $itemNs 'receipts/shift-map.md'
    $pageText = [IO.File]::ReadAllText($page)
    Expect-True ($pageText.Contains("From $($base.Substring(0, 12)), where the shift started, to $($head.Substring(0, 12)).`n")) "the shift map names its range: $pageText"
    Expect-True ((Get-NSFileMapSummary $page) -ceq '4 files changed, +7 -1') 'the shift map summary'
    Write-NSReceiptsIndex -Workspace $item
    Expect-True ([IO.File]::ReadAllText((Join-Path $itemNs 'receipts/README.md')).Contains("Shift file map: [shift-map.md](./shift-map.md)`n")) 'the index links the shift map'
    $morningText = (& $hostExe -NoProfile -NonInteractive -File $morning -Project $item) -join "`n"
    Expect-True ($morningText.Contains('- Files: 4 files changed, +7 -1 ([shift-map.md](./shift-map.md))')) "the morning page shows the shift map: $morningText"

    # A commit that touches 120 files collapses its folders and still totals 120.
    $wide = Join-Path $root 'wide'
    $wideNs = New-Project $wide "## Items`n- [ ] **1. Wide.** <!-- id: aa11 -->`n" 'on'
    Start-NSFileMap $wide
    foreach ($i in 1..40) {
        Write-Lines $wide "pkg/a/x$i.txt" 1
        Write-Lines $wide "pkg/b/y$i.txt" 1
        Write-Lines $wide "lib/z$i.txt" 1
    }
    Save-Commit $wide 'wide'
    $wideReceipt = Join-Path $wideNs 'receipts/01-wide-aa11.md'
    [IO.File]::WriteAllText($wideReceipt, "# 1. Wide.`n`nDone.`n", $utf8)
    Invoke-NSFileMapTick $wideNs $wide '1. Wide.'
    $want = "<!-- nightshift:file-map -->`n## File map`n`n120 files changed, +120 -0, folders collapsed`n`n${fence}text`nlib/  40 files  +40 -0`npkg/  80 files  +80 -0`n$fence`n<!-- /nightshift:file-map -->"
    $got = Get-Block $wideReceipt
    Expect-True ($got -ceq $want) "120 files collapse to their folders: $got"

    # With file maps off nothing is recorded and no map or block is written.
    $off = Join-Path $root 'off'
    $offNs = New-Project $off "## Items`n- [ ] **1. Quiet.** <!-- id: aa11 -->`n" 'off'
    Start-NSFileMap $off
    Expect-True (-not (Test-Path -LiteralPath (Get-NSLayoutPath $offNs 'file-map'))) 'no starting commit is recorded'
    Write-Lines $off 'src/a.sh' 2
    Save-Commit $off 'quiet'
    $offReceipt = Join-Path $offNs 'receipts/01-quiet-aa11.md'
    [IO.File]::WriteAllText($offReceipt, "# 1. Quiet.`n`nDone.`n", $utf8)
    Invoke-NSFileMapTick $offNs $off '1. Quiet.'
    Expect-True ([IO.File]::ReadAllText($offReceipt) -ceq "# 1. Quiet.`n`nDone.`n") 'the receipt is untouched'
    Expect-True (-not (Test-Path -LiteralPath (Join-Path $offNs 'receipts/shift-map.md'))) 'no shift map'

    # A map that cannot be built says why.
    $late = Join-Path $root 'late'
    $lateNs = New-Project $late "## Items`n- [ ] **1. Late.** <!-- id: aa11 -->`n" 'on'
    $lateReceipt = Join-Path $lateNs 'receipts/01-late-aa11.md'
    [IO.File]::WriteAllText($lateReceipt, "# 1. Late.`n`nDone.`n", $utf8)
    Invoke-NSFileMapTick $lateNs $late '1. Late.'
    Expect-True ((Get-Block $lateReceipt).Contains("unavailable $dash no starting commit was recorded when the shift started")) 'an unrecorded start is named'
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures.Count -gt 0) {
    Write-Host "receipt-file-map-logic failed ($($failures.Count)):"
    foreach ($failure in $failures) { Write-Host " - $failure" }
    exit 1
}
Write-Host 'receipt-file-map-logic passed'
exit 0
