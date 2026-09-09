# Portable PowerShell probe for Windows hardhat command guards.
# Run on macOS or Windows before pushing: pwsh -File tests/windows/hardhat-logic.ps1
# It does not replace windows-native CI (ACLs, mutexes, dispatchers), and Windows CI
# also runs it via tests/windows/run.ps1.
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$repository = Resolve-Path (Join-Path $PSScriptRoot '../..')
$hardhat = Join-Path $repository 'plugins/nightshift/hooks/windows/hardhat.ps1'
$failures = New-Object 'System.Collections.Generic.List[string]'

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

$env:NIGHTSHIFT_HARDHAT_LIB = '1'
. $hardhat -HostName codex

$root = Join-Path ([IO.Path]::GetTempPath()) ("ns-hardhat-logic-" + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $root -Force
try {
    Set-Location $root
    $null = & git init --quiet
    $null = & git config user.email dev@example.com
    $null = & git config user.name tester
    $null = & git config core.autocrlf false
    [IO.File]::WriteAllText((Join-Path $root 'tracked.txt'), "seed`n")
    $null = & git add -- tracked.txt
    $null = & git commit --quiet -m init

    $script:cwd = $root
    $script:ns = Join-Path $root '.nightshift'
    $null = New-Item -ItemType Directory -Path $script:ns -Force
    [IO.File]::WriteAllText((Join-Path $script:ns 'punch-list.md'), "## Items`n- [x] **1. done.**`n")
    $null = New-Item -ItemType File -Path (Join-Path $script:ns '.shift-armed') -Force
    Expect-True (-not (Test-NSHardhatActive $script:ns)) 'ticked list is inert without STOP'
    [IO.File]::WriteAllText((Join-Path $script:ns 'STOP'), "stopped`n")
    Expect-True (Test-NSHardhatActive $script:ns) 'STOP keeps hardhat without open boxes'
    [IO.File]::WriteAllText((Join-Path $script:ns '.ended'), "ended`n")
    Expect-True (-not (Test-NSHardhatActive $script:ns)) 'ENDED stands hardhat down'
    Remove-Item -LiteralPath (Join-Path $script:ns 'STOP') -Force
    Remove-Item -LiteralPath (Join-Path $script:ns '.ended') -Force

    # Only a readable list with every box ticked takes the hardhat off; a list that
    # will not count is not zero open work.
    $onWindows = $env:OS -eq 'Windows_NT'
    if (-not $onWindows) {
        $lockedPunch = Join-Path $script:ns 'punch-list.md'
        & chmod 000 $lockedPunch
        try {
            Expect-True (Test-NSHardhatActive $script:ns) 'an uncountable punch list keeps the hardhat on'
        }
        finally {
            & chmod 644 $lockedPunch
        }
    }

    Expect-True (Test-NSControlTarget 'Remove-Item -Force .nightshift\.shift-armed') `
        'backslash control path is denied'
    Expect-True (Test-NSControlTarget 'cd .nightshift && unlink .shift-armed') `
        'cd .nightshift && unlink .shift-armed is a control target'
    Expect-True (-not (Test-NSLeaseTarget 'cd .nightshift && unlink .shift-armed')) `
        'cd .nightshift && unlink .shift-armed is not rm .nightshift'
    Expect-True (Test-NSControlTarget 'cd .nightshift && touch STOP') `
        'cd .nightshift && touch STOP is a control target'
    Expect-True (-not (Test-NSControlTarget 'touch STOP')) `
        'touch STOP at repo root is not a control target'
    Expect-True (Test-NSLeaseTarget 'rm -rf .nightshift') `
        'rm -rf .nightshift is a lease target'
    Expect-True (Test-NSLeaseTarget 'Remove-Item -Force .nightshift\.shift-*') `
        'indirect lease glob is a lease target'

    $null = New-Item -ItemType Directory -Path (Join-Path $root 'ai_docs') -Force
    [IO.File]::WriteAllText((Join-Path $root 'ai_docs/secret.txt'), "secret`n")
    $addAll = Get-NSCommandDenyReason -Command 'git add -A' -Scrubbed 'git add -A' `
        -CurrentDirectory $root -Workspace $root -ProtectedDirectories 'ai_docs' `
        -ExpectedEmail '' -NeverCommitPatterns '' -ForbiddenCommands ''
    Expect-True ($addAll -match 'protected directory') "git add -A: $addAll"

    $null = & git add -- ai_docs/secret.txt
    $null = & git commit --quiet -m protected
    Remove-Item -LiteralPath (Join-Path $root 'ai_docs/secret.txt') -Force
    $addDeleted = Get-NSCommandDenyReason -Command 'git add -A' -Scrubbed 'git add -A' `
        -CurrentDirectory $root -Workspace $root -ProtectedDirectories 'ai_docs' `
        -ExpectedEmail '' -NeverCommitPatterns '' -ForbiddenCommands ''
    Expect-True ($addDeleted -match 'protected directory') "git add -A deletion: $addDeleted"

    $gitDirAdd = Get-NSCommandDenyReason -Command 'git --git-dir=C:\elsewhere\.git add x' `
        -Scrubbed 'git --git-dir=C:\elsewhere\.git add x' `
        -CurrentDirectory $root -Workspace $root -ProtectedDirectories 'ai_docs' `
        -ExpectedEmail '' -NeverCommitPatterns '' -ForbiddenCommands ''
    Expect-True ($gitDirAdd -match 'protected-directory guard cannot verify') "git-dir add: $gitDirAdd"

    $workTreeCommit = Get-NSCommandDenyReason -Command 'git --work-tree=C:\elsewhere commit -am x' `
        -Scrubbed 'git --work-tree=C:\elsewhere commit -am MSG' `
        -CurrentDirectory $root -Workspace $root -ProtectedDirectories 'ai_docs' `
        -ExpectedEmail '' -NeverCommitPatterns '' -ForbiddenCommands ''
    Expect-True ($workTreeCommit -match 'protected-directory guard cannot verify') "work-tree commit: $workTreeCommit"

    [IO.File]::WriteAllText((Join-Path $root 'secret.txt'), "placeholder`n")
    $null = & git add -- secret.txt
    $null = & git commit --quiet -m secret-seed
    [IO.File]::WriteAllText((Join-Path $root 'secret.txt'), "SECRET_KEY=abc`n")
    $null = & git add -- secret.txt
    $commitStaged = Get-NSCommandDenyReason -Command 'git commit -m x' -Scrubbed 'git commit -m MSG' `
        -CurrentDirectory $root -Workspace $root -ProtectedDirectories '' `
        -ExpectedEmail '' -NeverCommitPatterns 'secret_key' -ForbiddenCommands ''
    Expect-True ($commitStaged -match 'never-commit pattern') "staged never-commit: $commitStaged"

    $null = & git reset --quiet HEAD -- secret.txt
    $commitAm = Get-NSCommandDenyReason -Command 'git commit -am x' -Scrubbed 'git commit -am MSG' `
        -CurrentDirectory $root -Workspace $root -ProtectedDirectories '' `
        -ExpectedEmail '' -NeverCommitPatterns 'secret_key' -ForbiddenCommands ''
    Expect-True ($commitAm -notmatch 'cannot verify') "git commit -am is modeled: $commitAm"
    Expect-True ($commitAm -match 'never-commit pattern') "git commit -am never-commit: $commitAm"

    Remove-Item -LiteralPath (Join-Path $root 'secret.txt') -Force
    $commitClean = Get-NSCommandDenyReason -Command 'git commit -am x' -Scrubbed 'git commit -am MSG' `
        -CurrentDirectory $root -Workspace $root -ProtectedDirectories '' `
        -ExpectedEmail '' -NeverCommitPatterns 'secret_key' -ForbiddenCommands ''
    Expect-True ([string]::IsNullOrWhiteSpace($commitClean)) "clean git commit -am: $commitClean"

    $push = Get-NSCommandDenyReason -Command 'git push origin HEAD' -Scrubbed 'git push origin HEAD' `
        -CurrentDirectory $root -Workspace $root -ProtectedDirectories '' `
        -ExpectedEmail '' -NeverCommitPatterns '' -ForbiddenCommands 'git .*push'
    Expect-True ($push -match 'forbidden list') "forbidden push: $push"
    Expect-True ($push -match 'parking-lot.md') "forbidden push names parking lot: $push"

    $badForbidden = Get-NSCommandDenyReason -Command 'git status' -Scrubbed 'git status' `
        -CurrentDirectory $root -Workspace $root -ProtectedDirectories '' `
        -ExpectedEmail '' -NeverCommitPatterns '' -ForbiddenCommands '[[:punct:]]'
    Expect-True ($badForbidden -match 'NIGHTSHIFT_FORBIDDEN_COMMANDS is not a valid extended regular expression') `
        "invalid forbidden pattern: $badForbidden"
    Expect-True ($badForbidden -match 'Fix the pattern in your session settings') `
        "invalid forbidden pattern names session settings: $badForbidden"

    $wrongEmail = Get-NSCommandDenyReason -Command 'git commit -m x' -Scrubbed 'git commit -m MSG' `
        -CurrentDirectory $root -Workspace $root -ProtectedDirectories '' `
        -ExpectedEmail 'owner@nope.io' -NeverCommitPatterns '' -ForbiddenCommands ''
    Expect-True ($wrongEmail -match "committer identity \('dev@example.com'\) is not the expected 'owner@nope.io'") `
        "wrong expectedEmail: $wrongEmail"
    Expect-True ($wrongEmail -match 'Fix git config user.email') "wrong expectedEmail names git config: $wrongEmail"

    $rightEmail = Get-NSCommandDenyReason -Command 'git commit -m x' -Scrubbed 'git commit -m MSG' `
        -CurrentDirectory $root -Workspace $root -ProtectedDirectories '' `
        -ExpectedEmail 'dev@example.com' -NeverCommitPatterns '' -ForbiddenCommands ''
    Expect-True ([string]::IsNullOrWhiteSpace($rightEmail)) "expected identity is allowed: $rightEmail"

    $overrideEmail = Get-NSCommandDenyReason -Command 'git -c user.email=other@example.com commit -m x' `
        -Scrubbed 'git -c user.email=other@example.com commit -m MSG' `
        -CurrentDirectory $root -Workspace $root -ProtectedDirectories '' `
        -ExpectedEmail 'dev@example.com' -NeverCommitPatterns '' -ForbiddenCommands ''
    Expect-True ($overrideEmail -match "repository's configured identity") `
        "command-line identity override: $overrideEmail"

    $gitDirCommit = Get-NSCommandDenyReason -Command 'git --git-dir=C:\elsewhere\.git commit -m x' `
        -Scrubbed 'git --git-dir=C:\elsewhere\.git commit -m MSG' `
        -CurrentDirectory $root -Workspace $root -ProtectedDirectories '' `
        -ExpectedEmail 'dev@example.com' -NeverCommitPatterns '' -ForbiddenCommands ''
    Expect-True ($gitDirCommit -match 'configured commit guards cannot verify') `
        "git-dir commit under expectedEmail: $gitDirCommit"

    $workTreeNever = Get-NSCommandDenyReason -Command 'git --work-tree=C:\elsewhere commit -am x' `
        -Scrubbed 'git --work-tree=C:\elsewhere commit -am MSG' `
        -CurrentDirectory $root -Workspace $root -ProtectedDirectories '' `
        -ExpectedEmail '' -NeverCommitPatterns 'secret_key' -ForbiddenCommands ''
    Expect-True ($workTreeNever -match 'configured commit guards cannot verify') `
        "work-tree commit under never-commit: $workTreeNever"

    # --- the policy files are control files ---

    foreach ($file in @('shift-policy.json', 'shift-defaults.json', 'deadline')) {
        Expect-True (Test-NSControlTarget "printf forged > .nightshift/$file") `
            "$file path rewrite is a control target"
        Expect-True (Test-NSControlTarget "Remove-Item -Force .nightshift\$file") `
            "$file backslash delete is a control target"
        Expect-True (Test-NSControlTarget "cd .nightshift && rm -f $file") `
            "$file name delete in the nightshift directory is a control target"
    }
    Expect-True (-not (Test-NSControlTarget 'printf x > deadline')) `
        'a deadline file outside .nightshift is not a control target'

    foreach ($form in @(
            '.nightshift//STOP',
            '.nightshift/./STOP',
            '.nightshift/../.nightshift/STOP',
            '.nightshift\STOP',
            '.nightshift\\STOP'
        )) {
        Expect-True (Test-NSControlTarget "touch $form") "Bash forge $form"
        Expect-True (Test-NSControlTarget $form) "Write/Edit path forge $form"
        $patchTargets = @(Get-NSPayloadTargets $null 'apply_patch' "*** Update File: $form")
        Expect-True ($patchTargets.Count -ge 1 -and (Test-NSControlTarget $patchTargets[0])) `
            "apply_patch forge $form"
    }
    $twin = Join-Path (Split-Path -Parent $root) ("ns-hardhat-twin-" + [guid]::NewGuid().ToString('N'))
    $twinCreated = $false
    try {
        $null = New-Item -ItemType SymbolicLink -Path $twin -Target $root -ErrorAction Stop
        $twinCreated = $true
    }
    catch {
        try {
            $null = New-Item -ItemType Junction -Path $twin -Target $root -ErrorAction Stop
            $twinCreated = $true
        }
        catch { }
    }
    if ($twinCreated) {
        try {
            $twinStop = Join-Path $twin '.nightshift/STOP'
            Expect-True (Test-NSControlTarget "touch $twinStop") "Bash absolute twin $twinStop"
            Expect-True (Test-NSControlTarget $twinStop) "Write/Edit absolute twin $twinStop"
            $twinPatch = @(Get-NSPayloadTargets $null 'apply_patch' "*** Update File: $twinStop")
            Expect-True ($twinPatch.Count -ge 1 -and (Test-NSControlTarget $twinPatch[0])) `
                "apply_patch absolute twin $twinStop"
        }
        finally {
            try {
                Remove-Item -LiteralPath $twin -Force -Confirm:$false -ErrorAction SilentlyContinue
            }
            catch { }
        }
    }
    $canonRoot = $null
    try { $canonRoot = Resolve-NSCanonicalPath $root } catch { }
    if (-not [string]::IsNullOrEmpty($canonRoot) -and $canonRoot -cne $root) {
        $canonStop = Join-Path $canonRoot '.nightshift/STOP'
        Expect-True (Test-NSControlTarget $canonStop) "absolute twin via canonical root $canonStop"
    }

    [IO.File]::WriteAllText((Join-Path $script:ns 'parking-lot.md'), "lot`n")
    $lotAppend = "echo 'needs a change to .nightshift/rules.json' >> .nightshift/parking-lot.md"
    Expect-True (Test-NSInertParkingLotWrite 'Bash' $null $lotAppend) `
        'literal parking-lot append naming rules.json is inert'
    Expect-True (-not (Test-NSInertParkingLotWrite 'Bash' $null "echo '{}' > .nightshift/rules.json")) `
        'a real write to rules.json is not an inert parking-lot append'
    Expect-True (Test-NSRulesTarget "echo '{}' > .nightshift/rules.json") `
        'a real write to rules.json still matches the rules-file guard'
    Expect-True (-not (Test-NSInertParkingLotWrite 'Bash' $null 'echo $(cat .nightshift/rules.json) >> .nightshift/parking-lot.md')) `
        'an executable substitution is not a literal append'
    Expect-True (-not (Test-NSInertParkingLotWrite 'Bash' $null "echo 'rules.json' >> .nightshift/parking-lot.md && echo '{}' > .nightshift/rules.json")) `
        'a compound append plus protected write is not inert'
    $writeLot = [pscustomobject]@{ file_path = (Join-Path $script:ns 'parking-lot.md'); content = 'needs .nightshift/rules.json' }
    Expect-True (Test-NSInertParkingLotWrite 'Write' $writeLot '') `
        'a host file-edit of parking-lot.md is inert'
    $writeRules = [pscustomobject]@{ file_path = (Join-Path $script:ns 'rules.json'); content = '{}' }
    Expect-True (-not (Test-NSInertParkingLotWrite 'Write' $writeRules '')) `
        'a host file-edit of rules.json is not inert'
    $linkedLot = $false
    try {
        Remove-Item -LiteralPath (Join-Path $script:ns 'parking-lot.md') -Force
        $null = New-Item -ItemType SymbolicLink -Path (Join-Path $script:ns 'parking-lot.md') `
            -Target (Join-Path $script:ns 'rules.json') -ErrorAction Stop
        $linkedLot = $true
    }
    catch { }
    if ($linkedLot) {
        Expect-True (-not (Test-NSInertParkingLotWrite 'Bash' $null $lotAppend)) `
            'a parking-lot append through a symlink to the rules file does not qualify'
        Expect-True (Test-NSWriteTargetReachesRules (Join-Path $script:ns 'parking-lot.md')) `
            'the parking-lot symlink is a write that reaches the rules file'
        Remove-Item -LiteralPath (Join-Path $script:ns 'parking-lot.md') -Force
        [IO.File]::WriteAllText((Join-Path $script:ns 'parking-lot.md'), "lot`n")
    }

    # --- elevation categories ---

    $nightshift = Join-Path $root '.nightshift'
    $null = New-Item -ItemType Directory -Path $nightshift -Force
    $rulesPath = Join-Path $nightshift 'rules.json'
    $policyPath = Join-Path $nightshift 'shift-policy.json'
    $template = Join-Path $repository 'plugins/nightshift/skills/nightshift/references/nightshift-rules-template.json'
    Copy-Item -LiteralPath $template -Destination $rulesPath -Force

    function Get-ElevationReason {
        param([Parameter(Mandatory = $true)][string]$Command)
        return Get-NSCommandDenyReason -Command $Command -Scrubbed (Remove-NSCommitMessage $Command) `
            -CurrentDirectory $root -Workspace $root -ProtectedDirectories '' `
            -ExpectedEmail '' -NeverCommitPatterns '' -ForbiddenCommands ''
    }

    $categoryCommands = @{
        'sudo' = 'sudo apt-get install -y jq'
        'containers' = 'docker compose up -d'
        'global-packages' = 'brew install shellcheck'
        'daemons' = 'systemctl start nginx'
        'external-services' = 'gh auth login'
    }
    foreach ($category in @('sudo', 'containers', 'global-packages', 'daemons', 'external-services')) {
        $reason = Get-ElevationReason $categoryCommands[$category]
        $expected = "BLOCKED: this command needs the '$category' elevation category, which is denied for this shift. The owner allows it in .nightshift/rules.json (elevation.$category.policy) or for one shift in shift-policy.json before arming. Park the item in .nightshift/parking-lot.md as `"needs allowance: $category`" and keep working."
        Expect-True ($reason -ceq $expected) "$category default deny: $reason"
    }

    foreach ($command in @("psql -c 'select 1'", 'curl http://localhost:3000', 'npm test', 'docker ps', 'docker logs web', 'brew list')) {
        $reason = Get-ElevationReason $command
        Expect-True ([string]::IsNullOrEmpty($reason)) "using what already runs is never elevation: $command -> $reason"
    }
    $bypass = @{
        'sudo' = @('/usr/bin/sudo id', 'sudo;id', "eval 'sudo id'", "sh -c 'sudo apt-get install -y jq'")
        'containers' = @('docker run alpine', 'docker create alpine', 'docker start web', 'docker build .', 'curl --unix-socket /var/run/docker.sock http://localhost/info')
        'global-packages' = @('pip install black', 'cargo install ripgrep', 'go install example.com/cmd@latest', 'apt-get upgrade jq', 'brew uninstall shellcheck')
    }
    foreach ($category in @('sudo', 'containers', 'global-packages')) {
        $expected = "BLOCKED: this command needs the '$category' elevation category, which is denied for this shift. The owner allows it in .nightshift/rules.json (elevation.$category.policy) or for one shift in shift-policy.json before arming. Park the item in .nightshift/parking-lot.md as `"needs allowance: $category`" and keep working."
        foreach ($command in $bypass[$category]) {
            $reason = Get-ElevationReason $command
            Expect-True ($reason -ceq $expected) "create-state deny $command : $reason"
        }
    }
    # The Windows guard scrubs commit messages and nothing else, so a here-document reaches it
    # whole. An interpreter reading its script from one is inspected like any other command.
    $heredoc = @(
        "bash <<'EOF'`nsudo id`nEOF",
        "cat <<'EOF' | bash`nsudo id`nEOF",
        "python3 - <<'PY'`nrun('sudo id')`nPY"
    )
    foreach ($command in $heredoc) {
        $reason = Get-ElevationReason $command
        Expect-True ($reason -match 'needs allowance: sudo') "heredoc into an interpreter: $reason"
    }

    $messageOnly = Get-ElevationReason "git commit -m 'sudo apt-get install jq and docker compose up'"
    Expect-True ([string]::IsNullOrEmpty($messageOnly)) "a commit message names no category: $messageOnly"

    # A rules file that names no elevation answers from the built-in patterns alone, and answers
    # the same corpus the same way — the guard does not depend on the owner's file carrying them.
    $templateRules = [IO.File]::ReadAllText($rulesPath)
    $strippedRules = $templateRules | ConvertFrom-Json
    $null = $strippedRules.PSObject.Properties.Remove('elevation')
    [IO.File]::WriteAllText($rulesPath, ($strippedRules | ConvertTo-Json -Depth 10))
    foreach ($command in @('docker ps', 'docker logs web', 'brew list')) {
        $reason = Get-ElevationReason $command
        Expect-True ([string]::IsNullOrEmpty($reason)) "built-in patterns leave inspection alone: $command -> $reason"
    }
    foreach ($category in @('sudo', 'containers', 'global-packages')) {
        $expected = "BLOCKED: this command needs the '$category' elevation category, which is denied for this shift. The owner allows it in .nightshift/rules.json (elevation.$category.policy) or for one shift in shift-policy.json before arming. Park the item in .nightshift/parking-lot.md as `"needs allowance: $category`" and keep working."
        foreach ($command in $bypass[$category]) {
            $reason = Get-ElevationReason $command
            Expect-True ($reason -ceq $expected) "built-in create-state deny $command : $reason"
        }
    }
    [IO.File]::WriteAllText($rulesPath, $templateRules)

    $rules = Get-Content -LiteralPath $rulesPath -Raw | ConvertFrom-Json
    $rules.elevation.containers.policy = 'allow'
    [IO.File]::WriteAllText($rulesPath, ($rules | ConvertTo-Json -Depth 10))
    Expect-True ([string]::IsNullOrEmpty((Get-ElevationReason 'docker compose up -d'))) `
        'a rules allowance lifts its category'
    Expect-True ((Get-ElevationReason 'sudo id') -match 'needs allowance: sudo') `
        'a rules allowance lifts nothing else'
    $rules.elevation.containers.policy = 'deny'
    [IO.File]::WriteAllText($rulesPath, ($rules | ConvertTo-Json -Depth 10))

    $oneShift = @'
{"schemaVersion":1,"shiftId":"9f2c40ab77e51d63","createdAt":"2026-09-02T02:30:00Z",
 "source":"composition","deadlineEpoch":null,"verificationLevel":"final",
 "toolingPolicy":"existing-tools",
 "allowances":[{"category":"containers","scope":"category","provenance":"one-shift"}]}
'@
    [IO.File]::WriteAllText($policyPath, $oneShift)
    Expect-True ([string]::IsNullOrEmpty((Get-ElevationReason 'docker compose up -d'))) `
        'a one-shift allowance lifts the category'

    $workTarget = Get-NSAbsolutePath (Resolve-NSWorkTarget $root)
    $digest = Get-NSPolicyPlanDigest -Commands @('docker compose up -d') -WorkTarget $workTarget -ShiftId '9f2c40ab77e51d63'
    $exactPlan = @'
{"schemaVersion":1,"shiftId":"9f2c40ab77e51d63","createdAt":"2026-09-02T02:30:00Z",
 "source":"composition","deadlineEpoch":null,"verificationLevel":"final",
 "toolingPolicy":"existing-tools",
 "allowances":[{"category":"containers","scope":"exact-plan","provenance":"one-shift",
   "plan":{"commands":["docker compose up -d"],"workTarget":"__TARGET__","digest":"__DIGEST__"}}]}
'@
    $escapedTarget = $workTarget.Replace('\', '\\')
    [IO.File]::WriteAllText($policyPath, $exactPlan.Replace('__TARGET__', $escapedTarget).Replace('__DIGEST__', $digest))
    Expect-True ([string]::IsNullOrEmpty((Get-ElevationReason 'docker compose up -d'))) `
        'an exact plan permits the command it lists'
    $mismatch = Get-ElevationReason 'docker compose down'
    Expect-True ($mismatch -ceq "BLOCKED: this command needs the 'containers' elevation category, which is denied for this shift. An exact-plan allowance exists but this command is not one of its approved commands.") `
        "a neighbouring command is an exact-plan mismatch: $mismatch"

    [IO.File]::WriteAllText($policyPath, $exactPlan.Replace('__TARGET__', $escapedTarget).Replace('__DIGEST__', ('0' * 64)))
    Expect-True ((Get-ElevationReason 'docker compose up -d') -match 'not one of its approved commands') `
        'a plan whose digest does not cover it is not the approved plan'
    Remove-Item -LiteralPath $policyPath -Force

    $rules.elevation.daemons.pattern = '(unclosed'
    [IO.File]::WriteAllText($rulesPath, ($rules | ConvertTo-Json -Depth 10))
    $broken = Get-ElevationReason 'git status'
    Expect-True ($broken -match 'elevation\.daemons\.pattern is not a valid extended regular expression') `
        "an invalid elevation pattern fails closed: $broken"
    Expect-True ($broken -match 'so the guard it configures cannot run') `
        "an invalid elevation pattern uses the shared wording: $broken"

# --- lease reclaim, live-holder fence, disarm-total (Windows twin of the POSIX ownership fence) ---
# NIGHTSHIFT_HARDHAT_LIB is cleared above; these cases spawn the real hook so its full
# permission decision - not just the library functions - is what gets checked.

$hostExe = (Get-Process -Id $PID).Path

function Invoke-NSLeaseHardhat {
    param(
        [Parameter(Mandatory = $true)][string]$Workspace,
        [Parameter(Mandatory = $true)][string]$SessionId,
        [Parameter(Mandatory = $true)][string]$Tool,
        [Parameter(Mandatory = $true)][hashtable]$ToolInput
    )
    $payload = @{
        session_id = $SessionId
        transcript_path = ''
        cwd = $Workspace
        tool_name = $Tool
        tool_input = $ToolInput
    } | ConvertTo-Json -Compress -Depth 10
    $managed = @('NIGHTSHIFT_HARDHAT_LIB', 'NIGHTSHIFT_REVIVAL', 'NIGHTSHIFT_LEASE_GENERATION', 'NIGHTSHIFT_LEASE_NONCE', 'CODEX_PROJECT_DIR', 'CLAUDE_PROJECT_DIR')
    $saved = @{}
    foreach ($key in $managed) {
        $saved[$key] = [Environment]::GetEnvironmentVariable($key, 'Process')
        [Environment]::SetEnvironmentVariable($key, $null, 'Process')
    }
    [Environment]::SetEnvironmentVariable('CODEX_PROJECT_DIR', $Workspace, 'Process')
    try {
        $output = @($payload | & $hostExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $hardhat -HostName codex 2>&1)
        $code = $LASTEXITCODE
        $stdoutLines = @($output | Where-Object { $_ -isnot [Management.Automation.ErrorRecord] } | ForEach-Object { [string]$_ })
        return [pscustomobject]@{ ExitCode = $code; Stdout = ($stdoutLines -join "`n") }
    }
    finally {
        foreach ($key in $managed) {
            [Environment]::SetEnvironmentVariable($key, $saved[$key], 'Process')
        }
    }
}

$leaseRoot = Join-Path ([IO.Path]::GetTempPath()) ("ns-hardhat-lease-" + [guid]::NewGuid().ToString('N'))
try {
    $leaseWorkspace = Join-Path $leaseRoot 'workspace'
    $leaseNs = Join-Path $leaseWorkspace '.nightshift'
    $null = New-Item -ItemType Directory -Path $leaseNs -Force
    $rulesTemplate = Join-Path $repository 'plugins/nightshift/skills/nightshift/references/nightshift-rules-template.json'
    Copy-Item -LiteralPath $rulesTemplate -Destination (Join-Path $leaseNs 'rules.json') -Force
    [IO.File]::WriteAllText((Join-Path $leaseNs 'punch-list.md'), "# Contract`n`n## Items`n- [ ] one`n")
    [IO.File]::WriteAllText((Join-Path $leaseNs '.shift-armed'), '')

    $recordedSession = 'lease-recorded-session'
    [IO.File]::WriteAllText((Join-Path $leaseNs '.shift-session'), "$recordedSession`n`n`n`ncodex`n")
    [IO.File]::WriteAllText((Join-Path $leaseNs 'shift-log.md'), '')
    $deadStart = '2000-01-01T00:00:00.0000000Z'
    $deadPid = [string]$PID # a real, live pid - but this birthday can never match it, so it reads dead

    $bind = Invoke-NSLeaseHardhat -Workspace $leaseWorkspace -SessionId $recordedSession -Tool 'PowerShell' `
        -ToolInput @{ command = "`$null = 'nightshift-binding-probe'" }
    Expect-True ($bind.ExitCode -eq 0 -and [string]::IsNullOrWhiteSpace($bind.Stdout)) `
        "lease fixture binds the recorded conversation (exit=$($bind.ExitCode) stdout='$($bind.Stdout)')"

    # A watchman revival attempt took the lease and then died before attaching a live pid to
    # the recorded conversation's next tool call.
    Expect-True (Write-NSLease -NightshiftDir $leaseNs -SessionId $recordedSession -HostName 'codex' `
        -Generation 2 -Nonce 'lease-logic-dead-nonce' -ProcessId $deadPid -Start $deadStart) `
        'dead-holder lease fixture writes'

    $reclaim = Invoke-NSLeaseHardhat -Workspace $leaseWorkspace -SessionId $recordedSession -Tool 'PowerShell' `
        -ToolInput @{ command = 'Get-Location' }
    Expect-True ($reclaim.ExitCode -eq 0 -and [string]::IsNullOrWhiteSpace($reclaim.Stdout)) `
        "the recorded conversation reclaims a dead-holder lease instead of being fenced (exit=$($reclaim.ExitCode) stdout='$($reclaim.Stdout)')"
    $reclaimedLease = Read-NSLease $leaseNs
    Expect-True ($null -ne $reclaimedLease -and $reclaimedLease.Generation -eq 3 -and [string]::IsNullOrEmpty($reclaimedLease.Nonce)) `
        "the reclaim advances the generation and clears the nonce (generation=$($reclaimedLease.Generation) nonce='$($reclaimedLease.Nonce)')"
    $logText = [IO.File]::ReadAllText((Join-Path $leaseNs 'shift-log.md'))
    $expectedLogLine = "lease reclaimed by the recorded conversation after a dead recovery attempt (generation 2 $([char]0x2192) 3)"
    Expect-True ($logText.Contains($expectedLogLine)) "the reclaim is recorded in the shift log: $logText"

    # A live recovery worker still fences the recorded conversation - only a dead one reclaims.
    # This process is the holder: Linux Get-Process StartTime is not stable across
    # processes, so a written 'o' stamp can read as PID reuse and look dead.
    Expect-True (Write-NSLease -NightshiftDir $leaseNs -SessionId $recordedSession -HostName 'codex' `
        -Generation 10 -Nonce 'lease-logic-live-nonce' -ProcessId ([string]$PID) -Start '') `
        'live-holder lease fixture writes'

    $liveFence = Invoke-NSLeaseHardhat -Workspace $leaseWorkspace -SessionId $recordedSession -Tool 'PowerShell' `
        -ToolInput @{ command = 'Get-Location' }
    Expect-True ($liveFence.Stdout -match 'being recovered in another process') `
        "a live recovery worker still fences the recorded conversation (exit=$($liveFence.ExitCode) stdout='$($liveFence.Stdout)')"

    $stopHelper = Join-Path $repository 'plugins/nightshift/runtime/windows/stop-shift.ps1'
    $liveStop = Invoke-NSLeaseHardhat -Workspace $leaseWorkspace -SessionId $recordedSession -Tool 'PowerShell' `
        -ToolInput @{ command = "$stopHelper -Project $leaseWorkspace" }
    Expect-True ($liveStop.ExitCode -eq 0 -and [string]::IsNullOrWhiteSpace($liveStop.Stdout)) `
        "the Stop helper is allowed through a live foreign lease (exit=$($liveStop.ExitCode) stdout='$($liveStop.Stdout)')"
    $liveLeaseUnchanged = Read-NSLease $leaseNs
    Expect-True ($null -ne $liveLeaseUnchanged -and $liveLeaseUnchanged.Generation -eq 10 -and $liveLeaseUnchanged.Nonce -eq 'lease-logic-live-nonce') `
        'checking a live fence never mutates the lease it inspects'

    # A caller that is not the conversation named in .shift-session is still refused, never
    # reclaims - direct call, since the full pipeline never routes a stranger this far.
    $strangerNs = Join-Path $leaseRoot 'stranger/.nightshift'
    $null = New-Item -ItemType Directory -Path $strangerNs -Force
    Expect-True (Write-NSLease -NightshiftDir $strangerNs -SessionId 'stranger-recorded-conversation' -HostName 'codex' `
        -Generation 4 -Nonce 'lease-logic-stranger-nonce' -ProcessId $deadPid -Start $deadStart) `
        'stranger fixture writes a dead-holder lease'
    $strangerSession = [pscustomobject]@{
        SessionId = 'stranger-recorded-conversation'; Transcript = ''; ProcessId = ''; Start = ''; HostName = 'codex'
    }
    $strangerDecision = Resolve-NSShiftAuthorize -NightshiftDir $strangerNs -HostName 'codex' `
        -SessionId 'a-third-party-conversation' -ProcessId '' -ProcessStart '' -Nonce '' -Generation '' `
        -Revival $true -Mode hardhat -Session $strangerSession
    Expect-True ($strangerDecision.Status -eq 'Fail' -and $strangerDecision.Message -match 'continued in a recovered process') `
        "a conversation other than the recorded one is refused, not reclaimed ($($strangerDecision.Status): $($strangerDecision.Message))"
    $strangerLeaseAfter = Read-NSLease $strangerNs
    Expect-True ($null -ne $strangerLeaseAfter -and $strangerLeaseAfter.Generation -eq 4 -and $strangerLeaseAfter.Nonce -eq 'lease-logic-stranger-nonce') `
        'a refused reclaim attempt leaves the foreign lease untouched'

    # Liveness that cannot be classified (a malformed pid stands in for missing process
    # evidence) keeps the fence - it never counts as proof of death.
    $unclassifiedNs = Join-Path $leaseRoot 'unclassified/.nightshift'
    $null = New-Item -ItemType Directory -Path $unclassifiedNs -Force
    Expect-True (Write-NSLease -NightshiftDir $unclassifiedNs -SessionId 'unclassified-recorded-conversation' -HostName 'codex' `
        -Generation 1 -Nonce 'lease-logic-unclassified-nonce' -ProcessId '0' -Start '') `
        'unclassified-liveness fixture writes'
    $unclassifiedSession = [pscustomobject]@{
        SessionId = 'unclassified-recorded-conversation'; Transcript = ''; ProcessId = ''; Start = ''; HostName = 'codex'
    }
    $unclassifiedDecision = Resolve-NSShiftAuthorize -NightshiftDir $unclassifiedNs -HostName 'codex' `
        -SessionId 'unclassified-recorded-conversation' -ProcessId '' -ProcessStart '' -Nonce '' -Generation '' `
        -Revival $false -Mode hardhat -Session $unclassifiedSession
    Expect-True ($unclassifiedDecision.Status -eq 'Fail' -and $unclassifiedDecision.Message -match 'continued in a recovered process') `
        "liveness that cannot be classified keeps the fence ($($unclassifiedDecision.Status): $($unclassifiedDecision.Message))"

    # Disarm is total: a missing armed marker holds nobody, even a foreign lease.
    $disarmedWorkspace = Join-Path $leaseRoot 'disarmed'
    $disarmedNs = Join-Path $disarmedWorkspace '.nightshift'
    $null = New-Item -ItemType Directory -Path $disarmedNs -Force
    [IO.File]::WriteAllText((Join-Path $disarmedNs 'punch-list.md'), "# Contract`n`n## Items`n- [ ] one`n")
    # .shift-armed is deliberately absent.
    Expect-True (Write-NSLease -NightshiftDir $disarmedNs -SessionId 'disarmed-someone-else' -HostName 'codex' `
        -Generation 7 -Nonce 'lease-logic-disarmed-nonce' -ProcessId '' -Start '') `
        'disarmed fixture writes a foreign lease'
    $disarmedTool = Invoke-NSLeaseHardhat -Workspace $disarmedWorkspace -SessionId 'any-conversation-at-all' `
        -Tool 'PowerShell' -ToolInput @{ command = 'Get-Location' }
    Expect-True ($disarmedTool.ExitCode -eq 0 -and [string]::IsNullOrWhiteSpace($disarmedTool.Stdout)) `
        "a disarmed site holds nobody, even against a foreign lease (exit=$($disarmedTool.ExitCode) stdout='$($disarmedTool.Stdout)')"
    $disarmedLeaseUnchanged = Read-NSLease $disarmedNs
    Expect-True ($null -ne $disarmedLeaseUnchanged -and $disarmedLeaseUnchanged.Generation -eq 7) `
        'a disarmed pass-through never touches the lease'
}
finally {
    Remove-Item -LiteralPath $leaseRoot -Recurse -Force -Confirm:$false -ErrorAction SilentlyContinue
}
}
finally {
    Set-Location $repository
    Remove-Item -LiteralPath $root -Recurse -Force -Confirm:$false -ErrorAction SilentlyContinue
    Remove-Item Env:NIGHTSHIFT_HARDHAT_LIB -ErrorAction SilentlyContinue
}

if ($failures.Count -gt 0) {
    Write-Host "hardhat-logic failed ($($failures.Count)):"
    foreach ($failure in $failures) { Write-Host " - $failure" }
    exit 1
}
Write-Host 'hardhat-logic passed'
exit 0
