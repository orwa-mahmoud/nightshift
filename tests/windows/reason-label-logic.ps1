# Portable PowerShell coverage for Windows watchman reason labels.
# Prints one `code<TAB>label` line per shipped code. bats compares them to POSIX.
# Run on macOS or Windows: pwsh -File tests/windows/reason-label-logic.ps1
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$repository = Resolve-Path (Join-Path $PSScriptRoot '../..')
Import-Module (Join-Path $repository 'plugins/nightshift/lib/Nightshift.psm1') -Force -DisableNameChecking

$codes = @(
    'completed', 'owner-stop', 'owner-disarm', 'stale-pid', 'invalid-session', 'exhausted-retry',
    'unknown-wedge', 'revived', 'stand-down', 'wrong-host', 'deadline',
    'clean-session-end', 'esc-standby', 'silent-standby', 'non-resumable-session',
    'unreadable-rules', 'fresh-fallback', 'unsupported-state', 'process-evidence-unavailable',
    'clock-out-failed', 'recovery-scope-unavailable'
)

foreach ($code in $codes) {
    $label = Get-NSReasonLabel $code
    if ([string]::IsNullOrEmpty($label) -or $label -eq 'unknown watchman outcome') {
        Write-Host "FAIL: empty or unknown label for $code"
        exit 1
    }
    Write-Output ("{0}`t{1}" -f $code, $label)
}
exit 0
