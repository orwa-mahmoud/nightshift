param(
    [string]$Project = '',
    [string]$Name = ''
)

# plan-new.ps1  -  start a named plan: a punch list that waits its turn. Mirrors plan-new.sh.
#   plan-new.ps1 -Project DIR -Name NAME
# Writes <plans>\<key>.md, where <key> is the name lowercased with every other character a hyphen.
# The file is a copy of the punch list's contract and gates under the title `# Punch List - NAME`,
# with an empty `## Items` section. A plan that already has the key is kept exactly as it is.
# Prints `wrote <path>` or `kept <path>`, relative to the workspace.
# Exit: 0 done - 1 usage/resolve - 2 refused

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if (Test-Path Variable:PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $false
}

if ([string]::IsNullOrWhiteSpace($Project)) {
    [Console]::Error.WriteLine('plan-new: --project is required')
    exit 1
}
$Name = $Name.Replace("`r", '').Replace("`n", '')
if ([string]::IsNullOrWhiteSpace($Name)) {
    [Console]::Error.WriteLine('plan-new: --name is required')
    exit 1
}

$pluginRoot = Resolve-Path (Join-Path $PSScriptRoot '../..')
Import-Module (Join-Path $pluginRoot 'lib/Nightshift.psm1') -Force -DisableNameChecking

try { $workspace = Resolve-NSWorkspaceRoot $Project }
catch {
    [Console]::Error.WriteLine("plan-new: no workspace at $Project")
    exit 1
}
$ns = Join-Path $workspace '.nightshift'
if (-not (Test-Path -LiteralPath $ns -PathType Container) -or (Test-NSReparsePoint $ns)) {
    [Console]::Error.WriteLine("plan-new: no .nightshift/ at $workspace " + [char]0x2014 + ' run Setup first')
    exit 1
}
if (-not (Test-NSLayoutKey $ns 'plans')) {
    [Console]::Error.WriteLine('plan-new: this workspace keeps plans in its drafting table; ns migrate-state moves it to the layout with plan files')
    exit 2
}
$dir = Get-NSLayoutPath $ns 'plans'
$punch = Get-NSLayoutPath $ns 'punch-list'
if (-not (Test-Path -LiteralPath $punch -PathType Leaf) -or (Test-NSReparsePoint $punch)) {
    [Console]::Error.WriteLine('plan-new: no ' + (Get-NSLayoutName $ns 'punch-list') + ' to copy the contract from ' + [char]0x2014 + ' run Setup first')
    exit 1
}

$key = Get-NSReceiptSlug $Name
if ($key.Length -eq 0) {
    [Console]::Error.WriteLine("plan-new: $Name has no letters or digits to name a file by")
    exit 1
}
$rel = (Get-NSLayoutName $ns 'plans') + '/' + $key + '.md'
$file = Join-Path $dir ($key + '.md')

if ((Test-Path -LiteralPath $dir) -and ((Test-NSReparsePoint $dir) -or -not (Test-Path -LiteralPath $dir -PathType Container))) {
    [Console]::Error.WriteLine('plan-new: ' + (Get-NSLayoutName $ns 'plans') + ' is not a folder')
    exit 2
}
if (Test-Path -LiteralPath $file) {
    if ((Test-NSReparsePoint $file) -or -not (Test-Path -LiteralPath $file -PathType Leaf)) {
        [Console]::Error.WriteLine("plan-new: $rel is not a plain file")
        exit 2
    }
    Write-Output "kept $rel"
    exit 0
}

$tmp = ''
try {
    $null = New-Item -ItemType Directory -Force -Path $dir
    # The contract and gates: everything after the title line and before `## Items`, without the
    # `## Plan` notes of a plan the punch list was cut from.
    $body = New-Object Text.StringBuilder
    $null = $body.Append('# Punch List ' + [char]0x2014 + ' ' + $Name + "`n")
    $lines = [IO.File]::ReadAllLines($punch)
    $skip = $false
    for ($i = 1; $i -lt $lines.Count; $i++) {
        $line = $lines[$i].TrimEnd([char]"`r")
        if ($line -cmatch '^## Items[ \t]*$') { break }
        if ($line -cmatch '^## Plan[ \t]*$') { $skip = $true; continue }
        if ($line.StartsWith('## ')) { $skip = $false }
        if (-not $skip) { $null = $body.Append($line + "`n") }
    }
    $null = $body.Append("## Items`n`n")
    $tmp = Join-Path $dir ('.' + $key + '.md.tmp.' + $PID)
    [IO.File]::WriteAllText($tmp, $body.ToString(), (New-Object Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination $file -Force
}
catch {
    if ($tmp -and (Test-Path -LiteralPath $tmp)) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    [Console]::Error.WriteLine("plan-new: could not write $rel")
    exit 1
}
Write-Output "wrote $rel"
exit 0
