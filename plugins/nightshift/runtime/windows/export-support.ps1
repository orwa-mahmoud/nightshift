param(
    [string]$Project = [Environment]::CurrentDirectory
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$pluginRoot = Resolve-Path (Join-Path $PSScriptRoot '../..')
Import-Module (Join-Path $pluginRoot 'lib/Nightshift.psm1') -Force -DisableNameChecking

try {
    $hostPath = Resolve-NSCanonicalPath $Project
}
catch {
    [Console]::Error.WriteLine("export-support: cannot cd to $Project")
    exit 1
}

$linkState = 'absent'
try {
    $workspace = Resolve-NSWorkspaceRoot $hostPath
    $link = Join-Path $hostPath '.nightshift-link'
    if (Test-NSPathEntry $link) {
        $linkState = 'valid'
    }
}
catch {
    [Console]::Error.WriteLine('export-support: invalid .nightshift-link - Nightshift will not guess a workspace')
    exit 2
}

$ns = Join-Path $workspace '.nightshift'
if (-not (Test-Path -LiteralPath $ns -PathType Container)) {
    [Console]::Error.WriteLine("export-support: no .nightshift/ at $workspace")
    exit 2
}

$homeRoot = ''
if (-not [string]::IsNullOrEmpty($env:USERPROFILE)) {
    try { $homeRoot = Resolve-NSCanonicalPath $env:USERPROFILE } catch { $homeRoot = '' }
}
elseif (-not [string]::IsNullOrEmpty($env:HOME)) {
    try { $homeRoot = Resolve-NSCanonicalPath $env:HOME } catch { $homeRoot = '' }
}

$target = ''
try {
    $resolved = Resolve-NSWorkTarget $workspace
    if (-not [string]::IsNullOrEmpty($resolved)) {
        $target = Resolve-NSCanonicalPath $resolved
    }
}
catch {
    $target = ''
}

$pluginJson = Join-Path $pluginRoot '.claude-plugin/plugin.json'
$pluginVer = 'unknown'
$pluginName = 'nightshift'
if (Test-Path -LiteralPath $pluginJson -PathType Leaf) {
    try {
        $manifest = Get-Content -LiteralPath $pluginJson -Raw | ConvertFrom-Json -ErrorAction Stop
        if ($null -ne $manifest.PSObject.Properties['version'] -and -not [string]::IsNullOrEmpty([string]$manifest.version)) {
            $pluginVer = [string]$manifest.version
        }
        if ($null -ne $manifest.PSObject.Properties['name'] -and -not [string]::IsNullOrEmpty([string]$manifest.name)) {
            $pluginName = [string]$manifest.name
        }
    }
    catch {
    }
}

$stateKind = Get-NSStateKind $workspace
$stateVer = Get-NSStateVersion $workspace
if ($stateKind -notin @('current', 'legacy')) {
    $stateVer = ''
}

$rulesPath = Get-NSLayoutPath $ns 'rules'
$rulesState = 'missing'
$rulesKeys = ''
if (-not (Test-Path -LiteralPath $rulesPath -PathType Leaf)) {
    $rulesState = 'missing'
}
else {
    $rules = Get-NSRulesObject $workspace
    if ($null -eq $rules) {
        $rulesState = 'unreadable'
    }
    else {
        $rulesState = 'valid'
        $rulesKeys = (($rules.PSObject.Properties | ForEach-Object { $_.Name }) -join ' ')
    }
}

# The resolved view, never the policy files themselves. Owner free-form text and
# any value over 80 characters ship as their length: the bundle carries where a
# setting came from and when it expires, never what the owner wrote.
# Known sensitive fields are omitted. This is not a complete sanitization.
$policyFreeForm = @('forbiddenCommands', 'protectedDirs', 'neverCommitPatterns', 'expectedEmail')
$policyLines = New-Object Collections.Generic.List[string]
$policyState = 'unreadable'
try {
    $resolution = Get-NSPolicyResolution $workspace
    $policyState = [string]$resolution['policyState']
    $policySettings = $resolution['settings']
    foreach ($policyName in (Sort-NSOrdinal (@($policySettings.Keys)))) {
        $policyEntry = $policySettings[$policyName]
        $policyValue = Format-NSPolicyValue $policyEntry['value']
        if ($policyValue.Length -gt 0 -and (($policyFreeForm -ccontains $policyName) -or $policyValue.Length -gt 80)) {
            $policyValue = '<redacted ' + $policyValue.Length + ' chars>'
        }
        $null = $policyLines.Add(('{0}={1} ({2}, {3})' -f $policyName, $policyValue, $policyEntry['source'], $policyEntry['expiry']))
    }
}
catch {
    $policyLines.Clear()
}

$reason = Get-NSReasonCode $ns
$reasonLabel = ''
if (-not [string]::IsNullOrEmpty($reason)) {
    $reasonLabel = Get-NSReasonLabel $reason
}

$leaseState = 'absent'
$leaseHost = ''
$leaseGeneration = ''
$leaseMode = ''
$leasePath = Get-NSLayoutPath $ns 'lease'
if (Test-NSPathEntry $leasePath) {
    $lease = Read-NSLease $ns
    if ($null -ne $lease) {
        $leaseState = 'valid'
        $leaseHost = [string]$lease.HostName
        $leaseGeneration = [string]$lease.Generation
        $leaseMode = if (-not [string]::IsNullOrEmpty([string]$lease.Nonce)) { 'recovered' } else { 'interactive' }
    }
    else {
        $leaseState = 'malformed'
    }
}

$stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
$outdir = Get-NSLayoutPath $ns 'support'
try {
    $null = New-Item -ItemType Directory -Path $outdir -Force
}
catch {
    [Console]::Error.WriteLine("export-support: cannot create $outdir")
    exit 2
}
$tmp = Join-Path $outdir ".$stamp.$PID"
$dest = Join-Path $outdir "$stamp.txt"

function Format-NSIdentity {
    param([string]$Value, [string]$Label)
    if ([string]::IsNullOrEmpty($Value)) {
        return "${Label}: omitted"
    }
    $token = Convert-NSTokenizedText $Value $homeRoot $workspace $target
    if ($null -eq $token) {
        return "${Label}: omitted"
    }
    return "${Label}: $token"
}

$lines = New-Object Collections.Generic.List[string]
$null = $lines.Add('Nightshift support bundle')
$null = $lines.Add("Generated: $stamp")
$null = $lines.Add('')
$null = $lines.Add('== plugin ==')
$null = $lines.Add("name: $pluginName")
$null = $lines.Add("version: $pluginVer")
$null = $lines.Add('')
$null = $lines.Add('== host ==')
$null = $lines.Add("uname: $([Environment]::OSVersion.Platform)")
$null = $lines.Add("link: $linkState")
$null = $lines.Add('')
$null = $lines.Add('== state ==')
$null = $lines.Add("kind: $stateKind")
if (-not [string]::IsNullOrEmpty($stateVer)) {
    $null = $lines.Add("version: $stateVer")
}
$null = $lines.Add('')
$null = $lines.Add('== identities ==')
$null = $lines.Add((Format-NSIdentity $hostPath 'task'))
$null = $lines.Add((Format-NSIdentity $workspace 'workspace'))
if ([string]::IsNullOrEmpty($target)) {
    $null = $lines.Add('work_target: unresolved')
}
else {
    $null = $lines.Add((Format-NSIdentity $target 'work_target'))
}
$null = $lines.Add('')
$null = $lines.Add('== markers ==')
$armedPath = Get-NSLayoutPath $ns 'armed'
$armedLabel = if (Test-NSReparsePoint $armedPath) {
    'unusable'
}
elseif (Test-Path -LiteralPath $armedPath -PathType Leaf) {
    'yes'
}
else {
    'no'
}
$null = $lines.Add("armed: $armedLabel")
$endedPath = Get-NSLayoutPath $ns 'ended'
$endedLabel = if (Test-NSReparsePoint $endedPath) {
    'unusable'
}
elseif (Test-Path -LiteralPath $endedPath -PathType Leaf) {
    'yes'
}
else {
    'no'
}
$null = $lines.Add("ended: $endedLabel")
$null = $lines.Add(('stop: {0}' -f $(if (Test-Path -LiteralPath (Get-NSLayoutPath $ns 'stop') -PathType Leaf) { 'yes' } else { 'no' })))
$sessionEndPath = Get-NSLayoutPath $ns 'session-end'
$sessionEndLabel = if (Test-NSReparsePoint $sessionEndPath) {
    'unusable'
}
elseif (Test-Path -LiteralPath $sessionEndPath -PathType Leaf) {
    'yes'
}
else {
    'no'
}
$null = $lines.Add("session_end: $sessionEndLabel")
$pulsePath = Get-NSLayoutPath $ns 'pulse'
$pulseLabel = if (Test-NSReparsePoint $pulsePath) {
    'unusable'
}
elseif (Test-Path -LiteralPath $pulsePath -PathType Leaf) {
    'yes'
}
else {
    'no'
}
$null = $lines.Add("shift_pulse: $pulseLabel")
$sessionPath = Get-NSLayoutPath $ns 'session'
$sessionRecordLabel = if (Test-NSReparsePoint $sessionPath) {
    'unusable'
}
elseif (Test-Path -LiteralPath $sessionPath -PathType Leaf) {
    'present'
}
else {
    'absent'
}
$null = $lines.Add("session_record: $sessionRecordLabel")
$null = $lines.Add("process_lease: $leaseState")
if (-not [string]::IsNullOrEmpty($leaseHost)) { $lines.Add("lease_host: $leaseHost") }
if (-not [string]::IsNullOrEmpty($leaseGeneration)) { $lines.Add("lease_generation: $leaseGeneration") }
if (-not [string]::IsNullOrEmpty($leaseMode)) { $lines.Add("lease_mode: $leaseMode") }
$watchmanPath = Get-NSLayoutPath $ns 'watchman'
$watchmanPidfileLabel = if (Test-NSReparsePoint $watchmanPath) {
    'unusable'
}
elseif (Test-Path -LiteralPath $watchmanPath -PathType Leaf) {
    'present'
}
else {
    'absent'
}
$null = $lines.Add("watchman_pidfile: $watchmanPidfileLabel")
$null = $lines.Add('')
$null = $lines.Add('== rules ==')
$null = $lines.Add("validity: $rulesState")
$null = $lines.Add("keys: $rulesKeys")
$null = $lines.Add('')
$null = $lines.Add('== resolved policy ==')
$null = $lines.Add("shift_policy: $policyState")
foreach ($policyLine in $policyLines) {
    $null = $lines.Add($policyLine)
}
$null = $lines.Add('')
$null = $lines.Add('== evidence summary ==')
$null = $lines.Add((Get-NSEvidenceCountSummary $workspace))
$watchMinutes = 0
try {
    $watchMinutes = [int](Get-NSRule $workspace 'watchMinutes' '')
}
catch {
    $watchMinutes = 0
}
$null = $lines.Add(('liveness: {0}' -f (Get-NSStatusLiveness $workspace $watchMinutes)))
$activity = Get-NSStatusLastActivity $workspace
$null = $lines.Add(('last activity: {0}' -f $(if ($activity.Length -gt 0) { $activity } else { 'none' })))
$null = $lines.Add(('last checkpoint: {0}' -f (Get-NSGateCheckpointToken $workspace)))
$null = $lines.Add(('stall attempts: {0}' -f (Get-NSStatusStallAttempts $workspace)))
$invPath = Get-NSLayoutPath $ns 'capabilities'
if ((Test-Path -LiteralPath $invPath -PathType Leaf) -and -not (Test-NSReparsePoint $invPath)) {
    try {
        $invDoc = Get-Content -LiteralPath $invPath -Raw | ConvertFrom-Json -ErrorAction Stop
        $invCount = 0
        if ($null -ne $invDoc.PSObject.Properties['items'] -and $null -ne $invDoc.items) {
            $invCount = @($invDoc.items).Count
        }
        $null = $lines.Add("inventory items: $invCount")
    }
    catch {
        $null = $lines.Add('inventory items: omitted')
    }
}
else {
    $null = $lines.Add('inventory items: omitted')
}
$null = $lines.Add('')
$null = $lines.Add('== runtime log ==')
$null = $lines.Add('omitted')
$null = $lines.Add('')
$null = $lines.Add('== watchman reason ==')
if (-not [string]::IsNullOrEmpty($reason)) {
    $null = $lines.Add("code: $reason")
    $null = $lines.Add("label: $reasonLabel")
}
else {
    $null = $lines.Add('code: none')
}

try {
    $null = Write-NSAtomicLines -Path $tmp -Lines @($lines) -Private
    Move-Item -LiteralPath $tmp -Destination $dest -Force
}
catch {
    if (Test-Path -LiteralPath $tmp -PathType Leaf) {
        Remove-NSFile $tmp
    }
    [Console]::Error.WriteLine('export-support: failed to write bundle')
    exit 2
}

Write-Output "Support bundle: $dest"
Write-Output 'Included: plugin version, markers, the resolved policy view, counts'
Write-Output 'Omitted: scheduled.log, evidence ledger raw output, known sensitive fields, repository contents, diffs, transcripts, prompts, owner files, credentials, network, session identities, lease capabilities, capability inventory contents, policy files'
Write-Output 'Known sensitive fields are omitted. Inspect the file before sharing. Never uploaded, attached, or opened automatically.'
exit 0
