[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$Project = [Environment]::CurrentDirectory,
    [switch]$Fetch,
    [switch]$Stage,
    [switch]$ListProposed,
    [switch]$Promote,
    [string]$Repo = '',
    [string]$AuthorizedRepo = '',
    [switch]$AllowClosed,
    [switch]$AllowFlagged,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Specs = @()
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if (Test-Path Variable:PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $false
}

$pluginRoot = Resolve-Path (Join-Path $PSScriptRoot '../..')
Import-Module (Join-Path $pluginRoot 'lib/Nightshift.psm1') -Force -DisableNameChecking

$modeCount = @($Fetch, $Stage, $ListProposed, $Promote) | Where-Object { $_ } | Measure-Object
if ($modeCount.Count -gt 1) {
    [Console]::Error.WriteLine('import-issues: choose one of -Fetch, -Stage, -ListProposed, -Promote')
    exit 1
}
$mode = 'fetch'
if ($Stage) { $mode = 'stage' }
elseif ($ListProposed) { $mode = 'list-proposed' }
elseif ($Promote) { $mode = 'promote' }

try {
    $hostPath = Resolve-NSCanonicalPath $Project
}
catch {
    [Console]::Error.WriteLine("import-issues: cannot cd to $Project")
    exit 1
}
try {
    $workspace = Resolve-NSWorkspaceRoot $hostPath
}
catch {
    [Console]::Error.WriteLine('import-issues: invalid .nightshift-link')
    exit 2
}

$ns = Join-Path $workspace '.nightshift'
$draft = Get-NSLayoutPath $ns 'drafting-table'
$punch = Get-NSLayoutPath $ns 'punch-list'

function Parse-NSIssueSpec {
    param([string]$Spec)
    $spec = $Spec.Trim()
    if ([string]::IsNullOrEmpty($spec)) { return $null }
    $spec = $spec -replace '^https://', '' -replace '^http://', '' -replace '^www\.', ''
    $owner = ''
    $repoName = ''
    $num = ''
    if ($spec -like 'github.com/*') {
        $rest = $spec.Substring('github.com/'.Length)
        $parts = $rest.Split('/')
        if ($parts.Count -lt 4 -or $parts[2] -ne 'issues') { return $null }
        $owner = $parts[0]
        $repoName = $parts[1]
        $num = ($parts[3] -replace '[^0-9].*', '')
    }
    elseif ($spec -match '^([^/]+)/([^#]+)#([0-9]+)') {
        $owner = $Matches[1]
        $repoName = $Matches[2]
        $num = $Matches[3]
        if ($repoName.Contains('/')) { return $null }
    }
    else {
        return $null
    }
    if ($owner -notmatch '^[A-Za-z0-9._-]+$' -or $repoName -notmatch '^[A-Za-z0-9._-]+$' -or $num -notmatch '^[0-9]+$') {
        return $null
    }
    return [pscustomobject]@{
        Owner = $owner
        Repo = $repoName
        Number = $num
        Canonical = "https://github.com/$owner/$repoName/issues/$num"
    }
}

function Get-NSIssueFlags {
    param([string]$Title, [string]$Body)
    $blob = ($Title + "`n" + $Body).ToLowerInvariant()
    $flags = New-Object Collections.Generic.List[string]
    if ($blob -match 'rm\s+-rf|drop\s+table|format\s+.*disk|delete\s+all\s+(files|data)|wipe\s+disk') {
        $null = $flags.Add('destructive')
    }
    if ($blob -match 'exfiltrat|dump\s+(the\s+)?(secrets?|credentials?|tokens?)|printenv|steal\s+.*(password|secret|token)|api[_-]?key|private\s+key') {
        $null = $flags.Add('secret-seeking')
    }
    if ($blob -match 'git\s+push|npm\s+publish|deploy\s+to\s+prod|publish\s+to\s+(pypi|npm)') {
        $null = $flags.Add('publishing')
    }
    if ($blob -match 'credit\s+card|wire\s+transfer|send\s+money') {
        $null = $flags.Add('payment')
    }
    if ($blob -match 'relicense|change\s+the\s+license|assign\s+copyright|contributor\s+license\s+agreement') {
        $null = $flags.Add('legal')
    }
    if ([string]::IsNullOrEmpty($Body) -or $blob -match 'not sure what|maybe we should|consider whether|^tbd$') {
        $null = $flags.Add('ambiguous')
    }
    if ($flags.Count -eq 0) { return 'none' }
    return ($flags -join ',')
}

function Convert-NSIssueTitle {
    param([string]$Title)
    return (($Title -replace '[\n\r]', ' ' -replace '\*\*', '').Trim())
}

function Convert-NSQuotedBody {
    param([string]$Body)
    $text = ($Body -replace "`r", '' -replace '```', "'''")
    if ($text.Length -gt 4000) {
        $text = $text.Substring(0, 4000) + "`n... truncated"
    }
    if ([string]::IsNullOrEmpty($text)) {
        return "    > (empty issue body)"
    }
    $quoted = foreach ($line in ($text -split "`n", -1)) {
        "    > $line"
    }
    return ($quoted -join "`n")
}

function Test-NSIssueKnown {
    param([string]$Url)
    foreach ($path in @($draft, $punch)) {
        if ((Test-Path -LiteralPath $path -PathType Leaf) -and ([IO.File]::ReadAllText($path).Contains($Url))) {
            return $true
        }
    }
    $archive = Get-NSLayoutPath $ns 'archive'
    if (-not (Test-Path -LiteralPath $archive -PathType Container) -or (Test-NSReparsePoint $archive)) {
        return $false
    }
    foreach ($file in @(Get-ChildItem -LiteralPath $archive -File -Filter '*.md' -ErrorAction SilentlyContinue)) {
        if ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
        if ([IO.File]::ReadAllText($file.FullName).Contains($Url)) {
            return $true
        }
    }
    foreach ($dir in @(Get-ChildItem -LiteralPath $archive -Directory -ErrorAction SilentlyContinue)) {
        if ($dir.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
        foreach ($file in @(Get-ChildItem -LiteralPath $dir.FullName -File -Filter '*.md' -ErrorAction SilentlyContinue)) {
            if ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
            if ([IO.File]::ReadAllText($file.FullName).Contains($Url)) {
                return $true
            }
        }
    }
    return $false
}

function Split-NSDraftItems {
    param([string]$Text)
    $itemRe = [regex]::new('(?m)^- \[ \] \*\*.+\*\*\s*$')
    $matches = @($itemRe.Matches($Text))
    if ($matches.Count -eq 0) {
        return @{ Head = $Text; Items = @() }
    }
    $head = $Text.Substring(0, $matches[0].Index)
    $items = New-Object Collections.Generic.List[string]
    for ($i = 0; $i -lt $matches.Count; $i++) {
        $end = if ($i + 1 -lt $matches.Count) { $matches[$i + 1].Index } else { $Text.Length }
        $null = $items.Add($Text.Substring($matches[$i].Index, $end - $matches[$i].Index))
    }
    return @{ Head = $head; Items = @($items) }
}

function Convert-NSImportedBlock {
    param([string]$Block)
    if ($Block -notmatch '(?m)^\s*- Status: proposed\s*$') { return $null }
    $sm = [regex]::Match($Block, '(?m)^\s*- Source: (https://github.com/[^/\s]+/[^/\s]+/issues/\d+)\s*$')
    if (-not $sm.Success) { return $null }
    $rm = [regex]::Match($Block, '(?m)^\s*- Repository: (\S+)\s*$')
    $fm = [regex]::Match($Block, '(?m)^\s*- Review flags: (.+?)\s*$')
    $first = ($Block -split "`n")[0]
    $tm = [regex]::Match($first, '^- \[ \] \*\*(.+)\.\*\*\s*$')
    return [pscustomobject]@{
        Block = $Block
        Url = $sm.Groups[1].Value
        Repo = $(if ($rm.Success) { $rm.Groups[1].Value } else { '' })
        Flags = $(if ($fm.Success) { $fm.Groups[1].Value.Trim() } else { 'none' })
        Title = $(if ($tm.Success) { $tm.Groups[1].Value } else { '' })
    }
}

function Get-NSCanonicalSpecs {
    $parsed = New-Object 'System.Collections.Generic.List[psobject]'
    if (-not [string]::IsNullOrEmpty($Repo)) {
        if ($null -eq $Specs -or $Specs.Count -eq 0) {
            [Console]::Error.WriteLine('import-issues: -Repo requires explicit issue numbers. Nightshift never lists a repository.')
            exit 1
        }
        foreach ($spec in $Specs) {
            if ($spec -notmatch '^[0-9]+$') {
                [Console]::Error.WriteLine("import-issues: with -Repo, arguments must be issue numbers (got $spec)")
                exit 1
            }
            $row = Parse-NSIssueSpec "$Repo#$spec"
            if ($null -eq $row) {
                [Console]::Error.WriteLine("import-issues: cannot parse -Repo $Repo issue $spec")
                exit 1
            }
            $null = $parsed.Add($row)
        }
    }
    else {
        foreach ($spec in @($Specs)) {
            $row = Parse-NSIssueSpec $spec
            if ($null -eq $row) {
                [Console]::Error.WriteLine("import-issues: not an explicit GitHub issue: $spec")
                exit 1
            }
            $null = $parsed.Add($row)
        }
    }
    $seen = @{}
    $unique = New-Object 'System.Collections.Generic.List[psobject]'
    foreach ($row in $parsed) {
        if ($seen.ContainsKey($row.Canonical)) { continue }
        $seen[$row.Canonical] = $true
        $null = $unique.Add($row)
    }
    return @($unique)
}

function Assert-NSGhReady {
    $gh = Get-Command gh -ErrorAction SilentlyContinue
    if ($null -eq $gh) {
        [Console]::Error.WriteLine('import-issues: gh is not installed. Install the GitHub CLI yourself and run gh auth login. Nightshift will not install it.')
        exit 2
    }
    & gh auth status 1>$null 2>$null
    if ($LASTEXITCODE -ne 0) {
        [Console]::Error.WriteLine('import-issues: gh is not authenticated. Run gh auth login and retry. No files were changed.')
        exit 2
    }
}

if ($mode -eq 'list-proposed' -or $mode -eq 'promote') {
    if (-not (Test-Path -LiteralPath $ns -PathType Container)) {
        [Console]::Error.WriteLine('import-issues: no .nightshift/ - run setup first')
        exit 2
    }
    if (-not (Test-Path -LiteralPath $draft -PathType Leaf)) {
        [Console]::Error.WriteLine('import-issues: missing drafting-table.md - run setup first. No files were changed.')
        exit 2
    }
    if (-not [string]::IsNullOrEmpty($AuthorizedRepo) -and $AuthorizedRepo -notmatch '^[^/]+/[^/]+$') {
        [Console]::Error.WriteLine('import-issues: -AuthorizedRepo must be owner/repo')
        exit 1
    }
    $text = [IO.File]::ReadAllText($draft)
    $split = Split-NSDraftItems $text
    $imported = New-Object 'System.Collections.Generic.List[psobject]'
    $other = New-Object Collections.Generic.List[string]
    foreach ($block in @($split.Items)) {
        $info = Convert-NSImportedBlock $block
        if ($null -ne $info) { $null = $imported.Add($info) } else { $null = $other.Add($block) }
    }
    if ($mode -eq 'list-proposed') {
        foreach ($info in $imported) {
            if ([string]::IsNullOrEmpty($AuthorizedRepo) -or $info.Repo -eq $AuthorizedRepo) {
                Write-Output ("{0}`t{1}`t{2}`t{3}" -f $info.Url, $info.Repo, $info.Flags, $info.Title)
            }
        }
        exit 0
    }
    if (-not (Test-Path -LiteralPath $punch -PathType Leaf)) {
        [Console]::Error.WriteLine('import-issues: missing punch-list.md - run setup first. No files were changed.')
        exit 2
    }
    if (($null -eq $Specs -or $Specs.Count -eq 0) -and [string]::IsNullOrEmpty($Repo)) {
        [Console]::Error.WriteLine('import-issues: name explicit issue URLs to promote. Nightshift never searches.')
        exit 1
    }
    $urls = @(Get-NSCanonicalSpecs | ForEach-Object { $_.Canonical })
    if ($urls.Count -eq 0) {
        [Console]::Error.WriteLine('import-issues: nothing to promote')
        exit 1
    }
    $punchText = [IO.File]::ReadAllText($punch)
    if ($punchText -notmatch '## Items') {
        [Console]::Error.WriteLine('import-issues: punch list has no ## Items heading')
        exit 2
    }
    $byUrl = @{}
    foreach ($info in $imported) { $byUrl[$info.Url] = $info }
    $chosen = New-Object 'System.Collections.Generic.List[psobject]'
    foreach ($url in $urls) {
        if (-not $byUrl.ContainsKey($url)) {
            [Console]::Error.WriteLine("import-issues: not a proposed imported issue: $url")
            exit 2
        }
        $info = $byUrl[$url]
        if (-not [string]::IsNullOrEmpty($AuthorizedRepo) -and $info.Repo -ne $AuthorizedRepo) {
            [Console]::Error.WriteLine("import-issues: $url is outside the authorized repository")
            exit 2
        }
        if ($info.Flags -ne 'none' -and -not $AllowFlagged) {
            [Console]::Error.WriteLine("import-issues: refuse flagged issue $url ($($info.Flags))")
            exit 2
        }
        if ($punchText.Contains($info.Url)) {
            [Console]::Error.WriteLine("import-issues: already on the punch list: $url")
            exit 2
        }
        $null = $chosen.Add($info)
    }
    if ($chosen.Count -eq 0) {
        [Console]::Error.WriteLine('import-issues: nothing to promote')
        exit 1
    }
    $chosenUrls = @($chosen | ForEach-Object { $_.Url })
    $remain = @($imported | Where-Object { $_.Url -notin $chosenUrls } | ForEach-Object { $_.Block })
    $newDraft = $split.Head + ($other -join '') + ($remain -join '')
    $moved = ($chosen | ForEach-Object { $_.Block.TrimEnd() + "`n`n" }) -join ''
    if (-not $punchText.EndsWith("`n")) { $punchText += "`n" }
    $newPunch = $punchText + "`n" + $moved
    $draftNext = "$draft.next"
    $punchNext = "$punch.next"
    $draftBackup = Join-Path (Split-Path -Parent $draft) ('.drafting-table.md.rollback.{0}' -f $PID)
    $punchBackup = Join-Path (Split-Path -Parent $punch) ('.punch-list.md.rollback.{0}' -f $PID)
    try {
        [IO.File]::WriteAllText($draftNext, $newDraft, (New-Object Text.UTF8Encoding $false))
        [IO.File]::WriteAllText($punchNext, $newPunch, (New-Object Text.UTF8Encoding $false))
        Copy-Item -LiteralPath $draft -Destination $draftBackup -Force
        Copy-Item -LiteralPath $punch -Destination $punchBackup -Force
        Move-Item -LiteralPath $punchNext -Destination $punch -Force
        try {
            Move-Item -LiteralPath $draftNext -Destination $draft -Force
        }
        catch {
            Copy-Item -LiteralPath $punchBackup -Destination $punch -Force
            Copy-Item -LiteralPath $draftBackup -Destination $draft -Force
            [Console]::Error.WriteLine('import-issues: could not update the drafting table. Both live queues were restored.')
            exit 2
        }
    }
    catch {
        Remove-NSFile $draftNext
        Remove-NSFile $punchNext
        [Console]::Error.WriteLine('import-issues: could not update the punch list. Both live queues are unchanged.')
        exit 2
    }
    finally {
        Remove-NSFile $draftBackup
        Remove-NSFile $punchBackup
        Remove-NSFile $draftNext
        Remove-NSFile $punchNext
    }
    Write-Output ("Promoted {0} issue(s) into the punch list. Removed from the drafting table." -f $chosen.Count)
    exit 0
}

if (($null -eq $Specs -or $Specs.Count -eq 0) -and [string]::IsNullOrEmpty($Repo)) {
    [Console]::Error.WriteLine('import-issues: name explicit issue URLs or -Repo owner/repo plus issue numbers. Nightshift never searches.')
    exit 1
}

$rows = @(Get-NSCanonicalSpecs)
if ($rows.Count -eq 0) {
    [Console]::Error.WriteLine('import-issues: nothing to fetch')
    exit 1
}

if ($mode -eq 'stage') {
    if (-not (Test-Path -LiteralPath $ns -PathType Container)) {
        [Console]::Error.WriteLine('import-issues: no .nightshift/ - run setup first')
        exit 2
    }
    if (-not (Test-Path -LiteralPath $draft -PathType Leaf)) {
        [Console]::Error.WriteLine('import-issues: missing drafting-table.md - run setup first. No files were changed.')
        exit 2
    }
}

Assert-NSGhReady

$fail = $false
$issues = New-Object 'System.Collections.Generic.List[psobject]'
foreach ($row in $rows) {
    $json = & gh issue view $row.Number --repo "$($row.Owner)/$($row.Repo)" --json title,body,labels,state,number,url 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($json)) {
        [Console]::Error.WriteLine("import-issues: failed to read $($row.Canonical)")
        $fail = $true
        continue
    }
    try {
        $obj = $json | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        [Console]::Error.WriteLine("import-issues: failed to read $($row.Canonical)")
        $fail = $true
        continue
    }
    if ($null -eq $obj -or [string]::IsNullOrEmpty([string]$obj.title) -or $null -eq $obj.number -or [string]::IsNullOrEmpty([string]$obj.url)) {
        [Console]::Error.WriteLine("import-issues: failed to read $($row.Canonical)")
        $fail = $true
        continue
    }
    $null = $issues.Add([pscustomobject]@{ Row = $row; Json = $obj })
}

if ($issues.Count -eq 0) {
    [Console]::Error.WriteLine('import-issues: no issues could be read. No files were changed.')
    exit 2
}

$importedAt = [string]$env:NIGHTSHIFT_IMPORT_TIME
if ([string]::IsNullOrEmpty($importedAt)) {
    $importedAt = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
}

$blocks = New-Object Collections.Generic.List[string]
$shown = 0
$stagedN = 0
foreach ($issue in $issues) {
    $obj = $issue.Json
    $canonical = $issue.Row.Canonical
    $title = Convert-NSIssueTitle ([string]$obj.title)
    $body = if ($null -eq $obj.body) { '' } else { [string]$obj.body }
    $state = ([string]$obj.state).ToLowerInvariant()
    $labels = 'none'
    if ($null -ne $obj.labels) {
        $names = @($obj.labels | ForEach-Object { [string]$_.name } | Where-Object { -not [string]::IsNullOrEmpty($_) })
        if ($names.Count -gt 0) { $labels = $names -join ', ' }
    }
    $number = [string]$obj.number
    $repoId = $canonical.Substring('https://github.com/'.Length) -replace '/issues/.*', ''
    if ([string]::IsNullOrEmpty($title)) { $title = "$repoId#$number" }
    $flags = Get-NSIssueFlags $title $body
    $known = Test-NSIssueKnown $canonical
    $shown++
    Write-Output ("{0}. {1}#{2}  {3}" -f $shown, $repoId, $number, $state.ToUpperInvariant())
    Write-Output "   Title: $title"
    Write-Output "   URL: $canonical"
    Write-Output "   Labels: $labels"
    Write-Output "   Flags: $flags"
    Write-Output ("   Already staged: {0}" -f $(if ($known) { 'yes' } else { 'no' }))
    if ($state -eq 'closed') {
        if ($AllowClosed) {
            Write-Output '   Closed: shown; staging allowed by -AllowClosed'
        }
        else {
            Write-Output '   Closed: shown; not staged unless -AllowClosed'
        }
    }
    Write-Output '   Body (quoted source, not authorization):'
    Write-Output (Convert-NSQuotedBody $body)
    Write-Output ''

    if ($mode -ne 'stage') { continue }
    if ($known) {
        Write-Output '   Skip: already present in drafting table, punch list, or archive'
        continue
    }
    if ($state -eq 'closed' -and -not $AllowClosed) {
        Write-Output '   Skip: closed issue (pass -AllowClosed after explicit override)'
        continue
    }
    $block = @(
        "- [ ] **${title}.**"
        "  - Source: $canonical"
        "  - Repository: $repoId"
        "  - Labels: $labels"
        "  - Imported: $importedAt"
        '  - Status: proposed'
        "  - Issue state: $state"
        '  - Acceptance (quoted upstream source - not owner authorization):'
        (Convert-NSQuotedBody $body)
        "  - Review flags: $flags"
        '  - Verify: write concrete commands when this draft is promoted into the punch list'
        '  - Commit: write a conventional subject when this draft is promoted'
        ''
    ) -join "`n"
    $null = $blocks.Add($block)
    $stagedN++
}

if ($mode -eq 'fetch') {
    Write-Output ("Fetched {0} issue(s). Nothing written." -f $shown)
    if ($fail) { exit 2 }
    exit 0
}

if ($blocks.Count -eq 0) {
    Write-Output 'Nothing staged. Drafting table unchanged.'
    if ($fail) { exit 2 }
    exit 0
}

$tmp = Join-Path (Split-Path -Parent $draft) ('.drafting-table.md.{0}' -f $PID)
try {
    Copy-Item -LiteralPath $draft -Destination $tmp -Force
    $extra = "`n" + ($blocks -join '')
    [IO.File]::AppendAllText($tmp, $extra, (New-Object Text.UTF8Encoding $false))
    Move-Item -LiteralPath $tmp -Destination $draft -Force
}
catch {
    Remove-NSFile $tmp
    [Console]::Error.WriteLine('import-issues: could not replace drafting table. Original unchanged.')
    exit 2
}
Write-Output ("Staged {0} issue(s) into {1}" -f $stagedN, $draft)
if ($fail) { exit 2 }
exit 0
