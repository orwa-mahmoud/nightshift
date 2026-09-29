# Write-NSReceiptsIndex <workspace> [-Remaining] - rewrite receipts/README.md from the list, marks
# and files. -Remaining writes the index a live receipts folder still needs, every open item and
# every ticked item whose receipt is still there, and removes it when nothing is left.
function Write-NSReceiptsIndex {
    param([Parameter(Mandatory = $true)][string]$Workspace, [switch]$Remaining)
    $dir = Get-NSReceiptsDir $Workspace
    if ([string]::IsNullOrEmpty($dir)) { return }
    if ($Remaining) {
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) { return }
    }
    else {
        try { $null = New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop } catch { return }
    }
    if (Test-NSReparsePoint $dir) { return }
    $index = Join-Path $dir 'README.md'
    if (Test-NSReparsePoint $index) { return }
    # Between shifts a receipt moves to the name its item carries now; while one is armed the names
    # hold still, so the model keeps writing the file it was given.
    if (-not (Test-Path -LiteralPath (Get-NSLayoutPath (Join-Path $Workspace '.nightshift') 'armed'))) {
        $null = Rename-NSReceipts $Workspace
    }
    $punch = Get-NSLayoutPath (Join-Path $Workspace '.nightshift') 'punch-list'
    $rows = New-Object Collections.Generic.List[string]
    $tin = [long]0; $tcw = [long]0; $tcr = [long]0; $tout = [long]0; $trea = [long]0
    $twork = [long]0; $tpause = [long]0
    $offUsage = $false; $offTime = $false
    if ((Test-Path -LiteralPath $punch -PathType Leaf) -and -not (Test-NSReparsePoint $punch)) {
        foreach ($row in (Get-NSItemRows $punch 'all')) {
            $state = $(if ($row.Open) { 'open' } else { 'ticked' })
            $label = $row.Label
            $base = Get-NSReceiptBase $Workspace $label $row.Id
            $file = './' + $base + '.md'
            $path = Join-Path $dir ($base + '.md')
            if ($Remaining -and $state -ceq 'ticked' -and
                -not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
            $cells = Get-NSReceiptUsageCells $path
            $tin += [long]$cells['In']; $tcw += [long]$cells['CacheWrite']; $tcr += [long]$cells['CacheRead']
            $tout += [long]$cells['Out']; $trea += [long]$cells['Reasoning']
            $twork += [long]$cells['Work']; $tpause += [long]$cells['Pause']
            if ($cells['Tokens'] -ceq 'off') { $offUsage = $true }
            if ($cells['Time'] -ceq 'off') { $offTime = $true }
            $rows.Add(('| {0} | {1} | **{2}** | **{3}** | [{4}]({4}) |' -f
                $label, $state, $cells['Tokens'], $cells['Time'], $file))
        }
    }
    if ($Remaining -and $rows.Count -eq 0) {
        Remove-Item -LiteralPath $index -Force -ErrorAction SilentlyContinue
        return
    }
    $utf8 = New-Object Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($index,
        (Get-NSReceiptsIndexPage -Date (Get-NSReceiptsShiftDate $Workspace) -Rows $rows.ToArray() `
            -UsageTotal (Get-NSIndexTotal (Get-NSReceiptsUsageTotalCell $tin $tcw $tcr $tout $trea) $offUsage) `
            -TimeTotal (Get-NSIndexTotal (Get-NSReceiptsTimeTotalCell $twork $tpause) $offTime) `
            -Morning (Get-NSReceiptsMorningNames $dir)), $utf8)
}

# Get-NSIndexTotal <cell> <any-off> - a totals cell: off when nothing was measured because a row's
# measurement was turned off, the cell as it stands otherwise.
function Get-NSIndexTotal {
    param([AllowEmptyString()][string]$Cell, [bool]$AnyOff)
    if ($AnyOff -and $Cell -ceq [string][char]0x2014) { return 'off' }
    return $Cell
}

function Get-NSReceiptsUsageTotalCell {
    param([long]$In, [long]$CacheWrite, [long]$CacheRead, [long]$Out, [long]$Reasoning)
    if (($In + $CacheWrite + $CacheRead + $Out + $Reasoning) -eq 0) {
        return [string][char]0x2014
    }
    return ($script:NSUsageTokensFormat -f
        (Get-NSUsageScale $In), (Get-NSUsageScale $CacheWrite),
        (Get-NSUsageScale $CacheRead), (Get-NSUsageScale $Out),
        (Get-NSUsageScale $Reasoning))
}

function Get-NSReceiptsTimeCell {
    param([long]$Work, [long]$Pause = 0)
    if ($Work -le 0 -and $Pause -le 0) { return [string][char]0x2014 }
    if ($Pause -gt 0) {
        return ((Get-NSUsageDuration ([string]$Work)) + (' working ' + $script:NSDot + ' ') +
            (Get-NSUsageDuration ([string]$Pause)) + ' paused')
    }
    return ((Get-NSUsageDuration ([string]$Work)) + ' working')
}

function Get-NSReceiptsTimeTotalCell {
    param([long]$Work, [long]$Pause = 0)
    return (Get-NSReceiptsTimeCell $Work $Pause)
}
# Get-NSUsageScale <n> - integer below 1000, then one decimal k, M, or B. Tenths are rounded half
# up on the exact integer, never through a binary fraction, so 1950 is 2.0k on every runtime; a
# value that rounds to 1000.0 of a unit reads as 1.0 of the next.
function Get-NSUsageScale {
    param($Value)
    $n = [long]0
    if (-not [long]::TryParse([string]$Value, [ref]$n) -or $n -lt 0) { return [string]$Value }
    if ($n -lt 1000) { return [string]$n }
    $units = [long[]]@(1000, 1000000, 1000000000)
    $suffixes = @('k', 'M', 'B')
    $i = 0
    while ($i -lt 2 -and $n -ge $units[$i + 1]) { $i++ }
    $tenths = [long][math]::Floor(([decimal]$n * 10 + $units[$i] / 2) / $units[$i])
    if ($tenths -ge 10000 -and $i -lt 2) {
        $i++
        $tenths = [long][math]::Floor(([decimal]$n * 10 + $units[$i] / 2) / $units[$i])
    }
    return ('{0}.{1}{2}' -f [long][math]::Floor([decimal]$tenths / 10), ($tenths % 10), $suffixes[$i])
}

# Get-NSReportPath kept as the receipts folder path only for callers not yet moved.
function Get-NSReportPath {
    param([Parameter(Mandatory = $true)][string]$Workspace)
    return (Get-NSReceiptsDir $Workspace)
}

# Get-NSPolicyHostName - which host this session is, from what the host itself sets.
function Get-NSPolicyHostName {
    if (-not [string]::IsNullOrEmpty($env:CURSOR_PLUGIN_ROOT)) { return 'cursor' }
    if (-not [string]::IsNullOrEmpty($env:CODEX_PROJECT_DIR) -or
        -not [string]::IsNullOrEmpty($env:CODEX_SANDBOX) -or
        -not [string]::IsNullOrEmpty($env:CODEX_SANDBOX_MODE)) { return 'codex' }
    if (-not [string]::IsNullOrEmpty($env:CLAUDE_PLUGIN_ROOT) -or
        -not [string]::IsNullOrEmpty($env:CLAUDE_PROJECT_DIR)) { return 'claude' }
    return 'unknown'
}

# Test-NSLaunchScopeSupported <host> <scope> - true when the host can actually be asked to start
# a session at that scope. Nothing outside this vocabulary reaches a native flag.
function Test-NSLaunchScopeSupported {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$HostName,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Scope
    )
    if ($HostName -ceq 'codex') {
        return @('read-only', 'workspace-write', 'danger-full-access') -ccontains $Scope
    }
    if ($HostName -ceq 'claude') {
        return @('dangerously-skip-permissions', 'bypass-permissions') -ccontains $Scope
    }
    return $false
}

function Test-NSLaunchScopeElevated {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Scope)
    return @(
        'danger-full-access',
        'workspace-write',
        'dangerously-skip-permissions',
        'bypass-permissions',
        'bypassPermissions'
    ) -ccontains $Scope
}

# Get-NSLaunchObserved <host> - the scope this session runs under in the host's own words, and
# whether the host actually said so, joined by a tab. Only Codex names a session's sandbox.
# Claude Code and Cursor expose no name for one anywhere a hook can read it, so there is nothing
# to observe and this reports that rather than inventing a label for it.
function Get-NSLaunchObserved {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$HostName)
    if ($HostName -ceq 'codex') {
        if (-not [string]::IsNullOrEmpty($env:CODEX_SANDBOX_MODE)) {
            return ($env:CODEX_SANDBOX_MODE + "`tobserved")
        }
        if (-not [string]::IsNullOrEmpty($env:CODEX_SANDBOX)) {
            return ($env:CODEX_SANDBOX + "`tobserved")
        }
    }
    if (($HostName -ceq 'claude' -or $HostName -ceq 'cursor') -and
        -not [string]::IsNullOrEmpty([string]$env:CLAUDE_PROJECT_DIR + [string]$env:CLAUDE_PLUGIN_ROOT + [string]$env:CURSOR_PLUGIN_ROOT)) {
        $pid = $PID
        for ($hops = 0; $hops -lt 16 -and $null -ne $pid -and $pid -gt 1; $hops++) {
            try {
                $proc = Get-Process -Id $pid -ErrorAction Stop
                $cmd = [string]$proc.CommandLine
                if ([string]::IsNullOrEmpty($cmd)) {
                    try {
                        $cmd = (Get-CimInstance Win32_Process -Filter "ProcessId=$pid" -ErrorAction Stop).CommandLine
                    }
                    catch {
                        $cmd = ''
                    }
                }
                if ($cmd -match 'dangerously-skip-permissions|bypass-permissions') {
                    return "dangerously-skip-permissions`tobserved"
                }
                $pid = $proc.Parent.Id
            }
            catch {
                break
            }
        }
    }
    return "unknown`tunavailable"
}

# Get-NSRecoveryEffectiveScope <workspace> <host> - what a revival may actually ask for. The same
# four answers as the POSIX resolver, decided the same way:
#
#   host-default             the owner asked for it by name. No permission argument is passed.
#   host-grant               the owner wrote it by name.
#   recorded:<scope>         a scope the host observed and can be asked for again.
#   unavailable:unrecorded   nothing was recorded to inherit.
#   unavailable:unreadable   the policy that would have recorded it cannot be read.
#   unavailable:unsupported:<scope>
#                            a recorded scope this host has no way to request.
#
# The three unavailable answers are refusals. Inheriting means reproducing what the session had;
# where that cannot be established, falling back to the host's default is a guess about
# permissions rather than a narrowing, so the caller refuses and says what the owner can do.
function Get-NSRecoveryEffectiveScope {
    param(
        [Parameter(Mandatory = $true)][string]$Workspace,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$HostName
    )
    $configured = Get-NSRecoveryLaunchScope $Workspace
    if ($configured -ceq 'host-grant') { return 'host-grant' }
    if ($configured -ceq 'host-default') {
        $policyState = (Get-NSShiftPolicyState $Workspace)['state']
        if ($policyState -ceq 'valid') {
            $recorded = Get-NSPolicyLaunch -Workspace $Workspace -Field 'scope'
            $provenance = Get-NSPolicyLaunch -Workspace $Workspace -Field 'provenance'
            if ($provenance -ceq 'observed' -and (Test-NSLaunchScopeElevated $recorded)) {
                return ('unavailable:narrower:' + $recorded)
            }
        }
        return 'host-default'
    }
    $policyState = (Get-NSShiftPolicyState $Workspace)['state']
    if ($policyState -ceq 'absent') { return 'unavailable:unrecorded' }
    if ($policyState -cne 'valid') { return 'unavailable:unreadable' }
    $recorded = Get-NSPolicyLaunch -Workspace $Workspace -Field 'scope'
    $provenance = Get-NSPolicyLaunch -Workspace $Workspace -Field 'provenance'
    if ($provenance -ceq 'observed' -and -not [string]::IsNullOrEmpty($recorded) -and $recorded -cne 'unknown') {
        if (Test-NSLaunchScopeSupported $HostName $recorded) { return ('recorded:' + $recorded) }
        return ('unavailable:unsupported:' + $recorded)
    }
    return 'unavailable:unrecorded'
}

# Get-NSRecoveryRefusal <effective-scope> - the one sentence that says why a revival is refused.
# Empty for a scope that is not a refusal.
function Get-NSRecoveryRefusal {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Scope)
    if ($Scope -ceq 'unavailable:unrecorded') {
        return 'the host named no scope for the session this shift was started in, so there is nothing to inherit and no way to show a revival would be no broader'
    }
    if ($Scope -ceq 'unavailable:unreadable') {
        return 'the policy that records the launch scope cannot be read, so what this shift was started under is unknown'
    }
    if ($Scope -clike 'unavailable:unsupported:*') {
        return ("the shift was started under '" + $Scope.Substring('unavailable:unsupported:'.Length) + "', which this host has no way to be asked for again")
    }
    if ($Scope -clike 'unavailable:narrower:*') {
        return ("the shift was started under '" + $Scope.Substring('unavailable:narrower:'.Length) + "', so a host-default revival would be too narrow")
    }
    return ''
}

# Get-NSPolicyLaunch <workspace> <scope|provenance> - what the snapshot recorded about the scope
# the shift was started under. A field the snapshot never carried is empty, never a guess.
function Get-NSPolicyLaunch {
    param(
        [Parameter(Mandatory = $true)][string]$Workspace,
        [Parameter(Mandatory = $true)][ValidateSet('scope', 'provenance')][string]$Field
    )
    $path = (Get-NSPolicyPaths $Workspace)['policy']
    if ((Test-NSReparsePoint $path) -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { return '' }
    $document = $null
    try {
        $document = ConvertFrom-NSJsonText ([IO.File]::ReadAllText($path, $script:NSUtf8NoBom))
    }
    catch {
        return ''
    }
    if (-not ($document -is [Collections.IDictionary])) { return '' }
    $key = 'launchScope'
    if ($Field -ceq 'provenance') { $key = 'launchProvenance' }
    $value = Get-NSMapValue $document $key
    if ($value -is [string]) { return $value }
    return ''
}

function Get-NSShiftBlock {
    param([Parameter(Mandatory = $true)][string]$Workspace)
    $path = (Get-NSPolicyPaths $Workspace)['rules']
    if ((Test-NSReparsePoint $path) -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    $document = $null
    try {
        $document = ConvertFrom-NSJsonText ([IO.File]::ReadAllText($path, $script:NSUtf8NoBom))
    }
    catch {
        return $null
    }
    if (-not ($document -is [Collections.IDictionary])) { return $null }
    if (-not $document.Contains('shift')) { return $null }
    $block = $document['shift']
    if (-not ($block -is [Collections.IDictionary])) { return $null }
    return $block
}

# Set-NSShiftBlock <workspace> <block> - the owner file with its shift block replaced. Every other
# key survives, including one a later version added.
function Set-NSShiftBlock {
    param(
        [Parameter(Mandatory = $true)][string]$Workspace,
        [Parameter(Mandatory = $true)]$Block
    )
    $path = (Get-NSPolicyPaths $Workspace)['rules']
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        Write-NSPolicyError ('shift-policy: no owner rules file at ' + $path + ' - run setup first')
        return 2
    }
    $document = $null
    try {
        $document = ConvertFrom-NSJsonText ([IO.File]::ReadAllText($path, $script:NSUtf8NoBom))
    }
    catch {
        Write-NSPolicyError ('shift-policy: ' + $path + ' is not readable')
        return 2
    }
    if (-not ($document -is [Collections.IDictionary])) {
        Write-NSPolicyError ('shift-policy: ' + $path + ' is not a JSON object')
        return 2
    }
    $document['shift'] = $Block
    Write-NSEvidenceFileAtomic -Path $path -Text ((ConvertTo-NSCanonicalJson $document) + "`n")
    return 0
}

function Set-NSShiftDefaults {
    param(
        [Parameter(Mandatory = $true)][string]$Workspace,
        [AllowEmptyString()][string]$VerificationProfile = '',
        [AllowEmptyString()][string]$Hours = '',
        [AllowEmptyString()][string]$ToolingPolicy = '',
        [AllowEmptyString()][string]$Execution = ''
    )
    $paths = Get-NSPolicyPaths $Workspace
    if (-not (Test-Path -LiteralPath $paths['ns'] -PathType Container)) {
        Write-NSPolicyError ('shift-policy: no .nightshift/ at ' + $Workspace)
        return 2
    }
    if (Test-NSPolicyArmed $Workspace) {
        Write-NSPolicyError 'shift-policy: refuse to rewrite the shift defaults while the shift is armed; park the need'
        return 4
    }
    $document = Get-NSShiftDefaults $Workspace
    if (-not [string]::IsNullOrEmpty($VerificationProfile)) {
        if (-not (Test-NSEvidenceEnum $VerificationProfile $script:NSPolicyProfiles)) {
            Write-NSPolicyError ('shift-policy: verificationProfile: must be one of ' + ($script:NSPolicyProfiles -join ', '))
            return 2
        }
        $document['verificationProfile'] = $VerificationProfile
    }
    if (-not [string]::IsNullOrEmpty($ToolingPolicy)) {
        if (-not (Test-NSEvidenceEnum $ToolingPolicy $script:NSPolicyToolingPolicies)) {
            Write-NSPolicyError ('shift-policy: toolingPolicy: must be one of ' + ($script:NSPolicyToolingPolicies -join ', '))
            return 2
        }
        $document['toolingPolicy'] = $ToolingPolicy
    }
    if (-not [string]::IsNullOrEmpty($Execution)) {
        if (-not (Test-NSEvidenceEnum $Execution $script:NSPolicyExecutions)) {
            Write-NSPolicyError ('shift-policy: execution: must be one of ' + ($script:NSPolicyExecutions -join ', '))
            return 2
        }
        $document['execution'] = $Execution
    }
    if (-not [string]::IsNullOrEmpty($Hours)) {
        if ($Hours -ceq 'null') {
            $document['hours'] = $null
        }
        elseif ($Hours -cmatch '^[0-9]+$') {
            $document['hours'] = [long]$Hours
        }
        else {
            Write-NSPolicyError 'shift-policy: hours: must be a whole number of hours or null'
            return 2
        }
    }
    # These live in the shift block of the owner file, which is the one place a preference is
    # kept. Writing them anywhere else would leave the value that is read and the value that was
    # set in two files that can disagree.
    $block = New-NSOrdinalMap
    $block['verificationProfile'] = $document['verificationProfile']
    $block['hours'] = $document['hours']
    $block['execution'] = $document['execution']
    $block['toolingPolicy'] = $document['toolingPolicy']
    $rc = Set-NSShiftBlock -Workspace $Workspace -Block $block
    if ($rc -eq 0) { Write-NSPolicyOut (Get-NSPolicyPaths $Workspace)['rules'] }
    return $rc
}

# ---------------------------------------------------------------------------
# The resolver
# ---------------------------------------------------------------------------

function New-NSPolicySetting {
    param($Value, [Parameter(Mandatory = $true)][string]$Source, [Parameter(Mandatory = $true)][string]$Expiry)
    $entry = New-NSOrdinalMap
    $entry['value'] = $Value
    $entry['source'] = $Source
    $entry['expiry'] = $Expiry
    return $entry
}

# A key the owner wrote is an owner decision even when its value is empty, so
# presence - not emptiness - decides the source.
function Test-NSRuleKeyPresent {
    param(
        [Parameter(Mandatory = $true)][string]$Workspace,
        [Parameter(Mandatory = $true)][string]$Key
    )
    $rules = Get-NSRulesObject $Workspace
    if ($null -eq $rules) { return $false }
    return ($null -ne $rules.PSObject.Properties[$Key])
}

function Get-NSPolicyRuleSetting {
    param(
        [Parameter(Mandatory = $true)][string]$Workspace,
        [Parameter(Mandatory = $true)][string]$Key
    )
    $value = Get-NSRule $Workspace $Key ''
    if (Test-NSRuleKeyPresent $Workspace $Key) { return (New-NSPolicySetting $value 'rules' 'permanent') }
    return (New-NSPolicySetting $value 'built-in' '-')
}

# A dotted preference like report.progressMode: the owner's block if they wrote the key, the
# shipped default otherwise. Presence decides the source, so a key written as an empty string is
# still an owner decision.
function Get-NSPolicyGroupSetting {
    param(
        [Parameter(Mandatory = $true)][string]$Workspace,
        [Parameter(Mandatory = $true)][string]$Name
    )
    $fallback = $script:NSPolicyGroupDefaults[$Name]
    $block = $Name.Substring(0, $Name.IndexOf('.'))
    $key = $Name.Substring($Name.IndexOf('.') + 1)

    # A preference tonight's policy froze is what tonight uses, whatever the owner has since
    # written, and the view says so. A snapshot that cannot be read answers with the shipped
    # default rather than the mutable file it was supposed to fix; one written before this
    # feature carries no block, and then the owner's file is the source.
    $state = Get-NSShiftPolicyState $Workspace
    if ($state['state'] -ceq 'malformed') { return (New-NSPolicySetting $fallback 'built-in' '-') }
    if ($state['state'] -ceq 'absent') {
        # The shift ended and its policy was archived. Where it files is still its own decision,
        # so the ending marker answers for the two settings a later Archive needs.
        $ended = ''
        if ($Name -ceq 'archive.root') { $ended = Get-NSEndedField $Workspace 'archiveRoot' }
        elseif ($Name -ceq 'archive.layout') { $ended = Get-NSEndedField $Workspace 'archiveLayout' }
        if (-not [string]::IsNullOrEmpty($ended)) { return (New-NSPolicySetting $ended 'one-shift' 'shift') }
    }
    if ($state['state'] -ceq 'valid') {
        $frozen = Get-NSMapValue $state['policy'] $block
        if ($frozen -is [Collections.IDictionary] -and $frozen.Contains($key)) {
            $value = $frozen[$key]
            if ($null -ne $value) {
                if ($value -is [Array]) { return (New-NSPolicySetting ([object[]]@($value)) 'one-shift' 'shift') }
                return (New-NSPolicySetting $value 'one-shift' 'shift')
            }
        }
    }

    $rules = Get-NSRulesObject $Workspace
    if ($null -eq $rules) { return (New-NSPolicySetting $fallback 'built-in' '-') }
    $property = $rules.PSObject.Properties[$block]
    if ($null -eq $property -or $null -eq $property.Value) { return (New-NSPolicySetting $fallback 'built-in' '-') }
    $inner = $property.Value.PSObject.Properties[$key]
    if ($null -eq $inner) { return (New-NSPolicySetting $fallback 'built-in' '-') }
    $value = $inner.Value
    if ($value -is [Array]) { return (New-NSPolicySetting ([object[]]@($value)) 'rules' 'permanent') }
    return (New-NSPolicySetting $value 'rules' 'permanent')
}

function Get-NSPolicyRuleInteger {
    param(
        [Parameter(Mandatory = $true)][string]$Workspace,
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][long]$Fallback
    )
    $value = Get-NSRule $Workspace $Key ''
    if ($value -cmatch '^-?[0-9]+$') { return (New-NSPolicySetting ([long]$value) 'rules' 'permanent') }
    return (New-NSPolicySetting $Fallback 'built-in' '-')
}

function Get-NSPolicyDeadlineFile {
    param([Parameter(Mandatory = $true)][string]$Workspace)
    $path = (Get-NSPolicyPaths $Workspace)['deadline']
    if ((Test-NSReparsePoint $path) -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    $raw = ''
    try {
        $raw = ([IO.File]::ReadAllText($path, $script:NSUtf8NoBom)).Trim()
    }
    catch {
        return $null
    }
    if ($raw -cmatch '^[0-9]+$') { return [long]$raw }
    return $null
}

# The one resolver. Precedence, top to bottom: an allowance in tonight's policy,
# then rules.json, then the built-in default. Protected paths, never-commit
# patterns and the expected email come from rules.json alone - no allowance lifts
# them - and shift-defaults.json never appears as the source of a value.
function Get-NSPolicyResolution {
    param([Parameter(Mandatory = $true)][string]$Workspace)
    $paths = Get-NSPolicyPaths $Workspace
    $state = Get-NSShiftPolicyState $Workspace
    $policy = $state['policy']
    $settings = New-NSOrdinalMap

    # The built-in shift is the shipped fast profile: no gate cadence, existing
    # tools, no deadline. Only tonight's policy moves any of the three.
    $settings['verificationLevel'] = New-NSPolicySetting 'none' 'built-in' '-'
    $settings['toolingPolicy'] = New-NSPolicySetting 'existing-tools' 'built-in' '-'
    $settings['deadlineEpoch'] = New-NSPolicySetting $null 'built-in' '-'
    if ($null -ne $policy) {
        $settings['verificationLevel'] = New-NSPolicySetting $policy['verificationLevel'] 'one-shift' 'shift'
        $settings['toolingPolicy'] = New-NSPolicySetting $policy['toolingPolicy'] 'one-shift' 'shift'
        # Once a policy exists, the deadline is tonight's either way: a number is the clock, and
        # null says this shift runs without one. Neither is the absence of a decision.
        $deadline = Get-NSMapValue $policy 'deadlineEpoch'
        if (Test-NSJsonInteger $deadline) {
            $settings['deadlineEpoch'] = New-NSPolicySetting ([long]$deadline) 'one-shift' 'shift'
        }
        else {
            $settings['deadlineEpoch'] = New-NSPolicySetting $null 'one-shift' 'shift'
        }
    }

    foreach ($category in $script:NSPolicyCategories) {
        $entry = New-NSPolicySetting 'deny' 'built-in' '-'
        $rulePolicy = Get-NSElevationRulePolicy $Workspace $category
        if (-not [string]::IsNullOrEmpty($rulePolicy)) {
            $entry = New-NSPolicySetting $rulePolicy 'rules' 'permanent'
        }
        $allowance = Get-NSPolicyCategoryAllowance $policy $category
        if ($null -ne $allowance) {
            $provenance = [string]$allowance['provenance']
            if ($provenance -ceq 'rules') {
                $entry = New-NSPolicySetting 'allow' 'rules' 'permanent'
            }
            else {
                $entry = New-NSPolicySetting 'allow' 'one-shift' 'shift'
            }
        }
        elseif ((Get-NSPolicyExactPlanAllowances $policy $category).Count -gt 0) {
            $entry = New-NSPolicySetting 'exact-plan' 'exact-plan' 'shift'
        }
        $settings['elevation.' + $category] = $entry
    }

    $settings['forbiddenCommands'] = Get-NSPolicyRuleSetting $Workspace 'forbiddenCommands'
    $settings['protectedDirs'] = Get-NSPolicyRuleSetting $Workspace 'protectedDirs'
    $settings['neverCommitPatterns'] = Get-NSPolicyRuleSetting $Workspace 'neverCommitPatterns'
    $settings['expectedEmail'] = Get-NSPolicyRuleSetting $Workspace 'expectedEmail'
    $settings['stallMax'] = Get-NSPolicyRuleInteger $Workspace 'stallMax' 0
    $settings['watchMinutes'] = Get-NSPolicyRuleInteger $Workspace 'watchMinutes' 10
    foreach ($name in $script:NSPolicyGroupDefaults.Keys) {
        $settings[$name] = Get-NSPolicyGroupSetting $Workspace $name
    }

    $resolution = New-NSOrdinalMap
    $resolution['settings'] = $settings
    $resolution['policy'] = $policy
    $resolution['policyState'] = $state['state']
    $resolution['policyError'] = $state['error']
    $resolution['deadlineFile'] = Get-NSPolicyDeadlineFile $Workspace
    $resolution['deadlinePolicy'] = $settings['deadlineEpoch']['value']
    return $resolution
}

function Get-NSPolicyAllowances {
    param($Policy, [Parameter(Mandatory = $true)][string]$Category)
    $found = New-Object Collections.Generic.List[object]
    if ($null -eq $Policy) { return , $found }
    $allowances = Get-NSPolicyField $Policy 'allowances'
    if ($null -eq $allowances) { return , $found }
    foreach ($allowance in @($allowances)) {
        if (-not ($allowance -is [Collections.IDictionary])) { continue }
        $candidate = Get-NSMapValue $allowance 'category'
        if (($candidate -is [string]) -and ($candidate -ceq $Category)) { $found.Add($allowance) }
    }
    return , $found
}

function Get-NSPolicyCategoryAllowance {
    param($Policy, [Parameter(Mandatory = $true)][string]$Category)
    foreach ($allowance in (Get-NSPolicyAllowances $Policy $Category)) {
        $scope = Get-NSMapValue $allowance 'scope'
        if (($scope -is [string]) -and ($scope -ceq 'category')) { return $allowance }
    }
    return $null
}

function Get-NSPolicyExactPlanAllowances {
    param($Policy, [Parameter(Mandatory = $true)][string]$Category)
    $plans = New-Object Collections.Generic.List[object]
    foreach ($allowance in (Get-NSPolicyAllowances $Policy $Category)) {
        $scope = Get-NSMapValue $allowance 'scope'
        if (($scope -is [string]) -and ($scope -ceq 'exact-plan')) { $plans.Add($allowance) }
    }
    return , $plans
}

# One rendering for both resolvers: the table is read by people and by the model, so a boolean,
# a null and a list have to look the same whichever half printed them.
function Format-NSPolicyValue {
    param($Value)
    if ($null -eq $Value) { return 'null' }
    if ($Value -is [bool]) { if ($Value) { return 'true' } else { return 'false' } }
    if (Test-NSJsonInteger $Value) { return ([long]$Value).ToString([Globalization.CultureInfo]::InvariantCulture) }
    if ($Value -is [Array]) { return (ConvertTo-NSCanonicalJson $Value -Compact) }
    return [string]$Value
}

function Format-NSPolicyTable {
    param($Resolution)
    $settings = $Resolution['settings']
    $lines = New-Object Collections.Generic.List[string]
    foreach ($name in (Sort-NSOrdinal $script:NSPolicySettingNames)) {
        $entry = $settings[$name]
        $lines.Add(('{0}={1} ({2}, {3})' -f $name, (Format-NSPolicyValue $entry['value']), $entry['source'], $entry['expiry']))
    }
    return , $lines.ToArray()
}

function Resolve-NSPolicy {
    param(
        [Parameter(Mandatory = $true)][string]$Workspace,
        [switch]$Json,
        [switch]$Table
    )
    if ($Table -and $Json) {
        throw 'choose one of -Json or -Table'
    }
    $resolution = Get-NSPolicyResolution $Workspace
    if ($Table) {
        return ((Format-NSPolicyTable $resolution) -join "`n")
    }
    $document = New-NSOrdinalMap
    $document['schemaVersion'] = 1
    $document['settings'] = $resolution['settings']
    return (ConvertTo-NSCanonicalJson $document -Compact)
}

# The gate honours the earlier of the two, so a deadline file that drifts from
# the policy shortens the night rather than extending it.
function Get-NSPolicyDeadlineEpoch {
    param([Parameter(Mandatory = $true)][string]$Workspace)
    $resolution = Get-NSPolicyResolution $Workspace
    $file = $resolution['deadlineFile']
    $fromPolicy = $resolution['deadlinePolicy']
    if ($null -eq $file) { return $fromPolicy }
    if ($null -eq $fromPolicy) { return $file }
    if ([long]$file -lt [long]$fromPolicy) { return [long]$file }
    return [long]$fromPolicy
}

# 0 allow - 1 deny - 2 the category is denied and no exact plan covers this
# command. The caller has already matched the command against the category
# pattern; this answers only whether the shift permits it.
function Test-NSPolicyAllowed {
    param(
        [Parameter(Mandatory = $true)][string]$Workspace,
        [Parameter(Mandatory = $true)][string]$Category,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Command
    )
    if (-not ($script:NSPolicyCategories -ccontains $Category)) { return 1 }
    $resolution = Get-NSPolicyResolution $Workspace
    $value = [string]$resolution['settings']['elevation.' + $Category]['value']
    if ($value -ceq 'allow') { return 0 }
    if ($value -cne 'exact-plan') { return 1 }
    if (Test-NSPolicyExactPlan -Workspace $Workspace -Resolution $resolution -Category $Category -Command $Command) { return 0 }
    return 2
}

# An exact plan binds the command, the resolved work target, the shift identity
# and the deadline. Any drift is a mismatch, never a fall-through to the category.
function Test-NSPolicyExactPlan {
    param(
        [Parameter(Mandatory = $true)][string]$Workspace,
        [Parameter(Mandatory = $true)]$Resolution,
        [Parameter(Mandatory = $true)][string]$Category,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Command
    )
    $policy = $Resolution['policy']
    if ($null -eq $policy) { return $false }
    $deadline = $Resolution['deadlinePolicy']
    if ($null -ne $deadline -and (Get-NSUnixTime) -gt [long]$deadline) { return $false }
    $target = $Workspace
    try {
        $target = Resolve-NSWorkTarget $Workspace
    }
    catch {
        $target = Get-NSAbsolutePath $Workspace
    }
    $shiftId = [string]$policy['shiftId']
    $normalized = Get-NSPolicyNormalizedCommand $Command
    foreach ($allowance in (Get-NSPolicyExactPlanAllowances $policy $Category)) {
        $plan = Get-NSMapValue $allowance 'plan'
        if ($null -eq $plan) { continue }
        # A plan may expire before the shift does; a plan with no expiry of its
        # own defers to the shift deadline checked above.
        $planExpiry = Get-NSMapValue $plan 'expiry'
        if ((Test-NSJsonInteger $planExpiry) -and (Get-NSUnixTime) -gt [long]$planExpiry) { continue }
        $planTarget = [string](Get-NSMapValue $plan 'workTarget')
        if (-not ($planTarget -ceq (Get-NSAbsolutePath $target))) { continue }
        $commands = New-Object Collections.Generic.List[string]
        foreach ($command in @(Get-NSPolicyField $plan 'commands')) { $commands.Add([string]$command) }
        $expected = Get-NSPolicyPlanDigest -Commands $commands.ToArray() -WorkTarget $planTarget -ShiftId $shiftId
        if (-not ($expected -ceq [string](Get-NSMapValue $plan 'digest'))) { continue }
        foreach ($command in $commands) {
            if ((Get-NSPolicyNormalizedCommand $command) -ceq $normalized) { return $true }
        }
    }
    return $false
}

# ---------------------------------------------------------------------------
# Permission preflight - a filter for surprises, never a guarantee. It reports
# and exits 0; only the owner lifts a category.
# ---------------------------------------------------------------------------

function Get-NSPreflightTitle {
    param([AllowEmptyString()][string]$Line)
    $title = $Line.Trim()
    $title = [regex]::Replace($title, '^-\s*\[[ xX]\]\s*', '')
    $title = [regex]::Replace($title, '^#+\s*', '')
    $title = $title.Replace('*', '').Replace('`', '')
    $title = [regex]::Replace($title, '[\u0001-\u001F\u007F]', ' ')
    $title = [regex]::Replace($title, '\s+', ' ')
    return $title.Trim()
}

function Get-NSPreflightSectionItems {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][AllowEmptyString()][string[]]$Lines,
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$FallbackTitle
    )
    $items = New-Object Collections.Generic.List[object]
    $current = $null
    $sawBox = $false
    $boxIndex = 0
    $text = New-Object Text.StringBuilder
    foreach ($line in $Lines) {
        if ($line -match '^##\s') {
            if ($null -ne $current) {
                $current['text'] = $text.ToString()
                $items.Add($current)
                $current = $null
            }
            continue
        }
        # A ticked box is finished work: it closes the item above it and starts
        # nothing, so no allowance is ever reported or parked for it. The file
        # number still advances, matching the POSIX report.
        if ($line -match '^\s*-\s*\[[xX]\]') {
            $sawBox = $true
            $boxIndex++
            if ($null -ne $current) {
                $current['text'] = $text.ToString()
                $items.Add($current)
                $current = $null
            }
            continue
        }
        if ($line -match '^\s*-\s*\[ \]') {
            $sawBox = $true
            $boxIndex++
            if ($null -ne $current) {
                $current['text'] = $text.ToString()
                $items.Add($current)
            }
            $current = New-NSOrdinalMap
            $current['title'] = Get-NSPreflightTitle $line
            $current['source'] = $Source
            $current['index'] = $boxIndex
            $text = New-Object Text.StringBuilder
        }
        if ($null -ne $current) {
            $null = $text.Append($line)
            $null = $text.Append("`n")
        }
    }
    if ($null -ne $current) {
        $current['text'] = $text.ToString()
        $items.Add($current)
    }
    # A section that carries no box at all is itself the unit; one whose boxes are
    # all ticked has nothing left to need.
    if ($items.Count -eq 0 -and -not $sawBox -and -not [string]::IsNullOrEmpty($FallbackTitle)) {
        $item = New-NSOrdinalMap
        $item['title'] = $FallbackTitle
        $item['source'] = $Source
        $item['text'] = ($Lines -join "`n")
        $items.Add($item)
    }
    return , $items
}

function Get-NSPreflightFileLines {
    param([Parameter(Mandatory = $true)][string]$Path)
    if ((Test-NSReparsePoint $Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return , @() }
    try {
        return , ([regex]::Split([IO.File]::ReadAllText($Path, $script:NSUtf8NoBom), "\r\n|\n|\r"))
    }
    catch {
        return , @()
    }
}

function Get-NSPreflightItems {
    param([Parameter(Mandatory = $true)][string]$Workspace)
    $paths = Get-NSPolicyPaths $Workspace
    $items = New-Object Collections.Generic.List[object]

    $section = New-Object Collections.Generic.List[string]
    $inItems = $false
    foreach ($line in (Get-NSPreflightFileLines $paths['punch'])) {
        if (-not $inItems) {
            if ($line -match '^##\s+Items\s*$') { $inItems = $true }
            continue
        }
        if ($line -match '^##\s') { break }
        $section.Add($line)
    }
    foreach ($item in (Get-NSPreflightSectionItems -Lines $section.ToArray() -Source 'punch-list' -FallbackTitle '')) {
        $items.Add($item)
    }

    $orderLines = New-Object Collections.Generic.List[string]
    $inOrders = $false
    foreach ($line in (Get-NSPreflightFileLines $paths['orders'])) {
        if (-not $inOrders) {
            if ($line -match '^##\s+Work order') { $inOrders = $true }
            else { continue }
        }
        $orderLines.Add($line)
    }
    if ($orderLines.Count -gt 0) {
        foreach ($item in (Get-NSPreflightSectionItems -Lines $orderLines.ToArray() -Source 'work-orders' -FallbackTitle '')) {
            $items.Add($item)
        }
    }
    return , $items
}

function Get-NSPreflightReport {
    param([Parameter(Mandatory = $true)][string]$Workspace)
    $resolution = Get-NSPolicyResolution $Workspace
    $patterns = New-NSOrdinalMap
    foreach ($category in $script:NSPolicyCategories) {
        $pattern = Get-NSElevationPattern $Workspace $category
        $regex = $null
        try {
            $regex = New-NSPolicyRegex $pattern
        }
        catch {
            # An unreadable pattern is one reported defect. The category stays
            # denied and the hardhat guard still fails closed on the command.
            $regex = $null
        }
        $patterns[$category] = $regex
    }
    $patternErrors = New-Object Collections.Generic.List[string]
    foreach ($category in $script:NSPolicyCategories) {
        if ($null -eq $patterns[$category]) { $patternErrors.Add($category) }
    }
    $items = New-Object Collections.Generic.List[object]
    $gaps = New-Object Collections.Generic.List[object]
    foreach ($item in (Get-NSPreflightItems $Workspace)) {
        # An item quotes its commands in markdown; the backticks become spaces so
        # the shared elevation patterns read prose the way the guard reads a command.
        $text = ([string]$item['text']).Replace('`', ' ')
        $needs = New-Object Collections.Generic.List[object]
        foreach ($category in $script:NSPolicyCategories) {
            $regex = $patterns[$category]
            $matched = $false
            if ($null -eq $regex) {
                $matched = $true
            }
            elseif ($regex.IsMatch($text)) {
                $matched = $true
            }
            if (-not $matched) { continue }
            $value = [string]$resolution['settings']['elevation.' + $category]['value']
            $need = New-NSOrdinalMap
            $need['category'] = $category
            $need['resolved'] = $value
            $need['allowed'] = ($value -ceq 'allow')
            $needs.Add($need)
            if (-not $need['allowed']) {
                $gap = New-NSOrdinalMap
                $gap['category'] = $category
                $gap['title'] = $item['title']
                $gap['index'] = $item['index']
                $gaps.Add($gap)
            }
        }
        $entry = New-NSOrdinalMap
        $entry['title'] = $item['title']
        $entry['source'] = $item['source']
        $entry['index'] = $item['index']
        $entry['needs'] = $needs.ToArray()
        $items.Add($entry)
    }
    $report = New-NSOrdinalMap
    $report['schemaVersion'] = 1
    $report['items'] = $items.ToArray()
    $report['gaps'] = $gaps.ToArray()
    $report['patternErrors'] = $patternErrors.ToArray()
    return $report
}

function Get-NSPreflightNeeds {
    param(
        [Parameter(Mandatory = $true)][string]$Workspace,
        [switch]$Json
    )
    $report = Get-NSPreflightReport $Workspace
    if ($Json) {
        $document = New-NSOrdinalMap
        $document['schemaVersion'] = $report['schemaVersion']
        $document['gaps'] = @(foreach ($gap in @($report['gaps'])) {
                $row = New-NSOrdinalMap
                $row['category'] = $gap['category']
                $row['title'] = $gap['title']
                $row
            })
        $document['items'] = @(foreach ($item in @($report['items'])) {
                $row = New-NSOrdinalMap
                $row['needs'] = $item['needs']
                $row['source'] = $item['source']
                $row['title'] = $item['title']
                $row
            })
        $document['patternErrors'] = $report['patternErrors']
        return (ConvertTo-NSCanonicalJson $document -Compact)
    }
    $lines = New-Object Collections.Generic.List[string]
    $open = @($report['items']).Count
    $gapped = 0
    foreach ($item in $report['items']) {
        $hasGap = $false
        foreach ($need in @($item['needs'])) {
            if (-not $need['allowed']) { $hasGap = $true; break }
        }
        if ($hasGap) { $gapped++ }
    }
    $lines.Add(('preflight: {0} open items, {1} with gaps' -f $open, $gapped))
    foreach ($item in $report['items']) {
        $index = $item['index']
        if ($null -eq $index) { $index = 0 }
        $lines.Add(('item {0} [{1}] {2}' -f $index, $item['source'], $item['title']))
        if (@($item['needs']).Count -eq 0) {
            $lines.Add('  needs nothing')
            continue
        }
        foreach ($need in $item['needs']) {
            if ($need['allowed']) {
                $lines.Add(('  needs {0} (allowed)' -f $need['category']))
            }
            elseif ([string]$need['resolved'] -ceq 'exact-plan') {
                $lines.Add(('  needs {0} (allowed only for the approved plan)' -f $need['category']))
            }
            else {
                $lines.Add(('  needs {0} (denied)' -f $need['category']))
            }
        }
    }
    foreach ($category in $report['patternErrors']) {
        $lines.Add(('pattern error: elevation.{0}.pattern is not a valid grep -E pattern; the category counts as needed' -f $category))
    }
    $gapParts = New-Object Collections.Generic.List[string]
    foreach ($gap in $report['gaps']) {
        $gapIndex = $gap['index']
        if ($null -eq $gapIndex) { $gapIndex = 0 }
        $gapParts.Add(('{0} (item {1})' -f $gap['category'], $gapIndex))
    }
    if ($gapParts.Count -eq 0) {
        $lines.Add('gaps: none')
    }
    else {
        $lines.Add('gaps: ' + ($gapParts -join ', '))
    }
    return ($lines -join "`n")
}

# One parking-lot entry per item and category, idempotent: Start may run twice
# over the same punch list and the owner still reads one entry per gap. Each entry is
# a `- ` bullet, the shape Archive files once the owner answers it; an entry an
# earlier release wrote as a bare line is still recognised as already parked.
function Add-NSParkedNeeds {
    param([Parameter(Mandatory = $true)][string]$Workspace)
    $paths = Get-NSPolicyPaths $Workspace
    $report = Get-NSPreflightReport $Workspace
    $added = New-Object Collections.Generic.List[string]
    if (@($report['gaps']).Count -eq 0) { return , $added.ToArray() }
    $path = $paths['parking']
    if (Test-NSReparsePoint $path) {
        throw 'parking-lot.md is not a usable file'
    }
    $existing = ''
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        $existing = [IO.File]::ReadAllText($path, $script:NSUtf8NoBom)
    }
    else {
        $existing = "# Parking Lot`n"
    }
    $dash = [string][char]0x2014
    $builder = New-Object Text.StringBuilder
    $null = $builder.Append($existing)
    if (-not $existing.EndsWith("`n")) { $null = $builder.Append("`n") }
    foreach ($gap in $report['gaps']) {
        $category = [string]$gap['category']
        $title = [string]$gap['title']
        $marker = '**needs allowance: {0}** {1} item "{2}"' -f $category, $dash, $title
        if ($builder.ToString().Contains($marker)) { continue }
        $null = $builder.Append("`n- ")
        $null = $builder.Append($marker)
        $null = $builder.Append((' needs the {0} elevation category, which is denied for this shift. Default: parked, worked last if the owner allows it before then.' -f $category))
        $null = $builder.Append("`n")
        $added.Add(('{0}: {1}' -f $category, $title))
    }
    if ($added.Count -gt 0) {
        Write-NSEvidenceFileAtomic -Path $path -Text $builder.ToString()
    }
    return , $added.ToArray()
}

# ---------------------------------------------------------------------------
# Command surfaces for the thin runtime scripts
# ---------------------------------------------------------------------------

function Write-NSShiftPolicyUsage {
    Write-NSPolicyError 'usage: shift-policy.ps1 -Project DIR -Command {get|set|defaults-get|defaults-set|resolve|archive} ...'
    return 1
}

function Invoke-NSShiftPolicyArchive {
    param(
        [Parameter(Mandatory = $true)][string]$Workspace,
        [Parameter(Mandatory = $true)][string]$Date
    )
    $paths = Get-NSPolicyPaths $Workspace
    if (-not (Test-Path -LiteralPath $paths['policy'] -PathType Leaf)) {
        Write-NSPolicyError 'shift-policy: no shift policy to archive'
        return 3
    }
    $state = Get-NSShiftPolicyState $Workspace
    $shiftId = 'unknown'
    if ($state['state'] -ceq 'valid') {
        $shiftId = [string]$state['policy']['shiftId']
    }
    else {
        Write-NSPolicyError ('shift-policy: ' + $state['error'] + '; archiving it as the unknown shift')
    }
    # The shift's own folder, at the path the policy has live: the archive reads like the live site.
    $directory = Get-NSArchiveGroup -Workspace $Workspace -Date $Date -ShiftId $shiftId
    if ($null -eq $directory) {
        Write-NSPolicyError 'shift-policy: archive.root must name a directory inside .nightshift/'
        return 2
    }
    if (Test-NSReparsePoint $directory) {
        Write-NSPolicyError 'shift-policy: refuse to write through a symlink archive path'
        return 2
    }
    $destination = Join-NSPath $directory ((Get-NSLayoutRelativePath $paths['ns'] 'shift-policy').Replace('/', [IO.Path]::DirectorySeparatorChar))
    if (-not (Test-NSArchiveDest $destination)) {
        Write-NSPolicyError ('shift-policy: refuse to write through ' + $destination)
        return 2
    }
    if ((Test-Path -LiteralPath $destination -PathType Leaf) -and -not (Test-NSSameFileBytes $paths['policy'] $destination)) {
        Write-NSPolicyError ('shift-policy: a different shift policy is already filed at ' + $destination + '; the live one is unchanged')
        return 2
    }
    $null = [IO.Directory]::CreateDirectory((Split-Path -Parent $destination))
    Write-NSEvidenceFileAtomic -Path $destination -Text ([IO.File]::ReadAllText($paths['policy'], $script:NSUtf8NoBom))
    Remove-Item -LiteralPath $paths['policy'] -Force
    Write-NSPolicyOut $destination
    return 0
}

# The migration onto the one-file shape. Same contract as the POSIX helper: refuse while armed,
# name an invalid value by its key, validate the destination before replacing one that loads,
# keep a lossless backup, do nothing the second time, and refuse a disagreeing pair by naming
# both sides rather than choosing one.
function Invoke-NSPolicyMigrate {
    param(
        [Parameter(Mandatory = $true)][string]$Workspace,
        [switch]$DryRun
    )
    $paths = Get-NSPolicyPaths $Workspace
    $rules = $paths['rules']
    $legacy = $paths['defaults']
    if (-not (Test-Path -LiteralPath $rules -PathType Leaf)) {
        Write-NSPolicyError ('shift-policy: no owner rules file at ' + $rules + ' - run setup first')
        return 3
    }
    if (Test-NSPolicyArmed $Workspace) {
        Write-NSPolicyError 'shift-policy: refuse to migrate while the shift is armed - stop the shift, migrate, then start again'
        return 4
    }
    $canonical = Get-NSShiftBlock $Workspace
    $stated = $null
    if (Test-Path -LiteralPath $legacy -PathType Leaf) {
        try {
            $stated = ConvertFrom-NSJsonText ([IO.File]::ReadAllText($legacy, $script:NSUtf8NoBom))
        }
        catch {
            $stated = $null
        }
        if (-not ($stated -is [Collections.IDictionary])) { $stated = $null }
    }

    $fields = @(
        @{ Name = 'verificationProfile'; Enum = $script:NSPolicyProfiles },
        @{ Name = 'hours'; Enum = $null },
        @{ Name = 'execution'; Enum = $script:NSPolicyExecutions },
        @{ Name = 'toolingPolicy'; Enum = $script:NSPolicyToolingPolicies })

    $block = New-NSOrdinalMap
    $conflicts = New-Object Collections.Generic.List[string]
    foreach ($field in $fields) {
        $name = [string]$field['Name']
        $here = $null
        $there = $null
        $haveHere = ($null -ne $canonical) -and $canonical.Contains($name)
        $haveThere = ($null -ne $stated) -and $stated.Contains($name)
        if ($haveHere) { $here = $canonical[$name] }
        if ($haveThere) { $there = $stated[$name] }
        foreach ($pair in @(@($haveHere, $here), @($haveThere, $there))) {
            if (-not $pair[0]) { continue }
            if (-not (Test-NSMigrateValue $name $pair[1] $field['Enum'])) { return 2 }
        }
        if ($haveHere -and $haveThere -and ((ConvertTo-NSCanonicalJson @{ v = $here }) -cne (ConvertTo-NSCanonicalJson @{ v = $there }))) {
            $conflicts.Add('  shift.' + $name + ': this file says ' + (ConvertTo-NSJsonScalar $here) +
                ', the legacy file says ' + (ConvertTo-NSJsonScalar $there))
            continue
        }
        if ($haveHere) { $block[$name] = $here }
        elseif ($haveThere) { $block[$name] = $there }
    }

    if ($conflicts.Count -gt 0) {
        Write-NSPolicyError 'shift-policy: refused: two explicit values disagree, and nothing here decides between them'
        foreach ($line in $conflicts) { Write-NSPolicyError $line }
        Write-NSPolicyError ('shift-policy: keep one value, delete the other from ' + $legacy + ', then run migrate again')
        return 2
    }

    if (-not (Test-Path -LiteralPath $legacy -PathType Leaf) -and $null -ne $canonical) {
        Write-NSPolicyOut ('no-op: every remembered choice already lives in ' + $rules)
        return 0
    }

    Write-NSPolicyOut ('migrating into ' + $rules + ':')
    Write-NSPolicyOut ('  shift = ' + (ConvertTo-NSCanonicalJson $block))
    if ($DryRun) {
        Write-NSPolicyOut 'dry run: nothing was written'
        return 0
    }
    if (Test-Path -LiteralPath $legacy -PathType Leaf) {
        $nsDir = Join-Path $Workspace '.nightshift'
        New-NSLayoutParent $nsDir 'shift-defaults-backup'
        Copy-Item -LiteralPath $legacy -Destination (Get-NSLayoutPath $nsDir 'shift-defaults-backup') -Force
    }
    $rc = Set-NSShiftBlock -Workspace $Workspace -Block $block
    if ($rc -ne 0) { return $rc }
    Remove-Item -LiteralPath $legacy -Force -ErrorAction SilentlyContinue
    Write-NSPolicyOut $rules
    return 0
}

# The bounded reader answers about shape; this answers about the value, which is what a migration
# must know before it carries one forward.
function Test-NSMigrateValue {
    param([string]$Name, $Value, $Enum)
    if ($Name -ceq 'hours') {
        if ($null -eq $Value) { return $true }
        if ((Test-NSJsonInteger $Value) -and [long]$Value -ge 0) { return $true }
        Write-NSPolicyError 'shift-policy: shift.hours: must be a whole number of hours or null'
        return $false
    }
    if (Test-NSEvidenceEnum $Value $Enum) { return $true }
    Write-NSPolicyError ('shift-policy: shift.' + $Name + ': must be ' + ($Enum -join ', '))
    return $false
}

function ConvertTo-NSJsonScalar {
    param($Value)
    if ($null -eq $Value) { return 'null' }
    if ($Value -is [string]) { return ('"' + $Value + '"') }
    return ([string]$Value)
}

function Invoke-NSShiftPolicyCommand {
    param(
        [AllowEmptyString()][string]$Project = '',
        [AllowEmptyString()][string]$Command = '',
        [AllowEmptyString()][string]$FromJson = '',
        [AllowEmptyString()][string]$VerificationProfile = '',
        [AllowEmptyString()][string]$Hours = '',
        [AllowEmptyString()][string]$ToolingPolicy = '',
        [AllowEmptyString()][string]$Execution = '',
        [AllowEmptyString()][string]$Date = '',
        [switch]$Json,
        [switch]$Table,
        [switch]$DryRun
    )
    if ([string]::IsNullOrEmpty($Project) -or [string]::IsNullOrEmpty($Command)) { return (Write-NSShiftPolicyUsage) }
    $workspace = Get-NSAbsolutePath $Project
    $paths = Get-NSPolicyPaths $workspace
    switch ($Command) {
        'get' {
            if (-not (Test-Path -LiteralPath $paths['policy'] -PathType Leaf)) {
                Write-NSPolicyOut '{}'
                return 3
            }
            $text = [IO.File]::ReadAllText($paths['policy'], $script:NSUtf8NoBom)
            [Console]::Out.Write($text)
            if (-not $text.EndsWith("`n")) { [Console]::Out.Write("`n") }
            return 0
        }
        'set' {
            if ([string]::IsNullOrEmpty($FromJson)) { return (Write-NSShiftPolicyUsage) }
            $documentText = ''
            if ($FromJson -ceq '-') {
                $documentText = Get-NSStdinText
            }
            elseif (Test-Path -LiteralPath $FromJson -PathType Leaf) {
                $documentText = [IO.File]::ReadAllText($FromJson, $script:NSUtf8NoBom)
            }
            else {
                Write-NSPolicyError ('shift-policy: cannot read ' + $FromJson)
                return 2
            }
            return (Set-NSShiftPolicy -Workspace $workspace -Json $documentText)
        }
        'defaults-get' {
            Write-NSPolicyOut (ConvertTo-NSCanonicalJson (Get-NSShiftDefaults $workspace))
            return 0
        }
        'defaults-set' {
            return (Set-NSShiftDefaults -Workspace $workspace -VerificationProfile $VerificationProfile `
                    -Hours $Hours -ToolingPolicy $ToolingPolicy -Execution $Execution)
        }
        'resolve' {
            if ($Table) {
                Write-NSPolicyOut (Resolve-NSPolicy -Workspace $workspace -Table)
                return 0
            }
            Write-NSPolicyOut (Resolve-NSPolicy -Workspace $workspace -Json)
            return 0
        }
        'migrate' {
            return (Invoke-NSPolicyMigrate -Workspace $workspace -DryRun:$DryRun)
        }
        'archive' {
            $day = $Date
            if ([string]::IsNullOrEmpty($day)) { $day = Get-Date -Format 'yyyy-MM-dd' }
            if ($day -cnotmatch '^[0-9]{4}-[0-9]{2}-[0-9]{2}$') {
                Write-NSPolicyError 'shift-policy: -Date must be YYYY-MM-DD'
                return 2
            }
            return (Invoke-NSShiftPolicyArchive -Workspace $workspace -Date $day)
        }
    }
    return (Write-NSShiftPolicyUsage)
}

function Invoke-NSPreflightNeedsCommand {
    param([AllowEmptyString()][string]$Project = '', [switch]$Json)
    if ([string]::IsNullOrEmpty($Project)) {
        Write-NSPolicyError 'usage: preflight-needs.ps1 -Project DIR [-Json]'
        return 1
    }
    Write-NSPolicyOut (Get-NSPreflightNeeds -Workspace (Get-NSAbsolutePath $Project) -Json:$Json)
    return 0
}

function Invoke-NSParkNeedsCommand {
    param([AllowEmptyString()][string]$Project = '')
    if ([string]::IsNullOrEmpty($Project)) {
        Write-NSPolicyError 'usage: park-needs.ps1 -Project DIR'
        return 1
    }
    $workspace = Get-NSAbsolutePath $Project
    if (-not (Test-Path -LiteralPath (Get-NSPolicyPaths $workspace)['ns'] -PathType Container)) {
        Write-NSPolicyError ('park-needs: no .nightshift/ at ' + $workspace)
        return 1
    }
    $added = Add-NSParkedNeeds -Workspace $workspace
    foreach ($entry in $added) { Write-NSPolicyOut ('parked ' + $entry) }
    Write-NSPolicyOut ('park-needs: added ' + $added.Count)
    return 0
}

# ---------------------------------------------------------------------------
# Provisioning - the transaction document, native rollback, and the late stages.
# The engine that installs a capability is not on this host. What lives here is
# the recovery every host owes an interrupted transaction, the read-only plan,
# and the honest refusal.
# ---------------------------------------------------------------------------

$script:NSProvisionStages = @('authorize', 'capture-baseline', 'apply', 'smoke', 'record', 'commit-tooling')
# Every stage but record and commit-tooling undoes rather than finishes.
$script:NSProvisionRollbackStages = @('authorize', 'capture-baseline', 'apply', 'smoke', 'rollback')
$script:NSProvisionSetupPrefix = 'chore(tooling):'
$script:NSProvisionBudgetDefault = 120
$script:NSProvisionRequiredFields = @(
    'capabilityId', 'ecosystems', 'versionConstraints', 'detect', 'probe',
    'packageManagerAdditions', 'allowedFiles', 'minimalConfig', 'smoke',
    'rollback', 'enabledShifts', 'safetyClass', 'permissionRequirements', 'recipeVersion')
$script:NSProvisionLockedNames = @(
    'punch-list.md', 'parking-lot.md', 'drafting-table.md', 'work-orders.md',
    'capability-policy.json', 'shift-policy.json', 'shift-defaults.json')
$script:NSProvisionStackSignals = New-Object Collections.Specialized.OrderedDictionary([StringComparer]::Ordinal)
$script:NSProvisionStackSignals['javascript-typescript'] = @('package.json')
$script:NSProvisionStackSignals['python'] = @('pyproject.toml', 'requirements.txt', 'setup.cfg', 'setup.py')
$script:NSProvisionStackSignals['go'] = @('go.mod')
$script:NSProvisionStackSignals['rust'] = @('Cargo.toml')
$script:NSProvisionStackSignals['shell-plugin'] = @('.claude-plugin', '.codex-plugin')
$script:NSProvisionStackSignals['make'] = @('Makefile')

function Write-NSProvisionOut {
    param([AllowEmptyString()][string]$Text)
    [Console]::Out.Write($Text)
    [Console]::Out.Write("`n")
}

function Write-NSProvisionError {
    param([AllowEmptyString()][string]$Text)
    [Console]::Error.WriteLine($Text)
}

# One line of sorted, compact JSON with a single trailing newline - the bytes the
# POSIX recovery helper prints, so every host answers on one wire format.
function Write-NSProvisionJson {
    param([Parameter(Mandatory = $true)]$Document)
    Write-NSProvisionOut (ConvertTo-NSCanonicalJson $Document -Compact)
}

function Write-NSProvisionUsage {
    Write-NSProvisionError ('usage: provision.ps1 -Project DIR plan|apply|recover|rollback ' +
        '[-Recipe PATH] [-Capability ID] [-BudgetSeconds N]')
    return 1
}

function Get-NSProvisionNow {
    $fixed = $env:NIGHTSHIFT_PROVISION_NOW
    if (-not [string]::IsNullOrEmpty($fixed)) { return $fixed }
    return [DateTime]::UtcNow.ToString('yyyy-MM-dd\THH:mm:ss\Z', [Globalization.CultureInfo]::InvariantCulture)
}

function Get-NSProvisionPaths {
    param([Parameter(Mandatory = $true)][string]$Project)
    $ns = Join-NSPath (Get-NSAbsolutePath $Project) '.nightshift'
    $paths = New-NSOrdinalMap
    $paths['ns'] = $ns
    $paths['transaction'] = Get-NSLayoutPath $ns 'provision-transaction'
    $paths['baseline'] = Get-NSLayoutPath $ns 'provision-baseline'
    $paths['inventory'] = Get-NSLayoutPath $ns 'capabilities'
    return $paths
}

function Get-NSProvisionRelPath {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Rel)
    return ($Rel.Replace('\', '/')).TrimStart('.', '/')
}

function Get-NSProvisionByteSha256 {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]]$Bytes)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash($Bytes)
    }
    finally {
        $sha.Dispose()
    }
    $builder = New-Object Text.StringBuilder
    foreach ($byte in $hash) { $null = $builder.Append($byte.ToString('x2')) }
    return $builder.ToString()
}

# The blob file name is the digest of the normalized relative path, so the store
# is addressable without reading the transaction.
function Get-NSProvisionBlobId {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Rel)
    return (Get-NSTextSha256 (Get-NSProvisionRelPath $Rel))
}

# Every path the engine touches is relative, inside the work target, and never an
# owner file. A baseline that breaks any of the three is malformed, not repairable.
function Resolve-NSProvisionPath {
    param(
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Rel
    )
    $relative = Get-NSProvisionRelPath $Rel
    if ([string]::IsNullOrEmpty($relative)) { throw ('path outside work target: ' + $Rel) }
    if ($relative.StartsWith('/', [StringComparison]::Ordinal)) { throw ('path outside work target: ' + $Rel) }
    foreach ($part in $relative.Split('/')) {
        if ($part -ceq '..') { throw ('path outside work target: ' + $Rel) }
    }
    if ($script:NSProvisionLockedNames -ccontains ([IO.Path]::GetFileName($relative))) {
        throw 'refuses to write Nightshift owner files'
    }
    $root = Get-NSAbsolutePath $Target
    $full = Get-NSAbsolutePath (Join-NSPath $root $relative)
    $head = $root + [string][IO.Path]::DirectorySeparatorChar
    if (($full -cne $root) -and -not $full.StartsWith($head, [StringComparison]::Ordinal)) {
        throw ('path outside work target: ' + $Rel)
    }
    return $full
}

function Read-NSProvisionTransaction {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    return (ConvertFrom-NSJsonText ([IO.File]::ReadAllText($Path, $script:NSUtf8NoBom)))
}

function Write-NSProvisionTransaction {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Document
    )
    Write-NSEvidenceFileAtomic -Path $Path -Text ((ConvertTo-NSCanonicalJson $Document) + "`n")
}

# The scalar gate on a transaction: every field recovery reads is present and of
# the right type, or recovery names the field and touches nothing.
function Test-NSProvisionTransaction {
    param($Document)
    if (-not ($Document -is [Collections.IDictionary])) { return 'document' }
    if (-not (Test-NSEvidenceEnum (Get-NSMapValue $Document 'stage') (@($script:NSProvisionStages) + @('rollback')))) {
        return 'stage'
    }
    $capability = Get-NSMapValue $Document 'capabilityId'
    if (-not ($capability -is [string]) -or $capability.Length -eq 0) { return 'capabilityId' }
    $failed = Get-NSMapValue $Document 'failed'
    if (($null -ne $failed) -and -not ($failed -is [bool])) { return 'failed' }
    $target = Get-NSMapValue $Document 'workTarget'
    if ($null -ne $target) {
        if (-not ($target -is [string]) -or $target.Length -eq 0) { return 'workTarget' }
    }
    $touched = Get-NSMapValue $Document 'touched'
    if ($null -ne $touched) {
        if (($touched -is [string]) -or ($touched -is [Collections.IDictionary]) -or -not ($touched -is [Collections.IEnumerable])) {
            return 'touched'
        }
        foreach ($entry in @($touched)) {
            if (-not ($entry -is [string])) { return 'touched' }
        }
    }
    $baseline = Get-NSMapValue $Document 'baseline'
    if ($null -ne $baseline) {
        if (-not ($baseline -is [Collections.IDictionary])) { return 'baseline' }
    }
    return ''
}

# The baseline gate needs the work target, so it runs once the target is known:
# each entry is an object, says whether the file existed, carries a digest when
# it did, names a blob the store can address, and stays inside the target. The
# digest itself is compared, never shape-checked.
function Test-NSProvisionBaseline {
    param($Baseline, [Parameter(Mandatory = $true)][string]$Target)
    if ($null -eq $Baseline) { return '' }
    if (-not ($Baseline -is [Collections.IDictionary])) { return 'baseline' }
    foreach ($rel in (Sort-NSOrdinal @($Baseline.Keys))) {
        $label = 'baseline["' + [string]$rel + '"]'
        $meta = $Baseline[$rel]
        if (-not ($meta -is [Collections.IDictionary])) { return $label }
        $existed = Get-NSMapValue $meta 'existed'
        if (-not ($existed -is [bool])) { return ($label + '.existed') }
        try {
            $null = Resolve-NSProvisionPath $Target ([string]$rel)
        }
        catch {
            return $label
        }
        $blob = Get-NSMapValue $meta 'blob'
        if (($null -ne $blob) -and -not (Test-NSPolicyDigest $blob)) { return ($label + '.blob') }
        if (-not [bool]$existed) { continue }
        $digest = Get-NSMapValue $meta 'digest'
        if (-not ($digest -is [string]) -or $digest.Length -eq 0) { return ($label + '.digest') }
    }
    return ''
}

function Get-NSProvisionTouched {
    param($Transaction)
    $touched = New-Object Collections.Generic.List[string]
    $recorded = Get-NSMapValue $Transaction 'touched'
    if ($null -ne $recorded) {
        foreach ($entry in @($recorded)) { $touched.Add([string]$entry) }
    }
    return , $touched.ToArray()
}

# The blob store holds the original bytes; the base64 copy in the transaction is
# the fallback when the store is gone. Neither one usable returns nothing, and a
# restore with nothing to restore from leaves the file alone for the proof to
# report - it never invents empty content.
function Get-NSProvisionRestoreBytes {
    param(
        [Parameter(Mandatory = $true)][string]$BaselineDir,
        [Parameter(Mandatory = $true)]$Meta
    )
    $blob = Get-NSMapValue $Meta 'blob'
    if (($blob -is [string]) -and $blob.Length -gt 0) {
        $blobPath = Join-NSPath $BaselineDir $blob
        if (Test-Path -LiteralPath $blobPath -PathType Leaf) {
            return , ([IO.File]::ReadAllBytes($blobPath))
        }
    }
    $content = Get-NSMapValue $Meta 'content'
    if (($content -is [string]) -and $content.Length -gt 0) {
        $decoded = $null
        try {
            $decoded = [Convert]::FromBase64String($content)
        }
        catch {
            return $null
        }
        return , $decoded
    }
    return $null
}

# A real directory where a file has to land is the owner's, not ours: the restore
# steps over it and the proof names it.
function Test-NSProvisionDirectoryBlock {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (Test-NSReparsePoint $Path) { return $false }
    return (Test-Path -LiteralPath $Path -PathType Container)
}

# The restore lands by rename, so a reader never sees half a file, and it
# replaces a symlink rather than writing through it.
function Write-NSProvisionRestoredFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]]$Bytes
    )
    $temp = $Path + '.nightshift-restore'
    Remove-NSFile $temp
    [IO.File]::WriteAllBytes($temp, $Bytes)
    if (Test-NSReparsePoint $Path) {
        try {
            [IO.File]::Delete($Path)
        }
        catch {
            [IO.Directory]::Delete($Path)
        }
    }
    elseif (Test-Path -LiteralPath $Path -PathType Leaf) {
        Remove-NSFile $Path
    }
    [IO.File]::Move($temp, $Path)
}

# rmdir up the tree: a directory the engine created and nothing else needs goes
# away, and the walk stops at the work target itself.
function Remove-NSProvisionEmptyParents {
    param(
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string]$Path
    )
    $head = (Get-NSAbsolutePath $Target) + [string][IO.Path]::DirectorySeparatorChar
    $parent = [IO.Path]::GetDirectoryName($Path)
    while ((-not [string]::IsNullOrEmpty($parent)) -and $parent.StartsWith($head, [StringComparison]::Ordinal)) {
        try {
            [IO.Directory]::Delete($parent)
        }
        catch {
            return
        }
        $parent = [IO.Path]::GetDirectoryName($parent)
    }
}

function Invoke-NSProvisionRestore {
    param(
        [Parameter(Mandatory = $true)][string]$BaselineDir,
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)]$Baseline
    )
    foreach ($rel in (Sort-NSOrdinal @($Baseline.Keys))) {
        $meta = $Baseline[$rel]
        $path = Resolve-NSProvisionPath $Target $rel
        if (Test-NSPyTruthy (Get-NSMapValue $meta 'existed')) {
            if (Test-NSProvisionDirectoryBlock $path) { continue }
            $bytes = Get-NSProvisionRestoreBytes -BaselineDir $BaselineDir -Meta $meta
            if ($null -eq $bytes) { continue }
            $parent = [IO.Path]::GetDirectoryName($path)
            if ((-not [string]::IsNullOrEmpty($parent)) -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
                $null = New-Item -ItemType Directory -Path $parent -Force
            }
            Write-NSProvisionRestoredFile -Path $path -Bytes ([byte[]]$bytes)
            continue
        }
        if (Test-NSReparsePoint $path) {
            try {
                [IO.File]::Delete($path)
            }
            catch {
                [IO.Directory]::Delete($path)
            }
        }
        elseif (Test-Path -LiteralPath $path -PathType Leaf) {
            Remove-NSFile $path
        }
        Remove-NSProvisionEmptyParents -Target $Target -Path $path
    }
}

# The proof, after the restore: every file that existed hashes to its recorded
# digest and every file the engine created is gone. The first failure is the one
# reported, and it leaves the transaction and the store where they are.
function Test-NSProvisionRestored {
    param(
        [Parameter(Mandatory = $true)][string]$Target,
        $Baseline
    )
    if ($null -eq $Baseline) { return '' }
    foreach ($rel in (Sort-NSOrdinal @($Baseline.Keys))) {
        $meta = $Baseline[$rel]
        $path = Resolve-NSProvisionPath $Target $rel
        if (Test-NSPyTruthy (Get-NSMapValue $meta 'existed')) {
            if (Test-NSProvisionDirectoryBlock $path) {
                return ('a directory blocks the baseline path: ' + [string]$rel)
            }
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                return ('baseline file missing after restore: ' + [string]$rel)
            }
            if ((Get-NSFileSha256 $path) -cne [string](Get-NSMapValue $meta 'digest')) {
                return ('restored bytes do not match baseline digest: ' + [string]$rel)
            }
            continue
        }
        if (Test-NSPathEntry $path) { return ('created path still present: ' + [string]$rel) }
    }
    return ''
}

# Read-only twin of the proof: the bytes the store and the transaction hold for
# every file that existed already hash to the recorded digest, so a rollback
# would prove. Doctor and diagnose report this and restore nothing.
function Test-NSProvisionProvable {
    param(
        [Parameter(Mandatory = $true)][string]$BaselineDir,
        $Baseline
    )
    if ($null -eq $Baseline) { return $true }
    foreach ($rel in (Sort-NSOrdinal @($Baseline.Keys))) {
        $meta = $Baseline[$rel]
        if (-not (Test-NSPyTruthy (Get-NSMapValue $meta 'existed'))) { continue }
        $bytes = Get-NSProvisionRestoreBytes -BaselineDir $BaselineDir -Meta $meta
        if ($null -eq $bytes) { return $false }
        if ((Get-NSProvisionByteSha256 ([byte[]]$bytes)) -cne [string](Get-NSMapValue $meta 'digest')) { return $false }
    }
    return $true
}

function Get-NSProvisionRequiredFields {
    $fields = $null
    try {
        $fields = Get-NSJsonProperty (Get-NSSchemaDocument 'capability-recipe.json') 'requiredRecipeFields'
    }
    catch {
        $fields = $null
    }
    $names = New-Object Collections.Generic.List[string]
    if (($null -ne $fields) -and -not ($fields -is [string])) {
        foreach ($field in @($fields)) {
            if ($field -is [string]) { $names.Add($field) }
        }
    }
    if ($names.Count -eq 0) { return , @($script:NSProvisionRequiredFields) }
    return , $names.ToArray()
}

function Get-NSJsonStringList {
    param(
        $Value,
        [Parameter(Mandatory = $true)][string]$FieldName
    )
    $message = $FieldName + ' must be a list of relative paths'
    if ($null -eq $Value) { return @() }
    if ($Value -is [Collections.IDictionary]) { throw $message }
    if ($Value -is [string]) {
        if ($Value.Length -eq 0) { throw $message }
        return @($Value)
    }
    if (-not ($Value -is [Collections.IEnumerable])) { throw $message }
    $items = New-Object Collections.Generic.List[string]
    foreach ($entry in @($Value)) {
        if (($entry -is [Collections.IEnumerable]) -and -not ($entry -is [string])) {
            foreach ($nested in @($entry)) {
                if (-not ($nested -is [string]) -or $nested.Length -eq 0) { throw $message }
                $items.Add($nested)
            }
            continue
        }
        if (-not ($entry -is [string]) -or $entry.Length -eq 0) { throw $message }
        $items.Add($entry)
    }
    return , $items.ToArray()
}

function Read-NSProvisionRecipe {
    param([Parameter(Mandatory = $true)][string]$Path)
    $recipe = ConvertFrom-NSJsonText ([IO.File]::ReadAllText($Path, $script:NSUtf8NoBom))
    if (-not ($recipe -is [Collections.IDictionary])) { throw 'recipe must be an object' }
    $missing = New-Object Collections.Generic.List[string]
    foreach ($field in (Get-NSProvisionRequiredFields)) {
        if (-not $recipe.Contains($field)) { $missing.Add($field) }
    }
    if ($missing.Count -gt 0) { throw ('missing fields: ' + ($missing -join ', ')) }
    $recipe['allowedFiles'] = Get-NSJsonStringList (Get-NSMapValue $recipe 'allowedFiles') 'allowedFiles'
    return $recipe
}

function Get-NSProvisionAllowedFiles {
    param($Recipe)
    $allowed = New-Object Collections.Generic.List[string]
    $declared = Get-NSMapValue $Recipe 'allowedFiles'
    if (($null -ne $declared) -and -not ($declared -is [string])) {
        foreach ($entry in @($declared)) { $allowed.Add((Get-NSProvisionRelPath ([string]$entry))) }
    }
    elseif ($declared -is [string]) {
        $allowed.Add((Get-NSProvisionRelPath $declared))
    }
    return , $allowed.ToArray()
}

function Test-NSProvisionUnderAllowed {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Rel,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Allowed
    )
    $candidate = Get-NSProvisionRelPath $Rel
    foreach ($entry in $Allowed) {
        $normalized = Get-NSProvisionRelPath $entry
        if ($candidate -ceq $normalized) { return $true }
        if ($candidate.StartsWith($normalized.TrimEnd('/') + '/', [StringComparison]::Ordinal)) { return $true }
    }
    return $false
}

function Get-NSProvisionCommandText {
    param($Step)
    if ($Step -is [Collections.IDictionary]) {
        foreach ($key in @('command', 'cmd')) {
            $value = Get-NSMapValue $Step $key
            if (($value -is [string]) -and $value.Length -gt 0) { return $value }
        }
        return ''
    }
    if ($Step -is [string]) { return $Step }
    return ''
}

function Test-NSProvisionGitTarget {
    param([Parameter(Mandatory = $true)][string]$Target)
    $result = Invoke-NSGitCommand $Target @('rev-parse', '--is-inside-work-tree')
    if ($result.ExitCode -ne 0) { return $false }
    return (([string]$result.Text).Trim() -ceq 'true')
}

function Get-NSProvisionPorcelain {
    param(
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Paths
    )
    $lines = New-Object Collections.Generic.List[string]
    if ($Paths.Count -eq 0) { return , $lines.ToArray() }
    if (-not (Test-NSProvisionGitTarget $Target)) { return , $lines.ToArray() }
    $result = Invoke-NSGitCommand $Target (@('status', '--porcelain', '--') + $Paths)
    if ($result.ExitCode -ne 0) { return , $lines.ToArray() }
    foreach ($line in @($result.Lines)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$line)) { $lines.Add([string]$line) }
    }
    return , $lines.ToArray()
}

function Get-NSProvisionInventory {
    param([Parameter(Mandatory = $true)][string]$Project)
    $path = (Get-NSProvisionPaths $Project)['inventory']
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        $document = New-NSOrdinalMap
        $document['schemaVersion'] = 1
        $document['source'] = 'default'
        $document['items'] = @()
        $document['updatedAt'] = $null
        $document['tickProof'] = $false
        return $document
    }
    $document = ConvertFrom-NSJsonText ([IO.File]::ReadAllText($path, $script:NSUtf8NoBom))
    if (-not ($document -is [Collections.IDictionary])) { throw 'inventory must be an object' }
    return $document
}

# One row per capability, replaced in place. schemaVersion, updatedAt and
# tickProof are the writer's, never the caller's.
function Write-NSProvisionInventory {
    param(
        [Parameter(Mandatory = $true)][string]$Project,
        [Parameter(Mandatory = $true)]$Recipe,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$SetupCommit
    )
    $paths = Get-NSProvisionPaths $Project
    $document = $null
    try {
        $document = Get-NSProvisionInventory $Project
    }
    catch {
        $document = New-NSOrdinalMap
        $document['items'] = @()
    }
    $capability = [string](Get-NSMapValue $Recipe 'capabilityId')
    $items = New-Object Collections.Generic.List[object]
    $recorded = Get-NSMapValue $document 'items'
    if (($null -ne $recorded) -and -not ($recorded -is [string])) {
        foreach ($item in @($recorded)) {
            if (-not ($item -is [Collections.IDictionary])) { continue }
            if ([string](Get-NSMapValue $item 'capability') -ceq $capability) { continue }
            $items.Add($item)
        }
    }
    $row = New-NSOrdinalMap
    $row['capability'] = $capability
    $row['command'] = Get-NSProvisionCommandText (Get-NSMapValue $Recipe 'smoke')
    $row['source'] = 'recipe'
    $row['verifiedAt'] = Get-NSProvisionNow
    $row['configFiles'] = Get-NSPolicyField $Recipe 'allowedFiles'
    $row['recipeVersion'] = Get-NSMapValue $Recipe 'recipeVersion'
    $row['setupCommit'] = $SetupCommit
    $items.Add($row)
    $document['items'] = $items.ToArray()
    $document['schemaVersion'] = 1
    $document['updatedAt'] = Get-NSProvisionNow
    $document['tickProof'] = $false
    Write-NSEvidenceFileAtomic -Path $paths['inventory'] -Text ((ConvertTo-NSCanonicalJson $document) + "`n")
}

# The setup commit: the allowed files the transaction actually touched, staged
# and committed under one subject. Nothing staged is not a failure.
function Invoke-NSProvisionCommitTooling {
    param(
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)]$Recipe,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Touched
    )
    if (-not (Test-NSProvisionGitTarget $Target)) { return '' }
    $allowed = [string[]](Get-NSProvisionAllowedFiles $Recipe)
    $paths = New-Object Collections.Generic.List[string]
    foreach ($rel in $Touched) {
        if (Test-NSProvisionUnderAllowed -Rel $rel -Allowed $allowed) { $paths.Add((Get-NSProvisionRelPath $rel)) }
    }
    if ($paths.Count -eq 0) { return '' }
    foreach ($rel in $paths) {
        $null = Invoke-NSGitCommand $Target @('add', '--', $rel)
    }
    $subject = $script:NSProvisionSetupPrefix + ' ' + [string](Get-NSMapValue $Recipe 'capabilityId')
    $commit = Invoke-NSGitCommand $Target (@('commit', '-m', $subject, '--') + $paths.ToArray())
    if ($commit.ExitCode -ne 0) {
        if ((Get-NSProvisionPorcelain -Target $Target -Paths $paths.ToArray()).Count -eq 0) { return '' }
        throw 'commit-tooling failed'
    }
    $head = Invoke-NSGit $Target @('rev-parse', 'HEAD')
    if ([string]::IsNullOrEmpty($head)) { return '' }
    return $head
}

function Resolve-NSProvisionTarget {
    param([Parameter(Mandatory = $true)][string]$Project)
    $workspace = Get-NSAbsolutePath $Project
    $record = Get-NSLayoutPath (Join-Path $workspace '.nightshift') 'work-target'
    if (Test-Path -LiteralPath $record -PathType Leaf) {
        $lines = [IO.File]::ReadAllLines($record)
        if ($lines.Count -ge 1 -and -not [string]::IsNullOrWhiteSpace($lines[0])) {
            $target = $lines[0].Trim()
            if (-not [IO.Path]::IsPathRooted($target)) {
                $target = Join-Path $workspace $target
            }
            if (Test-Path -LiteralPath $target -PathType Container) {
                return (Get-NSAbsolutePath $target)
            }
        }
    }
    return $workspace
}

function Invoke-NSProvisionRollback {
    param(
        [Parameter(Mandatory = $true)][string]$Project,
        [Parameter(Mandatory = $true)]$Transaction,
        [Parameter(Mandatory = $true)][string]$Target
    )
    $paths = Get-NSProvisionPaths $Project
    $baseline = Get-NSMapValue $Transaction 'baseline'
    $detail = ''
    try {
        if ($null -ne $baseline) {
            Invoke-NSProvisionRestore -BaselineDir $paths['baseline'] -Target $Target -Baseline $baseline
        }
        $detail = Test-NSProvisionRestored -Target $Target -Baseline $baseline
    }
    catch {
        $detail = [string]$_.Exception.Message
    }
    if ($detail.Length -gt 0) {
        $document = New-NSOrdinalMap
        $document['ok'] = $false
        $document['rolledBack'] = $false
        $document['proven'] = $false
        $document['detail'] = $detail
        Write-NSProvisionJson $document
        return 3
    }
    Remove-NSPath $paths['baseline']
    Remove-NSFile $paths['transaction']
    $document = New-NSOrdinalMap
    $document['ok'] = $true
    $document['rolledBack'] = $true
    $document['capabilityId'] = [string](Get-NSMapValue $Transaction 'capabilityId')
    $document['touched'] = Get-NSProvisionTouched $Transaction
    $document['proven'] = $true
    Write-NSProvisionJson $document
    return 0
}

# record and commit-tooling are the two stages that finish rather than undo: the
# inventory row lands, the allowed files are committed under one subject, and the
# transaction goes away.
function Invoke-NSProvisionFinish {
    param(
        [Parameter(Mandatory = $true)][string]$Project,
        [Parameter(Mandatory = $true)]$Transaction,
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)]$Recipe
    )
    $paths = Get-NSProvisionPaths $Project
    $touched = [string[]](Get-NSProvisionTouched $Transaction)
    if ([string](Get-NSMapValue $Transaction 'stage') -ceq 'record') {
        Write-NSProvisionInventory -Project $Project -Recipe $Recipe -SetupCommit ''
        $Transaction['stage'] = 'commit-tooling'
        $Transaction['updatedAt'] = Get-NSProvisionNow
        Write-NSProvisionTransaction -Path $paths['transaction'] -Document $Transaction
    }
    $setup = Invoke-NSProvisionCommitTooling -Target $Target -Recipe $Recipe -Touched $touched
    if ($setup.Length -gt 0) {
        Write-NSProvisionInventory -Project $Project -Recipe $Recipe -SetupCommit $setup
    }
    Remove-NSPath $paths['baseline']
    Remove-NSFile $paths['transaction']
    $document = New-NSOrdinalMap
    $document['ok'] = $true
    $document['recovered'] = $true
    $document['finished'] = $true
    $document['capabilityId'] = Get-NSMapValue $Recipe 'capabilityId'
    $document['setupCommit'] = $setup
    $document['touched'] = $touched
    Write-NSProvisionJson $document
    return 0
}

