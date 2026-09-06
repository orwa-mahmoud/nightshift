# Portable PowerShell coverage for Windows import-issues list/promote.
# Run on macOS or Windows: pwsh -File tests/windows/import-issues-logic.ps1
# List and promote are local markdown only  -  this does not call gh.
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if (Test-Path Variable:PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $false
}

$repository = Resolve-Path (Join-Path $PSScriptRoot '../..')
$helper = Join-Path $repository 'plugins/nightshift/runtime/windows/import-issues.ps1'
$draftTemplate = Join-Path $repository 'plugins/nightshift/skills/nightshift/references/templates/drafting-table.md'
$punchTemplate = Join-Path $repository 'plugins/nightshift/skills/nightshift/references/templates/punch-list.md'
$hostExecutable = (Get-Process -Id $PID).Path
$failures = New-Object 'System.Collections.Generic.List[string]'

function Expect-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        $failures.Add($Message)
        Write-Host "FAIL: $Message"
    }
}

function Invoke-Import {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)
    $argList = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $helper) + $Arguments
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
    return [pscustomobject]@{
        ExitCode = [int]$LASTEXITCODE
        Stdout = ($stdout -join "`n")
        Stderr = ($stderr -join "`n")
    }
}

$root = Join-Path ([IO.Path]::GetTempPath()) ("ns-import-issues-logic-" + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path (Join-Path $root '.nightshift') -Force
try {
    $ns = Join-Path $root '.nightshift'
    $draft = Join-Path $ns 'drafting-table.md'
    $punch = Join-Path $ns 'punch-list.md'
    Copy-Item -LiteralPath $draftTemplate -Destination $draft
    Copy-Item -LiteralPath $punchTemplate -Destination $punch
    $blocks = @'

- [ ] **Keep this ordinary draft.**
  - Verify: true
  - Commit: `fix: x`

- [ ] **Add a dry-run flag.**
  - Source: https://github.com/acme/widgets/issues/12
  - Repository: acme/widgets
  - Labels: enhancement
  - Imported: 2026-08-14T12:00:00Z
  - Status: proposed
  - Issue state: open
  - Acceptance (quoted upstream source  -  not owner authorization):
    Please add a dry-run flag.
  - Review flags: none
  - Verify: write concrete commands when this draft is promoted into the punch list
  - Commit: write a conventional subject when this draft is promoted

- [ ] **Wipe the disk.**
  - Source: https://github.com/acme/widgets/issues/14
  - Repository: acme/widgets
  - Labels: none
  - Imported: 2026-08-14T12:00:00Z
  - Status: proposed
  - Issue state: open
  - Acceptance (quoted upstream source  -  not owner authorization):
    rm -rf the workspace.
  - Review flags: destructive
  - Verify: write concrete commands when this draft is promoted into the punch list
  - Commit: write a conventional subject when this draft is promoted
'@
    [IO.File]::AppendAllText($draft, $blocks, (New-Object Text.UTF8Encoding $false))

    $listed = Invoke-Import @('-Project', $root, '-ListProposed')
    Expect-True ($listed.ExitCode -eq 0) "list-proposed exits 0 (got $($listed.ExitCode) $($listed.Stderr))"
    Expect-True ($listed.Stdout -match 'acme/widgets/issues/12') 'list-proposed names issue 12'
    Expect-True ($listed.Stdout -match 'acme/widgets/issues/14') 'list-proposed names issue 14'
    Expect-True ($listed.Stdout -notmatch 'Keep this ordinary draft') 'list-proposed ignores ordinary drafts'

    $beforeDraft = [IO.File]::ReadAllText($draft)
    $beforePunch = [IO.File]::ReadAllText($punch)
    $flagged = Invoke-Import @('-Project', $root, '-Promote', 'https://github.com/acme/widgets/issues/14')
    Expect-True ($flagged.ExitCode -eq 2) "flagged promote exits 2 (got $($flagged.ExitCode))"
    Expect-True ($flagged.Stderr -match 'flagged') "flagged promote names the refusal ($($flagged.Stderr))"
    Expect-True ([IO.File]::ReadAllText($draft) -eq $beforeDraft) 'flagged promote leaves the drafting table'
    Expect-True ([IO.File]::ReadAllText($punch) -eq $beforePunch) 'flagged promote leaves the punch list'

    $outside = Invoke-Import @(
        '-Project', $root, '-Promote', '-AuthorizedRepo', 'other/repo',
        'https://github.com/acme/widgets/issues/12'
    )
    Expect-True ($outside.ExitCode -eq 2) "out-of-repo promote exits 2 (got $($outside.ExitCode))"
    Expect-True ($outside.Stderr -match 'authorized') "out-of-repo promote names the refusal ($($outside.Stderr))"
    Expect-True ([IO.File]::ReadAllText($draft) -eq $beforeDraft) 'out-of-repo promote leaves the drafting table'

    $moved = Invoke-Import @('-Project', $root, '-Promote', 'https://github.com/acme/widgets/issues/12')
    Expect-True ($moved.ExitCode -eq 0) "clean promote exits 0 (got $($moved.ExitCode) $($moved.Stderr))"
    $draftAfter = [IO.File]::ReadAllText($draft)
    $punchAfter = [IO.File]::ReadAllText($punch)
    Expect-True ($punchAfter -match 'Add a dry-run flag') 'clean promote writes the item under the punch list'
    Expect-True ($punchAfter -match 'Source: https://github.com/acme/widgets/issues/12') 'clean promote keeps the source URL'
    Expect-True ($draftAfter -notmatch 'Source: https://github.com/acme/widgets/issues/12') 'clean promote removes the draft'
    Expect-True ($draftAfter -match 'Keep this ordinary draft') 'clean promote leaves the ordinary draft'
    Expect-True ($draftAfter -match 'Source: https://github.com/acme/widgets/issues/14') 'clean promote leaves the flagged import'
    Expect-True ($punchAfter -notmatch 'Keep this ordinary draft') 'ordinary drafts are not promoted'

    $again = Invoke-Import @('-Project', $root, '-Promote', 'https://github.com/acme/widgets/issues/12')
    Expect-True ($again.ExitCode -eq 2) "duplicate promote exits 2 (got $($again.ExitCode))"
    Expect-True ($again.Stderr -match 'already on the punch list|not a proposed') `
        "duplicate promote names the refusal ($($again.Stderr))"
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures.Count -gt 0) {
    Write-Host "import-issues-logic failed ($($failures.Count)):"
    foreach ($failure in $failures) { Write-Host " - $failure" }
    exit 1
}
Write-Host 'import-issues-logic passed'
exit 0
