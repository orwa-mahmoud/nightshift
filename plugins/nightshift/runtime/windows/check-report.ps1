param(
    [string]$Project = [Environment]::CurrentDirectory,
    [string]$Report = '',
    [string]$Manifest = '',
    [string[]]$Output = @()
)
[Console]::Error.WriteLine('ns check-receipts')
& (Join-Path $PSScriptRoot 'check-receipts.ps1') -Project $Project -Report $Report -Manifest $Manifest -Output $Output
