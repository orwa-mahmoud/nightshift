# Permanent item ids on native Windows: the PowerShell half of tests/item-ids.bats.
# Run on macOS or Windows: pwsh -File tests/windows/item-ids-logic.ps1
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$repository = Resolve-Path (Join-Path $PSScriptRoot '../..')
Import-Module (Join-Path $repository 'plugins/nightshift/lib/Nightshift.psm1') -Force -DisableNameChecking
$rulesTemplate = Join-Path $repository 'plugins/nightshift/skills/nightshift/references/nightshift-rules-template.json'
$failures = New-Object 'System.Collections.Generic.List[string]'
$utf8 = New-Object Text.UTF8Encoding($false)

function Expect-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        $failures.Add($Message)
        Write-Host "FAIL: $Message"
    }
}

function New-Workspace {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Punch)
    $ns = Join-Path $Path '.nightshift'
    $null = New-Item -ItemType Directory -Path (Join-Path $ns 'receipts') -Force
    Copy-Item -LiteralPath $rulesTemplate -Destination (Join-Path $ns 'rules.json') -Force
    [IO.File]::WriteAllText((Join-Path $ns 'punch-list.md'), $Punch, $utf8)
    return $ns
}

# Save-Policy <workspace> [extra] - the shift policy as Start records it, before the site is armed.
function Save-Policy {
    param([Parameter(Mandatory = $true)][string]$Workspace, [string]$Extra = '')
    $json = '{"schemaVersion":1,"shiftId":"1111222233334444","createdAt":"2026-09-24T00:00:00Z",' +
        '"source":"start-defaults","deadlineEpoch":null,"verificationLevel":"none","toolingPolicy":"existing-tools"' +
        $Extra + '}'
    return (Set-NSShiftPolicy -Workspace $Workspace -Json $json)
}

function Get-Ids {
    param([Parameter(Mandatory = $true)][string]$Workspace)
    return @(Get-NSItemRows (Join-Path $Workspace '.nightshift/punch-list.md') | ForEach-Object { $_.Id })
}

$root = Join-Path ([IO.Path]::GetTempPath()) ('ns-item-ids-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $root -Force
try {
    # Recording the policy gives every item an id, keeps one it already has, and digests the result.
    $w = Join-Path $root 'assign'
    $ns = New-Workspace $w "# c`n`n## Items`n- [ ] **1. first.**`n  - a sub-bullet`n- [x] **2. done.**`n- [ ] **3. kept.** <!-- id: zz99 -->`n"
    Expect-True ((Save-Policy $w) -eq 0) 'the policy is recorded'
    $ids = Get-Ids $w
    Expect-True ($ids.Count -eq 3) "every item has an id (got $($ids -join ','))"
    Expect-True ($ids[0] -cmatch '^[a-z][a-z0-9]{3}$' -and $ids[1] -cmatch '^[a-z][a-z0-9]{3}$') 'a new id is a letter and three letters or digits'
    Expect-True ($ids[2] -ceq 'zz99') 'an existing id is kept'
    Expect-True (@($ids | Select-Object -Unique).Count -eq 3) 'the ids are distinct'
    $text = [IO.File]::ReadAllText((Join-Path $ns 'punch-list.md'))
    Expect-True ($text.Contains("`n  - a sub-bullet`n")) 'sub-bullets are untouched'
    $doc = [IO.File]::ReadAllText((Join-Path $ns 'shift-policy.json')) | ConvertFrom-Json
    Expect-True ($doc.itemsDigest -ceq (Get-NSPunchItemsDigest (Join-Path $ns 'punch-list.md'))) 'the digest is of the list with its ids'

    # Recording again keeps every id.
    Remove-Item -LiteralPath (Join-Path $ns 'shift-policy.json') -Force
    $null = Save-Policy $w
    Expect-True (((Get-Ids $w) -join ',') -ceq ($ids -join ',')) 'recording again keeps every id'

    # A CRLF list keeps its line endings.
    $crlf = Join-Path $root 'crlf'
    $crlfNs = New-Workspace $crlf "## Items`r`n- [ ] **1. first.**`r`n- [ ] **2. second.**`r`n"
    $null = Save-Policy $crlf
    $crlfText = [IO.File]::ReadAllText((Join-Path $crlfNs 'punch-list.md'))
    Expect-True ($crlfText -cmatch '^## Items\r\n- \[ \] \*\*1\. first\.\*\* <!-- id: [a-z][a-z0-9]{3} -->\r\n') "a CRLF list keeps CRLF: $crlfText"

    # A policy that states its items digest leaves the list alone.
    $stated = Join-Path $root 'stated'
    $statedNs = New-Workspace $stated "## Items`n- [ ] **1. first.**`n"
    $null = Save-Policy $stated ',"itemsDigest":"0000000000000000000000000000000000000000000000000000000000000000"'
    Expect-True ([IO.File]::ReadAllText((Join-Path $statedNs 'punch-list.md')) -ceq "## Items`n- [ ] **1. first.**`n") 'a stated digest leaves the list alone'

    # An id already used in the history is never given again.
    $hist = Join-Path $root 'history'
    $histNs = New-Workspace $hist "## Items`n"
    $null = New-Item -ItemType Directory -Path (Join-Path $histNs 'archive/2026-09-01') -Force
    [IO.File]::WriteAllText((Join-Path $histNs 'archive/2026-09-01/punch-list.md'), "## Items`n- [x] **1. old.** <!-- id: aaaa -->`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $histNs 'receipts/bbbb-carried.md'), '', $utf8)
    foreach ($used in @('aaaa', 'bbbb', 'cccc')) {
        Expect-True (Test-NSItemIdUsed $histNs $used @('cccc')) "$used reads as used"
    }
    Expect-True (-not (Test-NSItemIdUsed $histNs 'dddd' @('cccc'))) 'an unused id reads as free'
    Expect-True ((New-NSItemId $histNs @('cccc')) -cmatch '^[a-z][a-z0-9]{3}$') 'a fresh id is well formed'

    # Label readers never see the id comment.
    $labels = Join-Path $root 'labels'
    $labelsNs = New-Workspace $labels "## Items`n- [x] **1. done.** <!-- id: aa11 -->`n- [x] plain done <!-- id: bb22 -->`n- [ ] **3. open $([char]0x2014) later** <!-- id: cc33 -->`n"
    $labelsPunch = Join-Path $labelsNs 'punch-list.md'
    Expect-True (((Get-NSGateTickedLabels $labelsPunch) -join '|') -ceq '1. done.|plain done') 'ticked labels carry no id'
    Expect-True ((Get-NSPulseActiveItem $labels) -ceq '3. open') 'the active item carries no id'
    Expect-True ((Get-NSStatusOpenTitle $labelsPunch) -ceq ('3. open ' + [char]0x2014 + ' later')) 'the status title carries no id'
    Expect-True (((Get-NSGateUnchargedLabels $labelsNs $labelsPunch) -join '|') -ceq '1. done.|plain done') 'uncharged labels carry no id'

    # An item is found by its number, its id, or its label.
    $look = Join-Path $root 'lookup'
    $lookNs = New-Workspace $look "## Items`n- [x] **4. done.** <!-- id: aa11 -->`n- [ ] **5. open.** <!-- id: bb22 -->`n  - its bullet`n"
    foreach ($key in @('5', 'bb22', '5. open.')) {
        $found = @(Get-NSPunchItem -PunchList (Join-Path $lookNs 'punch-list.md') -Id $key)
        Expect-True (($found -join "`n") -ceq "- [ ] **5. open.** <!-- id: bb22 -->`n  - its bullet") "item $key resolves: $($found -join ' / ')"
    }
    Expect-True (@(Get-NSPunchItem -PunchList (Join-Path $lookNs 'punch-list.md') -Id '6').Count -eq 0) 'an unknown number finds nothing'

    # A new receipt is named for the item's id; an item without one keeps its label's name.
    $named = Join-Path $root 'named'
    $null = New-Workspace $named "## Items`n- [ ] **5. Charge the right item.** <!-- id: k7q2 -->`n- [ ] **6. No id yet.**`n"
    Expect-True ((Split-Path -Leaf (Get-NSReceiptPath $named '5. Charge the right item.')) -ceq 'k7q2-charge-the-right-item.md') 'an id names the receipt'
    Expect-True ((Split-Path -Leaf (Get-NSReceiptPath $named '6. No id yet.')) -ceq '6-no-id-yet.md') 'no id keeps the label name'
    Expect-True ((Get-NSPulseReceiptsStartLine $named '5. Charge the right item.').Contains('.nightshift/receipts/k7q2-charge-the-right-item.md')) 'the pulse names the id receipt'

    # Renumbering and retitling between shifts keeps the receipt and its totals.
    $renum = Join-Path $root 'renumber'
    $renumNs = New-Workspace $renum "## Items`n- [ ] **2. Old title.** <!-- id: k7q2 -->`n"
    $rec = Join-Path $renumNs 'receipts/k7q2-old-title.md'
    [IO.File]::WriteAllText($rec, "# 2. Old title.`n`n| Tokens | Amount |`n| --- | ---: |`n| input | 10 |`n`n<!-- tokens 10 0 0 5 0 -->`n`nWhere it stands.`n", $utf8)
    Update-NSReceiptLabel $rec '2. Old title.'
    [IO.File]::WriteAllText((Join-Path $renumNs 'punch-list.md'), "## Items`n- [ ] **1. Warm-up.**`n- [ ] **5. New title.** <!-- id: k7q2 -->`n", $utf8)
    Expect-True ((Get-NSReceiptPath $renum '5. New title.') -ceq $rec) 'a renumbered item keeps its receipt'
    Update-NSReceiptLabel $rec '5. New title.'
    $recLines = @([IO.File]::ReadAllLines($rec))
    Expect-True ($recLines[0] -ceq '# 5. New title.') "the heading follows the new label: $($recLines[0])"
    Expect-True (@($recLines | Where-Object { $_ -cmatch '^Renamed from 2\. Old title\. on [0-9]{4}-[0-9]{2}-[0-9]{2}\.$' }).Count -eq 1) 'the rename is recorded once'
    Expect-True ($recLines -ccontains 'Where it stands.') 'the model text is kept'
    Expect-True (@($recLines | Where-Object { $_ -cmatch '^<!-- item: ' }).Count -eq 1) 'one label note'
    Expect-True ($recLines -ccontains '<!-- item: 5. New title. -->') 'the label note follows'
    Write-NSReceiptsIndex $renum
    $indexRow = @([IO.File]::ReadAllLines((Join-Path $renumNs 'receipts/README.md')) | Where-Object { $_.StartsWith('| 5. New title. | open |') })
    Expect-True ($indexRow.Count -eq 1 -and $indexRow[0].Contains('input 10')) "the index keeps the totals: $($indexRow -join ' ')"
    Update-NSReceiptLabel $rec '5. New title.'
    Expect-True (@([IO.File]::ReadAllLines($rec) | Where-Object { $_.StartsWith('Renamed from ') }).Count -eq 1) 'tracking the same label adds nothing'
    Expect-True (-not (Test-NSReceiptHasModelText (Join-Path $renumNs 'receipts/none.md'))) 'a missing receipt has no model text'
    [IO.File]::WriteAllText((Join-Path $renumNs 'receipts/only-runtime.md'), "# 5. New title.`n`nRenamed from 2. Old title. on 2026-09-24.`n`n<!-- item: 5. New title. -->`n", $utf8)
    Expect-True (-not (Test-NSReceiptHasModelText (Join-Path $renumNs 'receipts/only-runtime.md'))) 'the runtime lines are not model text'

    # An earlier shift's receipt without an id is still found by its label.
    $legacy = Join-Path $root 'legacy'
    $legacyNs = New-Workspace $legacy "## Items`n- [ ] **3. Carry over.** <!-- id: abcd -->`n"
    [IO.File]::WriteAllText((Join-Path $legacyNs 'receipts/3-carry-over.md'), "# 3. Carry over.`n`nStarted last night.`n", $utf8)
    Expect-True ((Split-Path -Leaf (Get-NSReceiptPath $legacy '3. Carry over.')) -ceq '3-carry-over.md') 'a legacy receipt is found by its label'

    # The gate charges a tick to the id-named receipt.
    $gate = Join-Path $root 'gate'
    $gateNs = New-Workspace $gate "## Items`n- [x] **P01 - first.** <!-- id: aa11 -->`n- [ ] **P02 - open.** <!-- id: bb22 -->`n"
    [IO.File]::WriteAllText((Join-Path $gateNs '.shift-armed'), '', $utf8)
    $transcript = Join-Path $gate 't.jsonl'
    Copy-Item -LiteralPath (Join-Path $repository 'tests/fixtures/usage/claude-multiline.jsonl') -Destination $transcript
    $null = Write-NSUsageMarkArm $gateNs
    $r = (Read-NSUsageClaude $transcript 0 '').Split("`t")
    $null = Write-NSUsageRecord $gateNs 'claude' $r[2] 'transcript-incremental' $transcript $r[1] $r[0] $r[4]
    Expect-True (Invoke-NSGateUsageSync $gateNs $gate (Join-Path $gateNs 'punch-list.md') 1) 'the sync closes the ticked item'
    $gateRec = Join-Path $gateNs 'receipts/aa11-p01.md'
    Expect-True (Test-Path -LiteralPath $gateRec -PathType Leaf) 'the tick lands in the id-named receipt'
    if (Test-Path -LiteralPath $gateRec -PathType Leaf) {
        Expect-True (@([IO.File]::ReadAllLines($gateRec)) -ccontains '<!-- item: P01 -->') 'the receipt notes its label'
    }
    Expect-True ([IO.File]::ReadAllText((Join-Path $gateNs 'receipts/README.md')).Contains('[./aa11-p01.md](./aa11-p01.md)')) 'the index links the id-named receipt'

    # The archive index lists id-named receipts in the order of their headings.
    $arch = Join-Path $root 'archive'
    $null = New-Item -ItemType Directory -Path $arch -Force
    [IO.File]::WriteAllText((Join-Path $arch 'aaaa-ten.md'), "# 10. Ten.`n`ntext`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $arch 'zzzz-two.md'), "# 2. Two.`n`ntext`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $arch 'mmmm-one.md'), "# 1. One.`n`ntext`n", $utf8)
    Write-NSArchiveReceiptsIndex $arch '2026-09-24'
    $order = @([IO.File]::ReadAllLines((Join-Path $arch 'README.md')) |
        Where-Object { $_ -cmatch '^\| [0-9]+\. ' } | ForEach-Object { ($_ -creplace '^\| ([0-9]+)\..*$', '$1') })
    Expect-True (($order -join ' ') -ceq '1 2 10') "archived receipts list by heading order (got $($order -join ' '))"
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures.Count -gt 0) {
    Write-Host "item-ids-logic failed ($($failures.Count)):"
    foreach ($failure in $failures) { Write-Host " - $failure" }
    exit 1
}
Write-Host 'item-ids-logic passed'
exit 0
