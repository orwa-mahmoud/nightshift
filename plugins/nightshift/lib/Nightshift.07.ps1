function Invoke-NSMorningReceiptCommand {
    param(
        [AllowEmptyString()][string]$Project = '',
        [AllowEmptyString()][string]$View = '',
        [AllowEmptyString()][string]$Out = ''
    )
    if ([string]::IsNullOrEmpty($Project)) { return (Write-NSMorningReceiptUsage) }
    $view = $View
    if ([string]::IsNullOrEmpty($view)) { $view = 'owner' }
    if (-not ($script:NSReceiptViewNames -ccontains $view)) { return (Write-NSMorningReceiptUsage) }
    try {
        $text = Get-NSMorningReceipt -Workspace $Project -View $view -Out $Out
        if ([string]::IsNullOrEmpty($Out)) {
            [Console]::Out.Write($text)
            return 0
        }
        Write-NSEvidenceOut (Get-NSAbsolutePath $Out)
        return 0
    }
    catch [ApplicationException] {
        Write-NSEvidenceError $_.Exception.Message
        return 2
    }
}



# ---------------------------------------------------------------- the punch list, one item at a
# time
#
# Twin of lib/state.sh's ns_punch_* readers and runtime/punch-list.sh. Same bounded rule for what
# an item is, same two digests, same bytes out.

# Get-NSPunchLines <punch-list> - the file as lines, with line endings already flattened. Both
# digests are a property of what the list says, never of how the filesystem it sits on ends a line.
function Get-NSPunchLines {
    param([Parameter(Mandatory = $true)][string]$PunchList)
    if (-not (Test-Path -LiteralPath $PunchList -PathType Leaf)) { return @() }
    $text = ''
    try { $text = [IO.File]::ReadAllText($PunchList, $script:NSUtf8NoBom) }
    catch { return @() }
    if ([string]::IsNullOrEmpty($text)) { return @() }
    # A file ending in a newline splits to a trailing empty element; awk never prints that line.
    $text = $text -creplace '(\r\n|\n|\r)\z', ''
    return @($text -split "`r`n|`n|`r")
}

# Get-NSPunchGates <punch-list> - the gates block verbatim, heading included. Never digested and
# always reprinted: the owner may change it mid-shift by design.
function Get-NSPunchGates {
    param([Parameter(Mandatory = $true)][string]$PunchList)
    $out = New-Object Collections.Generic.List[string]
    $on = $false
    foreach ($line in (Get-NSPunchLines $PunchList)) {
        if ($line -cmatch '^## Gates[ \t]*$') { $on = $true; $out.Add($line); continue }
        if (-not $on) { continue }
        if ($line -cmatch '^## ') { break }
        $out.Add($line)
    }
    return $out.ToArray()
}

# Get-NSPunchItemsSection <punch-list> - the lines under `## Items`, up to the next top-level
# heading.
function Get-NSPunchItemsSection {
    param([Parameter(Mandatory = $true)][string]$PunchList)
    $out = New-Object Collections.Generic.List[string]
    $on = $false
    foreach ($line in (Get-NSPunchLines $PunchList)) {
        if (-not $on) {
            if ($line -cmatch '^##[ \t]*Items[ \t]*$') { $on = $true }
            continue
        }
        if ($line -cmatch '^## ') { break }
        $out.Add($line)
    }
    return $out.ToArray()
}

# Get-NSPunchItem <punch-list> <item> - one item with its sub-bullets, exactly as written. The item
# is named by its whole label, its number (`5`, `P03`), or its id; empty means the first still-open
# one, and the first item that matches wins. An item runs from its checkbox line to the next
# unindented line, so fenced code and nested lists inside it come through whole.
function Get-NSPunchItem {
    param(
        [Parameter(Mandatory = $true)][string]$PunchList,
        [AllowEmptyString()][string]$Id = ''
    )
    $out = New-Object Collections.Generic.List[string]
    $on = $false
    foreach ($line in (Get-NSPunchItemsSection $PunchList)) {
        if (-not $on) {
            if ($line -cnotmatch '^- \[[ xX]\]') { continue }
            if ([string]::IsNullOrEmpty($Id)) {
                if ($line -cnotmatch '^- \[ \]') { continue }
            }
            else {
                $label = Get-NSItemLabel $line
                if ($label -cne $Id -and (Get-NSItemId $line) -cne $Id -and (Get-NSReceiptNn $label) -cne $Id) { continue }
            }
            $on = $true
            $out.Add($line)
            continue
        }
        # Anything unindented and non-empty is the next item, a heading, or a note: this one ended.
        if (($line -cnotmatch '^[ \t]') -and ($line -cne '')) { break }
        $out.Add($line)
    }
    # The blank lines between this item and the next belong to neither.
    while (($out.Count -gt 0) -and ($out[$out.Count - 1].Trim() -ceq '')) {
        $out.RemoveAt($out.Count - 1)
    }
    return $out.ToArray()
}

# Get-NSPunchContract <punch-list> - everything above `## Items` except the gates block: the shift
# contract the owner wrote and nobody may edit while a shift is armed.
function Get-NSPunchContract {
    param([Parameter(Mandatory = $true)][string]$PunchList)
    $out = New-Object Collections.Generic.List[string]
    $skip = $false
    foreach ($line in (Get-NSPunchLines $PunchList)) {
        if ($line -cmatch '^## Items[ \t]*$') { break }
        if ($line -cmatch '^## Gates[ \t]*$') { $skip = $true; continue }
        if ($skip -and ($line -cmatch '^## ')) { $skip = $false }
        if ($skip) { continue }
        $out.Add($line)
    }
    return $out.ToArray()
}

# Get-NSPunchItemsNormalised <punch-list> - every item line and sub-bullet with the checkbox state
# flattened, so ticking a box changes nothing and rewording, deleting or inserting an item changes
# everything.
function Get-NSPunchItemsNormalised {
    param([Parameter(Mandatory = $true)][string]$PunchList)
    $out = New-Object Collections.Generic.List[string]
    foreach ($line in (Get-NSPunchItemsSection $PunchList)) {
        $out.Add(($line -creplace '^- \[[xX]\]', '- [ ]'))
    }
    return $out.ToArray()
}

# Get-NSPunchDigest <lines> - the same 64 lowercase hex characters the POSIX side produces: each
# line terminated with a single newline, UTF-8, no byte-order mark.
function Get-NSPunchDigest {
    param([AllowNull()][AllowEmptyCollection()][string[]]$Lines)
    $text = ''
    if (($null -ne $Lines) -and ($Lines.Count -gt 0)) {
        $text = [string]::Join("`n", $Lines) + "`n"
    }
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $sha.ComputeHash((New-Object Text.UTF8Encoding($false)).GetBytes($text))
    }
    finally {
        $sha.Dispose()
    }
    return ([BitConverter]::ToString($bytes)).Replace('-', '').ToLowerInvariant()
}

function Get-NSPunchContractDigest {
    param([Parameter(Mandatory = $true)][string]$PunchList)
    return (Get-NSPunchDigest (Get-NSPunchContract $PunchList))
}

function Get-NSPunchItemsDigest {
    param([Parameter(Mandatory = $true)][string]$PunchList)
    return (Get-NSPunchDigest (Get-NSPunchItemsNormalised $PunchList))
}

# Get-NSGateContractMismatch <workspace> <punch-list> - the sentence to block with, or ''.
#
# A file's own editor cannot be its watchman. The gate records the digests at arming, so it checks
# rather than asking the model to notice. A snapshot written without these fields compares nothing,
# which is not the same as a mismatch.
function Get-NSGateContractMismatch {
    param(
        [Parameter(Mandatory = $true)][string]$Workspace,
        [Parameter(Mandatory = $true)][string]$PunchList
    )
    if (-not (Test-Path -LiteralPath $PunchList -PathType Leaf)) { return '' }
    $which = ''
    $policy = Get-NSShiftPolicy $Workspace
    if ($null -eq $policy) { return '' }
    $recorded = Get-NSMapValue $policy 'contractDigest'
    if (-not [string]::IsNullOrEmpty($recorded)) {
        if ((Get-NSPunchContractDigest $PunchList) -cne $recorded) { $which = 'contract' }
    }
    if ([string]::IsNullOrEmpty($which)) {
        $recorded = Get-NSMapValue $policy 'itemsDigest'
        if (-not [string]::IsNullOrEmpty($recorded)) {
            if ((Get-NSPunchItemsDigest $PunchList) -cne $recorded) { $which = 'items' }
        }
    }
    if ([string]::IsNullOrEmpty($which)) { return '' }

    if ($which -ceq 'contract') {
        return ('DO NOT STOP - the shift contract above the Items heading in ' + $PunchList +
            ' has changed since this shift armed. It is the agreement the night is working to,' +
            ' and it is not editable while a shift runs. Restore the punch list from the' +
            ' work-target history or the receipts, or end the shift and let the owner edit the' +
            ' contract with nothing armed. Nothing else about the shift has changed: your ticks' +
            ' stand.')
    }
    return ('DO NOT STOP - an item in ' + $PunchList + ' has been reworded, removed or inserted' +
        ' since this shift armed. Ticking a box is invisible to this check, so something other' +
        ' than a tick changed. Restore the punch list from the work-target history or the' +
        ' receipts, or end the shift and let the owner edit the list with nothing armed. Nothing' +
        ' else about the shift has changed: your ticks stand.')
}

# Get-NSGateDoneMismatch <workspace> <punch-list> - the sentence to block a done clock-out with,
# or ''.
#
# Zero open boxes is done only when the list is still the one that armed. Deleting the unfinished
# items, or editing the contract once every box is ticked, reaches zero open boxes too, so the done
# path asks the same question the working path asks. A list that has disappeared entirely, from a
# shift that recorded one at arming, is that case at its limit. A snapshot that predates these
# fields records nothing, and a shift without one ends as it always has.
function Get-NSGateDoneMismatch {
    param(
        [Parameter(Mandatory = $true)][string]$Workspace,
        [Parameter(Mandatory = $true)][string]$PunchList
    )
    if (Test-Path -LiteralPath $PunchList -PathType Leaf) {
        return (Get-NSGateContractMismatch $Workspace $PunchList)
    }
    $policy = Get-NSShiftPolicy $Workspace
    if ($null -eq $policy) { return '' }
    $recorded = Get-NSMapValue $policy 'itemsDigest'
    if ([string]::IsNullOrEmpty($recorded)) { $recorded = Get-NSMapValue $policy 'contractDigest' }
    if ([string]::IsNullOrEmpty($recorded)) { return '' }
    return ('DO NOT STOP - ' + $PunchList + ' is gone, but this shift armed with a punch list.' +
        ' Deleting the list does not finish its items. Restore it from the work-target history or' +
        ' the receipts, or issue a stop-work order to end the shift with its work unfinished.')
}

# Invoke-NSPunchListCommand - runtime/windows/punch-list.ps1's whole body.
function Invoke-NSPunchListCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Project,
        [Parameter(Mandatory = $true)][ValidateSet('next', 'item')][string]$Verb,
        [AllowEmptyString()][string]$Id = ''
    )
    $workspace = Resolve-NSWorkspaceRoot $Project
    if ([string]::IsNullOrEmpty($workspace)) {
        [Console]::Error.WriteLine('punch-list: invalid .nightshift-link - Nightshift will not guess a workspace')
        return 2
    }
    $punch = Get-NSLayoutPath (Join-Path $workspace '.nightshift') 'punch-list'
    if (-not (Test-Path -LiteralPath $punch -PathType Leaf)) {
        [Console]::Error.WriteLine('punch-list: no punch list at ' + $punch)
        return 2
    }

    foreach ($line in @(Get-NSPunchGates $punch)) { [Console]::Out.WriteLine($line) }

    $body = @(Get-NSPunchItem -PunchList $punch -Id $(if ($Verb -ceq 'next') { '' } else { $Id }))
    if ($body.Count -eq 0) {
        if ($Verb -ceq 'item') {
            [Console]::Error.WriteLine('punch-list: no item ' + $Id + ' in ' + $punch)
            return 2
        }
        [Console]::Out.WriteLine('none')
        return 0
    }
    foreach ($line in $body) { [Console]::Out.WriteLine($line) }
    return 0
}


# ---------------------------------------------------------------- preflight explanations
#
# Twin of ns_explain_* in lib/state.sh, reading the same lib/preflight-explain.txt. One copy of the
# text, so the two hosts cannot word the same verdict differently.

# Get-NSExplainLines <file> <kind> <topic> - the records of that kind for that topic, in file
# order. A topic with no record returns nothing, which is not an error.
function Get-NSExplainLines {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Kind,
        [Parameter(Mandatory = $true)][string]$Topic
    )
    $out = New-Object 'System.Collections.Generic.List[string]'
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $out.ToArray() }
    $text = ''
    try { $text = [IO.File]::ReadAllText($Path, $script:NSUtf8NoBom) }
    catch { return $out.ToArray() }
    foreach ($line in ($text -split "`r`n|`n|`r")) {
        if ($line.StartsWith('#')) { continue }
        $fields = $line -split "`t"
        if ($fields.Count -lt 3) { continue }
        if (($fields[0] -ceq $Kind) -and ($fields[1] -ceq $Topic)) { $out.Add($fields[2]) }
    }
    return $out.ToArray()
}

# Get-NSExplainTopic <verdict text> - the first word, which every verdict leads with.
function Get-NSExplainTopic {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)
    $space = $Text.IndexOf(' ')
    if ($space -lt 0) { return $Text }
    return $Text.Substring(0, $space)
}

# ---------------------------------------------------------------- the facts Status renders
#
# Twins of the ns_status_* readers in lib/state.sh. Bounded readers, never Markdown parsers: each
# takes the first line of an entry under the shape the file already has, so a file the owner has
# written prose into still yields facts rather than a guess.

function Get-NSStatusFileLines {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }
    if (Test-NSReparsePoint $Path) { return @() }
    try { return @([IO.File]::ReadAllText($Path, $script:NSUtf8NoBom) -split "`r`n|`n|`r") }
    catch { return @() }
}

# Get-NSStatusOpenTitle <punch-list> - the title of the first still-open item, without its checkbox
# or bold markers.
function Get-NSStatusOpenTitle {
    param([Parameter(Mandatory = $true)][string]$PunchList)
    $item = @(Get-NSPunchItem -PunchList $PunchList -Id '')
    if ($item.Count -eq 0) { return '' }
    $title = $item[0] -creplace $script:NSItemIdPattern, ''
    $title = $title -creplace '^- \[[ xX]\][ \t]*', ''
    $title = $title -creplace '\*\*', ''
    return $title.TrimEnd()
}

# Get-NSStatusEntryTitles <file> <max> - the first line of each top-level `- ` entry. Used for the
# parking lot and the snag log, which share that shape.
function Get-NSStatusEntryTitles {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [int]$Max = 0
    )
    $out = New-Object 'System.Collections.Generic.List[string]'
    foreach ($line in (Get-NSStatusFileLines $Path)) {
        if ($line.StartsWith('Filed:') -or $line.StartsWith('- Filed:')) { continue }
        if (-not $line.StartsWith('- ')) { continue }
        $entry = ($line.Substring(2) -creplace '\*\*', '').TrimEnd()
        if ($entry.Length -gt 100) { $entry = $entry.Substring(0, 97) + '...' }
        $out.Add($entry)
    }
    if (($Max -gt 0) -and ($out.Count -gt $Max)) {
        return @($out.GetRange($out.Count - $Max, $Max).ToArray())
    }
    return $out.ToArray()
}

function Get-NSStatusEntryCount {
    param([Parameter(Mandatory = $true)][string]$Path)
    $n = 0
    foreach ($line in (Get-NSStatusFileLines $Path)) {
        if ($line.StartsWith('Filed:') -or $line.StartsWith('- Filed:')) { continue }
        if ($line.StartsWith('- ')) { $n++ }
    }
    return $n
}

# The map ships as a commented-out template. A template heading is not an opportunity.
function Get-NSStatusOpportunityCounts {
    param([Parameter(Mandatory = $true)][string]$Path)
    $counts = @{ candidate = 0; building = 0; shipped = 0; rejected = 0; parked = 0 }
    $comment = $false
    foreach ($line in (Get-NSStatusFileLines $Path)) {
        if ($line -clike '*<!--*') { $comment = $true }
        if ($line -clike '*-->*') { $comment = $false; continue }
        if ($comment) { continue }
        if ($line -cmatch '^[ \t]*Status:[ \t]*([A-Za-z]+)') {
            $state = $Matches[1].ToLowerInvariant()
            if ($counts.ContainsKey($state)) { $counts[$state]++ }
        }
    }
    return ('candidate=' + $counts.candidate + ' building=' + $counts.building +
        ' shipped=' + $counts.shipped + ' rejected=' + $counts.rejected +
        ' parked=' + $counts.parked)
}

# Get-NSStatusBuilding <map> - `<key>`tab`<value>` for the building entry's title, phase, next
# action and remaining verification. Nothing when none is building.
function Get-NSStatusBuilding {
    param([Parameter(Mandatory = $true)][string]$Path)
    $out = New-Object 'System.Collections.Generic.List[string]'
    $comment = $false
    $title = ''
    $building = $false
    $found = $false
    foreach ($line in (Get-NSStatusFileLines $Path)) {
        if ($line -clike '*<!--*') { $comment = $true }
        if ($line -clike '*-->*') { $comment = $false; continue }
        if ($comment) { continue }
        if ($line -cmatch '^#{2,}[ \t]') {
            if ($found) { break }
            $title = ($line -creplace '^#+[ \t]*', '') -creplace '\*\*', ''
            $building = $false
            continue
        }
        if ($line -cmatch '^[ \t]*Status:[ \t]*building') {
            $building = $true
            $found = $true
            $out.Add("title`t" + $title)
            continue
        }
        if ($building -and ($line -cmatch '^[ \t]*(Phase|Next|Verify remaining):[ \t]*(.*)$')) {
            $out.Add($Matches[1].ToLowerInvariant() + "`t" + $Matches[2])
        }
    }
    return $out.ToArray()
}

function Get-NSStatusStopReason {
    param([Parameter(Mandatory = $true)][string]$NightshiftDir)
    $lines = @(Get-NSStatusFileLines (Get-NSLayoutPath $NightshiftDir 'stop'))
    if ($lines.Count -eq 0) { return '' }
    return $lines[0]
}

# A transition is a line whose SUBJECT is the shift changing hands. Matching the words anywhere
# would catch an item summary that merely mentions one.
function Get-NSStatusTransitions {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [int]$Max = 3
    )
    $out = New-Object 'System.Collections.Generic.List[string]'
    foreach ($raw in (Get-NSStatusFileLines $Path)) {
        $line = $raw -creplace '^-[ \t]*', ''
        $line = $line -creplace '^[0-9][0-9:TZ .-]*', ''
        $line = $line -creplace "^$([char]0x00B7)[ \t]*", ''
        if ($line -inotmatch '^(watchman|the watchman|shift started|shift ended|the session ended|revived|host change)') { continue }
        if ($line.Length -gt 120) { $line = $line.Substring(0, 117) + '...' }
        $out.Add($line)
    }
    if (($Max -gt 0) -and ($out.Count -gt $Max)) {
        return @($out.GetRange($out.Count - $Max, $Max).ToArray())
    }
    return $out.ToArray()
}

# The clock is read once, here, rather than in the skill.
function Get-NSStatusDeadlineRemaining {
    param([Parameter(Mandatory = $true)][string]$NightshiftDir)
    $lines = @(Get-NSStatusFileLines (Get-NSLayoutPath $NightshiftDir 'deadline'))
    if ($lines.Count -eq 0) { return '' }
    $epoch = 0
    if (-not [long]::TryParse($lines[0].Trim(), [ref]$epoch)) { return '' }
    $now = Get-NSUnixTime
    if ($epoch -le $now) { return 'passed' }
    $left = $epoch - $now
    return ('{0}h{1:00}m remaining' -f [int][math]::Floor($left / 3600), [int][math]::Floor(($left % 3600) / 60))
}
# Write-NSStatusReport <workspace> - the same facts the POSIX helper prints, in the same order.
#
# It writes to the console rather than the pipeline. A function that both prints and returns cannot
# be called as an expression: `exit (Write-NSStatusReport ...)` captured every line as the value of
# that expression and the owner saw an empty response with exit 0.
function Write-NSStatusReport {
    param([Parameter(Mandatory = $true)][string]$Workspace)

    function Say { param([AllowEmptyString()][string]$Text) [Console]::Out.Write($Text + "`n") }
    # A fact whose value is empty is still a fact: `none` is an answer, a blank line is not.
    function Fact {
        param([string]$Label, [AllowEmptyString()][AllowNull()][string]$Value)
        if ([string]::IsNullOrEmpty($Value)) { $Value = 'none' }
        Say ($Label + ' ' + $Value)
    }

    $ns = Join-Path $Workspace '.nightshift'
    if (-not (Test-Path -LiteralPath $ns -PathType Container)) {
        Say 'Nightshift Status'
        Say ('Nightshift: missing at ' + $Workspace)
        return 0
    }
    $punch = Get-NSLayoutPath $ns 'punch-list'
    $open = 0; $ticked = 0
    if (Test-NSPathEntry $punch) {
        $counts = Get-NSBoxCounts $punch
        $open = [int]$counts.Open
        $ticked = [int]$counts.Ticked
    }
    $armed = Test-NSPathEntry (Get-NSLayoutPath $ns 'armed')
    $watch = 0
    try { $watch = [int](Get-NSRule $Workspace 'watchMinutes' '') } catch { $watch = 0 }

    Say 'Nightshift Status'
    Say ('Workspace:   ' + $Workspace)
    Say ('Shift:       ' + ($(if ($armed) { 'armed' } else { 'not armed' })))
    Say ('Items:       open=' + $open + ' ticked=' + $ticked)
    Say ('evidence:    ' + (Get-NSEvidenceCountSummary $Workspace))
    Say ('liveness:    ' + (Get-NSStatusLiveness $Workspace $watch))
    $activity = Get-NSStatusLastActivity $Workspace
    Say ('last activity: ' + ($(if ($activity.Length -gt 0) { $activity } else { 'none' })))
    Say ('last checkpoint: ' + (Get-NSGateCheckpointToken $Workspace))
    Say ('stall attempts: ' + (Get-NSStatusStallAttempts $Workspace))

    # The facts, derived here rather than by hand in the skill. One per line, stable label first,
    # so the model renders them rather than recomputing them.
    Say ''
    Say 'facts'
    $schema = ''
    try { $schema = [string](Get-NSStateVersion $Workspace) } catch { $schema = '' }
    Fact 'schema' $schema

    # Unarmed with work still open is the one state that reads wrong at a glance: a punch list
    # nobody is holding is a to-do file, and only Start makes it a shift.
    if ((-not $armed) -and ($open -gt 0)) {
        Fact 'armed' 'no (the punch list is a to-do file, not a shift; Start begins one)'
    }
    else {
        Fact 'armed' $(if ($armed) { 'yes' } else { 'no' })
    }

    Fact 'open item' (Get-NSStatusOpenTitle $punch)
    Fact 'parked' ([string](Get-NSStatusEntryCount (Get-NSLayoutPath $ns 'parking-lot')))
    foreach ($entry in (Get-NSStatusEntryTitles (Get-NSLayoutPath $ns 'parking-lot') 0)) {
        if (-not [string]::IsNullOrEmpty($entry)) { Fact 'parked entry' $entry }
    }

    $drafts = 0
    try { $drafts = [int](Get-NSOpenDrafts (Get-NSLayoutPath $ns 'drafting-table')) } catch { $drafts = 0 }
    $orders = 0
    try { $orders = [int](Get-NSOpenBoxesInFile (Get-NSLayoutPath $ns 'work-orders')) } catch { $orders = 0 }
    # With approved work open, staged work is informational and nothing else: Start works the punch
    # list exactly as the owner left it.
    $staged = 'drafts=' + $drafts + ' orders=' + $orders
    if ($open -gt 0) { $staged += ' (informational while items are open)' }
    Fact 'staged' $staged

    foreach ($entry in (Get-NSStatusEntryTitles (Get-NSLayoutPath $ns 'snag-log') 3)) {
        if (-not [string]::IsNullOrEmpty($entry)) { Fact 'snag' $entry }
    }

    Fact 'opportunities' (Get-NSStatusOpportunityCounts (Get-NSLayoutPath $ns 'opportunity-map'))
    foreach ($row in (Get-NSStatusBuilding (Get-NSLayoutPath $ns 'opportunity-map'))) {
        $fields = $row -split "`t", 2
        if ($fields.Count -eq 2) { Fact ('building ' + $fields[0]) $fields[1] }
    }

    $deadline = Get-NSStatusDeadlineRemaining $ns
    if ([string]::IsNullOrEmpty($deadline)) { $deadline = 'none (finite list)' }
    Fact 'deadline' $deadline

    if (Test-NSPathEntry (Get-NSLayoutPath $ns 'stop')) {
        $reason = Get-NSStatusStopReason $ns
        Fact 'stop' ('present' + $(if ([string]::IsNullOrEmpty($reason)) { '' } else { ' (' + $reason + ')' }))
    }
    else {
        Fact 'stop' 'absent'
    }
    Fact 'session' $(if (Test-NSPathEntry (Get-NSLayoutPath $ns 'session')) { 'bound' } else { 'none' })
    $lease = 'absent or unowned'
    try { if ($null -ne (Read-NSLease $ns)) { $lease = 'held' } } catch { $lease = 'absent or unowned' }
    Fact 'lease' $lease

    # Whether anything is watching the shift. An armed shift with work left and no live watchman
    # is not revived after a crash or a usage limit; only watchMinutes 0 means that on purpose.
    $watchmanPath = Get-NSLayoutPath $ns 'watchman'
    $watchmanState = 'none'
    if (Test-NSReparsePoint $watchmanPath) {
        $watchmanState = 'not a usable file'
    }
    elseif (Test-Path -LiteralPath $watchmanPath -PathType Leaf) {
        $watchmanLines = @()
        try { $watchmanLines = @([IO.File]::ReadAllLines($watchmanPath)) } catch { $watchmanLines = @() }
        $watchmanPid = if ($watchmanLines.Count -gt 0) { ([string]$watchmanLines[0]) -replace '\s', '' } else { '' }
        $watchmanStart = if ($watchmanLines.Count -gt 1) { [string]$watchmanLines[1] } else { '' }
        if ($watchmanPid -match '^[0-9]+$') {
            if ((Test-NSRecordedProcess $watchmanPid $watchmanStart) -eq 'Alive') { $watchmanState = "alive (pid $watchmanPid)" }
            else { $watchmanState = "stale (pid $watchmanPid)" }
        }
    }
    # A reason is the last thing a watchman recorded; once that watchman is gone it describes the past.
    $reasonNote = $(if ($watchmanState.StartsWith('alive', [StringComparison]::Ordinal)) { '' } else { '; the watchman that recorded it is not running' })
    if (Test-NSPathEntry (Get-NSLayoutPath $ns 'watch-reason')) {
        $code = ''
        try { $code = [string](Get-NSReasonCode $ns) } catch { $code = '' }
        if ([string]::IsNullOrEmpty($code)) { Fact 'watch reason' 'none' }
        else { Fact 'watch reason' ($code + ' (' + (Get-NSReasonLabel $code) + $reasonNote + ')') }
    }
    else {
        Fact 'watch reason' 'none'
    }

    Fact 'watchman' $watchmanState
    $watchMinutesRaw = ''
    try { $watchMinutesRaw = [string](Get-NSRule $Workspace 'watchMinutes' ([string]$env:NIGHTSHIFT_WATCH)) } catch { $watchMinutesRaw = '' }
    if ($armed -and $open -gt 0 -and $watchMinutesRaw -cne '0' -and
        -not ($watchmanState.StartsWith('alive', [StringComparison]::Ordinal) -or $watchmanState -ceq 'not a usable file')) {
        Fact 'watchman warning' 'the shift is armed with open items and nothing is watching it; a crash or usage limit will not be revived until ns start-watchman arms one again'
    }

    $mode = ''
    try { $mode = [string](Get-NSWorkMode $Workspace) } catch { $mode = '' }
    Fact 'work mode' $mode
    $target = ''
    try { $target = [string](Resolve-NSWorkTarget $Workspace) } catch { $target = '' }
    Fact 'work target' $target
    $receipts = 0
    try { $receipts = [int](Get-NSReceiptsCount $Workspace) } catch { $receipts = 0 }
    Fact 'artifact receipts' ([string]$receipts)
    $latest = ''
    try { $latest = [string](Get-NSLatestReceipt $Workspace) } catch { $latest = '' }
    Fact 'latest artifact receipt' $latest
    $unusableRecv = $false
    if ($mode -ceq 'artifact') {
        $recvPath = Get-NSReceiptsDir $Workspace
        $present = Test-Path -LiteralPath $recvPath
        $usable = $false
        try { $usable = [bool](Test-NSUsableReceiptsDir $Workspace) } catch { $usable = $false }
        if ($present -and (-not $usable)) {
            $unusableRecv = $true
            Fact 'receipts warning' 'the artifact receipts path is not a usable directory'
        }
    }
    if (Test-NSReceiptsEnabled $Workspace) {
        Fact 'completion record' 'per-item receipt'
        if (-not $unusableRecv) {
            $missing = Get-NSReceiptsMissingNns $Workspace
            if ($null -ne $missing -and $missing.Count -gt 0) { Fact 'receipts missing model text' ([string]$missing.Count) }
        }
    }
    else {
        Fact 'completion record' 'none; the owner disabled receipts'
    }

    foreach ($entry in (Get-NSStatusTransitions (Get-NSLayoutPath $ns 'shift-log') 3)) {
        if (-not [string]::IsNullOrEmpty($entry)) { Fact 'transition' $entry }
    }

    Say ''
    Say 'resolved policy'
    $table = Resolve-NSPolicy -Workspace $Workspace -Table
    if ([string]::IsNullOrEmpty($table)) { Say 'none' } else { Say $table }
    Say ''
    Say 'preflight gaps'
    $preflight = Get-NSPreflightNeeds $Workspace
    if ([string]::IsNullOrEmpty($preflight)) { Say 'none' } else { Say $preflight }
    return 0
}


# ---------------------------------------------------------------------------------------------
# Usage accounting, the native Windows half.
#
# The module carried the three readers and nothing that used them: no record, no marks, no total,
# no report line. A shift on native Windows measured its transcripts and then threw the numbers
# away. These are the POSIX functions in `lib/usage.sh` and `hooks/shared/gate-core.sh`, ported to
# the same file formats - `segments.tsv` and `marks.tsv`, tab separated, the same columns in the
# same order, including the eighth that carries the last response identity across a read.
#
# The formats are the contract between the two halves, not an implementation detail: a shift that
# starts on one host and is revived on the other reads what the first one wrote.

$script:NSUsageDimensions = @('input', 'cache_write', 'cache_read', 'output', 'reasoning')

function Get-NSUsageDir { param([Parameter(Mandatory = $true)][string]$NightshiftDir)
    return (Get-NSLayoutPath $NightshiftDir 'usage') }
function Get-NSUsageStatePath { param([Parameter(Mandatory = $true)][string]$NightshiftDir)
    return (Join-Path (Get-NSUsageDir $NightshiftDir) 'segments.tsv') }
function Get-NSUsageMarksPath { param([Parameter(Mandatory = $true)][string]$NightshiftDir)
    return (Join-Path (Get-NSUsageDir $NightshiftDir) 'marks.tsv') }

# Get-NSFileSize <path> - bytes, or -1 when the file cannot be measured.
function Get-NSFileSize {
    param([Parameter(Mandatory = $true)][string]$Path)
    try { return (Get-Item -LiteralPath $Path -Force).Length } catch { return -1 }
}

# Get-NSUsageField <fields> <dimension> - one dimension out of a snapshot, or ''.
function Get-NSUsageField {
    param([AllowEmptyString()][string]$Fields, [Parameter(Mandatory = $true)][string]$Key)
    if ([string]::IsNullOrEmpty($Fields)) { return '' }
    foreach ($pair in $Fields.Split(',')) {
        $i = $pair.IndexOf('=')
        if ($i -lt 1) { continue }
        if ($pair.Substring(0, $i) -ceq $Key) { return $pair.Substring($i + 1) }
    }
    return ''
}

# A dimension the host did not report is absent, never zero: zero is a measurement.
function Add-NSUsageFields {
    param([AllowEmptyString()][string]$A, [AllowEmptyString()][string]$B)
    $out = @()
    foreach ($dim in $script:NSUsageDimensions) {
        $x = Get-NSUsageField $A $dim
        $y = Get-NSUsageField $B $dim
        if ([string]::IsNullOrEmpty($x) -and [string]::IsNullOrEmpty($y)) { continue }
        if ([string]::IsNullOrEmpty($x)) { $x = '0' }
        if ([string]::IsNullOrEmpty($y)) { $y = '0' }
        $out += ($dim + '=' + ([long]$x + [long]$y))
    }
    return ($out -join ',')
}

function Get-NSUsageSubtract {
    param([AllowEmptyString()][string]$A, [AllowEmptyString()][string]$B)
    $out = @()
    foreach ($dim in $script:NSUsageDimensions) {
        $x = Get-NSUsageField $A $dim
        if ([string]::IsNullOrEmpty($x)) { continue }
        $y = Get-NSUsageField $B $dim
        if ([string]::IsNullOrEmpty($y)) { $y = '0' }
        $one = [long]$x - [long]$y
        if ($one -lt 0) { $one = 0 }
        $out += ($dim + '=' + $one)
    }
    return ($out -join ',')
}

# One segment line, seven fields plus the carried identity. Written whole so a partial line can
# never be read back as a complete one.
function Write-NSUsageSegments {
    # `[string[]]` refuses an empty array under a Mandatory binding, and an empty segment file is an
    # ordinary state - a workspace that has armed and read nothing yet.
    param([Parameter(Mandatory = $true)][string]$Path,
          [AllowEmptyCollection()][string[]]$Lines = @())
    $text = ''
    foreach ($l in $Lines) { if (-not [string]::IsNullOrEmpty($l)) { $text += $l + "`n" } }
    [IO.File]::WriteAllText($Path, $text, (New-Object Text.UTF8Encoding($false)))
}

function Get-NSUsageSegmentLines {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }
    return @([IO.File]::ReadAllLines($Path) | Where-Object { -not [string]::IsNullOrEmpty($_) })
}

function Get-NSUsageSegField {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Id,
          [Parameter(Mandatory = $true)][int]$Column)
    foreach ($line in (Get-NSUsageSegmentLines $Path)) {
        $parts = $line.Split("`t")
        if ($parts.Length -ge 1 -and $parts[0] -ceq $Id) {
            if ($parts.Length -ge $Column) { return $parts[$Column - 1] }
            return ''
        }
    }
    return ''
}

# Get-NSUsageOffset / Get-NSUsageCarry - where reading got to, and the response it stopped inside.
function Get-NSUsageOffset {
    param([Parameter(Mandatory = $true)][string]$NightshiftDir, [Parameter(Mandatory = $true)][string]$Id)
    $v = Get-NSUsageSegField (Get-NSUsageStatePath $NightshiftDir) $Id 5
    if ([string]::IsNullOrEmpty($v)) { return 0 }
    $n = 0
    if ([long]::TryParse($v, [ref]$n)) { return $n }
    return 0
}

function Get-NSUsageCarry {
    param([Parameter(Mandatory = $true)][string]$NightshiftDir, [Parameter(Mandatory = $true)][string]$Id)
    return (Get-NSUsageSegField (Get-NSUsageStatePath $NightshiftDir) $Id 8)
}

# Write-NSUsageRecord - one reading folded into the segment for that transcript.
#
# Claude's reader hands back only what was appended since the last offset, so its segment total
# accumulates; the other hosts hand back a counter already cumulative for the session. A stored
# current that is higher than the new reading means a different counter, and the segment is split
# rather than pretending one ran backwards.
function Write-NSUsageRecord {
    param([Parameter(Mandatory = $true)][string]$NightshiftDir,
          [Parameter(Mandatory = $true)][string]$HostName,
          [AllowEmptyString()][string]$Model,
          [Parameter(Mandatory = $true)][string]$Source,
          [Parameter(Mandatory = $true)][string]$Id,
          [AllowEmptyString()][string]$Offset,
          [AllowEmptyString()][string]$Fields,
          [AllowEmptyString()][string]$Carry = '')
    if ([string]::IsNullOrEmpty($Id) -or [string]::IsNullOrEmpty($Fields)) { return $false }
    $dir = Get-NSUsageDir $NightshiftDir
    $null = New-Item -ItemType Directory -Path $dir -Force
    $file = Get-NSUsageStatePath $NightshiftDir
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { Write-NSUsageSegments $file @() }
    # A reading can carry usage and no model: the model already recorded for the segment stands, and
    # a segment split off below keeps the model of the session it continues.
    if ([string]::IsNullOrEmpty($Model)) { $Model = Get-NSUsageSegField $file $Id 3 }
    $newId = $Id
    if ($Source -ceq 'transcript-incremental') {
        $seg = Get-NSUsageSegField $file $Id 7
        $Fields = Add-NSUsageFields $seg $Fields
    }
    $start = Get-NSUsageSegField $file $Id 6
    $cur = Get-NSUsageSegField $file $Id 7
    if ((-not [string]::IsNullOrEmpty($cur)) -and
        ((Get-NSUsageSubtract $cur $Fields) -cne (Get-NSUsageSubtract $cur $cur))) {
        $newId = $Id + '#' + (Get-NSUnixTime)
        $start = ''
        $cur = ''
    }
    if ([string]::IsNullOrEmpty($start)) {
        if ($Source -ceq 'transcript-incremental') { $start = Get-NSUsageSubtract $Fields $Fields }
        else { $start = $Fields }
    }
    $row = @($newId, $HostName, $Model, $Source, $Offset, $start, $Fields, $Carry) -join "`t"
    $out = @()
    $found = $false
    foreach ($line in (Get-NSUsageSegmentLines $file)) {
        if ($line.Split("`t")[0] -ceq $newId) { $out += $row; $found = $true }
        else { $out += $line }
    }
    if (-not $found) { $out += $row }
    Write-NSUsageSegments $file $out
    return $true
}

# Get-NSUsageTotal - what the shift has spent: each segment's advance past where it was first seen.
function Get-NSUsageTotal {
    param([Parameter(Mandatory = $true)][string]$NightshiftDir)
    $file = Get-NSUsageStatePath $NightshiftDir
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return '' }
    $total = ''
    foreach ($line in (Get-NSUsageSegmentLines $file)) {
        $p = $line.Split("`t")
        if ($p.Length -lt 7) { continue }
        if ([string]::IsNullOrEmpty($p[6])) { continue }
        $total = Add-NSUsageFields $total (Get-NSUsageSubtract $p[6] $p[5])
    }
    return $total
}

# The baseline segment: this transcript starts here, with nothing charged for what came before.
function Write-NSUsageSegBaseline {
    param([Parameter(Mandatory = $true)][string]$NightshiftDir,
          [Parameter(Mandatory = $true)][string]$Id, [Parameter(Mandatory = $true)][long]$Offset)
    $dir = Get-NSUsageDir $NightshiftDir
    $null = New-Item -ItemType Directory -Path $dir -Force
    $file = Get-NSUsageStatePath $NightshiftDir
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { Write-NSUsageSegments $file @() }
    foreach ($line in (Get-NSUsageSegmentLines $file)) {
        if ($line.Split("`t")[0] -ceq $Id) { return $false }
    }
    $row = @($Id, 'claude', '', 'transcript-incremental', $Offset, '', '', '') -join "`t"
    $lines = @(Get-NSUsageSegmentLines $file) + $row
    Write-NSUsageSegments $file $lines
    return $true
}

function Get-NSUsageMarkCount {
    param([Parameter(Mandatory = $true)][string]$NightshiftDir)
    $file = Get-NSUsageMarksPath $NightshiftDir
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return 0 }
    return @([IO.File]::ReadAllLines($file) | Where-Object { -not [string]::IsNullOrEmpty($_) }).Count
}

# Write-NSUsageMark <nightshift-dir> <label> [tick|switch|pause] - the running total and the clock at
# one moment, closing the span since the mark before it and charging it to <label>. Only a tick mark
# says the item is done; a mark written before kinds existed is a tick.
function Write-NSUsageMark {
    param([Parameter(Mandatory = $true)][string]$NightshiftDir, [Parameter(Mandatory = $true)][string]$Label,
          [ValidateSet('tick', 'switch', 'pause')][string]$Kind = 'tick')
    $dir = Get-NSUsageDir $NightshiftDir
    $null = New-Item -ItemType Directory -Path $dir -Force
    $file = Get-NSUsageMarksPath $NightshiftDir
    $total = Get-NSUsageTotal $NightshiftDir
    $line = @((Get-NSUnixTime), $Label, $total, $Kind) -join "`t"
    [IO.File]::AppendAllText($file, $line + "`n", (New-Object Text.UTF8Encoding($false)))
    return $true
}

# Get-NSUsageActive <nightshift-dir> - the item the running span is being charged to, or ''.
function Get-NSUsageActive {
    param([Parameter(Mandatory = $true)][string]$NightshiftDir)
    $file = Join-Path (Get-NSUsageDir $NightshiftDir) 'active'
    if (-not (Test-Path -LiteralPath $file -PathType Leaf) -or (Test-NSReparsePoint $file)) { return '' }
    $lines = @([IO.File]::ReadAllLines($file))
    if ($lines.Count -eq 0) { return '' }
    return $lines[0]
}

# Set-NSUsageActive <nightshift-dir> [label] - charge the running span to <label> from here on; no
# label clears it.
function Set-NSUsageActive {
    param([Parameter(Mandatory = $true)][string]$NightshiftDir, [AllowEmptyString()][string]$Label = '')
    $dir = Get-NSUsageDir $NightshiftDir
    $file = Join-Path $dir 'active'
    if (Test-NSReparsePoint $file) { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue }
    if ([string]::IsNullOrEmpty($Label)) {
        Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
        return
    }
    $null = New-Item -ItemType Directory -Path $dir -Force
    [IO.File]::WriteAllText($file, $Label + "`n", (New-Object Text.UTF8Encoding($false)))
}

# Get-NSUsageItemTotal <nightshift-dir> <label> - what this shift has charged to one item across every
# span that closed on it: `<fields>`t<wall-sec>`t<first-start>`t<paused-sec>`t<reason>`, or ''.
function Get-NSUsageItemTotal {
    param([Parameter(Mandatory = $true)][string]$NightshiftDir, [Parameter(Mandatory = $true)][string]$Label)
    $file = Get-NSUsageMarksPath $NightshiftDir
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return '' }
    $fields = ''
    $wall = [long]0
    $first = ''
    $paused = [long]0
    $reason = ''
    $prev = $null
    foreach ($line in @([IO.File]::ReadAllLines($file) | Where-Object { -not [string]::IsNullOrEmpty($_) })) {
        $cur = $line.Split("`t")
        if ($null -ne $prev -and $cur.Length -ge 2 -and $cur[1] -ceq $Label) {
            $pt = $(if ($prev.Length -ge 3) { $prev[2] } else { '' })
            $ct = $(if ($cur.Length -ge 3) { $cur[2] } else { '' })
            $fields = Add-NSUsageFields $fields (Get-NSUsageSubtract $ct $pt)
            $wall += ([long]$cur[0] - [long]$prev[0])
            if ([string]::IsNullOrEmpty($first)) { $first = $prev[0] }
            $gap = Get-NSUsagePausedBetween $NightshiftDir ([long]$prev[0]) ([long]$cur[0])
            if (-not [string]::IsNullOrEmpty($gap)) {
                $gp = $gap.Split("`t")
                $paused += [long]$gp[0]
                $reason = $(if ($gp.Length -ge 2) { $gp[1] } else { '' })
            }
        }
        $prev = $cur
    }
    if ([string]::IsNullOrEmpty($first)) { return '' }
    return ($fields + "`t" + $wall + "`t" + $first + "`t" + $paused + "`t" + $reason)
}

# The shift's own start, written before the first reading so it stands at zero, and the transcripts
# stamped where they already stood so what preceded the shift is not billed to its first item.
function Write-NSUsageMarkArm {
    param([Parameter(Mandatory = $true)][string]$NightshiftDir, [string[]]$Transcripts = @())
    $dir = Get-NSUsageDir $NightshiftDir
    $null = New-Item -ItemType Directory -Path $dir -Force
    $file = Get-NSUsageMarksPath $NightshiftDir
    if ((Test-Path -LiteralPath $file -PathType Leaf) -and (Get-NSFileSize $file) -gt 0) { return $true }
    foreach ($t in $Transcripts) {
        if ([string]::IsNullOrEmpty($t)) { continue }
        if (-not (Test-Path -LiteralPath $t -PathType Leaf)) { continue }
        $size = Get-NSFileSize $t
        if ($size -lt 0) { continue }
        $null = Write-NSUsageSegBaseline $NightshiftDir $t $size
    }
    [IO.File]::AppendAllText($file, ((Get-NSUnixTime).ToString() + "`tarm`t`n"),
        (New-Object Text.UTF8Encoding($false)))
    return $true
}

function Get-NSUsageSinceLastMark {
    param([Parameter(Mandatory = $true)][string]$NightshiftDir)
    $file = Get-NSUsageMarksPath $NightshiftDir
    $now = Get-NSUnixTime
    if ((-not (Test-Path -LiteralPath $file -PathType Leaf)) -or (Get-NSFileSize $file) -le 0) {
        return ("`t0")
    }
    $lines = @([IO.File]::ReadAllLines($file) | Where-Object { -not [string]::IsNullOrEmpty($_) })
    $last = $lines[$lines.Length - 1].Split("`t")
    $epoch = $now
    $n = 0
    if ($last.Length -ge 1 -and [long]::TryParse($last[0], [ref]$n)) { $epoch = $n }
    $prevTotal = $(if ($last.Length -ge 3) { $last[2] } else { '' })
    return ((Get-NSUsageSubtract (Get-NSUsageTotal $NightshiftDir) $prevTotal) + "`t" + ($now - $epoch))
}

function Get-NSUsageLastItem {
    param([Parameter(Mandatory = $true)][string]$NightshiftDir)
    $file = Get-NSUsageMarksPath $NightshiftDir
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return '' }
    $lines = @([IO.File]::ReadAllLines($file) | Where-Object { -not [string]::IsNullOrEmpty($_) })
    if ($lines.Length -lt 2) { return '' }
    $prev = $lines[$lines.Length - 2].Split("`t")
    $last = $lines[$lines.Length - 1].Split("`t")
    $pt = $(if ($prev.Length -ge 3) { $prev[2] } else { '' })
    $lt = $(if ($last.Length -ge 3) { $last[2] } else { '' })
    $seconds = [long]$last[0] - [long]$prev[0]
    $label = $(if ($last.Length -ge 2) { $last[1] } else { '' })
    return ((Get-NSUsageSubtract $lt $pt) + "`t" + $seconds + "`t" + $label)
}

function Get-NSUsageDuration {
    param([AllowEmptyString()][string]$Seconds)
    $s = 0
    if ([string]::IsNullOrEmpty($Seconds) -or -not [long]::TryParse($Seconds, [ref]$s)) {
        return 'unavailable'
    }
    if ($s -lt 60) { return ("{0}s" -f $s) }
    if ($s -lt 3600) { return ("{0}m {1}s" -f [math]::Floor($s / 60), ($s % 60)) }
    return ("{0}h {1}m" -f [math]::Floor($s / 3600), [math]::Floor(($s % 3600) / 60))
}

function Get-NSUsageIso {
    param([AllowEmptyString()][string]$Epoch)
    $e = 0L
    if ([string]::IsNullOrEmpty($Epoch) -or -not [long]::TryParse($Epoch, [ref]$e)) { return '' }
    $utc = New-Object DateTime 1970, 1, 1, 0, 0, 0, ([DateTimeKind]::Utc)
    return $utc.AddSeconds($e).ToString('yyyy-MM-ddTHH:mmZ',
        [Globalization.CultureInfo]::InvariantCulture)
}

function Get-NSUsageDurationLine {
    param(
        [AllowEmptyString()][string]$WallSeconds,
        [AllowEmptyString()][string]$PausedSeconds = '0',
        [AllowEmptyString()][string]$Reason = '',
        [AllowEmptyString()][string]$FromEpoch = '',
        [AllowEmptyString()][string]$ToEpoch = ''
    )
    $wall = 0L
    $paused = 0L
    if (-not [long]::TryParse($WallSeconds, [ref]$wall)) { $wall = 0 }
    if (-not [long]::TryParse($PausedSeconds, [ref]$paused)) { $paused = 0 }
    $work = $wall - $paused
    if ($work -lt 0) { $work = 0 }
    $rows = New-Object 'System.Collections.Generic.List[string]'
    $null = $rows.Add('| Time | |')
    $null = $rows.Add('| --- | --- |')
    $null = $rows.Add('| working | ' + (Get-NSUsageDuration ([string]$work)) + ' |')
    if ($paused -gt 0) {
        $pause = (Get-NSUsageDuration ([string]$paused))
        if (-not [string]::IsNullOrEmpty($Reason)) { $pause += ' (' + $Reason + ')' }
        $null = $rows.Add('| paused | ' + $pause + ' |')
    }
    $null = $rows.Add('| wall | ' + (Get-NSUsageDuration ([string]$wall)) + ' |')
    $from = Get-NSUsageIso $FromEpoch
    $to = Get-NSUsageIso $ToEpoch
    if (-not [string]::IsNullOrEmpty($from) -and -not [string]::IsNullOrEmpty($to)) {
        $null = $rows.Add('| span | ' + $from + ' ' + [char]0x2192 + ' ' + $to + ' |')
    }
    return ($rows -join "`n")
}

function Get-NSUsageSegmentCount {
    param([Parameter(Mandatory = $true)][string]$NightshiftDir)
    return @(Get-NSUsageSegmentLines (Get-NSUsageStatePath $NightshiftDir)).Count
}

function Get-NSUsageHosts {
    param([Parameter(Mandatory = $true)][string]$NightshiftDir)
    $lines = @(Get-NSUsageSegmentLines (Get-NSUsageStatePath $NightshiftDir))
    if ($lines.Count -eq 0) { return '' }
    $seen = New-Object 'System.Collections.Generic.List[string]'
    foreach ($line in $lines) {
        $p = $line.Split("`t")
        $pair = (($(if ($p.Length -ge 2) { $p[1] } else { '' })) + ' ' +
                 ($(if ($p.Length -ge 3) { $p[2] } else { '' })))
        if (-not $seen.Contains($pair)) { $null = $seen.Add($pair) }
    }
    $sorted = @($seen | Sort-Object -CaseSensitive)
    return ($sorted -join '; ')
}

# What each host's figures overlap. Input is fresh input on every host; what is still counted
# inside what is stated, so a total can be checked against the host's own figures.
function Get-NSUsageOverlapText {
    param([AllowEmptyString()][string]$HostName)
    switch ($HostName) {
        'claude' { return 'Cache reads and cache writes are separate from the input figure; reasoning is inside output.' }
        'codex' { return 'Cache reads and cache writes are separate from the input figure; reasoning is inside output.' }
        'cursor' { return 'The input figure overlaps the cache figures; Cursor reports no reasoning or subagent tokens.' }
        default { return 'Overlap between the dimensions is unknown for this host.' }
    }
}

function Get-NSUsageDimLabel {
    param([AllowEmptyString()][string]$Dimension)
    switch ($Dimension) {
        'cache_write' { return 'cache write' }
        'cache_read' { return 'cache read' }
        default { return $Dimension }
    }
}

function Get-NSUsageLine {
    param([AllowEmptyString()][string]$Fields, [AllowEmptyString()][string]$Sources,
          [AllowEmptyString()][string]$Segments, [AllowEmptyString()][string]$HostName = '')
    $rows = New-Object 'System.Collections.Generic.List[string]'
    $null = $rows.Add('| Tokens | Amount |')
    $null = $rows.Add('| --- | ---: |')
    $comment = @()
    $word = 'segment'
    if ($Segments -cne '1') { $word = 'segments' }
    foreach ($dim in $script:NSUsageDimensions) {
        $v = Get-NSUsageField $Fields $dim
        if ([string]::IsNullOrEmpty($v)) { $v = 'unavailable' }
        if ($v -cne 'unavailable') {
            $comment += $v
            $v = Get-NSUsageScale $v
        }
        else {
            $comment += '0'
        }
        $null = $rows.Add('| ' + (Get-NSUsageDimLabel $dim) + ' | ' + $v + ' |')
    }
    return (($rows -join "`n") + "`n`n<!-- tokens " + ($comment -join ' ') + " -->`n" +
            $Sources + ' ' + $script:NSDot + ' ' + $Segments + ' ' + $word + '. ' + (Get-NSUsageOverlapText $HostName))
}

# The item's own section of the report, written where the model already writes its account of the
# work. An existing section is spliced into rather than appended after, so one item is one section.
function Add-NSGateUsageAppend {
    param([Parameter(Mandatory = $true)][string]$Receipt, [Parameter(Mandatory = $true)][string]$Label,
          [Parameter(Mandatory = $true)][string]$Usage, [Parameter(Mandatory = $true)][string]$Duration)
    if ([string]::IsNullOrEmpty($Receipt)) { return }
    if (Test-NSReparsePoint $Receipt) { return }
    $utf8 = New-Object Text.UTF8Encoding($false)
    $dir = Split-Path -Parent $Receipt
    if (-not [string]::IsNullOrEmpty($dir)) {
        $null = New-Item -ItemType Directory -Path $dir -Force -ErrorAction SilentlyContinue
    }
    $block = $Usage + "`n`n" + $Duration + "`n"
    if (-not (Test-Path -LiteralPath $Receipt -PathType Leaf)) {
        [IO.File]::WriteAllText($Receipt, ('# ' + $Label + "`n`n" + $block), $utf8)
        return
    }
    $content = [IO.File]::ReadAllText($Receipt)
    $nl = "`n"
    if ($content.Contains("`r`n")) { $nl = "`r`n" }
    if ($content -cmatch '(?s)^(# [^\r\n]+)(\r?\n)') {
        $head = $Matches[1]
        $rest = $content.Substring($Matches[0].Length).TrimStart([char]13, [char]10)
        [IO.File]::WriteAllText($Receipt, ($head + $nl + $nl + $block + $nl + $rest), $utf8)
        return
    }
    [IO.File]::WriteAllText($Receipt, ($block + $nl + $content), $utf8)
}

# Get-NSGateTickedLabels <punch-list> - every ticked item's id, list order, as the report heads its
# section. A capital [X] is a tick here as it is in the counts. An item whose id cannot be read is
# 'item <n>', n its place among the ticked.
function Get-NSGateTickedLabels {
    param([Parameter(Mandatory = $true)][string]$PunchList)
    $labels = New-Object 'System.Collections.Generic.List[string]'
    if (-not (Test-Path -LiteralPath $PunchList -PathType Leaf)) { return , $labels.ToArray() }
    foreach ($line in (Get-NSPunchItemsSection $PunchList)) {
        if ($line -cmatch '^- \[[xX]\]') {
            $t = Get-NSItemLabel $line
            if ([string]::IsNullOrEmpty($t)) { $t = 'item ' + ($labels.Count + 1) }
            $labels.Add($t)
        }
    }
    return , $labels.ToArray()
}

# Get-NSGateUnchargedLabels <nightshift-dir> <punch-list> - the ticked items no mark names yet, in
# list order. A label ticked twice under the same name is charged twice, once per mark.
function Get-NSGateUnchargedLabels {
    param([Parameter(Mandatory = $true)][string]$NightshiftDir, [Parameter(Mandatory = $true)][string]$PunchList)
    $charged = New-Object 'System.Collections.Generic.Dictionary[string,int]' ([StringComparer]::Ordinal)
    $marks = Get-NSUsageMarksPath $NightshiftDir
    if ((Test-Path -LiteralPath $marks -PathType Leaf) -and -not (Test-NSReparsePoint $marks)) {
        $rows = 0
        foreach ($row in [IO.File]::ReadAllLines($marks)) {
            if ([string]::IsNullOrEmpty($row)) { continue }
            $rows++
            $fields = $row.Split("`t") + @('', '', '', '')
            $name = $fields[1]
            # The first mark is the shift arming, not an item, and only a tick closes an item: a
            # switch or a pause charges a span to an item that is still open.
            if ($rows -eq 1 -and $name -ceq 'arm') { continue }
            if ($fields[3] -cne '' -and $fields[3] -cne 'tick') { continue }
            if ($charged.ContainsKey($name)) { $charged[$name]++ } else { $charged[$name] = 1 }
        }
    }
    $open = New-Object 'System.Collections.Generic.List[string]'
    foreach ($label in (Get-NSGateTickedLabels $PunchList)) {
        if ($charged.ContainsKey($label) -and $charged[$label] -gt 0) { $charged[$label]--; continue }
        $open.Add($label)
    }
    return , $open.ToArray()
}

# Write-NSUsagePause <nightshift-dir> <reason> - a gap the runtime knows was not work.
#
# A session that ended and was revived, Esc, a usage-limit wait, or a shift held at STOP is
# wall-clock time nobody spent. The duration line lists it and subtracts it from working time.
function Write-NSUsagePause {
    param([Parameter(Mandatory = $true)][string]$NightshiftDir, [AllowEmptyString()][string]$Reason = '',
        [long]$At = 0)
    $dir = Get-NSUsageDir $NightshiftDir
    if (Test-NSReparsePoint $dir) { return $false }
    try { $null = New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop } catch { return $false }
    $why = $Reason
    if ([string]::IsNullOrEmpty($why)) { $why = 'paused' }
    $file = Join-Path $dir 'pauses.tsv'
    if (Test-NSReparsePoint $file) { return $false }
    $utf8 = New-Object Text.UTF8Encoding($false)
    $when = $(if ($At -gt 0) { $At } else { Get-NSUnixTime })
    try { [IO.File]::AppendAllText($file, ($when.ToString() + "`t" + $why + "`n"), $utf8) }
    catch { return $false }
    return $true
}

# Get-NSUsageLastPause <nightshift-dir> - the epoch of the most recent recorded pause, or 0.
# Mirrors ns_usage_last_pause.
function Get-NSUsageLastPause {
    param([Parameter(Mandatory = $true)][string]$NightshiftDir)
    $file = Join-Path (Get-NSUsageDir $NightshiftDir) 'pauses.tsv'
    if (-not (Test-Path -LiteralPath $file -PathType Leaf) -or (Test-NSReparsePoint $file)) { return [long]0 }
    $last = [long]0
    foreach ($line in [IO.File]::ReadAllLines($file)) {
        $field = ($line -split "`t")[0]
        if ($field -match '^[0-9]+$' -and [long]$field -gt $last) { $last = [long]$field }
    }
    return $last
}

# Get-NSUsageResumedAt <nightshift-dir> <epoch> - when work was next seen after a pause, from the
# marks the runtime was already keeping.
function Get-NSUsageResumedAt {
    param([Parameter(Mandatory = $true)][string]$NightshiftDir, [Parameter(Mandatory = $true)][long]$After)
    $file = Get-NSUsageMarksPath $NightshiftDir
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return '' }
    foreach ($line in @([IO.File]::ReadAllLines($file))) {
        $at = $line.Split("`t")[0]
        if ($at -notmatch '^[0-9]+$') { continue }
        if ([long]$at -gt $After) { return $at }
    }
    return ''
}

# Get-NSUsagePausedBetween <nightshift-dir> <from> <to> - how long was recorded as not-work inside one
# span, and why: `<seconds>`t<reason>`, empty when the runtime knows of no gap.
#
# A pause is closed by the next thing that happens, never past <to>. Where nothing followed, the gap
# is open and is reported as such rather than guessed at.
function Get-NSUsagePausedBetween {
    param([Parameter(Mandatory = $true)][string]$NightshiftDir, [Parameter(Mandatory = $true)][long]$From,
          [Parameter(Mandatory = $true)][long]$To)
    $file = Join-Path (Get-NSUsageDir $NightshiftDir) 'pauses.tsv'
    if (Test-NSReparsePoint $file) { return '' }
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return '' }
    $total = [long]0
    $lastReason = ''
    foreach ($line in @([IO.File]::ReadAllLines($file))) {
        $parts = $line.Split("`t")
        $at = $parts[0]
        if ($at -notmatch '^[0-9]+$') { continue }
        if ([long]$at -lt $From -or [long]$at -ge $To) { continue }
        $next = Get-NSUsageResumedAt $NightshiftDir ([long]$at)
        if ([string]::IsNullOrEmpty($next)) { continue }
        $end = [math]::Min([long]$next, $To)
        $total += ($end - [long]$at)
        $lastReason = $(if ($parts.Length -ge 2) { $parts[1] } else { '' })
    }
    if ($total -le 0) { return '' }
    return ([string]$total + "`t" + $lastReason)
}

# Get-NSUsagePausesByReason <nightshift-dir> <from> <to> - the not-work inside one span, one entry
# per reason in the order each was first recorded. Each gap is measured exactly as
# Get-NSUsagePausedBetween measures it, so the entries sum to its total.
function Get-NSUsagePausesByReason {
    param([Parameter(Mandatory = $true)][string]$NightshiftDir, [Parameter(Mandatory = $true)][long]$From,
          [Parameter(Mandatory = $true)][long]$To)
    $result = New-Object Collections.Generic.List[object]
    $file = Join-Path (Get-NSUsageDir $NightshiftDir) 'pauses.tsv'
    $marksFile = Get-NSUsageMarksPath $NightshiftDir
    if ((Test-NSReparsePoint $file) -or -not (Test-Path -LiteralPath $file -PathType Leaf) -or
        -not (Test-Path -LiteralPath $marksFile -PathType Leaf)) { return , $result.ToArray() }
    $marks = New-Object Collections.Generic.List[long]
    foreach ($line in @([IO.File]::ReadAllLines($marksFile))) {
        $at = $line.Split("`t")[0]
        if ($at -cmatch '^[0-9]+$') { $marks.Add([long]$at) }
    }
    $order = New-Object Collections.Generic.List[string]
    $totals = New-Object 'Collections.Generic.Dictionary[string,long]' ([StringComparer]::Ordinal)
    foreach ($line in @([IO.File]::ReadAllLines($file))) {
        $parts = $line.Split("`t")
        if ($parts[0] -cnotmatch '^[0-9]+$') { continue }
        $at = [long]$parts[0]
        if ($at -lt $From -or $at -ge $To) { continue }
        $resumed = -1L
        foreach ($mark in $marks) {
            if ($mark -gt $at) { $resumed = $mark; break }
        }
        if ($resumed -lt 0) { continue }
        if ($resumed -gt $To) { $resumed = $To }
        $why = $(if ($parts.Length -ge 2 -and $parts[1].Length -gt 0) { $parts[1] } else { 'paused' })
        if (-not $totals.ContainsKey($why)) {
            $order.Add($why)
            $totals[$why] = 0
        }
        $totals[$why] += ($resumed - $at)
    }
    foreach ($why in $order) {
        if ($totals[$why] -gt 0) { $result.Add([pscustomobject]@{ Reason = $why; Seconds = $totals[$why] }) }
    }
    return , $result.ToArray()
}

# What the shift cost, written where the item's section is, at the moment the item is ticked. Marks
# are the boundaries: a tick, a change of the item being worked, a shift ending with an item open.
# Everything spent between two marks belongs to the item the second one names.
function Invoke-NSGateUsageTick {
    param([Parameter(Mandatory = $true)][string]$NightshiftDir,
          [Parameter(Mandatory = $true)][string]$Project, [Parameter(Mandatory = $true)][string]$Label)
    if (-not (Test-Path -LiteralPath $NightshiftDir -PathType Container)) { return $false }
    if (-not (Test-NSReceiptsEnabled $Project)) { return $false }
    if (-not (Write-NSUsageMark $NightshiftDir $Label 'tick')) { return $false }
    $receipt = Get-NSReceiptPath $Project $Label
    Invoke-NSGateSessionRow $NightshiftDir $Project $Label 'ticked'
    $total = Get-NSUsageItemTotal $NightshiftDir $Label
    if ([string]::IsNullOrEmpty($total)) { return $false }
    $parts = $total.Split("`t")
    # Tokens and time are two measurements with a setting each. One the owner turned off says off,
    # which is not the same as one the host did not report.
    if ((Get-NSReceiptsField $Project 'usage') -ceq 'off') {
        $line = '**Tokens:** off'
    }
    else {
        $hosts = Get-NSUsageHosts $NightshiftDir
        if ([string]::IsNullOrEmpty($hosts)) { $hosts = 'unknown' }
        $line = Get-NSUsageLine $parts[0] $hosts (Get-NSUsageSegmentCount $NightshiftDir) ($hosts.Split(' ')[0])
    }
    if ((Get-NSReceiptsField $Project 'duration') -ceq 'off') {
        $duration = '**Time:** off'
    }
    else {
        # Working time first. Wall and any recorded gap stay beside it so the figure can be checked.
        $duration = Get-NSUsageDurationLine $parts[1] $parts[3] $parts[4] $parts[2] ([string](Get-NSUnixTime))
    }
    Add-NSGateUsageAppend $receipt $Label $line $duration
    Update-NSReceiptLabel $receipt $Label
    $due = Get-NSLayoutPath $NightshiftDir 'receipt-due'
    if (Test-Path -LiteralPath $due -PathType Leaf) { Remove-Item -LiteralPath $due -Force -ErrorAction SilentlyContinue }
    Write-NSReceiptsIndex $Project
    return $true
}

# Invoke-NSGateSessionRow <nightshift-dir> <project> <label> <ended> - the span the last mark just
# closed, recorded as one session in the item's receipt.
function Invoke-NSGateSessionRow {
    param([Parameter(Mandatory = $true)][string]$NightshiftDir, [Parameter(Mandatory = $true)][string]$Project,
          [Parameter(Mandatory = $true)][string]$Label, [Parameter(Mandatory = $true)][string]$Ended)
    $span = Get-NSUsageLastItem $NightshiftDir
    if ([string]::IsNullOrEmpty($span)) { return }
    $parts = $span.Split("`t")
    $lines = @([IO.File]::ReadAllLines((Get-NSUsageMarksPath $NightshiftDir)) | Where-Object { -not [string]::IsNullOrEmpty($_) })
    $end = [long]0
    if (-not [long]::TryParse($lines[$lines.Length - 1].Split("`t")[0], [ref]$end)) { return }
    $start = $end - [long]$parts[1]
    $paused = [long]0
    $gap = Get-NSUsagePausedBetween $NightshiftDir $start $end
    if (-not [string]::IsNullOrEmpty($gap)) { $paused = [long]$gap.Split("`t")[0] }
    $work = [string]([math]::Max([long]0, $end - $start - $paused))
    if ((Get-NSReceiptsField $Project 'duration') -ceq 'off') { $work = 'off' }
    if ((Get-NSReceiptsField $Project 'usage') -ceq 'off') {
        $in = 'off'
        $out = 'off'
    }
    else {
        $in = Get-NSUsageField $parts[0] 'input'
        $out = Get-NSUsageField $parts[0] 'output'
    }
    $sid = ''
    $state = Get-NSShiftPolicyState $Project
    if ($state['state'] -ceq 'valid') { $sid = [string]$state['policy']['shiftId'] }
    Add-NSReceiptSession (Get-NSReceiptPath $Project $Label) $Label $(if ($sid) { $sid } else { '-' }) `
        $start $end $work $(if ($in) { $in } else { '-' }) $(if ($out) { $out } else { '-' }) $Ended
}

# Test-NSGateItemOpen <punch-list> <label> - true when that item is still an open box.
function Test-NSGateItemOpen {
    param([Parameter(Mandatory = $true)][string]$PunchList, [Parameter(Mandatory = $true)][string]$Label)
    foreach ($row in (Get-NSItemRows $PunchList 'open')) {
        if ($row.Label -ceq $Label) { return $true }
    }
    return $false
}

# Get-NSGateSessionEnd <nightshift-dir> <label> - how a session that is not a tick ended: blocked when
# the parking lot records the item as stalled, switched away otherwise.
function Get-NSGateSessionEnd {
    param([Parameter(Mandatory = $true)][string]$NightshiftDir, [Parameter(Mandatory = $true)][string]$Label)
    $lot = Get-NSLayoutPath $NightshiftDir 'parking-lot'
    if ((Test-Path -LiteralPath $lot -PathType Leaf) -and -not (Test-NSReparsePoint $lot)) {
        foreach ($line in [IO.File]::ReadAllLines($lot)) {
            if ($line.Contains($Label) -and $line -match 'stalled') { return 'blocked' }
        }
    }
    return 'switched-away'
}

# Test-NSGateUsageAccounting <nightshift-dir> <project> - true when an armed shift with the receipts
# and usage on is keeping marks, which is when the item being worked is followed.
function Test-NSGateUsageAccounting {
    param([Parameter(Mandatory = $true)][string]$NightshiftDir, [Parameter(Mandatory = $true)][string]$Project)
    if (-not (Test-Path -LiteralPath (Get-NSLayoutPath $NightshiftDir 'armed') -PathType Leaf)) { return $false }
    if (-not (Test-NSReceiptsEnabled $Project)) { return $false }
    return ((Get-NSUsageMarkCount $NightshiftDir) -gt 0)
}

# Invoke-NSGateUsageSwitch <nightshift-dir> <project> <active> - follow the item being worked. When it
# changes, the span so far closes on the item that was being worked, which gets a session, and the
# running span is charged to the new one from here.
function Invoke-NSGateUsageSwitch {
    param([Parameter(Mandatory = $true)][string]$NightshiftDir, [Parameter(Mandatory = $true)][string]$Project,
          [AllowEmptyString()][string]$Active)
    if ([string]::IsNullOrEmpty($Active)) { return }
    # The pulse runs this on every tool call, so the common case, the same item still being worked,
    # is decided before anything reads the rules.
    $owner = Get-NSUsageActive $NightshiftDir
    if ($owner -ceq $Active) { return }
    if (-not (Test-NSGateUsageAccounting $NightshiftDir $Project)) { return }
    if (-not [string]::IsNullOrEmpty($owner) -and (Test-NSGateItemOpen (Get-NSLayoutPath $NightshiftDir 'punch-list') $owner)) {
        $null = Write-NSUsageMark $NightshiftDir $owner 'switch'
        Invoke-NSGateSessionRow $NightshiftDir $Project $owner (Get-NSGateSessionEnd $NightshiftDir $owner)
    }
    Set-NSUsageActive $NightshiftDir $Active
}

# Invoke-NSGateUsageFlush <nightshift-dir> <project> - a shift ending with an item open closes that
# item's session as paused. The next shift continues the same receipt.
function Invoke-NSGateUsageFlush {
    param([Parameter(Mandatory = $true)][string]$NightshiftDir, [Parameter(Mandatory = $true)][string]$Project)
    if (-not (Test-NSGateUsageAccounting $NightshiftDir $Project)) { return }
    $owner = Get-NSUsageActive $NightshiftDir
    if ([string]::IsNullOrEmpty($owner)) { return }
    if (Test-NSGateItemOpen (Get-NSLayoutPath $NightshiftDir 'punch-list') $owner) {
        $null = Write-NSUsageMark $NightshiftDir $owner 'pause'
        Invoke-NSGateSessionRow $NightshiftDir $Project $owner 'paused'
    }
    Set-NSUsageActive $NightshiftDir
}

# The catch-up. Every ticked item no mark names yet gets one, in list order, so a pulse that never
# fired does not cost the shift its accounting and an item ticked out of list order is charged to
# itself. The arm mark is the shift's start, not an item.
function Invoke-NSGateUsageSync {
    param([Parameter(Mandatory = $true)][string]$NightshiftDir, [Parameter(Mandatory = $true)][string]$Project,
          [Parameter(Mandatory = $true)][string]$PunchList, [Parameter(Mandatory = $true)][int]$Ticked,
          [string[]]$Transcripts = @())
    if (-not (Test-Path -LiteralPath $NightshiftDir -PathType Container)) { return $false }
    if (-not (Test-Path -LiteralPath $PunchList -PathType Leaf)) { return $false }
    # Accounting belongs to an armed shift with the report on. Before Start there is no shift to
    # bill, and an arm mark written then would stand in the way of the baseline arming records.
    if (-not (Test-Path -LiteralPath (Get-NSLayoutPath $NightshiftDir 'armed') -PathType Leaf)) { return $false }
    if (-not (Test-NSReceiptsEnabled $Project)) { return $false }
    if ($Ticked -lt 0) { return $false }
    if ((Get-NSUsageMarkCount $NightshiftDir) -le 0) { $null = Write-NSUsageMarkArm $NightshiftDir $Transcripts }
    [string[]]$labels = Get-NSGateUnchargedLabels $NightshiftDir $PunchList
    if ($null -eq $labels -or $labels.Count -eq 0) { return $true }
    # The span running now belongs to the item being worked. When that item is among the newly
    # ticked it closes first; when it is still open it closes as a switch, so a box ticked for work
    # done earlier is not charged for the work in hand.
    $owner = Get-NSUsageActive $NightshiftDir
    if (-not [string]::IsNullOrEmpty($owner)) {
        $at = [Array]::IndexOf([string[]]$labels, $owner)
        if ($at -ge 0) {
            $rest = New-Object Collections.Generic.List[string]
            for ($i = 0; $i -lt $labels.Count; $i++) { if ($i -ne $at) { $rest.Add($labels[$i]) } }
            $labels = @($owner) + $rest.ToArray()
        }
        elseif (Test-NSGateItemOpen $PunchList $owner) {
            $null = Write-NSUsageMark $NightshiftDir $owner 'switch'
            Invoke-NSGateSessionRow $NightshiftDir $Project $owner (Get-NSGateSessionEnd $NightshiftDir $owner)
        }
    }
    foreach ($label in $labels) {
        if (-not (Invoke-NSGateUsageTick $NightshiftDir $Project $label)) { return $false }
    }
    Set-NSUsageActive $NightshiftDir
    return $true
}

# Read-NSUsageCursor <payload> - the counter from a Cursor stop payload.
#
# Cursor delivers the figures on the hook payload itself; there is no transcript to read. The fields
# are optional and undocumented, so each is read defensively: a payload without them is not zero
# usage, it is no measurement, and the caller says `unavailable`.
function Read-NSUsageCursor {
    param([AllowEmptyString()][string]$Payload)
    if ([string]::IsNullOrEmpty($Payload)) { return $null }
    $input = Get-NSUsageNumber $Payload 'input_tokens'
    $output = Get-NSUsageNumber $Payload 'output_tokens'
    if ($input -lt 0 -and $output -lt 0) { return $null }
    $cacher = Get-NSUsageNumber $Payload 'cache_read_tokens'
    $cachew = Get-NSUsageNumber $Payload 'cache_write_tokens'
    $model = Get-NSUsageString $Payload 'model'
    $parts = New-Object 'System.Collections.Generic.List[string]'
    if ($input -ge 0) { $null = $parts.Add('input=' + $input) }
    if ($cachew -ge 0) { $null = $parts.Add('cache_write=' + $cachew) }
    if ($cacher -ge 0) { $null = $parts.Add('cache_read=' + $cacher) }
    if ($output -ge 0) { $null = $parts.Add('output=' + $output) }
    return (($parts -join ',') + "`t0`t" + $model + "`t0")
}

# Get-NSUsageSubagents <transcript> - the subagent transcripts belonging to one session, if any.
#
# A Task-spawned agent writes its own file beside the session's, and its usage is there rather than
# in the parent. Only this session's own directory is looked at.
function Get-NSUsageSubagents {
    param([Parameter(Mandatory = $true)][string]$Path)
    $dir = [IO.Path]::GetDirectoryName($Path)
    if ([string]::IsNullOrEmpty($dir)) { return @() }
    $base = [IO.Path]::GetFileName($Path)
    if ($base.EndsWith('.jsonl', [StringComparison]::Ordinal)) {
        $base = $base.Substring(0, $base.Length - 6)
    }
    $sub = Join-Path (Join-Path $dir $base) 'subagents'
    if (Test-NSReparsePoint $sub) { return @() }
    if (-not (Test-Path -LiteralPath $sub -PathType Container)) { return @() }
    return @(Get-ChildItem -LiteralPath $sub -File -Filter 'agent-*.jsonl' -ErrorAction SilentlyContinue |
        Sort-Object -Property FullName |
        ForEach-Object { $_.FullName })
}

# Invoke-NSPulseUsage <ns> <host> <session-id> <source> - take one reading, if the owner wants usage
# measured.
#
# The pulse fires on every tool call, so the reading rides on something that was going to happen
# anyway. The arm mark is stood up first, with the transcripts beside it: whatever the setting-up
# conversation already wrote is where reading begins, not byte zero.
function Invoke-NSPulseUsage {
    param([Parameter(Mandatory = $true)][string]$NightshiftDir,
          [Parameter(Mandatory = $true)][string]$HostName,
          [AllowEmptyString()][string]$SessionId,
          [AllowEmptyString()][string]$Source)
    if ([string]::IsNullOrEmpty($Source)) { return $false }
    if (-not (Test-Path -LiteralPath (Get-NSLayoutPath $NightshiftDir 'armed') -PathType Leaf)) { return $false }
    $project = [IO.Path]::GetDirectoryName($NightshiftDir)
    if (-not (Test-NSReceiptsEnabled $project)) { return $false }
    if ((Get-NSReceiptsField $project 'usage') -ceq 'off') { return $false }
    $agents = @()
    if ($HostName -ceq 'claude') { $agents = Get-NSUsageSubagents $Source }
    if ($HostName -ceq 'claude') {
        $null = Write-NSUsageMarkArm $NightshiftDir (@($Source) + $agents)
    }
    else {
        $null = Write-NSUsageMarkArm $NightshiftDir
    }
    switch ($HostName) {
        'claude' {
            foreach ($t in (@($Source) + $agents)) {
                $reading = Read-NSUsageClaude $t (Get-NSUsageOffset $NightshiftDir $t) `
                    (Get-NSUsageCarry $NightshiftDir $t)
                if ([string]::IsNullOrEmpty($reading)) { continue }
                $f = $reading.Split("`t")
                $null = Write-NSUsageRecord $NightshiftDir 'claude' $f[2] 'transcript-incremental' `
                    $t $f[1] $f[0] $f[4]
            }
            return $true
        }
        'codex' {
            $reading = Read-NSUsageCodex $Source
            if ([string]::IsNullOrEmpty($reading)) { return $false }
            $f = $reading.Split("`t")
            return (Write-NSUsageRecord $NightshiftDir 'codex' $f[2] 'rollout' $Source '0' $f[0])
        }
        'cursor' {
            $reading = Read-NSUsageCursor $Source
            if ([string]::IsNullOrEmpty($reading)) { return $false }
            $f = $reading.Split("`t")
            return (Write-NSUsageRecord $NightshiftDir 'cursor' $f[2] 'stop-payload' ('cursor:' + $SessionId) '0' $f[0])
        }
    }
    return $false
}

# Invoke-NSPulseMarks <ns> <project> - mark every item ticked since the last mark, at this moment.
#
# The gate marks on a stop attempt, so two items ticked between stops both get the reading taken at
# the stop. The pulse fires on the tool call that ticked the box, so a mark taken here carries the
# reading at the moment the work finished. It calls the gate's own sync: one code path writes the
# marks and the report lines, whichever side gets there first.
function Invoke-NSPulseMarks {
    param([Parameter(Mandatory = $true)][string]$NightshiftDir, [Parameter(Mandatory = $true)][string]$Project,
          [AllowEmptyString()][string]$Source = '')
    if (-not (Test-Path -LiteralPath $NightshiftDir -PathType Container)) { return $false }
    if (-not (Test-Path -LiteralPath (Get-NSLayoutPath $NightshiftDir 'armed') -PathType Leaf)) { return $false }
    $punch = Get-NSLayoutPath $NightshiftDir 'punch-list'
    if (-not (Test-Path -LiteralPath $punch -PathType Leaf)) { return $false }
    $counts = Get-NSBoxCounts $punch
    if (-not $counts.Readable) { return $false }
    $transcripts = @()
    if (-not [string]::IsNullOrEmpty($Source) -and (Test-Path -LiteralPath $Source -PathType Leaf)) { $transcripts = @($Source) }
    $synced = Invoke-NSGateUsageSync $NightshiftDir $Project $punch $counts.Ticked $transcripts
    # Then follow the item being worked, so a stretch spent on one item is not charged to another.
    Invoke-NSGateUsageSwitch $NightshiftDir $Project (Get-NSActiveItem $Project)
    return $synced
}

# Get-NSActiveItem <workspace> - the item being worked: the open item whose receipt the model wrote
# last, or the first open item while no open item has one. A receipt starts when substantive work on
# its item starts, and the runtime's own writes keep a receipt's time, so only the model's writing
# moves this. Two receipts written in the same instant go to the earlier item.
function Get-NSActiveItem {
    param([Parameter(Mandatory = $true)][string]$Workspace)
    $punch = Get-NSLayoutPath (Join-Path $Workspace '.nightshift') 'punch-list'
    if (-not (Test-Path -LiteralPath $punch -PathType Leaf)) { return '' }
    # The receipts folder is listed once: the pulse runs this on every tool call.
    $files = New-Object 'System.Collections.Generic.Dictionary[string,datetime]' ([StringComparer]::Ordinal)
    $dir = Get-NSReceiptsDir $Workspace
    if (Test-Path -LiteralPath $dir -PathType Container) {
        foreach ($file in @(Get-ChildItem -LiteralPath $dir -File -Force -ErrorAction SilentlyContinue)) {
            if ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
            if ($file.Name.EndsWith('.md', [StringComparison]::Ordinal)) { $files[$file.Name] = $file.LastWriteTimeUtc }
        }
    }
    $names = [string[]]@($files.Keys)
    [Array]::Sort($names, [StringComparer]::Ordinal)
    $first = ''
    $best = ''
    $bestTime = [DateTime]::MinValue
    foreach ($row in (Get-NSItemRows $punch 'open')) {
        if ([string]::IsNullOrEmpty($first)) { $first = $row.Label }
        $name = ''
        if ($row.Id) { $name = Find-NSReceiptName $names $row.Id }
        # A receipt named by label starts with the item's number; only when one might exist is the
        # exact name worked out.
        if (-not $name) {
            $nn = Get-NSReceiptNn $row.Label
            $maybe = [string]::IsNullOrEmpty($nn)
            foreach ($candidate in $names) {
                if ($candidate -ceq ($nn + '.md') -or $candidate.StartsWith($nn + '-', [StringComparison]::Ordinal)) { $maybe = $true; break }
            }
            if ($maybe) {
                $legacy = (Get-NSReceiptBasename $row.Label) + '.md'
                if ($files.ContainsKey($legacy)) { $name = $legacy }
                elseif ($nn -and $files.ContainsKey($nn + '.md')) { $name = $nn + '.md' }
            }
        }
        if (-not $name) { continue }
        $time = $files[$name]
        if ([string]::IsNullOrEmpty($best) -or $time -gt $bestTime) {
            $best = $row.Label
            $bestTime = $time
        }
    }
    if (-not [string]::IsNullOrEmpty($best)) { return $best }
    return $first
}

function Get-NSPulseActiveItem {
    param([Parameter(Mandatory = $true)][string]$Workspace)
    return (Get-NSActiveItem $Workspace)
}

function Get-NSPulseTickedLabels {
    param([Parameter(Mandatory = $true)][string]$Workspace)
    $out = New-Object Collections.Generic.List[string]
    $punch = Get-NSLayoutPath (Join-Path $Workspace '.nightshift') 'punch-list'
    if (-not (Test-Path -LiteralPath $punch -PathType Leaf)) { return [string[]]@() }
    foreach ($line in (Get-NSPunchItemsSection $punch)) {
        if ($line -cnotmatch '^- \[[xX]\]') { continue }
        $label = Get-NSItemLabel $line
        if (-not [string]::IsNullOrEmpty($label)) { $out.Add($label) }
    }
    $arr = $out.ToArray()
    if ($arr.Length -eq 0) { return [string[]]@() }
    return , $arr
}

# Get-NSReceiptsField <workspace> <name> - one receipts setting as this shift uses it, as a string:
# the value the shift policy froze, else the owner's rules file, else the shipped default. The same
# order the POSIX ns_receipts reads in.
function Get-NSReceiptsField {
    param([Parameter(Mandatory = $true)][string]$Workspace, [Parameter(Mandatory = $true)][string]$Name)
    if (-not $script:NSPolicyGroupDefaults.Contains('receipts.' + $Name)) { return '' }
    $value = (Get-NSPolicyGroupSetting $Workspace ('receipts.' + $Name))['value']
    if ($null -eq $value) { return '' }
    if ($value -is [bool]) { return $(if ($value) { 'true' } else { 'false' }) }
    return [string]$value
}

function Test-NSReceiptsEnabled {
    param([Parameter(Mandatory = $true)][string]$Workspace)
    return ((Get-NSReceiptsField $Workspace 'enabled') -cne 'false')
}

function Get-NSPulseReceiptsSections {
    param([Parameter(Mandatory = $true)][string]$Workspace)
    $path = Get-NSReceiptsField $Workspace 'templatePath'
    if (-not [string]::IsNullOrEmpty($path)) {
        return ('follow the owner''s template at ' + $path)
    }
    return "sections: What was delivered $script:NSDot Why $script:NSDot Tried and rejected $script:NSDot Verification $script:NSDot Outputs $script:NSDot Parked decisions and snags."
}

function Get-NSPulseReceiptsStartLine {
    param([string]$Workspace, [string]$Label)
    $dash = [string][char]0x2014
    return ('receipts: item ' + $Label + ' started ' + $dash + ' open ' + (Get-NSLayoutName (Join-Path $Workspace '.nightshift') 'receipts') + '/' +
        (Get-NSReceiptBase $Workspace $Label) + '.md with one paragraph on the approach; ' +
        (Get-NSPulseReceiptsSections $Workspace))
}

function Get-NSPulseReceiptsTickLine {
    param([string]$Workspace, [string]$Label)
    $dash = [string][char]0x2014
    return ('receipts: item ' + $Label + ' is ticked ' + $dash +
        ' write its closing paragraph in ' + (Get-NSLayoutName (Join-Path $Workspace '.nightshift') 'receipts') + '/' +
        (Get-NSReceiptBase $Workspace $Label) + '.md now, before starting the next item.')
}

function Get-NSPulseReceiptsCadenceLine {
    param([string]$Workspace, [string]$Label)
    $dash = [string][char]0x2014
    return ('receipts: progress update due for ' + $Label + ' ' + $dash +
        ' refresh the progress paragraph in ' + (Get-NSLayoutName (Join-Path $Workspace '.nightshift') 'receipts') + '/' +
        (Get-NSReceiptBase $Workspace $Label) + '.md: where it stands, what is left.')
}

function Test-NSReceiptHasModelText {
    param([AllowEmptyString()][string]$Path)
    if ([string]::IsNullOrEmpty($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    if (Test-NSReparsePoint $Path) { return $false }
    $sessions = $false
    foreach ($line in [IO.File]::ReadAllLines($Path)) {
        if ($line.StartsWith('<!-- sessions -->')) { $sessions = $true; continue }
        if ($line.StartsWith('<!-- /sessions -->')) { $sessions = $false; continue }
        if ($sessions) { continue }
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line.StartsWith('# ')) { continue }
        if ($line.StartsWith('**Usage:**')) { continue }
        if ($line.StartsWith('**Duration:**')) { continue }
        if ($line -ceq '**Tokens:** off' -or $line -ceq '**Time:** off') { continue }
        if ($line.StartsWith('  Source:')) { continue }
        if ($line.StartsWith('  Cache reads')) { continue }
        if ($line.StartsWith('  The input figure')) { continue }
        if ($line.StartsWith('  Cached input')) { continue }
        if ($line.StartsWith('  Overlap between')) { continue }
        if ($line.StartsWith('| Tokens |')) { continue }
        if ($line.StartsWith('| Time |')) { continue }
        if ($line.StartsWith('| ---')) { continue }
        if ($line.StartsWith('| input |')) { continue }
        if ($line.StartsWith('| cache ')) { continue }
        if ($line.StartsWith('| output |')) { continue }
        if ($line.StartsWith('| reasoning |')) { continue }
        if ($line.StartsWith('| working |')) { continue }
        if ($line.StartsWith('| paused |')) { continue }
        if ($line.StartsWith('| wall |')) { continue }
        if ($line.StartsWith('| span |')) { continue }
        if ($line.StartsWith('<!-- tokens ')) { continue }
        if ($line.StartsWith('<!-- item: ')) { continue }
        if ($line -cmatch '^Renamed from .* on [0-9]{4}-[0-9]{2}-[0-9]{2}\.$') { continue }
        if ($line -match ' \u00B7 [0-9]+ segments?\.') { continue }
        return $true
    }
    return $false
}

function Get-NSReceiptsMissingNns {
    param([Parameter(Mandatory = $true)][string]$Workspace)
    if (-not (Test-NSReceiptsEnabled $Workspace)) { return [string[]]@() }
    $ns = Join-Path $Workspace '.nightshift'
    $parts = New-Object Collections.Generic.List[string]
    foreach ($row in (Get-NSItemRows (Get-NSLayoutPath $ns 'punch-list') 'ticked')) {
        $path = Join-Path (Get-NSLayoutPath $ns 'receipts') ((Get-NSReceiptBase $Workspace $row.Label $row.Id) + '.md')
        if (Test-NSReceiptHasModelText $path) { continue }
        $nn = Get-NSReceiptNn $row.Label
        if ([string]::IsNullOrEmpty($nn)) { $nn = $row.Label }
        $parts.Add($nn)
    }
    $arr = $parts.ToArray()
    if ($arr.Length -eq 0) { return [string[]]@() }
    return , $arr
}

function Get-NSGateReceiptsMissingNote {
    param([Parameter(Mandatory = $true)][string]$Workspace)
    $parts = Get-NSReceiptsMissingNns $Workspace
    if ($null -eq $parts -or $parts.Count -eq 0) { return '' }
    return ('Receipts missing model text: ' + ($parts -join ', '))
}

function Add-NSGateReceiptsMissingNote {
    param([string]$Workspace, [AllowEmptyString()][string]$Text)
    $note = Get-NSGateReceiptsMissingNote $Workspace
    if ([string]::IsNullOrEmpty($note)) { return $Text }
    if ([string]::IsNullOrEmpty($Text)) { return $note }
    return ($Text + ' ' + $note)
}

# Get-NSUsageReceiptHash <file> - the receipt's short digest (the first 16 hex characters of its
# SHA-256, as the POSIX runtime writes it), or '' when there is no plain file.
function Get-NSUsageReceiptHash {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Path)
    if ([string]::IsNullOrEmpty($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf) -or
        (Test-NSReparsePoint $Path)) { return '' }
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $digest = $sha.ComputeHash([IO.File]::ReadAllBytes($Path))
    }
    finally {
        $sha.Dispose()
    }
    return (-join ($digest | ForEach-Object { $_.ToString('x2') })).Substring(0, 16)
}

# Get-NSUsageWindow <nightshift-dir> <receipt-file> - where the current cadence window started, as
# an object with Epoch and Total (the usage reading at that point), or $null before the first mark.
# The later of the item's own start mark and the last time its receipt changed, so a progress
# update restarts the window and nothing else does. The stamp is the usage/window file the POSIX
# runtime keeps, in the same format.
function Get-NSUsageWindow {
    param(
        [Parameter(Mandatory = $true)][string]$NightshiftDir,
        [AllowEmptyString()][string]$Receipt = ''
    )
    $marks = Get-NSUsageMarksPath $NightshiftDir
    if (-not (Test-Path -LiteralPath $marks -PathType Leaf)) { return $null }
    $last = @([IO.File]::ReadAllLines($marks)) | Select-Object -Last 1
    if ([string]::IsNullOrEmpty($last)) { return $null }
    $fields = $last.Split("`t")
    $epoch = [long]0
    [void][long]::TryParse($fields[0], [ref]$epoch)
    $total = if ($fields.Count -gt 2) { $fields[2] } else { '' }
    $stamp = Join-Path (Get-NSUsageDir $NightshiftDir) 'window'
    $hash = Get-NSUsageReceiptHash $Receipt
    $utf8 = New-Object Text.UTF8Encoding($false)
    if (-not [string]::IsNullOrEmpty($hash) -and -not (Test-NSReparsePoint $stamp)) {
        if (-not (Test-Path -LiteralPath $stamp -PathType Leaf)) {
            # First sight of this file. Recording what it looks like is not the same as the model
            # having just refreshed it, so the window stays where the item started.
            $null = New-Item -ItemType Directory -Force -Path (Get-NSUsageDir $NightshiftDir)
            [IO.File]::WriteAllText($stamp, "$epoch`t$hash`t$total`n", $utf8)
        }
        elseif (([IO.File]::ReadAllText($stamp).TrimEnd("`r", "`n").Split("`t"))[1] -cne $hash) {
            # It changed, so the model refreshed it: the window starts again from here.
            [IO.File]::WriteAllText($stamp, "$(Get-NSUnixTime)`t$hash`t$(Get-NSUsageTotal $NightshiftDir)`n", $utf8)
            foreach ($key in @('receipt-due', 'report-due')) {
                Remove-Item -LiteralPath (Get-NSLayoutPath $NightshiftDir $key) -Force -ErrorAction SilentlyContinue
            }
        }
    }
    if ((Test-Path -LiteralPath $stamp -PathType Leaf) -and -not (Test-NSReparsePoint $stamp)) {
        $row = [IO.File]::ReadAllText($stamp).TrimEnd("`r", "`n").Split("`t")
        $stamped = [long]0
        if ([long]::TryParse($row[0], [ref]$stamped) -and $stamped -gt $epoch) {
            $epoch = $stamped
            $total = if ($row.Count -gt 2) { $row[2] } else { '' }
        }
    }
    return [pscustomobject]@{ Epoch = $epoch; Total = $total }
}

# Test-NSUsageProgressDue <workspace> <label> - true when the owner's cadence says an update is now
# due. completion-only never is; time and tokens measure against the window; either is whichever
# comes first. The cadence is its own setting: a mode that needs a counter the owner turned off, or
# one no host reported, falls back to the time cadence rather than quietly never firing.
function Test-NSUsageProgressDue {
    param([Parameter(Mandatory = $true)][string]$Workspace, [AllowEmptyString()][string]$Label)
    $mode = Get-NSReceiptsField $Workspace 'progressMode'
    if ([string]::IsNullOrEmpty($mode)) { $mode = 'time' }
    if ($mode -ceq 'completion-only') { return $false }
    $ns = Join-Path $Workspace '.nightshift'
    $receipt = if ([string]::IsNullOrEmpty($Label)) { '' } else { Get-NSReceiptPath $Workspace $Label }
    $window = Get-NSUsageWindow $ns $receipt
    if ($null -eq $window) { return $false }
    $minutes = Get-NSReceiptsField $Workspace 'progressMinutes'
    if ($minutes -notmatch '^\d+$') { $minutes = '20' }
    $tokens = Get-NSReceiptsField $Workspace 'progressTokens'
    if ($tokens -notmatch '^\d+$') { $tokens = '100000' }
    $timeDue = ((Get-NSUnixTime) - $window.Epoch) -ge ([long]$minutes * 60)
    if ($mode -ceq 'time') { return $timeDue }
    if ($mode -cne 'tokens' -and $mode -cne 'either') { return $false }
    $spent = ''
    if ((Get-NSReceiptsField $Workspace 'usage') -cne 'off') { $spent = Get-NSUsageTotal $ns }
    if (-not [string]::IsNullOrEmpty($spent)) {
        if ((Get-NSUsageCountable (Get-NSUsageSubtract $spent $window.Total)) -ge [long]$tokens) { return $true }
        return ($mode -ceq 'either' -and $timeDue)
    }
    # A token cadence with no counter to read is a time cadence, not a silence.
    return $timeDue
}

# Get-NSUsageCountable <fields> - input plus output, counted once, as the POSIX ns_usage_countable
# counts it: the cache and reasoning figures either sit inside those two already or are separate
# readings of the same work.
function Get-NSUsageCountable {
    param([AllowEmptyString()][string]$Fields)
    $total = [long]0
    foreach ($dim in @('input', 'output')) {
        $v = [long]0
        if ([long]::TryParse((Get-NSUsageField $Fields $dim), [ref]$v)) { $total += $v }
    }
    return $total
}

function Get-NSPulseReportDue {
    param([Parameter(Mandatory = $true)][string]$NightshiftDir, [Parameter(Mandatory = $true)][string]$Workspace)
    if (-not (Test-Path -LiteralPath (Get-NSLayoutPath $NightshiftDir 'armed') -PathType Leaf)) { return '' }
    if (-not (Test-NSReceiptsEnabled $Workspace)) { return '' }
    $label = Get-NSPulseActiveItem $Workspace
    if ([string]::IsNullOrEmpty($label)) { return '' }
    $want = Get-NSPulseReceiptsCadenceLine $Workspace $label
    $duePath = Get-NSLayoutPath $NightshiftDir 'receipt-due'
    if ((Test-Path -LiteralPath $duePath -PathType Leaf) -and -not (Test-NSReparsePoint $duePath)) {
        $due = [IO.File]::ReadAllText($duePath).TrimEnd("`r", "`n")
        if ($due.Contains('for ' + $label + ' ') -or $due.EndsWith('for ' + $label)) {
            # Refreshing the receipt is what answers the notice. The window notices the change and
            # drops the marker, so a refreshed receipt is not reminded again on the next call.
            $null = Get-NSUsageWindow $NightshiftDir (Get-NSReceiptPath $Workspace $label)
            if (Test-Path -LiteralPath $duePath -PathType Leaf) { return $due }
        }
        else {
            # The marker names an item that is no longer the open one; it answers nothing now.
            Remove-Item -LiteralPath $duePath -Force -ErrorAction SilentlyContinue
        }
    }
    if (-not (Test-NSUsageProgressDue $Workspace $label)) { return '' }
    [IO.File]::WriteAllText($duePath, $want, (New-Object Text.UTF8Encoding($false)))
    return $want
}

function Get-NSPulseReceiptsNotice {
    param([Parameter(Mandatory = $true)][string]$NightshiftDir, [Parameter(Mandatory = $true)][string]$Workspace)
    if (-not (Test-Path -LiteralPath (Get-NSLayoutPath $NightshiftDir 'armed') -PathType Leaf)) { return '' }
    if (-not (Test-NSReceiptsEnabled $Workspace)) { return '' }
    $usage = Get-NSLayoutPath $NightshiftDir 'usage'
    $prevFile = Join-Path $usage 'previous-pulse'
    $labelsFile = Join-Path $usage 'previous-ticked'
    $prevActive = ''
    $prevTicked = 0
    if ((Test-Path -LiteralPath $prevFile -PathType Leaf) -and -not (Test-NSReparsePoint $prevFile)) {
        foreach ($row in [IO.File]::ReadAllLines($prevFile)) {
            if ($row.StartsWith('active' + "`t")) { $prevActive = $row.Substring(7) }
            elseif ($row.StartsWith('ticked' + "`t")) {
                $n = 0
                if ([int]::TryParse($row.Substring(7), [ref]$n)) { $prevTicked = $n }
            }
        }
    }
    $prevLabels = @()
    if ((Test-Path -LiteralPath $labelsFile -PathType Leaf) -and -not (Test-NSReparsePoint $labelsFile)) {
        $prevLabels = @([IO.File]::ReadAllLines($labelsFile))
    }
    $active = Get-NSPulseActiveItem $Workspace
    $labels = Get-NSPulseTickedLabels $Workspace
    if ($null -eq $labels) { $labels = [string[]]@() }
    $ticked = $labels.Count
    $lines = New-Object Collections.Generic.List[string]
    if ($ticked -gt $prevTicked) {
        foreach ($label in $labels) {
            if ($prevLabels -ccontains $label) { continue }
            $lines.Add((Get-NSPulseReceiptsTickLine $Workspace $label))
        }
    }
    if (-not [string]::IsNullOrEmpty($active) -and $active -cne $prevActive) {
        # An item carried from an earlier shift may have been renumbered or retitled since; its
        # receipt says so before the model opens it.
        Update-NSReceiptLabel (Get-NSReceiptPath $Workspace $active) $active
        $lines.Add((Get-NSPulseReceiptsStartLine $Workspace $active))
    }
    $cadence = Get-NSPulseReportDue $NightshiftDir $Workspace
    if (-not [string]::IsNullOrEmpty($cadence)) { $lines.Add($cadence) }
    if (-not (Test-Path -LiteralPath $usage -PathType Container)) {
        $null = New-Item -ItemType Directory -Path $usage -Force -ErrorAction SilentlyContinue
    }
    if ((Test-Path -LiteralPath $usage -PathType Container) -and -not (Test-NSReparsePoint $usage)) {
        [IO.File]::WriteAllText($prevFile, ("active`t$active`nticked`t$ticked`n"),
            (New-Object Text.UTF8Encoding($false)))
        [IO.File]::WriteAllText($labelsFile, (($labels -join "`n") + $(if ($labels.Count -gt 0) { "`n" } else { '' })),
            (New-Object Text.UTF8Encoding($false)))
    }
    if ($lines.Count -eq 0) { return '' }
    return ($lines -join "`n")
}

function Write-NSPulseContext {
    param([string]$HostName, [AllowEmptyString()][string]$Line)
    if ([string]::IsNullOrEmpty($Line)) { return }
    if ($HostName -ceq 'cursor') {
        Write-Output (ConvertTo-Json -Compress ([pscustomobject]@{ additional_context = $Line }))
        return
    }
    $hook = [pscustomobject]@{
        hookSpecificOutput = [pscustomobject]@{
            hookEventName     = 'PostToolUse'
            additionalContext = $Line
        }
    }
    Write-Output (ConvertTo-Json -Compress $hook)
}

# Copy-NSUsageSnapshot - copy the live readings to the ended shift's own folder, the one
# Move-NSUsageRetire would have moved them to, and leave the live readings in place for the shift
# that continues the same items. Returns the copy's path. Mirrors ns_usage_snapshot.
function Copy-NSUsageSnapshot {
    param([Parameter(Mandatory = $true)][string]$NightshiftDir, [AllowEmptyString()][string]$ShiftId)
    $dir = Get-NSUsageDir $NightshiftDir
    if (Test-NSReparsePoint $dir) { return '' }
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { return '' }
    $id = $ShiftId
    if ([string]::IsNullOrEmpty($id) -or $id -match '[\\/]' -or $id.StartsWith('.')) {
        $id = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
    }
    $dest = Get-NSLayoutPath $NightshiftDir 'usage-shift' $id
    if (Test-Path -LiteralPath $dest) { $dest = Get-NSLayoutPath $NightshiftDir 'usage-shift' ($id + '-' + (Get-NSUnixTime)) }
    try { Copy-Item -LiteralPath $dir -Destination $dest -Recurse -Force } catch { return '' }
    return $dest
}

# Move-NSUsageRetire - a finished shift's accounting, set aside so the next shift starts clean.
function Move-NSUsageRetire {
    param([Parameter(Mandatory = $true)][string]$NightshiftDir, [AllowEmptyString()][string]$ShiftId)
    $dir = Get-NSUsageDir $NightshiftDir
    if (Test-NSReparsePoint $dir) { return '' }
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { return '' }
    $id = $ShiftId
    if ([string]::IsNullOrEmpty($id) -or $id -match '[\\/]' -or $id.StartsWith('.')) {
        $id = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
    }
    $dest = Get-NSLayoutPath $NightshiftDir 'usage-shift' $id
    if (Test-Path -LiteralPath $dest) { $dest = Get-NSLayoutPath $NightshiftDir 'usage-shift' ($id + '-' + (Get-NSUnixTime)) }
    try { Move-Item -LiteralPath $dir -Destination $dest -Force } catch { return '' }
    return $dest
}

