# Times a person reads, in the machine's own zone with its UTC offset: the PowerShell half of
# tests/local-time.bats, against whatever zone this machine runs in.
# Run on macOS or Windows: pwsh -File tests/windows/local-time-logic.ps1
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$repository = Resolve-Path (Join-Path $PSScriptRoot '../..')
Import-Module (Join-Path $repository 'plugins/nightshift/lib/Nightshift.psm1') -Force -DisableNameChecking
$failures = New-Object 'System.Collections.Generic.List[string]'
$utf8 = New-Object Text.UTF8Encoding($false)

function Expect-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        $failures.Add($Message)
        Write-Host "FAIL: $Message"
    }
}

# The offset this machine's zone has at that moment, spelled the way the runtime spells it.
function Get-ExpectedOffset {
    param([long]$Epoch)
    $offset = [TimeZoneInfo]::Local.GetUtcOffset([DateTimeOffset]::FromUnixTimeSeconds($Epoch))
    $sign = $(if ($offset -lt [TimeSpan]::Zero) { '-' } else { '+' })
    $offset = $offset.Duration()
    return ('(UTC{0}{1:00}:{2:00})' -f $sign, $offset.Hours, $offset.Minutes)
}

$root = Join-Path ([IO.Path]::GetTempPath()) ('ns-local-time-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $root -Force
try {
    $epoch = 1790000000
    $local = [DateTimeOffset]::FromUnixTimeSeconds($epoch).ToLocalTime()
    $want = $local.ToString('yyyy-MM-dd HH:mm', [Globalization.CultureInfo]::InvariantCulture) + ' ' + (Get-ExpectedOffset $epoch)
    Expect-True ((Get-NSLocalTime ([string]$epoch)) -ceq $want) "a local time is the machine's own: $(Get-NSLocalTime ([string]$epoch)) vs $want"
    Expect-True ((Get-NSLocalTime ([string]$epoch) -Seconds) -cmatch '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:20 \(UTC[+-][0-9]{2}:[0-9]{2}\)$') 'to the second'
    Expect-True ((Get-NSLocalTime 'not-a-time') -ceq '') 'an unreadable epoch is no time'

    # Shift-log lines and the stop-work order carry the local stamp.
    $ns = Join-Path $root '.nightshift'
    $null = New-Item -ItemType Directory -Path $ns -Force
    Write-NSControlLog $ns 'a line'
    $line = @([IO.File]::ReadAllLines((Get-NSLayoutPath $ns 'shift-log')))[0]
    Expect-True ($line -cmatch ('^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} \(UTC[+-][0-9]{2}:[0-9]{2}\) ' + [char]0x00B7 + ' a line$')) "a shift-log line: $line"

    # Status reads the shift changing hands from either runtime's local-time lines.
    $log = Join-Path $root 'transitions.md'
    [IO.File]::WriteAllText($log, ("2026-10-08 07:12:33 (UTC+04:00) - watchman armed`n" +
            "2026-10-08 07:13:00 (UTC+04:00) " + [char]0x00B7 + " shift started`n" +
            "2026-10-08 07:14:00 (UTC+04:00) " + [char]0x00B7 + " item 1 ticked`n"), $utf8)
    Expect-True (((Get-NSStatusTransitions $log 5) -join '|') -ceq 'watchman armed|shift started') 'transitions read through the offset'
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures.Count -gt 0) {
    Write-Host "local-time-logic failed ($($failures.Count)):"
    foreach ($failure in $failures) { Write-Host " - $failure" }
    exit 1
}
Write-Host 'local-time-logic passed'
exit 0
