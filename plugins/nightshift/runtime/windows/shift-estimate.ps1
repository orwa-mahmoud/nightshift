param(
    [string]$Project = '',
    [string]$Items = ''
)

# shift-estimate.ps1  -  size a shift from the owner's own history: the Time and Tokens totals of
# every ticked item's receipt, live and archived. Mirrors shift-estimate.sh, line for line.
#   shift-estimate.ps1 -Project DIR [-Items N]
# Every figure is an estimate from past receipts, never a limit. Read-only.

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if (Test-Path Variable:PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $false
}

if ([string]::IsNullOrWhiteSpace($Project)) {
    [Console]::Error.WriteLine('shift-estimate: -Project is required')
    exit 1
}
if ($Items.Length -gt 0 -and $Items -cnotmatch '^[1-9][0-9]{0,2}$') {
    [Console]::Error.WriteLine('shift-estimate: -Items takes a whole number from 1 to 999')
    exit 1
}

$pluginRoot = Resolve-Path (Join-Path $PSScriptRoot '../..')
Import-Module (Join-Path $pluginRoot 'lib/Nightshift.psm1') -Force -DisableNameChecking
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)

try { $workspace = Resolve-NSWorkspaceRoot $Project }
catch {
    [Console]::Error.WriteLine("shift-estimate: no workspace at $Project")
    exit 1
}
$ns = Join-Path $workspace '.nightshift'
if (-not (Test-Path -LiteralPath $ns -PathType Container) -or (Test-NSReparsePoint $ns)) {
    [Console]::Error.WriteLine("shift-estimate: no .nightshift/ at $workspace")
    exit 1
}

# The fewest readings an estimate is made from.
$minimum = 3
$dot = [string][char]0x00B7
$dash = [string][char]0x2014

$files = New-Object Collections.Generic.List[object]
$receipts = Get-NSLayoutPath $ns 'receipts'
foreach ($name in (Get-NSTickedReceiptNames $workspace)) {
    $path = Join-Path $receipts $name
    if ((Test-Path -LiteralPath $path -PathType Leaf) -and -not (Test-NSReparsePoint $path)) { $files.Add(@('live', $path)) }
}
$archive = Get-NSLayoutPath $ns 'archive'
if ((Test-Path -LiteralPath $archive -PathType Container) -and -not (Test-NSReparsePoint $archive)) {
    $found = @(Get-ChildItem -LiteralPath $archive -Recurse -File -Filter '*.md' -ErrorAction SilentlyContinue | Where-Object {
            $_.Directory.Name -ceq 'receipts' -and $_.Name -cne 'README.md' -and $_.Name -cne 'previous-report.md' -and
            -not $_.Name.StartsWith('morning-', [StringComparison]::Ordinal) -and -not $_.Name.StartsWith('x-', [StringComparison]::Ordinal) -and
            -not $_.Name.EndsWith('.original.md', [StringComparison]::Ordinal)
        } | ForEach-Object { $_.FullName })
    $sorted = [string[]]$found
    [Array]::Sort($sorted, [StringComparer]::Ordinal)
    foreach ($path in $sorted) { $files.Add(@('archived', $path)) }
}

$live = 0
$archived = 0
$times = New-Object Collections.Generic.List[long]
$tokens = New-Object Collections.Generic.List[long]
foreach ($pair in $files) {
    $cells = Get-NSReceiptUsageCells $pair[1]
    if ($cells.Time -cne $dash -and [long]$cells.Work -gt 0) { $times.Add([long]$cells.Work) }
    if ($cells.Tokens -cne $dash -and $cells.Tokens -cne 'off') { $tokens.Add([long]$cells.In + [long]$cells.Out) }
    if ($pair[0] -ceq 'live') { $live++ } else { $archived++ }
}
$total = $live + $archived
if ($total -eq 0) {
    [Console]::Out.Write("estimate none: no ticked item has a receipt yet`n")
    exit 0
}
[Console]::Out.Write("estimate from $total ticked items: $live live, $archived archived`n")

function Get-Stats {
    param([Collections.Generic.List[long]]$Values)
    $v = $Values.ToArray()
    [Array]::Sort($v)
    $n = $v.Length
    if ($n -eq 0) { return @{ N = 0 } }
    if ($n % 2) { $median = $v[($n - 1) / 2] }
    else { $median = [long][math]::Floor(($v[$n / 2 - 1] + $v[$n / 2]) / 2) }
    return @{ N = $n; Median = [long]$median; Min = [long]$v[0]; Max = [long]$v[$n - 1] }
}

# Whole minutes up, as the Budget: syntax writes them: `45m`, `1h 30m`.
function Format-CeilMinutes {
    param([long]$Seconds)
    $m = [long][math]::Floor(($Seconds + 59) / 60)
    if ($m -lt 1) { $m = 1 }
    if ($m -ge 60) {
        if ($m % 60 -eq 0) { return ('{0}h' -f [long][math]::Floor($m / 60)) }
        return ('{0}h {1}m' -f [long][math]::Floor($m / 60), ($m % 60))
    }
    return ('{0}m' -f $m)
}

# Tokens up to one decimal in the unit the Budget: syntax reads: `800k`, `1.3M`.
function Format-CeilTokens {
    param([long]$Count)
    if ($Count -lt 1000000) {
        $k = [long][math]::Floor(($Count + 999) / 1000)
        if ($k -lt 1) { $k = 1 }
        return ('{0}k' -f $k)
    }
    $t = [long][math]::Floor(($Count + 99999) / 100000)
    if ($t % 10) { return ('{0}.{1}M' -f [long][math]::Floor($t / 10), ($t % 10)) }
    return ('{0}M' -f ($t / 10))
}

function Format-Missing {
    param([int]$Count)
    if ($Count -eq 0) { return '' }
    return (", $Count without a reading")
}

$t = Get-Stats $times
$k = Get-Stats $tokens
$tMissing = $total - $t.N
$kMissing = $total - $k.N
if ($t.N -ge $minimum) {
    [Console]::Out.Write(('time per item: median {0} {5} range {1} to {2} {5} from {3} items{4}' -f (Get-NSUsageDuration ([string]$t.Median)),
            (Get-NSUsageDuration ([string]$t.Min)), (Get-NSUsageDuration ([string]$t.Max)), $t.N, (Format-Missing $tMissing), $dot) + "`n")
}
else {
    [Console]::Out.Write(('time per item: too few readings ({0} of at least {1}){2}' -f $t.N, $minimum, (Format-Missing $tMissing)) + "`n")
}
if ($k.N -ge $minimum) {
    [Console]::Out.Write(('tokens per item: median {0} {5} range {1} to {2} {5} from {3} items{4}' -f (Get-NSUsageScale $k.Median),
            (Get-NSUsageScale $k.Min), (Get-NSUsageScale $k.Max), $k.N, (Format-Missing $kMissing), $dot) + "`n")
}
else {
    [Console]::Out.Write(('tokens per item: too few readings ({0} of at least {1}){2}' -f $k.N, $minimum, (Format-Missing $kMissing)) + "`n")
}

if ($Items.Length -eq 0) { exit 0 }
$count = [long]$Items
$timeOk = $t.N -ge $minimum
$tokensOk = $k.N -ge $minimum
if (-not $timeOk -and -not $tokensOk) {
    [Console]::Out.Write("for $count items: no estimate`n")
    exit 0
}
$line = "for $count items:"
if ($timeOk) { $line += ' time ' + (Get-NSUsageDuration ([string]($t.Median * $count))) + ' to ' + (Get-NSUsageDuration ([string]($t.Max * $count))) }
if ($timeOk -and $tokensOk) { $line += " $dot" }
if ($tokensOk) { $line += ' tokens ' + (Get-NSUsageScale ($k.Median * $count)) + ' to ' + (Get-NSUsageScale ($k.Max * $count)) }
[Console]::Out.Write($line + "`n")
# The deadline leaves a quarter over the median total for the items that run long.
if ($timeOk) {
    [Console]::Out.Write('suggested deadline: ' + (Format-CeilMinutes ([long][math]::Floor($t.Median * $count * 5 / 4))) + " from the start`n")
}
$soft = ''
$hard = ''
if ($timeOk) {
    $soft = Format-CeilMinutes $t.Median
    $hard = Format-CeilMinutes $t.Max
}
if ($tokensOk) {
    $soft = $(if ($soft.Length -gt 0) { "$soft / " } else { '' }) + (Format-CeilTokens $k.Median) + ' tokens'
    $hard = $(if ($hard.Length -gt 0) { "$hard / " } else { '' }) + (Format-CeilTokens $k.Max) + ' tokens'
}
[Console]::Out.Write("suggested budget: soft $soft, hard $hard`n")
exit 0
