# Portable PowerShell coverage for the native Windows evidence ledger.
# Run on macOS or Windows: pwsh -File tests/windows/evidence-logic.ps1
#
# Behavioural spec: plugins/nightshift/runtime/windows/evidence.ps1. This suite
# builds temp projects, shells out to the native ledger like a real caller
# would, and checks exit codes and exact byte formatting. The Python reference
# was removed; skip that parity leg when evidence.py is absent.
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if (Test-Path Variable:PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $false
}

$repository = Resolve-Path (Join-Path $PSScriptRoot '../..')
$plugin = Join-Path $repository 'plugins/nightshift'
$evidenceScript = Join-Path $plugin 'runtime/windows/evidence.ps1'
$pythonScript = Join-Path $plugin 'runtime/evidence.py'
$hostExecutable = (Get-Process -Id $PID).Path
$failures = New-Object 'System.Collections.Generic.List[string]'
$fixedNow = '2026-09-02T00:00:00Z'

# The companion native ledger is being built in a parallel lane. In this
# worktree runtime/windows/evidence.ps1 is still the old wrapper that shells
# out to python3 via `Get-Command python[3]`. Fail fast, precisely, and
# quietly against that exact signature: nothing else in this file should run
# or print until a real native implementation lands.
if (-not (Test-Path -LiteralPath $evidenceScript -PathType Leaf)) {
    [Console]::Error.WriteLine('evidence.ps1 is still a wrapper')
    exit 1
}
$evidenceScriptText = [IO.File]::ReadAllText($evidenceScript)
if ($evidenceScriptText.Contains('Get-Command python')) {
    [Console]::Error.WriteLine('evidence.ps1 is still a wrapper')
    exit 1
}

function Expect-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        $failures.Add($Message)
        Write-Host "FAIL: $Message"
    }
}

function Set-ProcessArguments {
    # Windows PowerShell 5.1 runs on .NET Framework, whose ProcessStartInfo has
    # no ArgumentList. Quote into Arguments there, the way CommandLineToArgvW
    # reads it back.
    param(
        [Parameter(Mandatory = $true)]$StartInfo,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )
    if ($null -ne $StartInfo.PSObject.Properties['ArgumentList']) {
        foreach ($argument in $Arguments) { $null = $StartInfo.ArgumentList.Add($argument) }
        return
    }
    $quoted = New-Object Collections.Generic.List[string]
    foreach ($argument in $Arguments) {
        $escaped = $argument -replace '(\\*)"', '$1$1\"'
        $escaped = $escaped -replace '(\\+)$', '$1$1'
        $quoted.Add('"' + $escaped + '"')
    }
    $StartInfo.Arguments = ($quoted -join ' ')
}

function Invoke-ProcessBytes {
    # Captures a child process's stdout/stderr as raw bytes via .NET Process,
    # never through PowerShell's native-command pipeline (which splits output
    # into lines and discards the exact newline/encoding evidence we need to
    # verify LF-only, single-trailing-newline, BOM-free, ASCII-only output).
    param(
        [Parameter(Mandatory = $true)][string]$FileName,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [hashtable]$EnvOverrides
    )
    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $FileName
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    Set-ProcessArguments -StartInfo $psi -Arguments $Arguments
    if ($PSBoundParameters.ContainsKey('EnvOverrides')) {
        foreach ($k in $EnvOverrides.Keys) {
            foreach ($existing in @($psi.EnvironmentVariables.Keys)) {
                if ($existing -ieq [string]$k) {
                    $null = $psi.EnvironmentVariables.Remove($existing)
                }
            }
            $psi.EnvironmentVariables.Add([string]$k, [string]$EnvOverrides[$k])
        }
    }
    $proc = [Diagnostics.Process]::new()
    $proc.StartInfo = $psi
    $null = $proc.Start()
    $stdoutStream = New-Object IO.MemoryStream
    $stderrStream = New-Object IO.MemoryStream
    $outTask = $proc.StandardOutput.BaseStream.CopyToAsync($stdoutStream)
    $errTask = $proc.StandardError.BaseStream.CopyToAsync($stderrStream)
    $proc.WaitForExit()
    $null = $outTask.GetAwaiter().GetResult()
    $null = $errTask.GetAwaiter().GetResult()
    $stdoutBytes = $stdoutStream.ToArray()
    $stderrBytes = $stderrStream.ToArray()
    return [pscustomobject]@{
        ExitCode   = $proc.ExitCode
        StdoutBytes = $stdoutBytes
        StderrBytes = $stderrBytes
        StdoutText = [Text.Encoding]::UTF8.GetString($stdoutBytes)
        StderrText = [Text.Encoding]::UTF8.GetString($stderrBytes)
    }
}

function Invoke-EvidenceNative {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectPath,
        [Parameter(Mandatory = $true)][string]$Command,
        [AllowEmptyString()][string]$Record = '',
        [AllowEmptyString()][string]$Raw = '',
        [AllowEmptyString()][string]$Id = '',
        [AllowEmptyString()][string]$Disposition = '',
        [AllowEmptyString()][string]$Ladder = '',
        [string]$Now = $fixedNow
    )
    $psArgs = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $evidenceScript, `
            '-Project', $ProjectPath, '-Command', $Command)
    if ($Record) { $psArgs += @('-Record', $Record) }
    if ($Raw) { $psArgs += @('-Raw', $Raw) }
    if ($Id) { $psArgs += @('-Id', $Id) }
    if ($Disposition) { $psArgs += @('-Disposition', $Disposition) }
    if ($Ladder) { $psArgs += @('-Ladder', $Ladder) }
    return Invoke-ProcessBytes -FileName $hostExecutable -Arguments $psArgs `
        -EnvOverrides @{ NIGHTSHIFT_EVIDENCE_NOW = $Now }
}

function Invoke-EvidencePython {
    param(
        [Parameter(Mandatory = $true)][string]$PythonPath,
        [Parameter(Mandatory = $true)][string]$ProjectPath,
        [Parameter(Mandatory = $true)][string]$Command,
        [AllowEmptyString()][string]$Record = '',
        [AllowEmptyString()][string]$Raw = '',
        [AllowEmptyString()][string]$Id = '',
        [AllowEmptyString()][string]$Disposition = '',
        [AllowEmptyString()][string]$Ladder = '',
        [string]$Now = $fixedNow
    )
    $pyArgs = @($pythonScript, '--project', $ProjectPath, $Command)
    if ($Command -eq 'append') {
        $pyArgs += @('--record', $Record)
        if ($Raw) { $pyArgs += @('--raw', $Raw) }
    }
    elseif ($Command -eq 'disposition') {
        $pyArgs += $Id
        $pyArgs += $Disposition
        if ($Ladder) { $pyArgs += $Ladder }
    }
    return Invoke-ProcessBytes -FileName $PythonPath -Arguments $pyArgs `
        -EnvOverrides @{ NIGHTSHIFT_EVIDENCE_NOW = $Now }
}

function Invoke-EvidenceSequence {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('native', 'python')][string]$Mode,
        [Parameter(Mandatory = $true)][string]$ProjectPath,
        [AllowEmptyString()][string]$PythonPath = '',
        [Parameter(Mandatory = $true)][array]$Steps
    )
    $results = [ordered]@{}
    foreach ($step in $Steps) {
        if ($Mode -eq 'native') {
            $result = Invoke-EvidenceNative -ProjectPath $ProjectPath -Command $step.Command `
                -Record $step.Record -Raw $step.Raw -Id $step.Id `
                -Disposition $step.Disposition -Ladder $step.Ladder
        }
        else {
            $result = Invoke-EvidencePython -PythonPath $PythonPath -ProjectPath $ProjectPath -Command $step.Command `
                -Record $step.Record -Raw $step.Raw -Id $step.Id `
                -Disposition $step.Disposition -Ladder $step.Ladder
        }
        $results[$step.Name] = $result
    }
    return $results
}

function New-EvidenceScratchProject {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectPath,
        [bool]$WithNightshift = $true
    )
    $null = New-Item -ItemType Directory -Path $ProjectPath -Force
    if ($WithNightshift) {
        $null = New-Item -ItemType Directory -Path (Join-Path $ProjectPath '.nightshift') -Force
    }
    return $ProjectPath
}

function Get-NSSha256HexOfText {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)
    $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $hashBytes = $sha.ComputeHash($bytes)
    }
    finally {
        $sha.Dispose()
    }
    $hex = New-Object Text.StringBuilder
    foreach ($b in $hashBytes) {
        $null = $hex.Append($b.ToString('x2'))
    }
    return $hex.ToString()
}

function Test-NSNoCarriageReturn {
    param([byte[]]$Bytes)
    foreach ($b in $Bytes) {
        if ($b -eq 13) {
            return $false
        }
    }
    return $true
}

function Test-NSSingleTrailingNewline {
    param([byte[]]$Bytes)
    if ($Bytes.Length -eq 0) {
        return $false
    }
    if ($Bytes[$Bytes.Length - 1] -ne 10) {
        return $false
    }
    if ($Bytes.Length -ge 2 -and $Bytes[$Bytes.Length - 2] -eq 10) {
        return $false
    }
    return $true
}

function Test-NSAsciiOnly {
    param([byte[]]$Bytes)
    foreach ($b in $Bytes) {
        if ($b -ge 128) {
            return $false
        }
    }
    return $true
}

function Test-NSHasBom {
    param([byte[]]$Bytes)
    if ($Bytes.Length -lt 3) {
        return $false
    }
    return ($Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF)
}

function Test-NSBytesEqual {
    param([byte[]]$Left, [byte[]]$Right)
    if ($Left.Length -ne $Right.Length) {
        return $false
    }
    for ($i = 0; $i -lt $Left.Length; $i++) {
        if ($Left[$i] -ne $Right[$i]) {
            return $false
        }
    }
    return $true
}

function Test-NSKeysSorted {
    # Recursively verifies every JSON object in the parsed tree has its keys
    # in ascending ordinal order, matching Python's json.dumps(sort_keys=True).
    param($Node)
    if ($null -eq $Node) {
        return $true
    }
    if ($Node -is [Array]) {
        foreach ($item in $Node) {
            if (-not (Test-NSKeysSorted $item)) {
                return $false
            }
        }
        return $true
    }
    if ($Node -is [Management.Automation.PSCustomObject]) {
        $names = @($Node.PSObject.Properties.Name)
        for ($i = 1; $i -lt $names.Count; $i++) {
            if ([string]::CompareOrdinal($names[$i - 1], $names[$i]) -gt 0) {
                return $false
            }
        }
        foreach ($n in $names) {
            if (-not (Test-NSKeysSorted $Node.$n)) {
                return $false
            }
        }
        return $true
    }
    return $true
}

function Get-NSEvidenceTreeStamp {
    # Recursive relative-path + SHA-256 snapshot of a directory, used to
    # compare the native and python3 evidence/ directories byte-for-byte.
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        return '(missing)'
    }
    $rootFull = (Resolve-Path -LiteralPath $Path).ProviderPath
    $lines = New-Object 'System.Collections.Generic.List[string]'
    $stack = New-Object 'System.Collections.Generic.Stack[string]'
    $stack.Push($rootFull)
    while ($stack.Count -gt 0) {
        $current = $stack.Pop()
        $entries = Get-ChildItem -LiteralPath $current -Force -ErrorAction SilentlyContinue
        foreach ($entry in $entries) {
            if ($entry.PSIsContainer) {
                $stack.Push($entry.FullName)
            }
            else {
                $rel = $entry.FullName.Substring($rootFull.Length).TrimStart('\', '/')
                $hash = (Get-FileHash -LiteralPath $entry.FullName -Algorithm SHA256).Hash
                $null = $lines.Add("$hash $rel")
            }
        }
    }
    return (($lines | Sort-Object) -join "`n")
}

# ---------------------------------------------------------------------------
# Fixture data for the frozen-interface command sequence:
#   validate-no-ledger . init . append R1 (full record) .
#   append R2 (-Raw contains a secret line) . append R3 (remote locator,
#   untrusted) . disposition R1 fixed measured . render . export-tsv .
#   validate . migrate
# ---------------------------------------------------------------------------
$r1Input = '{"id":"R1","domain":"tests","sourceClass":"shell","source":"npm test","scope":"repo",' + `
    '"severity":"medium","confidence":"high","impact":"developer","status":"open","ladder":"declared",' + `
    '"locator":"tests/example.spec.js","host":"claude","workTarget":"test-target",' + `
    '"action":"logged for review","fix":"","verificationLocator":"","disposition":"","rollback":""}'

# "domain" carries a literal JSON \u00e9 escape (the letter e-acute) so
# the ledger must re-emit it escaped on output, never as a raw non-ASCII
# byte. The escape is written as literal backslash-u-0-0-e-9 text here (not
# an actual source-file non-ASCII byte) so this whole script stays ASCII.
$r2Input = '{"id":"R2","domain":"caf\u00e9-notes","sourceClass":"shell","source":"npm test","scope":"repo",' + `
    '"severity":"low","confidence":"medium","impact":"developer","status":"open","ladder":"observed",' + `
    '"locator":"tests/other.spec.js","host":"claude","workTarget":"test-target"}'
$r2Raw = "context line one`napi_key=abcd`ncontext line three"

$r3Input = '{"id":"R3","domain":"tests","sourceClass":"shell","source":"npm test","scope":"repo",' + `
    '"severity":"high","confidence":"medium","impact":"user","status":"open","ladder":"reproduced",' + `
    '"locator":"https://example.com/report","host":"claude","workTarget":"test-target","untrusted":true}'

$steps = @(
    @{ Name = 'validate-no-ledger'; Command = 'validate'; Record = ''; Raw = ''; Id = ''; Disposition = ''; Ladder = '' }
    @{ Name = 'init'; Command = 'init'; Record = ''; Raw = ''; Id = ''; Disposition = ''; Ladder = '' }
    @{ Name = 'append-r1'; Command = 'append'; Record = $r1Input; Raw = ''; Id = ''; Disposition = ''; Ladder = '' }
    @{ Name = 'append-r2'; Command = 'append'; Record = $r2Input; Raw = $r2Raw; Id = ''; Disposition = ''; Ladder = '' }
    @{ Name = 'append-r3'; Command = 'append'; Record = $r3Input; Raw = ''; Id = ''; Disposition = ''; Ladder = '' }
    @{ Name = 'disposition-r1'; Command = 'disposition'; Record = ''; Raw = ''; Id = 'R1'; Disposition = 'fixed'; Ladder = 'measured' }
    @{ Name = 'render'; Command = 'render'; Record = ''; Raw = ''; Id = ''; Disposition = ''; Ladder = '' }
    @{ Name = 'export-tsv'; Command = 'export-tsv'; Record = ''; Raw = ''; Id = ''; Disposition = ''; Ladder = '' }
    @{ Name = 'validate-final'; Command = 'validate'; Record = ''; Raw = ''; Id = ''; Disposition = ''; Ladder = '' }
    @{ Name = 'migrate'; Command = 'migrate'; Record = ''; Raw = ''; Id = ''; Disposition = ''; Ladder = '' }
)

$root = Join-Path ([IO.Path]::GetTempPath()) ("ns-evidence-logic-" + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $root -Force
$pythonCommand = Get-Command python3 -ErrorAction SilentlyContinue

try {
    # === 1. Main command sequence against the native ledger ===
    $mainProject = Join-Path $root 'main'
    $null = New-EvidenceScratchProject $mainProject

    $nativeResults = Invoke-EvidenceSequence -Mode native -ProjectPath $mainProject -Steps $steps

    Expect-True ($nativeResults['validate-no-ledger'].ExitCode -eq 0) `
        "validate-no-ledger exits 0 (got $($nativeResults['validate-no-ledger'].ExitCode) $($nativeResults['validate-no-ledger'].StderrText))"
    Expect-True ($nativeResults['validate-no-ledger'].StdoutText.Trim() -eq 'evidence: no ledger (valid empty workspace)') `
        "validate-no-ledger prints the exact empty-workspace message (got '$($nativeResults['validate-no-ledger'].StdoutText.Trim())')"

    Expect-True ($nativeResults['init'].ExitCode -eq 0) `
        "init exits 0 (got $($nativeResults['init'].ExitCode) $($nativeResults['init'].StderrText))"

    Expect-True ($nativeResults['append-r1'].ExitCode -eq 0) `
        "append R1 exits 0 (got $($nativeResults['append-r1'].ExitCode) $($nativeResults['append-r1'].StderrText))"
    Expect-True ($nativeResults['append-r1'].StdoutText.Trim() -eq 'R1') `
        "append R1 prints the id (got '$($nativeResults['append-r1'].StdoutText.Trim())')"

    Expect-True ($nativeResults['append-r2'].ExitCode -eq 0) `
        "append R2 exits 0 (got $($nativeResults['append-r2'].ExitCode) $($nativeResults['append-r2'].StderrText))"
    Expect-True ($nativeResults['append-r2'].StdoutText.Trim() -eq 'R2') `
        "append R2 prints the id (got '$($nativeResults['append-r2'].StdoutText.Trim())')"

    Expect-True ($nativeResults['append-r3'].ExitCode -eq 0) `
        "append R3 exits 0 (got $($nativeResults['append-r3'].ExitCode) $($nativeResults['append-r3'].StderrText))"
    Expect-True ($nativeResults['append-r3'].StdoutText.Trim() -eq 'R3') `
        "append R3 prints the id (got '$($nativeResults['append-r3'].StdoutText.Trim())')"

    Expect-True ($nativeResults['disposition-r1'].ExitCode -eq 0) `
        "disposition R1 fixed measured exits 0 (got $($nativeResults['disposition-r1'].ExitCode) $($nativeResults['disposition-r1'].StderrText))"

    Expect-True ($nativeResults['render'].ExitCode -eq 0) `
        "render exits 0 (got $($nativeResults['render'].ExitCode) $($nativeResults['render'].StderrText))"

    Expect-True ($nativeResults['export-tsv'].ExitCode -eq 0) `
        "export-tsv exits 0 (got $($nativeResults['export-tsv'].ExitCode) $($nativeResults['export-tsv'].StderrText))"

    Expect-True ($nativeResults['validate-final'].ExitCode -eq 0) `
        "validate (after the sequence) exits 0 (got $($nativeResults['validate-final'].ExitCode) $($nativeResults['validate-final'].StderrText))"
    Expect-True ([string]::IsNullOrEmpty($nativeResults['validate-final'].StdoutText.Trim())) `
        "validate prints nothing on stdout once every record is valid (got '$($nativeResults['validate-final'].StdoutText.Trim())')"
    Expect-True ([string]::IsNullOrEmpty($nativeResults['validate-final'].StderrText.Trim())) `
        "validate prints nothing on stderr once every record is valid (got '$($nativeResults['validate-final'].StderrText.Trim())')"

    Expect-True ($nativeResults['migrate'].ExitCode -eq 0) `
        "migrate exits 0 (got $($nativeResults['migrate'].ExitCode) $($nativeResults['migrate'].StderrText))"
    Expect-True ($nativeResults['migrate'].StdoutText.Trim() -eq 'evidence: schema-version 1') `
        "migrate prints the exact schema-version message (got '$($nativeResults['migrate'].StdoutText.Trim())')"

    # === 2. findings.jsonl: compact canonical JSON, byte-exact ===
    $jsonlPath = Join-Path $mainProject '.nightshift/evidence/findings.jsonl'
    Expect-True (Test-Path -LiteralPath $jsonlPath -PathType Leaf) 'findings.jsonl exists after the sequence'
    $r1Record = $null
    $r2Record = $null
    $r3Record = $null
    $jsonlLines = @()
    if (Test-Path -LiteralPath $jsonlPath -PathType Leaf) {
        $jsonlBytes = [IO.File]::ReadAllBytes($jsonlPath)
        Expect-True (Test-NSNoCarriageReturn $jsonlBytes) 'findings.jsonl has no CR bytes (LF only)'
        Expect-True (Test-NSSingleTrailingNewline $jsonlBytes) 'findings.jsonl ends with exactly one trailing LF'
        Expect-True (Test-NSAsciiOnly $jsonlBytes) 'findings.jsonl contains no non-ASCII bytes'
        Expect-True (-not (Test-NSHasBom $jsonlBytes)) 'findings.jsonl has no BOM'

        $jsonlText = [Text.Encoding]::UTF8.GetString($jsonlBytes)
        $jsonlLines = @($jsonlText -split "`n" | Where-Object { $_.Length -gt 0 })
        Expect-True ($jsonlLines.Count -eq 3) "findings.jsonl has exactly 3 records (got $($jsonlLines.Count))"

        foreach ($line in $jsonlLines) {
            Expect-True (-not $line.Contains(', ')) "findings.jsonl line has no comma-space separator (line: $line)"
            Expect-True (-not $line.Contains(': ')) "findings.jsonl line has no colon-space separator (line: $line)"
            $parsed = $null
            try { $parsed = $line | ConvertFrom-Json } catch { $parsed = $null }
            Expect-True ($null -ne $parsed) "findings.jsonl line parses as JSON (line: $line)"
            if ($null -ne $parsed) {
                Expect-True (Test-NSKeysSorted $parsed) "findings.jsonl line has keys sorted recursively (line: $line)"
            }
        }

        $parsedRecords = @($jsonlLines | ForEach-Object { $_ | ConvertFrom-Json })
        $r1Record = $parsedRecords | Where-Object { $_.id -eq 'R1' } | Select-Object -First 1
        $r2Record = $parsedRecords | Where-Object { $_.id -eq 'R2' } | Select-Object -First 1
        $r3Record = $parsedRecords | Where-Object { $_.id -eq 'R3' } | Select-Object -First 1
        Expect-True ($null -ne $r1Record) 'R1 record present in findings.jsonl'
        Expect-True ($null -ne $r2Record) 'R2 record present in findings.jsonl'
        Expect-True ($null -ne $r3Record) 'R3 record present in findings.jsonl'
    }

    # digest = sha256(compact canonical JSON of the record after
    # schemaVersion/firstSeen/lastChecked defaults, before action/fix/
    # verificationLocator/disposition/rollback/source/sourceClass defaults).
    # R1 supplies action/fix/verificationLocator/disposition/rollback/source/
    # sourceClass itself, so nothing besides schemaVersion/firstSeen/
    # lastChecked was still pending when the digest was taken; this is the
    # full pre-digest record, independently hand-built and hashed here.
    if ($null -ne $r1Record) {
        $expectedR1Canonical = '{"action":"logged for review","confidence":"high","disposition":"",' + `
            '"domain":"tests","firstSeen":"' + $fixedNow + '","fix":"","host":"claude","id":"R1",' + `
            '"impact":"developer","ladder":"declared","lastChecked":"' + $fixedNow + '",' + `
            '"locator":"tests/example.spec.js","rollback":"","schemaVersion":1,"scope":"repo",' + `
            '"severity":"medium","source":"npm test","sourceClass":"shell","status":"open",' + `
            '"verificationLocator":"","workTarget":"test-target"}'
        $expectedR1Digest = Get-NSSha256HexOfText $expectedR1Canonical
        Expect-True ($r1Record.digest -eq $expectedR1Digest) `
            "R1 digest matches the hand-computed pre-defaults-complete canonical hash (expected $expectedR1Digest, got $($r1Record.digest))"
        Expect-True ($r1Record.disposition -eq 'fixed') "R1 disposition updated to fixed (got $($r1Record.disposition))"
        Expect-True ($r1Record.ladder -eq 'measured') "R1 ladder promoted to measured (got $($r1Record.ladder))"
    }

    if ($null -ne $r2Record) {
        $expectedCafe = "caf$([char]0x00e9)-notes"
        Expect-True ($r2Record.domain -eq $expectedCafe) `
            "R2 domain round-trips the non-ASCII character (got $($r2Record.domain))"
        $r2Line = @($jsonlLines | Where-Object { $_ -match '"id":"R2"' })[0]
        Expect-True ($null -ne $r2Line -and $r2Line -match '\\u00e9') `
            "R2's jsonl line escapes the non-ASCII character as \u00e9 (line: $r2Line)"

        $rawRel = ([string]$r2Record.rawPath) -replace '\\', '/'
        $rawPath = Join-Path $mainProject (Join-Path '.nightshift' $rawRel)
        Expect-True (Test-Path -LiteralPath $rawPath -PathType Leaf) "R2 raw file exists at $rawPath"
        if (Test-Path -LiteralPath $rawPath -PathType Leaf) {
            $rawBytes = [IO.File]::ReadAllBytes($rawPath)
            $rawText = [Text.Encoding]::UTF8.GetString($rawBytes)
            Expect-True ($rawText.Contains('api_key=abcd')) "R2 raw file stores the supplied text (content: $rawText)"
            Expect-True (Test-NSSingleTrailingNewline $rawBytes) 'R2 raw file ends with exactly one trailing newline'
            $expectedRaw = "context line one`napi_key=abcd`ncontext line three`n"
            Expect-True ($rawText -eq $expectedRaw) `
                "R2 raw file matches the supplied text exactly (got: $rawText)"
            # rawDigest is sha256 of the supplied text BEFORE the
            # guaranteed-trailing-newline fixup is applied to the file.
            $expectedRawPreFixup = "context line one`napi_key=abcd`ncontext line three"
            $expectedRawDigest = Get-NSSha256HexOfText $expectedRawPreFixup
            Expect-True ($r2Record.rawDigest -eq $expectedRawDigest) `
                "R2 rawDigest matches sha256 of the supplied text before the trailing-newline fixup (expected $expectedRawDigest, got $($r2Record.rawDigest))"
        }
    }

    if ($null -ne $r3Record) {
        Expect-True ($r3Record.locator -eq 'https://example.com/report') `
            "R3 locator is preserved (got $($r3Record.locator))"
        Expect-True ([bool]$r3Record.untrusted -eq $true) "R3 untrusted is true (got $($r3Record.untrusted))"
    }

    # === 3. findings.md ===
    $mdPath = Join-Path $mainProject '.nightshift/evidence/findings.md'
    Expect-True (Test-Path -LiteralPath $mdPath -PathType Leaf) 'findings.md exists after render'
    if (Test-Path -LiteralPath $mdPath -PathType Leaf) {
        $mdBytes = [IO.File]::ReadAllBytes($mdPath)
        $mdText = [Text.Encoding]::UTF8.GetString($mdBytes)
        Expect-True ($mdText.Contains('| ID | Domain | Severity | Ladder | Status | Locator |')) `
            'findings.md contains the table header'
        Expect-True ($mdText.Contains('R1') -and $mdText.Contains('R2')) 'findings.md contains both R1 and R2 ids'
        Expect-True ($mdText.Contains('R3')) 'findings.md contains the R3 id'
        Expect-True (Test-NSBytesEqual $mdBytes $nativeResults['render'].StdoutBytes) `
            'render stdout matches the written findings.md bytes exactly'
    }

    # === 4. export-tsv ===
    $expectedTsvHeader = "id`tdomain`tsourceClass`tsource`tscope`tseverity`tconfidence`timpact`tstatus`tladder`tlocator`thost"
    $tsvLines = @($nativeResults['export-tsv'].StdoutText -split "`n" | Where-Object { $_.Length -gt 0 })
    Expect-True ($tsvLines.Count -ge 1 -and $tsvLines[0] -eq $expectedTsvHeader) `
        "export-tsv header equals the exact reference column line (got '$(if ($tsvLines.Count -ge 1) { $tsvLines[0] } else { '' })')"
    Expect-True ($tsvLines.Count -eq 4) "export-tsv has a header plus 3 record rows (got $($tsvLines.Count) lines)"

    # === 5. schema-version ===
    $versionPath = Join-Path $mainProject '.nightshift/evidence/schema-version'
    Expect-True (Test-Path -LiteralPath $versionPath -PathType Leaf) 'schema-version exists'
    if (Test-Path -LiteralPath $versionPath -PathType Leaf) {
        $versionBytes = [IO.File]::ReadAllBytes($versionPath)
        $versionExpectedBytes = [Text.Encoding]::UTF8.GetBytes("1`n")
        Expect-True (Test-NSBytesEqual $versionBytes $versionExpectedBytes) 'schema-version file is exactly "1\n"'
    }

    # === 6. Rejection cases (each in its own fresh project) ===

    # invalid severity
    $sevProject = New-EvidenceScratchProject (Join-Path $root 'reject-severity')
    $null = Invoke-EvidenceNative -ProjectPath $sevProject -Command init
    $sevRecord = '{"id":"X1","domain":"tests","sourceClass":"shell","source":"npm test","scope":"repo",' + `
        '"severity":"extreme","confidence":"high","impact":"developer","status":"open","ladder":"declared",' + `
        '"locator":"tests/x1.spec.js","host":"claude","workTarget":"test-target"}'
    $sevRun = Invoke-EvidenceNative -ProjectPath $sevProject -Command append -Record $sevRecord
    Expect-True ($sevRun.ExitCode -eq 2) "invalid severity rejects with exit 2 (got $($sevRun.ExitCode))"
    Expect-True ($sevRun.StderrText.Trim() -eq 'evidence: invalid severity') `
        "invalid severity stderr is exact (got '$($sevRun.StderrText.Trim())')"

    # remote locator without untrusted
    $remoteProject = New-EvidenceScratchProject (Join-Path $root 'reject-remote-locator')
    $null = Invoke-EvidenceNative -ProjectPath $remoteProject -Command init
    $remoteRecord = '{"id":"X3","domain":"tests","sourceClass":"shell","source":"npm test","scope":"repo",' + `
        '"severity":"medium","confidence":"high","impact":"developer","status":"open","ladder":"declared",' + `
        '"locator":"https://example.com/x3","host":"claude","workTarget":"test-target"}'
    $remoteRun = Invoke-EvidenceNative -ProjectPath $remoteProject -Command append -Record $remoteRecord
    Expect-True ($remoteRun.ExitCode -eq 2) "remote locator without untrusted rejects with exit 2 (got $($remoteRun.ExitCode))"
    Expect-True ($remoteRun.StderrText.Trim() -eq 'evidence: remote locator requires untrusted=true') `
        "remote locator without untrusted stderr is exact (got '$($remoteRun.StderrText.Trim())')"

    # ladder promotion by prose
    $proseProject = New-EvidenceScratchProject (Join-Path $root 'reject-prose')
    $null = Invoke-EvidenceNative -ProjectPath $proseProject -Command init
    $prosePrev = '{"id":"X4","domain":"tests","sourceClass":"shell","source":"npm test","scope":"repo",' + `
        '"severity":"medium","confidence":"high","impact":"developer","status":"open","ladder":"declared",' + `
        '"locator":"tests/x4.spec.js","host":"claude","workTarget":"test-target"}'
    $proseFirstRun = Invoke-EvidenceNative -ProjectPath $proseProject -Command append -Record $prosePrev
    Expect-True ($proseFirstRun.ExitCode -eq 0) `
        "prose-promotion setup append exits 0 (got $($proseFirstRun.ExitCode) $($proseFirstRun.StderrText))"
    $proseNext = '{"id":"X4","domain":"tests","sourceClass":"shell","source":"npm test","scope":"repo",' + `
        '"severity":"medium","confidence":"high","impact":"developer","status":"open","ladder":"measured",' + `
        '"locator":"tests/x4.spec.js","host":"claude","workTarget":"test-target","promoteBy":"prose"}'
    $proseSecondRun = Invoke-EvidenceNative -ProjectPath $proseProject -Command append -Record $proseNext
    Expect-True ($proseSecondRun.ExitCode -eq 2) "prose promotion rejects with exit 2 (got $($proseSecondRun.ExitCode))"
    Expect-True ($proseSecondRun.StderrText.Trim() -eq 'evidence: ladder must not be promoted by prose') `
        "prose promotion stderr is exact (got '$($proseSecondRun.StderrText.Trim())')"

    # absolute evidence id must not write outside .nightshift
    $escapeProject = New-EvidenceScratchProject (Join-Path $root 'reject-absolute-id')
    $null = Invoke-EvidenceNative -ProjectPath $escapeProject -Command init
    $escapeRecord = '{"id":"/tmp/nightshift-proof","domain":"tests","sourceClass":"shell","source":"npm test","scope":"repo",' + `
        '"severity":"medium","confidence":"high","impact":"developer","status":"open","ladder":"declared",' + `
        '"locator":"tests/escape.spec.js","host":"claude","workTarget":"test-target"}'
    $escapeRun = Invoke-EvidenceNative -ProjectPath $escapeProject -Command append -Record $escapeRecord -Raw 'proof'
    Expect-True ($escapeRun.ExitCode -eq 2) "invalid id rejects with exit 2 (got $($escapeRun.ExitCode))"
    Expect-True ($escapeRun.StderrText.Trim() -eq 'evidence: invalid id') `
        "invalid id stderr is exact (got '$($escapeRun.StderrText.Trim())')"
    Expect-True (-not (Test-Path -LiteralPath '/tmp/nightshift-proof')) `
        '/tmp/nightshift-proof does not write outside .nightshift'
    Expect-True (-not (Test-Path -LiteralPath '/tmp/nightshift-proof.txt')) `
        '/tmp/nightshift-proof.txt is not created outside .nightshift'

    # unknown id
    $unknownProject = New-EvidenceScratchProject (Join-Path $root 'reject-unknown-id')
    $null = Invoke-EvidenceNative -ProjectPath $unknownProject -Command init
    $unknownRun = Invoke-EvidenceNative -ProjectPath $unknownProject -Command disposition -Id 'ghost' -Disposition 'fixed'
    Expect-True ($unknownRun.ExitCode -eq 2) "unknown id rejects with exit 2 (got $($unknownRun.ExitCode))"
    Expect-True ($unknownRun.StderrText.Trim() -eq 'evidence: unknown id ghost') `
        "unknown id stderr is exact (got '$($unknownRun.StderrText.Trim())')"

    # malformed JSON line
    $malformedProject = New-EvidenceScratchProject (Join-Path $root 'reject-malformed')
    $null = Invoke-EvidenceNative -ProjectPath $malformedProject -Command init
    $malformedJsonl = Join-Path $malformedProject '.nightshift/evidence/findings.jsonl'
    $malformedContent = '{"id":"X5"}' + "`n" + 'not-json-at-all' + "`n"
    [IO.File]::WriteAllText($malformedJsonl, $malformedContent)
    $malformedRun = Invoke-EvidenceNative -ProjectPath $malformedProject -Command validate
    Expect-True ($malformedRun.ExitCode -eq 1) "malformed JSON line exits 1 (got $($malformedRun.ExitCode))"
    Expect-True ($malformedRun.StderrText.Trim() -eq 'evidence: malformed JSON on line 2') `
        "malformed JSON message is exact (got '$($malformedRun.StderrText.Trim())')"

    # missing .nightshift/
    $missingNsProject = New-EvidenceScratchProject (Join-Path $root 'reject-missing-nightshift') -WithNightshift $false
    $missingNsRun = Invoke-EvidenceNative -ProjectPath $missingNsProject -Command init
    Expect-True ($missingNsRun.ExitCode -eq 1) "missing .nightshift/ exits 1 (got $($missingNsRun.ExitCode))"
    Expect-True ($missingNsRun.StderrText.Trim() -eq "evidence: no .nightshift/ at $missingNsProject") `
        "missing .nightshift/ stderr names the project path (got '$($missingNsRun.StderrText.Trim())')"

    function Get-NSEvidenceExampleRecord {
        param([Parameter(Mandatory = $true)][string]$Path)
        $buf = New-Object Collections.Generic.List[string]
        $in = $false
        foreach ($line in [IO.File]::ReadAllLines($Path)) {
            if (-not $in) {
                if ($line -ceq '```json') { $in = $true }
                continue
            }
            if ($line -ceq '```') { break }
            $buf.Add($line)
        }
        return ($buf -join '')
    }
    foreach ($kind in @('baseline', 'checkpoint')) {
        $page = Join-Path $plugin "skills/nightshift/references/evidence/$kind.md"
        $guide = New-EvidenceScratchProject (Join-Path $root "guide-$kind")
        $null = Invoke-EvidenceNative -ProjectPath $guide -Command init
        $rec = Get-NSEvidenceExampleRecord $page
        $appended = Invoke-EvidenceNative -ProjectPath $guide -Command append -Record $rec
        Expect-True ($appended.ExitCode -eq 0) "$kind guidance example appends (got $($appended.ExitCode) $($appended.StderrText))"
        $valid = Invoke-EvidenceNative -ProjectPath $guide -Command validate
        Expect-True ($valid.ExitCode -eq 0) "$kind guidance example validates (got $($valid.ExitCode) $($valid.StderrText))"
    }

    # === 7. python3 parity leg (skipped when the Python reference is absent) ===
    if (($null -ne $pythonCommand) -and (Test-Path -LiteralPath $pythonScript -PathType Leaf)) {
        $pyProject = Join-Path $root 'python-parity'
        $null = New-EvidenceScratchProject $pyProject
        $pyResults = Invoke-EvidenceSequence -Mode python -ProjectPath $pyProject -PythonPath $pythonCommand.Source -Steps $steps
        $pyStepFailed = $false
        foreach ($name in $pyResults.Keys) {
            if ($pyResults[$name].ExitCode -ne 0) {
                $pyStepFailed = $true
                Expect-True $false `
                    "python3 reference step '$name' exits 0 (got $($pyResults[$name].ExitCode) $($pyResults[$name].StderrText))"
            }
        }
        if (-not $pyStepFailed) {
            $nativeEvidenceDir = Join-Path $mainProject '.nightshift/evidence'
            $pyEvidenceDir = Join-Path $pyProject '.nightshift/evidence'
            $nativeStamp = Get-NSEvidenceTreeStamp $nativeEvidenceDir
            $pyStamp = Get-NSEvidenceTreeStamp $pyEvidenceDir
            Expect-True ($nativeStamp -eq $pyStamp) `
                'the native evidence.ps1 and the python3 reference produce byte-identical evidence directories for the same sequence'
        }
    }
    else {
        Write-Host 'skip: python3 not found on PATH; parity leg not run'
        Write-Host 'skip: python reference removed; parity leg not run'
    }
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures.Count -gt 0) {
    Write-Host "evidence-logic failed ($($failures.Count)):"
    foreach ($failure in $failures) { Write-Host " - $failure" }
    exit 1
}
Write-Host 'evidence-logic passed'
exit 0
