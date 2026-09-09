# Portable PowerShell coverage for the Windows SessionStart hook.
# Run on macOS or Windows: pwsh -File tests/windows/session-start-logic.ps1
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if (Test-Path Variable:PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $false
}

$repository = Resolve-Path (Join-Path $PSScriptRoot '../..')
$hook = Join-Path $repository 'plugins/nightshift/hooks/windows/session-start.ps1'
Import-Module (Join-Path $repository 'plugins/nightshift/lib/Nightshift.psm1') -Force -DisableNameChecking
$failures = New-Object 'System.Collections.Generic.List[string]'

function Expect-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        $failures.Add($Message)
        Write-Host "FAIL: $Message"
    }
}

function Invoke-Hook {
    param([Parameter(Mandatory = $true)][string]$Workspace, [Parameter(Mandatory = $true)][string]$Json)
    $out = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N') + '.out')
    $previous = $env:CLAUDE_PROJECT_DIR
    try {
        $env:CLAUDE_PROJECT_DIR = $Workspace
        $previousEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $Json | & (Get-Process -Id $PID).Path -NoProfile -NonInteractive -File $hook -HostName claude `
                > $out 2>&1
        }
        finally {
            $ErrorActionPreference = $previousEap
        }
        $code = $LASTEXITCODE
        $text = ''
        if (Test-Path -LiteralPath $out) { $text = [IO.File]::ReadAllText($out) }
        return [pscustomobject]@{ ExitCode = $code; Text = $text }
    }
    finally {
        $env:CLAUDE_PROJECT_DIR = $previous
        Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue
    }
}

$root = Join-Path ([IO.Path]::GetTempPath()) ("ns-session-start-logic-" + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $root -Force
try {
    $utf8 = New-Object Text.UTF8Encoding($false)
    $w = Join-Path $root 'armed'
    $ns = Join-Path $w '.nightshift'
    $null = New-Item -ItemType Directory -Path $ns -Force
    [IO.File]::WriteAllText((Join-Path $ns 'punch-list.md'), "# Punch list`n`n## Items`n`n- [ ] **A1 - one.**`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $ns '.shift-armed'), '', $utf8)
    [IO.File]::WriteAllText((Join-Path $ns '.shift-session'), "sess-1`n", $utf8)
    $marker = Join-Path $ns '.context-reset'

    $compact = Invoke-Hook $w '{"source":"compact","session_id":"sess-1"}'
    Expect-True ($compact.ExitCode -eq 0) "a compaction exits 0 (got $($compact.ExitCode))"
    Expect-True ($compact.Text -match 'SessionStart') 'a compaction emits the SessionStart event name'
    Expect-True ($compact.Text -match 'reload the nightshift skill') 'the line names the skill'
    Expect-True ($compact.Text -match 'the contract in punch-list.md') 'the line names the contract'
    Expect-True ($compact.Text -match 'receipts/') 'the line names the receipts folder'
    Expect-True ($compact.Text -match 'Receipts: one file per item under .nightshift/receipts/') `
        'a compaction restates the receipts duty'
    Expect-True (Test-Path -LiteralPath $marker -PathType Leaf) 'a compaction leaves the context-reset marker'

    Remove-Item -LiteralPath $marker -Force
    $resume = Invoke-Hook $w '{"source":"resume","session_id":"sess-1"}'
    Expect-True ($resume.Text -match 'SessionStart') 'a resumed conversation is treated the same way'
    Expect-True (Test-Path -LiteralPath $marker -PathType Leaf) 'a resume leaves the marker too'

    Remove-Item -LiteralPath $marker -Force
    $startup = Invoke-Hook $w '{"source":"startup","session_id":"sess-1"}'
    Expect-True ($startup.ExitCode -eq 0) 'an ordinary start exits 0'
    Expect-True ([string]::IsNullOrWhiteSpace($startup.Text)) 'an ordinary start says nothing'
    Expect-True (-not (Test-Path -LiteralPath $marker)) 'an ordinary start writes no marker'

    $other = Invoke-Hook $w '{"source":"compact","session_id":"sess-2"}'
    Expect-True ([string]::IsNullOrWhiteSpace($other.Text)) 'a second conversation on the same project says nothing'
    Expect-True (-not (Test-Path -LiteralPath $marker)) 'a second conversation writes no marker'

    $bad = Invoke-Hook $w 'not json at all'
    Expect-True ($bad.ExitCode -eq 0) 'a payload that will not parse exits 0'
    Expect-True ([string]::IsNullOrWhiteSpace($bad.Text)) 'a payload that will not parse says nothing'

    $idle = Join-Path $root 'unarmed'
    $null = New-Item -ItemType Directory -Path (Join-Path $idle '.nightshift') -Force
    $unarmed = Invoke-Hook $idle '{"source":"compact","session_id":"sess-1"}'
    Expect-True ($unarmed.ExitCode -eq 0) 'a project with no shift exits 0'
    Expect-True ([string]::IsNullOrWhiteSpace($unarmed.Text)) 'a project with no shift says nothing'
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures.Count -gt 0) {
    Write-Host "session-start-logic failed ($($failures.Count)):"
    foreach ($failure in $failures) { Write-Host " - $failure" }
    exit 1
}
Write-Host 'session-start-logic passed'
exit 0
