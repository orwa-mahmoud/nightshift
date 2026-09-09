# Portable PowerShell probe for Stop/Reset/Purge control helpers.
# Run on macOS or Windows before pushing: pwsh -File tests/windows/control-logic.ps1
# It does not replace windows-native CI (ACLs, mutexes, dispatchers), and Windows CI
# also runs it via tests/windows/run.ps1.
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$repository = Resolve-Path (Join-Path $PSScriptRoot '../..')
$plugin = Join-Path $repository 'plugins/nightshift'
Import-Module (Join-Path $plugin 'lib/Nightshift.psm1') -Force -DisableNameChecking

$failures = New-Object 'System.Collections.Generic.List[string]'

function Expect-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        $failures.Add($Message)
        Write-Host "FAIL: $Message"
    }
}

$root = Join-Path ([IO.Path]::GetTempPath()) ("ns-control-logic-" + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $root -Force
$ns = Join-Path $root '.nightshift'
$null = New-Item -ItemType Directory -Path $ns -Force
[IO.File]::WriteAllText((Join-Path $ns 'punch-list.md'), "## Items`n- [ ] **1. first.**`n")
[IO.File]::WriteAllText((Join-Path $ns 'rules.json'), "{ }`n")
[IO.File]::WriteAllText((Join-Path $ns 'shift-policy.json'), "{ }`n")
[IO.File]::WriteAllText((Join-Path $ns 'shift-defaults.json'), "{ }`n")
[IO.File]::WriteAllText((Join-Path $ns 'parking-lot.md'), "parked`n")
$deadline = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 3600
[IO.File]::WriteAllText((Join-Path $ns 'deadline'), "$deadline`n")
$null = New-Item -ItemType File -Path (Join-Path $ns '.shift-armed') -Force
[IO.File]::WriteAllText((Join-Path $ns '.shift-lease'), "sid`nclaude`n1`n`n1`n`n")

try {
    $lines = @(Stop-NSShift -Project $root)
    $joined = $lines -join "`n"
    Expect-True ($joined -match 'watchman absent') "stop names an absent watchman: $joined"
    Expect-True ($joined -match 'deadline preserved') "stop preserves deadline: $joined"
    Expect-True (Test-Path -LiteralPath (Join-Path $ns 'STOP') -PathType Leaf) 'STOP written'
    Expect-True (Test-Path -LiteralPath (Join-Path $ns '.shift-armed') -PathType Leaf) 'armed marker kept'
    Expect-True (Test-NSHardhatActive $ns) 'hardhat stays after STOP'
    Expect-True (Test-Path -LiteralPath (Join-Path $ns '.shift-lease') -PathType Leaf) 'lease kept until ENDED'
    Expect-True (Test-Path -LiteralPath (Join-Path $ns 'deadline') -PathType Leaf) 'deadline file kept'
    Expect-True (Test-Path -LiteralPath (Join-Path $ns 'parking-lot.md') -PathType Leaf) 'parking lot kept'
    Expect-True (Test-Path -LiteralPath (Join-Path $ns 'shift-policy.json') -PathType Leaf) 'stop keeps the shift policy'
    $null = Stop-NSShift -Project $root
    Expect-True $true 'second stop is idempotent'

    $refuse = Get-NSControlStartRefuseReason $ns
    Expect-True ([string]::IsNullOrEmpty($refuse)) "future paused deadline is resumable: $refuse"
    [IO.File]::WriteAllText((Join-Path $ns 'deadline'), "1`n")
    $refuse = Get-NSControlStartRefuseReason $ns
    Expect-True (-not [string]::IsNullOrEmpty($refuse)) 'expired paused deadline is refused'
    Expect-True ($refuse -match 'refusing to invent a time budget') "refuse names the budget: $refuse"

    $resetLines = @(Reset-NSShift -Project $root)
    $resetJoined = $resetLines -join "`n"
    Expect-True ($resetJoined -match 'deadline removed') "reset removes deadline: $resetJoined"
    Expect-True (-not (Test-Path -LiteralPath (Join-Path $ns 'deadline'))) 'deadline gone'
    Expect-True (-not (Test-Path -LiteralPath (Join-Path $ns 'STOP'))) 'STOP gone'
    Expect-True (Test-Path -LiteralPath (Join-Path $ns 'punch-list.md') -PathType Leaf) 'punch list kept'
    Expect-True (Test-Path -LiteralPath $ns -PathType Container) '.nightshift kept'
    Expect-True (-not (Test-Path -LiteralPath (Join-Path $ns 'shift-policy.json'))) 'reset removes the shift policy'
    Expect-True (Test-Path -LiteralPath (Join-Path $ns 'shift-defaults.json') -PathType Leaf) 'reset keeps remembered defaults'
    Expect-True (Test-Path -LiteralPath (Join-Path $ns 'rules.json') -PathType Leaf) 'reset keeps rules.json'
    $null = Reset-NSShift -Project $root

    $pluginRoot = Resolve-NSCanonicalPath $plugin
    $helper = Join-Path $pluginRoot 'runtime/windows/stop-shift.ps1'
    $ok = Test-NSTrustedShiftControl -Command "$helper -Project $root" -PluginRoot $pluginRoot -Workspace $root
    Expect-True $ok 'exact stop helper is trusted'
    $bad = Test-NSTrustedShiftControl -Command "$helper -Project $root; Remove-Item x" -PluginRoot $pluginRoot -Workspace $root
    Expect-True (-not $bad) 'semicolon extra command is not trusted'
    $rel = Test-NSTrustedShiftControl -Command "$helper -Project ." -PluginRoot $pluginRoot -Workspace $root
    Expect-True (-not $rel) 'relative project is not trusted'
    $ordinary = Test-NSTrustedShiftControl -Command 'Get-Location' -PluginRoot $pluginRoot -Workspace $root
    Expect-True (-not $ordinary) 'a single-token ordinary command is not trusted'

    Expect-True (Test-NSBroadWorkspace '/') 'slash is broad'
    if (-not [string]::IsNullOrEmpty($env:HOME)) {
        try {
            $home = Resolve-NSCanonicalPath $env:HOME
            Expect-True (Test-NSBroadWorkspace $home) 'home is broad'
        }
        catch { }
    }

    # A fresh policy snapshot, written after Reset already cleared the first one, so Purge's own
    # removal is exercised rather than inherited from the Reset call above.
    [IO.File]::WriteAllText((Join-Path $ns 'shift-policy.json'), "{ }`n")
    $purgeHelper = Join-Path $plugin 'runtime/windows/purge-workspace.ps1'
    $ctx = Resolve-NSControlWorkspace $root
    $expectedConfirm = Join-Path $ctx.Workspace '.nightshift'
    $purgeOut = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N') + '.purge-out')
    try {
        $previousEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            & (Get-Process -Id $PID).Path -NoProfile -NonInteractive -File $purgeHelper -Project $root `
                > $purgeOut 2>&1
        }
        finally {
            $ErrorActionPreference = $previousEap
        }
        $purgeCode = $LASTEXITCODE
        $purgeText = if (Test-Path -LiteralPath $purgeOut) { [IO.File]::ReadAllText($purgeOut) } else { '' }
        Expect-True ($purgeCode -eq 1) "missing confirm-path exits 1: $purgeText"
        $purgeFlat = [regex]::Replace($purgeText, '\s+', ' ')
        Expect-True ($purgeFlat -like "*purge-workspace: refusing without --confirm-path $expectedConfirm*") `
            "missing confirm-path names the exact path: $purgeText"
        Expect-True (Test-Path -LiteralPath $ns -PathType Container) 'missing confirm-path removes nothing'
    }
    finally {
        Remove-Item -LiteralPath $purgeOut -Force -ErrorAction SilentlyContinue
    }
    $confirm = Join-Path $root '.nightshift'
    try { $confirm = Resolve-NSCanonicalPath $ns } catch { }
    $null = Remove-NSNightshiftWorkspace -Project $root -ConfirmPath $confirm
    Expect-True (-not (Test-Path -LiteralPath $ns)) 'purge removes .nightshift'
    Expect-True (-not (Test-Path -LiteralPath (Join-Path $ns 'shift-policy.json'))) 'purge removes the shift policy'
    Expect-True (-not (Test-Path -LiteralPath (Join-Path $ns 'shift-defaults.json'))) 'purge removes remembered defaults'
    Expect-True (Test-Path -LiteralPath $root -PathType Container) 'project root remains'
    $null = Remove-NSNightshiftWorkspace -Project $root -ConfirmPath $confirm

    $threw = $false
    try {
        $null = Remove-NSNightshiftWorkspace -Project $root -ConfirmPath 'C:\not-this'
    }
    catch { $threw = $true }
    Expect-True $threw 'purge requires exact confirm-path'
}
finally {
    if (Test-Path -LiteralPath $root) {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($failures.Count -gt 0) {
    Write-Host ("{0} control-logic failures" -f $failures.Count)
    exit 1
}
Write-Host 'control-logic ok'
exit 0
