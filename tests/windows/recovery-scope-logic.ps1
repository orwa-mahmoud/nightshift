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
    Reset-Rules $path
    return $path
}

# The shipped template with recovery.launchScope set to inherit-recorded-scope: the owner who
# chose to restore a recorded scope, which is what most of this file exercises.
function Reset-Rules {
    param([string]$Workspace)
    Copy-Item $template (Join-Path $Workspace '.nightshift/rules.json') -Force
    Set-Rules $Workspace 'inherit-recorded-scope'
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
    # The owner's inherit-recorded-scope is what the resolver reports. Reading it as the broad
    # grant is the defect this file exists to keep out.
    Expect-Equal 'inherit-recorded-scope' (Get-NSRecoveryLaunchScope $workspace) 'an owner who chose to inherit inherits'
    $shipped = Join-Path ([IO.Path]::GetTempPath()) ('ns-scope-shipped-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path (Join-Path $shipped '.nightshift') | Out-Null
    Copy-Item $template (Join-Path $shipped '.nightshift/rules.json')
    try { Expect-Equal 'host-default' (Get-NSRecoveryLaunchScope $shipped) 'the shipped template is host-default' }
    finally { Remove-Item -Recurse -Force $shipped }

    # Nothing recorded: there is nothing to inherit, so a revival is refused rather than launched
    # at whatever the host happens to default to.
    Expect-Equal 'unavailable:unrecorded' (Get-NSRecoveryEffectiveScope $workspace 'codex') 'no snapshot refuses rather than guesses'
    Expect-True ((Get-NSRecoveryRefusal 'unavailable:unrecorded') -match 'nothing to inherit') 'the refusal says why'

    # A missing recovery block is a setting the owner never wrote, so it is the built-in default.
    # A malformed file and an unrecognised value inherit: neither is a reason to hand out
    # permissions.
    Set-Rules $workspace $null
    Expect-Equal 'host-default' (Get-NSRecoveryLaunchScope $workspace) 'a legacy file with no recovery block is the built-in default'
    [IO.File]::WriteAllText((Join-Path $workspace '.nightshift/rules.json'), '{ "recovery": ', $utf8)
    Expect-Equal 'inherit-recorded-scope' (Get-NSRecoveryLaunchScope $workspace) 'a malformed file inherits'
    Reset-Rules $workspace
    Set-Rules $workspace 'something-else'
    Expect-Equal 'inherit-recorded-scope' (Get-NSRecoveryLaunchScope $workspace) 'an unrecognised value inherits'

    # The owner's own two choices, by name.
    Set-Rules $workspace 'host-grant'
    Expect-Equal 'unavailable:host-grant' (Get-NSRecoveryEffectiveScope $workspace 'codex') 'legacy host-grant refuses recovery'
    Set-Rules $workspace 'host-default'
    Expect-Equal 'host-default' (Get-NSRecoveryEffectiveScope $workspace 'codex') 'host-default is available by name'
    Set-Snapshot $workspace 'danger-full-access' 'observed'
    Expect-Equal 'host-default' (Get-NSRecoveryEffectiveScope $workspace 'codex') 'host-default uses independent host configuration'
    Set-Snapshot $workspace 'unknown' 'unavailable'

    # An observed scope the host can be asked for again passes through; one it cannot is refused.
    Reset-Rules $workspace
    foreach ($mode in @('read-only', 'workspace-write')) {
        Set-Snapshot $workspace $mode 'observed'
        Expect-Equal ('recorded:' + $mode) (Get-NSRecoveryEffectiveScope $workspace 'codex') "codex can be asked for $mode"
    }
    foreach ($mode in @('danger-full-access', 'dangerously-skip-permissions', 'bypass-permissions', 'bypassPermissions')) {
        Set-Snapshot $workspace $mode 'observed'
        foreach ($hostName in @('codex', 'claude', 'cursor')) {
            Expect-Equal ('unavailable:unsupported:' + $mode) (Get-NSRecoveryEffectiveScope $workspace $hostName) "$hostName refuses recorded $mode"
        }
    }
    Set-Snapshot $workspace 'some-future-mode' 'observed'
    Expect-Equal 'unavailable:unsupported:some-future-mode' (Get-NSRecoveryEffectiveScope $workspace 'codex') 'an unsupported mode is refused, not passed'
    Expect-True ((Get-NSRecoveryRefusal 'unavailable:unsupported:some-future-mode') -match 'does not restore automatically') 'the refusal names the mode'
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

    # A Nightshift file that cannot be opened is that file, not a silent inherit and not an
    # unreadable policy. The test points the reader at a path that was never written.
    Expect-True ((Get-NSRecoveryReaderPath) -like '*Nightshift.03.ps1') 'the recovery reader is the module file'
    $missingReader = Join-Path ([IO.Path]::GetTempPath()) ('ns-missing-reader-' + [guid]::NewGuid().ToString('N'))
    $env:NIGHTSHIFT_RECOVERY_READER = $missingReader
    try {
        $missingScope = Get-NSRecoveryEffectiveScope $workspace 'claude'
        Expect-Equal ('unavailable:missing-file:' + $missingReader) $missingScope 'a missing Nightshift file is not inherited'
        Expect-True ((Get-NSRecoveryRefusal $missingScope) -match 'Nightshift file missing:') 'the refusal names the missing file'
        Expect-True ((Get-NSRecoveryRepair $workspace $missingScope) -notmatch 'set recovery.launchScope to host-default') 'a missing file is not repaired by setting a scope'
    }
    finally { Remove-Item Env:NIGHTSHIFT_RECOVERY_READER }

    Set-Rules $workspace 'host-default'
    Expect-True ((Get-NSRecoveryRepair $workspace 'unavailable:unrecorded') -match 'already host-default') 'repair does not ask for a scope that is already set'
    Reset-Rules $workspace
    Expect-True ((Get-NSRecoveryRepair $workspace 'unavailable:unrecorded') -match 'set recovery.launchScope to host-default') 'an unrecorded scope still names host-default'

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

# The watchman never constructs bypass flags or broad sandbox grants.
$watchman = [IO.File]::ReadAllText((Join-Path $repository 'plugins/nightshift/runtime/windows/watchman.ps1'), $utf8)
foreach ($fragment in @(
        "Get-NSRecoveryEffectiveScope",
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

Expect-True ($watchman -notmatch '--dangerously-skip-permissions|--yolo|--trust|danger-full-access') 'watchman never adds bypass grants'

# A refused scope must not leave a Cursor worker behind: the refusal comes before the mint, the
# mint records nothing, and the worker is written only once the revival is about to launch.
$resolveBody = $watchman.Substring($watchman.IndexOf('function Resolve-NSCursorWorkerId {'))
$resolveBody = $resolveBody.Substring(0, $resolveBody.IndexOf("`nfunction ", 1))
Expect-True (-not $resolveBody.Contains('Write-NSCursorWorkerId')) 'resolving the Cursor worker records nothing'
$agentBody = $watchman.Substring($watchman.IndexOf('function Start-NSAgent {'))
$scopeAt = $agentBody.IndexOf('Get-NSRecoveryEffectiveScope')
$resolveAt = $agentBody.IndexOf('Resolve-NSCursorWorkerId')
$heldAt = $agentBody.IndexOf('session activity while the CLI worker was minted')
$writeAt = $agentBody.IndexOf('Write-NSCursorWorkerId $sessionId')
$takeoverAt = $agentBody.IndexOf('Takeover-NSLease')
Expect-True ($scopeAt -ge 0 -and $resolveAt -gt $scopeAt) 'the launch scope is resolved before a Cursor worker is minted'
Expect-True ($heldAt -gt $resolveAt -and $writeAt -gt $heldAt -and $takeoverAt -gt $writeAt) `
    'the Cursor worker is recorded after the liveness re-check and just before the lease is taken'

# An unrecorded scope is final: one notice, then silence, until the rules file changes.
$holdWorkspace = New-Workspace
try {
    $holdNs = Join-Path $holdWorkspace '.nightshift'
    $first = Invoke-NSWatchmanRecoveryHold -Workspace $holdWorkspace -NightshiftDir $holdNs -HostName 'cursor'
    Expect-Equal 'unavailable:unrecorded' $first 'the first unrecorded wake sticks'
    $second = Invoke-NSWatchmanRecoveryHold -Workspace $holdWorkspace -NightshiftDir $holdNs -HostName 'cursor'
    Expect-Equal 'quiet' $second 'the next wake does not say it again'
    $lot = Get-NSLayoutPath $holdNs 'parking-lot'
    $notices = @(Select-String -LiteralPath $lot -Pattern 'unattended revival and watchman clock-out are stuck' -SimpleMatch)
    Expect-Equal 1 $notices.Count 'one parking notice for a stuck revival'
    Set-Rules $holdWorkspace 'host-default'
    $cleared = Invoke-NSWatchmanRecoveryHold -Workspace $holdWorkspace -NightshiftDir $holdNs -HostName 'cursor'
    Expect-Equal 'clear' $cleared 'host-default in the rules file clears the stuck revival'
    Expect-Equal '' (Get-NSReasonCode $holdNs) 'the stuck reason is gone once revival can proceed'
    $sentence = Get-NSRecoveryStuckSentence $holdNs
    Expect-Equal '' $sentence 'status has nothing to warn once the reason is gone'
}
finally {
    Remove-Item -LiteralPath $holdWorkspace -Recurse -Force
}

Expect-True ($watchman.Contains('Invoke-NSWatchmanRecoveryHold')) 'the Windows watchman holds a terminal scope'

if ($failures.Count -gt 0) {
    Write-Host ("recovery-scope-logic failed ($($failures.Count)):")
    foreach ($failure in $failures) { Write-Host " - $failure" }
    exit 1
}
Write-Host 'recovery-scope-logic passed'
exit 0
