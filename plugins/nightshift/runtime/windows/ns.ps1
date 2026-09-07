<#
.SYNOPSIS
  One verb per helper. The runtime picks the file, the flags and the workspace.

.DESCRIPTION
  Twin of runtime/ns. Same verbs, same arguments in the same POSIX spelling:

    & ns.ps1 <verb> [--flag value ...]
    & ns.ps1 bind        the six resolved facts
    & ns.ps1 help        this host's verb table

  Skills carry one spelling of every command. This translates it: `--flag value`
  becomes `-Flag value`, and a flag naming a switch parameter consumes no value.
  Which parameters those are is read off the helper's own param block, so a
  helper that grows a flag needs nothing here.

  A flag with no matching parameter is passed through untouched, so the helper
  refuses in its own words. The dispatcher never invents support a helper does
  not have.

  Exit: the helper's own status, streams passed through. 1 usage - 2 refused.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)][string]$Verb,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest = @()
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$runtime = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$pluginRoot = Split-Path -Parent $runtime
Import-Module (Join-Path $pluginRoot 'lib/Nightshift.psm1') -Force -DisableNameChecking

[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)

# The verbs that change something on disk. Identical in the POSIX dispatcher.
$NSWritingVerbs = @('scaffold', 'write-receipt', 'archive-receipts', 'stop-shift', 'link-workspace',
    'evidence-archive', 'migrate-state', 'apply-profile')

# The host, from the environment the hooks already read. Never from searching.
function Get-NSDispatchHost {
    if (-not [string]::IsNullOrEmpty($env:NIGHTSHIFT_HOST)) { return $env:NIGHTSHIFT_HOST }
    if (-not [string]::IsNullOrEmpty($env:CLAUDE_PROJECT_DIR + $env:CLAUDECODE + $env:CLAUDE_PLUGIN_ROOT)) { return 'claude' }
    if (-not [string]::IsNullOrEmpty($env:CODEX_PROJECT_DIR + $env:CODEX_HOME + $env:CODEX_SANDBOX)) { return 'codex' }
    if (-not [string]::IsNullOrEmpty($env:CURSOR_PROJECT_DIR + $env:CURSOR_PLUGIN_ROOT + $env:CURSOR_TRACE_ID)) { return 'cursor' }
    return 'unknown'
}

# Every verb this host can run, derived from what is on disk so it cannot drift.
function Get-NSDispatchVerbs {
    $names = New-Object 'System.Collections.Generic.List[string]'
    foreach ($file in (Get-ChildItem -LiteralPath (Join-Path $runtime 'windows') -Filter '*.ps1' -File -EA SilentlyContinue)) {
        if ($file.BaseName -ceq 'ns') { continue }
        $names.Add($file.BaseName)
    }
    return ($names | Sort-Object -Unique)
}

function Get-NSDispatchTarget {
    param([Parameter(Mandatory = $true)][string]$Name)
    if (($Name -ceq 'ns') -or ($Name -cmatch '[\\/]') -or ($Name -clike '*..*') -or ($Name -clike '-*')) { return '' }
    $path = Join-Path (Join-Path $runtime 'windows') ($Name + '.ps1')
    if (Test-Path -LiteralPath $path -PathType Leaf) { return $path }
    return ''
}

# The helper's own parameters, and which of them are switches. Read from the file rather than
# held in a list here, so the translation follows the helper.
function Get-NSHelperParameters {
    param([Parameter(Mandatory = $true)][string]$Path)
    $map = @{}
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    $block = $ast.ParamBlock
    if ($null -eq $block) { return $map }
    foreach ($parameter in $block.Parameters) {
        $name = $parameter.Name.VariablePath.UserPath
        $isSwitch = $false
        if ($null -ne $parameter.StaticType) {
            $isSwitch = ($parameter.StaticType.Name -ceq 'SwitchParameter')
        }
        $map[$name] = $isSwitch
    }
    return $map
}

# `--allow-closed` is `-AllowClosed`. Where a helper spells it differently, the helper wins: the
# match is by the parameter the helper actually declares, and an unmatched flag is passed through
# untouched so the helper can refuse it in its own words.
function Resolve-NSFlagName {
    param(
        [Parameter(Mandatory = $true)][string]$Flag,
        [Parameter(Mandatory = $true)][hashtable]$Parameters
    )
    $bare = $Flag.Substring(2)
    $pascal = (($bare -split '-') | ForEach-Object {
            if ($_.Length -eq 0) { '' } else { $_.Substring(0, 1).ToUpperInvariant() + $_.Substring(1) }
        }) -join ''
    foreach ($name in $Parameters.Keys) {
        if ($name -ceq $pascal) { return $name }
    }
    foreach ($name in $Parameters.Keys) {
        if ($name -ieq $pascal) { return $name }
    }
    # A helper may name a parameter more fully than the flag does - `--host` is `-HostName`,
    # `--input` is `-InputPath`. One unambiguous parameter starting with the flag's own name is
    # that parameter; two or more is nothing, and the flag passes through.
    $prefixed = @($Parameters.Keys | Where-Object { $_ -ilike ($pascal + '*') })
    if ($prefixed.Count -eq 1) { return $prefixed[0] }
    return ''
}

$hostName = Get-NSDispatchHost

# The workspace, by the one rule the skills already state. An invalid link refuses in the Start
# preflight's format rather than guessing a workspace.
$taskRoot = $env:CLAUDE_PROJECT_DIR
if ([string]::IsNullOrEmpty($taskRoot)) { $taskRoot = $env:CODEX_PROJECT_DIR }
if ([string]::IsNullOrEmpty($taskRoot)) { $taskRoot = $env:CURSOR_PROJECT_DIR }
if ([string]::IsNullOrEmpty($taskRoot)) { $taskRoot = (Get-Location).ProviderPath }
# The resolver throws on a link it cannot trust, and a terminating error here would replace the
# refusal with a stack trace.
try { $derived = Resolve-NSWorkspaceRoot $taskRoot } catch { $derived = '' }
if ([string]::IsNullOrEmpty($derived)) {
    [Console]::Out.WriteLine('refuse workspace invalid .nightshift-link at ' + $taskRoot)
    [Console]::Out.WriteLine('repair Fix or remove .nightshift-link so it holds one absolute path to a folder containing .nightshift/, then run the command again.')
    exit 2
}
$workspace = $derived
$source = 'derived'

# A session bound to one workspace and standing in another is not a preference to reconcile: the
# writing verbs would scaffold or file into whichever the dispatcher picked. So the bound value wins
# where it is the only one that resolves, and a disagreement refuses before any verb runs.
function Get-NSCanonicalPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    try { return (Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath }
    catch { return $Path }
}
if (-not [string]::IsNullOrEmpty($env:NIGHTSHIFT_WORKSPACE)) {
    try { $bound = Resolve-NSWorkspaceRoot $env:NIGHTSHIFT_WORKSPACE } catch { $bound = '' }
    if ([string]::IsNullOrEmpty($bound)) {
        [Console]::Out.WriteLine('refuse workspace invalid .nightshift-link at ' + $env:NIGHTSHIFT_WORKSPACE)
        [Console]::Out.WriteLine('repair Fix or remove .nightshift-link so it holds one absolute path to a folder containing .nightshift/, then run the command again.')
        exit 2
    }
    $workspace = $bound
    $source = 'bound'
    if ((Get-NSCanonicalPath $bound) -ne (Get-NSCanonicalPath $derived)) {
        [Console]::Out.WriteLine('refuse workspace bound ' + $bound + ' differs from derived ' + $derived)
        [Console]::Out.WriteLine('repair cd to the bound workspace, or unset NIGHTSHIFT_WORKSPACE, then run the command again.')
        exit 2
    }
}

if ($Verb -ceq 'bind') {
    [Console]::Out.WriteLine("TASK_ROOT`t" + $taskRoot)
    [Console]::Out.WriteLine("NIGHTSHIFT_WORKSPACE`t" + $workspace)
    [Console]::Out.WriteLine("NS`t" + (Join-Path $workspace '.nightshift'))
    [Console]::Out.WriteLine("NIGHTSHIFT_PLUGIN_ROOT`t" + $pluginRoot)
    [Console]::Out.WriteLine("HOST`t" + $hostName)
    [Console]::Out.WriteLine("SOURCE`t" + $source)
    exit 0
}

if ($Verb -ceq 'help') {
    [Console]::Out.WriteLine('ns <verb> [args…] — host ' + $hostName)
    [Console]::Out.WriteLine('')
    foreach ($name in (Get-NSDispatchVerbs)) {
        $target = Get-NSDispatchTarget $name
        if ([string]::IsNullOrEmpty($target)) { continue }
        [Console]::Out.WriteLine('  ' + $name.PadRight(22) + ' ' + $target)
    }
    exit 0
}

$target = Get-NSDispatchTarget $Verb
if ([string]::IsNullOrEmpty($target)) {
    [Console]::Error.WriteLine('ns: no verb ' + $Verb + ' on ' + $hostName + ' — run ns help for this host''s verbs')
    exit 1
}

# A verb that writes says where before it does. One line, first on stdout, so an owner reading a
# transcript can see which workspace took the change without reconstructing the resolution.
if ($NSWritingVerbs -ccontains $Verb) {
    [Console]::Out.WriteLine('workspace ' + $workspace)
}

$parameters = Get-NSHelperParameters $target

# Named parameters are splatted from a hashtable; an array splat would pass `-Project` as a value.
# Positional arguments (a helper's own command word, say) keep their order.
$named = @{}
$positional = New-Object 'System.Collections.Generic.List[string]'
$index = 0
while ($index -lt $Rest.Count) {
    $token = $Rest[$index]
    if ($token -clike '--*') {
        $name = Resolve-NSFlagName -Flag $token -Parameters $parameters
        if ([string]::IsNullOrEmpty($name)) {
            # Nothing on this helper answers to it. Hand it over as written so the helper refuses
            # in its own words rather than having the dispatcher guess.
            $positional.Add($token)
            $index++
            continue
        }
        if ($parameters[$name]) {
            $named[$name] = [switch]$true
        }
        elseif ($index + 1 -lt $Rest.Count) {
            $index++
            $named[$name] = $Rest[$index]
        }
        else {
            $named[$name] = ''
        }
        $index++
        continue
    }
    $positional.Add($token)
    $index++
}

# The workspace goes only to helpers that take it, and only when the caller did not say so.
if ((-not $named.ContainsKey('Project')) -and $parameters.ContainsKey('Project')) {
    $named['Project'] = $workspace
}

& $target @positional @named
exit $LASTEXITCODE
