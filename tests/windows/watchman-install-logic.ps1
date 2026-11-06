# A replaced plugin install is a directory, not a version string.
# Run on macOS or Windows: pwsh -File tests/windows/watchman-install-logic.ps1
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$repository = Resolve-Path (Join-Path $PSScriptRoot '../..')
$source = Join-Path $repository 'plugins/nightshift'
Import-Module (Join-Path $source 'lib/Nightshift.psm1') -Force -DisableNameChecking
$failures = New-Object 'System.Collections.Generic.List[string]'

function Expect-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        $failures.Add($Message)
        Write-Host "FAIL: $Message"
    }
}

function Expect-Equal {
    param($Expected, $Actual, [string]$Message)
    if ($Expected -cne $Actual) {
        $failures.Add("$Message (expected '$Expected', got '$Actual')")
        Write-Host "FAIL: $Message (expected '$Expected', got '$Actual')"
    }
}

$root = Join-Path ([IO.Path]::GetTempPath()) ('ns-install-' + [guid]::NewGuid().ToString('N'))
$workspace = Join-Path $root 'proj'
$old = Join-Path $root 'old'
$new = Join-Path $root 'new'
$profileRoot = Join-Path $root 'home'
$savedHome = [string]$env:HOME
$savedProfile = [string]$env:USERPROFILE
try {
    New-Item -ItemType Directory -Force -Path (Join-Path $workspace '.nightshift') | Out-Null
    New-Item -ItemType Directory -Force -Path $profileRoot | Out-Null
    Copy-Item -Recurse $source $old
    Copy-Item -Recurse $source $new
    $env:HOME = $profileRoot
    $env:USERPROFILE = $profileRoot
    $ns = Join-Path $workspace '.nightshift'
    $script = Join-Path $old 'runtime/windows/watchman.ps1'
    $stay = Get-NSWatchmanInstallPlan -NightshiftDir $ns -HostName 'claude' -ScriptPath $script -SelfVersion '0.30.1' -RuntimeKind windows
    Expect-Equal 'stay' $stay.Action 'a usable install stays'

    $canonNew = (Resolve-Path -LiteralPath $new).ProviderPath
    $copies = Get-NSLayoutPath $ns 'hook-copies'
    [IO.File]::WriteAllText($copies, ("100`tclaude`tsid`t{0}`t9.9.9`n" -f $canonNew), (New-Object Text.UTF8Encoding($false)))
    $reexec = Get-NSWatchmanInstallPlan -NightshiftDir $ns -HostName 'claude' -ScriptPath $script -SelfVersion '0.30.1' -RuntimeKind windows
    Expect-Equal 'reexec' $reexec.Action 'a different hooks copy re-runs'
    Expect-True ($reexec.Target -ceq (Join-Path $canonNew 'runtime/windows/watchman.ps1')) 'the re-run target is that copy'
    Expect-True ($reexec.Message -match 'hooks') 'the log names the hooks copy'

    Remove-Item -Recurse -Force $old
    Remove-Item -Recurse -Force $new
    Remove-Item -Force $copies
    $pending = Get-NSWatchmanInstallPlan -NightshiftDir $ns -HostName 'claude' -ScriptPath $script -SelfVersion '0.30.1' -RuntimeKind windows
    Expect-Equal 'pending' $pending.Action 'no current install waits for one confirming wake'
    Expect-Equal 'no-install' $pending.Reason 'the pending detail is no current install'
    $reason = Get-NSLayoutPath $ns 'watch-reason'
    [IO.File]::WriteAllText($reason, "install-pending`nno-install`n", (New-Object Text.UTF8Encoding($false)))
    $down = Get-NSWatchmanInstallPlan -NightshiftDir $ns -HostName 'claude' -ScriptPath $script -SelfVersion '0.30.1' -RuntimeKind windows
    Expect-Equal 'stand-down' $down.Action 'the confirming wake stands down once'

    $pidFile = Get-NSLayoutPath $ns 'watchman'
    [IO.File]::WriteAllText($pidFile, "99`nstart`nscript:$script`nversion:0.30.1`n", (New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText((Get-NSLayoutPath $ns 'session'), "sid`n`n`n`nclaude`n", (New-Object Text.UTF8Encoding($false)))
    $sentence = Get-NSWatchmanRemovedSentence $ns $pidFile '99' 'windows'
    Expect-True ($sentence -match 'watchman running from a removed install \(version 0.30.1\)') 'status names the removed version'
    Expect-True ($sentence -match 'current install is none') 'a missing host record says none'
    Expect-True ($sentence -match 'kill 99') 'the sentence names the replace command'
}
finally {
    if ([string]::IsNullOrEmpty($savedHome)) { Remove-Item Env:HOME -ErrorAction SilentlyContinue } else { $env:HOME = $savedHome }
    if ([string]::IsNullOrEmpty($savedProfile)) { Remove-Item Env:USERPROFILE -ErrorAction SilentlyContinue } else { $env:USERPROFILE = $savedProfile }
    if (Test-Path -LiteralPath $root) { Remove-Item -Recurse -Force $root }
}

if ($failures.Count -gt 0) {
    Write-Host ("watchman-install-logic failed ($($failures.Count)):")
    foreach ($failure in $failures) { Write-Host " - $failure" }
    exit 1
}
Write-Host 'watchman-install-logic passed'
exit 0
