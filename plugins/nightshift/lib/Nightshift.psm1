Set-StrictMode -Version 2.0

# The native Windows runtime, in parts that load in this order into this module's scope. Each part
# picks up where the one before it ends, so together they run as one file would.
. (Join-Path $PSScriptRoot 'Nightshift.01.ps1')
. (Join-Path $PSScriptRoot 'Nightshift.02.ps1')
. (Join-Path $PSScriptRoot 'Nightshift.03.ps1')
. (Join-Path $PSScriptRoot 'Nightshift.04.ps1')
. (Join-Path $PSScriptRoot 'Nightshift.05.ps1')
. (Join-Path $PSScriptRoot 'Nightshift.06.ps1')
. (Join-Path $PSScriptRoot 'Nightshift.07.ps1')

Export-ModuleMember -Function *
