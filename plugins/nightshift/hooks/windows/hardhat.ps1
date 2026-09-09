param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('claude', 'codex')]
    [string]$HostName,
    [Parameter(ValueFromPipeline = $true)]
    [AllowEmptyString()]
    [string]$HookJson = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if (Test-Path Variable:PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $false
}

$pluginRoot = Resolve-Path (Join-Path $PSScriptRoot '../..')
Import-Module (Join-Path $pluginRoot 'lib/Nightshift.psm1') -Force -DisableNameChecking
$script:cwd = ''
$script:ns = ''

function Write-Deny {
    param([Parameter(Mandatory = $true)][string]$Reason)
    if ((Test-Path Variable:workspace) -and -not [string]::IsNullOrEmpty($workspace)) {
        $Reason = Expand-NSInjectedPaths $workspace $Reason
    }
    $output = @{
        hookSpecificOutput = @{
            hookEventName = 'PreToolUse'
            permissionDecision = 'deny'
            permissionDecisionReason = $Reason
        }
    }
    [Console]::Out.WriteLine(($output | ConvertTo-Json -Compress -Depth 5))
    exit 0
}

function Get-PropertyValue {
    param(
        [AllowNull()][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowNull()][object]$Default = ''
    )
    if ($null -eq $Object) {
        return $Default
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) {
        return $Default
    }
    return $property.Value
}

function Remove-NSCommitMessage {
    param([AllowEmptyString()][string]$Command)

    $quotedPattern = @'
(?is)(?<!\S)(?<option>-m|--message)(?<separator>=|\s*)(?<value>'[^']*'|"(?:\\.|[^"])*")
'@
    $quoted = [Text.RegularExpressions.Regex]::new($quotedPattern)
    $Command = $quoted.Replace($Command, [Text.RegularExpressions.MatchEvaluator]{
        param($match)
        $value = $match.Groups['value'].Value
        $separator = $match.Groups['separator'].Value
        if ([string]::IsNullOrEmpty($separator) -and $value[0] -notin @("'", '"')) {
            return $match.Value
        }
        if ($value[0] -eq '"' -and ($value.Contains('$(') -or $value.Contains('`'))) {
            return $match.Value
        }
        return $match.Groups['option'].Value + $separator + 'MSG'
    })

    $plainPattern = @'
(?is)(?<!\S)(?<option>-m|--message)(?<separator>=|\s+)(?<value>[^\s'"]+)
'@
    $plain = [Text.RegularExpressions.Regex]::new($plainPattern)
    return $plain.Replace($Command, '${option}${separator}MSG')
}

function Get-NSNestedStrings {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) {
        return
    }
    if ($Value -is [string]) {
        $Value
        return
    }
    if ($Value -is [Collections.IEnumerable] -and $Value -isnot [Management.Automation.PSCustomObject]) {
        foreach ($entry in $Value) {
            Get-NSNestedStrings $entry
        }
        return
    }
    foreach ($property in $Value.PSObject.Properties) {
        Get-NSNestedStrings $property.Value
    }
}

function Get-NSPayloadTargets {
    param(
        [AllowNull()][object]$ToolInput,
        [AllowEmptyString()][string]$ToolName,
        [AllowEmptyString()][string]$Command
    )
    if ($ToolName -in @('Bash', 'PowerShell')) {
        Remove-NSCommitMessage $Command
        return
    }
    if ($ToolName -eq 'apply_patch') {
        foreach ($line in ($Command -split "`r?`n")) {
            if ($line -match '^\*\*\* (?:Add|Update|Delete) File:\s*(.+)$' -or $line -match '^\*\*\* Move to:\s*(.+)$') {
                $Matches[1]
            }
        }
        return
    }
    if ($null -eq $ToolInput) {
        return
    }

    $pathKey = '(?i)((^|_)(path|filepath|file|filename|directory|dir|uri|name)$|^(target|destination|dest|source|src)$)'
    $commandKey = '(?i)(^|_)(command|cmd|script)$'
    function Walk-Input {
        param([AllowNull()][object]$Value)
        if ($null -eq $Value -or $Value -is [string] -or $Value -is [ValueType]) {
            return
        }
        if ($Value -is [Collections.IEnumerable] -and $Value -isnot [Management.Automation.PSCustomObject]) {
            foreach ($entry in $Value) {
                Walk-Input $entry
            }
            return
        }
        $directories = @()
        $names = @()
        foreach ($property in $Value.PSObject.Properties) {
            $strings = @(Get-NSNestedStrings $property.Value)
            if ($property.Name -match $commandKey) {
                foreach ($string in $strings) {
                    Remove-NSCommitMessage $string
                }
            }
            elseif ($property.Name -match $pathKey) {
                $strings
            }
            if ($property.Name -match '^(?i:directory|dir)$') {
                $directories += $strings
            }
            if ($property.Name -match '^(?i:name|filename|file)$') {
                $names += $strings
            }
            Walk-Input $property.Value
        }
        foreach ($directory in $directories) {
            foreach ($name in $names) {
                Join-Path $directory $name
            }
        }
    }
    Walk-Input $ToolInput
}

function Test-NSRulesTarget {
    param([AllowEmptyString()][string]$Target)
    $normalized = $Target.Replace('\', '/')
    return $normalized -match '(?i)\.nightshift/rules\.json|nightshift-rules\.json' `
        -or ($normalized -match '(?i)\.nightshift' -and $normalized -match '(?i)rules\.json')
}

function Resolve-NSFollowSymlink {
    param([AllowEmptyString()][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        return $null
    }
    $item = Get-Item -LiteralPath $Path -Force
    $raw = $null
    if ($item.PSObject.Properties['LinkType'] -and $item.LinkType) {
        $raw = $item.Target
    }
    elseif ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        $raw = $item.Target
    }
    if ($null -eq $raw) {
        return $null
    }
    $dest = if ($raw -is [System.Array]) { [string]$raw[0] } else { [string]$raw }
    if ([string]::IsNullOrEmpty($dest)) {
        return $null
    }
    if (-not [IO.Path]::IsPathRooted($dest)) {
        $parent = Split-Path -Parent $Path
        if ([string]::IsNullOrEmpty($parent)) {
            return Resolve-NSWriteTarget $dest
        }
        $dest = Join-Path $parent $dest
    }
    return Resolve-NSWriteTarget $dest
}

function Test-NSWriteTargetReachesRules {
    param([AllowEmptyString()][string]$Target)
    if ([string]::IsNullOrWhiteSpace($Target) -or [string]::IsNullOrEmpty($script:ns)) {
        return $false
    }
    $rules = Resolve-NSWriteTarget (Join-Path $script:ns 'rules.json')
    if ($null -eq $rules) {
        return $false
    }
    $canon = Resolve-NSWriteTarget $Target
    if ($null -eq $canon) {
        return $false
    }
    if ($canon -ceq $rules) {
        return $true
    }
    $hop = Resolve-NSFollowSymlink $canon
    if ($null -ne $hop -and $hop -ceq $rules) {
        return $true
    }
    $lex = $Target.Replace('"', '').Replace("'", '').Replace('\', '/')
    if (-not [IO.Path]::IsPathRooted($lex)) {
        $base = if (-not [string]::IsNullOrEmpty($script:cwd)) { $script:cwd } else { Split-Path -Parent $script:ns }
        if ([string]::IsNullOrEmpty($base)) {
            return $false
        }
        $lex = (Join-Path $base $lex).Replace('\', '/')
    }
    $acc = ''
    foreach ($part in ($lex.TrimStart('/') -split '/')) {
        if ([string]::IsNullOrEmpty($part) -or $part -eq '.') {
            continue
        }
        if ($part -eq '..') {
            $acc = if ([string]::IsNullOrEmpty($acc) -or $acc -eq '/') { '/' } else { $acc.Substring(0, $acc.LastIndexOf('/')) }
            continue
        }
        $acc = if ([string]::IsNullOrEmpty($acc) -or $acc -eq '/') { "/$part" } else { "$acc/$part" }
        $hop = Resolve-NSFollowSymlink ($acc.Replace('/', [IO.Path]::DirectorySeparatorChar))
        if ($null -ne $hop -and $hop -ceq $rules) {
            return $true
        }
    }
    return $false
}

function Test-NSRealParkingLot {
    param([AllowEmptyString()][string]$Target)
    if ([string]::IsNullOrWhiteSpace($Target)) {
        return $false
    }
    if (Test-NSWriteTargetReachesRules $Target) {
        return $false
    }
    $parking = Resolve-NSWriteTarget (Join-Path $script:ns 'parking-lot.md')
    $canon = Resolve-NSWriteTarget $Target
    return ($null -ne $parking -and $null -ne $canon -and $canon -ceq $parking)
}

function Get-NSLiteralAppendTarget {
    param([AllowEmptyString()][string]$Command)
    if ([string]::IsNullOrEmpty($Command)) {
        return $null
    }
    $s = $Command
    $n = $s.Length
    $i = 0
    $q = $null
    $appends = 0
    $extraRedir = 0
    $extras = 0
    $target = ''
    $collecting = $false
    $word = ''
    while ($i -lt $n) {
        $c = $s[$i]
        $next = if ($i + 1 -lt $n) { $s[$i + 1] } else { [char]0 }
        if ($null -ne $q) {
            if ($c -eq '\' -and $q -eq '"') {
                $i += 2
                continue
            }
            if ($c -eq $q) {
                $q = $null
                $i += 1
                continue
            }
            if ($q -eq '"' -and ($c -eq '$' -or $c -eq '`')) {
                return $null
            }
            $i += 1
            continue
        }
        if ($c -eq "'" -or $c -eq '"') {
            if ($collecting) {
                $q = $c
                $i += 1
                while ($i -lt $n -and $s[$i] -ne $q) {
                    if ($q -eq '"' -and ($s[$i] -eq '$' -or $s[$i] -eq '`')) {
                        return $null
                    }
                    $word += $s[$i]
                    $i += 1
                }
                if ($i -ge $n) {
                    return $null
                }
                $target = $word
                $collecting = $false
                $word = ''
                $q = $null
                $i += 1
                continue
            }
            $q = $c
            $i += 1
            continue
        }
        if ($c -eq '$' -or $c -eq '`' -or $c -eq '(') {
            return $null
        }
        if ($c -eq '>' -and $next -eq '>') {
            $appends += 1
            $collecting = $true
            $word = ''
            $i += 2
            while ($i -lt $n -and ($s[$i] -eq ' ' -or $s[$i] -eq "`t")) {
                $i += 1
            }
            continue
        }
        if ($c -eq '>') {
            $extraRedir += 1
            $i += 1
            continue
        }
        if ($c -eq '<' -and $next -eq '<') {
            $collecting = $false
            $i += 2
            continue
        }
        if ($c -eq '<') {
            $extraRedir += 1
            $i += 1
            continue
        }
        if ($c -eq '|' -or $c -eq ';') {
            $extras += 1
            $collecting = $false
            $i += 1
            continue
        }
        if ($c -eq '&') {
            $extras += 1
            $collecting = $false
            $i += $(if ($next -eq '&') { 2 } else { 1 })
            continue
        }
        if ($collecting) {
            if ($c -eq ' ' -or $c -eq "`t" -or $c -eq "`n") {
                if (-not [string]::IsNullOrEmpty($word)) {
                    $target = $word
                    $collecting = $false
                    $word = ''
                }
                $i += 1
                continue
            }
            $word += $c
            $i += 1
            continue
        }
        $i += 1
    }
    if ($null -ne $q) {
        return $null
    }
    if ($appends -ne 1 -or $extraRedir -ne 0 -or $extras -ne 0) {
        return $null
    }
    if ([string]::IsNullOrEmpty($target)) {
        $target = $word
    }
    if ([string]::IsNullOrEmpty($target) -or $target -match '[*?[]') {
        return $null
    }
    $trimmed = $s.TrimStart()
    $first = ($trimmed -split '\s+', 2)[0]
    if ([string]::IsNullOrEmpty($first)) {
        return $null
    }
    if ($first -notin @('echo', 'printf', 'cat') -and $first[0] -notin @([char]"'", [char]'"')) {
        return $null
    }
    return $target
}

function Test-NSInertParkingLotWrite {
    param(
        [AllowEmptyString()][string]$ToolName,
        [AllowNull()][object]$ToolInput,
        [AllowEmptyString()][string]$Command
    )
    if ($ToolName -in @('Bash', 'PowerShell', 'Shell')) {
        $appendTarget = Get-NSLiteralAppendTarget $Command
        return (Test-NSRealParkingLot $appendTarget)
    }
    $paths = @(Get-NSPayloadTargets $ToolInput $ToolName $Command)
    if ($paths.Count -ne 1) {
        return $false
    }
    return Test-NSRealParkingLot ([string]$paths[0])
}

function Test-NSLeaseTarget {
    param([AllowEmptyString()][string]$Target)
    $normalized = $Target.Replace('\', '/').Replace('"', '').Replace("'", '')
    if ($normalized -match '(?i)(^|/)(\.shift-lease|\.mutex-scope)($|[^A-Za-z0-9_-])|(^|/)\.lease-lock\.d($|/)') {
        return $true
    }
    $nightshiftContext = Test-NSNightshiftDirContext $normalized
    if ($nightshiftContext -and
        $normalized -match '(?i)\.nightshift/(?:\.\*|\*|\?|\[|\{|\$|`)') {
        return $true
    }
    if ($nightshiftContext -and $normalized -match '(?i)\.(shift|lease|mutex)-(?:\*|\?|\[|\{|\$|`)') {
        return $true
    }
    if ($normalized -match '(?i)(^|[;&|()\s])(rm|rmdir|unlink|mv|Remove-Item|Move-Item|Rename-Item)\s+([^;&|\r\n]*\s+)?(\./)?\.nightshift/?([;&|()\s]|$)') {
        return $true
    }
    if ($normalized -match '(?i)(^|[;&|\s])find(\s|$)' -and $normalized -match '(?i)\.nightshift' `
        -and $normalized -match '(?i)(-delete|-exec)') {
        return $true
    }
    return $false
}

function Test-NSNightshiftDirContext {
    param([AllowEmptyString()][string]$Normalized)
    # `cd .nightshift && unlink .shift-armed` has no slash after the directory name.
    if ($Normalized -match '(?i)\.nightshift([/\s;&]|$)') {
        return $true
    }
    if ($Normalized -match '(?i)(^|[;&|()\s])(cd|pushd|Set-Location)(?:\s+-LiteralPath)?\s+[''"]?\.nightshift\b') {
        return $true
    }
    $cwdValue = [string]$script:cwd
    $nsValue = [string]$script:ns
    if (-not [string]::IsNullOrEmpty($cwdValue) -and -not [string]::IsNullOrEmpty($nsValue)) {
        $cwdNorm = $cwdValue.Replace('\', '/').TrimEnd('/')
        $nsNorm = $nsValue.Replace('\', '/').TrimEnd('/')
        if ($cwdNorm -eq $nsNorm -or $cwdNorm.StartsWith("$nsNorm/")) {
            return $true
        }
    }
    return $false
}

# The shift policy, the remembered defaults and the derived deadline are control files too:
# tonight's authority is written before arming, so an armed agent that could rewrite it could
# widen its own permissions. Regex is a pre-filter; a write is a hit only when the
# target's canonical absolute path equals $ns/<control-file>.
function Test-NSControlPrefilter {
    param([AllowEmptyString()][string]$Target)
    return $Target -match '(?i)(STOP|\.shift-armed|\.ended|\.shift-session|\.shift-worker|work-target|work-mode|shift-policy\.json|shift-defaults\.json|deadline|punch-list\.md)'
}

function Test-NSControlDeleteVerb {
    param([AllowEmptyString()][string]$Target)
    return $Target -match '(?i)(^|[;&|()\s])(rm|rmdir|unlink|mv|Remove-Item|Move-Item|Rename-Item)([\s]|$)'
}

function Test-NSControlBareName {
    param([AllowEmptyString()][string]$Token)
    return $Token -match '(?i)^(\./)?(STOP|\.shift-armed|\.ended|\.shift-session|\.shift-worker|work-target|work-mode|shift-policy\.json|shift-defaults\.json|deadline|punch-list\.md)$'
}

# Physical directory path, including symlink and junction ancestors. Matches POSIX cd -P.
function Resolve-NSPhysicalDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $full -PathType Container)) {
        throw 'not a directory'
    }
    if (Test-Path -LiteralPath '/bin/pwd' -PathType Leaf) {
        $here = Get-Location
        try {
            Set-Location -LiteralPath $full
            $physical = & /bin/pwd -P
            if (-not [string]::IsNullOrWhiteSpace($physical)) {
                return [string]$physical
            }
        }
        finally {
            Set-Location $here
        }
    }
    $root = [IO.Path]::GetPathRoot($full)
    $relative = $full.Substring($root.Length).Trim([char]'\', [char]'/')
    if ($root -eq '/' -or $root -eq '\') {
        $acc = '/'
    }
    else {
        $acc = $root
    }
    if (-not [string]::IsNullOrEmpty($relative)) {
        foreach ($part in ($relative -split '[\\/]+')) {
            if ([string]::IsNullOrEmpty($part) -or $part -eq '.') {
                continue
            }
            $next = if ($acc -eq '/') { "/$part" } else { Join-Path $acc $part }
            $item = Get-Item -LiteralPath $next -Force
            $target = $null
            if ($item.PSObject.Properties['LinkType'] -and $item.LinkType) {
                $raw = $item.Target
                $target = if ($raw -is [System.Array]) { [string]$raw[0] } else { [string]$raw }
            }
            elseif ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                $raw = $item.Target
                $target = if ($raw -is [System.Array]) { [string]$raw[0] } else { [string]$raw }
            }
            if (-not [string]::IsNullOrEmpty($target)) {
                if (-not [IO.Path]::IsPathRooted($target)) {
                    $target = Join-Path (Split-Path -Parent $next) $target
                }
                $acc = [IO.Path]::GetFullPath($target)
            }
            else {
                $acc = $item.FullName
            }
        }
    }
    return [IO.Path]::GetFullPath($acc)
}

function Resolve-NSWriteTarget {
    param([AllowEmptyString()][string]$Target)
    $normalized = $Target.Replace('"', '').Replace("'", '')
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        return $null
    }
    if (-not [IO.Path]::IsPathRooted($normalized)) {
        $base = $null
        if (-not [string]::IsNullOrEmpty($script:cwd)) {
            $base = $script:cwd
        }
        elseif (-not [string]::IsNullOrEmpty($script:ns)) {
            $base = Split-Path -Parent $script:ns
        }
        if ([string]::IsNullOrEmpty($base)) {
            return $null
        }
        $normalized = Join-Path $base $normalized
    }
    $full = [IO.Path]::GetFullPath($normalized)
    $parent = Split-Path -Parent $full
    $leaf = Split-Path -Leaf $full
    if ([string]::IsNullOrEmpty($parent) -or -not (Test-Path -LiteralPath $parent -PathType Container)) {
        return $null
    }
    try {
        $parentCanon = Resolve-NSPhysicalDirectory $parent
    }
    catch {
        try {
            $parentCanon = Resolve-NSCanonicalPath $parent
        }
        catch {
            return $null
        }
    }
    return (Join-Path $parentCanon $leaf)
}

function Test-NSControlRewriteHit {
    param([AllowEmptyString()][string]$Canon)
    if ([string]::IsNullOrEmpty($Canon) -or [string]::IsNullOrEmpty($script:ns)) {
        return $false
    }
    foreach ($name in @(
            'STOP', '.shift-armed', '.ended', '.shift-session', '.shift-worker',
            'work-target', 'work-mode', 'shift-policy.json', 'shift-defaults.json', 'deadline'
        )) {
        $expected = Resolve-NSWriteTarget (Join-Path $script:ns $name)
        if ($null -ne $expected -and $Canon -ceq $expected) {
            return $true
        }
    }
    return $false
}

function Test-NSControlListHit {
    param([AllowEmptyString()][string]$Canon)
    if ([string]::IsNullOrEmpty($Canon) -or [string]::IsNullOrEmpty($script:ns)) {
        return $false
    }
    $expected = Resolve-NSWriteTarget (Join-Path $script:ns 'punch-list.md')
    return ($null -ne $expected -and $Canon -ceq $expected)
}

function Test-NSControlCandidateHits {
    param(
        [AllowEmptyString()][string]$Candidate,
        [AllowEmptyString()][string]$Full
    )
    $leaf = Split-Path -Leaf ($Candidate.Replace('/', [IO.Path]::DirectorySeparatorChar))
    $canon = $null
    if ((Test-NSControlBareName $Candidate) -and (Test-NSNightshiftDirContext $Full)) {
        $canon = Resolve-NSWriteTarget (Join-Path $script:ns $leaf)
    }
    else {
        $canon = Resolve-NSWriteTarget $Candidate
    }
    if (Test-NSControlRewriteHit $canon) {
        return $true
    }
    return (Test-NSControlListHit $canon) -and (Test-NSControlDeleteVerb $Full)
}

function Test-NSControlTarget {
    param([AllowEmptyString()][string]$Target)
    $normalized = $Target.Replace('\', '/').Replace('"', '').Replace("'", '')
    if (-not (Test-NSControlPrefilter $normalized)) {
        return $false
    }
    if ([string]::IsNullOrEmpty($script:ns)) {
        return $false
    }
    if ($normalized -notmatch '[\s;&|<>()]') {
        return Test-NSControlCandidateHits $normalized $normalized
    }
    foreach ($candidate in ($normalized -split '[\s;&|<>()]+')) {
        if ([string]::IsNullOrWhiteSpace($candidate)) {
            continue
        }
        if (Test-NSControlCandidateHits $candidate $normalized) {
            return $true
        }
    }
    return $false
}

function Convert-NSErePattern {
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

function New-NSRegex {
    param(
        [Parameter(Mandatory = $true)][string]$Pattern,
        [switch]$IgnoreCase
    )
    $options = [Text.RegularExpressions.RegexOptions]::Multiline
    if ($IgnoreCase) {
        $options = $options -bor [Text.RegularExpressions.RegexOptions]::IgnoreCase
    }
    return [Text.RegularExpressions.Regex]::new((Convert-NSErePattern $Pattern), $options)
}

function Test-NSGitVerb {
    param(
        [AllowEmptyString()][string]$Command,
        [Parameter(Mandatory = $true)][string]$Verb
    )
    return $Command -match '(?i)(^|[^A-Za-z0-9_-])git(?:\.exe)?([^A-Za-z0-9]|$)' `
        -and $Command -match ('(?i)(^|[^A-Za-z0-9_-]){0}([^A-Za-z0-9]|$)' -f [regex]::Escape($Verb))
}

function Resolve-NSCommandRepository {
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [Parameter(Mandatory = $true)][string]$BaseDirectory,
        [Parameter(Mandatory = $true)][string]$Workspace
    )
    $directory = $null
    if ($Command -match '(?i)\bgit(?:\.exe)?\s+-C\s+["'']?([^"''\s;&|]+)') {
        $directory = $Matches[1]
    }
    elseif ($Command -match '(?i)^\s*(?:cd|Set-Location)(?:\s+-LiteralPath)?\s+["'']?([^"''\s;&|]+)["'']?\s*(?:&&|;)') {
        $directory = $Matches[1]
    }
    if ($null -ne $directory) {
        if (-not [IO.Path]::IsPathRooted($directory)) {
            $directory = Join-Path $BaseDirectory $directory
        }
        $top = Invoke-NSGit $directory @('rev-parse', '--show-toplevel')
        if ([string]::IsNullOrWhiteSpace($top)) {
            return $null
        }
        return (Resolve-NSCanonicalPath $top)
    }

    $top = Invoke-NSGit $BaseDirectory @('rev-parse', '--show-toplevel')
    if (-not [string]::IsNullOrWhiteSpace($top)) {
        return (Resolve-NSCanonicalPath $top)
    }
    try {
        return Resolve-NSWorkTarget $Workspace
    }
    catch {
        return $null
    }
}

function Get-NSProspectiveGitPaths {
    param(
        [Parameter(Mandatory = $true)][string]$Repository,
        [Parameter(Mandatory = $true)][string]$Command,
        [Parameter(Mandatory = $true)][string]$Verb,
        [switch]$AsDiff
    )
    $gitDir = Invoke-NSGit $Repository @('rev-parse', '--absolute-git-dir')
    if ([string]::IsNullOrWhiteSpace($gitDir)) {
        return $null
    }
    $temp = Join-Path ([IO.Path]::GetTempPath()) ("ns-git-" + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $temp -Force
    $index = Join-Path $gitDir 'index'
    $copy = Join-Path $temp 'index'
    if (Test-Path -LiteralPath $index -PathType Leaf) {
        Copy-Item -LiteralPath $index -Destination $copy -Force
    }
    $env:GIT_INDEX_FILE = $copy
    try {
        $before = Invoke-NSGitCommand $Repository @('ls-files', '--stage')
        $beforePaths = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
        foreach ($line in $before.Lines) {
            $tab = $line.IndexOf("`t")
            if ($tab -ge 0) {
                [void]$beforePaths.Add($line.Substring($tab + 1).Replace('\', '/'))
            }
        }
        $words = @($Command -split '\s+' | Where-Object { $_ -ne '' })
        $start = [array]::IndexOf($words, $Verb)
        if ($start -lt 0) { return $null }
        $form = 'index'
        $paths = New-Object System.Collections.Generic.List[string]
        $rest = $false
        $skip = $false
        foreach ($word in $words[($start + 1)..($words.Length - 1)]) {
            if ($skip) { $skip = $false; continue }
            if ($rest) {
                if ($word -ne 'MSG') { $paths.Add($word) }
                continue
            }
            switch -Regex ($word) {
                '^--$' { $rest = $true; break }
                '^(--all|-A)$' { $form = $(if ($Verb -eq 'add') { 'all' } else { 'tracked' }); break }
                '^(--update|-u)$' { $form = 'tracked'; break }
                '^(--include|-i)$' { if ($Verb -eq 'commit') { $form = 'include' }; break }
                '^(--only|-o)$' { if ($Verb -eq 'commit') { $form = 'only' }; break }
                '^(-m|--message|--file|--author|--date|--cleanup)$' { $skip = $true; break }
                '^(--message=|--file=|--author=|--date=|MSG)' { break }
                '^(--allow-empty|--allow-empty-message|--no-verify|--no-edit|--quiet|--signoff|-q|-s|-n|--no-gpg-sign|--verbose|-v|--force|-f|--ignore-missing|--refresh|--porcelain)$' { break }
                # .NET has no POSIX [[:alpha:]]; clustered shorts like -am must use [A-Za-z].
                '^-[A-Za-z]*a[A-Za-z]*$' { if ($Verb -eq 'commit') { $form = 'tracked' }; break }
                '^-[A-Za-z]*i[A-Za-z]*$' { if ($Verb -eq 'commit') { $form = 'include' }; break }
                '^-[A-Za-z]*o[A-Za-z]*$' { if ($Verb -eq 'commit') { $form = 'only' }; break }
                '^-[A-Za-z]*A[A-Za-z]*$' { if ($Verb -eq 'add') { $form = 'all' }; break }
                '^-[A-Za-z]*u[A-Za-z]*$' { if ($Verb -eq 'add') { $form = 'tracked' }; break }
                '^-' { return $null }
                default { if ($word -ne 'MSG') { $paths.Add($word) }; break }
            }
        }
        if ($Verb -eq 'commit' -and $paths.Count -gt 0 -and $form -eq 'index') { $form = 'only' }
        $replay = $null
        switch ("$Verb-$form") {
            'add-all' { $replay = Invoke-NSGitCommand $Repository @('add', '-A') }
            'add-tracked' { $replay = Invoke-NSGitCommand $Repository @('add', '-u') }
            'add-index' {
                if ($paths.Count -gt 0) { $replay = Invoke-NSGitCommand $Repository (@('add', '--') + @($paths)) }
                else { $replay = [pscustomobject]@{ ExitCode = 0 } }
            }
            'commit-index' { $replay = [pscustomobject]@{ ExitCode = 0 } }
            'commit-tracked' { $replay = Invoke-NSGitCommand $Repository @('add', '-u') }
            'commit-include' {
                if ($paths.Count -gt 0) { $replay = Invoke-NSGitCommand $Repository (@('add', '--') + @($paths)) }
                else { $replay = [pscustomobject]@{ ExitCode = 0 } }
            }
            'commit-only' {
                $replay = Invoke-NSGitCommand $Repository @('read-tree', 'HEAD')
                if ($null -eq $replay -or $replay.ExitCode -ne 0) {
                    $replay = Invoke-NSGitCommand $Repository @('read-tree', '--empty')
                }
                if ($null -ne $replay -and $replay.ExitCode -eq 0 -and $paths.Count -gt 0) {
                    $replay = Invoke-NSGitCommand $Repository (@('add', '--') + @($paths))
                }
            }
            default { return $null }
        }
        if ($null -eq $replay -or $replay.ExitCode -ne 0) {
            return $null
        }
        if ($AsDiff) {
            $diff = Get-NSGitDiffText $Repository @('diff', '--cached', '--no-ext-diff', 'HEAD')
            if ($null -eq $diff) {
                $diff = Get-NSGitDiffText $Repository @('diff', '--cached', '--no-ext-diff')
            }
            return $diff
        }
        $changed = New-Object System.Collections.Generic.List[string]
        if ($Verb -eq 'add') {
            $after = Invoke-NSGitCommand $Repository @('ls-files', '--stage')
            $afterPaths = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
            $beforeLines = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
            foreach ($line in $before.Lines) {
                [void]$beforeLines.Add($line)
            }
            foreach ($line in $after.Lines) {
                $tab = $line.IndexOf("`t")
                if ($tab -ge 0) {
                    $path = $line.Substring($tab + 1).Replace('\', '/')
                    [void]$afterPaths.Add($path)
                    if (-not $beforeLines.Contains($line)) {
                        $changed.Add($path)
                    }
                }
            }
            foreach ($path in $beforePaths) {
                if (-not $afterPaths.Contains($path)) {
                    $changed.Add($path)
                }
            }
            return @($changed | Select-Object -Unique)
        }
        $listed = Get-NSGitDiffText $Repository @('diff', '--cached', '--name-only', '--no-ext-diff', 'HEAD')
        if ($null -eq $listed) {
            $listed = Get-NSGitDiffText $Repository @('diff', '--cached', '--name-only', '--no-ext-diff')
        }
        if ([string]::IsNullOrEmpty($listed)) { return @() }
        return @($listed -split "(`r`n|`n|`0)" | Where-Object { -not [string]::IsNullOrEmpty($_) })
    }
    finally {
        Remove-Item -LiteralPath $env:GIT_INDEX_FILE -ErrorAction SilentlyContinue
        Remove-Item Env:GIT_INDEX_FILE -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# A simple quoted payload after eval or a shell -c. Hardening only: one pair of
# quotes, no nested parser, not a sandbox.
function Get-NSElevationInner {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Command)
    if ($Command -notmatch '(^|[;&|()\s])(eval|[A-Za-z0-9./_-]*sh\s+-[a-zA-Z]*c)\s') {
        return ''
    }
    if ($Command -match "eval\s+'([^']*)'") { return $Matches[1] }
    if ($Command -match 'eval\s+"([^"]*)"') { return $Matches[1] }
    if ($Command -match "[A-Za-z0-9./_-]*sh\s+-[a-zA-Z]*c\s+'([^']*)'") { return $Matches[1] }
    if ($Command -match '[A-Za-z0-9./_-]*sh\s+-[a-zA-Z]*c\s+"([^"]*)"') { return $Matches[1] }
    return ''
}

# Elevation gates creating system state, never using what already runs. The category patterns come
# from rules.elevation (or the shipped defaults) through Get-NSElevationPattern, which the
# permission preflight reads too, so the guard and the preflight cannot disagree about what a
# command needs. Whether tonight lifts a deny is Test-NSPolicyAllowed's answer alone - it carries
# the whole precedence table, including the exact-plan binding. A pattern the owner broke denies.
# A simple eval / sh -c quoted payload is matched as well as the outer text; that is hardening,
# not isolation.
function Get-NSElevationDenyReason {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Scrubbed,
        [Parameter(Mandatory = $true)][string]$Workspace
    )
    $subject = $Scrubbed
    $inner = Get-NSElevationInner $Scrubbed
    if (-not [string]::IsNullOrEmpty($inner)) { $subject = "$Scrubbed $inner" }
    foreach ($category in @('sudo', 'containers', 'global-packages', 'daemons', 'external-services')) {
        $pattern = [string](Get-NSElevationPattern -Workspace $Workspace -Category $category)
        if ([string]::IsNullOrEmpty($pattern)) { continue }
        try {
            $regex = New-NSRegex $pattern
        }
        catch {
            return "BLOCKED: elevation.$category.pattern is not a valid extended regular expression, so the guard it configures cannot run. Fix the pattern in .nightshift/rules.json."
        }
        if (-not $regex.IsMatch($subject)) { continue }
        $status = Test-NSPolicyAllowed -Workspace $Workspace -Category $category -Command $Scrubbed
        if ($status -eq 0) { continue }
        $reason = "BLOCKED: this command needs the '$category' elevation category, which is denied for this shift."
        if ($status -eq 2) {
            return "$reason An exact-plan allowance exists but this command is not one of its approved commands."
        }
        return "$reason The owner allows it in .nightshift/rules.json (elevation.$category.policy) or for one shift in shift-policy.json before arming. Park the item in .nightshift/parking-lot.md as `"needs allowance: $category`" and keep working."
    }
    return ''
}

function Get-NSCommandDenyReason {
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [Parameter(Mandatory = $true)][string]$Scrubbed,
        [Parameter(Mandatory = $true)][string]$CurrentDirectory,
        [Parameter(Mandatory = $true)][string]$Workspace,
        [AllowEmptyString()][string]$ProtectedDirectories,
        [AllowEmptyString()][string]$ExpectedEmail,
        [AllowEmptyString()][string]$NeverCommitPatterns,
        [AllowEmptyString()][string]$ForbiddenCommands
    )
    $forbiddenRegex = $null
    $neverRegex = $null
    if (-not [string]::IsNullOrEmpty($ForbiddenCommands)) {
        try {
            $forbiddenRegex = New-NSRegex $ForbiddenCommands
        }
        catch {
            return 'BLOCKED: NIGHTSHIFT_FORBIDDEN_COMMANDS is not a valid extended regular expression, so the guard it configures cannot run. Fix the pattern in your session settings.'
        }
    }
    if (-not [string]::IsNullOrEmpty($NeverCommitPatterns)) {
        try {
            $neverRegex = New-NSRegex $NeverCommitPatterns -IgnoreCase
        }
        catch {
            return 'BLOCKED: NIGHTSHIFT_NEVER_COMMIT_PATTERNS is not a valid extended regular expression, so the guard it configures cannot run. Fix the pattern in your session settings.'
        }
    }

    $isGitWrite = (Test-NSGitVerb $Scrubbed 'add') -or (Test-NSGitVerb $Scrubbed 'commit') `
        -or (Test-NSGitVerb $Scrubbed 'tag') -or (Test-NSGitVerb $Scrubbed 'remote')
    if ($isGitWrite -and -not [string]::IsNullOrEmpty($ProtectedDirectories)) {
        $verb = $null
        if (Test-NSGitVerb $Scrubbed 'add') { $verb = 'add' }
        if (Test-NSGitVerb $Scrubbed 'commit') { $verb = 'commit' }
        if ($null -ne $verb) {
            if ($Scrubbed -match '(?i)--git-dir|--work-tree') {
                return "BLOCKED: --git-dir/--work-tree point this $verb somewhere the protected-directory guard cannot verify. Run it from inside the repository instead."
            }
            $repository = Resolve-NSCommandRepository $Command $CurrentDirectory $Workspace
            if ([string]::IsNullOrEmpty($repository)) {
                return "BLOCKED: cannot tell which Git repository this $verb targets, so the protected-directory guard cannot run. Run it from inside the repository."
            }
            $paths = Get-NSProspectiveGitPaths $repository $Scrubbed $verb
            if ($null -eq $paths) {
                return "BLOCKED: this $verb uses a form the protected-directory guard cannot verify. Do not retry a rephrased form."
            }
            foreach ($path in $paths) {
                foreach ($directory in ($ProtectedDirectories -split '[\s|]+')) {
                    if ([string]::IsNullOrEmpty($directory)) { continue }
                    $normalized = $path.Replace('\', '/').TrimStart('./')
                    if ($normalized -eq $directory -or $normalized.StartsWith("$directory/") `
                        -or $normalized.EndsWith("/$directory") -or $normalized -match "/$([regex]::Escape($directory))/") {
                        return "BLOCKED: never git add/commit/tag/remote inside '$directory' (a protected directory). Do not retry a rephrased form."
                    }
                }
            }
        }
        else {
            $tokens = $Scrubbed -split '\s+'
            foreach ($directory in ($ProtectedDirectories -split '[\s|]+')) {
                if ([string]::IsNullOrEmpty($directory)) { continue }
                foreach ($token in $tokens) {
                    $clean = $token.Trim("'`"")
                    $parts = $clean.Replace('\', '/').Split('/')
                    if ($parts -contains $directory -or $clean -like "*=$directory" -or $clean -like "*=$directory/*") {
                        return "BLOCKED: never git add/commit/tag/remote inside '$directory' (a protected directory). Do not retry a rephrased form."
                    }
                }
            }
        }
    }

    $isCommit = Test-NSGitVerb $Scrubbed 'commit'
    if ($isCommit -and (-not [string]::IsNullOrEmpty($ExpectedEmail) -or $null -ne $neverRegex)) {
        if ($Scrubbed -match '(?i)--git-dir|--work-tree') {
            return 'BLOCKED: --git-dir/--work-tree point this commit somewhere the configured commit guards cannot verify. Run the commit from inside the repository instead.'
        }
        if (-not [string]::IsNullOrEmpty($ExpectedEmail) `
            -and $Scrubbed -match '(?i)-c\s*user\.email=|--author|GIT_(AUTHOR|COMMITTER)_EMAIL=|\$env:GIT_(AUTHOR|COMMITTER)_EMAIL') {
            return "BLOCKED: this commit overrides the author identity on the command line, which the expected-identity guard cannot verify. Commit with the repository's configured identity."
        }
        $repository = Resolve-NSCommandRepository $Command $CurrentDirectory $Workspace
        if ([string]::IsNullOrEmpty($repository)) {
            return 'BLOCKED: cannot tell which Git repository this commit targets, so the configured commit guards cannot run. Run the commit from inside the repository.'
        }
        if (-not [string]::IsNullOrEmpty($ExpectedEmail)) {
            $email = Invoke-NSGit $repository @('config', 'user.email')
            if ($email -ne $ExpectedEmail) {
                return "BLOCKED: committer identity ('$email') is not the expected '$ExpectedEmail'. Fix git config user.email, then retry."
            }
        }
        if ($null -ne $neverRegex) {
            $diff = Get-NSProspectiveGitPaths $repository $Scrubbed 'commit' -AsDiff
            if ($null -eq $diff) {
                return 'BLOCKED: this commit uses a form the never-commit guard cannot verify. Do not retry a rephrased form.'
            }
            if ($neverRegex.IsMatch([string]$diff)) {
                return 'BLOCKED: the diff this commit would write matches a never-commit pattern. Remove it, restage, retry. Do not weaken the pattern list.'
            }
        }
    }

    if ($null -ne $forbiddenRegex -and $forbiddenRegex.IsMatch($Scrubbed)) {
        return "BLOCKED: the command matches the owner's forbidden list for this shift. Find another way, or park the task with a note in .nightshift/parking-lot.md and keep working. Do not retry a rephrased form."
    }

    # forbiddenCommands is the owner's own list and stays independent of the categories: a command
    # can clear it and still need an allowance the shift does not hold.
    return (Get-NSElevationDenyReason -Scrubbed $Scrubbed -Workspace $Workspace)
}

if ($env:NIGHTSHIFT_HARDHAT_LIB -eq '1') {
    return
}

$raw = Get-NSStdinText -Piped $HookJson
if ([string]::IsNullOrWhiteSpace($raw)) {
    $raw = Get-NSStdinText -Piped (($input | ForEach-Object { $_ }) -join "`n")
}
$payload = $null
if (-not [string]::IsNullOrWhiteSpace($raw)) {
    try {
        $payload = $raw | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        $payload = $null
    }
}

$tool = [string](Get-PropertyValue $payload 'tool_name')
$toolInput = Get-PropertyValue $payload 'tool_input' $null
$command = [string](Get-PropertyValue $toolInput 'command')
if ([string]::IsNullOrEmpty($command)) {
    $command = [string](Get-PropertyValue $toolInput 'script')
}
$cwd = [string](Get-PropertyValue $payload 'cwd' ([Environment]::CurrentDirectory))
$sessionId = [string](Get-PropertyValue $payload 'session_id')
$transcript = [string](Get-PropertyValue $payload 'transcript_path')

if ($HostName -eq 'claude') {
    $hostRoot = if (-not [string]::IsNullOrEmpty($env:CLAUDE_PROJECT_DIR)) { $env:CLAUDE_PROJECT_DIR } else { $cwd }
}
else {
    $hostRoot = if (-not [string]::IsNullOrEmpty($env:CODEX_PROJECT_DIR)) { $env:CODEX_PROJECT_DIR } else { $cwd }
}
if ([string]::IsNullOrEmpty($hostRoot)) {
    $hostRoot = [Environment]::CurrentDirectory
}

try {
    $workspace = Resolve-NSWorkspaceRoot $hostRoot
}
catch {
    Write-Deny 'BLOCKED: .nightshift-link is invalid. Open the correct project task or repair the explicit link to an absolute workspace containing .nightshift/.'
}

$stateKind = Get-NSStateKind $workspace
if ($stateKind -in @('malformed', 'future')) {
    Write-Deny ('BLOCKED: ' + (Get-NSStateRefuseMessage $stateKind))
}

$ns = Join-Path $workspace '.nightshift'
$script:cwd = $cwd
try {
    $script:ns = Resolve-NSPhysicalDirectory $ns
}
catch {
    try {
        $script:ns = Resolve-NSCanonicalPath $ns
    }
    catch {
        $script:ns = $ns
    }
}
$punch = Join-Path $ns 'punch-list.md'
$armed = Join-Path $ns '.shift-armed'
$ended = Join-Path $ns '.ended'
$endedReal = (Test-Path -LiteralPath $ended -PathType Leaf) -and -not (Test-NSReparsePoint $ended)
$active = Test-NSHardhatActive $ns

$nonce = [string]$env:NIGHTSHIFT_LEASE_NONCE
$generation = [string]$env:NIGHTSHIFT_LEASE_GENERATION
$revival = $env:NIGHTSHIFT_REVIVAL -eq '1'

if (-not $active) {
    if ($revival -and (-not (Test-NSLeaseNonce $ns $HostName $nonce $generation) `
        -or -not (Test-Path -LiteralPath $armed -PathType Leaf) `
        -or -not (Test-Path -LiteralPath $punch -PathType Leaf) `
        -or $endedReal)) {
        Write-Deny 'BLOCKED: this recovered worker no longer owns an active shift. Do not continue after clock-out.'
    }
    exit 0
}

if ($null -eq $payload) {
    Write-Deny 'BLOCKED: the hook payload is unreadable while a shift is active. Retry after the host can provide valid hook JSON.'
}

$targets = @(Get-NSPayloadTargets $toolInput $tool $command)
foreach ($target in $targets) {
    if (Test-NSLeaseTarget ([string]$target)) {
        Write-Deny 'BLOCKED: the process lease is runtime-owned, as is its mutex identity. Do not read, delete, or rewrite either file; issue STOP from another session if ownership must be reset.'
    }
}

if ($tool -in @('Bash', 'PowerShell')) {
    if (Test-NSTrustedShiftControl -Command $command -PluginRoot "$pluginRoot" -Workspace $workspace) {
        exit 0
    }
}

# Cursor IDE loads the Claude marketplace plugin beside the Cursor host plugin.
if ($HostName -eq 'claude' -and (Test-NSClaudeForeignCursorSurface -NightshiftDir $ns -Transcript $transcript)) {
    exit 0
}

$unbound = Resolve-NSShiftUnbound -NightshiftDir $ns -HostName $HostName `
    -Nonce $nonce -Generation $generation -Revival $revival -Mode hardhat
if ($unbound.Status -eq 'Pass') { exit 0 }
if ($unbound.Status -eq 'Fail') { Write-Deny $unbound.Message }

$hostProcess = Get-NSHostProcess $HostName
$processId = if ($null -eq $hostProcess) { '' } else { [string]$hostProcess.Id }
$processStart = if ($null -eq $hostProcess) { '' } else { [string]$hostProcess.Start }

$bindingProbe = ($tool -in @('Bash', 'PowerShell')) -and (
    $command.Trim() -in @(': nightshift-binding-probe', "`$null = 'nightshift-binding-probe'")
)
$bindingTools = @('Bash', 'PowerShell', 'AskQuestion', 'AskUserQuestion', 'request_user_input', 'apply_patch', 'Edit', 'Write', 'MultiEdit', 'NotebookEdit')

$session = Read-NSSession $ns
if ($null -eq $session -and -not [string]::IsNullOrEmpty($sessionId) -and $tool -in $bindingTools) {
    $null = Claim-NSSession $ns $sessionId $transcript $processId $processStart $HostName
}

$rebind = Resolve-NSShiftRebind -NightshiftDir $ns -HostName $HostName `
    -SessionId $sessionId -Transcript $transcript -ProcessId $processId `
    -ProcessStart $processStart -Nonce $nonce -Generation $generation `
    -Revival $revival -Mode hardhat
if ($rebind.Status -eq 'Pass') { exit 0 }
if ($rebind.Status -eq 'Fail') { Write-Deny $rebind.Message }
$session = $rebind.Session

if ($bindingProbe) {
    if ([string]::IsNullOrEmpty($sessionId) -or $null -eq $session) {
        Write-Deny 'BLOCKED: Start could not bind this session atomically. Issue STOP, inspect with Doctor, and retry Start.'
    }
    if ($session.SessionId -ne $sessionId) {
        Write-Deny 'BLOCKED: another session already owns this shift. Reopen that conversation or issue STOP before running Start again.'
    }
}

$owned = Resolve-NSShiftAuthorize -NightshiftDir $ns -HostName $HostName `
    -SessionId $sessionId -ProcessId $processId -ProcessStart $processStart `
    -Nonce $nonce -Generation $generation -Revival $revival -Mode hardhat `
    -Session $session
if ($owned.Status -eq 'Pass') { exit 0 }
if ($owned.Status -eq 'Fail') { Write-Deny $owned.Message }
$session = $owned.Session

try {
    $toolRules = Get-NSToolRules $workspace ([string]$env:NIGHTSHIFT_TOOL_RULES)
}
catch {
    Write-Deny 'BLOCKED: toolDeny is not a JSON object of string values, so the tool rules cannot run. Fix .nightshift/rules.json or run Setup again (/nightshift:setup on Claude Code; ask Nightshift to set up on Codex).'
}

if (-not (Test-NSInertParkingLotWrite $tool $toolInput $command)) {
    $rulesHit = $false
    if ($tool -in @('Bash', 'PowerShell', 'Shell')) {
        if (Test-NSRulesTarget $command) { $rulesHit = $true }
        $appendTarget = Get-NSLiteralAppendTarget $command
        if (-not [string]::IsNullOrEmpty($appendTarget) -and (Test-NSWriteTargetReachesRules $appendTarget)) {
            $rulesHit = $true
        }
    }
    foreach ($target in $targets) {
        if ((Test-NSRulesTarget ([string]$target)) -or (Test-NSWriteTargetReachesRules ([string]$target))) {
            $rulesHit = $true
        }
    }
    if ($rulesHit) {
        Write-Deny 'BLOCKED: the rules file is the owner''s - the night neither reads nor rewrites its own rules. Park the need in .nightshift/parking-lot.md and keep working.'
    }
}

$controlPassive = $tool -in @(
    'Read', 'Grep', 'Glob', 'LS', 'WebFetch', 'WebSearch', 'Task', 'TodoWrite',
    'AskQuestion', 'AskUserQuestion', 'request_user_input', 'NotebookRead'
) -or $tool -match '(?i)read'
if (-not $controlPassive) {
    foreach ($target in $targets) {
        if (Test-NSControlTarget ([string]$target)) {
            Write-Deny 'BLOCKED: shift control files are owner-owned while the night is armed. Do not delete or forge .shift-armed, .ended, STOP, .shift-session, work-target, work-mode, shift-policy.json, shift-defaults.json, or deadline, and do not delete the punch list. Park the need in .nightshift/parking-lot.md and keep working.'
        }
    }
}

if ($tool -in @('AskQuestion', 'AskUserQuestion', 'request_user_input')) {
    $property = if ($null -eq $toolRules) { $null } else { $toolRules.PSObject.Properties[$tool] }
    if ($null -eq $property) {
        Write-Deny "BLOCKED: toolDeny is missing the required '$tool' entry. Add that exact host tool name to .nightshift/rules.json with a denial message, or use an empty string to allow it; run Setup again (/nightshift:setup on Claude Code; ask Nightshift to set up on Codex) to review the current template."
    }
    if (-not [string]::IsNullOrEmpty([string]$property.Value)) {
        Write-Deny ([string]$property.Value)
    }
    exit 0
}

if ($null -ne $toolRules -and -not [string]::IsNullOrEmpty($tool)) {
    $property = $toolRules.PSObject.Properties[$tool]
    if ($null -ne $property -and -not [string]::IsNullOrEmpty([string]$property.Value)) {
        Write-Deny ([string]$property.Value)
    }
}

if ($tool -in @('Bash', 'PowerShell')) {
    $scrubbed = Remove-NSCommitMessage $command
    $reason = Get-NSCommandDenyReason -Command $command -Scrubbed $scrubbed `
        -CurrentDirectory $cwd -Workspace $workspace `
        -ProtectedDirectories (Get-NSRule $workspace 'protectedDirs' ([string]$env:NIGHTSHIFT_PROTECTED_DIRS)) `
        -ExpectedEmail (Get-NSRule $workspace 'expectedEmail' ([string]$env:NIGHTSHIFT_EXPECTED_EMAIL)) `
        -NeverCommitPatterns (Get-NSRule $workspace 'neverCommitPatterns' ([string]$env:NIGHTSHIFT_NEVER_COMMIT_PATTERNS)) `
        -ForbiddenCommands (Get-NSRule $workspace 'forbiddenCommands' ([string]$env:NIGHTSHIFT_FORBIDDEN_COMMANDS))
    if (-not [string]::IsNullOrEmpty($reason)) {
        Write-Deny $reason
    }
}

exit 0
