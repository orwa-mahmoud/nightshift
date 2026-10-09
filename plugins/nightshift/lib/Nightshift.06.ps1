# The one recovery path, and Start runs it before any product work.
#   0 nothing to recover, rolled back and proven, or late stages finished
#   2 the transaction is malformed - the field is named and nothing is touched
#   3 the restore could not be proven - the transaction and the store stay put
# -Rollback forces the undo whatever the stage; -Diagnose only reports.
# -BudgetSeconds is the engine's argument contract; recovery is bounded by the
# work itself - the recorded files and at most two Git calls - and never
# abandons a restore half done.
function Invoke-NSProvisionRecover {
    param(
        [Parameter(Mandatory = $true)][string]$Project,
        [int]$BudgetSeconds = 0,
        [switch]$Rollback,
        [switch]$Diagnose
    )
    $project = Get-NSAbsolutePath $Project
    if ($Diagnose.IsPresent) { return (Invoke-NSProvisionDiagnose -Project $project) }
    $paths = Get-NSProvisionPaths $project
    if (-not (Test-Path -LiteralPath $paths['transaction'] -PathType Leaf)) {
        $document = New-NSOrdinalMap
        $document['ok'] = $true
        $document['recovered'] = $false
        $document['detail'] = 'no transaction'
        Write-NSProvisionJson $document
        return 0
    }
    $transaction = $null
    # State is a file, never a link: a transaction reached through a reparse
    # point is malformed, not followed.
    if (-not (Test-NSReparsePoint $paths['transaction'])) {
        try {
            $transaction = Read-NSProvisionTransaction $paths['transaction']
        }
        catch {
            $transaction = $null
        }
    }
    $field = 'document'
    if ($null -ne $transaction) { $field = Test-NSProvisionTransaction $transaction }
    $target = ''
    if ($field.Length -eq 0) {
        $target = [string](Get-NSMapValue $transaction 'workTarget')
        if ([string]::IsNullOrEmpty($target)) { $target = Resolve-NSProvisionTarget $project }
        $field = Test-NSProvisionBaseline -Baseline (Get-NSMapValue $transaction 'baseline') -Target $target
    }
    if ($field.Length -gt 0) {
        $document = New-NSOrdinalMap
        $document['ok'] = $false
        $document['recovered'] = $false
        $document['malformed'] = $true
        $document['detail'] = 'malformed transaction: ' + $field
        Write-NSProvisionJson $document
        return 2
    }
    $stage = [string](Get-NSMapValue $transaction 'stage')
    $failed = Test-NSPyTruthy (Get-NSMapValue $transaction 'failed')
    if ($Rollback.IsPresent -or $failed -or ($script:NSProvisionRollbackStages -ccontains $stage)) {
        return (Invoke-NSProvisionRollback -Project $project -Transaction $transaction -Target $target)
    }
    $recipePath = [string](Get-NSMapValue $transaction 'recipePath')
    $recipe = $null
    if ($recipePath.Length -gt 0) {
        try {
            $recipe = Read-NSProvisionRecipe $recipePath
        }
        catch {
            $recipe = $null
        }
    }
    if ($null -eq $recipe) {
        return (Invoke-NSProvisionRollback -Project $project -Transaction $transaction -Target $target)
    }
    try {
        return (Invoke-NSProvisionFinish -Project $project -Transaction $transaction -Target $target -Recipe $recipe)
    }
    catch {
        return (Invoke-NSProvisionRollback -Project $project -Transaction $transaction -Target $target)
    }
}

# What Doctor reads: whether a transaction is open, at which stage, for which
# capability, and whether its baseline would prove. Doctor never restores.
function Get-NSProvisionDiagnosis {
    param([Parameter(Mandatory = $true)][string]$Project)
    $paths = Get-NSProvisionPaths $Project
    $report = New-NSOrdinalMap
    $report['present'] = $false
    $report['malformed'] = ''
    $report['stage'] = ''
    $report['capabilityId'] = ''
    $report['provable'] = $false
    if (Test-NSReparsePoint $paths['transaction']) {
        $report['present'] = $true
        $report['malformed'] = 'document'
        return $report
    }
    if (-not (Test-Path -LiteralPath $paths['transaction'] -PathType Leaf)) { return $report }
    $report['present'] = $true
    $transaction = $null
    try {
        $transaction = Read-NSProvisionTransaction $paths['transaction']
    }
    catch {
        $transaction = $null
    }
    $field = 'document'
    if ($null -ne $transaction) { $field = Test-NSProvisionTransaction $transaction }
    if ($field.Length -gt 0) {
        $report['malformed'] = $field
        return $report
    }
    $report['stage'] = [string](Get-NSMapValue $transaction 'stage')
    $report['capabilityId'] = [string](Get-NSMapValue $transaction 'capabilityId')
    $target = [string](Get-NSMapValue $transaction 'workTarget')
    if ([string]::IsNullOrEmpty($target)) { $target = Resolve-NSProvisionTarget $Project }
    $baseline = Get-NSMapValue $transaction 'baseline'
    $field = Test-NSProvisionBaseline -Baseline $baseline -Target $target
    if ($field.Length -gt 0) {
        $report['malformed'] = $field
        return $report
    }
    $report['provable'] = (Test-NSProvisionProvable -BaselineDir $paths['baseline'] -Baseline $baseline)
    return $report
}

# The class, then the sentence - one tab-separated line, the same on every host.
function Get-NSProvisionDiagnosisClass {
    param([Parameter(Mandatory = $true)]$Report)
    if ([string]$Report['malformed'] -cne '') { return 'malformed' }
    if ($Report['provable']) { return 'provable' }
    return 'unprovable'
}

function Get-NSProvisionDiagnosisLine {
    param([Parameter(Mandatory = $true)]$Report)
    if ([string]$Report['malformed'] -cne '') {
        return ('provision-transaction.json is malformed (' + [string]$Report['malformed'] + ')')
    }
    $state = 'unprovable'
    if ($Report['provable']) { $state = 'provable' }
    return ('provision transaction stage=' + [string]$Report['stage'] + ' capability=' +
        [string]$Report['capabilityId'] + ' baseline=' + $state)
}

# Read-only: no transaction prints nothing at all.
function Invoke-NSProvisionDiagnose {
    param([Parameter(Mandatory = $true)][string]$Project)
    $report = Get-NSProvisionDiagnosis $Project
    if (-not $report['present']) { return 0 }
    Write-NSProvisionOut ((Get-NSProvisionDiagnosisClass $report) + "`t" + (Get-NSProvisionDiagnosisLine $report))
    return 0
}

function Invoke-NSProvisionCommand {
    param(
        [AllowEmptyString()][string]$Project = '',
        [AllowEmptyString()][string]$Command = '',
        [AllowEmptyString()][string]$BudgetSeconds = '',
        [switch]$Rollback,
        [switch]$Diagnose
    )
    if ([string]::IsNullOrEmpty($Project) -or [string]::IsNullOrEmpty($Command)) { return (Write-NSProvisionUsage) }
    $budget = $script:NSProvisionBudgetDefault
    if (-not [string]::IsNullOrEmpty($BudgetSeconds)) {
        if ($BudgetSeconds -cnotmatch '^[0-9]+$') { return (Write-NSProvisionUsage) }
        $budget = [int]$BudgetSeconds
    }
    $workspace = Get-NSAbsolutePath $Project
    if (-not (Test-Path -LiteralPath $workspace -PathType Container)) {
        Write-NSProvisionError ('provision: not a directory: ' + $workspace)
        return 1
    }
    switch ($Command) {
        'recover' {
            return (Invoke-NSProvisionRecover -Project $workspace -BudgetSeconds $budget `
                    -Rollback:$Rollback -Diagnose:$Diagnose)
        }
        'rollback' {
            return (Invoke-NSProvisionRecover -Project $workspace -BudgetSeconds $budget -Rollback)
        }
    }
    return (Write-NSProvisionUsage)
}

# Comparison and morning receipt - the native side of
# runtime/windows/evidence-compare.ps1 and morning-receipt.ps1.
#
# Nothing here reruns a tool or reads a work target for a finding. Every row a
# comparison prints and every line the receipt renders comes from a record
# already in the ledger, cited by id. A tool that failed, a source the ledger
# marked unavailable, and a moved environment digest are reported as
# unavailable - never as improvement.
# ---------------------------------------------------------------------------

$script:NSEvidenceBaselineDomain = 'baseline'
$script:NSEvidenceLifecycleDomains = @('baseline', 'checkpoint')

# The eight classes a comparison assigns, in report order.
$script:NSCompareClasses = @(
    'new', 'cleared', 'unchanged', 'regressed',
    'unavailable', 'rejected-duplicate', 'parked', 'human-only'
)

# Record state to class. First match wins, and the statuses that mean "could not
# be measured" come first so a tool that never ran is never read as a fix.
$script:NSCompareUnavailableStatuses = @('unavailable', 'unsupported', 'unmeasured')
$script:NSCompareHumanStatuses = @('human-only')
$script:NSCompareClearedStatuses = @('fixed')
$script:NSCompareParkedDispositions = @('parked')
$script:NSCompareDuplicateDispositions = @('rejected-duplicate')

# clear-all fails on any of these. no-regression-plus-selected-debt fails only on
# a regression, plus a selected id that did not clear.
$script:NSCompareOutstandingClasses = @('new', 'unchanged', 'regressed', 'unavailable')
$script:NSCompareRegressionClasses = @('regressed')

$script:NSCompareDigestLength = 12
$script:NSCompareTitle = '# Comparison'
$script:NSCompareTableHeader = '| ID | Class | Digest | Sources | Locator |'
$script:NSCompareTableRule = '| --- | --- | --- | --- | --- |'
$script:NSCompareRowFormat = '| {0} | {1} | {2} | {3} | {4} |'
$script:NSCompareEmptyLocator = 'empty'
$script:NSCompareBaselineFormat = 'Baseline: {0} {1} {2} {1} `{3}`'
$script:NSCompareModeFormat = 'Mode: {0}'
$script:NSCompareSourceFormat = 'Source: {0}'
$script:NSCompareResultFormat = 'Result: {0}'
$script:NSComparePassLabel = 'pass'
$script:NSCompareFailLabel = 'fail'
$script:NSCompareSummaryPrefix = 'Summary: '
$script:NSCompareSummaryCellFormat = '{0} {1}'
$script:NSCompareSummarySeparator = ', '
$script:NSCompareSelectedDebtPrefix = 'Selected debt outstanding: '
$script:NSMdPipeEscape = '\|'
$script:NSMdSourceSeparator = ', '

$script:NSReceiptTitle = '# Morning receipt'
$script:NSReceiptViewNames = @('owner', 'reviewer', 'release', 'artifact')
$script:NSReceiptNone = 'none'
$script:NSReceiptEndingUnknown = 'unknown'
$script:NSReceiptFileFormat = 'morning-{0}-{1}.md'
$script:NSReceiptDateFileFormat = 'morning-{0}.md'
$script:NSReceiptFieldFormat = '- {0}: {1}'
$script:NSReceiptNestedFormat = '  - {0}: {1}'
$script:NSReceiptPlainFormat = '- {0}'
$script:NSReceiptItemsFormat = '{0} ticked, {1} open'
$script:NSReceiptPolicyFormat = 'profile {0}, verification {1}, tooling {2}'
$script:NSReceiptAllowanceFormat = '{0} ({1}, {2})'
$script:NSReceiptBaselineFormat = '{0} `{1}` {2} env {3} raw {4} ({5})'
$script:NSReceiptVerifiedNoneFormat = 'none {0} verification level {1} (owner)'
$script:NSReceiptVerifiedNoPolicyFormat = 'none {0} no shift policy was written'
$script:NSReceiptPolicyMalformedReason = 'the policy file is present but unreadable or fails the schema'
$script:NSReceiptVerifiedMalformedFormat = 'none {0} the policy file is present but unreadable or fails the schema'
$script:NSReceiptPolicyAbsentReason = 'the shift wrote no policy'
$script:NSReceiptGatesFormat = '{0} (punch list)'
$script:NSReceiptChosenSource = 'one-shift'
$script:NSReceiptNextFormat = '{0} {1} next: {2}'

# Section headings in receipt order, and the sections each view renders. Same
# data, same conclusions - a view only decides how much of it.

$script:NSReceiptSectionTitle = New-Object Collections.Specialized.OrderedDictionary([StringComparer]::Ordinal)
$script:NSReceiptSectionTitle['shift'] = '## How it ended'
$script:NSReceiptSectionTitle['usage'] = '## Time and tokens'
$script:NSReceiptSectionTitle['items'] = '## Items'
$script:NSReceiptSectionTitle['review'] = '## Review first'
$script:NSReceiptSectionTitle['interruptions'] = '## Interruptions'
$script:NSReceiptSectionTitle['parked'] = '## Decisions for you'
$script:NSReceiptSectionTitle['snags'] = '## Found but not fixed'
$script:NSReceiptSectionTitle['baseline'] = '## Baseline'
$script:NSReceiptSectionTitle['changed'] = '## What changed'
$script:NSReceiptSectionTitle['unsupported'] = '## Unsupported / unmeasured'
$script:NSReceiptSectionTitle['next'] = '## Next step'

$script:NSReceiptViewSections = New-Object Collections.Specialized.OrderedDictionary([StringComparer]::Ordinal)
$script:NSReceiptViewSections['owner'] = @('shift', 'usage', 'items', 'review', 'interruptions', 'parked', 'snags', 'baseline', 'changed', 'unsupported', 'next')
$script:NSReceiptViewSections['reviewer'] = @('review', 'baseline', 'changed')
$script:NSReceiptViewSections['release'] = @('shift', 'changed')
$script:NSReceiptViewSections['artifact'] = @('shift', 'usage', 'items', 'review', 'interruptions', 'parked', 'snags', 'unsupported', 'next')

$script:NSReceiptReviewArtifact = 'Does not apply: an artifact shift is reviewed through its receipts.'
# What the runtime writes into the shift log when something interrupts the night, matched against
# the lowercased line.
$script:NSReceiptInterruptionPattern = 'resume attempt|reviv|resumed session|wedge|api down|(^|[^a-z])stall|stop-work|stopped by|pressed esc|quitting time|past the deadline|silent too long|usage limit'
$script:NSReceiptHandledPattern = ' ' + [char]0x00b7 + ' (' + $script:NSReviewDispositions + ')'

$script:NSReceiptLabels = New-Object Collections.Specialized.OrderedDictionary([StringComparer]::Ordinal)
$script:NSReceiptLabels['shift'] = 'Shift'
$script:NSReceiptLabels['host'] = 'Host'
$script:NSReceiptLabels['workTarget'] = 'Work target'
$script:NSReceiptLabels['started'] = 'Started'
$script:NSReceiptLabels['ended'] = 'Ended'
$script:NSReceiptLabels['ending'] = 'Ending'
$script:NSReceiptLabels['items'] = 'Items'
$script:NSReceiptLabels['commits'] = 'Commits'
$script:NSReceiptLabels['receipts'] = 'Receipts'
$script:NSReceiptLabels['policy'] = 'Policy'
$script:NSReceiptLabels['allowance'] = 'Allowance'
$script:NSReceiptLabels['gates'] = 'Gates'
$script:NSReceiptLabels['verified'] = 'Verified'
$script:NSReceiptLabels['disabled'] = 'Disabled by owner'
$script:NSReceiptLabels['unavailable'] = 'Unavailable'
$script:NSReceiptLabels['default'] = 'Default'
$script:NSReceiptLabels['rollback'] = 'Rollback'
$script:NSReceiptLabels['building'] = 'Building'

# Statuses section 5 owns: a surface nobody measured, and one only a human can.
$script:NSReceiptUnmeasuredStatuses = @('human-only', 'unsupported', 'unmeasured')
$script:NSReceiptVerifiedLadder = 'verified-after-change'

# ---------------------------------------------------------------------------
# Small readers over a parsed record
# ---------------------------------------------------------------------------

function Get-NSEvidenceDash {
    return ([string][char]0x2014)
}

function Get-NSEvidenceJoiner {
    return (' ' + (Get-NSEvidenceDash) + ' ')
}

function Get-NSEvidenceDay {
    $now = Get-NSEvidenceNow
    if ($now -cmatch '^[0-9]{4}-[0-9]{2}-[0-9]{2}') { return $now.Substring(0, 10) }
    return ([DateTime]::UtcNow.ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture))
}

function Get-NSEvidenceLedgerRecords {
    param([Parameter(Mandatory = $true)][string]$Workspace)
    $paths = Get-NSEvidencePaths $Workspace
    $records = Read-NSEvidenceRecords $paths['jsonl']
    if ($null -eq $records) { return , @() }
    if ($records -is [Collections.Generic.List[object]]) {
        return , $records.ToArray()
    }
    return , [object[]]@($records)
}

function Get-NSRecordText {
    param($Record, [Parameter(Mandatory = $true)][string]$Key)
    $value = Get-NSMapValue $Record $Key
    if ($null -eq $value) { return '' }
    if ($value -is [string]) { return $value }
    return (ConvertTo-NSPyText $value)
}

function Get-NSRecordDetails {
    param($Record)
    $details = Get-NSMapValue $Record 'details'
    if ($details -is [Collections.IDictionary]) { return $details }
    return (New-NSOrdinalMap)
}

# A JSON array of strings, a lone string, or nothing - always an array back.
function Get-NSRecordList {
    param($Record, [Parameter(Mandatory = $true)][string]$Key)
    $items = New-Object Collections.Generic.List[string]
    $value = Get-NSMapValue $Record $Key
    if ($null -eq $value) { return , $items.ToArray() }
    if ($value -is [string]) {
        if ($value.Length -gt 0) { $items.Add($value) }
        return , $items.ToArray()
    }
    if ($value -is [Collections.IEnumerable]) {
        foreach ($item in $value) {
            if ($null -eq $item) { continue }
            $text = ConvertTo-NSPyText $item
            if ($text.Length -gt 0) { $items.Add($text) }
        }
    }
    return , $items.ToArray()
}

function Get-NSUniqueSorted {
    param([AllowNull()][AllowEmptyCollection()][string[]]$Items)
    $map = New-NSOrdinalMap
    if ($null -ne $Items) {
        foreach ($item in $Items) {
            if ([string]::IsNullOrEmpty($item)) { continue }
            $map[$item] = $true
        }
    }
    return , (Sort-NSOrdinal ([string[]]@($map.Keys)))
}

function Get-NSCompareShortDigest {
    param([AllowEmptyString()][string]$Digest)
    if ([string]::IsNullOrEmpty($Digest)) { return '' }
    if ($Digest.Length -le $script:NSCompareDigestLength) { return $Digest }
    return $Digest.Substring(0, $script:NSCompareDigestLength)
}

# Reads either shape back: the {digest,id} array this module writes, or a plain
# array of ids from a hand-written record.
function Get-NSBaselineSeenMap {
    param($Baseline)
    $map = New-NSOrdinalMap
    $details = Get-NSRecordDetails $Baseline
    $seen = Get-NSMapValue $details 'seen'
    if ($null -eq $seen) { return $map }
    if ($seen -is [string]) {
        if ($seen.Length -gt 0) { $map[$seen] = '' }
        return $map
    }
    if (-not ($seen -is [Collections.IEnumerable])) { return $map }
    foreach ($entry in $seen) {
        if ($entry -is [Collections.IDictionary]) {
            $id = Get-NSRecordText $entry 'id'
            if ($id.Length -eq 0) { continue }
            $map[$id] = Get-NSRecordText $entry 'digest'
            continue
        }
        if ($null -eq $entry) { continue }
        $id = ConvertTo-NSPyText $entry
        if ($id.Length -gt 0) { $map[$id] = '' }
    }
    return $map
}

# A receipt records what the run knew. A work target that could not be resolved is not the
# workspace by default - naming it would put a path on the morning page that nothing ever chose -
# so this answers with nothing and the field is left out, which is what the POSIX renderer does.
function Get-NSEvidenceWorkTarget {
    param([Parameter(Mandatory = $true)][string]$Workspace)
    try {
        return (Resolve-NSWorkTarget $Workspace)
    }
    catch {
        return ''
    }
}

# ---------------------------------------------------------------------------
# The comparison
# ---------------------------------------------------------------------------

function Get-NSPolicyCompletionModeFrom {
    param($Policy)
    if ($null -eq $Policy) { return $script:NSPolicyCompletionDefault }
    $mode = Get-NSMapValue $Policy 'completionMode'
    if (Test-NSEvidenceEnum $mode $script:NSPolicyCompletionModes) { return [string]$mode }
    return $script:NSPolicyCompletionDefault
}

function Get-NSPolicyCompletionMode {
    param([Parameter(Mandatory = $true)][string]$Workspace)
    $policy = $null
    try {
        $policy = Get-NSShiftPolicy $Workspace
    }
    catch {
        $policy = $null
    }
    return (Get-NSPolicyCompletionModeFrom $policy)
}

function Get-NSPolicySelectedDebt {
    param([Parameter(Mandatory = $true)][string]$Workspace)
    $policy = $null
    try {
        $policy = Get-NSShiftPolicy $Workspace
    }
    catch {
        $policy = $null
    }
    if ($null -eq $policy) { return , @() }
    return (Get-NSUniqueSorted (Get-NSRecordList $policy 'selectedDebt'))
}

# Every originating tool a row stands on. A record that already carries sources
# keeps them; otherwise its own source is the one entry.
function Get-NSRowSources {
    param($Record)
    $sources = Get-NSRecordList $Record 'sources'
    if (@($sources).Count -gt 0) { return , @($sources) }
    $single = Get-NSRecordText $Record 'source'
    if ($single.Length -gt 0) { return , @($single) }
    return , @()
}

# One record, one class. Ordered so an unavailable source is never read as an
# improvement and a duplicate is never read as an outstanding finding.
function Get-NSCompareClass {
    param($Record, $SeenMap, [bool]$EnvironmentMoved)
    $status = Get-NSRecordText $Record 'status'
    $disposition = Get-NSRecordText $Record 'disposition'
    if ($script:NSCompareUnavailableStatuses -ccontains $status) { return 'unavailable' }
    if ($script:NSCompareHumanStatuses -ccontains $status) { return 'human-only' }
    if ($script:NSCompareDuplicateDispositions -ccontains $disposition) { return 'rejected-duplicate' }
    if ((Get-NSRecordText $Record 'duplicateOf').Length -gt 0) { return 'rejected-duplicate' }
    if ($script:NSCompareParkedDispositions -ccontains $disposition) { return 'parked' }
    if ($script:NSCompareClearedStatuses -ccontains $status) {
        if ($EnvironmentMoved) { return 'unavailable' }
        return 'cleared'
    }
    $id = Get-NSRecordText $Record 'id'
    if (-not $SeenMap.Contains($id)) { return 'new' }
    $before = [string]$SeenMap[$id]
    $now = Get-NSRecordText $Record 'digest'
    if ($before.Length -gt 0 -and $now.Length -gt 0 -and -not ($before -ceq $now)) { return 'regressed' }
    return 'unchanged'
}

function Get-NSCompareCounts {
    param($Rows)
    $counts = New-NSOrdinalMap
    foreach ($class in $script:NSCompareClasses) { $counts[$class] = [long]0 }
    foreach ($row in @($Rows)) {
        $class = [string]$row['class']
        if (-not $counts.Contains($class)) { $counts[$class] = [long]0 }
        $counts[$class] = [long]$counts[$class] + 1
    }
    return $counts
}

function Get-NSCompareBaselineRecords {
    param($Records)
    $found = New-Object Collections.Generic.List[object]
    foreach ($record in @($Records)) {
        if ((Get-NSRecordText $record 'domain') -ceq $script:NSEvidenceBaselineDomain) { $found.Add($record) }
    }
    return , $found.ToArray()
}

function Get-NSCompareBaselineSourceClass {
    param($Baseline)
    $sourceClass = Get-NSRecordText (Get-NSRecordDetails $Baseline) 'sourceClass'
    if ($sourceClass.Length -gt 0) { return $sourceClass }
    return (Get-NSRecordText $Baseline 'sourceClass')
}

# Reruns nothing. Reads the records sharing the baseline's source class, keeps
# the last state recorded for each id, and classifies by id and digest.
function Get-NSEvidenceComparison {
    param(
        [Parameter(Mandatory = $true)][string]$Workspace,
        [Parameter(Mandatory = $true)][string]$Baseline,
        $Records = $null,
        [AllowEmptyString()][string]$Mode = '',
        $SelectedDebt = $null
    )
    $all = $Records
    if ($null -eq $all) { $all = Get-NSEvidenceLedgerRecords $Workspace }
    $anchor = $null
    foreach ($record in (Get-NSCompareBaselineRecords $all)) {
        if ((Get-NSRecordText $record 'id') -ceq $Baseline) {
            $anchor = $record
            break
        }
    }
    if ($null -eq $anchor) {
        throw (New-NSEvidenceHalt ('evidence-compare: unknown baseline ' + $Baseline))
    }
    $details = Get-NSRecordDetails $anchor
    $sourceClass = Get-NSCompareBaselineSourceClass $anchor
    $environment = Get-NSRecordText $details 'environmentDigest'
    $seenMap = Get-NSBaselineSeenMap $anchor

    # A second baseline for the same source class taken in another environment
    # means the two measurements are not comparable. Nothing may clear against
    # this baseline until the environment matches again.
    $environmentMoved = $false
    foreach ($record in (Get-NSCompareBaselineRecords $all)) {
        if ((Get-NSRecordText $record 'id') -ceq $Baseline) { continue }
        if (-not ((Get-NSCompareBaselineSourceClass $record) -ceq $sourceClass)) { continue }
        $other = Get-NSRecordText (Get-NSRecordDetails $record) 'environmentDigest'
        if ($other.Length -eq 0 -or $environment.Length -eq 0) { continue }
        if (-not ($other -ceq $environment)) { $environmentMoved = $true }
    }

    # The source speaks for itself, above every row. A baseline of this source taken at or after
    # the chosen one that reports itself unavailable means the tool did not run: nothing it did
    # not say can be read as an improvement, and an empty answer is not a clean one.
    $sourceUnavailable = $false
    $reached = $false
    foreach ($record in (Get-NSCompareBaselineRecords $all)) {
        if ((Get-NSRecordText $record 'id') -ceq $Baseline) { $reached = $true }
        if (-not $reached) { continue }
        if (-not ((Get-NSCompareBaselineSourceClass $record) -ceq $sourceClass)) { continue }
        if ($script:NSCompareUnavailableStatuses -ccontains (Get-NSRecordText $record 'status')) {
            $sourceUnavailable = $true
        }
    }

    $current = New-NSOrdinalMap
    foreach ($record in @($all)) {
        if ($script:NSEvidenceLifecycleDomains -ccontains (Get-NSRecordText $record 'domain')) { continue }
        if (-not ((Get-NSRecordText $record 'sourceClass') -ceq $sourceClass)) { continue }
        $id = Get-NSRecordText $record 'id'
        if ($id.Length -eq 0) { continue }
        $current[$id] = $record
    }

    # A rejected duplicate never erases its tool: its source joins the surviving
    # finding's row and the duplicate keeps a row of its own.
    $extraSources = New-NSOrdinalMap
    foreach ($key in @($current.Keys)) {
        $record = $current[$key]
        $survivor = Get-NSRecordText $record 'duplicateOf'
        if ($survivor.Length -eq 0) { continue }
        if (-not $extraSources.Contains($survivor)) {
            $extraSources[$survivor] = New-Object Collections.Generic.List[string]
        }
        foreach ($source in (Get-NSRowSources $record)) { $extraSources[$survivor].Add([string]$source) }
    }

    $union = New-NSOrdinalMap
    foreach ($key in @($current.Keys)) { $union[[string]$key] = $true }
    foreach ($key in @($seenMap.Keys)) { $union[[string]$key] = $true }

    $command = Get-NSRecordText $details 'command'
    $rows = New-Object Collections.Generic.List[object]
    foreach ($id in (Sort-NSOrdinal ([string[]]@($union.Keys)))) {
        $row = New-NSOrdinalMap
        $row['id'] = [string]$id
        if ($current.Contains($id)) {
            $record = $current[$id]
            $row['class'] = Get-NSCompareClass $record $seenMap $environmentMoved
            $row['digest'] = Get-NSRecordText $record 'digest'
            $row['locator'] = Get-NSRecordText $record 'locator'
            $sources = New-Object Collections.Generic.List[string]
            foreach ($source in (Get-NSRowSources $record)) { $sources.Add([string]$source) }
            if ($extraSources.Contains($id)) {
                foreach ($source in $extraSources[$id]) { $sources.Add([string]$source) }
            }
            $row['sources'] = Get-NSUniqueSorted ([string[]]$sources.ToArray())
        }
        else {
            # An id the baseline saw and the ledger no longer carries is not a
            # fix: absence is not evidence. Environment-moved absence is never
            # cleared either - the two hosts agree.
            $row['class'] = 'unavailable'
            $row['digest'] = [string]$seenMap[$id]
            $row['locator'] = ''
            $row['sources'] = Get-NSUniqueSorted ([string[]]@($command))
        }
        if ($sourceUnavailable) { $row['class'] = 'unavailable' }
        $rows.Add($row)
    }

    $mode = $Mode
    if ([string]::IsNullOrEmpty($mode)) { $mode = Get-NSPolicyCompletionMode $Workspace }
    if (-not ($script:NSPolicyCompletionModes -ccontains $mode)) { $mode = $script:NSPolicyCompletionDefault }
    $selected = $SelectedDebt
    if ($null -eq $selected) { $selected = Get-NSPolicySelectedDebt $Workspace }

    $outstanding = New-Object Collections.Generic.List[string]
    foreach ($id in @($selected)) {
        $cleared = $false
        foreach ($row in $rows) {
            if ((([string]$row['id']) -ceq ([string]$id)) -and (([string]$row['class']) -ceq 'cleared')) {
                $cleared = $true
            }
        }
        if (-not $cleared) { $outstanding.Add([string]$id) }
    }

    $pass = $true
    if ($mode -ceq 'no-regression-plus-selected-debt') {
        foreach ($row in $rows) {
            if ($script:NSCompareRegressionClasses -ccontains ([string]$row['class'])) { $pass = $false }
        }
        if ($outstanding.Count -gt 0) { $pass = $false }
    }
    else {
        if ($sourceUnavailable -or $environmentMoved) { $pass = $false }
        foreach ($row in $rows) {
            if ($script:NSCompareOutstandingClasses -ccontains ([string]$row['class'])) { $pass = $false }
        }
    }

    $counts = Get-NSCompareCounts $rows.ToArray()
    $summary = New-NSOrdinalMap
    foreach ($class in $script:NSCompareClasses) { $summary[$class] = [long]$counts[$class] }
    $summary['selectedDebtOutstanding'] = Get-NSUniqueSorted ([string[]]$outstanding.ToArray())
    $summary['total'] = [long]$rows.Count

    $document = New-NSOrdinalMap
    $document['baseline'] = $Baseline
    $document['mode'] = $mode
    $document['pass'] = $pass
    $document['rows'] = $rows.ToArray()
    $document['schemaVersion'] = 1
    $document['sourceStatus'] = if ($sourceUnavailable -or $environmentMoved) { 'unavailable' } else { 'available' }
    $document['summary'] = $summary

    $result = New-NSOrdinalMap
    $result['document'] = $document
    $result['record'] = $anchor
    $result['sourceClass'] = $sourceClass
    $result['command'] = $command
    $result['environmentMoved'] = $environmentMoved
    return $result
}

function Get-NSMdCell {
    param([AllowEmptyString()][string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return (Get-NSEvidenceDash) }
    return ($Text.Replace('|', $script:NSMdPipeEscape))
}

function Get-NSCompareRowLine {
    param($Row)
    $id = Get-NSMdCell ([string]$Row['id'])
    $class = Get-NSMdCell ([string]$Row['class'])
    $digest = Get-NSMdCell (Get-NSCompareShortDigest ([string]$Row['digest']))
    $sources = Get-NSMdCell ((@($Row['sources']) -join $script:NSMdSourceSeparator))
    $locator = Get-NSMdCell ([string]$Row['locator'])
    return ($script:NSCompareRowFormat -f $id, $class, $digest, $sources, $locator)
}

function Get-NSCompareTableLines {
    param($Rows, [string]$SourceStatus = 'available')
    $lines = New-Object Collections.Generic.List[string]
    $lines.Add($script:NSCompareTableHeader)
    $lines.Add($script:NSCompareTableRule)
    $count = 0
    foreach ($row in @($Rows)) {
        $lines.Add((Get-NSCompareRowLine $row))
        $count++
    }
    if ($count -eq 0) {
        # An empty table says why it is empty: a source that ran and found nothing is not the
        # same answer as a source that never ran.
        $dash = Get-NSEvidenceDash
        $why = $script:NSCompareEmptyLocator
        if ($SourceStatus -ceq 'unavailable') { $why = 'unavailable' }
        $lines.Add(($script:NSCompareRowFormat -f $dash, $dash, $dash, $dash, $why))
    }
    return , $lines.ToArray()
}

function Get-NSCompareSummaryLines {
    param($Counts, $Outstanding)
    $cells = New-Object Collections.Generic.List[string]
    foreach ($class in $script:NSCompareClasses) {
        $value = [long]0
        if ($Counts.Contains($class)) { $value = [long]$Counts[$class] }
        $cells.Add(($script:NSCompareSummaryCellFormat -f $class, $value))
    }
    $lines = New-Object Collections.Generic.List[string]
    $lines.Add($script:NSCompareSummaryPrefix + (($cells -join $script:NSCompareSummarySeparator)))
    $ids = @($Outstanding)
    if ($ids.Count -gt 0) {
        $lines.Add($script:NSCompareSelectedDebtPrefix + (($ids -join $script:NSCompareSummarySeparator)))
    }
    return , $lines.ToArray()
}

function Get-NSCompareResultLabel {
    param($Pass)
    if ([bool]$Pass) { return $script:NSComparePassLabel }
    return $script:NSCompareFailLabel
}

function Get-NSCompareMarkdown {
    param($Comparison)
    $document = $Comparison['document']
    $dash = Get-NSEvidenceDash
    $lines = New-Object Collections.Generic.List[string]
    $lines.Add($script:NSCompareTitle)
    $lines.Add('')
    $lines.Add(($script:NSCompareBaselineFormat -f ([string]$document['baseline']), $dash, `
        ([string]$Comparison['sourceClass']), ([string]$Comparison['command'])))
    $lines.Add(($script:NSCompareModeFormat -f ([string]$document['mode'])))
    $lines.Add(($script:NSCompareSourceFormat -f ([string]$document['sourceStatus'])))
    $lines.Add(($script:NSCompareResultFormat -f (Get-NSCompareResultLabel $document['pass'])))
    $lines.Add('')
    foreach ($line in (Get-NSCompareTableLines $document['rows'] ([string]$document['sourceStatus']))) { $lines.Add($line) }
    $lines.Add('')
    $summary = $document['summary']
    foreach ($line in (Get-NSCompareSummaryLines $summary $summary['selectedDebtOutstanding'])) { $lines.Add($line) }
    return (($lines -join "`n") + "`n")
}

# ---------------------------------------------------------------------------
# The morning receipt
# ---------------------------------------------------------------------------

# The gate writes this path in end_shift and the archive helper moves the file
# from it. UTC, so a shift that crosses local midnight still files under the day
# the ledger stamped. A shift that wrote no policy has no id, and the date alone
# names its receipt.
function Get-NSMorningReceiptPath {
    param([Parameter(Mandatory = $true)][string]$Workspace)
    $shiftId = ''
    $policy = $null
    try {
        $policy = Get-NSShiftPolicy $Workspace
    }
    catch {
        $policy = $null
    }
    if ($null -ne $policy) {
        $candidate = Get-NSRecordText $policy 'shiftId'
        if ($candidate.Length -gt 0) { $shiftId = $candidate }
    }
    if ($shiftId.Length -gt 0) {
        $name = $script:NSReceiptFileFormat -f (Get-NSEvidenceDay), $shiftId
    }
    else {
        $name = $script:NSReceiptDateFileFormat -f (Get-NSEvidenceDay)
    }
    return (Join-NSPath (Get-NSReceiptsDir (Get-NSAbsolutePath $Workspace)) $name)
}

function Write-NSMorningReceiptFile {
    param([Parameter(Mandatory = $true)][string]$Workspace)
    $path = Get-NSMorningReceiptPath $Workspace
    # A page already standing for this shift is the one the owner asked for - a custom handoff
    # the model wrote, or the page a duplicate stop event already rendered. Neither is replaced.
    if (Test-Path -LiteralPath $path) { return $path }
    $view = Get-NSHandoffView $Workspace
    $null = Get-NSMorningReceipt -Workspace $Workspace -View $view -Out $path
    # The receipts index links the page it now has.
    if (Test-NSReceiptsEnabled $Workspace) { Write-NSReceiptsIndex $Workspace }
    return $path
}

# Get-NSHandoffView <workspace> - the reader the owner configured, or owner.
function Get-NSHandoffView {
    param([Parameter(Mandatory = $true)][string]$Workspace)
    $block = Get-NSHandoffBlock $Workspace
    if ($null -ne $block) {
        $view = Get-NSMapValue $block 'view'
        if ($script:NSReceiptViewNames -ccontains $view) { return [string]$view }
    }
    return 'owner'
}

# Test-NSHandoffEnabled <workspace> - false only when the owner turned the page off. A shift that
# writes no page still keeps every factual record it made.
function Test-NSHandoffEnabled {
    param([Parameter(Mandatory = $true)][string]$Workspace)
    $block = Get-NSHandoffBlock $Workspace
    if ($null -eq $block) { return $true }
    if (-not $block.Contains('enabled')) { return $true }
    return ([bool]$block['enabled'])
}

function Get-NSHandoffBlock {
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
    if (-not $document.Contains('handoff')) { return $null }
    $block = $document['handoff']
    if (-not ($block -is [Collections.IDictionary])) { return $null }
    return $block
}

# Get-NSReceiptLocalStamp <epoch> - that moment in this machine's local time to the second, with its UTC
# offset (Get-NSLocalTime).
function Get-NSReceiptLocalStamp {
    param([AllowEmptyString()][string]$Epoch)
    return (Get-NSLocalTime $Epoch -Seconds)
}

# Get-NSReceiptEndedEpoch <nightshift-dir> - when the clock-out gate wrote .ended, or ''.
function Get-NSReceiptEndedEpoch {
    param([Parameter(Mandatory = $true)][string]$NightshiftDir)
    $path = Get-NSLayoutPath $NightshiftDir 'ended'
    if ((Test-NSReparsePoint $path) -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { return '' }
    $utc = New-Object DateTime 1970, 1, 1, 0, 0, 0, ([DateTimeKind]::Utc)
    return [string][long][math]::Floor(([IO.File]::GetLastWriteTimeUtc($path) - $utc).TotalSeconds)
}

# Get-NSReceiptScrubbedLines <file> - the file's lines with every control character read as a space.
function Get-NSReceiptScrubbedLines {
    param([Parameter(Mandatory = $true)][string]$Path)
    if ((Test-NSReparsePoint $Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return , @() }
    $text = ''
    try { $text = [IO.File]::ReadAllText($Path, $script:NSUtf8NoBom) }
    catch { return , @() }
    if ($text.Length -eq 0) { return , @() }
    if ($text.EndsWith("`n", [StringComparison]::Ordinal)) { $text = $text.Substring(0, $text.Length - 1) }
    $lines = New-Object Collections.Generic.List[string]
    foreach ($line in $text.Split("`n")) { $lines.Add(($line -creplace '[\x00-\x1f\x7f]', ' ')) }
    return , $lines.ToArray()
}

# Get-NSReceiptShiftLogLines <shift-log> interruptions|handover - lines written since the last
# `shift started`: every interruption the runtime recorded, or the last handover line.
function Get-NSReceiptShiftLogLines {
    param([Parameter(Mandatory = $true)][string]$Path, [ValidateSet('interruptions', 'handover')][string]$Want)
    $out = New-Object Collections.Generic.List[string]
    $all = Get-NSReceiptScrubbedLines $Path
    $start = -1
    for ($i = 0; $i -lt $all.Length; $i++) {
        if ($all[$i].ToLowerInvariant().Contains('shift started')) { $start = $i }
    }
    $last = ''
    for ($i = $start + 1; $i -lt $all.Length; $i++) {
        $line = $all[$i].Trim(' ')
        if ($line.Length -eq 0) { continue }
        $lower = $line.ToLowerInvariant()
        if ($Want -ceq 'handover') {
            if ($lower.Contains('handover')) { $last = $line }
        }
        elseif ($lower -cmatch $script:NSReceiptInterruptionPattern) {
            $out.Add($line)
        }
    }
    if ($Want -ceq 'handover' -and $last.Length -gt 0) { $out.Add($last) }
    return , $out.ToArray()
}

# Get-NSReceiptMarks <nightshift-dir> - the usage marks in the order they were written.
function Get-NSReceiptMarks {
    param([Parameter(Mandatory = $true)][string]$NightshiftDir)
    $marks = New-Object Collections.Generic.List[object]
    $file = Get-NSUsageMarksPath $NightshiftDir
    if ((Test-NSReparsePoint $file) -or -not (Test-Path -LiteralPath $file -PathType Leaf)) { return , $marks.ToArray() }
    foreach ($line in @([IO.File]::ReadAllLines($file))) {
        $parts = $line.Split("`t")
        $at = 0L
        if ($parts[0] -cnotmatch '^[0-9]+$' -or -not [long]::TryParse($parts[0], [ref]$at)) { continue }
        $label = $(if ($parts.Length -ge 2) { $parts[1] } else { '' })
        $marks.Add([pscustomobject]@{ Epoch = $at; Label = $label })
    }
    return , $marks.ToArray()
}

# Get-NSReceiptCount <n> <noun> - "1 file", "3 files".
function Get-NSReceiptCount {
    param([long]$Count, [Parameter(Mandatory = $true)][string]$Noun)
    if ($Count -eq 1) { return ('1 ' + $Noun) }
    return ([string]$Count + ' ' + $Noun + 's')
}

# Get-NSReceiptItemLink <workspace> <label> <id> - the label, linked to its item receipt when that
# file exists.
function Get-NSReceiptItemLink {
    param(
        [Parameter(Mandatory = $true)][string]$Workspace,
        [Parameter(Mandatory = $true)][string]$Label,
        [AllowEmptyString()][string]$Id = ''
    )
    $base = Get-NSReceiptBase $Workspace $Label $Id
    if ([string]::IsNullOrEmpty($base)) { return $Label }
    $path = Join-Path (Get-NSReceiptsDir $Workspace) ($base + '.md')
    if ((Test-NSReparsePoint $path) -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { return $Label }
    return ('[{0}](./{1}.md)' -f $Label, $base)
}

# done when every box is ticked, otherwise whatever STOP says. Stop writes
# "<reason> MIDDOT <timestamp>"; the gate writes the bare word.
function Get-NSReceiptEnding {
    param([Parameter(Mandatory = $true)][string]$NightshiftDir, [int]$Open, [bool]$Readable = $true)
    $stop = Get-NSLayoutPath $NightshiftDir 'stop'
    if (Test-Path -LiteralPath $stop -PathType Leaf) {
        $first = ''
        try {
            $first = [string](([IO.File]::ReadLines($stop) | Select-Object -First 1) -as [string])
        }
        catch {
            $first = ''
        }
        if ($null -eq $first) { $first = '' }
        $at = $first.IndexOf([char]0x00b7)
        if ($at -ge 0) { $first = $first.Substring(0, $at) }
        $reason = $first.Trim()
        if ($reason -ceq 'deadline') { return 'deadline' }
        if ($reason -ceq 'stalled') { return 'stall' }
        return 'stop'
    }
    if (-not $Readable) { return $script:NSReceiptEndingUnknown }
    if ($Open -eq 0) { return 'done' }
    return $script:NSReceiptEndingUnknown
}

function Get-NSReceiptCommitCount {
    param(
        [Parameter(Mandatory = $true)][string]$Target,
        [AllowEmptyString()][string]$Since
    )
    if ([string]::IsNullOrEmpty($Since)) { return '' }
    $result = Invoke-NSGitCommand $Target @('rev-list', '--count', '--since', $Since, 'HEAD')
    if ($result.ExitCode -ne 0) { return '' }
    $text = ([string]$result.Text).Trim()
    if ($text -cmatch '^[0-9]+$') { return $text }
    return ''
}

# The commands in the punch list's Gates block, in byte order. These are the
# checks the level either ran or skipped; the block stays their only list.
function Get-NSReceiptGateCommands {
    param([Parameter(Mandatory = $true)][string]$PunchList)
    $commands = New-Object Collections.Generic.List[string]
    if (-not (Test-Path -LiteralPath $PunchList -PathType Leaf)) {
        return (Get-NSUniqueSorted ([string[]]$commands.ToArray()))
    }
    $inGates = $false
    try {
        foreach ($line in [IO.File]::ReadLines($PunchList)) {
            $text = [string]$line
            if ($text -cmatch '^##\s') {
                $inGates = ($text -cmatch '^##\s+Gates\s*$')
                continue
            }
            if (-not $inGates) { continue }
            foreach ($match in [regex]::Matches($text, '`([^`]+)`')) {
                $command = $match.Groups[1].Value.Trim()
                if ($command.Length -gt 0) { $commands.Add($command) }
            }
        }
    }
    catch {
        return (Get-NSUniqueSorted ([string[]]$commands.ToArray()))
    }
    return (Get-NSUniqueSorted ([string[]]$commands.ToArray()))
}

function Get-NSReceiptRecordSources {
    param($Records, $Statuses, [AllowEmptyString()][string]$Ladder)
    $sources = New-Object Collections.Generic.List[string]
    foreach ($record in @($Records)) {
        if ($script:NSEvidenceLifecycleDomains -ccontains (Get-NSRecordText $record 'domain')) { continue }
        $keep = $false
        if ($null -ne $Statuses -and ($Statuses -ccontains (Get-NSRecordText $record 'status'))) { $keep = $true }
        if (-not [string]::IsNullOrEmpty($Ladder) -and ((Get-NSRecordText $record 'ladder') -ceq $Ladder)) { $keep = $true }
        if (-not $keep) { continue }
        $source = Get-NSRecordText $record 'source'
        if ($source.Length -eq 0) { $source = Get-NSRecordText $record 'sourceClass' }
        if ($source.Length -gt 0) { $sources.Add($source) }
    }
    return (Get-NSUniqueSorted ([string[]]$sources.ToArray()))
}

# The last state the ledger recorded for each id, lifecycle records excluded.
function Get-NSReceiptFindingMap {
    param($Records)
    $map = New-NSOrdinalMap
    foreach ($record in @($Records)) {
        if ($script:NSEvidenceLifecycleDomains -ccontains (Get-NSRecordText $record 'domain')) { continue }
        $id = Get-NSRecordText $record 'id'
        if ($id.Length -eq 0) { continue }
        $map[$id] = $record
    }
    return $map
}

# Every decision below the parking lot's rule that still waits for the owner, whole. An entry is a
# `### ` heading and everything under it, a top-level bullet and its wrapped and nested lines, or a
# paragraph; its Default and Rollback lines are kept apart. Filed pointers, runtime notices and
# answered entries are skipped.
function Get-NSReceiptParkedEntries {
    param([Parameter(Mandatory = $true)][string]$ParkingLot)
    $entries = New-Object Collections.Generic.List[object]
    $state = New-NSOrdinalMap
    $state['open'] = $false
    $state['mode'] = ''
    $state['field'] = 't'
    $state['text'] = ''
    $state['default'] = ''
    $state['rollback'] = ''
    $add = {
        param([string]$Value)
        $value = $Value.Trim(' ')
        if ($value.Length -eq 0) { return }
        $key = 'text'
        if ($state['field'] -ceq 'd') { $key = 'default' }
        elseif ($state['field'] -ceq 'r') { $key = 'rollback' }
        if (([string]$state[$key]).Length -eq 0) { $state[$key] = $value }
        else { $state[$key] = ([string]$state[$key]) + ' ' + $value }
    }
    $flush = {
        $text = [string]$state['text']
        $all = ($text + ' ' + $state['default'] + ' ' + $state['rollback']).ToLowerInvariant()
        if ($state['open'] -and $text.Length -gt 0 -and
            -not $text.StartsWith('[notice]', [StringComparison]::Ordinal) -and
            $all -cnotmatch $script:NSReceiptHandledPattern) {
            $entry = New-NSOrdinalMap
            $entry['title'] = $text
            $entry['default'] = [string]$state['default']
            $entry['rollback'] = [string]$state['rollback']
            $entries.Add($entry)
        }
        $state['open'] = $false
        $state['mode'] = ''
        $state['field'] = 't'
        $state['text'] = ''
        $state['default'] = ''
        $state['rollback'] = ''
    }
    $begin = {
        param([string]$Mode, [string]$Value)
        & $flush
        $state['open'] = $true
        $state['mode'] = $Mode
        & $add $Value
    }
    $started = $false
    $blank = $false
    foreach ($raw in (Get-NSReceiptScrubbedLines $ParkingLot)) {
        if (-not $started) {
            if ($raw -cmatch '^--- *$') { $started = $true }
            continue
        }
        $line = $raw.TrimEnd(' ')
        if ($line.Length -eq 0) {
            $blank = $true
            if ($state['mode'] -ceq 'p') { & $flush }
            continue
        }
        if ($line -cmatch '^### +') {
            & $begin 'h' ($line -creplace '^### +', '')
            $blank = $false
            continue
        }
        if ($line -cmatch '^#' -or $line -cmatch '^(- )?Filed:' -or $line -cmatch '^\(empty') {
            & $flush
            $blank = $false
            continue
        }
        if ($state['open']) {
            $field = [regex]::Match($line, '^ *(- )?(\*\*)?(Default|Rollback):(\*\*)?')
            if ($field.Success) {
                if ($field.Value.Contains('Default')) { $state['field'] = 'd'; $state['default'] = '' }
                else { $state['field'] = 'r'; $state['rollback'] = '' }
                & $add $line.Substring($field.Length)
                $blank = $false
                continue
            }
        }
        if ($line.StartsWith('- ', [StringComparison]::Ordinal)) {
            if ($state['open'] -and $state['mode'] -ceq 'h') { & $add $line.Substring(2) }
            else { & $begin 'b' $line.Substring(2) }
        }
        elseif (-not $state['open'] -or ($state['mode'] -ceq 'b' -and $blank -and
                -not $line.StartsWith(' ', [StringComparison]::Ordinal))) {
            & $begin 'p' $line
        }
        else {
            & $add $line
        }
        $blank = $false
    }
    & $flush
    return , $entries.ToArray()
}

# One snag-log entry of this shift whose disposition is not fixed. An entry is
# `finding`, `evidence`, `disposition`, `date`, joined by middle dots; one without a disposition is open.
function Add-NSReceiptSnagRow {
    param($Rows, [AllowEmptyString()][string]$Entry, [AllowEmptyString()][string]$Day)
    if ($Entry.Length -eq 0) { return }
    $parts = $Entry.Split([string[]]@(' ' + [char]0x00b7 + ' '), [StringSplitOptions]::None)
    $disposition = 'open'
    if ($parts.Length -ge 3 -and $parts[2] -cnotmatch '^ *[0-9]{4}-[0-9]{2}-[0-9]{2} *$') {
        $disposition = $parts[2].Trim(' ')
    }
    $date = ''
    foreach ($match in [regex]::Matches($Entry, '[0-9]{4}-[0-9]{2}-[0-9]{2}')) { $date = $match.Value }
    if ($disposition.ToLowerInvariant().StartsWith('fixed', [StringComparison]::Ordinal)) { return }
    if ($Day.Length -gt 0 -and ($date.Length -eq 0 -or [string]::CompareOrdinal($date, $Day) -lt 0)) { return }
    $Rows.Add([pscustomobject]@{ Finding = $parts[0].Trim(' '); Disposition = $disposition })
}

# The snag-log entries of this shift - dated on or after the day it started - that were not fixed.
function Get-NSReceiptSnagEntries {
    param([Parameter(Mandatory = $true)][string]$SnagLog, [AllowEmptyString()][string]$Day = '')
    $rows = New-Object Collections.Generic.List[object]
    $started = $false
    $entry = ''
    foreach ($raw in (Get-NSReceiptScrubbedLines $SnagLog)) {
        if (-not $started) {
            if ($raw -cmatch '^--- *$') { $started = $true }
            continue
        }
        $line = $raw.TrimEnd(' ')
        if ($line.Length -eq 0 -or $line -cmatch '^#' -or $line -cmatch '^(- )?Filed:' -or $line -cmatch '^\(empty') {
            Add-NSReceiptSnagRow $rows $entry $Day
            $entry = ''
            continue
        }
        if ($line.StartsWith('- ', [StringComparison]::Ordinal)) {
            Add-NSReceiptSnagRow $rows $entry $Day
            $entry = $line.Substring(2).Trim(' ')
            continue
        }
        if ($entry.Length -gt 0) { $entry = $entry + ' ' + $line.Trim(' ') }
    }
    Add-NSReceiptSnagRow $rows $entry $Day
    return , $rows.ToArray()
}

# The one building entry from the opportunity map, with the exact next action it
# carries. Nothing is inferred: no Next line, no line in the receipt.
function Get-NSReceiptBuilding {
    param([Parameter(Mandatory = $true)][string]$OpportunityMap)
    $result = New-NSOrdinalMap
    $result['title'] = ''
    $result['next'] = ''
    if (-not (Test-Path -LiteralPath $OpportunityMap -PathType Leaf)) { return $result }
    $title = ''
    $building = $false
    # The shipped map carries its entry catalogue inside an HTML comment, and that example is
    # `Status: building`. Reading it makes a freshly scaffolded workspace look like a cycle in
    # progress and puts the template's own placeholders on the owner's morning page.
    $comment = $false
    try {
        foreach ($line in [IO.File]::ReadLines($OpportunityMap)) {
            $text = [string]$line
            if ($text -clike '*<!--*') { $comment = $true }
            if ($text -clike '*-->*') { $comment = $false; continue }
            if ($comment) { continue }
            $head = [regex]::Match($text, '^###\s+(.*)$')
            if ($head.Success) {
                if ($building -and $result['title'].Length -gt 0) { break }
                $title = $head.Groups[1].Value.Trim()
                $building = $false
                continue
            }
            if ($text -cmatch '^Status:\s*building\s*$') {
                $building = $true
                if ($result['title'].Length -eq 0) { $result['title'] = $title }
                continue
            }
            if (-not $building) { continue }
            $next = [regex]::Match($text, '^Next:\s*(.*)$')
            if ($next.Success -and $result['next'].Length -eq 0) {
                $result['next'] = $next.Groups[1].Value.Trim()
            }
        }
    }
    catch {
        return $result
    }
    return $result
}

function Get-NSReceiptContext {
    param(
        [Parameter(Mandatory = $true)][string]$Workspace,
        [Parameter(Mandatory = $true)][string]$View
    )
    $workspacePath = Get-NSAbsolutePath $Workspace
    $paths = Get-NSPolicyPaths $workspacePath
    $ns = [string]$paths['ns']
    $context = New-NSOrdinalMap
    $context['view'] = $View
    $context['workspace'] = $workspacePath
    $context['ns'] = $ns
    $context['punch'] = [string]$paths['punch']
    $context['parking'] = [string]$paths['parking']

    $records = New-Object Collections.Generic.List[object]
    try {
        $records = Get-NSEvidenceLedgerRecords $workspacePath
    }
    catch {
        $records = New-Object Collections.Generic.List[object]
    }
    $context['records'] = $records
    $context['findings'] = Get-NSReceiptFindingMap $records
    $context['baselines'] = Get-NSCompareBaselineRecords $records

    $policy = $null
    $policyKind = 'absent'
    try {
        $policyState = Get-NSReceiptPolicyState $workspacePath
        switch ([string]$policyState['state']) {
            'valid' { $policyKind = 'accepted'; $policy = $policyState['policy'] }
            'malformed' { $policyKind = 'malformed' }
        }
    }
    catch {
        $policy = $null
        $policyKind = 'absent'
    }
    $context['policy'] = $policy
    $context['policyKind'] = $policyKind

    $mode = 'repository'
    try {
        $mode = Get-NSWorkMode $workspacePath
    }
    catch {
        $mode = 'repository'
    }
    $context['workMode'] = $mode
    $context['workTarget'] = Get-NSEvidenceWorkTarget $workspacePath

    $shiftId = ''
    $createdAt = ''
    if ($null -ne $policy) {
        $shiftId = Get-NSRecordText $policy 'shiftId'
        $createdAt = Get-NSRecordText $policy 'createdAt'
    }
    $context['shiftId'] = $shiftId
    $context['createdAt'] = $createdAt

    # The start is the arming mark, or the policy's createdAt for a shift that kept no usage marks,
    # and commits are counted from that same moment; the end is when the clock-out gate wrote
    # .ended. Display times are local with the zone written out.
    $marks = Get-NSReceiptMarks $ns
    $context['marks'] = $marks
    $started = $createdAt
    $since = $createdAt
    $policyStart = [DateTimeOffset]::MinValue
    if ([DateTimeOffset]::TryParse($createdAt, [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$policyStart)) {
        $started = Get-NSReceiptLocalStamp ([string]$policyStart.ToUnixTimeSeconds())
    }
    if ($marks.Length -gt 0) {
        $armed = Get-NSReceiptLocalStamp ([string]$marks[0].Epoch)
        if ($armed.Length -gt 0) {
            $started = $armed
            $since = '@' + [string]$marks[0].Epoch
        }
    }
    $context['started'] = $started
    $context['since'] = $since
    $context['shiftDay'] = $(if ($started -cmatch '^[0-9]{4}-[0-9]{2}-[0-9]{2}') { $started.Substring(0, 10) } else { '' })
    $endedEpoch = Get-NSReceiptEndedEpoch $ns
    $context['endedEpoch'] = $endedEpoch
    $context['ended'] = Get-NSReceiptLocalStamp $endedEpoch

    $counts = Get-NSBoxCounts $context['punch']
    $context['ticked'] = [int]$counts.Ticked
    $context['open'] = [int]$counts.Open
    $context['stopped'] = [int]$counts.Stopped
    $context['punchReadable'] = [bool]$counts.Readable
    $context['ending'] = Get-NSReceiptEnding -NightshiftDir $ns -Open ([int]$counts.Open) -Readable ([bool]$counts.Readable)

    $sessionHost = ''
    $session = $null
    try {
        $session = Read-NSSession $ns
    }
    catch {
        $session = $null
    }
    if ($null -ne $session) { $sessionHost = [string]$session.HostName }
    if ($sessionHost.Length -eq 0) {
        foreach ($record in @($records)) {
            $candidate = Get-NSRecordText $record 'host'
            if ($candidate.Length -gt 0) { $sessionHost = $candidate }
        }
    }
    $context['host'] = $sessionHost

    $resolution = $null
    try {
        $resolution = Get-NSPolicyResolution $workspacePath
    }
    catch {
        $resolution = $null
    }
    $verificationLevel = 'none'
    $verificationSource = 'built-in'
    $toolingPolicy = 'existing-tools'
    if ($null -ne $resolution) {
        $verificationLevel = [string]$resolution['settings']['verificationLevel']['value']
        $verificationSource = [string]$resolution['settings']['verificationLevel']['source']
        $toolingPolicy = [string]$resolution['settings']['toolingPolicy']['value']
    }
    $context['verificationLevel'] = $verificationLevel
    $context['verificationSource'] = $verificationSource
    $context['toolingPolicy'] = $toolingPolicy

    $profile = ''
    try {
        $defaults = Get-NSShiftDefaults $workspacePath
        $profile = [string]$defaults['verificationProfile']
    }
    catch {
        $profile = ''
    }
    $context['profile'] = $profile

    $allowances = New-Object Collections.Generic.List[string]
  if ($null -ne $policy) {
        $rawAllowances = Get-NSMapValue $policy 'allowances'
        if ($null -ne $rawAllowances) {
            foreach ($allowance in @($rawAllowances)) {
                if (-not ($allowance -is [Collections.IDictionary])) { continue }
                $category = Get-NSRecordText $allowance 'category'
                $scope = Get-NSRecordText $allowance 'scope'
                $provenance = Get-NSRecordText $allowance 'provenance'
                if ($category.Length -eq 0 -and $scope.Length -eq 0 -and $provenance.Length -eq 0) { continue }
                $allowances.Add(($script:NSReceiptAllowanceFormat -f $category, $scope, $provenance))
            }
        }
    }
    $context['allowances'] = Get-NSUniqueSorted ([string[]]$allowances.ToArray())

    $context['gates'] = Get-NSReceiptGateCommands $context['punch']
    $context['verified'] = Get-NSReceiptRecordSources $records $null $script:NSReceiptVerifiedLadder
    $context['unavailable'] = Get-NSReceiptRecordSources $records $script:NSCompareUnavailableStatuses ''
    $context['mode'] = Get-NSPolicyCompletionModeFrom $policy
    $context['selectedDebt'] = Get-NSPolicySelectedDebt $workspacePath
    return $context
}

function Add-NSReceiptField {
    param(
        [Parameter(Mandatory = $true)]$Lines,
        [Parameter(Mandatory = $true)][string]$Key,
        [AllowEmptyString()][string]$Value
    )
    if ([string]::IsNullOrEmpty($Value)) { return }
    $Lines.Add(($script:NSReceiptFieldFormat -f ([string]$script:NSReceiptLabels[$Key]), $Value))
}

# Section 1. The three closing lines always appear: what ran green by command,
# what the level skipped, and what could not be measured. A disabled check is
# never rendered as a check that passed.
function Get-NSReceiptShiftLines {
    param($Context)
    $lines = New-Object Collections.Generic.List[string]
    Add-NSReceiptField $lines 'shift' ([string]$Context['shiftId'])
    Add-NSReceiptField $lines 'host' ([string]$Context['host'])
    Add-NSReceiptField $lines 'workTarget' ([string]$Context['workTarget'])
    Add-NSReceiptField $lines 'started' ([string]$Context['started'])
    Add-NSReceiptField $lines 'ended' ([string]$Context['ended'])
    Add-NSReceiptField $lines 'ending' ([string]$Context['ending'])
    if ($Context.Contains('punchReadable') -and -not [bool]$Context['punchReadable']) {
        Add-NSReceiptField $lines 'items' 'unknown'
    }
    else {
        $itemsText = ($script:NSReceiptItemsFormat -f ([int]$Context['ticked']), ([int]$Context['open']))
        if ([int]$Context['stopped'] -gt 0) { $itemsText += (', {0} stopped at their hard budget' -f [int]$Context['stopped']) }
        Add-NSReceiptField $lines 'items' $itemsText
    }
    $artifactView = ([string]$Context['view']) -ceq 'artifact'
    if ($artifactView -or (([string]$Context['workMode']) -ceq 'artifact')) {
        Add-NSReceiptField $lines 'receipts' ([string](Get-NSReceiptsCount ([string]$Context['workspace'])))
    }
    elseif (([string]$Context['workTarget']).Length -gt 0) {
        # No work target, no commit count: there is no repository to count in, and a zero would
        # read as a night that committed nothing.
        Add-NSReceiptField $lines 'commits' (Get-NSReceiptCommitCount -Target ([string]$Context['workTarget']) -Since ([string]$Context['since']))
    }
    $profile = [string]$Context['profile']
    if ($profile.Length -eq 0) { $profile = $script:NSReceiptNone }
    Add-NSReceiptField $lines 'policy' ($script:NSReceiptPolicyFormat -f $profile, ([string]$Context['verificationLevel']), ([string]$Context['toolingPolicy']))
    foreach ($allowance in @($Context['allowances'])) {
        Add-NSReceiptField $lines 'allowance' ([string]$allowance)
    }

    $gates = @($Context['gates'])
    $chosen = ([string]$Context['verificationSource']) -ceq $script:NSReceiptChosenSource
    # A shift that wrote no policy runs on the built-in floor, and the punch list's own Gates
    # section is what it was told to run. Naming those commands as the shift's gate keeps the
    # receipt from crediting the owner with a decision they never made.
    if (-not $chosen -and $gates.Count -gt 0) {
        Add-NSReceiptField $lines 'gates' ($script:NSReceiptGatesFormat -f ($gates -join $script:NSMdSourceSeparator))
    }

    $verified = @($Context['verified'])
    if ($verified.Count -gt 0) {
        Add-NSReceiptField $lines 'verified' (($verified -join $script:NSMdSourceSeparator))
    }
    elseif ($chosen) {
        Add-NSReceiptField $lines 'verified' ($script:NSReceiptVerifiedNoneFormat -f (Get-NSEvidenceDash), ([string]$Context['verificationLevel']))
    }
    elseif (([string]$Context['policyKind']) -ceq 'malformed') {
        Add-NSReceiptField $lines 'verified' ($script:NSReceiptVerifiedMalformedFormat -f (Get-NSEvidenceDash))
    }
    else {
        Add-NSReceiptField $lines 'verified' ($script:NSReceiptVerifiedNoPolicyFormat -f (Get-NSEvidenceDash))
    }

    $disabled = @()
    if ($chosen -and (([string]$Context['verificationLevel']) -ceq 'none')) { $disabled = $gates }
    if ($disabled.Count -gt 0) {
        Add-NSReceiptField $lines 'disabled' (($disabled -join $script:NSMdSourceSeparator))
    }
    else {
        Add-NSReceiptField $lines 'disabled' $script:NSReceiptNone
    }

    $unavailable = @($Context['unavailable'])
    if ($unavailable.Count -gt 0) {
        Add-NSReceiptField $lines 'unavailable' (($unavailable -join $script:NSMdSourceSeparator))
    }
    else {
        Add-NSReceiptField $lines 'unavailable' $script:NSReceiptNone
    }
    return , $lines.ToArray()
}

# The whole shift, from the arming mark to the end: working time with every recorded pause listed
# by its reason, and the tokens the host reported, in its own counting. Nothing is priced, and a
# measurement the owner turned off says off.
function Get-NSReceiptUsageLines {
    param($Context)
    $lines = New-Object Collections.Generic.List[string]
    $marks = @($Context['marks'])
    if ($marks.Count -eq 0) { return , @() }
    $ns = [string]$Context['ns']
    $workspace = [string]$Context['workspace']
    $start = [long]$marks[0].Epoch
    $end = [long]$marks[$marks.Count - 1].Epoch
    if (([string]$Context['endedEpoch']).Length -gt 0) { $end = [long]$Context['endedEpoch'] }
    if ($end -lt $start) { $end = $start }
    if ((Get-NSReceiptsField $workspace 'duration') -ceq 'off') {
        $lines.Add('- Time: off')
    }
    else {
        $wall = $end - $start
        $pauses = Get-NSUsagePausesByReason $ns $start $end
        $paused = 0L
        foreach ($pause in $pauses) { $paused += [long]$pause.Seconds }
        $work = $wall - $paused
        if ($work -lt 0) { $work = 0 }
        $lines.Add(('- Span: {0} {1} {2}' -f (Get-NSReceiptLocalStamp ([string]$start)), [char]0x2192,
                (Get-NSReceiptLocalStamp ([string]$end))))
        $lines.Add('- Working: ' + (Get-NSUsageDuration ([string]$work)))
        if ($paused -gt 0) {
            $lines.Add('- Paused: ' + (Get-NSUsageDuration ([string]$paused)))
            foreach ($pause in $pauses) {
                $lines.Add(('  - {0}: {1}' -f $pause.Reason, (Get-NSUsageDuration ([string]$pause.Seconds))))
            }
        }
        else {
            $lines.Add('- Paused: ' + $script:NSReceiptNone)
        }
        $lines.Add('- Wall: ' + (Get-NSUsageDuration ([string]$wall)))
    }
    if ((Get-NSReceiptsField $workspace 'usage') -ceq 'off') {
        $lines.Add('- Tokens: off')
    }
    else {
        $fields = Get-NSUsageTotal $ns
        $hostName = Get-NSUsageHosts $ns
        if ([string]::IsNullOrEmpty($hostName)) { $hostName = 'unknown' }
        $segments = [string](Get-NSUsageSegmentCount $ns)
        $lines.Add('')
        $lines.Add('| Tokens | Amount |')
        $lines.Add('| --- | ---: |')
        foreach ($dim in $script:NSUsageDimensions) {
            $value = Get-NSUsageField $fields $dim
            if ([string]::IsNullOrEmpty($value)) { $value = 'unavailable' } else { $value = Get-NSUsageScale $value }
            $lines.Add('| ' + (Get-NSUsageDimLabel $dim) + ' | ' + $value + ' |')
        }
        $lines.Add('')
        $word = $(if ($segments -ceq '1') { 'segment' } else { 'segments' })
        $lines.Add(('{0} {1} {2} {3}. {4}' -f $hostName, [char]0x00b7, $segments, $word,
                (Get-NSUsageOverlapText ($hostName.Split(' ')[0]))))
    }
    return , $lines.ToArray()
}

# One line per item, in list order, linked to its item receipt where that file exists. The receipt
# carries the item's own cost, sessions, checks and story; this page does not copy them.
function Get-NSReceiptItemsLines {
    param($Context)
    $lines = New-Object Collections.Generic.List[string]
    $workspace = [string]$Context['workspace']
    foreach ($row in (Get-NSItemRows ([string]$Context['punch']) 'all')) {
        $state = $row.State
        $lines.Add(('- {0} {1} {2}' -f (Get-NSReceiptItemLink $workspace $row.Label $row.Id), (Get-NSEvidenceDash), $state))
    }
    return , $lines.ToArray()
}

# Where review should start: the three largest changes of the shift, by lines and then files, each
# charged to the item whose span its commit landed in, and the one command that shows the range.
# A commit outside every item's span stands on its own line.
function Get-NSReceiptReviewLines {
    param($Context)
    $lines = New-Object Collections.Generic.List[string]
    if ((([string]$Context['view']) -ceq 'artifact') -or (([string]$Context['workMode']) -ceq 'artifact')) {
        $lines.Add('- ' + $script:NSReceiptReviewArtifact)
        return , $lines.ToArray()
    }
    $since = [string]$Context['since']
    $target = [string]$Context['workTarget']
    if ($since.Length -eq 0 -or $target.Length -eq 0) { return , @() }
    $log = Invoke-NSGitCommand $target @('log', '--no-merges', '--reverse', '--since', $since,
        '--format=@@%x09%h%x09%ct%x09%s', '--numstat', 'HEAD')
    if ($log.ExitCode -ne 0) { return , @() }
    $marks = @($Context['marks'])
    $separator = [string][char]0x1f
    $order = New-Object Collections.Generic.List[string]
    $stats = New-Object 'Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)
    $seen = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $first = ''
    $last = ''
    $current = ''
    foreach ($line in @($log.Lines)) {
        if ($line.StartsWith("@@`t", [StringComparison]::Ordinal)) {
            $fields = $line.Split("`t")
            $hash = $(if ($fields.Length -ge 2) { $fields[1] } else { '' })
            $committed = 0L
            if ($fields.Length -ge 3) { $null = [long]::TryParse($fields[2], [ref]$committed) }
            $subject = $(if ($fields.Length -ge 4) { ($fields[3..($fields.Length - 1)] -join "`t") } else { '' })
            if ($first.Length -eq 0) { $first = $hash }
            $last = $hash
            $key = ''
            foreach ($mark in $marks) {
                if ([long]$mark.Epoch -ge $committed) {
                    if ($mark.Label -cne 'arm' -and $mark.Label.Length -gt 0) { $key = 'i' + $separator + $mark.Label }
                    break
                }
            }
            if ($key.Length -eq 0) { $key = 'c' + $separator + $hash + $separator + $subject }
            if (-not $stats.ContainsKey($key)) {
                $order.Add($key)
                $stats[$key] = [pscustomobject]@{ Key = $key; Commits = 0L; Files = 0L; Added = 0L; Removed = 0L }
            }
            $stats[$key].Commits++
            $current = $key
            continue
        }
        $numstat = [regex]::Match($line, '^([0-9-]+)\t([0-9-]+)\t(.*)$')
        if (-not $numstat.Success -or $current.Length -eq 0) { continue }
        if ($seen.Add($current + $separator + $numstat.Groups[3].Value)) { $stats[$current].Files++ }
        if ($numstat.Groups[1].Value -cmatch '^[0-9]+$') { $stats[$current].Added += [long]$numstat.Groups[1].Value }
        if ($numstat.Groups[2].Value -cmatch '^[0-9]+$') { $stats[$current].Removed += [long]$numstat.Groups[2].Value }
    }
    if ($first.Length -eq 0) { return , @() }
    $ranked = New-Object 'Collections.Generic.List[object]'
    foreach ($key in $order) { $ranked.Add($stats[$key]) }
    $ranked.Sort([Comparison[object]] {
            param($left, $right)
            $leftLines = $left.Added + $left.Removed
            $rightLines = $right.Added + $right.Removed
            if ($leftLines -ne $rightLines) { return $rightLines.CompareTo($leftLines) }
            if ($left.Files -ne $right.Files) { return $right.Files.CompareTo($left.Files) }
            return [string]::CompareOrdinal($left.Key, $right.Key)
        })
    $workspace = [string]$Context['workspace']
    $punch = [string]$Context['punch']
    $shown = 0
    foreach ($row in $ranked) {
        if ($shown -ge 3) { break }
        $shown++
        $parts = $row.Key.Split($separator)
        if ($parts[0] -ceq 'i') {
            $display = Get-NSReceiptItemLink $workspace $parts[1] (Get-NSItemIdFor $punch $parts[1])
        }
        else {
            $display = '`' + $parts[1] + '` ' + $parts[2]
        }
        $lines.Add(('- {0} {1} {2}, {3} (+{4}/-{5}), {6}' -f $display, (Get-NSEvidenceDash),
                (Get-NSReceiptCount $row.Files 'file'), (Get-NSReceiptCount ($row.Added + $row.Removed) 'line'),
                $row.Added, $row.Removed, (Get-NSReceiptCount $row.Commits 'commit')))
    }
    $parent = Invoke-NSGitCommand $target @('rev-parse', '--verify', '--quiet', ($first + '^'))
    $range = $(if ($parent.ExitCode -eq 0) { $first + '^..' + $last } else { $last })
    $lines.Add('- Whole range: `git log --stat ' + $range + '`')
    return , $lines.ToArray()
}

# What interrupted the night, as the runtime wrote it into the shift log: revivals, API failures,
# stalls, usage limits and how it was stopped.
function Get-NSReceiptInterruptionLines {
    param($Context)
    $lines = New-Object Collections.Generic.List[string]
    foreach ($line in (Get-NSReceiptShiftLogLines (Get-NSLayoutPath ([string]$Context['ns']) 'shift-log') 'interruptions')) {
        $lines.Add('- ' + $line)
    }
    return , $lines.ToArray()
}

function Get-NSReceiptSnagLines {
    param($Context)
    $lines = New-Object Collections.Generic.List[string]
    $dash = Get-NSEvidenceDash
    foreach ($row in (Get-NSReceiptSnagEntries (Get-NSLayoutPath ([string]$Context['ns']) 'snag-log') ([string]$Context['shiftDay']))) {
        if ($row.Finding.Length -eq 0) { continue }
        $lines.Add(('- {0} {1} {2}' -f $row.Finding, $dash, $row.Disposition))
    }
    return , $lines.ToArray()
}

# Section 2. One line per baseline: its source class, the exact command, and the
# two digests the comparison is measured against.
function Get-NSReceiptBaselineLines {
    param($Context)
    $lines = New-Object Collections.Generic.List[string]
    $byId = New-NSOrdinalMap
    foreach ($record in @($Context['baselines'])) {
        $id = Get-NSRecordText $record 'id'
        if ($id.Length -eq 0) { continue }
        $byId[$id] = $record
    }
    foreach ($id in (Sort-NSOrdinal ([string[]]@($byId.Keys)))) {
        $record = $byId[$id]
        $details = Get-NSRecordDetails $record
        $environment = Get-NSCompareShortDigest (Get-NSRecordText $details 'environmentDigest')
        if ($environment.Length -eq 0) { $environment = $script:NSReceiptNone }
        $raw = Get-NSCompareShortDigest (Get-NSRecordText $details 'rawDigest')
        if ($raw.Length -eq 0) { $raw = $script:NSReceiptNone }
        $scope = Get-NSRecordText $details 'scope'
        if ($scope.Length -eq 0) { $scope = Get-NSRecordText $record 'scope' }
        if ($scope.Length -eq 0) { $scope = $script:NSReceiptNone }
        $body = $script:NSReceiptBaselineFormat -f (Get-NSCompareBaselineSourceClass $record), `
        (Get-NSRecordText $details 'command'), (Get-NSEvidenceDash), $environment, $raw, $scope
        $lines.Add(($script:NSReceiptFieldFormat -f ([string]$id), $body))
    }
    return , $lines.ToArray()
}

# Section 3. Every baseline's rows in one table, then one line per fix: the
# record, the commit or receipt it landed as, its verification locator, and the
# post-measurement digest from the same source.
function Get-NSReceiptChangedLines {
    param($Context)
    $lines = New-Object Collections.Generic.List[string]
    $rows = New-NSOrdinalMap
    $outstanding = New-Object Collections.Generic.List[string]
    foreach ($record in @($Context['baselines'])) {
        $id = Get-NSRecordText $record 'id'
        if ($id.Length -eq 0) { continue }
        $comparison = $null
        try {
            $comparison = Get-NSEvidenceComparison -Workspace ([string]$Context['workspace']) -Baseline $id `
                -Records $Context['records'] -Mode ([string]$Context['mode']) -SelectedDebt $Context['selectedDebt']
        }
        catch {
            $comparison = $null
        }
        if ($null -eq $comparison) { continue }
        $document = $comparison['document']
        foreach ($row in @($document['rows'])) {
            $rowId = [string]$row['id']
            if (-not $rows.Contains($rowId)) { $rows[$rowId] = $row }
        }
        foreach ($debt in @($document['summary']['selectedDebtOutstanding'])) { $outstanding.Add([string]$debt) }
    }
    $ordered = New-Object Collections.Generic.List[object]
    $release = ([string]$Context['view']) -ceq 'release'
    foreach ($rowId in (Sort-NSOrdinal ([string[]]@($rows.Keys)))) {
        $row = $rows[$rowId]
        if ($release -and -not ($script:NSCompareRegressionClasses -ccontains ([string]$row['class']))) { continue }
        $ordered.Add($row)
    }
    if ($ordered.Count -eq 0 -and @($Context['baselines']).Count -eq 0) { return , @() }
    foreach ($line in (Get-NSCompareTableLines $ordered.ToArray())) { $lines.Add($line) }
    $lines.Add('')
    foreach ($line in (Get-NSCompareSummaryLines (Get-NSCompareCounts $ordered.ToArray()) (Get-NSUniqueSorted ([string[]]$outstanding.ToArray())))) {
        $lines.Add($line)
    }

    $fixes = New-Object Collections.Generic.List[string]
    $findings = $Context['findings']
    $joiner = Get-NSEvidenceJoiner
    foreach ($id in (Sort-NSOrdinal ([string[]]@($findings.Keys)))) {
        $record = $findings[$id]
        if (-not ($script:NSCompareClearedStatuses -ccontains (Get-NSRecordText $record 'status'))) { continue }
        $fix = Get-NSRecordText $record 'fix'
        if ($fix.Length -eq 0) { $fix = $script:NSReceiptNone }
        $locator = Get-NSRecordText $record 'verificationLocator'
        if ($locator.Length -eq 0) { $locator = Get-NSRecordText $record 'locator' }
        if ($locator.Length -eq 0) { $locator = $script:NSReceiptNone }
        $digest = Get-NSCompareShortDigest (Get-NSRecordText $record 'digest')
        if ($digest.Length -eq 0) { $digest = $script:NSReceiptNone }
        $body = @($fix, $locator, $digest) -join $joiner
        $fixes.Add(($script:NSReceiptFieldFormat -f ([string]$id), $body))
    }
    if ($fixes.Count -gt 0) {
        $lines.Add('')
        foreach ($fix in $fixes) { $lines.Add($fix) }
    }
    return , $lines.ToArray()
}

# Section 4.
function Get-NSReceiptParkedLines {
    param($Context)
    $lines = New-Object Collections.Generic.List[string]
    # An item stopped at its hard budget is not done, and what happens to it is the owner's call.
    foreach ($row in (Get-NSItemRows ([string]$Context['punch']) 'stopped')) {
        $lines.Add(($script:NSReceiptPlainFormat -f ($row.Label + ' stopped at its hard budget without being done')))
        $lines.Add(($script:NSReceiptNestedFormat -f ([string]$script:NSReceiptLabels['default']), 'it stays open work; reopen it with a new budget, narrow it, or drop it'))
    }
    foreach ($entry in (Get-NSReceiptParkedEntries ([string]$Context['parking']))) {
        $lines.Add(($script:NSReceiptPlainFormat -f ([string]$entry['title'])))
        $default = [string]$entry['default']
        if ($default.Length -gt 0) {
            $lines.Add(($script:NSReceiptNestedFormat -f ([string]$script:NSReceiptLabels['default']), $default))
        }
        $rollback = [string]$entry['rollback']
        if ($rollback.Length -gt 0) {
            $lines.Add(($script:NSReceiptNestedFormat -f ([string]$script:NSReceiptLabels['rollback']), $rollback))
        }
    }
    return , $lines.ToArray()
}

# Section 5.
function Get-NSReceiptUnsupportedLines {
    param($Context)
    $lines = New-Object Collections.Generic.List[string]
    $findings = $Context['findings']
    $joiner = Get-NSEvidenceJoiner
    foreach ($id in (Sort-NSOrdinal ([string[]]@($findings.Keys)))) {
        $record = $findings[$id]
        $status = Get-NSRecordText $record 'status'
        if (-not ($script:NSReceiptUnmeasuredStatuses -ccontains $status)) { continue }
        $locator = Get-NSRecordText $record 'locator'
        if ($locator.Length -eq 0) { $locator = $script:NSReceiptNone }
        $lines.Add(($script:NSReceiptFieldFormat -f ([string]$id), (@($status, $locator) -join $joiner)))
    }
    return , $lines.ToArray()
}

# Section 6.
function Get-NSReceiptNextLines {
    param($Context)
    $lines = New-Object Collections.Generic.List[string]
    foreach ($row in (Get-NSItemRows ([string]$Context['punch']) 'open')) {
        $lines.Add(($script:NSReceiptPlainFormat -f ([string]$row.Label)))
    }
    $building = Get-NSReceiptBuilding (Get-NSLayoutPath ([string]$Context['ns']) 'opportunity-map')
    $title = [string]$building['title']
    $next = [string]$building['next']
    if ($title.Length -gt 0 -and $next.Length -gt 0) {
        $body = $script:NSReceiptNextFormat -f $title, (Get-NSEvidenceDash), $next
        $lines.Add(($script:NSReceiptFieldFormat -f ([string]$script:NSReceiptLabels['building']), $body))
    }
    foreach ($handover in (Get-NSReceiptShiftLogLines (Get-NSLayoutPath ([string]$Context['ns']) 'shift-log') 'handover')) {
        $lines.Add('- Handover: ' + $handover)
    }
    return , $lines.ToArray()
}

function Get-NSReceiptSectionLines {
    param([Parameter(Mandatory = $true)][string]$Key, $Context)
    switch ($Key) {
        'shift' { return (Get-NSReceiptShiftLines $Context) }
        'usage' { return (Get-NSReceiptUsageLines $Context) }
        'items' { return (Get-NSReceiptItemsLines $Context) }
        'review' { return (Get-NSReceiptReviewLines $Context) }
        'interruptions' { return (Get-NSReceiptInterruptionLines $Context) }
        'parked' { return (Get-NSReceiptParkedLines $Context) }
        'snags' { return (Get-NSReceiptSnagLines $Context) }
        'baseline' { return (Get-NSReceiptBaselineLines $Context) }
        'changed' { return (Get-NSReceiptChangedLines $Context) }
        'unsupported' { return (Get-NSReceiptUnsupportedLines $Context) }
        'next' { return (Get-NSReceiptNextLines $Context) }
    }
    return , @()
}

# Markdown from records only. It invents nothing, never upgrades a claim into
# proof, and omits a section it has no record for. The page links the index;
# each item links from the Items section.
function Get-NSMorningReceiptsLine {
    return ("Receipts:`n- [index](./README.md)")
}

# Get-NSHandoffSections <workspace> - the sections the owner picked, in their order, or none.
function Get-NSHandoffSections {
    param([Parameter(Mandatory = $true)][string]$Workspace)
    $block = Get-NSHandoffBlock $Workspace
    if ($null -eq $block -or -not $block.Contains('sections')) { return , @() }
    $names = New-Object Collections.Generic.List[string]
    foreach ($name in @($block['sections'])) {
        if ($name -is [string] -and $name.Length -gt 0) { $names.Add($name) }
    }
    return , $names.ToArray()
}

function Get-NSMorningReceipt {
    param(
        [Parameter(Mandatory = $true)][string]$Workspace,
        [ValidateSet('owner', 'reviewer', 'release', 'artifact')][string]$View = 'owner',
        [AllowEmptyString()][string]$Out = ''
    )
    $context = Get-NSReceiptContext -Workspace $Workspace -View $View
    $lines = New-Object Collections.Generic.List[string]
    $lines.Add($script:NSReceiptTitle)
    $lines.Add((Get-NSMorningReceiptsLine))
    $dash = Get-NSEvidenceDash
    switch ([string]$context['policyKind']) {
        'accepted' { $lines.Add('- Policy record: accepted') }
        'malformed' {
            $lines.Add(('- Policy record: malformed {0} {1}' -f $dash, $script:NSReceiptPolicyMalformedReason))
        }
        default {
            $lines.Add(('- Policy record: absent {0} {1}' -f $dash, $script:NSReceiptPolicyAbsentReason))
        }
    }
    # An owner list picks from the documented sections and orders them; an empty list keeps the
    # built-in order for the view.
    $sections = Get-NSHandoffSections $Workspace
    if ($sections.Length -eq 0) { $sections = @($script:NSReceiptViewSections[$View]) }
    foreach ($key in $sections) {
        if (-not $script:NSReceiptSectionTitle.Contains([string]$key)) { continue }
        $body = Get-NSReceiptSectionLines -Key ([string]$key) -Context $context
        if ($null -eq $body -or @($body).Count -eq 0) { continue }
        $lines.Add('')
        $lines.Add([string]$script:NSReceiptSectionTitle[[string]$key])
        $lines.Add('')
        foreach ($line in @($body)) { $lines.Add([string]$line) }
    }
    $text = ($lines -join "`n") + "`n"
    if (-not [string]::IsNullOrEmpty($Out)) {
        $directory = Split-Path -Parent $Out
        if (-not [string]::IsNullOrEmpty($directory)) { $null = [IO.Directory]::CreateDirectory($directory) }
        if (Test-NSReparsePoint $Out) { Remove-Item -LiteralPath $Out -Force -ErrorAction SilentlyContinue }
        Write-NSEvidenceFileAtomic -Path $Out -Text $text
    }
    return $text
}

# ---------------------------------------------------------------------------
# Command surfaces for the thin runtime scripts
# ---------------------------------------------------------------------------

function Write-NSEvidenceCompareUsage {
    Write-NSEvidenceError 'usage: evidence-compare.ps1 -Project DIR -Baseline ID [-Json|-Md]'
    return 1
}

# 0 the report renders and the mode is satisfied - 1 usage - 2 contract failure
# - 3 the report renders and the mode is not satisfied.
function Invoke-NSEvidenceCompareCommand {
    param(
        [AllowEmptyString()][string]$Project = '',
        [AllowEmptyString()][string]$Baseline = '',
        [switch]$Json,
        [switch]$Md
    )
    if ([string]::IsNullOrEmpty($Project) -or [string]::IsNullOrEmpty($Baseline)) { return (Write-NSEvidenceCompareUsage) }
    if ($Json -and $Md) { return (Write-NSEvidenceCompareUsage) }
    try {
        $comparison = Get-NSEvidenceComparison -Workspace $Project -Baseline $Baseline
        if ($Json) {
            [Console]::Out.Write((ConvertTo-NSCanonicalJson $comparison['document'] -Compact))
            [Console]::Out.Write("`n")
        }
        else {
            [Console]::Out.Write((Get-NSCompareMarkdown $comparison))
        }
        if ([bool]$comparison['document']['pass']) { return 0 }
        return 3
    }
    catch [ApplicationException] {
        Write-NSEvidenceError $_.Exception.Message
        return 2
    }
}

function Write-NSMorningReceiptUsage {
    Write-NSEvidenceError 'usage: morning-receipt.ps1 -Project DIR [-View owner|reviewer|release|artifact] [-Out PATH]'
    return 1
}

