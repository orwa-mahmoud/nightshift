# Drive runtime/windows/purge-workspace.ps1 in a scratch tree.
# Run on macOS or Windows: pwsh -File tests/windows/purge-workspace-logic.ps1
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if (Test-Path Variable:PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $false
}

$repository = Resolve-Path (Join-Path $PSScriptRoot '../..')
$plugin = Join-Path $repository 'plugins/nightshift'
$helper = Join-Path $plugin 'runtime/windows/purge-workspace.ps1'
Import-Module (Join-Path $plugin 'lib/Nightshift.psm1') -Force -DisableNameChecking

$failures = New-Object 'System.Collections.Generic.List[string]'

function Expect-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        $failures.Add($Message)
        Write-Host "FAIL: $Message"
    }
}

function Invoke-Purge {
    param([string[]]$Arguments = @())
    $out = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N') + '.purge-ep')
    try {
        & (Get-Process -Id $PID).Path -NoProfile -NonInteractive -File $helper @Arguments `
            > $out 2>&1
        $code = $LASTEXITCODE
        $text = ''
        if (Test-Path -LiteralPath $out) { $text = [IO.File]::ReadAllText($out) }
        return [pscustomobject]@{ ExitCode = $code; Text = $text }
    }
    finally {
        Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue
    }
}

$scratch = Join-Path ([IO.Path]::GetTempPath()) ("ns-purge-ep-" + [guid]::NewGuid().ToString('N'))
$project = Join-Path $scratch 'project'
$neighbor = Join-Path $scratch 'neighbor'
$ns = Join-Path $project '.nightshift'
$neighborNs = Join-Path $neighbor '.nightshift'
$null = New-Item -ItemType Directory -Path $ns -Force
$null = New-Item -ItemType Directory -Path $neighborNs -Force
[IO.File]::WriteAllText((Join-Path $project 'README.md'), "keep-project`n")
[IO.File]::WriteAllText((Join-Path $neighbor 'keep.md'), "keep-neighbor`n")
[IO.File]::WriteAllText((Join-Path $ns 'punch-list.md'), "## Items`n- [ ] **1. first.**`n")
[IO.File]::WriteAllText((Join-Path $ns 'rules.json'), "{ }`n")
[IO.File]::WriteAllText((Join-Path $neighborNs 'rules.json'), "{ }`n")

try {
    $missingProject = Invoke-Purge @()
    Expect-True ($missingProject.ExitCode -eq 1) "missing Project exits 1: $($missingProject.Text)"
    Expect-True ($missingProject.Text -like '*purge-workspace: -Project is required*') `
        "missing Project is a usage refusal: $($missingProject.Text)"
    Expect-True (Test-Path -LiteralPath $ns -PathType Container) 'missing Project removes nothing'

    $ctx = Resolve-NSControlWorkspace $project
    $expected = Join-Path $ctx.Workspace '.nightshift'
    $missingConfirm = Invoke-Purge @('-Project', $project)
    Expect-True ($missingConfirm.ExitCode -eq 1) "missing ConfirmPath exits 1: $($missingConfirm.Text)"
    Expect-True ($missingConfirm.Text -like "*purge-workspace: refusing without --confirm-path $expected*") `
        "missing ConfirmPath names the exact path: $($missingConfirm.Text)"
    Expect-True (Test-Path -LiteralPath $ns -PathType Container) 'missing ConfirmPath removes nothing'

    $wrong = Invoke-Purge @('-Project', $project, '-ConfirmPath', (Join-Path $scratch 'not-this'))
    Expect-True ($wrong.ExitCode -eq 1) "wrong ConfirmPath exits 1: $($wrong.Text)"
    Expect-True ($wrong.Text -like '*purge-workspace: --confirm-path must be exactly *') `
        "wrong ConfirmPath names the required path: $($wrong.Text)"
    Expect-True (Test-Path -LiteralPath $ns -PathType Container) 'wrong ConfirmPath removes nothing'
    Expect-True (Test-Path -LiteralPath (Join-Path $project 'README.md') -PathType Leaf) `
        'wrong ConfirmPath leaves project files'

    $confirm = $ns
    try { $confirm = Resolve-NSCanonicalPath $ns } catch { }
    $ok = Invoke-Purge @('-Project', $project, '-ConfirmPath', $confirm)
    Expect-True ($ok.ExitCode -eq 0) "canonical ConfirmPath exits 0: $($ok.Text)"
    Expect-True ($ok.Text -like '*plugin install was not touched*') "success names the plugin: $($ok.Text)"
    Expect-True (-not (Test-Path -LiteralPath $ns)) 'canonical ConfirmPath removes .nightshift'
    Expect-True (Test-Path -LiteralPath (Join-Path $project 'README.md') -PathType Leaf) `
        'canonical ConfirmPath leaves project files'
    Expect-True (Test-Path -LiteralPath $neighborNs -PathType Container) 'neighbour .nightshift remains'
    Expect-True (Test-Path -LiteralPath (Join-Path $neighbor 'keep.md') -PathType Leaf) `
        'neighbour project files remain'

    $again = Invoke-Purge @('-Project', $project, '-ConfirmPath', $confirm)
    Expect-True ($again.ExitCode -eq 0) "repeat purge is idempotent: $($again.Text)"
}
finally {
    if (Test-Path -LiteralPath $scratch) {
        Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($failures.Count -gt 0) {
    Write-Host ("{0} purge-workspace-logic failures" -f $failures.Count)
    exit 1
}
Write-Host 'purge-workspace-logic ok'
exit 0
