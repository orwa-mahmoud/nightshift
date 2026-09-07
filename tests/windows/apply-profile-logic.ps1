# Portable PowerShell coverage for the Windows apply-profile v2 profile behaviour (armed refuse,
# shift-defaults.json merge, and the `## Gates` block rewrite).
# Run on macOS or Windows: pwsh -File tests/windows/apply-profile-logic.ps1
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if (Test-Path Variable:PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $false
}

$repository = Resolve-Path (Join-Path $PSScriptRoot '../..')
$helper = Join-Path $repository 'plugins/nightshift/runtime/windows/apply-profile.ps1'
$template = Join-Path $repository 'plugins/nightshift/skills/nightshift/references/nightshift-rules-template.json'
$punchListTemplate = Join-Path $repository 'plugins/nightshift/skills/nightshift/references/templates/punch-list.md'
$hostExecutable = (Get-Process -Id $PID).Path
$failures = New-Object 'System.Collections.Generic.List[string]'

function Expect-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        $failures.Add($Message)
        Write-Host "FAIL: $Message"
    }
}

function Invoke-ApplyProfile {
    param(
        [Parameter(Mandatory = $true)][string]$Project,
        [string]$Helper = $helper,
        [string]$ProfileName = 'no-push',
        [string]$ModeName = 'fill',
        [switch]$Apply
    )
    $argList = @(
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', $Helper, '-Project', $Project,
        '-Profile', $ProfileName, '-Mode', $ModeName
    )
    if ($Apply) {
        $argList += '-Apply'
    }
    $stdout = [Collections.Generic.List[string]]::new()
    $stderr = [Collections.Generic.List[string]]::new()
    $previousEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        foreach ($item in @(& $hostExecutable @argList 2>&1)) {
            if ($item -is [Management.Automation.ErrorRecord]) {
                $stderr.Add([string]$item)
            }
            else {
                $stdout.Add([string]$item)
            }
        }
    }
    finally {
        $ErrorActionPreference = $previousEap
    }
    $code = $LASTEXITCODE
    if ($null -eq $code) {
        $code = 1
    }
    return [pscustomobject]@{
        ExitCode = [int]$code
        Stdout   = ($stdout -join "`n")
        Stderr   = ($stderr -join "`n")
    }
}

function New-NSTestProject {
    param([string]$Root, [switch]$WithPunchList)
    $null = New-Item -ItemType Directory -Path (Join-Path $Root '.nightshift') -Force
    Copy-Item -LiteralPath $template -Destination (Join-Path $Root '.nightshift/rules.json')
    if ($WithPunchList) {
        Copy-Item -LiteralPath $punchListTemplate -Destination (Join-Path $Root '.nightshift/punch-list.md')
    }
}

function Get-NSGatesBlockText {
    param([string]$PunchListPath)
    $lines = @(Get-Content -LiteralPath $PunchListPath)
    $gatesIdx = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -eq '## Gates') { $gatesIdx = $i; break }
    }
    if ($gatesIdx -lt 0) { return '' }
    $nextIdx = $lines.Count
    for ($i = $gatesIdx + 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -like '## *') { $nextIdx = $i; break }
    }
    return ($lines[$gatesIdx..($nextIdx)] -join "`n")
}

# --- armed refuse (v1 profile, unchanged behaviour) -------------------------------------------
$root = Join-Path ([IO.Path]::GetTempPath()) ("ns-apply-profile-logic-" + [guid]::NewGuid().ToString('N'))
try {
    New-NSTestProject $root
    [IO.File]::WriteAllText((Join-Path $root '.nightshift/.shift-armed'), '')
    $before = Get-FileHash -LiteralPath (Join-Path $root '.nightshift/rules.json') -Algorithm SHA256
    $refused = Invoke-ApplyProfile $root -Apply
    Expect-True ($refused.ExitCode -eq 2) "armed apply exits 2 (got $($refused.ExitCode) $($refused.Stderr))"
    Expect-True ($refused.Stderr -match 'refuse to write rules while the shift is armed') `
        "armed refuse names the armed marker: $($refused.Stderr)"
    $after = Get-FileHash -LiteralPath (Join-Path $root '.nightshift/rules.json') -Algorithm SHA256
    Expect-True ($after.Hash -eq $before.Hash) 'armed refuse writes no rules.json'
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

# --- v2 preview writes nothing ------------------------------------------------------------------
$previewRoot = Join-Path ([IO.Path]::GetTempPath()) ("ns-apply-profile-preview-" + [guid]::NewGuid().ToString('N'))
try {
    New-NSTestProject $previewRoot -WithPunchList
    $preview = Invoke-ApplyProfile $previewRoot -ProfileName 'fast'
    Expect-True ($preview.ExitCode -eq 0) "fast preview exits 0 (got $($preview.ExitCode) $($preview.Stderr))"
    Expect-True ($preview.Stdout -match 'Proposed shift-defaults\.json') 'preview shows proposed shift-defaults.json'
    Expect-True ($preview.Stdout -match 'Proposed ## Gates block') 'preview shows the proposed Gates block'
    Expect-True (-not (Test-Path (Join-Path $previewRoot '.nightshift/shift-defaults.json'))) `
        'preview writes no shift-defaults.json'
    $plText = Get-Content -LiteralPath (Join-Path $previewRoot '.nightshift/punch-list.md') -Raw
    Expect-True ($plText -match '_None configured\._') 'preview leaves the Gates placeholder untouched'
}
finally {
    Remove-Item -LiteralPath $previewRoot -Recurse -Force -ErrorAction SilentlyContinue
}

# --- apply fast, then strict: shift-defaults.json merges, Gates stays untouched ------------------
$mergeRoot = Join-Path ([IO.Path]::GetTempPath()) ("ns-apply-profile-merge-" + [guid]::NewGuid().ToString('N'))
try {
    New-NSTestProject $mergeRoot -WithPunchList
    $fastRun = Invoke-ApplyProfile $mergeRoot -ProfileName 'fast' -Apply
    Expect-True ($fastRun.ExitCode -eq 0) "apply fast exits 0 (got $($fastRun.ExitCode) $($fastRun.Stderr))"
    $defaultsPath = Join-Path $mergeRoot '.nightshift/shift-defaults.json'
    $fastDefaults = Get-Content -LiteralPath $defaultsPath -Raw | ConvertFrom-Json
    Expect-True ($fastDefaults.verificationProfile -eq 'fast') 'fast sets verificationProfile fast'
    Expect-True ($fastDefaults.toolingPolicy -eq 'existing-tools') 'fast sets toolingPolicy existing-tools'
    Expect-True ($fastDefaults.execution -eq 'run-direct') 'fast sets execution run-direct'
    $gatesAfterFast = Get-NSGatesBlockText (Join-Path $mergeRoot '.nightshift/punch-list.md')
    Expect-True ($gatesAfterFast -match '_None configured\._') 'fast writes the empty Gates placeholder'

    $punchHashBefore = (Get-FileHash -LiteralPath (Join-Path $mergeRoot '.nightshift/punch-list.md') -Algorithm SHA256).Hash
    $strictRun = Invoke-ApplyProfile $mergeRoot -ProfileName 'strict' -Apply
    Expect-True ($strictRun.ExitCode -eq 0) "apply strict exits 0 (got $($strictRun.ExitCode) $($strictRun.Stderr))"
    $strictDefaults = Get-Content -LiteralPath $defaultsPath -Raw | ConvertFrom-Json
    Expect-True ($strictDefaults.verificationProfile -eq 'strict') 'strict changes verificationProfile to strict'
    Expect-True ($strictDefaults.toolingPolicy -eq 'existing-tools') 'strict preserves toolingPolicy from fast'
    Expect-True ($strictDefaults.execution -eq 'run-direct') 'strict preserves execution from fast'
    $punchHashAfter = (Get-FileHash -LiteralPath (Join-Path $mergeRoot '.nightshift/punch-list.md') -Algorithm SHA256).Hash
    Expect-True ($punchHashBefore -eq $punchHashAfter) 'strict (gates: null) leaves punch-list.md untouched'

    $rulesHashBefore = (Get-FileHash -LiteralPath (Join-Path $mergeRoot '.nightshift/rules.json') -Algorithm SHA256).Hash
    $defaultsHashBefore = (Get-FileHash -LiteralPath $defaultsPath -Algorithm SHA256).Hash
    $noPushRun = Invoke-ApplyProfile $mergeRoot -ProfileName 'no-push' -ModeName 'replace' -Apply
    Expect-True ($noPushRun.ExitCode -eq 0) "apply no-push exits 0 (got $($noPushRun.ExitCode) $($noPushRun.Stderr))"
    $rulesAfter = Get-Content -LiteralPath (Join-Path $mergeRoot '.nightshift/rules.json') -Raw | ConvertFrom-Json
    Expect-True ($rulesAfter.forbiddenCommands -eq 'git .*push') 'v1 no-push (replace) sets forbiddenCommands'
    $rulesHashAfter = (Get-FileHash -LiteralPath (Join-Path $mergeRoot '.nightshift/rules.json') -Algorithm SHA256).Hash
    Expect-True ($rulesHashBefore -ne $rulesHashAfter) 'v1 apply changes rules.json'
    $defaultsHashAfter = (Get-FileHash -LiteralPath $defaultsPath -Algorithm SHA256).Hash
    Expect-True ($defaultsHashBefore -eq $defaultsHashAfter) 'v1 apply leaves shift-defaults.json untouched'
}
finally {
    Remove-Item -LiteralPath $mergeRoot -Recurse -Force -ErrorAction SilentlyContinue
}

# --- a v2 profile with a non-null gates refuses without a punch list -----------------------------
$noPunchRoot = Join-Path ([IO.Path]::GetTempPath()) ("ns-apply-profile-nopunch-" + [guid]::NewGuid().ToString('N'))
try {
    New-NSTestProject $noPunchRoot
    $refusedNoPunch = Invoke-ApplyProfile $noPunchRoot -ProfileName 'fast' -Apply
    Expect-True ($refusedNoPunch.ExitCode -eq 2) "fast apply without punch-list.md exits 2 (got $($refusedNoPunch.ExitCode))"
    Expect-True ($refusedNoPunch.Stderr -match 'punch-list\.md') 'refusal names punch-list.md'
}
finally {
    Remove-Item -LiteralPath $noPunchRoot -Recurse -Force -ErrorAction SilentlyContinue
}

# --- gates rendering: item gate + site inspection, and item gate alone (siteInspection absent) ---
$renderRoot = Join-Path ([IO.Path]::GetTempPath()) ("ns-apply-profile-render-" + [guid]::NewGuid().ToString('N'))
try {
    $pluginCopy = Join-Path $renderRoot 'plugincopy'
    Copy-Item -LiteralPath (Join-Path $repository 'plugins') (Join-Path $pluginCopy 'plugins') -Recurse
    $profilesDir = Join-Path $pluginCopy 'plugins/nightshift/skills/nightshift/references/profiles'
    $copiedHelper = Join-Path $pluginCopy 'plugins/nightshift/runtime/windows/apply-profile.ps1'

    @'
{
  "name": "probe",
  "version": 2,
  "risk": "low",
  "use": "test",
  "rules": {},
  "shiftDefaults": null,
  "gates": {
    "itemGate": ["eslint .", "tsc --noEmit"],
    "siteInspection": { "every": "5 items", "commands": ["knip"] }
  }
}
'@ | Set-Content -NoNewline (Join-Path $profilesDir 'probe.json')

    $proj = Join-Path $renderRoot 'proj'
    New-NSTestProject $proj -WithPunchList
    $probeRun = Invoke-ApplyProfile $proj -Helper $copiedHelper -ProfileName 'probe' -Apply
    Expect-True ($probeRun.ExitCode -eq 0) "probe apply exits 0 (got $($probeRun.ExitCode) $($probeRun.Stderr))"
    $gates = Get-NSGatesBlockText (Join-Path $proj '.nightshift/punch-list.md')
    Expect-True ($gates -match [regex]::Escape('`eslint .`')) 'probe renders the first item gate command'
    Expect-True ($gates -match [regex]::Escape('`tsc --noEmit`')) 'probe renders the second item gate command'
    Expect-True ($gates -match [regex]::Escape('**Site inspection**')) 'probe renders the site-inspection heading'
    Expect-True ($gates -match 'every 5 items') 'probe renders the site-inspection interval'
    Expect-True ($gates -match [regex]::Escape('`knip`')) 'probe renders the site-inspection command'

    @'
{
  "name": "probe2",
  "version": 2,
  "risk": "low",
  "use": "test",
  "rules": {},
  "shiftDefaults": null,
  "gates": { "itemGate": ["eslint ."] }
}
'@ | Set-Content -NoNewline (Join-Path $profilesDir 'probe2.json')
    $probe2Run = Invoke-ApplyProfile $proj -Helper $copiedHelper -ProfileName 'probe2' -Apply
    Expect-True ($probe2Run.ExitCode -eq 0) "probe2 apply exits 0 (got $($probe2Run.ExitCode) $($probe2Run.Stderr))"
    $gates2 = Get-NSGatesBlockText (Join-Path $proj '.nightshift/punch-list.md')
    Expect-True ($gates2 -match [regex]::Escape('`eslint .`')) 'probe2 renders its item gate command'
    Expect-True (-not ($gates2 -match [regex]::Escape('**Site inspection**'))) `
        'probe2 (no siteInspection key) omits the site-inspection sentence'
}
finally {
    Remove-Item -LiteralPath $renderRoot -Recurse -Force -ErrorAction SilentlyContinue
}

# --- malformed v2 shiftDefaults / gates are refused before any write -----------------------------
$badRoot = Join-Path ([IO.Path]::GetTempPath()) ("ns-apply-profile-bad-" + [guid]::NewGuid().ToString('N'))
try {
    $pluginCopy = Join-Path $badRoot 'plugincopy'
    Copy-Item -LiteralPath (Join-Path $repository 'plugins') (Join-Path $pluginCopy 'plugins') -Recurse
    $profilesDir = Join-Path $pluginCopy 'plugins/nightshift/skills/nightshift/references/profiles'
    $copiedHelper = Join-Path $pluginCopy 'plugins/nightshift/runtime/windows/apply-profile.ps1'

    @'
{
  "name": "bad-sd", "version": 2, "risk": "low", "use": "t", "rules": {},
  "shiftDefaults": { "verificationProfile": "nope" }, "gates": null
}
'@ | Set-Content -NoNewline (Join-Path $profilesDir 'bad-sd.json')
    @'
{
  "name": "bad-gates", "version": 2, "risk": "low", "use": "t", "rules": {},
  "shiftDefaults": null,
  "gates": { "itemGate": ["x"], "siteInspection": { "every": "abc", "commands": [] } }
}
'@ | Set-Content -NoNewline (Join-Path $profilesDir 'bad-gates.json')

    $proj = Join-Path $badRoot 'proj'
    New-NSTestProject $proj -WithPunchList
    $badSdRun = Invoke-ApplyProfile $proj -Helper $copiedHelper -ProfileName 'bad-sd'
    Expect-True ($badSdRun.ExitCode -eq 2) "bad-sd preview exits 2 (got $($badSdRun.ExitCode))"
    Expect-True ($badSdRun.Stderr -match 'verificationProfile') 'bad-sd names verificationProfile'
    Expect-True (-not (Test-Path (Join-Path $proj '.nightshift/shift-defaults.json'))) 'bad-sd writes nothing'

    $badGatesRun = Invoke-ApplyProfile $proj -Helper $copiedHelper -ProfileName 'bad-gates'
    Expect-True ($badGatesRun.ExitCode -eq 2) "bad-gates preview exits 2 (got $($badGatesRun.ExitCode))"
    Expect-True ($badGatesRun.Stderr -match 'siteInspection\.every') 'bad-gates names siteInspection.every'
}
finally {
    Remove-Item -LiteralPath $badRoot -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures.Count -gt 0) {
    Write-Host "apply-profile-logic failed ($($failures.Count)):"
    foreach ($failure in $failures) { Write-Host " - $failure" }
    exit 1
}
Write-Host 'apply-profile-logic ok'
exit 0
