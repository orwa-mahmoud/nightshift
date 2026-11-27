# Raw evidence promotion on native Windows: the PowerShell half of tests/promote-evidence.bats.
# Run on macOS or Windows: pwsh -File tests/windows/promote-evidence-logic.ps1
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if (Test-Path Variable:PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $false
}

$repository = Resolve-Path (Join-Path $PSScriptRoot '../..')
$plugin = Join-Path $repository 'plugins/nightshift'
Import-Module (Join-Path $plugin 'lib/Nightshift.psm1') -Force -DisableNameChecking
$rulesTemplate = Join-Path $plugin 'config/nightshift-rules-template.json'
$hostExe = (Get-Process -Id $PID).Path
$failures = New-Object 'System.Collections.Generic.List[string]'
$utf8 = New-Object Text.UTF8Encoding($false)
$folder = '2026-11-27-aaa111'
$base = '01-export-the-table-ab12'

function Expect-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        $failures.Add($Message)
        Write-Host "FAIL: $Message"
    }
}

function Write-Text { param([string]$Path, [string]$Text) [IO.File]::WriteAllText($Path, $Text, $utf8) }

function Invoke-Promote {
    param([string]$Site, [string[]]$Arguments)
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = @(& $hostExe -NoProfile -NonInteractive -File (Join-Path $plugin 'runtime/windows/promote-evidence.ps1') -Project $Site @Arguments 2>&1 | ForEach-Object { [string]$_ })
        return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Lines = $out; Text = ($out -join "`n") }
    }
    finally { $ErrorActionPreference = $previous }
}

function Add-Filed {
    param([string]$Site, [string]$Name)
    $filed = Join-Path $Site ".nightshift/archive/$Name"
    $null = New-Item -ItemType Directory -Path (Join-Path $filed "receipts/$base/logs") -Force
    Write-Text (Join-Path $filed '.shift-id') "$Name`n"
    Write-Text (Join-Path $filed "receipts/$base/before.png") "before`n"
    Write-Text (Join-Path $filed "receipts/$base/after.png") "after`n"
    Write-Text (Join-Path $filed "receipts/$base/logs/run.txt") "log`n"
    Write-Text (Join-Path $filed "receipts/$base.md") ("# 1. Export the table.`n`n![Before](./$base/before.png) and ![After](./$base/after.png).`n`nThe [run log]($base/logs/run.txt).`n")
}

function New-Site {
    param([string]$Path, [string]$Preference = '')
    $ns = Join-Path $Path '.nightshift'
    $null = New-Item -ItemType Directory -Path (Join-Path $ns 'runs') -Force
    $null = & git -C $Path init -q
    $null = & git -C $Path config user.email d@example.com
    $null = & git -C $Path config user.name d
    Write-Text (Join-Path $ns 'state-version') "3`n"
    $rules = Get-Content -Raw -LiteralPath $rulesTemplate | ConvertFrom-Json
    $rules.sharing.records = @('plans', 'decisions', 'rules', 'receipts', 'summaries')
    if ($Preference.Length -gt 0) { $rules.sharing.evidence = $Preference } else { $rules.sharing.PSObject.Properties.Remove('evidence') }
    Write-Text (Join-Path $ns 'rules.json') ($rules | ConvertTo-Json -Depth 20)
    $null = & $hostExe -NoProfile -NonInteractive -File (Join-Path $plugin 'runtime/windows/share.ps1') -Project $Path -Apply
    Add-Filed $Path $folder
    return (Resolve-NSCanonicalPath $Path)
}

function Get-Receipt { param([string]$Site, [string]$Name = $folder) return [IO.File]::ReadAllText((Join-Path $Site ".nightshift/archive/$Name/receipts/$base.md")) }
function Get-Shared {
    param([string]$Site)
    $dir = Join-Path $Site ".nightshift/archive/$folder/evidence"
    if (-not (Test-Path -LiteralPath $dir)) { return '' }
    return ((@(Get-ChildItem -LiteralPath $dir -Recurse -File | ForEach-Object { $_.FullName.Substring($dir.Length + 1).Replace('\', '/') }) | Sort-Object) -join '|')
}

$root = Join-Path ([IO.Path]::GetTempPath()) ('ns-promote-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $root -Force
try {
    # No preference: nothing is shared, and every link becomes a private label.
    $s = New-Site (Join-Path $root 'none')
    $preview = Invoke-Promote $s @('-Folder', $folder)
    Expect-True ($preview.ExitCode -eq 0 -and ($preview.Lines -ccontains 'ok preference none') -and -not ($preview.Text.Contains('promote '))) "none: $($preview.Text)"
    $null = Invoke-Promote $s @('-Folder', $folder, '-Apply')
    Expect-True ((Get-Shared $s) -ceq '') 'none: nothing copied'
    Expect-True ((Get-Receipt $s).Contains("Before (private evidence: $base/before.png)") -and (Get-Receipt $s).Contains("The run log (private evidence: $base/logs/run.txt).")) "none: labels: $(Get-Receipt $s)"

    # All: narrowing one filing to one file leaves the next filing at all.
    $s = New-Site (Join-Path $root 'all') 'all'
    $applied = Invoke-Promote $s @('-Folder', $folder, '-Select', "receipts/$base/before.png", '-Apply')
    Expect-True ($applied.ExitCode -eq 0 -and (Get-Shared $s) -ceq "$base/before.png") "all: one copy: $($applied.Text)"
    Expect-True ((Get-Receipt $s).Contains("![Before](../evidence/$base/before.png) and After (private evidence: $base/after.png).")) "all: links: $(Get-Receipt $s)"
    Add-Filed $s '2026-11-28-bbb222'
    $next = Invoke-Promote $s @('-Folder', '2026-11-28-bbb222')
    Expect-True (@($next.Lines | Where-Object { $_ -clike 'promote *' }).Count -eq 3) "all: the next filing defaults to all: $($next.Text)"

    # Select: the same choice applied twice leaves one copy and the same receipt; a teammate's
    # checkout opens the promoted copy.
    $s = New-Site (Join-Path $root 'select') 'select'
    $null = Invoke-Promote $s @('-Folder', $folder, '-Select', "receipts/$base/before.png", '-Apply')
    $first = Get-Receipt $s
    $null = Invoke-Promote $s @('-Folder', $folder, '-Select', "receipts/$base/before.png", '-Apply')
    Expect-True ((Get-Receipt $s) -ceq $first -and (Get-Shared $s) -ceq "$base/before.png") 'select: applied twice changes nothing'
    $refused = Invoke-Promote $s @('-Folder', $folder, '-Select', "receipts/$base/missing.png", '-Apply')
    Expect-True ($refused.ExitCode -eq 1) "select: a file that is not evidence is refused: $($refused.Text)"
    $null = & git -C $s add -A
    $null = & git -C $s commit -q -m file
    $clone = Join-Path $root 'teammate'
    $null = & git clone -q $s $clone 2>$null
    $receipts = Join-Path $clone ".nightshift/archive/$folder/receipts"
    Expect-True ([IO.File]::ReadAllText((Join-Path $receipts "../evidence/$base/before.png")) -ceq "before`n") 'select: the teammate opens the promoted copy'
    Expect-True (-not (Test-Path -LiteralPath (Join-Path $receipts $base))) 'select: the raw originals are not in the teammate checkout'
}
finally {
    Set-Location ([IO.Path]::GetTempPath())
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures.Count -gt 0) {
    Write-Host "promote evidence logic failed ($($failures.Count)):"
    foreach ($failure in $failures) { Write-Host " - $failure" }
    exit 1
}
Write-Host 'promote evidence logic passed.'
