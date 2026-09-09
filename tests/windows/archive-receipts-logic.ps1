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
    $dest = $ok.Stdout.Trim()
    Expect-True ($dest -match [regex]::Escape((Join-Path $ns 'archive/2026-08-28/receipts'))) `
        'prints the dated archive receipts path'
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
        $skipDest = $skipLink.Stdout.Trim()
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
        "# Snag Log`n`n- leak · tests/x.bats · fixed · 2026-09-09`n- still open · looking`n")
    [IO.File]::WriteAllText((Join-Path $ns 'parking-lot.md'), "# Parking Lot`n`n- wait for the owner`n")
    $one = Invoke-ArchiveReceipts $review @('-Date', '2026-09-09')
    Expect-True ($one.ExitCode -eq 0) "review file exits 0 (got $($one.ExitCode) $($one.Stderr))"
    $snagDest = Join-Path $ns 'archive/2026-09-09/aaaa1111bbbb2222/snag-log.md'
    Expect-True (Test-Path -LiteralPath $snagDest -PathType Leaf) 'handled snag is filed'
    Expect-True (-not (Test-Path -LiteralPath (Join-Path $ns 'archive/2026-09-09/aaaa1111bbbb2222/parking-lot.md'))) `
        'unanswered parking is not filed'
    $liveSnag = [IO.File]::ReadAllText((Join-Path $ns 'snag-log.md'))
    Expect-True ($liveSnag.Contains('Filed: [2026-09-09](archive/2026-09-09/aaaa1111bbbb2222/snag-log.md)')) `
        'one pointer names the dest relative to the live file'
    Expect-True ($liveSnag.Contains('still open · looking')) 'unresolved snag stays live'
    Expect-True (-not $liveSnag.Contains('leak ·')) 'filed snag leaves the live file'
    $again = Invoke-ArchiveReceipts $review @('-Date', '2026-09-09')
    Expect-True ($again.ExitCode -eq 0) "retry exits 0 (got $($again.ExitCode))"
    $liveSnag = [IO.File]::ReadAllText((Join-Path $ns 'snag-log.md'))
    Expect-True (([regex]::Matches($liveSnag, '(?m)^Filed:').Count) -eq 1) `
        'retry does not duplicate the pointer'

    [IO.File]::WriteAllText((Join-Path $ns 'snag-log.md'),
        "# Snag Log`n`nFiled: [2026-09-09](archive/missing/snag-log.md)`n")
    $broken = Invoke-ArchiveReceipts $review @('-Date', '2026-09-09')
    Expect-True ($broken.ExitCode -eq 0) "broken pointer exits 0 (got $($broken.ExitCode))"
    Expect-True ([IO.File]::ReadAllText((Join-Path $ns 'snag-log.md')).Contains(
        'broken archive pointer · archive/missing/snag-log.md is not a readable file')) `
        'a broken pointer is reported in the snag log'
}
finally {
    Remove-Item -LiteralPath $review -Recurse -Force -ErrorAction SilentlyContinue
}

# A shift that ended with work still open. The receipt of a ticked item is filed and retired; the
# receipt of an item nobody finished stays live, and each index lists only what its folder holds.
$openWork = Join-Path ([IO.Path]::GetTempPath()) ("ns-archive-open-" + [guid]::NewGuid().ToString('N'))
try {
    $ns = Join-Path $openWork '.nightshift'
    $recv = Join-Path $ns 'receipts'
    $null = New-Item -ItemType Directory -Path $recv -Force
    [IO.File]::WriteAllText((Join-Path $ns 'work-mode'), "artifact`n")
    [IO.File]::WriteAllText((Join-Path $ns 'punch-list.md'), ("Date: 2026-09-05`n`n## Items`n" +
        "- [x] **1. Fix the resolver.**`n- [x] **2. Cover the parser.**`n- [ ] **3. Trim the bundle.**`n"))
    [IO.File]::WriteAllText((Join-Path $recv '1-fix-the-resolver.md'), ("# 1. Fix the resolver.`n`nDone.`n`n" +
        "**Usage:** input 100 · output 20`n" +
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

    $filed = Invoke-ArchiveReceipts $openWork @('-Date', '2026-09-05',
        '-Retire', '1-fix-the-resolver.md,2-cover-the-parser.md,morning-2026-09-05-abc.md')
    Expect-True ($filed.ExitCode -eq 0) "open-work filing exits 0 (got $($filed.ExitCode) $($filed.Stderr))"
    $dest = Join-Path $ns 'archive/2026-09-05/receipts'
    foreach ($name in @('1-fix-the-resolver.md', '2-cover-the-parser.md', 'morning-2026-09-05-abc.md')) {
        Expect-True (Test-Path -LiteralPath (Join-Path $dest $name) -PathType Leaf) "files the closed record $name"
        Expect-True (-not (Test-Path -LiteralPath (Join-Path $recv $name))) "retires the closed record $name"
    }
    Expect-True (-not (Test-Path -LiteralPath (Join-Path $dest '3-trim-the-bundle.md'))) `
        'does not file the receipt of an open item'
    Expect-True (Test-Path -LiteralPath $liveOpen -PathType Leaf) 'leaves the open item receipt live'
    Expect-True ($openBefore -ceq [Convert]::ToBase64String([IO.File]::ReadAllBytes($liveOpen))) `
        'the open item receipt is byte-identical'
    $liveIndex = [IO.File]::ReadAllText((Join-Path $recv 'README.md'))
    Expect-True ($liveIndex.Contains('| 3. Trim the bundle. | open |')) 'the live index lists the open item'
    Expect-True (-not $liveIndex.Contains('Fix the resolver')) 'the live index drops a filed receipt'
    $archivedIndex = [IO.File]::ReadAllText((Join-Path $dest 'README.md'))
    Expect-True ($archivedIndex.Contains('# Receipts — 2026-09-05')) 'the archived index is dated'
    Expect-True ($archivedIndex.Contains(
        '| 1. Fix the resolver. | ticked | **120** | **10m 00s** | [./1-fix-the-resolver.md](./1-fix-the-resolver.md) |')) `
        'the archived index carries the first receipt with its measurements'
    Expect-True ($archivedIndex.Contains('| 2. Cover the parser. | ticked |')) `
        'the archived index carries the second receipt'
    Expect-True (-not $archivedIndex.Contains('Trim the bundle')) 'the archived index omits the open item'
    Expect-True (-not $archivedIndex.Contains('morning-2026-09-05-abc.md')) `
        'the archived index omits the morning receipt'
}
finally {
    Remove-Item -LiteralPath $openWork -Recurse -Force -ErrorAction SilentlyContinue
}

# Receipts link to each other by bare name, because they were written side by side. Filed, the ones
# that travelled together are still side by side; the receipt of an item nobody finished stayed
# behind and has to be reached back through the archive.
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

    # The open item's receipt stayed live, so the link reaches back out of the archive to it.
    Expect-True ($first.Contains('(../../../receipts/3-trim-the-bundle.md)')) `
        'the open item receipt is reached back through the archive'
    Expect-True (Test-Path -LiteralPath (Join-Path $dest '../../../receipts/3-trim-the-bundle.md') -PathType Leaf) `
        'the live open item receipt resolves from the archived receipt'
    # And a link that already climbed out of receipts/ climbed from there, not from the archive.
    Expect-True ($first.Contains('(../../../parking-lot.md)')) 'a climbing link climbed from receipts/'
    Expect-True (Test-Path -LiteralPath (Join-Path $dest '../../../parking-lot.md') -PathType Leaf) `
        'the live parking lot resolves from the archived receipt'
}
finally {
    Remove-Item -LiteralPath $siblings -Recurse -Force -ErrorAction SilentlyContinue
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
