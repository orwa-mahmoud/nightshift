<#
.SYNOPSIS
  The gates block and one punch-list item, printed exactly as the owner wrote them.

.DESCRIPTION
  Mirrors runtime/punch-list.sh. `next` prints the gates block then the first
  still-open item; `item <id>` prints the gates block then that named one.

  The model used to re-read the whole punch list at the start of every item,
  because the Gates block may legitimately change mid-shift. On a long list that
  is thousands of tokens per item to see one block. This prints the two things an
  item actually needs and nothing else.

  It is a reader and only a reader. Nothing here rewrites, reorders, renumbers or
  summarises an item: what comes out is the file's own text, so a model working
  from it is working from the contract rather than from someone's precis of it.

  Exit: 0 printed, or `none` when nothing is open - 1 usage - 2 refused
#>
param(
    [string]$Project = [Environment]::CurrentDirectory,
    [Parameter(Mandatory = $true, Position = 0)][ValidateSet('next', 'item')][string]$Verb,
    [Parameter(Position = 1)][AllowEmptyString()][string]$Id = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$pluginRoot = Resolve-Path (Join-Path $PSScriptRoot '../..')
Import-Module (Join-Path $pluginRoot 'lib/Nightshift.psm1') -Force -DisableNameChecking

# An item carries the owner's own punctuation, em dashes included, so pin stdout to
# UTF-8 whatever the host console code page is.
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)

if (($Verb -ceq 'item') -and [string]::IsNullOrEmpty($Id)) {
    [Console]::Error.WriteLine('punch-list: item needs an id')
    exit 1
}

exit (Invoke-NSPunchListCommand -Project $Project -Verb $Verb -Id $Id)
