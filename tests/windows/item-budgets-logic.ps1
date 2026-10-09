# Item budgets on native Windows: the PowerShell half of tests/item-budgets.bats.
# Run on macOS or Windows: pwsh -File tests/windows/item-budgets-logic.ps1
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$repository = Resolve-Path (Join-Path $PSScriptRoot '../..')
$plugin = Join-Path $repository 'plugins/nightshift'
Import-Module (Join-Path $plugin 'lib/Nightshift.psm1') -Force -DisableNameChecking
$rulesTemplate = Join-Path $plugin 'skills/nightshift/references/nightshift-rules-template.json'
$hostExe = (Get-Process -Id $PID).Path
$failures = New-Object 'System.Collections.Generic.List[string]'
$utf8 = New-Object Text.UTF8Encoding($false)
$item = '2. Build the importer.'
# The Windows hardhat's own checks, loaded as a library: it returns before reading any payload.
$env:NIGHTSHIFT_HARDHAT_LIB = '1'
. (Join-Path $plugin 'hooks/windows/hardhat.ps1') -HostName claude
Remove-Item Env:NIGHTSHIFT_HARDHAT_LIB

function Expect-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        $failures.Add($Message)
        Write-Host "FAIL: $Message"
    }
}

# New-Site <path> <budget-line> - an armed shift working item 2, whose receipt is the newest.
function New-Site {
    param([Parameter(Mandatory = $true)][string]$Path, [string]$Budget = '')
    $ns = Join-Path $Path '.nightshift'
    $null = New-Item -ItemType Directory -Path (Join-Path $ns 'receipts'), (Join-Path $Path 'src') -Force
    Copy-Item -LiteralPath $rulesTemplate -Destination (Join-Path $ns 'rules.json') -Force
    $list = "## Items`n- [x] **1. Done already.** <!-- id: aa11 -->`n- [ ] **2. Build the importer.** <!-- id: bb22 -->`n"
    if ($Budget.Length -gt 0) { $list += "  - Budget: $Budget`n" }
    $list += "  - Verify: the importer test passes.`n- [ ] **3. Later.** <!-- id: cc33 -->`n"
    [IO.File]::WriteAllText((Join-Path $ns 'punch-list.md'), $list, $utf8)
    [IO.File]::WriteAllText((Join-Path $ns '.shift-armed'), '', $utf8)
    & git -C $Path init --quiet
    & git -C $Path -c user.email=dev@example.com -c user.name=tester commit --quiet --allow-empty -m init
    $null = Write-NSUsageMarkArm $ns
    [IO.File]::WriteAllText((Join-Path $ns 'receipts/bb22-build-the-importer.md'), "# $item`n`nWriting the parser.`n", $utf8)
    $null = Invoke-NSPulseMarks $ns $Path ''
    return $ns
}

function Add-Spend {
    param([string]$Ns, [int]$In, [int]$Out)
    $null = Write-NSUsageRecord $Ns 'claude' 'claude-opus-5' 'transcript-incremental' '/t/a' '10' "input=$In,output=$Out"
}

function Get-BudgetNotice {
    param([string]$Ns, [string]$Workspace)
    return (@(([string](Get-NSPulseNotices $Ns $Workspace)) -split "`n" | Where-Object { $_.StartsWith('budget:') }) -join "`n")
}

$root = Join-Path ([IO.Path]::GetTempPath()) ('ns-item-budgets-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $root -Force
try {
    # Soft and hard limits in time, tokens or both; anything else is not a budget.
    Expect-True ((ConvertFrom-NSBudget 'soft 30m / 1M tokens, hard 45m / 2M tokens') -ceq '1800 1000000 2700 2000000') 'both limits parse'
    Expect-True ((ConvertFrom-NSBudget 'hard 2.5M tokens / 90s') -ceq '- - 90 2500000') 'a fraction of a million parses'
    Expect-True ((ConvertFrom-NSBudget '') -ceq '') 'no text is no budget'
    foreach ($bad in @('soft 30x', 'medium 3m', 'soft 3m, soft 4m', 'soft 3m / 4m', 'hard -5m')) {
        Expect-True ($null -eq (ConvertFrom-NSBudget $bad)) "refused: $bad"
    }

    # An item's own budget wins; the shift block's itemBudget covers an item that names none.
    $w = Join-Path $root 'default'
    $ns = New-Site $w 'hard 45m'
    $rules = Get-Content -Raw -LiteralPath (Join-Path $ns 'rules.json') | ConvertFrom-Json
    $rules.shift | Add-Member -NotePropertyName itemBudget -NotePropertyValue 'soft 10m' -Force
    [IO.File]::WriteAllText((Join-Path $ns 'rules.json'), ($rules | ConvertTo-Json -Depth 20), $utf8)
    Expect-True ((Get-NSBudgetText $w $item) -ceq 'hard 45m') 'the item budget wins'
    Expect-True ((Get-NSBudgetText $w '3. Later.') -ceq 'soft 10m') 'the shift default covers the rest'

    # A soft limit tells the agent once.
    $w = Join-Path $root 'soft'
    $ns = New-Site $w 'soft 100 tokens'
    Add-Spend $ns 60 10
    Expect-True ((Get-BudgetNotice $ns $w).Length -eq 0) 'nothing under the soft limit'
    Add-Spend $ns 30 10
    $notice = Get-BudgetNotice $ns $w
    Expect-True ($notice.StartsWith("budget: $item has reached its soft budget (100 tokens; spent ") -and $notice.Contains('Start finishing it now')) "the soft notice: $notice"
    Add-Spend $ns 30 10
    Expect-True ((Get-BudgetNotice $ns $w).Length -eq 0) 'the soft notice comes once'

    # A hard limit allows only wrap-up until the item is closed.
    $w = Join-Path $root 'hard'
    $ns = New-Site $w 'soft 50 tokens, hard 100 tokens'
    Add-Spend $ns 90 20
    $notice = Get-BudgetNotice $ns $w
    Expect-True ($notice.Contains('has reached its hard budget (100 tokens; spent ') -and $notice.Contains('only wrap-up is allowed')) "the hard notice: $notice"
    Expect-True ((Get-NSBudgetHardOpen $ns) -ceq $item) 'the spent hard budget is on record'
    $script:ns = $ns
    $script:cwd = $w
    $check = {
        param([string]$Tool, [string]$Command, [string[]]$Targets)
        return (Test-NSRestrictedAllows $Tool $Targets $Command 'wrapup')
    }
    Expect-True (-not (& $check 'Edit' '' @((Join-Path $w 'src/importer.js')))) 'a source edit is wrap-up denied'
    Expect-True (& $check 'Write' '' @((Join-Path $ns 'receipts/bb22-build-the-importer.md'))) 'the receipt may be written'
    Expect-True (& $check 'Edit' '' @((Join-Path $ns 'punch-list.md'))) 'the punch list may be closed'
    Expect-True (& $check 'Bash' 'git add -A && git commit -m "wip: importer parser"' @()) 'the work in progress may be committed'
    Expect-True (-not (& $check 'Bash' 'npm test' @())) 'other commands are denied'
    Expect-True (& $check 'Read' '' @((Join-Path $w 'src/importer.js'))) 'reading stays free'
    Expect-True (-not (& $check 'mcp__x__y' '' @())) 'an unclassified tool is denied'

    # A stopped item closes as stopped, never ticked, and its budget is forgotten.
    & git -C $w -c user.email=dev@example.com -c user.name=tester commit --quiet --allow-empty -m 'wip: importer parser'
    $punch = Join-Path $ns 'punch-list.md'
    $before = (Get-NSPunchItemsNormalised $punch) -join "`n"
    [IO.File]::WriteAllText($punch, ([IO.File]::ReadAllText($punch).Replace('- [ ] **2.', '- [-] **2.').Replace("  - Verify:", "  - Stopped: hard 100 tokens spent; wip committed.`n  - Verify:")), $utf8)
    Expect-True (((Get-NSPunchItemsNormalised $punch) -join "`n") -ceq $before) 'closing as stopped keeps the items digest'
    $null = Invoke-NSPulseMarks $ns $w ''
    Expect-True (((Get-NSItemRows $punch 'all') | ForEach-Object { $_.State }) -join ' ' -ceq 'ticked stopped open') 'item states'
    $counts = Get-NSBoxCounts $punch
    Expect-True ($counts.Open -eq 1 -and $counts.Ticked -eq 1 -and $counts.Stopped -eq 1) 'box counts'
    $receipt = [IO.File]::ReadAllText((Join-Path $ns 'receipts/bb22-build-the-importer.md'))
    Expect-True ($receipt -cmatch '(?m)\| stopped \|$') 'the session ends stopped'
    Expect-True ($receipt.Contains('**Budget** `soft 50 tokens, hard 100 tokens`')) 'the receipt names the budget'
    Expect-True ($receipt -cmatch '(?m)^- hard limit reached .*; closed as stopped$') 'the receipt records the hard limit'
    Expect-True ((Get-NSBudgetHardOpen $ns) -ceq '') 'the budget record is forgotten'

    $w = Join-Path $root 'symlink-budget'
    $ns = New-Site $w 'hard 1 tokens'
    Add-Spend $ns 2 0
    $victim = Join-Path $w 'src/victim.txt'
    [IO.File]::WriteAllText($victim, 'unchanged', $utf8)
    $budgetFile = Get-NSBudgetStateFile $ns
    $null = New-Item -ItemType SymbolicLink -Path $budgetFile -Target $victim
    Expect-True ((Invoke-NSBudgetCheck $ns $w) -ceq '') 'recording refuses a budget symlink'
    Expect-True ([IO.File]::ReadAllText($victim) -ceq 'unchanged') 'recording leaves the symlink target intact'
    $script:ns = $ns
    $script:cwd = $w
    Expect-True (Test-NSControlPrefilter $budgetFile) 'the budget is a control target'
    Expect-True (Test-NSControlRewriteHit (Resolve-NSWriteTarget $budgetFile)) 'the budget cannot be forged'
    $ignoreLines = Get-NSReceiptIgnoreLines $ns
    Expect-True ($ignoreLines -ccontains '.budget.tsv') 'legacy budget state is ignored by receipts git'
    Expect-True ($ignoreLines -ccontains '.plan-room') 'legacy plan room state is ignored by receipts git'

    # Status, the preflight and the morning receipt name a stopped item.
    $w = Join-Path $root 'readers'
    $ns = Join-Path $w '.nightshift'
    $null = New-Item -ItemType Directory -Path $ns -Force
    Copy-Item -LiteralPath $rulesTemplate -Destination (Join-Path $ns 'rules.json') -Force
    & git -C $w init --quiet
    [IO.File]::WriteAllText((Join-Path $ns 'punch-list.md'),
        "## Items`n- [x] **1. Done.**`n- [-] **2. Build the importer.**`n  - Stopped: hard 45m spent; wip in abc1234.`n- [ ] **3. Later.**`n", $utf8)
    $status = (& $hostExe -NoProfile -NonInteractive -File (Join-Path $plugin 'runtime/windows/status.ps1') -Project $w) -join "`n"
    Expect-True ($status.Contains('Items:       open=1 ticked=1 stopped=1')) "status: $status"
    $preflight = (& $hostExe -NoProfile -NonInteractive -File (Join-Path $plugin 'runtime/windows/start-preflight.ps1') -Project $w) -join "`n"
    Expect-True ($preflight -cmatch '(?m)^ok punch-list open=1 ticked=1 stopped=1$') "preflight: $preflight"
    $morning = (& $hostExe -NoProfile -NonInteractive -File (Join-Path $plugin 'runtime/windows/morning-receipt.ps1') -Project $w) -join "`n"
    Expect-True ($morning.Contains('- Items: 1 ticked, 1 open, 1 stopped at their hard budget')) "morning items: $morning"
    Expect-True ($morning.Contains("## Decisions for you`n`n- 2. Build the importer. stopped at its hard budget without being done")) "morning decisions: $morning"
    $w = Join-Path $root 'renamed-hard-item'
    $ns = New-Site $w 'hard 100 tokens'
    Add-Spend $ns 90 20
    $null = Get-BudgetNotice $ns $w
    $punch = Join-Path $ns 'punch-list.md'
    $text = [IO.File]::ReadAllText($punch).Replace('Build the importer.', 'Renamed importer.')
    [IO.File]::WriteAllText($punch, $text, $utf8)
    Expect-True ((Get-NSBudgetHardOpen $ns) -ceq '2. Renamed importer.') 'renaming keeps the reached hard budget'
    Expect-True ((Get-NSBudgetReached $ns '2. Renamed importer.' 'hard').Length -gt 0) 'reached readings follow the item id'
    [IO.File]::WriteAllText($punch, $text.Replace('<!-- id: bb22 -->', '<!-- id: dd44 -->'), $utf8)
    Expect-True ((Get-NSBudgetHardOpen $ns).Length -gt 0) 'replacing the identity does not release the fence'
    [IO.File]::WriteAllText($punch, $text.Replace('- [ ] **2.', '- [-] **2.'), $utf8)
    Expect-True ((Get-NSBudgetHardOpen $ns).Length -eq 0) 'closing the same identity releases the fence'
    Remove-NSBudgetRecord $ns '2. Renamed importer.'
    Expect-True (([IO.File]::ReadAllText((Get-NSBudgetStateFile $ns))).Length -eq 0) 'closing a renamed item forgets its record'
    foreach ($command in @(('awk ' + [char]39 + 'BEGIN { system("touch src/new") }' + [char]39), 'sed -n ''w src/new'' input', 'command touch src/new', 'sort -o src/new input', 'rg --pre touch src', 'uniq input src/new', 'Get-ChildItem | Where-Object { Remove-Item src/new }')) {
        Expect-True (-not (Test-NSRestrictedCommand $command 'plan')) "plan refuses $command"
        Expect-True (-not (Test-NSRestrictedCommand $command 'wrapup')) "wrapup refuses $command"
    }

}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures.Count -gt 0) {
    Write-Host "item-budgets-logic failed ($($failures.Count)):"
    foreach ($failure in $failures) { Write-Host " - $failure" }
    exit 1
}
Write-Host 'item-budgets-logic passed'
exit 0
