param(
    [string]$Project = '',
    [string]$File = ''
)

# check-items.ps1  -  check the shape of drafted items before they are promoted. Mirrors
# check-items.sh, line for line: the same part of the file, the same findings, the same words.
#   check-items.ps1 -Project DIR [-File PATH]
# It checks the shape of the plan, never the work behind a tick, and refuses nothing. Read-only.

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if (Test-Path Variable:PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $false
}

if ([string]::IsNullOrWhiteSpace($Project)) {
    [Console]::Error.WriteLine('check-items: -Project is required')
    exit 1
}

$pluginRoot = Resolve-Path (Join-Path $PSScriptRoot '../..')
Import-Module (Join-Path $pluginRoot 'lib/Nightshift.psm1') -Force -DisableNameChecking
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)

if ($File.Length -eq 0) {
    try { $workspace = Resolve-NSWorkspaceRoot $Project }
    catch {
        [Console]::Error.WriteLine("check-items: no workspace at $Project")
        exit 1
    }
    $File = Get-NSLayoutPath (Join-Path $workspace '.nightshift') 'drafting-table'
}
if (-not (Test-Path -LiteralPath $File -PathType Leaf) -or (Test-NSReparsePoint $File)) {
    [Console]::Out.Write("no items to check: $File is not there`n")
    exit 0
}

$lines = @([IO.File]::ReadAllLines($File) | ForEach-Object { $_.TrimEnd("`r") })
$box = '^[ \t]*-[ \t]*\[[ \t]\]'
$itemLine = '^- \[[ xX-]\]'
$concretePattern = '`[^`]+`|WHEN .*THEN '

# Where the items are: under `## Items`, else below the first rule, else everywhere.
$mode = ''
foreach ($l in $lines) {
    if ($l -cmatch '^##[ \t]*Items[ \t]*$') { $mode = 'items'; break }
    if ($l -cmatch '^--- *$' -and $mode -eq '') { $mode = 'rule' }
}
if ($mode -eq '') { $mode = 'all' }

$events = New-Object Collections.Generic.List[object]
$state = @{ Open = $false }
function Close-Item {
    if (-not $state.Open) { return }
    if (-not $state.Verify) { $events.Add(@('find', 'no Verify: line')) }
    elseif (-not $state.Concrete) { $events.Add(@('find', 'Verify: names no command and no WHEN/THEN scenario')) }
    if (-not $state.Commit) { $events.Add(@('find', 'no Commit: line')) }
    if ($state.Budget) { $events.Add(@('budget', $state.BudgetText)) }
    foreach ($n in $state.Nested) { $events.Add(@('find', "line ${n}: a nested checkbox; only the item line may be a box")) }
    $state.Open = $false
}

$on = ($mode -eq 'all')
$fence = $false
$comment = $false
$inVerify = $false
$verifyIndent = 0
for ($i = 0; $i -lt $lines.Count; $i++) {
    $line = $lines[$i]
    $number = $i + 1
    if (-not $on) {
        if ($mode -eq 'items' -and $line -cmatch '^##[ \t]*Items[ \t]*$') { $on = $true }
        if ($mode -eq 'rule' -and $line -cmatch '^--- *$') { $on = $true }
        continue
    }
    if ($mode -eq 'items' -and $line -cmatch '^## ') { Close-Item; $on = $false; continue }

    # Fenced code and HTML comments hold no items, but a box written in them is still counted.
    if ($fence -or $line -cmatch '^[ \t]*```') {
        if (-not $fence -and $line -cmatch '^```') { Close-Item }
        if ($line -cmatch '^[ \t]*```') { $fence = -not $fence }
        if ($line -cmatch $box) { $events.Add(@('outside', [string]$number)) }
        continue
    }
    if ($comment) {
        if ($line -cmatch $box) { $events.Add(@('outside', [string]$number)) }
        if ($line.Contains('-->')) { $comment = $false }
        continue
    }
    # A comment that opens here and runs on: nothing in it is an item. One that closes on the same
    # line, such as an item id, leaves the line as it was.
    if (([regex]::Replace($line, '<!--.*-->', '')).Contains('<!--')) {
        if ($line -cnotmatch '^[ \t]') { Close-Item }
        $comment = $true
        if ($line -cmatch $box) { $events.Add(@('outside', [string]$number)) }
        continue
    }

    if ($line -cmatch $itemLine) {
        Close-Item
        $label = $line -creplace '^- \[.\][ \t]*', ''
        $label = $label -creplace '[ \t]*<!--.*-->[ \t]*$', ''
        $events.Add(@('item', $label))
        $state = @{ Open = $true; Verify = $false; Concrete = $false; Commit = $false; Budget = $false; BudgetText = ''
            Nested = (New-Object Collections.Generic.List[int]) }
        $inVerify = $false
        continue
    }

    if ($line.Trim().Length -eq 0) { $inVerify = $false; continue }

    if ($state.Open -and $line -cmatch '^[ \t]+') {
        $indent = $line.Length - $line.TrimStart(' ', "`t").Length
        if ($inVerify -and $indent -gt $verifyIndent) {
            if ($line -cmatch $concretePattern) { $state.Concrete = $true }
            continue
        }
        $inVerify = $false
        if ($line -cmatch '^[ \t]*-[ \t]*\[.\]') { $state.Nested.Add($number); continue }
        if ($line -cmatch '^[ \t]*- Verify:') {
            $state.Verify = $true
            $inVerify = $true
            $verifyIndent = $indent
            if ($line -cmatch $concretePattern) { $state.Concrete = $true }
            continue
        }
        if ($line -cmatch '^[ \t]*- (Commit|Receipt):') { $state.Commit = $true; continue }
        if ($line -cmatch '^[ \t]*- Budget:') {
            $state.Budget = $true
            $state.BudgetText = $line -creplace '^[ \t]*- Budget:[ \t]*', ''
            continue
        }
        continue
    }

    # Any other top-level line ends the item; a box written another way is one no item owns.
    Close-Item
    if ($line -cmatch $box) { $events.Add(@('outside', [string]$number)) }
}
Close-Item

$items = 0
$with = 0
$outside = 0
$label = ''
$itemFindings = 0
$out = New-Object Collections.Generic.List[string]
function Complete-Label {
    if ($script:label.Length -eq 0) { return }
    if ($script:itemFindings -eq 0) { $out.Add($script:label + ': ok') }
    else { $script:with++ }
    $script:label = ''
}
foreach ($event in $events) {
    switch -CaseSensitive ($event[0]) {
        'item' {
            Complete-Label
            $label = $event[1]
            $itemFindings = 0
            $items++
        }
        'find' {
            $out.Add($label + ': ' + $event[1])
            $itemFindings++
        }
        'budget' {
            $parsed = ConvertFrom-NSBudget $event[1]
            if ($null -eq $parsed -or [string]$parsed -eq '') {
                $out.Add($label + ': Budget: does not parse (' + $event[1] + ')')
                $itemFindings++
            }
        }
        'outside' {
            Complete-Label
            $out.Add('line ' + $event[1] + ': a checkbox outside an item line counts as an open item')
            $outside++
        }
    }
}
Complete-Label

foreach ($line in $out) { [Console]::Out.Write($line + "`n") }
if ($items -eq 0 -and $outside -eq 0) {
    [Console]::Out.Write("no items to check`n")
    exit 0
}
$summary = "checked $items items: $with with findings"
if ($outside -eq 1) { $summary += ', 1 stray checkbox' }
elseif ($outside -gt 1) { $summary += ", $outside stray checkboxes" }
[Console]::Out.Write($summary + "`n")
exit 0
