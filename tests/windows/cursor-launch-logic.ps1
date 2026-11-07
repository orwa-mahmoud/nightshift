# Portable PowerShell probe for the Cursor revival launch record.
# Run on macOS or Windows: pwsh -File tests/windows/cursor-launch-logic.ps1
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$repository = Resolve-Path (Join-Path $PSScriptRoot '../..')
Import-Module (Join-Path $repository 'plugins/nightshift/lib/Nightshift.psm1') -Force -DisableNameChecking
$template = Join-Path $repository 'plugins/nightshift/skills/nightshift/references/nightshift-rules-template.json'
$utf8 = New-Object Text.UTF8Encoding($false)
$failures = New-Object 'System.Collections.Generic.List[string]'

function Expect-Equal {
    param($Expected, $Actual, [string]$Message)
    if ($Expected -cne $Actual) {
        $failures.Add("$Message (expected '$Expected', got '$Actual')")
        Write-Host "FAIL: $Message (expected '$Expected', got '$Actual')"
    }
}

function Expect-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        $failures.Add($Message)
        Write-Host "FAIL: $Message"
    }
}

$workspace = Join-Path ([IO.Path]::GetTempPath()) ('ns-cursor-launch-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path (Join-Path $workspace '.nightshift') | Out-Null
Copy-Item $template (Join-Path $workspace '.nightshift/rules.json')
$ns = Join-Path $workspace '.nightshift'
try {
    $empty = @(Get-NSCursorLaunchArguments $ns)
    Expect-Equal 0 $empty.Count 'a shift with no record adds no arguments'

    $document = ConvertFrom-NSJsonText ([IO.File]::ReadAllText((Join-Path $ns 'rules.json'), $utf8))
    $document['recovery']['cursorFlags'] = @('--force', '--yolo', '--trust', '--sandbox')
    [IO.File]::WriteAllText((Join-Path $ns 'rules.json'), (ConvertTo-NSCanonicalJson $document), $utf8)
    Add-NSCursorLaunchNote $ns '{"conversation_id":"conv-1","model":"ignored"}'
    $first = Get-NSCursorLaunch $ns
    Expect-True ($first.Model -cne 'ignored') 'the payload model is not recorded'
    Expect-Equal $true $first.Force '--force and its --yolo alias record as force'
    Expect-Equal $true $first.Trust '--trust is recorded'
    $document['recovery']['cursorFlags'] = @()
    [IO.File]::WriteAllText((Join-Path $ns 'rules.json'), (ConvertTo-NSCanonicalJson $document), $utf8)
    Add-NSCursorLaunchNote $ns '{"model_id":"composer-2","model":"other"}'
    $second = Get-NSCursorLaunch $ns
    Expect-Equal $first.Model $second.Model 'a later payload does not replace the recorded model'
    Expect-Equal $true $second.Force 'clearing the rules list does not drop a frozen flag'
    $passed = @((Get-NSCursorLaunchArguments $ns) -join ' ')
    Expect-True ($passed[0].Contains('--force')) 'force is passed'
    Expect-True ($passed[0].Contains('--trust')) 'trust is passed'
    Expect-True (-not $passed[0].Contains('ignored')) 'the payload model is not passed'
}
finally {
    Remove-Item -LiteralPath $workspace -Recurse -Force
}

$ancestor = Join-Path ([IO.Path]::GetTempPath()) ('ns-cursor-argv-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path (Join-Path $ancestor '.nightshift') | Out-Null
Copy-Item $template (Join-Path $ancestor '.nightshift/rules.json')
$ancestorNs = Join-Path $ancestor '.nightshift'
$stub = Join-Path $ancestor 'cursor-agent'
$note = Join-Path $ancestor 'note.ps1'
try {
    [IO.File]::WriteAllText($stub, @'
#!/bin/bash
cmd=()
seen=0
for a in "$@"; do
  if [ "$seen" = 1 ]; then
    cmd+=("$a")
  elif [ "$a" = "--run" ]; then
    seen=1
  fi
done
"${cmd[@]}"
'@)
    $module = Join-Path $repository 'plugins/nightshift/lib/Nightshift.psm1'
    [IO.File]::WriteAllText($note, @"
Import-Module '$module' -Force -DisableNameChecking
Add-NSCursorLaunchNote '$ancestorNs' '{"model_id":"grok-4.7"}'
"@)
    & bash $stub --model grok-4.7-high --force --trust --run pwsh -NoProfile -File $note
    Expect-Equal 0 $LASTEXITCODE 'the stub CLI ancestor ran the note'
    $recorded = Get-NSCursorLaunch $ancestorNs
    Expect-Equal 'grok-4.7-high' $recorded.Model 'argv model is recorded, not the payload base id'
    Expect-Equal $true $recorded.Force 'argv --force is recorded'
    Expect-Equal $true $recorded.Trust 'argv --trust is recorded'
    Add-NSCursorLaunchNote $ancestorNs '{"model_id":"other-model"}'
    $again = Get-NSCursorLaunch $ancestorNs
    Expect-Equal 'grok-4.7-high' $again.Model 'a later payload does not replace argv'
    $unread = Join-Path ([IO.Path]::GetTempPath()) ('ns-cursor-unread-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path (Join-Path $unread '.nightshift') | Out-Null
    Copy-Item $template (Join-Path $unread '.nightshift/rules.json')
    $unreadNs = Join-Path $unread '.nightshift'
    $unreadNote = Join-Path $unread 'note.ps1'
    $unreadDone = Join-Path $unread 'done'
    [IO.File]::WriteAllText($unreadNote, @"
Import-Module '$module' -Force -DisableNameChecking
Add-NSCursorLaunchNote '$unreadNs' '{"model_id":"grok-4.7"}'
Set-Content -LiteralPath '$unreadDone' -Value done
"@)
    if ($env:OS -eq 'Windows_NT') {
        & pwsh -NoProfile -File $unreadNote
    }
    else {
        & python3 -c @'
import os, sys
if os.fork() > 0:
    os.wait()
    raise SystemExit(0)
if os.fork() > 0:
    os._exit(0)
os.setsid()
os.execvp("pwsh", ["pwsh", "-NoProfile", "-File", sys.argv[1]])
'@ $unreadNote
        $waited = 0
        while (-not (Test-Path -LiteralPath $unreadDone) -and $waited -lt 50) {
            Start-Sleep -Milliseconds 100
            $waited++
        }
    }
    Expect-True (Test-Path -LiteralPath $unreadDone) 'the unreadable note finished'
    $blank = Get-NSCursorLaunch $unreadNs
    Expect-Equal '' $blank.Model 'an unreadable launch does not keep the payload model'
    Expect-Equal $false $blank.ModelKnown 'an unreadable model is not recorded as known'
    $args = @(Get-NSCursorLaunchArguments $ancestorNs)
    Expect-Equal '--model' $args[0] 'revival passes the recorded model'
    Expect-Equal 'grok-4.7-high' $args[1] 'revival passes the variant'
    Expect-Equal '--force' $args[2] 'revival passes force'
    Expect-Equal '--trust' $args[3] 'revival passes trust'
    Remove-Item -LiteralPath $unread -Recurse -Force
}
finally {
    Remove-Item -LiteralPath $ancestor -Recurse -Force
}

if ($failures.Count -gt 0) {
    Write-Host ("cursor-launch-logic failed ($($failures.Count))")
    exit 1
}
Write-Host 'cursor-launch-logic passed'
exit 0
