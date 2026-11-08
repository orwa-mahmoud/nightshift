# evidence-check.ps1 - whether a ticked item's named evidence is present.
# Mirrors lib/evidence-check.sh. check off asks for nothing. report and block name what is missing.
# block is the only one the clock-out gate treats as open.

. (Join-Path $PSScriptRoot 'catalog-sources.ps1')

function Get-NSEvidenceItemLine {
    param([Parameter(Mandatory = $true)][string]$PunchList, [Parameter(Mandatory = $true)][string]$Label)
    $inside = $false
    foreach ($line in (Get-NSPunchItemsSection $PunchList)) {
        if ($line -cmatch '^- \[[ xX-]\]') {
            $inside = ((Get-NSItemLabel $line) -ceq $Label)
            continue
        }
        if ($line -cmatch '^\S') { $inside = $false; continue }
        if ($inside -and $line -cmatch '^[ \t]+-[ \t]+Evidence:[ \t]*(.*)$') { return $Matches[1] }
    }
    return ''
}

function Get-NSEvidenceLineValue {
    param([AllowEmptyString()][string]$Line, [Parameter(Mandatory = $true)][string]$Key)
    foreach ($word in ($Line -split '\s+')) {
        if ($word -ceq ($Key + ':')) { continue }
        if ($word.StartsWith($Key + ':')) { return $word.Substring($Key.Length + 1) }
    }
    $words = @($Line -split '\s+')
    for ($i = 0; $i -lt $words.Count; $i++) {
        if ($words[$i] -ceq ($Key + ':') -and ($i + 1) -lt $words.Count) { return $words[$i + 1] }
    }
    return ''
}

function Get-NSEvidenceKinds {
    param([AllowEmptyString()][string]$Line)
    $found = New-Object Collections.Generic.List[string]
    $words = @($Line -split '\s+')
    for ($i = 0; $i -lt $words.Count; $i++) {
        $value = ''
        if ($words[$i] -ceq 'kind:' -and ($i + 1) -lt $words.Count) { $value = $words[$i + 1] }
        elseif ($words[$i].StartsWith('kind:')) { $value = $words[$i].Substring(5) }
        if ($value -cmatch '^[a-z0-9]+(-[a-z0-9]+)*$') { $found.Add($value) }
    }
    return $found.ToArray()
}

function Get-NSEvidenceFiles {
    param([AllowEmptyString()][string]$Line)
    $found = New-Object Collections.Generic.List[string]
    $matches = [regex]::Matches($Line, '`([^`]*)`')
    foreach ($one in $matches) {
        $name = $one.Groups[1].Value
        if ([string]::IsNullOrEmpty($name) -or $name.Contains('/') -or $name.Contains('\') -or $name -ceq '.' -or $name -ceq '..') { continue }
        $found.Add($name)
    }
    return $found.ToArray()
}

function Get-NSEvidenceShiftValue {
    param([Parameter(Mandatory = $true)][string]$Workspace, [Parameter(Mandatory = $true)][string]$Field)
    $got = Get-NSPolicyGroupSetting $Workspace ('receipts.evidence.' + $Field)
    if ($null -eq $got) { return '' }
    $value = $got['value']
    if ($null -eq $value) { return '' }
    return [string]$value
}

function Get-NSEvidenceEffective {
    param([Parameter(Mandatory = $true)][string]$Workspace, [AllowEmptyString()][string]$Line, [Parameter(Mandatory = $true)][string]$Field)
    $item = Get-NSEvidenceLineValue $Line $Field
    $shift = Get-NSEvidenceShiftValue $Workspace $Field
    if ($Field -ceq 'check') {
        if ($item -in @('off', 'report', 'block')) { return $item }
        if ($shift -in @('off', 'report', 'block')) { return $shift }
        return 'off'
    }
    if ($Field -ceq 'review') {
        if ($item -in @('off', 'on')) { return $item }
        if ($shift -in @('off', 'on')) { return $shift }
        return 'off'
    }
    if ($item -in @('hold', 'park', 'note')) { return $item }
    if ($shift -in @('hold', 'park', 'note')) { return $shift }
    if ((Get-NSEvidenceEffective $Workspace $Line 'check') -ceq 'block') { return 'hold' }
    return 'note'
}

function Get-NSEvidenceKindFile {
    param([Parameter(Mandatory = $true)][string]$Workspace, [Parameter(Mandatory = $true)][string]$Key)
    $ns = Join-Path $Workspace '.nightshift'
    if (Test-NSLayoutKey $ns 'evidence-kinds') {
        $dir = Get-NSLayoutPath $ns 'evidence-kinds'
        $candidate = Join-Path $dir ($Key + '.md')
        if ((Test-Path -LiteralPath $candidate -PathType Leaf) -and -not (Test-NSReparsePoint $candidate)) { return $candidate }
    }
    $raw = (Get-NSPolicyGroupSetting $Workspace 'receipts.evidence.kindsPaths')['value']
    if ($null -ne $raw -and $raw -is [Collections.IEnumerable] -and $raw -isnot [string]) {
        foreach ($one in @($raw)) {
            if ($one -isnot [string] -or [string]::IsNullOrEmpty($one)) { continue }
            $candidate = Join-Path (Resolve-NSCatalogPath $Workspace $one) ($Key + '.md')
            if ((Test-Path -LiteralPath $candidate -PathType Leaf) -and -not (Test-NSReparsePoint $candidate)) { return $candidate }
        }
    }
    $user = Join-Path (Get-NSCatalogUserDir 'evidence' 'kinds') ($Key + '.md')
    if ((Test-Path -LiteralPath $user -PathType Leaf) -and -not (Test-NSReparsePoint $user)) { return $user }
    $plugin = Join-Path $PSScriptRoot '../skills/nightshift/references/evidence/kinds'
    $shipped = Join-Path $plugin ($Key + '.md')
    if ((Test-Path -LiteralPath $shipped -PathType Leaf) -and -not (Test-NSReparsePoint $shipped)) { return $shipped }
    return ''
}

function Get-NSEvidenceBlock {
    param([Parameter(Mandatory = $true)][string]$KindFile)
    $on = $false
    $files = ''
    $min = ''
    $type = ''
    foreach ($line in [IO.File]::ReadAllLines($KindFile)) {
        if ($line -ceq '```evidence-check') { $on = $true; continue }
        if ($on -and $line -ceq '```') { break }
        if (-not $on) { continue }
        if ($line.StartsWith('files: ')) { $files = $line.Substring(7) }
        elseif ($line.StartsWith('min: ')) { $min = $line.Substring(5) }
        elseif ($line.StartsWith('type: ')) { $type = $line.Substring(6) }
    }
    if ([string]::IsNullOrEmpty($files) -and [string]::IsNullOrEmpty($min) -and [string]::IsNullOrEmpty($type)) { return $null }
    return [pscustomobject]@{ Files = $files; Min = $min; Type = $type }
}

function Test-NSEvidenceImage {
    param([Parameter(Mandatory = $true)][string]$Path)
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -ge 4 -and $bytes[0] -eq 0x89 -and $bytes[1] -eq 0x50 -and $bytes[2] -eq 0x4E -and $bytes[3] -eq 0x47) { return $true }
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xD8 -and $bytes[2] -eq 0xFF) { return $true }
    if ($bytes.Length -ge 4 -and $bytes[0] -eq 0x47 -and $bytes[1] -eq 0x49 -and $bytes[2] -eq 0x46 -and $bytes[3] -eq 0x38) { return $true }
    if ($bytes.Length -ge 12 -and $bytes[0] -eq 0x52 -and $bytes[1] -eq 0x49 -and $bytes[2] -eq 0x46 -and $bytes[3] -eq 0x46 -and $bytes[8] -eq 0x57 -and $bytes[9] -eq 0x45 -and $bytes[10] -eq 0x42 -and $bytes[11] -eq 0x50) { return $true }
    return $false
}

function Test-NSEvidenceJson {
    param([Parameter(Mandatory = $true)][string]$Path)
    try {
        $null = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($Path)) -ErrorAction Stop
        return $true
    }
    catch { return $false }
}

function Get-NSEvidenceTypeOf {
    param([Parameter(Mandatory = $true)][string]$Name)
    $lower = $Name.ToLowerInvariant()
    if ($lower.EndsWith('.png') -or $lower.EndsWith('.jpg') -or $lower.EndsWith('.jpeg') -or $lower.EndsWith('.gif') -or $lower.EndsWith('.webp')) { return 'image' }
    if ($lower.EndsWith('.json')) { return 'json' }
    return 'text'
}

function Test-NSEvidenceTyped {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Type)
    if ($Type -ceq 'image') { return (Test-NSEvidenceImage $Path) }
    if ($Type -ceq 'json') { return (Test-NSEvidenceJson $Path) }
    if ($Type -ceq 'text' -or $Type -ceq 'any') { return $true }
    return $false
}

function Get-NSEvidenceFileProblem {
    param([Parameter(Mandatory = $true)][string]$Dir, [Parameter(Mandatory = $true)][string]$Name)
    $path = Join-Path $Dir $Name
    $exists = Test-Path -LiteralPath $path
    if (-not $exists) { return ('missing ' + $Name) }
    if (Test-NSReparsePoint $path) { return ('link ' + $Name) }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return ('link ' + $Name) }
    if ((Get-Item -LiteralPath $path).Length -eq 0) { return ('empty ' + $Name) }
    if (-not (Test-NSEvidenceTyped $path (Get-NSEvidenceTypeOf $Name))) { return ('type ' + $Name) }
    return ''
}

function Get-NSEvidenceProblems {
    param([Parameter(Mandatory = $true)][string]$Workspace, [Parameter(Mandatory = $true)][string]$PunchList, [Parameter(Mandatory = $true)][string]$Label)
    $problems = New-Object Collections.Generic.List[string]
    $line = Get-NSEvidenceItemLine $PunchList $Label
    if ((Get-NSEvidenceEffective $Workspace $line 'check') -ceq 'off') { return $problems.ToArray() }
    $id = ''
    foreach ($row in (Get-NSItemRows $PunchList 'all')) {
        if ($row.Label -ceq $Label) { $id = [string]$row.Id; break }
    }
    $receipt = Get-NSReceiptPath $Workspace $Label $id
    if ((Test-Path -LiteralPath $receipt -PathType Leaf) -and -not (Test-NSReparsePoint $receipt)) {
        foreach ($receiptLine in [IO.File]::ReadAllLines($receipt)) {
            if ($receiptLine.TrimEnd("`r") -ceq '<!-- nightshift:evidence-unavailable -->') {
                return $problems.ToArray()
            }
        }
    }
    $dir = $receipt.Substring(0, $receipt.Length - 3)
    foreach ($file in @(Get-NSEvidenceFiles $line)) {
        $problem = Get-NSEvidenceFileProblem $dir $file
        if (-not [string]::IsNullOrEmpty($problem)) { $problems.Add($problem) }
    }
    foreach ($kind in @(Get-NSEvidenceKinds $line)) {
        $kindFile = Get-NSEvidenceKindFile $Workspace $kind
        if ([string]::IsNullOrEmpty($kindFile)) { $problems.Add('missing kind ' + $kind); continue }
        $block = Get-NSEvidenceBlock $kindFile
        if ($null -eq $block) { continue }
        if ($block.Files.Contains('/') -or $block.Files.Contains('\') -or $block.Files.Contains('..') -or [string]::IsNullOrEmpty($block.Files)) {
            $problems.Add('pattern ' + $kind); continue
        }
        $min = 0
        if (-not [int]::TryParse($block.Min, [ref]$min) -or $min -lt 1) { $problems.Add('pattern ' + $kind); continue }
        if ($block.Type -notin @('image', 'text', 'json', 'any')) { $problems.Add('pattern ' + $kind); continue }
        $count = 0
        if ((Test-Path -LiteralPath $dir -PathType Container) -and -not (Test-NSReparsePoint $dir)) {
            foreach ($match in @(Get-ChildItem -LiteralPath $dir -File -Filter $block.Files -ErrorAction SilentlyContinue)) {
                if ($match.LinkType) { continue }
                if ($match.Length -le 0) { continue }
                if (Test-NSEvidenceTyped $match.FullName $block.Type) { $count++ }
            }
        }
        if ($count -lt $min) { $problems.Add('pattern ' + $kind) }
    }
    if ((Get-NSEvidenceEffective $Workspace $line 'review') -ceq 'on' -and (Get-NSEvidenceEffective $Workspace $line 'check') -ceq 'block') {
        $reviewed = $false
        if ((Test-Path -LiteralPath $receipt -PathType Leaf) -and -not (Test-NSReparsePoint $receipt)) {
            foreach ($receiptLine in [IO.File]::ReadAllLines($receipt)) {
                if ($receiptLine -cmatch '^## Reviewed(\s|$)') { $reviewed = $true; break }
            }
        }
        if (-not $reviewed) { $problems.Add('reviewed') }
    }
    return $problems.ToArray()
}

function Get-NSEvidenceHold {
    param([Parameter(Mandatory = $true)][string]$Workspace, [Parameter(Mandatory = $true)][string]$PunchList)
    if (-not (Test-Path -LiteralPath $PunchList -PathType Leaf) -or (Test-NSReparsePoint $PunchList)) { return '' }
    foreach ($row in (Get-NSItemRows $PunchList 'ticked')) {
        $line = Get-NSEvidenceItemLine $PunchList $row.Label
        if ((Get-NSEvidenceEffective $Workspace $line 'check') -cne 'block') { continue }
        $problems = @(Get-NSEvidenceProblems $Workspace $PunchList $row.Label)
        if ($problems.Count -eq 0) { continue }
        $dash = [string][char]0x2014
        return ('DO NOT STOP ' + $dash + ' ' + $row.Label + ' is ticked and its evidence is not present: ' + ($problems -join ', ') + '. A present file is a regular, non-empty file of the type it claims. The tick stands once those files are there.')
    }
    return ''
}

function Test-NSEvidenceMechanical {
    param([Parameter(Mandatory = $true)][string]$Workspace, [AllowEmptyString()][string]$Line)
    if (@(Get-NSEvidenceFiles $Line).Count -gt 0) { return $true }
    foreach ($kind in @(Get-NSEvidenceKinds $Line)) {
        $kindFile = Get-NSEvidenceKindFile $Workspace $kind
        if ([string]::IsNullOrEmpty($kindFile)) { return $true }
        if ($null -ne (Get-NSEvidenceBlock $kindFile)) { return $true }
    }
    return $false
}

function Get-NSEvidenceReceiptText {
    param([Parameter(Mandatory = $true)][string]$Workspace, [Parameter(Mandatory = $true)][string]$PunchList, [Parameter(Mandatory = $true)][string]$Label)
    $line = Get-NSEvidenceItemLine $PunchList $Label
    if ((Get-NSEvidenceEffective $Workspace $line 'check') -ceq 'off') { return $null }
    $problems = @(Get-NSEvidenceProblems $Workspace $PunchList $Label | Where-Object { -not [string]::IsNullOrEmpty($_) })
    $lines = New-Object Collections.Generic.List[string]
    if (Test-NSEvidenceMechanical $Workspace $line) {
        if ($problems.Count -gt 0) { foreach ($one in $problems) { $lines.Add($one) } }
        else { $lines.Add('present') }
    }
    else {
        $lines.Add('Nothing mechanical to check.')
        foreach ($one in $problems) { $lines.Add($one) }
    }
    return ($lines -join "`n")
}

function Write-NSEvidenceRecord {
    param([Parameter(Mandatory = $true)][string]$NightshiftDir, [Parameter(Mandatory = $true)][string]$Workspace, [Parameter(Mandatory = $true)][string]$Label)
    if (-not (Test-NSReceiptsEnabled $Workspace)) { return }
    $punch = Get-NSLayoutPath $NightshiftDir 'punch-list'
    if (-not (Test-Path -LiteralPath $punch -PathType Leaf) -or (Test-NSReparsePoint $punch)) { return }
    $text = Get-NSEvidenceReceiptText $Workspace $punch $Label
    if ($null -eq $text) { return }
    $receipt = Get-NSReceiptPath $Workspace $Label
    if (-not (Test-Path -LiteralPath $receipt -PathType Leaf) -or (Test-NSReparsePoint $receipt)) { return }
    foreach ($receiptLine in [IO.File]::ReadAllLines($receipt)) {
        if ($receiptLine.TrimEnd("`r") -ceq '<!-- nightshift:evidence-unavailable -->') { return }
    }
    Write-NSReceiptBlock $receipt 'evidence-check' ($text + "`n")
}

function Set-NSEvidenceBox {
    param([Parameter(Mandatory = $true)][string]$PunchList, [Parameter(Mandatory = $true)][string]$Label, [Parameter(Mandatory = $true)][string]$Mark)
    if (-not (Test-Path -LiteralPath $PunchList -PathType Leaf) -or (Test-NSReparsePoint $PunchList)) { return $false }
    $text = [IO.File]::ReadAllText($PunchList)
    $newline = "`n"
    if ($text.Contains("`r`n")) { $newline = "`r`n" }
    $flat = $text.Replace("`r`n", "`n").Replace("`r", "`n")
    $lines = @($flat.Split([char]10))
    $changed = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = [string]$lines[$i]
        if ($line -cmatch '^- \[[ xX-]\]' -and (Get-NSItemLabel $line) -ceq $Label) {
            $lines[$i] = [regex]::Replace($line, '^- \[[ xX-]\]', ('- [' + $Mark + ']'), 1)
            $changed = $true
            break
        }
    }
    if (-not $changed) { return $false }
    [IO.File]::WriteAllText($PunchList, ($lines -join $newline), (New-Object Text.UTF8Encoding($false)))
    return $true
}

function Get-NSEvidenceUnavailableText {
    param([AllowEmptyString()][string]$Line, [Parameter(Mandatory = $true)][string]$Reason)
    $files = @(Get-NSEvidenceFiles $Line)
    $dash = [string][char]0x2014
    if ($files.Count -eq 0) { return ('unavailable ' + $dash + ' ' + $Reason) }
    $lines = New-Object Collections.Generic.List[string]
    foreach ($file in $files) { $lines.Add($file + ': unavailable ' + $dash + ' ' + $Reason) }
    return ($lines -join "`n")
}

function Invoke-NSEvidenceUnavailable {
    param([Parameter(Mandatory = $true)][string]$Workspace, [Parameter(Mandatory = $true)][string]$Label, [AllowEmptyString()][string]$Reason)
    $ns = Join-Path $Workspace '.nightshift'
    $punch = Get-NSLayoutPath $ns 'punch-list'
    if (-not (Test-Path -LiteralPath $punch -PathType Leaf) -or (Test-NSReparsePoint $punch)) { return '' }
    $found = $false
    foreach ($row in (Get-NSItemRows $punch 'all')) {
        if ($row.Label -ceq $Label) { $found = $true; break }
    }
    if (-not $found) { return '' }
    $clean = (($Reason -replace '[\r\n\t]', ' ') -replace ' +', ' ').Trim()
    if ([string]::IsNullOrEmpty($clean)) { $clean = 'not produced' }
    $line = Get-NSEvidenceItemLine $punch $Label
    $mode = Get-NSEvidenceEffective $Workspace $line 'unavailable'
    if ($mode -notin @('hold', 'park', 'note')) {
        if ((Get-NSEvidenceEffective $Workspace $line 'check') -ceq 'block') { $mode = 'hold' } else { $mode = 'note' }
    }
    if ($mode -ceq 'hold' -or $mode -ceq 'note') {
        $receipt = Get-NSReceiptPath $Workspace $Label
        if (Test-NSReparsePoint $receipt) { return '' }
        if (-not (Test-Path -LiteralPath $receipt -PathType Leaf)) {
            $null = New-Item -ItemType Directory -Path (Split-Path -Parent $receipt) -Force
            [IO.File]::WriteAllText($receipt, ('# ' + $Label + "`n"), (New-Object Text.UTF8Encoding($false)))
        }
        Write-NSReceiptBlock $receipt 'evidence-unavailable' ((Get-NSEvidenceUnavailableText $line $clean) + "`n")
    }
    $dot = [string][char]0x00B7
    if ($mode -ceq 'hold') {
        if (-not (Set-NSEvidenceBox $punch $Label '-')) { return '' }
        $snag = Get-NSLayoutPath $ns 'snag-log'
        $marker = $Label + ' ' + $dot + ' ' + $clean + ' ' + $dot + ' accepted-tradeoff ' + $dot + ' ' + (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd')
        $bullet = '- ' + $marker
        if (-not (Test-Path -LiteralPath $snag -PathType Leaf)) {
            $null = New-Item -ItemType Directory -Path (Split-Path -Parent $snag) -Force
            [IO.File]::WriteAllText($snag, "# Snag Log`n`n", (New-Object Text.UTF8Encoding($false)))
        }
        if (-not (Test-NSReparsePoint $snag)) {
            $existing = [IO.File]::ReadAllText($snag)
            if (-not $existing.Contains($bullet)) {
                if (-not $existing.EndsWith("`n")) { $existing += "`n" }
                [IO.File]::WriteAllText($snag, ($existing + $bullet + "`n"), (New-Object Text.UTF8Encoding($false)))
            }
        }
    }
    elseif ($mode -ceq 'park') {
        $lot = Get-NSLayoutPath $ns 'parking-lot'
        $marker = 'Evidence for ' + $Label + ' could not be produced'
        $bullet = '- ' + $marker + ' ' + $dot + ' leave the item open and keep working ' + $dot + ' ' + $clean
        if (-not (Test-Path -LiteralPath $lot -PathType Leaf)) {
            $null = New-Item -ItemType Directory -Path (Split-Path -Parent $lot) -Force
            [IO.File]::WriteAllText($lot, "# Parking Lot`n`n", (New-Object Text.UTF8Encoding($false)))
        }
        if (-not (Test-NSReparsePoint $lot)) {
            $existing = [IO.File]::ReadAllText($lot)
            if (-not $existing.Contains($marker)) {
                if (-not $existing.EndsWith("`n")) { $existing += "`n" }
                [IO.File]::WriteAllText($lot, ($existing + $bullet + "`n"), (New-Object Text.UTF8Encoding($false)))
            }
        }
    }
    else {
        if (-not (Set-NSEvidenceBox $punch $Label 'x')) { return '' }
    }
    return $mode
}
