# Make a fixture unreadable or unwritable on the host that is actually running.
# Unix mode bits are not NTFS permissions, and /bin/chmod is not on a Windows runner.
if (-not (Test-Path Variable:\IsWindows)) { $global:IsWindows = ($env:OS -eq 'Windows_NT') }

function Invoke-NSFixtureMode {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][ValidateSet('000', '555', '644', '755')][string]$Mode
    )
    if ($env:OS -ne 'Windows_NT') {
        & chmod $Mode $Path
        if ($LASTEXITCODE -ne 0) { throw "chmod $Mode failed for $Path" }
        return
    }
    $user = $env:USERNAME
    switch ($Mode) {
        # Drop inherited full control and leave the fixture readable, not writable.
        '000' { & icacls.exe $Path /inheritance:r /grant:r "${user}:(N)" | Out-Null }
        '555' { & icacls.exe $Path /inheritance:r /grant:r "${user}:(OI)(CI)(RX)" | Out-Null }
        '644' { & icacls.exe $Path /inheritance:e /grant:r "${user}:(R,W)" | Out-Null }
        '755' { & icacls.exe $Path /inheritance:e /grant:r "${user}:(OI)(CI)F" | Out-Null }
    }
    if ($LASTEXITCODE -ne 0) { throw "icacls $Mode failed for $Path" }
}
