<#
.SYNOPSIS
  Send a running shift a question or an answer. Mirrors runtime/send-message.sh.

.DESCRIPTION
    send-message.ps1 -Project DIR [-Run NAME] [-Text TEXT]

  Appends the message under an `## Owner` heading with the local time in the run's inbox/messages.md.
  The run's worker is shown it at its next tool call and appends its reply under a `## Worker` heading with the time
  in the same file, where the sender reads it. Without -Text the message is read from stdin, so
  multiline text reaches the file exactly as written. In a workspace that keeps runs, the run is the
  one named with -Run, by NIGHTSHIFT_RUN, or the only one.

  Prints the messages file. Exit: 0 sent - 1 usage or refused
#>
param(
    [string]$Project = [Environment]::CurrentDirectory,
    [string]$Run = '',
    [AllowNull()][string]$Text = $null
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$pluginRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).ProviderPath
Import-Module (Join-Path $pluginRoot 'lib/Nightshift.psm1') -Force -DisableNameChecking
[Console]::InputEncoding = New-Object Text.UTF8Encoding($false)

if ($null -eq $Text -or -not $PSBoundParameters.ContainsKey('Text')) {
    $Text = [Console]::In.ReadToEnd()
    if ($Text.EndsWith("`n")) { $Text = $Text.Substring(0, $Text.Length - 1) }
    if ($Text.EndsWith("`r")) { $Text = $Text.Substring(0, $Text.Length - 1) }
}
if ([string]::IsNullOrWhiteSpace($Text)) { [Console]::Error.WriteLine('send-message: the message is empty'); exit 1 }

try { $workspace = Resolve-NSWorkspaceRoot $Project }
catch { [Console]::Error.WriteLine("send-message: no workspace at $Project"); exit 1 }
$ns = Join-Path $workspace '.nightshift'
if (-not (Test-Path -LiteralPath $ns -PathType Container) -or (Test-NSReparsePoint $ns)) {
    [Console]::Error.WriteLine("send-message: no .nightshift/ at $workspace"); exit 1
}
$choice = Select-NSRunChoice $ns $Run
if ($choice.Code -ne 0) { [Console]::Error.WriteLine('send-message: ' + $choice.Error); exit 1 }
try { Add-NSMessage -NightshiftDir $ns -Author Owner -Text $Text }
catch { [Console]::Error.WriteLine($_.Exception.Message); exit 1 }
[Console]::Out.Write((Get-NSLayoutPath $ns 'messages') + "`n")
exit 0
