<#
.SYNOPSIS
  Let Git see the project records the team shares, and nothing private. Mirrors runtime/share.sh.

.DESCRIPTION
    share.ps1 -Project DIR [-Apply]

  sharing.records in rules.json names the records a team shares through Git: plans, decisions, rules,
  receipts and summaries. This prints the block of .nightshift/.gitignore that matches it: everything
  under .nightshift/ is ignored, then each shared record is let back in, while raw evidence folders,
  private messages, the runtime's own folders, STOP, leases and locks stay ignored. With -Apply it
  writes that block, keeping every line outside it, and removes it again when sharing.records is
  empty. It never stages, commits or pushes; when to do that is the team's.

  When the repository above ignores .nightshift/ through the one line Setup writes, -Apply takes that
  line out; any other pattern is named for the owner to change. Files Git already tracks that are now
  private are named with the command that untracks them.

  Prints one verdict per line: ok, warn or refuse, each refusal followed by its repair.
  Exit: 0 written or previewed - 1 refused - 2 usage
#>
param(
    [string]$Project = [Environment]::CurrentDirectory,
    [switch]$Apply
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if (Test-Path Variable:PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $false
}

$pluginRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).ProviderPath
Import-Module (Join-Path $pluginRoot 'lib/Nightshift.psm1') -Force -DisableNameChecking
$utf8 = New-Object Text.UTF8Encoding($false)

function Write-Verdict { param([string]$Kind, [string]$Text) [Console]::Out.Write($Kind + ' ' + $Text + "`n") }
function Stop-Refused {
    param([string]$Text, [string]$Repair = '')
    Write-Verdict 'refuse' $Text
    if ($Repair.Length -gt 0) { Write-Verdict 'repair' $Repair }
    exit 1
}

try { $workspace = Resolve-NSWorkspaceRoot $Project }
catch { Stop-Refused "workspace no workspace at $Project" 'run Setup in the project first' }
$ns = Join-Path $workspace '.nightshift'
if (-not (Test-Path -LiteralPath $ns -PathType Container) -or (Test-NSReparsePoint $ns)) {
    Stop-Refused "workspace no .nightshift/ at $workspace" 'run Setup in the project first'
}

$unknown = Get-NSShareUnknown $workspace
if ($unknown.Count -gt 0) {
    Stop-Refused ('records sharing.records names ' + ($unknown -join ' ') + ', which is no record') `
        ('use only ' + ((Get-NSShareRecordNames) -join ', ') + ' in sharing.records')
}
$records = Get-NSSharedRecords $workspace
$ignore = Join-Path $ns '.gitignore'
$begin = Get-NSShareMarker
$end = Get-NSShareMarker -End

if ($records.Count -gt 0) {
    if (-not (Test-NSLayoutPerRun $ns 'punch-list')) {
        Stop-Refused "layout this workspace keeps one shift at a time, so teammates' runs would share its files" `
            'preview the move to run folders with ns migrate-state, make it with -Apply, then run this again'
    }
    if (Test-Path -LiteralPath (Join-Path $ns '.git')) {
        Stop-Refused "receipts-repo .nightshift/ is a Git repository of its own, so the project's Git cannot see into it" `
            'move .nightshift/.git out of .nightshift/ to stop keeping the receipts repo, then run this again'
    }
    Write-Verdict 'ok' ('records ' + ($records -join ' '))
}
else {
    Write-Verdict 'ok' 'records none: the site stays private to its runner'
}

# Split-NSShareFile <path> - the block as it stands in the file, and every line outside it.
function Split-NSShareFile {
    param([string]$Path)
    $fileLines = @()
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $fileLines = @(([IO.File]::ReadAllText($Path) -replace "`r", '').Split("`n"))
        if ($fileLines.Count -gt 0 -and $fileLines[$fileLines.Count - 1] -ceq '') {
            $fileLines = @($fileLines[0..($fileLines.Count - 2)])
        }
    }
    $current = New-Object Collections.Generic.List[string]
    $outside = New-Object Collections.Generic.List[string]
    $on = $false
    foreach ($line in $fileLines) {
        if ($line -ceq $begin) { $on = $true }
        if ($on) { $current.Add($line) } else { $outside.Add($line) }
        if ($line -ceq $end) { $on = $false }
    }
    return [pscustomobject]@{ Block = $current.ToArray(); Outside = $outside.ToArray() }
}

# Show-NSSharePreview <path> <block> <label> - what -Apply would do to the file.
function Show-NSSharePreview {
    param([string]$Path, [string[]]$Block, [string]$Label)
    $name = '.nightshift/' + (Split-Path -Leaf $Path)
    $parts = Split-NSShareFile $Path
    if (($parts.Block -join "`n") -ceq ($Block -join "`n")) { Write-Verdict 'ok' "$Label $name already matches"; return $false }
    if ($Block.Count -gt 0) {
        Write-Verdict 'ok' "$Label would write this block to ${name}:"
        foreach ($line in $Block) { [Console]::Out.Write('  ' + $line + "`n") }
    }
    else { Write-Verdict 'ok' "$Label would take the sharing block out of $name" }
    return $true
}

# Write-NSShareBlock <path> <block> <label> - the block first, every other line of the file after it;
# the file goes when nothing is left.
function Write-NSShareBlock {
    param([string]$Path, [string[]]$Block, [string]$Label)
    $name = '.nightshift/' + (Split-Path -Leaf $Path)
    $newLines = @($Block) + @((Split-NSShareFile $Path).Outside)
    try {
        if ($newLines.Count -eq 0) {
            if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force }
        }
        else {
            [IO.File]::WriteAllText($Path, (($newLines -join "`n") + "`n"), $utf8)
        }
    }
    catch {
        Stop-Refused "$Label could not write $Path" 'check that .nightshift/ is writable, then run this again'
    }
    if ($Block.Count -gt 0) { Write-Verdict 'ok' "$Label wrote the sharing block to $name" }
    else { Write-Verdict 'ok' "$Label took the sharing block out of $name" }
}

$attributes = Join-Path $ns '.gitattributes'
$block = @()
$attributesBlock = @()
if ($records.Count -gt 0) {
    $block = Get-NSShareIgnoreBlock $workspace
    $attributesBlock = Get-NSShareAttributesBlock $workspace
}

if (-not $Apply) {
    $changes = Show-NSSharePreview $ignore $block 'gitignore'
    $changes = (Show-NSSharePreview $attributes $attributesBlock 'gitattributes') -or $changes
    if ($changes) { [Console]::Out.Write("next run ns share --apply to write it`n") }
    exit 0
}

# ---------------------------------------------------------------- write the blocks
Write-NSShareBlock $ignore $block 'gitignore'
Write-NSShareBlock $attributes $attributesBlock 'gitattributes'
if ($block.Count -eq 0) { exit 0 }

# ---------------------------------------------------------------- the repository above
$top = [string](& git -C $ns rev-parse --show-toplevel 2>$null)
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrEmpty($top)) {
    Write-Verdict 'warn' 'repository .nightshift/ is in no Git repository, so nothing is shared until one holds it'
    exit 0
}
$top = (Resolve-Path -LiteralPath $top).ProviderPath
Write-Verdict 'ok' "repository $top"
# Where the site sits in the repository, as Git names it.
$siteRel = ([string](& git -C $ns rev-parse --show-prefix 2>$null)).TrimEnd('/')
$rel = $siteRel + '/state-version'
$hit = [string](& git -C $top check-ignore -v -- $rel 2>$null)
if ($LASTEXITCODE -eq 0 -and $hit.Length -gt 0) {
    # source:line:pattern<TAB>path
    $tab = $hit.IndexOf("`t")
    $head = $(if ($tab -ge 0) { $hit.Substring(0, $tab) } else { $hit })
    $m = [regex]::Match($head, '^(.*):([0-9]+):(.*)$')
    $source = $m.Groups[1].Value
    $lineNumber = [int]$m.Groups[2].Value
    $pattern = $m.Groups[3].Value
    $sourceFile = $(if ([IO.Path]::IsPathRooted($source)) { $source } else { Join-Path $top $source })
    $ours = @(($siteRel + '/'), ('/' + $siteRel + '/'), $siteRel, ('/' + $siteRel)) -ccontains $pattern
    $setupFile = ([IO.Path]::GetFullPath($sourceFile) -ceq [IO.Path]::GetFullPath((Join-Path $top '.gitignore'))) -or
        ([IO.Path]::GetFullPath($sourceFile) -ceq [IO.Path]::GetFullPath((Join-Path $workspace '.gitignore')))
    if ($ours -and $setupFile) {
        try {
            $lines = @(([IO.File]::ReadAllText($sourceFile) -replace "`r", '').Split("`n"))
            $kept = New-Object Collections.Generic.List[string]
            for ($i = 0; $i -lt $lines.Count; $i++) { if ($i -ne $lineNumber - 1) { $kept.Add($lines[$i]) } }
            [IO.File]::WriteAllText($sourceFile, ($kept.ToArray() -join "`n"), $utf8)
        }
        catch {
            Stop-Refused "repository could not edit $sourceFile" "take the line $pattern out of $sourceFile by hand"
        }
        Write-Verdict 'ok' "repository took the line $pattern out of $sourceFile so Git can see the shared records"
    }
    elseif ($ours) {
        Stop-Refused "repository $source line $lineNumber ($pattern) hides .nightshift/ from Git" 'take that line out, then run this again'
    }
    else {
        Stop-Refused "repository $source line $lineNumber ($pattern) hides .nightshift/ from Git" 'change that pattern so it no longer covers .nightshift/, then run this again'
    }
}

# Files Git tracks that the block now keeps private.
foreach ($file in @(& git -C $ns ls-files -ci --exclude-standard -- . 2>$null)) {
    if ([string]::IsNullOrEmpty([string]$file)) { continue }
    Write-Verdict 'warn' "tracked-private Git still tracks $file, which stays private"
    Write-Verdict 'repair' "git -C $ns rm --cached -- $file"
}
Write-Verdict 'ok' 'next stage and commit .nightshift/ when the team chooses; nothing was staged'
exit 0
