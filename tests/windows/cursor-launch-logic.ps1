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
    Expect-Equal 'ignored' $first.Model 'the payload model is recorded'
    Expect-Equal $true $first.Force '--force and its --yolo alias record as force'
    Expect-Equal $true $first.Trust '--trust is recorded'
    $document['recovery']['cursorFlags'] = @()
    [IO.File]::WriteAllText((Join-Path $ns 'rules.json'), (ConvertTo-NSCanonicalJson $document), $utf8)
    Add-NSCursorLaunchNote $ns '{"model_id":"composer-2","model":"other"}'
    $second = Get-NSCursorLaunch $ns
    Expect-Equal 'ignored' $second.Model 'a later payload does not replace the recorded model'
    Expect-Equal $true $second.Force 'clearing the rules list does not drop a frozen flag'
    $args = @(Get-NSCursorLaunchArguments $ns)
    Expect-Equal '--model' $args[0] 'the model flag comes first'
    Expect-Equal 'ignored' $args[1] 'the recorded model is the value'
    Expect-Equal '--force' $args[2] 'force is passed'
    Expect-Equal '--trust' $args[3] 'trust is passed'
    Expect-Equal 4 $args.Count 'nothing broader than the record is added'
}
finally {
    Remove-Item -LiteralPath $workspace -Recurse -Force
}

if ($failures.Count -gt 0) {
    Write-Host ("cursor-launch-logic failed ($($failures.Count))")
    exit 1
}
Write-Host 'cursor-launch-logic passed'
exit 0
