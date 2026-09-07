# Portable PowerShell probe for the recovery launch scope.
# Run on macOS or Windows: pwsh -File tests/windows/recovery-scope-logic.ps1
# Windows CI also runs it via tests/windows/run.ps1.
#
# The scope a revived session starts under decides what an unattended night is allowed to do, so
# these assert the resolver directly and then the arguments the watchman actually constructs.
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$repository = Resolve-Path (Join-Path $PSScriptRoot '../..')
Import-Module (Join-Path $repository 'plugins/nightshift/lib/Nightshift.psm1') -Force -DisableNameChecking
$template = Join-Path $repository 'plugins/nightshift/skills/nightshift/references/nightshift-rules-template.json'
$failures = New-Object 'System.Collections.Generic.List[string]'
$utf8 = New-Object Text.UTF8Encoding($false)

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

function New-Workspace {
    $path = Join-Path ([IO.Path]::GetTempPath()) ('ns-scope-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path (Join-Path $path '.nightshift') | Out-Null
    Copy-Item $template (Join-Path $path '.nightshift/rules.json')
    return $path
}

function Set-Rules {
    param([string]$Workspace, [AllowNull()]$Scope)
    $path = Join-Path $Workspace '.nightshift/rules.json'
    $document = ConvertFrom-NSJsonText ([IO.File]::ReadAllText($path, $utf8))
    if ($null -eq $Scope) { $null = $document.Remove('recovery') }
    else { $document['recovery']['launchScope'] = $Scope }
    [IO.File]::WriteAllText($path, (ConvertTo-NSCanonicalJson $document), $utf8)
}

function Set-Snapshot {
    param([string]$Workspace, [string]$Scope, [string]$Provenance)
    $document = New-NSOrdinalMap
    $document['schemaVersion'] = 1
    $document['shiftId'] = '9f2c40ab77e51d63'
    $document['createdAt'] = '2026-09-02T00:00:00Z'
    $document['source'] = 'composition'
    $document['verificationLevel'] = 'none'
    $document['toolingPolicy'] = 'existing-tools'
    $document['launchScope'] = $Scope
    $document['launchProvenance'] = $Provenance
    [IO.File]::WriteAllText((Join-Path $Workspace '.nightshift/shift-policy.json'),
        (ConvertTo-NSCanonicalJson $document), $utf8)
}

$workspace = New-Workspace
try {
    # The shipped template asks to inherit, and that is what the resolver reports. Reading it as
    # the broad grant is the defect this file exists to keep out.
    Expect-Equal 'inherit-recorded-scope' (Get-NSRecoveryLaunchScope $workspace) 'shipped template inherits'

    # Nothing recorded: there is nothing to inherit, so a revival is refused rather than launched
    # at whatever the host happens to default to.
    Expect-Equal 'unavailable:unrecorded' (Get-NSRecoveryEffectiveScope $workspace 'codex') 'no snapshot refuses rather than guesses'
    Expect-True ((Get-NSRecoveryRefusal 'unavailable:unrecorded') -match 'nothing to inherit') 'the refusal says why'

    # A missing recovery block, a malformed file and an unrecognised value all inherit. None of
    # them is a reason to hand out permissions.
    Set-Rules $workspace $null
    Expect-Equal 'inherit-recorded-scope' (Get-NSRecoveryLaunchScope $workspace) 'a legacy file with no recovery block inherits'
    [IO.File]::WriteAllText((Join-Path $workspace '.nightshift/rules.json'), '{ "recovery": ', $utf8)
    Expect-Equal 'inherit-recorded-scope' (Get-NSRecoveryLaunchScope $workspace) 'a malformed file inherits'
    Copy-Item $template (Join-Path $workspace '.nightshift/rules.json') -Force
    Set-Rules $workspace 'something-else'
    Expect-Equal 'inherit-recorded-scope' (Get-NSRecoveryLaunchScope $workspace) 'an unrecognised value inherits'

    # The owner's own two choices, by name.
    Set-Rules $workspace 'host-grant'
    Expect-Equal 'host-grant' (Get-NSRecoveryEffectiveScope $workspace 'codex') 'host-grant is the owner writing it'
    Set-Rules $workspace 'host-default'
    Expect-Equal 'host-default' (Get-NSRecoveryEffectiveScope $workspace 'codex') 'host-default is available by name'

    # An observed scope the host can be asked for again passes through; one it cannot is refused.
    Copy-Item $template (Join-Path $workspace '.nightshift/rules.json') -Force
    foreach ($mode in @('read-only', 'workspace-write', 'danger-full-access')) {
        Set-Snapshot $workspace $mode 'observed'
        Expect-Equal ('recorded:' + $mode) (Get-NSRecoveryEffectiveScope $workspace 'codex') "codex can be asked for $mode"
    }
    Set-Snapshot $workspace 'some-future-mode' 'observed'
    Expect-Equal 'unavailable:unsupported:some-future-mode' (Get-NSRecoveryEffectiveScope $workspace 'codex') 'an unsupported mode is refused, not passed'
    Expect-True ((Get-NSRecoveryRefusal 'unavailable:unsupported:some-future-mode') -match 'no way to be asked for again') 'the refusal names the mode'
    Set-Snapshot $workspace 'workspace-write' 'unavailable'
    Expect-Equal 'unavailable:unrecorded' (Get-NSRecoveryEffectiveScope $workspace 'codex') 'a scope nobody observed is not inherited'

    # Claude Code and Cursor name no scope, so nothing is ever handed to their command lines.
    Expect-Equal "unknown`tunavailable" (Get-NSLaunchObserved 'claude') 'claude observes nothing'
    Expect-Equal "unknown`tunavailable" (Get-NSLaunchObserved 'cursor') 'cursor observes nothing'
    Set-Snapshot $workspace 'workspace-write' 'observed'
    Expect-Equal 'unavailable:unsupported:workspace-write' (Get-NSRecoveryEffectiveScope $workspace 'cursor') 'cursor cannot be asked for a codex mode'

    # What Codex does report is recorded, so a revival has something to inherit.
    $env:CODEX_SANDBOX_MODE = 'read-only'
    try { Expect-Equal "read-only`tobserved" (Get-NSLaunchObserved 'codex') 'codex reports its sandbox' }
    finally { Remove-Item Env:CODEX_SANDBOX_MODE }

    # And the writer records it, so the reader is not inheriting a field nobody wrote.
    $written = New-Workspace
    try {
        $env:CODEX_SANDBOX_MODE = 'workspace-write'
        $env:CODEX_PROJECT_DIR = $written
        try {
            $json = '{"schemaVersion":1,"shiftId":"0123456789abcdef","createdAt":"2026-09-02T02:30:00Z",' +
                '"source":"composition","verificationLevel":"final","toolingPolicy":"existing-tools"}'
            Expect-Equal 0 (Set-NSShiftPolicy -Workspace $written -Json $json) 'the snapshot is written'
            Expect-Equal 'recorded:workspace-write' (Get-NSRecoveryEffectiveScope $written 'codex') 'the writer records what the reader inherits'
        }
        finally {
            Remove-Item Env:CODEX_SANDBOX_MODE
            Remove-Item Env:CODEX_PROJECT_DIR
        }
    }
    finally { Remove-Item -Recurse -Force $written }
}
finally { Remove-Item -Recurse -Force $workspace }

# The watchman's own argument construction: the broad flags belong to host-grant alone.
$watchman = [IO.File]::ReadAllText((Join-Path $repository 'plugins/nightshift/runtime/windows/watchman.ps1'), $utf8)
foreach ($fragment in @(
        "Get-NSRecoveryEffectiveScope",
        "if (`$launchScope -ceq 'host-grant') {",
        "unavailable:*",
        "recovery-scope-unavailable")) {
    if (-not $watchman.Contains($fragment)) {
        $failures.Add("watchman is missing: $fragment")
        Write-Host "FAIL: watchman is missing: $fragment"
    }
}
if ($watchman.Contains("if (`$launchScope -ne 'host-default')")) {
    $failures.Add('watchman still treats anything but host-default as the broad grant')
    Write-Host 'FAIL: watchman still treats anything but host-default as the broad grant'
}

if ($failures.Count -gt 0) {
    Write-Host ("recovery-scope-logic failed ($($failures.Count)):")
    foreach ($failure in $failures) { Write-Host " - $failure" }
    exit 1
}
Write-Host 'recovery-scope-logic passed'
exit 0
