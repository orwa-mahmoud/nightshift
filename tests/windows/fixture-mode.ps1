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
        # (N) is not an icacls right. Denying read makes the file unreadable to this user.
        # A directory that must reject a new child needs the add-subdirectory right denied,
        # which generic write does not cover.
        '000' { & icacls.exe $Path /deny "${user}:R" | Out-Null }
        '555' { & icacls.exe $Path /deny "${user}:(OI)(CI)(W,WD,AD,DC)" | Out-Null }
        '644' { & icacls.exe $Path /remove:d $user | Out-Null }
        '755' { & icacls.exe $Path /remove:d $user | Out-Null }
    }
    if ($LASTEXITCODE -ne 0) { throw "icacls $Mode failed for $Path" }
}
