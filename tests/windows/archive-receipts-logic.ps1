# Portable PowerShell coverage for artifact-mode archive-receipts.
# Run on macOS or Windows: pwsh -File tests/windows/archive-receipts-logic.ps1
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if (Test-Path Variable:PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $false
}

$repository = Resolve-Path (Join-Path $PSScriptRoot '../..')
$helper = Join-Path $repository 'plugins/nightshift/runtime/windows/archive-receipts.ps1'
$hostExecutable = (Get-Process -Id $PID).Path
Import-Module (Join-Path $repository 'plugins/nightshift/lib/Nightshift.psm1') -Force -DisableNameChecking
$failures = New-Object 'System.Collections.Generic.List[string]'
# The separator the records use, spelled by its code: Windows PowerShell 5.1 reads this file as ANSI.
$dot = [string][char]0x00B7
$onWin32 = [Environment]::OSVersion.Platform -eq 'Win32NT'

function Expect-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        $failures.Add($Message)
        Write-Host "FAIL: $Message"
    }
}

function Invoke-ArchiveReceipts {
    param(
        [Parameter(Mandatory = $true)][string]$Project,
        [string[]]$Extra = @()
    )
    $argList = @(
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', $helper, '-Project', $Project
    ) + $Extra
    $stdout = [Collections.Generic.List[string]]::new()
    $stderr = [Collections.Generic.List[string]]::new()
    $previousEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        foreach ($item in @(& $hostExecutable @argList 2>&1)) {
            if ($item -is [Management.Automation.ErrorRecord]) {
                $stderr.Add([string]$item)
            }
            else {
                $stdout.Add([string]$item)
            }
        }
    }
    finally {
        $ErrorActionPreference = $previousEap
    }
    $code = $LASTEXITCODE
    if ($null -eq $code) {
        $code = 1
    }
    return [pscustomobject]@{
        ExitCode = [int]$code
        Stdout = ($stdout -join "`n")
        Stderr = ($stderr -join "`n")
    }
}

function New-ReparseDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Target
    )
    if ($onWin32) {
        $null = New-Item -ItemType Junction -Path $Path -Target $Target
    }
    else {
        $null = New-Item -ItemType SymbolicLink -Path $Path -Target $Target
    }
}

$root = Join-Path ([IO.Path]::GetTempPath()) ("ns-archive-receipts-logic-" + [guid]::NewGuid().ToString('N'))
try {
    $artifact = Join-Path $root 'notes'
    $ns = Join-Path $artifact '.nightshift'
    $recv = Join-Path $ns 'receipts'
    $null = New-Item -ItemType Directory -Path $recv -Force
    [IO.File]::WriteAllText((Join-Path $ns 'work-mode'), "artifact`n")
    [IO.File]::WriteAllText((Join-Path $recv '20260101T000000Z-one.md'), "one`n")
    [IO.File]::WriteAllText((Join-Path $recv '20260101T000001Z-two.md'), "two`n")
    [IO.File]::WriteAllText((Join-Path $recv '.not-a-receipt'), "dot`n")
    $nestedRecv = Join-Path $recv 'nested'
    $null = New-Item -ItemType Directory -Path $nestedRecv -Force
    [IO.File]::WriteAllText((Join-Path $nestedRecv '20260101T000000Z-nested.md'), "nested`n")

    $ok = Invoke-ArchiveReceipts $artifact @('-Date', '2026-08-28')
    Expect-True ($ok.ExitCode -eq 0) "copy exits 0 (got $($ok.ExitCode) $($ok.Stderr))"
    $folder = ($ok.Stdout -split "`n")[0].Trim()
    Expect-True ($folder -match ([regex]::Escape((Join-Path $ns 'archive/2026-08-28')) + '$')) `
        "prints the shift's archive folder"
    $dest = Join-Path $folder 'receipts'
    Expect-True (Test-Path -LiteralPath (Join-Path $recv '20260101T000000Z-one.md') -PathType Leaf) `
        'leaves the first live receipt'
    Expect-True (Test-Path -LiteralPath (Join-Path $recv '20260101T000001Z-two.md') -PathType Leaf) `
        'leaves the second live receipt'
    Expect-True (Test-Path -LiteralPath (Join-Path $dest '20260101T000000Z-one.md') -PathType Leaf) `
        'copies the first receipt'
    Expect-True (Test-Path -LiteralPath (Join-Path $dest '20260101T000001Z-two.md') -PathType Leaf) `
        'copies the second receipt'
    Expect-True (-not (Test-Path -LiteralPath (Join-Path $dest '.not-a-receipt'))) `
        'does not copy a hidden file'
    Expect-True (-not (Test-Path -LiteralPath (Join-Path $dest '20260101T000000Z-nested.md'))) `
        'does not copy a nested receipt'

    $symlinkNotes = Join-Path $root 'symlink-receipts'
    $symlinkNs = Join-Path $symlinkNotes '.nightshift'
    $symlinkRecv = Join-Path $symlinkNs 'receipts'
    $null = New-Item -ItemType Directory -Path $symlinkRecv -Force
    [IO.File]::WriteAllText((Join-Path $symlinkNs 'work-mode'), "artifact`n")
    $realReceipt = Join-Path $symlinkRecv '20260101T000000Z-real.md'
    [IO.File]::WriteAllText($realReceipt, "real`n")
    $receiptLink = Join-Path $symlinkRecv '20260101T000000Z-link.md'
    $fileLinkCreated = $true
    try {
        $null = New-Item -ItemType SymbolicLink -Path $receiptLink -Target $realReceipt -ErrorAction Stop
    }
    catch {
        if ($onWin32) {
            $fileLinkCreated = $false
        }
        else {
            throw
        }
    }
    if ($fileLinkCreated) {
        $skipLink = Invoke-ArchiveReceipts $symlinkNotes @('-Date', '2026-08-28')
        Expect-True ($skipLink.ExitCode -eq 0) "symlink receipt copy exits 0 (got $($skipLink.ExitCode) $($skipLink.Stderr))"
        $skipDest = Join-Path (($skipLink.Stdout -split "`n")[0].Trim()) 'receipts'
        Expect-True (Test-Path -LiteralPath (Join-Path $skipDest '20260101T000000Z-real.md') -PathType Leaf) `
            'copies the regular receipt beside a symlink'
        Expect-True (-not (Test-Path -LiteralPath (Join-Path $skipDest '20260101T000000Z-link.md'))) `
            'does not copy a symlink receipt'
        Expect-True (Test-Path -LiteralPath $receiptLink) 'leaves the live symlink receipt'
    }

    $empty = Join-Path $root 'empty-notes'
    $emptyNs = Join-Path $empty '.nightshift'
    $null = New-Item -ItemType Directory -Path $emptyNs -Force
    [IO.File]::WriteAllText((Join-Path $emptyNs 'work-mode'), "artifact`n")
    $none = Invoke-ArchiveReceipts $empty @('-Date', '2026-08-28')
    Expect-True ($none.ExitCode -eq 0) "empty receipts exit 0 (got $($none.ExitCode) $($none.Stderr))"
    Expect-True ([string]::IsNullOrWhiteSpace($none.Stdout)) 'empty receipts print nothing'
    Expect-True (-not (Test-Path -LiteralPath (Join-Path $emptyNs 'archive/2026-08-28/receipts'))) `
        'empty receipts create no archive folder'

    $emptyDir = Join-Path $root 'empty-dir-notes'
    $emptyDirNs = Join-Path $emptyDir '.nightshift'
    $emptyDirRecv = Join-Path $emptyDirNs 'receipts'
    $null = New-Item -ItemType Directory -Path $emptyDirRecv -Force
    [IO.File]::WriteAllText((Join-Path $emptyDirNs 'work-mode'), "artifact`n")
    [IO.File]::WriteAllText((Join-Path $emptyDirRecv '.not-a-receipt'), "dot`n")
    $emptyOnly = Invoke-ArchiveReceipts $emptyDir @('-Date', '2026-08-28')
    Expect-True ($emptyOnly.ExitCode -eq 0) "skip-only receipts exit 0 (got $($emptyOnly.ExitCode) $($emptyOnly.Stderr))"
    Expect-True ([string]::IsNullOrWhiteSpace($emptyOnly.Stdout)) 'skip-only receipts print nothing'
    Expect-True (-not (Test-Path -LiteralPath (Join-Path $emptyDirNs 'archive/2026-08-28/receipts'))) `
        'skip-only receipts create no archive folder'

    $bad = Invoke-ArchiveReceipts $artifact @('-Date', 'not-a-date')
    Expect-True ($bad.ExitCode -eq 1) "malformed date exits 1 (got $($bad.ExitCode))"

    $missing = Invoke-ArchiveReceipts (Join-Path $root 'no-such-project')
    Expect-True ($missing.ExitCode -eq 1) "missing project exits 1 (got $($missing.ExitCode))"

    $linked = Join-Path $root 'link-notes'
    $linkedNs = Join-Path $linked '.nightshift'
    $linkedRecv = Join-Path $linkedNs 'receipts'
    $outside = Join-Path $root 'outside'
    $null = New-Item -ItemType Directory -Path $linkedRecv, $outside -Force
    [IO.File]::WriteAllText((Join-Path $linkedNs 'work-mode'), "artifact`n")
    [IO.File]::WriteAllText((Join-Path $linkedRecv '20260101T000000Z-real.md'), "real`n")
    New-ReparseDirectory (Join-Path $linkedNs 'archive') $outside
    $refused = Invoke-ArchiveReceipts $linked @('-Date', '2026-08-28')
    Expect-True ($refused.ExitCode -eq 2) "symlink archive path exits 2 (got $($refused.ExitCode) $($refused.Stderr))"
    Expect-True (-not (Test-Path -LiteralPath (Join-Path $outside 'receipts/20260101T000000Z-real.md'))) `
        'does not write through a reparse archive path'

    $srcLinked = Join-Path $root 'src-link-notes'
    $srcLinkedNs = Join-Path $srcLinked '.nightshift'
    $srcOutside = Join-Path $root 'src-outside'
    $null = New-Item -ItemType Directory -Path $srcLinkedNs, $srcOutside -Force
    [IO.File]::WriteAllText((Join-Path $srcLinkedNs 'work-mode'), "artifact`n")
    [IO.File]::WriteAllText((Join-Path $srcOutside '20260101T000000Z-real.md'), "real`n")
    New-ReparseDirectory (Join-Path $srcLinkedNs 'receipts') $srcOutside
    $srcRefused = Invoke-ArchiveReceipts $srcLinked @('-Date', '2026-08-28')
    Expect-True ($srcRefused.ExitCode -eq 2) "symlink receipts dir exits 2 (got $($srcRefused.ExitCode) $($srcRefused.Stderr))"
    Expect-True (-not (Test-Path -LiteralPath (Join-Path $srcLinkedNs 'archive/2026-08-28/receipts'))) `
        'does not copy through a reparse receipts path'

    $fileSrc = Join-Path $root 'file-src-notes'
    $fileSrcNs = Join-Path $fileSrc '.nightshift'
    $null = New-Item -ItemType Directory -Path $fileSrcNs -Force
    [IO.File]::WriteAllText((Join-Path $fileSrcNs 'work-mode'), "artifact`n")
    [IO.File]::WriteAllText((Join-Path $fileSrcNs 'receipts'), "not-a-dir`n")
    $fileRefused = Invoke-ArchiveReceipts $fileSrc @('-Date', '2026-08-28')
    Expect-True ($fileRefused.ExitCode -eq 2) "file receipts path exits 2 (got $($fileRefused.ExitCode) $($fileRefused.Stderr))"
    Expect-True ((Get-Content -LiteralPath (Join-Path $fileSrcNs 'receipts') -Raw) -match 'not-a-dir') `
        'does not replace a file receipts path'
    Expect-True (-not (Test-Path -LiteralPath (Join-Path $fileSrcNs 'archive/2026-08-28/receipts'))) `
        'file receipts path creates no archive folder'

    $fileDest = Join-Path $root 'file-dest-notes'
    $fileDestNs = Join-Path $fileDest '.nightshift'
    $fileDestRecv = Join-Path $fileDestNs 'receipts'
    $fileDestDated = Join-Path $fileDestNs 'archive/2026-08-28'
    $null = New-Item -ItemType Directory -Path $fileDestRecv, $fileDestDated -Force
    [IO.File]::WriteAllText((Join-Path $fileDestNs 'work-mode'), "artifact`n")
    [IO.File]::WriteAllText((Join-Path $fileDestRecv '20260101T000000Z-real.md'), "real`n")
    [IO.File]::WriteAllText((Join-Path $fileDestDated '.shift-id'), "unknown`n")
    [IO.File]::WriteAllText((Join-Path $fileDestDated 'receipts'), "not-a-dir`n")
    $destRefused = Invoke-ArchiveReceipts $fileDest @('-Date', '2026-08-28')
    Expect-True ($destRefused.ExitCode -eq 2) "file archive dest exits 2 (got $($destRefused.ExitCode) $($destRefused.Stderr))"
    Expect-True ((Get-Content -LiteralPath (Join-Path $fileDestDated 'receipts') -Raw) -match 'not-a-dir') `
        'does not replace a file archive dest'
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

# Containment of the whole destination path, not just its last component. The escape that matters
# is a link on the way to the root: `linked\history` is an ordinary directory name and passes any
# check that only looks at where it ends.
$containment = Join-Path ([IO.Path]::GetTempPath()) ('ns-contain-' + [guid]::NewGuid().ToString('N'))
$state = Join-Path $containment '.nightshift'
try {
    New-Item -ItemType Directory -Force -Path $state | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $containment 'outside') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $state 'archive-old') | Out-Null
    [IO.File]::WriteAllText((Join-Path $state 'afile'), "not a directory`n")

    foreach ($allowed in @('archive', 'history', 'nested/deep', 'archive-old')) {
        Expect-True ($null -ne (Get-NSStatePath $state $allowed)) "an ordinary name is allowed: $allowed"
    }
    foreach ($refused in @('../escape', '/tmp/elsewhere', '.hidden', 'afile', 'afile/history', '', '.')) {
        Expect-True ($null -eq (Get-NSStatePath $state $refused)) "a name that leaves the state area is refused: $refused"
    }

    # A directory link on the way to the root, where the platform allows one to be made.
    $linked = Join-Path $state 'linked'
    $made = $false
    try {
        New-Item -ItemType SymbolicLink -Path $linked -Target (Join-Path $containment 'outside') -ErrorAction Stop | Out-Null
        $made = $true
    }
    catch {
        Write-Host 'skipped: this host does not allow creating a directory link'
    }
    if ($made) {
        Expect-True ($null -eq (Get-NSStatePath $state 'linked/history')) 'an intermediate link is refused'
        Expect-True ($null -eq (Get-NSStatePath $state 'linked')) 'a link at the root is refused'
    }

    # The leaf a record is about to land on is checked too.
    Expect-True (Test-NSArchiveDest (Join-Path $state 'fresh.md')) 'a name nothing occupies may be written'
    Expect-True (-not (Test-NSArchiveDest $state)) 'a directory in the way is refused'
}
finally {
    Remove-Item -LiteralPath $containment -Recurse -Force -ErrorAction SilentlyContinue
}

$review = Join-Path ([IO.Path]::GetTempPath()) ("ns-archive-review-" + [guid]::NewGuid().ToString('N'))
try {
    $ns = Join-Path $review '.nightshift'
    $null = New-Item -ItemType Directory -Path $ns -Force
    $rulesTemplate = Join-Path $repository 'plugins/nightshift/skills/nightshift/references/nightshift-rules-template.json'
    Copy-Item -LiteralPath $rulesTemplate -Destination (Join-Path $ns 'rules.json')
    [IO.File]::WriteAllText((Join-Path $ns '.ended'), "shiftId=aaaa1111bbbb2222`narchiveRoot=archive`narchiveLayout=date`n")
    [IO.File]::WriteAllText((Join-Path $ns 'snag-log.md'),
        "# Snag Log`n`n- leak $dot tests/x.bats $dot fixed $dot 2026-09-09`n- still open $dot looking`n")
    [IO.File]::WriteAllText((Join-Path $ns 'parking-lot.md'), "# Parking Lot`n`n- wait for the owner`n")
    $one = Invoke-ArchiveReceipts $review @('-Date', '2026-09-09')
    Expect-True ($one.ExitCode -eq 0) "review file exits 0 (got $($one.ExitCode) $($one.Stderr))"
    $snagDest = Join-Path $ns 'archive/2026-09-09/snag-log.md'
    Expect-True ((Test-Path -LiteralPath $snagDest -PathType Leaf) -and
        [IO.File]::ReadAllText($snagDest) -ceq "# Snag Log`n`n- leak $dot tests/x.bats $dot fixed $dot 2026-09-09`n- still open $dot looking`n") `
        'the snag log is filed whole, where it sits live'
    $lotDest = Join-Path $ns 'archive/2026-09-09/parking-lot.md'
    Expect-True ((Test-Path -LiteralPath $lotDest -PathType Leaf) -and
        [IO.File]::ReadAllText($lotDest) -ceq "# Parking Lot`n`n- wait for the owner`n") 'an unanswered parking lot is filed as it stands'
    Expect-True (-not [IO.File]::ReadAllText((Join-Path $ns 'parking-lot.md')).Contains('Filed:')) 'with nothing answered it gets no pointer'
    $liveSnag = [IO.File]::ReadAllText((Join-Path $ns 'snag-log.md'))
    Expect-True ($liveSnag.Contains('Filed: [2026-09-09](archive/2026-09-09/snag-log.md)')) `
        'one pointer names the dest relative to the live file'
    Expect-True ($liveSnag.Contains('still open ' + $dot + ' looking')) 'unresolved snag stays live'
    Expect-True (-not $liveSnag.Contains('leak ' + $dot)) 'filed snag leaves the live file'
    $again = Invoke-ArchiveReceipts $review @('-Date', '2026-09-09')
    Expect-True ($again.ExitCode -eq 0) "retry exits 0 (got $($again.ExitCode))"
    $liveSnag = [IO.File]::ReadAllText((Join-Path $ns 'snag-log.md'))
    Expect-True (([regex]::Matches($liveSnag, '(?m)^Filed:').Count) -eq 1) `
        'retry does not duplicate the pointer'

    # A second shift the same day files into its own dated folder, and its pointer says which.
    [IO.File]::WriteAllText((Join-Path $ns '.ended'), "shiftId=cccc3333dddd4444`narchiveRoot=archive`narchiveLayout=date`n")
    [IO.File]::AppendAllText((Join-Path $ns 'snag-log.md'), "- second $dot y $dot answered $dot 2026-09-09`n")
    $two = Invoke-ArchiveReceipts $review @('-Date', '2026-09-09')
    Expect-True ($two.ExitCode -eq 0) "second shift exits 0 (got $($two.ExitCode) $($two.Stderr))"
    Expect-True (Test-Path -LiteralPath (Join-Path $ns 'archive/2026-09-09-shift-2/snag-log.md') -PathType Leaf) `
        "the second shift files into its own folder"
    Expect-True ([IO.File]::ReadAllText((Join-Path $ns 'snag-log.md')).Contains('Filed: [2026-09-09-shift-2](archive/2026-09-09-shift-2/snag-log.md)')) `
        'the second pointer names its folder'
    [IO.File]::WriteAllText((Join-Path $ns '.ended'), "shiftId=aaaa1111bbbb2222`narchiveRoot=archive`narchiveLayout=date`n")

    $dash = [string][char]0x2014
    [IO.File]::WriteAllText((Join-Path $ns 'snag-log.md'),
        ("# Snag Log`n`n- leak $dot tests/x.bats`n  $dot fixed " + $dash +
         " join must see the disposition`n  $dot 2026-09-13`n- still open $dot looking`n"))
    $wrapped = Invoke-ArchiveReceipts $review @('-Date', '2026-09-13')
    Expect-True ($wrapped.ExitCode -eq 0) "wrapped review file exits 0 (got $($wrapped.ExitCode) $($wrapped.Stderr))"
    $wrapDest = Join-Path $ns 'archive/2026-09-13/snag-log.md'
    Expect-True (Test-Path -LiteralPath $wrapDest -PathType Leaf) 'wrapped handled snag is filed'
    if (Test-Path -LiteralPath $wrapDest -PathType Leaf) {
        Expect-True ([IO.File]::ReadAllText($wrapDest).Contains('fixed ' + $dash + ' join must see the disposition')) `
            'the wrapped disposition is in the archive'
    }
    $liveSnag = [IO.File]::ReadAllText((Join-Path $ns 'snag-log.md'))
    Expect-True ($liveSnag.Contains('still open ' + $dot + ' looking')) 'unresolved snag stays live after wrap filing'
    Expect-True (-not $liveSnag.Contains('leak ' + $dot)) 'filed wrapped snag leaves the live file'

    # An entry ends where the morning receipt ends it: a heading straight after a bullet and a
    # paragraph after a blank line stay live, and Default and Rollback lines travel with it.
    $boundsText = ((@(
        '# Parking Lot', '', '---', '',
        "- Ship the flag on? $dot answered: yes, behind the setting",
        '- **Default:** kept off', '', '  - Rollback: turn it off again',
        '## Tomorrow',
        "- Rename the flag? $dot answered: keep the name", '',
        "A note the owner wrote as a paragraph $dot answered: later",
        '- still open') -join "`n") + "`n")
    [IO.File]::WriteAllText((Join-Path $ns 'parking-lot.md'), $boundsText)
    $bounds = Invoke-ArchiveReceipts $review @('-Date', '2026-09-24')
    Expect-True ($bounds.ExitCode -eq 0) "entry-bounds review file exits 0 (got $($bounds.ExitCode) $($bounds.Stderr))"
    $boundsDest = Join-Path $ns 'archive/2026-09-24/parking-lot.md'
    $boundsFiled = $(if (Test-Path -LiteralPath $boundsDest -PathType Leaf) { [IO.File]::ReadAllText($boundsDest) } else { '' })
    # Archive writes the host's line ending on the live side; the assertions read LF.
    $boundsLive = [IO.File]::ReadAllText((Join-Path $ns 'parking-lot.md')).Replace("`r`n", "`n")
    Expect-True ($boundsFiled -ceq $boundsText) 'the parking lot is filed whole, as it stood'
    Expect-True ($boundsLive.Contains("`n## Tomorrow`n") -and
        $boundsLive.Contains("`nA note the owner wrote as a paragraph $dot answered: later`n") -and
        $boundsLive.Contains("`n- still open`n")) 'the heading, the paragraph and the open entry stay live'
    Expect-True (-not $boundsLive.Contains('Ship the flag') -and -not $boundsLive.Contains('kept off') -and
        -not $boundsLive.Contains('Rename the flag')) 'the filed entries leave the live parking lot whole'

    [IO.File]::WriteAllText((Join-Path $ns 'snag-log.md'),
        "# Snag Log`n`nFiled: [2026-09-09](archive/missing/snag-log.md)`n")
    $broken = Invoke-ArchiveReceipts $review @('-Date', '2026-09-09')
    Expect-True ($broken.ExitCode -eq 0) "broken pointer exits 0 (got $($broken.ExitCode))"
    Expect-True ([IO.File]::ReadAllText((Join-Path $ns 'snag-log.md')).Contains(
        'broken archive pointer ' + $dot + ' archive/missing/snag-log.md is not a readable file')) `
        'a broken pointer is reported in the snag log'
}
finally {
    Remove-Item -LiteralPath $review -Recurse -Force -ErrorAction SilentlyContinue
}

# A retired shift's usage folder is one record: filed whole, retired once filed, and refused by name
# only when it was not filed.
function Get-TextOrEmpty {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (Test-Path -LiteralPath $Path -PathType Leaf) { return [IO.File]::ReadAllText($Path) }
    return ''
}
$usageWork = Join-Path ([IO.Path]::GetTempPath()) ("ns-archive-usage-" + [guid]::NewGuid().ToString('N'))
try {
    $ns = Join-Path $usageWork '.nightshift'
    foreach ($name in @('usage-aaaa', 'usage-bbbb')) { $null = New-Item -ItemType Directory -Path (Join-Path $ns $name) -Force }
    Copy-Item -LiteralPath (Join-Path $repository 'plugins/nightshift/skills/nightshift/references/nightshift-rules-template.json') `
        -Destination (Join-Path $ns 'rules.json')
    [IO.File]::WriteAllText((Join-Path $ns 'usage-aaaa/segments.tsv'), "seg a`n")
    [IO.File]::WriteAllText((Join-Path $ns 'usage-aaaa/marks.tsv'), "marks a`n")
    [IO.File]::WriteAllText((Join-Path $ns 'usage-bbbb/segments.tsv'), "seg b`n")
    [IO.File]::WriteAllText((Join-Path $ns '.ended'), '')
    $usageRun = Invoke-ArchiveReceipts $usageWork @('-Date', '2026-09-05', '-Retire', 'usage-aaaa')
    Expect-True ($usageRun.ExitCode -eq 0) "usage filing exits 0 (got $($usageRun.ExitCode) $($usageRun.Stderr))"
    $usageDest = Join-Path $ns 'archive/2026-09-05'
    Expect-True ((Get-TextOrEmpty (Join-Path $usageDest 'usage-aaaa/segments.tsv')) -ceq "seg a`n") 'a named usage folder is filed'
    Expect-True ((Get-TextOrEmpty (Join-Path $usageDest 'usage-aaaa/marks.tsv')) -ceq "marks a`n") 'every record in it is filed'
    Expect-True ((Get-TextOrEmpty (Join-Path $usageDest 'usage-bbbb/segments.tsv')) -ceq "seg b`n") 'an unnamed usage folder is filed too'
    Expect-True (-not (Test-Path -LiteralPath (Join-Path $ns 'usage-aaaa'))) 'the named folder leaves live storage'
    Expect-True (-not (Test-Path -LiteralPath (Join-Path $ns 'usage-bbbb'))) 'a closed shift folder leaves live storage once filed, named or not'
    Expect-True (-not $usageRun.Stderr.Contains('this run filed no such record')) "a filed folder is not refused ($($usageRun.Stderr))"

    # A folder holding a record that cannot be filed stays live, whole, and naming it is refused.
    $null = New-Item -ItemType Directory -Path (Join-Path $ns 'usage-cccc'), (Join-Path $usageDest 'usage-cccc') -Force
    [IO.File]::WriteAllText((Join-Path $ns 'usage-cccc/segments.tsv'), "seg c`n")
    [IO.File]::WriteAllText((Join-Path $ns 'usage-cccc/marks.tsv'), "marks c`n")
    [IO.File]::WriteAllText((Join-Path $usageDest 'usage-cccc/segments.tsv'), "a different record`n")
    $clashRun = Invoke-ArchiveReceipts $usageWork @('-Date', '2026-09-05', '-Retire', 'usage-cccc')
    Expect-True ($clashRun.ExitCode -eq 0) "a clashing usage folder exits 0 (got $($clashRun.ExitCode))"
    Expect-True ((Get-TextOrEmpty (Join-Path $ns 'usage-cccc/segments.tsv')) -ceq "seg c`n") 'the clashing record stays live'
    Expect-True ((Get-TextOrEmpty (Join-Path $ns 'usage-cccc/marks.tsv')) -ceq "marks c`n") 'the rest of its folder stays live'
    Expect-True ($clashRun.Stderr.Contains('usage-cccc (not every record in it could be filed)')) "the folder is reported kept ($($clashRun.Stderr))"
    Expect-True ($clashRun.Stderr -match '(?m)^\s*usage-cccc\s*$') 'naming it is refused'
}
finally {
    Remove-Item -LiteralPath $usageWork -Recurse -Force -ErrorAction SilentlyContinue
}

# A shift that ended with work still open. The receipt of a ticked item is filed and retired; the
# receipt of an item nobody finished is filed as it stands and stays live, and each index lists what
# its folder holds.
$openWork = Join-Path ([IO.Path]::GetTempPath()) ("ns-archive-open-" + [guid]::NewGuid().ToString('N'))
try {
    $ns = Join-Path $openWork '.nightshift'
    $recv = Join-Path $ns 'receipts'
    $null = New-Item -ItemType Directory -Path $recv -Force
    [IO.File]::WriteAllText((Join-Path $ns 'work-mode'), "artifact`n")
    [IO.File]::WriteAllText((Join-Path $ns 'punch-list.md'), ("Date: 2026-09-05`n`n## Items`n" +
        "- [x] **1. Fix the resolver.**`n- [x] **2. Cover the parser.**`n- [ ] **3. Trim the bundle.**`n"))
    [IO.File]::WriteAllText((Join-Path $recv '1-fix-the-resolver.md'), ("# 1. Fix the resolver.`n`nDone.`n`n" +
        "**Usage:** input 100 $dot output 20`n" +
        "  Source: claude claude-opus-5, cumulative counters, segments 1; exact: 100 / 0 / 0 / 20 / 0`n" +
        "**Duration:** 10m 00s`n"))
    [IO.File]::WriteAllText((Join-Path $recv '2-cover-the-parser.md'),
        "# 2. Cover the parser.`n`nDone.`n`n**Duration:** 5m 00s`n")
    [IO.File]::WriteAllText((Join-Path $recv '3-trim-the-bundle.md'),
        "# 3. Trim the bundle.`n`nIn progress: the loader is measured, the chunks are not.`n")
    [IO.File]::WriteAllText((Join-Path $recv 'morning-2026-09-05-abc.md'), "morning`n")
    Write-NSReceiptsIndex -Workspace $openWork
    [IO.File]::WriteAllText((Join-Path $ns '.ended'), '')
    $liveOpen = Join-Path $recv '3-trim-the-bundle.md'
    $openBefore = [Convert]::ToBase64String([IO.File]::ReadAllBytes($liveOpen))

    $bare = Invoke-ArchiveReceipts $openWork @('-Date', '2026-09-05')
    Expect-True ($bare.ExitCode -eq 0) "bare ended filing exits 0 (got $($bare.ExitCode) $($bare.Stderr))"
    Expect-True (-not (Test-Path -LiteralPath (Join-Path $recv '1-fix-the-resolver.md'))) `
        'bare archive retires a ticked item receipt'
    Expect-True (-not (Test-Path -LiteralPath (Join-Path $recv '2-cover-the-parser.md'))) `
        'bare archive retires every ticked item receipt'
    Expect-True (Test-Path -LiteralPath (Join-Path $recv '3-trim-the-bundle.md') -PathType Leaf) `
        'bare archive keeps an open item receipt'
    Expect-True (Test-Path -LiteralPath (Join-Path $recv 'morning-2026-09-05-abc.md') -PathType Leaf) `
        'bare archive leaves morning until it is named'

    $filed = Invoke-ArchiveReceipts $openWork @('-Date', '2026-09-05',
        '-Retire', '1-fix-the-resolver.md,2-cover-the-parser.md,morning-2026-09-05-abc.md')
    Expect-True ($filed.ExitCode -eq 0) "open-work filing exits 0 (got $($filed.ExitCode) $($filed.Stderr))"
    $dest = Join-Path $ns 'archive/2026-09-05/receipts'
    foreach ($name in @('1-fix-the-resolver.md', '2-cover-the-parser.md', 'morning-2026-09-05-abc.md')) {
        Expect-True (Test-Path -LiteralPath (Join-Path $dest $name) -PathType Leaf) "files the closed record $name"
        Expect-True (-not (Test-Path -LiteralPath (Join-Path $recv $name))) "retires the closed record $name"
    }
    Expect-True ((Test-Path -LiteralPath (Join-Path $dest '3-trim-the-bundle.md') -PathType Leaf) -and
        $openBefore -ceq [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $dest '3-trim-the-bundle.md')))) `
        'files the receipt of an open item as it stands'
    Expect-True (Test-Path -LiteralPath $liveOpen -PathType Leaf) 'leaves the open item receipt live'
    Expect-True ($openBefore -ceq [Convert]::ToBase64String([IO.File]::ReadAllBytes($liveOpen))) `
        'the open item receipt is byte-identical'
    $liveIndex = [IO.File]::ReadAllText((Join-Path $recv 'README.md'))
    Expect-True ($liveIndex.Contains('| 3. Trim the bundle. | open |')) 'the live index lists the open item'
    Expect-True (-not $liveIndex.Contains('Fix the resolver')) 'the live index drops a filed receipt'
    $archivedIndex = [IO.File]::ReadAllText((Join-Path $dest 'README.md'))
    Expect-True ($archivedIndex.Contains('# Receipts ' + [char]0x2014 + ' 2026-09-05')) 'the archived index is dated'
    Expect-True ($archivedIndex.Contains(
        '| 1. Fix the resolver. | ticked | **input 100 ' + $dot + ' cache_write 0 ' + $dot + ' cache_read 0 ' + $dot + ' output 20 ' + $dot + ' reasoning 0** | **10m 0s working** | [./1-fix-the-resolver.md](./1-fix-the-resolver.md) |')) `
        'the archived index carries the first receipt with its measurements'
    Expect-True ($archivedIndex.Contains('| 2. Cover the parser. | ticked |')) `
        'the archived index carries the second receipt'
    Expect-True ($archivedIndex.Contains('| 3. Trim the bundle. | open |')) 'the archived index lists the open item as open'
    $summaryAt = $archivedIndex.IndexOf('Shift summary: [morning-2026-09-05-abc.md](./morning-2026-09-05-abc.md)')
    Expect-True ($summaryAt -gt 0 -and $summaryAt -lt $archivedIndex.IndexOf('| Item | State |')) `
        'the archived index links the morning receipt above the item table'
    Expect-True (-not $archivedIndex.Contains('| morning-')) 'the morning receipt is never an item row'
    Expect-True (-not $liveIndex.Contains('morning-2026-09-05-abc.md')) `
        'the live index stops linking a morning receipt once it is filed'
}
finally {
    Remove-Item -LiteralPath $openWork -Recurse -Force -ErrorAction SilentlyContinue
}

# Receipts link to each other by bare name, because they were written side by side. Filed, they are
# still side by side, the open item's copy included; a record that was not filed has to be reached
# back through the archive.
$siblings = Join-Path ([IO.Path]::GetTempPath()) ("ns-archive-siblings-" + [guid]::NewGuid().ToString('N'))
try {
    $ns = Join-Path $siblings '.nightshift'
    $recv = Join-Path $ns 'receipts'
    $null = New-Item -ItemType Directory -Path $recv -Force
    [IO.File]::WriteAllText((Join-Path $ns 'work-mode'), "artifact`n")
    [IO.File]::WriteAllText((Join-Path $ns 'punch-list.md'), ("Date: 2026-09-05`n`n## Items`n" +
        "- [x] **1. Fix the resolver.**`n- [x] **2. Cover the parser.**`n- [ ] **3. Trim the bundle.**`n"))
    [IO.File]::WriteAllText((Join-Path $recv '1-fix-the-resolver.md'), ("# 1. Fix the resolver.`n`n" +
        "Next: [2. Cover the parser.](./2-cover-the-parser.md), and`n" +
        "[3. Trim the bundle.](./3-trim-the-bundle.md) is still open. Index: [receipts](./README.md).`n" +
        "Decision: [the parking lot](../parking-lot.md).`n"))
    [IO.File]::WriteAllText((Join-Path $recv '2-cover-the-parser.md'),
        "# 2. Cover the parser.`n`nBack to [the resolver](1-fix-the-resolver.md).`n")
    [IO.File]::WriteAllText((Join-Path $recv '3-trim-the-bundle.md'), "# 3. Trim the bundle.`n`nIn progress.`n")
    [IO.File]::WriteAllText((Join-Path $recv 'morning-2026-09-05-abc.md'),
        "# Morning`n`nThe index of this shift: [receipts](./README.md).`n")
    [IO.File]::WriteAllText((Join-Path $ns 'parking-lot.md'), "# Parking`n")
    [IO.File]::WriteAllText((Join-Path $ns '.ended'), '')

    $siblingRun = Invoke-ArchiveReceipts $siblings @('-Date', '2026-09-05',
        '-Retire', '1-fix-the-resolver.md,2-cover-the-parser.md,morning-2026-09-05-abc.md')
    Expect-True ($siblingRun.ExitCode -eq 0) "sibling filing exits 0 (got $($siblingRun.ExitCode) $($siblingRun.Stderr))"
    $dest = Join-Path $ns 'archive/2026-09-05/receipts'
    $morning = [IO.File]::ReadAllText((Join-Path $dest 'morning-2026-09-05-abc.md'))
    $first = [IO.File]::ReadAllText((Join-Path $dest '1-fix-the-resolver.md'))
    $second = [IO.File]::ReadAllText((Join-Path $dest '2-cover-the-parser.md'))

    # The index of the folder it landed in, not the one it was written beside.
    Expect-True ($morning.Contains('(./README.md)')) 'the archived morning receipt still names ./README.md'
    Expect-True (Test-Path -LiteralPath (Join-Path $dest 'README.md') -PathType Leaf) `
        'the archived index the morning receipt names is there'

    # A neighbour that travelled with it is still a neighbour, written with or without ./.
    Expect-True ($first.Contains('(./2-cover-the-parser.md)')) 'a filed neighbour is still a sibling'
    Expect-True (Test-Path -LiteralPath (Join-Path $dest '2-cover-the-parser.md') -PathType Leaf) `
        'the filed neighbour is where the link says'
    Expect-True ($second.Contains('(1-fix-the-resolver.md)')) 'a bare sibling name is left as written'

    # The open item's receipt was filed as it stood, so the link names its filed copy.
    Expect-True ($first.Contains('(./3-trim-the-bundle.md)')) 'the open item receipt is reached as a filed sibling'
    Expect-True (Test-Path -LiteralPath (Join-Path $dest '3-trim-the-bundle.md') -PathType Leaf) `
        'the filed open item receipt resolves from the archived receipt'
    # And a link that already climbed out of receipts/ climbed from there, not from the archive.
    Expect-True ($first.Contains('(../../../parking-lot.md)')) 'a climbing link climbed from receipts/'
    Expect-True (Test-Path -LiteralPath (Join-Path $dest '../../../parking-lot.md') -PathType Leaf) `
        'the live parking lot resolves from the archived receipt'
}
finally {
    Remove-Item -LiteralPath $siblings -Recurse -Force -ErrorAction SilentlyContinue
}

# The archived index follows item order: 1, 2, 10 by value, letter ids by letters then value, and
# unnumbered receipts last.
$ordered = Join-Path ([IO.Path]::GetTempPath()) ('ns-archive-order-' + [guid]::NewGuid().ToString('N'))
try {
    $null = New-Item -ItemType Directory -Path $ordered
    $expected = @('1. One.', '2. Two.', '10. Ten.', 'A1 Alpha one.', 'A2 Alpha two.', 'A10 Alpha ten.',
        'B1 Beta one.')
    $files = @('1-one.md', '2-two.md', '10-ten.md', 'A1-alpha-one.md', 'A2-alpha-two.md',
        'A10-alpha-ten.md', 'B1-beta-one.md')
    $utf8 = New-Object Text.UTF8Encoding($false)
    for ($i = 0; $i -lt $files.Count; $i++) {
        [IO.File]::WriteAllText((Join-Path $ordered $files[$i]), "# $($expected[$i])`n`nDone.`n", $utf8)
    }
    [IO.File]::WriteAllText((Join-Path $ordered 'unnumbered.md'), "# Unnumbered.`n`nDone.`n", $utf8)
    Write-NSArchiveReceiptsIndex -Directory $ordered -Date '2026-09-05'
    $labels = @([IO.File]::ReadAllLines((Join-Path $ordered 'README.md')) |
        Where-Object { $_ -cmatch '^\| ([^|]+) \| ticked \|' } |
        ForEach-Object { ($_ -creplace '^\| ([^|]+) \| ticked \|.*$', '$1') })
    Expect-True (($labels -join '|') -ceq (($expected + 'Unnumbered.') -join '|')) `
        "the archived index lists receipts in item order (got: $($labels -join ', '))"
}
finally {
    Remove-Item -LiteralPath $ordered -Recurse -Force -ErrorAction SilentlyContinue
}

# An ended shift's punch list is filed into its folder whole, as it stood. The contract and the open
# items stay live; an armed shift's list is never touched; a different record already filed is
# refused.
$punchRoot = Join-Path ([IO.Path]::GetTempPath()) ('ns-punch-filing-' + [guid]::NewGuid().ToString('N'))
try {
    $utf8 = New-Object Text.UTF8Encoding($false)
    $rulesTemplate = Join-Path $repository 'plugins/nightshift/skills/nightshift/references/nightshift-rules-template.json'
    $body = "# Punch list`n`n## Shift`n`nThe contract.`n`n## Gates`n`n- run checks`n`n## Items`n`n- [x] **1. done.**`n  - its bullet`n`n- [ ] **2. open.**`n"
    function New-EndedSite {
        param([string]$Name, [string]$ShiftId, [string]$Punch, [switch]$Armed)
        $site = Join-Path $punchRoot $Name
        $siteNs = Join-Path $site '.nightshift'
        $null = New-Item -ItemType Directory -Path $siteNs -Force
        Copy-Item -LiteralPath $rulesTemplate -Destination (Join-Path $siteNs 'rules.json')
        [IO.File]::WriteAllText((Join-Path $siteNs 'punch-list.md'), $Punch, $utf8)
        if ($Armed) { [IO.File]::WriteAllText((Join-Path $siteNs '.shift-armed'), '', $utf8) }
        else { [IO.File]::WriteAllText((Join-Path $siteNs '.ended'), "shiftId=$ShiftId`narchiveRoot=archive`narchiveLayout=date`n", $utf8) }
        return $site
    }

    $site = New-EndedSite 'filed' '9f2c40ab77e51d63' $body
    $run = Invoke-ArchiveReceipts $site @('-Date', '2026-09-05')
    Expect-True ($run.ExitCode -eq 0) "punch filing exits 0 (got $($run.ExitCode) $($run.Stderr))"
    $filedPath = Join-Path $site '.nightshift/archive/2026-09-05/punch-list.md'
    Expect-True ($run.Stdout.Contains('filed the punch list as ')) "the helper says where the punch list went: $($run.Stdout) $($run.Stderr)"
    Expect-True ((Test-Path -LiteralPath $filedPath) -and [IO.File]::ReadAllText($filedPath) -ceq $body) 'the record is the whole list as it stood'
    Expect-True ([IO.File]::ReadAllText((Join-Path $site '.nightshift/punch-list.md')) -ceq "# Punch list`n`n## Shift`n`nThe contract.`n`n## Gates`n`n- run checks`n`n## Items`n`n- [ ] **2. open.**`n") `
        'the open item and the contract stay live'

    $site = New-EndedSite 'two' '1111111111111111' "## Items`n- [x] **1. first night.**`n"
    $null = Invoke-ArchiveReceipts $site @('-Date', '2026-09-05')
    [IO.File]::WriteAllText((Join-Path $site '.nightshift/.ended'), "shiftId=2222222222222222`narchiveRoot=archive`narchiveLayout=date`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $site '.nightshift/punch-list.md'), "## Items`n- [x] **1. second night.**`n", $utf8)
    $null = Invoke-ArchiveReceipts $site @('-Date', '2026-09-05')
    Expect-True ([IO.File]::ReadAllText((Join-Path $site '.nightshift/archive/2026-09-05/punch-list.md')).Contains('first night')) 'the first shift keeps its record'
    Expect-True ([IO.File]::ReadAllText((Join-Path $site '.nightshift/archive/2026-09-05-shift-2/punch-list.md')).Contains('second night')) 'the second shift files its own record'

    $site = New-EndedSite 'none' '9f2c40ab77e51d63' "## Items`n- [ ] **1. open.**`n"
    $null = Invoke-ArchiveReceipts $site @('-Date', '2026-09-05')
    $noneFiled = Join-Path $site '.nightshift/archive/2026-09-05/punch-list.md'
    Expect-True ((Test-Path -LiteralPath $noneFiled) -and [IO.File]::ReadAllText($noneFiled) -ceq "## Items`n- [ ] **1. open.**`n") 'a list with only open items is filed as it stood'
    Expect-True ([IO.File]::ReadAllText((Join-Path $site '.nightshift/punch-list.md')) -ceq "## Items`n- [ ] **1. open.**`n") 'and stays live whole'

    $site = New-EndedSite 'armed' '9f2c40ab77e51d63' $body -Armed
    $null = Invoke-ArchiveReceipts $site @('-Date', '2026-09-05')
    Expect-True ([IO.File]::ReadAllText((Join-Path $site '.nightshift/punch-list.md')) -ceq $body) 'an armed shift keeps its list'

    $site = New-EndedSite 'clash' '9f2c40ab77e51d63' $body
    $clashDir = Join-Path $site '.nightshift/archive/2026-09-05'
    $null = New-Item -ItemType Directory -Path $clashDir -Force
    [IO.File]::WriteAllText((Join-Path $clashDir '.shift-id'), "9f2c40ab77e51d63`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $clashDir 'punch-list.md'), "an earlier record`n", $utf8)
    $clash = Invoke-ArchiveReceipts $site @('-Date', '2026-09-05')
    Expect-True ($clash.Stderr.Contains('a different punch list is already filed at')) "a different record is refused: $($clash.Stderr)"
    Expect-True ([IO.File]::ReadAllText((Join-Path $site '.nightshift/punch-list.md')) -ceq $body) 'the live list is kept after a refusal'
}
finally {
    Remove-Item -LiteralPath $punchRoot -Recurse -Force -ErrorAction SilentlyContinue
}

# Each later shift on a date files into its own numbered folder, and a shift filed again that day
# comes back to its own.
$sameDay = Join-Path ([IO.Path]::GetTempPath()) ('ns-same-day-' + [guid]::NewGuid().ToString('N'))
try {
    $sameNs = Join-Path $sameDay '.nightshift'
    $null = New-Item -ItemType Directory -Path $sameNs -Force
    $archiveBase = Join-Path $sameNs 'archive'
    $first = Get-NSArchiveDir -Workspace $sameDay -Date '2026-09-05' -ShiftId '1111111111111111'
    $second = Get-NSArchiveDir -Workspace $sameDay -Date '2026-09-05' -ShiftId '2222222222222222'
    $third = Get-NSArchiveDir -Workspace $sameDay -Date '2026-09-05' -ShiftId '3333333333333333'
    Expect-True ($first -ceq (Join-Path $archiveBase '2026-09-05')) "the first shift files into the date folder (got $first)"
    Expect-True ($second -ceq (Join-Path $archiveBase '2026-09-05-shift-2')) "the second shift gets -shift-2 (got $second)"
    Expect-True ($third -ceq (Join-Path $archiveBase '2026-09-05-shift-3')) "the third shift gets -shift-3 (got $third)"
    Expect-True (([IO.File]::ReadAllText((Join-Path $second '.shift-id'))).Trim() -ceq '2222222222222222') 'a folder records its shift'
    Expect-True ((Get-NSArchiveDir -Workspace $sameDay -Date '2026-09-05' -ShiftId '2222222222222222') -ceq $second) 'the same shift returns to its folder'
    Expect-True (-not (Test-Path -LiteralPath (Join-Path $archiveBase '2026-09-05-shift-4'))) 'no extra folder is opened'
    # A shift with no id claims its folder as unknown, comes back to it, and a shift with an id
    # moves past it.
    $noId = Join-Path $archiveBase '2026-09-06'
    Expect-True ((Get-NSArchiveDir -Workspace $sameDay -Date '2026-09-06' -ShiftId 'unknown') -ceq $noId) 'no id files into the date folder'
    Expect-True (([IO.File]::ReadAllText((Join-Path $noId '.shift-id'))).Trim() -ceq 'unknown') 'no id claims the folder as unknown'
    [IO.File]::WriteAllText((Join-Path $noId 'punch-list.md'), "the first night`n", (New-Object Text.UTF8Encoding($false)))
    Expect-True ((Get-NSArchiveDir -Workspace $sameDay -Date '2026-09-06' -ShiftId 'unknown') -ceq $noId) 'no id comes back to its folder'
    Expect-True ((Get-NSArchiveDir -Workspace $sameDay -Date '2026-09-06' -ShiftId '') -ceq $noId) 'an empty id is no id'
    Expect-True ((Get-NSArchiveDir -Workspace $sameDay -Date '2026-09-06' -ShiftId '2222222222222222') -ceq ($noId + '-shift-2')) 'a shift with an id moves past an unknown folder'
    # A shift with no id moves past a folder another shift owns.
    Expect-True ((Get-NSArchiveDir -Workspace $sameDay -Date '2026-09-05' -ShiftId 'unknown') -ceq (Join-Path $archiveBase '2026-09-05-shift-4')) 'no id moves past owned folders'

    # A folder holding records nobody claimed is left alone; an empty one is claimed.
    $legacy = Join-Path $archiveBase '2026-09-07'
    $null = New-Item -ItemType Directory -Path $legacy -Force
    [IO.File]::WriteAllText((Join-Path $legacy 'shipped.md'), "an earlier night`n", (New-Object Text.UTF8Encoding($false)))
    Expect-True ((Get-NSArchiveDir -Workspace $sameDay -Date '2026-09-07' -ShiftId '1111111111111111') -ceq ($legacy + '-shift-2')) 'a folder with records nobody claimed is not claimed'
    Expect-True (-not (Test-Path -LiteralPath (Join-Path $legacy '.shift-id'))) 'that folder stays unclaimed'
    $empty = Join-Path $archiveBase '2026-09-08'
    $null = New-Item -ItemType Directory -Path $empty -Force
    Expect-True ((Get-NSArchiveDir -Workspace $sameDay -Date '2026-09-08' -ShiftId '1111111111111111') -ceq $empty) 'an empty unclaimed folder is claimed'

    # The clock-out policy archive files a second same-day shift into its own folder.
    $utf8 = New-Object Text.UTF8Encoding($false)
    $today = Get-Date -Format 'yyyy-MM-dd'
    foreach ($id in @('4444444444444444', '5555555555555555')) {
        [IO.File]::WriteAllText((Join-Path $sameNs 'shift-policy.json'),
            ('{"schemaVersion":1,"shiftId":"' + $id + '","createdAt":"2026-09-02T00:00:00Z","source":"composition",' +
                '"verificationLevel":"none","toolingPolicy":"existing-tools"}'), $utf8)
        $null = Invoke-NSShiftPolicyArchive -Workspace $sameDay -Date $today
    }
    $todayFirst = Join-Path $archiveBase $today
    $todaySecond = Join-Path $archiveBase ($today + '-shift-2')
    Expect-True (Test-Path -LiteralPath (Join-Path $todayFirst 'shift-policy.json')) 'the first policy files into the date folder'
    Expect-True (Test-Path -LiteralPath (Join-Path $todaySecond 'shift-policy.json')) 'the second policy files into -shift-2'
}
finally {
    Remove-Item -LiteralPath $sameDay -Recurse -Force -ErrorAction SilentlyContinue
}

# A shift in the current layout is filed into its own folder laid out like the live site, the same
# way the POSIX helper files it.
$mirror = Join-Path ([IO.Path]::GetTempPath()) ('ns-archive-mirror-' + [guid]::NewGuid().ToString('N'))
try {
    $utf8 = New-Object Text.UTF8Encoding($false)
    $dash = [string][char]0x2014
    $rulesTemplate = Join-Path $repository 'plugins/nightshift/skills/nightshift/references/nightshift-rules-template.json'
    function Set-EndedShift {
        param([string]$Site, [string]$ShiftId)
        $siteNs = Join-Path $Site '.nightshift'
        $name = Get-NSShiftName (Get-NSLayoutPath $siteNs 'punch-list')
        $claimed = Get-NSArchiveDir -Workspace $Site -Date (Get-Date -Format 'yyyy-MM-dd') -ShiftId $ShiftId -Name $name
        Write-NSEndedRecord -StateDir $siteNs -ShiftId $ShiftId `
            -ArchiveRoot ([string](Get-NSPolicyGroupSetting $Site 'archive.root')['value']) `
            -ArchiveLayout ([string](Get-NSPolicyGroupSetting $Site 'archive.layout')['value']) `
            -ShiftName $name -ArchiveFolder (Split-Path -Leaf $claimed)
    }
    function New-CurrentSite {
        param([string]$Name, [string]$Layout = 'date')
        $site = Join-Path $mirror $Name
        $siteNs = Join-Path $site '.nightshift'
        foreach ($dir in @('receipts', 'inbox', 'run/usage', 'staging')) { $null = New-Item -ItemType Directory -Path (Join-Path $siteNs $dir) -Force }
        [IO.File]::WriteAllText((Join-Path $siteNs 'state-version'), "2`n", $utf8)
        $rules = [IO.File]::ReadAllText($rulesTemplate) -replace '"layout": "date"', ('"layout": "' + $Layout + '"')
        [IO.File]::WriteAllText((Join-Path $siteNs 'rules.json'), $rules, $utf8)
        [IO.File]::WriteAllText((Join-Path $siteNs 'punch-list.md'), ("# Punch List $dash Archive follow-ups`n`n> contract`n`n## Items`n`n" +
            "- [x] **1. Done.** <!-- id: ab12 -->`n  - Verify: x`n- [ ] **2. Open.** <!-- id: cd34 -->`n"), $utf8)
        [IO.File]::WriteAllText((Join-Path $siteNs 'receipts/01-done-ab12.md'),
            "# 1. Done.`n`nSee [snags](../inbox/snag-log.md) and [drafts](../staging/drafting-table.md).`n", $utf8)
        [IO.File]::WriteAllText((Join-Path $siteNs 'receipts/02-open-cd34.md'), "# 2. Open.`n`nhalf way`n", $utf8)
        [IO.File]::WriteAllText((Join-Path $siteNs 'inbox/snag-log.md'),
            "# Snag Log`n`n---`n`n- a bug $dot evidence $dot fixed in abc $dot 2026-09-25`n- an open one $dot evidence $dot 2026-09-25`n", $utf8)
        [IO.File]::WriteAllText((Join-Path $siteNs 'inbox/parking-lot.md'),
            "# Parking Lot`n`n---`n`n- a question $dot default $dot answered: yes $dot 2026-09-25`n", $utf8)
        [IO.File]::WriteAllText((Join-Path $siteNs 'staging/drafting-table.md'), "# Drafting Table`n", $utf8)
        [IO.File]::WriteAllText((Join-Path $siteNs 'run/shift-log.md'), "# Shift Log`n2026-09-25 a line`n", $utf8)
        [IO.File]::WriteAllText((Join-Path $siteNs 'run/usage/marks.tsv'), "arm`tP01`n", $utf8)
        Set-EndedShift $site '1111222233334444'
        return $site
    }
    function Get-FolderListing {
        param([string]$Directory)
        $full = (Get-Item -LiteralPath $Directory -Force).FullName.TrimEnd([char]'/', [char]'\')
        $names = @(Get-ChildItem -LiteralPath $Directory -File -Recurse -Force |
            Where-Object { -not $_.Name.EndsWith('.original.md') } |
            ForEach-Object { $_.FullName.Substring($full.Length).TrimStart([char]'/', [char]'\').Replace('\', '/') })
        return ((Sort-NSOrdinal $names) -join ' ')
    }

    $site = New-CurrentSite 'mirror'
    $siteNs = Join-Path $site '.nightshift'
    $claimed = Join-Path $siteNs ('archive/' + (Get-NSEndedField $site 'archiveFolder'))
    Expect-True ((Get-NSEndedField $site 'shiftName') -ceq 'Archive follow-ups') 'the ending marker records the shift name'
    $run = Invoke-ArchiveReceipts $site
    Expect-True ($run.ExitCode -eq 0) "mirror filing exits 0 (got $($run.ExitCode) $($run.Stderr))"
    Expect-True ((($run.Stdout -split "`n")[0].Trim()) -ceq $claimed) "prints the claimed folder: $($run.Stdout)"
    Expect-True ((Get-FolderListing $claimed) -ceq '.shift-id inbox/parking-lot.md inbox/snag-log.md punch-list.md receipts/01-done-ab12.md receipts/02-open-cd34.md receipts/README.md run/shift-log.md run/usage/marks.tsv') `
        "every record is filed at its live path (got $(Get-FolderListing $claimed))"
    $filedReceipt = [IO.File]::ReadAllText((Join-Path $claimed 'receipts/01-done-ab12.md'))
    Expect-True ($filedReceipt.Contains('[snags](../inbox/snag-log.md)') -and $filedReceipt.Contains('[drafts](../../../staging/drafting-table.md)')) `
        'a filed link reads as written and a live one reaches back'
    Expect-True ((Sort-NSOrdinal @(Get-ChildItem -LiteralPath (Join-Path $siteNs 'receipts') -File | ForEach-Object { $_.Name })) -join ' ' -ceq '02-open-cd34.md README.md') `
        'live receipts keep only the open item'
    $liveSnag = [IO.File]::ReadAllText((Join-Path $siteNs 'inbox/snag-log.md'))
    Expect-True ($liveSnag.Contains(('Filed: [' + (Split-Path -Leaf $claimed) + '](../archive/' + (Split-Path -Leaf $claimed) + '/inbox/snag-log.md)')) -and
        -not $liveSnag.Contains('a bug')) 'the live snag log keeps the open entry and points at the copy'
    Expect-True ([IO.File]::ReadAllText((Join-Path $siteNs 'run/shift-log.md')) -ceq "# Shift Log`n") 'the live shift log starts again'
    Expect-True (-not (Test-Path -LiteralPath (Join-Path $siteNs 'run/usage'))) 'the usage readings leave live storage'

    # Filing again changes nothing and repoints no link twice.
    $before = Get-FolderListing $claimed
    $beforeReceipt = [IO.File]::ReadAllText((Join-Path $claimed 'receipts/01-done-ab12.md'))
    $again = Invoke-ArchiveReceipts $site
    Expect-True ($again.ExitCode -eq 0 -and -not $again.Stderr.Contains('kept in live storage')) "a second filing is quiet: $($again.Stderr)"
    Expect-True ((Get-FolderListing $claimed) -ceq $before -and
        [IO.File]::ReadAllText((Join-Path $claimed 'receipts/01-done-ab12.md')) -ceq $beforeReceipt) 'a second filing changes nothing'

    # A later Archive returns to the claimed folder, whatever the date.
    $later = New-CurrentSite 'later'
    $laterClaimed = Join-Path $later ('.nightshift/archive/' + (Get-NSEndedField $later 'archiveFolder'))
    $laterRun = Invoke-ArchiveReceipts $later @('-Date', '2031-01-01')
    Expect-True ((($laterRun.Stdout -split "`n")[0].Trim()) -ceq $laterClaimed -and
        -not (Test-Path -LiteralPath (Join-Path $later '.nightshift/archive/2031-01-01'))) 'a later filing returns to the claimed folder'

    # Named layouts, a second shift under the same name, and a shift with no name.
    foreach ($layout in @('name', 'date-name')) {
        $named = New-CurrentSite ('named-' + $layout) $layout
        $first = Get-NSEndedField $named 'archiveFolder'
        $want = $(if ($layout -ceq 'name') { 'archive-follow-ups' } else { (Get-Date -Format 'yyyy-MM-dd') + '-archive-follow-ups' })
        Expect-True ($first -ceq $want) "the $layout layout names the folder (got $first)"
        Set-EndedShift $named '5555666677778888'
        Expect-True ((Get-NSEndedField $named 'archiveFolder') -ceq ($first + '-shift-2')) "a second shift under the same name takes -shift-2 ($layout)"
    }
    $unnamed = New-CurrentSite 'named-none' 'date-name'
    [IO.File]::WriteAllText((Join-Path $unnamed '.nightshift/punch-list.md'), "# Punch List`n`n## Items`n", $utf8)
    Set-EndedShift $unnamed '9999000011112222'
    Expect-True ((Get-NSEndedField $unnamed 'archiveFolder') -ceq (Get-Date -Format 'yyyy-MM-dd')) 'a shift with no name files by date'

    # A usage folder a Start set aside goes to the folder of the shift it belongs to.
    $usageSite = New-CurrentSite 'usage'
    $usageNs = Join-Path $usageSite '.nightshift'
    foreach ($dir in @('archive/2026-09-20', 'run/usage-4444555566667777', 'run/usage-unknown')) {
        $null = New-Item -ItemType Directory -Path (Join-Path $usageNs $dir) -Force
    }
    [IO.File]::WriteAllText((Join-Path $usageNs 'archive/2026-09-20/.shift-id'), "4444555566667777`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $usageNs 'run/usage-4444555566667777/marks.tsv'), "theirs`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $usageNs 'run/usage-unknown/marks.tsv'), "nobody knows`n", $utf8)
    $usageRun = Invoke-ArchiveReceipts $usageSite
    $usageClaimed = ($usageRun.Stdout -split "`n")[0].Trim()
    Expect-True ((Get-TextOrEmpty (Join-Path $usageNs 'archive/2026-09-20/run/usage/marks.tsv')) -ceq "theirs`n") 'a set-aside folder joins its own shift'
    Expect-True ((Get-TextOrEmpty (Join-Path $usageClaimed 'run/usage-unknown/marks.tsv')) -ceq "nobody knows`n") 'one nobody can place stays with this shift'
    Expect-True (-not (Test-Path -LiteralPath (Join-Path $usageNs 'run/usage-4444555566667777')) -and
        -not (Test-Path -LiteralPath (Join-Path $usageNs 'run/usage-unknown'))) 'both leave live storage'

    # The ended shift's policy still live is filed; the next shift's is left where it is.
    $policySite = New-CurrentSite 'policy'
    [IO.File]::WriteAllText((Join-Path $policySite '.nightshift/run/shift-policy.json'),
        '{"schemaVersion":1,"shiftId":"1111222233334444","createdAt":"2026-09-25T00:00:00Z","source":"composition","verificationLevel":"none","toolingPolicy":"existing-tools"}', $utf8)
    $policyRun = Invoke-ArchiveReceipts $policySite
    $policyClaimed = ($policyRun.Stdout -split "`n")[0].Trim()
    Expect-True ((Test-Path -LiteralPath (Join-Path $policyClaimed 'run/shift-policy.json')) -and
        -not (Test-Path -LiteralPath (Join-Path $policySite '.nightshift/run/shift-policy.json'))) "the ended shift's live policy is filed"
    $nextSite = New-CurrentSite 'next'
    [IO.File]::WriteAllText((Join-Path $nextSite '.nightshift/run/shift-policy.json'),
        '{"schemaVersion":1,"shiftId":"aaaabbbbccccdddd","createdAt":"2026-09-26T00:00:00Z","source":"composition","verificationLevel":"none","toolingPolicy":"existing-tools"}', $utf8)
    $nextRun = Invoke-ArchiveReceipts $nextSite
    $nextClaimed = ($nextRun.Stdout -split "`n")[0].Trim()
    Expect-True ((Test-Path -LiteralPath (Join-Path $nextSite '.nightshift/run/shift-policy.json')) -and
        -not (Test-Path -LiteralPath (Join-Path $nextClaimed 'run/shift-policy.json')) -and
        ([IO.File]::ReadAllText((Join-Path $nextClaimed '.shift-id'))).Trim() -ceq '1111222233334444') "the next shift's policy stays live"

    # A second clock-out of a shift appends its findings to the ones already filed.
    $findingsSite = New-CurrentSite 'findings'
    $null = New-Item -ItemType Directory -Path (Join-Path $findingsSite '.nightshift/run/evidence') -Force
    foreach ($record in @('one', 'two')) {
        [IO.File]::WriteAllText((Join-Path $findingsSite '.nightshift/run/evidence/findings.jsonl'), ('{"record":"' + $record + '"}' + "`n"), $utf8)
        $null = Invoke-NSEvidenceArchive -Workspace $findingsSite -ShiftId '1111222233334444'
    }
    $findingsClaimed = Join-Path $findingsSite ('.nightshift/archive/' + (Get-NSEndedField $findingsSite 'archiveFolder'))
    Expect-True ((Get-TextOrEmpty (Join-Path $findingsClaimed 'run/evidence/findings.jsonl')) -ceq ('{"record":"one"}' + "`n" + '{"record":"two"}' + "`n")) `
        'findings filed twice keep both records'
}
finally {
    Remove-Item -LiteralPath $mirror -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures.Count -gt 0) {
    Write-Host "archive-receipts-logic failed ($($failures.Count)):"
    foreach ($failure in $failures) {
        Write-Host " - $failure"
    }
    exit 1
}
Write-Host 'archive-receipts logic passed'
exit 0
