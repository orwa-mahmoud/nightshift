<#
.SYNOPSIS
  Choose which raw evidence of a filed shift the team's history shares. Mirrors
  runtime/promote-evidence.sh.

.DESCRIPTION
    promote-evidence.ps1 -Project DIR -Folder NAME [-Select FILE,...] [-All | -None] [-Apply]

  A filed shift keeps each receipt's raw evidence in a folder beside the receipt, which Git ignores.
  This lists those files and the ones the project's preference, sharing.evidence in rules.json, would
  promote: none (the default), all, or select (the owner picks). -Select, -All and -None set this
  filing's choice without changing the preference. With -Apply, each chosen file is copied into the
  folder's evidence/, where Git sees it, and the filed receipts link to that copy by relative path; a
  file left private keeps its original and its link becomes a label that names it as private
  evidence. Applying the same choice again leaves one copy and changes nothing else. Only regular
  files inside the folder's own evidence folders are eligible: a link is never followed.

  Prints one verdict per line: ok, eligible, promote, or refuse followed by its repair.
  Exit: 0 previewed or applied - 1 refused - 2 usage
#>
param(
    [string]$Project = [Environment]::CurrentDirectory,
    [string]$Folder = '',
    [string[]]$Select = @(),
    [switch]$All,
    [switch]$None,
    [switch]$Apply
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if (Test-Path Variable:PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $false
}

$pluginRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).ProviderPath
Import-Module (Join-Path $pluginRoot 'lib/Nightshift.psm1') -Force -DisableNameChecking
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
$utf8 = New-Object Text.UTF8Encoding($false)

function Write-Verdict { param([string]$Kind, [string]$Text) [Console]::Out.Write($Kind + ' ' + $Text + "`n") }
function Stop-Refused {
    param([string]$Text, [string]$Repair = '')
    Write-Verdict 'refuse' $Text
    if ($Repair.Length -gt 0) { Write-Verdict 'repair' $Repair }
    exit 1
}

if ($Folder.Length -eq 0 -or $Folder.StartsWith('.') -or $Folder.Contains('/') -or $Folder.Contains('\')) {
    [Console]::Error.WriteLine('promote-evidence: -Folder names one filed shift folder'); exit 2
}

try { $workspace = Resolve-NSWorkspaceRoot $Project }
catch { Stop-Refused "workspace no workspace at $Project" 'run Setup in the project first' }
$root = Get-NSArchiveRoot $workspace
if ($null -eq $root) { Stop-Refused 'archive the archive root cannot be resolved' 'run ns doctor' }
$dir = Join-Path $root $Folder
if (-not (Test-Path -LiteralPath $dir -PathType Container) -or (Test-NSReparsePoint $dir)) {
    Stop-Refused ("folder no filed shift folder $Folder under " + (Split-Path -Leaf $root)) 'name a folder Archive printed'
}
# The folders of filed receipts, named from the filed shift's folder: receipts for a shift filed from a
# site that keeps one shift, runs/<run>/receipts for one filed from a run folder.
$receiptDirs = New-Object Collections.Generic.List[string]
if ((Test-Path -LiteralPath (Join-Path $dir 'receipts') -PathType Container) -and -not (Test-NSReparsePoint (Join-Path $dir 'receipts'))) { $receiptDirs.Add('receipts') }
$runsDir = Join-Path $dir 'runs'
if ((Test-Path -LiteralPath $runsDir -PathType Container) -and -not (Test-NSReparsePoint $runsDir)) {
    foreach ($runDir in @(Get-ChildItem -LiteralPath $runsDir -Directory -Force | Sort-Object Name)) {
        $candidate = Join-Path $runDir.FullName 'receipts'
        if ((Test-NSReparsePoint $runDir.FullName) -or -not (Test-Path -LiteralPath $candidate -PathType Container) -or (Test-NSReparsePoint $candidate)) { continue }
        $receiptDirs.Add('runs/' + $runDir.Name + '/receipts')
    }
}

$preference = ''
$rules = Get-NSRulesObject $workspace
if ($null -ne $rules) {
    $block = $rules.PSObject.Properties['sharing']
    if ($null -ne $block -and $block.Value -is [pscustomobject]) {
        $field = $block.Value.PSObject.Properties['evidence']
        if ($null -ne $field) { $preference = [string]$field.Value }
    }
}
if ($preference.Length -eq 0) { $preference = 'none' }
if (@('none', 'select', 'all') -cnotcontains $preference) { Stop-Refused "preference sharing.evidence is $preference" 'use none, select or all' }
$choice = $(if ($Select.Count -gt 0) { 'select' } elseif ($All) { 'all' } elseif ($None) { 'none' } elseif ($preference -ceq 'all') { 'all' } else { 'none' })

# Get-Eligible - each raw evidence file of the filed receipts, named from the filed shift's folder as
# <receipts folder>/<receipt>/<path>: a regular file in a folder named after a filed receipt, reached
# without passing through a link.
function Get-Eligible {
    $out = New-Object Collections.Generic.List[string]
    foreach ($rd in $receiptDirs) {
        $receipts = Join-Path $dir $rd
        foreach ($sub in @(Get-ChildItem -LiteralPath $receipts -Directory -Force)) {
            if ((Test-NSReparsePoint $sub.FullName) -or $sub.Name.StartsWith('.')) { continue }
            if (-not [IO.File]::Exists((Join-Path $receipts ($sub.Name + '.md')))) { continue }
            $stack = New-Object Collections.Generic.Stack[string]
            $stack.Push($sub.FullName)
            while ($stack.Count -gt 0) {
                $current = $stack.Pop()
                foreach ($entry in @(Get-ChildItem -LiteralPath $current -Force)) {
                    if ($entry.Name.StartsWith('.') -or (Test-NSReparsePoint $entry.FullName)) { continue }
                    if ($entry.PSIsContainer) { $stack.Push($entry.FullName); continue }
                    $rel = $entry.FullName.Substring($sub.FullName.Length).TrimStart('\', '/').Replace('\', '/')
                    $out.Add($rd + '/' + $sub.Name + '/' + $rel)
                }
            }
        }
    }
    [string[]]$sorted = $out.ToArray()
    [Array]::Sort($sorted, [StringComparer]::Ordinal)
    return , $sorted
}

$eligible = Get-Eligible
$chosen = @()
switch ($choice) {
    'all' { $chosen = $eligible }
    'none' { $chosen = @() }
    'select' {
        foreach ($f in $Select) {
            if ($eligible -cnotcontains $f) { Stop-Refused "select $f is not raw evidence of $Folder" 'choose from the eligible files this prints without --select' }
        }
        [string[]]$chosen = @($Select | Select-Object -Unique)
        [Array]::Sort($chosen, [StringComparer]::Ordinal)
    }
}

Write-Verdict 'ok' "preference $preference"
foreach ($f in $eligible) { Write-Verdict 'eligible' $f }
foreach ($f in $chosen) { Write-Verdict 'promote' $f }
if ($eligible.Count -eq 0) {
    Write-Verdict 'ok' "nothing to promote: $Folder keeps no raw evidence"
    exit 0
}
if (-not $Apply) {
    [Console]::Out.Write("next run this again with --apply, and --select, --all or --none to change the choice`n")
    exit 0
}

# ---------------------------------------------------------------- copy the chosen files
# Each chosen file's copy sits in evidence/ beside the receipts folder it came from.
foreach ($f in $chosen) {
    $rd = $(if ($f.StartsWith('receipts/', [StringComparison]::Ordinal)) { 'receipts' } else { $f.Substring(0, $f.IndexOf('/receipts/') + 9) })
    $from = Join-Path $dir $f
    $to = Join-Path $dir ($rd.Substring(0, $rd.Length - 8) + 'evidence/' + $f.Substring($rd.Length + 1))
    try {
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $to) -Force
        $same = [IO.File]::Exists($to) -and ([Linq.Enumerable]::SequenceEqual([IO.File]::ReadAllBytes($from), [IO.File]::ReadAllBytes($to)))
        if (-not $same) { [IO.File]::Copy($from, $to, $true) }
    }
    catch { Stop-Refused "copy could not copy $f" 'check that .nightshift/ is writable' }
}

# Update-NSEvidenceLinks <line> <base> - every link into the evidence folder of receipt <base>: a
# promoted file links to its shared copy; any other becomes a label, so the shared page carries no
# link that resolves only on one machine. Mirrors the relink step in runtime/promote-evidence.sh.
function Update-NSEvidenceLinks {
    param([string]$Line, [string]$Base)
    $out = New-Object Text.StringBuilder
    while ($true) {
        $i = $Line.IndexOf('](', [StringComparison]::Ordinal)
        if ($i -lt 0) { break }
        $close = $Line.IndexOf(')', $i + 2, [StringComparison]::Ordinal)
        if ($close -lt 0) { break }
        $target = $Line.Substring($i + 2, $close - $i - 2)
        $p = $(if ($target.StartsWith('./', [StringComparison]::Ordinal)) { $target.Substring(2) } else { $target })
        $open = $(if ($i -gt 0) { $Line.LastIndexOf('[', $i - 1, [StringComparison]::Ordinal) } else { -1 })
        if (-not $p.StartsWith($Base + '/', [StringComparison]::Ordinal) -or $open -lt 0) {
            $null = $out.Append($Line.Substring(0, $close + 1))
            $Line = $Line.Substring($close + 1)
            continue
        }
        $text = $Line.Substring($open + 1, $i - $open - 1)
        $bang = ($open -gt 0 -and $Line[$open - 1] -eq '!')
        $null = $out.Append($Line.Substring(0, $open - $(if ($bang) { 1 } else { 0 })))
        if ($script:localChosen -ccontains $p) { $null = $out.Append($(if ($bang) { '!' } else { '' }) + '[' + $text + '](../evidence/' + $p + ')') }
        else { $null = $out.Append($text + ' (private evidence: ' + $p + ')') }
        $Line = $Line.Substring($close + 1)
    }
    return ($out.ToString() + $Line)
}

# ---------------------------------------------------------------- relink the filed receipts
foreach ($rd in $receiptDirs) {
    # The files chosen from this receipts folder, named from it, as the links name them.
    $script:localChosen = @($chosen | Where-Object { $_.StartsWith($rd + '/', [StringComparison]::Ordinal) } | ForEach-Object { $_.Substring($rd.Length + 1) })
    foreach ($receipt in @(Get-ChildItem -LiteralPath (Join-Path $dir $rd) -Filter '*.md' -File -Force)) {
        if (Test-NSReparsePoint $receipt.FullName) { continue }
        $base = [IO.Path]::GetFileNameWithoutExtension($receipt.Name)
        $text = [IO.File]::ReadAllText($receipt.FullName)
        $trailing = $text.EndsWith("`n")
        $lines = $text.Replace("`r`n", "`n").Split("`n")
        if ($trailing) { $lines = $lines[0..($lines.Count - 2)] }
        $result = New-Object Collections.Generic.List[string]
        foreach ($line in $lines) { $result.Add((Update-NSEvidenceLinks $line $base)) }
        try { [IO.File]::WriteAllText($receipt.FullName, (($result.ToArray() -join "`n") + $(if ($trailing) { "`n" } else { '' })), $utf8) }
        catch { Stop-Refused ('relink could not rewrite ' + $receipt.Name) 'check that .nightshift/ is writable' }
    }
}
Write-Verdict 'ok' ("promoted " + $chosen.Count + " of " + $eligible.Count + " evidence files of $Folder; the rest stay private")
exit 0
