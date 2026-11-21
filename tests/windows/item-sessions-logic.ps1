# Charging the item being worked on native Windows: the PowerShell half of tests/item-sessions.bats.
# Run on macOS or Windows: pwsh -File tests/windows/item-sessions-logic.ps1
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$repository = Resolve-Path (Join-Path $PSScriptRoot '../..')
Import-Module (Join-Path $repository 'plugins/nightshift/lib/Nightshift.psm1') -Force -DisableNameChecking
$rulesTemplate = Join-Path $repository 'plugins/nightshift/config/nightshift-rules-template.json'
$failures = New-Object 'System.Collections.Generic.List[string]'
$utf8 = New-Object Text.UTF8Encoding($false)
$list3 = "## Items`n- [ ] **3. Blocked on a reply.** <!-- id: cc33 -->`n- [ ] **4. The next one.** <!-- id: dd44 -->`n- [ ] **5. Later.** <!-- id: ee55 -->`n"

function Expect-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        $failures.Add($Message)
        Write-Host "FAIL: $Message"
    }
}

# New-Site <path> - an armed shift with items 3, 4 and 5 open and the shift started at zero.
function New-Site {
    param([Parameter(Mandatory = $true)][string]$Path)
    $ns = Join-Path $Path '.nightshift'
    $null = New-Item -ItemType Directory -Path (Join-Path $ns 'receipts') -Force
    Copy-Item -LiteralPath $rulesTemplate -Destination (Join-Path $ns 'rules.json') -Force
    [IO.File]::WriteAllText((Join-Path $ns 'punch-list.md'), $list3, $utf8)
    [IO.File]::WriteAllText((Join-Path $ns '.shift-armed'), '', $utf8)
    $null = Write-NSUsageMarkArm $ns
    return $ns
}

# Add-Reading <ns> <input> <output> [id] - what the host reports was spent since the previous reading.
function Add-Reading {
    param([string]$Ns, [int]$In, [int]$Out, [string]$Id = '/t/a')
    $null = Write-NSUsageRecord $Ns 'claude' 'claude-opus-5' 'transcript-incremental' $Id '10' "input=$In,output=$Out"
}

# Write-Receipt <ns> <stem> <utc> - the model wrote that receipt at that time.
function Write-Receipt {
    param([string]$Ns, [string]$Stem, [DateTime]$When)
    $path = Join-Path $Ns ('receipts/' + $Stem + '.md')
    [IO.File]::AppendAllText($path, "# $Stem`n`nWorking on it.`n", $utf8)
    [IO.File]::SetLastWriteTimeUtc($path, $When)
}

# Invoke-Step <ns> <workspace> - what the pulse does after a tool call.
function Invoke-Step {
    param([string]$Ns, [string]$Workspace)
    $null = Invoke-NSPulseMarks $Ns $Workspace ''
}

# Get-Sessions <receipt> - `input output ended` for each recorded session.
function Get-Sessions {
    param([string]$Receipt)
    $out = New-Object Collections.Generic.List[string]
    $on = $false
    foreach ($line in [IO.File]::ReadAllLines($Receipt)) {
        if ($line -ceq '<!-- session-data') { $on = $true; continue }
        if ($on -and $line -ceq '-->') { break }
        if ($on) { $f = $line.Split(' '); $out.Add(($f[4], $f[5], $f[6]) -join ' ') }
    }
    return ($out -join '|')
}

function Set-Tick {
    param([string]$Ns, [string]$Number)
    $punch = Join-Path $Ns 'punch-list.md'
    [IO.File]::WriteAllText($punch, ([IO.File]::ReadAllText($punch) -creplace ('(?m)^- \[ \] \*\*' + $Number + '\.'), ('- [x] **' + $Number + '.')), $utf8)
}

$t0 = [DateTime]::SpecifyKind([DateTime]'2026-09-24T03:00:00', [DateTimeKind]::Utc)
$root = Join-Path ([IO.Path]::GetTempPath()) ('ns-item-sessions-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $root -Force
try {
    # The active item is the open item whose receipt was written last.
    $w = Join-Path $root 'active'
    $ns = New-Site $w
    Expect-True ((Get-NSActiveItem $w) -ceq '3. Blocked on a reply.') 'with no receipts the first open item is active'
    Write-Receipt $ns 'ee55-later' $t0
    Expect-True ((Get-NSActiveItem $w) -ceq '5. Later.') 'a written receipt makes its item active'
    Write-Receipt $ns 'dd44-the-next-one' $t0.AddMinutes(10)
    Expect-True ((Get-NSActiveItem $w) -ceq '4. The next one.') 'the newest receipt wins'
    Set-Tick $ns '4'
    Expect-True ((Get-NSActiveItem $w) -ceq '5. Later.') 'a ticked item is never the active one'

    # A receipt named by label from an earlier shift still marks its item as the one worked.
    $w = Join-Path $root 'legacy-active'
    $ns = New-Site $w
    Write-Receipt $ns 'dd44-the-next-one' $t0
    $legacy = Join-Path $ns 'receipts/5-later.md'
    [IO.File]::WriteAllText($legacy, "# 5. Later.`n`nCarried over.`n", $utf8)
    [IO.File]::SetLastWriteTimeUtc($legacy, $t0.AddMinutes(10))
    Expect-True ((Get-NSActiveItem $w) -ceq '5. Later.') 'a label-named receipt still counts'

    # Setting item 3 aside to tick item 4 charges each its own span, and returning adds a session.
    $w = Join-Path $root 'aside'
    $ns = New-Site $w
    Add-Reading $ns 10 1
    Write-Receipt $ns 'cc33-blocked-on-a-reply' $t0
    Invoke-Step $ns $w
    Add-Reading $ns 30 3
    Write-Receipt $ns 'dd44-the-next-one' $t0.AddMinutes(10)
    Invoke-Step $ns $w
    Add-Reading $ns 60 5
    Set-Tick $ns '4'
    Invoke-Step $ns $w
    $marks = @([IO.File]::ReadAllLines((Get-NSUsageMarksPath $ns)) | ForEach-Object {
            $f = $_.Split("`t") + @('', '', '', '')
            if ($f[3]) { $f[1] + ':' + $f[3] } else { $f[1] }
        })
    Expect-True (($marks -join '|') -ceq 'arm|3. Blocked on a reply.:switch|4. The next one.:tick') "marks name the item charged (got $($marks -join '|'))"
    $r3 = Join-Path $ns 'receipts/cc33-blocked-on-a-reply.md'
    $r4 = Join-Path $ns 'receipts/dd44-the-next-one.md'
    Expect-True ((Get-Sessions $r3) -ceq '40 4 switched-away') "item 3 is charged its own span (got $(Get-Sessions $r3))"
    Expect-True ((Get-Sessions $r4) -ceq '60 5 ticked') "item 4 is charged its own span (got $(Get-Sessions $r4))"
    Expect-True ([IO.File]::ReadAllText($r4).Contains('| input | 60 |')) 'the tick block shows the item total'
    Expect-True ([IO.File]::ReadAllText($r3).Contains('| switched away |')) 'the session end reads in words'
    Write-Receipt $ns 'cc33-blocked-on-a-reply' $t0.AddMinutes(20)
    Invoke-Step $ns $w
    Add-Reading $ns 30 3
    Set-Tick $ns '3'
    Invoke-Step $ns $w
    Expect-True ((Get-Sessions $r3) -ceq '40 4 switched-away|30 3 ticked') "returning adds a second session (got $(Get-Sessions $r3))"
    $r3Text = [IO.File]::ReadAllText($r3)
    Expect-True ($r3Text.Contains('| input | 70 |')) 'the tick counts both sessions'
    Expect-True ($r3Text -cmatch '(?m)^\| \*\*Total\*\* \| 2 sessions \|') 'the totals row counts both sessions'

    # Only a tick is a charge.
    $w = Join-Path $root 'charge'
    $ns = New-Site $w
    Add-Reading $ns 10 1
    Write-Receipt $ns 'cc33-blocked-on-a-reply' $t0
    Invoke-Step $ns $w
    Write-Receipt $ns 'dd44-the-next-one' $t0.AddMinutes(10)
    Invoke-Step $ns $w
    [IO.File]::WriteAllText((Join-Path $ns 'punch-list.md'), ($list3 -creplace '- \[ \] \*\*3\.', '- [x] **3.'), $utf8)
    Expect-True (((Get-NSGateUnchargedLabels $ns (Join-Path $ns 'punch-list.md')) -join '|') -ceq '3. Blocked on a reply.') 'a switch is not a charge'

    # An item parked as stalled ends its session blocked.
    $w = Join-Path $root 'blocked'
    $ns = New-Site $w
    Add-Reading $ns 10 1
    Write-Receipt $ns 'cc33-blocked-on-a-reply' $t0
    Invoke-Step $ns $w
    [IO.File]::WriteAllText((Join-Path $ns 'parking-lot.md'), "# Parking lot`n`n- 3. Blocked on a reply. $([char]0x2014) stalled $([char]0x2014) needs human: the vendor has not answered.`n", $utf8)
    Write-Receipt $ns 'dd44-the-next-one' $t0.AddMinutes(10)
    Invoke-Step $ns $w
    Expect-True ((Get-Sessions (Join-Path $ns 'receipts/cc33-blocked-on-a-reply.md')) -ceq '10 1 blocked') 'a stalled item ends blocked'

    # The shift's end closes the open session as paused, and the next shift continues the receipt.
    $w = Join-Path $root 'carry'
    $ns = New-Site $w
    Add-Reading $ns 10 1
    Write-Receipt $ns 'cc33-blocked-on-a-reply' $t0
    Invoke-Step $ns $w
    Add-Reading $ns 15 1
    Invoke-NSGateUsageFlush $ns $w
    $rc = Join-Path $ns 'receipts/cc33-blocked-on-a-reply.md'
    Expect-True ((Get-Sessions $rc) -ceq '25 2 paused') "the shift's end pauses the open session (got $(Get-Sessions $rc))"
    Move-Item -LiteralPath (Get-NSUsageDir $ns) -Destination (Join-Path $ns 'usage-retired')
    $null = Write-NSUsageMarkArm $ns
    Add-Reading $ns 7 1 '/t/b'
    Write-Receipt $ns 'cc33-blocked-on-a-reply' $t0.AddDays(1)
    Invoke-Step $ns $w
    Set-Tick $ns '3'
    Invoke-Step $ns $w
    Expect-True ((Get-Sessions $rc) -ceq '25 2 paused|7 1 ticked') "the next shift continues the receipt (got $(Get-Sessions $rc))"
    Expect-True ([IO.File]::ReadAllText($rc) -cmatch '(?m)^\| \*\*Total\*\* \| 2 sessions \| .* \| \*\*32\*\* \| \*\*3\*\* \|') 'totals run across shifts'

    # The runtime's own writes keep the receipt's modification time.
    $w = Join-Path $root 'mtime'
    $ns = New-Site $w
    Write-Receipt $ns 'cc33-blocked-on-a-reply' $t0
    $rm = Join-Path $ns 'receipts/cc33-blocked-on-a-reply.md'
    Update-NSReceiptLabel $rm '3. Blocked on a reply.'
    Add-NSReceiptSession $rm '3. Blocked on a reply.' '1111222233334444' '1790210000' '1790210600' '600' '12' '3' 'switched-away'
    Expect-True ([IO.File]::GetLastWriteTimeUtc($rm) -eq $t0) 'runtime writes keep the time'

    # The Sessions table is not the model's text.
    $rf = Join-Path $ns 'receipts/ff66-runtime-only.md'
    Add-NSReceiptSession $rf '6. Runtime only.' '1111222233334444' '1790210000' '1790210600' '600' '12' '3' 'ticked'
    Expect-True (@([IO.File]::ReadAllLines($rf))[0] -ceq '# 6. Runtime only.') 'a new receipt gets its heading'
    Expect-True (-not (Test-NSReceiptHasModelText $rf)) 'the Sessions table is not model text'

    # A session records the decisions and snags added while the item was worked.
    $w = Join-Path $root 'inbox'
    $ns = New-Site $w
    $five = "## Items`n- [ ] **1. First.** <!-- id: a1a1 -->`n- [ ] **2. Second.** <!-- id: b2b2 -->`n" +
        "- [ ] **3. Third.** <!-- id: c3c3 -->`n- [ ] **4. Fourth.** <!-- id: d4d4 -->`n- [ ] **5. Fifth.** <!-- id: e5e5 -->`n"
    [IO.File]::WriteAllText((Join-Path $ns 'punch-list.md'), $five, $utf8)
    $lot = Get-NSLayoutPath $ns 'parking-lot'
    $snag = Get-NSLayoutPath $ns 'snag-log'
    $null = New-Item -ItemType Directory -Path (Split-Path -Parent $lot), (Split-Path -Parent $snag) -Force
    [IO.File]::WriteAllText($lot, "# Parking Lot`n`n---`n`n- one decision`n- another decision`n", $utf8)
    [IO.File]::WriteAllText($snag, "# Snag Log`n`n---`n`n- one finding`n", $utf8)
    Set-Tick $ns '1'
    Invoke-Step $ns $w
    $first = [IO.File]::ReadAllText((Get-NSReceiptPath $w '1. First.'))
    Expect-True ($first.Contains(' parked=2')) 'the first item records two parked decisions'
    Expect-True ($first.Contains(' snags=1')) 'the first item records one snag'
    Set-Tick $ns '2'
    Invoke-Step $ns $w
    $second = [IO.File]::ReadAllText((Get-NSReceiptPath $w '2. Second.'))
    Expect-True (-not $second.Contains('parked=')) 'a quiet item records no parked count'
    Expect-True (-not $second.Contains('snags=')) 'a quiet item records no snag count'
    [IO.File]::WriteAllText($lot, (($firstLot = [IO.File]::ReadAllText($lot)) -replace '(?m)^- another decision\r?\n', '') + "- a different decision`n", $utf8)
    Set-Tick $ns '3'
    Invoke-Step $ns $w
    $third = [IO.File]::ReadAllText((Get-NSReceiptPath $w '3. Third.'))
    Expect-True ($third.Contains(' parked=1')) 'a replaced decision counts the new one'
    Expect-True (-not $third.Contains('snags=')) 'the snag is not counted again'
    [IO.File]::AppendAllText($lot, "- late one`n- late two`n", $utf8)
    $sessionsDir = Get-NSLayoutPath $ns 'item-sessions'
    if ($IsWindows) { & icacls.exe $sessionsDir /deny "${env:USERNAME}:(OI)(CI)W" | Out-Null }
    else { & chmod 555 $sessionsDir }
    Set-Tick $ns '4'
    try { Invoke-Step $ns $w } catch { $null = $_.Exception.Message }
    if ($IsWindows) { & icacls.exe $sessionsDir /remove:d $env:USERNAME | Out-Null }
    else { & chmod 755 $sessionsDir }
    Set-Tick $ns '5'
    Invoke-Step $ns $w
    $fifth = [IO.File]::ReadAllText((Get-NSReceiptPath $w '5. Fifth.'))
    Expect-True ($fifth.Contains(' parked=2')) 'a failed write is counted on the next session'
    $fourthPath = Get-NSReceiptPath $w '4. Fourth.'
    if (Test-Path -LiteralPath $fourthPath) {
        Expect-True (-not ([IO.File]::ReadAllText($fourthPath).Contains('parked='))) 'the failed write left no parked count'
    }
    Expect-True (([regex]::Matches($fifth, 'parked=2')).Count -eq 1) 'the fifth item counts those two once'
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

function Get-UsageText {
    param([string]$Line)
    return ((Get-NSReceiptUsageSection @($Line)) -join "`n")
}

$dot = [string][char]0x00B7
$none = Get-UsageText 'abc 1000 1600 600 - - ticked cw=- cr=- rea=- paused=0'
Expect-True ($none.Contains("**Tokens:** unavailable")) 'no figure says tokens are unavailable'
Expect-True (-not $none.Contains('| Tokens | Amount |')) 'no figure draws no Tokens table'
Expect-True ($none.Contains('| # | Shift | Host ' + $dot + ' model | Start | End | Working | Paused | Ended |')) `
    'no figure leaves the token columns out of Sessions'
$figures = Get-UsageText 'abc 1000 1600 600 1200 300 ticked cw=0 cr=0 rea=- paused=0'
Expect-True ($figures.Contains('| Tokens | Amount |')) 'a figure keeps the Tokens table'
Expect-True ($figures.Contains('| # | Shift | Host ' + $dot + ' model | Start | End | Working | Paused | Input | Output | Cache write | Cache read | Reasoning | Ended |')) `
    'a figure keeps the token columns'
$sharedLine = Get-UsageText 'abc 1000 1600 600 - - ticked turn=g2/input=800,cache_read=4000,output=20/P01;P02'
Expect-True ($sharedLine.Contains('**Tokens:** not attributable to this item')) 'a shared turn with no own figure says so'
Expect-True ($sharedLine.Contains('**Shared turn**')) 'a shared turn keeps its paragraph'

if ($failures.Count -gt 0) {
    Write-Host "item-sessions-logic failed ($($failures.Count)):"
    foreach ($failure in $failures) { Write-Host " - $failure" }
    exit 1
}
Write-Host 'item-sessions-logic passed'
exit 0
