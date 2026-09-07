# Portable PowerShell coverage for the Windows dispatcher's workspace binding.
# Run on macOS or Windows: pwsh -File tests/windows/ns-logic.ps1
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if (Test-Path Variable:PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $false
}

$repository = Resolve-Path (Join-Path $PSScriptRoot '../..')
$dispatcher = Join-Path $repository 'plugins/nightshift/runtime/windows/ns.ps1'
$failures = New-Object 'System.Collections.Generic.List[string]'

function Expect-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        $failures.Add($Message)
        Write-Host "FAIL: $Message"
    }
}

# The dispatcher reads the environment, so each case runs in its own process with only what it
# needs set.
function Invoke-Dispatcher {
    param([Parameter(Mandatory = $true)][string]$Derived, [AllowEmptyString()][string]$Bound,
          [Parameter(Mandatory = $true)][string[]]$Arguments)
    $out = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N') + '.out')
    $previousDerived = $env:CLAUDE_PROJECT_DIR
    $previousBound = $env:NIGHTSHIFT_WORKSPACE
    $previousHost = $env:NIGHTSHIFT_HOST
    try {
        $env:CLAUDE_PROJECT_DIR = $Derived
        $env:NIGHTSHIFT_HOST = 'claude'
        if ([string]::IsNullOrEmpty($Bound)) {
            Remove-Item Env:NIGHTSHIFT_WORKSPACE -ErrorAction SilentlyContinue
        }
        else {
            $env:NIGHTSHIFT_WORKSPACE = $Bound
        }
        & (Get-Process -Id $PID).Path -NoProfile -NonInteractive -File $dispatcher @Arguments `
            > $out 2>&1
        $code = $LASTEXITCODE
        $text = ''
        if (Test-Path -LiteralPath $out) { $text = [IO.File]::ReadAllText($out) }
        return [pscustomobject]@{ ExitCode = $code; Text = $text }
    }
    finally {
        $env:CLAUDE_PROJECT_DIR = $previousDerived
        $env:NIGHTSHIFT_WORKSPACE = $previousBound
        $env:NIGHTSHIFT_HOST = $previousHost
        Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue
    }
}

function New-Workspace {
    param([Parameter(Mandatory = $true)][string]$Path)
    $null = New-Item -ItemType Directory -Path (Join-Path $Path '.nightshift') -Force
    return (Resolve-Path -LiteralPath $Path).ProviderPath
}

$root = Join-Path ([IO.Path]::GetTempPath()) ("ns-dispatcher-logic-" + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $root -Force
try {
    $here = New-Workspace (Join-Path $root 'here')
    $there = New-Workspace (Join-Path $root 'there')

    $unbound = Invoke-Dispatcher $here '' @('bind')
    Expect-True ($unbound.ExitCode -eq 0) "an unbound bind succeeds: $($unbound.Text)"
    Expect-True ($unbound.Text -match "SOURCE`tderived") 'with nothing bound, bind says derived'

    $same = Invoke-Dispatcher $here $here @('bind')
    Expect-True ($same.ExitCode -eq 0) "a bind that agrees succeeds: $($same.Text)"
    Expect-True ($same.Text -match "SOURCE`tbound") 'a bound workspace that agrees says bound'

    $beforeHere = @(Get-ChildItem -LiteralPath $here -Recurse -Force).Count
    $beforeThere = @(Get-ChildItem -LiteralPath $there -Recurse -Force).Count
    $clash = Invoke-Dispatcher $here $there @('scaffold')
    Expect-True ($clash.ExitCode -eq 2) "a disagreement refuses with 2 (got $($clash.ExitCode))"
    Expect-True ($clash.Text -match 'refuse workspace bound .* differs from derived ') 'the refusal names both'
    Expect-True ($clash.Text -match 'repair cd to the bound workspace, or unset NIGHTSHIFT_WORKSPACE') `
        'the refusal carries its repair'
    Expect-True (@(Get-ChildItem -LiteralPath $here -Recurse -Force).Count -eq $beforeHere) `
        'the refusal comes before the verb, so the derived workspace is untouched'
    Expect-True (@(Get-ChildItem -LiteralPath $there -Recurse -Force).Count -eq $beforeThere) `
        'and so is the bound one'

    $broken = New-Workspace (Join-Path $root 'broken')
    [IO.File]::WriteAllText((Join-Path $broken '.nightshift-link'), "nowhere-near-a-workspace`n",
        (New-Object Text.UTF8Encoding($false)))
    $invalid = Invoke-Dispatcher $here $broken @('bind')
    Expect-True ($invalid.ExitCode -eq 2) "an invalid bound link refuses with 2 (got $($invalid.ExitCode))"
    Expect-True ($invalid.Text -match 'refuse workspace invalid .nightshift-link at') `
        'an invalid bound link refuses the way an unreadable link always has'

    $writing = Invoke-Dispatcher $here '' @('scaffold')
    Expect-True (($writing.Text -split "`r?`n")[0] -ceq ('workspace ' + $here)) `
        "a verb that writes says where first (got $(($writing.Text -split [char]10)[0]))"
    $reading = Invoke-Dispatcher $here '' @('status')
    Expect-True (-not ($reading.Text -match '(?m)^workspace ')) 'a verb that only reads says nothing extra'
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures.Count -gt 0) {
    Write-Host "ns-logic failed ($($failures.Count)):"
    foreach ($failure in $failures) { Write-Host " - $failure" }
    exit 1
}
Write-Host 'ns-logic passed'
exit 0
