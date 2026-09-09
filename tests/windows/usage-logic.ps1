# Portable PowerShell coverage for Windows usage accounting.
# Run on macOS or Windows: pwsh -File tests/windows/usage-logic.ps1
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$repository = Resolve-Path (Join-Path $PSScriptRoot '../..')
Import-Module (Join-Path $repository 'plugins/nightshift/lib/Nightshift.psm1') -Force -DisableNameChecking
$failures = New-Object 'System.Collections.Generic.List[string]'

function Expect-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        $failures.Add($Message)
        Write-Host "FAIL: $Message"
    }
}

function New-Workspace {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Punch)
    $null = New-Item -ItemType Directory -Path (Join-Path $Path '.nightshift') -Force
    [IO.File]::WriteAllText((Join-Path $Path '.nightshift/punch-list.md'), $Punch,
        (New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText((Join-Path $Path '.nightshift/.shift-armed'), '')
    return (Join-Path $Path '.nightshift')
}

$fixtures = Join-Path $repository 'tests/fixtures/usage'
$root = Join-Path ([IO.Path]::GetTempPath()) ("ns-usage-logic-" + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $root -Force
try {
    $punchText = "# Punch list`n`n## Items`n`n- [x] **A1 - first.**`n- [x] **A2 - second.**`n- [ ] **A3 - open.**`n"

    # A reading is folded into a segment, and the total is what the segment holds.
    $w = Join-Path $root 'record'
    $ns = New-Workspace $w $punchText
    $transcript = Join-Path $w 't.jsonl'
    Copy-Item -LiteralPath (Join-Path $fixtures 'claude-multiline.jsonl') -Destination $transcript
    $reading = Read-NSUsageClaude $transcript 0 ''
    Expect-True (-not [string]::IsNullOrEmpty($reading)) 'the reader returns a reading'
    $f = $reading.Split("`t")
    Expect-True (Write-NSUsageRecord $ns 'claude' $f[2] 'transcript-incremental' $transcript $f[1] $f[0] $f[4]) `
        'a reading is recorded'
    Expect-True ((Get-NSUsageSegmentCount $ns) -eq 1) 'one transcript is one segment'
    Expect-True ((Get-NSUsageTotal $ns) -ceq $f[0]) 'the total is what the one segment holds'
    Expect-True ((Get-NSUsageCarry $ns $transcript) -ceq $f[4]) 'the last response identity is carried'
    Expect-True ((Get-NSUsageOffset $ns $transcript) -eq [long]$f[1]) 'the offset is where the read stopped'

    # The arm mark stamps a baseline, so pre-shift content is never billed to item one.
    $w = Join-Path $root 'baseline'
    $ns = New-Workspace $w $punchText
    $pre = Join-Path $w 't.jsonl'
    Copy-Item -LiteralPath (Join-Path $fixtures 'claude-preshift.jsonl') -Destination $pre
    $size = Get-NSFileSize $pre
    Expect-True (Write-NSUsageMarkArm $ns @($pre)) 'the arm mark is written'
    Expect-True ((Get-NSUsageOffset $ns $pre) -eq $size) 'the baseline starts where the transcript already stood'
    Expect-True ((Get-NSUsageMarkCount $ns) -eq 1) 'arming leaves one mark'
    Expect-True (Write-NSUsageMarkArm $ns @($pre)) 'a second arm is a no-op'
    Expect-True ((Get-NSUsageMarkCount $ns) -eq 1) 'a second arm adds no mark'

    # Marks close items in order, and each item's report section carries its own two lines.
    $w = Join-Path $root 'sync'
    $ns = New-Workspace $w $punchText
    $punch = Join-Path $ns 'punch-list.md'
    $t = Join-Path $w 't.jsonl'
    Copy-Item -LiteralPath (Join-Path $fixtures 'claude-multiline.jsonl') -Destination $t
    $null = Write-NSUsageMarkArm $ns
    $r = (Read-NSUsageClaude $t 0 '').Split("`t")
    $null = Write-NSUsageRecord $ns 'claude' $r[2] 'transcript-incremental' $t $r[1] $r[0] $r[4]
    Expect-True (Invoke-NSGateUsageSync $ns $w $punch 2) 'the sync closes both ticked items'
    $marks = @([IO.File]::ReadAllLines((Get-NSUsageMarksPath $ns)))
    Expect-True ($marks.Count -eq 3) "arm plus one mark per ticked item (got $($marks.Count))"
    Expect-True ($marks[1].Split("`t")[1] -ceq 'A1') 'the first mark carries the first item label'
    Expect-True ($marks[2].Split("`t")[1] -ceq 'A2') 'the second mark carries the second item label'
    $a1 = [IO.File]::ReadAllText((Get-NSReceiptPath $w 'A1'))
    $a2 = [IO.File]::ReadAllText((Get-NSReceiptPath $w 'A2'))
    Expect-True ($a1.Contains('# A1')) 'the first item has a receipt'
    Expect-True ($a2.Contains('# A2')) 'the second item has a receipt'
    Expect-True ($a1.Contains('**Duration:**') -and $a2.Contains('**Duration:**')) 'each closed item gets one duration line'
    Expect-True (Invoke-NSGateUsageSync $ns $w $punch 2) 'a second sync is accepted'
    Expect-True (@([IO.File]::ReadAllLines((Get-NSUsageMarksPath $ns))).Count -eq 3) `
        'a second sync with nothing newly ticked writes no mark'

    # A pause is listed beside the duration, never subtracted from it.
    $w = Join-Path $root 'paused'
    $ns = New-Workspace $w $punchText
    $t = Join-Path $w 't.jsonl'
    Copy-Item -LiteralPath (Join-Path $fixtures 'claude-multiline.jsonl') -Destination $t
    Expect-True (Write-NSUsagePause $ns 'the session ended and the shift was revived') 'a pause is recorded'
    # A gap is closed by the mark that follows it, so the shift has to have started before the pause
    # and the item to close after it. Both stamps are the runtime's own, backdated here.
    $now = Get-NSUnixTime
    $utf8 = New-Object Text.UTF8Encoding($false)
    [IO.File]::WriteAllText((Join-Path (Get-NSUsageDir $ns) 'pauses.tsv'),
        ([string]($now - 60) + "`tthe session ended and the shift was revived`n"), $utf8)
    [IO.File]::WriteAllText((Get-NSUsageMarksPath $ns), ([string]($now - 120) + "`tarm`t`n"), $utf8)
    $r = (Read-NSUsageClaude $t 0 '').Split("`t")
    $null = Write-NSUsageRecord $ns 'claude' $r[2] 'transcript-incremental' $t $r[1] $r[0] $r[4]
    $null = Invoke-NSGateUsageSync $ns $w (Join-Path $ns 'punch-list.md') 1
    $report = [IO.File]::ReadAllText((Get-NSReceiptPath $w 'A1'))
    Expect-True ($report.Contains('(paused ')) 'the duration line lists the gap the runtime knows about'
    Expect-True ($report.Contains('the session ended and the shift was revived')) 'the pause names its reason'

    # A finished shift's accounting is set aside, so the next shift starts clean.
    $w = Join-Path $root 'retire'
    $ns = New-Workspace $w $punchText
    $null = Write-NSUsageMarkArm $ns
    $moved = Move-NSUsageRetire $ns 'shift-1'
    Expect-True ($moved.EndsWith('usage-shift-1')) "the directory is retired under the shift id (got $moved)"
    Expect-True (-not (Test-Path -LiteralPath (Get-NSUsageDir $ns))) 'the live directory is gone'
    Expect-True ([string]::IsNullOrEmpty((Move-NSUsageRetire $ns 'shift-1'))) 'retiring nothing is a no-op'

    # The pulse takes the reading and closes the item in one step.
    $w = Join-Path $root 'pulse'
    $ns = New-Workspace $w $punchText
    [IO.File]::WriteAllText((Join-Path $ns '.shift-armed'), '')
    $t = Join-Path $w 't.jsonl'
    Copy-Item -LiteralPath (Join-Path $fixtures 'claude-preshift.jsonl') -Destination $t
    Expect-True (Invoke-NSPulseUsage $ns 'claude' 'sid-1' $t) 'the pulse takes a reading'
    Add-Content -LiteralPath $t -Value ([IO.File]::ReadAllText((Join-Path $fixtures 'claude-multiline.jsonl'))) -NoNewline
    $null = Invoke-NSPulseUsage $ns 'claude' 'sid-1' $t
    Expect-True (Invoke-NSPulseMarks $ns $w) 'the pulse closes the ticked items'
    Expect-True (@([IO.File]::ReadAllLines((Get-NSUsageMarksPath $ns))).Count -eq 3) `
        'the pulse leaves the arm mark and one per ticked item'
    Expect-True ((Get-NSUsageTotal $ns).Length -gt 0) 'the pulse recorded a total'

    # Cursor hands its figures over on the payload, with no transcript at all.
    $cursor = Read-NSUsageCursor '{"usage":{"input_tokens":10,"output_tokens":4,"cache_read_tokens":7},"model":"cursor-fast"}'
    Expect-True ($cursor.Split("`t")[0] -ceq 'input=10,cache_read=7,output=4') `
        "a Cursor payload reads in the order the report prints (got $($cursor.Split([char]9)[0]))"
    Expect-True ($null -eq (Read-NSUsageCursor '{"model":"cursor-fast"}')) `
        'a payload with no figures is no measurement, not zero'
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures.Count -gt 0) {
    Write-Host "usage-logic failed ($($failures.Count)):"
    foreach ($failure in $failures) { Write-Host " - $failure" }
    exit 1
}
Write-Host 'usage-logic passed'
exit 0
