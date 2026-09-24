param(
    [string]$Project = [Environment]::CurrentDirectory,
    [string]$Report = '',
    [string]$Manifest = '',
    [string[]]$Output = @()
)
[Console]::Error.WriteLine('ns check-report')
& (Join-Path $PSScriptRoot 'check-report.ps1') -Project $Project -Report $Report -Manifest $Manifest -Output $Output
exit $LASTEXITCODE
