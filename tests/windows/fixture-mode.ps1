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
    # A deny entry wins over the inherited allow. icacls generic write does not stop
    # creating a child directory, so the rights are the .NET ones Copy-Item actually needs.
    $acl = Get-Acl -LiteralPath $Path
    $who = New-Object System.Security.Principal.NTAccount($env:USERNAME)
    foreach ($entry in @($acl.Access)) {
        if ($entry.AccessControlType -eq 'Deny' -and $entry.IdentityReference.Value -like "*\$env:USERNAME") {
            [void]$acl.RemoveAccessRule($entry)
        }
    }
    if ($Mode -eq '000' -or $Mode -eq '555') {
        $rights = if ($Mode -eq '000') {
            [System.Security.AccessControl.FileSystemRights]'ReadData,ReadAndExecute'
        }
        else {
            [System.Security.AccessControl.FileSystemRights]'CreateFiles,CreateDirectories,WriteData,AppendData,Delete,DeleteSubdirectoriesAndFiles'
        }
        # Inheritance flags are legal only on a directory. A file rejects them.
        $isDir = (Get-Item -LiteralPath $Path).PSIsContainer
        $inherit = if ($isDir) {
            [System.Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit'
        }
        else {
            [System.Security.AccessControl.InheritanceFlags]::None
        }
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $who, $rights, $inherit,
            [System.Security.AccessControl.PropagationFlags]::None,
            [System.Security.AccessControl.AccessControlType]::Deny)
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}
