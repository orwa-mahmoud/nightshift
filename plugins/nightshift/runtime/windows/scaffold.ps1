<#
.SYNOPSIS
  Copy the state templates into the workspace, never over an existing file.

.DESCRIPTION
  Mirrors runtime/scaffold.sh.

    scaffold.ps1 [-Project DIR] [-List] [<file>...]

  With no file named it writes what every shift uses: the punch list, the parking
  lot, the snag log, the drafting table, and the shift log's header. The rest waits
  until something needs it: `work-orders` when Hunt stages an order, `product`
  (the opportunity map and the research notes) when a product-evolution item is
  cut. Each file lands where the workspace's layout keeps it, and a `.nightshift/`
  this run creates gets the current state-version first.

  Copying a file does not require its text, so the model reads none of the
  templates. Never clobbers. A name already in `.nightshift/` is the owner's,
  whatever it now contains, so it is reported `kept` and left exactly as it is.
  Running this twice is safe, which is what makes it usable as a repair.

  The copy resolves `$NIGHTSHIFT_WORKSPACE` and `$NS` to the paths this workspace
  actually has, because the owner reads their copy and a person cannot paste a
  shell variable they do not have. The shipped template is never changed.

  Prints one line per file: `wrote <path>` or `kept <path>`, relative to
  `.nightshift/`.
  Exit: 0 done - 1 usage - 2 refused
#>
param(
    [string]$Project = [Environment]::CurrentDirectory,
    [switch]$List,
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)][string[]]$Names = @()
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$pluginRoot = Resolve-Path (Join-Path $PSScriptRoot '../..')
Import-Module (Join-Path $pluginRoot 'lib/Nightshift.psm1') -Force -DisableNameChecking

[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)

foreach ($name in $Names) {
    if ($name.StartsWith('-', [StringComparison]::Ordinal)) {
        [Console]::Error.WriteLine('scaffold: unknown argument: ' + $name)
        exit 1
    }
}
try {
    $keys = Get-NSScaffoldKeys $Names
}
catch {
    [Console]::Error.WriteLine('scaffold: ' + $_.Exception.Message)
    exit 1
}

$templates = Join-Path $pluginRoot 'skills/nightshift/references/templates'
if (-not (Test-Path -LiteralPath $templates -PathType Container)) {
    [Console]::Error.WriteLine('scaffold: no templates at ' + $templates)
    exit 2
}

if ($List) {
    foreach ($key in @('punch-list', 'parking-lot', 'snag-log', 'drafting-table', 'work-orders', 'opportunity-map', 'product-research')) {
        if (Test-Path -LiteralPath (Join-Path $templates ($key + '.md')) -PathType Leaf) {
            [Console]::Out.Write($key + ".md`n")
        }
    }
    exit 0
}

try {
    $workspace = Resolve-NSWorkspaceRoot $Project
}
catch {
    $workspace = ''
}
if ([string]::IsNullOrEmpty($workspace)) {
    [Console]::Error.WriteLine('scaffold: invalid .nightshift-link - Nightshift will not guess a workspace')
    exit 2
}

try {
    foreach ($line in (Invoke-NSScaffold -Workspace $workspace -Keys $keys)) {
        [Console]::Out.Write($line + "`n")
    }
}
catch {
    [Console]::Error.WriteLine('scaffold: ' + $_.Exception.Message)
    exit 2
}
exit 0
