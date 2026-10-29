param(
    [string]$Project = [Environment]::CurrentDirectory,
    [string]$Report = '',
    [string]$Manifest = '',
    [string[]]$Output = @(),
    [switch]$Diagrams
)

# check-receipts.ps1 - with -Diagrams, a report on the receipts of ticked items: while
# receipts.evidence.architecture is on, each one with no `Diagram:` line. Report only. Without
# -Diagrams it is check-report, kept under this name so existing invocations keep working.
# Mirrors check-receipts.sh.
if (-not $Diagrams) {
    [Console]::Error.WriteLine('ns check-report')
    & (Join-Path $PSScriptRoot 'check-report.ps1') -Project $Project -Report $Report -Manifest $Manifest -Output $Output
    exit $LASTEXITCODE
}

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$pluginRoot = Resolve-Path (Join-Path $PSScriptRoot '../..')
Import-Module (Join-Path $pluginRoot 'lib/Nightshift.psm1') -Force -DisableNameChecking
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)

try { $workspace = Resolve-NSWorkspaceRoot $Project }
catch {
    [Console]::Error.WriteLine("check-receipts: no workspace at $Project")
    exit 1
}
$ticked = 0
foreach ($row in (Get-NSItemRows (Get-NSLayoutPath (Join-Path $workspace '.nightshift') 'punch-list') 'ticked')) { $ticked++ }
$with = 0
foreach ($label in (Get-NSArchitectureMissing $workspace)) {
    [Console]::Out.Write($label + ": no Diagram: line`n")
    $with++
}
[Console]::Out.Write("checked $ticked ticked items: $with with findings`n")
exit 0
