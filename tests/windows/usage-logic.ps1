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

    # A reading that names no model keeps the model the segment recorded, a counter that starts
    # again keeps its session's model, and a reading that names one sets it from then on.
    $w = Join-Path $root 'no-model'
    $ns = New-Workspace $w $punchText
    $segments = Get-NSUsageStatePath $ns
    $null = Write-NSUsageRecord $ns 'claude' 'claude-opus-5' 'transcript-incremental' '/t/a' '10' 'input=10,output=5'
    $null = Write-NSUsageRecord $ns 'claude' '' 'transcript-incremental' '/t/a' '20' 'input=3,output=1'
    Expect-True ((Get-NSUsageSegField $segments '/t/a' 3) -ceq 'claude-opus-5') 'a model-less reading keeps the recorded model'
    Expect-True ((Get-NSUsageHosts $ns) -ceq 'claude claude-opus-5') "the source line still names the model ($(Get-NSUsageHosts $ns))"
    Expect-True ((Get-NSUsageTotal $ns) -ceq 'input=13,output=6') 'a model-less reading still counts'
    $null = Write-NSUsageRecord $ns 'codex' 'gpt-x' 'rollout' '/r/a' '0' 'input=1000,output=50'
    $null = Write-NSUsageRecord $ns 'codex' '' 'rollout' '/r/a' '0' 'input=40,output=2'
    $split = @(Get-NSUsageSegmentLines $segments | Where-Object { $_.StartsWith('/r/a#') })
    Expect-True ($split.Count -eq 1 -and $split[0].Split("`t")[2] -ceq 'gpt-x') 'a restarted counter keeps its session model'
    $null = Write-NSUsageRecord $ns 'claude' 'claude-sonnet-5' 'transcript-incremental' '/t/a' '30' 'input=1,output=1'
    Expect-True ((Get-NSUsageSegField $segments '/t/a' 3) -ceq 'claude-sonnet-5') 'a reading that names a model sets it'

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
    Expect-True ($a1.Contains('| Time |') -and $a2.Contains('| Time |')) 'each closed item gets one Time table'
    Expect-True (Invoke-NSGateUsageSync $ns $w $punch 2) 'a second sync is accepted'
    Expect-True (@([IO.File]::ReadAllLines((Get-NSUsageMarksPath $ns))).Count -eq 3) `
        'a second sync with nothing newly ticked writes no mark'

    # Marks name the item they charged, so a later item ticked first is charged to itself.
    $w = Join-Path $root 'out-of-order'
    $ns = New-Workspace $w "## Items`n- [ ] **A1 - first.**`n- [x] **A2 - second.**`n"
    $punch = Join-Path $ns 'punch-list.md'
    $t = Join-Path $w 't.jsonl'
    Copy-Item -LiteralPath (Join-Path $fixtures 'claude-multiline.jsonl') -Destination $t
    $null = Write-NSUsageMarkArm $ns
    $r = (Read-NSUsageClaude $t 0 '').Split("`t")
    $null = Write-NSUsageRecord $ns 'claude' $r[2] 'transcript-incremental' $t $r[1] $r[0] $r[4]
    Expect-True (Invoke-NSGateUsageSync $ns $w $punch 1) 'the sync closes the one ticked item'
    [IO.File]::WriteAllText($punch, "## Items`n- [x] **A1 - first.**`n- [x] **A2 - second.**`n",
        (New-Object Text.UTF8Encoding($false)))
    Expect-True (Invoke-NSGateUsageSync $ns $w $punch 2) 'the sync closes the item ticked second'
    $names = @([IO.File]::ReadAllLines((Get-NSUsageMarksPath $ns)) | ForEach-Object { $_.Split("`t")[1] })
    Expect-True (($names -join ' ') -ceq 'arm A2 A1') "each mark names the item ticked (got $($names -join ' '))"
    foreach ($id in @('A1', 'A2')) {
        $tables = @([IO.File]::ReadAllLines((Get-NSReceiptPath $w $id)) | Where-Object { $_.StartsWith('| Tokens |') })
        Expect-True ($tables.Count -eq 1) "$id is charged exactly once (got $($tables.Count))"
    }

    # A pause is listed beside the duration and subtracted from working time.
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
    Expect-True ($report.Contains('| working |')) 'working time is the wall clock minus the recorded gap'
    Expect-True ($report.Contains('| paused |')) 'the Time table lists the gap the runtime knows about'
    Expect-True ($report.Contains('| wall |')) 'wall time stays listed'
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

    # Tokens, duration and the progress cadence each follow their own setting. The settings come
    # from the policy the shift was composed with, as they do at run time.
    function Set-ReceiptsPolicy {
        param([string]$Ns, [string]$Receipts)
        [IO.File]::WriteAllText((Join-Path $Ns 'shift-policy.json'),
            ('{"schemaVersion":1,"shiftId":"9f2c40ab77e51d63","createdAt":"2026-09-02T00:00:00Z",' +
                '"source":"composition","verificationLevel":"none","toolingPolicy":"existing-tools","receipts":' +
                $Receipts + '}'), (New-Object Text.UTF8Encoding($false)))
    }
    function New-TickedUnder {
        param([string]$Name, [string]$Receipts)
        $site = Join-Path $root $Name
        $siteNs = New-Workspace $site "## Items`n- [x] **P01 - first.**`n- [ ] **P02 - open.**`n"
        Set-ReceiptsPolicy $siteNs $Receipts
        $null = Write-NSUsageRecord $siteNs 'claude' 'claude-opus-5' 'transcript-incremental' '/t/a' '10' 'input=4,output=2'
        $null = Invoke-NSGateUsageSync $siteNs $site (Join-Path $siteNs 'punch-list.md') 1
        return $site
    }
    $w = New-TickedUnder 'usage-off' '{"usage":"off"}'
    $rec = [IO.File]::ReadAllText((Join-Path $w '.nightshift/receipts/P01.md'))
    Expect-True ($rec.Contains("`n**Tokens:** off`n") -and -not $rec.Contains('| Tokens |')) 'usage off says the tokens are off'
    Expect-True ($rec.Contains('| Time |')) 'usage off still writes the Time table'
    $row = @([IO.File]::ReadAllLines((Join-Path $w '.nightshift/receipts/README.md')) | Where-Object { $_.StartsWith('| P01 | ticked |') })
    Expect-True ($row.Count -eq 1 -and $row[0].Contains('| **off** | **')) "the index reads the tokens as off (got $($row -join ' '))"

    $w = New-TickedUnder 'duration-off' '{"duration":"off"}'
    $rec = [IO.File]::ReadAllText((Join-Path $w '.nightshift/receipts/P01.md'))
    Expect-True ($rec.Contains('| input | 4 |')) 'duration off still writes the Tokens table'
    Expect-True ($rec.Contains("`n**Time:** off`n") -and -not $rec.Contains('| Time |')) 'duration off says the time is off'

    $w = New-TickedUnder 'both-off' '{"usage":"off","duration":"off"}'
    $recPath = Join-Path $w '.nightshift/receipts/P01.md'
    $rec = [IO.File]::ReadAllText($recPath)
    $kinds = @([IO.File]::ReadAllLines((Get-NSUsageMarksPath (Join-Path $w '.nightshift'))) | ForEach-Object {
            $f = $_.Split("`t") + @('', '', '', '')
            if ($f[3]) { $f[1] + ':' + $f[3] } else { $f[1] }
        })
    Expect-True (($kinds -join '|') -ceq 'arm|P01:tick') "both off still ticks (got $($kinds -join '|'))"
    Expect-True (-not $rec.Contains('| Tokens |') -and -not $rec.Contains('| Time |')) 'both off writes neither table'
    Expect-True ($rec.Contains('| off | off | off | ticked |')) 'the session reads off'
    Expect-True (@([IO.File]::ReadAllLines((Join-Path $w '.nightshift/receipts/README.md'))) -ccontains '| **Totals** |  | **off** | **off** |  |') `
        'the index totals read off'

    # The cadence.
    $w = Join-Path $root 'cadence'
    $ns = New-Workspace $w "## Items`n- [ ] **P01 - open.**`n"
    $marksFile = Get-NSUsageMarksPath $ns
    $null = New-Item -ItemType Directory -Path (Get-NSUsageDir $ns) -Force
    $now = Get-NSUnixTime
    $utf8 = New-Object Text.UTF8Encoding($false)
    Set-ReceiptsPolicy $ns '{"usage":"off","progressMode":"time","progressMinutes":20}'
    [IO.File]::WriteAllText($marksFile, "$($now - 60)`tarm`t`n", $utf8)
    Expect-True (-not (Test-NSUsageProgressDue $w 'P01')) 'usage off: time is not due before progressMinutes'
    [IO.File]::WriteAllText($marksFile, "$($now - 25 * 60)`tarm`t`n", $utf8)
    Expect-True (Test-NSUsageProgressDue $w 'P01') 'usage off: time still fires after progressMinutes'

    Set-ReceiptsPolicy $ns '{"usage":"off","progressMode":"tokens","progressTokens":1000,"progressMinutes":20}'
    [IO.File]::WriteAllText($marksFile, "$($now - 60)`tarm`t`n", $utf8)
    $null = Write-NSUsageRecord $ns 'claude' 'm' 'transcript-incremental' '/t/a' '1' 'input=5000,output=500'
    Expect-True (-not (Test-NSUsageProgressDue $w 'P01')) 'usage off: a reading past the threshold does not count'
    [IO.File]::WriteAllText($marksFile, "$($now - 25 * 60)`tarm`t`n", $utf8)
    Expect-True (Test-NSUsageProgressDue $w 'P01') 'usage off: tokens falls back to time'

    Set-ReceiptsPolicy $ns '{"progressMode":"tokens","progressTokens":1000,"progressMinutes":20}'
    [IO.File]::WriteAllText($marksFile, "$($now - 60)`tarm`tinput=0,output=0`n", $utf8)
    Expect-True (Test-NSUsageProgressDue $w 'P01') 'tokens fires on the counter'
    Set-ReceiptsPolicy $ns '{"progressMode":"completion-only"}'
    [IO.File]::WriteAllText($marksFile, "$($now - 90 * 60)`tarm`t`n", $utf8)
    Expect-True (-not (Test-NSUsageProgressDue $w 'P01')) 'completion-only never fires'
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
