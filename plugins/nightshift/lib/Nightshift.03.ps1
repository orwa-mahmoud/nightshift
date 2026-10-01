# Get-NSReceiptIgnoreLines <state-dir> - what the receipts repository leaves out: the stop-work
# order and the runtime's folder. A layout with no runtime folder keeps those files beside the
# owner's, so each transient one is named.
function Get-NSReceiptIgnoreLines {
    param([Parameter(Mandatory = $true)][string]$NightshiftDir)
    $run = Get-NSLayoutRelativePath $NightshiftDir 'run'
    if ($run.Length -gt 0) { return , @((Get-NSLayoutRelativePath $NightshiftDir 'stop'), ($run + '/')) }
    return , @('STOP', '.stall', '.notified', 'deadline', '.session-end', '.shift-pulse', '.mint-failed',
        '.shift-session', '.shift-session.tmp.*', '.shift-worker', '.shift-lease', '.shift-lease.tmp.*',
        '.mutex-scope', '.mutex-scope.tmp.*', '.watchman', '.watchman-tick', '.lock.d/', '.lease-lock.d/')
}

# Invoke-NSScaffold <workspace> <keys> - copy each key's template to where the workspace's layout
# keeps it, never over an existing name. The punch list brings the shift log's header and the
# runtime's folder with it. A .nightshift/ this call creates gets the current state-version first.
# Returns one `wrote` or `kept` line per file; throws naming what it could not write.
function Invoke-NSScaffold {
    param(
        [Parameter(Mandatory = $true)][string]$Workspace,
        [Parameter(Mandatory = $true)][string[]]$Keys
    )
    $templates = Join-Path (Split-Path -Parent $PSScriptRoot) 'skills/nightshift/references/templates'
    Initialize-NSStateDir $Workspace
    $ns = Join-Path $Workspace '.nightshift'
    $lines = New-Object Collections.Generic.List[string]
    foreach ($key in $Keys) {
        $source = Join-Path $templates ($key + '.md')
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "no template for $key" }
        $line = Write-NSScaffoldFile -Workspace $Workspace -Key $key -Template $source
        if ($line.Length -gt 0) { $lines.Add($line) }
    }
    if ($Keys -ccontains 'punch-list') {
        $line = Write-NSScaffoldFile -Workspace $Workspace -Key 'shift-log' -Line '# Shift Log'
        if ($line.Length -gt 0) { $lines.Add($line) }
        # The runtime's markers land beside the shift log from the first arming on.
        New-NSLayoutParent $ns 'armed'
    }
    return , $lines.ToArray()
}

# --- paths, JSON and schema documents --------------------------------------

function Sort-NSOrdinal {
    param([AllowNull()][AllowEmptyCollection()][string[]]$Items)
    $sorted = New-Object Collections.Generic.List[string]
    if ($null -ne $Items) {
        foreach ($item in $Items) {
            $sorted.Add($item)
        }
    }
    $sorted.Sort([StringComparer]::Ordinal)
    return , $sorted.ToArray()
}

function Get-NSAbsolutePath {
    param([Parameter(Mandatory = $true)][string]$Path)
    $candidate = $Path
    if (-not [IO.Path]::IsPathRooted($candidate)) {
        $candidate = Join-Path (Get-Location).ProviderPath $candidate
    }
    $full = [IO.Path]::GetFullPath($candidate)
    $sep = [IO.Path]::DirectorySeparatorChar
    while ($full.Length -gt 1 -and $full[$full.Length - 1] -eq $sep -and -not $full.EndsWith(':' + $sep, [StringComparison]::Ordinal)) {
        $full = $full.Substring(0, $full.Length - 1)
    }
    return $full
}

function Test-NSEvidenceId {
    param([AllowEmptyString()][string]$Id)
    if ([string]::IsNullOrEmpty($Id)) { return $false }
    return [regex]::IsMatch($Id, '^[A-Za-z0-9][A-Za-z0-9_-]*$')
}

# Join a directory and a leaf name. Never treats Name as a path, even when
# it looks rooted - Join-NSPath's rooted-name rule is how an evidence id
# such as /tmp/nightshift-proof escaped .nightshift/.
function Join-NSLeaf {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Base,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Name
    )
    if ([string]::IsNullOrEmpty($Base)) { return $Name }
    $last = $Base[$Base.Length - 1]
    if ($last -eq [IO.Path]::DirectorySeparatorChar -or $last -eq [IO.Path]::AltDirectorySeparatorChar) {
        return ($Base + $Name)
    }
    return ($Base + [IO.Path]::DirectorySeparatorChar + $Name)
}

function Get-NSEvidenceRawDestination {
    param(
        [Parameter(Mandatory = $true)][string]$Ns,
        [AllowEmptyString()][string]$Id
    )
    if (-not (Test-NSEvidenceId $Id)) { return $null }
    $rawDir = Get-NSLayoutPath $Ns 'evidence'
    $rawDir = Join-NSPath $rawDir 'raw'
    if (-not (Test-Path -LiteralPath $rawDir -PathType Container)) {
        $null = New-Item -ItemType Directory -Path $rawDir -Force
    }
    $parent = Get-NSAbsolutePath $rawDir
    $nsRoot = Get-NSAbsolutePath $Ns
    $sep = [string][IO.Path]::DirectorySeparatorChar
    if ($parent -ne $nsRoot -and -not $parent.StartsWith($nsRoot + $sep, [StringComparison]::Ordinal)) {
        return $null
    }
    $dest = Join-NSLeaf $parent ($Id + '.txt')
    $destParent = Get-NSAbsolutePath ([IO.Path]::GetDirectoryName($dest))
    if ($destParent -ne $parent) { return $null }
    $result = New-NSOrdinalMap
    $result['rel'] = (Join-NSLeaf (Join-NSLeaf (Get-NSLayoutRelativePath $Ns 'evidence') 'raw') ($Id + '.txt')) -replace '\\', '/'
    $result['abs'] = $dest
    return $result
}

function Join-NSPath {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Base,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Name
    )
    if ([string]::IsNullOrEmpty($Base) -or [IO.Path]::IsPathRooted($Name)) {
        return $Name
    }
    $last = $Base[$Base.Length - 1]
    if ($last -eq [IO.Path]::DirectorySeparatorChar -or $last -eq [IO.Path]::AltDirectorySeparatorChar) {
        return ($Base + $Name)
    }
    return ($Base + [IO.Path]::DirectorySeparatorChar + $Name)
}

# The canonical capability document: recursively sorted keys,
# two-space indent, "key": value, [] and {} for empties, \uXXXX for every
# character outside printable ASCII, no escaped slash, LF only. -Compact drops
# every newline and space, giving Python json.dumps(sort_keys=True,
# separators=(",", ":")) - the one-line form the evidence ledger stores.
# -Readable escapes only what JSON requires and leaves every other character as
# it stands, the form lib/rules-read.awk writes for a settings file the owner reads.
function ConvertTo-NSJsonStringLiteral {
    param([AllowNull()][AllowEmptyString()][string]$Text, [switch]$Readable)
    $builder = New-Object Text.StringBuilder
    $null = $builder.Append('"')
    if (-not [string]::IsNullOrEmpty($Text)) {
        foreach ($char in $Text.ToCharArray()) {
            $code = [int]$char
            if ($code -eq 34) { $null = $builder.Append('\"') }
            elseif ($code -eq 92) { $null = $builder.Append('\\') }
            elseif ($code -eq 8) { $null = $builder.Append('\b') }
            elseif ($code -eq 9) { $null = $builder.Append('\t') }
            elseif ($code -eq 10) { $null = $builder.Append('\n') }
            elseif ($code -eq 12) { $null = $builder.Append('\f') }
            elseif ($code -eq 13) { $null = $builder.Append('\r') }
            elseif ($code -lt 32 -or ($code -gt 126 -and -not $Readable)) { $null = $builder.Append(('\u{0:x4}' -f $code)) }
            else { $null = $builder.Append($char) }
        }
    }
    $null = $builder.Append('"')
    return $builder.ToString()
}

function Test-NSJsonInteger {
    param($Value)
    return ($Value -is [int] -or $Value -is [long] -or $Value -is [int16] -or $Value -is [byte] -or $Value -is [uint16] -or $Value -is [uint32] -or $Value -is [uint64] -or $Value -is [sbyte])
}

function Test-NSJsonFloat {
    param($Value)
    return ($Value -is [double] -or $Value -is [single] -or $Value -is [decimal])
}

# repr() of a Python float: shortest round-trip, and always a fractional part so
# 1.0 never collapses to 1.
function Format-NSJsonFloat {
    param($Value)
    $text = ([double]$Value).ToString('R', [Globalization.CultureInfo]::InvariantCulture)
    if ($text.IndexOf('.') -lt 0 -and $text.IndexOf('E') -lt 0 -and $text.IndexOf('e') -lt 0 -and $text.IndexOf('N') -lt 0 -and $text.IndexOf('I') -lt 0) {
        $text = $text + '.0'
    }
    return $text
}

function Write-NSCanonicalJsonValue {
    param(
        [Parameter(Mandatory = $true)]$Builder,
        $Value,
        [int]$Level = 0,
        [switch]$Compact,
        [switch]$Readable
    )
    if ($null -eq $Value) {
        $null = $Builder.Append('null')
        return
    }
    if ($Value -is [bool]) {
        if ($Value) { $null = $Builder.Append('true') } else { $null = $Builder.Append('false') }
        return
    }
    if ($Value -is [string]) {
        $null = $Builder.Append((ConvertTo-NSJsonStringLiteral $Value -Readable:$Readable))
        return
    }
    if (Test-NSJsonInteger $Value) {
        $null = $Builder.Append(([long]$Value).ToString([Globalization.CultureInfo]::InvariantCulture))
        return
    }
    if (Test-NSJsonFloat $Value) {
        $null = $Builder.Append((Format-NSJsonFloat $Value))
        return
    }
    $pad = ' ' * (2 * ($Level + 1))
    $tail = ' ' * (2 * $Level)
    $break = "`n"
    $colon = ': '
    if ($Compact) {
        $pad = ''
        $tail = ''
        $break = ''
        $colon = ':'
    }
    if ($Value -is [Collections.IDictionary]) {
        $keys = Sort-NSOrdinal (@($Value.Keys))
        if ($keys.Count -eq 0) {
            $null = $Builder.Append('{}')
            return
        }
        $null = $Builder.Append('{')
        $index = 0
        foreach ($key in $keys) {
            if ($index -gt 0) { $null = $Builder.Append(',') }
            $null = $Builder.Append($break)
            $null = $Builder.Append($pad)
            $null = $Builder.Append((ConvertTo-NSJsonStringLiteral $key -Readable:$Readable))
            $null = $Builder.Append($colon)
            Write-NSCanonicalJsonValue $Builder $Value[$key] ($Level + 1) -Compact:$Compact -Readable:$Readable
            $index++
        }
        $null = $Builder.Append($break)
        $null = $Builder.Append($tail)
        $null = $Builder.Append('}')
        return
    }
    if ($Value -is [Collections.IEnumerable]) {
        $items = @($Value)
        if ($items.Count -eq 0) {
            $null = $Builder.Append('[]')
            return
        }
        $null = $Builder.Append('[')
        $index = 0
        foreach ($item in $items) {
            if ($index -gt 0) { $null = $Builder.Append(',') }
            $null = $Builder.Append($break)
            $null = $Builder.Append($pad)
            Write-NSCanonicalJsonValue $Builder $item ($Level + 1) -Compact:$Compact -Readable:$Readable
            $index++
        }
        $null = $Builder.Append($break)
        $null = $Builder.Append($tail)
        $null = $Builder.Append(']')
        return
    }
    $null = $Builder.Append((ConvertTo-NSJsonStringLiteral ([string]$Value) -Readable:$Readable))
}

function ConvertTo-NSCanonicalJson {
    param([AllowNull()]$InputObject, [switch]$Compact, [switch]$Readable)
    $builder = New-Object Text.StringBuilder
    Write-NSCanonicalJsonValue $builder $InputObject 0 -Compact:$Compact -Readable:$Readable
    return $builder.ToString()
}

function Get-NSSchemaDocument {
    param([Parameter(Mandatory = $true)][string]$Name)
    $dir = Join-Path (Split-Path -Parent $PSScriptRoot) 'skills/nightshift/references/schemas/v1'
    $raw = [IO.File]::ReadAllText((Join-Path $dir $Name))
    return ($raw | ConvertFrom-Json)
}

function Get-NSJsonProperty {
    param($Object, [Parameter(Mandatory = $true)][string]$Name)
    if ($null -eq $Object) {
        return $null
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }
    return $property.Value
}

# ---------------------------------------------------------------------------
# Evidence ledger - the native side of runtime/windows/evidence.ps1.
# Validates records. Does not verify a Nightshift tick or interpret domain
# meaning. Every byte it writes matches runtime/evidence.py for the same input.
# ---------------------------------------------------------------------------

$script:NSEvidenceLadderRank = New-Object Collections.Specialized.OrderedDictionary([StringComparer]::Ordinal)
$script:NSEvidenceLadderRank['declared'] = 0
$script:NSEvidenceLadderRank['observed'] = 1
$script:NSEvidenceLadderRank['reproduced'] = 2
$script:NSEvidenceLadderRank['measured'] = 3
$script:NSEvidenceLadderRank['verified-after-change'] = 4
$script:NSEvidenceLadderRank['human-accepted'] = 5

$script:NSEvidenceTsvColumns = @(
    'id', 'domain', 'sourceClass', 'source', 'scope', 'severity',
    'confidence', 'impact', 'status', 'ladder', 'locator', 'host'
)

# ConvertFrom-Json turns any string that looks like a timestamp into a DateTime,
# which would rewrite firstSeen/lastChecked on the way through. Prefixing every
# string literal with one guard character before the parse - and dropping it
# again after - keeps every value the text it was.
$script:NSJsonGuard = '~'

function Add-NSJsonStringGuard {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)
    $builder = New-Object Text.StringBuilder
    $inString = $false
    $i = 0
    while ($i -lt $Text.Length) {
        $ch = $Text[$i]
        if (-not $inString) {
            $null = $builder.Append($ch)
            if ($ch -eq '"') {
                $inString = $true
                $null = $builder.Append($script:NSJsonGuard)
            }
            $i++
            continue
        }
        if ($ch -eq '\') {
            $null = $builder.Append($ch)
            if ($i + 1 -lt $Text.Length) { $null = $builder.Append($Text[$i + 1]) }
            $i += 2
            continue
        }
        $null = $builder.Append($ch)
        if ($ch -eq '"') { $inString = $false }
        $i++
    }
    return $builder.ToString()
}

function Remove-NSJsonStringGuard {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)
    if ($Text.Length -eq 0) { return $Text }
    return $Text.Substring(1)
}

function New-NSOrdinalMap {
    return (New-Object Collections.Specialized.OrderedDictionary([StringComparer]::Ordinal))
}

function ConvertFrom-NSJsonNode {
    param($Node)
    if ($null -eq $Node) { return $null }
    if ($Node -is [string]) { return (Remove-NSJsonStringGuard $Node) }
    if ($Node -is [bool] -or (Test-NSJsonInteger $Node) -or (Test-NSJsonFloat $Node)) { return $Node }
    if ($Node -is [Collections.IDictionary]) {
        $map = New-NSOrdinalMap
        foreach ($key in @($Node.Keys)) {
            $map[(Remove-NSJsonStringGuard ([string]$key))] = ConvertFrom-NSJsonNode $Node[$key]
        }
        return $map
    }
    if ($Node -is [Collections.IEnumerable]) {
        $items = New-Object Collections.Generic.List[object]
        foreach ($item in $Node) { $items.Add((ConvertFrom-NSJsonNode $item)) }
        return , $items.ToArray()
    }
    $map = New-NSOrdinalMap
    foreach ($property in $Node.PSObject.Properties) {
        $name = Remove-NSJsonStringGuard $property.Name
        if ($null -eq $property.Value -and ($property.TypeNameOfValue -ceq 'System.Object[]')) {
            $map[$name] = @()
            continue
        }
        $map[$name] = ConvertFrom-NSJsonNode $property.Value
    }
    return $map
}

# json.loads: ordered dictionaries with ordinal keys, so "id" and "ID" stay two
# keys and the canonical serializer sees them the way Python does.
function ConvertFrom-NSJsonText {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)
    $parsed = ConvertFrom-Json (Add-NSJsonStringGuard $Text) -ErrorAction Stop
    return (ConvertFrom-NSJsonNode $parsed)
}

function Get-NSMapValue {
    param($Map, [Parameter(Mandatory = $true)][string]$Key)
    if (-not ($Map -is [Collections.IDictionary])) { return $null }
    if (-not $Map.Contains($Key)) { return $null }
    return , $Map[$Key]
}

function Copy-NSMap {
    param($Map)
    $copy = New-NSOrdinalMap
    if ($Map -is [Collections.IDictionary]) {
        foreach ($key in @($Map.Keys)) { $copy[$key] = $Map[$key] }
    }
    return $copy
}

# Python truth testing: empty string, zero, empty container and None are false.
function Test-NSPyTruthy {
    param($Value)
    if ($null -eq $Value) { return $false }
    if ($Value -is [bool]) { return [bool]$Value }
    if ($Value -is [string]) { return ($Value.Length -gt 0) }
    if (Test-NSJsonInteger $Value) { return ([long]$Value -ne 0) }
    if (Test-NSJsonFloat $Value) { return ([double]$Value -ne 0) }
    if ($Value -is [Collections.IDictionary]) { return ($Value.Count -gt 0) }
    if ($Value -is [Collections.ICollection]) { return ($Value.Count -gt 0) }
    return $true
}

# Python str(): None renders None, booleans render True/False.
function ConvertTo-NSPyText {
    param($Value)
    if ($null -eq $Value) { return 'None' }
    if ($Value -is [bool]) {
        if ($Value) { return 'True' }
        return 'False'
    }
    if (Test-NSJsonFloat $Value) { return (Format-NSJsonFloat $Value) }
    return [string]$Value
}

# Python ==: same type and same value, so 1 and "1" stay different.
function Test-NSPyEqual {
    param($Left, $Right)
    return ((ConvertTo-NSCanonicalJson $Left -Compact) -ceq (ConvertTo-NSCanonicalJson $Right -Compact))
}

function Write-NSEvidenceOut {
    param([AllowEmptyString()][string]$Text)
    [Console]::Out.Write($Text)
    [Console]::Out.Write("`n")
}

function Write-NSEvidenceError {
    param([AllowEmptyString()][string]$Text)
    [Console]::Error.WriteLine($Text)
}

function Write-NSEvidenceUsage {
    Write-NSEvidenceError 'usage: evidence.ps1 -Project DIR -Command {init|validate|append|disposition|render|export-tsv|migrate} ...'
    return 1
}

function Get-NSEvidenceNow {
    $fixed = $env:NIGHTSHIFT_EVIDENCE_NOW
    if (-not [string]::IsNullOrEmpty($fixed)) { return $fixed }
    return [DateTime]::UtcNow.ToString('yyyy-MM-dd\THH:mm:ss\Z', [Globalization.CultureInfo]::InvariantCulture)
}

function Get-NSTextSha256 {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash($script:NSUtf8NoBom.GetBytes($Text))
    }
    finally {
        $sha.Dispose()
    }
    $builder = New-Object Text.StringBuilder
    foreach ($byte in $hash) { $null = $builder.Append($byte.ToString('x2')) }
    return $builder.ToString()
}

function Get-NSEvidencePaths {
    param([Parameter(Mandatory = $true)][string]$Project)
    $ns = Join-NSPath (Get-NSAbsolutePath $Project) '.nightshift'
    $evidence = Get-NSLayoutPath $ns 'evidence'
    $paths = New-NSOrdinalMap
    $paths['ns'] = $ns
    $paths['dir'] = $evidence
    $paths['jsonl'] = Join-NSPath $evidence 'findings.jsonl'
    $paths['md'] = Join-NSPath $evidence 'findings.md'
    $paths['raw'] = Join-NSPath $evidence 'raw'
    $paths['version'] = Join-NSPath $evidence 'schema-version'
    return $paths
}

function Write-NSEvidenceFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text
    )
    [IO.File]::WriteAllText($Path, $Text, $script:NSUtf8NoBom)
}

function Write-NSEvidenceFileAtomic {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text
    )
    $tmp = $Path + '.tmp'
    Write-NSEvidenceFile -Path $tmp -Text $Text
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        # [NullString]::Value, not $null: PowerShell would bind $null to "" and
        # Replace rejects an empty backup path.
        [IO.File]::Replace($tmp, $Path, [NullString]::Value)
        return
    }
    [IO.File]::Move($tmp, $Path)
}

function Test-NSEvidenceSchemaOne {
    param($Value)
    if ($null -eq $Value) { return $false }
    if ($Value -is [bool]) { return [bool]$Value }
    if (Test-NSJsonInteger $Value) { return ([long]$Value -eq 1) }
    if (Test-NSJsonFloat $Value) { return ([double]$Value -eq 1) }
    return $false
}

# Python "value in list": exact, case-sensitive, and never true across types.
function Test-NSEvidenceEnum {
    param($Value, $Allowed)
    if (-not ($Value -is [string])) { return $false }
    foreach ($candidate in @($Allowed)) {
        if (($candidate -is [string]) -and ($candidate -ceq $Value)) { return $true }
    }
    return $false
}

function Get-NSEvidenceLadderRank {
    param($Ladder)
    if (-not ($Ladder -is [string])) { return -1 }
    if (-not $script:NSEvidenceLadderRank.Contains($Ladder)) { return -1 }
    return [int]$script:NSEvidenceLadderRank[$Ladder]
}

function Test-NSEvidenceRecord {
    param($Record, $Schema, $Previous)
    $errors = New-Object Collections.Generic.List[string]
    if (-not ($Record -is [Collections.IDictionary])) {
        $errors.Add('record is not an object')
        return , $errors
    }
    foreach ($key in $Schema.required) {
        if (-not $Record.Contains($key)) { $errors.Add('missing ' + $key) }
    }
    if (-not (Test-NSEvidenceSchemaOne (Get-NSMapValue $Record 'schemaVersion'))) { $errors.Add('unsupported schemaVersion') }
    if (-not (Test-NSEvidenceEnum (Get-NSMapValue $Record 'severity') $Schema.severity)) { $errors.Add('invalid severity') }
    if (-not (Test-NSEvidenceEnum (Get-NSMapValue $Record 'confidence') $Schema.confidence)) { $errors.Add('invalid confidence') }
    if (-not (Test-NSEvidenceEnum (Get-NSMapValue $Record 'impact') $Schema.impact)) { $errors.Add('invalid impact') }
    if (-not (Test-NSEvidenceEnum (Get-NSMapValue $Record 'status') $Schema.status)) { $errors.Add('invalid status') }
    if (-not (Test-NSEvidenceEnum (Get-NSMapValue $Record 'ladder') $Schema.ladder)) { $errors.Add('invalid ladder') }
    if ($Record.Contains('id') -and -not (Test-NSEvidenceId (Get-NSMapValue $Record 'id'))) { $errors.Add('invalid id') }
    $locator = Get-NSMapValue $Record 'locator'
    if (-not (Test-NSPyTruthy $locator)) { $locator = '' }
    if (([string]$locator).Contains('://') -and -not (Test-NSPyTruthy (Get-NSMapValue $Record 'untrusted'))) {
        $errors.Add('remote locator requires untrusted=true')
    }
    if ($null -ne $Previous) {
        $oldRank = Get-NSEvidenceLadderRank (Get-NSMapValue $Previous 'ladder')
        $newRank = Get-NSEvidenceLadderRank (Get-NSMapValue $Record 'ladder')
        $promoteBy = Get-NSMapValue $Record 'promoteBy'
        if ($oldRank -ge 0 -and $newRank -ge 0 -and $newRank -gt $oldRank -and ($promoteBy -is [string]) -and ($promoteBy -ceq 'prose')) {
            $errors.Add('ladder must not be promoted by prose')
        }
    }
    return , $errors
}

# SystemExit in the reference: the message goes to stderr and the process
# leaves with 1, whichever command was running.
function New-NSEvidenceHalt {
    param([Parameter(Mandatory = $true)][string]$Message)
    return (New-Object ApplicationException($Message))
}

function Read-NSEvidenceRecords {
    param([Parameter(Mandatory = $true)][string]$Path)
    $records = New-Object Collections.Generic.List[object]
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return , $records }
    $lines = [regex]::Split([IO.File]::ReadAllText($Path, $script:NSUtf8NoBom), "\r\n|\n|\r")
    for ($i = 0; $i -lt $lines.Length; $i++) {
        $line = $lines[$i].Trim()
        if ($line.Length -eq 0) { continue }
        $record = $null
        try {
            $record = ConvertFrom-NSJsonText $line
        }
        catch {
            throw (New-NSEvidenceHalt ('evidence: malformed JSON on line ' + ($i + 1)))
        }
        $records.Add($record)
    }
    return , $records
}

function Write-NSEvidenceRecords {
    param([Parameter(Mandatory = $true)][string]$Path, $Records)
    $builder = New-Object Text.StringBuilder
    foreach ($record in $Records) {
        $null = $builder.Append((ConvertTo-NSCanonicalJson $record -Compact))
        $null = $builder.Append("`n")
    }
    Write-NSEvidenceFileAtomic -Path $Path -Text $builder.ToString()
}

function Invoke-NSEvidenceInit {
    param([Parameter(Mandatory = $true)][string]$Project, [switch]$Quiet)
    $paths = Get-NSEvidencePaths $Project
    if (-not (Test-Path -LiteralPath $paths['ns'] -PathType Container)) {
        Write-NSEvidenceError ('evidence: no .nightshift/ at ' + $Project)
        return 1
    }
    $null = [IO.Directory]::CreateDirectory($paths['raw'])
    if (-not (Test-Path -LiteralPath $paths['jsonl'] -PathType Leaf)) {
        Write-NSEvidenceFile -Path $paths['jsonl'] -Text ''
    }
    if (-not (Test-Path -LiteralPath $paths['version'] -PathType Leaf)) {
        Write-NSEvidenceFile -Path $paths['version'] -Text "1`n"
    }
    if (-not $Quiet) { Write-NSEvidenceOut $paths['jsonl'] }
    return 0
}

function Invoke-NSEvidenceValidate {
    param([Parameter(Mandatory = $true)][string]$Project)
    $paths = Get-NSEvidencePaths $Project
    if (-not (Test-Path -LiteralPath $paths['jsonl'] -PathType Leaf)) {
        Write-NSEvidenceOut 'evidence: no ledger (valid empty workspace)'
        return 0
    }
    $schema = Get-NSSchemaDocument 'finding.json'
    $records = Read-NSEvidenceRecords $paths['jsonl']
    $seen = New-NSOrdinalMap
    $code = 0
    foreach ($record in $records) {
        $id = Get-NSMapValue $record 'id'
        $key = ConvertTo-NSCanonicalJson $id -Compact
        $previous = $null
        if ($seen.Contains($key)) { $previous = $seen[$key] }
        $errors = Test-NSEvidenceRecord $record $schema $previous
        if ($errors.Count -gt 0) {
            $code = 2
            $label = '?'
            if (Test-NSPyTruthy $id) { $label = ConvertTo-NSPyText $id }
            foreach ($error in $errors) { Write-NSEvidenceError ('evidence: ' + $label + ': ' + $error) }
        }
        if (Test-NSPyTruthy $id) { $seen[$key] = $record }
    }
    return $code
}

function Invoke-NSEvidenceAppend {
    param(
        [Parameter(Mandatory = $true)][string]$Project,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$RecordJson,
        [AllowEmptyString()][string]$RawText = ''
    )
    $paths = Get-NSEvidencePaths $Project
    $null = Invoke-NSEvidenceInit -Project $Project -Quiet
    $record = ConvertFrom-NSJsonText $RecordJson
    if ($record -is [Collections.IDictionary]) {
        if (-not $record.Contains('schemaVersion')) { $record['schemaVersion'] = 1 }
        if (-not $record.Contains('firstSeen')) { $record['firstSeen'] = Get-NSEvidenceNow }
        if (-not $record.Contains('lastChecked')) { $record['lastChecked'] = $record['firstSeen'] }
        if (-not $record.Contains('digest')) {
            $record['digest'] = Get-NSTextSha256 (ConvertTo-NSCanonicalJson $record -Compact)
        }
        foreach ($key in @('action', 'fix', 'verificationLocator', 'disposition', 'rollback')) {
            if (-not $record.Contains($key)) { $record[$key] = '' }
        }
        $source = Get-NSMapValue $record 'source'
        if (-not (Test-NSPyTruthy $source)) { $source = Get-NSMapValue $record 'sourceCommand' }
        if (-not (Test-NSPyTruthy $source)) { $source = '' }
        $record['source'] = $source
        $sourceClass = Get-NSMapValue $record 'sourceClass'
        if (-not (Test-NSPyTruthy $sourceClass)) { $sourceClass = Get-NSMapValue $record 'sourceTool' }
        if (-not (Test-NSPyTruthy $sourceClass)) { $sourceClass = 'unknown' }
        $record['sourceClass'] = $sourceClass
    }
    $schema = Get-NSSchemaDocument 'finding.json'
    $records = Read-NSEvidenceRecords $paths['jsonl']
    $previous = $null
    foreach ($existing in $records) {
        if (Test-NSPyEqual (Get-NSMapValue $existing 'id') (Get-NSMapValue $record 'id')) {
            $previous = $existing
            break
        }
    }
    $errors = Test-NSEvidenceRecord $record $schema $previous
    if ($errors.Count -gt 0) {
        foreach ($error in $errors) { Write-NSEvidenceError ('evidence: ' + $error) }
        return 2
    }
    if (Test-NSPyTruthy $RawText) {
        $contained = Get-NSEvidenceRawDestination -Ns $paths['ns'] -Id ([string](Get-NSMapValue $record 'id'))
        if ($null -eq $contained) {
            Write-NSEvidenceError 'evidence: invalid id'
            return 2
        }
        $record['rawPath'] = [string]$contained['rel']
        $onDisk = $RawText
        if (-not $RawText.EndsWith("`n")) { $onDisk = $RawText + "`n" }
        Write-NSEvidenceFile -Path ([string]$contained['abs']) -Text $onDisk
        $record['rawDigest'] = Get-NSTextSha256 $RawText
    }
    $records.Add($record)
    Write-NSEvidenceRecords -Path $paths['jsonl'] -Records $records
    Write-NSEvidenceOut (ConvertTo-NSPyText (Get-NSMapValue $record 'id'))
    return 0
}

function Invoke-NSEvidenceDisposition {
    param(
        [Parameter(Mandatory = $true)][string]$Project,
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Disposition,
        [AllowEmptyString()][string]$Ladder = ''
    )
    $paths = Get-NSEvidencePaths $Project
    $records = Read-NSEvidenceRecords $paths['jsonl']
    $schema = Get-NSSchemaDocument 'finding.json'
    $found = $false
    foreach ($record in $records) {
        $recordId = Get-NSMapValue $record 'id'
        if (-not (($recordId -is [string]) -and ($recordId -ceq $Id))) { continue }
        $found = $true
        $previous = Copy-NSMap $record
        $record['disposition'] = $Disposition
        $record['lastChecked'] = Get-NSEvidenceNow
        if (Test-NSPyTruthy $Ladder) { $record['ladder'] = $Ladder }
        $errors = Test-NSEvidenceRecord $record $schema $previous
        if ($errors.Count -gt 0) {
            foreach ($error in $errors) { Write-NSEvidenceError ('evidence: ' + $error) }
            return 2
        }
    }
    if (-not $found) {
        Write-NSEvidenceError ('evidence: unknown id ' + $Id)
        return 2
    }
    Write-NSEvidenceRecords -Path $paths['jsonl'] -Records $records
    return 0
}

function Get-NSEvidenceMarkdown {
    param($Records)
    $dash = [string][char]0x2014
    $lines = New-Object Collections.Generic.List[string]
    $lines.Add('# Evidence ledger')
    $lines.Add('')
    $lines.Add('Machine source: `evidence/findings.jsonl`. Helpers validate records; they do not')
    $lines.Add('verify a Nightshift tick or interpret domain meaning.')
    $lines.Add('')
    $lines.Add('| ID | Domain | Severity | Ladder | Status | Locator |')
    $lines.Add('| --- | --- | --- | --- | --- | --- |')
    $count = 0
    foreach ($record in $Records) {
        $cells = New-Object Collections.Generic.List[string]
        foreach ($column in @('id', 'domain', 'severity', 'ladder', 'status', 'locator')) {
            $cells.Add((ConvertTo-NSPyText (Get-NSMapValue $record $column)))
        }
        $lines.Add('| ' + ($cells -join ' | ') + ' |')
        $count++
    }
    if ($count -eq 0) {
        $empty = @($dash, $dash, $dash, $dash, $dash, 'empty')
        $lines.Add('| ' + ($empty -join ' | ') + ' |')
    }
    return (($lines -join "`n") + "`n")
}

function Invoke-NSEvidenceRender {
    param([Parameter(Mandatory = $true)][string]$Project)
    $paths = Get-NSEvidencePaths $Project
    $records = Read-NSEvidenceRecords $paths['jsonl']
    $text = Get-NSEvidenceMarkdown $records
    $null = [IO.Directory]::CreateDirectory($paths['dir'])
    Write-NSEvidenceFile -Path $paths['md'] -Text $text
    [Console]::Out.Write($text)
    return 0
}

function Invoke-NSEvidenceExportTsv {
    param([Parameter(Mandatory = $true)][string]$Project)
    $paths = Get-NSEvidencePaths $Project
    $records = Read-NSEvidenceRecords $paths['jsonl']
    Write-NSEvidenceOut ($script:NSEvidenceTsvColumns -join "`t")
    foreach ($record in $records) {
        $cells = New-Object Collections.Generic.List[string]
        foreach ($column in $script:NSEvidenceTsvColumns) {
            $value = ''
            if (($record -is [Collections.IDictionary]) -and $record.Contains($column)) {
                $value = ConvertTo-NSPyText $record[$column]
            }
            $cells.Add($value.Replace("`t", ' '))
        }
        Write-NSEvidenceOut ($cells -join "`t")
    }
    return 0
}

function Invoke-NSEvidenceMigrate {
    param([Parameter(Mandatory = $true)][string]$Project)
    $paths = Get-NSEvidencePaths $Project
    $hasDir = Test-Path -LiteralPath $paths['dir'] -PathType Container
    $hasLedger = Test-Path -LiteralPath $paths['jsonl'] -PathType Leaf
    if (-not $hasDir -and -not $hasLedger) {
        Write-NSEvidenceOut 'evidence: nothing to migrate'
        return 0
    }
    $version = '0'
    if (Test-Path -LiteralPath $paths['version'] -PathType Leaf) {
        $version = ([IO.File]::ReadAllText($paths['version'], $script:NSUtf8NoBom)).Trim()
        if ($version.Length -eq 0) { $version = '0' }
    }
    if (($version -ceq '0') -or ($version -ceq '1')) {
        $null = [IO.Directory]::CreateDirectory($paths['raw'])
        Write-NSEvidenceFile -Path $paths['version'] -Text "1`n"
        if (-not (Test-Path -LiteralPath $paths['jsonl'] -PathType Leaf)) {
            Write-NSEvidenceFile -Path $paths['jsonl'] -Text ''
        }
        Write-NSEvidenceOut 'evidence: schema-version 1'
        return 0
    }
    Write-NSEvidenceError ('evidence: unsupported evidence schema-version ' + $version)
    return 2
}

function Invoke-NSEvidenceCommand {
    param(
        [AllowEmptyString()][string]$Project = '',
        [AllowEmptyString()][string]$Command = '',
        [AllowEmptyString()][string]$Record = '',
        [AllowEmptyString()][string]$Raw = '',
        [AllowEmptyString()][string]$Id = '',
        [AllowEmptyString()][string]$Disposition = '',
        [AllowEmptyString()][string]$Ladder = ''
    )
    try {
        if ([string]::IsNullOrEmpty($Project) -or [string]::IsNullOrEmpty($Command)) { return (Write-NSEvidenceUsage) }
        switch ($Command) {
            'init' { return (Invoke-NSEvidenceInit -Project $Project) }
            'validate' { return (Invoke-NSEvidenceValidate -Project $Project) }
            'append' {
                if ([string]::IsNullOrEmpty($Record)) { return (Write-NSEvidenceUsage) }
                return (Invoke-NSEvidenceAppend -Project $Project -RecordJson $Record -RawText $Raw)
            }
            'disposition' {
                if ([string]::IsNullOrEmpty($Id) -or [string]::IsNullOrEmpty($Disposition)) { return (Write-NSEvidenceUsage) }
                return (Invoke-NSEvidenceDisposition -Project $Project -Id $Id -Disposition $Disposition -Ladder $Ladder)
            }
            'render' { return (Invoke-NSEvidenceRender -Project $Project) }
            'export-tsv' { return (Invoke-NSEvidenceExportTsv -Project $Project) }
            'migrate' { return (Invoke-NSEvidenceMigrate -Project $Project) }
        }
        return (Write-NSEvidenceUsage)
    }
    catch [ApplicationException] {
        Write-NSEvidenceError $_.Exception.Message
        return 1
    }
}

# ---------------------------------------------------------------------------
# Layered shift policy - the native side of runtime/windows/shift-policy.ps1,
# preflight-needs.ps1 and park-needs.ps1.
#
# rules.json carries the permanent boundaries, shift-defaults.json only prefills
# the next composition question, and shift-policy.json is tonight's snapshot.
# Get-NSPolicyResolution is the one resolver: hardhat, Start, Doctor, Status and
# the support bundle render what it returns and never re-derive precedence.
# ---------------------------------------------------------------------------

$script:NSPolicyCategories = @('sudo', 'containers', 'global-packages', 'daemons', 'external-services')
$script:NSPolicyVerificationLevels = @('none', 'final', 'per-item', 'custom')
$script:NSPolicyToolingPolicies = @('existing-tools', 'review-missing', 'auto-add')
$script:NSPolicyProfiles = @('fast', 'balanced', 'strict', 'custom')
$script:NSPolicyExecutions = @('review-first', 'run-direct')
$script:NSPolicySources = @('composition', 'start-defaults')
$script:NSPolicyScopes = @('category', 'exact-plan')
$script:NSPolicyProvenances = @('rules', 'one-shift')

$script:NSPolicyCompletionModes = @('clear-all', 'no-regression-plus-selected-debt')
$script:NSPolicyCompletionDefault = 'clear-all'

# Shipped elevation patterns (grep -E), used for any category rules.json does not
# carry. Preflight and the hardhat guard read them through Get-NSElevationPattern,
# so the signal that parks an item is the signal that blocks the command. The rules
# template and lib/policy.sh carry the same text, so a category answers alike on
# either engine and whether or not the owner's file names it.
$script:NSPolicyElevationPattern = New-Object Collections.Specialized.OrderedDictionary([StringComparer]::Ordinal)
$script:NSPolicyElevationPattern['sudo'] = '(^|[;&|(`]|[[:space:]]|''|")(/[A-Za-z0-9._-]+)*/*(sudo|d[o]as)([[:space:]]|[;&|)''"`]|$)'
$script:NSPolicyElevationPattern['containers'] = '(/var/run/docker\.sock|unix://[^ \t]*docker\.sock|DOCKER_HOST=)|(^|[;&|(`]|[[:space:]]|''|")(docker-compose)[[:space:]]+(up|run|start|build|down|create)|(^|[;&|(`]|[[:space:]]|''|")(docker|podman|nerdctl|colima)[[:space:]]+(run|create|start|build|compose[[:space:]]+(up|run|start|build|down|create))'
$script:NSPolicyElevationPattern['global-packages'] = '(^|[;&|(`]|[[:space:]]|''|")(brew|apt|apt-get|dnf|yum|pacman|choco|winget|scoop)[[:space:]]+(install|upgrade|uninstall|remove|reinstall)|npm[[:space:]]+(i|install)[[:space:]]+(-g|--global)|pnpm[[:space:]]+add[[:space:]]+-g|yarn[[:space:]]+global|(pip3?|cargo|go)[[:space:]]+install'
$script:NSPolicyElevationPattern['daemons'] = '(^|[;&|(`]|[[:space:]]|''|")(systemctl|launchctl|service|brew[[:space:]]+services|pg_ctl|redis-server|mongod|mysqld)([[:space:]]|$)'
$script:NSPolicyElevationPattern['external-services'] = '(^|[;&|(`]|[[:space:]]|''|")(gh[[:space:]]+auth[[:space:]]+login|npm[[:space:]]+login|docker[[:space:]]+login|az[[:space:]]+login|gcloud[[:space:]]+auth|aws[[:space:]]+configure)([[:space:]]|$)'

# Every setting the resolved view reports, in the order the table prints them.
# The owner preference blocks the resolved view carries, with the built-in each falls back to.
# The same list as NS_RULES_GROUP_KEYS in lib/rules-read.sh, and the same defaults as
# ns_policy_builtin in lib/policy.sh: both resolvers print one view.
$script:NSPolicyGroupDefaults = New-Object Collections.Specialized.OrderedDictionary([StringComparer]::Ordinal)
$script:NSPolicyGroupDefaults['archive.automatic'] = $false
$script:NSPolicyGroupDefaults['archive.layout'] = 'date'
$script:NSPolicyGroupDefaults['archive.root'] = 'archive'
$script:NSPolicyGroupDefaults['archive.templatePath'] = ''
$script:NSPolicyGroupDefaults['handoff.detail'] = 'concise'
$script:NSPolicyGroupDefaults['handoff.enabled'] = $true
$script:NSPolicyGroupDefaults['handoff.language'] = 'auto'
$script:NSPolicyGroupDefaults['handoff.sections'] = @()
$script:NSPolicyGroupDefaults['handoff.templatePath'] = ''
$script:NSPolicyGroupDefaults['handoff.view'] = 'owner'
$script:NSPolicyGroupDefaults['recovery.launchScope'] = 'inherit-recorded-scope'
$script:NSPolicyGroupDefaults['receipts.duration'] = 'on'
$script:NSPolicyGroupDefaults['receipts.enabled'] = $true
$script:NSPolicyGroupDefaults['receipts.progressMinutes'] = 20
$script:NSPolicyGroupDefaults['receipts.progressMode'] = 'time'
$script:NSPolicyGroupDefaults['receipts.progressTokens'] = 100000
$script:NSPolicyGroupDefaults['receipts.templatePath'] = ''
$script:NSPolicyGroupDefaults['receipts.usage'] = 'when-available'
$script:NSPolicyGroupDefaults['shift.execution'] = 'review-first'
$script:NSPolicyGroupDefaults['shift.hours'] = $null
$script:NSPolicyGroupDefaults['shift.toolingPolicy'] = 'existing-tools'
$script:NSPolicyGroupDefaults['shift.verificationProfile'] = 'fast'

$script:NSPolicySettingNames = @(
    'archive.automatic',
    'archive.layout',
    'archive.root',
    'archive.templatePath',
    'deadlineEpoch',
    'elevation.containers',
    'elevation.daemons',
    'elevation.external-services',
    'elevation.global-packages',
    'elevation.sudo',
    'expectedEmail',
    'forbiddenCommands',
    'handoff.detail',
    'handoff.enabled',
    'handoff.language',
    'handoff.sections',
    'handoff.templatePath',
    'handoff.view',
    'neverCommitPatterns',
    'protectedDirs',
    'recovery.launchScope',
    'receipts.duration',
    'receipts.enabled',
    'receipts.progressMinutes',
    'receipts.progressMode',
    'receipts.progressTokens',
    'receipts.templatePath',
    'receipts.usage',
    'shift.execution',
    'shift.hours',
    'shift.toolingPolicy',
    'shift.verificationProfile',
    'stallMax',
    'toolingPolicy',
    'verificationLevel',
    'watchMinutes'
)

function Write-NSPolicyOut {
    param([AllowEmptyString()][string]$Text)
    [Console]::Out.Write($Text)
    [Console]::Out.Write("`n")
}

function Write-NSPolicyError {
    param([AllowEmptyString()][string]$Text)
    [Console]::Error.WriteLine($Text)
}

function Get-NSPolicyNow {
    $fixed = $env:NIGHTSHIFT_POLICY_NOW
    if (-not [string]::IsNullOrEmpty($fixed)) { return $fixed }
    return [DateTime]::UtcNow.ToString('yyyy-MM-dd\THH:mm:ss\Z', [Globalization.CultureInfo]::InvariantCulture)
}

function Get-NSPolicyPaths {
    param([Parameter(Mandatory = $true)][string]$Workspace)
    $ns = Join-NSPath (Get-NSAbsolutePath $Workspace) '.nightshift'
    $paths = New-NSOrdinalMap
    $paths['ns'] = $ns
    $paths['policy'] = Get-NSLayoutPath $ns 'shift-policy'
    $paths['defaults'] = Get-NSLayoutPath $ns 'shift-defaults'
    $paths['deadline'] = Get-NSLayoutPath $ns 'deadline'
    $paths['armed'] = Get-NSLayoutPath $ns 'armed'
    $paths['archive'] = Get-NSLayoutPath $ns 'archive'
    $paths['punch'] = Get-NSLayoutPath $ns 'punch-list'
    $paths['orders'] = Get-NSLayoutPath $ns 'work-orders'
    $paths['parking'] = Get-NSLayoutPath $ns 'parking-lot'
    $paths['rules'] = Get-NSLayoutPath $ns 'rules'
    return $paths
}

function Test-NSPolicyArmed {
    param([Parameter(Mandatory = $true)][string]$Workspace)
    return (Test-Path -LiteralPath (Get-NSPolicyPaths $Workspace)['armed'] -PathType Leaf)
}

# .NET has no POSIX character classes; the shipped patterns and any owner pattern
# in rules.elevation are grep -E. Same table as the hardhat hook's converter.
function Convert-NSPolicyErePattern {
    param([Parameter(Mandatory = $true)][string]$Pattern)
    $result = $Pattern.Replace('[[:space:]]', '\s')
    $result = $result.Replace('[[:blank:]]', '[ \t]')
    $result = $result.Replace('[[:digit:]]', '\d')
    $result = $result.Replace('[[:alnum:]]', '[A-Za-z0-9]')
    $result = $result.Replace('[[:alpha:]]', '[A-Za-z]')
    $result = $result.Replace('[[:lower:]]', '[a-z]')
    $result = $result.Replace('[[:upper:]]', '[A-Z]')
    $result = $result.Replace('[[:xdigit:]]', '[A-Fa-f0-9]')
    if ($result -match '\[:[a-z]+:\]') {
        throw 'unmapped POSIX character class'
    }
    return $result
}

function New-NSPolicyRegex {
    param([Parameter(Mandatory = $true)][string]$Pattern)
    return [Text.RegularExpressions.Regex]::new(
        (Convert-NSPolicyErePattern $Pattern),
        [Text.RegularExpressions.RegexOptions]::Multiline)
}

function Get-NSRulesElevationEntry {
    param(
        [Parameter(Mandatory = $true)][string]$Workspace,
        [Parameter(Mandatory = $true)][string]$Category
    )
    $rules = Get-NSRulesObject $Workspace
    if ($null -eq $rules) { return $null }
    $elevation = Get-NSJsonProperty $rules 'elevation'
    if ($null -eq $elevation) { return $null }
    return (Get-NSJsonProperty $elevation $Category)
}

function Get-NSElevationPattern {
    param(
        [Parameter(Mandatory = $true)][string]$Workspace,
        [Parameter(Mandatory = $true)][string]$Category
    )
    if (-not ($script:NSPolicyCategories -ccontains $Category)) { return '' }
    $entry = Get-NSRulesElevationEntry $Workspace $Category
    if ($null -ne $entry) {
        $pattern = Get-NSJsonProperty $entry 'pattern'
        if (($pattern -is [string]) -and $pattern.Length -gt 0) { return $pattern }
    }
    return [string]$script:NSPolicyElevationPattern[$Category]
}

function Get-NSElevationRulePolicy {
    param(
        [Parameter(Mandatory = $true)][string]$Workspace,
        [Parameter(Mandatory = $true)][string]$Category
    )
    $entry = Get-NSRulesElevationEntry $Workspace $Category
    if ($null -eq $entry) { return '' }
    $policy = Get-NSJsonProperty $entry 'policy'
    if (($policy -is [string]) -and (($policy -ceq 'allow') -or ($policy -ceq 'deny'))) { return $policy }
    return ''
}

# ---------------------------------------------------------------------------
# shift-policy.json
# ---------------------------------------------------------------------------

# A function that returns an array unrolls it, so a one-command plan would come
# back as a bare string. The comma keeps an array an array and a scalar a scalar.
function Get-NSPolicyField {
    param($Map, [Parameter(Mandatory = $true)][string]$Key)
    if (-not ($Map -is [Collections.IDictionary])) { return $null }
    if (-not $Map.Contains($Key)) { return $null }
    return , $Map[$Key]
}

function Test-NSPolicyShiftId {
    param($Value)
    if (-not ($Value -is [string])) { return $false }
    if ($Value -cmatch '^[0-9a-f]{16}$') { return $true }
    return ($Value -cmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
}

function Test-NSPolicyDigest {
    param($Value)
    return (($Value -is [string]) -and ($Value -cmatch '^[0-9a-f]{64}$'))
}

# The schema lives at references/schemas/v1/shift-policy.json; these are the same
# constraints, applied without a file read so a helper still validates on a host
# whose plugin tree is read-only or partially installed.
function Test-NSShiftPolicyDocument {
    param($Document)
    $errors = New-Object Collections.Generic.List[string]
    if (-not ($Document -is [Collections.IDictionary])) {
        $errors.Add('document: not a JSON object')
        return , $errors
    }
    $known = @('schemaVersion', 'shiftId', 'createdAt', 'source', 'deadlineEpoch',
        'verificationLevel', 'toolingPolicy', 'launchScope', 'launchProvenance', 'budgets',
        'allowances', 'gatesDigest', 'completionMode', 'selectedDebt', 'contractDigest', 'itemsDigest',
        'shift', 'recovery', 'handoff', 'archive', 'receipts')
    foreach ($key in @($Document.Keys)) {
        if (-not ($known -ccontains [string]$key)) {
            $errors.Add(([string]$key) + ': unknown field')
        }
    }
    foreach ($key in @('schemaVersion', 'shiftId', 'createdAt', 'source', 'verificationLevel', 'toolingPolicy')) {
        if (-not $Document.Contains($key)) { $errors.Add($key + ': missing') }
    }
    if ($Document.Contains('schemaVersion') -and -not (Test-NSEvidenceSchemaOne $Document['schemaVersion'])) {
        $errors.Add('schemaVersion: must be 1')
    }
    if ($Document.Contains('shiftId') -and -not (Test-NSPolicyShiftId $Document['shiftId'])) {
        $errors.Add('shiftId: must be a uuid or 16 lowercase hex characters')
    }
    if ($Document.Contains('createdAt') -and -not (($Document['createdAt'] -is [string]) -and ($Document['createdAt'] -cmatch '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'))) {
        $errors.Add('createdAt: must be YYYY-MM-DDTHH:MM:SSZ')
    }
    if ($Document.Contains('source') -and -not (Test-NSEvidenceEnum $Document['source'] $script:NSPolicySources)) {
        $errors.Add('source: must be one of ' + ($script:NSPolicySources -join ', '))
    }
    if ($Document.Contains('verificationLevel') -and -not (Test-NSEvidenceEnum $Document['verificationLevel'] $script:NSPolicyVerificationLevels)) {
        $errors.Add('verificationLevel: must be one of ' + ($script:NSPolicyVerificationLevels -join ', '))
    }
    if ($Document.Contains('toolingPolicy') -and -not (Test-NSEvidenceEnum $Document['toolingPolicy'] $script:NSPolicyToolingPolicies)) {
        $errors.Add('toolingPolicy: must be one of ' + ($script:NSPolicyToolingPolicies -join ', '))
    }
    if ($Document.Contains('completionMode') -and -not (Test-NSEvidenceEnum $Document['completionMode'] $script:NSPolicyCompletionModes)) {
        $errors.Add('completionMode: must be one of ' + ($script:NSPolicyCompletionModes -join ', '))
    }
    if ($Document.Contains('selectedDebt')) {
        $debt = Get-NSPolicyField $Document 'selectedDebt'
        if (($debt -is [Collections.IDictionary]) -or ($debt -is [string]) -or -not ($debt -is [Collections.IEnumerable])) {
            $errors.Add('selectedDebt: must be an array of finding ids')
        }
        else {
            foreach ($id in @($debt)) {
                if (-not (($id -is [string]) -and $id.Trim().Length -gt 0)) {
                    $errors.Add('selectedDebt: must be an array of non-empty strings')
                    break
                }
            }
        }
    }
    if ($Document.Contains('deadlineEpoch')) {
        $deadline = $Document['deadlineEpoch']
        if ($null -ne $deadline -and -not (Test-NSJsonInteger $deadline)) {
            $errors.Add('deadlineEpoch: must be an integer or null')
        }
    }
    if ($Document.Contains('gatesDigest') -and -not (Test-NSPolicyDigest $Document['gatesDigest'])) {
        $errors.Add('gatesDigest: must be 64 lowercase hex characters')
    }
    if ($Document.Contains('budgets')) {
        $budgets = $Document['budgets']
        if (-not ($budgets -is [Collections.IDictionary])) {
            $errors.Add('budgets: must be an object of integers')
        }
        else {
            foreach ($key in @($budgets.Keys)) {
                if (-not (Test-NSJsonInteger $budgets[$key])) {
                    $errors.Add('budgets.' + ([string]$key) + ': must be an integer')
                }
            }
        }
    }
    if ($Document.Contains('allowances')) {
        $allowances = $Document['allowances']
        if (($allowances -is [Collections.IDictionary]) -or ($allowances -is [string]) -or -not ($allowances -is [Collections.IEnumerable])) {
            $errors.Add('allowances: must be an array')
        }
        else {
            $index = 0
            foreach ($allowance in @($allowances)) {
                $label = 'allowances[' + $index + ']'
                $index++
                if (-not ($allowance -is [Collections.IDictionary])) {
                    $errors.Add($label + ': not a JSON object')
                    continue
                }
                foreach ($key in @($allowance.Keys)) {
                    if (-not (@('category', 'scope', 'provenance', 'plan') -ccontains [string]$key)) {
                        $errors.Add($label + '.' + ([string]$key) + ': unknown field')
                    }
                }
                if (-not (Test-NSEvidenceEnum (Get-NSMapValue $allowance 'category') $script:NSPolicyCategories)) {
                    $errors.Add($label + '.category: must be one of ' + ($script:NSPolicyCategories -join ', '))
                }
                if (-not (Test-NSEvidenceEnum (Get-NSMapValue $allowance 'scope') $script:NSPolicyScopes)) {
                    $errors.Add($label + '.scope: must be one of ' + ($script:NSPolicyScopes -join ', '))
                }
                if (-not (Test-NSEvidenceEnum (Get-NSMapValue $allowance 'provenance') $script:NSPolicyProvenances)) {
                    $errors.Add($label + '.provenance: must be one of ' + ($script:NSPolicyProvenances -join ', '))
                }
                $scope = Get-NSMapValue $allowance 'scope'
                $plan = Get-NSMapValue $allowance 'plan'
                if (($scope -is [string]) -and ($scope -ceq 'exact-plan')) {
                    foreach ($planError in (Test-NSPolicyPlan $plan ($label + '.plan'))) { $errors.Add($planError) }
                }
                elseif ($null -ne $plan) {
                    $errors.Add($label + '.plan: only an exact-plan allowance carries a plan')
                }
            }
        }
    }
    return , $errors
}

function Test-NSPolicyPlan {
    param($Plan, [Parameter(Mandatory = $true)][string]$Label)
    $errors = New-Object Collections.Generic.List[string]
    if (-not ($Plan -is [Collections.IDictionary])) {
        $errors.Add($Label + ': an exact-plan allowance needs a plan object')
        return , $errors
    }
    foreach ($key in @($Plan.Keys)) {
        if (-not (@('commands', 'workTarget', 'digest', 'expiry') -ccontains [string]$key)) {
            $errors.Add($Label + '.' + ([string]$key) + ': unknown field')
        }
    }
    $commands = Get-NSPolicyField $Plan 'commands'
    if (($commands -is [Collections.IDictionary]) -or ($commands -is [string]) -or -not ($commands -is [Collections.IEnumerable])) {
        $errors.Add($Label + '.commands: must be an array of strings')
    }
    else {
        $items = @($commands)
        if ($items.Count -eq 0) {
            $errors.Add($Label + '.commands: must list at least one command')
        }
        foreach ($command in $items) {
            if (-not (($command -is [string]) -and $command.Trim().Length -gt 0)) {
                $errors.Add($Label + '.commands: must be an array of non-empty strings')
                break
            }
        }
    }
    $target = Get-NSMapValue $Plan 'workTarget'
    if (-not (($target -is [string]) -and $target.Length -gt 0 -and [IO.Path]::IsPathRooted($target))) {
        $errors.Add($Label + '.workTarget: must be an absolute path')
    }
    if ($Plan.Contains('expiry')) {
        $expiry = $Plan['expiry']
        if ($null -ne $expiry -and -not (Test-NSJsonInteger $expiry)) {
            $errors.Add($Label + '.expiry: must be a UNIX epoch integer or null')
        }
    }
    if (-not (Test-NSPolicyDigest (Get-NSMapValue $Plan 'digest'))) {
        $errors.Add($Label + '.digest: must be 64 lowercase hex characters')
    }
    return , $errors
}

# The digest an exact-plan allowance carries and hardhat recomputes: sha256 over
# the compact canonical JSON of {"commands":[...],"shiftId":...,"workTarget":...}.
# plan.expiry is checked before the digest, never inside it.
function Get-NSPolicyPlanDigest {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Commands,
        [Parameter(Mandatory = $true)][string]$WorkTarget,
        [Parameter(Mandatory = $true)][string]$ShiftId
    )
    $normalized = New-Object Collections.Generic.List[string]
    foreach ($command in $Commands) { $normalized.Add((Get-NSPolicyNormalizedCommand $command)) }
    $preimage = New-NSOrdinalMap
    $preimage['commands'] = $normalized.ToArray()
    $preimage['shiftId'] = $ShiftId
    $preimage['workTarget'] = $WorkTarget
    return (Get-NSTextSha256 (ConvertTo-NSCanonicalJson $preimage -Compact))
}

# Whitespace runs collapse to one space and the ends are trimmed, so a command
# approved as written matches the command as the host reports it.
function Get-NSPolicyNormalizedCommand {
    param([AllowEmptyString()][string]$Command)
    if ([string]::IsNullOrEmpty($Command)) { return '' }
    return ([regex]::Replace($Command, '\s+', ' ')).Trim()
}

function Get-NSShiftPolicyState {
    param([Parameter(Mandatory = $true)][string]$Workspace)
    $paths = Get-NSPolicyPaths $Workspace
    return (Read-NSShiftPolicyFile ([string]$paths['policy']))
}

# Read-NSShiftPolicyFile <path> - one policy document, classified: absent, malformed or valid.
function Read-NSShiftPolicyFile {
    param([Parameter(Mandatory = $true)][string]$Path)
    $state = New-NSOrdinalMap
    $state['state'] = 'absent'
    $state['error'] = ''
    $state['policy'] = $null
    $path = $Path
    if (Test-NSReparsePoint $path) {
        $state['state'] = 'malformed'
        $state['error'] = 'document: shift-policy.json is not a usable file'
        return $state
    }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $state }
    $document = $null
    try {
        $document = ConvertFrom-NSJsonText ([IO.File]::ReadAllText($path, $script:NSUtf8NoBom))
    }
    catch {
        $state['state'] = 'malformed'
        $state['error'] = 'document: not valid JSON'
        return $state
    }
    $errors = Test-NSShiftPolicyDocument $document
    if ($errors.Count -gt 0) {
        $state['state'] = 'malformed'
        $state['error'] = $errors[0]
        return $state
    }
    $state['state'] = 'valid'
    $state['policy'] = $document
    return $state
}

# Find-NSReplayedShiftPolicy <workspace> - the archived copy of tonight's snapshot, when the archive
# has already filed a shift under its id: the policy in the folder that shift claimed, or a
# shift-policy-<id>.json an earlier version filed anywhere under the archive root. Empty when the
# snapshot is unreadable, carries no id, or has never run. Mirrors ns_policy_replayed.
function Find-NSReplayedShiftPolicy {
    param([Parameter(Mandatory = $true)][string]$Workspace)
    $state = Get-NSShiftPolicyState $Workspace
    if ([string]$state['state'] -cne 'valid') { return '' }
    $id = [string](Get-NSRecordText $state['policy'] 'shiftId')
    if ($id -cnotmatch '^[0-9a-f-]+$') { return '' }
    return (Find-NSArchivedShiftPolicy $Workspace $id)
}

# Get-NSReceiptPolicyState <workspace> - the policy the morning receipt reports. It is the live
# snapshot while one exists, and after clock-out only the copy filed for the shift the ending
# marker names. Any other archived snapshot is a different night's, and then this one has no
# policy record. Mirrors _find_policy and _match_policy in runtime/morning-receipt.sh.
function Get-NSReceiptPolicyState {
    param([Parameter(Mandatory = $true)][string]$Workspace)
    $paths = Get-NSPolicyPaths $Workspace
    $live = [string]$paths['policy']
    if (Test-NSPathEntry $live) { return (Read-NSShiftPolicyFile $live) }
    $state = New-NSOrdinalMap
    $state['state'] = 'absent'
    $state['error'] = ''
    $state['policy'] = $null
    $id = [string](Get-NSEndedField $Workspace 'shiftId')
    if ($id -cnotmatch '^[0-9a-f-]+$') { return $state }
    $filed = Find-NSArchivedShiftPolicy $Workspace $id
    if ([string]::IsNullOrEmpty($filed)) { return $state }
    $found = Read-NSShiftPolicyFile $filed
    # A file filed under this shift's id that names another shift inside is not this night's either.
    if ([string]$found['state'] -ceq 'valid' -and (Get-NSRecordText $found['policy'] 'shiftId') -cne $id) { return $state }
    return $found
}

function Get-NSShiftPolicy {
    param([Parameter(Mandatory = $true)][string]$Workspace)
    $state = Get-NSShiftPolicyState $Workspace
    return $state['policy']
}

# New-NSShiftId <nightshift-dir> - a lowercase 16-hex shift id that appears nowhere under the
# archive yet, so a fresh snapshot can never be mistaken for a night already filed.
function New-NSShiftId {
    param([Parameter(Mandatory = $true)][string]$NightshiftDir)
    $archive = Get-NSLayoutPath $NightshiftDir 'archive'
    for ($try = 0; $try -lt 8; $try++) {
        $bytes = New-Object byte[] 8
        [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
        $id = -join ($bytes | ForEach-Object { $_.ToString('x2') })
        if ((Test-Path -LiteralPath $archive -PathType Container) -and
            (Get-ChildItem -LiteralPath $archive -Recurse -File -Force -ErrorAction SilentlyContinue |
                Select-String -SimpleMatch -Pattern $id -Quiet)) { continue }
        return $id
    }
    return ''
}

# New-NSStartSnapshot <workspace> - tonight's snapshot for a Start with no composition behind it.
# A composed shift has its policy written before arming; a plain Start had none, so nothing
# recorded the contract and items it armed with and the gate could not tell a deleted item from a
# finished one. This writes one with source start-defaults and the values the resolved view already
# shows without a policy (no gate cadence, existing tools, and the deadline file's epoch or none)
# through the same writer composition uses, which records the digests and freezes the owner's
# preference blocks. Returns the new shift id, or '' when nothing was written.
function New-NSStartSnapshot {
    param([Parameter(Mandatory = $true)][string]$Workspace)
    $ns = Join-Path $Workspace '.nightshift'
    if (Test-Path -LiteralPath (Get-NSLayoutPath $ns 'shift-policy')) { return '' }
    $id = New-NSShiftId $ns
    if ([string]::IsNullOrEmpty($id)) { return '' }
    $deadline = 'null'
    $deadlinePath = Get-NSLayoutPath $ns 'deadline'
    if ((Test-Path -LiteralPath $deadlinePath -PathType Leaf) -and -not (Test-NSReparsePoint $deadlinePath)) {
        $value = ([IO.File]::ReadAllText($deadlinePath)).Trim()
        if ($value -match '^[0-9]+$') { $deadline = $value }
    }
    $created = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture)
    $json = '{"schemaVersion":1,"shiftId":"' + $id + '","createdAt":"' + $created +
        '","source":"start-defaults","deadlineEpoch":' + $deadline +
        ',"verificationLevel":"none","toolingPolicy":"existing-tools"}'
    if ((Set-NSShiftPolicy -Workspace $Workspace -Json $json) -ne 0) { return '' }
    return $id
}

function Set-NSShiftPolicy {
    param(
        [Parameter(Mandatory = $true)][string]$Workspace,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Json
    )
    $paths = Get-NSPolicyPaths $Workspace
    if (-not (Test-Path -LiteralPath $paths['ns'] -PathType Container)) {
        Write-NSPolicyError ('shift-policy: no .nightshift/ at ' + $Workspace)
        return 2
    }
    if (Test-NSPolicyArmed $Workspace) {
        Write-NSPolicyError 'shift-policy: refuse to rewrite the shift policy while the shift is armed; park the need'
        return 4
    }
    $document = $null
    try {
        $document = ConvertFrom-NSJsonText $Json
    }
    catch {
        Write-NSPolicyError 'shift-policy: document: not valid JSON'
        return 2
    }
    $errors = Test-NSShiftPolicyDocument $document
    if ($errors.Count -gt 0) {
        foreach ($error in $errors) { Write-NSPolicyError ('shift-policy: ' + $error) }
        return 2
    }
    # The contract as it stands right now, so the gate can tell later whether it moved. Two
    # digests: everything above the Items heading, which nobody may edit while a shift runs, and
    # the items with their checkbox state flattened, so a tick is invisible and any other edit is
    # not. A candidate that already states one is left as the owner wrote it.
    $punch = Get-NSLayoutPath $paths['ns'] 'punch-list'
    # Every item gets its permanent id before the items are digested, so the digest is of the list
    # the shift arms with, ids included. A document that already states the items digest was
    # written against the list as it is, and the list is left alone.
    if (-not $document.Contains('itemsDigest')) {
        if (-not (Add-NSPunchItemIds $punch $paths['ns'])) {
            Write-NSPolicyError ('shift-policy: the items in ' + $punch + ' could not be given ids; receipts stay named by label')
        }
    }
    # Receipts take the names their items carry now, before the shift arms and the names hold still.
    if (-not (Rename-NSReceipts $Workspace)) {
        Write-NSPolicyError ('shift-policy: a receipt in ' + (Get-NSReceiptsDir $Workspace) + ' could not take its item''s name; it keeps the one it has')
    }
    if (-not $document.Contains('contractDigest')) {
        $value = ''
        try { $value = Get-NSPunchContractDigest $punch } catch { $value = '' }
        if (-not [string]::IsNullOrEmpty($value)) { $document['contractDigest'] = $value }
    }
    if (-not $document.Contains('itemsDigest')) {
        $value = ''
        try { $value = Get-NSPunchItemsDigest $punch } catch { $value = '' }
        if (-not [string]::IsNullOrEmpty($value)) { $document['itemsDigest'] = $value }
    }

    # Record what this session is actually running under, so a revival can reproduce it instead of
    # guessing. It grants nothing - it is a note of what the shift already had - and a candidate
    # that states it already is left exactly as the owner wrote it.
    # Freeze the owner's preference blocks into tonight's policy. From here the shift reads them
    # here, so an edit to rules.json lands on the next shift rather than moving the ground under
    # this one. A candidate that already states a block is left exactly as it was written.
    foreach ($block in @('shift', 'recovery', 'handoff', 'archive', 'receipts')) {
        if ($document.Contains($block)) { continue }
        $frozen = New-NSOrdinalMap
        foreach ($name in $script:NSPolicyGroupDefaults.Keys) {
            if (-not $name.StartsWith($block + '.', [StringComparison]::Ordinal)) { continue }
            $frozen[$name.Substring($block.Length + 1)] = (Get-NSPolicyGroupSetting $Workspace $name)['value']
        }
        if ($frozen.Count -gt 0) { $document[$block] = $frozen }
    }
    if (-not $document.Contains('launchScope')) {
        $observed = (Get-NSLaunchObserved (Get-NSPolicyHostName)) -split "`t", 2
        $document['launchScope'] = $observed[0]
        $document['launchProvenance'] = $observed[1]
    }
    Write-NSEvidenceFileAtomic -Path $paths['policy'] -Text ((ConvertTo-NSCanonicalJson $document) + "`n")
    return 0
}

# ---------------------------------------------------------------------------
# shift-defaults.json - prefill only. Nothing here is ever an effective value.
# ---------------------------------------------------------------------------

function New-NSShiftDefaultsDocument {
    $document = New-NSOrdinalMap
    $document['schemaVersion'] = 1
    $document['verificationProfile'] = 'fast'
    $document['hours'] = $null
    $document['toolingPolicy'] = 'existing-tools'
    $document['execution'] = 'review-first'
    $document['updatedAt'] = ''
    return $document
}

function Get-NSShiftDefaults {
    param([Parameter(Mandatory = $true)][string]$Workspace)
    $paths = Get-NSPolicyPaths $Workspace
    $defaults = New-NSShiftDefaultsDocument
    $path = $paths['defaults']
    # Every way out of the legacy file goes through the shift block, so a workspace that has
    # already migrated - and so has no legacy file at all - still reports what the owner chose.
    if ((Test-NSReparsePoint $path) -or -not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return (Merge-NSShiftBlockDefaults -Workspace $Workspace -Defaults $defaults)
    }
    $document = $null
    try {
        $document = ConvertFrom-NSJsonText ([IO.File]::ReadAllText($path, $script:NSUtf8NoBom))
    }
    catch {
        return (Merge-NSShiftBlockDefaults -Workspace $Workspace -Defaults $defaults)
    }
    if (-not ($document -is [Collections.IDictionary])) {
        return (Merge-NSShiftBlockDefaults -Workspace $Workspace -Defaults $defaults)
    }
    $storedProfile = Get-NSMapValue $document 'verificationProfile'
    if (Test-NSEvidenceEnum $storedProfile $script:NSPolicyProfiles) { $defaults['verificationProfile'] = $storedProfile }
    $tooling = Get-NSMapValue $document 'toolingPolicy'
    if (Test-NSEvidenceEnum $tooling $script:NSPolicyToolingPolicies) { $defaults['toolingPolicy'] = $tooling }
    $execution = Get-NSMapValue $document 'execution'
    if (Test-NSEvidenceEnum $execution $script:NSPolicyExecutions) { $defaults['execution'] = $execution }
    $hours = Get-NSMapValue $document 'hours'
    if ((Test-NSJsonInteger $hours) -and [long]$hours -ge 0) { $defaults['hours'] = [long]$hours }
    $updated = Get-NSMapValue $document 'updatedAt'
    if ($updated -is [string]) { $defaults['updatedAt'] = $updated }
    return (Merge-NSShiftBlockDefaults -Workspace $Workspace -Defaults $defaults)
}

# The shift block of the owner file is where these live now. A value stated there is the owner's
# answer and wins over the older file, which stays readable only so a workspace that has not
# migrated yet still reports the choice it remembers.
function Merge-NSShiftBlockDefaults {
    param(
        [Parameter(Mandatory = $true)][string]$Workspace,
        [Parameter(Mandatory = $true)]$Defaults
    )
    $block = Get-NSShiftBlock $Workspace
    if ($null -eq $block) { return $Defaults }
    $stored = Get-NSMapValue $block 'verificationProfile'
    if (Test-NSEvidenceEnum $stored $script:NSPolicyProfiles) { $Defaults['verificationProfile'] = $stored }
    $stored = Get-NSMapValue $block 'toolingPolicy'
    if (Test-NSEvidenceEnum $stored $script:NSPolicyToolingPolicies) { $Defaults['toolingPolicy'] = $stored }
    $stored = Get-NSMapValue $block 'execution'
    if (Test-NSEvidenceEnum $stored $script:NSPolicyExecutions) { $Defaults['execution'] = $stored }
    if ($block.Contains('hours')) {
        $stored = Get-NSMapValue $block 'hours'
        if ($null -eq $stored) { $Defaults['hours'] = $null }
        elseif ((Test-NSJsonInteger $stored) -and [long]$stored -ge 0) { $Defaults['hours'] = [long]$stored }
    }
    return $Defaults
}

# Get-NSShiftBlock <workspace> - the shift object of the owner rules file, or $null.
# Get-NSRecoveryLaunchScope <workspace> - the scope the owner chose, as written.
#
# Legacy host-grant remains readable so recovery can refuse it explicitly. host-default uses
# independently configured host permissions; missing or invalid values inherit recorded scope.
function Get-NSRecoveryLaunchScope {
    param([Parameter(Mandatory = $true)][string]$Workspace)
    if (-not [string]::IsNullOrEmpty($env:NIGHTSHIFT_LAUNCH_SCOPE)) {
        if ($env:NIGHTSHIFT_LAUNCH_SCOPE -ceq 'host-default') { return 'host-default' }
        if ($env:NIGHTSHIFT_LAUNCH_SCOPE -ceq 'host-grant') { return 'host-grant' }
        return 'inherit-recorded-scope'
    }
    $path = (Get-NSPolicyPaths $Workspace)['rules']
    if ((Test-NSReparsePoint $path) -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { return 'inherit-recorded-scope' }
    $document = $null
    try {
        $document = ConvertFrom-NSJsonText ([IO.File]::ReadAllText($path, $script:NSUtf8NoBom))
    }
    catch {
        return 'inherit-recorded-scope'
    }
    if (-not ($document -is [Collections.IDictionary])) { return 'inherit-recorded-scope' }
    if (-not $document.Contains('recovery')) { return 'inherit-recorded-scope' }
    $block = $document['recovery']
    if (-not ($block -is [Collections.IDictionary])) { return 'inherit-recorded-scope' }
    $value = Get-NSMapValue $block 'launchScope'
    if ($value -ceq 'host-default') { return 'host-default' }
    if ($value -ceq 'host-grant') { return 'host-grant' }
    return 'inherit-recorded-scope'
}

# The ending marker carries what filing still needs after the live policy has moved. Clock-out
# archives the policy, and a later Archive would then have no shift id to name a directory after
# and no frozen archive settings to file into. One line per field, key=value; an empty marker
# stays a valid ending.
function Write-NSEndedRecord {
    param(
        [Parameter(Mandatory = $true)][string]$StateDir,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ShiftId,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ArchiveRoot,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ArchiveLayout,
        [AllowEmptyString()][string]$ShiftName = '',
        [AllowEmptyString()][string]$ArchiveFolder = ''
    )
    if (-not (Test-Path -LiteralPath $StateDir -PathType Container)) { return }
    $path = Get-NSLayoutPath $StateDir 'ended'
    if (Test-NSReparsePoint $path) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
    $text = "shiftId=$ShiftId`narchiveRoot=$ArchiveRoot`narchiveLayout=$ArchiveLayout`nshiftName=$ShiftName`narchiveFolder=$ArchiveFolder`n"
    [IO.File]::WriteAllText($path, $text, (New-Object Text.UTF8Encoding($false)))
}

# Get-NSShiftName <punch-list> - the name the owner gave the shift on the list's title line, as in
# `# Punch List - Archive follow-ups`, with an em or en dash, a hyphen or a colon after the words.
# '' when the title carries no name. Mirrors ns_shift_name.
function Get-NSShiftName {
    param([Parameter(Mandatory = $true)][string]$PunchList)
    if (-not (Test-Path -LiteralPath $PunchList -PathType Leaf) -or (Test-NSReparsePoint $PunchList)) { return '' }
    # Only the title line is read, and the reader is closed before returning: a handle left open
    # would stop the list being replaced when Archive trims it.
    $reader = New-Object IO.StreamReader($PunchList)
    try { $first = $reader.ReadLine() } finally { $reader.Dispose() }
    if ($null -eq $first) { $first = '' }
    $first = $first.TrimEnd([char]"`r")
    $dashes = [string][char]0x2014 + [char]0x2013
    if ($first -cmatch ('^#[ \t]+Punch[ \t]+List[ \t]*([' + $dashes + ']|-|:)[ \t]*(.*[^ \t])[ \t]*$')) { return $Matches[2] }
    return ''
}

# Get-NSEndedField <workspace> <key> - one field of the ending marker, or an empty string.
function Get-NSEndedField {
    param(
        [Parameter(Mandatory = $true)][string]$Workspace,
        [Parameter(Mandatory = $true)][string]$Key
    )
    $path = Get-NSLayoutPath (Join-Path $Workspace '.nightshift') 'ended'
    if ((Test-NSReparsePoint $path) -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { return '' }
    foreach ($line in [IO.File]::ReadAllLines($path)) {
        if ($line.StartsWith($Key + '=', [StringComparison]::Ordinal)) {
            return $line.Substring($Key.Length + 1)
        }
    }
    return ''
}

# ---------------------------------------------------------------------------
# Which form a clock-out block takes
#
# The POSIX half is ns_gate_reminder_* in hooks/shared/gate-core.sh. These have to decide the same
# way on the same facts, and produce the same fingerprint text byte for byte.
# ---------------------------------------------------------------------------

# Get-NSGateReminderFingerprint <open> <ticked> <item> <stopped> <deadline> <stall>
function Get-NSGateReminderFingerprint {
    param($Open, $Ticked, $Item, $Stopped, $Deadline, $Stall)
    function Fallback($v) { if ($null -eq $v -or "$v" -eq '') { return '?' } return "$v" }
    return ('open=' + (Fallback $Open) + ' ticked=' + (Fallback $Ticked) + ' item=' + (Fallback $Item) +
        ' stopped=' + (Fallback $Stopped) + ' deadline=' + (Fallback $Deadline) +
        ' stall=' + (Fallback $Stall))
}

# Format-NSGateReminder <short> <item> <open> <ticked> - the owner's own wording with the facts put
# in, by name, so dropping one keeps the rest of their sentence.
function Format-NSGateReminder {
    param([AllowEmptyString()][string]$Short, [AllowEmptyString()][string]$Item, $Open, $Ticked)
    $total = [int]$Open + [int]$Ticked
    $out = $Short.Replace('{item}', "$Item").Replace('{open}', "$Open")
    return $out.Replace('{ticked}', "$Ticked").Replace('{total}', "$total")
}

# Get-NSGateStallState <stall-file> <warn-every> - `warned` once the stall guard has begun saying
# so, `quiet` before that. Deliberately not the raw attempt count: that rises on every stop
# attempt without progress, so a fingerprint carrying it could never compare equal twice.
function Get-NSGateStallState {
    param([AllowEmptyString()][string]$Path, $WarnEvery)
    if ([string]::IsNullOrEmpty($Path) -or (Test-NSReparsePoint $Path) -or
        -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return 'quiet' }
    $lines = @([IO.File]::ReadAllLines($Path))
    if ($lines.Count -lt 2) { return 'quiet' }
    $n = $lines[1].Trim()
    if ($n -notmatch '^\d+$') { return 'quiet' }
    if ("$WarnEvery" -notmatch '^\d+$' -or [int]$WarnEvery -le 0) { return 'quiet' }
    if ([int]$n -ge [int]$WarnEvery) { return 'warned' }
    return 'quiet'
}

# Get-NSGateReminderText <workspace> <full> <open> <ticked> <item> <fingerprint>
#
# The whole contract unless the gate positively knows nothing has changed. Unknown always means
# the full text: a missing, empty or malformed comparison file, a context reset, the first block,
# and too many short lines in a row all send everything.
function Get-NSGateReminderText {
    param(
        [Parameter(Mandatory = $true)][string]$Workspace,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Full,
        $Open, $Ticked, [AllowEmptyString()][string]$Item,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Fingerprint
    )
    $ns = Join-Path $Workspace '.nightshift'
    $mode = [string](Get-NSPolicyGroupSettingOrRule $Workspace 'clockOutReminderMode')
    if ($mode -cne 'changed-only') {
        Save-NSGateReminder $ns $Fingerprint 0
        return (Add-NSGateReceiptsMissingNote $Workspace $Full)
    }
    $reset = Get-NSLayoutPath $ns 'context-reset'
    if (Test-Path -LiteralPath $reset) {
        Remove-Item -LiteralPath $reset -Force -ErrorAction SilentlyContinue
        Save-NSGateReminder $ns $Fingerprint 0
        return (Add-NSGateReceiptsMissingNote $Workspace $Full)
    }
    $file = Get-NSLayoutPath $ns 'clock-out-reminder'
    if ((Test-NSReparsePoint $file) -or -not (Test-Path -LiteralPath $file -PathType Leaf)) {
        Save-NSGateReminder $ns $Fingerprint 0
        return (Add-NSGateReceiptsMissingNote $Workspace $Full)
    }
    $lines = @([IO.File]::ReadAllLines($file))
    if ($lines.Count -lt 2 -or [string]::IsNullOrEmpty($lines[0]) -or $lines[1].Trim() -notmatch '^\d+$') {
        Save-NSGateReminder $ns $Fingerprint 0
        return (Add-NSGateReceiptsMissingNote $Workspace $Full)
    }
    if ($lines[0] -cne $Fingerprint) {
        Save-NSGateReminder $ns $Fingerprint 0
        return (Add-NSGateReceiptsMissingNote $Workspace $Full)
    }
    $count = [int]$lines[1].Trim()
    $limit = [string](Get-NSPolicyGroupSettingOrRule $Workspace 'clockOutReminderLimit')
    if ($limit -notmatch '^\d+$' -or [int]$limit -le 0) { $limit = 10 }
    if ($count -ge [int]$limit) {
        Save-NSGateReminder $ns $Fingerprint 0
        return (Add-NSGateReceiptsMissingNote $Workspace $Full)
    }
    $short = [string](Get-NSPolicyGroupSettingOrRule $Workspace 'clockOutReminder')
    if ([string]::IsNullOrEmpty($short)) {
        Save-NSGateReminder $ns $Fingerprint 0
        return (Add-NSGateReceiptsMissingNote $Workspace $Full)
    }
    Save-NSGateReminder $ns $Fingerprint ($count + 1)
    return (Add-NSGateReceiptsMissingNote $Workspace (Format-NSGateReminder $short $Item $Open $Ticked))
}

function Save-NSGateReminder {
    param([string]$StateDir, [AllowEmptyString()][string]$Fingerprint, [int]$Count)
    if (-not (Test-Path -LiteralPath $StateDir -PathType Container)) { return }
    $path = Get-NSLayoutPath $StateDir 'clock-out-reminder'
    if (Test-NSReparsePoint $path) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
    [IO.File]::WriteAllText($path, "$Fingerprint`n$Count`n", (New-Object Text.UTF8Encoding($false)))
}

# One reader for a top-level rules key, going through the same frozen-policy path every other
# setting uses.
function Get-NSPolicyGroupSettingOrRule {
    param([string]$Workspace, [string]$Key)
    return (Get-NSRule $Workspace $Key '')
}

# ---------------------------------------------------------------------------
# What a shift cost, read from the records the host already keeps
#
# The POSIX halves live in lib/usage.sh and lib/usage-*.awk. These have to answer identically on
# the same fixture: same deduplication, same field names, same order, same overlap sentence.
# ---------------------------------------------------------------------------

$script:NSUsageDimensions = @('input', 'cache_write', 'cache_read', 'output', 'reasoning')

# Get-NSUsageNumber <text> <key> - one number out of a line, or -1. A bounded scan rather than a
# JSON parse, the same way the POSIX reader works.
function Get-NSUsageNumber {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Line,
          [Parameter(Mandatory = $true)][string]$Key)
    $match = [Text.RegularExpressions.Regex]::Match($Line, '"' + [Text.RegularExpressions.Regex]::Escape($Key) + '":\s*(\d+)')
    if (-not $match.Success) { return -1 }
    return [long]$match.Groups[1].Value
}

# Get-NSUsageString <text> <key> - one string out of a line, or an empty string.
function Get-NSUsageString {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Line,
          [Parameter(Mandatory = $true)][string]$Key)
    $match = [Text.RegularExpressions.Regex]::Match($Line, '"' + [Text.RegularExpressions.Regex]::Escape($Key) + '":"([^"]*)"')
    if (-not $match.Success) { return '' }
    return $match.Groups[1].Value
}

# Read-NSUsageClaude <transcript> [offset] - the cumulative counter from a Claude Code transcript,
# deduplicated on request id. One response is written once per content block and each copy repeats
# the same usage, so summing lines would overstate the total; and a line that does not end in a
# closing brace was still being written, so nothing is taken from it.
function Read-NSUsageClaude {
    param([Parameter(Mandatory = $true)][string]$Path,
          [long]$Offset = 0,
          [AllowEmptyString()][string]$Carry = '')
    if ((Test-NSReparsePoint $Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $size = (Get-Item -LiteralPath $Path -Force).Length
    # A transcript that shrank is a different file under the same name. The carried identity
    # describes the file that is gone, so it goes with the offset.
    if ($Offset -lt 0 -or $Offset -gt $size) { $Offset = 0; $Carry = '' }
    $input = 0; $cachew = 0; $cacher = 0; $output = 0; $reason = 0
    $model = ''; $responses = 0
    # The identity of the last response counted, handed back so a response whose lines straddle two
    # reads is counted once. `changed` spends the carry as soon as a different identity appears.
    $last = ''; $changed = $false
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    if ($Offset -lt $size) {
        $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        try {
            $null = $stream.Seek($Offset, [IO.SeekOrigin]::Begin)
            $reader = New-Object IO.StreamReader($stream, (New-Object Text.UTF8Encoding($false)))
            while ($null -ne ($line = $reader.ReadLine())) {
                if ($line.IndexOf('"usage"', [StringComparison]::Ordinal) -lt 0) { continue }
                if (-not $line.EndsWith('}', [StringComparison]::Ordinal)) { continue }
                $id = Get-NSUsageString $line 'requestId'
                if ([string]::IsNullOrEmpty($id)) { $id = Get-NSUsageString $line 'id' }
                if ([string]::IsNullOrEmpty($id)) { continue }
                if ((-not [string]::IsNullOrEmpty($Carry)) -and $id -ceq $Carry -and -not $changed) { continue }
                if ($id -cne $Carry) { $changed = $true }
                if (-not $seen.Add($id)) { continue }
                $responses++
                $last = $id
                $m = Get-NSUsageString $line 'model'
                if (-not [string]::IsNullOrEmpty($m)) { $model = $m }
                foreach ($pair in @(@('input_tokens', 'input'), @('cache_creation_input_tokens', 'cachew'),
                        @('cache_read_input_tokens', 'cacher'), @('output_tokens', 'output'),
                        @('thinking_tokens', 'reason'))) {
                    $v = Get-NSUsageNumber $line $pair[0]
                    if ($v -lt 0) { continue }
                    switch ($pair[1]) {
                        'input' { $input += $v }
                        'cachew' { $cachew += $v }
                        'cacher' { $cacher += $v }
                        'output' { $output += $v }
                        'reason' { $reason += $v }
                    }
                }
            }
        }
        finally { $stream.Dispose() }
    }
    $fields = "input=$input,cache_write=$cachew,cache_read=$cacher,output=$output,reasoning=$reason"
    $tail = $(if ([string]::IsNullOrEmpty($last)) { $Carry } else { $last })
    return ($fields + "`t" + $size + "`t" + $model + "`t" + $responses + "`t" + $tail)
}

