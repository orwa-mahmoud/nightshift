# Portable PowerShell coverage for receipt-duty injection.
# Run: pwsh -File tests/windows/pulse-logic.ps1
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if (Test-Path Variable:PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $false
}

$repository = Resolve-Path (Join-Path $PSScriptRoot '../..')
Import-Module (Join-Path $repository 'plugins/nightshift/lib/Nightshift.psm1') -Force -DisableNameChecking
$failures = New-Object 'System.Collections.Generic.List[string]'
$utf8 = New-Object Text.UTF8Encoding($false)
$dash = [string][char]0x2014

function Expect-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        $failures.Add($Message)
        Write-Host "FAIL: $Message"
    }
}

$root = Join-Path ([IO.Path]::GetTempPath()) ("ns-pulse-logic-" + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $root -Force
try {
    $w = Join-Path $root 'start'
    $ns = Join-Path $w '.nightshift'
    $null = New-Item -ItemType Directory -Path $ns -Force
    [IO.File]::WriteAllText((Join-Path $ns 'punch-list.md'), "## Items`n- [ ] **36. First of the replay.**`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $ns '.shift-armed'), '', $utf8)
    $first = Get-NSPulseReceiptsNotice $ns $w
    Expect-True ($first.Contains("receipts: item 36. First of the replay. started $dash open .nightshift/receipts/36-first-of-the-replay.md")) `
        'item-start injection fires once'
    $again = Get-NSPulseReceiptsNotice $ns $w
    Expect-True (-not $again.Contains('started ')) 'a second pulse on the same item does not restart it'

    # In a Cursor session the Claude copy's pulse records nothing, and the Cursor copy's records the turn.
    $pulseScript = Join-Path $repository 'plugins/nightshift/hooks/windows/pulse.ps1'
    $hostExecutable = (Get-Process -Id $PID).Path
    $oneCopy = Join-Path $root 'one-copy'
    $oneNs = Join-Path $oneCopy '.nightshift'
    $null = New-Item -ItemType Directory -Path $oneNs -Force
    [IO.File]::WriteAllText((Join-Path $oneNs 'punch-list.md'), "## Items`n- [ ] **1. first.**`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $oneNs '.shift-armed'), '', $utf8)
    [IO.File]::WriteAllText((Join-Path $oneNs '.shift-session'), "conv-1`n`n`n`ncursor`n", $utf8)
    $cursorTranscript = Join-Path $root 'home/.cursor/projects/w/agent-transcripts/conv-1.jsonl'
    $null = New-Item -ItemType Directory -Path (Split-Path -Parent $cursorTranscript) -Force
    Copy-Item -LiteralPath (Join-Path $repository 'tests/fixtures/usage/claude-multiline.jsonl') -Destination $cursorTranscript
    $claudePayload = (@{ session_id = 'conv-1'; transcript_path = $cursorTranscript; cwd = $oneCopy; tool_name = 'Bash' } | ConvertTo-Json -Compress)
    $env:CLAUDE_PROJECT_DIR = $oneCopy
    $null = $claudePayload | & $hostExecutable -NoProfile -NonInteractive -File $pulseScript -HostName claude
    Remove-Item Env:CLAUDE_PROJECT_DIR
    $oneUsage = Get-NSUsageDir $oneNs
    Expect-True (-not (Test-Path -LiteralPath (Join-Path $oneUsage 'marks.tsv'))) 'the Claude copy writes no mark in a Cursor session'
    Expect-True (-not (Test-Path -LiteralPath (Join-Path $oneUsage 'segments.tsv'))) 'the Claude copy writes no reading in a Cursor session'
    $cursorPayload = (@{ conversation_id = 'conv-1'; generation_id = 'g1'; cwd = $oneCopy; input_tokens = 700; output_tokens = 30 } | ConvertTo-Json -Compress)
    $env:CURSOR_PROJECT_DIR = $oneCopy
    $null = $cursorPayload | & $hostExecutable -NoProfile -NonInteractive -File $pulseScript -HostName cursor
    Remove-Item Env:CURSOR_PROJECT_DIR
    Expect-True ((Get-NSUsageTotal $oneNs) -ceq 'input=700,output=30') "the Cursor copy records its turn ($(Get-NSUsageTotal $oneNs))"

    # A recorded worker that no revival ran leaves the origin tab the shift's pulse; one that ran takes it.
    $workerWs = Join-Path $root 'worker'
    $workerNs = Join-Path $workerWs '.nightshift'
    $null = New-Item -ItemType Directory -Path $workerNs -Force
    [IO.File]::WriteAllText((Join-Path $workerNs 'punch-list.md'), "## Items`n- [ ] **1. first.**`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $workerNs '.shift-armed'), '', $utf8)
    [IO.File]::WriteAllText((Join-Path $workerNs '.shift-session'), "origin-ide`n`n`n`ncursor`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $workerNs '.shift-worker'), "never-ran-worker`n", $utf8)
    $workerPulse = Get-NSLayoutPath $workerNs 'pulse'
    $originPayload = (@{ conversation_id = 'origin-ide'; cwd = $workerWs; tool_name = 'Read' } | ConvertTo-Json -Compress)
    $env:CURSOR_PROJECT_DIR = $workerWs
    $null = $originPayload | & $hostExecutable -NoProfile -NonInteractive -File $pulseScript -HostName cursor
    Expect-True ((Test-Path -LiteralPath $workerPulse) -and ([IO.File]::ReadAllText($workerPulse) -match ' origin-ide')) `
        'the origin tab keeps the pulse while the recorded worker never ran'
    Remove-Item -LiteralPath $workerPulse -Force
    [IO.File]::WriteAllText((Join-Path $workerNs '.shift-lease'), "origin-ide`ncursor`n2`ncursor.2.1.1.1`n4242`n`n", $utf8)
    $null = $originPayload | & $hostExecutable -NoProfile -NonInteractive -File $pulseScript -HostName cursor
    Remove-Item Env:CURSOR_PROJECT_DIR
    Expect-True (-not (Test-Path -LiteralPath $workerPulse)) 'the origin tab stops pulsing once a revival ran the worker'

    $tickWs = Join-Path $root 'tick'
    $tickNs = Join-Path $tickWs '.nightshift'
    $null = New-Item -ItemType Directory -Path $tickNs -Force
    [IO.File]::WriteAllText((Join-Path $tickNs 'punch-list.md'), "## Items`n- [ ] **36. First of the replay.**`n- [ ] **37. Second of the replay.**`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $tickNs '.shift-armed'), '', $utf8)
    $null = Get-NSPulseReceiptsNotice $tickNs $tickWs
    [IO.File]::WriteAllText((Join-Path $tickNs 'punch-list.md'), "## Items`n- [x] **36. First of the replay.**`n- [ ] **37. Second of the replay.**`n", $utf8)
    $ticked = Get-NSPulseReceiptsNotice $tickNs $tickWs
    Expect-True ($ticked.Contains("receipts: item 36. First of the replay. is ticked $dash write its closing paragraph in .nightshift/receipts/36-first-of-the-replay.md now, before starting the next item.")) `
        'tick injection names the newly ticked item and file'

    $off = Join-Path $root 'off'
    $offNs = Join-Path $off '.nightshift'
    $null = New-Item -ItemType Directory -Path $offNs -Force
    [IO.File]::WriteAllText((Join-Path $offNs 'punch-list.md'), "## Items`n- [ ] **36. First of the replay.**`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $offNs '.shift-armed'), '', $utf8)
    [IO.File]::WriteAllText((Join-Path $offNs 'rules.json'), '{"receipts":{"enabled":false}}', $utf8)
    Expect-True ([string]::IsNullOrEmpty((Get-NSPulseReceiptsNotice $offNs $off))) `
        'no injection when receipts.enabled is false'

    $miss = Join-Path $root 'missing'
    $missNs = Join-Path $miss '.nightshift'
    $null = New-Item -ItemType Directory -Path (Join-Path $missNs 'receipts') -Force
    Copy-Item -LiteralPath (Join-Path $repository 'plugins/nightshift/skills/nightshift/references/nightshift-rules-template.json') `
        -Destination (Join-Path $missNs 'rules.json')
    [IO.File]::WriteAllText((Join-Path $missNs 'punch-list.md'), "## Items`n- [x] **36. First of the replay.**`n- [x] **37. Second of the replay.**`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $missNs 'receipts/36-first-of-the-replay.md'), "# 36.`n`n**Usage:** input 1`n**Duration:** 1m`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $missNs 'receipts/37-second-of-the-replay.md'), "# 37.`n`nWrote the closing paragraph.`n", $utf8)
    Expect-True ((Get-NSGateReceiptsMissingNote $miss) -ceq 'Receipts missing model text: 36') `
        'clock-out lists receipts missing model text'

    $stale = Join-Path $root 'stale'
    $staleNs = Join-Path $stale '.nightshift'
    $null = New-Item -ItemType Directory -Path (Join-Path $staleNs 'usage') -Force
    [IO.File]::WriteAllText((Join-Path $staleNs 'punch-list.md'), "## Items`n- [x] **37. Second of the replay.**`n- [ ] **38. Third of the replay.**`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $staleNs '.shift-armed'), '', $utf8)
    $old = (Get-NSUnixTime) - (25 * 60)
    [IO.File]::WriteAllText((Join-Path $staleNs 'usage/marks.tsv'), "$old`tarm`t`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $staleNs '.receipt-due'),
        "receipts: progress update due for 37. Second of the replay. $dash refresh the progress paragraph in .nightshift/receipts/37-second-of-the-replay.md: where it stands, what is left.",
        $utf8)
    $cadence = Get-NSPulseReportDue $staleNs $stale
    Expect-True ($cadence.Contains('progress update due for 38. Third of the replay.')) `
        'a stale marker naming 37 with 38 active produces a message naming 38'

    $quiet = Join-Path $root 'stale-quiet'
    $quietNs = Join-Path $quiet '.nightshift'
    $null = New-Item -ItemType Directory -Path (Join-Path $quietNs 'usage') -Force
    [IO.File]::WriteAllText((Join-Path $quietNs 'punch-list.md'), "## Items`n- [x] **37. Second of the replay.**`n- [ ] **38. Third of the replay.**`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $quietNs '.shift-armed'), '', $utf8)
    [IO.File]::WriteAllText((Join-Path $quietNs 'usage/marks.tsv'), "$((Get-NSUnixTime) - 60)`ttick`t`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $quietNs '.receipt-due'),
        "receipts: progress update due for 37. Second of the replay. $dash refresh the progress paragraph in .nightshift/receipts/37-second-of-the-replay.md: where it stands, what is left.",
        $utf8)
    Expect-True ([string]::IsNullOrEmpty((Get-NSPulseReportDue $quietNs $quiet))) `
        'a stale marker for another item is not rewritten when nothing is due'
    Expect-True (-not (Test-Path -LiteralPath (Join-Path $quietNs '.receipt-due'))) `
        'a stale marker for another item is dropped'

    $answer = Join-Path $root 'answered'
    $answerNs = Join-Path $answer '.nightshift'
    $null = New-Item -ItemType Directory -Path (Join-Path $answerNs 'usage') -Force
    $null = New-Item -ItemType Directory -Path (Join-Path $answerNs 'receipts') -Force
    [IO.File]::WriteAllText((Join-Path $answerNs 'punch-list.md'), "## Items`n- [ ] **P01 - open.**`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $answerNs '.shift-armed'), '', $utf8)
    $receipt = Join-Path $answerNs 'receipts/P01.md'
    [IO.File]::WriteAllText($receipt, "# P01`n`nWhere it has got to.`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $answerNs 'usage/marks.tsv'), "$((Get-NSUnixTime) - (25 * 60))`tarm`t`n", $utf8)
    $standing = Get-NSPulseReportDue $answerNs $answer
    Expect-True ($standing.Contains('progress update due for P01')) 'an overdue item gets the progress notice'
    Expect-True ((Get-NSPulseReportDue $answerNs $answer) -ceq $standing) 'the notice stands until the receipt changes'
    [IO.File]::WriteAllText($receipt, "# P01`n`nWhere it has got to, updated.`n", $utf8)
    Expect-True ([string]::IsNullOrEmpty((Get-NSPulseReportDue $answerNs $answer))) `
        'refreshing the receipt answers the standing notice'
    Expect-True (-not (Test-Path -LiteralPath (Join-Path $answerNs '.receipt-due'))) `
        'the answered notice leaves no marker'
    Expect-True (-not (Test-NSUsageProgressDue $answer 'P01')) 'the refresh restarts the cadence window'
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures.Count -gt 0) {
    Write-Host "pulse-logic failed ($($failures.Count)):"
    foreach ($f in $failures) { Write-Host "  $f" }
    exit 1
}
Write-Host 'pulse-logic passed'
exit 0
