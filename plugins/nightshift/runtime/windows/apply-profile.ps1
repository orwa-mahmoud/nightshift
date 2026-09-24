param(
    [string]$Project = [Environment]::CurrentDirectory,
    [string]$Profile = '',
    [ValidateSet('', 'replace', 'fill')][string]$Mode = '',
    [switch]$List,
    [switch]$Apply
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$pluginRoot = Resolve-Path (Join-Path $PSScriptRoot '../..')
Import-Module (Join-Path $pluginRoot 'lib/Nightshift.psm1') -Force -DisableNameChecking

$profilesDir = Join-Path $pluginRoot 'skills/nightshift/references/profiles'
$schemaPath = Join-Path $pluginRoot 'skills/nightshift/references/nightshift-rules.schema.json'
$templatePath = Join-Path $pluginRoot 'skills/nightshift/references/nightshift-rules-template.json'

try {
    $hostPath = Resolve-NSCanonicalPath $Project
}
catch {
    [Console]::Error.WriteLine("apply-profile: cannot cd to $Project")
    exit 1
}

try {
    $workspace = Resolve-NSWorkspaceRoot $hostPath
}
catch {
    [Console]::Error.WriteLine('apply-profile: invalid .nightshift-link')
    exit 2
}

$ns = Join-Path $workspace '.nightshift'
$rulesPath = Get-NSLayoutPath $ns 'rules'
$defaultsPath = Get-NSLayoutPath $ns 'shift-defaults'
$punchListPath = Get-NSLayoutPath $ns 'punch-list'

if ($List) {
    Write-Output 'Nightshift rule profiles (local copies, not a subscription)'
    foreach ($file in @(Get-ChildItem -LiteralPath $profilesDir -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
        try {
            $parsed = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json -ErrorAction Stop
            Write-Output ("  {0}  risk={1}  v{2}  {3}" -f $parsed.name, $parsed.risk, $parsed.version, $parsed.use)
        }
        catch {
            Write-Output ("  {0}" -f $file.Name)
        }
    }
    exit 0
}

if ($Mode -notin @('replace', 'fill')) {
    [Console]::Error.WriteLine('apply-profile: -Mode must be replace or fill')
    exit 1
}
if ([string]::IsNullOrEmpty($Profile) -or $Profile -notmatch '^[A-Za-z0-9_-]+$') {
    [Console]::Error.WriteLine("apply-profile: unknown profile $Profile")
    exit 1
}

$src = Join-Path $profilesDir "$Profile.json"
if (-not (Test-Path -LiteralPath $src -PathType Leaf)) {
    [Console]::Error.WriteLine("apply-profile: unknown profile $Profile")
    exit 1
}

try {
    $profileObj = Get-Content -LiteralPath $src -Raw | ConvertFrom-Json -ErrorAction Stop
    $schema = Get-Content -LiteralPath $schemaPath -Raw | ConvertFrom-Json -ErrorAction Stop
    $template = Get-Content -LiteralPath $templatePath -Raw | ConvertFrom-Json -ErrorAction Stop
}
catch {
    [Console]::Error.WriteLine('apply-profile: profile is malformed or not version 1 or 2')
    exit 2
}

$nameProp = $profileObj.PSObject.Properties['name']
$versionProp = $profileObj.PSObject.Properties['version']
$rulesProp = $profileObj.PSObject.Properties['rules']
if ($null -eq $nameProp -or $null -eq $versionProp `
    -or ([string]$versionProp.Value -ne '1' -and [string]$versionProp.Value -ne '2') `
    -or $null -eq $rulesProp -or $null -eq $rulesProp.Value `
    -or $rulesProp.Value -is [Array] -or $rulesProp.Value -is [string] -or $rulesProp.Value -is [ValueType]) {
    [Console]::Error.WriteLine('apply-profile: profile is malformed or not version 1 or 2')
    exit 2
}
$version = [string]$versionProp.Value

$schemaKeys = @{}
foreach ($property in $schema.properties.PSObject.Properties) {
    $schemaKeys[$property.Name] = $true
}
$unknown = New-Object Collections.Generic.List[string]
foreach ($property in $profileObj.rules.PSObject.Properties) {
    if (-not $schemaKeys.ContainsKey($property.Name) -or $property.Name -eq '$schema') {
        $null = $unknown.Add($property.Name)
    }
}
if ($unknown.Count -gt 0) {
    [Console]::Error.WriteLine("apply-profile: profile has unsupported keys: $($unknown -join ' ')")
    exit 2
}

# type/kind classification for a value already parsed by ConvertFrom-Json (mirrors jq's `type`).
function Get-NSJsonKind {
    param($Value)
    if ($null -eq $Value) { return 'null' }
    if ($Value -is [Array]) { return 'array' }
    if ($Value -is [string]) { return 'string' }
    if ($Value -is [bool]) { return 'boolean' }
    if ($Value -is [ValueType]) { return 'number' }
    return 'object'
}

$sdType = ''
$gatesType = ''
$sdValue = $null
$gatesValue = $null
if ($version -eq '2') {
    $sdProp = $profileObj.PSObject.Properties['shiftDefaults']
    if ($null -ne $sdProp) { $sdValue = $sdProp.Value }
    $sdType = Get-NSJsonKind $sdValue
    if ($sdType -ne 'null' -and $sdType -ne 'object') {
        [Console]::Error.WriteLine('apply-profile: profile shiftDefaults must be null or an object')
        exit 2
    }
    $gatesProp = $profileObj.PSObject.Properties['gates']
    if ($null -ne $gatesProp) { $gatesValue = $gatesProp.Value }
    $gatesType = Get-NSJsonKind $gatesValue
    if ($gatesType -ne 'null' -and $gatesType -ne 'object') {
        [Console]::Error.WriteLine('apply-profile: profile gates must be null or an object')
        exit 2
    }

    if ($sdType -eq 'object') {
        $knownSd = @('verificationProfile', 'hours', 'toolingPolicy', 'execution')
        $unknownSd = New-Object Collections.Generic.List[string]
        foreach ($property in $sdValue.PSObject.Properties) {
            if ($knownSd -notcontains $property.Name) {
                $null = $unknownSd.Add($property.Name)
            }
        }
        if ($unknownSd.Count -gt 0) {
            [Console]::Error.WriteLine("apply-profile: profile shiftDefaults has unsupported keys: $($unknownSd -join ' ')")
            exit 2
        }
        $vpProp = $sdValue.PSObject.Properties['verificationProfile']
        if ($null -ne $vpProp -and (@('fast', 'balanced', 'strict', 'custom') -notcontains [string]$vpProp.Value)) {
            [Console]::Error.WriteLine('apply-profile: profile shiftDefaults.verificationProfile must be fast, balanced, strict, or custom')
            exit 2
        }
        $hoursProp = $sdValue.PSObject.Properties['hours']
        if ($null -ne $hoursProp) {
            $hv = $hoursProp.Value
            if ($null -ne $hv -and -not ($hv -is [ValueType] -and $hv -isnot [bool])) {
                [Console]::Error.WriteLine('apply-profile: profile shiftDefaults.hours must be an integer or null')
                exit 2
            }
        }
        $tpProp = $sdValue.PSObject.Properties['toolingPolicy']
        if ($null -ne $tpProp -and (@('existing-tools', 'review-missing', 'auto-add') -notcontains [string]$tpProp.Value)) {
            [Console]::Error.WriteLine('apply-profile: profile shiftDefaults.toolingPolicy must be existing-tools, review-missing, or auto-add')
            exit 2
        }
        $execProp = $sdValue.PSObject.Properties['execution']
        if ($null -ne $execProp -and (@('review-first', 'run-direct') -notcontains [string]$execProp.Value)) {
            [Console]::Error.WriteLine('apply-profile: profile shiftDefaults.execution must be review-first or run-direct')
            exit 2
        }
    }

    if ($gatesType -eq 'object') {
        $itemGateProp = $gatesValue.PSObject.Properties['itemGate']
        $itemGateOk = $false
        if ($null -ne $itemGateProp -and $itemGateProp.Value -is [Array]) {
            $itemGateOk = $true
            foreach ($cmd in $itemGateProp.Value) {
                if ($cmd -isnot [string]) { $itemGateOk = $false; break }
            }
        }
        if (-not $itemGateOk) {
            [Console]::Error.WriteLine('apply-profile: profile gates.itemGate must be an array of command strings')
            exit 2
        }
        $siProp = $gatesValue.PSObject.Properties['siteInspection']
        if ($null -ne $siProp) {
            $siValue = $siProp.Value
            if ((Get-NSJsonKind $siValue) -ne 'object') {
                [Console]::Error.WriteLine('apply-profile: profile gates.siteInspection must be an object')
                exit 2
            }
            $everyProp = $siValue.PSObject.Properties['every']
            $every = if ($null -ne $everyProp) { [string]$everyProp.Value } else { '' }
            if ($every -notmatch '^[0-9]+ (items|hours)$') {
                [Console]::Error.WriteLine('apply-profile: profile gates.siteInspection.every must be "N items" or "H hours"')
                exit 2
            }
            $cmdsProp = $siValue.PSObject.Properties['commands']
            $cmdsOk = $false
            if ($null -ne $cmdsProp -and $cmdsProp.Value -is [Array]) {
                $cmdsOk = $true
                foreach ($cmd in $cmdsProp.Value) {
                    if ($cmd -isnot [string]) { $cmdsOk = $false; break }
                }
            }
            if (-not $cmdsOk) {
                [Console]::Error.WriteLine('apply-profile: profile gates.siteInspection.commands must be an array of command strings')
                exit 2
            }
        }
    }
}

if (-not (Test-Path -LiteralPath $ns -PathType Container)) {
    [Console]::Error.WriteLine('apply-profile: no .nightshift/ - run setup first')
    exit 2
}

if ($Apply -and (Test-Path -LiteralPath (Get-NSLayoutPath $ns 'armed') -PathType Leaf)) {
    [Console]::Error.WriteLine('apply-profile: refuse to write rules while the shift is armed')
    exit 2
}

if ($Apply -and $gatesType -eq 'object') {
    if (-not (Test-Path -LiteralPath $punchListPath -PathType Leaf)) {
        [Console]::Error.WriteLine('apply-profile: no punch-list.md - run setup first')
        exit 2
    }
    $plProbe = Get-Content -LiteralPath $punchListPath
    if (-not (@($plProbe) -contains '## Gates')) {
        [Console]::Error.WriteLine('apply-profile: punch-list.md has no "## Gates" heading')
        exit 2
    }
}

$current = [pscustomobject]@{}
if (Test-Path -LiteralPath $rulesPath -PathType Leaf) {
    try {
        $parsedCurrent = Get-Content -LiteralPath $rulesPath -Raw | ConvertFrom-Json -ErrorAction Stop
        if ($null -ne $parsedCurrent -and $parsedCurrent -isnot [Array] -and $parsedCurrent -isnot [string] -and $parsedCurrent -isnot [ValueType]) {
            $current = $parsedCurrent
        }
    }
    catch {
        $current = [pscustomobject]@{}
    }
}

function Copy-NSJsonObject {
    param($Object)
    if ($null -eq $Object) {
        return [pscustomobject]@{}
    }
    return ($Object | ConvertTo-Json -Depth 20 | ConvertFrom-Json)
}

function Get-NSJsonPropertyValue {
    param($Object, [string]$Name)
    if ($null -eq $Object) {
        return $null
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }
    return $property.Value
}

if ($Mode -eq 'fill') {
    $proposed = Copy-NSJsonObject $current
    foreach ($property in $profileObj.rules.PSObject.Properties) {
        if ($null -eq $proposed.PSObject.Properties[$property.Name]) {
            $proposed | Add-Member -NotePropertyName $property.Name -NotePropertyValue $property.Value
        }
    }
}
else {
    $proposed = Copy-NSJsonObject $template
    foreach ($property in $profileObj.rules.PSObject.Properties) {
        if ($null -eq $proposed.PSObject.Properties[$property.Name]) {
            $proposed | Add-Member -NotePropertyName $property.Name -NotePropertyValue $property.Value
        }
        else {
            $proposed.($property.Name) = $property.Value
        }
    }
    $schemaValue = Get-NSJsonPropertyValue $current '$schema'
    if ($schemaValue -is [string] -and -not [string]::IsNullOrEmpty($schemaValue)) {
        if ($null -eq $proposed.PSObject.Properties['$schema']) {
            $proposed | Add-Member -NotePropertyName '$schema' -NotePropertyValue $schemaValue
        }
        else {
            $proposed.'$schema' = $schemaValue
        }
    }
}

$toolDeny = Get-NSJsonPropertyValue $proposed 'toolDeny'
$ask = Get-NSJsonPropertyValue $toolDeny 'AskUserQuestion'
$request = Get-NSJsonPropertyValue $toolDeny 'request_user_input'
$cursorAsk = Get-NSJsonPropertyValue $toolDeny 'AskQuestion'
if ($null -eq $toolDeny -or $toolDeny -is [Array] -or $toolDeny -is [string] -or $toolDeny -is [ValueType] `
    -or $null -eq $toolDeny.PSObject.Properties['AskUserQuestion'] `
    -or $null -eq $toolDeny.PSObject.Properties['request_user_input'] `
    -or $null -eq $toolDeny.PSObject.Properties['AskQuestion'] `
    -or $ask -isnot [string] -or $request -isnot [string] -or $cursorAsk -isnot [string]) {
    [Console]::Error.WriteLine('apply-profile: proposed rules lack an explicit native question policy - re-run setup first')
    exit 2
}

# shift-defaults.json base: the current file when it parses and matches the shape, else the
# built-in defaults (a missing or malformed file decides nothing).
function Get-NSShiftDefaultsBase {
    param([string]$Path)
    $builtin = [pscustomobject]@{
        schemaVersion        = 1
        verificationProfile  = 'fast'
        hours                = $null
        toolingPolicy        = 'existing-tools'
        execution            = 'review-first'
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $builtin
    }
    try {
        $parsed = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        return $builtin
    }
    if ($null -eq $parsed -or $parsed -is [Array] -or $parsed -is [string] -or $parsed -is [ValueType]) {
        return $builtin
    }
    $svProp = $parsed.PSObject.Properties['schemaVersion']
    if ($null -eq $svProp -or [string]$svProp.Value -ne '1') {
        return $builtin
    }
    $vpProp = $parsed.PSObject.Properties['verificationProfile']
    if ($null -eq $vpProp -or (@('fast', 'balanced', 'strict', 'custom') -notcontains [string]$vpProp.Value)) {
        return $builtin
    }
    $hoursProp = $parsed.PSObject.Properties['hours']
    if ($null -eq $hoursProp) {
        return $builtin
    }
    $hv = $hoursProp.Value
    if ($null -ne $hv -and -not ($hv -is [ValueType] -and $hv -isnot [bool])) {
        return $builtin
    }
    $tpProp = $parsed.PSObject.Properties['toolingPolicy']
    if ($null -eq $tpProp -or (@('existing-tools', 'review-missing', 'auto-add') -notcontains [string]$tpProp.Value)) {
        return $builtin
    }
    $execProp = $parsed.PSObject.Properties['execution']
    if ($null -eq $execProp -or (@('review-first', 'run-direct') -notcontains [string]$execProp.Value)) {
        return $builtin
    }
    return $parsed
}

# Merge the profile's shiftDefaults over the base - only the keys the profile sets change.
function Merge-NSShiftDefaults {
    param($Base, $ProfileObj)
    $merged = Copy-NSJsonObject $Base
    $sdProp = $ProfileObj.PSObject.Properties['shiftDefaults']
    if ($null -ne $sdProp -and $null -ne $sdProp.Value) {
        $sd = $sdProp.Value
        foreach ($name in @('verificationProfile', 'hours', 'toolingPolicy', 'execution')) {
            $prop = $sd.PSObject.Properties[$name]
            if ($null -ne $prop) {
                if ($null -eq $merged.PSObject.Properties[$name]) {
                    $merged | Add-Member -NotePropertyName $name -NotePropertyValue $prop.Value
                }
                else {
                    $merged.$name = $prop.Value
                }
            }
        }
    }
    $now = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    if ($null -eq $merged.PSObject.Properties['schemaVersion']) {
        $merged | Add-Member -NotePropertyName schemaVersion -NotePropertyValue 1
    }
    else {
        $merged.schemaVersion = 1
    }
    if ($null -eq $merged.PSObject.Properties['updatedAt']) {
        $merged | Add-Member -NotePropertyName updatedAt -NotePropertyValue $now
    }
    else {
        $merged.updatedAt = $now
    }
    return $merged
}

# The rendered `## Gates` block body: the placeholder for an empty itemGate, else the item gate
# commands in the template's phrasing, plus the site inspection sentence when that key is
# present (a profile that omits siteInspection gets no site-inspection sentence at all).
function Get-NSGatesBody {
    param($ProfileObj)
    $itemGate = @($ProfileObj.gates.itemGate)
    if ($itemGate.Count -eq 0) {
        return '_None configured._'
    }
    $lines = New-Object Collections.Generic.List[string]
    [void]$lines.Add('**Item gate** - runs every item, right before its commit or artifact receipt:')
    [void]$lines.Add('')
    foreach ($cmd in $itemGate) {
        [void]$lines.Add('- `' + $cmd + '`')
    }
    $siProp = $ProfileObj.gates.PSObject.Properties['siteInspection']
    if ($null -ne $siProp) {
        $si = $siProp.Value
        [void]$lines.Add('')
        [void]$lines.Add(('**Site inspection** - the heavier batch, every {0}:' -f $si.every))
        $siCommands = @($si.commands)
        if ($siCommands.Count -eq 0) {
            [void]$lines.Add('')
            [void]$lines.Add('_None configured._')
        }
        else {
            [void]$lines.Add('')
            foreach ($cmd in $siCommands) {
                [void]$lines.Add('- `' + $cmd + '`')
            }
        }
    }
    return ($lines -join "`n")
}

Write-Output ("Profile: {0}" -f $profileObj.name)
Write-Output ("Risk:    {0}" -f $profileObj.risk)
Write-Output ("Use:     {0}" -f $profileObj.use)
Write-Output ("Mode:    {0}" -f $Mode)
Write-Output 'Rules the profile sets:'
foreach ($property in $profileObj.rules.PSObject.Properties) {
    $json = $property.Value | ConvertTo-Json -Compress -Depth 5
    Write-Output ("  {0}={1}" -f $property.Name, $json)
}
Write-Output ''
Write-Output 'Proposed rules.json'
Write-Output ($proposed | ConvertTo-Json -Depth 20)

if ($sdType -eq 'object') {
    $sdBase = Get-NSShiftDefaultsBase $defaultsPath
    $sdMerged = Merge-NSShiftDefaults $sdBase $profileObj
    Write-Output ''
    Write-Output 'Proposed shift-defaults.json'
    Write-Output ($sdMerged | ConvertTo-Json -Depth 20)
}

if ($gatesType -eq 'object') {
    Write-Output ''
    Write-Output 'Proposed ## Gates block'
    Write-Output (Get-NSGatesBody $profileObj)
}

if (-not $Apply) {
    Write-Output ''
    Write-Output 'Dry run. Re-run with -Apply after explicit confirmation.'
    exit 0
}

$json = ($proposed | ConvertTo-Json -Depth 20)
if (-not $json.EndsWith("`n")) {
    $json += [Environment]::NewLine
}
$tmp = Join-Path $ns ('.rules.json.{0}' -f $PID)
try {
    [IO.File]::WriteAllText($tmp, $json, (New-Object Text.UTF8Encoding $false))
    Move-Item -LiteralPath $tmp -Destination $rulesPath -Force
}
catch {
    if (Test-Path -LiteralPath $tmp -PathType Leaf) {
        Remove-NSFile $tmp
    }
    exit 2
}
Write-Output "Wrote $rulesPath"

if ($sdType -eq 'object') {
    $sdBase = Get-NSShiftDefaultsBase $defaultsPath
    $sdMerged = Merge-NSShiftDefaults $sdBase $profileObj
    $sdJson = ($sdMerged | ConvertTo-Json -Depth 20) -replace "`r`n", "`n"
    if (-not $sdJson.EndsWith("`n")) {
        $sdJson += "`n"
    }
    $tmpSd = Join-Path $ns ('.shift-defaults.json.{0}' -f $PID)
    try {
        [IO.File]::WriteAllText($tmpSd, $sdJson, (New-Object Text.UTF8Encoding $false))
        Move-Item -LiteralPath $tmpSd -Destination $defaultsPath -Force
    }
    catch {
        if (Test-Path -LiteralPath $tmpSd -PathType Leaf) {
            Remove-NSFile $tmpSd
        }
        exit 2
    }
    Write-Output "Wrote $defaultsPath"
}

if ($gatesType -eq 'object') {
    $plLines = @(Get-Content -LiteralPath $punchListPath)
    $gatesIdx = -1
    for ($i = 0; $i -lt $plLines.Count; $i++) {
        if ($plLines[$i] -eq '## Gates') { $gatesIdx = $i; break }
    }
    if ($gatesIdx -lt 0) {
        [Console]::Error.WriteLine('apply-profile: punch-list.md has no "## Gates" heading')
        exit 2
    }
    $nextIdx = $plLines.Count
    for ($i = $gatesIdx + 1; $i -lt $plLines.Count; $i++) {
        if ($plLines[$i] -like '## *') { $nextIdx = $i; break }
    }
    $body = Get-NSGatesBody $profileObj
    $newLines = New-Object Collections.Generic.List[string]
    for ($i = 0; $i -le $gatesIdx; $i++) { [void]$newLines.Add($plLines[$i]) }
    [void]$newLines.Add('')
    [void]$newLines.Add('<!-- Nightshift Setup fills this from your stack, or leaves it empty (no automated checks).')
    [void]$newLines.Add('     Item gate: runs every item, right before its commit or artifact receipt - must be green to tick.')
    [void]$newLines.Add('     Site inspection: the heavier batch (coverage, dead code, Sonar), every N items or H hours. -->')
    [void]$newLines.Add('')
    foreach ($bodyLine in ($body -split "`n")) { [void]$newLines.Add($bodyLine) }
    [void]$newLines.Add('')
    for ($i = $nextIdx; $i -lt $plLines.Count; $i++) { [void]$newLines.Add($plLines[$i]) }

    $plText = ($newLines -join "`n") + "`n"
    $tmpPl = Join-Path $ns ('.punch-list.md.{0}' -f $PID)
    try {
        [IO.File]::WriteAllText($tmpPl, $plText, (New-Object Text.UTF8Encoding $false))
        Move-Item -LiteralPath $tmpPl -Destination $punchListPath -Force
    }
    catch {
        if (Test-Path -LiteralPath $tmpPl -PathType Leaf) {
            Remove-NSFile $tmpPl
        }
        exit 2
    }
    Write-Output "Wrote $punchListPath"
}

exit 0
