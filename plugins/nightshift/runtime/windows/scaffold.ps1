<#
.SYNOPSIS
  Copy the state templates into the workspace, never over an existing file.

.DESCRIPTION
  Mirrors runtime/scaffold.sh. Copying a file does not require its text, so the
  model reads none of the nine templates.

  Never clobbers. A name already in `.nightshift/` is the owner's, whatever it
  now contains, so it is reported `kept` and left exactly as it is. Running this
  twice is safe, which is what makes it usable as a repair.

  The copy resolves `$NIGHTSHIFT_WORKSPACE` and `$NS` to the paths this workspace
  actually has, because the owner reads their copy and a person cannot paste a
  shell variable they do not have. The shipped template is never changed.

  Prints one line per template: `wrote <name>` or `kept <name>`.
  Exit: 0 done - 1 usage - 2 refused
#>
param(
    [string]$Project = [Environment]::CurrentDirectory,
    [switch]$List
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$pluginRoot = Resolve-Path (Join-Path $PSScriptRoot '../..')
Import-Module (Join-Path $pluginRoot 'lib/Nightshift.psm1') -Force -DisableNameChecking

$utf8 = New-Object Text.UTF8Encoding($false)
[Console]::OutputEncoding = $utf8

$templates = Join-Path $pluginRoot 'skills/nightshift/references/templates'
if (-not (Test-Path -LiteralPath $templates -PathType Container)) {
    [Console]::Error.WriteLine('scaffold: no templates at ' + $templates)
    exit 2
}

$files = @(Get-ChildItem -LiteralPath $templates -Filter '*.md' -File | Sort-Object Name)

if ($List) {
    foreach ($file in $files) { [Console]::Out.WriteLine($file.Name) }
    exit 0
}

$workspace = Resolve-NSWorkspaceRoot $Project
if ([string]::IsNullOrEmpty($workspace)) {
    [Console]::Error.WriteLine('scaffold: invalid .nightshift-link - Nightshift will not guess a workspace')
    exit 2
}
$ns = Join-Path $workspace '.nightshift'
if (-not (Test-Path -LiteralPath $ns -PathType Container)) {
    $null = New-Item -ItemType Directory -Path $ns -Force
}

foreach ($file in $files) {
    $dest = Join-Path $ns $file.Name
    # A name that is already taken is the owner's, whatever it holds and whatever kind of file it is.
    if (Test-Path -LiteralPath $dest) {
        [Console]::Out.WriteLine('kept ' + $file.Name)
        continue
    }
    try {
        # The owner's copy carries resolved paths: a person pasting a command out of their own
        # punch list has no `$NS`. The shipped template is never changed.
        $text = [IO.File]::ReadAllText($file.FullName, $utf8)
        $text = $text.Replace('$NIGHTSHIFT_WORKSPACE', $workspace).Replace('$NS', $ns)
        [IO.File]::WriteAllText($dest, $text, $utf8)
        [Console]::Out.WriteLine('wrote ' + $file.Name)
    }
    catch {
        [Console]::Error.WriteLine('scaffold: cannot write ' + $dest)
        exit 2
    }
}
exit 0
