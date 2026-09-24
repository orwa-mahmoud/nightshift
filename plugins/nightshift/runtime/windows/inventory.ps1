[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$Project = '',
    [switch]$Json
)

# inventory.ps1 - the native Windows twin of runtime/inventory.sh.
#
#   inventory.ps1 -Project <work-target> [-Json]
#
# Same walk, same fields, same bytes: the parity test diffs both engines over the
# same fixture trees. PowerShell reads package.json itself, so this side never
# needs jq.
#
# Exit: 0 inventory - 1 usage - 3 unavailable

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if (Test-Path Variable:PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $false
}

$pluginRoot = Resolve-Path (Join-Path $PSScriptRoot '../..')
Import-Module (Join-Path $pluginRoot 'lib/Nightshift.psm1') -Force -DisableNameChecking

if ([string]::IsNullOrWhiteSpace($Project)) {
    if (-not [string]::IsNullOrWhiteSpace($env:CLAUDE_PROJECT_DIR)) { $Project = $env:CLAUDE_PROJECT_DIR }
    elseif (-not [string]::IsNullOrWhiteSpace($env:CODEX_PROJECT_DIR)) { $Project = $env:CODEX_PROJECT_DIR }
    else { $Project = [string](Get-Location).ProviderPath }
}

$script:Out = New-Object Text.StringBuilder

function Write-NVLine {
    param([string]$Text = '')
    [void]$script:Out.Append($Text)
    [void]$script:Out.Append("`n")
}

function Complete-NVOutput {
    [Console]::Out.Write($script:Out.ToString())
    [Console]::Out.Flush()
    exit 0
}

function Write-NVUnavailable {
    param([string]$Reason)
    [Console]::Out.Write("unavailable inventory: $Reason`n")
    [Console]::Out.Flush()
    exit 3
}

try { $target = Resolve-NSCanonicalPath $Project }
catch { Write-NVUnavailable 'the work target is not a readable directory' }
if (-not (Test-Path -LiteralPath $target -PathType Container)) {
    Write-NVUnavailable 'the work target is not a readable directory'
}

# The fixed vocabularies, in the order both engines report them.
$roles = @('build', 'format', 'lint', 'test', 'typecheck')
$tools = @('biome', 'clippy', 'eslint', 'golangci-lint', 'mypy', 'prettier', 'pytest', 'ruff', 'tsc')
$manifests = @('package.json', 'Cargo.toml', 'go.mod', 'pyproject.toml', 'setup.cfg', 'requirements.txt')
$ciNames = @('.gitlab-ci.yml', 'azure-pipelines.yml', 'Jenkinsfile', '.travis.yml',
    'bitbucket-pipelines.yml', '.circleci/config.yml')
$noise = @('node_modules', '.git', '.venv', 'venv', '__pycache__', 'vendor', 'dist', 'build',
    '.next', '.tox')

function Get-NVSanitized {
    param([AllowEmptyString()][AllowNull()][string]$Text)
    if ($null -eq $Text) { $Text = '' }
    $sb = New-Object Text.StringBuilder
    foreach ($ch in $Text.ToCharArray()) {
        $code = [int]$ch
        if ($code -ge 32 -and $code -le 126) { [void]$sb.Append($ch) }
        else { [void]$sb.Append(' ') }
    }
    $value = $sb.ToString()
    while ($value.Contains('  ')) { $value = $value.Replace('  ', ' ') }
    $value = $value.Trim([char]' ')
    if ($value -eq '') { $value = '-' }
    return $value
}

function Get-NVJsonEscaped {
    param([string]$Text)
    $sb = New-Object Text.StringBuilder
    foreach ($ch in $Text.ToCharArray()) {
        if ($ch -eq '"') { [void]$sb.Append('\"') }
        elseif ($ch -eq '\') { [void]$sb.Append('\\') }
        else { [void]$sb.Append($ch) }
    }
    return $sb.ToString()
}

function Get-NVCellEscaped {
    param([string]$Text)
    return $Text.Replace('|', '\|')
}

# A path no inventory should describe: an installed dependency, a build output, or a cache.
function Test-NVNoise {
    param([string]$Relative)
    $probe = '/' + $Relative + '/'
    foreach ($name in $noise) {
        if ($probe.Contains('/' + $name + '/')) { return $true }
    }
    if ($probe.Contains('/target/debug/') -or $probe.Contains('/target/release/')) { return $true }
    return $false
}

function Join-NVPath {
    param([string]$Directory, [string]$Leaf)
    if ($Directory -ceq '.') { return (Join-Path $target $Leaf) }
    return (Join-Path $target ($Directory + '/' + $Leaf))
}

function Test-NVFile {
    param([string]$Directory, [string]$Leaf)
    return (Test-Path -LiteralPath (Join-NVPath $Directory $Leaf) -PathType Leaf)
}

function Get-NVFirst {
    param([string]$Directory, [string[]]$Names)
    foreach ($name in $Names) {
        if (Test-NVFile $Directory $name) { return $name }
    }
    return '-'
}

function Test-NVSection {
    param([string]$Directory, [string]$File, [string]$Pattern)
    if (-not (Test-NVFile $Directory $File)) { return $false }
    foreach ($line in [IO.File]::ReadAllLines((Join-NVPath $Directory $File))) {
        if ($line -cmatch $Pattern) { return $true }
    }
    return $false
}

# A delimiter on both sides of a name: an end of line, a version operator, an extras
# bracket, a quote or a comma.
$mentionDelimiters = [char[]]@(' ', "`t", "`r", '=', '<', '>', '[', '~', '!', '"', "'", ',')

function Test-NVMentionEdge {
    param([AllowEmptyString()][string]$Character)
    if ($Character -eq '') { return $true }
    return ($mentionDelimiters -contains [char]$Character)
}

# A manifest in $Directory names $Token as a package of its own. The token has to
# stand alone: a dependency on `ruff-lsp` is not a dependency on `ruff`, so a
# neighbouring name character rules the hit out.
function Test-NVMentions {
    param([string]$Directory, [string]$Token)
    foreach ($file in @('package.json', 'Cargo.toml', 'go.mod', 'pyproject.toml', 'setup.cfg',
            'requirements.txt', 'tox.ini')) {
        if (-not (Test-NVFile $Directory $file)) { continue }
        $text = [IO.File]::ReadAllText((Join-NVPath $Directory $file))
        foreach ($line in $text.Split("`n")) {
            $from = 0
            while ($true) {
                $at = $line.IndexOf($Token, $from, [StringComparison]::Ordinal)
                if ($at -lt 0) { break }
                $before = ''
                if ($at -gt 0) { $before = $line.Substring($at - 1, 1) }
                $after = ''
                if ($at + $Token.Length -lt $line.Length) {
                    $after = $line.Substring($at + $Token.Length, 1)
                }
                if ((Test-NVMentionEdge $before) -and (Test-NVMentionEdge $after)) { return $true }
                $from = $at + 1
            }
        }
    }
    return $false
}

function Get-NVParent {
    param([string]$Directory)
    if ($Directory.Contains('/')) { return $Directory.Substring(0, $Directory.LastIndexOf('/')) }
    return '.'
}

# A bin file under this package's node_modules/.bin or any ancestor's, or the tool on PATH.
function Test-NVBin {
    param([string]$Directory, [string]$Name)
    $probe = $Directory
    while ($true) {
        if (Test-NVFile $probe ('node_modules/.bin/' + $Name)) { return $true }
        if ($probe -ceq '.') { break }
        $probe = Get-NVParent $probe
    }
    $found = Get-Command -Name $Name -CommandType Application -ErrorAction SilentlyContinue
    return ($null -ne $found)
}

$lockOrder = @(
    @('pnpm-lock.yaml', 'pnpm'), @('yarn.lock', 'yarn'), @('package-lock.json', 'npm'),
    @('npm-shrinkwrap.json', 'npm'), @('bun.lockb', 'bun'), @('Cargo.lock', 'cargo'),
    @('go.sum', 'go'), @('uv.lock', 'uv'), @('poetry.lock', 'poetry'), @('Pipfile.lock', 'pipenv')
)

# The nearest lockfile at or above the package, which is what a workspace looks like
# from inside one of its packages.
function Get-NVLockfile {
    param([string]$Directory)
    $probe = $Directory
    while ($true) {
        foreach ($pick in $lockOrder) {
            if (-not (Test-NVFile $probe $pick[0])) { continue }
            $relative = $pick[0]
            if ($probe -cne '.') { $relative = $probe + '/' + $pick[0] }
            return [pscustomobject]@{ Lockfile = $relative; Manager = $pick[1] }
        }
        if ($probe -ceq '.') { break }
        $probe = Get-NVParent $probe
    }
    return [pscustomobject]@{ Lockfile = '-'; Manager = '-' }
}

# ------------------------------------------------------------------ the walk

# The deepest tree this walks. `find` has no limit and neither does a real project;
# the cap is what stops a cycle reached some other way from running forever.
$walkDepthLimit = 64

# Every file under $Root, relative and slash-separated. Written out rather than
# handed to -Recurse because Windows PowerShell 5.1 follows a junction and a
# directory symlink, and `find` without -L follows neither: a reparse point is
# skipped here for the same reason. A pruned directory is never entered, so a
# vendored tree costs nothing to ignore.
function Get-NVWalk {
    param([string]$Root)
    $found = New-Object 'Collections.Generic.List[string]'
    $pending = New-Object 'Collections.Generic.Stack[object]'
    $pending.Push([pscustomobject]@{ Path = $Root; Relative = ''; Depth = 0 })
    while ($pending.Count -gt 0) {
        $current = $pending.Pop()
        $entries = @()
        try { $entries = @(Get-ChildItem -LiteralPath $current.Path -Force) }
        catch { continue }
        foreach ($entry in $entries) {
            $relative = $entry.Name
            if ($current.Relative -ne '') { $relative = $current.Relative + '/' + $entry.Name }
            if ((([int]$entry.Attributes) -band ([int][IO.FileAttributes]::ReparsePoint)) -ne 0) {
                continue
            }
            if ($entry.PSIsContainer) {
                if ($noise -ccontains $entry.Name) { continue }
                if ($current.Depth -ge $walkDepthLimit) { continue }
                $pending.Push([pscustomobject]@{
                        Path = $entry.FullName; Relative = $relative
                        Depth = $current.Depth + 1
                    })
                continue
            }
            [void]$found.Add($relative)
        }
    }
    return , ([string[]]$found)
}

$vcs = 'none'
$inside = Invoke-NSGitCommand $target @('rev-parse', '--is-inside-work-tree')
if ($inside.ExitCode -eq 0 -and $inside.Text.Trim() -ceq 'true') { $vcs = 'git' }

$all = New-Object 'Collections.Generic.List[string]'
if ($vcs -ceq 'git') {
    $listed = Invoke-NSGitCommand $target @('ls-files', '--cached', '--others', '--exclude-standard')
    if ($listed.ExitCode -eq 0) {
        foreach ($line in $listed.Lines) { if ($line -ne '') { [void]$all.Add($line) } }
    }
}
else {
    foreach ($relative in (Get-NVWalk $target)) {
        if (Test-NVNoise $relative) { continue }
        [void]$all.Add($relative)
    }
}

$dirSet = New-Object 'Collections.Generic.HashSet[string]'
$ciSet = New-Object 'Collections.Generic.HashSet[string]'
foreach ($relative in $all) {
    if (Test-NVNoise $relative) { continue }
    $base = $relative
    if ($base.Contains('/')) { $base = $base.Substring($base.LastIndexOf('/') + 1) }
    if ($manifests -ccontains $base) {
        $directory = '.'
        if ($relative.Contains('/')) { $directory = $relative.Substring(0, $relative.LastIndexOf('/')) }
        [void]$dirSet.Add($directory)
    }
    if ($relative.StartsWith('.github/workflows/', [StringComparison]::Ordinal) -and
        ($relative.EndsWith('.yml', [StringComparison]::Ordinal) -or
            $relative.EndsWith('.yaml', [StringComparison]::Ordinal))) {
        [void]$ciSet.Add($relative)
        continue
    }
    if ($ciNames -ccontains $relative) { [void]$ciSet.Add($relative) }
}

$packageDirs = [string[]]@($dirSet)
[Array]::Sort($packageDirs, [StringComparer]::Ordinal)
$ciFiles = [string[]]@($ciSet)
[Array]::Sort($ciFiles, [StringComparer]::Ordinal)

# ------------------------------------------------------------------ per package

$packages = New-Object 'Collections.Generic.List[object]'
foreach ($directory in $packageDirs) {
    $kind = 'other'
    if (Test-NVFile $directory 'requirements.txt') { $kind = 'python' }
    if (Test-NVFile $directory 'setup.cfg') { $kind = 'python' }
    if (Test-NVFile $directory 'pyproject.toml') { $kind = 'python' }
    if (Test-NVFile $directory 'go.mod') { $kind = 'go' }
    if (Test-NVFile $directory 'Cargo.toml') { $kind = 'cargo' }
    if (Test-NVFile $directory 'package.json') { $kind = 'node' }

    $scriptKeys = New-Object 'Collections.Generic.List[string]'
    $workspaces = '-'
    if (Test-NVFile $directory 'package.json') {
        $manifestPath = Join-NVPath $directory 'package.json'
        $parsed = $null
        try { $parsed = ConvertFrom-NSJsonText ([IO.File]::ReadAllText($manifestPath)) }
        catch { Write-NVUnavailable "$directory/package.json is not readable JSON" }
        if (-not ($parsed -is [Collections.IDictionary])) {
            Write-NVUnavailable "$directory/package.json is not readable JSON"
        }
        if ($parsed.Contains('scripts') -and ($parsed['scripts'] -is [Collections.IDictionary])) {
            foreach ($key in @($parsed['scripts'].Keys)) { [void]$scriptKeys.Add([string]$key) }
        }
        $workspaces = 'no'
        if ($parsed.Contains('workspaces') -and $null -ne $parsed['workspaces']) { $workspaces = 'yes' }
        if ($workspaces -ceq 'no' -and (Test-NVFile $directory 'pnpm-workspace.yaml')) {
            $workspaces = 'yes'
        }
    }
    elseif (Test-NVFile $directory 'Cargo.toml') {
        if (Test-NVSection $directory 'Cargo.toml' '^\[workspace\]') { $workspaces = 'yes' }
        else { $workspaces = 'no' }
    }

    $lock = Get-NVLockfile $directory
    $manager = $lock.Manager
    if ($manager -ceq '-') {
        if ($kind -ceq 'go') { $manager = 'go' }
        elseif ($kind -ceq 'cargo') { $manager = 'cargo' }
        elseif ($kind -ceq 'python') { $manager = 'pip' }
    }

    $scripts = New-Object 'Collections.Generic.List[object]'
    foreach ($role in $roles) {
        $candidates = @($role)
        if ($role -ceq 'typecheck') { $candidates = @('typecheck', 'type-check', 'types', 'tsc') }
        elseif ($role -ceq 'format') { $candidates = @('format', 'fmt') }
        $value = '-'
        foreach ($candidate in $candidates) {
            if ($scriptKeys -ccontains $candidate) { $value = $candidate; break }
        }
        [void]$scripts.Add([pscustomobject]@{ Name = $role; Value = $value })
    }

    $configs = New-Object 'Collections.Generic.List[object]'
    $cfgBiome = Get-NVFirst $directory @('biome.json', 'biome.jsonc')
    [void]$configs.Add([pscustomobject]@{ Name = 'biome'; Value = $cfgBiome })
    $cfgClippy = Get-NVFirst $directory @('clippy.toml', '.clippy.toml')
    [void]$configs.Add([pscustomobject]@{ Name = 'clippy'; Value = $cfgClippy })
    $cfgEditorconfig = Get-NVFirst $directory @('.editorconfig')
    [void]$configs.Add([pscustomobject]@{ Name = 'editorconfig'; Value = $cfgEditorconfig })
    $cfgEslint = Get-NVFirst $directory @('eslint.config.js', 'eslint.config.mjs',
        'eslint.config.cjs', 'eslint.config.ts', '.eslintrc', '.eslintrc.js', '.eslintrc.cjs',
        '.eslintrc.json', '.eslintrc.yml', '.eslintrc.yaml')
    [void]$configs.Add([pscustomobject]@{ Name = 'eslint'; Value = $cfgEslint })
    $cfgGolangci = Get-NVFirst $directory @('.golangci.yml', '.golangci.yaml', '.golangci.toml',
        '.golangci.json')
    [void]$configs.Add([pscustomobject]@{ Name = 'golangci'; Value = $cfgGolangci })
    $cfgMypy = Get-NVFirst $directory @('mypy.ini', '.mypy.ini')
    if ($cfgMypy -ceq '-' -and (Test-NVSection $directory 'pyproject.toml' '^\[tool\.mypy')) {
        $cfgMypy = 'pyproject.toml'
    }
    if ($cfgMypy -ceq '-' -and (Test-NVSection $directory 'setup.cfg' '^\[mypy\]')) {
        $cfgMypy = 'setup.cfg'
    }
    [void]$configs.Add([pscustomobject]@{ Name = 'mypy'; Value = $cfgMypy })
    $cfgPrettier = Get-NVFirst $directory @('.prettierrc', '.prettierrc.json', '.prettierrc.yml',
        '.prettierrc.yaml', '.prettierrc.js', '.prettierrc.cjs', 'prettier.config.js',
        'prettier.config.cjs', 'prettier.config.mjs')
    [void]$configs.Add([pscustomobject]@{ Name = 'prettier'; Value = $cfgPrettier })
    $cfgPytest = Get-NVFirst $directory @('pytest.ini')
    if ($cfgPytest -ceq '-' -and (Test-NVSection $directory 'pyproject.toml' '^\[tool\.pytest')) {
        $cfgPytest = 'pyproject.toml'
    }
    if ($cfgPytest -ceq '-' -and (Test-NVSection $directory 'setup.cfg' '^\[tool:pytest\]')) {
        $cfgPytest = 'setup.cfg'
    }
    if ($cfgPytest -ceq '-' -and (Test-NVSection $directory 'tox.ini' '^\[pytest\]')) {
        $cfgPytest = 'tox.ini'
    }
    [void]$configs.Add([pscustomobject]@{ Name = 'pytest'; Value = $cfgPytest })
    $cfgRuff = Get-NVFirst $directory @('ruff.toml', '.ruff.toml')
    if ($cfgRuff -ceq '-' -and (Test-NVSection $directory 'pyproject.toml' '^\[tool\.ruff')) {
        $cfgRuff = 'pyproject.toml'
    }
    [void]$configs.Add([pscustomobject]@{ Name = 'ruff'; Value = $cfgRuff })
    $cfgTsconfig = Get-NVFirst $directory @('tsconfig.json')
    [void]$configs.Add([pscustomobject]@{ Name = 'tsconfig'; Value = $cfgTsconfig })

    $toolStates = New-Object 'Collections.Generic.List[object]'
    foreach ($tool in $tools) {
        switch -CaseSensitive ($tool) {
            'biome' { $config = $cfgBiome; $bin = 'biome'; $mention = 'biome' }
            'clippy' { $config = $cfgClippy; $bin = 'cargo-clippy'; $mention = 'clippy' }
            'eslint' { $config = $cfgEslint; $bin = 'eslint'; $mention = 'eslint' }
            'golangci-lint' { $config = $cfgGolangci; $bin = 'golangci-lint'; $mention = 'golangci-lint' }
            'mypy' { $config = $cfgMypy; $bin = 'mypy'; $mention = 'mypy' }
            'prettier' { $config = $cfgPrettier; $bin = 'prettier'; $mention = 'prettier' }
            'pytest' { $config = $cfgPytest; $bin = 'pytest'; $mention = 'pytest' }
            'ruff' { $config = $cfgRuff; $bin = 'ruff'; $mention = 'ruff' }
            'tsc' { $config = $cfgTsconfig; $bin = 'tsc'; $mention = 'typescript' }
        }
        $state = 'absent'
        if (Test-NVBin $directory $bin) { $state = 'runnable' }
        elseif ($config -cne '-' -or (Test-NVMentions $directory $mention)) { $state = 'declared' }
        [void]$toolStates.Add([pscustomobject]@{ Name = $tool; Value = $state })
    }

    [void]$packages.Add([pscustomobject]@{
            Path = Get-NVSanitized $directory
            Kind = Get-NVSanitized $kind
            Manager = Get-NVSanitized $manager
            Lockfile = Get-NVSanitized $lock.Lockfile
            Workspaces = Get-NVSanitized $workspaces
            Scripts = $scripts
            Configs = $configs
            Tools = $toolStates
        })
}

# ------------------------------------------------------------------ rendering

$targetText = Get-NVSanitized $target
$vcsText = Get-NVSanitized $vcs
$ciText = [string[]]@($ciFiles | ForEach-Object { Get-NVSanitized $_ })

if ($Json) {
    $text = '{"ci":['
    for ($i = 0; $i -lt $ciText.Count; $i++) {
        if ($i -gt 0) { $text += ',' }
        $text += '"' + (Get-NVJsonEscaped $ciText[$i]) + '"'
    }
    $text += '],"packages":['
    for ($p = 0; $p -lt $packages.Count; $p++) {
        if ($p -gt 0) { $text += ',' }
        $package = $packages[$p]
        $text += '{"configs":{'
        for ($i = 0; $i -lt $package.Configs.Count; $i++) {
            if ($i -gt 0) { $text += ',' }
            $text += '"' + (Get-NVJsonEscaped $package.Configs[$i].Name) + '":"' +
            (Get-NVJsonEscaped (Get-NVSanitized $package.Configs[$i].Value)) + '"'
        }
        $text += '},"kind":"' + (Get-NVJsonEscaped $package.Kind) + '"'
        $text += ',"lockfile":"' + (Get-NVJsonEscaped $package.Lockfile) + '"'
        $text += ',"manager":"' + (Get-NVJsonEscaped $package.Manager) + '"'
        $text += ',"path":"' + (Get-NVJsonEscaped $package.Path) + '","scripts":{'
        for ($i = 0; $i -lt $package.Scripts.Count; $i++) {
            if ($i -gt 0) { $text += ',' }
            $text += '"' + (Get-NVJsonEscaped $package.Scripts[$i].Name) + '":"' +
            (Get-NVJsonEscaped (Get-NVSanitized $package.Scripts[$i].Value)) + '"'
        }
        $text += '},"tools":{'
        for ($i = 0; $i -lt $package.Tools.Count; $i++) {
            if ($i -gt 0) { $text += ',' }
            $text += '"' + (Get-NVJsonEscaped $package.Tools[$i].Name) + '":"' +
            (Get-NVJsonEscaped (Get-NVSanitized $package.Tools[$i].Value)) + '"'
        }
        $text += '},"workspaces":"' + (Get-NVJsonEscaped $package.Workspaces) + '"}'
    }
    $text += '],"target":"' + (Get-NVJsonEscaped $targetText) + '","vcs":"' +
        (Get-NVJsonEscaped $vcsText) + '","version":1}'
    Write-NVLine $text
    Complete-NVOutput
}

$noun = 'packages'
if ($packages.Count -eq 1) { $noun = 'package' }
Write-NVLine ("inventory: {0} {1} in {2} ({3})" -f $packages.Count, $noun, $targetText, $vcsText)
if ($ciText.Count -eq 0) { Write-NVLine 'ci: none' }
else { Write-NVLine ('ci: ' + ($ciText -join ' ')) }
foreach ($package in $packages) {
    Write-NVLine ''
    Write-NVLine ('## ' + $package.Path + ' (' + $package.Kind + ')')
    Write-NVLine ''
    Write-NVLine '| field | value |'
    Write-NVLine '| --- | --- |'
    Write-NVLine ('| manager | ' + (Get-NVCellEscaped $package.Manager) + ' |')
    Write-NVLine ('| lockfile | ' + (Get-NVCellEscaped $package.Lockfile) + ' |')
    Write-NVLine ('| workspaces | ' + (Get-NVCellEscaped $package.Workspaces) + ' |')
    foreach ($row in $package.Scripts) {
        Write-NVLine ('| script ' + (Get-NVCellEscaped $row.Name) + ' | ' +
            (Get-NVCellEscaped (Get-NVSanitized $row.Value)) + ' |')
    }
    foreach ($row in $package.Configs) {
        Write-NVLine ('| config ' + (Get-NVCellEscaped $row.Name) + ' | ' +
            (Get-NVCellEscaped (Get-NVSanitized $row.Value)) + ' |')
    }
    foreach ($row in $package.Tools) {
        Write-NVLine ('| tool ' + (Get-NVCellEscaped $row.Name) + ' | ' +
            (Get-NVCellEscaped (Get-NVSanitized $row.Value)) + ' |')
    }
}
Complete-NVOutput
